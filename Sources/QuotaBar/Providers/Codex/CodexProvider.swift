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
    let piUsageScanner: PiUsageScanner
    let expectedIdentityKey: String?
    let allowsKeychainFallback: Bool
    let allowsUnattributedPiUsage: Bool
    /// Higher-priority peer homes are identity-only sources for excluding shared rollouts. They are
    /// resolved at scan time and may belong to disabled cards; their contents are never folded here.
    let peerHomes: @MainActor () -> [URL]
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing

    init(
        provider: Provider = CodexProvider.makeProvider(),
        authStore: CodexAuthStore = CodexAuthStore(),
        usageClient: CodexUsageClient = CodexUsageClient(),
        logUsageScanner: CodexLogUsageScanner = CodexLogUsageScanner(),
        proxyUsageScanner: CodexProxyUsageScanner = CodexProxyUsageScanner(),
        routerUsageScanner: CodexRouterUsageScanner = CodexRouterUsageScanner(),
        piUsageScanner: PiUsageScanner = .shared,
        expectedIdentityKey: String? = nil,
        allowsKeychainFallback: Bool = true,
        allowsUnattributedPiUsage: Bool = true,
        peerHomes: @escaping @MainActor () -> [URL] = { [] },
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = { ModelPricingStore.shared.current() }
    ) {
        self.provider = provider
        let normalizedIdentity = CodexAuthStore.normalizedIdentityKey(expectedIdentityKey)
        self.authStore = authStore.scoped(to: normalizedIdentity)
        self.usageClient = usageClient
        self.logUsageScanner = logUsageScanner
        self.proxyUsageScanner = proxyUsageScanner
        self.routerUsageScanner = routerUsageScanner
        self.piUsageScanner = piUsageScanner
        self.expectedIdentityKey = normalizedIdentity
        self.allowsKeychainFallback = allowsKeychainFallback
        self.allowsUnattributedPiUsage = allowsUnattributedPiUsage
        self.peerHomes = peerHomes
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
                .exportingLimit("rateLimitResets", kind: .balance, unit: "resets", source: .value(kind: .count, label: "available"))
                .hidingWhenEmpty(),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: "From your Codex logs (estimated)"
                )
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        let fileCandidates: [CodexAuthState]
        do {
            fileCandidates = try await loadOffMainActor { [authStore] in
                try authStore.loadAuthCandidates()
            }.filter(isExpectedAccount)
        } catch CodexAuthError.credentialsUnreadable, CodexAuthError.invalidAuthPayload {
            // Keep a card visible when its local credential source exists but cannot currently be
            // inspected. The normal refresh surfaces the actionable file/keychain error.
            return true
        } catch {
            return false
        }
        if fileCandidates.contains(where: \.hasUsableAccessToken) {
            return true
        }
        guard allowsKeychainFallback else { return false }
        // A Keychain refusal means the item is not usable from here, which is the same boolean answer
        // as "no candidate" for this probe; the reason is surfaced separately by `refresh`.
        let keychain: CodexAuthState?
        do {
            keychain = try await loadOffMainActor { [authStore] in
                try authStore.loadKeychainAuth()
            }
        } catch CodexAuthError.credentialPermissionRequired {
            // The Keychain confirmed a credential exists but requires consent. Keep this card enabled
            // so its permission state is visible and the user's manual refresh can request access.
            return true
        } catch CodexAuthError.credentialsUnreadable {
            // An indeterminate Keychain result must not permanently hide a card during one-shot seeding.
            return true
        } catch {
            return false
        }
        return keychain.map { isExpectedAccount($0) && $0.hasUsableAccessToken } == true
    }

    func refresh() async -> ProviderSnapshot {
        guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }
        // Fold-only passes (closed-panel ledger wakes, panel phase 2) fold the router ledger and
        // native sessions without re-reading the live quota APIs — per-turn re-reads are exactly
        // the burn the watcher's closed-panel rate limit exists to prevent, and the panel's
        // phase 1 fetched the meters seconds ago. The data store's merge recovers the quota
        // meters from the prior snapshot and carries their freshness stamp.
        if ProviderRefreshContext.scope.suppressesLiveQuota {
            var lines: [MetricLine] = []
            let modelPricing = await pricing()
            guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }
            let usageHistory = await appendLocalUsage(
                to: &lines,
                now: now(),
                pricing: modelPricing,
                accountIdentityKey: expectedIdentityKey
            )
            guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }
            MetricLine.appendNoDataIfNeeded(&lines)
            return ProviderSnapshot.make(
                provider: provider,
                plan: nil,
                lines: lines,
                refreshedAt: now(),
                usageHistory: usageHistory
            )
        }

        let fileCandidates: [CodexAuthState]
        var localSourceError: Error?
        do {
            fileCandidates = try await loadOffMainActor { [authStore] in
                try authStore.loadAuthCandidates()
            }.filter(isExpectedAccount)
        } catch is CancellationError {
            return cancelledRefreshSnapshot(provider: provider)
        } catch {
            if ProviderCancellation.isCancellation(error) {
                return cancelledRefreshSnapshot(provider: provider)
            }
            fileCandidates = []
            localSourceError = error
        }
        var lastFallbackError: Error?

        for candidate in fileCandidates {
            guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }
            do {
                return try await probe(authState: candidate)
            } catch let error as CodexAuthError where error.allowsAuthFallback {
                guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }
                lastFallbackError = error
                continue
            } catch is CancellationError {
                return cancelledRefreshSnapshot(provider: provider)
            } catch {
                if ProviderCancellation.isCancellation(error) {
                    return cancelledRefreshSnapshot(provider: provider)
                }
                return await localOnlySnapshot(after: error)
            }
        }

        if allowsKeychainFallback {
            guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }
            // Surface a credential-permission failure instead of letting it fall through to
            // `notLoggedIn`, whose remedy (re-authenticate) cannot possibly help.
            let keychainCandidate: CodexAuthState?
            do {
                keychainCandidate = try await loadOffMainActor({ [authStore] in
                    try authStore.loadKeychainAuth()
                })
            } catch is CancellationError {
                return cancelledRefreshSnapshot(provider: provider)
            } catch {
                if Task.isCancelled { return cancelledRefreshSnapshot(provider: provider) }
                return await localOnlySnapshot(after: error)
            }
            guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }
            if let keychainCandidate, isExpectedAccount(keychainCandidate) {
                do {
                    return try await probe(authState: keychainCandidate)
                } catch is CancellationError {
                    return cancelledRefreshSnapshot(provider: provider)
                } catch {
                    if ProviderCancellation.isCancellation(error) {
                        return cancelledRefreshSnapshot(provider: provider)
                    }
                    return await localOnlySnapshot(after: error)
                }
            }
        }

        return await localOnlySnapshot(
            after: lastFallbackError ?? localSourceError ?? CodexAuthError.notLoggedIn
        )
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
        try Task.checkCancellation()
        var authState = initialState
        guard isExpectedAccount(authState) else { throw CodexAuthError.tokenConflict }
        guard var accessToken = authState.auth.tokens?.accessToken, !accessToken.isEmpty else {
            if authState.auth.apiKey?.isEmpty == false {
                throw CodexAuthError.usageAPIKey
            }
            throw CodexAuthError.notLoggedIn
        }

        if authStore.needsRefresh(authState.auth) {
            if let live = try await reloadLiveAuth(source: authState.source),
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

        try Task.checkCancellation()
        guard isExpectedAccount(authState) else { throw CodexAuthError.tokenConflict }
        let response = try await fetchUsageWithRetry(accessToken: accessToken, authState: &authState)
        try Task.checkCancellation()
        let currentToken = authState.auth.tokens?.accessToken ?? accessToken
        let resetCredits = try await fetchResetCreditsBestEffort(
            accessToken: currentToken,
            accountID: authState.auth.tokens?.accountID
        )
        try Task.checkCancellation()
        var mapped = try CodexUsageMapper.mapUsageResponse(response, resetCredits: resetCredits, now: now())

        // Menu-bar and panel-meter passes only need Session/Weekly (and sibling) quota meters from
        // the rate-limit API. Skip the expensive local JSONL / FCC / CodexRouter history scan;
        // the data store merges prior token/history lines onto this snapshot.
        let usageHistory: ProviderUsageHistory?
        if ProviderRefreshContext.scope.skipsLocalAccounting {
            usageHistory = nil
        } else {
            let pricing = await pricing()
            try Task.checkCancellation()
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
        guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }
        var lines: [MetricLine] = []
        let usageHistory: ProviderUsageHistory?
        if ProviderRefreshContext.scope.skipsLocalAccounting {
            // Meters-only pass: do not scrape local history just to paint a warning card; keep
            // prior spend/history via the data-store merge.
            usageHistory = nil
        } else {
            let modelPricing = await pricing()
            guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }
            usageHistory = await appendLocalUsage(
                to: &lines,
                now: now(),
                pricing: modelPricing,
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
        guard !Task.isCancelled else { return nil }
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
            daysBack: UsageHistoryWindow.lifetimeDays(through: now),
            now: now,
            pricing: pricing
        )
        guard !Task.isCancelled else { return nil }
        // Native sessions may contain days that never passed through Codex Router. Their per-file
        // aggregates skip unchanged events, so preserving gap-fill history needs no repeated fold.
        let nativeResult = await logUsageScanner.scanResult(
            daysBack: UsageHistoryWindow.lifetimeDays(through: now),
            now: now,
            pricing: pricing,
            peerHomes: peerHomes()
        )
        guard !Task.isCancelled else { return nil }
        let nativeScan: LogUsageScan?
        switch nativeResult {
        case .complete(let scan):
            nativeScan = scan
        case .incomplete:
            AppLog.warn(
                LogTag.plugin("codex"),
                "Codex session discovery or fold was incomplete; keeping the previous combined usage history"
            )
            return nil
        }
        let proxyScan = await proxyUsageScanner.scan(
            accountIdentityKey: accountIdentityKey,
            daysBack: UsageHistoryWindow.lifetimeDays(through: now),
            now: now,
            pricing: pricing
        )
        guard !Task.isCancelled else { return nil }
        let piResult: PiUsageScanResult = allowsUnattributedPiUsage
            ? await piUsageScanner.scanResult(
                cardID: provider.id,
                daysBack: UsageHistoryWindow.lifetimeDays(through: now),
                now: now,
                pricing: pricing
            )
            : .complete(nil)
        guard !Task.isCancelled else { return nil }
        let piScan: LogUsageScan?
        switch piResult {
        case .complete(let scan):
            piScan = scan
        case .incomplete:
            AppLog.warn(
                LogTag.plugin("codex"),
                "Pi session discovery was incomplete; keeping the previous combined usage history"
            )
            return nil
        }
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
        guard let scan = DailyUsageAccumulator.merged([coreScan, piScan]) else {
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
            unknownModelsByDay: scan.unknownModelsByDay,
            apiEstimateByDay: scan.apiEstimateByDay,
            apiEstimateIncompleteDays: scan.apiEstimateIncompleteDays
        )
        SpendTileMapper.appendTokenUsage(
            scan.series,
            to: &lines,
            now: now,
            unknownModelsByDay: scan.unknownModelsByDay,
            modelUsage: scan.modelUsage,
            modelSourceNote: note,
            apiEstimateByDay: scan.apiEstimateByDay
        )
        SpendTileMapper.appendUsageTrend(scan.series, to: &lines, now: now, note: note)
        return usageHistory
    }

    private func fetchResetCreditsBestEffort(accessToken: String, accountID: String?) async throws -> HTTPResponse? {
        guard !Task.isCancelled else { return nil }
        do {
            return try await usageClient.fetchResetCredits(accessToken: accessToken, accountID: accountID)
        } catch {
            try ProviderCancellation.rethrowIfCancellation(error)
            AppLog.warn(LogTag.plugin("codex"), "reset-credit fetch failed; using usage-body count: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchUsageWithRetry(accessToken: String, authState: inout CodexAuthState) async throws -> HTTPResponse {
        try Task.checkCancellation()
        var working = authState
        defer { authState = working }
        return try await ProviderAuthRetry.fetch(
            token: accessToken,
            attempt: {
                try Task.checkCancellation()
                return try await self.usageClient.fetchUsage(
                    accessToken: $0,
                    accountID: working.auth.tokens?.accountID
                )
            },
            refreshAccessToken: {
                try Task.checkCancellation()
                guard let refreshToken = working.auth.tokens?.refreshToken, !refreshToken.isEmpty else {
                    throw CodexAuthError.tokenExpired
                }
                do {
                    return try await self.refreshAccessToken(authState: &working, refreshToken: refreshToken)
                } catch let error as CodexAuthError {
                    throw error
                } catch {
                    try ProviderCancellation.rethrowIfCancellation(error)
                    throw CodexUsageError.connectionFailed
                }
            },
            connectionFailed: CodexUsageError.connectionFailed,
            authExpired: CodexAuthError.tokenExpired
        )
    }

    private func reloadLiveAuth(source: CodexAuthState.Source) async throws -> CodexAuthState? {
        let candidate: CodexAuthState?
        switch source {
        case .file(let path):
            do {
                candidate = try await loadOffMainActor { [authStore] in
                    try authStore.loadAuth(at: path)
                }
            } catch {
                try ProviderCancellation.rethrowIfCancellation(error)
                candidate = nil
            }
        case .keychain(let account):
            guard allowsKeychainFallback else { return nil }
            do {
                candidate = try await loadOffMainActor { [authStore] in
                    try authStore.loadKeychainAuth(account: account)
                }
            } catch {
                try ProviderCancellation.rethrowIfCancellation(error)
                AppLog.info(LogTag.auth("codex"), "keychain credential unavailable: \(error)")
                return nil
            }
        }
        guard let candidate, isExpectedAccount(candidate) else { return nil }
        return candidate
    }

    private func refreshAccessToken(authState: inout CodexAuthState, refreshToken: String) async throws -> String {
        let originalState = authState
        try Task.checkCancellation()
        let response: CodexRefreshResponse
        do {
            response = try await usageClient.refreshToken(refreshToken)
        } catch {
            try ProviderCancellation.rethrowIfCancellation(error)
            throw error
        }
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
            let persistedState = authState
            let authStore = self.authStore
            let refreshContext = ProviderRefreshContext.detachedValues
            // A successful refresh may rotate the refresh token and invalidate the old one. Persist
            // that rotation even if the provider task was canceled while the HTTP response was in
            // flight; otherwise the next refresh can be permanently stranded on a revoked token.
            try await Task.detached(priority: .utility) {
                try refreshContext.withValue {
                    try authStore.save(persistedState, replacing: originalState)
                }
            }.value
        } catch let error as CodexAuthError {
            switch error {
            case .tokenConflict, .credentialPermissionRequired, .credentialsUnreadable, .invalidAuthPayload:
                // The refreshed token must not be used after logout, an account switch, or an
                // indeterminate live-source check. Only ordinary write failures may use it in-memory.
                throw error
            default:
                AppLog.error(LogTag.auth("codex"), "failed to persist rotated credentials; using the refreshed token for this session only: \(error.localizedDescription)")
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AppLog.error(LogTag.auth("codex"), "failed to persist rotated credentials; using the refreshed token for this session only: \(error.localizedDescription)")
        }
        try Task.checkCancellation()
        return response.accessToken
    }
}
