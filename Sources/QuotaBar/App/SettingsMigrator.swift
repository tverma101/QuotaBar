import Foundation

/// The v2 conversion only needs these fields from the account registry. Keep this decoder tolerant of
/// fields added by the live provider-account model so a schema migration does not depend on that type.
private struct LegacyProviderAccountRecord: Decodable {
    let id: String
    let family: String
    let removedTombstone: Bool?
}

/// One ordered step that brings persisted settings from schema version `version - 1` up to `version`.
/// A step is a pure transform over a `UserDefaults` domain — rename a key, seed a new default, drop a
/// dead one. Keep it idempotent: an interrupted upgrade may re-run the same step on the next launch.
struct SettingsMigration: Sendable {
    /// The schema version this step produces. Versions are whole numbers counting up (1, 2, 3, …) and
    /// are independent of the app's marketing version — they change only when a *setting's shape* does.
    let version: Int
    /// Applies the change to `defaults`. Throw to abort the cascade: the engine stops, keeps the version
    /// at the last success, and retries from there on the next launch.
    let migrate: @Sendable (UserDefaults) throws -> Void
}

/// The settings schema: its current version and the ordered migrations that build up to it. This enum is
/// the ONLY thing to edit when a setting changes shape — append a `SettingsMigration` and bump `current`
/// to match. The engine (`SettingsMigrator`) never needs to change.
enum SettingsSchema {
    /// Current schema version. Keep equal to the highest migration `version` below (or the baseline when
    /// there are none). This is NOT the app version — bump it only alongside a migration you add.
    static let current = 4

    /// The provider IDs that existed when the v2 migration shipped, frozen forever. A migration is a
    /// point-in-time transform: any future build with more providers also contains this migration, so a
    /// legacy install jumping several versions is first converted with this exact list, and
    /// `NewProviderSeeder` then picks up everything added afterwards as new. Never edit this list.
    static let v2ProviderIDs = [
        "antigravity", "claude", "codex", "copilot", "cursor", "devin", "grok", "openrouter", "zai"
    ]

    /// Providers that were already in the registry when v2 shipped but were accidentally omitted from
    /// its frozen provider list. The legacy disabled-list conversion must still treat them as enabled
    /// unless explicitly disabled; v3 also marks them known so provider discovery preserves old choices.
    static let v3PreviouslyShippedProviderIDs = ["hermes", "opencode"]

    /// Provider cards the owner chose to keep on by default. Keep provider IDs frozen by migration
    /// version; Codex account IDs are carried forward separately from the existing enabled set.
    static let v4DefaultOnProviderIDs = ["claude", "codex", "cursor", "freebuff"]

