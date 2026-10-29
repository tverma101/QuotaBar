import Foundation
import Observation

/// Shared persisted defaults and crash-recovery for provider selection. A single pending intent lets
/// launch finish a user toggle if the process exits between its enabled-list and choice-marker writes.
enum ProviderEnablementPersistence {
    static let initiallyEnabledProviderIDs: Set<String> = ["claude", "codex", "cursor", "freebuff"]
    static let firstRunSeedPendingKey = "openusage.firstRunProviderSeedPending.v1"
    static let pendingChoiceIntentKey = "openusage.pendingProviderChoiceIntent.v1"
    static let pendingResetIntentKey = "openusage.pendingProviderResetIntent.v1"

    private static let enabledStorageKey = "openusage.enabledProviders.v1"
    private static let disabledStorageKey = "openusage.disabledProviders.v1"
    private static let userChoiceRevisionKey = "openusage.providerUserChoiceRevision.v1"
    private static let userChoiceProviderIDsKey = "openusage.providerUserChoiceIDs.v1"

    static func writePendingResetIntent(enabledProviderIDs: Set<String>, defaults: UserDefaults) {
        defaults.set(enabledProviderIDs.sorted(), forKey: pendingResetIntentKey)
    }

    /// Reset All spans several defaults keys. Replay its target set and choice-history clear before
    /// either migrations or stores read the domain after an interrupted reset.
    static func recoverPendingResetIntent(defaults: UserDefaults) {
        guard defaults.object(forKey: pendingResetIntentKey) != nil else { return }
        guard let rawIDs = defaults.stringArray(forKey: pendingResetIntentKey) else {
            let priorEnabled = Set(defaults.stringArray(forKey: enabledStorageKey) ?? [])
            let safeDefaults = initiallyEnabledProviderIDs.union(
                priorEnabled.filter { $0.hasPrefix("codex@") }
            )
            defaults.set(safeDefaults.sorted(), forKey: enabledStorageKey)
            defaults.set([String](), forKey: userChoiceProviderIDsKey)
            defaults.removeObject(forKey: disabledStorageKey)
            defaults.removeObject(forKey: pendingChoiceIntentKey)
            defaults.removeObject(forKey: pendingResetIntentKey)
            AppLog.error(.config, "malformed provider-reset intent; restored core and registered Codex defaults")
            return
        }
        defaults.set(Array(Set(rawIDs)).sorted(), forKey: enabledStorageKey)
        defaults.set([String](), forKey: userChoiceProviderIDsKey)
        defaults.removeObject(forKey: disabledStorageKey)
        // Reset supersedes any earlier toggle that was only half-persisted.
        defaults.removeObject(forKey: pendingChoiceIntentKey)
        defaults.removeObject(forKey: pendingResetIntentKey)
        AppLog.info(.config, "recovered interrupted provider reset")
    }

    static func writePendingChoiceIntent(
        providerID: String,
        enabled: Bool,
        revision: UInt64,
        defaults: UserDefaults
    ) {
        defaults.set(
            ["providerID": providerID, "enabled": enabled, "revision": NSNumber(value: revision)],
            forKey: pendingChoiceIntentKey
        )
    }

    /// Replays a choice before migrations and stores load, so a crash during a manual enable cannot make
    /// schema migration mistake that provider for an old credential-detected card.
    static func recoverPendingChoiceIntent(defaults: UserDefaults) {
        guard let intent = defaults.dictionary(forKey: pendingChoiceIntentKey) else { return }
        guard let providerID = intent["providerID"] as? String, !providerID.isEmpty,
              let enabledNumber = intent["enabled"] as? NSNumber
        else {
            AppLog.error(.config, "discarding malformed pending provider-choice intent")
            defaults.removeObject(forKey: pendingChoiceIntentKey)
            return
        }
        let enabled = enabledNumber.boolValue

        if defaults.array(forKey: enabledStorageKey) != nil {
            var enabledIDs = Set(defaults.stringArray(forKey: enabledStorageKey) ?? [])
            if enabled { enabledIDs.insert(providerID) } else { enabledIDs.remove(providerID) }
            defaults.set(enabledIDs.sorted(), forKey: enabledStorageKey)
        } else {
            var disabledIDs = Set(defaults.stringArray(forKey: disabledStorageKey) ?? [])
            if enabled { disabledIDs.remove(providerID) } else { disabledIDs.insert(providerID) }
            defaults.set(disabledIDs.sorted(), forKey: disabledStorageKey)
        }

        var choices = Set(defaults.stringArray(forKey: userChoiceProviderIDsKey) ?? [])
        choices.insert(providerID)
        defaults.set(choices.sorted(), forKey: userChoiceProviderIDsKey)

        let currentRevision = (defaults.object(forKey: userChoiceRevisionKey) as? NSNumber)?.uint64Value ?? 0
        let intendedRevision = (intent["revision"] as? NSNumber)?.uint64Value ?? (currentRevision &+ 1)
        if intendedRevision > currentRevision {
            defaults.set(intendedRevision, forKey: userChoiceRevisionKey)
        }
        defaults.removeObject(forKey: pendingChoiceIntentKey)
        AppLog.info(.config, "recovered interrupted provider choice for \(providerID)")
    }
}

