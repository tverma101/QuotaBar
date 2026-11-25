import Foundation

/// Production Freebuff runtime. Credential discovery, the hosted session API, hosted receipts,
/// and the Desktop token history all run in `Rust/quotabar-engine/src/providers/freebuff`; this
/// type owns only the SwiftUI identity and widget descriptors. `FreebuffProvider` remains the
/// Swift test oracle.
@MainActor
final class RustFreebuffProvider: ProviderRuntime {
    let provider = Provider(
        id: "freebuff",
        displayName: "Freebuff",
        icon: .providerMark("freebuff"),
        links: [
            ProviderLink(label: "Dashboard", url: "https://codebuff.com/account")
        ]
    )

    private static let historySourceNote =
        "Measured Freebuff hosted runs and legacy Desktop tokens on this Mac."

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
                .hidingWhenEmpty(),
            .usageTrend(provider: provider)
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    /// The network boundary is a compile-time host decision, not a user preference. Public
    /// artifacts are offline (saved measurements only). The owner's local build may read the
    /// session meter, but hosted history and the model catalogue remain disabled.
    var engineConfig: EngineProviderConfig? {
        #if QUOTABAR_LOCAL_FREEBUFF
        EngineProviderConfig(["liveSessionEnabled": true, "hostedDetailEnabled": false])
        #else
        EngineProviderConfig(["liveSessionEnabled": false, "hostedDetailEnabled": false])
        #endif
    }

    func hasLocalCredentials() async -> Bool {
        await RustEngine.hasLocalCredentials(providerID: provider.id, config: engineConfig)
    }

    func refresh() async -> ProviderSnapshot {
        await RustEngine.refresh(provider: provider, config: engineConfig)
    }

    func unloadLocalAccountingCachesForMemoryPressure() async {
        await RustEngine.unloadCaches(providerID: provider.id)
    }
}
