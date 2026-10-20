import Foundation

@MainActor
final class CursorProvider: ProviderRuntime {
    private func logOptionalWarning(kind: String, label: String, reason: String, message: String) {
        let labelKey = JSONLScanCachePaths.stableFingerprint(label.lowercased())
        DiagnosticGate.logOnce(for: "auth.cursor.\(kind).\(labelKey).\(reason)") {
            AppLog.warn(LogTag.plugin("cursor"), message)
        }
    }

    private func clearOptionalWarnings(kind: String, label: String, reason: String? = nil) {
        let labelKey = JSONLScanCachePaths.stableFingerprint(label.lowercased())
        let prefix = "auth.cursor.\(kind).\(labelKey)."
        if let reason {
            DiagnosticGate.clearFailure(prefix + reason)
        } else {
            DiagnosticGate.clearFailures(prefix: prefix)
        }
    }

    private func clearOptionalResponseFailures(kind: String, label: String) {
        let labelKey = JSONLScanCachePaths.stableFingerprint(label.lowercased())
        let prefix = "auth.cursor.\(kind).\(labelKey)."
        DiagnosticGate.clearFailure(prefix + "transport")
        DiagnosticGate.clearFailure(prefix + "unprepared")
        DiagnosticGate.clearFailures(prefix: prefix + "http.")
    }

    let provider = Provider(
        id: "cursor",
        displayName: "Cursor",
        icon: .providerMark("cursor"),
        links: [
            .init(label: "Status", url: "https://status.cursor.com/"),
            .init(label: "Dashboard", url: "https://www.cursor.com/dashboard")
        ]
    )

    let authStore: CursorAuthStore
    let usageClient: CursorUsageClient
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing
    private let unresolvedCacheIdentityKey = "cursor-unresolved-\(UUID().uuidString)"

