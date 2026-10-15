import Foundation

@MainActor
final class GrokProvider: ProviderRuntime {
    let provider = Provider(
        id: "grok",
        displayName: "Grok",
        icon: .providerMark("grok"),
        links: [
            .init(label: "Usage", url: "https://grok.com/?_s=usage")
        ]
    )

    let authStore: GrokAuthStore
    let usageClient: GrokUsageClient
    let logUsageScanner: GrokLogUsageScanner
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing

    init(
        authStore: GrokAuthStore = GrokAuthStore(),
        usageClient: GrokUsageClient = GrokUsageClient(),
        logUsageScanner: GrokLogUsageScanner = GrokLogUsageScanner(),
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = { ModelPricingStore.shared.current() }
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.logUsageScanner = logUsageScanner
        self.now = now
        self.pricing = pricing
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "grok.weekly", provider: provider, title: "Weekly", metricLabel: "Weekly limit")
                .exportingLimit("weekly", unit: "percent"),
            .badge(id: "grok.payAsYouGo", provider: provider, title: "Extra Usage", metricLabel: "Pay as you go")
                .hidingWhenEmpty(),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: "From your Grok logs (estimated)"
                )
            // Local spend tiles from completed turns in the Grok CLI's session transcripts.
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        // Same source as `refresh()`: ~/.grok/auth.json with at least one keyed entry.
        await loadOffMainActor { [authStore] in
            do {
                let candidates = try authStore.loadAuthCandidates()
                return !candidates.isEmpty
            } catch is GrokCredentialsUnreadableError {
                // Keep an unreadable configured auth file visible so refresh can explain how to repair it.
                return true
            } catch GrokAuthError.invalidAuth {
                // A present but malformed or unusable auth file is a configured source, not a logout.
                return true
            } catch {
                return false
            }
        }
    }

    func refresh() async -> ProviderSnapshot {
        do {
            return try await loadAndProbe()
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    private func loadAndProbe() async throws -> ProviderSnapshot {
        let candidates = try await loadOffMainActor { [authStore] in
            try authStore.loadAuthCandidates()
        }
        try Task.checkCancellation()
        var sawExpiredCandidate = false
        var refreshFailure: GrokUsageError?

        for var state in candidates {
            if authStore.needsRefresh(entry: state.entry, token: state.token) {
                do {
                    if let refreshed = try await refreshAccessToken(state: &state) {
                        try Task.checkCancellation()
                        return try await probe(state: &state, accessToken: refreshed)
                    }
                } catch let error as GrokUsageError {
                    if authStore.isExpired(entry: state.entry, token: state.token) {
                        // Try other configured accounts before returning a transient refresh error.
                        refreshFailure = error
                        continue
                    }
                    // A still-valid access token can continue to serve this refresh if the proactive
                    // token rotation hit a transient network or server error.
                }
                if authStore.isExpired(entry: state.entry, token: state.token) {
                    sawExpiredCandidate = true
                    continue
                }
            }
            return try await probe(state: &state, accessToken: state.token)
        }

        if let refreshFailure {
            throw refreshFailure
        }
        if sawExpiredCandidate {
            throw GrokAuthError.expired
        }
        throw GrokAuthError.invalidAuth
    }

    private func probe(state: inout GrokAuthState, accessToken: String) async throws -> ProviderSnapshot {
        try Task.checkCancellation()
        // The weekly shared-pool meter and pay-as-you-go badge come from the billing endpoint with
        // `?format=credits` — the call the Grok CLI itself makes. This is the provider's primary
        // remote fetch; a failure here fails the provider like any other usage call. Fold-only
        // passes (panel phase 2) skip it: the meters-only phase just answered this endpoint, and
        // the store's merge recovers the meters onto the fresh local scan.
        var mapped = GrokMappedUsage(lines: [])
        if !ProviderRefreshContext.scope.suppressesLiveQuota {
            let creditsResponse = try await fetchCreditsConfigWithRetry(accessToken: accessToken, state: &state)
            mapped = try GrokUsageMapper.mapCreditsConfig(creditsResponse)
        }
        // Fold-only passes recover the plan label from the prior snapshot via the merge too.
        let plan: String?
        if ProviderRefreshContext.scope.suppressesLiveQuota {
            plan = nil
        } else {
            plan = try await fetchPlanName(accessToken: state.token)
        }

        // Menu-bar and panel-meter passes only need the weekly / Extra Usage meters from the
        // credits API. Skip the local JSONL history scan; the data store merges prior spend onto
        // this snapshot.
        if ProviderRefreshContext.scope.skipsLocalAccounting {
            return ProviderSnapshot.make(
                provider: provider,
                plan: plan,
                lines: mapped.lines,
                refreshedAt: now(),
                usageHistory: nil
            )
        }

        // Local spend tiles from completed session turns. Recorded Grok costs win when available;
        // older turns without a carried cost use the shared pricing store.
        var usageHistory: ProviderUsageHistory?
        let scanNow = now()
        if let scan = await logUsageScanner.scan(
            daysBack: UsageHistoryWindow.lifetimeDays(through: scanNow),
            now: scanNow,
            pricing: await pricing()
        ) {
            usageHistory = ProviderUsageHistory(
                series: scan.series,
                modelUsage: scan.modelUsage,
                unknownModelsByDay: scan.unknownModelsByDay,
                apiEstimateByDay: scan.apiEstimateByDay,
                apiEstimateIncompleteDays: scan.apiEstimateIncompleteDays
            )
            SpendTileMapper.appendTokenUsage(
                scan.series,
                to: &mapped.lines,
                now: now(),
                unknownModelsByDay: scan.unknownModelsByDay,
                modelUsage: scan.modelUsage,
                modelSourceNote: "From your Grok logs (estimated)",
                apiEstimateByDay: scan.apiEstimateByDay
            )
            SpendTileMapper.appendUsageTrend(scan.series, to: &mapped.lines, now: now(),
                                             note: "From your Grok logs (estimated)")
        }

        return ProviderSnapshot.make(
            provider: provider,
            plan: plan,
            lines: mapped.lines,
            refreshedAt: now(),
            usageHistory: usageHistory
        )
    }

    private func fetchCreditsConfigWithRetry(accessToken: String, state: inout GrokAuthState) async throws -> HTTPResponse {
        var working = state
        defer { state = working }
        return try await ProviderAuthRetry.fetch(
            token: accessToken,
            attempt: { try await self.usageClient.fetchCreditsConfig(accessToken: $0) },
            refreshAccessToken: {
                guard let refreshed = try await self.refreshAccessToken(state: &working) else {
                    throw GrokAuthError.expired
                }
                return refreshed
            },
            connectionFailed: GrokUsageError.connectionFailed,
            authExpired: GrokAuthError.expired
        )
    }

    private func refreshAccessToken(state: inout GrokAuthState) async throws -> String? {
        let originalState = state
        guard let refreshToken = authStore.refreshToken(for: state.entry) else {
            return nil
        }

        let response: HTTPResponse
        do {
            response = try await usageClient.refreshToken(
                refreshToken,
                clientID: authStore.clientID(entryKey: state.entryKey, entry: state.entry)
            )
        } catch {
            try ProviderCancellation.rethrowIfCancellation(error)
            AppLog.warn(LogTag.auth("grok"), "token refresh request failed (transport)")
            throw GrokUsageError.connectionFailed
        }
        guard (200..<300).contains(response.statusCode) else {
            AppLog.warn(LogTag.auth("grok"), "token refresh failed (HTTP \(response.statusCode))")
            // OAuth's 400/401 rejection means the refresh grant is no longer usable. Other statuses
            // (notably 429 and 5xx) are retryable service/HTTP failures, not evidence that the user
            // needs to sign in again.
            if response.statusCode == 400 || response.statusCode == 401 { return nil }
            throw GrokUsageError.requestFailed(response.statusCode)
        }
        guard let decoded = usageClient.decodeRefreshResponse(response),
              !decoded.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            AppLog.warn(LogTag.auth("grok"), "token refresh returned an undecodable or empty access token")
            return nil
        }

        let accessToken = decoded.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        state.token = accessToken
        state.entry.key = accessToken
        if let refreshToken = decoded.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines), !refreshToken.isEmpty {
            state.entry.refreshToken = refreshToken
        }
        if let idToken = decoded.idToken?.trimmingCharacters(in: .whitespacesAndNewlines), !idToken.isEmpty {
            state.entry.idToken = idToken
        }

        let expiresAt = refreshExpiryDate(response: decoded, accessToken: accessToken)
        state.entry.expiresAt = OpenUsageISO8601.string(from: expiresAt)
        // Fail loudly: a swallowed save strands the rotated token on disk (next launch re-refreshes /
        // can surface a false "auth expired"). The refreshed token works for this session, so log and
        // continue rather than fail the live fetch.
        do {
            let persistedState = state
            let authStore = self.authStore
            let refreshContext = ProviderRefreshContext.detachedValues
            // A successful OAuth response may rotate and revoke its refresh token. Persist it even
            // when the provider task is canceled before usage requests resume.
            try await Task.detached(priority: .utility) {
                try refreshContext.withValue {
                    try authStore.save(persistedState, replacing: originalState)
                }
            }.value
        } catch is GrokAuthConflictError {
            // The login was removed/replaced while OAuth was in flight. Do not use the old
            // account's late response for this refresh either.
            throw GrokAuthConflictError()
        } catch let error as GrokCredentialsUnreadableError {
            throw error
        } catch let error as GrokAuthError where error == .invalidAuth {
            throw error
        } catch {
            try ProviderCancellation.rethrowIfCancellation(error)
            AppLog.error(LogTag.auth("grok"), "failed to persist rotated credentials; using the refreshed token for this session only: \(error.localizedDescription)")
        }
        try Task.checkCancellation()
        return accessToken
    }

    private func refreshExpiryDate(response: GrokRefreshResponse, accessToken: String) -> Date {
        if let expiresIn = response.expiresIn, expiresIn.isFinite, expiresIn > 0 {
            return now().addingTimeInterval(expiresIn)
        }
        if let tokenExpiry = authStore.tokenExpiresAt(accessToken) {
            return tokenExpiry
        }
        return now().addingTimeInterval(60 * 60)
    }

    private func fetchPlanName(accessToken: String) async throws -> String? {
        try Task.checkCancellation()
        do {
            let response = try await usageClient.fetchSettings(accessToken: accessToken)
            try Task.checkCancellation()
            return GrokUsageMapper.planName(from: response)
        } catch {
            try ProviderCancellation.rethrowIfCancellation(error)
            return nil
        }
    }
}
