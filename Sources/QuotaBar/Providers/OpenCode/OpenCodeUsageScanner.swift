import Foundation

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
    /// The OpenCode-hosted providerIDs we track: the Go subscription and the Zen pay-as-you-go gateway.
    /// Both write an authoritative `cost`; other (BYO-key) providerIDs log `cost: 0` and are out of scope.
    static let hostedProviderIDs = ["opencode-go", "opencode"]
    static let goProviderID = "opencode-go"

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
    var hermesStateDBPath: @Sendable () -> String?
    /// CodexRouter's append-only `usage-events.jsonl` ledgers, for the turns it served against an
    /// OpenCode-hosted account. These are Codex-CLI turns, so they live in the router's ledger rather
    /// than `opencode*.db`, and they never reach the Codex card either (it defers them to us) — without
    /// this fold they were simply not counted anywhere.
    var routerLedgerPaths: @Sendable () -> [String]
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
        hermesStateDBPath: @escaping @Sendable () -> String? = { nil },
        routerLedgerPaths: @escaping @Sendable () -> [String] = { [] },
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
        let tileSince: Date
        let pricing: ModelPricing
        let rates: [String: Double]
        var accumulator: DailyUsageAccumulator
        var goWindowCosts: [(ms: Double, cost: Double)]
        var includesEstimatedCost: Bool
        var partialDays: Set<String>

        init(
            tileSince: Date,
            pricing: ModelPricing,
            rates: [String: Double],
            accumulator: DailyUsageAccumulator,
            goWindowCosts: [(ms: Double, cost: Double)],
            includesEstimatedCost: Bool,
            partialDays: Set<String>
        ) {
            self.tileSince = tileSince
            self.pricing = pricing
            self.rates = rates
            self.accumulator = accumulator
            self.goWindowCosts = goWindowCosts
            self.includesEstimatedCost = includesEstimatedCost
            self.partialDays = partialDays
        }

        func foldClaude(_ entry: ClaudeLogUsageScanner.Entry) {
            OpenCodeUsageScanner.foldGatewayRows(
                OpenCodeUsageScanner.claudeGatewayRows(from: [entry]),
                since: tileSince, pricing: pricing, effectiveRates: rates,
                accumulator: &accumulator, goWindowCosts: &goWindowCosts,
                includesEstimatedCost: &includesEstimatedCost, partialDays: &partialDays
            )
        }

        func foldCodex(_ event: CodexLogUsageScanner.Event) {
            OpenCodeUsageScanner.foldGatewayRows(
                OpenCodeUsageScanner.codexGatewayRows(from: [event]),
                since: tileSince, pricing: pricing, effectiveRates: rates,
                accumulator: &accumulator, goWindowCosts: &goWindowCosts,
                includesEstimatedCost: &includesEstimatedCost, partialDays: &partialDays
            )
        }
    }

    func scan(now: Date, daysBack: Int = 30, hasGoKey: Bool = false, pricing: ModelPricing = .empty) async throws -> OpenCodeUsageScan? {
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
        guard !paths.isEmpty else {
            await readFailureReporter.update(checkedPaths: [], failingPaths: [])
            return nil
        }

        // Same calendar bound the tiles/trend use. A wall-clock `now - daysBack×86400` cutoff sits
        // later the same day, so morning rows on the oldest day never leave SQLite.
        let cutoffDate = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let cutoffMs = Int(cutoffDate.timeIntervalSince1970 * 1000)
        var rows: [Row] = []
        var anchorMs: Double?
        var checked: Set<String> = []
        var failures: [String: String] = [:]

        for path in paths {
            checked.insert(path)
            do {
                if let json = try sqlite.queryValue(path: path, sql: Self.dataSQL(cutoffMs: cutoffMs)) {
                    rows.append(contentsOf: Self.parseRows(json))
                }
            } catch {
                failures[path] = error.localizedDescription
                continue
            }
            // Monthly cycle anchor: the earliest-ever local Go usage (unbounded, so it survives the
            // day-window cutoff). Best-effort per path — anchor failures are edge-warned (not silent)
            // so a persistently broken anchor query surfaces once, then falls back to calendar month.
            do {
                if let text = try sqlite.queryValue(path: path, sql: Self.anchorSQL),
                   let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    anchorMs = Swift.min(anchorMs ?? value, value)
                }
            } catch {
                // Edge-warn via reporter path for consistency: treat anchor as a separate check;
                // a per-path anchor failure is rare (table missing) and should not be silent.
                AppLog.warn(LogTag.plugin("opencode"), "anchor query failed for \(path): \(error.localizedDescription) — monthly window falls back to calendar month")
            }
        }
        // Per-path detail is logged only for newly failing paths (the reporter edge-triggers), so a
        // persistently locked database warns once, not on every 5-minute refresh.
        let newlyFailing = await readFailureReporter.update(checkedPaths: checked, failingPaths: Set(failures.keys))
        for path in newlyFailing.sorted() {
            AppLog.warn(LogTag.plugin("opencode"), "usage query failed for \(path): \(failures[path] ?? "unknown error")")
        }
        if failures.count == checked.count {
            throw OpenCodeUsageError.databaseUnreadable
        }

        // Combined hosted daily series (opencode-go + opencode) → the spend tiles + usage trend. Cost is
        // authoritative, so every row is "priced": feed it straight into the shared accumulator.
        let tileSince = JSONLScanning.sinceDate(daysBack: 30, now: now)
        var accumulator = DailyUsageAccumulator()
        for row in rows {
            let date = Date(timeIntervalSince1970: row.ms / 1000)
            guard date >= tileSince else { continue }
            accumulator.add(
                day: DailyUsageAccumulator.dayKey(from: date),
                tokens: row.tokens, cost: row.cost, model: row.model
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
        var goWindowCosts: [(ms: Double, cost: Double)] = rows
            .filter { $0.providerID == Self.goProviderID }
            .map { (ms: $0.ms, cost: $0.cost) }
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
        let rates = Self.effectiveRates(from: rows)
        // Stream Claude/Codex gateway rows; unload Codex tail-cache between homes so peaks cannot stack.
        let gatewayFold = GatewayFoldState(
            tileSince: tileSince,
            pricing: pricing,
            rates: rates,
            accumulator: accumulator,
            goWindowCosts: goWindowCosts,
            includesEstimatedCost: includesEstimatedCost,
            partialDays: partialDays
        )
        _ = await ClaudeLogUsageScanner().foldParsedEntries(
            daysBack: daysBack, now: now, roots: claudeRoots(),
            cacheIdentityOverride: claudeCacheIdentity()
        ) { entry in
            gatewayFold.foldClaude(entry)
        }
        let partitionedCodex = Self.partitionCodexHomes(codexHomes())
        for home in partitionedCodex.defaultHomes {
            guard !Task.isCancelled else { return nil }
            _ = await CodexLogUsageScanner().foldParsedEvents(
                daysBack: daysBack, now: now, homes: [home]
            ) { event in
                gatewayFold.foldCodex(event)
            }
            CodexLogUsageScanner.unloadSharedTailCacheItems()
        }
        for home in partitionedCodex.managed {
            guard !Task.isCancelled else { return nil }
            _ = await CodexLogUsageScanner(peerHomes: partitionedCodex.defaultHomes).foldParsedEvents(
                daysBack: daysBack, now: now, homes: [home]
            ) { event in
                gatewayFold.foldCodex(event)
            }
            CodexLogUsageScanner.unloadSharedTailCacheItems()
        }
        accumulator = gatewayFold.accumulator
        goWindowCosts = gatewayFold.goWindowCosts
        includesEstimatedCost = gatewayFold.includesEstimatedCost
        partialDays = gatewayFold.partialDays
        // Hermes sessions billed to the OpenCode hosted account — they never reach `opencode*.db`.
        // A supplementary source: an unreadable Hermes database logs a warn (edge-triggered) and never
        // fails the scan (the tiles still have the OpenCode DBs + gateway logs) — but it must never
        // be SILENT: a WAL-locked read during a busy write burst would quietly drop the whole fold
        // and the day would read as ~$0 while the account meter proves otherwise.
        if let hermesPath = hermesStateDBPath() {
            do {
                if let json = try sqlite.queryValue(path: hermesPath, sql: Self.hermesGatewaySQL(cutoffSeconds: Double(cutoffMs) / 1000)) {
                    Self.foldGatewayRows(
                        Self.parseHermesGatewayRows(json), since: tileSince, pricing: pricing,
                        effectiveRates: rates,
                        accumulator: &accumulator, goWindowCosts: &goWindowCosts,
                        includesEstimatedCost: &includesEstimatedCost, partialDays: &partialDays
                    )
                }
                await readFailureReporter.update(checkedPaths: [hermesPath], failingPaths: [])
            } catch {
                let newlyFailing = await readFailureReporter.update(checkedPaths: [hermesPath], failingPaths: [hermesPath])
                if !newlyFailing.isEmpty {
                    AppLog.warn(LogTag.plugin("opencode"), "Hermes session database \(hermesPath): \(error.localizedDescription) — Hermes usage is not folded into this card until it recovers")
                }
            }
        }
        // CodexRouter turns served against an OpenCode account. The router meters every routed turn,
        // including the ones it handed to OpenCode, and those turns never appear in `opencode*.db` (a
        // free/custom Zen model can bypass the OpenCode server entirely) nor on the Codex card, which
        // now defers them here. They were previously invisible: a router configured for a free model
        // logged thousands of turns that no card counted.
        // Resolve and dedupe: two entries pointing at the same file would fold every row twice.
        var seenLedgerPaths: Set<String> = []
        for path in routerLedgerPaths().map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        where FileManager.default.isReadableFile(atPath: path)
            && seenLedgerPaths.insert(path).inserted {
            let rows = Self.routerGatewayRows(atPath: path, since: tileSince)
            guard !rows.isEmpty else { continue }
            Self.foldGatewayRows(
                rows, since: tileSince, pricing: pricing,
                effectiveRates: rates,
                accumulator: &accumulator, goWindowCosts: &goWindowCosts,
                includesEstimatedCost: &includesEstimatedCost, partialDays: &partialDays
            )
        }
        // Muse harness sessions via the local `muse-opencode-go-bridge` — same Go account,
        // same `muse-spark-1.*` billed quota. Muse's `goal_usage_attribution` with
        // `reported:true` carries per-step provider tokens; without this fold the tiles +
        // meter-detail dollars undercount Muse spend by omitting the harness entirely.
        let museRootsValue = museRoots()
        if !museRootsValue.isEmpty {
            let museEntries = await MuseUsageScanner().parsedEntries(
                daysBack: daysBack, now: now, roots: museRootsValue
            )
            Self.foldGatewayRows(
                Self.museGatewayRows(from: museEntries), since: tileSince, pricing: pricing,
                effectiveRates: rates,
                accumulator: &accumulator, goWindowCosts: &goWindowCosts,
                includesEstimatedCost: &includesEstimatedCost, partialDays: &partialDays
            )
        }
        let logScan = accumulator.build()

        // Go-only windows → the Session / Weekly / Monthly caps. Shown only on a CURRENT Go signal: the
        // user is logged into Go (`hasGoKey`), or has spent on Go within the window — recorded or
        // folded — so a stale anchor from old usage must NOT resurrect the caps or the "Go" plan for a
        // lapsed or Zen-only user; the anchor only sets the monthly-cycle boundary once we've decided
        // to show the meters.
        let goWindows: OpenCodeGoWindows? = (hasGoKey || !goWindowCosts.isEmpty)
            ? OpenCodeGoWindowMath.compute(costs: goWindowCosts, anchorMs: anchorMs, now: now)
            : nil

        return OpenCodeUsageScan(
            logScan: logScan,
            goWindows: goWindows,
            includesEstimatedCost: includesEstimatedCost,
            partialDays: partialDays
        )
    }

    /// Cheap local probe for `hasLocalCredentials()`: does any tracked database hold at least one hosted
    /// assistant row with a numeric cost? Read-only, no network. Failures are logged (this runs only
    /// during first-run / new-provider detection, so there's no refresh spam to throttle); an unreadable
    /// data directory counts as an OpenCode footprint so `refresh()` gets to surface the real error.
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

        var tokens: Int { input + output + cacheWrite + cacheRead }
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


    /// The gateway turns among parsed Codex events: a turn counts only when its session's model
    /// carries a gateway prefix; the prefix is stripped so the pricing catalogs see the real model
    /// (deepseek-v4-flash, …). Reasoning tokens bill at the output rate, mirroring the Codex
    /// scanner's cost math.
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
                output: event.output + event.reasoning,
                cacheWrite: 0,
                cacheRead: event.cached,
                model: model,
                burnsGoQuota: prefix == Self.codexGatewayPrefixes[0],
                isInProgress: false
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
    /// The payload's last two elements carry `billing_provider` (so the Go-cap meters can tell the
    /// subscription's sessions from the Zen pay-as-you-go's) and `ended_at` — `0` while a session
    /// is still running, which marks its day partial (Hermes finalizes the ledger in delayed
    /// bursts, so an in-progress session's row understates what has actually been consumed).
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
                 COALESCE(ended_at,0)))
        FROM sessions
        WHERE started_at >= \(cutoffSeconds)
          AND (billing_provider LIKE 'opencode%' OR billing_base_url LIKE '%opencode%');
        """
    }

    /// Parse the `json_group_array(json_array(...))` payload: `[started_at, input, output, cacheRead,
    /// cacheWrite, reasoning, model, billing_provider, ended_at]`. A session's whole token ledger lands
    /// on its start day — the same attribution the Hermes card uses — and reasoning bills at the
    /// output rate. Only `opencode-go` sessions burn the Go subscription's cap meters; sessions with
    /// `ended_at` 0/NULL (still running) are flagged `isInProgress` so their days render as partial.
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
        guard let lastSlash = model.lastIndex(of: "/") else { return model }
        return String(model[model.index(after: lastSlash)...])
    }

    /// Rows for this card's window, read from the router ledger.
    ///
    /// The ledger is append-only and grows without bound (tens of MB), and the scan runs on every refresh.
    /// Re-reading it in full cost ~13 s of CPU per refresh for a 36 MB file, because the whole file was
    /// JSON-parsed regardless of the window. This tails instead: only bytes appended since the last call
    /// are read and parsed, and previously parsed rows are kept for the window.
    static func routerGatewayRows(atPath path: String, since: Date) -> [ClaudeGatewayRow] {
        RouterLedgerTail.shared.rows(atPath: path, since: since)
    }

    /// Per-ledger tail state: how far it has been consumed, and the rows that fall inside the window.
    private final class RouterLedgerTail: @unchecked Sendable {
        static let shared = RouterLedgerTail()

        /// Rows older than this are dropped from the cache. Comfortably wider than the 30-day display
        /// window, so a widening window never needs a re-read.
        private static let retentionDays = 45

        private struct State {
            var offset: UInt64 = 0
            var rows: [ClaudeGatewayRow] = []
            /// Bytes of a line the writer had not finished when we last read.
            ///
            /// This must persist across calls. Holding it in a function-local buffer meant the bytes after
            /// the last newline were dropped when the function returned — the offset said EOF while those
            /// bytes had never been parsed, so a line completed by the next refresh was lost forever.
            var partial: Data = Data()
        }

        private let lock = NSLock()
        private var states: [String: State] = [:]

        func rows(atPath path: String, since: Date) -> [ClaudeGatewayRow] {
            let cutoff = Date().addingTimeInterval(-Double(Self.retentionDays) * 86_400)
            return lock.withLock {
                var state = states[path] ?? State()

                // Truncated or rotated: the cached offset is meaningless, so start over.
                if let size = fileSize(path), size < state.offset {
                    state = State()
                }

                if let size = fileSize(path), size > state.offset {
                    consumeNewBytes(of: path, into: &state, upTo: size)
                }

                state.rows.removeAll { $0.date < cutoff }
                states[path] = state
                return state.rows.filter { $0.date >= since }
            }
        }

        private func fileSize(_ path: String) -> UInt64? {
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return (attributes?[.size] as? NSNumber)?.uint64Value
        }

        /// Reads to EOF, then sets the offset to the start of any line the writer had not finished.
        ///
        /// The rewind happens **once, after the loop**. Doing it per-iteration either re-read the same
        /// bytes (infinite) or, with a `break`, stopped after a single chunk and left the fold lagging
        /// megabytes behind. Reading forward and rewinding at the end cannot do either.
        private func consumeNewBytes(of path: String, into state: inout State, upTo size: UInt64) {
            guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return }
            defer { try? handle.close() }
            do { try handle.seek(toOffset: state.offset) } catch { return }

            var buffer = state.partial
            defer { state.partial = buffer }
            let chunkSize = 1 << 20

            while state.offset < size {
                // A cancelled refresh stops here; `offset` and the carry are written back by the defers, so
                // the next call resumes exactly where this one stopped.
                if Task.isCancelled { return }
                let remaining = size - state.offset
                guard let chunk = try? handle.read(upToCount: Int(min(UInt64(chunkSize), remaining))),
                      !chunk.isEmpty else { break }
                state.offset += UInt64(chunk.count)
                buffer.append(chunk)

                // Consume only what is complete: everything up to and including the LAST newline. Bytes after
                // it are a line the writer has not finished, and stay in the carry.
                guard let lastNewline = buffer.lastIndex(of: UInt8(ascii: "\n")) else { continue }
                let completeEnd = buffer.index(after: lastNewline)
                for line in buffer[..<completeEnd].split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
                    if let row = OpenCodeUsageScanner.routerGatewayRow(from: Data(line)) { state.rows.append(row) }
                }
                buffer = Data(buffer[completeEnd...])
            }

            // Rewind once, for the incomplete tail only, so the next call re-reads it whole.
            if state.offset >= UInt64(buffer.count) {
                state.offset -= UInt64(buffer.count)
            }
        }
    }

    /// Parses one ledger line. The ISO timestamp is located by scanning for `"at":"` rather than assuming it
    /// is the first field — the ledger starts with `"meteringVersion"`, so a positional read was never a date
    /// and the old window prefilter silently matched every line.
    static func routerGatewayRow(from line: Data) -> ClaudeGatewayRow? {
        // A line must be a whole JSON object. The byte scanner below defaults any missing field to 0, so a
        // truncated line did not get skipped — it became a *wrong* row: `..."inputTokens":1000` cut short
        // charged 1000 uncached input instead of 100 input + 900 cache-read, a ~10x overstatement on that
        // row, with the output tokens dropped. `JSONLFileReader` gets this by construction; hand-rolling
        // the reader means checking it here.
        guard let first = line.first, first == UInt8(ascii: "{"),
              let last = line.last, last == UInt8(ascii: "}")
        else { return nil }

        // Read the six fields this fold needs straight out of the bytes.
        //
        // `JSONSerialization` builds a dictionary per line, and this ledger has ~96k lines: profiling the
        // full read showed that dominated it, and the rows it produced were then thrown away because a
        // non-OpenCode provider was filtered out. Extracting scalars avoids allocating a container for
        // every line, and costs nothing for the lines we discard.
        // Trim once and reuse: the classifier trims, so an untrimmed provider here made `burnsGoQuota`
        // disagree with inclusion and put one turn in the tiles but not in the cap meters.
        guard let rawProvider = jsonScalar(for: "provider", in: line) else { return nil }
        let provider = rawProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CodexRouterUsageScanner.isOpenCodeProvider(provider),
              let status = jsonInteger(for: "status", in: line),
              CodexRouterUsageScanner.isSuccessfulStatus(status),
              let at = jsonScalar(for: "at", in: line),
              let timestamp = OpenUsageISO8601.date(from: at)
        else { return nil }
        let input = max(0, jsonInteger(for: "inputTokens", in: line) ?? 0)
        let cached = min(max(0, jsonInteger(for: "cachedInputTokens", in: line) ?? 0), input)
        return ClaudeGatewayRow(
            date: timestamp,
            input: input - cached,
            output: max(0, jsonInteger(for: "outputTokens", in: line) ?? 0),
            cacheWrite: 0,
            cacheRead: cached,
            model: bareRouterModelName(jsonScalar(for: "model", in: line) ?? ""),
            // Only the Go subscription's cap meters are consumed by `opencode-go`; Zen and the free tier
            // are billed outside those caps.
            burnsGoQuota: provider.lowercased().hasPrefix("opencode-go"),
            isInProgress: false
        )
    }

    /// Value of a `"key":"value"` scalar, without building a dictionary.
    private static func jsonScalar(for key: String, in data: Data) -> String? {
        // The colon belongs in the needle: `"provider":` — matching `"provider"` alone leaves the
        // separator next, which is not the opening quote of the value.
        let needle = Data(("\"" + key + "\":").utf8)
        guard let start = data.range(of: needle)?.upperBound else { return nil }
        guard start < data.endIndex, data[start] == UInt8(ascii: "\"") else { return nil }
        let valueStart = data.index(after: start)
        guard let end = data[valueStart...].firstIndex(of: UInt8(ascii: "\"")), end > valueStart else { return nil }
        return String(decoding: data[valueStart..<end], as: UTF8.self)
    }

    /// Value of a `"key":<number>` scalar, without building a dictionary.
    private static func jsonInteger(for key: String, in data: Data) -> Int? {
        let needle = Data(("\"" + key + "\":").utf8)
        guard let start = data.range(of: needle)?.upperBound else { return nil }
        var value = 0
        var seen = false
        var negative = false
        var index = start
        if index < data.endIndex, data[index] == UInt8(ascii: "-") { negative = true; index = data.index(after: index) }
        // Saturating rather than trapping. `value * 10` overflows `Int` on a long digit run — which is a
        // SIGTRAP, i.e. the process dies — and the ledger is untrusted, append-only input that can carry a
        // hand-edited or absurdly large count. A saturating read costs nothing and cannot kill the app.
        // The same 1e15 clamp every other parser in this file uses; saturating without it let a 26-digit
        // run through at 1.15e18 tokens, i.e. an absurd figure rather than a crash.
        let ceiling = 1_000_000_000_000_000
        var saturated = false
        while index < data.endIndex {
            let byte = data[index]
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { break }
            seen = true
            if !saturated {
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
                if value > ceiling { saturated = true }   // far past any real token count
            }
            index = data.index(after: index)
        }
        guard seen else { return nil }
        guard !saturated else { return ceiling }
        return negative ? -value : value
    }


    static func parseHermesGatewayRows(_ json: String) -> [ClaudeGatewayRow] {
        guard let data = json.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return [] }
        var rows: [ClaudeGatewayRow] = []
        rows.reserveCapacity(parsed.count)
        for element in parsed {
            guard let entry = element as? [Any], entry.count >= 9,
                  let startedAt = ProviderParse.number(entry[0]),
                  let model = entry[6] as? String, !model.isEmpty
            else { continue }
            func tokens(_ index: Int) -> Int {
                Int(min(max(ProviderParse.number(entry[index]) ?? 0, 0), 1e15))
            }
            let endedAt = ProviderParse.number(entry[8]) ?? 0
            rows.append(ClaudeGatewayRow(
                date: Date(timeIntervalSince1970: startedAt),
                input: tokens(1),
                output: tokens(2) + tokens(5),
                cacheWrite: tokens(4),
                cacheRead: tokens(3),
                model: model,
                burnsGoQuota: (entry[7] as? String) == "opencode-go",
                isInProgress: endedAt <= 0
            ))
        }
        return rows
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
    private static func foldGatewayRows(
        _ rows: [ClaudeGatewayRow],
        since: Date,
        pricing: ModelPricing,
        effectiveRates: [String: Double],
        accumulator: inout DailyUsageAccumulator,
        goWindowCosts: inout [(ms: Double, cost: Double)],
        includesEstimatedCost: inout Bool,
        partialDays: inout Set<String>
    ) {
        for row in rows where row.date >= since {
            let day = DailyUsageAccumulator.dayKey(from: row.date)
            if row.isInProgress {
                // Still-running Hermes session: its ledger is not final (Hermes writes it in
                // delayed bursts), so the day's total is partial until the session ends.
                partialDays.insert(day)
            }
            let cost: Double?
            if let rate = effectiveRates[row.model] {
                // The gateway's own recorded average for this model — all of the row's tokens blend
                // at it (the same proportion the provider's recorded dollars represent).
                cost = rate * Double(row.tokens)
            } else if let estimated = pricing.estimatedCostDollars(
                model: row.model,
                tokens: TokenBreakdown(
                    input: row.input, cacheWrite5m: row.cacheWrite, cacheRead: row.cacheRead, output: row.output
                )
            ) {
                cost = estimated
            } else {
                cost = nil
            }
            if let cost {
                accumulator.add(day: day, tokens: row.tokens, cost: cost, model: row.model)
                if row.burnsGoQuota {
                    goWindowCosts.append((ms: row.date.timeIntervalSince1970 * 1000, cost: cost))
                }
                includesEstimatedCost = true
            } else {
                accumulator.addUnknownModel(day: day, model: row.model)
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
    /// galaxy. Zero-cost rows (free tiers) yield a $0 rate; models with no recorded rows get no
    /// entry and fall back to the pricing engine. Clamped to $4/M as a corruption guard — far above
    /// any real open-model rate (DeepSeek tops out at $0.28/M), so a pathological tiny sample can't
    /// fabricate a fortune while every real rate passes untouched.
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
    private static func effectiveRates(from rows: [Row]) -> [String: Double] {
        var totals: [String: (cost: Double, tokens: Double)] = [:]
        for row in rows where row.tokens > 0 {
            // Muse Spark and DeepSeek Pro must use the catalog — their DB samples
            // are either tiny/uncached (Muse: 7 rows / 60k tokens → $43/M blended
            // would price the 426M-token harness at $18k vs $81 at the supplement's
            // $1.25/$0.125 lane) or cache-mix-mismatched (Pro: Hermes reports
            // 98% cache_read at $0.0036/M, the DB's blended $0.43/M would inflate
            // the Hermes fold ~25x). Flash stays calibrated: its DB effective
            // $0.0085/M closely matches Hermes' cache-heavy $0.007/M, so the
            // blended rate is not systematically inflated and the existing
            // gateway test expects calibration.
            if row.model.hasPrefix("muse-") || row.model == "deepseek-v4-pro" || row.model == "deepseek/deepseek-v4-pro" {
                continue
            }
            let t = totals[row.model] ?? (0, 0)
            totals[row.model] = (t.cost + row.cost, t.tokens + Double(row.tokens))
        }
        var rates: [String: Double] = [:]
        rates.reserveCapacity(totals.count)
        for (model, t) in totals {
            rates[model] = min(max(t.cost / t.tokens, 0), 4e-6)
        }
        return rates
    }

    // MARK: - Parsing

    private struct Row {
        var ms: Double
        var cost: Double
        var tokens: Int
        var model: String
        var providerID: String
    }

    /// Parse the `json_group_array(json_array(...))` payload: an array of
    /// `[time_created, cost, tokensTotal, modelID, providerID]`. Rows with a missing timestamp/cost or a
    /// non-string providerID are skipped at this boundary.
    private static func parseRows(_ json: String) -> [Row] {
        guard let data = json.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return [] }

        var rows: [Row] = []
        rows.reserveCapacity(parsed.count)
        for element in parsed {
            guard let entry = element as? [Any], entry.count >= 5,
                  let ms = ProviderParse.number(entry[0]),
                  let cost = ProviderParse.number(entry[1]), cost >= 0,
                  let providerID = entry[4] as? String
            else { continue }
            // Clamp before the Int conversion so a corrupt, absurdly large token count can't trap
            // (Int(Double) crashes above Int.max). 1e15 is far above any real token total.
            let tokens = Int(min(max(ProviderParse.number(entry[2]) ?? 0, 0), 1e15))
            let model = (entry[3] as? String) ?? ""
            rows.append(Row(
                ms: ms,
                cost: cost,
                tokens: tokens,
                model: model,
                providerID: providerID
            ))
        }
        return rows
    }

    // MARK: - SQL

    /// SQL literal built from `hostedProviderIDs`, so the tracked list has one source of truth.
    private static let providerFilter = "(" + hostedProviderIDs.map { "'\($0)'" }.joined(separator: ",") + ")"

    static func dataSQL(cutoffMs: Int) -> String {
        """
        SELECT json_group_array(json_array(
                 time_created,
                 json_extract(data,'$.cost'),
                 COALESCE(json_extract(data,'$.tokens.total'),0),
                 json_extract(data,'$.modelID'),
                 json_extract(data,'$.providerID')))
        FROM message
        WHERE time_created >= \(cutoffMs)
          AND json_valid(data)
          AND json_extract(data,'$.role') = 'assistant'
          AND json_extract(data,'$.providerID') IN \(providerFilter)
          AND json_type(data,'$.cost') IN ('integer','real');
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
