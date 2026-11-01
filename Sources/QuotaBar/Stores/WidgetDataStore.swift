import Foundation
import Observation

/// A compact staleness hint for a provider's on-screen snapshot. `label` is a short, fixed word
/// ("Outdated") that stays narrow next to long plan names like "Super Grok Heavy", while the precise
/// age lives in `tooltip` ("Last updated 3h 12m ago"), revealed on hover.
struct StalenessHint: Equatable {
    let label: String
    let tooltip: String
}

@MainActor
@Observable
final class WidgetDataStore {
    private let registry: WidgetRegistry
    private let providersByID: [String: ProviderRuntime]
    private let cache: ProviderSnapshotCache
    private let defaults: UserDefaults
    /// Whether a provider is currently enabled. Injected so the store consults the single
    /// `ProviderEnablementStore` without owning it; defaults to "all enabled" for tests and previews.
    private let isProviderEnabled: @MainActor (String) -> Bool
    /// The user's widget order (already enablement-filtered) that drives the menu-bar value. Injected
    /// so the store reads `LayoutStore.visiblePlaced` without owning it; defaults to registry order.
    private let orderedDescriptors: @MainActor () -> [WidgetDescriptor]
    /// Provider IDs the user hid from the menu-bar strip ("Show in menu bar" off). A closed-panel
    /// strip pass has nothing to paint for them, so refreshing their live meters every tick is pure
    /// waste — injected from `LayoutStore` like `orderedDescriptors`; empty in tests that don't care.
    private let hiddenMenuBarProviderIDs: @MainActor () -> Set<String>
    /// Metric IDs currently pinned to the status-item strip. Injected from `LayoutStore`; empty in
    /// tests that don't care about menu-bar filtering (menuBar passes then refresh nothing unless
    /// notifications pull providers in).
    private let pinnedMetricIDs: @MainActor () -> Set<String>
    /// Clock for the failure-backoff window. Injected so tests can advance time deterministically.
    private let now: () -> Date
    /// Monotonic clock for refresh durations, kept separate from wall time so a clock adjustment cannot
    /// produce a negative or wildly inflated provider timing. Tests inject exact ticks.
    private let monotonicNow: () -> TimeInterval
    private let slowProviderRefreshThreshold: TimeInterval
    /// See `defaultProviderRefreshTimeout`. Injected so tests can drive the deadline in milliseconds.
    private let providerRefreshTimeout: TimeInterval
    /// Quota-notification preferences (three independent triggers). Injected; `nil` disables
    /// notifications entirely (tests and previews that don't wire it).
    private let notificationSettings: (@MainActor () -> NotificationSettingsStore)?
    /// Card id → the identity that produced or currently owns the account-scoped snapshot. Launch
    /// discovery seeds this map; providers that detect an account switch during refresh update it.
    private var providerIdentityKeys: [String: String]
    /// Where a fired milestone is delivered: `(idPrefix, title, subtitle, body) -> Bool`. The Bool is
    /// whether it was actually delivered (authorized + scheduled); on false the caller leaves the
    /// milestone un-marked so it retries next pass. Injected so tests can record posts without a live
    /// notification center; defaults to the shared `AppNotifications`.
    private let postNotification: @MainActor (String, String, String, String) async -> Bool

    private static let meterStyleKey = "meterStyle"
    private static let resetDisplayModeKey = "resetDisplayMode"
    private static let alwaysShowPacingKey = "alwaysShowPacing"
    /// How long a provider that just failed is skipped before the loop will probe it again. A failed
    /// refresh isn't cached, so — unlike a success, which the snapshot cache gates for an interval —
    /// nothing else stops the loop from re-probing a broken provider (logged-out Devin/Grok especially)
    /// on every wake, spawning subprocesses and network calls in a tight loop. This negative-cache caps a
    /// failing provider to one probe per window. It bounds wake bursts while remaining no longer
    /// than the AC meter cadence; on battery, the next two-minute quota tick retries it. The manual
    /// `force` refresh (⌘R) always bypasses it.
    private static let failureRetryBackoff: TimeInterval = 60
    static let defaultSlowProviderRefreshThreshold: TimeInterval = 10
    /// Hard deadline for a single provider's `refresh()` call. If the provider hasn't returned by then
    /// the refresh is cancelled, the spinner stops, and the failure is surfaced like any other error.
    ///
    /// This is a last-resort backstop for a provider that hangs (a subprocess that never exits, a
    /// credential read that blocks) — not a latency budget. It must therefore sit well above the sum of
    /// the per-request timeouts a healthy provider can legitimately spend, or a slow network would turn
    /// working providers into errors. The worst legitimate case is Cursor, whose probe is sequential:
    /// token refresh (15s) → usage (10s, plus a 401 refresh-and-retry of another 25s) → plan (10s) →
    /// usage summary (10s) → credits (10s) → usage CSV (30s), i.e. up to ~110s. Slowness short of the
    /// deadline is already reported separately by `slowProviderRefreshThreshold`.
    static let defaultProviderRefreshTimeout: TimeInterval = 120

    /// Backoff bounds for a forced caller waiting on an in-flight provider pass.
    ///
    /// This wait used to be `while inFlight { await Task.yield() }` — a bare re-enqueue on the
    /// MainActor's serial executor. Every waiter spun a full core for the whole wait, and the panel
    /// spawns one `refreshAll(force:)` per popover open, so twenty open/close cycles inside one slow
    /// provider's window left twenty tasks doing nothing but re-enqueueing. It inflated MainActor queue
    /// latency for every panel and menu-bar update, and nothing could cancel them. Sleeping with backoff
    /// keeps the wait responsive to completion while costing nothing when idle.
    private static let forceWaitInitialDelay: TimeInterval = 0.02
    private static let forceWaitMaxDelay: TimeInterval = 0.25
    /// Slack past the provider deadline before a forced waiter gives up. The in-flight pass is itself
    /// cancelled at `defaultProviderRefreshTimeout`, so this only has to cover the unwind.
    private static let forceWaitGrace: TimeInterval = 5

    /// Rendered snapshots consumed by every UI/API surface. Equal to `localSnapshots` when iCloud sync
    /// is off; machine-local history rows are rebuilt from the union while sync is on.
    var snapshots: [String: ProviderSnapshot] = [:]
    /// Each provider's history descriptor, keyed by provider ID — the classifying metadata the
    /// Usage History screen reuses (e.g. `estimatedCost`, which drives the lifetime hero's
    /// "(Est.)" mark). Same source the spend tiles' ⓘ flag reads.
    var historyDescriptorsByProvider: [String: UsageHistoryDescriptor] {
        registry.historyDescriptorsByProvider
    }
    /// Last-good snapshots produced on this Mac. These alone are cached and exported to iCloud, so a
    /// peer contribution can never echo back out and multiply on the next device.
    private(set) var localSnapshots: [String: ProviderSnapshot] = [:]
    var refreshingProviderIDs: Set<String> = []
    /// Running batches keyed by their complete execution policy, so a second caller asking for the same
    /// thing joins it instead of starting its own set of per-provider tasks. Manual action identity is
    /// part of the key: a new Refresh Now must not join work whose Keychain prompt budget it superseded.
    ///
    /// Keyed rather than a single slot: a non-forced batch (the periodic tick, a CodexRouter ledger wake)
    /// routinely overlaps a forced one (panel open), and it finishes first because it is nearly all cache
    /// hits. With one slot the fast batch's completion cleared the *forced* batch's registration while that
    /// batch was still running, so the next popover open saw an empty slot and re-fetched every provider
    /// — double API calls, double subprocesses, a second full parse of the JSONL corpus, and a spinner for
    /// the sum of both passes. Each batch now removes only its own entry.
    ///
    /// A forced caller must never be handed a menu-bar-scoped pass, and a memory-capped pass must not
    /// join an uncapped one. Different settings are not joined; per-provider waits serialize overlap.
    private struct RefreshBatchKey: Hashable {
        let force: Bool
        let bypassSnapshotCache: Bool
        let bypassFailureBackoff: Bool
        let scope: ProviderRefreshContext.Scope
        let manualActionID: UInt64?
        let maxConcurrentProviders: Int?
    }

    /// Quota requests and local history folds are independent work. A failure in one must not
    /// throttle the other, while the same work still gets a short negative-cache window.
    private enum FailureDomain: Hashable {
        case liveQuota
        case accounting
        case full

    }

    private struct FailureBackoffKey: Hashable {
        let providerID: String
        let domain: FailureDomain
    }

    private struct ProviderFailureState {
        let message: String
        let category: ErrorCategory?
        let order: UInt64
    }

    private struct ProviderFailureLogIdentity: Equatable {
        let message: String
        let category: ErrorCategory?
    }

    private var activeBatches: [RefreshBatchKey: Task<Void, Never>] = [:]
    /// Publication ownership is per provider. The Keychain gate retains a global action identity for
    /// prompt safety, but a targeted refresh must not invalidate unrelated cards in an older full pass.
    @ObservationIgnored private var providerRequestGenerations: [String: UInt64] = [:]
    @ObservationIgnored private var providerRefreshRequestOrders: [String: UInt64] = [:]
    @ObservationIgnored private var providerIdentityResolutionOrders: [String: UInt64] = [:]
    @ObservationIgnored private var latestManualActionByProvider: [String: UInt64] = [:]
    /// Manual actions issued before a provider was disabled must not become valid again if that card is
    /// re-enabled while a delayed phase-two request is still queued.
    @ObservationIgnored private var invalidatedManualActionsThrough: [String: UInt64] = [:]
    /// Handles for provider work currently awaited by any batch or direct card refresh. Disabling a
    /// card cancels its task so cancellation-aware scanners can stop instead of finishing work the user
    /// has just turned off.
    @ObservationIgnored private var activeProviderRefreshTasks: [String: [UUID: Task<RefreshOutcome, Never>]] = [:]
    @ObservationIgnored private var activeProviderRefreshTaskScopes: [String: [UUID: ProviderRefreshContext.Scope]] = [:]
    @ObservationIgnored private var activeProviderRefreshTaskBatchIDs: [String: [UUID: UUID]] = [:]
    /// Scopes currently inside `ProviderRuntime.refresh`, keyed by task ID. Meter refreshes may overlap
    /// a fold-only pass for the same enabled card so a slow local scan cannot hold subscription meters
    /// past their deadline. Other combinations remain serialized, except an explicit forced panel-meter
    /// retry uses the same safe overlap rule to keep the visible Retry action responsive.
    @ObservationIgnored private var runningProviderRefreshScopes: [String: [UUID: ProviderRefreshContext.Scope]] = [:]
    /// Refresh requests skipped behind an incompatible in-flight scope. They are emitted to the
    /// scheduler as soon as the provider can accept them, so a consumed timer/ledger/panel intent is
    /// retried promptly without repeatedly polling the provider.
    @ObservationIgnored private var deferredRefreshRequests: [String: Set<DeferredRefreshRequest>] = [:]
    /// Wall-clock time of the most recent live quota attempt or due scheduler check. The footer uses
    /// it for its live "Next update in …" countdown. Fold-only and early cache-hit passes do not
    /// advance it, so they cannot make the meter countdown appear fresh while the quota schedule is due.
    var lastQuotaRefreshAt: Date?
    /// Monotonic time a provider actually attempted a live quota refresh. Early panel/trigger passes
    /// that only hit cache must not move the scheduler's deadline or claim the meters were refreshed.
    @ObservationIgnored private(set) var lastLiveQuotaRefreshUptime: TimeInterval?

    /// Keeps the footer aligned with a due scheduler check when no provider was eligible or every
    /// selected provider was skipped/backed off. Early cache-hit passes must not call this.
    func markQuotaRefreshCheckCompleted(at date: Date = Date()) {
        lastQuotaRefreshAt = date
    }
    /// Latest refresh error per provider (e.g. "Not logged in. Run `codex` to authenticate."). It is
    /// cleared when the work that failed succeeds again. The dashboard renders it as a warning
    /// indicator beside the provider name; the last good snapshot keeps displaying
    /// (stale-while-revalidate) instead of being replaced by dead "No data" rows.
    var providerErrors: [String: String] = [:]

    @ObservationIgnored private var providerFailureStates: [String: [FailureDomain: ProviderFailureState]] = [:]
    @ObservationIgnored private var nextProviderFailureOrder: UInt64 = 0

    /// The same persistent provider failure is logged once until recovery or a changed error. A forced
    /// retry may repeat transient diagnostics, but not credential-access or structurally invalid auth
    /// failures that another read cannot repair.
    @ObservationIgnored private var lastLoggedProviderFailure: [String: [FailureDomain: ProviderFailureLogIdentity]] = [:]

    /// Per-provider earliest next-probe time after a failure (see `failureRetryBackoff`). Not part of
    /// observable UI state, so it's excluded from `@Observable` tracking.
    @ObservationIgnored private var failureRetryAfter: [FailureBackoffKey: Date] = [:]

    /// Owns the quota pace-notification subsystem (dedup state, fire/deliver decision, trace). This store
    /// just gathers each pass's enabled bounded metrics and delegates.
    @ObservationIgnored private let notificationEvaluator = QuotaNotificationEvaluator()