    init(
        authStore: CursorAuthStore = CursorAuthStore(),
        usageClient: CursorUsageClient = CursorUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = { ModelPricingStore.shared.current() }
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
        self.pricing = pricing
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "cursor.usage", provider: provider, title: "Total Usage", metricLabel: "Total usage")
                .exportingLimit("totalUsage", unit: "percent")
                .hidingWhenEmpty(),
            .percent(id: "cursor.auto", provider: provider, title: "Cursor Models")
                .exportingLimit("autoUsage", unit: "percent")
                .hidingWhenEmpty(),
            .percent(id: "cursor.api", provider: provider, title: "Other Models")
                .exportingLimit("apiUsage", unit: "percent")
                .hidingWhenEmpty(),
            .percent(id: "cursor.grokBot", provider: provider, title: "Grok Bot", metricLabel: "Grok Bot usage").hidingWhenEmpty()
                .exportingLimit("grokBot", unit: "percent"),
            .boundedDollars(id: "cursor.onDemand", provider: provider, title: "Extra Usage", metricLabel: "On-demand", limit: 100, valueWord: "spent").hidingWhenEmpty()
                .exportingLimit("onDemand", unit: "usd", source: .progressOrValue(kind: .dollars)),
            .boundedCount(id: "cursor.requests", provider: provider, title: "Requests", limit: 500,
                          suffix: "requests", periodDurationMs: CursorUsageMapper.billingPeriodMs)
                .exportingLimit("requests", unit: "requests")
                .hidingWhenEmpty(),
            .dollarBalance(id: "cursor.credits", provider: provider, title: "Credits", valueWord: "left")
                .exportingLimit("credits", kind: .balance, unit: "usd", source: .value(kind: .dollars))
                .hidingWhenEmpty(),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .accountWide,
                    estimatedCost: true,
                    sourceNote: "From your Cursor usage export"
                )
        ] + WidgetDescriptor.spendTiles(
            provider: provider,
            valueTooltipNote: WidgetData.cursorUsageHistoryNote
        )
    }

    func hasLocalCredentials() async -> Bool {
        // Same source as `refresh()`: any auth state (state DB or keychain) counts.
        do {
            return try await loadOffMainActor { [authStore] in try authStore.loadAuthState() } != nil
        } catch CursorAuthError.credentialPermissionRequired {
            // Preserve an inaccessible but present Keychain login so the card exposes its repair path.
            return true
        } catch CursorAuthError.credentialsUnreadable {
            // An indeterminate Keychain read must not make one-shot seeding hide the provider.
            return true
        } catch {
            return false
        }
    }

    func refresh() async -> ProviderSnapshot {
        // Distinguish "no credential" from "macOS won't release the credential": the second needs one
        // Refresh and an "Always Allow", not a re-login.
        let state: CursorAuthState?
        do {
            state = try await loadOffMainActor({ [authStore] in try authStore.loadAuthState() })
        } catch {
            if ProviderCancellation.isCancellation(error) {
                return cancelledRefreshSnapshot(provider: provider)
            }
            return ProviderSnapshot.error(provider: provider, error: error)
        }
        guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }
        guard let state else {
            // A successful probe that finds no credential is an explicit identity change. Read failures
            // leave the per-request sink empty so a transient Keychain/SQLite problem keeps last-good data.
            ProviderRefreshContext.cacheIdentityResult?.set(unresolvedCacheIdentityKey)
            return ProviderSnapshot.error(provider: provider, error: CursorAuthError.notLoggedIn)
        }
        ProviderRefreshContext.cacheIdentityResult?.set(
            CursorAuthStore.cacheIdentityKey(for: state) ?? unresolvedCacheIdentityKey
        )

        do {
            return try await probe(authState: state)
        } catch {
            if ProviderCancellation.isCancellation(error) {
                return cancelledRefreshSnapshot(provider: provider)
            }
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    private func probe(authState initialState: CursorAuthState) async throws -> ProviderSnapshot {
        var authState = initialState
        var accessToken = authState.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        if authStore.needsRefresh(accessToken) {
            do {
                if let refreshed = try await refreshAccessToken(authState: authState) {
                    authState.accessToken = refreshed
                    accessToken = refreshed
                } else if accessToken == nil {
                    throw CursorAuthError.notLoggedIn
                } else if authStore.isExpired(accessToken) {
                    throw CursorAuthError.tokenExpired
                }
            } catch let error as CursorAuthError where error == .sessionExpired
                || error == .credentialPermissionRequired || error == .credentialsUnreadable {
                // A live-source mismatch or failed source recheck is not a transient OAuth outage:
                // never continue requests with the pre-switch account's token.
                throw error
            } catch {
                try ProviderCancellation.rethrowIfCancellation(error)
                if accessToken == nil || authStore.isExpired(accessToken) {
                    throw error
                }
            }
        }
        try Task.checkCancellation()

        guard let accessToken else {
            throw CursorAuthError.notLoggedIn
        }

        // Fold-only pass (panel phase 2): the meters-only phase just ran this account's API chain;
        // re-running it per fold would double every panel-open request burst. Only the token needs
        // acquiring (the CSV download authenticates with it) — skip the meter chain, fold the CSV,
        // and let the store's merge recover the meters onto the fresh history.
        if ProviderRefreshContext.scope.suppressesLiveQuota {
            var working = CursorMappedUsage(plan: nil, lines: [])
            let history = try await appendSpendLines(to: &working.lines, accessToken: accessToken)
            return snapshot(working, usageHistory: history)
        }

        let usageResponse = try await fetchUsageWithRetry(accessToken: accessToken, authState: &authState)
        try ProviderAuthRetry.requireSuccess(
            usageResponse,
            authExpired: CursorAuthError.tokenExpired,
            requestFailed: { CursorUsageError.requestFailed($0) }
        )
        guard let usage = ProviderParse.jsonObject(usageResponse.body) else {
            throw CursorUsageError.invalidResponse
        }
        // The access token may have rotated during the usage fetch's refresh-and-retry; read the live one.
        let currentToken = authState.accessToken ?? accessToken

        let (planName, planInfoUnavailable) = try await fetchPlanName(accessToken: currentToken)
        let fallback = CursorUsageMapper.shouldUseRequestBasedFallback(
            usage: usage,
            planName: planName,
            planInfoUnavailable: planInfoUnavailable
        )
        if fallback.shouldFallback {
            var mapped = try await usageSummaryAndRequestResult(
                accessToken: currentToken,
                planName: planName,
                unavailableMessage: fallback.message
            )
            try await appendGrokBotUsage(to: &mapped.lines, accessToken: currentToken)
            return try await snapshotWithOptionalSpend(mapped, accessToken: currentToken)
        }

        if shouldTryGenericRequestFallback(usage: usage) {
            do {
                var mapped = try await requestBasedResult(
                    accessToken: currentToken,
                    planName: planName,
                    unavailableMessage: "Cursor request-based usage data unavailable. Try again later."
                )
                clearOptionalWarnings(kind: "optional", label: "request-based usage")
                try await appendGrokBotUsage(to: &mapped.lines, accessToken: currentToken)
                // Same spend/history attachment as the other two success paths: this fallback serves
                // accounts without the dashboard usage payload, and skipping the CSV froze their
                // spend tiles at the last snapshot another path happened to produce.
                return try await snapshotWithOptionalSpend(mapped, accessToken: currentToken)
            } catch {
                try ProviderCancellation.rethrowIfCancellation(error)
                logOptionalWarning(
                    kind: "optional",
                    label: "request-based usage",
                    reason: "fallback",
                    message: "optional request-based usage fallback failed"
                )
            }
        }

        let creditGrants = try await fetchCreditGrants(accessToken: currentToken)
        let stripeBalanceCents = try await fetchStripeBalanceCents(accessToken: currentToken)
        var mapped = try CursorUsageMapper.mapUsage(
            usage: usage,
            planName: planName,
            creditGrants: creditGrants,
            stripeBalanceCents: stripeBalanceCents
        )
        try await appendGrokBotUsage(to: &mapped.lines, accessToken: currentToken)
        return try await snapshotWithOptionalSpend(mapped, accessToken: currentToken)
    }

    /// Meters-only passes (menu-bar ticks, panel phase 1) keep Auto/API (and sibling) quota meters;
    /// skip the usage CSV download that only feeds spend tiles / history. The data store merges
    /// prior spend onto this snapshot until a fold pass runs.
    private func snapshotWithOptionalSpend(
        _ mapped: CursorMappedUsage,
        accessToken: String
    ) async throws -> ProviderSnapshot {
        if ProviderRefreshContext.scope.skipsLocalAccounting {
            return snapshot(mapped)
        }
        var working = mapped
        let history = try await appendSpendLines(to: &working.lines, accessToken: accessToken)
        return snapshot(working, usageHistory: history)
    }

    /// Grok Bot uses the same Cursor account but keeps a separate weekly allowance. Missing access is
    /// normal for ineligible accounts; malformed data and request failures remain visible in diagnostics.
    private func appendGrokBotUsage(to lines: inout [MetricLine], accessToken: String) async throws {
        guard let usage = try await fetchOptionalJSONObject(label: "Grok Bot usage", request: {
            try await self.usageClient.fetchGrokBotUsage(accessToken: accessToken)
        }) else {
            return
        }
        guard usage["usesPooledEnterpriseAllowance"] as? Bool != true,
              usage["hasNonZeroIncludedLimit"] as? Bool != false,
              usage["includedLimitZero"] as? Bool != true
        else {
            clearOptionalWarnings(kind: "schema", label: "Grok Bot usage")
            return
        }
        guard let line = CursorUsageMapper.mapGrokBotUsage(usage) else {
            if usage["usagePercent"] != nil || usage["hasNonZeroIncludedLimit"] as? Bool == true ||
                usage["hasAvailableUsage"] as? Bool == true {
                logOptionalWarning(
                    kind: "schema",
                    label: "Grok Bot usage",
                    reason: "invalid",
                    message: "optional Grok Bot usage response contained invalid usage metadata"
                )
            }
            return
        }
        clearOptionalWarnings(kind: "schema", label: "Grok Bot usage")
        lines.append(line)
    }

    /// Strictly additive: fetch the usage CSV and append the three per-day spend tiles. Any failure
    /// (no session, non-2xx, or undecodable body) appends nothing, so the live Cursor mapping is never
    /// affected and the spend tiles fall back to "No data".
    private func appendSpendLines(to lines: inout [MetricLine], accessToken: String) async throws -> ProviderUsageHistory? {
        try Task.checkCancellation()
        let calendar = Calendar.current
        let end = now()
        let startOfToday = calendar.startOfDay(for: end)
        // Same shared window as every other provider's "Last 30 Days" tile, so the cross-provider
        // Total Spend ring sums like-for-like periods. This was the one provider already using -29
        // (a correct 30 days) while the rest used a 31-day window, so the two were not comparable.
        let start = calendar.date(
            byAdding: .day,
            value: -UsageHistoryWindow.previousDays,
            to: startOfToday
        ) ?? startOfToday

        let response: HTTPResponse?
        do {
            try Task.checkCancellation()
            response = try await usageClient.fetchUsageCSV(accessToken: accessToken, start: start, end: end)
        } catch {
            try ProviderCancellation.rethrowIfCancellation(error)
            logOptionalWarning(kind: "csv", label: "usage CSV", reason: "transport", message: "usage CSV request failed")
            return nil
        }
        try Task.checkCancellation()
        guard let response else {
            logOptionalWarning(kind: "csv", label: "usage CSV", reason: "unprepared", message: "usage CSV request could not be prepared from the current session")
            return nil
        }
        clearOptionalResponseFailures(kind: "csv", label: "usage CSV")
        guard (200..<300).contains(response.statusCode) else {
            logOptionalWarning(kind: "csv", label: "usage CSV", reason: "http.\(response.statusCode)", message: "usage CSV request returned HTTP \(response.statusCode)")
            return nil
        }
        guard let csv = String(data: response.body, encoding: .utf8) else {
            logOptionalWarning(kind: "csv", label: "usage CSV", reason: "utf8", message: "usage CSV response was not valid UTF-8")
            return nil
        }
        let pricing = await pricing()
        try Task.checkCancellation()
        let paceAccountingWork = ProviderRefreshContext.accountingCPUThrottleEnabled
        do {
            // CSV parsing and the shared model fold can be sizeable on a long export. Keep both off
            // MainActor and pass the refresh budget explicitly because Task.detached drops TaskLocal.
            let computationTask = Task.detached(priority: .utility) {
                try JSONLAccountingWorkPacer.shared.perform(enabled: paceAccountingWork) {
                    let parsed = try CursorUsageCSV.parse(
                        csv: csv,
                        pricing: pricing,
                        maximumTimestamp: JSONLScanning.maximumTimestamp(now: end)
                    )
                    var spendLines: [MetricLine] = []
                    let history = try CursorUsageMapper.appendSpendLines(
                        rows: parsed.rows,
                        now: end,
                        pricing: pricing,
                        to: &spendLines
                    )
                    return (parsed, history, spendLines)
                }
            }
            let computation = try await withTaskCancellationHandler {
                try await computationTask.value
            } onCancel: {
                computationTask.cancel()
            }

            try Task.checkCancellation()
            let (parsed, history, spendLines) = computation
            if parsed.rejectedRowCount > 0 {
                logOptionalWarning(
                    kind: "csv",
                    label: "usage CSV",
                    reason: "rows",
                    message: "usage CSV rejected \(parsed.rejectedRowCount) malformed row\(parsed.rejectedRowCount == 1 ? "" : "s"); withholding partial spend history"
                )
                // The parser keeps valid rows for diagnostics and boundary tests, but the provider
                // must not publish their subtotal as if the full export had been accounted for.
                return nil
            }
            if parsed.unpricedGrokBotRowCount > 0 {
                DiagnosticGate.logOnce(for: "auth.cursor.csv.unpriced-grok-bot") {
                    AppLog.info(
                        LogTag.plugin("cursor"),
                        "usage CSV kept \(parsed.unpricedGrokBotRowCount) Grok Bot row\(parsed.unpricedGrokBotRowCount == 1 ? "" : "s") with measured tokens but no serving-model price"
                    )
                }
            } else {
                DiagnosticGate.clearFailure("auth.cursor.csv.unpriced-grok-bot")
            }
            clearOptionalWarnings(kind: "csv", label: "usage CSV")
            lines.append(contentsOf: spendLines)
            return history
        } catch let error as CursorUsageCSVError {
            switch error {
            case .missingColumns(let columns):
                logOptionalWarning(kind: "csv", label: "usage CSV", reason: "columns", message: "usage CSV missing required columns: \(columns.joined(separator: ", "))")
            case .malformedCSV:
                logOptionalWarning(kind: "csv", label: "usage CSV", reason: "malformed", message: "usage CSV is structurally malformed")
            case .futureTimestamp:
                logOptionalWarning(kind: "csv", label: "usage CSV", reason: "future-timestamp", message: "usage CSV contains a timestamp more than five minutes ahead; preserving last-good history")
            }
        } catch {
            try ProviderCancellation.rethrowIfCancellation(error)
            logOptionalWarning(kind: "csv", label: "usage CSV", reason: "parse", message: "usage CSV could not be parsed")
        }
        return nil
    }

    private func fetchUsageWithRetry(accessToken: String, authState: inout CursorAuthState) async throws -> HTTPResponse {
        var working = authState
        defer { authState = working }
        return try await ProviderAuthRetry.fetch(
            providerID: provider.id,
            diagnosticSourceID: Self.authRetrySourceID(for: working),
            token: accessToken,
            attempt: { try await self.usageClient.fetchUsage(accessToken: $0) },
            refreshAccessToken: {
                guard let refreshed = try await self.refreshAccessToken(
                    authState: working,
                    forceKeychainReload: true
                ) else {
                    throw CursorAuthError.tokenExpired
                }
                working.accessToken = refreshed
                return refreshed
            },
            connectionFailed: CursorUsageError.connectionFailed,
            retriedConnectionFailed: CursorUsageError.usageAfterRefreshFailed,
            authExpired: CursorAuthError.tokenExpired
        )
    }

    private static func authRetrySourceID(for state: CursorAuthState) -> String {
        let source = state.source == .sqlite ? "sqlite" : "keychain"
        return source + "\n" + (CursorAuthStore.tokenSubject(state.accessToken) ?? "")
    }

    private func refreshAccessToken(
        authState: CursorAuthState,
        forceKeychainReload: Bool = false
    ) async throws -> String? {
        let refreshState = try await loadOffMainActor { [authStore] in
            try authStore.authStateForRefresh(authState, forceKeychainReload: forceKeychainReload)
        }
        guard let refreshState,
              let refreshToken = refreshState.refreshToken?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        else {
            return nil
        }
        let persistenceDiagnosticKey = Self.tokenPersistenceFailureKey(for: refreshState.source)

        let response = try await usageClient.refreshToken(refreshToken)
        if response.statusCode == 400 || response.statusCode == 401 {
            let body = ProviderParse.jsonObject(response.body)
            if body?["shouldLogout"] as? Bool == true {
                throw CursorAuthError.sessionExpired
            }
            throw CursorAuthError.tokenExpired
        }
        guard (200..<300).contains(response.statusCode),
              let body = ProviderParse.jsonObject(response.body)
        else {
            // A 5xx (or any unexpected status) from the OAuth endpoint is a transient service
            // failure, not an expired token. Returning nil here read as "refresh returned nothing"
            // and callers raised tokenExpired, sending the user to re-login during an outage;
            // surface a retryable request failure instead.
            throw CursorUsageError.requestFailed(response.statusCode)
        }
        if body["shouldLogout"] as? Bool == true {
            throw CursorAuthError.sessionExpired
        }
        guard let accessToken = (body["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return nil
        }
        // Keychain and SQLite persistence are synchronous; keep their process waits off MainActor.
        // Keep the error log generic because SQLite stderr can echo sensitive write/error-path details.
        // The refreshed token still works for this session if persistence fails.
        do {
            let authStore = self.authStore
            let refreshContext = ProviderRefreshContext.detachedValues
            // A successful OAuth response must save even if this provider task is canceled while the
            // response is returning. The store revalidates the live source immediately before writing.
            try await Task.detached(priority: .utility) {
                try refreshContext.withValue {
                    try authStore.saveAccessToken(accessToken, replacing: refreshState)
                }
                DiagnosticGate.clearFailure(persistenceDiagnosticKey)
            }.value
        } catch let error as CursorAuthError where error == .sessionExpired
            || error == .credentialPermissionRequired || error == .credentialsUnreadable {
            throw error
        } catch let error as CancellationError {
            throw error
        } catch {
            try ProviderCancellation.rethrowIfCancellation(error)
            DiagnosticGate.logOnce(for: persistenceDiagnosticKey) {
                AppLog.error(LogTag.auth("cursor"), "failed to persist rotated access token; using it for this session only")
            }
        }
        return accessToken
    }

    private static func tokenPersistenceFailureKey(for source: CursorAuthState.Source) -> String {
        let sourceName: String
        switch source {
        case .sqlite: sourceName = "sqlite"
        case .keychain: sourceName = "keychain"
        }
        return "auth.cursor.token-persist.\(sourceName)"
    }

    private func fetchPlanName(accessToken: String) async throws -> (String?, Bool) {
        guard let body = try await fetchOptionalJSONObject(label: "plan", request: {
            try await self.usageClient.fetchPlan(accessToken: accessToken)
        }) else {
            return (nil, true)
        }
        guard let planInfo = body["planInfo"] as? [String: Any],
              let planName = (planInfo["planName"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        else {
            logOptionalWarning(kind: "schema", label: "plan", reason: "invalid", message: "optional plan response contained invalid plan metadata")
            return (nil, true)
        }
        clearOptionalWarnings(kind: "schema", label: "plan")
        return (planName, false)
    }

    private func fetchCreditGrants(accessToken: String) async throws -> [String: Any]? {
        guard let body = try await fetchOptionalJSONObject(label: "credit-grants", request: {
            try await self.usageClient.fetchCredits(accessToken: accessToken)
        }) else {
            return nil
        }
        // Absent `hasCreditGrants` is the common "no grants" shape from Cursor — treat as none without
        // spamming WARN every refresh. Only warn when the field is present but unreadable, or when
        // grants are claimed without usable totals.
        guard body["hasCreditGrants"] != nil else {
            clearOptionalWarnings(kind: "schema", label: "credit-grants")
            return nil
        }
        guard let hasCreditGrants = ProviderParse.bool(body["hasCreditGrants"]) else {
            logOptionalWarning(kind: "schema", label: "credit-grants", reason: "invalid", message: "optional credit-grants response contained invalid grant metadata")
            return nil
        }
        if hasCreditGrants {
            guard let totalCents = ProviderParse.number(body["totalCents"]), totalCents > 0,
                  let usedCents = ProviderParse.number(body["usedCents"]), usedCents >= 0 else {
                logOptionalWarning(kind: "schema", label: "credit-grants", reason: "invalid", message: "optional credit-grants response contained invalid grant metadata")
                return nil
            }
        }
        clearOptionalWarnings(kind: "schema", label: "credit-grants")
        return body
    }

    private func fetchStripeBalanceCents(accessToken: String) async throws -> Double {
        guard let body = try await fetchOptionalJSONObject(label: "prepaid-balance", request: {
            try await self.usageClient.fetchStripeBalance(accessToken: accessToken)
        }) else {
            return 0
        }
        guard ProviderParse.number(body["customerBalance"]) != nil else {
            logOptionalWarning(kind: "schema", label: "prepaid-balance", reason: "invalid", message: "optional prepaid-balance response contained invalid balance metadata")
            return 0
        }
        clearOptionalWarnings(kind: "schema", label: "prepaid-balance")
        return CursorUsageMapper.stripeBalanceCents(from: body)
    }

    /// Optional endpoints enrich a usable primary snapshot; they never fail the whole provider. Keep
    /// their boundary handling in one place so transport, preparation, status, and schema failures are
    /// all visible with fixed, credential-free diagnostics.
    private func fetchOptionalJSONObject(
        label: String,
        request: () async throws -> HTTPResponse?
    ) async throws -> [String: Any]? {
        try Task.checkCancellation()
        let response: HTTPResponse?
        do {
            response = try await request()
        } catch {
            try ProviderCancellation.rethrowIfCancellation(error)
            logOptionalWarning(kind: "optional", label: label, reason: "transport", message: "optional \(label) request failed")
            return nil
        }
        try Task.checkCancellation()
        guard let response else {
            logOptionalWarning(kind: "optional", label: label, reason: "unprepared", message: "optional \(label) request could not be prepared from the current session")
            return nil
        }
        clearOptionalResponseFailures(kind: "optional", label: label)
        guard (200..<300).contains(response.statusCode) else {
            logOptionalWarning(kind: "optional", label: label, reason: "http.\(response.statusCode)", message: "optional \(label) request returned HTTP \(response.statusCode)")
            return nil
        }
        guard let body = ProviderParse.jsonObject(response.body) else {
            logOptionalWarning(kind: "optional", label: label, reason: "json", message: "optional \(label) response was invalid")
            return nil
        }
        clearOptionalWarnings(kind: "optional", label: label)
        return body
    }

    private func requestBasedResult(accessToken: String, planName: String?, unavailableMessage: String) async throws -> CursorMappedUsage {
        do {
            guard let response = try await usageClient.fetchRequestBasedUsage(accessToken: accessToken),
                  (200..<300).contains(response.statusCode),
                  let body = ProviderParse.jsonObject(response.body)
            else {
                throw CursorUsageError.requestBasedUnavailable(unavailableMessage)
            }
            return try CursorUsageMapper.mapRequestBasedUsage(body, planName: planName, unavailableMessage: unavailableMessage)
        } catch let error as CursorUsageError {
            throw error
        } catch {
            try ProviderCancellation.rethrowIfCancellation(error)
            throw CursorUsageError.requestBasedUnavailable(unavailableMessage)
        }
    }

    private func usageSummaryAndRequestResult(
        accessToken: String,
        planName: String?,
        unavailableMessage: String
    ) async throws -> CursorMappedUsage {
        let summary = try await fetchOptionalJSONObject(label: "usage-summary", request: {
            try await self.usageClient.fetchUsageSummary(accessToken: accessToken)
        })
        if let summary, !CursorUsageSummaryMapper.hasUsableSummaryPayload(summary) {
            logOptionalWarning(
                kind: "schema",
                label: "usage-summary",
                reason: "no-usable-fields",
                message: "optional usage-summary response contained no usable usage fields"
            )
        } else if summary != nil {
            clearOptionalWarnings(kind: "schema", label: "usage-summary")
        }
        let requestUsage = try await fetchOptionalJSONObject(label: "request-based usage", request: {
            try await self.usageClient.fetchRequestBasedUsage(accessToken: accessToken)
        })
        if let requestUsage, !CursorUsageSummaryMapper.hasUsableRequestPayload(requestUsage) {
            logOptionalWarning(
                kind: "schema",
                label: "request-based usage",
                reason: "no-usable-fields",
                message: "optional request-based usage response contained no usable usage fields"
            )
        } else if requestUsage != nil {
            clearOptionalWarnings(kind: "schema", label: "request-based usage")
        }
        return try CursorUsageSummaryMapper.map(
            summary: summary,
            requestUsage: requestUsage,
            planName: planName,
            unavailableMessage: unavailableMessage
        )
    }

    private func shouldTryGenericRequestFallback(usage: [String: Any]) -> Bool {
        CursorPlanUsageFacts(usage: usage).shouldTryGenericRequestFallback
    }

    private func snapshot(_ mapped: CursorMappedUsage, usageHistory: ProviderUsageHistory? = nil) -> ProviderSnapshot {
        ProviderSnapshot.make(
            provider: provider,
            plan: mapped.plan,
            lines: mapped.lines,
            refreshedAt: now(),
            usageHistory: usageHistory
        )
    }
}
