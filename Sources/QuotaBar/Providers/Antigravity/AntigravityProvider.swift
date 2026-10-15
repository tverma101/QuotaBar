import Foundation

/// Tracks pool quota for Antigravity (Google's Codeium/Windsurf-derived AI IDE). Quotas are
/// fraction-based and shown as up to four percent meters: the shared Gemini pool and the shared
/// non-Gemini pool (Claude, GPT-OSS), each with a rolling 5-hour and a weekly window.
///
/// Probe order, best source first:
/// 1. Antigravity language server (running app) — richest, gives the authoritative plan.
/// 2. `agy` language server (running CLI).
/// 3. Keychain token → Google Cloud Code (works with the app closed); refreshes via Google OAuth.
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

    private static let antigravityServerOptions = LanguageServerDiscovery.Options(
        processName: "language_server",
        markers: ["antigravity", "antigravity-ide"],
        csrfFlag: "--csrf_token",
        portFlag: "--extension_server_port"
    )
    private static let agyServerOptions = LanguageServerDiscovery.Options(
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
            .percent(id: AntigravityMetric.claudeID, provider: provider, title: AntigravityMetric.claudeLabel, sessionStartSignal: .zeroUsage)
                .exportingLimit("nonGeminiSession", unit: "percent"),
            .percent(id: AntigravityMetric.claudeWeeklyID, provider: provider, title: AntigravityMetric.claudeWeeklyLabel)
                .exportingLimit("nonGeminiWeekly", unit: "percent"),
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
        var hasLocalServer = await hasDiscoveredLocalServer(options: Self.antigravityServerOptions)
        if !hasLocalServer {
            hasLocalServer = await hasDiscoveredLocalServer(options: Self.agyServerOptions)
        }

        // The Keychain login remains the source of truth for Cloud Code. The app-owned access-token
        // cache is derivative and must never independently enable the provider after logout.
        do {
            let keychainToken = try await loadOffMainActor { [authStore] in
                try authStore.loadKeychainToken()
            }
            guard !Task.isCancelled else { return hasLocalServer }
            guard keychainToken != nil else {
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
        let scope = ProviderRefreshContext.scope
        let refreshedAt = now()
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
                        usageHistory: nil
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
                    usageHistory: history?.history
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
                }
                return snapshot
            }
        } onCancel: {
            historyTask?.cancel()
        }
    }

    private struct LocalHistoryResult: Sendable {
        let history: ProviderUsageHistory
        let lines: [MetricLine]
    }

    private func scanLocalHistory(through refreshedAt: Date) async -> LocalHistoryResult? {
        guard !Task.isCancelled,
              let scan = await dbUsageScanner.scan(
                  daysBack: UsageHistoryWindow.lifetimeDays(through: refreshedAt),
                  now: refreshedAt,
                  pricing: await pricing()
              ),
              !Task.isCancelled
        else { return nil }

        let history = ProviderUsageHistory(
            series: scan.series,
            modelUsage: scan.modelUsage,
            unknownModelsByDay: scan.unknownModelsByDay,
            apiEstimateByDay: scan.apiEstimateByDay,
            apiEstimateIncompleteDays: scan.apiEstimateIncompleteDays
        )
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            scan.series,
            to: &lines,
            now: refreshedAt,
            unknownModelsByDay: scan.unknownModelsByDay,
            modelUsage: scan.modelUsage,
            modelSourceNote: Self.usageSourceNote,
            apiEstimateByDay: scan.apiEstimateByDay
        )
        SpendTileMapper.appendUsageTrend(
            scan.series,
            to: &lines,
            now: refreshedAt,
            note: Self.usageSourceNote
        )
        return LocalHistoryResult(history: history, lines: lines)
    }

    private struct StrategyResult {
        var plan: String?
        var lines: [MetricLine]
    }

    private func probe() async throws -> StrategyResult {
        try Task.checkCancellation()
        if let result = try await probeLS(options: Self.antigravityServerOptions) {
            return result
        }
        if let result = try await probeLS(options: Self.agyServerOptions) {
            return result
        }
        try Task.checkCancellation()
        return try await probeCloudCode()
    }

    // MARK: - Language server

    private func hasDiscoveredLocalServer(options: LanguageServerDiscovery.Options) async -> Bool {
        let discovery = self.discovery
        return await loadOffMainActor { discovery.discover(options) != nil }
    }

    private func probeLS(options: LanguageServerDiscovery.Options) async throws -> StrategyResult? {
        let discovery = self.discovery
        guard let discovered = await loadOffMainActor({ discovery.discover(options) }) else { return nil }

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
                    if let lines = AntigravityUsageMapper.parseQuotaSummary(summary.body) {
                        // The plan comes from an independent GetUserStatus call; the summary never
                        // gates on it — a failed plan lookup just leaves the plan blank.
                        var plan: String?
                        if let status = try await usageClient.callLS(scheme: endpoint.scheme, port: endpoint.port, csrf: discovered.csrf, method: "GetUserStatus"),
                           (200..<300).contains(status.statusCode) {
                            plan = AntigravityUsageMapper.parseUserStatus(status.body)?.plan
                        }
                        return StrategyResult(plan: plan, lines: lines)
                    }
                    // 2xx but not a summary payload — the parser warned; fall to the legacy flow.
                } else if summary.statusCode != 404 {
                    // 404 = a build without the RPC (expected; legacy is the truth there, no retry).
                    // Anything else is surprising enough to say before degrading to 5h-only data.
                    AppLog.warn(LogTag.plugin("antigravity"), "RetrieveUserQuotaSummary HTTP \(summary.statusCode); falling back to legacy quota endpoints")
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

    // MARK: - Cloud Code

    private func probeCloudCode() async throws -> StrategyResult {
        let authStore = self.authStore
        let keychainToken = try await loadOffMainActor { try authStore.loadKeychainToken() }
        try Task.checkCancellation()

        guard let keychainToken else {
            // Proven logout invalidates the derived cache. A Keychain read failure throws above and
            // deliberately leaves the cache untouched for recovery.
            await loadOffMainActor { authStore.discardCachedToken() }
            throw AntigravityError.notSignedIn
        }

        var tokens: [String] = []
        var hasKnownExpiredAccessToken = false
        if let access = keychainToken.accessToken {
            if authStore.isUsable(expiry: keychainToken.expiry) {
                tokens.append(access)
            } else {
                hasKnownExpiredAccessToken = true
            }
        }
        if let cached = await loadOffMainActor({ authStore.loadCachedToken(matching: keychainToken) }),
           !tokens.contains(cached) {
            try Task.checkCancellation()
            tokens.append(cached)
        }
        try Task.checkCancellation()

        // We have something to authenticate with if any token was tried or a refresh token exists. Used
        // to tell a transient outage ("temporarily unavailable") apart from a genuine "not signed in".
        let hasCredentials = !tokens.isEmpty || (keychainToken.refreshToken?.isEmpty == false)

        var sawAuthFailure = false
        for token in tokens {
            switch try await fetchCloudCode(token: token) {
            case .success(let result): return result
            case .authFailed: sawAuthFailure = true
            case .forbidden: throw AntigravityError.accessDenied
            case .unavailable: break
            }
        }

        // Only refresh on evidence of an auth failure (or no token to try) — a transient Cloud Code
        // outage must not trigger a Google OAuth refresh every cycle.
        if sawAuthFailure || tokens.isEmpty, let refreshToken = keychainToken.refreshToken {
            switch try await usageClient.refreshGoogleToken(refreshToken) {
            case .refreshed(let accessToken, let expiresIn):
                try Task.checkCancellation()
                let cached = try await loadOffMainActor {
                    try authStore.cacheToken(
                        accessToken,
                        expiresIn: expiresIn,
                        matching: keychainToken
                    )
                }
                guard cached else { throw AntigravityError.authExpired }
                try Task.checkCancellation()
                switch try await fetchCloudCode(token: accessToken) {
                case .success(let result): return result
                case .authFailed: throw AntigravityError.authExpired
                case .forbidden: throw AntigravityError.accessDenied
                // The refreshed token is valid, so a non-2xx here is a transient outage, not bad auth.
                case .unavailable: throw AntigravityError.unavailable
                }
            // The refresh token itself is dead (revoked / expired) — that's expired auth, not an outage.
            case .authFailed: throw AntigravityError.authExpired
            case .clientConfigurationInvalid: throw AntigravityError.oauthClientConfigurationInvalid
            // Refresh was only transiently unavailable (throttled / 5xx / network). The refresh token may
            // still be valid, so report a transient outage — even if a token 401'd, an expired access
            // token is normal and isn't evidence the sign-in is dead.
            case .unavailable: throw AntigravityError.unavailable
            }
        }

        // Reached only when no refresh was attempted (no refresh token): a rejected token with no way to
        // refresh is genuinely expired auth.
        if sawAuthFailure || hasKnownExpiredAccessToken { throw AntigravityError.authExpired }
        // Signed in but every endpoint was unreachable — report a transient failure, not "not signed in".
        if hasCredentials { throw AntigravityError.unavailable }
        throw AntigravityError.notSignedIn
    }

    private enum CloudCodeProbe {
        case success(StrategyResult)
        case authFailed
        case forbidden
        case unavailable
    }

    private enum CodeAssistLookup {
        case response(plan: String?, project: String?)
        case authFailed
        case forbidden
        case unavailable

        var plan: String? {
            guard case .response(let plan, _) = self else { return nil }
            return plan
        }
    }

    private func fetchCloudCode(token: String) async throws -> CloudCodeProbe {
        // Authoritative first: the quota summary (merged pools + weekly windows). A parsed summary —
        // even one with zero usable buckets — is the answer and must never fall into the legacy chain
        // below, which fabricates "fully used" from missing quota info. A 404 (build without the RPC)
        // reads as `.unavailable` and falls through. The independent plan lookup runs in parallel.
        let codeAssistTask = Task { try await loadCodeAssist(token: token) }
        return try await withTaskCancellationHandler {
            defer { codeAssistTask.cancel() }
            switch try await usageClient.cloudCode(path: AntigravityUsageClient.quotaSummaryPath, token: token, userAgent: "antigravity", body: [:]) {
            case .authFailed:
                return .authFailed
            case .forbidden:
                return .forbidden
            case .ok(let data):
                if let lines = AntigravityUsageMapper.parseQuotaSummary(data) {
                    return .success(StrategyResult(plan: try await codeAssistTask.value.plan, lines: lines))
                }
                // 2xx but not a summary payload — the parser warned; fall to the legacy chain.
            case .unavailable:
                break
            }

            // Legacy: fetchAvailableModels — the full Antigravity model set (Gemini + Claude + GPT-OSS).
            switch try await usageClient.cloudCode(path: AntigravityUsageClient.fetchModelsPath, token: token, userAgent: "antigravity", body: [:]) {
            case .authFailed:
                return .authFailed
            case .forbidden:
                return .forbidden
            case .ok(let data):
                let lines = AntigravityUsageMapper.buildLines(AntigravityUsageMapper.parseCloudCodeModels(data))
                if !lines.isEmpty {
                    return .success(StrategyResult(plan: try await codeAssistTask.value.plan, lines: lines))
                }
            case .unavailable:
                break
            }

            // Fallback: the shared loadCodeAssist result supplies both the plan and project.
            // Its request already ran alongside the summary/models lookups.
            var plan: String?
            var project: String?
            switch try await codeAssistTask.value {
            case .authFailed: return .authFailed
            case .forbidden: return .forbidden
            case .response(let loadedPlan, let loadedProject):
                plan = loadedPlan
                project = loadedProject
            case .unavailable: break
            }

            var quota = try await usageClient.cloudCode(
                path: AntigravityUsageClient.retrieveQuotaPath,
                token: token,
                userAgent: "agy",
                body: project.map { ["project": $0] } ?? [:]
            )
            if case .unavailable = quota, project != nil {
                quota = try await usageClient.cloudCode(path: AntigravityUsageClient.retrieveQuotaPath, token: token, userAgent: "agy", body: [:])
            }
            switch quota {
            case .authFailed: return .authFailed
            case .forbidden: return .forbidden
            case .ok(let data):
                let lines = AntigravityUsageMapper.buildLines(AntigravityUsageMapper.parseQuotaBuckets(data))
                if !lines.isEmpty { return .success(StrategyResult(plan: plan, lines: lines)) }
            case .unavailable: break
            }
            return .unavailable
        } onCancel: {
            codeAssistTask.cancel()
        }
    }

    private func loadCodeAssist(token: String) async throws -> CodeAssistLookup {
        switch try await usageClient.cloudCode(
            path: AntigravityUsageClient.loadCodeAssistPath,
            token: token,
            userAgent: "agy",
            body: [:]
        ) {
        case .authFailed:
            return .authFailed
        case .forbidden:
            return .forbidden
        case .ok(let data):
            return .response(
                plan: AntigravityUsageMapper.parseLoadCodeAssistPlan(data),
                project: AntigravityUsageMapper.parseProject(data)
            )
        case .unavailable:
            return .unavailable
        }
    }
}
