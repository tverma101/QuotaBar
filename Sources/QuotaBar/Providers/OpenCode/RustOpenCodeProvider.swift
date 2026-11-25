import Foundation

/// Production OpenCode runtime. Credential discovery, the Go account API, OpenCode's SQLite
/// history, the local Go windows, and the Claude/Codex/Hermes/Muse gateway folds all run in
/// `Rust/quotabar-engine/src/providers/opencode`; this type owns only the SwiftUI identity,
/// widget descriptors, and the engine call.
///
/// `OpenCodeProvider` remains the test-only Swift oracle.
@MainActor
final class RustOpenCodeProvider: ProviderRuntime {
    let provider = Provider(
        id: "opencode",
        displayName: "OpenCode",
        icon: .providerMark("opencode"),
        links: [
            .init(label: "Dashboard", url: "https://opencode.ai/auth")
        ]
    )

    private let authStore: OpenCodeAuthStore
    private let goKeyStore: OpenCodeGoKeyStore
    private let activeKeyID: @Sendable () -> String?
    private let makeConfig: @MainActor () -> [String: Any]
    private let preloadedAccountIdentities: [OpenCodeGoAccountIdentity]?
    private let accountInventoryDiscoveryDeferred: Bool
    private let onGoKeysChanged: @MainActor () -> Void
    private let keyManager: OpenCodeProvider

    private static let sourceNote = "From your OpenCode logs"

    init(
        authStore: OpenCodeAuthStore = OpenCodeAuthStore(),
        goKeyStore: OpenCodeGoKeyStore = OpenCodeGoKeyStore(),
        activeKeyID: @escaping @Sendable () -> String? = {
            OpenCodeGoKeyStore.activeSelection()
        },
        makeConfig: @escaping @MainActor () -> [String: Any] = { [:] },
        onGoKeysChanged: @escaping @MainActor () -> Void = {},
        preloadedAccountIdentities: [OpenCodeGoAccountIdentity]? = nil,
        preloadedAccountInventory: OpenCodeGoAccountInventory? = nil,
        accountInventoryDiscoveryDeferred: Bool = false
    ) {
        self.authStore = authStore
        self.goKeyStore = goKeyStore
        self.activeKeyID = activeKeyID
        self.makeConfig = makeConfig
        self.preloadedAccountIdentities = preloadedAccountInventory?.identities
            ?? preloadedAccountIdentities
        self.accountInventoryDiscoveryDeferred = accountInventoryDiscoveryDeferred
        self.onGoKeysChanged = onGoKeysChanged
        // Reuses the Swift credential and key-management helpers for the Settings surface only.
        // Refresh never calls this instance.
        self.keyManager = OpenCodeProvider(
            authStore: authStore,
            goKeyStore: goKeyStore,
            onGoKeysChanged: onGoKeysChanged,
            preloadedAccountIdentities: preloadedAccountInventory?.identities
                ?? preloadedAccountIdentities,
            preloadedAccountInventory: preloadedAccountInventory,
            accountInventoryDiscoveryDeferred: accountInventoryDiscoveryDeferred,
            activeKeyID: activeKeyID
        )
    }

    var widgetDescriptors: [WidgetDescriptor] {
        let baseMeters: [WidgetDescriptor] = [
            .percent(id: "opencode.session", provider: provider, title: "Session", sessionStartSignal: .zeroUsage)
                .exportingLimit("session", unit: "percent", estimated: true)
                .hidingWhenEmpty(),
            .percent(id: "opencode.weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent", estimated: true)
                .hidingWhenEmpty(),
            .percent(id: "opencode.monthly", provider: provider, title: "Monthly")
                .exportingLimit("monthly", unit: "percent", estimated: true)
                .hidingWhenEmpty(),
        ]
        let accountIdentities = preloadedAccountIdentities
            ?? (accountInventoryDiscoveryDeferred ? [] : configuredAccountIdentities())
        return baseMeters + accountIdentities.flatMap { account in
            Self.accountMeterDescriptors(for: account, provider: provider)
        } + [
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: false,
                    sourceNote: Self.sourceNote
                )
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    var engineConfig: EngineProviderConfig? { currentEngineConfig() }

    func hasLocalCredentials() async -> Bool {
        await RustEngine.hasLocalCredentials(providerID: provider.id, config: currentEngineConfig())
    }

    func refresh() async -> ProviderSnapshot {
        await RustEngine.refresh(provider: provider, config: currentEngineConfig())
    }

    private func currentEngineConfig() -> EngineProviderConfig {
        var values = makeConfig()
        values["activeKeyID"] = activeKeyID() ?? ""
        return EngineProviderConfig(values)
    }

    private func configuredAccountIdentities() -> [OpenCodeGoAccountIdentity] {
        var apiKeys: [(name: String, key: String, id: String, source: OpenCodeGoKeySource)] = []
        if let fileKeys = try? authStore.apiKeys() {
            apiKeys += fileKeys.map { (name: $0.name, key: $0.key, id: $0.name, source: .authFile) }
        }
        if let storedKeys = try? goKeyStore.loadKeys() {
            apiKeys += storedKeys.map {
                (name: $0.label, key: $0.key, id: $0.id.uuidString, source: .appSaved)
            }
        }
        let identities = OpenCodeProvider.distinctAccountIdentities(apiKeys: apiKeys)
        return identities.count > 1 ? identities : []
    }

    private static func accountMeterDescriptors(
        for account: OpenCodeGoAccountIdentity,
        provider: Provider
    ) -> [WidgetDescriptor] {
        let suffix = "account.\(account.descriptorKey)"
        let sessionLabel = "Session (\(account.displayName))"
        let weeklyLabel = "Weekly (\(account.displayName))"
        let monthlyLabel = "Monthly (\(account.displayName))"
        return [
            .percent(
                id: "opencode.session.\(suffix)", provider: provider, title: sessionLabel,
                metricLabel: sessionLabel, sessionStartSignal: .zeroUsage
            )
            .exportingLimit("session.\(account.descriptorKey)", unit: "percent", estimated: true)
            .hidingWhenEmpty(),
            .percent(
                id: "opencode.weekly.\(suffix)", provider: provider, title: weeklyLabel,
                metricLabel: weeklyLabel
            )
            .exportingLimit("weekly.\(account.descriptorKey)", unit: "percent", estimated: true)
            .hidingWhenEmpty(),
            .percent(
                id: "opencode.monthly.\(suffix)", provider: provider, title: monthlyLabel,
                metricLabel: monthlyLabel
            )
            .exportingLimit("monthly.\(account.descriptorKey)", unit: "percent", estimated: true)
            .hidingWhenEmpty()
        ]
    }
}

extension RustOpenCodeProvider: GoKeyManaging {
    func goKeyEntries() async -> [OpenCodeGoKeyEntry] {
        await keyManager.goKeyEntries()
    }

    @discardableResult
    func saveGoKey(label: String, key: String) async throws -> OpenCodeGoKey {
        try await keyManager.saveGoKey(label: label, key: key)
    }

    func removeGoKey(id: UUID) async throws {
        try await keyManager.removeGoKey(id: id)
    }

    func selectGoKey(id: String) {
        keyManager.selectGoKey(id: id)
    }

    func activeGoKeyID() -> String? {
        keyManager.activeGoKeyID()
    }
}