/// The single source of truth for which providers are turned on.
///
/// Two storage modes, distinguished by which key exists:
/// - **Legacy disabled-list** (`openusage.disabledProviders.v1`): only the *disabled* IDs are persisted.
///   "Everything on" is an empty set, so a provider shipped in a future release defaults to enabled.
///   Since the v2 settings migration converted every install to enabled-list mode, this branch is a
///   dormant read path kept for downgrade safety only.
/// - **Enabled-list** (`openusage.enabledProviders.v1`): only the *enabled* IDs are persisted. Fresh
///   installs are seeded into this mode (see `FirstRunSeeder`) with the owner-selected defaults;
///   existing installs were migrated into it (settings schema v2 and later).
///
/// When the enabled-list key exists it wins; the legacy key is ignored.
///
/// A third set — **known provider IDs** (`openusage.knownProviders.v1`) — records every provider this
/// install has ever seen. `NewProviderSeeder` records newly shipped providers here while leaving them
/// off; provider selection is manual and does not depend on whether credentials exist locally.
@MainActor
@Observable
final class ProviderEnablementStore {
    private static let disabledStorageKey = "openusage.disabledProviders.v1"
    private static let enabledStorageKey = "openusage.enabledProviders.v1"
    private static let knownStorageKey = "openusage.knownProviders.v1"
    private static let userChoiceRevisionKey = "openusage.providerUserChoiceRevision.v1"
    private static let userChoiceProviderIDsKey = "openusage.providerUserChoiceIDs.v1"
    private static let firstRunProbePendingKey = "openusage.firstRunCredentialProbePending.v1"
    private static let firstRunProbeRevisionKey = "openusage.firstRunCredentialProbeRevision.v1"
    private static let pendingProviderProbeIDsKey = "openusage.pendingProviderCredentialProbeIDs.v1"

    /// Posted when the enabled-provider set actually changes. The refresh loop listens for this to wake
    /// early and fetch a newly-enabled provider promptly, instead of waiting out the full interval —
    /// WITHOUT subscribing to the firehose `UserDefaults.didChangeNotification`, which also fires for the
    /// app's own snapshot-cache writes, and unrelated global-domain changes
    /// from other processes. Waking on that (with no minimum interval) collapsed the bounded periodic
    /// cadence into a refresh storm.
    ///
    /// `nonisolated` so the refresh loop's background task can name it without hopping to the main actor
    /// (it's an immutable, `Sendable` constant — like Foundation's own notification names).
    nonisolated static let didChangeNotification = Notification.Name("ProviderEnablementDidChange")

    /// Called with a provider's id the moment it turns ON (not on disable, not on a no-op re-set).
    /// `AppContainer` wires this to clear that provider's failure backoff, so the enablement wake's
    /// refresh actually probes it instead of being suppressed by a backoff left over from a failure
    /// just before it was turned off.
    var onProviderEnabled: (@MainActor (String) -> Void)?
    /// Called after any real enablement-set change. iCloud history rewrites its one machine document so
    /// disabling a provider removes its stale contribution as promptly as enabling adds it.
    var onChange: (@MainActor (Set<String>) -> Void)?

