import Foundation

/// Registers providers shipped by an update without enabling them. Provider activation is a user choice:
/// a new card stays off until the user turns it on in Customize, regardless of local credential files.
@MainActor
enum NewProviderSeeder {
    /// Returns `nil` because registry reconciliation is synchronous and performs no credential probes.
    @discardableResult
    static func reconcileIfNeeded(
        providers: [ProviderRuntime],
        enablement: ProviderEnablementStore
    ) -> Task<Void, Never>? {
        // Legacy disabled-list installs are migrated before the store is constructed in the bundled app.
        // Keep this guard for downgrade/unbundled safety; these stores already define absent providers
        // as enabled and cannot represent an opt-in default without migrating their storage shape.
        guard enablement.enabledIDs != nil else { return nil }

        let currentIDs = Set(providers.map(\.provider.id))
        let newIDs = enablement.registerKnownProviders(currentIDs)
        if !newIDs.isEmpty {
            AppLog.info(.config, "new providers available in Customize (left off): \(newIDs.sorted())")
        }

        // Older releases persisted unfinished probes. Clear them so a relaunch or stale task cannot
        // auto-enable a provider under the new manual policy.
        if !enablement.pendingProviderCredentialProbeIDs.isEmpty {
            enablement.completeProviderCredentialProbes(for: enablement.pendingProviderCredentialProbeIDs)
        }
        return nil
    }
}
