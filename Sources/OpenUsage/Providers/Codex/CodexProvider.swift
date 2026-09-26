import Foundation

@MainActor
final class CodexProvider: ProviderRuntime {
    static func makeProvider(id: String = "codex", displayName: String = "Codex") -> Provider {
        Provider(
            id: id,
            displayName: displayName,
            icon: .providerMark("codex"),
            links: [
                .init(label: "Status", url: "https://status.openai.com/"),
                .init(label: "Dashboard", url: "https://chatgpt.com/codex/settings/usage")
            ]
        )
    }

    let provider: Provider
    let authStore: CodexAuthStore
    let usageClient: CodexUsageClient
    let logUsageScanner: CodexLogUsageScanner
    let proxyUsageScanner: CodexProxyUsageScanner
    let routerUsageScanner: CodexRouterUsageScanner
    let expectedIdentityKey: String?
    let allowsKeychainFallback: Bool
    let allowsUnattributedPiUsage: Bool
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing

    init(
        provider: Provider = CodexProvider.makeProvider(),
        authStore: CodexAuthStore = CodexAuthStore(),
        usageClient: CodexUsageClient = CodexUsageClient(),
        logUsageScanner: CodexLogUsageScanner = CodexLogUsageScanner(),
        proxyUsageScanner: CodexProxyUsageScanner = CodexProxyUsageScanner(),
        routerUsageScanner: CodexRouterUsageScanner = CodexRouterUsageScanner(),
        expectedIdentityKey: String? = nil,
        allowsKeychainFallback: Bool = true,
        allowsUnattributedPiUsage: Bool = true,
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() }
    ) {
        self.provider = provider
        let normalizedIdentity = CodexAuthStore.normalizedIdentityKey(expectedIdentityKey)
        self.authStore = authStore.scoped(to: normalizedIdentity)
        self.usageClient = usageClient
        self.logUsageScanner = logUsageScanner
        self.proxyUsageScanner = proxyUsageScanner
        self.routerUsageScanner = routerUsageScanner
        self.expectedIdentityKey = normalizedIdentity
        self.allowsKeychainFallback = allowsKeychainFallback
        self.allowsUnattributedPiUsage = allowsUnattributedPiUsage
        self.now = now
        self.pricing = pricing
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "\(provider.id).session", provider: provider, title: "Session")
                .exportingLimit("session", unit: "percent"),
            .percent(id: "\(provider.id).weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            .percent(id: "\(provider.id).spark", provider: provider, title: "Spark")
                .exportingLimit("spark", unit: "percent"),
            .percent(id: "\(provider.id).sparkWeekly", provider: provider, title: "Spark Weekly")
                .exportingLimit("sparkWeekly", unit: "percent"),
            .combined(id: "\(provider.id).credits", provider: provider, title: "Extra Usage", metricLabel: "Credits")
                .exportingLimit("credits", kind: .balance, unit: "credits", source: .value(kind: .count, label: "credits"))
                .exportingLimit("creditValue", kind: .balance, unit: "usd", source: .value(kind: .dollars)),
            .values(id: "\(provider.id).rateLimitResets", provider: provider, title: "Rate Limit Resets", metricLabel: "Rate Limit Resets", traySuffix: "resets", showsResetExpiries: true)
                .exportingLimit("rateLimitResets", kind: .balance, unit: "resets", source: .value(kind: .count, label: "available")),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: "From your Codex logs (estimated)"
                )
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        let fileCandidates = authStore.loadAuthCandidates().filter(isExpectedAccount)
        if fileCandidates.contains(where: \.hasUsableAccessToken) {
            return true
        }
        guard allowsKeychainFallback else { return false }
        let keychain = await loadOffMainActor { [authStore] in authStore.loadKeychainAuth() }
        return keychain.map { isExpectedAccount($0) && $0.hasUsableAccessToken } == true
    }

    func refresh() async -> ProviderSnapshot {
        let fileCandidates = authStore.loadAuthCandidates().filter(isExpectedAccount)
        var lastFallbackError: Error?

        for candidate in fileCandidates {
            do {
                return try await probe(authState: candidate)
            } catch let error as CodexAuthError where error.allowsAuthFallback {
                lastFallbackError = error
                continue
            } catch {
                return await localOnlySnapshot(after: error)
            }
        }

        if allowsKeychainFallback,
           let keychainCandidate = await loadOffMainActor({ [authStore] in authStore.loadKeychainAuth() }),
           isExpectedAccount(keychainCandidate)
        {
            do {
                return try await probe(authState: keychainCandidate)
            } catch {
                return await localOnlySnapshot(after: error)
            }
        }

        return await localOnlySnapshot(after: lastFallbackError ?? CodexAuthError.notLoggedIn)
    }

    /// The account boundary for a scoped card. A candidate that cannot prove which ChatGPT/Codex
    /// account it belongs to is rejected rather than guessed onto the card.
    private func isExpectedAccount(_ state: CodexAuthState) -> Bool {
        guard let expectedIdentityKey else { return true }
        guard let actual = Self.accountIdentity(in: state.auth) else { return false }
        return actual.caseInsensitiveCompare(expectedIdentityKey) == .orderedSame
    }

    private static func accountIdentity(in auth: CodexAuth) -> String? {
        CodexAuthStore.accountIdentity(in: auth)
    }

    private func probe(authState initialState: CodexAuthState) async throws -> ProviderSnapshot {
        var authState = initialState
        guard isExpectedAccount(authState) else { throw CodexAuthError.tokenConflict }
        guard var accessToken = authState.auth.tokens?.accessToken, !accessToken.isEmpty else {
            if authState.auth.apiKey?.isEmpty == false {
                throw CodexAuthError.usageAPIKey
            }
            throw CodexAuthError.notLoggedIn
        }

        if authStore.needsRefresh(authState.auth) {
            if let live = reloadLiveAuth(source: authState.source),
               let liveToken = live.auth.tokens?.accessToken, !liveToken.isEmpty {
                authState = live
                accessToken = liveToken
            }
        }

        if authStore.needsRefresh(authState.auth),
           let refreshToken = authState.auth.tokens?.refreshToken,
           !refreshToken.isEmpty {
            let refreshed = try await refreshAccessToken(authState: &authState, refreshToken: refreshToken)
            accessToken = refreshed
        }

        guard isExpectedAccount(authState) else { throw CodexAuthError.tokenConflict }
        let response = try await fetchUsageWithRetry(accessToken: accessToken, authState: &authState)
        let currentToken = authState.auth.tokens?.accessToken ?? accessToken
        let resetCredits = await fetchResetCreditsBestEffort(
            accessToken: currentToken,
            accountID: authState.auth.tokens?.accountID
        )
        var mapped = try CodexUsageMapper.mapUsageResponse(response, resetCredits: resetCredits, now: now())

        // Menu-bar background ticks only need Session/Weekly (and sibling) quota meters from the
        // rate-limit API. Skip the expensive local JSONL / FCC / CodexRouter history scan; the
        // data store merges prior token/history lines onto this snapshot.
        let usageHistory: ProviderUsageHistory?
        if ProviderRefreshContext.scope == .menuBar {
            usageHistory = nil
        } else {
            let pricing = await pricing()
            usageHistory = await appendLocalUsage(
                to: &mapped.lines,
                now: now(),
                pricing: pricing,
                accountIdentityKey: expectedIdentityKey ?? Self.accountIdentity(in: authState.auth)
            )
        }

        MetricLine.appendNoDataIfNeeded(&mapped.lines)
        return ProviderSnapshot.make(
            provider: provider,
            plan: mapped.plan,
            lines: mapped.lines,
            refreshedAt: now(),
            usageHistory: usageHistory
        )
    }

    /// Local Codex history remains useful when the remote quota endpoint is unavailable. Returning a
    /// successful snapshot with a warning prevents a stale, possibly mixed cached total from being
    /// presented as current accounting; the live quota meters are simply absent until auth recovers.
    private func localOnlySnapshot(after error: Error) async -> ProviderSnapshot {
        var lines: [MetricLine] = []
        let usageHistory: ProviderUsageHistory?
        if ProviderRefreshContext.scope == .menuBar {
            // Icons-only pass: do not scrape local history just to paint a warning card; keep prior
            // spend/history via the data-store merge.
            usageHistory = nil
        } else {
            usageHistory = await appendLocalUsage(
                to: &lines,
                now: now(),
                pricing: await pricing(),
                accountIdentityKey: expectedIdentityKey
            )
        }
        MetricLine.appendNoDataIfNeeded(&lines)
        return ProviderSnapshot.make(
            provider: provider,
            plan: nil,
            lines: lines,
            refreshedAt: now(),
            usageHistory: usageHistory,
            warning: "Live Codex limits unavailable: \(error.localizedDescription)"
        )
    }

    private func appendLocalUsage(
        to lines: inout [MetricLine],
        now: Date,
        pricing: ModelPricing,
        accountIdentityKey: String?
    ) async -> ProviderUsageHistory? {
        let nativeScan = await logUsageScanner.scan(now: now, pricing: pricing)
        let proxyScan = await proxyUsageScanner.scan(
            accountIdentityKey: accountIdentityKey,
            now: now,
            pricing: pricing
        )
        // Unscoped legacy router rows (no account fingerprint) are only safe on the
        // single/default card. Multi-account cards always carry expectedIdentityKey and
        // therefore require a matching stamp — see CodexRouterUsageScanner.
        // Never absorb unscoped router rows onto a Codex card. With multiple ChatGPT
        // homes (CodexRouter pool), dumping ~tens of thousands of unstamped events onto
        // the "default" card inflates token/spend by billions of tokens. Stamped rows
        // still match via fingerprint / accountId / pool alias.
        let routerScan = await routerUsageScanner.scan(
            accountIdentityKey: accountIdentityKey,
            allowsUnscopedEvents: false,
            now: now,
            pricing: pricing
        )
        let piScan = allowsUnattributedPiUsage
            ? await PiUsageScanner.shared.scan(cardID: provider.id, now: now, pricing: pricing)
            : nil
        // Multi-account cards (expectedIdentityKey set): prefer CodexRouter stamped metering as
        // primary. Shared ~/.codex session trees often mix both accounts' history, so logs-first
        // made both cards show the same inflated chart. Single-card installs keep logs → FCC →
        // router so native rollouts still win when the router ledger is absent.
        let usedLogs: Bool
        let usedProxy: Bool
        let usedRouter: Bool
        let coreScan: LogUsageScan?
        if expectedIdentityKey != nil {
            let routerThenLogs = DailyUsageAccumulator.mergedPreferringPrimary(
                routerScan,
                fillingGapsFrom: [nativeScan]
            )
            let withProxy = DailyUsageAccumulator.mergedPreferringPrimary(
                routerThenLogs.scan,
                fillingGapsFrom: [proxyScan]
            )
            coreScan = withProxy.scan
            usedRouter = routerScan != nil
            usedLogs = routerThenLogs.usedSupplement
            usedProxy = withProxy.usedSupplement
        } else {
            let logsAndProxy = DailyUsageAccumulator.mergedPreferringPrimary(
                nativeScan,
                fillingGapsFrom: [proxyScan]
            )
            let logsProxyAndRouter = DailyUsageAccumulator.mergedPreferringPrimary(
                logsAndProxy.scan,
                fillingGapsFrom: [routerScan]
            )
            coreScan = logsProxyAndRouter.scan
            usedLogs = nativeScan != nil
            usedProxy = logsAndProxy.usedSupplement
            usedRouter = logsProxyAndRouter.usedSupplement
        }
        guard !Task.isCancelled, let scan = DailyUsageAccumulator.merged([coreScan, piScan]) else {
            return nil
        }

        let sourceNames = [
            usedLogs ? "Codex logs" : nil,
            usedProxy ? "FCC proxy" : nil,
            usedRouter ? "Codex Router" : nil,
            piScan.map { _ in "pi" }
        ].compactMap { $0 }
        let note = "From your \(sourceNames.joined(separator: ", ")) (estimated)"
        let usageHistory = ProviderUsageHistory(
            series: scan.series,
            modelUsage: scan.modelUsage,
            unknownModelsByDay: scan.unknownModelsByDay
        )
        SpendTileMapper.appendTokenUsage(
            scan.series,
            to: &lines,
            now: now,
            unknownModelsByDay: scan.unknownModelsByDay,
            modelUsage: scan.modelUsage,
            modelSourceNote: note
        )
        SpendTileMapper.appendUsageTrend(scan.series, to: &lines, now: now, note: note)
        return usageHistory
    }

    private func fetchResetCreditsBestEffort(accessToken: String, accountID: String?) async -> HTTPResponse? {
        do {
            return try await usageClient.fetchResetCredits(accessToken: accessToken, accountID: accountID)
        } catch {
            AppLog.warn(LogTag.plugin("codex"), "reset-credit fetch failed; using usage-body count: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchUsageWithRetry(accessToken: String, authState: inout CodexAuthState) async throws -> HTTPResponse {
        var working = authState
        defer { authState = working }
        return try await ProviderAuthRetry.fetch(
            token: accessToken,
            attempt: { try await self.usageClient.fetchUsage(accessToken: $0, accountID: working.auth.tokens?.accountID) },
            refreshAccessToken: {
                guard let refreshToken = working.auth.tokens?.refreshToken, !refreshToken.isEmpty else {
                    throw CodexAuthError.tokenExpired
                }
                do {
                    return try await self.refreshAccessToken(authState: &working, refreshToken: refreshToken)
                } catch let error as CodexAuthError {
                    throw error
                } catch {
                    throw CodexUsageError.connectionFailed
                }
            },
            connectionFailed: CodexUsageError.connectionFailed,
            authExpired: CodexAuthError.tokenExpired
        )
    }

    private func reloadLiveAuth(source: CodexAuthState.Source) -> CodexAuthState? {
        let candidate: CodexAuthState?
        switch source {
        case .file(let path):
            candidate = authStore.loadAuth(at: path)
        case .keychain:
            guard allowsKeychainFallback else { return nil }
            candidate = authStore.loadKeychainAuth()
        }
        guard let candidate, isExpectedAccount(candidate) else { return nil }
        return candidate
    }

    private func refreshAccessToken(authState: inout CodexAuthState, refreshToken: String) async throws -> String {
        let response = try await usageClient.refreshToken(refreshToken)
        authState.auth.tokens?.accessToken = response.accessToken
        if let refreshToken = response.refreshToken {
            authState.auth.tokens?.refreshToken = refreshToken
        }
        if let idToken = response.idToken {
            authState.auth.tokens?.idToken = idToken
        }
        authState.auth.lastRefresh = OpenUsageISO8601.string(from: now())
        guard isExpectedAccount(authState) else { throw CodexAuthError.tokenConflict }
        do {
            try authStore.save(authState)
        } catch {
            AppLog.error(LogTag.auth("codex"), "failed to persist rotated credentials; using the refreshed token for this session only: \(error.localizedDescription)")
        }
        return response.accessToken
    }
}

