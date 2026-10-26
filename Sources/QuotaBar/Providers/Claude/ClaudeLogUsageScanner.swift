import Foundation
import CoreFoundation

/// Readable ownership metadata can legitimately be ambiguous or absent. Only a failure to read the
/// preamble makes an account-scoped scan incomplete.
enum ClaudeSessionOwnershipLookupResult: Sendable {
    case readable(organizationID: String?, accountID: String?, isAmbiguous: Bool)
    case unreadable
}

/// Lets a provider distinguish a complete empty log scan from a source read that was incomplete.
enum ClaudeLogUsageScanResult: Sendable {
    case complete(LogUsageScan?)
    case incomplete
}

/// Account-scoped Claude cards share physical logs. Cache ownership metadata across those cards so
/// each candidate session is classified once; nonmatching usage rows never enter the parse/fold cache.
private actor ClaudeSessionOwnershipIndex {
    static let shared = ClaudeSessionOwnershipIndex()
    private static let ownershipReadDiagnosticBase = "claude.session.ownership-read."

    private struct CachedIdentity {
        var size: Int
        var mtime: Date
        var attributeMtime: Date?
        var organizationID: String?
        var accountID: String?
        var isAmbiguous: Bool
    }

    private var entries: [String: CachedIdentity] = [:]

    func identity(for file: JSONLScanning.DiscoveredFile) -> ClaudeSessionOwnershipLookupResult {
        if let cached = entries[file.path], cached.size == file.size,
           cached.mtime == file.mtime, cached.attributeMtime == file.attributeMtime {
            DiagnosticGate.clearFailures(prefix: Self.failureDiagnosticPrefix(for: file.path))
            return .readable(
                organizationID: cached.organizationID,
                accountID: cached.accountID,
                isAmbiguous: cached.isAmbiguous
            )
        }
        guard !Task.isCancelled else { return .unreadable }
        guard let identity = Self.readOwnershipPrefix(at: URL(fileURLWithPath: file.path)) else {
            DiagnosticGate.logOnce(for: Self.failureDiagnosticKey(for: file)) {
                AppLog.warn(LogTag.plugin("claude"), "Failed to read Claude session ownership from \(file.path)")
            }
            return .unreadable
        }
        DiagnosticGate.clearFailures(prefix: Self.failureDiagnosticPrefix(for: file.path))
        entries[file.path] = CachedIdentity(
            size: file.size, mtime: file.mtime, attributeMtime: file.attributeMtime,
            organizationID: identity.organizationID, accountID: identity.accountID,
            isAmbiguous: identity.isAmbiguous
        )
        return .readable(
            organizationID: identity.organizationID,
            accountID: identity.accountID,
            isAmbiguous: identity.isAmbiguous
        )
    }

    private static func failureDiagnosticPrefix(for path: String) -> String {
        "\(ownershipReadDiagnosticBase)\(JSONLScanCachePaths.stableFingerprint(path))."
    }

    private static func failureDiagnosticKey(for file: JSONLScanning.DiscoveredFile) -> String {
        let revision = [
            String(file.size),
            String(file.mtime.timeIntervalSinceReferenceDate),
            file.attributeMtime.map { String($0.timeIntervalSinceReferenceDate) } ?? "no-attribute-mtime"
        ].joined(separator: "|")
        return failureDiagnosticPrefix(for: file.path)
            + JSONLScanCachePaths.stableFingerprint(revision)
    }

    /// Ownership is written in the session preamble, before the first usage row. Read only that
    /// prefix: a disabled account's shared-root file needs attribution metadata, not a full-file
    /// scan just to decide that its usage rows do not belong to this enabled card.
    private static func readOwnershipPrefix(at url: URL) -> (
        organizationID: String?, accountID: String?, isAmbiguous: Bool
    )? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let ownerMarker = Data(#""ownerOrganizationUuid""#.utf8)
        let usageMarker = Data(#""usage":{"#.utf8)
        var owner: String?
        var account: String?
        var isAmbiguous = false
        var carry = Data()
        let readLimit = 1024 * 1024
        var bytesRead = 0
        var reachedUsage = false

        func inspect(_ line: Data.SubSequence) {
            guard !isAmbiguous, line.range(of: ownerMarker) != nil,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let value = object["ownerOrganizationUuid"] as? String, !value.isEmpty
            else { return }
            let candidate = value.lowercased()
            if let owner, owner != candidate {
                isAmbiguous = true
                return
            }
            owner = candidate
            if let candidateAccount = object["ownerAccountUuid"] as? String, !candidateAccount.isEmpty {
                let normalizedAccount = candidateAccount.lowercased()
                if let account, account != normalizedAccount {
                    isAmbiguous = true
                    return
                }
                account = normalizedAccount
            }
        }

        do {
            while bytesRead < readLimit, !reachedUsage {
                guard !Task.isCancelled else { return nil }
                let amount = min(64 * 1024, readLimit - bytesRead)
                guard let chunk = try handle.read(upToCount: amount), !chunk.isEmpty else {
                    if !carry.isEmpty { inspect(carry[...]) }
                    break
                }
                bytesRead += chunk.count
                carry.append(chunk)
                var lineStart = carry.startIndex
                while let newline = carry[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
                    let line = carry[lineStart..<newline]
                    inspect(line)
                    lineStart = carry.index(after: newline)
                    if line.range(of: usageMarker) != nil {
                        reachedUsage = true
                        break
                    }
                }
                if lineStart > carry.startIndex {
                    carry.removeSubrange(carry.startIndex..<lineStart)
                }
            }
        } catch {
            return nil
        }
        return (owner, account, isAmbiguous)
    }
}

/// Builds daily token/cost estimates for Claude by scanning Claude Code's local session logs
/// natively (`<config dir>/projects/**/*.jsonl`), replacing the external `ccusage` CLI.
///
/// Ports ccusage's Claude adapter semantics:
/// - Roots come from `CLAUDE_CONFIG_DIR` (comma-separated; each entry is a config dir containing
///   `projects/`, or the `projects/` dir itself), else `$XDG_CONFIG_HOME/claude` and `~/.claude`.
/// - A usage line must carry `"usage":{`, parse as JSON with a valid timestamp, not carry `null` in
///   fields Claude never writes as null, and pass the validity checks (semver-ish `version`,
///   non-empty ids/model).
/// - Entries are deduplicated by `(message.id, requestId)`, with a second pass that catches
///   sidechain logs replaying a parent message under a new request id. On collision the non-sidechain
///   entry wins, then the larger token total, then the one carrying a `speed` field.
/// - Advisor-message iterations become separate entries under their own model. Other iteration
///   types stay represented only by the parent usage totals, avoiding double-counting.
/// - Cost mode "auto": a line's `costUSD` when present, else tokens priced through `ModelPricing`.
///
/// An actor so the whole scan runs off the main actor. Parsed files are cached by path + size + content
/// mtime + attribute mtime in memory and Application Support: refreshes and relaunches parse only
/// changed files, then re-run the cheap dedup + day aggregation over cached entries before local
/// model-rate estimates.
actor ClaudeLogUsageScanner {
    private static let futureTimestampDiagnosticKey = "claude.sessions.future-timestamp"
    private let environment: EnvironmentReading
    private let homeDirectory: @Sendable () -> URL
    private let scanner: IncrementalJSONLScanner<Entry>
    /// Scoped provider instances pass their stable parse-source identity here. Account or time filters
    /// over the same physical roots deliberately pass the same value and share whole-file records.
    private let cacheIdentityOverride: String?
    private let organizationID: String?
    private let accountID: String?
    private let allowsUnattributedSessions: Bool
    private let ownershipLookup: @Sendable (JSONLScanning.DiscoveredFile) async -> ClaudeSessionOwnershipLookupResult
    private var aggregateCache: ClaudeUsageFoldCache<LogUsageScan>?
    /// OpenCode needs only hosted gateway entries. Bound that projection independently of the much
    /// larger native history; oversized projections keep using the streaming fold.
    private var gatewayCache: ClaudeUsageFoldCache<[Entry]>?
    private static let maximumCachedGatewayEntries = 4_096

    /// One parsed usage line. Token buckets are pre-normalized into `TokenBreakdown`; dedup fields
    /// ride along so the global dedup pass can run over cached entries.
    struct Entry: Codable, Sendable, Equatable {
        var timestamp: Date
        var tokens: TokenBreakdown
        var messageID: String?
        var requestID: String?
        var isSidechain: Bool = false
        /// The line carried a `speed` field at all (dedup tiebreaker); `tokens.isFast` says it was "fast".
        var hasSpeed: Bool = false
        var costUSD: Double?
        /// `nil` when the line has no model or the placeholder `<synthetic>` (tokens count, cost is $0).
        var model: String?
    }

    /// Cards that read the same Claude home share one actor, so the first scan populates both the
    /// in-memory and disk caches and the rest reuse it. Tests inject an isolated memory-only scanner.
    /// Unload resident Entry arrays after each return so long-lived refreshes do not keep full
    /// JSONL parses in RAM between cycles (disk hydrate / reparse on next scan).
    private static let sharedScanner = IncrementalJSONLScanner<Entry>(
        retainResidentItems: false,
        logTag: LogTag.plugin("claude"),
        // Reparse records classified by the old byte-wide null/usage checks.
        persistence: JSONLScanCachePersistence(namespace: "claude", schemaVersion: 6)
    )

    static func flushPersistentCacheWrites() async {
        await sharedScanner.flushPendingWrites()
    }

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        incrementalScanner: IncrementalJSONLScanner<Entry>? = nil,
        cacheIdentityOverride: String? = nil,
        accountUUID: String? = nil,
        organizationUUID: String? = nil,
        allowsUnattributedSessions: Bool = false,
        ownershipLookup: (@Sendable (JSONLScanning.DiscoveredFile) async -> ClaudeSessionOwnershipLookupResult)? = nil
    ) {
        precondition(cacheIdentityOverride?.isEmpty != true)
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.scanner = incrementalScanner ?? Self.sharedScanner
        self.cacheIdentityOverride = cacheIdentityOverride
        self.organizationID = organizationUUID?.lowercased()
        self.accountID = accountUUID?.lowercased()
        self.allowsUnattributedSessions = allowsUnattributedSessions
        self.ownershipLookup = ownershipLookup ?? { file in
            await ClaudeSessionOwnershipIndex.shared.identity(for: file)
        }
    }

    /// Scan the last `daysBack` days of Claude logs. Returns `nil` when no Claude data directory or
    /// no log files exist (the spend tiles then render "No data"); returns an empty series when logs
    /// exist but have no usage in the window.
    func scan(daysBack: Int = UsageHistoryWindow.previousDays, now: Date = Date(), pricing: ModelPricing) async -> LogUsageScan? {
        switch await scanResult(daysBack: daysBack, now: now, pricing: pricing) {
        case .complete(let scan):
            return scan
        case .incomplete:
            return nil
        }
    }

    /// Completeness-aware form used by the Claude provider so an ownership/read failure cannot be
    /// mistaken for a clean scan that simply found no Claude rows.
    func scanResult(
        daysBack: Int = UsageHistoryWindow.previousDays,
        now: Date = Date(),
        pricing: ModelPricing
    ) async -> ClaudeLogUsageScanResult {
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let cacheIdentity = parseCacheIdentity()
        let futureIdentity = futureGateIdentity(kind: "sessions", cacheIdentity: cacheIdentity)
        let roots = claudeRoots()
        guard !roots.isEmpty else {
            aggregateCache = nil
            FutureTimestampRevisionGate.retain(identity: futureIdentity, paths: [])
            _ = await scanner.items(
                from: [], since: since, cacheIdentity: cacheIdentity, parseFile: { url in Self.parseFile(at: url) }
            )
            DiagnosticGate.clearFailure(Self.futureTimestampDiagnosticGateKey(for: futureIdentity))
            return .complete(nil)
        }

        guard var files = Self.usageFilesIfComplete(under: roots) else { return .incomplete }
        if let organizationID {
            guard let owned = await ownedUsageFiles(files, organizationID: organizationID) else {
                return .incomplete
            }
            files = owned
        }
        guard !Task.isCancelled else { return .incomplete }
        guard !files.isEmpty else {
            aggregateCache = nil
            FutureTimestampRevisionGate.retain(identity: futureIdentity, paths: [])
            _ = await scanner.items(
                from: [], since: since, cacheIdentity: cacheIdentity, parseFile: { url in Self.parseFile(at: url) }
            )
            DiagnosticGate.clearFailure(Self.futureTimestampDiagnosticGateKey(for: futureIdentity))
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
        let aggregateKey = ClaudeUsageFoldCache<LogUsageScan>.Key(
            files: files, identity: cacheIdentity, since: since,
            pricingToken: pricing.aggregateCacheToken
        )
        if let cached = aggregateCache?.lookup(aggregateKey, now: now) {
            DiagnosticGate.clearFailure(Self.futureTimestampDiagnosticGateKey(for: futureIdentity))
            return .complete(cached)
        }
        aggregateCache = nil
        let bucket = FutureTimestampFoldBucket<Entry>()
        let complete = await scanner.foldItems(
            from: files,
            since: since,
            cacheIdentity: cacheIdentity,
            parseFile: { url in Self.parseFile(at: url) },
            visit: { entry in
                guard Self.contributesUsage(entry) else { return }
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
        DiagnosticGate.clearFailure(Self.futureTimestampDiagnosticGateKey(for: futureIdentity))
        let deduped = Self.dedup(bucket.items)
        guard !Task.isCancelled else { return .incomplete }
        let result = Self.aggregate(entries: deduped, since: since, pricing: pricing)
        guard !Task.isCancelled else { return .incomplete }
        aggregateCache = ClaudeUsageFoldCache(key: aggregateKey, observedAt: now, value: result)
        return .complete(result)
    }

    /// The parsed usage entries of the last `daysBack` days — the same incremental scan the card's
    /// `scan()` runs, but returning the raw entries instead of the aggregated series. The OpenCode
    /// gateway fold uses this so both consumers share one persistent parse cache: unchanged session
    /// logs are never re-parsed on a 5-minute refresh. `roots` overrides discovery (the fold passes
    /// its own roots so tests stay hermetic).
    func parsedEntries(
        daysBack: Int = 33,
        now: Date = Date(),
        roots: [URL],
        cacheIdentityOverride: String? = nil
    ) async -> [Entry] {
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let identityPaths = Set(roots.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
            .sorted()
        let cacheIdentity = cacheIdentityOverride
            ?? (identityPaths.isEmpty ? "no-claude-root" : identityPaths.joined(separator: "\n"))
        let files = Self.usageFiles(under: roots)
        let futureIdentity = futureGateIdentity(kind: "parsed", cacheIdentity: cacheIdentity)
        guard !files.isEmpty else {
            FutureTimestampRevisionGate.retain(identity: futureIdentity, paths: [])
            return []
        }
        let maximumTimestamp = JSONLScanning.maximumTimestamp(now: now)
        FutureTimestampRevisionGate.retain(identity: futureIdentity, paths: Set(files.map(\.path)))
        for file in files where FutureTimestampRevisionGate.shouldDefer(
            identity: futureIdentity, file: file, maximumTimestamp: maximumTimestamp
        ) {
            Self.logFutureTimestamp(identity: futureIdentity)
            return []
        }
        let bucket = FutureTimestampFoldBucket<Entry>()
        let complete = await scanner.foldItems(
            from: files, since: since, cacheIdentity: cacheIdentity,
            parseFile: { url in Self.parseFile(at: url) },
            visit: { entry in
                guard Self.contributesUsage(entry) else { return }
                bucket.append(entry, timestamp: entry.timestamp, maximumTimestamp: maximumTimestamp)
            },
            fileStarted: { bucket.begin($0) },
            fileCompleted: { path, _ in bucket.finish(path) }
        )
        guard complete else { return [] }
        for (path, timestamp) in bucket.futureTimestamps {
            guard let file = files.first(where: { $0.path == path }),
                  FutureTimestampRevisionGate.record(timestamp, identity: futureIdentity, file: file)
            else { return [] }
        }
        guard bucket.futureTimestamps.isEmpty else {
            Self.logFutureTimestamp(identity: futureIdentity)
            return []
        }
        DiagnosticGate.clearFailure(Self.futureTimestampDiagnosticGateKey(for: futureIdentity))
        return bucket.items
    }

    /// Stream Claude entries without building a mega-array (OpenCode gateway fold).
    @discardableResult
    func foldParsedEntries(
        daysBack: Int = 33,
        now: Date = Date(),
        roots: [URL],
        cacheIdentityOverride: String? = nil,
        hostedGatewayOnly: Bool = false,
        visit: @Sendable (Entry) -> Void
    ) async -> Bool {
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let identityPaths = Set(roots.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
            .sorted()
        let cacheIdentity = cacheIdentityOverride
            ?? (identityPaths.isEmpty ? "no-claude-root" : identityPaths.joined(separator: "\n"))
        guard var files = Self.usageFilesIfComplete(under: roots) else { return false }
        if let organizationID {
            guard let owned = await ownedUsageFiles(files, organizationID: organizationID) else { return false }
            files = owned
        }
        guard !Task.isCancelled else { return false }
        let futureIdentity = futureGateIdentity(kind: "gateway", cacheIdentity: cacheIdentity)
        guard !files.isEmpty else {
            gatewayCache = nil
            FutureTimestampRevisionGate.retain(identity: futureIdentity, paths: [])
            DiagnosticGate.clearFailure(Self.futureTimestampDiagnosticGateKey(for: futureIdentity))
            return true
        }
        let maximumTimestamp = JSONLScanning.maximumTimestamp(now: now)
        FutureTimestampRevisionGate.retain(identity: futureIdentity, paths: Set(files.map(\.path)))
        for file in files where FutureTimestampRevisionGate.shouldDefer(
            identity: futureIdentity, file: file, maximumTimestamp: maximumTimestamp
        ) {
            Self.logFutureTimestamp(identity: futureIdentity)
            return false
        }
        let gatewayKey = ClaudeUsageFoldCache<[Entry]>.Key(
            files: files, identity: cacheIdentity, since: since
        )
        if hostedGatewayOnly, let cached = gatewayCache?.lookup(gatewayKey, now: now) {
            DiagnosticGate.clearFailure(Self.futureTimestampDiagnosticGateKey(for: futureIdentity))
            for entry in cached {
                guard !Task.isCancelled else { return false }
                visit(entry)
            }
            return !Task.isCancelled
        }
        if hostedGatewayOnly { gatewayCache = nil }
        let deduplication = ClaudeEntryDeduplication()
        let bucket = FutureTimestampFoldBucket<Entry>()
        let complete = await scanner.foldItems(
            from: files, since: since, cacheIdentity: cacheIdentity,
            parseFile: { url in Self.parseFile(at: url) },
            visit: { entry in
                guard Self.contributesUsage(entry) else { return }
                bucket.observe(timestamp: entry.timestamp, maximumTimestamp: maximumTimestamp)
                deduplication.append(entry)
            },
            fileStarted: { bucket.begin($0) },
            fileCompleted: { path, _ in bucket.finish(path) }
        )
        guard complete, !Task.isCancelled else { return false }
        for (path, timestamp) in bucket.futureTimestamps {
            guard let file = files.first(where: { $0.path == path }),
                  FutureTimestampRevisionGate.record(timestamp, identity: futureIdentity, file: file)
            else { return false }
        }
        guard bucket.futureTimestamps.isEmpty else {
            Self.logFutureTimestamp(identity: futureIdentity)
            return false
        }
        DiagnosticGate.clearFailure(Self.futureTimestampDiagnosticGateKey(for: futureIdentity))
        // Deduplicate the complete source before selecting gateway entries: a native replay may win
        // a cross-file collision, so filtering first could count a turn owned by the Claude card.
        let entries = hostedGatewayOnly ? deduplication.entries.filter {
            $0.model.map { OpenCodeUsageScanner.isHostedGatewayModel($0.trimmingCharacters(in: .whitespacesAndNewlines)) } == true
        } : deduplication.entries
        for entry in entries {
            guard !Task.isCancelled else { return false }
            visit(entry)
        }
        if hostedGatewayOnly, !Task.isCancelled, entries.count <= Self.maximumCachedGatewayEntries {
            gatewayCache = ClaudeUsageFoldCache(key: gatewayKey, observedAt: now, value: entries)
        }
        return !Task.isCancelled
    }

    private static func futureTimestampDiagnosticGateKey(for identity: String) -> String {
        "\(futureTimestampDiagnosticKey).\(JSONLScanCachePaths.stableFingerprint(identity))"
    }

    private func futureGateIdentity(kind: String, cacheIdentity: String) -> String {
        [
            kind,
            cacheIdentity,
            organizationID ?? "no-organization",
            accountID ?? "no-account",
            allowsUnattributedSessions ? "allows-unattributed" : "requires-owned-session"
        ].joined(separator: "\n")
    }

    private static func contributesUsage(_ entry: Entry) -> Bool {
        entry.tokens.totalTokens > 0 || (entry.costUSD ?? 0) > 0
    }

    private static func logFutureTimestamp(identity: String) {
        DiagnosticGate.logOnce(for: futureTimestampDiagnosticGateKey(for: identity)) {
            AppLog.warn(LogTag.plugin("claude"), "session usage contains a timestamp more than five minutes ahead; preserving last-good history")
        }
    }

    /// Stable source configuration identity rather than the discovered root list: Cowork adds session
    /// roots over time, and a new session must extend the same cache instead of cold-parsing every old
    /// file. Scoped root overrides pass an explicit identity so distinct homes stay partitioned.
    private func parseCacheIdentity() -> String {
        if let cacheIdentityOverride { return cacheIdentityOverride }
        return Self.parseSourceIdentity(environment: environment, homeDirectory: homeDirectory)
    }

    /// Stable identity for the physical Claude parse source. OpenCode's gateway fold uses this same
    /// source, so its supplementary scan can reuse the native Claude card's whole-file cache instead
    /// of cold-parsing the same terminal sessions under a second identity. Cowork session roots are
    /// intentionally excluded: they appear and disappear over time but still share this source cache.
    nonisolated static func parseSourceIdentity(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) -> String {
        let home = homeDirectory().resolvingSymlinksInPath().path
        let configuredRoots: [URL]
        if let raw = environment.value(for: "CLAUDE_CONFIG_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty
        {
            configuredRoots = raw.split(separator: ",").compactMap { part in
                let value = part.trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { return nil }
                var url = URL(fileURLWithPath: expandHome(value))
                if url.lastPathComponent == "projects" { url.deleteLastPathComponent() }
                return url
            }
        } else {
            let homeURL = homeDirectory()
            let xdg = environment.value(for: "XDG_CONFIG_HOME")?.nilIfEmpty
                .map { URL(fileURLWithPath: expandHome($0)) }
                ?? homeURL.appendingPathComponent(".config")
            configuredRoots = [
                xdg.appendingPathComponent("claude"),
                homeURL.appendingPathComponent(".claude"),
            ]
        }
        let roots = Set(configuredRoots.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
            .sorted()
            .joined(separator: "\n")
        return "home=\(home)\nroots=\(roots)"
    }

    // MARK: - Root and file discovery

    /// Claude config directories that actually contain a `projects/` folder, in ccusage's order:
    /// every entry of `CLAUDE_CONFIG_DIR` when set (an invalid list logs and yields none), else
    /// `$XDG_CONFIG_HOME/claude` (default `~/.config/claude`) and `~/.claude`. Cowork's per-session
    /// `.claude` sandboxes are always appended — they live under the desktop app's own container,
    /// so `CLAUDE_CONFIG_DIR` (a terminal-CLI override) doesn't speak for them.
    private func claudeRoots() -> [URL] {
        var roots: [URL] = []
        var seen: Set<String> = []

        func addIfValid(_ url: URL) {
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent("projects").path),
                  seen.insert(url.path).inserted
            else { return }
            roots.append(url)
        }

        if let raw = environment.value(for: "CLAUDE_CONFIG_DIR")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            let diagnosticPrefix = "claude.config-dir.invalid."
            let diagnosticKey = diagnosticPrefix + JSONLScanCachePaths.stableFingerprint(raw)
            for part in raw.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
                var url = URL(fileURLWithPath: expandHome(part))
                // Accept the `projects/` directory itself as an alias for its parent config dir.
                if url.lastPathComponent == "projects", FileManager.default.fileExists(atPath: url.path) {
                    url.deleteLastPathComponent()
                }
                addIfValid(url)
            }
            if roots.isEmpty {
                DiagnosticGate.logOnce(for: diagnosticKey) {
                    AppLog.warn(LogTag.plugin("claude"), "CLAUDE_CONFIG_DIR is set but contains no Claude data directory with projects/: \(raw)")
                }
            } else {
                DiagnosticGate.clearFailures(prefix: diagnosticPrefix)
            }
        } else {
            DiagnosticGate.clearFailures(prefix: "claude.config-dir.invalid.")
            let home = homeDirectory()
            let xdg = environment.value(for: "XDG_CONFIG_HOME")?.nilIfEmpty.map { URL(fileURLWithPath: expandHome($0)) }
                ?? home.appendingPathComponent(".config")
            addIfValid(xdg.appendingPathComponent("claude"))
            addIfValid(home.appendingPathComponent(".claude"))
        }

        for sandbox in Self.coworkClaudeDirs(
            home: homeDirectory(), organizationID: organizationID, accountID: accountID
        ) {
            addIfValid(sandbox)
        }
        return roots
    }

    /// The `.claude` dirs Cowork (the Claude desktop app's agent mode) creates, one per session,
    /// under `~/Library/Application Support/Claude/local-agent-mode-sessions/<group>/<sub>/local_*`
    /// (plus an `agent/local_*` variant one level deeper). Each holds the same `projects/**/*.jsonl`
    /// session logs as `~/.claude`, so they scan as additional roots. The walk is bounded to those
    /// known levels — session dirs contain full sandbox homes we must not recurse into.
    private static func coworkClaudeDirs(home: URL, organizationID: String?, accountID: String?) -> [URL] {
        let base = home
            .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")

        func subdirectories(of url: URL) -> [URL] {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
            return contents.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
        }

        var dirs: [URL] = []
        for group in subdirectories(of: base) {
            guard organizationID == nil || accountID == nil || group.lastPathComponent.lowercased() == accountID
            else { continue }
            for sub in subdirectories(of: group) {
                guard organizationID == nil || sub.lastPathComponent.lowercased() == organizationID else {
                    continue
                }
                var sessions = subdirectories(of: sub)
                for holder in sessions where holder.lastPathComponent == "agent" {
                    sessions.append(contentsOf: subdirectories(of: holder))
                }
                for session in sessions {
                    dirs.append(session.appendingPathComponent(".claude"))
                }
            }
        }
        return dirs.sorted { $0.path < $1.path }
    }

    /// Every `*.jsonl` under each root's `projects/`, path-sorted so the dedup pass (keep-first wins)
    /// is deterministic — the same order ccusage scans in.
    static func usageFiles(under roots: [URL]) -> [JSONLScanning.DiscoveredFile] {
        usageFilesIfComplete(under: roots) ?? []
    }

    static func usageFilesIfComplete(under roots: [URL]) -> [JSONLScanning.DiscoveredFile]? {
        var seenPaths: Set<String> = []
        var files: [JSONLScanning.DiscoveredFile] = []
        for root in roots {
            guard !Task.isCancelled,
                  let rootFiles = JSONLScanning.jsonlFilesIfComplete(
                    under: root.appendingPathComponent("projects")
                  )
            else { return nil }
            files.append(contentsOf: rootFiles)
        }
        return files.sorted { $0.path < $1.path }
            .filter { seenPaths.insert($0.path).inserted }
    }

    /// Cowork roots carry their organization in the directory layout. Other sessions identify theirs
    /// in a bridge event or Desktop's account-and-organization-scoped session index; subagent files
    /// inherit their parent session's ownership. Keep this outside the shared parsed-entry cache.
    private func ownedUsageFiles(
        _ files: [JSONLScanning.DiscoveredFile],
        organizationID: String
    ) async -> [JSONLScanning.DiscoveredFile]? {
        let coworkPrefix = homeDirectory()
            .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
            .resolvingSymlinksInPath().path + "/"
        let filesByPath = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var seenPaths: Set<String> = []
        var ownedFiles: [JSONLScanning.DiscoveredFile] = []
        var desktopSessionIDs: Set<String>?

        for file in files {
            guard !Task.isCancelled else { return nil }
            guard seenPaths.insert(file.path).inserted else { continue }
            let canonicalPath = URL(fileURLWithPath: file.path).resolvingSymlinksInPath().path
            if canonicalPath.hasPrefix(coworkPrefix) {
                let components = canonicalPath.dropFirst(coworkPrefix.count).split(separator: "/")
                if components.count > 1,
                   components[1].lowercased() == organizationID,
                   accountID == nil || components[0].lowercased() == accountID
                {
                    ownedFiles.append(file)
                }
                continue
            }

            let directory = URL(fileURLWithPath: file.path).deletingLastPathComponent()
            let sessionFile: JSONLScanning.DiscoveredFile?
            if directory.lastPathComponent == "subagents" {
                let parentPath = directory.deletingLastPathComponent().appendingPathExtension("jsonl").path
                sessionFile = filesByPath[parentPath]
            } else {
                sessionFile = file
            }
            guard let sessionFile else { continue }
            let lookup = await ownershipLookup(sessionFile)
            guard !Task.isCancelled else { return nil }
            switch lookup {
            case .unreadable:
                // It may belong to this account; omitting it would publish a successful partial sum.
                return nil
            case .readable(let owner, let ownerAccount, let isAmbiguous):
                guard !isAmbiguous else { continue }
                if let owner {
                    if owner == organizationID, accountID == nil || ownerAccount == accountID {
                        ownedFiles.append(file)
                    }
                } else if allowsUnattributedSessions {
                    ownedFiles.append(file)
                } else if let accountID {
                    if desktopSessionIDs == nil {
                        let diagnosticPrefix = desktopSessionIndexDiagnosticPrefix(
                            accountID: accountID,
                            organizationID: organizationID
                        )
                        guard let indexed = indexedDesktopSessionIDs(
                            accountID: accountID,
                            organizationID: organizationID
                        ) else {
                            DiagnosticGate.logOnce(for: diagnosticPrefix + "incomplete") {
                                AppLog.warn(
                                    LogTag.plugin("claude"),
                                    "account-scoped desktop session index could not be completely read; preserving last-good history"
                                )
                            }
                            return nil
                        }
                        DiagnosticGate.clearFailures(prefix: diagnosticPrefix)
                        desktopSessionIDs = indexed
                    }
                    let sessionID = URL(fileURLWithPath: sessionFile.path)
                        .deletingPathExtension().lastPathComponent.lowercased()
                    if desktopSessionIDs?.contains(sessionID) == true {
                        ownedFiles.append(file)
                    }
                }
            }
        }
        return ownedFiles
    }

    private func indexedDesktopSessionIDs(accountID: String, organizationID: String) -> Set<String>? {
        let directory = desktopSessionIndexDirectory(accountID: accountID, organizationID: organizationID)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            // A missing index is a valid empty source. A present index that cannot be read below is
            // different: account ownership is unresolved and the combined history must not publish.
            return []
        }
        guard isDirectory.boolValue, FileManager.default.isReadableFile(atPath: directory.path),
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              )
        else { return nil }

        var sessionIDs: Set<String> = []
        for file in files where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                return nil
            }
            // Do not follow index symlinks into another account's directory. They do not establish
            // ownership for this account's sessions.
            guard values.isSymbolicLink != true else { continue }
            guard values.isRegularFile == true,
                  let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawSessionID = object["cliSessionId"] as? String
            else { return nil }
            // Non-UUID values cannot match Claude's UUID-named session logs; keep ignoring those
            // well-formed but unrelated index entries.
            if let sessionID = UUID(uuidString: rawSessionID) {
                sessionIDs.insert(sessionID.uuidString.lowercased())
            }
        }
        return sessionIDs
    }

    private func desktopSessionIndexDirectory(accountID: String, organizationID: String) -> URL {
        homeDirectory()
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
            .appendingPathComponent(accountID)
            .appendingPathComponent(organizationID)
    }

    private func desktopSessionIndexDiagnosticPrefix(accountID: String, organizationID: String) -> String {
        let path = desktopSessionIndexDirectory(accountID: accountID, organizationID: organizationID)
            .standardizedFileURL.path
        return "claude.desktop.session-index.\(JSONLScanCachePaths.stableFingerprint(path))."
    }

    // MARK: - Line parsing

    /// Parse every usage line of one session file. Entries keep their raw timestamps — the date
    /// window is applied at aggregation so a cached parse stays valid as the window slides.
    static func parseFile(_ data: Data) -> [Entry] {
        var entries: [Entry] = []
        var malformedTokenCounts = false
        for line in data.split(separator: UInt8(ascii: "\n")) {
            appendEntries(from: line, to: &entries, malformedTokenCounts: &malformedTokenCounts)
        }
        return entries
    }

    /// Streaming counterpart used by the incremental scanner so a large session file never becomes
    /// one giant Data allocation.
    nonisolated static func parseFile(at url: URL) -> [Entry]? {
        ClaudeSessionAppendCache.shared.parse(at: url) { line in
            var entries: [Entry] = []
            var malformedTokenCounts = false
            appendEntries(from: line, to: &entries, malformedTokenCounts: &malformedTokenCounts)
            return malformedTokenCounts ? nil : entries
        }
    }

    private static let usageMarker = Data(#""usage""#.utf8)

    private static func appendEntries(
        from line: Data.SubSequence,
        to entries: inout [Entry],
        malformedTokenCounts: inout Bool
    ) {
        guard line.range(of: usageMarker) != nil else { return }
        entries.append(contentsOf: parseEntries(Data(line), malformedTokenCounts: &malformedTokenCounts))
    }

    /// Decode one JSONL line into an `Entry`, mirroring what ccusage's serde model accepts: `usage`
    /// with numeric `input_tokens`/`output_tokens` is required, everything else optional, and a
    /// malformed or invalid line is skipped rather than failing the file.
    static func parseLine(_ data: Data) -> Entry? {
        var malformedTokenCounts = false
        return parseEntries(data, malformedTokenCounts: &malformedTokenCounts).first
    }

    /// A Claude log line can carry nested advisor work in `usage.iterations`. The top-level usage
    /// remains the main-model entry; only advisor-message iterations become additional entries,
    /// matching ccusage without recounting the ordinary message iterations that feed that total.
    private static func parseEntries(_ data: Data, malformedTokenCounts: inout Bool) -> [Entry] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            malformedTokenCounts = true
            return []
        }
        // Attachments and tool results can contain unrelated usage objects. Only the assistant
        // message's accounting belongs to this source; a byte marker alone cannot classify it.
        if let type = object["type"], type as? String != "assistant" { return [] }
        guard let message = object["message"] as? [String: Any],
              let rawUsage = message["usage"] else {
            // A claimed assistant accounting record in an unfamiliar shape must stay observable.
            // Other rows may legitimately carry a usage key inside unrelated payloads.
            if object["type"] as? String == "assistant", object["usage"] != nil {
                malformedTokenCounts = true
            }
            return []
        }
        guard let usage = rawUsage as? [String: Any] else {
            malformedTokenCounts = true
            return []
        }
        guard let timestampRaw = object["timestamp"] as? String,
              let timestamp = OpenUsageISO8601.date(from: timestampRaw),
              isValidEntry(object, message: message)
        else {
            malformedTokenCounts = true
            return []
        }
        guard let parsedUsage = tokenBreakdown(from: usage, malformedTokenCounts: &malformedTokenCounts) else {
            return []
        }

        let costUSD: Double?
        if let rawCost = object["costUSD"], !(rawCost is NSNull) {
            guard let number = rawCost as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID()
            else {
                malformedTokenCounts = true
                return []
            }
            let value = number.doubleValue
            guard value.isFinite, value >= 0, value <= 1e12 else {
                malformedTokenCounts = true
                return []
            }
            costUSD = value
        } else {
            costUSD = nil
        }

        let model = (message["model"] as? String).flatMap { $0 == "<synthetic>" ? nil : $0 }
        let parent = Entry(
            timestamp: timestamp,
            tokens: parsedUsage.tokens,
            messageID: message["id"] as? String,
            requestID: object["requestId"] as? String,
            isSidechain: object["isSidechain"] as? Bool ?? false,
            hasSpeed: parsedUsage.hasSpeed,
            costUSD: costUSD,
            model: model
        )

        guard let rawIterations = usage["iterations"], !(rawIterations is NSNull) else { return [parent] }
        guard let iterations = rawIterations as? [Any] else {
            malformedTokenCounts = true
            return [parent]
        }

        var entries = [parent]
        var advisorIndex = 0
        for rawIteration in iterations {
            guard let iteration = rawIteration as? [String: Any] else {
                malformedTokenCounts = true
                continue
            }
            if let rawType = iteration["type"], !(rawType is String) {
                malformedTokenCounts = true
                continue
            }
            guard iteration["type"] as? String == "advisor_message" else { continue }
            guard let advisorUsage = tokenBreakdown(from: iteration, malformedTokenCounts: &malformedTokenCounts) else {
                continue
            }
            // Missing or malformed model attribution must not discard measured advisor tokens. Keep
            // them under the shared Unattributed label so their cost remains visibly unknown.
            let advisorModel = (iteration["model"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty

            entries.append(Entry(
                timestamp: parent.timestamp,
                tokens: advisorUsage.tokens,
                messageID: parent.messageID.map { "\($0):advisor:\(advisorIndex)" },
                requestID: parent.requestID,
                isSidechain: parent.isSidechain,
                hasSpeed: advisorUsage.hasSpeed,
                costUSD: nil,
                model: advisorModel
            ))
            advisorIndex += 1
        }
        return entries
    }

    private static func tokenBreakdown(
        from usage: [String: Any],
        malformedTokenCounts: inout Bool
    ) -> (tokens: TokenBreakdown, hasSpeed: Bool)? {
        guard let inputRaw = usage["input_tokens"],
              let outputRaw = usage["output_tokens"]
        else {
            malformedTokenCounts = true
            return nil
        }
        guard let input = nonnegativeTokenCount(inputRaw),
              let output = nonnegativeTokenCount(outputRaw)
        else {
            malformedTokenCounts = true
            return nil
        }

        // Cache writes: the 5m/1h split when present (1h bills at 2x input), else the legacy
        // aggregate `cache_creation_input_tokens` treated as all-5m.
        var cacheWrite5m = 0
        var cacheWrite1h = 0
        if let rawCacheCreation = usage["cache_creation"], !(rawCacheCreation is NSNull) {
            guard let cacheCreation = rawCacheCreation as? [String: Any],
                  let cache5m = optionalNonnegativeTokenCount(
                    cacheCreation["ephemeral_5m_input_tokens"]
                  ),
                  let cache1h = optionalNonnegativeTokenCount(
                    cacheCreation["ephemeral_1h_input_tokens"]
                  )
            else {
                malformedTokenCounts = true
                return nil
            }
            cacheWrite5m = cache5m
            cacheWrite1h = cache1h
        } else {
            guard let cacheWrite = optionalNonnegativeTokenCount(usage["cache_creation_input_tokens"]) else {
                malformedTokenCounts = true
                return nil
            }
            cacheWrite5m = cacheWrite
        }
        guard let cacheRead = optionalNonnegativeTokenCount(usage["cache_read_input_tokens"]) else {
            malformedTokenCounts = true
            return nil
        }
        // Claude tags fast-mode requests with `speed`; any value outside the known set marks a log
        // shape we don't understand, so the line is skipped (ccusage's enum parse does the same).
        let speed: String?
        if let rawSpeed = usage["speed"], !(rawSpeed is NSNull) {
            guard let value = rawSpeed as? String,
                  value == "fast" || value == "standard"
            else {
                malformedTokenCounts = true
                return nil
            }
            speed = value
        } else {
            speed = nil
        }

        return (TokenBreakdown(
            input: input,
            cacheWrite5m: cacheWrite5m,
            cacheWrite1h: cacheWrite1h,
            cacheRead: cacheRead,
            output: output,
            isFast: speed == "fast"
        ), speed != nil)
    }

    private static func optionalNonnegativeTokenCount(_ raw: Any?) -> Int? {
        guard let raw else { return 0 }
        if raw is NSNull { return 0 }
        return nonnegativeTokenCount(raw)
    }

    private static func nonnegativeTokenCount(_ raw: Any) -> Int? {
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

    /// ccusage's validity rules: a `version` that isn't SemVer marks a foreign log format, and
    /// ids/model that are present but empty mark a malformed line.
    private static func isValidEntry(_ object: [String: Any], message: [String: Any]) -> Bool {
        if let rawVersion = object["version"] {
            guard let version = rawVersion as? String, isValidSemVer(version) else { return false }
        }
        for value in [object["sessionId"], object["requestId"], message["id"]] {
            guard let value else { continue }
            guard let text = value as? String, !text.isEmpty else { return false }
        }
        if let rawSidechain = object["isSidechain"] {
            guard let number = rawSidechain as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID()
            else { return false }
        }
        if let rawModel = message["model"] {
            guard let model = rawModel as? String,
                  !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return false }
        }
        return true
    }

    /// Accepts a complete SemVer value, including valid prerelease and build identifiers.
    static func isValidSemVer(_ value: String) -> Bool {
        let buildParts = value.split(separator: "+", omittingEmptySubsequences: false)
        guard buildParts.count <= 2 else { return false }
        if buildParts.count == 2,
           !isValidSemVerIdentifiers(String(buildParts[1]), allowNumericLeadingZero: true) {
            return false
        }

        let releaseParts = buildParts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let coreParts = releaseParts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard coreParts.count == 3,
              coreParts.allSatisfy({ part in
                  !part.isEmpty
                      && part.utf8.allSatisfy(\.isASCIIDigit)
                      && (part == "0" || part.first != "0")
              })
        else { return false }
        if releaseParts.count == 2,
           !isValidSemVerIdentifiers(String(releaseParts[1]), allowNumericLeadingZero: false) {
            return false
        }
        return true
    }

    private static func isValidSemVerIdentifiers(_ value: String, allowNumericLeadingZero: Bool) -> Bool {
        let identifiers = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !identifiers.isEmpty else { return false }
        return identifiers.allSatisfy { identifier in
            let bytes = Array(identifier.utf8)
            guard !bytes.isEmpty,
                  bytes.allSatisfy({
                      $0.isASCIIDigit || (65...90).contains($0) || (97...122).contains($0) || $0 == UInt8(ascii: "-")
                  })
            else { return false }
            if !allowNumericLeadingZero,
               bytes.count > 1,
               bytes.allSatisfy(\.isASCIIDigit),
               bytes[0] == UInt8(ascii: "0") {
                return false
            }
            return true
        }
    }

    // MARK: - Deduplication

    private struct ExactKey: Hashable {
        var messageID: String
        var requestID: String?
    }

    /// Stateful counterpart to `dedup` for the gateway fold. `foldItems` calls its visitor serially;
    /// the unchecked Sendable conformance lets that callback build only the compact deduplicated set,
    /// which is emitted after the source scan completes so a failed read cannot publish half a fold.
    private final class ClaudeEntryDeduplication: @unchecked Sendable {
        private(set) var entries: [Entry] = []
        private var exactIndex: [ExactKey: Int] = [:]
        private var messageIndex: [String: [Int]] = [:]

        func append(_ entry: Entry) {
            guard let messageID = entry.messageID else {
                entries.append(entry)
                return
            }
            let key = ExactKey(messageID: messageID, requestID: entry.requestID)
            let collision = exactIndex[key] ?? messageIndex[messageID]?.first(where: { index in
                entry.isSidechain || entries[index].isSidechain
            })

            if let index = collision {
                if ClaudeLogUsageScanner.shouldReplace(candidate: entry, existing: entries[index]) {
                    let old = entries[index]
                    if let oldID = old.messageID {
                        exactIndex.removeValue(forKey: ExactKey(messageID: oldID, requestID: old.requestID))
                    }
                    entries[index] = entry
                    exactIndex[key] = index
                }
                return
            }

            let index = entries.count
            entries.append(entry)
            exactIndex[key] = index
            messageIndex[messageID, default: []].append(index)
        }
    }

    /// Drop replayed usage lines, keeping ccusage's preferences. Entries are keyed by
    /// `(message.id, requestId)`; a second index on `message.id` alone catches sidechain logs that
    /// replay a parent message under a new request id. On a collision the existing entry is replaced
    /// only when the candidate wins `shouldReplace`. Entries without a message id are always kept.
    static func dedup(_ entries: [Entry]) -> [Entry] {
        let deduplication = ClaudeEntryDeduplication()
        JSONLAccountingWorkPacer.shared.forEach(entries) { entry in
            deduplication.append(entry)
        }
        return deduplication.entries
    }

    /// Preference order on a duplicate: the non-sidechain (parent) entry, then the larger token
    /// total, then the entry that carries a `speed` field (richer log shape).
    static func shouldReplace(candidate: Entry, existing: Entry) -> Bool {
        if candidate.isSidechain != existing.isSidechain {
            return existing.isSidechain
        }
        let candidateTotal = candidate.tokens.totalTokens
        let existingTotal = existing.tokens.totalTokens
        if candidateTotal != existingTotal {
            return candidateTotal > existingTotal
        }
        return candidate.hasSpeed && !existing.hasSpeed
    }

    // MARK: - Aggregation

    /// Bucket deduplicated entries into local calendar days. Cost mode "auto": a line's `costUSD`
    /// when present, else tokens priced through `pricing`.
    ///
    /// Rows no pricing source can price still count their tokens (cost dashes, per the owner's
    /// "count tokens, dash cost" policy) and land in `unknownModelsByDay` for the warning triangle
    /// and the reveal system. Every row with a resolvable rate also contributes its tokens' public-
    /// API-rate value to `apiEstimateByDay` — the "if it were all API" comparison — including rows
    /// whose displayed cost is provider-reported.
    static func aggregate(entries: [Entry], since: Date, pricing: ModelPricing) -> LogUsageScan {
        var accumulator = DailyUsageAccumulator()

        JSONLAccountingWorkPacer.shared.forEach(entries) { entry in
            guard entry.timestamp >= since else { return }
            let day = DailyUsageAccumulator.dayKey(from: entry.timestamp)
            // One trimmed slug for pricing, the unknown-model warning, and the breakdown key alike —
            // diverging spellings would let the warning triangle and the hover panel disagree.
            let trimmedModel = entry.model?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let modelName = trimmedModel ?? ModelUsageEntry.unattributedModelName
            // OpenCode Go/Zen gateway turns are folded into the OpenCode card; counting them here
            // double-counts the same dollars/tokens in Total Spend.
            if let trimmedModel, OpenCodeUsageScanner.isHostedGatewayModel(trimmedModel) { return }

            let cost: Double?
            if let carried = entry.costUSD {
                cost = carried
            } else if let model = trimmedModel, let estimated = pricing.estimatedCostDollars(model: model, tokens: entry.tokens) {
                cost = estimated
            } else {
                cost = nil
            }
            if cost == nil, entry.tokens.totalTokens > 0 {
                accumulator.addUnknownModel(day: day, model: modelName)
            }
            accumulator.recordApiEstimate(
                day: day,
                cost: trimmedModel.flatMap { pricing.estimatedCostDollars(model: $0, tokens: entry.tokens) },
                tokens: entry.tokens.totalTokens
            )

            accumulator.add(day: day, tokens: entry.tokens.totalTokens, cost: cost, model: modelName)
        }

        return accumulator.build()
    }
}

private extension UInt8 {
    var isASCIIDigit: Bool { self >= UInt8(ascii: "0") && self <= UInt8(ascii: "9") }
}
