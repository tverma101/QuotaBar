import XCTest
@testable import QuotaBar

/// Covers the persistence contract of `ProviderEnablementStore`: only *disabled* IDs are stored, so an
/// empty suite means everything is on and the choice survives relaunch.
@MainActor
final class ProviderEnablementStoreTests: XCTestCase {
    func testEmptySuiteEnablesEverything() {
        let store = ProviderEnablementStore(defaults: makeDefaults("empty"))

        XCTAssertTrue(store.disabledIDs.isEmpty)
        XCTAssertTrue(store.isEnabled("claude"))
        XCTAssertTrue(store.isEnabled("a-provider-that-ships-next-year"))
        XCTAssertTrue(store.hasEnabledProviderFamily("claude"))
    }

    func testClaudeFamilyIsEnabledWhenAnyAccountCardIsEnabled() {
        let defaults = makeDefaults("claude-family")
        defaults.set(["claude", "claude@work"], forKey: "openusage.knownProviders.v1")
        defaults.set(["claude@work"], forKey: "openusage.enabledProviders.v1")
        let store = ProviderEnablementStore(defaults: defaults)

        XCTAssertTrue(store.hasEnabledProviderFamily("claude"))
        XCTAssertFalse(store.isEnabled("claude"))
        XCTAssertTrue(store.isEnabled("claude@work"))
    }

    func testExplicitGenericClaudeEnablementTransfersToNewAccountCard() {
        let store = ProviderEnablementStore(defaults: makeDefaults("claude-enable-transfer"))
        store.seedEnabledProviders(["claude"])
        store.setEnabled(false, for: "claude")
        store.setEnabled(true, for: "claude")

        let transferredID = store.transferExplicitGenericClaudeEnablement(to: ["claude@work"])

        XCTAssertEqual(transferredID, "claude@work")
        XCTAssertTrue(store.isEnabled("claude@work"))
        XCTAssertFalse(store.userChoiceProviderIDs.contains("claude@work"), "the family choice should not fabricate an account-level toggle")
    }

    func testGenericClaudeEnablementDoesNotOverrideAnExplicitAccountOffChoice() {
        let store = ProviderEnablementStore(defaults: makeDefaults("claude-enable-transfer-off"))
        store.seedEnabledProviders(["claude", "claude@work"])
        store.setEnabled(false, for: "claude@work")
        store.setEnabled(false, for: "claude")
        store.setEnabled(true, for: "claude")

        let transferredID = store.transferExplicitGenericClaudeEnablement(to: ["claude@work"])

        XCTAssertNil(transferredID)
        XCTAssertFalse(store.isEnabled("claude@work"))
    }

    func testDisablingAndReenablingPersistAcrossInstances() {
        let defaults = makeDefaults("persist")
        let store = ProviderEnablementStore(defaults: defaults)

        store.setEnabled(false, for: "codex")

        XCTAssertFalse(store.isEnabled("codex"))
        XCTAssertTrue(store.isEnabled("claude"))

        let reloaded = ProviderEnablementStore(defaults: defaults)
        XCTAssertEqual(reloaded.disabledIDs, ["codex"])
        XCTAssertFalse(reloaded.isEnabled("codex"))
        XCTAssertTrue(reloaded.isEnabled("claude"))

        store.setEnabled(true, for: "codex")

        XCTAssertTrue(store.disabledIDs.isEmpty)
        XCTAssertTrue(store.isEnabled("codex"))

        let reenabled = ProviderEnablementStore(defaults: defaults)
        XCTAssertTrue(reenabled.disabledIDs.isEmpty)
        XCTAssertTrue(reenabled.isEnabled("codex"))
    }

    // MARK: - Early-refresh signal

    func testRealChangePostsDidChangeNotification() {
        let store = ProviderEnablementStore(defaults: makeDefaults("notify-change"))
        let posted = XCTNSNotificationExpectation(name: ProviderEnablementStore.didChangeNotification)

        store.setEnabled(false, for: "codex")   // enabled -> disabled: a real change

        wait(for: [posted], timeout: 1)
    }

    func testNoOpToggleDoesNotPostDidChangeNotification() {
        // The refresh loop wakes on this notification; a redundant toggle must not wake it (and re-probe).
        let store = ProviderEnablementStore(defaults: makeDefaults("notify-noop"))
        let notPosted = XCTNSNotificationExpectation(name: ProviderEnablementStore.didChangeNotification)
        notPosted.isInverted = true

        store.setEnabled(true, for: "codex")    // already enabled (empty suite): a no-op

        wait(for: [notPosted], timeout: 0.2)
    }

    func testOnProviderEnabledFiresOnEnableOnly() {
        // Wired to clear the failure backoff; must fire on a real enable, never on disable or a no-op.
        let store = ProviderEnablementStore(defaults: makeDefaults("on-enable"))
        var enabledIDs: [String] = []
        store.onProviderEnabled = { enabledIDs.append($0) }

        store.setEnabled(false, for: "codex")   // disable: must NOT fire
        store.setEnabled(true, for: "codex")    // enable: fires with "codex"
        store.setEnabled(true, for: "codex")    // already enabled (no-op): must NOT fire

        XCTAssertEqual(enabledIDs, ["codex"])
    }

