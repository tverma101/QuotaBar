import Foundation

/// Grok quota, OAuth rotation, and CLI session-log spend tiles. All credential loading, API calls,
/// log scanning, and mapping live in the Rust engine (`Rust/quotabar-engine/src/providers/grok`).
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
                    sourceNote: "From your Grok logs"
                )
            // Local spend tiles from completed turns in the Grok CLI's session transcripts.
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        await RustEngine.hasLocalCredentials(providerID: provider.id)
    }

    func refresh() async -> ProviderSnapshot {
        await RustEngine.refresh(provider: provider)
    }
}
