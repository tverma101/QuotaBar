import Foundation
import CoreFoundation

/// Uses measured Devin CLI session database usage first, falling back to ATIF exports when the
/// database is missing or has no metered calls. The sources are never added together.
actor DevinTranscriptUsageScanner {
    private static let futureTimestampDiagnosticKey = "devin.transcripts.future-timestamp"
    private static let enumerationDiagnosticKey = "devin.transcripts.enumeration"

    /// One metered model call inside a transcript's `steps` array.
    struct Entry: Codable, Sendable, Equatable {
        var timestamp: Date
        var model: String
        var tokens: TokenBreakdown
    }

    private let transcriptsDirectory: URL
    private let sessionDatabase: URL
    private let scanner: IncrementalJSONLScanner<Entry>
    private var sessionUsageReader = DevinSessionUsageReader()

    private static let sharedScanner = IncrementalJSONLScanner<Entry>(
        retainResidentItems: false,
        logTag: LogTag.plugin("devin"),
        persistence: JSONLScanCachePersistence(namespace: "devin", schemaVersion: 1)
    )

    static func flushPersistentCacheWrites() async {
        await sharedScanner.flushPendingWrites()
    }

    init(
        transcriptsDirectory: URL = DevinTranscriptUsageScanner.defaultTranscriptsDirectory(),
        incrementalScanner: IncrementalJSONLScanner<Entry>? = nil
    ) {
        self.transcriptsDirectory = transcriptsDirectory
        self.sessionDatabase = transcriptsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("sessions.db")
        self.scanner = incrementalScanner ?? Self.sharedScanner
    }

    static func defaultTranscriptsDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory.appendingPathComponent(".local/share/devin/cli/transcripts", isDirectory: true)
    }

    /// Fold local session usage — the CLI's session database first, exported transcripts as the
    /// fallback — into per-day token/cost rows. `nil` means the source could not be completely read
    /// (database or enumeration failure, a damaged or mid-rewrite transcript, a future timestamp);
    /// the provider then keeps its last-good history instead of publishing a partial fold.
    func scan(daysBack: Int = UsageHistoryWindow.previousDays, now: Date = Date(), pricing: ModelPricing) async -> LogUsageScan? {
        let directory = transcriptsDirectory.resolvingSymlinksInPath().standardizedFileURL
        let identity = directory.path
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let maximumSessionTimestamp = JSONLScanning.maximumTimestamp(now: now)
        let databaseDiagnosticKey = "devin.sessions.read"
        do {
            let entries = try sessionUsageReader.entries(at: sessionDatabase)
            guard !Task.isCancelled else { return nil }
            if !entries.isEmpty {
                guard !entries.contains(where: { $0.timestamp > maximumSessionTimestamp }) else {
                    throw SQLiteError.queryFailed("Devin session usage contained a future timestamp")
                }
                DiagnosticGate.clearFailure(databaseDiagnosticKey)
                let result = Self.aggregate(entries: entries, since: since, pricing: pricing)
                return Task.isCancelled ? nil : result
            }
            DiagnosticGate.clearFailure(databaseDiagnosticKey)
        } catch {
            guard !Task.isCancelled else { return nil }
            DiagnosticGate.logOnce(for: databaseDiagnosticKey) {
                AppLog.warn(LogTag.plugin("devin"), "session database usage could not be read; preserving last-good history")
            }
            return nil
        }
        guard let files = Self.jsonFilesIfComplete(under: directory) else {
            DiagnosticGate.logOnce(for: Self.enumerationDiagnosticKey) {
                AppLog.warn(LogTag.plugin("devin"), "transcript files could not be completely enumerated; preserving last-good history")
            }
            return nil
        }
        DiagnosticGate.clearFailure(Self.enumerationDiagnosticKey)

        let futureIdentity = "devin.transcripts.\(identity)"
        guard !files.isEmpty else {
            FutureTimestampRevisionGate.retain(identity: futureIdentity, paths: [])
            _ = await scanner.items(from: [], since: since, cacheIdentity: identity, parse: Self.parseFile)
            DiagnosticGate.clearFailure(Self.futureTimestampDiagnosticKey)
            return nil
        }

        let maximumTimestamp = JSONLScanning.maximumTimestamp(now: now)
        FutureTimestampRevisionGate.retain(identity: futureIdentity, paths: Set(files.map(\.path)))
        for file in files where FutureTimestampRevisionGate.shouldDefer(
            identity: futureIdentity, file: file, maximumTimestamp: maximumTimestamp
        ) {
            Self.logFutureTimestamp()
            return nil
        }
        let bucket = FutureTimestampFoldBucket<Entry>()
        let complete = await scanner.foldItems(
            from: files,
            since: since,
            cacheIdentity: identity,
            parseFile: Self.parseFile(at:),
            visit: { entry in
                guard entry.tokens.totalTokens > 0 else { return }
                bucket.append(entry, timestamp: entry.timestamp, maximumTimestamp: maximumTimestamp)
            },
            fileStarted: { bucket.begin($0) },
            fileCompleted: { path, _ in bucket.finish(path) }
        )
        guard complete, !Task.isCancelled else { return nil }
        for (path, timestamp) in bucket.futureTimestamps {
            guard let file = files.first(where: { $0.path == path }),
                  FutureTimestampRevisionGate.record(timestamp, identity: futureIdentity, file: file)
            else { return nil }
        }
        guard bucket.futureTimestamps.isEmpty else {
            Self.logFutureTimestamp()
            return nil
        }
        DiagnosticGate.clearFailure(Self.futureTimestampDiagnosticKey)
        let result = Self.aggregate(entries: bucket.items, since: since, pricing: pricing)
        guard !Task.isCancelled else { return nil }
        return result
    }

    private static func logFutureTimestamp() {
        DiagnosticGate.logOnce(for: futureTimestampDiagnosticKey) {
            AppLog.warn(LogTag.plugin("devin"), "transcript usage contains a timestamp more than five minutes ahead; preserving last-good history")
        }
    }

    /// Every `*.json` regular file directly under `dir`, path-sorted — the `.json` sibling of
    /// `JSONLScanning.jsonlFilesIfComplete` (transcripts are whole JSON documents, not line files).
    /// A missing directory is a complete empty result; an unreadable one returns nil so the caller
    /// preserves last-good history instead of publishing a partial fold.
    static func jsonFilesIfComplete(under dir: URL) -> [JSONLScanning.DiscoveredFile]? {
        guard !Task.isCancelled else { return nil }
        return JSONLAccountingWorkPacer.shared.perform {
            let dir = dir.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory) else { return [] }
            guard isDirectory.boolValue, FileManager.default.isReadableFile(atPath: dir.path) else { return nil }
            let keySet: Set<URLResourceKey> = [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .attributeModificationDateKey,
            ]
            var enumerationFailed = false
            guard let enumerator = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: Array(keySet),
                options: [],
                errorHandler: { _, _ in
                    enumerationFailed = true
                    return false
                }
            ) else { return nil }
            var files: [JSONLScanning.DiscoveredFile] = []
            for case let url as URL in enumerator {
                guard !Task.isCancelled else { return nil }
                guard url.pathExtension == "json" else { continue }
                guard let values = try? url.resourceValues(forKeys: keySet) else { return nil }
                guard values.isRegularFile == true else { continue }
                files.append(JSONLScanning.DiscoveredFile(
                    path: url.path,
                    size: values.fileSize ?? 0,
                    mtime: values.contentModificationDate ?? .distantPast,
                    attributeMtime: values.attributeModificationDate
                ))
            }
            guard !enumerationFailed else { return nil }
            return files.sorted { $0.path < $1.path }
        }
    }

    // MARK: - Transcript parsing

    /// Parse one ATIF transcript into metered entries. Returns nil for an unreadable file, a
    /// non-ATIF document, or a step whose token/timestamp fields are malformed — a mid-rewrite or
    /// damaged export must fail the fold (→ keep last-good) rather than silently drop its usage.
    nonisolated static func parseFile(at url: URL) -> [Entry]? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let steps = root["steps"] as? [[String: Any]]
        else { return nil }

        // The step's own model wins; the export-level agent name covers steps that omit it.
        let sessionModel = sessionModelName(root)
        var entries: [Entry] = []
        entries.reserveCapacity(steps.count)
        for step in steps {
            switch stepMetrics(step) {
            case .damaged: return nil
            case .unmetered: continue
            case .counts(let counts):
                guard let timestamp = stepTimestamp(step) else { return nil }
                entries.append(makeEntry(step: step, counts: counts, timestamp: timestamp, sessionModel: sessionModel))
            }
        }
        return entries
    }

    /// Whole-document parse for the `items` path (empty-scan cache warmup). Damaged steps are
    /// skipped here — this path only primes the cache while discovery found nothing.
    static func parseFile(_ data: Data) -> [Entry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let steps = root["steps"] as? [[String: Any]]
        else { return [] }
        let sessionModel = sessionModelName(root)
        var entries: [Entry] = []
        for step in steps {
            guard case .counts(let counts) = stepMetrics(step),
                  let timestamp = stepTimestamp(step)
            else { continue }
            entries.append(makeEntry(step: step, counts: counts, timestamp: timestamp, sessionModel: sessionModel))
        }
        return entries
    }

    private struct StepCounts: Equatable {
        var prompt: Int
        var completion: Int
        var cached: Int
    }

    private enum StepMetrics: Equatable {
        /// No `metrics` object or no token keys at all — user input, system, tool output.
        case unmetered
        /// Token fields are present but cannot be real counts — the file is damaged.
        case damaged
        case counts(StepCounts)
    }

    /// A present token key must hold a valid count; an absent one reads as zero so an older export
    /// without `cached_tokens` still folds instead of reporting the file damaged.
    private static func stepMetrics(_ step: [String: Any]) -> StepMetrics {
        guard let metrics = step["metrics"] as? [String: Any] else { return .unmetered }
        var sawTokenKey = false
        var counts = StepCounts(prompt: 0, completion: 0, cached: 0)
        for key in ["prompt_tokens", "completion_tokens", "cached_tokens"] {
            guard let raw = metrics[key], !(raw is NSNull) else { continue }
            sawTokenKey = true
            guard let count = strictCount(raw) else { return .damaged }
            switch key {
            case "prompt_tokens": counts.prompt = count
            case "completion_tokens": counts.completion = count
            default: counts.cached = count
            }
        }
        guard sawTokenKey else { return .unmetered }
        // `cached_tokens` is a subset of `prompt_tokens`; a transcript that reports more cache
        // than prompt is damaged rather than merely odd.
        guard counts.cached <= counts.prompt else { return .damaged }
        return .counts(counts)
    }

    private static func makeEntry(
        step: [String: Any],
        counts: StepCounts,
        timestamp: Date,
        sessionModel: String
    ) -> Entry {
        let model = ((step["model_name"] as? String) ?? sessionModel)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Entry(
            timestamp: timestamp,
            model: model.isEmpty ? ModelUsageEntry.unattributedModelName : model,
            tokens: TokenBreakdown(
                input: counts.prompt - counts.cached,
                cacheRead: counts.cached,
                output: counts.completion
            )
        )
    }

    private static func sessionModelName(_ root: [String: Any]) -> String {
        (((root["agent"] as? [String: Any])?["model_name"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stepTimestamp(_ step: [String: Any]) -> Date? {
        guard let raw = step["timestamp"] as? String else { return nil }
        return OpenUsageISO8601.date(from: raw)
    }

    /// A non-negative integer token count; nil when the value can't be a real count — fractions,
    /// negatives, booleans, absurd magnitudes — which the caller treats as malformed, not zero.
    private static func strictCount(_ raw: Any?) -> Int? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let value = number.doubleValue
        guard value.isFinite,
              value >= 0,
              value <= 1e15,
              value.rounded(.towardZero) == value
        else { return nil }
        return Int(value)
    }

    // MARK: - Aggregation

    static func aggregate(entries: [Entry], since: Date, pricing: ModelPricing) -> LogUsageScan {
        var accumulator = DailyUsageAccumulator()
        JSONLAccountingWorkPacer.shared.forEach(entries) { entry in
            guard entry.timestamp >= since else { return }
            let day = DailyUsageAccumulator.dayKey(from: entry.timestamp)
            // A step can bundle more than one model call, so its prompt total is not a single
            // request's context size — per-request long-context tiers must not apply to the sum.
            let estimate = pricing.estimatedCostDollars(
                model: entry.model,
                tokens: entry.tokens,
                applyLongContextRates: false
            )
            accumulator.recordApiEstimate(
                day: day,
                cost: estimate,
                tokens: entry.tokens.totalTokens
            )
            if estimate == nil, entry.tokens.totalTokens > 0 {
                if entry.model == ModelUsageEntry.unattributedModelName {
                    // Usage with no model identity at all: genuinely unknown, worth the warning.
                    accumulator.addUnknownModel(day: day, model: entry.model)
                } else {
                    // Devin-native models (swe-*) are named but have no public per-token rate — an
                    // explained gap, so tokens count without a permanent warning triangle.
                    accumulator.addNamedUnpricedModel(day: day, model: entry.model)
                }
            }
            let canonical = pricing.canonicalName(for: entry.model)
                ?? PricingCatalog.normalizedKey(entry.model).lowercased()
            accumulator.add(
                day: day,
                tokens: entry.tokens.totalTokens,
                cost: estimate,
                model: entry.model,
                canonical: canonical,
                costIsComplete: estimate != nil
            )
            if estimate != nil {
                accumulator.markEstimatedCost(day: day)
            }
        }
        return accumulator.build()
    }
}
