import Foundation

/// GitHub Copilot quota and org billing tiles. All credential loading, API calls, and mapping live
/// in the Rust engine (`Rust/quotabar-engine/src/providers/copilot`).
@MainActor
final class CopilotProvider: ProviderRuntime {
    let provider = Provider(
        id: "copilot",
        displayName: "Copilot",
        icon: .providerMark("copilot"),
        links: [
            .init(label: "Status", url: "https://www.githubstatus.com/"),
            .init(label: "Dashboard", url: "https://github.com/settings/billing")
        ]
    )

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "copilot.premium", provider: provider, title: "Credits")
                .exportingLimit("premiumCredits", unit: "credits", source: .progressOrValue(kind: .count))
                .hidingWhenEmpty(),
            .values(id: "copilot.extra", provider: provider, title: "Extra Usage", selection: .kind(.count)).hidingWhenEmpty()
                .exportingLimit("extraUsage", unit: "count", source: .value(kind: .count)),
            .values(id: "copilot.orgCredits", provider: provider, title: "Org Credits", selection: .kind(.count))
                .exportingLimit("orgCredits", unit: "credits", source: .value(kind: .count, label: "credits"))
                .hidingWhenEmpty(),
            .values(id: "copilot.orgSpend", provider: provider, title: "Org Spend", selection: .kind(.dollars), valueWord: "spent")
                .exportingLimit("orgSpend", unit: "usd", source: .value(kind: .dollars))
                .hidingWhenEmpty(),
            .percent(id: "copilot.chat", provider: provider, title: "Chat")
                .exportingLimit("chat", unit: "percent")
                .hidingWhenEmpty(),
            .percent(id: "copilot.completions", provider: provider, title: "Completions")
                .exportingLimit("completions", unit: "percent")
                .hidingWhenEmpty()
        ]
    }

    func hasLocalCredentials() async -> Bool {
        await RustEngine.hasLocalCredentials(providerID: provider.id)
    }

    func refresh() async -> ProviderSnapshot {
        await RustEngine.refresh(provider: provider)
    }
}