    /// Legacy-mode state: the providers the user turned off. Unused (empty) in enabled-list mode.
    private(set) var disabledIDs: Set<String>
    /// Enabled-list-mode state; `nil` means legacy disabled-list mode.
    private(set) var enabledIDs: Set<String>?
    /// Every provider ID this install has ever seen (see the type comment). Seeded by the v2 settings
    /// migration or `FirstRunSeeder`, then grown by `registerKnownProviders`.
    private(set) var knownIDs: Set<String>
    /// Provider IDs the user has explicitly toggled. The v4 migration uses this to preserve manually
    /// selected provider states while removing cards older versions enabled through credential probes.
    private(set) var userChoiceProviderIDs: Set<String>
    /// Legacy revision from v3's asynchronous first-run detection; retained only to clear old pending
    /// probe state after upgrades.
    private(set) var persistentUserChoiceRevision: UInt64
    /// Legacy pending-probe state from versions that automatically enabled detected providers. Current
    /// seeders clear these markers and never start new credential probes.
    private(set) var firstRunCredentialProbeRevision: UInt64?
    private(set) var pendingProviderCredentialProbeIDs: Set<String>
    private let defaults: UserDefaults
    /// In-memory revisions distinguish a final user choice from the store merely returning to the
    /// same enabled set while an asynchronous credential probe is running.
    private var userChoiceRevisions: [String: UInt64] = [:]

    init(defaults: UserDefaults = .standard) {
        ProviderEnablementPersistence.recoverPendingResetIntent(defaults: defaults)
        ProviderEnablementPersistence.recoverPendingChoiceIntent(defaults: defaults)
        self.defaults = defaults
        if let enabled = defaults.stringArray(forKey: Self.enabledStorageKey) {
            self.enabledIDs = Set(enabled)
            self.disabledIDs = []
        } else {
            self.enabledIDs = nil
            self.disabledIDs = Set(defaults.stringArray(forKey: Self.disabledStorageKey) ?? [])
        }
        self.knownIDs = Set(defaults.stringArray(forKey: Self.knownStorageKey) ?? [])
        self.userChoiceProviderIDs = Set(defaults.stringArray(forKey: Self.userChoiceProviderIDsKey) ?? [])
        self.persistentUserChoiceRevision = (defaults.object(forKey: Self.userChoiceRevisionKey) as? NSNumber)?.uint64Value ?? 0
        self.firstRunCredentialProbeRevision = (defaults.object(forKey: Self.firstRunProbeRevisionKey) as? NSNumber)?.uint64Value
        self.pendingProviderCredentialProbeIDs = Set(
            defaults.stringArray(forKey: Self.pendingProviderProbeIDsKey) ?? []
        )
    }

    func isEnabled(_ id: String) -> Bool {
        if let enabledIDs { return enabledIDs.contains(id) }
        if defaults.bool(forKey: ProviderEnablementPersistence.firstRunSeedPendingKey) {
            return ProviderEnablementPersistence.initiallyEnabledProviderIDs.contains(id)
        }
        return !disabledIDs.contains(id)
    }

    func hasEnabledProviderFamily(_ family: String) -> Bool {
        let known = knownIDs.union(enabledIDs ?? []).union(disabledIDs)
        let familyIDs = known.filter { ProviderAccountID.family(of: $0) == family }
        guard !familyIDs.isEmpty else { return isEnabled(family) }
        return familyIDs.contains(where: isEnabled)
    }

    var hasPendingFirstRunSeed: Bool {
        defaults.bool(forKey: ProviderEnablementPersistence.firstRunSeedPendingKey)
    }

    func beginFirstRunSeed() {
        defaults.set(true, forKey: ProviderEnablementPersistence.firstRunSeedPendingKey)
    }

    func completeFirstRunSeed() {
        defaults.removeObject(forKey: ProviderEnablementPersistence.firstRunSeedPendingKey)
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        updateEnabled(enabled, for: id, recordsUserChoice: true)
    }

    /// Reset All is an explicit request to discard provider-toggle history as well as the current set.
    /// Without clearing it, an off choice for an account absent from the live catalog could survive
    /// reset and silently block the default-on behavior when that same stable Codex identity returns.
    func clearUserChoiceHistory() {
        guard !userChoiceProviderIDs.isEmpty else { return }
        userChoiceProviderIDs.removeAll()
        defaults.set([String](), forKey: Self.userChoiceProviderIDsKey)
    }

    /// Apply Reset All with a write-ahead intent so a crash cannot leave the old optional-on set paired
    /// with cleared choice markers. The migration and store initializer replay this target on launch.
    func resetProviderChoices(to enabledProviderIDs: Set<String>) {
        ProviderEnablementPersistence.writePendingResetIntent(
            enabledProviderIDs: enabledProviderIDs,
            defaults: defaults
        )
        clearUserChoiceHistory()
        seedEnabledProviders(enabledProviderIDs)
        defaults.removeObject(forKey: ProviderEnablementPersistence.pendingResetIntentKey)
    }

