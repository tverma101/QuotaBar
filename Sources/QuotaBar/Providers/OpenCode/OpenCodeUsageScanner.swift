import Darwin
import CoreFoundation
import Foundation
import os

/// The result of a local OpenCode scan: the combined-hosted daily series (for the spend tiles + trend,
/// via `SpendTileMapper`) and the Go-only plan windows (for the meters). `goWindows` is `nil` when the
/// machine has no `opencode-go` footprint at all, so a Zen-only user sees spend tiles without empty caps.
struct OpenCodeUsageScan: Sendable {
    var logScan: LogUsageScan
    var goWindows: OpenCodeGoWindows?
    /// True when the combined series includes cost imputed from token counts — Claude Code sessions
    /// routed through the OpenCode gateway, whose logs carry tokens but no per-message cost — rather
    /// than OpenCode's own recorded cost alone. Drives the ⓘ marker on the spend tiles.
    var includesEstimatedCost: Bool
    /// Local-calendar day keys (`yyyy-MM-dd`) whose totals are PARTIAL: they include Hermes sessions
    /// that are still running (`ended_at IS NULL`). Hermes writes a session's usage ledger in delayed
    /// bursts while it runs, so the fold always reads an incomplete picture for the active session —
    /// the day's number is real but not final, and keeps rising until the session ends. The mapper
    /// marks partial days' tiles with the ⓘ-estimated marker so a live session is never presented as
    /// a settled total. Empty when no tracked Hermes session is in progress.
    var partialDays: Set<String>
}

/// Reads OpenCode's local SQLite logs (`~/.local/share/opencode/opencode*.db`, all release channels) and
/// builds the usage the provider renders. Cookie-free and network-free: the per-message `cost` OpenCode
/// writes for its own hosted gateways is authoritative (Zen models aren't in our pricing snapshots), so
/// it is summed directly rather than re-priced.
///
/// A `Sendable` struct (like the Grok scanner), `async` and nonisolated, so the SQLite reads run off the
/// main actor when the `@MainActor` provider `await`s it.
struct OpenCodeUsageScanner: Sendable {
    struct EffectiveRateKey: Hashable {
        var model: String
        var providerID: String
    }

    /// Other provider tools whose local histories can contain OpenCode-hosted turns. These folds
    /// are only useful while the corresponding card family is enabled.
    enum GatewaySource: String, CaseIterable, Hashable, Sendable {
        case claude
        case codex
        case hermes
        case muse
    }

    /// Per-stage wall-clock attribution for one scan, logged at the end so the closed-panel
    /// accounting cadence's slow fold (~17-21s observed) can be pinned to a stage in the log
    /// file before optimizing it. Only scans slower than the threshold are logged — a healthy
    /// incremental pass must not add a line per 5-minute tick.
    struct StageTimer {
        private var stageStart = Date()
        private var timings: [(name: String, ms: Double)] = []

        mutating func end(_ name: String) {
            let now = Date()
            timings.append((name, now.timeIntervalSince(stageStart) * 1000))
            stageStart = now
        }

        func logIfSlow(thresholdMs: Double = 1500) {
            let total = timings.reduce(0.0) { $0 + $1.ms }
            guard total >= thresholdMs else { return }
            let parts = timings
                .filter { $0.ms >= 5 }
                .map { "\($0.name)=\(Int($0.ms))ms" }
                .joined(separator: " ")
            AppLog.info(.refresh, "opencode scan stages total=\(Int(total))ms [\(parts)]")
        }
    }
    /// The OpenCode-hosted providerIDs we track: the Go subscription and the Zen pay-as-you-go gateway.
    /// Both write an authoritative `cost`; other (BYO-key) providerIDs log `cost: 0` and are out of scope.
    static let hostedProviderIDs = ["opencode-go", "opencode"]
    static let goProviderID = "opencode-go"
    private static let zenProviderID = "opencode"

