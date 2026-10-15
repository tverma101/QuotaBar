import Foundation
import Observation

/// The single source of truth for which providers are turned on.
///
/// Two storage modes, distinguished by which key exists:
/// - **Legacy disabled-list** (`openusage.disabledProviders.v1`): only the *disabled* IDs are persisted.
///   "Everything on" is an empty set, so a provider shipped in a future release defaults to enabled.
///   Since the v2 settings migration converted every install to enabled-list mode, this branch is a
///   dormant read path kept for downgrade safety only.
/// - **Enabled-list** (`openusage.enabledProviders.v1`): only the *enabled* IDs are persisted. Fresh
///   installs are seeded into this mode (see `FirstRunSeeder`) with just the providers detected on the
///   machine; existing installs were migrated into it (settings schema v2).
///
/// When the enabled-list key exists it wins; the legacy key is ignored.
///
/// A third set — **known provider IDs** (`openusage.knownProviders.v1`) — records every provider this
/// install has ever seen. In enabled-list mode "absent from the enabled set" is ambiguous (deliberately
/// turned off, or didn't exist yet?); the known set resolves it. `NewProviderSeeder` diffs the registry
/// against it each launch and credential-probes only the never-seen providers, so a user's choice to
/// keep a known provider off is never overridden.
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
    /// Provider IDs the user has explicitly toggled. Persisted so an interrupted first-launch probe
    /// cannot auto-enable a provider the user intentionally left off before quitting.
    private(set) var userChoiceProviderIDs: Set<String>
    /// Persisted revision lets a first-launch probe detect user changes even across an app restart.
    private(set) var persistentUserChoiceRevision: UInt64
    /// Durable probe state: first-run detection has a single revision fence; update-time detection
    /// retains the individual provider IDs until each local credential probe completes.
    private(set) var firstRunCredentialProbeRevision: UInt64?
    private(set) var pendingProviderCredentialProbeIDs: Set<String>
    private let defaults: UserDefaults
    /// In-memory revisions distinguish a final user choice from the store merely returning to the
    /// same enabled set while an asynchronous credential probe is running.
    private var userChoiceRevisions: [String: UInt64] = [:]

    init(defaults: UserDefaults = .standard) {
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
        return !disabledIDs.contains(id)
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        updateEnabled(enabled, for: id, recordsUserChoice: true)
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

    private func updateEnabled(_ enabled: Bool, for id: String, recordsUserChoice: Bool) {
        if var ids = enabledIDs {
            if enabled { ids.insert(id) } else { ids.remove(id) }
            // A no-op toggle (re-setting the same value) shouldn't persist or wake the refresh loop.
            guard ids != enabledIDs else { return }
            enabledIDs = ids
            defaults.set(Array(ids), forKey: Self.enabledStorageKey)
        } else {
            let before = disabledIDs
            if enabled {
                disabledIDs.remove(id)
            } else {
                disabledIDs.insert(id)
            }
            guard disabledIDs != before else { return }
            defaults.set(Array(disabledIDs), forKey: Self.disabledStorageKey)
        }
        if recordsUserChoice {
            userChoiceRevisions[id, default: 0] &+= 1
            persistentUserChoiceRevision &+= 1
            userChoiceProviderIDs.insert(id)
            defaults.set(persistentUserChoiceRevision, forKey: Self.userChoiceRevisionKey)
            defaults.set(Array(userChoiceProviderIDs), forKey: Self.userChoiceProviderIDsKey)
        }
        // Clear the backoff BEFORE the wake notification, so the refresh it triggers actually probes the
        // just-enabled provider instead of skipping it as recently-failed.
        if enabled { onProviderEnabled?(id) }
        onChange?([id])
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// Switches the store into enabled-list mode with exactly `ids` on. Used by `FirstRunSeeder` on
    /// fresh installs only — first synchronously with the fallback set, then again with the detected
    /// set. Fires `onProviderEnabled` for each newly-on provider and posts the change notification, so
    /// the refresh loop fetches them promptly.
    /// Records `ids` as seen and returns the ones that were new. Pure bookkeeping: no enablement
    /// change, no notification — `NewProviderSeeder` decides separately what to do with the new ones.
    @discardableResult
    func registerKnownProviders(_ ids: Set<String>) -> Set<String> {
        let new = ids.subtracting(knownIDs)
        guard !new.isEmpty else { return [] }
        knownIDs.formUnion(new)
        defaults.set(Array(knownIDs), forKey: Self.knownStorageKey)
        return new
    }

    /// Begins the durable first-run credential probe before fallback state is written. A later launch
    /// can resume it and compare the saved user-choice revision before applying detection results.
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

    /// Marks newly-seen providers as pending before starting their asynchronous local credential
    /// probes. Pending IDs are intentionally distinct from `knownIDs`: a relaunch resumes unfinished
    /// detection, while completed misses remain one-shot and preserve the user's ability to enable them.
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