    /// An account card discovered immediately after the user completes QuotaBar's explicit Codex
    /// registration flow is part of that requested action, not a newly installed optional provider.
    /// Enable only newly added `codex@…` identities; older disabled account cards and optional provider
    /// families keep their saved state.
    func enableNewlyRegisteredCodexAccounts(
        discoveredIDs: Set<String>,
        previouslyDiscoveredIDs: Set<String>
    ) {
        for id in discoveredIDs.subtracting(previouslyDiscoveredIDs).sorted() where id.hasPrefix("codex@") {
            // The identity is stable across unregister/re-register cycles. Preserve a saved explicit
            // off choice even if the account was absent from the catalog during this process lifetime.
            if userChoiceProviderIDs.contains(id), !isEnabled(id) { continue }
            setEnabled(true, for: id)
        }
    }

    /// Preserve an explicit enable of the generic Claude card when a catalog reload replaces that
    /// fallback with account-scoped cards. The first card is the assembly's preferred account. Keep
    /// any explicit off choice for that account intact; this transfer is continuity for the family
    /// toggle and does not create a separate account-level user choice.
    @discardableResult
    func transferExplicitGenericClaudeEnablement(to accountIDs: [String]) -> String? {
        guard userChoiceProviderIDs.contains("claude"), isEnabled("claude"),
              let accountID = accountIDs.first
        else { return nil }
        return transferEnabledGenericClaudeFamily(to: [accountID])
    }

    /// Carry an enabled family-level default onto the preferred scoped Claude card when registry
    /// history occupies the bare `claude` ID with a tombstone. An explicit account-level off choice
    /// still wins, and the family default is not recorded as an account toggle. Retire the stale
    /// family ID so it cannot keep Claude effectively enabled after the scoped card is turned off.
    @discardableResult
    func transferEnabledGenericClaudeFamily(to accountIDs: [String]) -> String? {
        guard isEnabled("claude"), let accountID = accountIDs.first else { return nil }
        let accountIsExplicitlyOff = userChoiceProviderIDs.contains(accountID) && !isEnabled(accountID)
        if !accountIsExplicitlyOff {
            enableDetectedProvider(accountID)
        }
        disableDetectedProvider("claude")
        return accountIsExplicitlyOff ? nil : accountID
    }

