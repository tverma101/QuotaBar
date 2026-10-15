import Foundation
import LocalAuthentication

enum ProviderRefreshContext {
    /// How much work a refresh pass should do.
    /// - `menuBar`: auth + quota/rate-limit meters the status-item strip needs; skip expensive
    ///   local JSONL / CSV / history scans where cleanly separable (Codex, Claude, Cursor,
    ///   Antigravity, Grok). `WidgetDataStore.refreshAll` also limits the pass to pinned
    ///   providers (plus notification-relevant ones when quota alerts are on). Default for
    ///   background ticks while the popover is closed.
    /// - `panelMeters`: the panel-open pass's fast first phase — the same meters-only work as
    ///   `menuBar`, but for every enabled provider so the whole dashboard's meters land in
    ///   seconds instead of trailing the slowest local fold. `WidgetDataStore.refreshAll` does
    ///   not narrow the provider set.
    /// - `full`: complete snapshot including token/spend/history (manual refresh, CLI,
    ///   background triggers).
    /// - `localAccounting`: local usage files changed (CodexRouter ledger appends), with the panel
    ///   either open or closed. Refreshes enabled Codex cards and the enabled OpenCode card when a
    ///   Codex source is enabled, folding them WITHOUT re-reading live quota APIs — re-reading those
    ///   on every routed turn is the burn the old panel-open-only watcher suppression existed to prevent.
    ///   Paced like `menuBar` and skips catalogue discovery. Remote-only providers never run.
    /// - `panelAccounting`: the panel-open full-history phase — local folds every enabled
    ///   history-exporting provider needs, without re-reading live quota APIs. Runs on panel open,
    ///   full refresh requests, visible retry follow-up, and the separate five-minute history deadline,
    ///   not on every meter tick.
    ///   The store's merge recovers the meters onto the fresh history. Scheduler-owned panel accounting
    ///   runs unpaced; a visible manual retry opts into the interactive CPU pacer.
    enum Scope: Sendable, Equatable, Hashable {
        case menuBar
        case panelMeters
        case localAccounting
        case panelAccounting
        case full

        var isFull: Bool {
            if case .full = self { return true }
            return false
        }

        /// Meters-only passes: live quota meters only, no local folds. The store's merge keeps
        /// prior spend/history rows on the snapshot.
        var skipsLocalAccounting: Bool {
            switch self {
            case .menuBar, .panelMeters: return true
            case .localAccounting, .panelAccounting, .full: return false
            }
        }

        /// Fold-only passes: local corpora recompute without re-reading live quota APIs; the
        /// store's merge recovers the meters from the prior snapshot and carries their freshness
        /// stamp (see `ProviderSnapshot.quotaRefreshedAt`).
        var suppressesLiveQuota: Bool {
            switch self {
            case .localAccounting, .panelAccounting: return true
            case .menuBar, .panelMeters, .full: return false
            }
        }
    }

    /// True only for the user's explicit Refresh Now action. Snapshot-only panel presentation
    /// never opens another app's Keychain dialog.
    @TaskLocal static var isManual = false
    /// Shared by all provider refresh tasks from one explicit refresh action. A provider can claim it
    /// only after a silent credential read proves interaction is required, limiting each action to one
    /// Keychain dialog across all enabled providers and account cards.
    @TaskLocal static var credentialInteractionGate: CredentialInteractionGate? = nil
    /// Monotonic identity for the newest explicit refresh. Detached credential reads retain this so
    /// work queued by an older action cannot open a Keychain dialog after a newer action has started.
    @TaskLocal static var manualActionID: UInt64? = nil
    /// Per-load cancellation handle for synchronous Security.framework reads. Each `loadOffMainActor`
    /// creates its own token so canceling one provider or a Safe Storage cache waiter cannot cancel a
    /// sibling load's authentication context.
    @TaskLocal static var keychainReadCancellationToken: KeychainReadCancellationToken? = nil
    /// Defaults to `.full` so tests, CLI, and any unscoped call site keep today's behavior.
    @TaskLocal static var scope: Scope = .full
    /// Refresh entry points opt into the process-wide CPU allowance when appropriate: background
    /// menu-bar ticks use the 7.5% budget, while explicit full-history reads and visible-retry recovery
    /// use the 25% interactive budget. The panel-open periodic loop can opt out to meet provider deadlines.
    /// Focused unit tests stay unthrottled unless they explicitly measure the budget.
    @TaskLocal static var accountingCPUThrottleEnabled = false
    /// Silent recovery for an interrupted user retry has no Keychain permission, but its local work
    /// still needs the same interactive pacing allowance so a cold fold can finish inside the deadline.
    @TaskLocal static var accountingCPUInteractiveBudgetEnabled = false
    /// Lightweight background menu-bar scope keeps existing catalogues on disk; missing catalogues
    /// may still download. Full accounting refreshes perform due catalogue discovery.
    @TaskLocal static var skipModelCatalogRefresh = false