    /// Ordered migrations, each taking the domain one version higher. v1 is the baseline — the settings
    /// shape at the moment this system replaced the beta-era "wipe on every update" behavior — so it
    /// needs no transform. Migrations reference storage keys as string literals on purpose: they are
    /// frozen transforms and must keep working even if a store renames its key constant later.
    static let migrations: [SettingsMigration] = [
        // v2 unifies every install onto enabled-list mode (see `ProviderEnablementStore`) and records
        // which providers the install has seen (`NewProviderSeeder` registers newly shipped providers):
        // - legacy disabled-list installs convert to the equivalent enabled list (behavior-preserving:
        //   the effective on/off set is identical before and after),
        // - every install gets the known-provider set seeded with the providers of this era, so nothing
        //   already shipped is retroactively treated as "new"; registered Codex accounts and legacy
        //   explicit off choices are carried forward too.
        SettingsMigration(version: 2) { defaults in
            let legacyDisabledKey = "openusage.disabledProviders.v1"
            let legacyDisabled = Set(defaults.stringArray(forKey: legacyDisabledKey) ?? [])
            let hasLegacyDisabledList = defaults.object(forKey: legacyDisabledKey) != nil
            let existingEnabledList = defaults.stringArray(forKey: "openusage.enabledProviders.v1")
            let existingKnownList = defaults.stringArray(forKey: "openusage.knownProviders.v1")
            // A previously shipped v2 could stop after writing enabledProviders but before removing
            // disabledProviders. On retry, the enabled key makes the conversion branch below skip;
            // persist the still-present explicit off choices first so v4 defaults cannot revive them.
            if !legacyDisabled.isEmpty {
                var choices = Set(defaults.stringArray(forKey: "openusage.providerUserChoiceIDs.v1") ?? [])
                choices.formUnion(legacyDisabled)
                defaults.set(choices.sorted(), forKey: "openusage.providerUserChoiceIDs.v1")
            }
            if existingEnabledList == nil {
                let legacyShippedIDs = Set(v2ProviderIDs).union(v3PreviouslyShippedProviderIDs)
                let registeredCodexIDs = registeredCodexAccountIDs(in: defaults)
                var enabled = legacyShippedIDs
                    .union(registeredCodexIDs)
                    .subtracting(legacyDisabled)
                // The legacy disabled-list format meant every omitted provider was on. Freebuff was
                // absent from the frozen v2 list; providerUserChoiceIDs records that a toggle happened,
                // not its direction, so only the legacy disabled list distinguishes explicit off from
                // a user who toggled Freebuff off and later turned it back on.
                if !legacyDisabled.contains("freebuff") { enabled.insert("freebuff") }

                defaults.set(enabled.sorted(), forKey: "openusage.enabledProviders.v1")
            } else if hasLegacyDisabledList {
                // The surviving disabled-list key proves this was the old "everything on except
                // disabled IDs" mode, even if enabledProviders had already been written by an
                // interrupted conversion. Recover registered Codex cards omitted by the released
                // conversion, while respecting both legacy and already-recorded off choices.
                var enabled = Set(existingEnabledList ?? [])
                // In this mode the surviving disabled list is directional source of truth. The released
                // converter could omit a manually re-enabled Codex card, while userChoiceIDs remembers
                // only that it was toggled, not its direction.
                let explicitlyOff = legacyDisabled
                enabled.formUnion(
                    registeredCodexAccountIDs(in: defaults).subtracting(explicitlyOff)
                )
                // Freebuff was absent from the frozen v2 list, so carry its implicit-on state
                // forward unless the persisted evidence says it was explicitly disabled.
                if !explicitlyOff.contains("freebuff") { enabled.insert("freebuff") }
                defaults.set(enabled.sorted(), forKey: "openusage.enabledProviders.v1")
            }
            // Enabled-list installs predate provider tracking. Their empty or missing known-list is
            // an intentional ambiguity sentinel: NewProviderSeeder baselines the live registry and
            // leaves its enablement untouched.
            // Only legacy disabled-list installs have enough information to safely seed v2's set.
            if existingEnabledList == nil || !(existingKnownList ?? []).isEmpty {
                var known = Set(existingKnownList ?? [])
                known.formUnion(v2ProviderIDs)
                known.formUnion(registeredCodexAccountIDs(in: defaults))
                known.formUnion(legacyDisabled)
                defaults.set(known.sorted(), forKey: "openusage.knownProviders.v1")
            } else {
                defaults.set([String](), forKey: "openusage.knownProviders.v1")
            }
            // The old key can remain after an interrupted conversion with enabled-list mode already
            // written. Its off state now has durable user-choice markers above, so complete cleanup.
            defaults.removeObject(forKey: "openusage.disabledProviders.v1")
        },
        // v2's frozen list omitted OpenCode and Hermes even though both were already shipped. Repair
        // the known set for installs with provider tracking while preserving the enabled set.
        SettingsMigration(version: 3) { defaults in
            var known = Set(defaults.stringArray(forKey: "openusage.knownProviders.v1") ?? [])
            // An empty/missing known set is a deliberate legacy sentinel: NewProviderSeeder then
            // baselines the current registry without credential probes because old enabled-list
            // installs cannot distinguish "user turned it off" from "not tracked yet". Do not make
            // that ambiguous state look partially known by inserting only these two IDs.
            if !known.isEmpty {
                known.formUnion(v3PreviouslyShippedProviderIDs)
                defaults.set(known.sorted(), forKey: "openusage.knownProviders.v1")
            }
        },
        // Provider activation is now manual for optional providers. Preserve explicit choices, core
        // defaults already on, and enabled Codex accounts; make Freebuff the default unless explicitly
        // off. Turn off optional cards older versions enabled only because a local credential probe hit.
        // Discard old in-flight probes so they cannot undo the new policy after launch.
        SettingsMigration(version: 4) { defaults in
            let enabled = Set(defaults.stringArray(forKey: "openusage.enabledProviders.v1") ?? [])
            let userChoices = Set(defaults.stringArray(forKey: "openusage.providerUserChoiceIDs.v1") ?? [])
            let known = Set(defaults.stringArray(forKey: "openusage.knownProviders.v1") ?? [])
            let legacyDisabled = Set(defaults.stringArray(forKey: "openusage.disabledProviders.v1") ?? [])
            let defaultIDs = Set(v4DefaultOnProviderIDs)
            let codexAccounts = Set(enabled.filter { $0.hasPrefix("codex@") })
            var retained = enabled.intersection(userChoices.union(defaultIDs).union(codexAccounts))
            // Released v2 could drop registered Codex account IDs while converting the old
            // disabled-list format. Recover only IDs that were never recorded as known/off; an empty
            // known set is an ambiguity sentinel, so it is not evidence that those accounts were on.
            if !known.isEmpty {
                let unambiguousCodexAccounts = registeredCodexAccountIDs(in: defaults)
                    .subtracting(enabled)
                    .subtracting(known)
                    .subtracting(userChoices)
                    .subtracting(legacyDisabled)
                retained.formUnion(unambiguousCodexAccounts)
            }
            // Freebuff became a default after the older enabled-list model shipped. Add it only when
            // tracking proves this install had not seen or explicitly disabled it before. Never infer
            // a default from an empty/missing known set.
            if !known.isEmpty, !enabled.contains("freebuff"), !known.contains("freebuff"),
               !userChoices.contains("freebuff"), !legacyDisabled.contains("freebuff") {
                retained.insert("freebuff")
            }
            defaults.set(retained.sorted(), forKey: "openusage.enabledProviders.v1")
            defaults.set([String](), forKey: "openusage.pendingProviderCredentialProbeIDs.v1")
            defaults.removeObject(forKey: "openusage.firstRunCredentialProbePending.v1")
            defaults.removeObject(forKey: "openusage.firstRunCredentialProbeRevision.v1")
        }
    ]

