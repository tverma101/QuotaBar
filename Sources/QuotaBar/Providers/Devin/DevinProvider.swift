import Foundation

/// Devin quota tiles and local CLI session/transcript spend. All credential loading, API calls,
/// SQLite/transcript scans, and metric mapping live in the Rust engine (`Rust/quotabar-engine/src/providers/devin`).
@MainActor
final class DevinProvider: ProviderRuntime {
    let provider = Provider(
        id: "devin",
        displayName: "Devin",
        icon: .providerMark("devin"),
        links: [
            .init(label: "Dashboard", url: "https://app.devin.ai/settings/plans")
        ]
    )

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "devin.daily", provider: provider, title: "Daily", metricLabel: "Daily quota")
                .exportingLimit("daily", unit: "percent")
                .hidingWhenEmpty(),
            .percent(id: "devin.weekly", provider: provider, title: "Weekly", metricLabel: "Weekly quota")
                .exportingLimit("weekly", unit: "percent"),
            .dollarBalance(id: "devin.extra", provider: provider, title: "Extra Balance", metricLabel: "Extra usage balance", valueWord: "left").hidingWhenEmpty()
                .exportingLimit("extraUsageBalance", kind: .balance, unit: "usd", source: .value(kind: .dollars)),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: "From local Devin sessions; dollar amounts are estimates"
                )
            // Local spend tiles from the CLI's local session usage.
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        await RustEngine.hasLocalCredentials(providerID: provider.id)
    }

    func refresh() async -> ProviderSnapshot {
        await RustEngine.refresh(provider: provider)
    }
}
