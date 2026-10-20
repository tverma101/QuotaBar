import XCTest
@testable import QuotaBar

final class SettingsMigratorTests: XCTestCase {
    // MARK: - Fresh vs. legacy vs. existing

    /// A genuine first launch (empty domain) records the current schema and runs no migrations — the
    /// stores seed their own current-shape defaults afterward.
    func testFreshInstallStampsCurrentAndRunsNothing() {
        let (defaults, domain) = makeDefaults("Fresh")
        defer { defaults.removePersistentDomain(forName: domain) }

        let result = SettingsMigrator.migrate(
            defaults: defaults, domainName: domain, current: 3, migrations: recording(1, 2, 3)
        )

        XCTAssertEqual(result, 3)
        XCTAssertEqual(defaults.integer(forKey: SettingsMigrator.schemaVersionKey), 3)
        XCTAssertNil(ranVersions(defaults), "a fresh install must not run historical migrations")
        XCTAssertEqual(
            Set(defaults.stringArray(forKey: "openusage.enabledProviders.v1") ?? []),
            ProviderEnablementPersistence.initiallyEnabledProviderIDs,
            "seed a safe enabled-list before the app waits for launch discovery"
        )
        XCTAssertTrue(defaults.bool(forKey: ProviderEnablementPersistence.firstRunSeedPendingKey))
    }

    /// An install that predates the schema-version key (settings present, no version) is migrated forward
    /// from v0 — every step runs, in order, and existing settings are kept.
    func testLegacyInstallMigratesFromZeroAndKeepsSettings() {
        let (defaults, domain) = makeDefaults("Legacy")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("custom", forKey: "openusage.layout.v1")  // pre-existing settings, no schema version

        let result = SettingsMigrator.migrate(
            defaults: defaults, domainName: domain, current: 3, migrations: recording(1, 2, 3)
        )

        XCTAssertEqual(result, 3)
        XCTAssertEqual(ranVersions(defaults), [1, 2, 3])
        XCTAssertEqual(defaults.string(forKey: "openusage.layout.v1"), "custom", "existing settings preserved")
    }

    // MARK: - Cascading

    /// A version jump runs only the pending intermediate steps in ascending order.
    func testCascadeRunsAllIntermediateStepsInOrder() {
        let (defaults, domain) = makeDefaults("Cascade")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(1, forKey: SettingsMigrator.schemaVersionKey)

        let result = SettingsMigrator.migrate(
            defaults: defaults, domainName: domain,
            current: 4, migrations: recording(1, 2, 3, 4)
        )

        XCTAssertEqual(result, 4)
        XCTAssertEqual(ranVersions(defaults), [2, 3, 4], "only pending steps run, in order")
    }

    /// Migrations declared out of order are still applied by ascending version.
    func testStepsApplyInAscendingOrderRegardlessOfDeclaration() {
        let (defaults, domain) = makeDefaults("Order")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(0, forKey: SettingsMigrator.schemaVersionKey)

        SettingsMigrator.migrate(
            defaults: defaults, domainName: domain,
            current: 3, migrations: [recordingStep(3), recordingStep(1), recordingStep(2)]
        )

        XCTAssertEqual(ranVersions(defaults), [1, 2, 3])
    }

    func testCurrentAndNewerVersionsNeverReplayMigrations() {
        for storedVersion in [3, 5] {
            let (defaults, domain) = makeDefaults("NoReplay\(storedVersion)")
            defer { defaults.removePersistentDomain(forName: domain) }
            defaults.set(storedVersion, forKey: SettingsMigrator.schemaVersionKey)

            let result = SettingsMigrator.migrate(
                defaults: defaults, domainName: domain, current: 3, migrations: recording(1, 2, 3)
            )

            XCTAssertEqual(result, storedVersion)
            XCTAssertEqual(defaults.integer(forKey: SettingsMigrator.schemaVersionKey), storedVersion)
            XCTAssertNil(ranVersions(defaults))
        }
    }

    /// A version bump with no data change for the top step still records reaching `current`, so the
    /// cascade isn't re-evaluated every launch.
    func testReachesCurrentEvenWhenTopVersionsHaveNoStep() {
        let (defaults, domain) = makeDefaults("Gap")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(0, forKey: SettingsMigrator.schemaVersionKey)

        let result = SettingsMigrator.migrate(
            defaults: defaults, domainName: domain, current: 5, migrations: recording(1, 2)
        )

        XCTAssertEqual(result, 5)
        XCTAssertEqual(defaults.integer(forKey: SettingsMigrator.schemaVersionKey), 5)
        XCTAssertEqual(ranVersions(defaults), [1, 2])
    }