    // MARK: - Enabled-list mode (fresh installs)

    func testSeedingSwitchesToEnabledListMode() {
        let defaults = makeDefaults("seed")
        let store = ProviderEnablementStore(defaults: defaults)

        store.seedEnabledProviders(["claude", "codex"])

        XCTAssertTrue(store.isEnabled("claude"))
        XCTAssertTrue(store.isEnabled("codex"))
        XCTAssertFalse(store.isEnabled("grok"))
        // The key property of enabled-list mode: a provider shipped later defaults to OFF.
        XCTAssertFalse(store.isEnabled("a-provider-that-ships-next-year"))

        let reloaded = ProviderEnablementStore(defaults: defaults)
        XCTAssertEqual(reloaded.enabledIDs, ["claude", "codex"])
        XCTAssertTrue(reloaded.isEnabled("claude"))
        XCTAssertFalse(reloaded.isEnabled("grok"))
    }

    func testTogglesPersistInEnabledListMode() {
        let defaults = makeDefaults("enabled-toggles")
        let store = ProviderEnablementStore(defaults: defaults)
        store.seedEnabledProviders(["claude"])

        store.setEnabled(true, for: "grok")
        store.setEnabled(false, for: "claude")

        let reloaded = ProviderEnablementStore(defaults: defaults)
        XCTAssertEqual(reloaded.enabledIDs, ["grok"])
        XCTAssertTrue(reloaded.isEnabled("grok"))
        XCTAssertFalse(reloaded.isEnabled("claude"))
    }

    func testCodexRegistrationEnablesOnlyNewAccountCards() {
        let defaults = makeDefaults("codex-registration-enable")
        defaults.set(["claude", "codex", "cursor"], forKey: "openusage.enabledProviders.v1")
        let store = ProviderEnablementStore(defaults: defaults)

        store.enableNewlyRegisteredCodexAccounts(
            discoveredIDs: ["codex@existing-off", "codex@new-account", "grok"],
            previouslyDiscoveredIDs: ["codex@existing-off"]
        )

        XCTAssertTrue(store.isEnabled("codex@new-account"))
        XCTAssertFalse(store.isEnabled("codex@existing-off"))
        XCTAssertFalse(store.isEnabled("grok"))
        XCTAssertTrue(store.userChoiceProviderIDs.contains("codex@new-account"))
    }

    func testCodexRegistrationDoesNotRevivePreviouslyDisabledAccountAfterRelaunch() {
        let defaults = makeDefaults("codex-registration-preserve-off")
        defaults.set(["claude", "codex", "cursor"], forKey: "openusage.enabledProviders.v1")
        defaults.set(["codex@removed-home"], forKey: "openusage.providerUserChoiceIDs.v1")
        let relaunchedStore = ProviderEnablementStore(defaults: defaults)

        // The stable account ID reappears after its home was absent from the previous process catalog.
        relaunchedStore.enableNewlyRegisteredCodexAccounts(
            discoveredIDs: ["codex@removed-home"],
            previouslyDiscoveredIDs: []
        )

        XCTAssertFalse(relaunchedStore.isEnabled("codex@removed-home"))
    }

    func testRelaunchReplaysInterruptedExplicitOffChoice() {
        let defaults = makeDefaults("recover-off-intent")
        defaults.set(["claude", "grok"], forKey: "openusage.enabledProviders.v1")
        ProviderEnablementPersistence.writePendingChoiceIntent(
            providerID: "grok", enabled: false, revision: 4, defaults: defaults
        )

        let reloaded = ProviderEnablementStore(defaults: defaults)

        XCTAssertFalse(reloaded.isEnabled("grok"))
        XCTAssertTrue(reloaded.userChoiceProviderIDs.contains("grok"))
        XCTAssertEqual(reloaded.persistentUserChoiceRevision, 4)
        XCTAssertNil(defaults.object(forKey: ProviderEnablementPersistence.pendingChoiceIntentKey))
    }

    func testRelaunchReplaysInterruptedResetBeforeReadingOldEnabledSet() {
        let defaults = makeDefaults("recover-reset-intent")
        defaults.set(
            ["claude", "codex", "cursor", "freebuff", "grok", "opencode", "antigravity"],
            forKey: "openusage.enabledProviders.v1"
        )
        defaults.set(["freebuff", "grok"], forKey: "openusage.providerUserChoiceIDs.v1")
        defaults.set(
            ["providerID": "grok", "enabled": true, "revision": NSNumber(value: 9)],
            forKey: ProviderEnablementPersistence.pendingChoiceIntentKey
        )
        let defaultsAfterReset = ProviderEnablementPersistence.initiallyEnabledProviderIDs
        ProviderEnablementPersistence.writePendingResetIntent(
            enabledProviderIDs: defaultsAfterReset,
            defaults: defaults
        )
        // Simulate a crash after Reset All cleared choice provenance, but before it replaced the old set.
        defaults.set([String](), forKey: "openusage.providerUserChoiceIDs.v1")

        let reloaded = ProviderEnablementStore(defaults: defaults)

        XCTAssertEqual(reloaded.enabledIDs, defaultsAfterReset)
        XCTAssertTrue(reloaded.isEnabled("freebuff"))
        XCTAssertFalse(reloaded.isEnabled("grok"))
        XCTAssertFalse(reloaded.isEnabled("opencode"))
        XCTAssertFalse(reloaded.isEnabled("antigravity"))
        XCTAssertTrue(reloaded.userChoiceProviderIDs.isEmpty)
        XCTAssertNil(defaults.object(forKey: ProviderEnablementPersistence.pendingResetIntentKey))
        XCTAssertNil(defaults.object(forKey: ProviderEnablementPersistence.pendingChoiceIntentKey))
    }

