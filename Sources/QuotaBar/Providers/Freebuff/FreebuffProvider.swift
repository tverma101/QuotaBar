import Foundation

@MainActor
final class FreebuffProvider: ProviderRuntime {
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
    let now: @Sendable () -> Date

    init(
        authStore: FreebuffAuthStore = FreebuffAuthStore(),
        usageClient: FreebuffUsageClient = FreebuffUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .boundedCount(id: "freebuff.session", provider: provider, title: "Session Pool",
                          metricLabel: "Session Pool", limit: 1, suffix: "sessions")
                .hidingWhenEmpty(),
            .boundedCount(id: "freebuff.daily", provider: provider, title: "Daily",
                          metricLabel: "Daily", limit: 1, suffix: "sessions",
                          periodDurationMs: MetricPeriod.dayMs),
            .boundedCount(id: "freebuff.weekly", provider: provider, title: "Weekly",
                          metricLabel: "Weekly", limit: 1, suffix: "sessions",
                          periodDurationMs: MetricPeriod.weekMs)
                .hidingWhenEmpty(),
            .boundedCount(id: "freebuff.fiveDay", provider: provider, title: "5-Day",
                          metricLabel: "5-Day", limit: 1, suffix: "sessions",
                          periodDurationMs: FreebuffUsageMapper.fiveDayPeriodMs)
                .hidingWhenEmpty(),
            .boundedCount(id: "freebuff.monthly", provider: provider, title: "Monthly",
                          metricLabel: "Monthly", limit: 1, suffix: "sessions"),
            .boundedCount(id: "freebuff.premiumSessions", provider: provider, title: "Premium Sessions",
                          metricLabel: "Premium Sessions", limit: 1, suffix: "sessions",
                          periodDurationMs: MetricPeriod.dayMs)
                .hidingWhenEmpty(),
            .boundedCount(id: "freebuff.freePremiumSessions", provider: provider, title: "Free Premium Sessions",
                          metricLabel: "Free Premium Sessions", limit: 1, suffix: "sessions",
                          periodDurationMs: MetricPeriod.dayMs)
                .hidingWhenEmpty(),
            .boundedCount(id: "freebuff.freebucksDaily", provider: provider, title: "Freebucks Daily",
                          metricLabel: "Freebucks Daily", limit: 1, suffix: "Freebucks",
                          periodDurationMs: MetricPeriod.dayMs)
                .hidingWhenEmpty(),
            .values(id: "freebuff.freebucksBalance", provider: provider, title: "Freebucks Balance",
                    metricLabel: "Freebucks Balance", selection: .kind(.count))
                .hidingWhenEmpty(),
            .values(id: "freebuff.monthlySpend", provider: provider, title: "Monthly Spend",
                    metricLabel: "Monthly Spend", selection: .kind(.dollars), valueWord: "spent")
                .hidingWhenEmpty()
        ]
    }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [authStore] in authStore.hasLocalCredentials() }
    }

    func refresh() async -> ProviderSnapshot {
        guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }
        let auth: FreebuffAuth
        do {
            guard let loaded = try await loadOffMainActor({ [authStore] in try authStore.loadAuth() }) else {
                return ProviderSnapshot.error(provider: provider, error: FreebuffAuthError.notLoggedIn)
            }
            auth = loaded
        } catch is CancellationError {
            return cancelledRefreshSnapshot(provider: provider)
        } catch {
            if ProviderCancellation.isCancellation(error) {
                return cancelledRefreshSnapshot(provider: provider)
            }
            return ProviderSnapshot.error(provider: provider, error: error)
        }
        guard !Task.isCancelled else { return cancelledRefreshSnapshot(provider: provider) }

        do {
            let response = try await usageClient.fetchSession(auth: auth)
            if Task.isCancelled { return cancelledRefreshSnapshot(provider: provider) }
            if response.statusCode == 401 {
                return ProviderSnapshot.error(provider: provider, error: FreebuffAuthError.tokenInvalid)
            }
            guard (200..<300).contains(response.statusCode) || response.statusCode == 404 else {
                return ProviderSnapshot.error(provider: provider, error: FreebuffUsageError.requestFailed(response.statusCode))
            }
            let mapped = try FreebuffUsageMapper.map(response: response)
            return ProviderSnapshot.make(provider: provider, plan: mapped.plan, lines: mapped.lines, refreshedAt: now())
        } catch is CancellationError {
            return cancelledRefreshSnapshot(provider: provider)
        } catch {
            AppLog.warn(LogTag.auth("freebuff"), "usage refresh failed: \(error.localizedDescription)")
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }
}
