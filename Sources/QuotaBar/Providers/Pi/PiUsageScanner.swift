import Foundation
import CoreFoundation

/// A missing Pi source is a complete empty result, but a failed directory walk is not. Callers that
/// merge Pi with another history source must keep the prior combined history on `.incomplete`.
enum PiUsageScanResult: Sendable {
    case complete(LogUsageScan?)
    case incomplete
}

/// Builds a per-day token/cost series from pi's session logs for one QuotaBar card, so usage that
/// happened inside pi (e.g. a Claude sub driven through pi) folds into that card's Usage Trend and
/// spend tiles alongside its native source.
///
/// Pi records an authoritative per-message `usage.cost.total` (like OpenCode), so that carried cost is
/// used when present; when pi logs a `$0` cost (subscription usage it doesn't impute), the tokens are
/// priced through the shared engine instead — the same `carried cost, else price` rule the Claude and
/// Codex log scanners use. Pi's usage shape differs from Claude Code's (`usage.input`/`output`,
/// nested `usage.cost.total`), so it has its own parser rather than routing through those scanners.
///
/// An actor holding the versioned incremental parse cache (keyed path + size + content mtime + attribute
/// mtime) in memory and
/// Application Support, so refreshes and relaunches parse only changed session files. A single shared
/// instance is used by every consuming provider, so pi's logs are parsed once rather than once per card.
actor PiUsageScanner {
    static let shared = PiUsageScanner()

    private let environment: EnvironmentReading
    private let homeDirectory: @Sendable () -> URL
    private let scanner: IncrementalJSONLScanner<Entry>

    private static let sharedScanner = IncrementalJSONLScanner<Entry>(
        retainResidentItems: false,
        logTag: LogTag.plugin("pi"),
        persistence: JSONLScanCachePersistence(namespace: "pi", schemaVersion: 3)
    )

    static func flushPersistentCacheWrites() async {
        await sharedScanner.flushPendingWrites()
    }

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        incrementalScanner: IncrementalJSONLScanner<Entry>? = nil
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.scanner = incrementalScanner ?? Self.sharedScanner
    }

    /// One parsed assistant-message usage line. Raw timestamp is kept so a cached parse stays valid as
    /// the window slides; `cardID` is resolved at parse time so aggregation is a cheap filter.
    struct Entry: Codable, Sendable, Equatable {
        var id: String?
        var timestamp: Date
        var cardID: String
        var model: String
        /// pi's own `usage.cost.total`, used directly when > 0; nil/0 falls through to engine pricing.
        var carriedCost: Double?
        /// The token buckets, for pricing the fall-through case.
        var tokens: TokenBreakdown
        /// pi's reported `usage.totalTokens`, shown as the row's token count (matches pi's own footer).
        var reportedTotalTokens: Int
    }

    /// Scan the last `daysBack` days of pi logs for one card. Returns nil when pi's sessions directory
    /// has no log files at all, so a provider with no pi usage folds in nothing.
    func scan(cardID: String, daysBack: Int = UsageHistoryWindow.previousDays, now: Date = Date(), pricing: ModelPricing) async -> LogUsageScan? {
        switch await scanResult(cardID: cardID, daysBack: daysBack, now: now, pricing: pricing) {
        case .complete(let scan):
            return scan
        case .incomplete:
            return nil
        }
    }

    /// Completeness-aware scan used by providers that merge Pi with another source. Returning an
    /// optional `LogUsageScan` alone cannot distinguish an empty Pi directory from a failed walk.
    func scanResult(
        cardID: String,
        daysBack: Int = UsageHistoryWindow.previousDays,
        now: Date = Date(),
        pricing: ModelPricing
    ) async -> PiUsageScanResult {
        let directory = PiPaths.sessionsDirectory(environment: environment, homeDirectory: homeDirectory())
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let cacheIdentity = directory.resolvingSymlinksInPath().path
        let futureIdentity = "pi.sessions.\(cacheIdentity).card.\(cardID)"
        let discoveryFailureKey = Self.discoveryFailureKey(for: cacheIdentity)
        guard let files = JSONLScanning.jsonlFilesIfComplete(under: directory) else {
            DiagnosticGate.logOnce(for: discoveryFailureKey) {
                AppLog.warn(LogTag.plugin("pi"), "session directory could not be completely enumerated; combined usage history is incomplete")
            }
            return .incomplete
        }
        DiagnosticGate.clearFailure(discoveryFailureKey)
        let futureDiagnosticKey = Self.futureTimestampDiagnosticKey(for: futureIdentity)
        guard !files.isEmpty else {
            FutureTimestampRevisionGate.retain(identity: futureIdentity, paths: [])
            _ = await scanner.items(
                from: [], since: since, cacheIdentity: cacheIdentity, parseFile: { url in Self.parseFile(at: url) }
            )
            DiagnosticGate.clearFailure(futureDiagnosticKey)
            return .complete(nil)
        }

        let maximumTimestamp = JSONLScanning.maximumTimestamp(now: now)
        FutureTimestampRevisionGate.retain(identity: futureIdentity, paths: Set(files.map(\.path)))
        for file in files where FutureTimestampRevisionGate.shouldDefer(
            identity: futureIdentity, file: file, maximumTimestamp: maximumTimestamp
        ) {
            Self.logFutureTimestamp(identity: futureIdentity)
            return .incomplete
        }
        let bucket = FutureTimestampFoldBucket<Entry>()
        let complete = await scanner.foldItems(
            from: files,
            since: since,
            cacheIdentity: cacheIdentity,
            parseFile: { url in Self.parseFile(at: url) },
            visit: { entry in
                guard entry.cardID == cardID else { return }
                guard entry.reportedTotalTokens > 0 || (entry.carriedCost ?? 0) > 0 else { return }
                bucket.append(entry, timestamp: entry.timestamp, maximumTimestamp: maximumTimestamp)
            },
            fileStarted: { bucket.begin($0) },
            fileCompleted: { path, _ in bucket.finish(path) }
        )
        guard complete, !Task.isCancelled else { return .incomplete }
        for (path, timestamp) in bucket.futureTimestamps {
            guard let file = files.first(where: { $0.path == path }),
                  FutureTimestampRevisionGate.record(timestamp, identity: futureIdentity, file: file)
            else { return .incomplete }
        }
        guard bucket.futureTimestamps.isEmpty else {
            Self.logFutureTimestamp(identity: futureIdentity)
            return .incomplete
        }
        DiagnosticGate.clearFailure(futureDiagnosticKey)
        let deduped = Self.dedup(bucket.items)
        guard !Task.isCancelled else { return .incomplete }
        let result = Self.aggregate(entries: deduped, cardID: cardID, since: since, pricing: pricing)
        guard !Task.isCancelled else { return .incomplete }
        return .complete(result)
    }

    private static func discoveryFailureKey(for identity: String) -> String {
        "pi.sessions.discovery.\(JSONLScanCachePaths.stableFingerprint(identity))"
    }

    private static func futureTimestampDiagnosticKey(for identity: String) -> String {
        "pi.sessions.future-timestamp.\(JSONLScanCachePaths.stableFingerprint(identity))"
    }

    private static func logFutureTimestamp(identity: String) {
        DiagnosticGate.logOnce(for: futureTimestampDiagnosticKey(for: identity)) {
            AppLog.warn(LogTag.plugin("pi"), "session usage contains a timestamp more than five minutes ahead; preserving last-good history")
        }
    }

    // MARK: - Parsing

    /// Parse every mapped assistant usage line of one session file. Lines for pi providers QuotaBar
    /// doesn't track are dropped here so they never reach aggregation.
    static func parseFile(_ data: Data) -> [Entry] {
        var entries: [Entry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if case .entry(let entry) = parseLineResult(Data(line)) { entries.append(entry) }
        }
        return entries
    }

    /// Streaming counterpart used by the incremental scanner so a large session file never becomes
    /// one giant Data allocation.
    nonisolated static func parseFile(at url: URL) -> [Entry]? {
        var entries: [Entry] = []
        var malformed = false
        let readSucceeded = JSONLFileReader.forEachLine(at: url) { line in
            switch parseLineResult(Data(line)) {
            case .entry(let entry): entries.append(entry)
            case .irrelevant: break
            case .malformed: malformed = true
            }
        }
        guard readSucceeded, !malformed else { return nil }
        return entries
    }

    private static let usageMarker = Data(#""usage":{"#.utf8)

    private enum LineResult {
        case entry(Entry)
        case irrelevant
        case malformed
    }

    static func parseLine(_ data: Data) -> Entry? {
        guard case .entry(let entry) = parseLineResult(data) else { return nil }
        return entry
    }

    private static func parseLineResult(_ data: Data) -> LineResult {
        guard data.range(of: usageMarker) != nil else { return .irrelevant }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .malformed
        }
        guard object["type"] as? String == "message" else { return .irrelevant }
        guard let message = object["message"] as? [String: Any] else { return .malformed }
        guard message["role"] as? String == "assistant" else { return .irrelevant }
        guard let providerID = message["provider"] as? String else { return .malformed }
        guard let cardID = PiProviderMapping.cardID(forPiProvider: providerID) else { return .irrelevant }
        guard let timestampRaw = object["timestamp"] as? String,
              let timestamp = OpenUsageISO8601.date(from: timestampRaw),
              let usage = message["usage"] as? [String: Any]
        else { return .malformed }

        let id: String?
        if let rawID = object["id"] {
            guard let text = rawID as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return .malformed }
            id = text
        } else {
            id = nil
        }

        guard let input = strictCount(usage["input"], required: true),
              let output = strictCount(usage["output"], required: true),
              let cacheRead = strictCount(usage["cacheRead"], required: false),
              let cacheWrite = strictCount(usage["cacheWrite"], required: false),
              let cacheWrite1h = strictCount(usage["cacheWrite1h"], required: false),
              let reportedTotal = strictCount(usage["totalTokens"], required: true),
              cacheWrite1h <= cacheWrite
        else { return .malformed }

        let tokens = TokenBreakdown(
            input: input,
            cacheWrite5m: cacheWrite - cacheWrite1h,
            cacheWrite1h: cacheWrite1h,
            cacheRead: cacheRead,
            output: output
        )
        guard tokens.totalTokens == reportedTotal else { return .malformed }

        let carriedCost: Double?
        if let rawCost = usage["cost"], !(rawCost is NSNull) {
            guard let cost = rawCost as? [String: Any] else { return .malformed }
            if let rawTotal = cost["total"], !(rawTotal is NSNull) {
                guard let number = rawTotal as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID()
                else { return .malformed }
                let value = number.doubleValue
                guard value.isFinite, value >= 0, value <= 1e12 else { return .malformed }
                carriedCost = value
            } else {
                carriedCost = nil
            }
        } else {
            carriedCost = nil
        }

        if let rawModel = message["model"], !(rawModel is String) { return .malformed }
        return .entry(Entry(
            id: id,
            timestamp: timestamp,
            cardID: cardID,
            model: (message["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            carriedCost: carriedCost,
            tokens: tokens,
            reportedTotalTokens: reportedTotal
        ))
    }

    private static func strictCount(_ raw: Any?, required: Bool) -> Int? {
        guard let raw else { return required ? nil : 0 }
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

    // MARK: - Dedup and aggregation

    /// Drop replayed lines that a forked/cloned session can duplicate under the same message id, keeping
    /// the first occurrence. Lines without an id are always kept.
    static func dedup(_ entries: [Entry]) -> [Entry] {
        var seen: Set<String> = []
        var out: [Entry] = []
        out.reserveCapacity(entries.count)
        JSONLAccountingWorkPacer.shared.forEach(entries) { entry in
            if let id = entry.id, !seen.insert(id).inserted { return }
            out.append(entry)
        }
        return out
    }

    /// Bucket the card's entries into local calendar days. Cost is pi's carried total when it recorded
    /// one, else the tokens priced through `pricing`; a row that can't be priced counts its tokens with
    /// a dashed cost and surfaces as the tile's unknown-model warning, matching the log scanners.
    static func aggregate(entries: [Entry], cardID: String, since: Date, pricing: ModelPricing) -> LogUsageScan {
        var accumulator = DailyUsageAccumulator()
        JSONLAccountingWorkPacer.shared.forEach(entries) { entry in
            guard entry.cardID == cardID, entry.timestamp >= since else { return }
            let day = DailyUsageAccumulator.dayKey(from: entry.timestamp)
            let trimmedModel = entry.model.nilIfEmpty
            let modelName = trimmedModel ?? ModelUsageEntry.unattributedModelName

            let cost: Double?
            if let carried = entry.carriedCost, carried > 0 {
                cost = carried
            } else if let model = trimmedModel, let estimated = pricing.estimatedCostDollars(model: model, tokens: entry.tokens) {
                cost = estimated
            } else {
                cost = nil
            }
            if cost == nil, entry.reportedTotalTokens > 0 {
                accumulator.addUnknownModel(day: day, model: modelName)
            }
            accumulator.recordApiEstimate(
                day: day,
                cost: trimmedModel.flatMap { pricing.estimatedCostDollars(model: $0, tokens: entry.tokens) },
                tokens: entry.reportedTotalTokens
            )
            accumulator.add(day: day, tokens: entry.reportedTotalTokens, cost: cost, model: modelName)
        }
        return accumulator.build()
    }
}