    private static func registeredCodexAccountIDs(in defaults: UserDefaults) -> Set<String> {
        guard let data = defaults.data(forKey: "openusage.providerAccounts.v1"),
              let records = try? JSONDecoder().decode([LegacyProviderAccountRecord].self, from: data)
        else { return [] }
        return Set(records.compactMap { record in
            guard record.family == "codex", record.removedTombstone != true,
                  record.id.hasPrefix("codex@")
            else { return nil }
            return record.id
        })
    }
}

/// Versioned, cascading settings migration — the replacement for the beta-era domain wipe. Runs once at
/// launch, BEFORE any store reads `UserDefaults`, so migrated values are already in place when stores
/// load and a true fresh install can still be told apart from an upgrade (its domain is empty).
///
/// The stored schema version (`schemaVersionKey`, an integer) drives everything:
///   - **Existing install:** run every migration whose `version` is above the stored one, in ascending
///     order, persisting the new version after EACH step — so an interrupted or failed upgrade resumes
///     where it left off next launch instead of replaying completed steps.
///   - **Fresh install:** persist a safe provider seed plus a resumable marker, stamp `current`, and run
///     no historical migrations; `FirstRunSeeder` completes account-aware defaults after discovery.
///   - **Legacy install (predates this key):** treated as version 0 and migrated forward from there.
///
/// Crucially there is NO wipe: an app-version change never discards settings. (The old reset silently
/// cleared unrelated preferences that happened to live in the same domain.)
enum SettingsMigrator {
    /// Where the applied schema version is recorded, in the same standard domain as the settings it
    /// guards. Integer; absent means "never migrated" — a fresh or legacy install, disambiguated at runtime.
    static let schemaVersionKey = "quotabar.settings.schemaVersion"

