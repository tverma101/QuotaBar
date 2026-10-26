import Foundation
import CoreFoundation
import os

/// A missing native source is complete empty data; an incomplete discovery or fold must preserve the
/// last-good combined history instead of publishing whichever session files happened to succeed.
enum CodexLogUsageScanResult: Sendable {
    case complete(LogUsageScan?)
    case incomplete
}

/// Builds daily token/cost estimates for Codex by scanning the Codex CLI's local session rollouts
/// natively (`$CODEX_HOME/sessions/**/*.jsonl` + `archived_sessions/`), replacing the external
/// `ccusage` CLI.
///
/// Rollouts are append-heavy. The persisted file cache still provides correctness across launches;
/// within a running process a bounded checkpoint cache remembers the parser state at EOF so a growing
/// multi-GB rollout reads only its appended bytes. Any identity/anchor/truncation mismatch falls back to
/// the full streaming parser. Only a bounded recent event window is retained; older lines are still
/// consumed on a cold parse when needed to establish cumulative/model/replay state, but are not kept.
actor CodexLogUsageScanner {
    private let environment: EnvironmentReading
    private let homeDirectory: @Sendable () -> URL
    private let scanner: IncrementalJSONLScanner<Event>

    struct Event: Codable, Sendable, Equatable {
        var timestamp: Date
        var model: String
        var pricingModel: String? = nil
        var input: Int
        var cached: Int
        var output: Int
        var reasoning: Int
        var total: Int
        var hasCompleteCostBreakdown: Bool = true
        var isFast: Bool = false
        var serviceTier: String? = nil
    }

    /// Token fields of a `token_count` usage object, tolerating the older field spellings ccusage
    /// accepts (`prompt_tokens`, `completion_tokens`, `cache_read_input_tokens`, …).
    struct RawUsage: Sendable {
        var input: Int
        var cached: Int
        var output: Int
        var reasoning: Int
        var total: Int
        /// `total` is component-derived when absent or zero; only a positive reported value is a
        /// cumulative total counter that can authoritatively produce a later delta.
        var hasReportedTotal: Bool
        var hasCompleteCostBreakdown: Bool
        var isValid: Bool

        init(json: [String: Any]) {
            func int(_ keys: String...) -> (value: Int?, isPresent: Bool, isValid: Bool) {
                for key in keys {
                    guard let raw = json[key] else { continue }
                    guard let number = raw as? NSNumber,
                          CFGetTypeID(number) != CFBooleanGetTypeID()
                    else { return (nil, true, false) }
                    let value = number.doubleValue
                    guard value.isFinite,
                          value >= 0,
                          value <= 1e15,
                          value.rounded(.towardZero) == value
                    else { return (nil, true, false) }
                    return (Int(value), true, true)
                }
                return (nil, false, true)
            }
            let parsedInput = int("input_tokens", "prompt_tokens", "input")
            let parsedCached = int("cached_input_tokens", "cache_read_input_tokens", "cached_tokens")
            let parsedOutput = int("output_tokens", "completion_tokens", "output")
            let parsedReasoning = int("reasoning_output_tokens", "reasoning_tokens")
            let parsedTotal = int("total_tokens")
            input = parsedInput.value ?? 0
            // Cached input is a subset of reported input. Some Codex snapshots briefly disagree
            // while counters settle; count no more cached tokens than the measured input bucket.
            cached = min(parsedCached.value ?? 0, input)
            output = parsedOutput.value ?? 0
            reasoning = parsedReasoning.value ?? 0
            let reported = parsedTotal.value ?? 0
            // Reasoning tokens are a subset of output on OpenAI/Codex usage; do not add them again.
            // Counts are bounded before recomputation; the parser rejects an invalid row before aggregation.
            let recomputed = ProviderParse.addingSaturating(input, output)
            let hasReportedTotal = reported > 0
            total = hasReportedTotal ? reported : recomputed
            self.hasReportedTotal = hasReportedTotal
            let hasAuthoritativeTotal = hasReportedTotal || (parsedInput.isPresent && parsedOutput.isPresent)
            isValid = parsedInput.isValid && parsedCached.isValid && parsedOutput.isValid
                && parsedReasoning.isValid && parsedTotal.isValid && hasAuthoritativeTotal
            hasCompleteCostBreakdown = parsedInput.isPresent && parsedOutput.isPresent
                && cached <= input && reasoning <= output
                // A present zero total is still a report. If it contradicts positive components,
                // keep the component-derived token count but never present its partial price as whole.
                && (!parsedTotal.isPresent || reported == recomputed)
        }

        private init(
            input: Int,
            cached: Int,
            output: Int,
            reasoning: Int,
            total: Int,
            hasReportedTotal: Bool,
            isValid: Bool,
            hasCompleteCostBreakdown: Bool
        ) {
            self.input = input
            self.cached = min(cached, input)
            self.output = output
            self.reasoning = reasoning
            self.total = total
            self.hasReportedTotal = hasReportedTotal
            self.isValid = isValid
            self.hasCompleteCostBreakdown = hasCompleteCostBreakdown
        }

        func equalCounts(_ other: RawUsage) -> Bool {
            input == other.input && cached == other.cached && output == other.output
                && reasoning == other.reasoning && total == other.total
                && hasReportedTotal == other.hasReportedTotal && isValid == other.isValid
                && hasCompleteCostBreakdown == other.hasCompleteCostBreakdown
        }

        func subtracting(_ previous: RawUsage?) -> RawUsage {
            guard let previous else {
                return RawUsage(
                    input: input, cached: cached, output: output, reasoning: reasoning, total: total,
                    hasReportedTotal: hasReportedTotal,
                    isValid: isValid, hasCompleteCostBreakdown: hasCompleteCostBreakdown
                )
            }
            // Components are cumulative too, but their resets require independent deltas. A derived
            // total cannot be differenced across a component reset or it permanently loses tokens.
            // A reported total remains authoritative against either a prior reported total or a
            // baseline accumulated from last-only events. Discrepancies with component deltas make
            // only the cost incomplete.
            let inputDelta = input >= previous.input ? input - previous.input : input
            let cachedDelta = cached >= previous.cached ? cached - previous.cached : cached
            let outputDelta = output >= previous.output ? output - previous.output : output
            let reasoningDelta = reasoning >= previous.reasoning ? reasoning - previous.reasoning : reasoning
            let componentTotal = ProviderParse.addingSaturating(inputDelta, outputDelta)
            let totalDelta: Int
            if hasReportedTotal {
                totalDelta = total >= previous.total ? total - previous.total : total
            } else {
                totalDelta = componentTotal
            }
            let complete = hasCompleteCostBreakdown && previous.hasCompleteCostBreakdown
                && cachedDelta <= inputDelta && reasoningDelta <= outputDelta
                && totalDelta == componentTotal
            return RawUsage(
                input: inputDelta, cached: cachedDelta, output: outputDelta, reasoning: reasoningDelta,
                total: totalDelta, hasReportedTotal: false, isValid: isValid && previous.isValid,
                hasCompleteCostBreakdown: complete
            )
        }

        func addingAsBaseline(_ delta: RawUsage) -> RawUsage {
            RawUsage(
                input: ProviderParse.addingSaturating(input, delta.input),
                cached: ProviderParse.addingSaturating(cached, delta.cached),
                output: ProviderParse.addingSaturating(output, delta.output),
                reasoning: ProviderParse.addingSaturating(reasoning, delta.reasoning),
                total: ProviderParse.addingSaturating(total, delta.total),
                hasReportedTotal: false,
                isValid: isValid && delta.isValid,
                hasCompleteCostBreakdown: hasCompleteCostBreakdown && delta.hasCompleteCostBreakdown
            )
        }

        func asBaseline() -> RawUsage {
            RawUsage(
                input: input,
                cached: cached,
                output: output,
                reasoning: reasoning,
                total: total,
                hasReportedTotal: false,
                isValid: isValid,
                hasCompleteCostBreakdown: hasCompleteCostBreakdown
            )
        }
    }

    private enum ChildReplayGate: Sendable {
        case untilStartedAt(TimeInterval)
        case untilSelfTimedTaskStarted

        func isCleared(byStartedAt startedAt: TimeInterval, lineTimestamp: String?) -> Bool {
            switch self {
            case .untilStartedAt(let gate):
                return startedAt >= gate
            case .untilSelfTimedTaskStarted:
                guard let raw = lineTimestamp?.trimmingCharacters(in: .whitespaces),
                      let lineDate = OpenUsageISO8601.date(from: raw)
                else { return false }
                return startedAt >= lineDate.timeIntervalSince1970.rounded(.down)
            }
        }
    }

    private struct ParserCheckpoint: Sendable {
        var previousTotals: RawUsage?
        var currentModel: String?
        var currentTierIsFast: Bool
        var currentServiceTier: String?
        var currentServiceTierIsValid: Bool
        var sawSessionMeta: Bool
        var replayGate: ChildReplayGate?
    }

    struct IncrementalReadStatistics: Equatable, Sendable {
        var fullParses: Int
        var tailParses: Int
        var bytesRead: Int
    }

    private static let minimumCacheRetentionDays = 35
    private static let sharedTailCache = AppendOnlyFileTailCache<Event, ParserCheckpoint>(
        maxEntries: 128,
        maxRetainedItems: 8_000
    )

    /// Schema 4 intentionally drops the old unbounded per-file event records. Rebuilding once gives
    /// every persisted record the bounded retention semantics below.
    ///
    /// `retainResidentItems: false` unloads IncrementalJSONLScanner CachedFile.items after each
    /// return so Event arrays are not retained twice (scanner + sharedTailCache). Metadata-only
    /// disk loads keep cold identities cheap; hydrate/reparse uses disk or the tail cache.
    static let parsedEventCachePersistence = JSONLScanCachePersistence(namespace: "codex", schemaVersion: 8)
    private static let sharedScanner = IncrementalJSONLScanner<Event>(
        maxResidentIdentities: 2,
        retainResidentItems: false,
        logTag: LogTag.plugin("codex"),
        persistence: parsedEventCachePersistence
    )

    static func flushPersistentCacheWrites() async {
        await sharedScanner.flushPendingWrites()
    }

    /// Drop Event arrays from the process-wide tail cache while keeping append checkpoints. Used only
    /// when the process crosses its memory budget or macOS reports pressure; routine refreshes keep
    /// this cache warm so an append does not reparse unchanged history.
    static func unloadSharedTailCacheItems() {
        sharedTailCache.unloadRetainedItems()
    }

    /// Other Codex account homes whose session rollouts may share hardlinks with this card's homes.
    /// When this scanner enumerates a *managed* (non-default) home, files whose inode also appears
    /// under a peer `~/.codex` are skipped so Orca backfills stay attributed to default. Default
    /// `~/.codex` keeps shared inodes (see `sessionFiles`).
    private let peerHomes: [URL]

    /// Priced per-inode folds. A menu-bar tap reuses these when size/mtime/inode are unchanged
    /// instead of re-walking every retained session event. Only the files that actually grew are
    /// folded, then merged with the cached slices.
    private struct InodeAggregateKey: Hashable, Codable {
        var device: UInt64
        var inode: UInt64
    }

    private struct InodeAggregateRecord: Codable {
        var size: Int
        var mtime: Date
        var attributeMtime: Date?
        var latestIncludedTimestamp: Date?
        var scan: LogUsageScan
    }

    private struct PersistedInodeAggregates: Codable {
        var schema: Int
        var pricingToken: String
        var since: Date
        var timeZoneIdentifier: String
        var records: [PersistedInodeAggregate]
    }

    private struct PersistedInodeAggregate: Codable {
        var device: UInt64
        var inode: UInt64
        var record: InodeAggregateRecord
    }

    private final class PerFileFoldBucket: @unchecked Sendable {
        var fold = AggregateFoldState()
        var scans: [String: LogUsageScan] = [:]
        var latestTimestamps: [String: Date] = [:]
        var futureTimestamps: [String: Date] = [:]
        private var currentPath: String?
        private var currentLatestTimestamp: Date?

        func begin(_ path: String) {
            currentPath = path
            fold = AggregateFoldState()
            currentLatestTimestamp = nil
        }

        func finish(_ path: String) {
            scans[path] = fold.accumulator.build()
            if let currentLatestTimestamp {
                latestTimestamps[path] = currentLatestTimestamp
            }
            currentPath = nil
        }

        func noteIncludedTimestamp(_ timestamp: Date) {
            if currentLatestTimestamp.map({ timestamp > $0 }) ?? true {
                currentLatestTimestamp = timestamp
            }
        }

        func noteFutureTimestamp(_ timestamp: Date) {
            guard let currentPath else { return }
            if futureTimestamps[currentPath].map({ timestamp > $0 }) ?? true {
                futureTimestamps[currentPath] = timestamp
            }
        }
    }

    private var inodeAggregates: [InodeAggregateKey: InodeAggregateRecord] = [:]
    private var aggregatePricingToken: String?
    private var aggregateSince: Date?
    private var aggregateTimeZone: String?
    private var aggregateIdentity: String?
    private var didAttemptAggregateLoad = false

    private static var persistsUsageAggregates: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    }

    init(
        environment: EnvironmentReading = QuotaBarEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        peerHomes: [URL] = [],
        incrementalScanner: IncrementalJSONLScanner<Event>? = nil
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.peerHomes = peerHomes
        self.scanner = incrementalScanner ?? Self.sharedScanner
    }

    func scan(
        daysBack: Int = UsageHistoryWindow.previousDays,
        now: Date = Date(),
        pricing: ModelPricing,
        peerHomes peerHomesOverride: [URL]? = nil
    ) async -> LogUsageScan? {
        switch await scanResult(
            daysBack: daysBack,
            now: now,
            pricing: pricing,
            peerHomes: peerHomesOverride
        ) {
        case .complete(let scan):
            return scan
        case .incomplete:
            return nil
        }
    }

    /// Completeness-aware scan used by providers that merge Codex logs with other sources.
    func scanResult(
        daysBack: Int = UsageHistoryWindow.previousDays,
        now: Date = Date(),
        pricing: ModelPricing,
        peerHomes peerHomesOverride: [URL]? = nil
    ) async -> CodexLogUsageScanResult {
        guard !Task.isCancelled else { return .incomplete }
        let homes = codexHomes()
        guard !Task.isCancelled else { return .incomplete }
        let context = Self.scanContext(homes: homes, daysBack: daysBack, now: now)
        let futureIdentity = "codex.native.\(context.identity)"
        guard let files = Self.sessionFilesIfComplete(
            homes: homes,
            peerHomes: peerHomesOverride ?? peerHomes,
            homeDirectory: homeDirectory
        ) else {
            if !Task.isCancelled {
                Self.logScanFailure(
                    identity: context.identity,
                    kind: "discovery",
                    message: "session files or peer inodes could not be completely discovered; preserving last-good history"
                )
            }
            return .incomplete
        }
        guard !Task.isCancelled else { return .incomplete }
        guard !files.isEmpty else {
            FutureTimestampRevisionGate.retain(identity: futureIdentity, paths: [])
            DiagnosticGate.clearFailure(Self.futureTimestampDiagnosticKey(for: futureIdentity))
            let complete = await scanner.foldItems(
                from: [], since: context.cacheSince, cacheIdentity: context.identity,
                parseFile: { url in
                    Self.parseFileIncrementally(
                        at: url,
                        emitSince: context.cacheSince,
                        retentionDays: context.retentionDays
                    )
                },
                visit: { _ in }
            )
            guard complete else {
                if !Task.isCancelled {
                    Self.logScanFailure(
                        identity: context.identity,
                        kind: "empty-fold",
                        message: "empty session fold did not complete; preserving last-good history"
                    )
                }
                return .incomplete
            }
            Self.clearScanFailures(identity: context.identity)
            return Task.isCancelled ? .incomplete : .complete(nil)
        }

        let maximumTimestamp = JSONLScanning.maximumTimestamp(now: now)
        FutureTimestampRevisionGate.retain(identity: futureIdentity, paths: Set(files.map(\.path)))
        for file in files where FutureTimestampRevisionGate.shouldDefer(
            identity: futureIdentity, file: file, maximumTimestamp: maximumTimestamp
        ) {
            Self.logFutureTimestamp(identity: futureIdentity)
            return .incomplete
        }

        let pricingToken = pricing.aggregateCacheToken
        let timeZone = Calendar.current.timeZone.identifier
        prepareInodeAggregates(
            identity: context.identity,
            pricingToken: pricingToken,
            since: context.cacheSince,
            timeZone: timeZone
        )

        let requestedSince = context.requestedSince
        // Per-inode aggregates fold the RETENTION window (cacheSince — stable within a day), not the
        // requested one. Keying them on requestedSince made every scope change discard every
        // aggregate: menu-bar passes (small daysBack) and full passes (30 days) alternate, so each
        // paid a full re-fold of the whole session corpus. The narrower window is clipped at serve
        // time instead, from the same retained aggregates.
        let minDayKey = DailyUsageAccumulator.dayKey(from: requestedSince)
        var unchanged: [LogUsageScan] = []
        var changed: [JSONLScanning.DiscoveredFile] = []
        var liveInodes: Set<InodeAggregateKey> = []
        var fileKeysByPath: [String: InodeAggregateKey] = [:]
        unchanged.reserveCapacity(files.count)
        for file in files {
            guard !Task.isCancelled else { return .incomplete }
            guard let revision = AppendOnlyFileProbe.revision(at: URL(fileURLWithPath: file.path)) else {
                Self.logScanFailure(
                    identity: context.identity,
                    kind: "file-stat",
                    path: file.path,
                    message: "session file identity could not be read; preserving last-good history"
                )
                return .incomplete
            }
            let key = InodeAggregateKey(device: revision.device, inode: revision.inode)
            liveInodes.insert(key)
            fileKeysByPath[file.path] = key
            if let cached = inodeAggregates[key],
               cached.size == file.size,
               Self.timestampsMatch(cached.mtime, file.mtime),
               Self.timestampsMatch(cached.attributeMtime, file.attributeMtime) {
                guard Self.sourceRevisionStillMatches(file, key: key) else {
                    Self.logScanFailure(
                        identity: context.identity,
                        kind: "changed-after-discovery",
                        path: file.path,
                        message: "session file changed after discovery; preserving last-good history"
                    )
                    return .incomplete
                }
                if cached.latestIncludedTimestamp.map({
                    $0 > maximumTimestamp
                }) ?? false {
                    if let latestTimestamp = cached.latestIncludedTimestamp {
                        _ = FutureTimestampRevisionGate.record(
                            latestTimestamp, identity: futureIdentity, file: file
                        )
                    }
                    Self.logFutureTimestamp(identity: futureIdentity)
                    return .incomplete
                }
                unchanged.append(cached.scan)
            } else {
                changed.append(file)
            }
        }
        if inodeAggregates.contains(where: { !liveInodes.contains($0.key) }) {
            inodeAggregates = inodeAggregates.filter { liveInodes.contains($0.key) }
        }
        if changed.isEmpty {
            AppLog.debug(LogTag.plugin("codex"), "aggregate split: unchanged=\(unchanged.count) changed=0")
            guard !Task.isCancelled else { return .incomplete }
            DiagnosticGate.clearFailure(Self.futureTimestampDiagnosticKey(for: futureIdentity))
            Self.clearScanFailures(identity: context.identity)
            return .complete(
                DailyUsageAccumulator.merged(unchanged, droppingDaysBefore: minDayKey)
                    ?? DailyUsageAccumulator().build()
            )
        }
        AppLog.debug(LogTag.plugin("codex"), "aggregate split: unchanged=\(unchanged.count) changed=\(changed.count)")

        let bucket = PerFileFoldBucket()
        guard !Task.isCancelled else { return .incomplete }
        let ok = await scanner.foldItems(
            from: changed, since: context.cacheSince, cacheIdentity: context.identity,
            parseFile: { url in
                Self.parseFileIncrementally(
                    at: url,
                    emitSince: context.cacheSince,
                    retentionDays: context.retentionDays
                )
            },
            visit: { event in
                guard Self.hasTokenUsage(event) else { return }
                guard event.timestamp <= maximumTimestamp else {
                    bucket.noteFutureTimestamp(event.timestamp)
                    return
                }
                bucket.noteIncludedTimestamp(event.timestamp)
                Self.accumulate(
                    event: event,
                    since: context.cacheSince,
                    pricing: pricing,
                    seen: &bucket.fold.seen,
                    accumulator: &bucket.fold.accumulator
                )
            },
            fileStarted: { path in
                bucket.begin(path)
            },
            fileCompleted: { path, _ in
                bucket.finish(path)
            }
        )
        guard ok else {
            if !Task.isCancelled {
                Self.logScanFailure(
                    identity: context.identity,
                    kind: "fold",
                    message: "session file fold was incomplete; preserving last-good history"
                )
            }
            return .incomplete
        }
        guard !Task.isCancelled else { return .incomplete }

        var refreshed: [(key: InodeAggregateKey, record: InodeAggregateRecord, scan: LogUsageScan)] = []
        refreshed.reserveCapacity(changed.count)
        let futurePaths = Set(bucket.futureTimestamps.keys)
        for file in changed where !futurePaths.contains(file.path) {
            guard let scan = bucket.scans[file.path],
                  let key = fileKeysByPath[file.path],
                  Self.sourceRevisionStillMatches(file, key: key)
            else {
                if !Task.isCancelled {
                    Self.logScanFailure(
                        identity: context.identity,
                        kind: "changed-during-fold",
                        path: file.path,
                        message: "session file changed during fold; preserving last-good history"
                    )
                }
                return .incomplete
            }
            refreshed.append((
                key: key,
                record: InodeAggregateRecord(
                    size: file.size,
                    mtime: file.mtime,
                    attributeMtime: file.attributeMtime,
                    latestIncludedTimestamp: bucket.latestTimestamps[file.path],
                    scan: scan
                ),
                scan: scan
            ))
        }
        for file in changed where futurePaths.contains(file.path) {
            guard let futureTimestamp = bucket.futureTimestamps[file.path],
                  let key = fileKeysByPath[file.path],
                  Self.sourceRevisionStillMatches(file, key: key),
                  FutureTimestampRevisionGate.record(
                    futureTimestamp, identity: futureIdentity, file: file
                  )
            else {
                if !Task.isCancelled {
                    Self.logScanFailure(
                        identity: context.identity,
                        kind: "changed-during-future-scan",
                        path: file.path,
                        message: "session file changed during future-timestamp scan; preserving last-good history"
                    )
                }
                return .incomplete
            }
        }
        for item in refreshed {
            inodeAggregates[item.key] = item.record
            unchanged.append(item.scan)
        }
        if !refreshed.isEmpty {
            persistInodeAggregates(
                identity: context.identity,
                pricingToken: pricingToken,
                since: context.cacheSince,
                timeZone: timeZone
            )
        }
        guard !Task.isCancelled else { return .incomplete }
        if !futurePaths.isEmpty {
            Self.logFutureTimestamp(identity: futureIdentity)
            return .incomplete
        }
        DiagnosticGate.clearFailure(Self.futureTimestampDiagnosticKey(for: futureIdentity))
        Self.clearScanFailures(identity: context.identity)
        return .complete(
            DailyUsageAccumulator.merged(unchanged, droppingDaysBefore: minDayKey)
                ?? DailyUsageAccumulator().build()
        )
    }

    private static func futureTimestampDiagnosticKey(for identity: String) -> String {
        "codex.sessions.future-timestamp.\(JSONLScanCachePaths.stableFingerprint(identity))"
    }

    private static func logFutureTimestamp(identity: String) {
        DiagnosticGate.logOnce(for: futureTimestampDiagnosticKey(for: identity)) {
            AppLog.warn(LogTag.plugin("codex"), "session usage contains a timestamp more than five minutes ahead; preserving last-good history")
        }
    }

    private static func scanFailurePrefix(for identity: String) -> String {
        "codex.sessions.scan.\(JSONLScanCachePaths.stableFingerprint(identity))."
    }

    private static func logScanFailure(
        identity: String,
        kind: String,
        path: String? = nil,
        message: String
    ) {
        let pathKey = path.map { ".\(JSONLScanCachePaths.stableFingerprint($0))" } ?? ""
        DiagnosticGate.logOnce(for: scanFailurePrefix(for: identity) + kind + pathKey) {
            AppLog.warn(LogTag.plugin("codex"), message)
        }
    }

    private static func clearScanFailures(identity: String) {
        DiagnosticGate.clearFailures(prefix: scanFailurePrefix(for: identity))
    }

    private static func sourceRevisionStillMatches(
        _ file: JSONLScanning.DiscoveredFile,
        key: InodeAggregateKey
    ) -> Bool {
        let url = URL(fileURLWithPath: file.path)
        guard let revision = AppendOnlyFileProbe.revision(at: url),
              revision.device == key.device,
              revision.inode == key.inode,
              revision.size == UInt64(file.size),
              let metadata = try? url.resourceValues(forKeys: Set([
                  .fileSizeKey, .contentModificationDateKey, .attributeModificationDateKey
              ]))
        else { return false }
        return metadata.fileSize == file.size
            && metadata.contentModificationDate == file.mtime
            && metadata.attributeModificationDate == file.attributeMtime
    }

    private func prepareInodeAggregates(
        identity: String,
        pricingToken: String,
        since: Date,
        timeZone: String
    ) {
        let contextChanged = aggregateIdentity != identity
            || aggregatePricingToken != pricingToken
            || aggregateTimeZone != timeZone
            || !Self.timestampsMatch(aggregateSince, since)
        if contextChanged {
            inodeAggregates = [:]
            didAttemptAggregateLoad = false
            aggregateIdentity = identity
            aggregatePricingToken = pricingToken
            aggregateSince = since
            aggregateTimeZone = timeZone
        }
        guard !didAttemptAggregateLoad else { return }
        didAttemptAggregateLoad = true
        guard Self.persistsUsageAggregates else { return }
        let loaded = Self.readInodeAggregates(identity: identity)
        if loaded == nil {
            AppLog.debug(LogTag.plugin("codex"), "aggregate load: no index on disk for identity")
        }
        guard let loaded,
              loaded.schema == 5,
              loaded.pricingToken == pricingToken,
              loaded.timeZoneIdentifier == timeZone,
              Self.timestampsMatch(loaded.since, since)
        else {
            if let loaded {
                AppLog.debug(
                    LogTag.plugin("codex"),
                    "aggregate load rejected: tokenMatch=\(loaded.pricingToken == pricingToken) tzMatch=\(loaded.timeZoneIdentifier == timeZone) sinceMatch=\(Self.timestampsMatch(loaded.since, since))"
                )
            }
            return
        }
        var restored: [InodeAggregateKey: InodeAggregateRecord] = [:]
        restored.reserveCapacity(loaded.records.count)
        for entry in loaded.records {
            restored[InodeAggregateKey(device: entry.device, inode: entry.inode)] = entry.record
        }
        inodeAggregates = restored
    }

    private func persistInodeAggregates(
        identity: String,
        pricingToken: String,
        since: Date,
        timeZone: String
    ) {
        guard Self.persistsUsageAggregates else { return }
        let payload = PersistedInodeAggregates(
            schema: 5,
            pricingToken: pricingToken,
            since: since,
            timeZoneIdentifier: timeZone,
            records: inodeAggregates.map { key, record in
                PersistedInodeAggregate(device: key.device, inode: key.inode, record: record)
            }
        )
        let url = Self.aggregateIndexURL(identity: identity)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            let data = try encoder.encode(payload)
            try data.write(to: url, options: .atomic)
        } catch {
            AppLog.debug(LogTag.plugin("codex"), "usage aggregate index write failed")
        }
    }

    private static func readInodeAggregates(identity: String) -> PersistedInodeAggregates? {
        let url = aggregateIndexURL(identity: identity)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(PersistedInodeAggregates.self, from: data)
    }

    private static func aggregateIndexURL(identity: String) -> URL {
        JSONLScanCachePaths.defaultDirectory
            .appendingPathComponent("aggregates", isDirectory: true)
            .appendingPathComponent("codex-sessions-\(JSONLScanCachePaths.stableFingerprint(identity)).json")
    }

    private static func timestampsMatch(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return abs(lhs.timeIntervalSinceReferenceDate - rhs.timeIntervalSinceReferenceDate) < 0.001
        default:
            return false
        }
    }

    /// The parsed turns of the last `daysBack` days. Default 30/33-day consumers share one 35-day
    /// cache; an explicitly wider request receives its own retention bucket so a narrow earlier scan
    /// can never poison a later wider one.
    func parsedEvents(daysBack: Int = 33, now: Date = Date(), homes: [URL]? = nil) async -> [Event] {
        let homes = homes ?? codexHomes()
        let context = Self.scanContext(homes: homes, daysBack: daysBack, now: now)
        guard let files = Self.sessionFilesIfComplete(
            homes: homes,
            peerHomes: peerHomes,
            homeDirectory: homeDirectory
        ) else { return [] }
        guard !files.isEmpty else { return [] }
        let cached = await scanner.items(
            from: files, since: context.cacheSince, cacheIdentity: context.identity,
            parseFile: { url in
                Self.parseFileIncrementally(
                    at: url,
                    emitSince: context.cacheSince,
                    retentionDays: context.retentionDays
                )
            }
        ) ?? []
        return cached.filter { $0.timestamp >= context.requestedSince }
    }

    /// Stream parsed turns without retaining a mega-array. OpenCode gateway fold uses this so each
    /// Codex home can be folded and forgotten before the next home starts.
    @discardableResult
    func foldParsedEvents(
        daysBack: Int = 33,
        now: Date = Date(),
        homes: [URL]? = nil,
        visit: @Sendable (Event) -> Void
    ) async -> Bool {
        let homes = homes ?? codexHomes()
        let context = Self.scanContext(homes: homes, daysBack: daysBack, now: now)
        guard let files = Self.sessionFilesIfComplete(
            homes: homes,
            peerHomes: peerHomes,
            homeDirectory: homeDirectory
        ) else { return false }
        guard !files.isEmpty else { return true }
        return await scanner.foldItems(
            from: files, since: context.cacheSince, cacheIdentity: context.identity,
            parseFile: { url in
                Self.parseFileIncrementally(
                    at: url,
                    emitSince: context.cacheSince,
                    retentionDays: context.retentionDays
                )
            },
            visit: { event in
                guard event.timestamp >= context.requestedSince else { return }
                visit(event)
            }
        )
    }

    /// OpenCode consumes only gateway events. Its own slim cache prevents decoding every native
    /// Codex event after the ordinary cache has released its resident arrays.
    @discardableResult
    func foldHostedGatewayEvents(
        daysBack: Int = 33,
        now: Date = Date(),
        homes: [URL],
        gatewayScanner: IncrementalJSONLScanner<Event>? = nil,
        nativeCachePersistence: JSONLScanCachePersistence? = nil,
        rolloutNameDeduper: CodexRolloutNameDeduper? = nil,
        visit: @Sendable (Event) -> Void
    ) async -> Bool {
        let context = Self.scanContext(homes: homes, daysBack: daysBack, now: now)
        guard let discovered = Self.sessionFilesIfComplete(
            homes: homes,
            peerHomes: peerHomes,
            homeDirectory: homeDirectory
        ) else { return false }
        let files = rolloutNameDeduper?.retainingFirstOccurrence(of: discovered) ?? discovered
        let futureIdentity = "codex.gateway.\(context.identity)"
        guard !files.isEmpty else {
            FutureTimestampRevisionGate.retain(identity: futureIdentity, paths: [])
            DiagnosticGate.clearFailure(Self.futureTimestampDiagnosticKey(for: futureIdentity))
            return true
        }
        let maximumTimestamp = JSONLScanning.maximumTimestamp(now: now)
        FutureTimestampRevisionGate.retain(identity: futureIdentity, paths: Set(files.map(\.path)))
        for file in files where FutureTimestampRevisionGate.shouldDefer(
            identity: futureIdentity, file: file, maximumTimestamp: maximumTimestamp
        ) {
            Self.logHostedGatewayFutureTimestamp(identity: futureIdentity)
            return false
        }
        let projection = CodexGatewayCacheProjection.load(
            persistence: nativeCachePersistence ?? Self.parsedEventCachePersistence,
            identity: context.identity, files: files
        )
        let bucket = FutureTimestampFoldBucket<Event>()
        let complete = await (gatewayScanner ?? Self.hostedGatewayScanner).foldItems(
            from: files, since: context.cacheSince, cacheIdentity: context.identity,
            parseFile: { url in
                if let projected = projection.read(at: url) { return projected }
                return Self.parseFileIncrementally(at: url, emitSince: context.cacheSince,
                    retentionDays: context.retentionDays)?.filter {
                    OpenCodeUsageScanner.isHostedGatewayModel($0.model)
                }
            },
            visit: { event in
                guard event.timestamp >= context.requestedSince else { return }
                guard Self.hasTokenUsage(event) else { return }
                bucket.observe(timestamp: event.timestamp, maximumTimestamp: maximumTimestamp)
                guard event.timestamp <= maximumTimestamp else { return }
                visit(event)
            },
            fileStarted: { bucket.begin($0) },
            fileCompleted: { path, _ in bucket.finish(path) }
        )
        guard complete else { return false }
        for (path, timestamp) in bucket.futureTimestamps {
            guard let file = files.first(where: { $0.path == path }),
                  FutureTimestampRevisionGate.record(timestamp, identity: futureIdentity, file: file)
            else { return false }
        }
        guard bucket.futureTimestamps.isEmpty else {
            Self.logHostedGatewayFutureTimestamp(identity: futureIdentity)
            return false
        }
        DiagnosticGate.clearFailure(Self.futureTimestampDiagnosticKey(for: futureIdentity))
        return true
    }

    private static func logHostedGatewayFutureTimestamp(identity: String) {
        DiagnosticGate.logOnce(for: futureTimestampDiagnosticKey(for: identity)) {
            AppLog.warn(LogTag.plugin("codex"), "gateway session usage contains a timestamp more than five minutes ahead; preserving last-good history")
        }
    }

    private static func hasTokenUsage(_ event: Event) -> Bool {
        event.total > 0 || event.input > 0 || event.cached > 0 || event.output > 0 || event.reasoning > 0
    }

    private struct ScanContext: Sendable {
        var requestedSince: Date
        var cacheSince: Date
        var retentionDays: Int
        var identity: String
    }

    private static func scanContext(homes: [URL], daysBack: Int, now: Date) -> ScanContext {
        let retentionDays = max(minimumCacheRetentionDays, daysBack)
        let requestedSince = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let cacheSince = JSONLScanning.sinceDate(daysBack: retentionDays, now: now)
        let identityPaths = Set(homes.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
            .sorted()
        let roots = identityPaths.isEmpty ? "no-codex-home" : identityPaths.joined(separator: "\n")
        return ScanContext(
            requestedSince: requestedSince,
            cacheSince: cacheSince,
            retentionDays: retentionDays,
            identity: "\(roots)\nretention-days=\(retentionDays)"
        )
    }

    private static func tailKey(for url: URL, retentionDays: Int) -> String {
        "\(url.resolvingSymlinksInPath().standardizedFileURL.path)\nretention-days=\(retentionDays)"
    }

    static func incrementalReadStatisticsForTesting(
        path: String,
        retentionDays: Int = minimumCacheRetentionDays
    ) -> IncrementalReadStatistics? {
        let key = tailKey(for: URL(fileURLWithPath: path), retentionDays: retentionDays)
        guard let stats = sharedTailCache.statistics(for: key) else { return nil }
        return IncrementalReadStatistics(
            fullParses: stats.fullParses,
            tailParses: stats.tailParses,
            bytesRead: stats.bytesRead
        )
    }

    static func tailCheckpointCountForTesting() -> Int {
        sharedTailCache.entryCountForTesting()
    }

    static func clearSharedTailCacheForTesting(path: String) {
        sharedTailCache.remove(tailKey(for: URL(fileURLWithPath: path), retentionDays: minimumCacheRetentionDays))
    }

    /// Exposes the scanner's resolved CODEX_HOME list for multi-account wiring tests.
    func discoveredHomesForTesting() -> [URL] {
        Self.discoverCodexHomes(environment: environment, homeDirectory: homeDirectory)
    }

    /// Exposes peer homes used for hardlink attribution for multi-account wiring tests.
    func peerHomesForTesting() -> [URL] {
        peerHomes
    }

    // MARK: - Discovery

    /// Device+inode identity used to detect hardlinked Codex rollouts across homes.
    struct FileIdentity: Hashable, Sendable {
        var device: UInt64
        var inode: UInt64
    }

    static func discoverCodexHomes(
        environment: EnvironmentReading = QuotaBarEnvironmentReader(),
        homeDirectory: @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) -> [URL] {
        if let raw = environment.value(for: "CODEX_HOME")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { URL(fileURLWithPath: expandHome($0)) }
        }
        return [homeDirectory().appendingPathComponent(".codex")]
    }

    private func codexHomes() -> [URL] {
        Self.discoverCodexHomes(environment: environment, homeDirectory: homeDirectory)
    }

    /// Enumerate Codex session rollouts under `homes`.
    ///
    /// - Parameters:
    ///   - homes: Codex homes to scan (`CODEX_HOME` values / logHomes).
    ///   - peerHomes: Other account homes whose hardlinked copies should not be priced when
    ///     enumerating a non-default / managed home (Orca backfilled from `~/.codex`).
    ///   - homeDirectory: User home used to identify the default `~/.codex` path.
    ///   - peerInodeDiscovery: Optional test seam for simulating a complete or incomplete peer walk.
    ///
    /// Attribution rules:
    /// 1. Collect `(st_dev, st_ino)` for every `*.jsonl` under each peer home's `sessions/` and
    ///    `archived_sessions/`.
    /// 2. When enumerating a non-default / managed home, skip any file whose inode appears in that
    ///    peer set (shared hardlinks stay attributed to default `~/.codex`).
    /// 3. Default `~/.codex` does not skip peer hardlinks — it keeps shared inodes.
    /// 4. Across all homes in one call, dedupe by inode and by Codex rollout filename. Orca's
    ///    backfill can copy a rollout instead of hard-linking it, so the copied files have different
    ///    inodes but the same globally unique `rollout-<id>.jsonl` name. Default homes are processed
    ///    first so the kept path is `~/.codex` when both are present.
    static func sessionFiles(
        homes: [URL],
        peerHomes: [URL] = [],
        homeDirectory: @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) -> [JSONLScanning.DiscoveredFile] {
        sessionFilesIfComplete(homes: homes, peerHomes: peerHomes, homeDirectory: homeDirectory) ?? []
    }

    /// `nil` means a present Codex session root could not be fully enumerated. A caller must keep
    /// its last-good history rather than publishing whichever other roots happened to be readable.
    static func sessionFilesIfComplete(
        homes: [URL],
        peerHomes: [URL] = [],
        homeDirectory: @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        peerInodeDiscovery: (@Sendable (URL) -> Set<FileIdentity>?)? = nil
    ) -> [JSONLScanning.DiscoveredFile]? {
        guard !Task.isCancelled else { return nil }
        let defaultCodexPath = homeDirectory()
            .appendingPathComponent(".codex")
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        var nonDefaultHomes: [URL] = []
        var defaultHomes: [URL] = []
        for home in homes {
            guard !Task.isCancelled else { return nil }
            if isDefaultCodexHome(home, defaultCodexPath: defaultCodexPath) {
                defaultHomes.append(home)
            } else {
                nonDefaultHomes.append(home)
            }
        }
        // The default ~/.codex card keeps shared hardlinks and never needs peer inode discovery.
        // For a managed card, every known peer home is supplied by CodexProvider, even when its card
        // is disabled. This pass reads file identities only (not rollout contents), preserving source
        // attribution without refreshing or folding the disabled account.
        let peerInodes: Set<FileIdentity>
        if nonDefaultHomes.isEmpty {
            peerInodes = []
        } else {
            let discovery = peerInodeDiscovery ?? { home in Self.collectSessionInodesUncached(under: home) }
            guard let collectedPeerInodes = collectSessionInodes(under: peerHomes, discoverHome: discovery) else {
                return nil
            }
            peerInodes = collectedPeerInodes
        }
        // Prefer default ~/.codex when the same inode appears under both a peer managed home and ~/.codex.
        let orderedHomes = defaultHomes + nonDefaultHomes

        var files: [JSONLScanning.DiscoveredFile] = []
        var seenDirs: Set<String> = []
        var seenInodes: Set<FileIdentity> = []
        var seenRolloutNames: Set<String> = []
        for home in orderedHomes {
            guard !Task.isCancelled else { return nil }
            // Managed/non-default homes skip inodes that already exist under peer ~/.codex.
            // Default keeps shared hardlinks (Orca backfilled FROM system root INTO managed home).
            let skipPeerHardlinks = !isDefaultCodexHome(home, defaultCodexPath: defaultCodexPath)
                && !peerInodes.isEmpty
            var seenRelative: Set<String> = []
            var sourceDirs: [URL] = []
            for name in ["sessions", "archived_sessions"] {
                let dir = home.appendingPathComponent(name).resolvingSymlinksInPath()
                let attributes: [FileAttributeKey: Any]
                do {
                    attributes = try FileManager.default.attributesOfItem(atPath: dir.path)
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                    continue
                } catch {
                    return nil
                }
                guard attributes[.type] as? FileAttributeType == .typeDirectory else { return nil }
                sourceDirs.append(dir)
            }
            // CodexRouter chatgpt-accounts homes often have auth + plugins but no session rollouts.
            // Falling back to the whole CODEX_HOME walked plugins/ (tens of thousands of files) for
            // zero *.jsonl and risked mis-attributing any future non-session JSONL under the home.
            if sourceDirs.isEmpty {
                continue
            }
            for dir in sourceDirs.map({ $0.resolvingSymlinksInPath() }) where seenDirs.insert(dir.path).inserted {
                guard !Task.isCancelled,
                      let discovered = JSONLScanning.jsonlFilesIfComplete(under: dir)
                else { return nil }
                for file in discovered {
                    guard !Task.isCancelled else { return nil }
                    let relative = String(file.path.dropFirst(dir.path.count))
                    guard seenRelative.insert(relative).inserted else { continue }
                    let fileURL = URL(fileURLWithPath: file.path)
                    // Rollout IDs are globally unique. This catches copied backfills whose inode
                    // differs from the canonical file, while leaving generic fixture names and any
                    // future non-rollout JSONL sources untouched.
                    let rolloutName = fileURL.lastPathComponent
                    if rolloutName.hasPrefix("rollout-"), !seenRolloutNames.insert(rolloutName).inserted {
                        continue
                    }
                    guard let identity = fileIdentity(at: fileURL) else { return nil }
                    if skipPeerHardlinks, peerInodes.contains(identity) {
                        continue
                    }
                    guard seenInodes.insert(identity).inserted else { continue }
                    files.append(file)
                }
            }
        }
        return files
    }

    private static func isDefaultCodexHome(_ home: URL, defaultCodexPath: String) -> Bool {
        home.resolvingSymlinksInPath().standardizedFileURL.path == defaultCodexPath
    }


    /// Process-local cache of peer-home inode sets keyed by standardized home path + session-dir mtime.
    /// Avoids rebuilding large `(dev,ino)` sets on every card/fold scan within a refresh window.
    private final class SessionInodeSetCache: @unchecked Sendable {
        static let shared = SessionInodeSetCache()

        /// How long a computed set is reused regardless of the directory signature.
        ///
        /// The signature is a top-level `sessions/` mtime, which cannot see a new rollout: Codex writes
        /// `sessions/YYYY/MM/DD/`, so adding a file bumps only the deepest parent's mtime. The signature
        /// was therefore constant for the process's whole life, and every rollout created after the first
        /// scan was missing from the peer set — meaning the *same file* was skipped on neither card and
        /// got priced on both. That put one account's usage on another account's card and double-counted
        /// it in Total Spend. Verified against a replica: the shared rollout appeared on both cards.
        ///
        /// A time bound is the honest fix. The cache exists to avoid rebuilding the set for every card
        /// *within* one refresh window, not across windows, so a minute of reuse costs nothing and caps
        /// how long a new file can go unseen.
        private static let maxAge: TimeInterval = 60

        private let lock = NSLock()
        private var entries: [String: (signature: String, storedAt: TimeInterval, inodes: Set<FileIdentity>)] = [:]

        func lookupOrCompute(
            key: String,
            signature: String,
            shouldCache: () -> Bool,
            compute: () -> Set<FileIdentity>?
        ) -> Set<FileIdentity>? {
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            if let entry = entries[key],
               entry.signature == signature,
               now - entry.storedAt < Self.maxAge {
                let hit = entry.inodes
                lock.unlock()
                return hit
            }
            lock.unlock()
            guard let inodes = compute() else { return nil }
            // An incomplete or cancelled traversal never becomes an authoritative cache entry.
            guard shouldCache() else { return inodes }
            lock.lock()
            guard shouldCache() else {
                lock.unlock()
                return inodes
            }
            entries[key] = (signature, now, inodes)
            lock.unlock()
            return inodes
        }

        /// Test seam: drops every memoized set. Production has no reason to, since `maxAge` bounds
        /// staleness on its own.
        func reset() {
            lock.lock()
            entries.removeAll()
            lock.unlock()
        }
    }

    /// `(st_dev, st_ino)` for every `*.jsonl` under each home's `sessions/` and `archived_sessions/`.
    /// Lightweight enumerator only — no `DiscoveredFile` / mtime arrays (those were ~11GB-path peak RSS
    /// amplifiers when peer homes held hundreds of hardlinked rollouts).
    private static func collectSessionInodes(
        under homes: [URL],
        discoverHome: @Sendable (URL) -> Set<FileIdentity>?
    ) -> Set<FileIdentity>? {
        var result: Set<FileIdentity> = []
        for home in homes {
            guard !Task.isCancelled else { return nil }
            let key = home.resolvingSymlinksInPath().standardizedFileURL.path
            guard let signature = sessionDirectorySignature(for: home),
                  let inodes = SessionInodeSetCache.shared.lookupOrCompute(
                    key: key,
                    signature: signature,
                    shouldCache: { !Task.isCancelled },
                    compute: { discoverHome(home) }
                  )
            else { return nil }
            result.formUnion(inodes)
        }
        return result
    }

    /// Directory mtime signature for the refresh-lifetime inode cache. Nested file adds may not bump
    /// the top-level dir mtime on every FS; unique per-test paths keep hermetic tests correct.
    private static func sessionDirectorySignature(for home: URL) -> String? {
        var parts: [String] = []
        for name in ["sessions", "archived_sessions"] {
            let dir = home.appendingPathComponent(name).resolvingSymlinksInPath()
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: dir.path)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                parts.append("\(name)=missing")
                continue
            } catch {
                return nil
            }
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  let mtime = attributes[.modificationDate] as? Date
            else { return nil }
            parts.append("\(name)=\(mtime.timeIntervalSince1970)")
        }
        return parts.joined(separator: ";")
    }

    private static func collectSessionInodesUncached(under home: URL) -> Set<FileIdentity>? {
        var result: Set<FileIdentity> = []
        for name in ["sessions", "archived_sessions"] {
            guard !Task.isCancelled else { return nil }
            let dir = home.appendingPathComponent(name).resolvingSymlinksInPath()
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: dir.path)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                continue
            } catch {
                return nil
            }
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { return nil }
            var enumerationFailed = false
            guard let enumerator = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [],
                errorHandler: { _, _ in
                    enumerationFailed = true
                    return false
                }
            ) else { return nil }
            for case let url as URL in enumerator {
                guard !Task.isCancelled else { return nil }
                guard url.pathExtension == "jsonl" else { continue }
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else { return nil }
                guard values.isRegularFile == true else { continue }
                guard let identity = fileIdentity(at: url) else { return nil }
                result.insert(identity)
            }
            guard !enumerationFailed else { return nil }
        }
        return result
    }

    static func fileIdentity(at url: URL) -> FileIdentity? {
        // Reuse AppendOnlyFileProbe's resolve+lstat path so hardlinks share identity with the probe.
        guard let revision = AppendOnlyFileProbe.revision(at: url) else { return nil }
        return FileIdentity(device: revision.device, inode: revision.inode)
    }

    // MARK: - File parsing

    /// Fixture/compatibility parser: parse exactly the supplied bytes and preserve final-line semantics.
    static func parseFile(_ data: Data) -> [Event] {
        var parser = FileParser()
        for line in data.split(separator: UInt8(ascii: "\n")) {
            parser.consume(line)
        }
        return parser.finish()
    }

    /// Full compatibility path used by tests/other callers. Production cache refreshes use the
    /// checkpoint-aware variant below.
    nonisolated static func parseFile(at url: URL) -> [Event]? {
        var parser = FileParser()
        let readSucceeded = JSONLFileReader.forEachLine(at: url) { line in
            parser.consume(line)
        }
        guard readSucceeded, !parser.hasMalformedUsage else { return nil }
        return parser.finish()
    }

    /// Read only bytes after the prior EOF when the file still proves to be an append of the same
    /// prefix. Otherwise perform the safe full streaming parse and replace the checkpoint.
    nonisolated private static func parseFileIncrementally(
        at url: URL,
        emitSince: Date,
        retentionDays: Int
    ) -> [Event]? {
        let key = tailKey(for: url, retentionDays: retentionDays)
        let currentStamp = AppendOnlyFileProbe.stamp(at: url)

        if let currentStamp,
           let cached = sharedTailCache.entry(for: key),
           cached.modificationTimes == currentStamp.modificationTimes,
           currentStamp.revision.device == cached.revision.device,
           currentStamp.revision.inode == cached.revision.inode,
           currentStamp.revision.size == cached.offset,
           AppendOnlyFileProbe.anchor(at: url, endingAt: cached.offset) == cached.anchor
        {
            // Exact revision match: IncrementalJSONLScanner may re-invoke parse after unloading
            // resident items; return the tail-cache copy without rereading the file.
            // itemsAvailable=false means a prior refresh unloaded Event arrays — fall through to a
            // full parse rather than treating the empty array as authoritative.
            if cached.itemsAvailable {
                return cached.items.filter { $0.timestamp >= emitSince }
            }
        }

        if let currentStamp,
           let cached = sharedTailCache.entry(for: key),
           cached.itemsAvailable,
           currentStamp.revision.device == cached.revision.device,
           currentStamp.revision.inode == cached.revision.inode,
           currentStamp.revision.size > cached.offset,
           AppendOnlyFileProbe.anchor(at: url, endingAt: cached.offset) == cached.anchor
        {
            var parser = FileParser(emitSince: emitSince, checkpoint: cached.parserState)
            var read = JSONLFileReader.readLines(
                at: url,
                chunkSize: 64 * 1024,
                startOffset: cached.offset,
                initialCarry: cached.partialLine,
                discardingOversizedLine: cached.isDiscardingOversizedLine,
                deliverFinalPartial: false
            ) { line in
                parser.consume(line)
            }
            guard read.isComplete else { return nil }
            guard !parser.hasMalformedUsage else { return nil }

            // A same-inode historical rewrite can race after the pre-read anchor check while we are
            // consuming the tail. Re-prove the exact old checkpoint prefix before accepting any parser
            // state derived from it; a mismatch discards this speculative tail and performs one full parse.
            guard AppendOnlyFileProbe.anchor(at: url, endingAt: cached.offset) == cached.anchor else {
                return fullParseAndCheckpoint(
                    at: url,
                    emitSince: emitSince,
                    retentionDays: retentionDays,
                    key: key
                )
            }

            consumeCompleteFinalJSONIfPossible(&read, parser: &parser)
            guard !parser.hasMalformedUsage else { return nil }

            let newOffset = cached.offset + UInt64(read.statistics.bytesRead)
            if let after = AppendOnlyFileProbe.stamp(at: url),
               after.modificationTimes == currentStamp.modificationTimes,
               after.revision.device == currentStamp.revision.device,
               after.revision.inode == currentStamp.revision.inode,
               after.revision.size >= newOffset,
               let anchor = AppendOnlyFileProbe.anchor(at: url, endingAt: newOffset)
            {
                var merged = cached.items.filter { $0.timestamp >= emitSince }
                merged.append(contentsOf: parser.finish())
                sharedTailCache.store(
                    AppendOnlyFileTailCache<Event, ParserCheckpoint>.Entry(
                        revision: after.revision,
                        modificationTimes: after.modificationTimes,
                        offset: newOffset,
                        anchor: anchor,
                        partialLine: read.finalPartial,
                        isDiscardingOversizedLine: read.isDiscardingOversizedLine,
                        parserState: parser.checkpoint(),
                        items: merged
                    ),
                    for: key,
                    parseKind: .tail,
                    bytesRead: read.statistics.bytesRead
                )
                return merged
            }
            // File identity changed while the handle was open. The bytes we read are not a checkpoint
            // we can safely continue from; fall through to one authoritative full parse.
        }

        return fullParseAndCheckpoint(at: url, emitSince: emitSince, retentionDays: retentionDays, key: key)
    }

    nonisolated private static func fullParseAndCheckpoint(
        at url: URL,
        emitSince: Date,
        retentionDays: Int,
        key: String
    ) -> [Event]? {
        _ = retentionDays
        let before = AppendOnlyFileProbe.stamp(at: url)
        var parser = FileParser(emitSince: emitSince)
        var read = JSONLFileReader.readLines(
            at: url,
            chunkSize: 64 * 1024,
            deliverFinalPartial: false
        ) { line in
            parser.consume(line)
        }
        guard read.isComplete else {
            sharedTailCache.remove(key)
            return nil
        }
        consumeCompleteFinalJSONIfPossible(&read, parser: &parser)
        guard !parser.hasMalformedUsage else {
            sharedTailCache.remove(key)
            return nil
        }
        let events = parser.finish()
        let offset = UInt64(read.statistics.bytesRead)

        if let before,
           let after = AppendOnlyFileProbe.stamp(at: url),
           (before.revision.size != after.revision.size || before.modificationTimes == after.modificationTimes),
           before.revision.device == after.revision.device,
           before.revision.inode == after.revision.inode,
           after.revision.size >= offset,
           let anchor = AppendOnlyFileProbe.anchor(at: url, endingAt: offset)
        {
            sharedTailCache.store(
                AppendOnlyFileTailCache<Event, ParserCheckpoint>.Entry(
                    revision: after.revision,
                    modificationTimes: after.modificationTimes,
                    offset: offset,
                    anchor: anchor,
                    partialLine: read.finalPartial,
                    isDiscardingOversizedLine: read.isDiscardingOversizedLine,
                    parserState: parser.checkpoint(),
                    items: events
                ),
                for: key,
                parseKind: .full,
                bytesRead: read.statistics.bytesRead
            )
        } else {
            sharedTailCache.remove(key)
        }
        return events
    }

    /// JSONL permits a complete final record without a newline. Keep an invalid final fragment as
    /// append carry, but consume a syntactically complete JSON object immediately so metrics do not
    /// lag one turn merely because the writer omitted the trailing newline.
    nonisolated private static func consumeCompleteFinalJSONIfPossible(
        _ read: inout JSONLFileReader.ReadResult,
        parser: inout FileParser
    ) {
        guard !read.isDiscardingOversizedLine,
              !read.finalPartial.isEmpty,
              (try? JSONSerialization.jsonObject(with: read.finalPartial)) != nil
        else { return }
        parser.consume(read.finalPartial[...])
        read.finalPartial.removeAll(keepingCapacity: false)
    }

    private struct FileParser {
        private let turnContextMarker = Data(#""type":"turn_context""#.utf8)
        private let tokenCountMarker = Data(#""type":"token_count""#.utf8)
        private let sessionMetaMarker = Data(#""type":"session_meta""#.utf8)
        private let taskStartedMarker = Data(#""type":"task_started""#.utf8)
        private let threadSettingsMarker = Data(#""type":"thread_settings_applied""#.utf8)

        private var events: [Event] = []
        private var previousTotals: RawUsage?
        private var currentModel: String?
        private var currentTierIsFast = false
        private var currentServiceTier: String?
        private var currentServiceTierIsValid = true
        private var sawSessionMeta = false
        private var replayGate: ChildReplayGate?
        private let emitSince: Date?
        var hasMalformedUsage = false

        init(emitSince: Date? = nil, checkpoint: ParserCheckpoint? = nil) {
            self.emitSince = emitSince
            if let checkpoint {
                self.previousTotals = checkpoint.previousTotals
                self.currentModel = checkpoint.currentModel
                self.currentTierIsFast = checkpoint.currentTierIsFast
                self.currentServiceTier = checkpoint.currentServiceTier
                self.currentServiceTierIsValid = checkpoint.currentServiceTierIsValid
                self.sawSessionMeta = checkpoint.sawSessionMeta
                self.replayGate = checkpoint.replayGate
            }
        }

        mutating func consume(_ line: Data.SubSequence) {
            let isTurnContext = line.range(of: turnContextMarker) != nil
            let isSessionMeta = !sawSessionMeta && line.range(of: sessionMetaMarker) != nil
            let isTaskStarted = replayGate != nil && line.range(of: taskStartedMarker) != nil
            let isThreadSettings = line.range(of: threadSettingsMarker) != nil
            guard isTurnContext || isSessionMeta || isTaskStarted || isThreadSettings
                || line.range(of: tokenCountMarker) != nil
            else { return }
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                if line.range(of: tokenCountMarker) != nil { hasMalformedUsage = true }
                return
            }

            let type = object["type"] as? String
            let payload = object["payload"] as? [String: Any]

            if type == "turn_context" {
                guard let payload else {
                    hasMalformedUsage = true
                    currentModel = nil
                    return
                }
                let modelUpdate = CodexLogUsageScanner.modelNameUpdate(in: payload)
                if case .invalid = modelUpdate {
                    hasMalformedUsage = true
                    currentModel = nil
                    return
                }
                if case .value(let model) = modelUpdate {
                    currentModel = model
                }
                return
            }
            if type == "session_meta", !sawSessionMeta {
                sawSessionMeta = true
                if let payload, CodexLogUsageScanner.isChildSessionMeta(payload) {
                    if let timestampRaw = (object["timestamp"] as? String)?.trimmingCharacters(in: .whitespaces),
                       let created = OpenUsageISO8601.date(from: timestampRaw) {
                        replayGate = .untilStartedAt(created.timeIntervalSince1970.rounded(.down))
                    } else {
                        replayGate = .untilSelfTimedTaskStarted
                    }
                }
                return
            }
            if isThreadSettings, type == "event_msg",
               payload?["type"] as? String == "thread_settings_applied" {
                if let update = CodexLogUsageScanner.serviceTierUpdate(in: payload) {
                    currentServiceTierIsValid = update.isValid
                    currentServiceTier = update.isValid ? update.tier : nil
                    currentTierIsFast = update.isValid
                        && (currentServiceTier == "fast" || currentServiceTier == "priority")
                }
                return
            }
            guard type == "event_msg", let payload else {
                if line.range(of: tokenCountMarker) != nil { hasMalformedUsage = true }
                return
            }

            if payload["type"] as? String == "task_started" {
                if let gate = replayGate,
                   let startedAt = payload["started_at"] as? NSNumber,
                   gate.isCleared(byStartedAt: startedAt.doubleValue, lineTimestamp: object["timestamp"] as? String) {
                    replayGate = nil
                }
                return
            }
            guard payload["type"] as? String == "token_count" else {
                if line.range(of: tokenCountMarker) != nil { hasMalformedUsage = true }
                return
            }
            guard let timestampRaw = (object["timestamp"] as? String)?.trimmingCharacters(in: .whitespaces),
                  let timestamp = OpenUsageISO8601.date(from: timestampRaw)
            else {
                hasMalformedUsage = true
                return
            }

            guard let rawInfo = payload["info"],
                  let info = rawInfo as? [String: Any]
            else {
                hasMalformedUsage = true
                return
            }
            let totals: RawUsage?
            if let rawTotals = info["total_token_usage"], !(rawTotals is NSNull) {
                guard let totalsObject = rawTotals as? [String: Any] else {
                    hasMalformedUsage = true
                    return
                }
                let parsedTotals = RawUsage(json: totalsObject)
                guard parsedTotals.isValid else {
                    hasMalformedUsage = true
                    return
                }
                totals = parsedTotals
            } else {
                totals = nil
            }

            if replayGate != nil {
                if let totals {
                    previousTotals = totals
                } else if let rawLast = info["last_token_usage"], !(rawLast is NSNull) {
                    guard let lastObject = rawLast as? [String: Any] else {
                        hasMalformedUsage = true
                        return
                    }
                    let last = RawUsage(json: lastObject)
                    guard last.isValid else {
                        hasMalformedUsage = true
                        return
                    }
                    previousTotals = previousTotals?.addingAsBaseline(last) ?? last.asBaseline()
                }
                return
            }
            if let totals, let previous = previousTotals, totals.equalCounts(previous) {
                return
            }

            let usage: RawUsage
            if let rawLast = info["last_token_usage"], !(rawLast is NSNull) {
                guard let lastObject = rawLast as? [String: Any] else {
                    hasMalformedUsage = true
                    return
                }
                let last = RawUsage(json: lastObject)
                guard last.isValid else {
                    hasMalformedUsage = true
                    return
                }
                usage = last
                if totals == nil {
                    previousTotals = previousTotals?.addingAsBaseline(last) ?? last.asBaseline()
                }
            } else if let totals {
                usage = totals.subtracting(previousTotals)
            } else {
                hasMalformedUsage = true
                return
            }
            guard usage.isValid else {
                hasMalformedUsage = true
                return
            }
            if let totals { previousTotals = totals }
            guard usage.input > 0 || usage.cached > 0 || usage.output > 0 || usage.reasoning > 0
                    || usage.total > 0
            else { return }

            let parsedModel: String?
            switch CodexLogUsageScanner.modelNameUpdate(in: payload) {
            case .value(let model):
                parsedModel = model
            case .invalid:
                hasMalformedUsage = true
                return
            case .absent:
                switch CodexLogUsageScanner.modelNameUpdate(in: info) {
                case .value(let model): parsedModel = model
                case .invalid:
                    hasMalformedUsage = true
                    return
                case .absent: parsedModel = nil
                }
            }
            let model = CodexLogUsageScanner.resolveModel(parsed: parsedModel, currentModel: &currentModel)
            let event = Event(
                timestamp: timestamp,
                model: model,
                pricingModel: model == CodexLogUsageScanner.autoReviewModel
                    || model == CodexLogUsageScanner.reserveModel
                    ? CodexLogUsageScanner.autoReviewFallback(at: timestampRaw)
                    : nil,
                input: usage.input,
                cached: usage.cached,
                output: usage.output,
                reasoning: usage.reasoning,
                total: usage.total,
                hasCompleteCostBreakdown: usage.hasCompleteCostBreakdown && currentServiceTierIsValid,
                isFast: currentTierIsFast,
                serviceTier: currentServiceTier
            )
            if emitSince == nil || timestamp >= emitSince! {
                events.append(event)
            }
        }

        func finish() -> [Event] {
            events
        }

        func checkpoint() -> ParserCheckpoint {
            ParserCheckpoint(
                previousTotals: previousTotals,
                currentModel: currentModel,
                currentTierIsFast: currentTierIsFast,
                currentServiceTier: currentServiceTier,
                currentServiceTierIsValid: currentServiceTierIsValid,
                sawSessionMeta: sawSessionMeta,
                replayGate: replayGate
            )
        }
    }

    private struct ServiceTierUpdate {
        var tier: String?
        var isValid: Bool
    }

    private static func serviceTierUpdate(in payload: [String: Any]?) -> ServiceTierUpdate? {
        guard let payload else { return nil }
        if let rawSettings = payload["thread_settings"] {
            guard let settings = rawSettings as? [String: Any] else {
                return ServiceTierUpdate(tier: nil, isValid: false)
            }
            if let rawTier = settings["service_tier"] {
                return parsedServiceTier(rawTier)
            }
        }
        if let rawTier = payload["service_tier"] {
            return parsedServiceTier(rawTier)
        }
        return nil
    }

    private static func parsedServiceTier(_ raw: Any) -> ServiceTierUpdate {
        guard let text = raw as? String else {
            return ServiceTierUpdate(tier: nil, isValid: false)
        }
        let tier = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let known: Set<String> = [
            "auto", "default", "standard", "priority", "fast", "flex", "batch", "ultrafast"
        ]
        guard !tier.isEmpty, known.contains(tier) else {
            return ServiceTierUpdate(tier: tier.nilIfEmpty, isValid: false)
        }
        return ServiceTierUpdate(tier: tier, isValid: true)
    }

    private enum ModelNameUpdate {
        case absent
        case value(String)
        case invalid
    }

    private static func modelNameUpdate(in json: [String: Any]) -> ModelNameUpdate {
        let values: [Any?] = [
            json["model"],
            json["model_name"],
            (json["metadata"] as? [String: Any])?["model"]
        ]
        for value in values {
            guard let value else { continue }
            guard let text = value as? String else { return .invalid }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            return .value(trimmed)
        }
        return .absent
    }

    static func isChildSessionMeta(_ payload: [String: Any]) -> Bool {
        if hasNonNullValue(payload["forked_from_id"]) { return true }
        if hasNonNullValue(payload["parent_thread_id"]) { return true }
        if payload["thread_source"] as? String == "subagent" { return true }
        if let source = payload["source"] as? [String: Any], hasNonNullValue(source["subagent"]) {
            return true
        }
        return false
    }

    private static func hasNonNullValue(_ value: Any?) -> Bool {
        switch value {
        case nil, is NSNull:
            return false
        case let text as String:
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return true
        }
    }

    static func resolveModel(parsed: String?, currentModel: inout String?) -> String {
        if let parsed {
            currentModel = parsed
        }
        var model: String
        if let parsed {
            model = parsed
        } else if let current = currentModel {
            model = current
        } else {
            currentModel = "gpt-5"
            model = "gpt-5"
        }
        return model
    }

    private static let autoReviewModel = "codex-auto-review"
    /// Visible slug for Codex Luna Reserve turns; cost uses `autoReviewFallback` (current Luna).
    static let reserveModel = "gpt-reserve"

    private static let autoReviewFallbacks: [(releasedOn: String, model: String)] = [
        ("2026-09-22", "gpt-6-luna"),
        ("2026-07-09", "gpt-5.6-luna"),
        ("2026-04-23", "gpt-5.5"),
        ("2026-03-05", "gpt-5.4"),
        ("2026-02-05", "gpt-5.3-codex"),
        ("2025-12-11", "gpt-5.2-codex"),
        ("2025-11-13", "gpt-5.1-codex"),
        ("2025-09-15", "gpt-5-codex"),
        ("2025-08-07", "gpt-5")
    ]

    static func autoReviewFallback(at timestamp: String) -> String {
        let date = String(timestamp.prefix(10))
        guard date.count == 10,
              date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
        else { return "gpt-5" }
        return autoReviewFallbacks.first(where: { date >= $0.releasedOn })?.model ?? "gpt-5"
    }

    /// When a visible slug is auto-review / gpt-reserve (or a dated alias of those), return the
    /// dated Luna-family pricing key so token rows still price instead of dropping into unknown.
    /// Returns nil for ordinary model names so callers do not invent fallbacks for mystery slugs.
    static func pricingFallbackModel(for model: String, at timestamp: String) -> String? {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        let normalized = bare.lowercased()
        guard normalized == autoReviewModel
            || normalized == reserveModel
            || normalized.hasPrefix("gpt-reserve")
            || normalized == "codex-auto-review"
            || normalized.hasSuffix("-reserve")
        else { return nil }
        return autoReviewFallback(at: timestamp)
    }

    // MARK: - Aggregation

    /// Escaping fold visits cannot capture `inout` Sets/accumulators; this tiny box owns them.
    private final class AggregateFoldState: @unchecked Sendable {
        var seen: Set<EventKey> = []
        var accumulator = DailyUsageAccumulator()
    }

    private struct EventKey: Hashable {
        var timestamp: Date
        var model: String
        var pricingModel: String?
        var input: Int
        var cached: Int
        var output: Int
        var reasoning: Int
        var total: Int
        var hasCompleteCostBreakdown: Bool
        var isFast: Bool
        var serviceTier: String?
    }

    private static func accumulate(
        event: Event,
        since: Date,
        pricing: ModelPricing,
        seen: inout Set<EventKey>,
        accumulator: inout DailyUsageAccumulator
    ) {
        guard event.timestamp >= since else { return }
        let key = EventKey(
            timestamp: event.timestamp,
            model: event.model,
            pricingModel: event.pricingModel,
            input: event.input,
            cached: event.cached,
            output: event.output,
            reasoning: event.reasoning,
            total: event.total,
            hasCompleteCostBreakdown: event.hasCompleteCostBreakdown,
            isFast: event.isFast,
            serviceTier: event.serviceTier
        )
        guard seen.insert(key).inserted else { return }

        let day = DailyUsageAccumulator.dayKey(from: event.timestamp)
        // An empty model is not a reason to drop the row's tokens: count them under the shared
        // Unattributed name (same convention as the Claude scanner). The pricing lookup then misses
        // and the day's warning triangle carries "Unattributed", so the loss is visible instead of
        // silently vanishing from every total.
        let model = event.model.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? ModelUsageEntry.unattributedModelName
        // OpenCode Go/Zen gateway turns are folded into the OpenCode card; counting them here
        // double-counts the same dollars/tokens in Total Spend.
        if OpenCodeUsageScanner.isHostedGatewayModel(model) { return }
        let pricingModel = event.pricingModel ?? model
        let canonicalModel = pricing.canonicalName(for: pricingModel) ?? pricingModel
        let isFastAlias = canonicalModel.hasSuffix("-fast")
        let rateModel = isFastAlias ? String(canonicalModel.dropLast("-fast".count)) : canonicalModel
        let baseRates = pricing.resolve(model: rateModel)
        let resolvedRates = baseRates ?? pricing.resolve(model: pricingModel)
        // Public-API-rate comparison: the same tokens at the catalog rates, without the router's
        // priority/fast-tier adjustments. Unrevealed codenames contribute nothing.
        let apiEstimate = event.hasCompleteCostBreakdown ? resolvedRates.map { rates in
            rates.costDollars(for: TokenBreakdown(
                input: max(0, event.input - event.cached),
                cacheRead: event.cached,
                output: event.output
            ))
        } : nil
        accumulator.recordApiEstimate(
            day: day,
            cost: event.hasCompleteCostBreakdown ? apiEstimate : nil,
            tokens: event.total
        )
        guard let rates = resolvedRates else {
            if event.total > 0 {
                accumulator.addUnknownModel(day: day, model: model)
            }
            // Count the tokens with a dashed cost so an unrevealed codename stays visible.
            accumulator.add(
                day: day,
                tokens: event.total,
                cost: nil,
                model: model,
                canonical: GatewaySlug.identity(of: model, resolvedPricingModel: rateModel)
            )
            if !event.hasCompleteCostBreakdown {
                accumulator.markCostIncomplete(
                    day: day,
                    model: model,
                    canonical: GatewaySlug.identity(of: model, resolvedPricingModel: rateModel)
                )
            }
            return
        }
        let appliesCodexFastTier = isFastAlias ? baseRates != nil : event.isFast
        let serviceTierMultiplier = codexServiceTierMultiplier(
            for: rateModel,
            serviceTier: event.serviceTier
        )
        let eventCost = event.hasCompleteCostBreakdown ? cost(
            rates: rates,
            event: event,
            model: rateModel,
            fastTier: serviceTierMultiplier != nil || appliesCodexFastTier,
            fastMultiplier: serviceTierMultiplier ?? codexPriorityMultiplier(for: rateModel, rates: rates)
        ) : nil
        // Key the row on the resolved model, not the emitted slug. Session logs carry gateway-prefixed
        // slugs too, so the same model can arrive both tagged and untagged; grouping on the raw slug split
        // it across rows and into the period total twice. The spelling is kept as a tooltip variant.
        accumulator.add(
            day: day,
            tokens: event.total,
            cost: eventCost,
            model: model,
            canonical: GatewaySlug.identity(of: model, resolvedPricingModel: rateModel)
        )
        if !event.hasCompleteCostBreakdown {
            accumulator.markCostIncomplete(
                day: day,
                model: model,
                canonical: GatewaySlug.identity(of: model, resolvedPricingModel: rateModel)
            )
        }
    }

    static func aggregate(events: [Event], since: Date, pricing: ModelPricing) -> LogUsageScan {
        var seen: Set<EventKey> = []
        var accumulator = DailyUsageAccumulator()
        for event in events {
            accumulate(
                event: event,
                since: since,
                pricing: pricing,
                seen: &seen,
                accumulator: &accumulator
            )
        }
        return accumulator.build()
    }

    static func cost(
        rates: ModelRates,
        event: Event,
        model: String,
        fastTier: Bool,
        fastMultiplier: Double
    ) -> Double {
        var effectiveRates = rates
        if let longContext = codexLongContextRates(for: model) {
            effectiveRates.inputAbove200kPerMillion = longContext.input
            effectiveRates.outputAbove200kPerMillion = longContext.output
            effectiveRates.cacheReadAbove200kPerMillion = longContext.cacheRead
            effectiveRates.longContextThresholdTokens = 272_000
        }
        if codexModelHasNoCacheDiscount(model) {
            effectiveRates.cacheReadPerMillion = effectiveRates.inputPerMillion
            effectiveRates.cacheReadAbove200kPerMillion = effectiveRates.inputAbove200kPerMillion
        } else if !rates.cacheReadIsExplicit {
            effectiveRates.cacheReadPerMillion = effectiveRates.inputPerMillion
            effectiveRates.cacheReadAbove200kPerMillion = effectiveRates.inputAbove200kPerMillion
        }
        effectiveRates.fastMultiplier = fastMultiplier

        let nonCached = max(0, event.input - event.cached)
        return effectiveRates.costDollars(for: TokenBreakdown(
            input: nonCached,
            cacheRead: event.cached,
            output: event.output,
            isFast: fastTier
        ))
    }

    static func codexPriorityMultiplier(for model: String, rates: ModelRates) -> Double {
        let base = datedBaseModel(model)
        switch base {
        case "gpt-5.5", "gpt-5.5-pro": return 2.5
        case "gpt-5.4", "gpt-5.4-pro",
             "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna",
             "gpt-6-sol", "gpt-6-terra", "gpt-6-luna", "gpt-6-astra": return 2
        default: return rates.fastMultiplier == 1 ? 2 : rates.fastMultiplier
        }
    }

    /// OpenAI publishes the named GPT-6.1 Sol service-tier multipliers. Keep these exact-model
    /// overrides scoped to that published schedule; unknown tiers and sibling models stay standard.
    static func codexServiceTierMultiplier(for model: String, serviceTier: String?) -> Double? {
        let base = datedBaseModel(model)
        let slug = base.split(separator: "/").last.map(String.init) ?? base
        guard slug == "gpt-6.1-sol", let serviceTier = serviceTier?.lowercased() else { return nil }
        switch serviceTier {
        case "fast", "priority": return 2
        case "flex", "batch": return 0.5
        case "ultrafast": return 6
        default: return nil
        }
    }

    private static func codexModelHasNoCacheDiscount(_ model: String) -> Bool {
        switch datedBaseModel(model) {
        case "gpt-5.4-pro", "gpt-5.5-pro": return true
        default: return false
        }
    }

    private static func codexLongContextRates(for model: String) -> (input: Double, output: Double, cacheRead: Double)? {
        // Official OpenAI long-context tiers (>272k input): 2x input/cache, 1.5x output for the
        // whole request. Keep GPT-5.6 and GPT-6 families separate — GPT-6 published Standard
        // short-context rates are about half of the transitional GPT-5.6-successor pins.
        switch datedBaseModel(model) {
        case "gpt-5.4": return (5, 22.5, 0.5)
        case "gpt-5.4-pro": return (60, 270, 60)
        case "gpt-5.5": return (10, 45, 1)
        case "gpt-5.5-pro": return (60, 270, 60)
        case "gpt-5.6-sol": return (8, 30, 0.8)
        case "gpt-5.6-terra", "gpt-6-terra": return (4, 18, 0.4)
        case "gpt-5.6-luna": return (0.4, 1.8, 0.04)
        case "gpt-6-sol": return (4, 15, 0.4)
        case "gpt-6-astra": return (20, 75, 2)
        case "gpt-6-luna": return (0.2, 0.75, 0.02)
        default: return nil
        }
    }

    private static func datedBaseModel(_ model: String) -> String {
        stripDatedSuffix(model, separated: true)
            ?? stripDatedSuffix(model, separated: false)
            ?? model
    }

    /// These helpers run several times for every priced Codex event. The suffix grammar is fixed, so
    /// checking its ASCII digits directly avoids compiling/running two regular expressions per event.
    private static func stripDatedSuffix(_ model: String, separated: Bool) -> String? {
        let bytes = model.utf8
        let suffixLength = separated ? 11 : 9
        guard bytes.count >= suffixLength else { return nil }
        let start = bytes.index(bytes.endIndex, offsetBy: -suffixLength)
        func byte(_ offset: Int) -> UInt8 {
            bytes[bytes.index(start, offsetBy: offset)]
        }
        guard byte(0) == UInt8(ascii: "-") else { return nil }

        if separated {
            for offset in 1...10 {
                if offset == 5 || offset == 8 {
                    guard byte(offset) == UInt8(ascii: "-") else { return nil }
                } else {
                    guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte(offset)) else { return nil }
                }
            }
        } else {
            for offset in 1...8 {
                guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte(offset)) else { return nil }
            }
        }

        guard let stringStart = String.Index(start, within: model) else { return nil }
        return String(model[..<stringStart])
    }
}

/// OpenCode folds enabled Codex homes one at a time to release each home's parsed tail before moving
/// on. Rollout ids are global across Codex homes, so keep first-seen names across those calls too;
/// otherwise a copied backfill with a different inode is counted once per home.
final class CodexRolloutNameDeduper: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: Set<String> = []

    func retainingFirstOccurrence(
        of files: [JSONLScanning.DiscoveredFile]
    ) -> [JSONLScanning.DiscoveredFile] {
        lock.lock()
        defer { lock.unlock() }
        return files.filter { file in
            let name = URL(fileURLWithPath: file.path).lastPathComponent
            guard name.hasPrefix("rollout-") else { return true }
            return seen.insert(name).inserted
        }
    }
}