    /// Telemetry hook wired by `AppContainer`. Invoked once per *real* provider fetch — `.refreshed` or
    /// `.failed` only, never the cache-hit/skip/backoff outcomes that the one-minute meter timer produces in
    /// bulk — so the recorder can roll daily usage and error counts up into one event per provider per
    /// day. `nil` (and so a no-op) in tests and previews. Not observable UI state.
    @ObservationIgnored var onRefreshOutcome: (@MainActor (String, RefreshOutcome, ErrorCategory?, Bool) -> Void)?
    @ObservationIgnored var onDeferredRefreshReady: (@MainActor (DeferredRefreshRequest) -> Void)?
    @ObservationIgnored var onDeferredRefreshesInvalidated: (@MainActor (Set<String>) -> Void)?
    /// Wired by `ICloudUsageSyncStore`; debounced there so a concurrent provider batch produces one file.
    @ObservationIgnored var onLocalHistoryChanged: (@MainActor () -> Void)?
    @ObservationIgnored private var peerHistoryDocuments: [UsageHistoryDocument] = []
    /// The merged daily fold is reused across quota-only refreshes. Its value arrays are shared with
    /// rendered snapshots through copy-on-write, while history, peer, enablement, and day changes
    /// explicitly invalidate it.
    @ObservationIgnored private var mergedHistoryCache: [String: ProviderUsageHistory]?
    @ObservationIgnored private var mergedHistoryCacheDayKey: String?
    @ObservationIgnored private var localHistoryRevision: UInt64 = 0

    /// Global meter style: whether every bounded tile (and the menu-bar value) renders as "used" or
    /// "left/remaining". Persisted so the choice survives relaunch; defaults to `.remaining`.
    var meterStyle: WidgetDisplayMode {
        didSet { defaults.set(meterStyle.rawValue, forKey: Self.meterStyleKey) }
    }

    /// Global reset-countdown format: relative ("Resets in 4d 17h") or absolute ("Resets tomorrow at
    /// 9:00 AM"). Persisted across relaunch; defaults to `.relative`. Toggled by clicking a reset label.
    var resetDisplayMode: ResetDisplayMode {
        didSet { defaults.set(resetDisplayMode.rawValue, forKey: Self.resetDisplayModeKey) }
    }

    /// Global "always show pacing" opt-in: when on, on-track rows surface their pace projection (the
    /// blue/healthy row gains its "~N% left at reset" copy + an even-pace tick, the amber tick switches
    /// to the same even-pace line). Persisted across relaunch; defaults to `false` (every row unchanged).
    var alwaysShowPacing: Bool {
        didSet { defaults.set(alwaysShowPacing, forKey: Self.alwaysShowPacingKey) }
    }

    /// Restores the Usage Display preferences (meter style, reset-time format, always-show-pacing) to
    /// their defaults — the Settings "Reset All Settings" path. Cached usage snapshots are data, not
    /// settings, and stay untouched.
    func resetDisplaySettings() {
        meterStyle = .remaining
        resetDisplayMode = .relative
        alwaysShowPacing = false
    }

    func unloadProviderCachesForMemoryPressure() async {
        if let antigravity = providersByID["antigravity"] as? AntigravityProvider {
            await antigravity.unloadLocalAccountingCachesForMemoryPressure()
        }
        if let freebuff = providersByID["freebuff"] as? FreebuffProvider {
            await freebuff.unloadLocalAccountingCachesForMemoryPressure()
        }
    }