    // MARK: - Resilience

    /// The version is persisted after EACH step, and a failing step stops the cascade at the last
    /// success so the next launch resumes instead of replaying completed steps.
    func testFailureStopsCascadeAndResumesNextLaunch() {
        let (defaults, domain) = makeDefaults("Failure")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(0, forKey: SettingsMigrator.schemaVersionKey)

        let result = SettingsMigrator.migrate(
            defaults: defaults, domainName: domain,
            current: 3, migrations: [recordingStep(1), failingStep(2), recordingStep(3)]
        )

        XCTAssertEqual(result, 1, "stops at the last successful step")
        XCTAssertEqual(defaults.integer(forKey: SettingsMigrator.schemaVersionKey), 1)
        XCTAssertEqual(ranVersions(defaults), [1], "the step after the failure does not run")

        // Next launch, failure resolved: resumes from v1 and finishes without replaying v1.
        let resumed = SettingsMigrator.migrate(
            defaults: defaults, domainName: domain, current: 3, migrations: recording(1, 2, 3)
        )
        XCTAssertEqual(resumed, 3)
        XCTAssertEqual(ranVersions(defaults), [1, 2, 3], "resumes at v2; v1 not replayed")
    }

    // MARK: - Regression (the beta-update bug)

    /// The bug this replaces: the old reset wiped the whole domain on every beta bump, silently clearing
    /// `betaUpdatesEnabled` (and everything else) and dropping users off the Early Access channel. The
    /// migrator must NEVER discard settings — an up-to-date install keeps every key untouched.
    func testMigrateNeverWipesExistingSettings() {
        let (defaults, domain) = makeDefaults("NoWipe")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "betaUpdatesEnabled")
        defaults.set("custom", forKey: "openusage.layout.v1")
        defaults.set(720.0, forKey: "openusage.panelHeight")
        defaults.set(SettingsSchema.current, forKey: SettingsMigrator.schemaVersionKey)

        SettingsMigrator.migrate(defaults: defaults, domainName: domain)  // real (shipped) schema

