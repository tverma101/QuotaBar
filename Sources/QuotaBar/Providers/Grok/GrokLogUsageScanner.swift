import Foundation
import CoreFoundation
import Darwin

/// Builds Grok's daily usage from completed turns in the CLI's durable session transcripts.
/// `logs/unified.jsonl` is a capped debug log, so it cannot back historical spend or reliable model
/// attribution. Session `updates.jsonl` files carry both per-model token counts and Grok's own costs.
actor GrokLogUsageScanner {
    private static let futureTimestampDiagnosticKey = "grok.sessions.future-timestamp"
    private let environment: EnvironmentReading
    private let homeDirectory: @Sendable () -> URL
    private let scanner: IncrementalJSONLScanner<Entry>

    /// One model's contribution to a completed turn. Event identifiers let copied session transcripts
    /// deduplicate the same notification without collapsing multiple models within that notification.
    struct Entry: Codable, Sendable, Equatable {
        var eventID: String?
        var timestamp: Date
        var model: String
        var tokens: TokenBreakdown
        var carriedCost: Double?
    }

    /// The revision of a session's `summary.json`: its size and modification time.
    private struct SummaryRevision: Equatable {
        var path: String
        var size: UInt64
        var modifiedNanos: Int64

        init(path: String, metadata: stat) {
            self.path = path
            self.size = UInt64(metadata.st_size)
            self.modifiedNanos = Int64(metadata.st_mtimespec.tv_sec) * 1_000_000_000
                + Int64(metadata.st_mtimespec.tv_nsec)
        }
    }

    private struct SummaryClassification {
        var revision: SummaryRevision
        var isCoordinator: Bool
    }

    /// How many session summaries stay classified in memory. A session folder that disappears leaves
    /// its entry behind, and sessions only accumulate, so the cache is capped.
    private static let maximumCachedSummaries = 4096

    private var summaryClassifications: [String: SummaryClassification] = [:]

    private static let sharedScanner = IncrementalJSONLScanner<Entry>(
        retainResidentItems: false,
        logTag: LogTag.plugin("grok"),
        persistence: JSONLScanCachePersistence(namespace: "grok", schemaVersion: 2)
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

    /// Scan completed turns under `$GROK_HOME/sessions`, or `~/.grok/sessions` by default.
    /// Missing transcripts leave the spend tiles unbacked instead of falling back to the debug log.
    func scan(daysBack: Int = UsageHistoryWindow.previousDays, now: Date = Date(), pricing: ModelPricing) async -> LogUsageScan? {
        let directory = grokHome().appendingPathComponent("sessions", isDirectory: true)
        let identity = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        guard let discoveredFiles = JSONLScanning.jsonlFilesIfComplete(under: directory) else {
            DiagnosticGate.logOnce(for: "grok.sessions.enumeration") {
                AppLog.warn(LogTag.plugin("grok"), "session files could not be completely enumerated; preserving last-good history")
            }
            return nil
        }
        DiagnosticGate.clearFailure("grok.sessions.enumeration")
        var files: [JSONLScanning.DiscoveredFile] = []
        for file in discoveredFiles where URL(fileURLWithPath: file.path).lastPathComponent == "updates.jsonl" {
            guard let isCoordinator = isCoordinatorSession(file) else { return nil }
            if isCoordinator { files.append(file) }
        }

        let futureIdentity = "grok.sessions.\(identity)"
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
                guard entry.tokens.totalTokens > 0 || (entry.carriedCost ?? 0) > 0 else { return }
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
        let deduped = Self.dedup(bucket.items)
        guard !Task.isCancelled else { return nil }
        let result = Self.aggregate(entries: deduped, since: since, pricing: pricing)
        guard !Task.isCancelled else { return nil }
        return result
    }

    private static func logFutureTimestamp() {
        DiagnosticGate.logOnce(for: futureTimestampDiagnosticKey) {
            AppLog.warn(LogTag.plugin("grok"), "session usage contains a timestamp more than five minutes ahead; preserving last-good history")
        }
    }

    private func grokHome() -> URL {
        if let raw = environment.value(for: "GROK_HOME")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return URL(fileURLWithPath: expandHome(raw))
        }
        return homeDirectory().appendingPathComponent(".grok", isDirectory: true)
    }

    /// Coordinator turns already include their subagents, so reading both ledgers would charge every
    /// child task twice. Older sessions without a summary remain eligible because their kind is unknown.
    ///
    /// The summary of a finished session never changes, so its classification is cached against the
    /// file's revision. Without the cache every fold re-opened and re-parsed one `summary.json` per
    /// session — hundreds of file reads per fold for a boolean that was already known.
    private func isCoordinatorSession(_ file: JSONLScanning.DiscoveredFile) -> Bool? {
        let fileURL = URL(fileURLWithPath: file.path)
        let summaryURL = fileURL.deletingLastPathComponent().appendingPathComponent("summary.json")
        var metadata = stat()
        guard Darwin.lstat(summaryURL.path, &metadata) == 0 else {
            if errno == ENOENT {
                DiagnosticGate.clearFailure(Self.summaryDiagnosticKey(for: file.path))
                return true
            }
            Self.logSummaryFailure(file: file.path, message: "Could not inspect Grok session summary")
            return nil
        }

        let revision = SummaryRevision(path: summaryURL.path, metadata: metadata)
        if let cached = summaryClassifications[summaryURL.path], cached.revision == revision {
            return cached.isCoordinator
        }

        do {
            guard FileManager.default.isReadableFile(atPath: summaryURL.path) else {
                Self.logSummaryFailure(file: file.path, message: "Could not read Grok session summary")
                return nil
            }
            let data = try Data(contentsOf: summaryURL)
            guard let summary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                Self.logSummaryFailure(file: file.path, message: "Grok session summary is not a JSON object")
                return nil
            }
            if let rawKind = summary["session_kind"] {
                guard let kind = rawKind as? String else {
                    Self.logSummaryFailure(file: file.path, message: "Grok session summary has an invalid session kind")
                    return nil
                }
                DiagnosticGate.clearFailure(Self.summaryDiagnosticKey(for: file.path))
                let isCoordinator = !kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("subagent")
                remember(revision: revision, isCoordinator: isCoordinator)
                return isCoordinator
            }
            DiagnosticGate.clearFailure(Self.summaryDiagnosticKey(for: file.path))
            remember(revision: revision, isCoordinator: true)
            return true
        } catch {
            Self.logSummaryFailure(
                file: file.path,
                message: "Could not read Grok session summary: \(error.localizedDescription)"
            )
            return nil
        }
    }

    /// Remember a summary's classification. The cache is bounded: a session folder that disappears
    /// leaves its entry behind, and the number of sessions only grows.
    private func remember(revision: SummaryRevision, isCoordinator: Bool) {
        if summaryClassifications.count >= Self.maximumCachedSummaries {
            summaryClassifications.removeAll(keepingCapacity: true)
        }
        summaryClassifications[revision.path] = SummaryClassification(
            revision: revision,
            isCoordinator: isCoordinator
        )
    }

    private static func summaryDiagnosticKey(for path: String) -> String {
        "grok.session.summary.\(JSONLScanCachePaths.stableFingerprint(path))"
    }

    private static func logSummaryFailure(file path: String, message: String) {
        DiagnosticGate.logOnce(for: summaryDiagnosticKey(for: path)) {
            AppLog.warn(LogTag.plugin("grok"), message)
        }
    }

    // MARK: - Session parsing

    static func parseFile(_ data: Data) -> [Entry] {
        var entries: [Entry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if case .entries(let parsed) = parseLine(Data(line)) { entries.append(contentsOf: parsed) }
        }
        return entries
    }

    nonisolated static func parseFile(at url: URL) -> [Entry]? {
        var entries: [Entry] = []
        var malformed = false
        let readSucceeded = JSONLFileReader.forEachLine(at: url) { line in
            switch parseLine(Data(line)) {
            case .entries(let parsed): entries.append(contentsOf: parsed)
            case .irrelevant: break
            case .malformed: malformed = true
            }
        }
        guard readSucceeded, !malformed else { return nil }
        return entries
    }

    private enum LineResult {
        case entries([Entry])
        case irrelevant
        case malformed
    }

    private static let completedTurnMarker = Data("turn_completed".utf8)

    private static func parseLine(_ line: Data) -> LineResult {
        guard line.range(of: completedTurnMarker) != nil else { return .irrelevant }
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return .malformed
        }
        let params = object["params"] as? [String: Any]
        let update = (params?["update"] as? [String: Any]) ?? (object["update"] as? [String: Any])
        guard let update else { return .irrelevant }
        guard let sessionUpdate = update["sessionUpdate"] as? String else { return .irrelevant }
        guard sessionUpdate == "turn_completed" else { return .irrelevant }
        guard let entries = parseCompletedTurn(object, params: params, update: update) else {
            return .malformed
        }
        return .entries(entries)
    }

    private static func parseCompletedTurn(
        _ object: [String: Any],
        params: [String: Any]?,
        update: [String: Any]
    ) -> [Entry]? {
        guard let usage = update["usage"] as? [String: Any],
              let modelUsage = usage["modelUsage"] as? [String: Any],
              let timestamp = timestamp(in: object, params: params)
        else { return nil }

        let metadata = (params?["_meta"] as? [String: Any]) ?? (object["_meta"] as? [String: Any])
        var eventID: String?
        if let rawMetadata = params?["_meta"] ?? object["_meta"], !(rawMetadata is NSNull),
           !(rawMetadata is [String: Any]) { return nil }
        if let rawID = metadata?["eventId"], !(rawID is NSNull) {
            guard let text = rawID as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            eventID = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let topLevelTicks: Double?
        if let rawTicks = usage["costUsdTicks"], !(rawTicks is NSNull) {
            guard let ticks = validTicks(rawTicks) else { return nil }
            topLevelTicks = ticks
        } else {
            topLevelTicks = nil
        }
        var entries: [Entry] = []

        for (rawModel, rawUsage) in modelUsage.sorted(by: { $0.key < $1.key }) {
            let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty,
                  let values = rawUsage as? [String: Any],
                  let input = strictCount(values["inputTokens"], required: true),
                  let output = strictCount(values["outputTokens"], required: true),
                  let cacheRead = strictCount(values["cachedReadTokens"], required: false),
                  let cacheWrite = strictCount(values["cacheCreationTokens"], required: false),
                  cacheRead <= input,
                  cacheWrite <= input - cacheRead
            else { return nil }

            // Grok reports reasoning as a subset of outputTokens, so it must never be added again.
            let ticks: Double?
            if let rawTicks = values["costUsdTicks"], !(rawTicks is NSNull) {
                guard let parsedTicks = validTicks(rawTicks) else { return nil }
                ticks = parsedTicks
            } else {
                ticks = modelUsage.count == 1 ? topLevelTicks : nil
            }
            let carriedCost = ticks.map { $0 / 10_000_000_000 }

            entries.append(Entry(
                eventID: eventID,
                timestamp: timestamp,
                model: model,
                tokens: TokenBreakdown(
                    input: input - cacheRead - cacheWrite,
                    cacheWrite5m: cacheWrite,
                    cacheRead: cacheRead,
                    output: output
                ),
                carriedCost: carriedCost
            ))
        }
        return entries
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

    private static func validTicks(_ raw: Any) -> Double? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let value = number.doubleValue
        guard value.isFinite,
              value >= 0,
              value <= 1e22,
              value.rounded(.towardZero) == value
        else { return nil }
        return value
    }

    private static func timestamp(in object: [String: Any], params: [String: Any]?) -> Date? {
        for rawMetadata in [params?["_meta"], object["_meta"]] {
            guard let rawMetadata else { continue }
            if rawMetadata is NSNull { continue }
            guard let values = rawMetadata as? [String: Any] else { return nil }
            if let rawMilliseconds = values["agentTimestampMs"] {
                guard let milliseconds = strictCount(rawMilliseconds, required: true), milliseconds > 0 else {
                    return nil
                }
                return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
            }
        }

        if let rawTimestamp = object["timestamp"] as? NSNumber {
            guard CFGetTypeID(rawTimestamp) != CFBooleanGetTypeID() else { return nil }
            let seconds = rawTimestamp.doubleValue
            guard seconds.isFinite, seconds > 0, seconds <= 1e12 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        if let value = object["timestamp"] as? String {
            return OpenUsageISO8601.date(from: value)
        }
        return nil
    }

    // MARK: - Deduplication and aggregation

    static func dedup(_ entries: [Entry]) -> [Entry] {
        var seen: Set<String> = []
        var output: [Entry] = []
        output.reserveCapacity(entries.count)
        JSONLAccountingWorkPacer.shared.forEach(entries) { entry in
            guard let eventID = entry.eventID else {
                output.append(entry)
                return
            }
            if seen.insert(eventID + "\0" + entry.model).inserted {
                output.append(entry)
            }
        }
        return output
    }

    static func aggregate(entries: [Entry], since: Date, pricing: ModelPricing) -> LogUsageScan {
        var accumulator = DailyUsageAccumulator()
        JSONLAccountingWorkPacer.shared.forEach(entries) { entry in
            guard entry.timestamp >= since else { return }
            let day = DailyUsageAccumulator.dayKey(from: entry.timestamp)
            // One price resolution per entry: the same estimate feeds the day's cost and the
            // API-rate comparison. Resolving it twice per entry doubled the pricing work on every
            // fold, and the two numbers were always the same.
            let estimate = pricing.estimatedCostDollars(model: entry.model, tokens: entry.tokens)
            let cost = entry.carriedCost ?? estimate
            accumulator.recordApiEstimate(
                day: day,
                cost: estimate,
                tokens: entry.tokens.totalTokens
            )
            if cost == nil, entry.tokens.totalTokens > 0 {
                accumulator.addUnknownModel(day: day, model: entry.model)
            }
            // Unpriced rows count their tokens with a dashed cost (owner policy), so the totals stay
            // complete and a later reveal can price them.
            accumulator.add(day: day, tokens: entry.tokens.totalTokens, cost: cost, model: entry.model)
        }
        return accumulator.build()
    }
}
