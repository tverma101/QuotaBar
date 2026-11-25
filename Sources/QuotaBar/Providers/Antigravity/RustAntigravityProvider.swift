import Foundation

/// Production Antigravity runtime. Language-server discovery, Keychain/Cloud Code credentials,
/// quota summary parsing, and the conversation-database accounting fold all run in
/// `Rust/quotabar-engine/src/providers/antigravity`; this type owns only the SwiftUI identity and
/// widget descriptors. `AntigravityProvider` remains the Swift test oracle.
@MainActor
final class RustAntigravityProvider: ProviderRuntime {
    let provider = Provider(
        id: "antigravity",
        displayName: "Antigravity",
        icon: .providerMark("antigravity")
    )

    private static let usageSourceNote = "From your Antigravity conversations"

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: AntigravityMetric.geminiID, provider: provider, title: AntigravityMetric.sessionLabel, sessionStartSignal: .zeroUsage)
                .exportingLimit("geminiSession", unit: "percent"),
            .percent(id: AntigravityMetric.geminiWeeklyID, provider: provider, title: AntigravityMetric.weeklyLabel)
                .exportingLimit("geminiWeekly", unit: "percent"),
            .percent(id: AntigravityMetric.argonWeeklyID, provider: provider, title: AntigravityMetric.argonWeeklyLabel)
                .exportingLimit("argonWeekly", unit: "percent")
                .hidingWhenEmpty(),
            .percent(id: AntigravityMetric.claudeID, provider: provider, title: AntigravityMetric.claudeLabel, sessionStartSignal: .zeroUsage)
                .exportingLimit("nonGeminiSession", unit: "percent")
                .hidingWhenEmpty(),
            .percent(id: AntigravityMetric.claudeWeeklyID, provider: provider, title: AntigravityMetric.claudeWeeklyLabel)
                .exportingLimit("nonGeminiWeekly", unit: "percent")
                .hidingWhenEmpty(),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: Self.usageSourceNote
                )
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        await RustEngine.hasLocalCredentials(providerID: provider.id)
    }

    func refresh() async -> ProviderSnapshot {
        await RustEngine.refresh(provider: provider)
    }

    func unloadLocalAccountingCachesForMemoryPressure() async {
        await RustEngine.unloadCaches(providerID: provider.id)
    }
}
