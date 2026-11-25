import Foundation

/// Z.ai Coding Plan quota and local ZCode usage. All credential loading, API calls, SQLite/LevelDB
/// scans, pricing, and mapping live in the Rust engine
/// (`Rust/quotabar-engine/src/providers/zai`). The former Swift implementation remains in the tree as
/// `ZAISwiftReferenceProvider`, the oracle its Swift unit tests drive.
@MainActor
final class ZAIProvider: ProviderRuntime {
    let provider = Provider(
        id: "zai",
        displayName: "Z.ai",
        icon: .providerMark("zai"),
        links: [
            ProviderLink(label: "Dashboard", url: "https://z.ai/manage-apikey/coding-plan/personal/my-plan"),
            ProviderLink(label: "API Keys", url: "https://z.ai/manage-apikey/apikey-list")
        ]
    )

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "zai.session", provider: provider, title: "Session",
                     metricLabel: "Session")
                .exportingLimit("session", unit: "percent"),
            .percent(id: "zai.weekly", provider: provider, title: "Weekly",
                     metricLabel: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            .boundedCount(id: "zai.weekendBuild", provider: provider, title: "Weekend Build",
                          metricLabel: "Weekend Build", limit: 500_000_000, suffix: "tokens")
                .hidingWhenEmpty(),
            .boundedCount(id: "zai.webSearches", provider: provider, title: "Web Searches",
                          metricLabel: "Web Searches", limit: 1000, suffix: "searches",
                          periodDurationMs: ZAIUsageMapper.monthlyPeriodMs)
                .exportingLimit("webSearches", unit: "searches")
                .hidingWhenEmpty()
        ] + WidgetDescriptor.spendTiles(provider: provider).map { descriptor in
            // Declare the local history resource on an existing tile so the Usage History screen
            // counts ZCode's recorded days — no new metric, just the stats wiring.
            descriptor.id == "zai.last30"
                ? descriptor.exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: "From your ZCode usage history"
                )
                : descriptor
        }
    }

    func hasLocalCredentials() async -> Bool {
        await RustEngine.hasLocalCredentials(providerID: provider.id)
    }

    func refresh() async -> ProviderSnapshot {
        await RustEngine.refresh(provider: provider)
    }

    /// Release the engine's in-memory ZCode scan/catalog caches under memory pressure.
    func unloadLocalAccountingCachesForMemoryPressure() async {
        await RustEngine.unloadCaches(providerID: provider.id)
    }
}

extension ZAIProvider: APIKeyManaging {
    var apiKeyStatus: APIKeyStatus { RustEngine.apiKeyStatus(providerID: provider.id) }
    func currentAPIKey() -> String? { RustEngine.currentAPIKey(providerID: provider.id) }
    func saveAPIKey(_ key: String) throws { try RustEngine.saveAPIKey(key, providerID: provider.id) }
    func deleteAPIKey() throws { try RustEngine.deleteAPIKey(providerID: provider.id) }
}
