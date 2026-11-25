import Foundation

/// Claude provider runtime. Credential loading, Claude Desktop Safe Storage decryption, OAuth
/// refresh, usage/profile requests, mapping, and local Claude Code + pi accounting all live in the
/// Rust engine (`Rust/quotabar-engine/src/providers/claude`). This type owns only the SwiftUI
/// provider identity, widget descriptors, and the engine call.
@MainActor
final class ClaudeProvider: ProviderRuntime {
    static func makeProvider(id: String = "claude", displayName: String = "Claude") -> Provider {
        Provider(
            id: id,
            displayName: displayName,
            icon: .providerMark("claude"),
            links: [
                .init(label: "Status", url: "https://status.anthropic.com/"),
                .init(label: "Dashboard", url: "https://claude.ai/settings/usage")
            ]
        )
    }

    let provider: Provider
    /// Per-card engine configuration (account identity, Desktop organization, unattributed-session policy).
    let engineConfig: EngineProviderConfig?

    init(
        provider: Provider = ClaudeProvider.makeProvider(),
        engineConfig: [String: Any] = [:]
    ) {
        self.provider = provider
        self.engineConfig = engineConfig.isEmpty ? nil : EngineProviderConfig(engineConfig)
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "\(provider.id).session", provider: provider, title: "Session", sessionStartSignal: .missingResetDate)
                .exportingLimit("session", unit: "percent"),
            .percent(id: "\(provider.id).weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            .percent(id: "\(provider.id).fable", provider: provider, title: "Fable")
                .exportingLimit("fable", unit: "percent")
                .hidingWhenEmpty(),
            .percent(id: "\(provider.id).sonnet", provider: provider, title: "Sonnet")
                .exportingLimit("sonnet", unit: "percent")
                .hidingWhenEmpty(),
            .boundedDollars(id: "\(provider.id).extra", provider: provider, title: "Extra Usage", metricLabel: "Extra usage spent", limit: 100, valueWord: "spent")
                .exportingLimit("extraUsage", unit: "usd", source: .progressOrValue(kind: .dollars))
                .hidingWhenEmpty(),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: "From your Claude usage history"
                )
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        await RustEngine.hasLocalCredentials(providerID: provider.id, config: engineConfig)
    }

    func refresh() async -> ProviderSnapshot {
        await RustEngine.refresh(provider: provider, config: engineConfig)
    }
}