    /// Revisions captured before an async seed probe. No-op toggles do not advance the revision.
    func userChoiceRevisionsSnapshot(for ids: Set<String>) -> [String: UInt64] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, userChoiceRevisions[$0, default: 0]) })
    }

    func userChangedChoices(since revisions: [String: UInt64]) -> Bool {
        revisions.contains { userChoiceRevisions[$0.key, default: 0] != $0.value }
    }

    /// Apply a detected new-provider default without treating it as a manual user toggle.
    func enableDetectedProvider(_ id: String) {
        updateEnabled(true, for: id, recordsUserChoice: false)
    }

    /// Remove a stale family-level default after that family has moved to an account-scoped ID.
    /// This is bookkeeping continuity, not a new user choice.
    func disableDetectedProvider(_ id: String) {
        updateEnabled(false, for: id, recordsUserChoice: false)
    }

    private func updateEnabled(_ enabled: Bool, for id: String, recordsUserChoice: Bool) {
        let nextPersistentChoiceRevision = recordsUserChoice ? persistentUserChoiceRevision &+ 1 : nil
        if var ids = enabledIDs {
            if enabled { ids.insert(id) } else { ids.remove(id) }
            // A no-op toggle (re-setting the same value) shouldn't persist or wake the refresh loop.
            guard ids != enabledIDs else { return }
            if let nextPersistentChoiceRevision {
                ProviderEnablementPersistence.writePendingChoiceIntent(
                    providerID: id,
                    enabled: enabled,
                    revision: nextPersistentChoiceRevision,
                    defaults: defaults
                )
            }
            enabledIDs = ids
            defaults.set(ids.sorted(), forKey: Self.enabledStorageKey)
        } else {
            let before = disabledIDs
            if enabled {
                disabledIDs.remove(id)
            } else {
                disabledIDs.insert(id)
            }
            guard disabledIDs != before else { return }
            if let nextPersistentChoiceRevision {
                ProviderEnablementPersistence.writePendingChoiceIntent(
                    providerID: id,
                    enabled: enabled,
                    revision: nextPersistentChoiceRevision,
                    defaults: defaults
                )
            }
            defaults.set(disabledIDs.sorted(), forKey: Self.disabledStorageKey)
        }
        if recordsUserChoice {
            userChoiceRevisions[id, default: 0] &+= 1
            persistentUserChoiceRevision = nextPersistentChoiceRevision ?? persistentUserChoiceRevision
            userChoiceProviderIDs.insert(id)
            defaults.set(persistentUserChoiceRevision, forKey: Self.userChoiceRevisionKey)
            defaults.set(userChoiceProviderIDs.sorted(), forKey: Self.userChoiceProviderIDsKey)
            defaults.removeObject(forKey: ProviderEnablementPersistence.pendingChoiceIntentKey)
        }
        // Clear the backoff BEFORE the wake notification, so the refresh it triggers actually probes the
        // just-enabled provider instead of skipping it as recently-failed.
        if enabled { onProviderEnabled?(id) }
        onChange?([id])
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// Switches the store into enabled-list mode with exactly `ids` on. Used by first-run and Reset All
    /// to apply the stable defaults synchronously. Fires `onProviderEnabled` for each newly-on provider
    /// and posts the change notification, so the refresh loop fetches them promptly.
    /// Records `ids` as seen and returns the ones that were new. Pure bookkeeping: no enablement
    /// change or notification — `NewProviderSeeder` leaves new providers off for manual selection.
    @discardableResult
    func registerKnownProviders(_ ids: Set<String>) -> Set<String> {
        let new = ids.subtracting(knownIDs)
        guard !new.isEmpty else { return [] }
        knownIDs.formUnion(new)
        defaults.set(Array(knownIDs), forKey: Self.knownStorageKey)
        return new
    }

    /// Legacy v3 state only. Current first-run setup is synchronous and does not start credential probes.
    func beginFirstRunCredentialProbe() {
        firstRunCredentialProbeRevision = persistentUserChoiceRevision
        defaults.set(true, forKey: Self.firstRunProbePendingKey)
        defaults.set(persistentUserChoiceRevision, forKey: Self.firstRunProbeRevisionKey)
    }

    var hasPendingFirstRunCredentialProbe: Bool {
        defaults.bool(forKey: Self.firstRunProbePendingKey)
    }

    func completeFirstRunCredentialProbe() {
        firstRunCredentialProbeRevision = nil
        defaults.removeObject(forKey: Self.firstRunProbePendingKey)
        defaults.removeObject(forKey: Self.firstRunProbeRevisionKey)
    }

    /// Legacy v3 state only. Kept so migration tests can construct an interrupted probe; current
    /// `NewProviderSeeder` registers providers directly and never schedules credential detection.
    @discardableResult
    func registerProvidersForCredentialProbe(_ ids: Set<String>) -> Set<String> {
        let newlyKnown = ids.subtracting(knownIDs)
        if !newlyKnown.isEmpty {
            knownIDs.formUnion(newlyKnown)
            defaults.set(Array(knownIDs), forKey: Self.knownStorageKey)
            pendingProviderCredentialProbeIDs.formUnion(newlyKnown)
            defaults.set(Array(pendingProviderCredentialProbeIDs), forKey: Self.pendingProviderProbeIDsKey)
        }
        return newlyKnown
    }

    func completeProviderCredentialProbes(for ids: Set<String>) {
        pendingProviderCredentialProbeIDs.subtract(ids)
        defaults.set(Array(pendingProviderCredentialProbeIDs), forKey: Self.pendingProviderProbeIDsKey)
    }

    func seedEnabledProviders(_ ids: Set<String>) {
        let previouslyEnabled = enabledIDs ?? knownIDs.subtracting(disabledIDs)
        let changedIDs = previouslyEnabled.symmetricDifference(ids)
        let newlyEnabled = ids.filter { !isEnabled($0) }
        let changed = enabledIDs != ids
        enabledIDs = ids
        disabledIDs = []
        defaults.set(Array(ids), forKey: Self.enabledStorageKey)
        guard changed else { return }
        for id in newlyEnabled.sorted() { onProviderEnabled?(id) }
        onChange?(changedIDs)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
