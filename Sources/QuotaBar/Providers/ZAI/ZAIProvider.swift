import Foundation

/// Z.ai GLM Coding Plan quota and ZCode's local token history. Credential loading, the quota and
/// subscription APIs, the ZCode SQLite/leveldb scans, and mapping all live in the Rust engine
/// (`Rust/quotabar-engine/src/providers/zai`).
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

    /// ZCode's local database, also read by the Generation Speed dashboard.
    nonisolated static let zcodeSqlitePath = "~/.zcode/cli/db/db.sqlite"

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
                          periodDurationMs: MetricPeriod.monthMs)
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
}

extension ZAIProvider: APIKeyManaging {
    var apiKeyStatus: APIKeyStatus { RustEngine.apiKeyStatus(providerID: provider.id) }
    func currentAPIKey() -> String? { RustEngine.currentAPIKey(providerID: provider.id) }
    func saveAPIKey(_ key: String) throws { try RustEngine.saveAPIKey(key, providerID: provider.id) }
    func deleteAPIKey() throws { try RustEngine.deleteAPIKey(providerID: provider.id) }
}