    /// Bring the domain up to `current`. Returns the resulting schema version (for logging and tests).
    @discardableResult
    static func migrate(
        defaults: UserDefaults = .standard,
        domainName: String = Bundle.main.bundleIdentifier ?? "",
        current: Int = SettingsSchema.current,
        migrations: [SettingsMigration] = SettingsSchema.migrations
    ) -> Int {
        ProviderEnablementPersistence.recoverPendingResetIntent(defaults: defaults)
        ProviderEnablementPersistence.recoverPendingChoiceIntent(defaults: defaults)
        var version: Int
        if let stored = defaults.object(forKey: schemaVersionKey) as? Int {
            version = stored
        } else if isFreshInstall(defaults: defaults, domainName: domainName) {
            // A crash between stamping the schema and constructing AppContainer must not turn this
            // empty install into legacy "everything on" mode. Keep a resumable seed marker and seed
            // the known safe set before publishing the schema stamp.
            defaults.set(true, forKey: ProviderEnablementPersistence.firstRunSeedPendingKey)
            defaults.set(
                ProviderEnablementPersistence.initiallyEnabledProviderIDs.sorted(),
                forKey: "openusage.enabledProviders.v1"
            )
            defaults.set(current, forKey: schemaVersionKey)
            AppLog.info(.config, "fresh install — settings schema stamped at v\(current)")
            return current
        } else {
            version = 0
            AppLog.info(.config, "legacy settings (no schema version) — migrating forward from v0")
        }

        // Already current, or a downgrade (ran a newer build before): leave the recorded version as-is
        // and never re-apply old migrations backward.
        guard version < current else { return version }

        for step in migrations.sorted(by: { $0.version < $1.version })
        where step.version > version && step.version <= current {
            do {
                try step.migrate(defaults)
            } catch {
                AppLog.warn(.config, "settings migration to v\(step.version) failed: \(error.localizedDescription) — will retry next launch")
                return version  // keep the last success; resume here next launch
            }
            version = step.version
            defaults.set(version, forKey: schemaVersionKey)  // persist after EACH step (resumable cascade)
            AppLog.info(.config, "migrated settings to schema v\(version)")
        }

        // Record reaching `current` even when the highest migration is below it (a version bump that
        // needed no data change), so the cascade isn't re-evaluated on every launch.
        if version < current {
            version = current
            defaults.set(current, forKey: schemaVersionKey)
        }
        return version
    }

    /// A genuine first launch has nothing persisted yet. The migrator runs before any store writes
    /// defaults, so an empty domain means fresh; existing keys with no schema version mean a legacy
    /// install to migrate forward. An empty `domainName` (unbundled `swift run`) has no domain to
    /// inspect — treat it as fresh, since there is nothing to migrate.
    ///
    /// Internal (not just the migrator's own check) because `AppDelegate` reads it BEFORE calling
    /// `migrate()` — stamping the schema version makes the domain non-empty, so the answer must be
    /// captured first. `FirstRunSeeder` keys off it to seed a fresh install's enabled providers.
    static func isFreshInstall(
        defaults: UserDefaults = .standard,
        domainName: String = Bundle.main.bundleIdentifier ?? ""
    ) -> Bool {
        guard !domainName.isEmpty else { return true }
        return (defaults.persistentDomain(forName: domainName) ?? [:]).isEmpty
    }
}
