import Foundation

/// Codex provider runtime. `auth.json`/Keychain credential loading, OAuth refresh, usage requests,
/// reset-credit reads and claims, mapping, native rollout accounting, and pi use live in the Rust
/// engine (`Rust/quotabar-engine/src/providers/codex`). This type owns only the SwiftUI provider
/// identity, widget descriptors, and the engine calls; the former Swift runtime remains as a test
/// oracle.
@MainActor
final class CodexProvider: ProviderRuntime {
    static func makeProvider(id: String = "codex", displayName: String = "Codex") -> Provider {
        Provider(
            id: id,
            displayName: displayName,
            icon: .providerMark("codex"),
            links: [
                .init(label: "Status", url: "https://status.openai.com/"),
                .init(label: "Dashboard", url: "https://chatgpt.com/codex/settings/usage")
            ]
        )
    }

    let provider: Provider
    let engineConfig: EngineProviderConfig?
    let rawConfig: [String: Any]
    let expectedIdentityKey: String?
    let allowsKeychainFallback: Bool
    let logHomes: [String]

    init(
        provider: Provider = CodexProvider.makeProvider(),
        engineConfig: [String: Any] = [:]
    ) {
        self.provider = provider
        self.rawConfig = engineConfig
        self.engineConfig = engineConfig.isEmpty ? nil : EngineProviderConfig(engineConfig)
        self.expectedIdentityKey = (engineConfig["expectedIdentityKey"] as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }
        self.allowsKeychainFallback = engineConfig["allowsKeychainFallback"] as? Bool ?? true
        self.logHomes = engineConfig["logHomes"] as? [String] ?? []
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "\(provider.id).session", provider: provider, title: "Session")
                .exportingLimit("session", unit: "percent"),
            .percent(id: "\(provider.id).weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            .percent(id: "\(provider.id).spark", provider: provider, title: "Spark")
                .exportingLimit("spark", unit: "percent")
                .hidingWhenEmpty(),
            .percent(id: "\(provider.id).sparkWeekly", provider: provider, title: "Spark Weekly")
                .exportingLimit("sparkWeekly", unit: "percent")
                .hidingWhenEmpty(),
            .combined(id: "\(provider.id).credits", provider: provider, title: "Extra Usage", metricLabel: "Credits")
                .exportingLimit("credits", kind: .balance, unit: "credits", source: .value(kind: .count, label: "credits"))
                .exportingLimit("creditValue", kind: .balance, unit: "usd", source: .value(kind: .dollars))
                .hidingWhenEmpty(),
            .values(id: "\(provider.id).rateLimitResets", provider: provider, title: "Rate Limit Resets", metricLabel: "Rate Limit Resets", traySuffix: "resets", showsResetExpiries: true)
                .exportingLimit("rateLimitResets", kind: .balance, unit: "resets", source: .value(kind: .count, label: "available"))
                .hidingWhenEmpty(),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: "From your Codex logs"
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
