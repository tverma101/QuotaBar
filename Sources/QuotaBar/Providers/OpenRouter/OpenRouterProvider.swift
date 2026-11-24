import Foundation

/// OpenRouter credits, balance, and key-limit tiles. All credential loading, API calls, and mapping
/// live in the Rust engine (`Rust/quotabar-engine/src/providers/openrouter`).
@MainActor
final class OpenRouterProvider: ProviderRuntime {
    let provider = Provider(
        id: "openrouter",
        displayName: "OpenRouter",
        icon: .providerMark("openrouter"),
        links: [
            ProviderLink(label: "Activity", url: "https://openrouter.ai/activity"),
            ProviderLink(label: "Credits", url: "https://openrouter.ai/settings/credits")
        ]
    )

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .boundedDollars(id: "openrouter.credits", provider: provider, title: "Credits",
                            metricLabel: "Credits", limit: 100, limitNoun: "purchased")
                .exportingLimit("credits", unit: "usd")
                .hidingWhenEmpty(),
            .dollarBalance(id: "openrouter.balance", provider: provider, title: "Balance",
                           metricLabel: "Balance", valueWord: "left")
                .exportingLimit("balance", kind: .balance, unit: "usd", source: .value(kind: .dollars))
                .hidingWhenEmpty(),
            .values(id: "openrouter.today", provider: provider, title: "Today",
                    metricLabel: "Today", selection: .kind(.dollars), isUsagePeriod: true),
            .values(id: "openrouter.week", provider: provider, title: "This Week",
                    metricLabel: "This Week", selection: .kind(.dollars), isUsagePeriod: true),
            .values(id: "openrouter.month", provider: provider, title: "This Month",
                    metricLabel: "This Month", selection: .kind(.dollars), isUsagePeriod: true),
            .boundedDollars(id: "openrouter.keyLimit", provider: provider, title: "Key Limit",
                            metricLabel: "Key Limit", limit: 100, valueWord: "spent")
                .exportingLimit("keyLimit", unit: "usd")
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

extension OpenRouterProvider: APIKeyManaging {
    var apiKeyStatus: APIKeyStatus { RustEngine.apiKeyStatus(providerID: provider.id) }
    func currentAPIKey() -> String? { RustEngine.currentAPIKey(providerID: provider.id) }
    func saveAPIKey(_ key: String) throws { try RustEngine.saveAPIKey(key, providerID: provider.id) }
    func deleteAPIKey() throws { try RustEngine.deleteAPIKey(providerID: provider.id) }
}