    init(
        registry: WidgetRegistry,
        providers: [ProviderRuntime],
        cache: ProviderSnapshotCache = ProviderSnapshotCache(),
        defaults: UserDefaults = .standard,
        isProviderEnabled: @escaping @MainActor (String) -> Bool = { _ in true },
        orderedDescriptors: (@MainActor () -> [WidgetDescriptor])? = nil,
        pinnedMetricIDs: (@MainActor () -> Set<String>)? = nil,
        hiddenMenuBarProviderIDs: (@MainActor () -> Set<String>)? = nil,
        now: @escaping () -> Date = Date.init,
        monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        slowProviderRefreshThreshold: TimeInterval = WidgetDataStore.defaultSlowProviderRefreshThreshold,
        providerRefreshTimeout: TimeInterval = WidgetDataStore.defaultProviderRefreshTimeout,
        notificationSettings: (@MainActor () -> NotificationSettingsStore)? = nil,
        postNotification: (@MainActor (String, String, String, String) async -> Bool)? = nil,
        providerIdentityKeys: [String: String] = [:]
    ) {
        precondition(slowProviderRefreshThreshold >= 0)
        precondition(providerRefreshTimeout > 0)
        self.registry = registry
        self.providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.provider.id, $0) })
        self.cache = cache
        self.defaults = defaults
        self.isProviderEnabled = isProviderEnabled
        self.orderedDescriptors = orderedDescriptors ?? { registry.descriptors }
        self.pinnedMetricIDs = pinnedMetricIDs ?? { [] }
        self.hiddenMenuBarProviderIDs = hiddenMenuBarProviderIDs ?? { [] }
        self.now = now
        self.monotonicNow = monotonicNow
        self.slowProviderRefreshThreshold = slowProviderRefreshThreshold
        self.providerRefreshTimeout = providerRefreshTimeout
        self.notificationSettings = notificationSettings
        self.postNotification = postNotification
            ?? { idPrefix, title, subtitle, body in
                await AppNotifications.shared.post(idPrefix: idPrefix, title: title, subtitle: subtitle, body: body)
            }
        self.providerIdentityKeys = providerIdentityKeys
        self.meterStyle = defaults.enumValue(forKey: Self.meterStyleKey, default: .remaining)
        self.resetDisplayMode = defaults.enumValue(forKey: Self.resetDisplayModeKey, default: .relative)
        self.alwaysShowPacing = defaults.bool(forKey: Self.alwaysShowPacingKey)
        // Stale-while-revalidate: load whatever was cached (expired included) so the menu bar and
        // dashboard show last-known values immediately at launch instead of "—"; the refresh loop
        // replaces them as soon as fresh data lands.
        //
        // Account swap guard: account-scoped rows only paint when their producer identity matches.
        // OpenCode and Antigravity quota belong to credentials, while their usage history is
        // machine-local. Account changes clear plan/progress but keep local history.
        let retentionDate = now()
        let lifetimeDayKeys = UsageHistoryWindow.lifetimeDayKeys(through: retentionDate)
        let detailDayKeys = UsageHistoryWindow.dayKeys(through: retentionDate)
        cache.compactHistories(lifetimeDayKeys: lifetimeDayKeys, detailDayKeys: detailDayKeys)
        var loaded = cache.loadSnapshots(providerIDs: registry.providers.map(\.id))
        for cardID in Array(loaded.keys) where cache.hasStaleAccountStamp(
            providerID: cardID,
            currentIdentityKey: providerIdentityKeys[cardID]
        ) {
            guard let snapshot = loaded[cardID] else { continue }
            AppLog.info(.cache, "stale account cache filtered for \(cardID)")
            if cardID == "opencode" || cardID == "antigravity" {
                loaded[cardID] = Self.snapshotByClearingQuotaState(snapshot)
            } else {
                loaded.removeValue(forKey: cardID)
            }
        }
        self.localSnapshots = loaded
        self.snapshots = loaded
    }

    /// Mark Codex card snapshots stale for this session so a ledger wake can re-scan JSONL without
    /// a full `force` (which would also re-hit Cursor/network). Last-good UI rows stay painted until
    /// the refetch completes.
    func invalidateSessionFreshnessForCodexSpend() {
        // Codex only: the ledger rows OpenCode's card would fold are the ones it skips, so an OpenCode
        // snapshot is not made stale by a router append. `invalidateLocalAccountingFreshness` covers
        // the trigger path, which does need both families.
        let ids = providersByID.keys.filter { ProviderAccountID.family(of: $0) == "codex" }
        cache.invalidateSessionFreshness(providerIDs: Array(ids))
        if !ids.isEmpty {
            AppLog.debug(.refresh, "codex spend cache invalidated (\(ids.count) cards) after ledger wake")
        }
    }

    /// An external background refresh can append or replace local usage data for any provider with
    /// a history descriptor. Drop those providers' session freshness so the next ordinary refresh
    /// recomputes their local history while unrelated cards continue to use their cache.
    func invalidateLocalAccountingFreshness() {
        let ids = providersByID.keys.filter {
            isProviderEnabled($0) && registry.historyDescriptorsByProvider[$0] != nil
        }
        cache.invalidateSessionFreshness(providerIDs: Array(ids))
        if !ids.isEmpty {
            AppLog.debug(.refresh, "local history cache invalidated (\(ids.count) cards) for background refresh")
        }
    }

    func hasEnabledProviderFamily(_ family: String) -> Bool {
        providersByID.keys.contains {
            ProviderAccountID.family(of: $0) == family && isProviderEnabled($0)
        }
    }

    func descriptor(id: String) -> WidgetDescriptor? {
        registry.descriptor(id: id)
    }

    /// Whether any pinned metric derives from a ledger append (Codex spend or OpenCode metrics).
    func closedPanelLedgerWakeAffectsVisibleMetrics() -> Bool {
        MenuBarRefreshFilter.closedPanelLedgerWakeAffectsVisibleMetrics(
            pinnedMetricIDs: pinnedMetricIDs(),
            descriptorForMetric: { [registry] id in registry.descriptor(id: id) }
        )
    }

    /// Refresh every enabled provider, concurrently by default — one slow provider never delays the
    /// rest. Callers can cap the first pass with `maxConcurrentProviders` so a cold launch with large
    /// local indexes does not start every parser and network client at once; later periodic passes keep
    /// the normal overlap. Everything stays MainActor-isolated; the overlap happens at provider awaits,
    /// and the per-provider in-flight guard still prevents duplicate fetches. `force` bypasses the
    /// snapshot cache (the manual "refresh now" path); the periodic loop keeps honoring it.
    /// Runs one refresh batch, coalescing callers that asked for exactly the same work.
    ///
    /// The panel fires a forced full-scope batch on every popover open and never cancels the previous
    /// one, so a user opening and closing the panel repeatedly used to stack batches — each spawning a
    /// task per provider, each of which then hit the forced-wait path for any provider already in
    /// flight. A caller arriving while an identical batch runs now joins it, which yields the same
    /// result because the batch refreshes the same provider set.
    ///
    /// A caller with a *different* force/cache/scope tuple is deliberately not joined: a forced caller
    /// must not be handed a menu-bar-scoped pass, and a scheduled history fold must not join a batch
    /// that is allowed to reuse its cached snapshot.
    func refreshAll(
        force: Bool = false,
        bypassSnapshotCache: Bool = false,
        bypassFailureBackoff: Bool = false,
        maxConcurrentProviders: Int? = nil
    ) async {
        let scope = ProviderRefreshContext.scope
        let batchKey = RefreshBatchKey(
            force: force,
            bypassSnapshotCache: bypassSnapshotCache,
            bypassFailureBackoff: bypassFailureBackoff,
            scope: scope,
            manualActionID: ProviderRefreshContext.manualActionID,
            maxConcurrentProviders: maxConcurrentProviders.map { max(1, $0) }
        )
        if let active = activeBatches[batchKey] {
            AppLog.debug(.refresh, "batch join (force=\(force), bypassCache=\(bypassSnapshotCache) already in flight)")
            // A joiner owns only its wait. Canceling it must not cancel the shared batch that the
            // original caller and other joiners still rely on.
            await active.value
            return
        }
        let batchID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runBatch(
                batchID: batchID,
                force: force,
                bypassSnapshotCache: bypassSnapshotCache,
                bypassFailureBackoff: bypassFailureBackoff,
                maxConcurrentProviders: maxConcurrentProviders
            )
        }
        activeBatches[batchKey] = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: { [weak self] in
            task.cancel()
            Task { @MainActor [weak self] in
                self?.cancelProviderRefreshes(batchID: batchID)
            }
        }
        // Remove only *this* batch's entry. `Task` is a value type, so there is no identity to compare;
        // but a same-key entry cannot have been replaced while this one ran, because a same-key caller
        // would have joined instead of starting a second. Removing a *different* key's entry here is
        // exactly the bug this map replaced, so the key is all that is needed.
        activeBatches[batchKey] = nil
    }

    /// Log/batch-key label per scope. Distinct keys matter: a `.localAccounting` batch in flight
    /// must not absorb a panel-open `.full` request (it refreshes only the ledger-consuming
    /// families), and vice versa a `.full` batch legitimately subsumes a concurrent wake pass.
    /// The two panel phases get their own keys too, so a phase-1 meters batch can never join (or
    /// be joined by) a phase-2 fold batch.
    static func batchScopeLabel(_ scope: ProviderRefreshContext.Scope) -> String {
        switch scope {
        case .menuBar: return "menuBar"
        case .panelMeters: return "panelMeters"
        case .localAccounting: return "localAccounting"
        case .panelAccounting: return "panelAccounting"
        case .full: return "full"
        }
    }

    private func runBatch(
        batchID: UUID,
        force: Bool,
        bypassSnapshotCache: Bool,
        bypassFailureBackoff: Bool,
        maxConcurrentProviders: Int?
    ) async {
        // `Task {}` from MainActor context inherits the isolation (a task-group child can't capture
        // the non-Sendable store), so fire one task per provider in bounded groups, then await them all.
        let enabledIDs = registry.providers.map(\.id).filter { isProviderEnabled($0) }
        var providerIDs = Self.selectProviderIDsForRefresh(
            enabledProviderIDs: enabledIDs,
            scope: ProviderRefreshContext.scope,
            pinnedMetricIDs: pinnedMetricIDs(),
            providerIDForMetric: { [registry] id in registry.descriptor(id: id)?.providerID },
            orderedDescriptors: orderedDescriptors(),
            notificationsEnabled: notificationSettings?().anyEnabled ?? false,
            hiddenMenuBarProviderIDs: hiddenMenuBarProviderIDs()
        )
        // The panel fold phase only needs providers whose snapshot carries local accounting (the
        // history exporters). Pure-API providers (Z.ai, OpenRouter, Devin, …) have no local fold;
        // suppressing their quota fetch would just re-stamp an unchanged snapshot, and running
        // them here would double every panel-open API call (phase 1 already fetched their meters).
        if ProviderRefreshContext.scope == .panelAccounting {
            providerIDs = providerIDs.filter {
                registry.historyDescriptorsByProvider[$0] != nil
                    && providersByID[$0]?.panelMetersRefreshIncludesHistory != true
            }
        }
        if providerIDs.isEmpty {
            AppLog.info(.refresh, "batch skip (0 providers for scope=\(Self.batchScopeLabel(ProviderRefreshContext.scope)), force=\(force))")
            return
        }
        // Capture request ownership before starting any provider task. A newer manual request can then
        // invalidate only the cards it actually covers, even while it waits for their current pass.
        var requestGenerations: [String: UInt64] = [:]
        for providerID in providerIDs {
            requestGenerations[providerID] = beginProviderRequest(
                providerID: providerID,
                manualActionID: ProviderRefreshContext.manualActionID
            )
        }
        let start = monotonicNow()
        AppLog.info(.refresh, "batch start (\(providerIDs.count) providers, force=\(force), scope=\(Self.batchScopeLabel(ProviderRefreshContext.scope)))")
        let startingHistoryRevision = localHistoryRevision
        var concurrency = max(1, maxConcurrentProviders ?? providerIDs.count)
        var outcomes: [RefreshOutcome] = []
        outcomes.reserveCapacity(providerIDs.count)
        var attemptedLiveQuota = false
        var pendingProviderIDs = providerIDs
        while !pendingProviderIDs.isEmpty {
            guard !Task.isCancelled else { break }
            // Re-check the budget before every chunk, not just once per pass. The per-provider unload
            // runs *after* a provider finishes, so a chunk that started under the limit can leave the
            // next one stacking on top of a much larger footprint. Dropping to one at a time here
            // caps the peak at a single provider's parse arrays instead of their sum.
            if ProcessMemoryBudget.isOverSoftLimit {
                concurrency = 1
            }
            // Heavy local-log scans allocate their parse working set before the post-refresh unload.
            // Keep at most one such provider in flight even when the process is currently below its
            // soft limit; otherwise several large scans can cross the hard limit before it is sampled.
            // Most menu-bar meters skip those scans, but Hermes still reads its local database in a
            // meters-only scope, so serialize that provider while allowing scan-light quota APIs together.
            let serializedHeavyProviders = Self.heavyProvidersToSerialize(in: ProviderRefreshContext.scope)
            var chunk: [String] = []
            var includesHeavyProvider = false
            while chunk.count < concurrency, !pendingProviderIDs.isEmpty {
                guard !Task.isCancelled else { break }
                guard let nextIndex = pendingProviderIDs.firstIndex(where: { providerID in
                    !serializedHeavyProviders.contains(providerID) || !includesHeavyProvider
                }) else { break }
                let providerID = pendingProviderIDs.remove(at: nextIndex)
                if serializedHeavyProviders.contains(providerID) {
                    includesHeavyProvider = true
                }
                chunk.append(providerID)
            }
            let tasks = chunk.map { providerID in
                let taskID = UUID()
                let requestGeneration = requestGenerations[providerID, default: 0]
                let task = Task { @MainActor [weak self] in
                    guard let self else { return RefreshOutcome.skipped }
                    return await self.performRefresh(
                        providerID: providerID,
                        taskID: taskID,
                        requestGeneration: requestGeneration,
                        force: force,
                        bypassSnapshotCache: bypassSnapshotCache,
                        notifyHistoryChange: false,
                        bypassFailureBackoff: bypassFailureBackoff
                    )
                }
                registerProviderRefreshTask(
                    task,
                    id: taskID,
                    providerID: providerID,
                    scope: ProviderRefreshContext.scope,
                    batchID: batchID
                )
                return (providerID, taskID, task)
            }
            for (providerID, taskID, task) in tasks {
                let outcome = await task.value
                outcomes.append(outcome)
                if !ProviderRefreshContext.scope.suppressesLiveQuota,
                   providersByID[providerID]?.panelMetersRefreshIncludesHistory != true,
                   outcome == .refreshed || outcome == .failed
                {
                    attemptedLiveQuota = true
                }
                unregisterProviderRefreshTask(taskID, providerID: providerID)
            }
        }
        let durationMs = durationMilliseconds(since: start)
        // Count THIS batch's actual outcomes, not the long-lived `providerErrors` map (which persists
        // across passes, so reading it would miscount cache hits and stale earlier failures).
        let refreshed = outcomes.count { $0 == .refreshed }
        let failed = outcomes.count { $0 == .failed }
        let cached = outcomes.count { $0 == .cacheHit }
        let backedOff = outcomes.count { $0 == .backedOff }
        let inFlight = outcomes.count { $0 == .inFlight }
        // Fold-only and cache-hit batches do not advance the quota timer or the popover countdown.
        // In particular, a panel-open or accepted-trigger meter pass just before TTL expiry must
        // not buy another full interval without making a live quota attempt.
        if !ProviderRefreshContext.scope.suppressesLiveQuota, attemptedLiveQuota {
            lastQuotaRefreshAt = Date()
            lastLiveQuotaRefreshUptime = ProcessInfo.processInfo.systemUptime
        }
        if localHistoryRevision != startingHistoryRevision { onLocalHistoryChanged?() }
        AppLog.info(.refresh, "batch end (\(durationMs)ms, \(refreshed) ok / \(failed) failed / \(cached) cached / \(backedOff) backed off / \(inFlight) deferred)")
    }

    /// Evaluate every visible, enabled metric for a quota pace milestone and post a notification for any
    /// that just crossed one. Driven from the periodic loop *after* `refreshAll`, so it catches pace
    /// worsening from time passing (not only from a fresh fetch). Deduped per metric per reset window by
    /// the evaluator's per-key state. No-data metrics never fire; bounded level-only metrics can fire
    /// Almost Out, but not pace-based milestones. A no-op when notifications are unconfigured
    /// (tests/previews) or all triggers are off.
    ///
    /// State for metrics not visited this pass (e.g. a provider the user just disabled, or a metric
    /// removed from the layout) is pruned, so re-enabling/re-adding starts fresh rather than carrying a
    /// stale "already fired" flag.
    func evaluateNotifications(now: Date = Date()) async {
        guard let settingsProvider = notificationSettings else { return }
        let settings = settingsProvider()
        let toggles = settings.toggles
        if !settings.anyEnabled {
            // Preserve the evaluator's pruning semantics while avoiding descriptor/data resolution on
            // every one-minute background tick when notifications are completely disabled.
            await notificationEvaluator.evaluate(
                metrics: [],
                toggles: toggles,
                now: now,
                providerName: { [providersByID] id in providersByID[id]?.provider.displayName ?? id },
                post: postNotification
            )
            return
        }
        // Gather this pass's enabled, bounded, visible metrics — unbounded rows and charts have no pace
        // story (their meterState never fires), so they're skipped here rather than occupying state.
        // Order is the layout order; the evaluator prunes state for anything not passed this pass.
        // Deliberate delta from the pre-extraction loop: the pass decides from this snapshot, taken
        // before the first delivery `await`, where the old inline loop re-read `data(for:)` between
        // deliveries — a mid-pass refresh no longer changes later metrics' inputs within one pass.
        let metrics = orderedDescriptors()
            .filter { isProviderEnabled($0.providerID) }
            .compactMap { descriptor -> QuotaNotificationEvaluator.Metric? in
                let data = data(for: descriptor)
                guard data.isBounded else { return nil }
                return QuotaNotificationEvaluator.Metric(
                    key: "\(descriptor.providerID).\(descriptor.id)",
                    providerID: descriptor.providerID,
                    data: data
                )
            }
        await notificationEvaluator.evaluate(
            metrics: metrics,
            toggles: toggles,
            now: now,
            providerName: { [providersByID] id in providersByID[id]?.provider.displayName ?? id },
            post: postNotification
        )
    }

    /// Picks the provider IDs a refresh pass should hit. `.full` and `.panelMeters` refresh every
    /// enabled provider (pinned first so the panel paints the strip quickly); `.panelMeters` is
    /// the panel-open meters phase and must not be narrowed to pinned providers, or the
    /// dashboard's unpinned cards would wait for phase 2 to show meters. `.menuBar` only refreshes
    /// providers that power pinned strip meters, plus providers with visible bounded metrics when
    /// quota notifications are enabled. `.localAccounting` refreshes only the providers that fold
    /// local usage corpora (enabled Codex cards, plus OpenCode only while Codex is an enabled source)
    /// — the wake sources for that scope are CodexRouter ledger appends, so unrelated providers have
    /// nothing new to read. `.panelAccounting`
    /// selects every enabled provider; the store narrows it to history exporters, which only the
    /// registry knows.
    static func selectProviderIDsForRefresh(
        enabledProviderIDs: [String],
        scope: ProviderRefreshContext.Scope,
        pinnedMetricIDs: Set<String>,
        providerIDForMetric: (String) -> String?,
        orderedDescriptors: [WidgetDescriptor],
        notificationsEnabled: Bool,
        hiddenMenuBarProviderIDs: Set<String> = []
    ) -> [String] {
        let notificationRelevant = MenuBarRefreshFilter.notificationRelevantProviderIDs(
            descriptors: orderedDescriptors
        )
        switch scope {
        case .localAccounting:
            // This scope is driven by CodexRouter ledger appends. OpenCode only needs that wake while
            // at least one Codex card is enabled as a ledger source; otherwise an off Codex card's
            // writes would unnecessarily start OpenCode's unrelated local database fold.
            guard enabledProviderIDs.contains(where: { ProviderAccountID.family(of: $0) == "codex" }) else {
                return []
            }
            return enabledProviderIDs.filter {
                let family = ProviderAccountID.family(of: $0)
                return family == "codex" || family == "opencode"
            }
        case .full, .panelMeters, .panelAccounting:
            return MenuBarRefreshFilter.prioritize(
                providerIDs: enabledProviderIDs,
                pinnedMetricIDs: pinnedMetricIDs,
                providerIDForMetric: providerIDForMetric,
                notificationRelevantProviderIDs: notificationRelevant,
                notificationsEnabled: notificationsEnabled
            )
        case .menuBar:
            return MenuBarRefreshFilter.providerIDs(
                enabledProviderIDs: enabledProviderIDs,
                pinnedMetricIDs: pinnedMetricIDs,
                providerIDForMetric: providerIDForMetric,
                notificationRelevantProviderIDs: notificationRelevant,
                notificationsEnabled: notificationsEnabled,
                hiddenProviderIDs: hiddenMenuBarProviderIDs
            )
        }
    }

    /// What a single provider's refresh actually did this pass, so `refreshAll` can summarize the batch
    /// from real outcomes rather than cumulative error state. `.backedOff` is a probe deliberately skipped
    /// because the provider failed within the last `failureRetryBackoff` — distinct from `.skipped`
    /// (disabled / unknown / already in flight) so a wake-burst's suppression is visible in the logs.
    struct DeferredRefreshRequest: Hashable, Sendable {
        let providerID: String
        let scope: ProviderRefreshContext.Scope
        let bypassSnapshotCache: Bool
        let bypassFailureBackoff: Bool
        let requestGeneration: UInt64
        let manualActionID: UInt64?
        let credentialInteractionGate: CredentialInteractionGate?

        init(
            providerID: String,
            scope: ProviderRefreshContext.Scope,
            bypassSnapshotCache: Bool,
            bypassFailureBackoff: Bool,
            requestGeneration: UInt64,
            manualActionID: UInt64? = nil,
            credentialInteractionGate: CredentialInteractionGate? = nil
        ) {
            self.providerID = providerID
            self.scope = scope
            self.bypassSnapshotCache = bypassSnapshotCache
            self.bypassFailureBackoff = bypassFailureBackoff
            self.requestGeneration = requestGeneration
            self.manualActionID = manualActionID
            self.credentialInteractionGate = credentialInteractionGate
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.providerID == rhs.providerID
                && lhs.scope == rhs.scope
                && lhs.bypassSnapshotCache == rhs.bypassSnapshotCache
                && lhs.bypassFailureBackoff == rhs.bypassFailureBackoff
                && lhs.requestGeneration == rhs.requestGeneration
                && lhs.manualActionID == rhs.manualActionID
                && lhs.credentialInteractionGate === rhs.credentialInteractionGate
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(providerID)
            hasher.combine(scope)
            hasher.combine(bypassSnapshotCache)
            hasher.combine(bypassFailureBackoff)
            hasher.combine(requestGeneration)
            hasher.combine(manualActionID)
            hasher.combine(credentialInteractionGate.map { ObjectIdentifier($0) })
        }
    }

    enum RefreshOutcome: Sendable, Equatable { case refreshed, failed, cacheHit, skipped, inFlight, backedOff }

    @discardableResult
    func refresh(
        providerID: String,
        force: Bool = false,
        notifyHistoryChange: Bool = true,
        bypassSnapshotCache: Bool = false,
        bypassFailureBackoff: Bool = false
    ) async -> RefreshOutcome {
        guard isProviderEnabled(providerID) else { return .skipped }
        let requestGeneration = beginProviderRequest(
            providerID: providerID,
            manualActionID: ProviderRefreshContext.manualActionID
        )
        let taskID = UUID()
        let task: Task<RefreshOutcome, Never> = Task { @MainActor [weak self] in
            guard let self else { return RefreshOutcome.skipped }
            return await self.performRefresh(
                providerID: providerID,
                taskID: taskID,
                requestGeneration: requestGeneration,
                force: force,
                bypassSnapshotCache: bypassSnapshotCache,
                notifyHistoryChange: notifyHistoryChange,
                bypassFailureBackoff: bypassFailureBackoff
            )
        }
        registerProviderRefreshTask(
            task, id: taskID, providerID: providerID, scope: ProviderRefreshContext.scope
        )
        defer { unregisterProviderRefreshTask(taskID, providerID: providerID) }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Refresh just the provider's local usage history after a visible quota retry.
    /// The panel accounting phase is only meaningful for history exporters; running it against a
    /// pure API provider would repeat its live requests. Keep the retry's action identity so a newer
    /// manual refresh makes this delayed fold stale, and leave `force` off so conflicting work can
    /// defer this provider-local fold. The store still merges its partial result with any quota meters
    /// phase one recovered. Bypass the just-written failure backoff so a failed quota attempt can
    /// still leave useful local history.
    func refreshProviderHistoryAfterRetry(
        providerID: String,
        manualActionID: UInt64?,
        credentialInteractionGate: CredentialInteractionGate? = nil
    ) async -> RefreshOutcome {
        guard registry.historyDescriptorsByProvider[providerID] != nil,
              providersByID[providerID]?.panelMetersRefreshIncludesHistory != true
        else { return .skipped }
        return await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await ProviderRefreshContext.$isManual.withValue(manualActionID != nil) {
                await ProviderRefreshContext.$credentialInteractionGate.withValue(
                    credentialInteractionGate
                ) {
                    await ProviderRefreshContext.$manualActionID.withValue(manualActionID) {
                        await ProviderRefreshContext.$accountingCPUInteractiveBudgetEnabled.withValue(true) {
                            await ProviderRefreshContext.$accountingCPUThrottleEnabled.withValue(true) {
                                await refresh(
                                    providerID: providerID,
                                    force: false,
                                    bypassSnapshotCache: true,
                                    bypassFailureBackoff: true
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    /// Resume a visible retry's history fold after conflicting provider work has ended.
    /// Carry its original Keychain action through the scheduler wake so the delayed pass does not
    /// become a silent global accounting refresh.
    func resumeDeferredManualHistoryRetry(_ request: DeferredRefreshRequest) async -> RefreshOutcome {
        guard request.scope == .panelAccounting,
              let manualActionID = request.manualActionID,
              isProviderEnabled(request.providerID),
              isCurrentProviderRequest(
                  providerID: request.providerID,
                  generation: request.requestGeneration
              )
        else { return .skipped }
        return await refreshProviderHistoryAfterRetry(
            providerID: request.providerID,
            manualActionID: manualActionID,
            credentialInteractionGate: request.credentialInteractionGate
        )
    }

    private func registerProviderRefreshTask(
        _ task: Task<RefreshOutcome, Never>,
        id: UUID,
        providerID: String,
        scope: ProviderRefreshContext.Scope,
        batchID: UUID? = nil
    ) {
        activeProviderRefreshTasks[providerID, default: [:]][id] = task
        activeProviderRefreshTaskScopes[providerID, default: [:]][id] = scope
        if let batchID {
            activeProviderRefreshTaskBatchIDs[providerID, default: [:]][id] = batchID
        }
    }

    private func unregisterProviderRefreshTask(_ id: UUID, providerID: String) {
        activeProviderRefreshTasks[providerID]?[id] = nil
        activeProviderRefreshTaskScopes[providerID]?[id] = nil
        activeProviderRefreshTaskBatchIDs[providerID]?[id] = nil
        if activeProviderRefreshTasks[providerID]?.isEmpty == true {
            activeProviderRefreshTasks[providerID] = nil
            activeProviderRefreshTaskScopes[providerID] = nil
            activeProviderRefreshTaskBatchIDs[providerID] = nil
        }
        emitReadyDeferredRefreshes(for: providerID)
    }

    private func emitReadyDeferredRefreshes(for providerID: String) {
        guard let requests = deferredRefreshRequests[providerID], !requests.isEmpty else { return }
        let activeScopes = Array(runningProviderRefreshScopes[providerID, default: [:]].values)
        let ready = requests.filter { request in
            activeScopes.isEmpty || Self.mayOverlapMeterRefresh(request.scope, with: activeScopes)
        }
        guard !ready.isEmpty else { return }
        deferredRefreshRequests[providerID] = requests.subtracting(ready)
        if deferredRefreshRequests[providerID]?.isEmpty == true {
            deferredRefreshRequests[providerID] = nil
        }
        for request in ready {
            AppLog.debug(.refresh, "deferred refresh ready \(providerID) (scope=\(Self.batchScopeLabel(request.scope)))")
            onDeferredRefreshReady?(request)
        }
    }

    /// Cancels scheduler-owned accounting work when its loop shuts down. Meter tasks keep running so
    /// app teardown does not accidentally cancel an unrelated manual or visible-panel request.
    func cancelProviderRefreshes(scopes: [ProviderRefreshContext.Scope]) {
        for (providerID, tasks) in activeProviderRefreshTasks {
            for (id, task) in tasks where scopes.contains(activeProviderRefreshTaskScopes[providerID]?[id] ?? .full) {
                task.cancel()
            }
        }
    }

    /// A provider catalog replacement owns a new refresh store. Stop every request and batch that
    /// belongs to this instance before the replacement starts, so a retired manual refresh cannot
    /// keep making requests or trying interactive credential reads beside the new scheduler.
    func cancelActiveProviderRefreshesForCatalogReload() {
        for batch in activeBatches.values { batch.cancel() }
        for tasks in activeProviderRefreshTasks.values {
            for task in tasks.values { task.cancel() }
        }
        deferredRefreshRequests.removeAll()
    }

    private func cancelProviderRefreshes(batchID: UUID) {
        for (providerID, tasks) in activeProviderRefreshTasks {
            for (id, task) in tasks where activeProviderRefreshTaskBatchIDs[providerID]?[id] == batchID {
                task.cancel()
            }
        }
    }

    /// Returns a stable per-provider request generation. Two refreshes in one manual action share one
    /// generation; a later action advances it once for each provider it covers. A superseded action
    /// that reaches this store late receives a sentinel that cannot publish.
    private func nextProviderRefreshRequestOrder(_ providerID: String) -> UInt64 {
        let next = providerRefreshRequestOrders[providerID, default: 0] &+ 1
        providerRefreshRequestOrders[providerID] = next
        return next
    }

    private func beginProviderRequest(providerID: String, manualActionID: UInt64?) -> UInt64 {
        let current = providerRequestGenerations[providerID, default: 0]
        guard let manualActionID else { return current }
        if let invalidatedThrough = invalidatedManualActionsThrough[providerID],
           manualActionID <= invalidatedThrough
        {
            return UInt64.max
        }
        if let latestAction = latestManualActionByProvider[providerID] {
            if manualActionID == latestAction { return current }
            if manualActionID < latestAction { return UInt64.max }
        }
        latestManualActionByProvider[providerID] = manualActionID
        let next = current &+ 1
        providerRequestGenerations[providerID] = next
        return next
    }

    private func isCurrentProviderRequest(providerID: String, generation: UInt64) -> Bool {
        generation != UInt64.max && providerRequestGenerations[providerID, default: 0] == generation
    }

    /// A global manual action may supersede an unrelated provider's Keychain read. Retry that card
    /// once in a silent task if no newer request owns it; the old action cannot spend another prompt.
    private func scheduleSilentSupersessionRetry(
        providerID: String,
        requestGeneration: UInt64,
        scope: ProviderRefreshContext.Scope
    ) {
        guard isCurrentProviderRequest(providerID: providerID, generation: requestGeneration),
              isProviderEnabled(providerID)
        else { return }
        AppLog.debug(.refresh, "superseded manual action; scheduling silent retry for \(providerID)")
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  self.isCurrentProviderRequest(providerID: providerID, generation: requestGeneration),
                  self.isProviderEnabled(providerID)
            else { return }
            await ProviderRefreshContext.$scope.withValue(scope) {
                await ProviderRefreshContext.$isManual.withValue(false) {
                    await ProviderRefreshContext.$credentialInteractionGate.withValue(nil) {
                        await ProviderRefreshContext.$manualActionID.withValue(nil) {
                            await ProviderRefreshContext.$accountingCPUInteractiveBudgetEnabled.withValue(true) {
                                let foldOnly = scope.suppressesLiveQuota
                                let outcome = await self.refresh(
                                    providerID: providerID,
                                    force: !foldOnly,
                                    bypassSnapshotCache: foldOnly,
                                    bypassFailureBackoff: foldOnly
                                )
                                // A visible retry's first (meters) phase may have been cancelled when a
                                // newer manual action arrived for another card. Once its silent meters
                                // retry recovers this provider, perform the missing local fold too.
                                // A newer request for this same provider owns the generation and must win.
                                if scope == .panelMeters,
                                   outcome == .refreshed || outcome == .failed,
                                   self.isCurrentProviderRequest(
                                       providerID: providerID,
                                       generation: requestGeneration
                                   )
                                {
                                    _ = await self.refreshProviderHistoryAfterRetry(
                                        providerID: providerID,
                                        manualActionID: nil
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func performRefresh(
        providerID: String,
        taskID: UUID,
        requestGeneration: UInt64,
        force: Bool,
        bypassSnapshotCache: Bool,
        notifyHistoryChange: Bool,
        bypassFailureBackoff: Bool = false
    ) async -> RefreshOutcome {
        guard isProviderEnabled(providerID) else { return .skipped }
        let manualActionID = ProviderRefreshContext.manualActionID
        guard isCurrentProviderRequest(providerID: providerID, generation: requestGeneration) else {
            return .skipped
        }
        let requestOrder = nextProviderRefreshRequestOrder(providerID)
        if let manualActionID,
           !KeychainPermissionGate.shared.isCurrentManualAction(manualActionID)
        {
            scheduleSilentSupersessionRetry(
                providerID: providerID,
                requestGeneration: requestGeneration,
                scope: ProviderRefreshContext.scope
            )
            return .skipped
        }
        // A TTL-fresh entry that provably belongs to another account (swap since it was written) must
        // not short-circuit the refresh — under persisted freshness (the one-shot CLI) it would copy
        // the previous account's snapshot back in. Treat it as a miss so the fetch overwrites it.
        let staleAccountStamp = cache.hasStaleAccountStamp(
            providerID: providerID,
            currentIdentityKey: providerIdentityKeys[providerID]
        )
        let freshnessInterval = ProviderRefreshContext.scope.skipsLocalAccounting
            ? RefreshSetting.quotaCacheInterval
            : nil
        if !force, !bypassSnapshotCache, !staleAccountStamp,
           let cachedSnapshot = cache.snapshot(providerID: providerID, freshnessInterval: freshnessInterval) {
            var cached = cachedSnapshot
            if let history = cached.usageHistory {
                let compacted = history.retainingHistory(through: now())
                if compacted != history {
                    cached.usageHistory = compacted
                    cache.compactHistory(providerID: providerID, through: now())
                }
            }
            // A menu-bar merge re-stamps `refreshedAt` for the meters it computed, but its history
            // was only carried over from the last full pass. Honoring that stamp here would let
            // every menu-bar tick (one per TTL) keep vouching for history no pass ever recomputed —
            // the spend tiles and unknown-model warnings would go stale forever. A full pass
            // therefore treats carried history as stale and re-runs the provider; a menu-bar pass
            // keeps the hit (it skips the deferred work by design). `panelMeters` behaves like
            // `menuBar`: meters-only work, prior history carried.
            //
            // The panel's accounting phase additionally falls through when the cached snapshot
            // carries NO history at all (fresh install, newly enabled provider, a scan that has
            // never produced rows): otherwise it would cache-hit on the meters-only phase's write
            // and the first fold would never run. `.full` keeps its TTL contract — a fresh
            // snapshot with no history is legitimately fresh, because a full pass is the fold.
            let foldPhaseNeedsFirstFold = ProviderRefreshContext.scope == .panelAccounting
                && cached.usageHistory == nil
            if ProviderRefreshContext.scope.skipsLocalAccounting
                || (cached.carriesPriorHistory != true && !foldPhaseNeedsFirstFold) {
                // Skip the no-op write: `@Observable` doesn't compare values, so unconditionally
                // re-assigning an unchanged snapshot would re-render the menu-bar label every pass.
                AppLog.debug(.refresh, "cache hit \(providerID)")
                if localSnapshots[providerID] != cached {
                    if localSnapshots[providerID]?.usageHistory != cached.usageHistory {
                        localHistoryRevision &+= 1
                        invalidateMergedHistoryCache()
                    }
                    localSnapshots[providerID] = cached
                    rebuildRenderedSnapshots()
                }
                return .cacheHit
            }
            AppLog.info(.refresh, "\(providerID) history carried from menu-bar merge — recompute in full pass")
        }
        if !force {
            let reason = bypassSnapshotCache ? "scheduled cache bypass" : "cache miss"
            AppLog.debug(.refresh, "\(reason) \(providerID)")
        }

        // A provider that just failed isn't cached, so nothing else stops the loop from re-probing it on
        // every wake. Map the requested scope to the work it actually performs: full failures share
        // backoff with their quota/accounting phases, and local-only providers such as Hermes use the
        // accounting domain even during `.panelMeters`.
        let scope = ProviderRefreshContext.scope
        let failureDomains = failureDomains(for: providerID, scope: scope)
        let failureBackoffKeys = failureDomains.map {
            FailureBackoffKey(providerID: providerID, domain: $0)
        }
        let checkTime = now()
        if !force, !bypassFailureBackoff,
           failureBackoffKeys.contains(where: { key in
               guard let retryAfter = failureRetryAfter[key] else { return false }
               return checkTime < retryAfter
           }) {
            AppLog.debug(.refresh, "backoff skip \(providerID) (failed <\(Int(Self.failureRetryBackoff))s ago)")
            return .backedOff
        }

        guard let provider = providersByID[providerID] else { return .skipped }
        // Skip if an in-flight refresh already owns this provider (e.g. the background timer racing the
        // first popover open), so we never fire duplicate network calls for the same provider.
        // Forced refreshes (panel open / manual Refresh) must not bail: wait for incompatible in-flight
        // work, then run the caller's requested scope. A forced panel-meter retry is the exception when
        // only fold-only work is active: meters skip local accounting and folds skip live quota, so this
        // uses the same safe overlap as an ordinary due meter pass. Otherwise a menuBar tick in flight at
        // open time would leave the panel on quota-only merge data and the cache TTL could block the next
        // full pass.
        if refreshingProviderIDs.contains(providerID) {
            let activeScopes = Array(runningProviderRefreshScopes[providerID, default: [:]].values)
            let requestedScope = ProviderRefreshContext.scope
            let canOverlapFold = Self.mayOverlapMeterRefresh(requestedScope, with: activeScopes)
            if canOverlapFold && (!force || requestedScope == .panelMeters) {
                AppLog.debug(.refresh, "meter refresh overlaps fold-only work for \(providerID)")
            } else if !force {
                AppLog.debug(.refresh, "cache skip \(providerID) (already in flight)")
                deferredRefreshRequests[providerID, default: []].insert(DeferredRefreshRequest(
                    providerID: providerID,
                    scope: ProviderRefreshContext.scope,
                    bypassSnapshotCache: bypassSnapshotCache,
                    bypassFailureBackoff: bypassFailureBackoff,
                    requestGeneration: requestGeneration,
                    manualActionID: ProviderRefreshContext.manualActionID,
                    credentialInteractionGate: ProviderRefreshContext.credentialInteractionGate
                ))
                return .inFlight
            } else {
                AppLog.debug(.refresh, "force wait \(providerID) (already in flight)")
                // Bounded and sleeping. `Task.yield()` here was a hot spin on the MainActor, and the loop
                // had no deadline at all, so a waiter could outlive the pass it was waiting for.
                let waitDeadline = monotonicNow() + Self.defaultProviderRefreshTimeout + Self.forceWaitGrace
                var delay = Self.forceWaitInitialDelay
                while !runningProviderRefreshScopes[providerID, default: [:]].isEmpty {
                    guard !Task.isCancelled,
                          isProviderEnabled(providerID),
                          isCurrentProviderRequest(providerID: providerID, generation: requestGeneration)
                    else { return .skipped }
                    guard KeychainPermissionGate.shared.isCurrentManualAction(manualActionID) else {
                        scheduleSilentSupersessionRetry(
                            providerID: providerID,
                            requestGeneration: requestGeneration,
                            scope: ProviderRefreshContext.scope
                        )
                        return .skipped
                    }
                    if monotonicNow() >= waitDeadline {
                        AppLog.info(
                            .refresh,
                            "force wait gave up \(providerID) (still in flight past the deadline)"
                        )
                        return .skipped
                    }
                    // `try?` because cancellation throws here; the `isCancelled` check above acts on it.
                    try? await Task.sleep(for: .seconds(delay))
                    delay = min(delay * 2, Self.forceWaitMaxDelay)
                }
            }
        }
        guard !Task.isCancelled,
              isProviderEnabled(providerID),
              isCurrentProviderRequest(providerID: providerID, generation: requestGeneration)
        else { return .skipped }
        guard KeychainPermissionGate.shared.isCurrentManualAction(manualActionID) else {
            scheduleSilentSupersessionRetry(
                providerID: providerID,
                requestGeneration: requestGeneration,
                scope: ProviderRefreshContext.scope
            )
            return .skipped
        }
        runningProviderRefreshScopes[providerID, default: [:]][taskID] = ProviderRefreshContext.scope
        // Only write when the membership actually changes: `@Observable` publishes every write, and
        // `refreshingProviderIDs` is a single slot that every provider card observes.
        if !refreshingProviderIDs.contains(providerID) {
            refreshingProviderIDs.insert(providerID)
        }
        defer {
            runningProviderRefreshScopes[providerID]?[taskID] = nil
            if runningProviderRefreshScopes[providerID]?.isEmpty == true {
                runningProviderRefreshScopes[providerID] = nil
                if refreshingProviderIDs.contains(providerID) {
                    refreshingProviderIDs.remove(providerID)
                }
            }
        }
        // App and CLI share persisted snapshots but have independent in-process request generations.
        // The cache order fences a slower result if a newer refresh starts in the other process.
        let cacheRefreshOrder = cache.beginRefreshOrder(providerID: providerID)
        let start = monotonicNow()
        // A provider that never returns would otherwise hold the in-flight entry — and the spinner —
        // forever. Past the deadline, stop waiting and treat it as any other failed refresh.
        let cacheIdentityResult = ProviderCacheIdentityResult()
        let fetchedSnapshot = await ProviderRefreshContext.$cacheIdentityResult.withValue(cacheIdentityResult) {
            await ProviderRefreshDeadline.snapshot(from: provider, timeout: providerRefreshTimeout)
        }
        guard isCurrentProviderRequest(providerID: providerID, generation: requestGeneration) else {
            AppLog.debug(.refresh, "superseded provider request (\(providerID)); discarding stale result")
            return .skipped
        }
        if let cacheRefreshOrder,
           !cache.isCurrentRefresh(
            providerID: providerID,
            order: cacheRefreshOrder,
            scope: scope,
            hasHistoryDomain: registry.historyDescriptorsByProvider[providerID] != nil,
            panelMetersIncludesHistory: providersByID[providerID]?.panelMetersRefreshIncludesHistory == true
           )
        {
            AppLog.debug(.refresh, "superseded cross-process provider request (\(providerID))")
            return .skipped
        }
        if let identityKey = cacheIdentityResult.value {
            let lastIdentityOrder = providerIdentityResolutionOrders[providerID, default: 0]
            let currentIdentityKey = providerIdentityKeys[providerID]
            if requestOrder < lastIdentityOrder, currentIdentityKey != identityKey {
                AppLog.debug(.cache, "discarding stale account result for \(providerID)")
                if !ProviderRefreshContext.scope.skipsLocalAccounting,
                   registry.historyDescriptorsByProvider[providerID] != nil
                {
                    deferredRefreshRequests[providerID, default: []].insert(DeferredRefreshRequest(
                        providerID: providerID,
                        scope: .panelAccounting,
                        bypassSnapshotCache: true,
                        bypassFailureBackoff: true,
                        requestGeneration: requestGeneration
                    ))
                }
                return .skipped
            }
            if requestOrder >= lastIdentityOrder {
                providerIdentityResolutionOrders[providerID] = requestOrder
            }
            guard updateProviderCacheIdentity(
                to: identityKey,
                providerID: providerID,
                notifyHistoryChange: notifyHistoryChange,
                refreshOrder: cacheRefreshOrder
            ) else { return .skipped }
        }
        guard var snapshot = fetchedSnapshot else {
            // A disabled provider's non-cooperative work can outlive the deadline after its task was
            // cancelled. Do not turn that cancellation into a timeout failure: the provider may have
            // been re-enabled in the meantime, and the stale task must not restore failure backoff.
            guard !Task.isCancelled, isProviderEnabled(providerID) else {
                AppLog.debug(.refresh, "cancelled or disabled \(providerID) refresh reached deadline; skipping")
                return .skipped
            }
            if let manualActionID,
               !KeychainPermissionGate.shared.isCurrentManualAction(manualActionID)
            {
                scheduleSilentSupersessionRetry(
                    providerID: providerID,
                    requestGeneration: requestGeneration,
                    scope: ProviderRefreshContext.scope
                )
                return .skipped
            }
            let message = "Refresh timed out after \(Int(providerRefreshTimeout))s"
            recordProviderFailure(message, category: .network, for: providerID, domains: failureDomains)
            let retryAfter = now().addingTimeInterval(Self.failureRetryBackoff)
            for key in failureBackoffKeys { failureRetryAfter[key] = retryAfter }
            AppLog.warn(.refresh, "\(providerID) timed out after \(Int(providerRefreshTimeout))s")
            onRefreshOutcome?(providerID, .failed, .network, force)
            return .failed
        }
        // A canceled refresh may still return if a provider's underlying work is non-throwing. Never
        // publish that potentially partial snapshot; keep the last-good state exactly as it was.
        guard !Task.isCancelled, isProviderEnabled(providerID) else {
            AppLog.debug(.refresh, "cancelled or disabled \(providerID) refresh; keeping last-good snapshot")
            return .skipped
        }
        if snapshot.errorCategory == .cancelled {
            if let manualActionID,
               !KeychainPermissionGate.shared.isCurrentManualAction(manualActionID)
            {
                scheduleSilentSupersessionRetry(
                    providerID: providerID,
                    requestGeneration: requestGeneration,
                    scope: ProviderRefreshContext.scope
                )
            }
            AppLog.debug(.refresh, "provider refresh cancelled (\(providerID)); keeping last-good snapshot")
            return .skipped
        }
        let durationMs = durationMilliseconds(since: start)
        if TimeInterval(durationMs) >= slowProviderRefreshThreshold * 1000 {
            AppLog.warn(
                .refresh,
                "\(providerID) slow refresh (\(durationMs)ms, threshold=\(Int(slowProviderRefreshThreshold * 1000))ms)"
            )
        }
        if let message = Self.errorMessage(in: snapshot) {
            // Failed refresh: surface the error but keep the last good snapshot on screen rather than
            // collapsing every row to "No data". A provider may explicitly invalidate quota state
            // when the failure proves that a prior subscription/credential no longer applies; keep
            // its spend history while dropping the stale plan and progress rows.
            if snapshot.clearsPriorMenuBarQuotaState == true,
               (!ProviderRefreshContext.scope.suppressesLiveQuota || snapshot.invalidatesQuotaIdentity == true)
            {
                // Quota and history have independent commit orders. A newer meter pass can supersede
                // this clear while this full result still carries the newest valid history.
                _ = clearPriorQuotaState(for: providerID, refreshOrder: cacheRefreshOrder)
            }
            guard mergeHistoryFromFailedRefresh(
                snapshot,
                providerID: providerID,
                notifyHistoryChange: notifyHistoryChange,
                refreshOrder: cacheRefreshOrder
            ) else { return .skipped }
            recordProviderFailure(
                message,
                category: snapshot.errorCategory,
                for: providerID,
                domains: failureDomains
            )
            // Negative-cache the failure so a wake burst can't re-probe this provider in a tight loop.
            let retryAfter = now().addingTimeInterval(Self.failureRetryBackoff)
            for key in failureBackoffKeys { failureRetryAfter[key] = retryAfter }
            let failureIdentity = ProviderFailureLogIdentity(message: message, category: snapshot.errorCategory)
            let priorLoggedFailures = lastLoggedProviderFailure[providerID, default: [:]]
            if failureDomains.contains(where: { priorLoggedFailures[$0] != failureIdentity })
                || (force
                    && snapshot.errorCategory != .credentialAccess
                    && snapshot.errorCategory != .authInvalid
                    && snapshot.errorCategory != .notLoggedIn)
            {
                AppLog.warn(.refresh, "\(providerID) failed: \(message)")
                var loggedFailures = priorLoggedFailures
                for domain in failureDomains { loggedFailures[domain] = failureIdentity }
                lastLoggedProviderFailure[providerID] = loggedFailures
            }
            onRefreshOutcome?(providerID, .failed, snapshot.errorCategory, force)
            return .failed
        }
        clearProviderFailure(for: providerID, domains: failureDomains, clearAll: scope == .full)
        // Recovered: drop the matching backoff so that work resumes its normal cadence immediately.
        if scope == .full {
            clearFailureBackoff(for: providerID)
        } else {
            for key in failureBackoffKeys { failureRetryAfter[key] = nil }
        }
        if let history = snapshot.usageHistory {
            snapshot.usageHistory = history.retainingHistory(through: now())
        }
        // Keep the provider's raw result separate from this process's local composite. The cache
        // combines partial domains with the newest persisted snapshot under its cross-process lock.
        var snapshotForCache = snapshot
        // A provider can refresh its live limits successfully while its optional local log/CSV scan
        // produces no result. Keep only the last-good normalized history in that case; the new plan,
        // limits, warnings, and timestamp still win. A non-nil empty history remains authoritative and
        // clears the old rows, because it proves the scan completed and found no usage.
        // Full-scope refreshes replace the snapshot. Menu-bar, panel-meter, and fold-only scopes
        // merge their partial result even when forced: `force` bypasses cache/in-flight policy, while
        // the scope still controls which parts of this snapshot were actually recomputed.
        if ProviderRefreshContext.scope != .full {
            // Meters-only pass: keep prior spend/token/chart lines and usageHistory so the panel
            // does not blank those rows between opens. Fresh meters still win on label collision;
            // omitted meters (incomplete localOnly pass) are preserved by the merge helper. A
            // fold-only pass (localAccounting / panelAccounting) is the mirror image: fresh
            // usageHistory, no live quota meters,
            // and the same helper recovers the meters from the prior snapshot.
            snapshot = snapshot.mergingMenuBarUpdate(over: localSnapshots[providerID])
            if ProviderRefreshContext.scope.suppressesLiveQuota,
               providerHasQuotaMetrics(providerID),
               !Self.hasQuotaProgress(snapshot.lines),
               !Self.hasQuotaProgress(localSnapshots[providerID]?.lines ?? [])
            {
                // A first-run fold has no prior meter stamp to carry. It must not make the failed
                // or skipped quota request look fresh just because local history completed.
                snapshot.quotaRefreshedAt = .distantPast
                snapshotForCache.quotaRefreshedAt = .distantPast
            }
        } else if snapshot.usageHistory == nil,
           let history = localSnapshots[providerID]?.usageHistory,
           let descriptor = registry.historyDescriptorsByProvider[providerID]
        {
            // Preserved, not computed this pass: a later full pass must re-run the scan rather than
            // trust this snapshot's freshness stamp (see `carriesPriorHistory`).
            snapshot.carriesPriorHistory = true
            snapshot.usageHistory = history
            snapshot.historyRefreshedAt = localSnapshots[providerID]?.historyRefreshedAt
                ?? localSnapshots[providerID]?.refreshedAt
            snapshot = UsageHistorySnapshotRenderer.render(
                local: snapshot,
                history: history,
                descriptor: descriptor,
                now: now(),
                combined: false
            )
            snapshotForCache = snapshot
            AppLog.debug(.refresh, "preserved last-good history for \(providerID) after scan miss")
        }
        let cacheWrite = cache.store(
            snapshotForCache,
            producedByIdentityKey: providerIdentityKeys[providerID],
            refreshOrder: cacheRefreshOrder,
            scope: scope,
            historyDescriptor: registry.historyDescriptorsByProvider[providerID],
            panelMetersIncludesHistory: providersByID[providerID]?.panelMetersRefreshIncludesHistory == true,
            now: now()
        )
        var persistedToBlob = true
        var historyChanged = false
        switch cacheWrite {
        case .stored(let persistedSnapshot):
            if let persistedSnapshot { snapshot = persistedSnapshot }
        case .unchanged(let persistedSnapshot):
            if let persistedSnapshot { snapshot = persistedSnapshot }
        case .superseded(let newerSnapshot):
            let historyChanged = localSnapshots[providerID]?.usageHistory != newerSnapshot?.usageHistory
            if let newerSnapshot {
                localSnapshots[providerID] = newerSnapshot
            } else {
                localSnapshots[providerID] = nil
            }
            if historyChanged {
                localHistoryRevision &+= 1
                invalidateMergedHistoryCache()
            }
            rebuildRenderedSnapshots()
            if notifyHistoryChange, historyChanged { onLocalHistoryChanged?() }
            return .skipped
        case .unavailable:
            // The write could not be persisted (the shared lock or an encode failure). Keep the
            // in-memory copy aligned with the blob instead of adopting a value the blob never saw:
            // the store merges over its own copy while the cache merges over the persisted one, so
            // a divergent copy is folded over on the next pass and rolls the card back to older
            // data. Loud, because the fresh values are dropped until the next pass.
            persistedToBlob = false
            AppLog.error(
                .cache,
                "\(providerID) snapshot could not be persisted; keeping the last persisted values"
            )
        }
        if persistedToBlob {
            historyChanged = localSnapshots[providerID]?.usageHistory != snapshot.usageHistory
            localSnapshots[providerID] = snapshot
            if historyChanged {
                localHistoryRevision &+= 1
                invalidateMergedHistoryCache()
            }
        }
        rebuildRenderedSnapshots()
        if notifyHistoryChange, historyChanged { onLocalHistoryChanged?() }
        AppLog.info(.refresh, "\(providerID) ok (\(durationMs)ms)")
        onRefreshOutcome?(providerID, .refreshed, nil, force)
        // Local-log providers can allocate large parse arrays. Their bounded warm caches remain in
        // place below the process budget and are released when that budget is crossed.
        if Self.isHeavyLocalLogProvider(providerID) {
            await PersistentJSONLScanCaches.unloadAfterHeavyProvider(providerID: providerID)
        } else if ProcessMemoryBudget.isOverSoftLimit {
            await PersistentJSONLScanCaches.unloadAfterHeavyProvider(providerID: providerID)
        }
        return .refreshed
    }

    /// A provider can still produce useful local usage history while its quota API is unavailable.
    /// Merge that history into the last-good display without clearing the provider error or making
    /// preserved quota meters look freshly checked. A first-run history-only snapshot gets an old
    /// quota stamp so the next normal refresh still probes the live API.
    private func mergeHistoryFromFailedRefresh(
        _ failedSnapshot: ProviderSnapshot,
        providerID: String,
        notifyHistoryChange: Bool,
        refreshOrder: UInt64?
    ) -> Bool {
        guard let incomingHistory = failedSnapshot.usageHistory,
              let descriptor = registry.historyDescriptorsByProvider[providerID]
        else { return true }

        let previous = localSnapshots[providerID]
        let history = incomingHistory.retainingHistory(through: now())
        var updated = previous ?? ProviderSnapshot(
            providerID: failedSnapshot.providerID,
            displayName: failedSnapshot.displayName,
            lines: [],
            refreshedAt: failedSnapshot.refreshedAt
        )
        let hasPreviousQuota = Self.hasQuotaProgress(previous?.lines ?? [])
        let previousQuotaStamp = previous.map { $0.quotaRefreshedAt ?? $0.refreshedAt }
        updated.refreshedAt = failedSnapshot.refreshedAt
        updated.quotaRefreshedAt = hasPreviousQuota ? previousQuotaStamp : .distantPast
        updated.historyRefreshedAt = failedSnapshot.historyRefreshedAt ?? failedSnapshot.refreshedAt
        if failedSnapshot.usageHistory != nil || failedSnapshot.historyWarning != nil {
            updated.historyWarning = failedSnapshot.historyWarning
        }
        updated = UsageHistorySnapshotRenderer.render(
            local: updated,
            history: history,
            descriptor: descriptor,
            now: now(),
            combined: false
        )

        var historyOnly = ProviderSnapshot(
            providerID: failedSnapshot.providerID,
            displayName: failedSnapshot.displayName,
            lines: [],
            refreshedAt: failedSnapshot.refreshedAt,
            usageHistory: history,
            historyWarning: failedSnapshot.historyWarning
        )
        historyOnly = UsageHistorySnapshotRenderer.render(
            local: historyOnly,
            history: history,
            descriptor: descriptor,
            now: now(),
            combined: false
        )
        historyOnly.quotaRefreshedAt = .distantPast
        let cacheResult = cache.store(
            historyOnly,
            producedByIdentityKey: providerIdentityKeys[providerID],
            refreshOrder: refreshOrder,
            scope: .panelAccounting,
            historyDescriptor: descriptor,
            now: now()
        )
        var persistedToBlob = true
        var historyChanged = false
        switch cacheResult {
        case .stored(let persistedSnapshot):
            if let persistedSnapshot { updated = persistedSnapshot }
        case .unchanged(let persistedSnapshot):
            if let persistedSnapshot { updated = persistedSnapshot }
        case .superseded(let newerSnapshot):
            let historyChanged = previous?.usageHistory != newerSnapshot?.usageHistory
            localSnapshots[providerID] = newerSnapshot
            if historyChanged {
                localHistoryRevision &+= 1
                invalidateMergedHistoryCache()
            }
            rebuildRenderedSnapshots()
            if notifyHistoryChange, historyChanged { onLocalHistoryChanged?() }
            return false
        case .unavailable:
            // Not persisted: keep the in-memory copy aligned with the blob (see `performRefresh`).
            persistedToBlob = false
            AppLog.error(
                .cache,
                "\(providerID) history could not be persisted; keeping the last persisted values"
            )
        }

        if persistedToBlob {
            historyChanged = previous?.usageHistory != updated.usageHistory
            localSnapshots[providerID] = updated
            if historyChanged {
                localHistoryRevision &+= 1
                invalidateMergedHistoryCache()
            }
        }
        rebuildRenderedSnapshots()
        if notifyHistoryChange, historyChanged { onLocalHistoryChanged?() }
        return true
    }

    /// Provider IDs / families whose refresh parses large on-disk JSONL corpora.
    private static let heavyLocalLogProviders: Set<String> = [
        "claude", "codex", "opencode", "grok", "muse", "pi", "hermes", "freebuff",
    ]

    private static func heavyProvidersToSerialize(in scope: ProviderRefreshContext.Scope) -> Set<String> {
        guard scope.skipsLocalAccounting else { return heavyLocalLogProviders }
        // HermesProvider always reads SQLite, and OpenCode may do a small SQLite window fallback when
        // its account API has no answer. Keep those local reads out of the same heavy-provider chunk.
        return ["hermes", "opencode"]
    }

    /// A due meter batch may run while local files are being folded for the same card. Providers already
    /// separate these scopes: meter passes skip local accounting, and fold-only passes skip quota APIs.
    /// Never overlap two meter passes or a full pass, which could duplicate API calls or publish stale
    /// quota data over a newer result.
    private static func mayOverlapMeterRefresh(
        _ requested: ProviderRefreshContext.Scope,
        with active: [ProviderRefreshContext.Scope]
    ) -> Bool {
        guard requested.skipsLocalAccounting, !active.isEmpty else { return false }
        switch requested {
        case .menuBar, .panelMeters:
            return active.allSatisfy(\.suppressesLiveQuota)
        case .localAccounting, .panelAccounting, .full:
            return false
        }
    }

    private func providerHasQuotaMetrics(_ providerID: String) -> Bool {
        registry.descriptors(for: providerID).contains { descriptor in
            descriptor.sample.limit != nil || !descriptor.limitResources.isEmpty
        }
    }

    private func failureDomains(
        for providerID: String,
        scope: ProviderRefreshContext.Scope
    ) -> [FailureDomain] {
        let includesHistoryInMeters = providersByID[providerID]?.panelMetersRefreshIncludesHistory == true
        let hasQuota = providerHasQuotaMetrics(providerID)
        let hasHistory = registry.historyDescriptorsByProvider[providerID] != nil
        switch scope {
        case .full:
            var domains: [FailureDomain] = []
            if hasQuota { domains.append(.liveQuota) }
            if hasHistory || includesHistoryInMeters { domains.append(.accounting) }
            return domains.isEmpty ? [.full] : domains
        case .menuBar, .panelMeters:
            var domains: [FailureDomain] = []
            if hasQuota { domains.append(.liveQuota) }
            if includesHistoryInMeters && (hasHistory || !hasQuota) { domains.append(.accounting) }
            return domains.isEmpty ? [.liveQuota] : domains
        case .localAccounting, .panelAccounting:
            return [.accounting]
        }
    }

    private func recordProviderFailure(
        _ message: String,
        category: ErrorCategory?,
        for providerID: String,
        domains: [FailureDomain]
    ) {
        for affectedDomain in domains {
            nextProviderFailureOrder &+= 1
            providerFailureStates[providerID, default: [:]][affectedDomain] = ProviderFailureState(
                message: message,
                category: category,
                order: nextProviderFailureOrder
            )
        }
        updateDisplayedProviderError(for: providerID)
    }

    private func clearProviderFailure(
        for providerID: String,
        domains: [FailureDomain],
        clearAll: Bool
    ) {
        if clearAll {
            providerFailureStates[providerID] = nil
        } else {
            // `.full` is the unattributable fallback bucket, not a distinct kind of failure: it is
            // only recorded for a provider whose scopes all resolve to nothing narrower. Any
            // successful pass proves at least part of such a provider works, so the catch-all error
            // must not outlive it — otherwise its error row and Retry affordance stay forever.
            for domain in domains + [.full] {
                providerFailureStates[providerID]?[domain] = nil
            }
            if providerFailureStates[providerID]?.isEmpty == true {
                providerFailureStates[providerID] = nil
            }
        }
        updateDisplayedProviderError(for: providerID)
        if clearAll {
            lastLoggedProviderFailure[providerID] = nil
        } else if var loggedFailures = lastLoggedProviderFailure[providerID] {
            for domain in domains + [.full] { loggedFailures[domain] = nil }
            lastLoggedProviderFailure[providerID] = loggedFailures.isEmpty ? nil : loggedFailures
            if providerErrors[providerID] == nil {
                lastLoggedProviderFailure[providerID] = nil
            }
        }
    }

    private func updateDisplayedProviderError(for providerID: String) {
        let latest = providerFailureStates[providerID]?.values.max { $0.order < $1.order }
        let message = latest?.message
        // `@Observable` publishes every write, even when the value did not change, and
        // `providerErrors` is read for every provider group — so a no-op assignment re-rendered the
        // whole dashboard on every successful refresh.
        if providerErrors[providerID] != message {
            providerErrors[providerID] = message
        }
    }


    private func durationMilliseconds(since start: TimeInterval) -> Int {
        max(0, Int((monotonicNow() - start) * 1000))
    }

    /// Clears a provider's failure backoff so the next pass probes it immediately. Called when the user
    /// re-enables a provider: the enablement wake exists to fetch promptly, so a stale backoff from a
    /// failure just before it was turned off must not suppress that fetch (the loop wouldn't otherwise
    /// retry until the 5-minute heartbeat). The periodic loop never calls this — only the user action does.
    func clearFailureBackoff(for providerID: String) {
        failureRetryAfter = failureRetryAfter.filter { $0.key.providerID != providerID }
    }

    /// Rebuild the in-memory union immediately after a provider toggle. Local cached data remains
    /// available to direct API reads, but disabled providers stop receiving peer contributions.
    func providerEnablementDidChange(changedProviderIDs: Set<String> = []) {
        invalidateMergedHistoryCache()
        rebuildRenderedSnapshots()
        let disabledProviderIDs = changedProviderIDs.filter { !isProviderEnabled($0) }
        let enabledProviderIDs = changedProviderIDs.filter { isProviderEnabled($0) }
        for providerID in disabledProviderIDs {
            if let latestAction = latestManualActionByProvider[providerID] {
                invalidatedManualActionsThrough[providerID] = max(
                    invalidatedManualActionsThrough[providerID] ?? latestAction,
                    latestAction
                )
            }
            providerRequestGenerations[providerID, default: 0] &+= 1
            deferredRefreshRequests[providerID] = nil
            activeProviderRefreshTasks[providerID]?.values.forEach { $0.cancel() }
        }
        if !disabledProviderIDs.isEmpty {
            onDeferredRefreshesInvalidated?(Set(disabledProviderIDs))
        }
        // A re-enable wake is meters-only. Drop the cache freshness stamp so a recent pre-disable
        // snapshot cannot short-circuit the prompt fetch and leave the provider blank or stale.
        cache.invalidateSessionFreshness(providerIDs: enabledProviderIDs.sorted())

        let codexPeerSetChanged = changedProviderIDs.contains {
            ProviderAccountID.family(of: $0) == "codex"
        }
        if codexPeerSetChanged {
            // An enabled Codex card may have captured a peer-home list before this toggle. Cancel
            // every active Codex scan so no task keeps walking a card that was just switched off;
            // the next pass rebuilds peer homes from current enablement and refreshes enabled cards.
            let codexProviderIDs = providersByID.keys.filter {
                ProviderAccountID.family(of: $0) == "codex"
            }
            for providerID in codexProviderIDs {
                activeProviderRefreshTasks[providerID]?.values.forEach { $0.cancel() }
            }
        }

        // Muse shares OpenCode's provider card and enablement ID, while keeping its own source-family
        // identity in usage rows. Toggling the card must invalidate OpenCode's cached fold too.
        let sourceFamilies: Set<String> = ["claude", "codex", "hermes", "muse", "opencode"]
        let changedSourceFamily = changedProviderIDs.contains {
            sourceFamilies.contains(ProviderAccountID.family(of: $0))
        }
        if changedSourceFamily {
            // OpenCode's spend fold consumes these source families. Cancel an in-flight fold so the
            // next pass uses the new source plan instead of finishing work for the old card selection.
            activeProviderRefreshTasks["opencode"]?.values.forEach { $0.cancel() }
            cache.invalidateSessionFreshness(providerIDs: ["opencode"])
        }
    }

    /// Replaces the downloaded peer set. A conflicted duplicate device file resolves to the newest
    /// valid document, and this Mac's own downloaded copy is excluded in favor of current memory.
    func setPeerHistoryDocuments(_ documents: [UsageHistoryDocument], ownDeviceID: String) {
        peerHistoryDocuments = UsageHistoryDocument.newestByDevice(documents)
            .filter { $0.deviceID != ownDeviceID }
        invalidateMergedHistoryCache()
        rebuildRenderedSnapshots()
    }

    func clearPeerHistoryDocuments() {
        guard !peerHistoryDocuments.isEmpty else { return }
        peerHistoryDocuments = []
        invalidateMergedHistoryCache()
        rebuildRenderedSnapshots()
    }

    func localHistoryDocument(deviceID: String, deviceName: String, updatedAt: Date = Date()) -> UsageHistoryDocument {
        var providers: [String: ProviderUsageHistory] = [:]
        var identities: [String: String] = [:]
        let hasMultipleClaudeCards = registry.providers.count {
            ProviderAccountID.family(of: $0.id) == "claude"
        } > 1
        let lifetimeDayKeys = UsageHistoryWindow.lifetimeDayKeys(through: updatedAt)
        let detailDayKeys = UsageHistoryWindow.dayKeys(through: updatedAt)
        for (providerID, descriptor) in registry.historyDescriptorsByProvider
        where descriptor.scope == .machineLocal && isProviderEnabled(providerID) {
            if let history = localSnapshots[providerID]?.usageHistory {
                let exportHistory = history.retainingHistory(
                    lifetimeDayKeys: lifetimeDayKeys,
                    detailDayKeys: detailDayKeys
                )
                if ProviderAccountID.family(of: providerID) == "claude" {
                    if let identity = providerIdentityKeys[providerID] {
                        identities[providerID] = identity.lowercased()
                    } else if hasMultipleClaudeCards || providerID != "claude" {
                        AppLog.warn(.config, "sync: omitting Claude history without account ownership")
                        continue
                    }
                }
                providers[providerID] = exportHistory
            }
        }
        let exportedClaudeIDs = providers.keys.filter {
            ProviderAccountID.family(of: $0) == "claude"
        }
        if let onlyClaudeID = exportedClaudeIDs.first,
           exportedClaudeIDs.count == 1, onlyClaudeID != "claude"
        {
            providers["claude"] = providers.removeValue(forKey: onlyClaudeID)
            identities["claude"] = identities.removeValue(forKey: onlyClaudeID)
        }
        let hasClaudeAccountCards = providers.keys.contains {
            ProviderAccountID.family(of: $0) == "claude" && $0 != "claude"
        }
        return UsageHistoryDocument(
            schema: hasClaudeAccountCards ? UsageHistoryDocument.accountSchema : UsageHistoryDocument.currentSchema,
            deviceID: deviceID,
            deviceName: deviceName,
            updatedAt: updatedAt,
            providers: providers,
            identities: identities.isEmpty ? nil : identities
        )
    }

    /// Recomputes `snapshots` from `localSnapshots` and the peer set, **assigning only when the result
    /// actually differs**.
    ///
    /// Assigning unconditionally is what made the dashboard feel like it was thrashing. The cache-hit path
    /// already compared before rebuilding, but the *success* path did not — so every successful provider
    /// refresh replaced the whole array even when the provider returned byte-identical data. In SwiftUI that
    /// invalidates the views holding it, which is why tapping a token-usage row opened its detail popover
    /// and the popover immediately closed itself: opening the panel fires a forced refresh, the refresh
    /// reassigned `snapshots`, and the popover the user had just opened was torn down and rebuilt. It
    /// looked like constant refreshing, and it re-triggered on every retry.
    ///
    /// The guard makes the whole family idempotent — one place, so every caller benefits and none can
    /// forget it. `ProviderSnapshot` is `Equatable`, so the comparison is cheap relative to the work this
    /// function has just done.
    private func rebuildRenderedSnapshots() {
        guard !peerHistoryDocuments.isEmpty else {
            if snapshots != localSnapshots { snapshots = localSnapshots }
            return
        }
        let renderDate = now()
        let renderDayKey = DailyUsageAccumulator.dayKey(from: renderDate)
        if mergedHistoryCacheDayKey != renderDayKey {
            invalidateMergedHistoryCache()
        }
        let enabledDescriptors = registry.historyDescriptorsByProvider.reduce(
            into: [String: UsageHistoryDescriptor]()
        ) { result, entry in
            if isProviderEnabled(entry.key) { result[entry.key] = entry.value }
        }
        let merged: [String: ProviderUsageHistory]
        if let mergedHistoryCache {
            merged = mergedHistoryCache
        } else {
            merged = UsageHistoryAggregator.merged(
                localSnapshots: localSnapshots,
                peerDocuments: peerHistoryDocuments,
                descriptors: enabledDescriptors,
                providerIdentityKeys: providerIdentityKeys,
                now: renderDate
            )
            mergedHistoryCache = merged
            mergedHistoryCacheDayKey = renderDayKey
        }
        var rendered = localSnapshots
        for (providerID, history) in merged {
            guard let descriptor = registry.historyDescriptorsByProvider[providerID],
                  let provider = registry.provider(id: providerID)
            else { continue }
            let local = localSnapshots[providerID] ?? ProviderSnapshot(
                providerID: providerID,
                displayName: provider.displayName,
                lines: [],
                refreshedAt: peerHistoryDocuments.map(\.updatedAt).max() ?? renderDate
            )
            rendered[providerID] = UsageHistorySnapshotRenderer.render(
                local: local,
                history: history,
                descriptor: descriptor,
                now: renderDate
            )
        }
        if snapshots != rendered { snapshots = rendered }
    }

    private func invalidateMergedHistoryCache() {
        mergedHistoryCache = nil
        mergedHistoryCacheDayKey = nil
    }

    private static func isHeavyLocalLogProvider(_ providerID: String) -> Bool {
        let family = ProviderAccountID.family(of: providerID)
        return heavyLocalLogProviders.contains(family) || heavyLocalLogProviders.contains(providerID)
    }

    /// The provider's latest refresh error, or `nil` when its last refresh succeeded.
    func errorMessage(for providerID: String) -> String? {
        providerErrors[providerID]
    }

    /// The category attached to the latest rendered provider failure. Views use this only for
    /// provider-specific empty-state presentation; the localized message remains the user-facing copy.
    func errorCategory(for providerID: String) -> ErrorCategory? {
        providerFailureStates[providerID]?.values.max { $0.order < $1.order }?.category
    }

    /// A soft, non-blocking notice from the provider's latest *successful* snapshot (e.g. Claude's
    /// "Re-login for live usage" when the login lacks the `user:profile` scope). `nil` when there's no
    /// warning. After a *failed* refresh the store keeps the last good snapshot (so this warning can
    /// linger) while setting `providerErrors` — use `headerNotice(for:)` for the rendered triangle so a
    /// current hard error isn't masked by a stale soft warning.
    func warningMessage(for providerID: String) -> String? {
        guard let snapshot = snapshots[providerID] else { return nil }
        let warnings = [snapshot.warning, snapshot.historyWarning]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return warnings.isEmpty ? nil : warnings.joined(separator: " ")
    }

    /// The provider header's amber-triangle notice: a hard refresh error takes precedence over a stale
    /// soft warning from the last successful snapshot. After a failed refresh the store keeps the last
    /// good snapshot (so `warningMessage` still returns its warning) while `errorMessage` holds the
    /// current failure — the error must win, or a stale "Re-login for live usage" warning would hide a
    /// real "Token expired" failure. When there's no error, the soft warning (if any) shows.
    func headerNotice(for providerID: String) -> String? {
        errorMessage(for: providerID) ?? warningMessage(for: providerID)
    }

    /// A snapshot that carries only error lines is a failed refresh; its message comes from the badge.
    private static func errorMessage(in snapshot: ProviderSnapshot) -> String? {
        guard !snapshot.lines.isEmpty, snapshot.lines.allSatisfy(\.isError) else { return nil }
        if case .badge(_, let text, _, _) = snapshot.lines[0] { return text }
        return "Refresh failed"
    }

    private static func hasQuotaProgress(_ lines: [MetricLine]) -> Bool {
        lines.contains { line in
            if case .progress = line { return true }
            return false
        }
    }

    @discardableResult
    private func clearPriorQuotaState(for providerID: String, refreshOrder: UInt64? = nil) -> Bool {
        let previous = localSnapshots[providerID]
        if let previous {
            localSnapshots[providerID] = Self.snapshotByClearingQuotaState(previous)
        }
        let result = cache.clearQuotaState(providerID: providerID, refreshOrder: refreshOrder)
        switch result {
        case .stored(let persistedSnapshot):
            if let persistedSnapshot {
                localSnapshots[providerID] = persistedSnapshot
            } else if let previous {
                localSnapshots[providerID] = Self.snapshotByClearingQuotaState(previous)
            }
        case .unchanged(let persistedSnapshot):
            if let persistedSnapshot { localSnapshots[providerID] = persistedSnapshot }
        case .superseded(let newerSnapshot):
            localSnapshots[providerID] = newerSnapshot
            rebuildRenderedSnapshots()
            return false
        case .unavailable:
            break
        }
        rebuildRenderedSnapshots()
        return true
    }

    @discardableResult
    private func updateProviderCacheIdentity(
        to currentIdentityKey: String,
        providerID: String,
        notifyHistoryChange: Bool,
        refreshOrder: UInt64?
    ) -> Bool {
        guard providerIdentityKeys[providerID] != currentIdentityKey else { return true }

        if providerID == "antigravity" {
            guard clearPriorQuotaState(for: providerID, refreshOrder: refreshOrder) else { return false }
            providerIdentityKeys[providerID] = currentIdentityKey
            AppLog.info(.cache, "account identity changed during refresh; cleared prior quota state for antigravity")
            return true
        }

        guard cache.removeSnapshot(providerID: providerID, refreshOrder: refreshOrder) else {
            return false
        }

        providerIdentityKeys[providerID] = currentIdentityKey
        let previous = localSnapshots.removeValue(forKey: providerID)
        let historyChanged = previous?.usageHistory != nil
        if historyChanged {
            localHistoryRevision &+= 1
            invalidateMergedHistoryCache()
        }
        AppLog.info(.cache, "account identity changed during refresh; cleared prior snapshot for \(providerID)")
        rebuildRenderedSnapshots()
        if notifyHistoryChange, historyChanged { onLocalHistoryChanged?() }
        return true
    }

    /// Strip account-bound meters while retaining provider history stored on this Mac. Used at launch
    /// and by explicit catalog reloads for providers whose history is independent of quota identity.
    static func snapshotByClearingQuotaState(_ snapshot: ProviderSnapshot) -> ProviderSnapshot {
        var cleared = snapshot
        cleared.plan = nil
        cleared.lines.removeAll { line in
            if case .progress = line { return true }
            return false
        }
        cleared.warning = nil
        cleared.clearsPriorMenuBarQuotaState = nil
        cleared.replacesPriorQuotaProgress = nil
        cleared.invalidatesQuotaIdentity = nil
        cleared.quotaRefreshedAt = nil
        return cleared
    }

    /// Discard quota rows before an account-scoped descriptor inventory is replaced. Local history
    /// stays cached; quotas from a rotated OpenCode key must never paint under its new identity.
    func invalidateQuotaStateForCatalogReload(providerID: String) {
        clearPriorQuotaState(for: providerID)
        cache.invalidateSessionFreshness(providerIDs: [providerID])
    }

    /// Drop account-bound quota rows before a persisted credential selection changes. The selection
    /// is not part of OpenCode's credential-inventory stamp, so clear synchronously and supersede
    /// in-flight work before the new preference is written.
    func invalidateQuotaStateForAccountSelectionChange(providerID: String) {
        providerRequestGenerations[providerID, default: 0] &+= 1
        deferredRefreshRequests[providerID] = nil
        activeProviderRefreshTasks[providerID]?.values.forEach { $0.cancel() }
        clearPriorQuotaState(for: providerID)
        cache.invalidateSessionFreshness(providerIDs: [providerID])
    }

    func data(for descriptor: WidgetDescriptor) -> WidgetData {
        var result: WidgetData
        if let snapshot = snapshots[descriptor.providerID],
           let line = snapshot.line(label: descriptor.metricLabel),
           let data = resolve(line, descriptor: descriptor) {
            result = data
        } else {
            // No real metric line backs this placed tile, so the sample's numbers are placeholders.
            // Flag it as no-data; the tile renders "No data" instead of inventing usage.
            result = descriptor.sample
            result.hasData = false
        }

        if case .sessionCountdowns(let metricLabel) = descriptor.sample.trayStyle {
            // Read only explicit session expiries. Cached daily spend is not session activity.
            if case .values(_, _, _, let expiries, _, _) = snapshots[descriptor.providerID]?.line(label: metricLabel) {
                result.traySessionExpiriesAt = expiries
            } else {
                result.traySessionExpiriesAt = []
            }
        }

        // Single global choke point: dashboard/share rows and menu-bar values all funnel through here,
        // so stamping the mode once makes them follow the global setting. Inert for unbounded rows
        // (limit == nil), whose displayed value ignores displayMode.
        result.displayMode = meterStyle
        result.resetDisplayMode = resetDisplayMode
        result.alwaysShowPacing = alwaysShowPacing
        return result
    }

    /// The retained local history of providers the user has turned off, keyed by provider ID — the
    /// dormant half of the Total Spend card's input.
    ///
    /// Disabling a provider stops its refreshes and hides its card; it deliberately keeps the
    /// already-computed history on disk, because the same records should still count as usage that
    /// happened. The card re-windows that history for the selected period instead of trusting the
    /// frozen spend tiles, which still describe the day they were last computed.
    ///
    /// Every requested provider that is off gets an entry, even when no history is retained yet: the
    /// key's presence is what tells the aggregator "this provider is dormant, do not read its frozen
    /// tiles". A missing entry would let a turned-off provider's stale "Today" tile count as today.
    func dormantUsageHistories(for providerIDs: [String]) -> [String: ProviderUsageHistory] {
        var result: [String: ProviderUsageHistory] = [:]
        result.reserveCapacity(providerIDs.count)
        for providerID in providerIDs where !isProviderEnabled(providerID) {
            result[providerID] = snapshots[providerID]?.usageHistory ?? ProviderUsageHistory(
                series: DailyUsageSeries(daily: [])
            )
        }
        return result
    }

    /// The plan label for a provider's latest snapshot. `nil` until a snapshot exists or when the
    /// provider doesn't expose a plan. Provider section headers render this beside the provider name.
    func plan(for providerID: String) -> String? {
        snapshots[providerID]?.plan
    }

    /// How long a displayed snapshot may age before the header calls it out. A healthy provider's
    /// snapshot resets to ~0 on every successful pass and only brushes one interval just before the next
    /// one, so the threshold sits at two intervals: it fires only when a refresh has actually been missed
    /// — a refresh loop that keeps failing, or a long-suspended background timer — never on the normal
    /// per-cycle aging, which would flicker a hint on healthy providers.
    /// Derived from the *slowest* cadence the refresh loop can legally sleep at, not the panel-open one.
    ///
    /// Live quota meters update every minute on AC and every two minutes on battery / Low Power Mode;
    /// full-detail snapshots still use the five-minute cadence. The threshold follows the slower of
    /// those schedules so a healthy provider does not show a false amber "Outdated" on panel open.
    static var stalenessThreshold: TimeInterval {
        max(RefreshSetting.interval, RefreshSetting.backgroundInterval) * 2
    }

    /// A compact "Outdated" hint for the oldest visible data domain. Fresh quota responses must not hide
    /// carried history, and a fresh history fold must not make carried quota appear current.
    func stalenessHint(for providerID: String) -> StalenessHint? {
        guard let snapshot = snapshots[providerID] else { return nil }
        var stamps = [snapshot.refreshedAt]
        if Self.hasQuotaProgress(snapshot.lines) {
            stamps.append(snapshot.quotaRefreshedAt ?? snapshot.refreshedAt)
        }
        if snapshot.usageHistory != nil {
            stamps.append(snapshot.historyRefreshedAt ?? snapshot.refreshedAt)
        }
        let age = now().timeIntervalSince(stamps.min() ?? snapshot.refreshedAt)
        guard age >= Self.stalenessThreshold, let duration = Formatters.compactDuration(age) else {
            return nil
        }
        return StalenessHint(label: "Outdated", tooltip: "Last updated \(duration) ago")
    }

    private func resolve(_ line: MetricLine, descriptor: WidgetDescriptor) -> WidgetData? {
        switch line {
        case .progress(_, let used, let limit, let format, let resetsAt, let periodDurationMs, _, let detail):
            // A percent meter is a bounded 0...100 domain; sanitize an out-of-range sample (a provider
            // reporting a negative or >100 utilization) here, at the single construction choke point
            // every provider funnels through, so no surface — headline, flip tooltip, menu bar — can
            // render "-5%" or "105%". For percent the limit is always 100, so clamping `used` also
            // keeps the meter's spent verdict intact (>=100 still reads "Limit reached"). Non-percent
            // meters keep their raw `used`: a dollar/count overage (used > limit) is real and is
            // conveyed by the meter's spent state rather than hidden.
            let normalizedUsed = format == .percent ? ProviderParse.clampPercent(used) : used
            var result = WidgetData(
                title: descriptor.sample.title,
                icon: descriptor.sample.icon,
                kind: format.metricKind,
                used: normalizedUsed,
                limit: limit,
                countSuffix: format.countSuffix,
                valuePrefix: descriptor.sample.valuePrefix,
                resetsAt: resetsAt,
                periodDurationMs: periodDurationMs,
                limitNoun: descriptor.sample.limitNoun,
                infoNote: descriptor.sample.infoNote
            )
            // Descriptor opt-in (session-window meters read "Not started" when unused); the fresh
            // `.progress` result doesn't start from the sample, so carry the signal explicitly.
            result.sessionStartSignal = descriptor.sample.sessionStartSignal
            // Same reason: a timer segment is a descriptor opt-in, and `.progress` rebuilds the row.
            result.trayStyle = descriptor.sample.trayStyle
            result.boundedDetail = detail
            return result
        case .text:
            // Text lines carry provider notices for the local API; no dashboard descriptor consumes
            // them. Numeric widgets use typed progress/values lines and must never parse display text.
            return nil
        case .values(_, let values, _, let expiriesAt, let unknownModels, let modelBreakdown):
            // The number is carried raw — no regex re-parse. Presentation (title, icon, selection,
            // trailing word) comes from the descriptor's sample; the live numbers come from the line.
            var data = descriptor.sample
            data.values = values
            // A `.values` line is unbounded by definition (see `MetricLine`), so it never renders as a
            // meter even when the descriptor template carries a placeholder limit — e.g. Claude's
            // `claude.extra` is `boundedDollars` for its capped `.progress` case but feeds an uncapped
            // `.values` row when there's no monthly cap.
            data.limit = nil
            // Optional expiry instants (Codex rate-limit-reset credits): surfaced in the row's hover
            // tooltip (see `expiryTooltip`), with the row re-rendering on the clock tick so they stay live.
            data.expiriesAt = expiriesAt
            // Unknown-model names (Cursor spend tiles): drive the label warning triangle whose hover lists
            // the models this period used that the pricing manifest can't price, so the cost is incomplete.
            data.unknownModels = unknownModels
            data.modelBreakdown = modelBreakdown
            // A tile whose selection finds no value (e.g. a cost-only tile on a day the scanner couldn't
            // price) has nothing real to show — render "No data" rather than a misleading $0.00 / 0.
            data.hasData = !data.selectedValues.isEmpty
            // The ⓘ is data-driven: it shows when a *shown* value is locally estimated (a spend row's
            // dollars) and stays off for a measured one (its tokens), so the tokens-only tile reads clean.
            data.infoNote = data.selectedValues.contains(where: \.estimated)
                ? WidgetData.localEstimateNote
                : descriptor.sample.infoNote
            return data
        case .badge(_, let text, _, let subtitle):
            var data = descriptor.sample
            data.valueTextOverride = text
            data.subtitleOverride = subtitle
            return data
        case .chart(_, let points, let note):
            // Presentation (title, icon) from the sample; the live per-day points from the line. No
            // points means the source was read but had no usable day — render "No data", not an empty
            // axis (and so descriptor template data never leaks onto the dashboard).
            var data = descriptor.sample
            data.isChart = true
            data.chartPoints = points
            data.chartNote = note
            data.hasData = !points.isEmpty
            return data
        }
    }

}
