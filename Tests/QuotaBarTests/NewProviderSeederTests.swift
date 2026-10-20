import XCTest
@testable import QuotaBar

/// Update-time discovery only registers providers. A credential file never turns a new card on.
@MainActor
final class NewProviderSeederTests: XCTestCase {
    func testNewCredentialedProviderIsRegisteredButRemainsOffWithoutProbe() {
        let enablement = seededStore("manual-new-provider", enabled: ["claude", "freebuff"], known: ["claude", "freebuff"])
        let windsurf = probe("windsurf", hasCredentials: true)

        let task = NewProviderSeeder.reconcileIfNeeded(
            providers: [probe("claude", hasCredentials: true), windsurf], enablement: enablement
        )

        XCTAssertNil(task, "manual provider registration is synchronous")
        XCTAssertEqual(enablement.enabledIDs, ["claude", "freebuff"])
        XCTAssertEqual(enablement.knownIDs, ["claude", "freebuff", "windsurf"])
        XCTAssertEqual(windsurf.probeCount, 0)
    }

    func testInterruptedOldProbeIsDiscardedWithoutEnablingProvider() {
        let defaults = makeDefaults("discard-old-probe")
        let original = ProviderEnablementStore(defaults: defaults)
        original.seedEnabledProviders(["claude", "freebuff"])
        original.registerKnownProviders(["claude", "freebuff"])
        XCTAssertEqual(original.registerProvidersForCredentialProbe(["claude", "grok"]), ["grok"])

        let relaunched = ProviderEnablementStore(defaults: defaults)
        let grok = probe("grok", hasCredentials: true)
        let task = NewProviderSeeder.reconcileIfNeeded(
            providers: [probe("claude", hasCredentials: false), grok], enablement: relaunched
        )

        XCTAssertNil(task)
        XCTAssertEqual(relaunched.enabledIDs, ["claude", "freebuff"])
        XCTAssertTrue(relaunched.pendingProviderCredentialProbeIDs.isEmpty)
        XCTAssertEqual(grok.probeCount, 0)
    }

    func testExplicitlyEnabledNewProviderStaysEnabled() {
        let enablement = seededStore("manual-on", enabled: ["claude"], known: ["claude"])
        enablement.setEnabled(true, for: "windsurf")
        let windsurf = probe("windsurf", hasCredentials: false)

        _ = NewProviderSeeder.reconcileIfNeeded(providers: [windsurf], enablement: enablement)

        XCTAssertTrue(enablement.isEnabled("windsurf"))
        XCTAssertTrue(enablement.userChoiceProviderIDs.contains("windsurf"))
        XCTAssertEqual(windsurf.probeCount, 0)
    }

    func testKnownDisabledProviderIsNotProbedOrReenabled() {
        let enablement = seededStore("known-off", enabled: ["claude"], known: ["claude", "grok"])
        let grok = probe("grok", hasCredentials: true)

        _ = NewProviderSeeder.reconcileIfNeeded(
            providers: [probe("claude", hasCredentials: true), grok], enablement: enablement
        )

        XCTAssertFalse(enablement.isEnabled("grok"))
        XCTAssertEqual(grok.probeCount, 0)
    }

    func testEmptyKnownSetIsBaselinedWithoutProbing() {
        let enablement = seededStore("baseline", enabled: ["claude"], known: [])
        let grok = probe("grok", hasCredentials: true)

        _ = NewProviderSeeder.reconcileIfNeeded(providers: [probe("claude", hasCredentials: true), grok], enablement: enablement)

        XCTAssertEqual(enablement.knownIDs, ["claude", "grok"])
        XCTAssertFalse(enablement.isEnabled("grok"))
        XCTAssertEqual(grok.probeCount, 0)
    }

    func testLegacyModeStoreIsUntouched() {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("legacy"))
        let grok = probe("grok", hasCredentials: true)

        let task = NewProviderSeeder.reconcileIfNeeded(providers: [grok], enablement: enablement)

        XCTAssertNil(task)
        XCTAssertNil(enablement.enabledIDs)
        XCTAssertTrue(enablement.isEnabled("grok"), "legacy disabled-list mode is preserved for downgrade safety")
        XCTAssertEqual(grok.probeCount, 0)
    }

    private func seededStore(_ name: String, enabled: Set<String>, known: Set<String>) -> ProviderEnablementStore {
        let store = ProviderEnablementStore(defaults: makeDefaults(name))
        store.seedEnabledProviders(enabled)
        store.registerKnownProviders(known)
        return store
    }

    private func probe(_ id: String, hasCredentials: Bool) -> ProbeCountingProvider {
        ProbeCountingProvider(id: id, hasCredentials: hasCredentials)
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "QuotaBarTests.NewProviderSeeder.\(name).\(UUID().uuidString)"
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
