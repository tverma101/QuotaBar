import Foundation

/// Tracks pool quota for Antigravity (Google's Codeium/Windsurf-derived AI IDE). Quotas are
/// fraction-based and shown as up to four percent meters: the shared Gemini pool and the shared
/// non-Gemini pool (Claude, GPT-OSS), each with a rolling 5-hour and a weekly window.
///
/// Probe order, best source first:
/// 1. Antigravity language server (running app) — richest, gives the authoritative plan.
/// 2. `agy` language server (running CLI).
/// 3. Keychain token → Google Cloud Code (works with the app closed); refreshes via Google OAuth.
/// 4. T3 Code's private Antigravity instances keep file-based OAuth credentials (`acp_token.json`);
///    when the Keychain is absent or its ACL blocks this build, those refresh without any grant.
///
/// On each source, `RetrieveUserQuotaSummary` is tried first (the only endpoint reporting the merged
/// pools and the weekly windows); builds without it fall back to the legacy per-model endpoints,
/// which are 5h-only — the weekly meters read "No data" there.
@MainActor
final class AntigravityProvider: ProviderRuntime {
    let provider = Provider(id: "antigravity", displayName: "Antigravity", icon: .providerMark("antigravity"))

    let authStore: AntigravityAuthStore
    let usageClient: AntigravityUsageClient
    let discovery: LanguageServerDiscovery
    let dbUsageScanner: AntigravityDbUsageScanner
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing

    func unloadLocalAccountingCachesForMemoryPressure() async {
        await dbUsageScanner.unloadCachesForMemoryPressure()
    }

    nonisolated private static let antigravityServerOptions = LanguageServerDiscovery.Options(
        processName: "language_server",
        markers: ["antigravity", "antigravity-ide"],
        csrfFlag: "--csrf_token",
        portFlag: "--extension_server_port"
    )
    nonisolated private static let agyServerOptions = LanguageServerDiscovery.Options(
        processName: "agy",
        markers: [],
        csrfFlag: "",
        portFlag: nil
    )

    private static let usageSourceNote = "From your Antigravity conversations (estimated)"