    func testMalformedResetIntentRestoresSafeDefaultsAndRegisteredCodexAccounts() {
        let defaults = makeDefaults("recover-malformed-reset-intent")
        defaults.set(
            ["claude", "codex", "cursor", "freebuff", "grok", "opencode", "codex@work"],
            forKey: "openusage.enabledProviders.v1"
        )
        defaults.set(["freebuff", "grok"], forKey: "openusage.providerUserChoiceIDs.v1")
        defaults.set(true, forKey: ProviderEnablementPersistence.pendingResetIntentKey)
        defaults.set(
            ["providerID": "grok", "enabled": true, "revision": NSNumber(value: 9)],
            forKey: ProviderEnablementPersistence.pendingChoiceIntentKey
        )

        let reloaded = ProviderEnablementStore(defaults: defaults)

        XCTAssertEqual(reloaded.enabledIDs, Set(["claude", "codex", "cursor", "freebuff", "codex@work"]))
        XCTAssertTrue(reloaded.userChoiceProviderIDs.isEmpty)
        XCTAssertNil(defaults.object(forKey: ProviderEnablementPersistence.pendingResetIntentKey))
        XCTAssertNil(defaults.object(forKey: ProviderEnablementPersistence.pendingChoiceIntentKey))
    }

    func testReseedFiresOnProviderEnabledForNewlyOnOnly() {
        let store = ProviderEnablementStore(defaults: makeDefaults("reseed-enable"))
        store.seedEnabledProviders(["claude", "codex"])
        var enabledIDs: [String] = []
        store.onProviderEnabled = { enabledIDs.append($0) }

        // The detection pass replacing the fallback: codex stays on (no callback), grok turns on.
        store.seedEnabledProviders(["codex", "grok"])

        XCTAssertEqual(enabledIDs, ["grok"])
    }

    func testNoOpReseedDoesNotNotify() {
        let store = ProviderEnablementStore(defaults: makeDefaults("reseed-noop"))
        store.seedEnabledProviders(["claude"])
        let notPosted = XCTNSNotificationExpectation(name: ProviderEnablementStore.didChangeNotification)
        notPosted.isInverted = true

        store.seedEnabledProviders(["claude"])

        wait(for: [notPosted], timeout: 0.2)
    }

    func testLegacyModeIgnoresEnabledListUntilSeeded() {
        // An existing install (disabled-list mode) must keep its semantics: absent enabled key means
        // everything is on except the explicitly disabled IDs.
        let defaults = makeDefaults("legacy-untouched")
        defaults.set(["devin"], forKey: "openusage.disabledProviders.v1")
        let store = ProviderEnablementStore(defaults: defaults)

        XCTAssertNil(store.enabledIDs)
        XCTAssertFalse(store.isEnabled("devin"))
        XCTAssertTrue(store.isEnabled("claude"))
        XCTAssertTrue(store.isEnabled("a-provider-that-ships-next-year"))
    }

    // MARK: - Known-provider set

    func testRegisterKnownProvidersReturnsNewOnesAndPersists() {
        let defaults = makeDefaults("known")
        let store = ProviderEnablementStore(defaults: defaults)
        XCTAssertTrue(store.knownIDs.isEmpty)

        XCTAssertEqual(store.registerKnownProviders(["claude", "codex"]), ["claude", "codex"])
        XCTAssertEqual(store.registerKnownProviders(["claude", "grok"]), ["grok"], "only never-seen IDs")
        XCTAssertEqual(store.registerKnownProviders(["claude"]), [], "no-op re-registration")

        let reloaded = ProviderEnablementStore(defaults: defaults)
        XCTAssertEqual(reloaded.knownIDs, ["claude", "codex", "grok"])
    }

    func testRegisterKnownProvidersDoesNotTouchEnablement() {
        // Pure bookkeeping: registering must not flip any toggle or wake the refresh loop.
        let store = ProviderEnablementStore(defaults: makeDefaults("known-pure"))
        store.seedEnabledProviders(["claude"])
        let notPosted = XCTNSNotificationExpectation(name: ProviderEnablementStore.didChangeNotification)
        notPosted.isInverted = true

        store.registerKnownProviders(["claude", "grok"])

        XCTAssertEqual(store.enabledIDs, ["claude"])
        XCTAssertFalse(store.isEnabled("grok"))
        wait(for: [notPosted], timeout: 0.2)
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.Enablement.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
