import Foundation

/// Cursor plan usage, on-demand spend, credits, and the usage-export history. Credential loading
/// (Cursor's state database and Keychain item through the host), the Connect-RPC/dashboard APIs, the
/// CSV export, and mapping all live in the Rust engine (`Rust/quotabar-engine/src/providers/cursor`).
@MainActor
final class CursorProvider: ProviderRuntime {
    let provider = Provider(
        id: "cursor",
        displayName: "Cursor",
        icon: .providerMark("cursor"),
        links: [
            .init(label: "Status", url: "https://status.cursor.com/"),
            .init(label: "Dashboard", url: "https://www.cursor.com/dashboard")
        ]
    )

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
                          suffix: "requests", periodDurationMs: MetricPeriod.monthMs)
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
        await RustEngine.hasLocalCredentials(providerID: provider.id)
    }

    func refresh() async -> ProviderSnapshot {
        await RustEngine.refresh(provider: provider)
    }

    /// The history-cache identity for launch, read from Cursor's state database only (never the
    /// Keychain), so starting the app never prompts.
    nonisolated static func cacheIdentityKeyForLaunch() -> String {
        RustEngine.cacheIdentityKey(providerID: "cursor") ?? "cursor-unresolved-\(UUID().uuidString)"
    }
}
