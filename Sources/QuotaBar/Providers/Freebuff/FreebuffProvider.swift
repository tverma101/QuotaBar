import Foundation

@MainActor
final class FreebuffProvider: ProviderRuntime {
    private static let usageFailureDiagnosticPrefix = "auth.freebuff.usage.failure."

    let provider = Provider(
        id: "freebuff",
        displayName: "Freebuff",
        icon: .providerMark("freebuff"),
        links: [
            ProviderLink(label: "Dashboard", url: "https://codebuff.com/account")
        ]
    )

    let authStore: FreebuffAuthStore
    let usageClient: FreebuffUsageClient
    let historyScanner: FreebuffDesktopUsageScanner
    let hostedScanner: FreebuffHostedUsageScanner
    let modelCatalog: FreebuffModelCatalog
    let pricing: @Sendable () async -> ModelPricing
    let now: @Sendable () -> Date

    func unloadLocalAccountingCachesForMemoryPressure() async {
        await historyScanner.unloadCachesForMemoryPressure()
        await hostedScanner.unloadCachesForMemoryPressure()
    }

    init(
        historyScanner: FreebuffDesktopUsageScanner = FreebuffDesktopUsageScanner(),
        hostedScanner: FreebuffHostedUsageScanner = FreebuffHostedUsageScanner(),
        authStore: FreebuffAuthStore = FreebuffAuthStore(),
        usageClient: FreebuffUsageClient = FreebuffUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init,
        modelCatalog: FreebuffModelCatalog = FreebuffModelCatalog(),
        pricing: @escaping @Sendable () async -> ModelPricing = { ModelPricingStore.shared.current() }
    ) {
        self.authStore = authStore
        self.historyScanner = historyScanner
        self.hostedScanner = hostedScanner
        self.usageClient = usageClient
        self.now = now
        self.modelCatalog = modelCatalog
        self.pricing = pricing
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .boundedCount(id: "freebuff.session", provider: provider, title: "Session Pool",
                          metricLabel: "Session Pool", limit: 1, suffix: "sessions")
                .hidingWhenEmpty(),
            .boundedCount(id: "freebuff.daily", provider: provider, title: "Daily",
                          metricLabel: "Daily", limit: 1, suffix: "sessions",
                          periodDurationMs: MetricPeriod.dayMs)
                .hidingWhenEmpty(),
            .boundedCount(id: "freebuff.weekly", provider: provider, title: "Weekly",
                          metricLabel: "Weekly", limit: 1, suffix: "sessions",
                          periodDurationMs: MetricPeriod.weekMs)
                .hidingWhenEmpty(),
            .boundedCount(id: "freebuff.fiveDay", provider: provider, title: "5-Day",
                          metricLabel: "5-Day", limit: 1, suffix: "sessions",
                          periodDurationMs: FreebuffUsageMapper.fiveDayPeriodMs)
                .hidingWhenEmpty(),
            .boundedCount(id: "freebuff.monthly", provider: provider, title: "Monthly",
                          metricLabel: "Monthly", limit: 1, suffix: "sessions")
                .hidingWhenEmpty(),
            .boundedCount(id: "freebuff.premiumSessions", provider: provider, title: "Premium Sessions",
                          metricLabel: "Premium Sessions", limit: 1, suffix: "sessions",
                          periodDurationMs: MetricPeriod.dayMs)
                .hidingWhenEmpty(),
            .boundedCount(id: "freebuff.freePremiumSessions", provider: provider, title: "Free Premium Sessions",
                          metricLabel: "Free Premium Sessions", limit: 1, suffix: "sessions",
                          periodDurationMs: MetricPeriod.dayMs)
                .hidingWhenEmpty(),
            .boundedCount(id: "freebuff.freebucksDaily", provider: provider, title: "Daily Hours",
                          metricLabel: "Daily Hours", limit: 1, suffix: "hours",
                          periodDurationMs: MetricPeriod.dayMs)
                .hidingWhenEmpty()
                .showingSessionTimersInMenuBar(metricLabel: "Active Sessions"),
            .values(id: "freebuff.freebucksBalance", provider: provider, title: "Hours Balance",
                    metricLabel: "Hours Balance", selection: .kind(.count))
                .hidingWhenEmpty()
                .exportingHistory(scope: .accountWide, estimatedCost: true,
                                  sourceNote: Self.historySourceNote),
            .values(id: "freebuff.monthlySpend", provider: provider, title: "Monthly Spend",
                    metricLabel: "Monthly Spend", selection: .kind(.dollars), valueWord: "spent")
                .hidingWhenEmpty()
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [authStore] in authStore.hasLocalCredentials() }
    }

    func refresh() async -> ProviderSnapshot {
        guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }
        let scope = ProviderRefreshContext.scope
        var auth: FreebuffAuth?
        var authError: (any Error)?
        do {
            auth = try await loadOffMainActor { [authStore] in try authStore.loadAuth() }
            if auth == nil { authError = FreebuffAuthError.notLoggedIn }
        } catch {
            if ProviderCancellation.isCancellation(error) { return cancelledRefreshSnapshot(provider: provider) }
            authError = error
        }
        let snapshot: ProviderSnapshot
        if scope.suppressesLiveQuota {
            snapshot = .make(provider: provider, plan: nil, lines: [], refreshedAt: now())
        } else if let auth {
            snapshot = await refreshQuota(auth: auth)
        } else {
            snapshot = .error(provider: provider, error: authError ?? FreebuffAuthError.notLoggedIn)
        }
        guard !scope.skipsLocalAccounting, !Task.isCancelled else { return snapshot }
        var result = snapshot
        do {
            let scanNow = now()
            var hostedReceipts: [FreebuffUsageReceipt] = []
            var incompleteHistory = auth == nil
            if auth == nil { result.historyWarning = authError?.localizedDescription }
            if let auth {
                if scope == .localAccounting {
                    hostedReceipts = await hostedScanner.cachedReceipts(auth: auth)
                } else {
                    do {
                        hostedReceipts = try await hostedScanner.scan(auth: auth, client: usageClient, now: scanNow)
                        DiagnosticGate.clearFailure("auth.freebuff.hosted-history.failure")
                    } catch {
                        try ProviderCancellation.rethrowIfCancellation(error)
                        DiagnosticGate.logOnce(for: "auth.freebuff.hosted-history.failure") {
                            AppLog.warn(LogTag.auth("freebuff"), "hosted token history read failed: \(error.localizedDescription)")
                        }
                        hostedReceipts = await hostedScanner.cachedReceipts(auth: auth)
                        incompleteHistory = true
                        result.historyWarning = "Freebuff's hosted token history couldn't be refreshed. Totals may be incomplete."
                    }
                }
                var hasHistory = !hostedReceipts.isEmpty
                if scope != .localAccounting, !hasHistory {
                    hasHistory = try await historyScanner.hasHistory(now: scanNow)
                }
                if scope != .localAccounting, hasHistory {
                    do {
                        try await modelCatalog.refresh(auth: auth, client: usageClient, now: scanNow)
                        DiagnosticGate.clearFailure("auth.freebuff.catalog.failure")
                    } catch {
                        try ProviderCancellation.rethrowIfCancellation(error)
                        DiagnosticGate.logOnce(for: "auth.freebuff.catalog.failure") {
                            AppLog.warn(LogTag.auth("freebuff"), "model catalogue refresh failed: \(error.localizedDescription)")
                        }
                        if result.historyWarning == nil {
                            result.historyWarning = "Freebuff model names couldn't be refreshed. Saved model data is still available."
                        }
                    }
                }
            }
            let catalog = await modelCatalog.current()
            if var scan = try await historyScanner.scan(now: scanNow, pricing: pricing(), modelCatalog: catalog,
                                                       hostedReceipts: hostedReceipts) {
                DiagnosticGate.clearFailure("auth.freebuff.history.failure")
                let usage = scan.usage
                if incompleteHistory { scan.partialDays.formUnion(usage.series.daily.map(\.date)) }
                result.usageHistory = ProviderUsageHistory(
                    series: usage.series, modelUsage: usage.modelUsage,
                    unknownModelsByDay: usage.unknownModelsByDay, apiEstimateByDay: usage.apiEstimateByDay,
                    partialDays: scan.partialDays, estimatedCostDays: usage.estimatedCostDays
                )
                SpendTileMapper.appendTokenUsage(
                    usage.series, to: &result.lines, now: scanNow, estimated: true,
                    unknownModelsByDay: usage.unknownModelsByDay,
                    modelUsage: usage.modelUsage,
                    modelSourceNote: Self.historySourceNote,
                    partialDays: scan.partialDays,
                    apiEstimateByDay: usage.apiEstimateByDay, estimatedCostDays: usage.estimatedCostDays
                )
            }
        } catch is CancellationError {
            return cancelledRefreshSnapshot(provider: provider)
        } catch {
            DiagnosticGate.logOnce(for: "auth.freebuff.history.failure") {
                AppLog.warn(LogTag.auth("freebuff"), "token history read failed: \(error.localizedDescription)")
            }
            result.historyWarning = FreebuffUsageError.localHistoryUnreadable.localizedDescription
        }
        return result
    }

    private func refreshQuota(auth: FreebuffAuth) async -> ProviderSnapshot {
        guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }
        do {
            let response = try await usageClient.fetchSession(auth: auth)
            if Task.isCancelled { return cancelledRefreshSnapshot(provider: provider) }
            DiagnosticGate.clearFailure(Self.usageFailureDiagnosticKey(FreebuffUsageError.connectionFailed))
            if response.statusCode == 401 {
                return ProviderSnapshot.error(provider: provider, error: FreebuffAuthError.tokenInvalid)
            }
            guard (200..<300).contains(response.statusCode) || response.statusCode == 404 else {
                return ProviderSnapshot.error(provider: provider, error: FreebuffUsageError.requestFailed(response.statusCode))
            }
            let mapped = try FreebuffUsageMapper.map(response: response)
            DiagnosticGate.clearFailures(prefix: Self.usageFailureDiagnosticPrefix)
            return ProviderSnapshot.make(provider: provider, plan: mapped.plan, lines: mapped.lines,
                                         refreshedAt: now(), clearsPriorMenuBarQuotaState: true)
        } catch is CancellationError {
            return cancelledRefreshSnapshot(provider: provider)
        } catch {
            DiagnosticGate.logOnce(
                for: Self.usageFailureDiagnosticKey(error)
            ) {
                AppLog.warn(LogTag.auth("freebuff"), "usage refresh failed: \(error.localizedDescription)")
            }
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    private static let historySourceNote = "Measured Freebuff hosted runs and legacy Desktop tokens on this Mac; dollars estimated at public API rates, not Freebuff charges."

    private static func usageFailureDiagnosticKey(_ error: Error) -> String {
        usageFailureDiagnosticPrefix + String(reflecting: type(of: error))
    }
}