    /// Re-read the live credential before persisting a successful token rotation. A newer manual
    /// refresh must fence stale prompts, but it must not make a silent source check fail merely
    /// because this already-successful OAuth response came from the older action.
    static func withCredentialSourceRevalidation<T>(_ operation: () throws -> T) rethrows -> T {
        try $isManual.withValue(false) {
            try $credentialInteractionGate.withValue(nil) {
                try $manualActionID.withValue(nil) {
                    try operation()
                }
            }
        }
    }

    /// Capture the refresh context before moving synchronous work into `Task.detached`, which does
    /// not inherit task-local values. Keep every value together so off-actor provider loads preserve
    /// manual-interaction permissions, scope, and accounting policy as one context.
    struct DetachedValues: Sendable {
        let isManual: Bool
        let credentialInteractionGate: CredentialInteractionGate?
        let manualActionID: UInt64?
        let scope: Scope
        let accountingCPUThrottleEnabled: Bool
        let accountingCPUInteractiveBudgetEnabled: Bool
        let skipModelCatalogRefresh: Bool

        func withValue<T>(_ operation: () throws -> T) rethrows -> T {
            try ProviderRefreshContext.$scope.withValue(scope) {
                try ProviderRefreshContext.$isManual.withValue(isManual) {
                    try ProviderRefreshContext.$credentialInteractionGate.withValue(credentialInteractionGate) {
                        try ProviderRefreshContext.$manualActionID.withValue(manualActionID) {
                            try ProviderRefreshContext.$accountingCPUThrottleEnabled.withValue(accountingCPUThrottleEnabled) {
                                try ProviderRefreshContext.$accountingCPUInteractiveBudgetEnabled.withValue(
                                    accountingCPUInteractiveBudgetEnabled
                                ) {
                                    try ProviderRefreshContext.$skipModelCatalogRefresh.withValue(skipModelCatalogRefresh) {
                                        try operation()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    static var detachedValues: DetachedValues {
        DetachedValues(
            isManual: isManual,
            credentialInteractionGate: credentialInteractionGate,
            manualActionID: manualActionID,
            scope: scope,
            accountingCPUThrottleEnabled: accountingCPUThrottleEnabled,
            accountingCPUInteractiveBudgetEnabled: accountingCPUInteractiveBudgetEnabled,
            skipModelCatalogRefresh: skipModelCatalogRefresh
        )
    }

    /// Cancellation includes the detached load's token because Security.framework calls are synchronous
    /// and cannot observe task cancellation until they return. The token invalidates a context currently
    /// being used for Keychain authentication.
    static var credentialReadIsCancelled: Bool {
        keychainReadCancellationToken?.isCancelled == true || Task<Never, Never>.isCancelled
    }
}

/// A single detached credential load's cancellation target for in-flight Keychain authentication.
/// `LAContext.invalidate()` stops pending policy evaluations, so keep each context registered only while
/// its `SecItemCopyMatching` call is active and never reuse it after cancellation.
final class KeychainReadCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private let invalidateContext: @Sendable (LAContext) -> Void
    private var cancelled = false
    private var activeContexts: [ObjectIdentifier: LAContext] = [:]

    init(invalidateContext: @escaping @Sendable (LAContext) -> Void = { $0.invalidate() }) {
        self.invalidateContext = invalidateContext
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Returns false after cancellation and invalidates a context that arrived too late for Security to
    /// use. Registration and cancellation share one lock so neither ordering can leave an unowned prompt.
    func register(_ context: LAContext) -> Bool {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            invalidateContext(context)
            return false
        }
        activeContexts[ObjectIdentifier(context)] = context
        lock.unlock()
        return true
    }

    /// Removes a completed query and reports whether cancellation won the race with its completion.
    func finish(_ context: LAContext) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        activeContexts.removeValue(forKey: ObjectIdentifier(context))
        return !cancelled
    }

    func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let contexts = Array(activeContexts.values)
        activeContexts.removeAll()
        lock.unlock()

        // Do not hold the bookkeeping lock while LocalAuthentication stops pending evaluations.
        contexts.forEach(invalidateContext)
    }
}

/// Run an explicit full-history refresh under the interactive CPU allowance. Keep forced refresh
/// entry points in views/settings on the same path as manual-refresh reads; the panel-open periodic
/// loop chooses its own pacing based on the provider deadline.
func withThrottledFullAccounting<T: Sendable>(
    _ operation: @Sendable () async throws -> T
) async rethrows -> T {
    try await ProviderRefreshContext.$scope.withValue(.full) {
        try await ProviderRefreshContext.$accountingCPUThrottleEnabled.withValue(true) {
            try await operation()
        }
    }
}

/// Run a visible quota retry's meter phase with the interactive CPU allowance. Most providers skip
/// local accounting in the panelMeters scope, but Hermes includes its local SQLite history scan in this pass.
func withThrottledPanelMeters<T: Sendable>(
    _ operation: @Sendable () async throws -> T
) async rethrows -> T {
    try await ProviderRefreshContext.$scope.withValue(.panelMeters) {
        try await ProviderRefreshContext.$accountingCPUThrottleEnabled.withValue(true) {
            try await operation()
        }
    }
}

/// Run a user-requested refresh with one shared Keychain-dialog budget. Background scheduler passes
/// and local credential probes must not use this wrapper.
func withManualRefresh<T: Sendable>(
    _ operation: @Sendable () async throws -> T
) async rethrows -> T {
    // A new explicit request is the user retry action. Advance the action identity as well as
    // clearing per-item declines, so detached reads queued by an older action cannot prompt later.
    let manualActionID = KeychainPermissionGate.shared.beginManualAction()
    let interactionGate = CredentialInteractionGate()
    return try await ProviderRefreshContext.$isManual.withValue(true) {
        try await ProviderRefreshContext.$credentialInteractionGate.withValue(interactionGate) {
            try await ProviderRefreshContext.$manualActionID.withValue(manualActionID) {
                try await operation()
            }
        }
    }
}

final class CredentialInteractionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }

    /// Returns the per-action dialog budget if the process-wide query lease was released before an
    /// interactive Keychain call began. Once Security.framework is entered, the budget stays spent.
    func releaseClaim() {
        lock.lock()
        claimed = false
        lock.unlock()
    }
}

/// One AI provider QuotaBar can track. A conformer reads credentials already on the machine, calls the
/// provider's API, and normalizes the result into a `ProviderSnapshot` of `MetricLine` values that the UI
/// renders. See `docs/adding-a-provider.md` for the full walkthrough.
///
/// `refresh()` returns the latest snapshot. Build its `lines` from the app's small metric vocabulary,
/// choosing the case by the shape of the value:
/// - `.progress` — a bounded meter with a `used`/`limit` and a `format` (percent, dollars, or count). Use
///   for anything with a ceiling: session/weekly quotas, credits with a cap. Add `resetsAt` when the
///   window resets at a known time.
/// - `.values` — one or more typed, unbounded numbers. Use for spend, balances, token counts, and other
///   limitless numeric rows; formatting stays at the display edge.
/// - `.badge` — a short status pill (e.g. "Disabled", or a pay-as-you-go cap). Use for state, not a number
///   to fill a bar with.
/// - `.chart` — dated numeric points rendered as a compact usage trend.
/// - `.text` — a string-valued provider notice preserved for the local API. Dashboard widgets do not
///   parse display text; use a typed line above for every widget descriptor.
///
/// On failure, return `ProviderSnapshot.error(provider:error:)` with a typed provider error so the error
/// surfaces loudly in the UI and telemetry can report a stable, non-PII category. Use the message-only
/// factory only when no typed error exists.
@MainActor
protocol ProviderRuntime: AnyObject {
    var provider: Provider { get }
    var widgetDescriptors: [WidgetDescriptor] { get }

    /// True when `.panelMeters` must also compute this provider's local history because there is no
    /// separate remote quota surface. A visible retry can then avoid immediately scanning that source
    /// a second time in the follow-up accounting phase.
    var panelMetersRefreshIncludesHistory: Bool { get }

    func refresh() async -> ProviderSnapshot

    /// Whether credentials for this provider already exist on this machine — a cheap, local-only probe
    /// (files, keychain, SQLite; never the network). Used once, on a fresh install's first launch, by
    /// `FirstRunSeeder` to enable exactly the providers the user actually has. Mirror the credential
    /// sources `refresh()` reads, and run blocking loads via `loadOffMainActor`.
    func hasLocalCredentials() async -> Bool
}

extension ProviderRuntime {
    var panelMetersRefreshIncludesHistory: Bool { false }
}

/// Run a blocking, `Sendable` credential load off the MainActor.
///
/// Auth stores read credentials via the `security` (keychain) and `sqlite3` CLIs, whose `ProcessRunner`
/// waits block the calling thread for up to ~5s each. Those loads run at the top of a provider's
/// `@MainActor refresh()`, so calling them inline freezes the popover and the periodic-refresh loop for
/// the whole subprocess window (Cursor issues several reads per refresh — up to ~25s). Offloading to a
/// detached task moves the wait onto a background executor; the `Sendable` result crosses back cleanly.
/// It is awaited immediately, so it reads like a normal call while no longer blocking the actor.
func loadOffMainActor<T: Sendable>(_ load: @escaping @Sendable () -> T) async -> T {
    let context = ProviderRefreshContext.detachedValues
    let cancellationToken = KeychainReadCancellationToken()
    let work = Task.detached(priority: .utility) {
        context.withValue {
            ProviderRefreshContext.$keychainReadCancellationToken.withValue(
                cancellationToken,
                operation: load
            )
        }
    }
    return await withTaskCancellationHandler {
        await work.value
    } onCancel: {
        cancellationToken.cancel()
        work.cancel()
    }
}

/// Throwing counterpart for blocking credential reads that distinguish absence from access failure.
func loadOffMainActor<T: Sendable>(_ load: @escaping @Sendable () throws -> T) async throws -> T {
    let context = ProviderRefreshContext.detachedValues
    let cancellationToken = KeychainReadCancellationToken()
    let work = Task.detached(priority: .utility) {
        try context.withValue {
            try ProviderRefreshContext.$keychainReadCancellationToken.withValue(
                cancellationToken,
                operation: load
            )
        }
    }
    return try await withTaskCancellationHandler {
        try await work.value
    } onCancel: {
        cancellationToken.cancel()
        work.cancel()
    }
}

/// Provider refresh methods are nonthrowing, so return a discardable marker when their owner is
/// cancelled. WidgetDataStore checks the task state and will not publish this snapshot or its error.
func cancelledRefreshSnapshot(provider: Provider) -> ProviderSnapshot {
    ProviderSnapshot.error(provider: provider, error: CancellationError())
}
