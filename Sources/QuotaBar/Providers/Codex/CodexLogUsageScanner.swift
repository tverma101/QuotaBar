import Foundation

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
        var isFast: Bool = false
    }

    /// Token fields of a `token_count` usage object, tolerating the older field spellings ccusage
    /// accepts (`prompt_tokens`, `completion_tokens`, `cache_read_input_tokens`, …).
    struct RawUsage: Sendable {
        var input: Int
        var cached: Int
        var output: Int
        var reasoning: Int
        var total: Int

        init(json: [String: Any]) {
            func int(_ keys: String...) -> Int? {
                for key in keys {
                    if let number = json[key] as? NSNumber { return number.intValue }
                }
                return nil
            }
            input = int("input_tokens", "prompt_tokens", "input") ?? 0
            cached = int("cached_input_tokens", "cache_read_input_tokens", "cached_tokens") ?? 0
            output = int("output_tokens", "completion_tokens", "output") ?? 0
            reasoning = int("reasoning_output_tokens", "reasoning_tokens") ?? 0
            let reported = int("total_tokens") ?? 0
            // Reasoning tokens are a subset of output on OpenAI/Codex usage; do not add them again.
            let recomputed = input + output
            total = (reported > 0 || recomputed == 0) ? reported : recomputed
        }

        private init(input: Int, cached: Int, output: Int, reasoning: Int, total: Int) {
            self.input = input
            self.cached = cached
            self.output = output
            self.reasoning = reasoning
            self.total = total
        }

        func equalCounts(_ other: RawUsage) -> Bool {
            input == other.input && cached == other.cached && output == other.output
                && reasoning == other.reasoning && total == other.total
        }

        func subtracting(_ previous: RawUsage?) -> RawUsage {
            RawUsage(
                input: max(0, input - (previous?.input ?? 0)),
                cached: max(0, cached - (previous?.cached ?? 0)),
                output: max(0, output - (previous?.output ?? 0)),
                reasoning: max(0, reasoning - (previous?.reasoning ?? 0)),
                total: max(0, total - (previous?.total ?? 0))
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
    private static let sharedScanner = IncrementalJSONLScanner<Event>(
        maxResidentIdentities: 2,
        retainResidentItems: false,
        logTag: LogTag.plugin("codex"),
        persistence: JSONLScanCachePersistence(namespace: "codex", schemaVersion: 4)
    )

    static func flushPersistentCacheWrites() async {
        await sharedScanner.flushPendingWrites()
    }

    /// After a refresh cycle settles, drop Event arrays from the process-wide tail cache while keeping
    /// append checkpoints. The next exact-match / append path full-reparses when items were unloaded.
    static func unloadSharedTailCacheItems() {
        sharedTailCache.unloadRetainedItems()
    }

    /// Other Codex account homes whose session rollouts may share hardlinks with this card's homes.
    /// When this scanner enumerates a *managed* (non-default) home, files whose inode also appears
    /// under a peer `~/.codex` are skipped so Orca backfills stay attributed to default. Default
    /// `~/.codex` keeps shared inodes (see `sessionFiles`).
    private let peerHomes: [URL]

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

    func scan(daysBack: Int = 30, now: Date = Date(), pricing: ModelPricing) async -> LogUsageScan? {
        let homes = codexHomes()
        let context = Self.scanContext(homes: homes, daysBack: daysBack, now: now)
        let files = Self.sessionFiles(homes: homes, peerHomes: peerHomes, homeDirectory: homeDirectory)
        guard !files.isEmpty else {
            _ = await scanner.foldItems(
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
            return nil
        }

        let fold = AggregateFoldState()
        let requestedSince = context.requestedSince
        let ok = await scanner.foldItems(
            from: files, since: context.cacheSince, cacheIdentity: context.identity,
            parseFile: { url in
                Self.parseFileIncrementally(
                    at: url,
                    emitSince: context.cacheSince,
                    retentionDays: context.retentionDays
                )
            },
            visit: { event in
                Self.accumulate(
                    event: event,
                    since: requestedSince,
                    pricing: pricing,
                    seen: &fold.seen,
                    accumulator: &fold.accumulator
                )
            }
        )
        guard ok, !Task.isCancelled else { return nil }
        return fold.accumulator.build()
    }

    /// The parsed turns of the last `daysBack` days. Default 30/33-day consumers share one 35-day
    /// cache; an explicitly wider request receives its own retention bucket so a narrow earlier scan
    /// can never poison a later wider one.
    func parsedEvents(daysBack: Int = 33, now: Date = Date(), homes: [URL]? = nil) async -> [Event] {
        let homes = homes ?? codexHomes()
        let context = Self.scanContext(homes: homes, daysBack: daysBack, now: now)
        let files = Self.sessionFiles(homes: homes, peerHomes: peerHomes, homeDirectory: homeDirectory)
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
        let files = Self.sessionFiles(homes: homes, peerHomes: peerHomes, homeDirectory: homeDirectory)
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
    private struct FileIdentity: Hashable, Sendable {
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
        let defaultCodexPath = homeDirectory()
            .appendingPathComponent(".codex")
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let peerInodes = collectSessionInodes(under: peerHomes)

        var nonDefaultHomes: [URL] = []
        var defaultHomes: [URL] = []
        for home in homes {
            if isDefaultCodexHome(home, defaultCodexPath: defaultCodexPath) {
                defaultHomes.append(home)
            } else {
                nonDefaultHomes.append(home)
            }
        }
        // Prefer default ~/.codex when the same inode appears under both a peer managed home and ~/.codex.
        let orderedHomes = defaultHomes + nonDefaultHomes

        var files: [JSONLScanning.DiscoveredFile] = []
        var seenDirs: Set<String> = []
        var seenInodes: Set<FileIdentity> = []
        var seenRolloutNames: Set<String> = []
        for home in orderedHomes {
            // Managed/non-default homes skip inodes that already exist under peer ~/.codex.
            // Default keeps shared hardlinks (Orca backfilled FROM system root INTO managed home).
            let skipPeerHardlinks = !isDefaultCodexHome(home, defaultCodexPath: defaultCodexPath)
                && !peerInodes.isEmpty
            var seenRelative: Set<String> = []
            var sourceDirs: [URL] = []
            for name in ["sessions", "archived_sessions"] {
                let dir = home.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    sourceDirs.append(dir)
                }
            }
            // CodexRouter chatgpt-accounts homes often have auth + plugins but no session rollouts.
            // Falling back to the whole CODEX_HOME walked plugins/ (tens of thousands of files) for
            // zero *.jsonl and risked mis-attributing any future non-session JSONL under the home.
            if sourceDirs.isEmpty {
                continue
            }
            for dir in sourceDirs.map({ $0.resolvingSymlinksInPath() }) where seenDirs.insert(dir.path).inserted {
                for file in JSONLScanning.jsonlFiles(under: dir) {
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
                    if let identity = fileIdentity(at: fileURL) {
                        if skipPeerHardlinks, peerInodes.contains(identity) {
                            continue
                        }
                        guard seenInodes.insert(identity).inserted else { continue }
                    }
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
        private let lock = NSLock()
        private var entries: [String: (signature: String, inodes: Set<FileIdentity>)] = [:]

        func lookupOrCompute(
            key: String,
            signature: String,
            compute: () -> Set<FileIdentity>
        ) -> Set<FileIdentity> {
            lock.lock()
            if let entry = entries[key], entry.signature == signature {
                let hit = entry.inodes
                lock.unlock()
                return hit
            }
            lock.unlock()
            let inodes = compute()
            lock.lock()
            entries[key] = (signature, inodes)
            lock.unlock()
            return inodes
        }
    }

    /// `(st_dev, st_ino)` for every `*.jsonl` under each home's `sessions/` and `archived_sessions/`.
    /// Lightweight enumerator only — no `DiscoveredFile` / mtime arrays (those were ~11GB-path peak RSS
    /// amplifiers when peer homes held hundreds of hardlinked rollouts).
    private static func collectSessionInodes(under homes: [URL]) -> Set<FileIdentity> {
        var result: Set<FileIdentity> = []
        for home in homes {
            let key = home.resolvingSymlinksInPath().standardizedFileURL.path
            let signature = sessionDirectorySignature(for: home)
            result.formUnion(
                SessionInodeSetCache.shared.lookupOrCompute(key: key, signature: signature) {
                    collectSessionInodesUncached(under: home)
                }
            )
        }
        return result
    }

    /// Directory mtime signature for the refresh-lifetime inode cache. Nested file adds may not bump
    /// the top-level dir mtime on every FS; unique per-test paths keep hermetic tests correct.
    private static func sessionDirectorySignature(for home: URL) -> String {
        var parts: [String] = []
        for name in ["sessions", "archived_sessions"] {
            let dir = home.appendingPathComponent(name)
            guard let values = try? dir.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
                  values.isDirectory == true,
                  let mtime = values.contentModificationDate
            else {
                parts.append("\(name)=missing")
                continue
            }
            parts.append("\(name)=\(mtime.timeIntervalSince1970)")
        }
        return parts.joined(separator: ";")
    }

    private static func collectSessionInodesUncached(under home: URL) -> Set<FileIdentity> {
        var result: Set<FileIdentity> = []
        for name in ["sessions", "archived_sessions"] {
            let dir = home.appendingPathComponent(name).resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { continue }
            guard let enumerator = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: []
            ) else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl" else { continue }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                if let identity = fileIdentity(at: url) {
                    result.insert(identity)
                }
            }
        }
        return result
    }

    private static func fileIdentity(at url: URL) -> FileIdentity? {
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
        guard readSucceeded else { return nil }
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
        let currentRevision = AppendOnlyFileProbe.revision(at: url)

        if let currentRevision,
           let cached = sharedTailCache.entry(for: key),
           currentRevision.device == cached.revision.device,
           currentRevision.inode == cached.revision.inode,
           currentRevision.size == cached.offset,
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

        if let currentRevision,
           let cached = sharedTailCache.entry(for: key),
           cached.itemsAvailable,
           currentRevision.device == cached.revision.device,
           currentRevision.inode == cached.revision.inode,
           currentRevision.size > cached.offset,
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
            guard read.succeeded else { return nil }

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

            let newOffset = cached.offset + UInt64(read.statistics.bytesRead)
            if let after = AppendOnlyFileProbe.revision(at: url),
               after.device == currentRevision.device,
               after.inode == currentRevision.inode,
               after.size >= newOffset,
               let anchor = AppendOnlyFileProbe.anchor(at: url, endingAt: newOffset)
            {
                var merged = cached.items.filter { $0.timestamp >= emitSince }
                merged.append(contentsOf: parser.finish())
                sharedTailCache.store(
                    AppendOnlyFileTailCache<Event, ParserCheckpoint>.Entry(
                        revision: after,
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
        let before = AppendOnlyFileProbe.revision(at: url)
        var parser = FileParser(emitSince: emitSince)
        var read = JSONLFileReader.readLines(
            at: url,
            chunkSize: 64 * 1024,
            deliverFinalPartial: false
        ) { line in
            parser.consume(line)
        }
        guard read.succeeded else {
            sharedTailCache.remove(key)
            return nil
        }
        consumeCompleteFinalJSONIfPossible(&read, parser: &parser)
        let events = parser.finish()
        let offset = UInt64(read.statistics.bytesRead)

        if let before,
           let after = AppendOnlyFileProbe.revision(at: url),
           before.device == after.device,
           before.inode == after.inode,
           after.size >= offset,
           let anchor = AppendOnlyFileProbe.anchor(at: url, endingAt: offset)
        {
            sharedTailCache.store(
                AppendOnlyFileTailCache<Event, ParserCheckpoint>.Entry(
                    revision: after,
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
        private var sawSessionMeta = false
        private var replayGate: ChildReplayGate?
        private let emitSince: Date?

        init(emitSince: Date? = nil, checkpoint: ParserCheckpoint? = nil) {
            self.emitSince = emitSince
            if let checkpoint {
                self.previousTotals = checkpoint.previousTotals
                self.currentModel = checkpoint.currentModel
                self.currentTierIsFast = checkpoint.currentTierIsFast
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
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }

            let type = object["type"] as? String
            let payload = object["payload"] as? [String: Any]

            if type == "turn_context" {
                if let model = payload.flatMap(CodexLogUsageScanner.modelName(in:)) {
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
                if let tier = CodexLogUsageScanner.serviceTier(in: payload) {
                    currentTierIsFast = tier == "fast" || tier == "priority"
                }
                return
            }
            guard type == "event_msg", let payload else { return }

            if payload["type"] as? String == "task_started" {
                if let gate = replayGate,
                   let startedAt = payload["started_at"] as? NSNumber,
                   gate.isCleared(byStartedAt: startedAt.doubleValue, lineTimestamp: object["timestamp"] as? String) {
                    replayGate = nil
                }
                return
            }
            guard payload["type"] as? String == "token_count",
                  let timestampRaw = (object["timestamp"] as? String)?.trimmingCharacters(in: .whitespaces),
                  let timestamp = OpenUsageISO8601.date(from: timestampRaw)
            else { return }

            let info = payload["info"] as? [String: Any]
            let totals = (info?["total_token_usage"] as? [String: Any]).map(RawUsage.init(json:))

            if replayGate != nil {
                if let totals { previousTotals = totals }
                return
            }
            if let totals, let previous = previousTotals, totals.equalCounts(previous) {
                return
            }

            let usage: RawUsage
            if let last = (info?["last_token_usage"] as? [String: Any]).map(RawUsage.init(json:)) {
                usage = last
            } else if let totals {
                usage = totals.subtracting(previousTotals)
            } else {
                return
            }
            if let totals { previousTotals = totals }
            guard usage.input > 0 || usage.cached > 0 || usage.output > 0 || usage.reasoning > 0 else { return }

            let parsedModel = CodexLogUsageScanner.modelName(in: payload)
                ?? info.flatMap(CodexLogUsageScanner.modelName(in:))
            let model = CodexLogUsageScanner.resolveModel(parsed: parsedModel, currentModel: &currentModel)
            let event = Event(
                timestamp: timestamp,
                model: model,
                pricingModel: model == CodexLogUsageScanner.autoReviewModel
                    || model == CodexLogUsageScanner.reserveModel
                    ? CodexLogUsageScanner.autoReviewFallback(at: timestampRaw)
                    : nil,
                input: usage.input,
                cached: min(usage.cached, usage.input),
                output: usage.output,
                reasoning: usage.reasoning,
                total: usage.total,
                isFast: currentTierIsFast
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
                sawSessionMeta: sawSessionMeta,
                replayGate: replayGate
            )
        }
    }

    private static func serviceTier(in payload: [String: Any]?) -> String? {
        guard let payload else { return nil }
        let settings = payload["thread_settings"] as? [String: Any]
        for value in [settings?["service_tier"], payload["service_tier"]] {
            if let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static func modelName(in json: [String: Any]) -> String? {
        for value in [json["model"], json["model_name"], (json["metadata"] as? [String: Any])?["model"]] {
            if let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
                return text
            }
        }
        return nil
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
            total: event.total
        )
        guard seen.insert(key).inserted else { return }

        let day = DailyUsageAccumulator.dayKey(from: event.timestamp)
        let trimmedModel = event.model.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard let model = trimmedModel else { return }
        // OpenCode Go/Zen gateway turns are folded into the OpenCode card; counting them here
        // double-counts the same dollars/tokens in Total Spend.
        if OpenCodeUsageScanner.isHostedGatewayModel(model) { return }
        let pricingModel = event.pricingModel ?? model
        let canonicalModel = pricing.supplement.canonicalName(for: pricingModel) ?? pricingModel
        let isFastAlias = canonicalModel.hasSuffix("-fast")
        let rateModel = isFastAlias ? String(canonicalModel.dropLast("-fast".count)) : canonicalModel
        let baseRates = pricing.resolve(model: rateModel)
        let resolvedRates = baseRates ?? pricing.resolve(model: pricingModel)
        guard let rates = resolvedRates else {
            if event.total > 0 {
                accumulator.addUnknownModel(day: day, model: model)
            }
            return
        }
        let appliesCodexFastTier = isFastAlias ? baseRates != nil : event.isFast
        let eventCost = cost(
            rates: rates,
            event: event,
            model: rateModel,
            fastTier: appliesCodexFastTier,
            fastMultiplier: codexPriorityMultiplier(for: rateModel, rates: rates)
        )
        accumulator.add(day: day, tokens: event.total, cost: eventCost, model: model)
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
        model
            .replacingOccurrences(of: #"-\d{4}-\d{2}-\d{2}$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
    }
}