        XCTAssertTrue(defaults.bool(forKey: "betaUpdatesEnabled"), "Early Access opt-in must survive updates")
        XCTAssertEqual(defaults.string(forKey: "openusage.layout.v1"), "custom")
        XCTAssertEqual(defaults.double(forKey: "openusage.panelHeight"), 720.0)
    }

    /// A legacy install (no schema version) running the real shipped schema keeps unrelated settings.
    func testLegacyInstallKeepsSettingsUnderShippedSchema() {
        let (defaults, domain) = makeDefaults("LegacyReal")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "betaUpdatesEnabled")

        let result = SettingsMigrator.migrate(defaults: defaults, domainName: domain)

        XCTAssertEqual(result, SettingsSchema.current)
        XCTAssertTrue(defaults.bool(forKey: "betaUpdatesEnabled"))
    }

    // MARK: - v2: enabled-list unification + known-provider set

    /// A legacy disabled-list install converts to the equivalent enabled list: everything on except the
    /// explicitly disabled IDs — behavior-preserving — and the known set records the providers of the
    /// v2 era so none of them is later treated as "new" and probed.
    @MainActor  // `ProviderEnablementStore` (used to verify the migrated shape) is main-actor.
    func testV2ConvertsLegacyDisabledListToEnabledList() {
        let (defaults, domain) = makeDefaults("V2Legacy")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(1, forKey: SettingsMigrator.schemaVersionKey)
        defaults.set(["devin", "grok"], forKey: "openusage.disabledProviders.v1")

        let result = SettingsMigrator.migrate(defaults: defaults, domainName: domain, current: 3)

        XCTAssertEqual(result, 3)
        let enabled = Set(defaults.stringArray(forKey: "openusage.enabledProviders.v1") ?? [])
        XCTAssertEqual(
            enabled,
            Set(SettingsSchema.v2ProviderIDs)
                .union(SettingsSchema.v3PreviouslyShippedProviderIDs)
                .union(["freebuff"])
                .subtracting(["devin", "grok"])
        )
        XCTAssertNil(defaults.stringArray(forKey: "openusage.disabledProviders.v1"), "legacy key removed")
        XCTAssertEqual(
            Set(defaults.stringArray(forKey: "openusage.knownProviders.v1") ?? []),
            Set(SettingsSchema.v2ProviderIDs).union(SettingsSchema.v3PreviouslyShippedProviderIDs)
        )

        // The store loads the migrated shape: same effective on/off set, now in enabled-list mode.
        let store = ProviderEnablementStore(defaults: defaults)
        XCTAssertNotNil(store.enabledIDs)
        XCTAssertTrue(store.isEnabled("claude"))
        XCTAssertFalse(store.isEnabled("devin"))
        XCTAssertFalse(store.isEnabled("grok"))
    }

    /// A legacy install with no disabled providers (the all-on default) keeps all previously shipped
    /// providers enabled, including OpenCode and Hermes omitted from v2's original frozen list.
    func testV2ConvertsAllOnLegacyInstall() {
        let (defaults, domain) = makeDefaults("V2AllOn")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(1, forKey: SettingsMigrator.schemaVersionKey)
        defaults.set("custom", forKey: "openusage.layout.v1")  // some settings, so not a fresh install

        SettingsMigrator.migrate(defaults: defaults, domainName: domain, current: 3)

        XCTAssertEqual(
            Set(defaults.stringArray(forKey: "openusage.enabledProviders.v1") ?? []),
            Set(SettingsSchema.v2ProviderIDs).union(SettingsSchema.v3PreviouslyShippedProviderIDs).union(["freebuff"])
        )
    }

    /// An install with an existing nonempty known set preserves its enabled choices and adds the
    /// providers that were already shipped when the migration first went live.
    func testV2LeavesExistingEnabledListAloneAndExtendsKnownSet() {
        let (defaults, domain) = makeDefaults("V2EnabledList")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(1, forKey: SettingsMigrator.schemaVersionKey)
        defaults.set(["claude", "cursor"], forKey: "openusage.enabledProviders.v1")
        defaults.set(["claude", "cursor"], forKey: "openusage.knownProviders.v1")

        SettingsMigrator.migrate(defaults: defaults, domainName: domain, current: 3)

        XCTAssertEqual(
            Set(defaults.stringArray(forKey: "openusage.enabledProviders.v1") ?? []),
            ["claude", "cursor"]
        )
        XCTAssertEqual(
            Set(defaults.stringArray(forKey: "openusage.knownProviders.v1") ?? []),
            Set(["claude", "cursor"])
                .union(SettingsSchema.v2ProviderIDs)
                .union(SettingsSchema.v3PreviouslyShippedProviderIDs)
        )
    }

    /// The legacy disabled list can contain provider IDs missing from v2's frozen set, including
    /// OpenCode/Hermes and account-specific cards. Those explicit choices must not look like newcomers
    /// to `NewProviderSeeder` after the migration drops the old key.
    @MainActor
    func testMigrationKeepsPreviouslyDisabledProviderChoicesOff() async {
        let (defaults, domain) = makeDefaults("preserve-disabled")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(1, forKey: SettingsMigrator.schemaVersionKey)
        let disabled = ["opencode", "hermes", "codex@account-a"]
        defaults.set(disabled, forKey: "openusage.disabledProviders.v1")

        SettingsMigrator.migrate(defaults: defaults, domainName: domain, current: 3)
        let enablement = ProviderEnablementStore(defaults: defaults)
        let probes = disabled.map(MigrationCredentialProvider.init)
        let task = NewProviderSeeder.reconcileIfNeeded(providers: probes, enablement: enablement)
        await task?.value

        for providerID in disabled {
            XCTAssertFalse(enablement.isEnabled(providerID), "\(providerID) was explicitly disabled")
        }
        XCTAssertTrue(probes.allSatisfy { $0.probeCount == 0 }, "old choices must not be re-probed")
        XCTAssertEqual(enablement.knownIDs, Set(SettingsSchema.v2ProviderIDs)
            .union(SettingsSchema.v3PreviouslyShippedProviderIDs)
            .union(disabled))
    }

    /// Through v3, the old disabled-list format meant every omitted provider was enabled. OpenCode and
    /// Hermes were already shipped but absent from v2's frozen list, so v3 must preserve that state;
    /// v4 later applies the requested manual-provider defaults.
    @MainActor
    func testLegacyDisabledListKeepsPreviouslyShippedOmittedProvidersEnabled() {
        let (defaults, domain) = makeDefaults("preserve-omitted-enabled")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(1, forKey: SettingsMigrator.schemaVersionKey)
        defaults.set(["devin"], forKey: "openusage.disabledProviders.v1")

        SettingsMigrator.migrate(defaults: defaults, domainName: domain, current: 3)
        let enablement = ProviderEnablementStore(defaults: defaults)

        XCTAssertTrue(enablement.isEnabled("opencode"))
        XCTAssertTrue(enablement.isEnabled("hermes"))
        XCTAssertFalse(enablement.isEnabled("devin"))
    }

    /// Some schema-v2 standalone installs already had an enabled list but never acquired a known set.
    /// The empty set is the seeder's signal to baseline every current provider without probing; v3 must
    /// not replace that sentinel with only Hermes/OpenCode and cause every other omitted ID to be probed.
    @MainActor
    func testV3PreservesEmptyKnownSetSentinelWithoutReenablingDisabledChoices() async {
        let (defaults, domain) = makeDefaults("v2-empty-known")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(2, forKey: SettingsMigrator.schemaVersionKey)
        defaults.set(["cursor"], forKey: "openusage.enabledProviders.v1")
        defaults.set([String](), forKey: "openusage.knownProviders.v1")

        SettingsMigrator.migrate(defaults: defaults, domainName: domain, current: 3)
        let enablement = ProviderEnablementStore(defaults: defaults)
        let omitted = ["claude", "opencode", "hermes", "grok"]
        let currentRegistryIDs = omitted + ["cursor"]
        let probes = currentRegistryIDs.map(MigrationCredentialProvider.init)
        let task = NewProviderSeeder.reconcileIfNeeded(providers: probes, enablement: enablement)
        await task?.value

        XCTAssertEqual(enablement.enabledIDs, ["cursor"])
        XCTAssertTrue(probes.allSatisfy { $0.probeCount == 0 })
        XCTAssertEqual(enablement.knownIDs, Set(currentRegistryIDs))
    }

    /// A schema-v1 enabled-list install passes through v2 and v3 in one launch. The v2 migration must
    /// keep its empty-known sentinel intact so omitted credentials do not re-enable disabled choices.
    @MainActor
    func testV1MigrationPreservesEmptyKnownSentinelWithoutCredentialProbes() async {
        let (defaults, domain) = makeDefaults("v1-empty-known")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(1, forKey: SettingsMigrator.schemaVersionKey)
        defaults.set(["cursor"], forKey: "openusage.enabledProviders.v1")
        defaults.set([String](), forKey: "openusage.knownProviders.v1")

        SettingsMigrator.migrate(defaults: defaults, domainName: domain, current: 3)
        let enablement = ProviderEnablementStore(defaults: defaults)
        let registryIDs = ["claude", "cursor", "codex", "codex@account-a", "hermes", "opencode"]
        let probes = registryIDs.map(MigrationCredentialProvider.init)
        let task = NewProviderSeeder.reconcileIfNeeded(providers: probes, enablement: enablement)
        await task?.value

        XCTAssertEqual(enablement.enabledIDs, ["cursor"])
        XCTAssertTrue(probes.allSatisfy { $0.probeCount == 0 })
        XCTAssertEqual(enablement.knownIDs, Set(registryIDs))
    }

    /// Re-running the v2 step (an interrupted upgrade replays it) changes nothing.
    func testV2IsIdempotent() {
        let (defaults, domain) = makeDefaults("V2Idempotent")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(1, forKey: SettingsMigrator.schemaVersionKey)
        defaults.set(["codex"], forKey: "openusage.disabledProviders.v1")

        SettingsMigrator.migrate(defaults: defaults, domainName: domain, current: 2)
        let enabledAfterFirst = defaults.stringArray(forKey: "openusage.enabledProviders.v1")
        defaults.set(1, forKey: SettingsMigrator.schemaVersionKey)  // simulate an interrupted upgrade
        SettingsMigrator.migrate(defaults: defaults, domainName: domain, current: 2)

        XCTAssertEqual(defaults.stringArray(forKey: "openusage.enabledProviders.v1"), enabledAfterFirst)
    }

    func testLegacyDisabledChoicesSurviveRetryAfterEnabledListWasWritten() {
        let (defaults, domain) = makeDefaults("V2InterruptedAfterEnabledWrite")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(1, forKey: SettingsMigrator.schemaVersionKey)
        let disabled = ["antigravity", "freebuff"]
        defaults.set(
            (Set(SettingsSchema.v2ProviderIDs).union(SettingsSchema.v3PreviouslyShippedProviderIDs)
                .subtracting(disabled)).sorted(),
            forKey: "openusage.enabledProviders.v1"
        )
        defaults.set(disabled, forKey: "openusage.disabledProviders.v1")
        defaults.set([String](), forKey: "openusage.knownProviders.v1")

        SettingsMigrator.migrate(defaults: defaults, domainName: domain)

        let enabled = Set(defaults.stringArray(forKey: "openusage.enabledProviders.v1") ?? [])
        XCTAssertFalse(enabled.contains("antigravity"))
        XCTAssertFalse(enabled.contains("freebuff"), "legacy explicit-off state must not be revived by v4 defaults")
        XCTAssertTrue(Set(defaults.stringArray(forKey: "openusage.providerUserChoiceIDs.v1") ?? []).isSuperset(of: disabled))
        XCTAssertNil(defaults.object(forKey: "openusage.disabledProviders.v1"), "retry should finish cleaning legacy state")
    }

    func testInterruptedLegacyConversionAddsFreebuffWhenOnlyAnotherProviderWasDisabled() {
        let (defaults, domain) = makeDefaults("V2InterruptedWithUnrelatedDisabledProvider")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(1, forKey: SettingsMigrator.schemaVersionKey)
        defaults.set(
            Set(SettingsSchema.v2ProviderIDs).union(SettingsSchema.v3PreviouslyShippedProviderIDs)
                .subtracting(["devin"]).sorted(),
            forKey: "openusage.enabledProviders.v1"
        )
        defaults.set(["devin"], forKey: "openusage.disabledProviders.v1")
        defaults.set([String](), forKey: "openusage.knownProviders.v1")

        SettingsMigrator.migrate(defaults: defaults, domainName: domain)

        let enabled = Set(defaults.stringArray(forKey: "openusage.enabledProviders.v1") ?? [])
        XCTAssertTrue(enabled.contains("freebuff"), "the surviving legacy list means Freebuff was not explicitly off")
        XCTAssertFalse(enabled.contains("devin"))
        XCTAssertFalse(enabled.contains("antigravity"), "auto-detected optional providers still require a manual choice")
        XCTAssertTrue((defaults.stringArray(forKey: "openusage.providerUserChoiceIDs.v1") ?? []).contains("devin"))
    }

    func testInterruptedLegacyConversionRecoversRegisteredCodexCardsAndKeepsExplicitOff() throws {
        let (defaults, domain) = makeDefaults("V2InterruptedCodexRecovery")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(1, forKey: SettingsMigrator.schemaVersionKey)
        defaults.set(
            Set(SettingsSchema.v2ProviderIDs).union(SettingsSchema.v3PreviouslyShippedProviderIDs)
                .subtracting(["devin"])
                .sorted(),
            forKey: "openusage.enabledProviders.v1"
        )
        defaults.set(["devin", "codex@manual-off"], forKey: "openusage.disabledProviders.v1")
        defaults.set(try JSONSerialization.data(withJSONObject: [
            ["id": "codex@previously-enabled", "family": "codex", "removedTombstone": false],
            ["id": "codex@manual-off", "family": "codex", "removedTombstone": false],
            ["id": "codex@removed", "family": "codex", "removedTombstone": true]
        ]), forKey: "openusage.providerAccounts.v1")
        defaults.set([String](), forKey: "openusage.knownProviders.v1")

        SettingsMigrator.migrate(defaults: defaults, domainName: domain)

        let enabled = Set(defaults.stringArray(forKey: "openusage.enabledProviders.v1") ?? [])
        XCTAssertTrue(enabled.contains("codex@previously-enabled"))
        XCTAssertFalse(enabled.contains("codex@manual-off"))
        XCTAssertFalse(enabled.contains("codex@removed"))
        XCTAssertTrue(enabled.contains("freebuff"))
        XCTAssertTrue((defaults.stringArray(forKey: "openusage.providerUserChoiceIDs.v1") ?? []).contains("codex@manual-off"))
    }

    func testLegacyConversionPreservesFreebuffExplicitlyTurnedBackOn() {
        let (defaults, domain) = makeDefaults("LegacyFreebuffOn")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(1, forKey: SettingsMigrator.schemaVersionKey)
        defaults.set(["devin"], forKey: "openusage.disabledProviders.v1")
        // The old store records an ID after either toggle direction. The disabled-list is authoritative.
        defaults.set(["freebuff", "devin"], forKey: "openusage.providerUserChoiceIDs.v1")

        SettingsMigrator.migrate(defaults: defaults, domainName: domain)

        let enabled = Set(defaults.stringArray(forKey: "openusage.enabledProviders.v1") ?? [])
        XCTAssertTrue(enabled.contains("freebuff"))
        XCTAssertFalse(enabled.contains("devin"))
        XCTAssertFalse(enabled.contains("grok"), "credential-detected optional providers become manual")
    }

    func testInterruptedLegacyRetryUsesDisabledListForCodexDirection() throws {
        let (defaults, domain) = makeDefaults("V2InterruptedCodexDirection")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(1, forKey: SettingsMigrator.schemaVersionKey)
        defaults.set(
            Set(SettingsSchema.v2ProviderIDs).union(SettingsSchema.v3PreviouslyShippedProviderIDs)
                .subtracting(["devin"]).sorted(),
            forKey: "openusage.enabledProviders.v1"
        )
        defaults.set(["devin", "codex@manual-off"], forKey: "openusage.disabledProviders.v1")
        defaults.set(["codex@previously-enabled", "codex@manual-off"], forKey: "openusage.providerUserChoiceIDs.v1")
        defaults.set(try JSONSerialization.data(withJSONObject: [
            ["id": "codex@previously-enabled", "family": "codex", "removedTombstone": false],
            ["id": "codex@manual-off", "family": "codex", "removedTombstone": false]
        ]), forKey: "openusage.providerAccounts.v1")
        defaults.set([String](), forKey: "openusage.knownProviders.v1")

        SettingsMigrator.migrate(defaults: defaults, domainName: domain)

        let enabled = Set(defaults.stringArray(forKey: "openusage.enabledProviders.v1") ?? [])
        XCTAssertTrue(enabled.contains("codex@previously-enabled"))
        XCTAssertFalse(enabled.contains("codex@manual-off"))
    }

    func testPendingManualEnableIsRecoveredBeforeOptionalProviderMigration() {
        let (defaults, domain) = makeDefaults("RecoverPendingManualEnable")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(3, forKey: SettingsMigrator.schemaVersionKey)
        defaults.set(["claude", "codex", "cursor"], forKey: "openusage.enabledProviders.v1")
        defaults.set(
            SettingsSchema.v2ProviderIDs + SettingsSchema.v3PreviouslyShippedProviderIDs,
            forKey: "openusage.knownProviders.v1"
        )
        ProviderEnablementPersistence.writePendingChoiceIntent(
            providerID: "grok", enabled: true, revision: 1, defaults: defaults
        )

        SettingsMigrator.migrate(defaults: defaults, domainName: domain)

        XCTAssertTrue((defaults.stringArray(forKey: "openusage.enabledProviders.v1") ?? []).contains("grok"))
        XCTAssertTrue((defaults.stringArray(forKey: "openusage.providerUserChoiceIDs.v1") ?? []).contains("grok"))
        XCTAssertNil(defaults.object(forKey: ProviderEnablementPersistence.pendingChoiceIntentKey))
    }

    @MainActor
    func testV4PreservesManualChoicesAndDefaultsWhileDisablingDetectedOptionalProviders() {
        let (defaults, domain) = makeDefaults("V4ManualProviders")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(3, forKey: SettingsMigrator.schemaVersionKey)
        defaults.set(
            ["claude", "cursor", "freebuff", "codex@account-a", "copilot", "antigravity", "grok", "opencode"],
            forKey: "openusage.enabledProviders.v1"
        )
        defaults.set(["freebuff", "copilot", "devin", "codex"], forKey: "openusage.providerUserChoiceIDs.v1")
        defaults.set(["grok", "opencode"], forKey: "openusage.pendingProviderCredentialProbeIDs.v1")
        defaults.set(true, forKey: "openusage.firstRunCredentialProbePending.v1")
        defaults.set(12, forKey: "openusage.firstRunCredentialProbeRevision.v1")

        SettingsMigrator.migrate(defaults: defaults, domainName: domain)

        XCTAssertEqual(
            Set(defaults.stringArray(forKey: "openusage.enabledProviders.v1") ?? []),
            ["claude", "cursor", "freebuff", "codex@account-a", "copilot"]
        )
        XCTAssertTrue(defaults.stringArray(forKey: "openusage.pendingProviderCredentialProbeIDs.v1")?.isEmpty ?? false)
        XCTAssertNil(defaults.object(forKey: "openusage.firstRunCredentialProbePending.v1"))
        XCTAssertNil(defaults.object(forKey: "openusage.firstRunCredentialProbeRevision.v1"))

        // An explicit off for a core provider remains off; untouched core defaults keep their current
        // state rather than being enabled by the migration.
        defaults.set(3, forKey: SettingsMigrator.schemaVersionKey)
        defaults.set(["claude", "cursor"], forKey: "openusage.enabledProviders.v1")
        defaults.set(["codex", "freebuff"], forKey: "openusage.providerUserChoiceIDs.v1")
        SettingsMigrator.migrate(defaults: defaults, domainName: domain)
        XCTAssertEqual(Set(defaults.stringArray(forKey: "openusage.enabledProviders.v1") ?? []), ["claude", "cursor"])
    }

    @MainActor
    func testV4AddsFreebuffAndPreservesRegisteredCodexCardsFromLegacyDisabledList() throws {
        let (defaults, domain) = makeDefaults("legacy-codex-cards")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(1, forKey: SettingsMigrator.schemaVersionKey)
        defaults.set(["devin", "codex@account-b"], forKey: "openusage.disabledProviders.v1")
        defaults.set(try JSONSerialization.data(withJSONObject: [
            ["id": "codex@account-a", "family": "codex", "removedTombstone": false],
            ["id": "codex@account-b", "family": "codex", "removedTombstone": false],
            ["id": "codex@removed", "family": "codex", "removedTombstone": true],
            ["id": "claude@account-c", "family": "claude", "removedTombstone": false]
        ]), forKey: "openusage.providerAccounts.v1")

        SettingsMigrator.migrate(defaults: defaults, domainName: domain)

        XCTAssertEqual(
            Set(defaults.stringArray(forKey: "openusage.enabledProviders.v1") ?? []),
            ["claude", "codex", "cursor", "freebuff", "codex@account-a"]
        )
        XCTAssertEqual(
            Set(defaults.stringArray(forKey: "openusage.providerUserChoiceIDs.v1") ?? []),
            ["devin", "codex@account-b"]
        )
    }

    func testV4DoesNotReenableAbsentCoreProvidersWithoutRecordedChoice() {
        let (defaults, domain) = makeDefaults("do-not-reenable-core")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(3, forKey: SettingsMigrator.schemaVersionKey)
        defaults.set(["claude"], forKey: "openusage.enabledProviders.v1")
        defaults.set(["claude", "codex", "cursor"], forKey: "openusage.knownProviders.v1")

        SettingsMigrator.migrate(defaults: defaults, domainName: domain)

        XCTAssertEqual(Set(defaults.stringArray(forKey: "openusage.enabledProviders.v1") ?? []), ["claude", "freebuff"])
    }

    @MainActor
    func testV4RecoversOnlyUnambiguousCodexCardsFromReleasedMigration() throws {
        let (defaults, domain) = makeDefaults("recover-codex-account-cards")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(3, forKey: SettingsMigrator.schemaVersionKey)
        defaults.set(["claude", "codex", "cursor"], forKey: "openusage.enabledProviders.v1")
        defaults.set(SettingsSchema.v2ProviderIDs + SettingsSchema.v3PreviouslyShippedProviderIDs + ["codex@legacy-off"],
                     forKey: "openusage.knownProviders.v1")
        defaults.set(["codex@manual-off"], forKey: "openusage.providerUserChoiceIDs.v1")
        defaults.set(try JSONSerialization.data(withJSONObject: [
            ["id": "codex@lost-enabled", "family": "codex", "removedTombstone": false],
            ["id": "codex@legacy-off", "family": "codex", "removedTombstone": false],
            ["id": "codex@manual-off", "family": "codex", "removedTombstone": false],
            ["id": "codex@removed", "family": "codex", "removedTombstone": true]
        ]), forKey: "openusage.providerAccounts.v1")

        SettingsMigrator.migrate(defaults: defaults, domainName: domain)

        XCTAssertEqual(
            Set(defaults.stringArray(forKey: "openusage.enabledProviders.v1") ?? []),
            ["claude", "codex", "cursor", "freebuff", "codex@lost-enabled"]
        )
    }

    func testV4DoesNotTurnKnownOffFreebuffBackOnOrInferFromUnknownSentinel() {
        for (label, enabled, known, disabled, expected) in [
            ("known-off", ["claude"], ["claude", "codex", "cursor", "freebuff"], [String](), ["claude"]),
            (
                "empty-known", ["claude", "codex", "cursor", "freebuff", "grok"], [String](), [String](),
                ["claude", "codex", "cursor", "freebuff"]
            ),
            ("legacy-disabled", ["claude"], ["claude", "codex", "cursor"], ["freebuff"], ["claude"])
        ] {
            let (defaults, domain) = makeDefaults(label)
            defaults.set(3, forKey: SettingsMigrator.schemaVersionKey)
            defaults.set(enabled, forKey: "openusage.enabledProviders.v1")
            defaults.set(known, forKey: "openusage.knownProviders.v1")
            defaults.set(disabled, forKey: "openusage.disabledProviders.v1")

            SettingsMigrator.migrate(defaults: defaults, domainName: domain)

            XCTAssertEqual(Set(defaults.stringArray(forKey: "openusage.enabledProviders.v1") ?? []), Set(expected), label)
            defaults.removePersistentDomain(forName: domain)
        }
    }

