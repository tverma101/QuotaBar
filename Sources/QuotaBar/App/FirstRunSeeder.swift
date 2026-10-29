import Foundation

/// Seeds a new install with the small provider set the owner chose to show by default. Optional
/// providers stay off until the user turns them on in Customize; startup never scans local credentials
/// to decide which cards to enable.
@MainActor
enum FirstRunSeeder {
    /// Established providers plus Freebuff, which the owner explicitly chose as a default-on card.
    static let fallbackProviderIDs = ProviderEnablementPersistence.initiallyEnabledProviderIDs

    /// Returns `nil` when no seeding happened. Fresh installs are initialized synchronously so no
    /// provider can flash on or wait for a credential/keychain probe before the dashboard appears.
    @discardableResult
    static func seedIfNeeded(
        isFreshInstall: Bool,
        providers: [ProviderRuntime],
        enablement: ProviderEnablementStore,
        onboarding: OnboardingStore
    ) -> Task<Void, Never>? {
        let orderedProviderIDs = providers.map(\.provider.id)
        let providerIDs = Set(orderedProviderIDs)

        if enablement.hasPendingFirstRunSeed || (isFreshInstall && enablement.enabledIDs == nil) {
            enablement.beginFirstRunSeed()
            enablement.registerKnownProviders(providerIDs)
            onboarding.markCustomizeHintPending()
            enablement.seedEnabledProviders(defaultProviderIDs(in: orderedProviderIDs))
            enablement.completeFirstRunSeed()
            AppLog.info(.config, "first run: enabled default providers; optional providers are manual in Customize")
            return nil
        }

        // Older builds could leave credential probes pending across a relaunch. Discard those markers;
        // a stale completion must never turn a provider on after activation became manual.
        if enablement.hasPendingFirstRunCredentialProbe {
            enablement.completeFirstRunCredentialProbe()
        }
        if !enablement.pendingProviderCredentialProbeIDs.isEmpty {
            enablement.completeProviderCredentialProbes(for: enablement.pendingProviderCredentialProbeIDs)
        }
        return nil
    }

    /// The Customize “Reset All” action is explicit, but it now resets to the same stable defaults
    /// instead of re-probing every provider and turning on whichever local auth files happen to exist.
    /// The returned task keeps the existing caller contract; all state changes finish synchronously.
    @discardableResult
    static func reseed(
        providers: [ProviderRuntime],
        enablement: ProviderEnablementStore
    ) -> Task<Void, Never> {
        let orderedProviderIDs = providers.map(\.provider.id)
        let providerIDs = Set(orderedProviderIDs)
        enablement.resetProviderChoices(to: defaultProviderIDs(in: orderedProviderIDs))
        enablement.registerKnownProviders(providerIDs)
        enablement.completeFirstRunCredentialProbe()
        enablement.completeProviderCredentialProbes(for: enablement.pendingProviderCredentialProbeIDs)
        AppLog.info(.config, "reset all: restored default providers; optional providers remain off")
        return Task {}
    }

    /// Codex account cards are explicit signed-in profiles of the core Codex provider, so retain them
    /// with the default Codex card. If tombstone history occupies the bare Claude ID, keep the
    /// assembly's preferred account-scoped Claude card as the family default instead.
    static func defaultProviderIDs(in orderedProviderIDs: [String]) -> Set<String> {
        let providerIDs = Set(orderedProviderIDs)
        var defaults = fallbackProviderIDs.intersection(providerIDs)
            .union(providerIDs.filter { $0.hasPrefix("codex@") })
        if !providerIDs.contains("claude"),
           let preferredClaudeID = orderedProviderIDs.first(where: {
               ProviderAccountID.family(of: $0) == "claude"
           })
        {
            defaults.insert(preferredClaudeID)
        }
        return defaults
    }
}