    var sqlite: SQLiteAccessing
    var databasePaths: @Sendable () throws -> [String]
    /// Roots whose `projects/**/*.jsonl` hold Claude Code sessions routed through the OpenCode
    /// gateway (`anthropic/opencode_go/…` / `anthropic/opencode/…` models). Those sessions burn the
    /// same OpenCode-hosted quota but never appear in `opencode*.db`, so they are folded into the
    /// spend tiles + trend. Empty by default — the production provider wires real discovery, and
    /// tests stay hermetic.
    var claudeRoots: @Sendable () -> [URL]
    /// Stable parse-source identity shared with the native Claude card. The gateway fold reads the
    /// same terminal session files, so it must not create a second whole-file cache for them.
    var claudeCacheIdentity: @Sendable () -> String
    /// Codex homes whose `sessions/` + `archived_sessions/` rollouts may hold gateway-routed turns
    /// (same model prefixes). Parsed with the Codex scanner's own parser. Empty by default.
    var codexHomes: @Sendable () -> [URL]
    /// Hermes' session database, when present — sessions billed to the OpenCode hosted account
    /// (`billing_provider` `opencode-go`/`opencode`) never reach `opencode*.db` and are folded from
    /// here. Nil by default — the production provider wires real discovery.
    var hermesStateDBPath: @Sendable () throws -> String?
    /// CodexRouter's append-only `usage-events.jsonl` ledgers, for the turns it served against an
    /// OpenCode-hosted account. These are Codex-CLI turns, so they live in the router's ledger rather
    /// than `opencode*.db`, and they never reach the Codex card either (it defers them to us) — without
    /// this fold they were simply not counted anywhere.
    var routerLedgerPaths: @Sendable () throws -> [String]
    /// Muse harness roots for `muse-go` sessions (`~/.local/share/muse/sessions/**/*.jsonl`).
    /// Muse routes Muse Spark through the OpenCode Go account via the local `muse-opencode-go-bridge`
    /// (see `~/.hermes/tools/muse-opencode-go-bridge/`), so its `goal_usage_attribution`
    /// with `reported:true` is Go-billed. Empty by default; production wires real discovery.
    var museRoots: @Sendable () -> [URL]
    private let readFailureReporter: UsageLogReadFailureReporter

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        databasePaths: @escaping @Sendable () throws -> [String] = OpenCodeUsageScanner.defaultDatabasePaths,
        claudeRoots: @escaping @Sendable () -> [URL] = { [] },
        claudeCacheIdentity: @escaping @Sendable () -> String = { ClaudeLogUsageScanner.parseSourceIdentity() },
        codexHomes: @escaping @Sendable () -> [URL] = { [] },
        hermesStateDBPath: @escaping @Sendable () throws -> String? = { nil },
        routerLedgerPaths: @escaping @Sendable () throws -> [String] = { [] },
        museRoots: @escaping @Sendable () -> [URL] = { [] },
        readFailureWarning: UsageLogReadFailureReporter.Warning? = nil
    ) {
        self.sqlite = sqlite
        self.databasePaths = databasePaths
        self.claudeRoots = claudeRoots
        self.claudeCacheIdentity = claudeCacheIdentity
        self.codexHomes = codexHomes
        self.hermesStateDBPath = hermesStateDBPath
        self.routerLedgerPaths = routerLedgerPaths
        self.museRoots = museRoots
        self.readFailureReporter = UsageLogReadFailureReporter(
            logTag: LogTag.plugin("opencode"),
            warning: readFailureWarning
        )
    }

    static let defaultDatabasePaths: @Sendable () throws -> [String] = {
        let dir = OpenCodePaths.dataDirectory(
            environment: ProcessEnvironmentReader(),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        return try OpenCodePaths.databaseFiles(in: dir)
    }

    /// A missing implicit Hermes installation is an optional source. An explicit HERMES_HOME is a
    /// configured source even before its state file is created, so disappearance/read errors fail the fold.
    static func configuredHermesStateDBPath(
        environment: EnvironmentReading,
        homeDirectory: URL
    ) throws -> String? {
        let path = HermesPaths.stateDBPath(environment: environment, homeDirectory: homeDirectory)
        if FileManager.default.fileExists(atPath: path) { return path }
        let configuredHome = environment.value(for: "HERMES_HOME")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return configuredHome == nil ? nil : path
    }

    /// The implicit router ledger is optional until it appears. Environment-selected ledger paths are
    /// explicit sources; keep them in the set so the scan can detect deletion or read failure.
    static func configuredRouterLedgerPaths(
        environment: EnvironmentReading,
        homeDirectory: URL
    ) -> [String] {
        let paths = CodexRouterUsageScanner.defaultLedgerPaths(
            environment: environment,
            homeDirectory: homeDirectory
        )
        let isConfigured = [
            "OPENUSAGE_CODEX_ROUTER_USAGE_EVENTS",
            "CODEX_ROUTER_STATE_DIR",
            "MODEL_ROUTER_STATE_DIR"
        ].contains { key in
            environment.value(for: key)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty != nil
        }
        guard !isConfigured, let optionalPath = paths.first else { return paths }
        var metadata = stat()
        guard Darwin.lstat(optionalPath, &metadata) != 0, errno == ENOENT else { return paths }
        return []
    }

    /// Claude Code config roots (with a `projects/` folder), mirroring the Claude scanner's discovery:
    /// `CLAUDE_CONFIG_DIR` when set (a comma-separated list), else `$XDG_CONFIG_HOME/claude` and
    /// `~/.claude`. The desktop app's per-session Cowork sandboxes are not scanned — OpenCode gateway
    /// sessions run through the terminal CLI's config, and the sandboxes' logs are already accounted
    /// for by the Claude provider when they use Claude models.
    static func discoverClaudeRoots(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) -> [URL] {
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
            for part in raw.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
                var url = URL(fileURLWithPath: expandHome(part))
                if url.lastPathComponent == "projects", FileManager.default.fileExists(atPath: url.path) {
                    url.deleteLastPathComponent()
                }
                addIfValid(url)
            }
        } else {
            let home = homeDirectory()
            let xdg = environment.value(for: "XDG_CONFIG_HOME")?.nilIfEmpty.map { URL(fileURLWithPath: expandHome($0)) }
                ?? home.appendingPathComponent(".config")
            addIfValid(xdg.appendingPathComponent("claude"))
            addIfValid(home.appendingPathComponent(".claude"))
        }
        return roots
    }

    /// Canonicalize and deduplicate Codex homes before the gateway fold. The native Codex cards and
    /// the supplementary fold can receive the same home through the default path, an environment
    /// override, and an app registration; a stable one-home-at-a-time plan keeps those aliases from
    /// multiplying discovery and parse work.
    static func uniqueCodexHomes(_ homes: [URL]) -> [URL] {
        var seen: Set<String> = []
        return homes.compactMap { home in
            let canonical = home.resolvingSymlinksInPath().standardizedFileURL
            guard seen.insert(canonical.path).inserted else { return nil }
            return canonical
        }
    }

    /// Split canonical Codex homes into managed/non-default vs default `~/.codex`, using the same
    /// path standardization as `CodexLogUsageScanner.sessionFiles` (`resolve` + `standardizedFileURL`).
    /// Default homes are scanned without stripping hardlinks via managed peers; managed homes are
    /// scanned with `peerHomes` including default so shared hardlinks stay on `~/.codex`.
    static func partitionCodexHomes(
        _ homes: [URL],
        homeDirectory: @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) -> (managed: [URL], defaultHomes: [URL]) {
        let defaultCodexPath = homeDirectory()
            .appendingPathComponent(".codex")
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        var managed: [URL] = []
        var defaultHomes: [URL] = []
        for home in uniqueCodexHomes(homes) {
            if home.resolvingSymlinksInPath().standardizedFileURL.path == defaultCodexPath {
                defaultHomes.append(home)
            } else {
                managed.append(home)
            }
        }
        return (managed, defaultHomes)
    }

    private static func expandHome(_ path: String) -> String {
        guard path.hasPrefix("~/") else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + path.dropFirst(1)
    }

    /// Scan the last `daysBack` days. Returns `nil` only when there is no OpenCode database at all (→ the
    /// provider shows "No data"); a present-but-empty database yields an empty scan (idle tiles collapse
    /// to "No data" via `SpendTileMapper`). Throws `databaseUnreadable` when databases exist but none
    /// could be read — an all-failed refresh has no data source and must not render as zero usage.
    /// Escaping fold visits mutate OpenCode accumulators through this box.
    private final class GatewayFoldState: @unchecked Sendable {
        let scanSince: Date
        let maximumTimestamp: Date
        let pricing: ModelPricing
        let rates: [EffectiveRateKey: Double]
        /// Complete (local day, model, Codex identity) pairs the router ledger can replace in that
        /// account's native Codex logs. Claude, Hermes, and Muse are independent sources.
        let routerCoverage: Set<String>
        let routerAccountIdentityKeys: [String: String]
        var accumulator: DailyUsageAccumulator
        var goWindowCosts: [(ms: Double, cost: Double)]
        var includesEstimatedCost: Bool
        var partialDays: Set<String>
        var nativeCoverage: Set<String> = []
        var sawFutureTimestamp = false

        init(
            scanSince: Date,
            maximumTimestamp: Date,
            pricing: ModelPricing,
            rates: [EffectiveRateKey: Double],
            routerCoverage: Set<String>,
            routerAccountIdentityKeys: [String: String],
            accumulator: DailyUsageAccumulator,
            goWindowCosts: [(ms: Double, cost: Double)],
            includesEstimatedCost: Bool,
            partialDays: Set<String>
        ) {
            self.scanSince = scanSince
            self.maximumTimestamp = maximumTimestamp
            self.pricing = pricing
            self.rates = rates
            self.routerCoverage = routerCoverage
            self.routerAccountIdentityKeys = routerAccountIdentityKeys
            self.accumulator = accumulator
            self.goWindowCosts = goWindowCosts
            self.includesEstimatedCost = includesEstimatedCost
            self.partialDays = partialDays
        }

        func foldClaude(_ entry: ClaudeLogUsageScanner.Entry) {
            guard entry.tokens.totalTokens > 0 || (entry.costUSD ?? 0) > 0 else { return }
            guard entry.timestamp <= maximumTimestamp else {
                sawFutureTimestamp = true
                return
            }
            let rows = OpenCodeUsageScanner.claudeGatewayRows(from: [entry])
            OpenCodeUsageScanner.foldGatewayRows(
                rows,
                since: scanSince, pricing: pricing, effectiveRates: rates,
                accumulator: &accumulator, goWindowCosts: &goWindowCosts,
                includesEstimatedCost: &includesEstimatedCost, partialDays: &partialDays
            )
        }

        func foldCodex(_ event: CodexLogUsageScanner.Event, accountIdentityKey: String?) {
            guard event.total > 0 || event.input > 0 || event.cached > 0 || event.output > 0 || event.reasoning > 0 else { return }
            guard event.timestamp <= maximumTimestamp else {
                sawFutureTimestamp = true
                return
            }
            let rows = OpenCodeUsageScanner.codexGatewayRows(from: [event])
            let rowsToFold = rows.filter { row in
                guard let accountIdentityKey else { return true }
                let key = OpenCodeUsageScanner.dayModelAccountKey(
                    row,
                    accountIdentityKey: accountIdentityKey,
                    pricing: pricing
                )
                nativeCoverage.insert(key)
                return OpenCodeUsageScanner.shouldFoldNativeCodexRow(
                    row,
                    accountIdentityKey: accountIdentityKey,
                    completeRouterCoverage: routerCoverage,
                    pricing: pricing
                )
            }
            OpenCodeUsageScanner.foldGatewayRows(
                rowsToFold,
                since: scanSince, pricing: pricing, effectiveRates: rates,
                accumulator: &accumulator, goWindowCosts: &goWindowCosts,
                includesEstimatedCost: &includesEstimatedCost, partialDays: &partialDays
            )
        }
    }

    /// Legacy unscoped merge key retained for isolated fold helpers. Production source reconciliation
    /// uses `dayModelAccountKey` because a model and day alone can collide across accounts.
    static func dayModelKey(day: String, model: String) -> String {
        day + "\u{1f}" + model
    }

    static func dayModelKey(_ row: ClaudeGatewayRow) -> String {
        dayModelKey(day: DailyUsageAccumulator.dayKey(from: row.date), model: row.model)
    }

    private static func reconciliationModelName(_ model: String, pricing: ModelPricing?) -> String {
        guard let pricing else { return model }
        return DailyUsageAccumulator.codexCrossSourceModelIdentity(model, pricing: pricing)
    }

    static func dayModelAccountKey(
        day: String,
        model: String,
        accountIdentityKey: String,
        pricing: ModelPricing? = nil
    ) -> String {
        day + "\u{1f}" + reconciliationModelName(model, pricing: pricing) + "\u{1f}" + accountIdentityKey.lowercased()
    }

    static func dayModelAccountKey(
        _ row: ClaudeGatewayRow,
        accountIdentityKey: String,
        pricing: ModelPricing? = nil
    ) -> String {
        dayModelAccountKey(
            day: DailyUsageAccumulator.dayKey(from: row.date),
            model: row.model,
            accountIdentityKey: accountIdentityKey,
            pricing: pricing
        )
    }

    /// A router row can reconcile only when every account identifier it carries maps to the same
    /// enabled Codex identity. Missing, unknown, or contradictory identifiers stay unscoped.
    static func routerAccountIdentityKey(
        for row: ClaudeGatewayRow,
        identifiersToIdentityKeys: [String: String]
    ) -> String? {
        routerAccountIdentityKey(
            accountId: row.accountId,
            accountFingerprint: row.accountFingerprint,
            identifiersToIdentityKeys: identifiersToIdentityKeys
        )
    }

    static func routerAccountIdentityKey(
        accountId: String?,
        accountFingerprint: String?,
        identifiersToIdentityKeys: [String: String]
    ) -> String? {
        let identifiers = [accountId, accountFingerprint].compactMap {
            $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfEmpty
        }
        guard !identifiers.isEmpty else { return nil }
        let resolved = identifiers.compactMap { identifiersToIdentityKeys[$0] }
        guard resolved.count == identifiers.count,
              let identity = resolved.first,
              resolved.allSatisfy({ $0 == identity })
        else { return nil }
        return identity.lowercased()
    }

    /// Exclude rows only when their account resolves positively to a disabled identity. Missing,
    /// unknown, or contradictory IDs are still useful token evidence and remain additive.
    static func routerRowsForEnabledAccounts(
        _ rows: [ClaudeGatewayRow],
        enabledIdentityKeys: Set<String>?,
        identifiersToIdentityKeys: [String: String]
    ) -> [ClaudeGatewayRow] {
        guard let enabledIdentityKeys else { return rows }
        let enabled = Set(enabledIdentityKeys.map { $0.lowercased() })
        return rows.filter { row in
            guard let identity = routerAccountIdentityKey(
                for: row, identifiersToIdentityKeys: identifiersToIdentityKeys
            ) else { return true }
            return enabled.contains(identity)
        }
    }

    static func shouldFoldNativeCodexRow(
        _ row: ClaudeGatewayRow,
        accountIdentityKey: String,
        completeRouterCoverage: Set<String>,
        pricing: ModelPricing? = nil
    ) -> Bool {
        !completeRouterCoverage.contains(dayModelAccountKey(
            row,
            accountIdentityKey: accountIdentityKey,
            pricing: pricing
        ))
    }

    /// A router pair only owns its resolved Codex account's native fold when all rows for that
    /// local day/model/account carry measured input and a reconciled cost breakdown. Older cached
    /// or unresolvable rows cannot suppress native usage.
    static func completeRouterCoverage(
        from rows: [ClaudeGatewayRow],
        identifiersToIdentityKeys: [String: String] = [:],
        pricing: ModelPricing? = nil
    ) -> Set<String> {
        var completeness: [String: Bool] = [:]
        for row in rows {
            guard row.tokens > 0 else { continue }
            guard let identity = routerAccountIdentityKey(
                for: row, identifiersToIdentityKeys: identifiersToIdentityKeys
            ) else { continue }
            let key = dayModelAccountKey(row, accountIdentityKey: identity, pricing: pricing)
            completeness[key] = (completeness[key] ?? true) && row.hasCompleteRouterCounts
        }
        var result: Set<String> = []
        for (key, complete) in completeness where complete {
            result.insert(key)
        }
        return result
    }

    /// An incomplete router row remains a fallback when no matching native Codex row exists. If that
    /// account-scoped native source is available, use its measured counts and avoid duplicate router output.
    static func reconciledRouterRows(
        _ rows: [ClaudeGatewayRow],
        completeCoverage: Set<String>,
        nativeCoverage: Set<String>,
        identifiersToIdentityKeys: [String: String] = [:],
        pricing: ModelPricing? = nil
    ) -> [ClaudeGatewayRow] {
        rows.filter { row in
            guard let identity = routerAccountIdentityKey(
                for: row, identifiersToIdentityKeys: identifiersToIdentityKeys
            ) else { return true }
            let key = dayModelAccountKey(row, accountIdentityKey: identity, pricing: pricing)
            return completeCoverage.contains(key) || !nativeCoverage.contains(key)
        }
    }

    func scan(
        now: Date,
        daysBack: Int = UsageHistoryWindow.previousDays,
        pricing: ModelPricing = .empty,
        windowFallbackOnly: Bool = false,
        gatewaySources: Set<GatewaySource> = Set(GatewaySource.allCases),
        enabledCodexHomes: [URL]? = nil,
        enabledClaudeScanners: [ClaudeLogUsageScanner]? = nil,
        enabledCodexIdentityKeys: Set<String>? = nil,
        codexHomeIdentityKeys: [String: String]? = nil,
        codexAccountIdentityKeys: [String: String] = [:],
        routerAccountIdentityKeys: [String: String] = [:]
    ) async throws -> OpenCodeUsageScan? {
        guard !Task.isCancelled else { return nil }
        let paths: [String]
        do {
            paths = try databasePaths()
        } catch {
            // The data directory exists but couldn't be enumerated — same failure class as unreadable
            // databases, edge-logged through the reporter so a persistent failure doesn't spam.
            let marker = "<data directory>"
            let newlyFailing = await readFailureReporter.update(checkedPaths: [marker], failingPaths: [marker])
            if !newlyFailing.isEmpty {
                AppLog.warn(LogTag.plugin("opencode"), "data directory unreadable: \(error.localizedDescription)")
            }
            throw OpenCodeUsageError.databaseUnreadable
        }
        if paths.isEmpty {
            await readFailureReporter.update(checkedPaths: [], failingPaths: [])
        }

        var stageTimer = StageTimer()
        // Same calendar bound the tiles/trend use. A wall-clock `now - daysBack×86400` cutoff sits
        // later the same day, so morning rows on the oldest day never leave SQLite.
        let cutoffDate = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let cutoffMs = Int(cutoffDate.timeIntervalSince1970 * 1000)
        // These local rows are written on this machine. Allow a small clock skew, but reject
        // implausible future values so they cannot create future-day buckets or poison last-good data.
        let maximumTimestampMs = (now.timeIntervalSince1970 + 5 * 60) * 1000
        var rows: [Row] = []
        var anchorMs: Double?
        var checked: Set<String> = []
        var failures: [String: String] = [:]

        for path in paths {
            // sqlite3 is a synchronous subprocess (bounded to five seconds). A disable cannot stop the
            // query already running, but this prevents later database/anchor queries from starting.
            guard !Task.isCancelled else { return nil }
            checked.insert(path)
            do {
                guard let json = try JSONLAccountingWorkPacer.shared.perform({
                    try sqlite.queryValue(path: path, sql: Self.dataSQL(cutoffMs: cutoffMs))
                }) else {
                    failures[path] = "usage query returned no result"
                    continue
                }
                guard !Task.isCancelled else { return nil }
                guard let parsedRows = JSONLAccountingWorkPacer.shared.perform({
                    Self.parseRows(json, maximumTimestampMs: maximumTimestampMs)
                }) else {
                    failures[path] = "usage rows contain malformed accounting values"
                    continue
                }
                rows.append(contentsOf: parsedRows)
            } catch {
                guard !Task.isCancelled else { return nil }
                failures[path] = error.localizedDescription
                continue
            }
            guard !Task.isCancelled else { return nil }
            // Monthly cycle anchor: the earliest-ever local Go usage (unbounded, so it survives the
            // day-window cutoff). Best-effort per path — anchor failures are edge-warned (not silent)
            // so a persistently broken anchor query surfaces once, then falls back to calendar month.
            //
            // The anchor is memoized per database revision: it is a full-history MIN() scan that
            // cannot change unless the database file changes (any write moves size/mtime, which the
            // memo key catches, including a deleted oldest session), yet it re-ran on every refresh.
            let memoKey = Self.goAnchorMemoKey(path: path)
            if let memoKey, let anchor = Self.cachedGoAnchor(key: memoKey) {
                anchorMs = Swift.min(anchorMs ?? anchor, anchor)
            } else {
                let anchorDiagnosticKey = "opencode.sqlite.anchor.\(JSONLScanCachePaths.stableFingerprint(path))"
                do {
                    guard !Task.isCancelled else { return nil }
                    let text = try JSONLAccountingWorkPacer.shared.perform({
                        try sqlite.queryValue(path: path, sql: Self.anchorSQL)
                    })
                    DiagnosticGate.clearFailure(anchorDiagnosticKey)
                    if let text,
                       let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        guard !Task.isCancelled else { return nil }
                        anchorMs = Swift.min(anchorMs ?? value, value)
                        if let memoKey {
                            Self.storeGoAnchor(key: memoKey, anchorMs: value)
                        }
                    }
                } catch {
                    guard !Task.isCancelled else { return nil }
                    DiagnosticGate.logOnce(for: anchorDiagnosticKey) {
                        AppLog.warn(LogTag.plugin("opencode"), "anchor query failed for \(path): \(error.localizedDescription) — monthly window falls back to calendar month")
                    }
                }
            }
        }
        guard !Task.isCancelled else { return nil }
        // Per-path detail is logged only for newly failing paths (the reporter edge-triggers), so a
        // persistently locked database warns once, not on every 5-minute refresh.
        let newlyFailing = await readFailureReporter.update(checkedPaths: checked, failingPaths: Set(failures.keys))
        for path in newlyFailing.sorted() {
            AppLog.warn(LogTag.plugin("opencode"), "usage query failed for \(path): \(failures[path] ?? "unknown error")")
        }
        stageTimer.end("sqlite")
        if !failures.isEmpty {
            throw OpenCodeUsageError.databaseUnreadable
        }

        // Combined hosted daily series (opencode-go + opencode) → the spend tiles + usage trend. Cost is
        // authoritative, so every row is "priced": feed it straight into the shared accumulator.
        // Same window the tiles label (today + the previous 29 days), so the sum matches the label.
        let scanSince = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let tileSince = JSONLScanning.sinceDate(daysBack: UsageHistoryWindow.previousDays, now: now)
        var accumulator = DailyUsageAccumulator()
        JSONLAccountingWorkPacer.shared.forEach(rows) { row in
            let date = Date(timeIntervalSince1970: row.ms / 1000)
            guard date >= scanSince else { return }
            accumulator.add(
                day: DailyUsageAccumulator.dayKey(from: date),
                tokens: row.tokens, cost: row.cost, model: row.model,
                tokenCountSaturated: row.tokenCountSaturated
            )
        }

        // Claude Code sessions routed through the OpenCode gateway (`anthropic/opencode_go/…` and
        // `anthropic/opencode/…` model ids) burn the same OpenCode-hosted quota but never land in
        // `opencode*.db`. Fold their measured tokens into the tiles + trend. Their logs carry no
        // per-message cost, so dollars are imputed from token counts through the pricing engine —
        // which marks the whole series as estimated (ⓘ) and leaves unpriced models to the unknown-
        // model warning, the same convention the Claude tiles use.
        var includesEstimatedCost = false
        // Days (local `yyyy-MM-dd`) that hold still-running Hermes sessions (`ended_at IS NULL`):
        // Hermes finalizes a session's usage ledger in delayed bursts, so those days' totals are
        // partial — real but not final. Carried to the tiles so a live session is marked ⓘ instead
        // of being presented as a settled number.
        var partialDays: Set<String> = []
        // Go-cap window costs: the Go subscription's recorded `opencode*.db` rows, to which the
        // gateway folds below append their imputed dollars (Claude Code / Codex / Hermes burn the
        // same Go quota but never reach the DB; Zen pay-as-you-go usage is excluded — it bills
        // separately, not against the Session / Weekly / Monthly caps).
        var goWindowCosts: [(ms: Double, cost: Double)] = []
        goWindowCosts.reserveCapacity(rows.count)
        JSONLAccountingWorkPacer.shared.forEach(rows) { row in
            if row.providerID == Self.goProviderID, let cost = row.cost {
                goWindowCosts.append((ms: row.ms, cost: cost))
            }
        }
        // Claude Code sessions routed through the gateway — parsed with the Claude scanner's own
        // incremental parser (a persistent cache shared with the Claude card, so unchanged session
        // logs aren't re-parsed on every 5-minute refresh). Their logs carry no per-message cost, so
        // dollars are imputed from token counts: at the provider's OWN recorded average rate for the
        // model when `opencode*.db` has billed rows for it (the gateway bills DeepSeek cache hits at
        // a fraction of the sticker input rate, so the recorded average can sit ~15x below the
        // catalog miss rate — charging every token at the miss rate would overstate spend by the
        // same factor), else through the pricing engine. Either way the series is marked estimated
        // (ⓘ) and unpriced models fall to the unknown-model warning, the convention the Claude
        // tiles use.
        // Current spend tiles use a recent observed average. Older rates can differ after a provider
        // changes pricing or cache billing, so lifetime history must not recalibrate today's tile.
        let rates = Self.effectiveRates(from: rows.filter { Date(timeIntervalSince1970: $0.ms / 1000) >= tileSince })
        stageTimer.end("accumulate")
        if windowFallbackOnly {
            // Meters-only pass needs window caps but the account API didn't answer: stop after the
            // SQLite stage. The Go-cap windows derive from the recorded `opencode-go` DB rows (plus
            // the memoized anchor) alone — the corpus folds below would append imputed gateway
            // dollars to the window math, but they cost 15-20s and the meters-only phase must stay
            // fast; the fold passes (panel accounting, full) refresh the windows with the complete
            // fold. `logScan` stays empty: tiles are not this pass's work, and the store's merge
            // keeps the prior tiles on the card.
            let goWindows = goWindowCosts.isEmpty
                ? nil
                : OpenCodeGoWindowMath.compute(costs: goWindowCosts, anchorMs: anchorMs, now: now)
            stageTimer.logIfSlow()
            return OpenCodeUsageScan(
                logScan: DailyUsageAccumulator().build(),
                goWindows: goWindows,
                includesEstimatedCost: false,
                partialDays: []
            )
        }
        // Read the router ledger FIRST. Complete, identity-resolved pairs can replace matching native
        // Codex log rows; Claude, Hermes, and Muse sessions remain independent sources.
        var routerRows: [ClaudeGatewayRow] = []
        var seenLedgerPaths: Set<String> = []
        var routerSourceSnapshots: [String: OpenCodeRouterLedger.SourceSnapshot] = [:]
        if gatewaySources.contains(.codex) {
            let discoveredLedgerPaths: [String]
            do {
                discoveredLedgerPaths = try routerLedgerPaths()
            } catch {
                throw OpenCodeUsageError.usageSourcesIncomplete
            }
            for path in discoveredLedgerPaths.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
            where seenLedgerPaths.insert(path).inserted {
                guard !Task.isCancelled else { return nil }
                guard FileManager.default.fileExists(atPath: path),
                      FileManager.default.isReadableFile(atPath: path),
                      let result = Self.routerGatewayRowsWithSourceIfComplete(
                        atPath: path,
                        since: scanSince,
                        maximumTimestamp: JSONLScanning.maximumTimestamp(now: now),
                        enabledIdentityKeys: enabledCodexIdentityKeys,
                        identifiersToIdentityKeys: codexAccountIdentityKeys
                      )
                else {
                    throw OpenCodeUsageError.usageSourcesIncomplete
                }
                routerRows += result.rows
                routerSourceSnapshots[path] = result.source
            }
        }
        routerRows = Self.routerRowsForEnabledAccounts(
            routerRows,
            enabledIdentityKeys: enabledCodexIdentityKeys,
            identifiersToIdentityKeys: codexAccountIdentityKeys
        )
        let routerCoverage = Self.completeRouterCoverage(
            from: routerRows,
            identifiersToIdentityKeys: routerAccountIdentityKeys,
            pricing: pricing
        )
        stageTimer.end("routerLedger")
        // Stream Claude/Codex gateway rows; unload Codex tail-cache between homes so peaks cannot stack.
        let gatewayFold = GatewayFoldState(
            scanSince: scanSince,
            maximumTimestamp: JSONLScanning.maximumTimestamp(now: now),
            pricing: pricing,
            rates: rates,
            routerCoverage: routerCoverage,
            routerAccountIdentityKeys: routerAccountIdentityKeys,
            accumulator: accumulator,
            goWindowCosts: goWindowCosts,
            includesEstimatedCost: includesEstimatedCost,
            partialDays: partialDays
        )
        if gatewaySources.contains(.claude) {
            let scanners = enabledClaudeScanners ?? [ClaudeLogUsageScanner()]
            let roots = claudeRoots()
            for scanner in scanners {
                guard !Task.isCancelled else { return nil }
                let complete = await scanner.foldParsedEntries(
                    daysBack: daysBack, now: now, roots: roots,
                    cacheIdentityOverride: claudeCacheIdentity()
                ) { entry in
                    gatewayFold.foldClaude(entry)
                }
                guard complete, !gatewayFold.sawFutureTimestamp else {
                    if gatewayFold.sawFutureTimestamp {
                        DiagnosticGate.logOnce(for: "opencode.gateway.future-timestamp") {
                            AppLog.warn(LogTag.plugin("opencode"), "local session usage contains a timestamp more than five minutes ahead; preserving last-good history")
                        }
                    }
                    throw OpenCodeUsageError.usageSourcesIncomplete
                }
            }
        }
        stageTimer.end("claudeFold")
        if gatewaySources.contains(.codex) {
            let partitionedCodex = Self.partitionCodexHomes(enabledCodexHomes ?? codexHomes())
            let rolloutNameDeduper = CodexRolloutNameDeduper()
            func accountIdentityKey(for home: URL) -> String? {
                let path = home.resolvingSymlinksInPath().standardizedFileURL.path
                return codexHomeIdentityKeys?[path]?.lowercased()
            }
            for home in partitionedCodex.defaultHomes {
                let accountIdentityKey = accountIdentityKey(for: home)
                guard !Task.isCancelled else { return nil }
                let complete = await CodexLogUsageScanner().foldHostedGatewayEvents(
                    daysBack: daysBack, now: now, homes: [home],
                    rolloutNameDeduper: rolloutNameDeduper
                ) { event in
                    gatewayFold.foldCodex(event, accountIdentityKey: accountIdentityKey)
                }
                guard complete, !gatewayFold.sawFutureTimestamp else {
                    if gatewayFold.sawFutureTimestamp {
                        DiagnosticGate.logOnce(for: "opencode.gateway.future-timestamp") {
                            AppLog.warn(LogTag.plugin("opencode"), "local session usage contains a timestamp more than five minutes ahead; preserving last-good history")
                        }
                    }
                    throw OpenCodeUsageError.usageSourcesIncomplete
                }
                CodexLogUsageScanner.unloadSharedTailCacheItems()
            }
            for home in partitionedCodex.managed {
                let accountIdentityKey = accountIdentityKey(for: home)
                guard !Task.isCancelled else { return nil }
                let complete = await CodexLogUsageScanner(peerHomes: partitionedCodex.defaultHomes).foldHostedGatewayEvents(
                    daysBack: daysBack, now: now, homes: [home],
                    rolloutNameDeduper: rolloutNameDeduper
                ) { event in
                    gatewayFold.foldCodex(event, accountIdentityKey: accountIdentityKey)
                }
                guard complete, !gatewayFold.sawFutureTimestamp else {
                    if gatewayFold.sawFutureTimestamp {
                        DiagnosticGate.logOnce(for: "opencode.gateway.future-timestamp") {
                            AppLog.warn(LogTag.plugin("opencode"), "local session usage contains a timestamp more than five minutes ahead; preserving last-good history")
                        }
                    }
                    throw OpenCodeUsageError.usageSourcesIncomplete
                }
                CodexLogUsageScanner.unloadSharedTailCacheItems()
            }
        }
        accumulator = gatewayFold.accumulator
        goWindowCosts = gatewayFold.goWindowCosts
        includesEstimatedCost = gatewayFold.includesEstimatedCost
        partialDays = gatewayFold.partialDays
        stageTimer.end("codexFold")
        // Hermes sessions billed to the OpenCode hosted account — they never reach `opencode*.db`.
        // If its database cannot be read, the combined fold is incomplete: publishing the readable
        // OpenCode/router subset would silently omit this independent source and understate spend.
        // Keep the last complete snapshot and edge-log the failure until the database recovers.
        let hermesPath: String?
        do {
            hermesPath = gatewaySources.contains(.hermes) ? try hermesStateDBPath() : nil
        } catch {
            throw OpenCodeUsageError.usageSourcesIncomplete
        }
        if let hermesPath {
            guard FileManager.default.fileExists(atPath: hermesPath),
                  FileManager.default.isReadableFile(atPath: hermesPath)
            else {
                let newlyFailing = await readFailureReporter.update(
                    checkedPaths: [hermesPath], failingPaths: [hermesPath]
                )
                if !newlyFailing.isEmpty {
                    AppLog.warn(LogTag.plugin("opencode"), "Hermes session database is missing or unreadable: \(hermesPath) — keeping the last complete history")
                }
                throw OpenCodeUsageError.usageSourcesIncomplete
            }
            do {
                guard !Task.isCancelled else { return nil }
                guard let json = try JSONLAccountingWorkPacer.shared.perform({
                    try sqlite.queryValue(
                        path: hermesPath,
                        sql: Self.hermesGatewaySQL(cutoffSeconds: Double(cutoffMs) / 1000)
                    )
                }) else {
                    throw OpenCodeUsageError.usageSourcesIncomplete
                }
                guard !Task.isCancelled else { return nil }
                guard let rows = JSONLAccountingWorkPacer.shared.perform({
                    Self.parseHermesGatewayRows(
                        json,
                        maximumTimestamp: JSONLScanning.maximumTimestamp(now: now)
                    )
                }) else {
                    throw OpenCodeUsageError.usageSourcesIncomplete
                }
                Self.foldGatewayRows(
                    rows,
                    since: scanSince, pricing: pricing,
                    effectiveRates: rates,
                    accumulator: &accumulator, goWindowCosts: &goWindowCosts,
                    includesEstimatedCost: &includesEstimatedCost, partialDays: &partialDays
                )
                guard !Task.isCancelled else { return nil }
                await readFailureReporter.update(checkedPaths: [hermesPath], failingPaths: [])
            } catch {
                guard !Task.isCancelled else { return nil }
                let newlyFailing = await readFailureReporter.update(checkedPaths: [hermesPath], failingPaths: [hermesPath])
                if !newlyFailing.isEmpty {
                    AppLog.warn(LogTag.plugin("opencode"), "Hermes session database \(hermesPath): \(error.localizedDescription) — Hermes usage is not folded into this card until it recovers")
                }
                throw OpenCodeUsageError.usageSourcesIncomplete
            }
        }
        // Fold router rows after native Codex discovery. Complete pairs were used instead of their
        // account-matched native copies. An incomplete router pair stays only when no matching native
        // row was available; otherwise the native row supplies the measured counts.
        stageTimer.end("hermes")
        if !routerRows.isEmpty {
            guard !Task.isCancelled else { return nil }
            Self.foldGatewayRows(
                Self.reconciledRouterRows(
                    routerRows,
                    completeCoverage: routerCoverage,
                    nativeCoverage: gatewayFold.nativeCoverage,
                    identifiersToIdentityKeys: gatewayFold.routerAccountIdentityKeys,
                    pricing: pricing
                ),
                since: scanSince, pricing: pricing,
                effectiveRates: rates,
                accumulator: &accumulator, goWindowCosts: &goWindowCosts,
                includesEstimatedCost: &includesEstimatedCost, partialDays: &partialDays
            )
        }
        // Muse harness sessions via the local `muse-opencode-go-bridge` — same Go account,
        // same `muse-spark-1.*` billed quota. Muse's `goal_usage_attribution` with
        // `reported:true` carries per-step provider tokens; without this fold the tiles +
        // meter-detail dollars undercount Muse spend by omitting the harness entirely.
        if gatewaySources.contains(.muse) {
            let museRootsValue = museRoots()
            if !museRootsValue.isEmpty {
                guard !Task.isCancelled else { return nil }
                guard let museEntries = await MuseUsageScanner().parsedEntriesIfComplete(
                    daysBack: daysBack, now: now, roots: museRootsValue
                ) else { throw OpenCodeUsageError.usageSourcesIncomplete }
                guard !Task.isCancelled else { return nil }
                Self.foldGatewayRows(
                    Self.museGatewayRows(from: museEntries), since: scanSince, pricing: pricing,
                    effectiveRates: rates,
                    accumulator: &accumulator, goWindowCosts: &goWindowCosts,
                    includesEstimatedCost: &includesEstimatedCost, partialDays: &partialDays
                )
            }
        }
        stageTimer.end("museFold")
        guard !Task.isCancelled else { return nil }
        if gatewaySources.contains(.codex) {
            let finalLedgerPaths: Set<String>
            do {
                finalLedgerPaths = Set(try routerLedgerPaths().map {
                    URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
                })
            } catch {
                throw OpenCodeUsageError.usageSourcesIncomplete
            }
            guard finalLedgerPaths == seenLedgerPaths,
                  routerSourceSnapshots.count == seenLedgerPaths.count,
                  routerSourceSnapshots.allSatisfy({ source in
                      Self.routerGatewaySourceIsCurrent(source.value, atPath: source.key)
                  })
            else { throw OpenCodeUsageError.usageSourcesIncomplete }
        }
        let logScan = accumulator.build()
        stageTimer.end("build")
        // Hosted turns can still be present in CodexRouter, Claude, Hermes, or Muse logs when the
        // OpenCode SQLite database is absent. Return those folds; retain the meters-only behavior
        // when neither SQLite nor any independent source produced history.
        if paths.isEmpty, logScan.series.daily.isEmpty {
            return nil
        }
        DiagnosticGate.clearFailure("opencode.gateway.future-timestamp")

        // Local fallback windows need current Go spend. A key's presence alone does not prove an active
        // subscription; the provider uses the account endpoint to confirm that case.
        let goWindows: OpenCodeGoWindows? = !goWindowCosts.isEmpty
            ? OpenCodeGoWindowMath.compute(costs: goWindowCosts, anchorMs: anchorMs, now: now)
            : nil
        stageTimer.logIfSlow()

        return OpenCodeUsageScan(
            logScan: logScan,
            goWindows: goWindows,
            includesEstimatedCost: includesEstimatedCost,
            partialDays: partialDays
        )
    }

    /// Cheap local probe for `hasLocalCredentials()`: does any tracked database hold at least one hosted
    /// assistant row with a numeric cost? Read-only, no network. An unreadable data directory or
    /// database counts as an OpenCode footprint so a selected provider can surface the real error.
    func hasHostedUsage() -> Bool {
        let paths: [String]
        do {
            paths = try databasePaths()
        } catch {
            AppLog.warn(LogTag.plugin("opencode"), "usage probe: data directory unreadable: \(error.localizedDescription)")
            return true
        }
        for path in paths {
            do {
                if let value = try sqlite.queryValue(path: path, sql: Self.probeSQL), !value.isEmpty {
                    return true
                }
            } catch {
                AppLog.warn(LogTag.plugin("opencode"), "usage probe failed for \(path): \(error.localizedDescription)")
                // We cannot establish that this database is empty. Keep OpenCode enabled so refresh
                // can surface the database read error instead of recording a one-shot detection miss.
                return true
            }
        }
        return false
    }

    // MARK: - Claude Code gateway sessions

    /// Model-id prefixes that identify Claude Code sessions routed through the OpenCode gateway.
    /// `anthropic/opencode_go/<model>` is the Go subscription, `anthropic/opencode/<model>` the Zen
    /// gateway — the same two provider ids the SQLite scan tracks.
    static let claudeGatewayPrefixes = ["anthropic/opencode_go/", "anthropic/opencode/"]

    /// One priced session message from a Claude Code log, normalized like the SQLite rows.
    struct ClaudeGatewayRow {
        var date: Date
        var input: Int
        var output: Int
        var cacheWrite: Int
        var cacheRead: Int
        var model: String
        /// A router's explicitly reported total may disagree with its components. Preserve that
        /// provider count for token totals while marking its cost breakdown incomplete.
        var totalTokens: Int? = nil
        /// Whether this session burns the Go SUBSCRIPTION's quota (`anthropic/opencode_go/…`,
        /// billing_provider `opencode-go`) rather than the Zen pay-as-you-go gateway — only Go
        /// usage counts against the Session / Weekly / Monthly cap meters' local dollar context.
        var burnsGoQuota: Bool
        /// True for Hermes sessions that are STILL RUNNING (`ended_at IS NULL`): Hermes writes a
        /// session's usage ledger in delayed bursts, so the fold's view of an in-progress session is
        /// partial and keeps growing until the session ends. The row's day is marked partial and its
        /// tiles carry the ⓘ marker instead of being presented as a settled total. Always false for
        /// the Claude/Codex log folds — those CLIs write per-message in real time, so their rows are
        /// complete as recorded.
        var isInProgress: Bool
        /// Summed day/model bucket, not one ledger event. Long-context rates must not treat the sum as one call.
        var isAggregated: Bool = false
        /// CodexRouter account identity, retained by its compact aggregate so disabled account rows can
        /// be omitted without rebuilding the shared append-only ledger cache.
        var accountId: String? = nil
        var accountFingerprint: String? = nil
        /// False when the router reports full measured input, true when it only has an input estimate,
        /// and nil for older persisted rows that predate this signal.
        var routerInputWasEstimated: Bool? = nil
        /// False when the router's own record reconciles to a complete measured cost breakdown
        /// (`totalTokens` equals measured input + output, with no estimate standing in for input),
        /// true when it does not, and nil for rows from sources that carry no such record — native
        /// gateway folds and aggregates written before this signal existed.
        var routerCostBreakdownIsComplete: Bool? = nil
        /// Source counters were clamped to a safe lower bound before aggregation.
        var tokenCountSaturated: Bool = false
        /// Sentinel retained for a malformed Router row owned by a positively identified disabled
        /// account. It contributes no tokens and becomes source-incomplete if that account is enabled.
        var isMalformed: Bool = false

        /// True only when the router row carries measured counts suitable for reconciling against a
        /// native Codex row. A missing signal is never proof of completeness, so an unknown flag
        /// cannot suppress a native row.
        var hasCompleteRouterCounts: Bool {
            routerInputWasEstimated == false && routerCostBreakdownIsComplete == true
        }

        /// Keep an explicit router total even when it disagrees with the components; otherwise use a
        /// saturating sum because every component is externally supplied and can reach `Int.max`.
        var tokens: Int {
            if let totalTokens { return max(0, totalTokens) }
            return ProviderParse.addingSaturating(
                ProviderParse.addingSaturating(input, output),
                ProviderParse.addingSaturating(cacheWrite, cacheRead)
            )
        }
    }

    /// Every `*.jsonl` under a root's `projects/` — including each project's per-session
    /// subdirectory (`projects/<project>/<session>.jsonl`), mirroring the Claude scanner's
    /// discovery so the fold reads exactly the files the Claude card scans. Path-sorted for
    /// deterministic iteration.
    static func claudeUsageFiles(under root: URL) -> [URL] {
        JSONLScanning.jsonlFiles(under: root.appendingPathComponent("projects"))
            .map { URL(fileURLWithPath: $0.path) }
            .sorted { $0.path < $1.path }
    }

    /// The gateway turns among the Claude scanner's parsed entries: an entry counts only when its
    /// model id carries one of the gateway prefixes; the prefix is stripped so the pricing catalogs
    /// see the real model (deepseek-v4-flash, …). Token buckets map straight across — the Claude
    /// scanner already normalized `usage.input_tokens` to the uncached portion.
    static func claudeGatewayRows(from entries: [ClaudeLogUsageScanner.Entry]) -> [ClaudeGatewayRow] {
        entries.compactMap { entry in
            guard let rawModel = entry.model,
                  let prefix = Self.claudeGatewayPrefixes.first(where: { rawModel.hasPrefix($0) })
            else { return nil }
            let model = String(rawModel.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else { return nil }
            return ClaudeGatewayRow(
                date: entry.timestamp,
                input: entry.tokens.input,
                output: entry.tokens.output,
                cacheWrite: entry.tokens.cacheWrite5m,
                cacheRead: entry.tokens.cacheRead,
                model: model,
                burnsGoQuota: prefix == Self.claudeGatewayPrefixes[0],
                isInProgress: false
            )
        }
    }

    // MARK: - Codex gateway sessions

    /// Model-id prefixes that identify Codex turns routed through the OpenCode gateway — the same
    /// prefixes the Claude fold tracks (the gateway advertises itself as `anthropic/opencode_go/…`
    /// / `anthropic/opencode/…` regardless of which client dials it).
    static let codexGatewayPrefixes = ["anthropic/opencode_go/", "anthropic/opencode/"]

    /// True when a Claude Code / Codex log model is billed through OpenCode Go/Zen rather than the
    /// native Claude/Codex subscription. Native card aggregates skip these so Total Spend does not
    /// count the same gateway turn on both the Codex/Claude card and the OpenCode fold.
    static func isHostedGatewayModel(_ model: String) -> Bool {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return claudeGatewayPrefixes.contains { trimmed.hasPrefix($0) }
    }

    /// The Go slug identifies Go billing even when an older Router row carries the upstream vendor
    /// as its provider label instead of `opencode-go`.
    static func isOpenCodeGoGatewayModel(_ model: String) -> Bool {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix(claudeGatewayPrefixes[0])
    }


    /// The gateway turns among parsed Codex events: a turn counts only when its session's model
    /// carries a gateway prefix; the prefix is stripped so the pricing catalogs see the real model
    /// (deepseek-v4-flash, …). Codex output already includes reasoning tokens, so the gateway
    /// keeps that same output count rather than adding its reasoning subset again.
    static func codexGatewayRows(from events: [CodexLogUsageScanner.Event]) -> [ClaudeGatewayRow] {
        events.compactMap { event in
            guard let prefix = Self.codexGatewayPrefixes.first(where: { event.model.hasPrefix($0) }) else {
                return nil
            }
            let model = String(event.model.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else { return nil }
            return ClaudeGatewayRow(
                date: event.timestamp,
                input: max(0, event.input - event.cached),
                output: event.output,
                cacheWrite: 0,
                cacheRead: event.cached,
                model: model,
                totalTokens: event.total,
                burnsGoQuota: prefix == Self.codexGatewayPrefixes[0],
                isInProgress: false,
                routerCostBreakdownIsComplete: event.hasCompleteCostBreakdown
            )
        }
    }

    /// Parse the OpenCode-gateway turns out of one Codex rollout, reusing the Codex scanner's own
    /// parser (cumulative-total deltas, stale-snapshot dedup, child-session replay gating).
    static func parseCodexGatewayRows(_ data: Data) -> [ClaudeGatewayRow] {
        codexGatewayRows(from: CodexLogUsageScanner.parseFile(data))
    }

    // MARK: - Hermes gateway sessions

    /// Hermes sessions billed to the OpenCode hosted account. Hermes writes `billing_provider` /
    /// `billing_base_url` from its provider config; the Go subscription's provider id is
    /// `opencode-go` (base URL `opencode.ai/zen/go/v1`) and the Zen gateway's is `opencode`. The
    /// LIKE clauses also catch custom spellings; `started_at` is a Unix-epoch float in seconds.
    /// The payload carries `billing_provider` and `billing_base_url` (either can identify Go billing)
    /// plus `ended_at` — `0` while a session is still running, which marks its day partial (Hermes
    /// finalizes the ledger in delayed bursts, so an in-progress row understates what was consumed).
    static func hermesGatewaySQL(cutoffSeconds: Double) -> String {
        """
        SELECT json_group_array(json_array(
                 started_at,
                 COALESCE(input_tokens,0),
                 COALESCE(output_tokens,0),
                 COALESCE(cache_read_tokens,0),
                 COALESCE(cache_write_tokens,0),
                 COALESCE(reasoning_tokens,0),
                 model,
                 billing_provider,
                 billing_base_url,
                 COALESCE(ended_at,0)))
        FROM sessions
        WHERE started_at >= \(cutoffSeconds)
          AND (billing_provider LIKE 'opencode%' OR billing_base_url LIKE '%opencode%');
        """
    }

    /// Parse the `json_group_array(json_array(...))` payload: `[started_at, input, output, cacheRead,
    /// cacheWrite, reasoning, model, billing_provider, billing_base_url, ended_at]`. A session's whole
    /// token ledger lands on its start day — the same attribution the Hermes card uses — and reasoning
    /// bills at the output rate. `opencode-go` or the canonical Go base URL identifies sessions that
    /// burn subscription caps; sessions with `ended_at` 0/NULL are flagged as partial.
    static func parseHermesGatewayRows(
        _ json: String,
        maximumTimestamp: Date = JSONLScanning.maximumTimestamp(now: Date())
    ) -> [ClaudeGatewayRow]? {
        guard let data = json.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return nil }
        var rows: [ClaudeGatewayRow] = []
        rows.reserveCapacity(parsed.count)
        for element in parsed {
            guard let entry = element as? [Any], entry.count == 10,
                  let startedAt = Self.finiteJSONNumber(entry[0]),
                  let model = entry[6] as? String, !model.isEmpty
            else { return nil }
            let provider: String?
            if entry[7] is NSNull {
                provider = nil
            } else if let value = entry[7] as? String {
                provider = value
            } else {
                return nil
            }
            let billingBaseURL: String?
            if entry[8] is NSNull {
                billingBaseURL = nil
            } else if let value = entry[8] as? String {
                billingBaseURL = value
            } else {
                return nil
            }
            guard let input = Self.hermesTokenCount(entry[1]),
                  let output = Self.hermesTokenCount(entry[2]),
                  let cacheRead = Self.hermesTokenCount(entry[3]),
                  let cacheWrite = Self.hermesTokenCount(entry[4]),
                  let reasoning = Self.hermesTokenCount(entry[5])
            else { return nil }
            let endedAt: Double
            if entry[9] is NSNull {
                endedAt = 0
            } else if let value = Self.finiteJSONNumber(entry[9]) {
                endedAt = value
            } else {
                return nil
            }
            let date = Date(timeIntervalSince1970: startedAt)
            let hasUsage = input > 0 || output > 0 || cacheRead > 0 || cacheWrite > 0 || reasoning > 0
            // An empty future-dated session cannot change token totals or cap estimates. Validate it
            // first, then discard it before source-completeness checks. Keep ordinary zero-token rows
            // in the parsed source so billing attribution remains testable; the fold ignores them.
            if date > maximumTimestamp {
                guard !hasUsage else { return nil }
                continue
            }
            rows.append(ClaudeGatewayRow(
                date: date,
                input: input,
                output: ProviderParse.addingSaturating(output, reasoning),
                cacheWrite: cacheWrite,
                cacheRead: cacheRead,
                model: model,
                burnsGoQuota: Self.isOpenCodeGoBilling(provider: provider, baseURL: billingBaseURL),
                isInProgress: endedAt <= 0
            ))
        }
        return rows
    }

    private static func finiteJSONNumber(_ value: Any) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private static func isOpenCodeGoBilling(provider: String?, baseURL: String?) -> Bool {
        let providerID = provider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if providerID == "opencode-go" {
            return true
        }
        // `opencode` is the Zen pay-as-you-go provider. A stale or shared Go URL in the other
        // column cannot turn those rows into subscription-cap usage.
        if providerID == "opencode" { return false }
        guard let baseURL = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !baseURL.isEmpty else {
            return false
        }
        let urlString = baseURL.contains("://") ? baseURL : "https://" + baseURL
        guard let components = URLComponents(string: urlString),
              components.host?.lowercased() == "opencode.ai"
        else { return false }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        return path == "zen/go/v1"
    }

    private static func hermesTokenCount(_ value: Any) -> Int? {
        if value is NSNull { return 0 }
        guard let count = finiteJSONNumber(value),
              count >= 0,
              count <= 1e15,
              count.rounded(.towardZero) == count
        else { return nil }
        return Int(count)
    }

    // MARK: - Codex Router ledger

    /// OpenCode-served turns from a CodexRouter ledger, mapped onto this fold's row shape.
    ///
    /// Reads the same `usage-events.jsonl` the Codex card reads and selects the rows whose `provider` is
    /// OpenCode-hosted, so the two cards partition the ledger instead of overlapping or leaving a gap.
    /// `cached` is carved out of `input` because the router reports `inputTokens` inclusive of the cached
    /// portion, matching the Codex session-log contract.
    /// Router model slugs are `<provider>/<model>` (`opencode-free/space-bunny-free`). The card should
    /// name the model, not the account that served it — the same rule the Codex card's identity resolution
    /// follows, so a gateway path never becomes a row title.
    static func bareRouterModelName(_ model: String) -> String {
        let bare: String
        if let lastSlash = model.lastIndex(of: "/") {
            bare = String(model[model.index(after: lastSlash)...])
        } else {
            bare = model
        }
        return bare.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Rows for this card's window, read from the router ledger.
    ///
    /// The ledger is append-only and grows without bound (tens of MB), and the scan runs on every refresh.
    /// Re-reading it in full cost ~13 s of CPU per refresh for a 36 MB file, because the whole file was
    /// JSON-parsed regardless of the window. This tails instead: only bytes appended since the last call
    /// are read and parsed. Large ledgers fold into a durable day/model aggregate so each refresh
    /// materializes a few dozen rows instead of the whole OpenCode history.
    static func routerGatewayRows(atPath path: String, since: Date) -> [ClaudeGatewayRow] {
        OpenCodeRouterLedger.shared.rows(atPath: path, since: since)
    }

    static func routerGatewayRowsIfComplete(
        atPath path: String,
        since: Date,
        maximumTimestamp: Date = JSONLScanning.maximumTimestamp(now: Date())
    ) -> [ClaudeGatewayRow]? {
        OpenCodeRouterLedger.shared.rowsIfComplete(
            atPath: path, since: since, maximumTimestamp: maximumTimestamp
        )
    }

    static func routerGatewayRowsWithSourceIfComplete(
        atPath path: String,
        since: Date,
        maximumTimestamp: Date = JSONLScanning.maximumTimestamp(now: Date()),
        enabledIdentityKeys: Set<String>? = nil,
        identifiersToIdentityKeys: [String: String] = [:]
    ) -> (rows: [ClaudeGatewayRow], source: OpenCodeRouterLedger.SourceSnapshot)? {
        OpenCodeRouterLedger.shared.rowsWithSourceSnapshotIfComplete(
            atPath: path,
            since: since,
            maximumTimestamp: maximumTimestamp,
            enabledIdentityKeys: enabledIdentityKeys,
            identifiersToIdentityKeys: identifiersToIdentityKeys
        )
    }

    static func routerGatewaySourceIsCurrent(
        _ snapshot: OpenCodeRouterLedger.SourceSnapshot,
        atPath path: String
    ) -> Bool {
        OpenCodeRouterLedger.sourceSnapshotIsCurrent(snapshot, atPath: path)
    }

    /// Read counters for the offline performance benchmark and cache regression tests.
    static func routerLedgerReadStatisticsForTesting(path: String) -> (fullParses: Int, tailParses: Int, bytesRead: Int)? {
        OpenCodeRouterLedger.shared.statistics(path: path)
    }

    /// Remove the in-memory checkpoints and durable compact aggregate for one synthetic test ledger.
    static func routerLedgerClearCacheForTesting(path: String) {
        OpenCodeRouterLedger.shared.clearForTesting(path: path)
    }

    /// Parse one line through the same production router parser used by the streaming ledger reader.
    static func routerGatewayRow(from line: Data) -> ClaudeGatewayRow? {
        OpenCodeRouterLedger.row(from: line)
    }

    // MARK: - Muse gateway sessions (muse-go harness)

    static func museSessionsRoot(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        MusePaths.sessionsDirectory(homeDirectory: homeDirectory)
    }

    /// Normalize `MuseUsageScanner.Entry` (one billed `goal_usage_attribution` per turn)
    /// into the shared `ClaudeGatewayRow` so `foldGatewayRows` stays the sole pricing site.
    /// Every Muse-via-bridge turn is Go-billed (`burnsGoQuota: true`) — the bridge routes
    /// `muse-spark-1.*-contributor` through `opencode.ai/zen/go/v1`.
    static func museGatewayRows(from entries: [MuseUsageScanner.Entry]) -> [ClaudeGatewayRow] {
        entries.map { entry in
            ClaudeGatewayRow(
                date: entry.timestamp,
                input: entry.tokens.input,
                output: entry.tokens.output,
                cacheWrite: entry.tokens.cacheWrite5m,
                cacheRead: entry.tokens.cacheRead,
                model: entry.model ?? "muse-spark-1.2-contributor",
                burnsGoQuota: true,
                isInProgress: false
            )
        }
    }

    // MARK: - Gateway folding

    /// Fold gateway-log rows (measured tokens, imputed dollars) into the combined daily series.
    /// Claude Code, Codex, and Hermes rows all normalize to `ClaudeGatewayRow`; unpriced models
    /// surface through the unknown-model warning instead of a fabricated price, the same convention
    /// the Claude tiles use.
    ///
    /// A row's model is priced at the provider's OWN recorded average rate when `effectiveRates`
    /// carries one (see `effectiveRates(from:)`): those are real billed dollars per token from the
    /// hosted providers' local logs — cache-hit-aware, often far below the catalog miss rate.
    /// Models without recorded rows fall back to the pricing engine, and models neither source
    /// knows become unknown-model warnings. Priced rows that burn the Go subscription's quota are
    /// also appended to `goWindowCosts` (timestamp + imputed dollars) so the cap meters' local
    /// dollar context includes the gateway folds, exactly like the tiles do.
    /// `skippingDayModels` remains for explicitly scoped helper callers. Production source merging uses
    /// account-aware Codex keys; Claude sessions always fold independently of CodexRouter coverage.
    static func foldGatewayRows(
        _ rows: [ClaudeGatewayRow],
        since: Date,
        pricing: ModelPricing,
        effectiveRates: [EffectiveRateKey: Double],
        accumulator: inout DailyUsageAccumulator,
        goWindowCosts: inout [(ms: Double, cost: Double)],
        includesEstimatedCost: inout Bool,
        partialDays: inout Set<String>,
        skippingDayModels: Set<String> = []
    ) {
        JSONLAccountingWorkPacer.shared.forEach(rows) { row in
            guard row.date >= since, row.tokens > 0 else { return }
            let day = DailyUsageAccumulator.dayKey(from: row.date)
            guard !skippingDayModels.contains(Self.dayModelKey(day: day, model: row.model)) else { return }
            if row.isInProgress {
                // Still-running Hermes session: its ledger is not final (Hermes writes it in
                // delayed bursts), so the day's total is partial until the session ends.
                partialDays.insert(day)
            }
            let cost: Double?
            let providerID = row.burnsGoQuota ? Self.goProviderID : Self.zenProviderID
            if let rate = effectiveRates[EffectiveRateKey(model: row.model, providerID: providerID)] {
                // The gateway's own recorded average for this model — all of the row's tokens blend
                // at it (the same proportion the provider's recorded dollars represent).
                cost = rate * Double(row.tokens)
            } else if let estimated = pricing.estimatedCostDollars(
                model: row.model,
                tokens: TokenBreakdown(
                    input: row.input, cacheWrite5m: row.cacheWrite, cacheRead: row.cacheRead, output: row.output
                ),
                applyLongContextRates: !row.isAggregated
            ) {
                cost = estimated
            } else {
                cost = nil
            }
            let apiEstimate = pricing.estimatedCostDollars(
                model: row.model,
                tokens: TokenBreakdown(
                    input: row.input, cacheWrite5m: row.cacheWrite, cacheRead: row.cacheRead, output: row.output
                ),
                applyLongContextRates: !row.isAggregated
            )
            let hasEstimatedRouterInput = row.routerInputWasEstimated == true
            let hasIncompleteRouterBreakdown = row.routerCostBreakdownIsComplete == false
            let hasIncompleteRouterAccounting = hasEstimatedRouterInput
                || hasIncompleteRouterBreakdown
                || row.tokenCountSaturated
            accumulator.recordApiEstimate(
                day: day,
                cost: hasIncompleteRouterAccounting ? nil : apiEstimate,
                tokens: row.tokens
            )
            if let cost {
                accumulator.add(
                    day: day, tokens: row.tokens, cost: cost, model: row.model,
                    tokenCountSaturated: row.tokenCountSaturated
                )
                accumulator.markEstimatedCost(day: day)
                if hasIncompleteRouterAccounting {
                    // Keep the priced subtotal internally, but don't present it as a complete cost
                    // when the router's input estimate or reported total doesn't reconcile.
                    accumulator.markCostIncomplete(day: day, model: row.model)
                } else if row.burnsGoQuota {
                    goWindowCosts.append((ms: row.date.timeIntervalSince1970 * 1000, cost: cost))
                }
                includesEstimatedCost = true
            } else {
                // Unpriced rows count their tokens with a dashed cost (owner policy), so an
                // unrevealed codename stays visible in the totals.
                if !hasIncompleteRouterAccounting {
                    accumulator.addUnknownModel(day: day, model: row.model)
                }
                accumulator.add(
                    day: day, tokens: row.tokens, cost: nil, model: row.model,
                    tokenCountSaturated: row.tokenCountSaturated
                )
            }
            if row.isInProgress {
                accumulator.markModelCostIncomplete(day: day, model: row.model)
            }
        }
    }

    /// Per-model blended dollars-per-token from the hosted providers' OWN recorded costs
    /// (`opencode*.db` `$.cost`), computed over the scan window's rows.
    ///
    /// The gateway bills DeepSeek cache hits at a fraction of the sticker input rate, so a model's
    /// real average rate can sit ~15x below its catalog miss rate — folding token-only gateway logs
    /// (Claude Code / Codex / Hermes) at the miss rate would overstate spend by the same factor.
    /// Calibrating to the provider's recorded average keeps the imputed dollars in the right
    /// galaxy. Calibration is kept separate for Go and Zen because their billed rates differ. Zero-cost
    /// rows (free tiers) yield a $0 rate; models with no recorded rows get no entry and fall back to
    /// the pricing engine. A broad $1,000/M ceiling guards against a corrupt one-token sample without
    /// clipping premium Zen models to the old open-model-only $4/M ceiling.
    ///
    /// Muse Spark (`muse-spark-1.*`) is explicitly excluded: `opencode.db` holds only 7
    /// `muse-spark-1.2-contributor` rows (60k tokens, $0.0025 → ~$43/M blended) — a tiny,
    /// unrepresentative sample that would price the 412M-token Muse harness fold at ~$17k
    /// instead of the supplement's $1.25/ $0.125 cache-read / $4.25 catalog rate (~$77).
    /// DeepSeek V4 Pro is also excluded: Hermes now reports its `cache_read_tokens`
    /// explicitly (744M cache_read in the last 33d), so the catalog's distinct $0.003625
    /// cache-read lane is authoritative; a blended $0.43/M rate from 6 DB rows (which
    /// barely exercise cache) would re-inflate Pro tiles by ~15x, re-creating the
    /// "Pro pricing wrong" bug the supplement pin fixed.
    /// Space Bunny (`space-bunny-free`) is excluded for the inverse reason: the DB's
    /// recorded $0/M is the free-promo artifact, not a real rate — the model is paid on
    /// the GO plan now (opencode.ai/docs/go, verified 2026-10-06) and OpenCode kept the
    /// legacy `-free` id, so the supplement's GO card must price the multi-billion-token
    /// router folds instead of the poisoned $0 calibration.
    private static func effectiveRates(from rows: [Row]) -> [EffectiveRateKey: Double] {
        var totals: [EffectiveRateKey: (cost: Double, tokens: Double)] = [:]
        var overflowedKeys: Set<EffectiveRateKey> = []
        JSONLAccountingWorkPacer.shared.forEach(rows) { row in
            guard row.tokens > 0,
                  !row.tokenCountSaturated,
                  let cost = row.cost,
                  row.model.caseInsensitiveCompare(ModelUsageEntry.unattributedModelName) != .orderedSame
            else { return }
            // Muse Spark and DeepSeek Pro must use the catalog — their DB samples
            // are either tiny/uncached (Muse: 7 rows / 60k tokens → $43/M blended
            // would price the 426M-token harness at $18k vs $81 at the supplement's
            // $1.25/$0.125 lane) or cache-mix-mismatched (Pro: Hermes reports
            // 98% cache_read at $0.0036/M, the DB's blended $0.43/M would inflate
            // the Hermes fold ~25x). Flash stays calibrated: its DB effective
            // $0.0085/M closely matches Hermes' cache-heavy $0.007/M, so the
            // blended rate is not systematically inflated and the existing
            // gateway test expects calibration.
            if row.model.hasPrefix("muse-") || row.model == "deepseek-v4-pro" || row.model == "deepseek/deepseek-v4-pro" || row.model == "space-bunny-free" {
                return
            }
            let key = EffectiveRateKey(model: row.model, providerID: row.providerID)
            guard !overflowedKeys.contains(key) else { return }
            let t = totals[key] ?? (0, 0)
            let nextCost = t.cost + cost
            let nextTokens = t.tokens + Double(row.tokens)
            guard nextCost.isFinite, nextTokens.isFinite else {
                overflowedKeys.insert(key)
                return
            }
            totals[key] = (nextCost, nextTokens)
        }
        var rates: [EffectiveRateKey: Double] = [:]
        rates.reserveCapacity(totals.count)
        for (key, t) in totals {
            guard !overflowedKeys.contains(key), t.tokens > 0 else { continue }
            let rate = t.cost / t.tokens
            guard rate.isFinite else { continue }
            rates[key] = min(max(rate, 0), 1e-3)
        }
        return rates
    }

    // MARK: - Parsing

    private struct Row {
        var ms: Double
        var cost: Double?
        var tokens: Int
        var tokenCountSaturated: Bool
        var model: String
        var providerID: String
    }

    /// Parse the `json_group_array(json_array(...))` payload: an array of
    /// `[time_created, cost, tokensTotal, modelID, providerID]`. Invalid token/time/identity fields
    /// invalidate the query so last-good history stays intact; a missing source cost keeps measured
    /// tokens while marking dollar coverage incomplete.
    private static func parseRows(_ json: String, maximumTimestampMs: Double) -> [Row]? {
        guard let data = json.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return nil }

        var rows: [Row] = []
        rows.reserveCapacity(parsed.count)
        for element in parsed {
            guard let entry = element as? [Any], entry.count >= 5,
                  let ms = ProviderParse.number(entry[0]), ms >= 0,
                  let rawTokens = ProviderParse.number(entry[2]),
                  rawTokens >= 0,
                  rawTokens.rounded(.towardZero) == rawTokens,
                  let providerID = entry[4] as? String
            else { return nil }
            let tokenCountSaturated = rawTokens > 1e15
            let tokens = Int(min(rawTokens, 1e15))
            let cost = ProviderParse.number(entry[1]).flatMap { $0 >= 0 ? $0 : nil }
            // Completed zero-token, zero-cost bookkeeping rows carry no usage and must not let a
            // skewed timestamp discard otherwise complete history. Keep cost-only rows meaningful.
            if tokens == 0, (cost ?? 0) == 0 { continue }
            guard ms <= maximumTimestampMs else { return nil }
            let model: String
            if entry[3] is NSNull {
                model = ModelUsageEntry.unattributedModelName
            } else if let rawModel = entry[3] as? String {
                model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? ModelUsageEntry.unattributedModelName
            } else {
                return nil
            }
            rows.append(Row(
                ms: ms,
                cost: cost,
                tokens: tokens,
                tokenCountSaturated: tokenCountSaturated,
                model: model,
                providerID: providerID
            ))
        }
        return rows
    }

    // MARK: - SQL

    // MARK: Go anchor memo

    /// Process-wide memo of the monthly-cycle anchor per database revision (path + main-db stat +
    /// WAL stat). The anchor is a full-history `MIN()` scan that ran on every refresh, but it can
    /// only change when the database changes. The key stats both the main file and its `-wal`
    /// companion: in WAL mode a commit touches the companion without moving the main db, so any
    /// write — including a deleted oldest session — re-queries. Idle databases (the common
    /// panel-open case) then skip the scan entirely.
    private static let goAnchorMemo = OSAllocatedUnfairLock<[String: Double]>(initialState: [:])

    private static func goAnchorMemoKey(path: String) -> String? {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        func stamp(_ url: URL) -> String {
            guard let values = try? url.resourceValues(forKeys: keys) else { return "?" }
            return "\(values.fileSize ?? -1)|\(values.contentModificationDate?.timeIntervalSinceReferenceDate ?? -1)"
        }
        let main = URL(fileURLWithPath: path)
        let wal = URL(fileURLWithPath: path + "-wal")
        return "\(path)|\(stamp(main))|\(stamp(wal))"
    }

    private static func cachedGoAnchor(key: String) -> Double? {
        goAnchorMemo.withLock { $0[key] }
    }

    private static func storeGoAnchor(key: String, anchorMs: Double) {
        goAnchorMemo.withLock { $0[key] = anchorMs }
    }

    /// SQL literal built from `hostedProviderIDs`, so the tracked list has one source of truth.
    private static let providerFilter = "(" + hostedProviderIDs.map { "'\($0)'" }.joined(separator: ",") + ")"

    static func dataSQL(cutoffMs: Int) -> String {
        """
        WITH source AS (
            SELECT time_created,
                   json_type(data,'$.cost') AS cost_type,
                   json_extract(data,'$.cost') AS cost,
                   json_type(data,'$.tokens') AS tokens_type,
                   json_type(data,'$.tokens.total') AS total_type,
                   json_extract(data,'$.tokens.total') AS total,
                   json_type(data,'$.tokens.input') AS input_type,
                   json_extract(data,'$.tokens.input') AS input_tokens,
                   json_type(data,'$.tokens.output') AS output_type,
                   json_extract(data,'$.tokens.output') AS output_tokens,
                   json_type(data,'$.tokens.reasoning') AS reasoning_type,
                   json_extract(data,'$.tokens.reasoning') AS reasoning_tokens,
                   json_type(data,'$.tokens.cache') AS cache_type,
                   json_type(data,'$.tokens.cache.read') AS cache_read_type,
                   json_extract(data,'$.tokens.cache.read') AS cache_read_tokens,
                   json_type(data,'$.tokens.cache.write') AS cache_write_type,
                   json_extract(data,'$.tokens.cache.write') AS cache_write_tokens,
                   json_extract(data,'$.modelID') AS model_id,
                   json_extract(data,'$.providerID') AS provider_id
            FROM message
            WHERE time_created >= \(cutoffMs)
              AND json_valid(data)
              AND json_extract(data,'$.role') = 'assistant'
              AND json_extract(data,'$.providerID') IN \(providerFilter)
        )
        SELECT json_group_array(json_array(
                 time_created,
                 CASE WHEN cost_type IN ('integer','real') AND cost >= 0 THEN cost ELSE -1 END,
                 CASE
                     WHEN total_type IN ('integer','real') AND total > 0 THEN total
                     WHEN tokens_type = 'object'
                       AND (total_type IS NULL OR total_type = 'null' OR (total_type IN ('integer','real') AND total = 0))
                       AND input_type IN ('integer','real') AND input_tokens >= 0
                       AND output_type IN ('integer','real') AND output_tokens >= 0
                       AND (reasoning_type IS NULL OR reasoning_type = 'null' OR (reasoning_type IN ('integer','real') AND reasoning_tokens >= 0))
                       AND (cache_type IS NULL OR cache_type IN ('null','object'))
                       AND (cache_read_type IS NULL OR cache_read_type = 'null' OR (cache_read_type IN ('integer','real') AND cache_read_tokens >= 0))
                       AND (cache_write_type IS NULL OR cache_write_type = 'null' OR (cache_write_type IN ('integer','real') AND cache_write_tokens >= 0))
                     THEN COALESCE(input_tokens,0)
                        + COALESCE(output_tokens,0)
                        + COALESCE(reasoning_tokens,0)
                        + COALESCE(cache_read_tokens,0)
                        + COALESCE(cache_write_tokens,0)
                     ELSE -1
                END,
                 model_id,
                 provider_id))
        FROM source;
        """
    }

    static let anchorSQL = """
        SELECT MIN(time_created) FROM message
        WHERE json_valid(data)
          AND json_extract(data,'$.role') = 'assistant'
          AND json_extract(data,'$.providerID') = '\(goProviderID)'
          AND json_type(data,'$.cost') IN ('integer','real');
        """

    static let probeSQL = """
        SELECT 1 FROM message
        WHERE json_valid(data)
          AND json_extract(data,'$.role') = 'assistant'
          AND json_extract(data,'$.providerID') IN \(providerFilter)
          AND json_type(data,'$.cost') IN ('integer','real')
        LIMIT 1;
        """
}