    init(
        authStore: AntigravityAuthStore = AntigravityAuthStore(),
        usageClient: AntigravityUsageClient = AntigravityUsageClient(),
        discovery: LanguageServerDiscovery = LanguageServerDiscovery(),
        dbUsageScanner: AntigravityDbUsageScanner = AntigravityDbUsageScanner(),
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = { ModelPricingStore.shared.current() }
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.discovery = discovery
        self.dbUsageScanner = dbUsageScanner
        self.now = now
        self.pricing = pricing
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: AntigravityMetric.geminiID, provider: provider, title: AntigravityMetric.sessionLabel, sessionStartSignal: .zeroUsage)
                .exportingLimit("geminiSession", unit: "percent"),
            .percent(id: AntigravityMetric.geminiWeeklyID, provider: provider, title: AntigravityMetric.weeklyLabel)
                .exportingLimit("geminiWeekly", unit: "percent"),
            .percent(id: AntigravityMetric.argonWeeklyID, provider: provider, title: AntigravityMetric.argonWeeklyLabel)
                .exportingLimit("argonWeekly", unit: "percent")
                .hidingWhenEmpty(),
            .percent(id: AntigravityMetric.claudeID, provider: provider, title: AntigravityMetric.claudeLabel, sessionStartSignal: .zeroUsage)
                .exportingLimit("nonGeminiSession", unit: "percent")
                .hidingWhenEmpty(),
            .percent(id: AntigravityMetric.claudeWeeklyID, provider: provider, title: AntigravityMetric.claudeWeeklyLabel)
                .exportingLimit("nonGeminiWeekly", unit: "percent")
                .hidingWhenEmpty(),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: Self.usageSourceNote
                )
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        // A running local server is an independent quota source. Discovery only inspects the local
        // process table and its listening sockets; it never calls Google during first-run seeding.
        let discovery = self.discovery
        let hasLocalServer = await loadOffMainActor {
            guard let processSnapshot = discovery.processSnapshot(), !Task.isCancelled else { return false }
            if discovery.discover(Self.antigravityServerOptions, processSnapshot: processSnapshot) != nil {
                return true
            }
            guard !Task.isCancelled else { return false }
            return discovery.discover(Self.agyServerOptions, processSnapshot: processSnapshot) != nil
        }

        // The Keychain login remains the source of truth for Cloud Code when readable. The app-owned
        // access-token cache is derivative and must never independently enable the provider after
        // logout. T3 Code's file credentials are an independent login that needs no Keychain grant.
        do {
            let keychainToken = try await loadOffMainActor { [authStore] in
                try authStore.loadKeychainToken()
            }
            guard !Task.isCancelled else { return hasLocalServer }
            guard keychainToken != nil else {
                let hasFileCredential = await loadOffMainActor { [authStore] in
                    !authStore.loadFileCredentials().isEmpty
                }
                guard !Task.isCancelled else { return hasLocalServer }
                if hasFileCredential { return true }
                await loadOffMainActor { [authStore] in authStore.discardCachedToken() }
                return hasLocalServer
            }
            return true
        } catch is CancellationError {
            // A cancelled local probe is not evidence that a Keychain credential exists.
            return hasLocalServer
        } catch {
            // Detection runs once; keep an indeterminate store enabled so refresh can show the repair.
            return true
        }
    }

    func refresh() async -> ProviderSnapshot {
        // Fold-only passes run the conversation-database scan (SQLite reads, protobuf decode, and
        // the priced fold) in the scan-worker child when available; the body below stays the
        // in-process path for the fallback and for meter/full scopes.
        if ProviderRefreshContext.scope.suppressesLiveQuota {
            return await ScanWorkerClient.shared.foldOnlySnapshot(
                provider: provider,
                inProcessFallback: { await self.refreshInProcess() }
            )
        }
        return await refreshInProcess()
    }

    private func refreshInProcess() async -> ProviderSnapshot {
        let scope = ProviderRefreshContext.scope
        let refreshedAt = now()
        // Fold-only passes have no live quota evidence. Any quota-refreshing scope may replace old
        // rows only when its response proves that every bucket was represented.
        let mayReplacePriorQuotaProgress = scope.refreshesQuotaDomain
        let historyTask: Task<LocalHistoryResult?, Never>?
        if scope.skipsLocalAccounting {
            historyTask = nil
        } else {
            historyTask = Task { await scanLocalHistory(through: refreshedAt) }
        }

        return await withTaskCancellationHandler {
            do {
                // Fold-only pass (panel phase 2): the meters-only phase just ran the meter strategy;
                // re-running it per fold would double every panel-open request. The store's merge
                // recovers the meters and plan onto the fresh DB history.
                let result = scope.suppressesLiveQuota
                    ? StrategyResult(plan: nil, lines: [])
                    : try await probe()
                try Task.checkCancellation()

                // Meters-only passes (menu-bar ticks, panel phase 1) only need the live quota meters.
                // Skip the local DB history scan; the data store merges prior spend/history lines onto
                // this snapshot.
                if scope.skipsLocalAccounting {
                    return ProviderSnapshot.make(
                        provider: provider,
                        plan: result.plan,
                        lines: result.lines,
                        refreshedAt: refreshedAt,
                        usageHistory: nil,
                        warning: result.warning,
                        replacesPriorQuotaProgress: mayReplacePriorQuotaProgress && result.replacesPriorQuotaProgress
                    )
                }

                let history = await historyTask?.value
                try Task.checkCancellation()
                var lines = result.lines
                if let history {
                    lines.append(contentsOf: history.lines)
                }

                return ProviderSnapshot.make(
                    provider: provider,
                    plan: result.plan,
                    lines: lines,
                    refreshedAt: refreshedAt,
                    usageHistory: history?.history,
                    warning: result.warning,
                    historyWarning: history?.warning,
                    replacesPriorQuotaProgress: mayReplacePriorQuotaProgress && result.replacesPriorQuotaProgress
                )
            } catch is CancellationError {
                return cancelledRefreshSnapshot(provider: provider)
            } catch {
                guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }
                var snapshot = ProviderSnapshot.error(provider: provider, error: error)
                let history = await historyTask?.value
                guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }
                if let history {
                    // A quota outage must not hide valid local token history, especially on first run.
                    // Keep the error badge as the only error line; WidgetDataStore merges this history
                    // into the last-good display while retaining the error and retry backoff.
                    snapshot.usageHistory = history.history
                    if history.history != nil { snapshot.historyRefreshedAt = refreshedAt }
                    snapshot.historyWarning = history.warning
                }
                return snapshot
            }
        } onCancel: {
            historyTask?.cancel()
        }
    }

    private struct LocalHistoryResult: Sendable {
        let history: ProviderUsageHistory?
        let lines: [MetricLine]
        let warning: String?
    }

    private func scanLocalHistory(through refreshedAt: Date) async -> LocalHistoryResult? {
        guard !Task.isCancelled else { return nil }
        let scanResult = await dbUsageScanner.scanWithStatus(
            daysBack: UsageHistoryWindow.lifetimeDays(through: refreshedAt),
            now: refreshedAt,
            pricing: await pricing()
        )
        guard !Task.isCancelled else { return nil }
        guard let scan = scanResult.scan else {
            guard scanResult.hasReadFailures else { return nil }
            return LocalHistoryResult(
                history: nil,
                lines: [],
                warning: "Antigravity conversation history could not be read. Any displayed totals are last known and may be stale."
            )
        }

        let partialDays = scan.unmeasuredUsageDays ?? []
        let hasOnlyUnmeasuredUsage = scan.series.daily.isEmpty && !partialDays.isEmpty
        let history = hasOnlyUnmeasuredUsage ? nil : ProviderUsageHistory(
            series: scan.series,
            modelUsage: scan.modelUsage,
            unknownModelsByDay: scan.unknownModelsByDay,
            apiEstimateByDay: scan.apiEstimateByDay,
            apiEstimateIncompleteDays: scan.apiEstimateIncompleteDays,
            partialDays: scan.unmeasuredUsageDays
        )
        var lines: [MetricLine] = []
        if !hasOnlyUnmeasuredUsage {
            SpendTileMapper.appendTokenUsage(
                scan.series,
                to: &lines,
                now: refreshedAt,
                unknownModelsByDay: scan.unknownModelsByDay,
                modelUsage: scan.modelUsage,
                modelSourceNote: Self.usageSourceNote,
                partialDays: partialDays,
                apiEstimateByDay: scan.apiEstimateByDay
            )
            SpendTileMapper.appendUsageTrend(
                scan.series,
                to: &lines,
                now: refreshedAt,
                note: Self.usageSourceNote,
                partialDays: partialDays,
                partialNote: "incomplete Antigravity history is shown as a lower bound"
            )
        }
        let warning = partialDays.isEmpty
            ? (scanResult.hasReadFailures
                ? "Some Antigravity conversation stores could not be read. Visible totals are lower bounds."
                : nil)
            : (scanResult.hasReadFailures
                ? "Some Antigravity conversation stores could not be read, and some history could not be dated or counted. Visible totals are lower bounds."
                : "Some Antigravity history could not be dated or counted. Visible totals are lower bounds.")
        return LocalHistoryResult(history: history, lines: lines, warning: warning)
    }

    /// Shared with the Cloud Code probe in AntigravityCloudCode.swift.
    struct StrategyResult {
        var plan: String?
        var lines: [MetricLine]
        var replacesPriorQuotaProgress = true
        var warning: String?
    }

    private func probe() async throws -> StrategyResult {
        try Task.checkCancellation()
        let discovery = self.discovery
        let processSnapshot = await loadOffMainActor { discovery.processSnapshot() }
        try Task.checkCancellation()
        if let processSnapshot {
            if let result = try await probeLS(
                options: Self.antigravityServerOptions,
                processSnapshot: processSnapshot
            ) {
                return result
            }
            if let result = try await probeLS(
                options: Self.agyServerOptions,
                processSnapshot: processSnapshot
            ) {
                return result
            }
        }
        try Task.checkCancellation()
        return try await probeCloudCode()
    }

    // MARK: - Language server

    private func probeLS(
        options: LanguageServerDiscovery.Options,
        processSnapshot: String
    ) async throws -> StrategyResult? {
        let discovery = self.discovery
        guard let discovered = await loadOffMainActor({
            discovery.discover(options, processSnapshot: processSnapshot)
        }) else { return nil }

        // HTTPS first (the LS serves a self-signed cert), then HTTP, then the HTTP-only extension port.
        var endpoints: [(scheme: String, port: Int)] = []
        for port in discovered.ports {
            endpoints.append(("https", port))
            endpoints.append(("http", port))
        }
        if let extensionPort = discovered.extensionPort {
            endpoints.append(("http", extensionPort))
        }

        for endpoint in endpoints {
            try Task.checkCancellation()
            // The quota summary is authoritative (merged pools + weekly windows), so it goes first.
            // A parsed summary — even one with zero usable buckets — ends the probe: the legacy
            // endpoints below fabricate "fully used" from missing quota info, so an authoritative
            // answer must never fall through to them. Empty lines render as "No data" rows.
            if let summary = try await usageClient.callLS(scheme: endpoint.scheme, port: endpoint.port, csrf: discovered.csrf, method: "RetrieveUserQuotaSummary") {
                if (200..<300).contains(summary.statusCode) {
                    DiagnosticGate.clearFailures(prefix: Self.quotaSummaryDiagnosticPrefix(for: endpoint))
                    let sourceID = "language-server:\(endpoint.scheme):\(endpoint.port)"
                    if let summary = AntigravityUsageMapper.parseQuotaSummaryResult(
                        summary.body,
                        sourceID: sourceID
                    ) {
                        // The plan comes from an independent GetUserStatus call; the summary never
                        // gates on it — a failed plan lookup just leaves the plan blank.
                        var plan: String?
                        if let status = try await usageClient.callLS(scheme: endpoint.scheme, port: endpoint.port, csrf: discovered.csrf, method: "GetUserStatus"),
                           (200..<300).contains(status.statusCode) {
                            plan = AntigravityUsageMapper.parseUserStatus(status.body)?.plan
                        }
                        return StrategyResult(
                            plan: plan,
                            lines: summary.lines,
                            replacesPriorQuotaProgress: summary.isComplete,
                            warning: summary.isComplete
                                ? nil
                                : "Some Antigravity quota limits could not be read. Missing limits may retain older values."
                        )
                    }
                    // The named RPC answered, but its schema is not usable. Preserve prior meters
                    // with an explicit warning; legacy per-model endpoints turn missing quota into
                    // fabricated depleted meters and would hide the schema failure.
                    return StrategyResult(
                        plan: nil,
                        lines: [],
                        replacesPriorQuotaProgress: false,
                        warning: "Antigravity quota summary could not be read. Existing limits are retained."
                    )
                } else if summary.statusCode == 404 {
                    DiagnosticGate.clearFailures(prefix: Self.quotaSummaryDiagnosticPrefix(for: endpoint))
                    AntigravityUsageMapper.clearQuotaSummaryDiagnostics(
                        sourceID: "language-server:\(endpoint.scheme):\(endpoint.port)"
                    )
                } else {
                    // 404 = a build without the RPC (expected; legacy is the truth there, no retry).
                    // Anything else is surprising enough to say before degrading to 5h-only data.
                    DiagnosticGate.logOnce(
                        for: Self.quotaSummaryDiagnosticPrefix(for: endpoint) + String(summary.statusCode)
                    ) {
                        AppLog.warn(LogTag.plugin("antigravity"), "RetrieveUserQuotaSummary HTTP \(summary.statusCode); falling back to legacy quota endpoints")
                    }
                }
            }

            guard let response = try await usageClient.callLS(scheme: endpoint.scheme, port: endpoint.port, csrf: discovered.csrf, method: "GetUserStatus"),
                  (200..<300).contains(response.statusCode)
            else {
                continue
            }

            if let parsed = AntigravityUsageMapper.parseUserStatus(response.body) {
                let lines = AntigravityUsageMapper.buildLines(parsed.configs)
                if !lines.isEmpty { return StrategyResult(plan: parsed.plan, lines: lines) }
            }

            // The endpoint answered but GetUserStatus had nothing usable — try the documented fallback.
            if let fallback = try await usageClient.callLS(scheme: endpoint.scheme, port: endpoint.port, csrf: discovered.csrf, method: "GetCommandModelConfigs"),
               (200..<300).contains(fallback.statusCode),
               let configs = AntigravityUsageMapper.parseCommandModelConfigs(fallback.body) {
                let lines = AntigravityUsageMapper.buildLines(configs)
                if !lines.isEmpty { return StrategyResult(plan: nil, lines: lines) }
            }
        }
        return nil
    }

    private static func quotaSummaryDiagnosticPrefix(for endpoint: (scheme: String, port: Int)) -> String {
        let identity = JSONLScanCachePaths.stableFingerprint("\(endpoint.scheme):\(endpoint.port)")
        return "antigravity.quota-summary.\(identity)."
    }
}
