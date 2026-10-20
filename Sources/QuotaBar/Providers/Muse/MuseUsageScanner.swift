import Foundation
import CoreFoundation

/// Reads Muse session logs (`~/.local/share/muse/sessions/**/*.jsonl`) and folds
/// Muse's OpenCode Go-billed usage into the OpenCode provider's tiles + trend.
///
/// Muse, when launched via `muse-go`, routes Meta Muse Spark through
/// `https://opencode.ai/zen/go/v1` — the same hosted Go account as `opencode-go`.
/// That bridge bypasses `opencode.db`, so without a fold Muse spend is invisible.
/// Muse's runtime emits `goal_usage_attribution` with per-step token counts;
/// this scanner sums the `reported:true` rows (the provider-billed ones) and
/// attributes them to the session's model (`muse-spark-1.*` → Go).
///
/// Analogous to `ClaudeLogUsageScanner.parsedEntries` / `CodexLogUsageScanner.parsedEvents`:
/// the caller passes `roots` so tests stay hermetic, and the persistent
/// `IncrementalJSONLScanner` cache is shared — unchanged session files aren't
/// re-parsed on every 5-minute refresh.
actor MuseUsageScanner {
    private static let futureTimestampDiagnosticKey = "muse.sessions.future-timestamp"
    private let homeDirectory: @Sendable () -> URL
    private let scanner: IncrementalJSONLScanner<Entry>

    struct Entry: Codable, Sendable, Equatable {
        var timestamp: Date
        var tokens: TokenBreakdown
        var model: String?
    }

    private static let sharedScanner = IncrementalJSONLScanner<Entry>(
        retainResidentItems: false,
        logTag: LogTag.plugin("muse"),
        persistence: JSONLScanCachePersistence(namespace: "muse", schemaVersion: 4)
    )

    static func flushPersistentCacheWrites() async {
        await sharedScanner.flushPendingWrites()
    }

    init(
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        incrementalScanner: IncrementalJSONLScanner<Entry>? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.scanner = incrementalScanner ?? Self.sharedScanner
    }

    /// Default Muse sessions root on this machine.
    static func defaultSessionsRoot(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        MusePaths.sessionsDirectory(homeDirectory: homeDirectory)
    }

    /// Raw usage entries from the last `daysBack` days — the same incremental scan the
    /// OpenCode fold calls, but returning Entry items so both consumers share one cache.
    func parsedEntries(daysBack: Int = 33, now: Date = Date(), roots: [URL]) async -> [Entry] {
        await parsedEntriesIfComplete(daysBack: daysBack, now: now, roots: roots) ?? []
    }

    /// `nil` means a configured Muse source was unreadable or the incremental parse was incomplete;
    /// an empty array is a successful scan with no usage entries.
    func parsedEntriesIfComplete(daysBack: Int = 33, now: Date = Date(), roots: [URL]) async -> [Entry]? {
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let maximumTimestamp = JSONLScanning.maximumTimestamp(now: now)
        let identityPaths = Set(roots.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
            .sorted()
        let cacheIdentity = identityPaths.isEmpty ? "no-muse-root" : identityPaths.joined(separator: "\n")
        guard let files = Self.usageFilesIfComplete(under: roots) else { return nil }
        let futureIdentity = "muse.sessions.\(cacheIdentity)"
        guard !files.isEmpty else {
            FutureTimestampRevisionGate.retain(identity: futureIdentity, paths: [])
            _ = await scanner.items(
                from: [], since: since, cacheIdentity: cacheIdentity, parseFile: Self.parseFile(at:)
            )
            DiagnosticGate.clearFailure(Self.futureTimestampDiagnosticKey)
            return Task.isCancelled ? nil : []
        }
        FutureTimestampRevisionGate.retain(identity: futureIdentity, paths: Set(files.map(\.path)))
        for file in files where FutureTimestampRevisionGate.shouldDefer(
            identity: futureIdentity, file: file, maximumTimestamp: maximumTimestamp
        ) {
            Self.logFutureTimestamp()
            return nil
        }
        let bucket = FutureTimestampFoldBucket<Entry>()
        let complete = await scanner.foldItems(
            from: files, since: since, cacheIdentity: cacheIdentity, parseFile: Self.parseFile(at:),
            visit: { entry in
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
        return bucket.items
    }

    /// Every `session.jsonl` under each root, path-sorted. Only session files
    /// carry `goal_usage_attribution` — the `approval-review/` and `process-owners/`
    /// trees hold unrelated review logs. Restricting to `session.jsonl` cuts the
    /// parse set from ~1755 to ~700 files without missing any billed usage
    /// (subagent sessions also use `session.jsonl` inside `subagent/<id>/`).
    static func usageFiles(under roots: [URL]) -> [JSONLScanning.DiscoveredFile] {
        usageFilesIfComplete(under: roots) ?? []
    }

    static func usageFilesIfComplete(under roots: [URL]) -> [JSONLScanning.DiscoveredFile]? {
        var files: [JSONLScanning.DiscoveredFile] = []
        for root in roots {
            guard !Task.isCancelled,
                  let rootFiles = JSONLScanning.jsonlFilesIfComplete(under: root)
            else { return nil }
            files.append(contentsOf: rootFiles)
        }
        return files
            .filter { $0.path.hasSuffix("/session.jsonl") }
            .sorted { $0.path < $1.path }
    }

    /// Streaming parser — a large session file never becomes one giant Data allocation.
    nonisolated static func parseFile(at url: URL) -> [Entry]? {
        var entries: [Entry] = []
        var malformed = false
        let readSucceeded = JSONLFileReader.forEachLine(at: url) { line in
            switch parseLineResult(line) {
            case .entry(let entry): entries.append(entry)
            case .irrelevant: break
            case .malformed: malformed = true
            }
        }
        guard readSucceeded, !malformed else { return nil }
        return entries
    }

    static func parseFile(_ data: Data) -> [Entry] {
        var entries: [Entry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if case .entry(let entry) = parseLineResult(line) { entries.append(entry) }
        }
        return entries
    }

    // Fast pre-filter: only lines mentioning the attribution kind carry usage.
    private static let marker = Data("\"goal_usage_attribution\"".utf8)

    private enum LineResult {
        case entry(Entry)
        case irrelevant
        case malformed
    }

    private static func parseLineResult(_ line: Data.SubSequence) -> LineResult {
        guard line.range(of: marker) != nil else { return .irrelevant }
        let lineData = Data(line)
        guard let object = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else {
            return .malformed
        }
        // The marker can appear inside quoted user text. Only a decoded event with the actual
        // attribution kind is a candidate; other valid session events are irrelevant to usage.
        guard let payload = object["payload"] as? [String: Any],
              let event = payload["event"] as? [String: Any],
              let rawKind = event["kind"]
        else { return .irrelevant }
        guard let kind = rawKind as? String else { return .irrelevant }
        guard kind == "goal_usage_attribution" else { return .irrelevant }

        guard let record = event["record"] as? [String: Any],
              let quantity = record["quantity"] as? [String: Any],
              let reported = strictBoolean(quantity["reported"]),
              let unit = quantity["unit"] as? String
        else { return .malformed }
        guard reported, unit == "tokens" else { return .irrelevant }

        guard let input = tokenCount(quantity["input_tokens"], required: true),
              let output = tokenCount(quantity["output_tokens"], required: true),
              let cached = tokenCount(quantity["cached_tokens"], required: false),
              let reasoning = tokenCount(quantity["reasoning_tokens"], required: false),
              cached <= input
        else { return .malformed }
        // Muse attribution is per-step, not incremental — each line already is one billed turn.
        // Input is total; cached is the prefix-hit portion inside it.
        let uncachedInput = input - cached

        // Timestamp is the durable `recorded_at` (microseconds since epoch).
        // Every real Muse session carries it; a missing or malformed value makes this file incomplete.
        guard let micros = exactInteger(object["recorded_at"], maximum: 9e15), micros > 0 else {
            return .malformed
        }
        let timestamp = Date(timeIntervalSince1970: Double(micros) / 1_000_000)

        for key in ["model"] {
            if let value = record[key], !(value is String) { return .malformed }
            if let value = quantity[key], !(value is String) { return .malformed }
        }

        // Model: from the run's metadata in the same file would be ideal, but Muse's
        // attribution line doesn't carry it. The sessions root's metadata file holds
        // provider/model, but per-line we assume the bridged Muse model (muse-spark)
        // when the session's harness IS opencode-go. Callers map this to Go billing;
        // a non-Go Muse session (direct Meta, not via bridge) still folds under Go
        // when the model is muse-spark — the quota is the same upstream.
        let model = (record["model"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? (quantity["model"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
            ?? "muse-spark-1.2-contributor"

        // Zero-token attributions are bookkeeping placeholders (reported:false filtered above,
        // but reported:true can still be 0-0 on some control steps) — skip them.
        let total = ProviderParse.addingSaturating(
            ProviderParse.addingSaturating(input, output),
            reasoning
        )
        guard total > 0 else { return .irrelevant }

        return .entry(Entry(
            timestamp: timestamp,
            tokens: TokenBreakdown(
                input: uncachedInput,
                cacheWrite5m: 0,
                cacheRead: cached,
                output: ProviderParse.addingSaturating(output, reasoning)
            ),
            model: model
        ))
    }

    private static func logFutureTimestamp() {
        DiagnosticGate.logOnce(for: futureTimestampDiagnosticKey) {
            AppLog.warn(LogTag.plugin("muse"), "session usage contains a timestamp more than five minutes ahead; preserving last-good history")
        }
    }

    private static func strictBoolean(_ raw: Any?) -> Bool? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }

    private static func tokenCount(_ raw: Any?, required: Bool) -> Int? {
        guard let raw else { return required ? nil : 0 }
        return exactInteger(raw, maximum: 1e15)
    }

    private static func exactInteger(_ raw: Any?, maximum: Double) -> Int? {
        guard let raw else { return nil }
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let value = number.doubleValue
        guard value.isFinite,
              value >= 0,
              value <= maximum,
              value.rounded(.towardZero) == value
        else { return nil }
        return Int(value)
    }
}
