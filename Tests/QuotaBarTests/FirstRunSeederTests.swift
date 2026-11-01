import XCTest
@testable import QuotaBar

/// Provider activation is manual except for the owner-selected first-run defaults. These tests also
/// prove startup seeding does not inspect provider credentials or wait for local/keychain reads.
@MainActor
final class FirstRunSeederTests: XCTestCase {
    func testFreshInstallSeedsOnlyDefaultsAndDoesNotProbeCredentials() {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("manual-defaults"))
        let onboarding = OnboardingStore(defaults: makeDefaults("manual-defaults-onboarding"))
        let providers = [
            stub("claude", hasCredentials: false),
            stub("codex", hasCredentials: true),
            stub("codex@account-a", hasCredentials: true),
            stub("cursor", hasCredentials: false),
            stub("freebuff", hasCredentials: false),
            stub("antigravity", hasCredentials: true),
            stub("grok", hasCredentials: true),
            stub("opencode", hasCredentials: true)
        ]

        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: true, providers: providers,
            enablement: enablement, onboarding: onboarding
        )

        XCTAssertNil(task, "first-run defaults are committed synchronously")
        XCTAssertEqual(enablement.enabledIDs, ["claude", "codex", "codex@account-a", "cursor", "freebuff"])
        XCTAssertEqual(enablement.knownIDs, Set(providers.map(\.provider.id)))
        XCTAssertTrue(onboarding.isCustomizeHintPending)
        XCTAssertTrue(providers.allSatisfy { ($0 as? ProbeCountingProvider)?.probeCount == 0 })
    }

    func testExistingInstallIsNeverReseeded() {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("existing"))
        let onboarding = OnboardingStore(defaults: makeDefaults("existing-onboarding"))
        let grok = stub("grok", hasCredentials: true)

        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: false, providers: [grok],
            enablement: enablement, onboarding: onboarding
        )

        XCTAssertNil(task)
        XCTAssertNil(enablement.enabledIDs, "existing legacy state must not be converted by first-run seeding")
        XCTAssertTrue(enablement.isEnabled("grok"))
        XCTAssertFalse(onboarding.isCustomizeHintPending)
        XCTAssertEqual(grok.probeCount, 0)
    }

    func testInterruptedFreshInstallSeedResumesOnNextLaunchAndKeepsOptionalProvidersOff() {
        let defaults = makeDefaults("resume-fresh-seed")
        defaults.set(true, forKey: ProviderEnablementPersistence.firstRunSeedPendingKey)
        let enablement = ProviderEnablementStore(defaults: defaults)
        let onboardingDefaults = makeDefaults("resume-fresh-seed-onboarding")
        let onboarding = OnboardingStore(defaults: onboardingDefaults)
        let providers = [
            stub("claude", hasCredentials: false),
            stub("codex", hasCredentials: false),
            stub("codex@account-a", hasCredentials: true),
            stub("cursor", hasCredentials: false),
            stub("freebuff", hasCredentials: false),
            stub("grok", hasCredentials: true),
            stub("opencode", hasCredentials: true)
        ]

        XCTAssertTrue(enablement.isEnabled("claude"))
        XCTAssertFalse(enablement.isEnabled("grok"), "pending first-run state must never fall back to legacy all-on")
        XCTAssertNil(enablement.enabledIDs, "this models a crash before the first enabled-list write")

        FirstRunSeeder.seedIfNeeded(
            isFreshInstall: false,
            providers: providers,
            enablement: enablement,
            onboarding: onboarding
        )

        XCTAssertEqual(enablement.enabledIDs, ["claude", "codex", "codex@account-a", "cursor", "freebuff"])
        XCTAssertTrue(enablement.knownIDs.isSuperset(of: Set(providers.map(\.provider.id))))
        XCTAssertFalse(enablement.hasPendingFirstRunSeed)
        XCTAssertTrue(onboarding.isCustomizeHintPending)
        XCTAssertTrue(providers.allSatisfy { ($0 as? ProbeCountingProvider)?.probeCount == 0 })
    }

    func testAlreadySeededStoreIsNotReseeded() {
        let defaults = makeDefaults("idempotent")
        let enablement = ProviderEnablementStore(defaults: defaults)
        enablement.seedEnabledProviders(["grok"])
        let onboarding = OnboardingStore(defaults: makeDefaults("idempotent-onboarding"))
        let grok = stub("grok", hasCredentials: true)

        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: true, providers: [grok],
            enablement: enablement, onboarding: onboarding
        )

        XCTAssertNil(task)
        XCTAssertEqual(enablement.enabledIDs, ["grok"])
        XCTAssertEqual(grok.probeCount, 0)
    }

    func testResetAllRestoresManualDefaultsWithoutProbingOptionalProviders() async {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("reset-all"))
        enablement.seedEnabledProviders(["claude", "grok", "opencode"])
        enablement.registerKnownProviders(["claude", "grok", "opencode"])
        let providers = [
            stub("claude", hasCredentials: true),
            stub("codex", hasCredentials: false),
            stub("codex@account-a", hasCredentials: true),
            stub("cursor", hasCredentials: false),
            stub("freebuff", hasCredentials: false),
            stub("grok", hasCredentials: true),
            stub("opencode", hasCredentials: true)
        ]

        await FirstRunSeeder.reseed(providers: providers, enablement: enablement).value

        XCTAssertEqual(enablement.enabledIDs, ["claude", "codex", "codex@account-a", "cursor", "freebuff"])
        XCTAssertEqual(enablement.knownIDs, Set(providers.map(\.provider.id)))
        XCTAssertTrue(providers.allSatisfy { ($0 as? ProbeCountingProvider)?.probeCount == 0 })
    }

    func testResetAllClearsOffChoiceForUnregisteredCodexAccountBeforeItReturns() async {
        let defaults = makeDefaults("reset-all-removed-codex")
        let enablement = ProviderEnablementStore(defaults: defaults)
        enablement.seedEnabledProviders(["claude", "codex", "cursor", "codex@removed-account"])
        enablement.setEnabled(false, for: "codex@removed-account")
        XCTAssertTrue(enablement.userChoiceProviderIDs.contains("codex@removed-account"))

        await FirstRunSeeder.reseed(
            providers: [stub("claude", hasCredentials: false), stub("codex", hasCredentials: false), stub("cursor", hasCredentials: false)],
            enablement: enablement
        ).value

        XCTAssertFalse(enablement.userChoiceProviderIDs.contains("codex@removed-account"))
        enablement.enableNewlyRegisteredCodexAccounts(
            discoveredIDs: ["codex@removed-account"],
            previouslyDiscoveredIDs: []
        )
        XCTAssertTrue(enablement.isEnabled("codex@removed-account"))
    }

    func testLegacyPendingFirstRunProbeIsClearedWithoutApplyingItsResult() {
        let defaults = makeDefaults("clear-old-pending")
        let original = ProviderEnablementStore(defaults: defaults)
        original.beginFirstRunCredentialProbe()
        original.registerKnownProviders(["claude", "grok"])
        original.seedEnabledProviders(["claude"])

        let relaunched = ProviderEnablementStore(defaults: defaults)
        let grok = stub("grok", hasCredentials: true)
        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: false,
            providers: [stub("claude", hasCredentials: true), grok],
            enablement: relaunched,
            onboarding: OnboardingStore(defaults: makeDefaults("clear-old-pending-onboarding"))
        )

        XCTAssertNil(task)
        XCTAssertEqual(relaunched.enabledIDs, ["claude"])
        XCTAssertFalse(relaunched.hasPendingFirstRunCredentialProbe)
        XCTAssertEqual(grok.probeCount, 0)
    }

    private func stub(_ id: String, hasCredentials: Bool) -> ProbeCountingProvider {
        ProbeCountingProvider(id: id, hasCredentials: hasCredentials)
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "QuotaBarTests.FirstRunSeeder.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

}

@MainActor
private final class ProbeCountingProvider: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor] = []
    private let hasCredentials: Bool
    private(set) var probeCount = 0

    init(id: String, hasCredentials: Bool) {
        self.provider = Provider(id: id, displayName: id.capitalized, icon: .providerMark(id))
        self.hasCredentials = hasCredentials
    }

    func refresh() async -> ProviderSnapshot {
        ProviderSnapshot.make(provider: provider, plan: nil, lines: [], refreshedAt: Date())
    }

    func hasLocalCredentials() async -> Bool {
        probeCount += 1
        return hasCredentials
    }
}