@MainActor
private final class MigrationCredentialProvider: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor] = []
    private(set) var probeCount = 0

    init(_ id: String) {
        provider = Provider(id: id, displayName: id, icon: .providerMark(id))
    }

    func refresh() async -> ProviderSnapshot {
        ProviderSnapshot.make(provider: provider, plan: nil, lines: [], refreshedAt: Date())
    }

    func hasLocalCredentials() async -> Bool {
        probeCount += 1
        return true
    }
}

    // MARK: - Schema integrity

    /// Guards against editing the migration list without bumping `current` (or vice versa): every
    /// migration targets a unique version in `1...current`, and `current` is at least the highest one.
    func testShippedSchemaIsConsistent() {
        let versions = SettingsSchema.migrations.map(\.version)
        XCTAssertEqual(Set(versions).count, versions.count, "migration versions must be unique")
        XCTAssertGreaterThanOrEqual(
            SettingsSchema.current, versions.max() ?? SettingsSchema.current,
            "bump SettingsSchema.current when you add a migration"
        )
        for version in versions {
            XCTAssertGreaterThanOrEqual(version, 1, "schema versions start at 1")
            XCTAssertLessThanOrEqual(version, SettingsSchema.current)
        }
    }

    // MARK: - Helpers

    private static let ranKey = "test.ran"

    private func makeDefaults(_ name: String) -> (UserDefaults, String) {
        let suite = "OpenUsageTests.SettingsMigrator.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    /// A migration that appends its version to a list in `defaults`, so a test can assert exactly which
    /// steps ran and in what order.
    private func recordingStep(_ version: Int) -> SettingsMigration {
        SettingsMigration(version: version) { defaults in
            var ran = defaults.array(forKey: Self.ranKey) as? [Int] ?? []
            ran.append(version)
            defaults.set(ran, forKey: Self.ranKey)
        }
    }

    private func recording(_ versions: Int...) -> [SettingsMigration] {
        versions.map(recordingStep)
    }

    /// A migration that always throws, to exercise the stop-and-resume path.
    private func failingStep(_ version: Int) -> SettingsMigration {
        SettingsMigration(version: version) { _ in throw MigrationTestError.boom }
    }

    /// The recorded run order, or `nil` if no step ran.
    private func ranVersions(_ defaults: UserDefaults) -> [Int]? {
        defaults.array(forKey: Self.ranKey) as? [Int]
    }

    private enum MigrationTestError: Error { case boom }
}
