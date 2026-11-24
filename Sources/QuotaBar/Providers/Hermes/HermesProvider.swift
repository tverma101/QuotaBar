import Foundation

/// Tracks Hermes Agent usage from Hermes' own local session database (`~/.hermes/state.db`, or
/// `$HERMES_HOME/state.db`). All database scanning and metric mapping live in the Rust engine
/// (`Rust/quotabar-engine/src/providers/hermes`).
@MainActor
final class HermesProvider: ProviderRuntime {
    let provider = Provider(
        id: "hermes",
        displayName: "Hermes",
        icon: .providerMark("hermes"),
        links: [
            .init(label: "Dashboard", url: "https://hermes-agent.nousresearch.com/docs")
        ]
    )

    var panelMetersRefreshIncludesHistory: Bool { true }

    var widgetDescriptors: [WidgetDescriptor] {
        // Today / This Week / This Month above the fold — the period token rows are the card's core —
        // with the Usage Trend chart behind the caret.
        [
            .values(id: "hermes.today", provider: provider, title: "Today", isUsagePeriod: true),
            .values(id: "hermes.thisweek", provider: provider, title: "This Week", isUsagePeriod: true),
            .values(id: "hermes.thismonth", provider: provider, title: "This Month", isUsagePeriod: true),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: "From your Hermes state database"
                )
        ]
    }

    func hasLocalCredentials() async -> Bool {
        await RustEngine.hasLocalCredentials(providerID: provider.id)
    }

    func refresh() async -> ProviderSnapshot {
        await RustEngine.refresh(provider: provider)
    }
}
