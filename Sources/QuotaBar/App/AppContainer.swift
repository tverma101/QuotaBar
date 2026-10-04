import Dispatch
import Foundation
import KeyboardShortcuts
import Observation

/// Composition root: owns the (constant) registry and the (mutable) stores, injected
/// into the SwiftUI environment.
@MainActor
@Observable
final class AppContainer {
    /// User-registered additional Codex homes. The registration survives relaunch; credentials remain
    /// owned by the Codex CLI and are never copied into QuotaBar settings.
    let codexAccounts: CodexAccountRegistrationStore
    /// Owns the in-app handoff to Codex's official browser OAuth login for an additional account.
    let codexAccountRegistration: CodexAccountRegistrationService
    let registry: WidgetRegistry
    let layout: LayoutStore
    let dataStore: WidgetDataStore
    /// Opt-in private iCloud document sync for additive machine-local daily history.
    let iCloudSync: ICloudUsageSyncStore
    /// Single source of truth for which providers the user has turned off. Both stores consult it (via
    /// injected closures) and the Customize provider list drives it.
    let enablement: ProviderEnablementStore
    /// Providers that need a user-supplied API key (currently OpenRouter and Z.ai), conforming to
    /// `APIKeyManaging`. Each matching Customize provider detail shows an API Key section and writes
    /// changes through the capability. Empty when no installed provider needs a user key.
    let apiKeyProviders: [any APIKeyManaging]
    /// Providers with app-saved multi-key support (currently OpenCode), conforming to
    /// `GoKeyManaging`. Each matching Customize provider detail shows a Go Keys section: add or
    /// remove keys and pin which account the card shows. Empty when no installed provider supports it.
    let goKeyProviders: [any GoKeyManaging]
    /// Quota pace notification preferences (three independent triggers). Drives the Settings section
    /// and is read by `WidgetDataStore.evaluateNotifications`.
    let notificationSettings: NotificationSettingsStore
    /// Anonymous usage telemetry (mandatory daily activity and crashes, optional provider rollups).
    /// Exposed so Settings can toggle extra analytics and termination can flush queued events.
    let telemetry: TelemetryRecorder
    /// Source of truth for the popover's transparency: the persisted Increase Transparency toggle, the
    /// ephemeral secret-code easter-egg state, and the system accessibility flags it yields to. Read by both
    /// the SwiftUI surface and the AppKit panel (`StatusItemController`).
    let transparency: PopoverTransparencyStore
    /// The menu bar's screen-share privacy mode: the persisted Hide From Screen Share toggle
    /// plus the live capture signal. Read by `StatusItemImageUpdater` to swap the strip for the
    /// wordmark while the screen is shared or recorded.
    let privacy: MenuBarPrivacyStore
    /// One-time onboarding state (the first-run Customize hint card). Only ever marked pending by
    /// `FirstRunSeeder` on a fresh install, so existing installs never see the card.
    let onboarding: OnboardingStore
    /// Claims Codex rate-limit reset credits from the resets popover (the app's only provider-API
    /// write). Shares the Codex provider's auth store and usage client. This is deliberately `nil`
    /// while multiple Codex accounts are active because the existing UI has no account selector for
    /// that write; reads remain fully account-scoped.
    let codexResetClaim: CodexResetClaimService?
    /// The provider runtimes, kept so on-demand credential detection (the Customize "Reset All" reseed)
    /// can re-probe `hasLocalCredentials()` the same way first-run seeding does.
    private let providers: [ProviderRuntime]
    /// Read-only usage API on 127.0.0.1:6736 for other local apps (silently off when the port is taken).
    private let localAPI: LocalUsageServer
    /// Separate Kaggle TPU GLM-5.3 control plane. It is read-only until the dashboard card's explicit
    /// Turn On action is used; it never shares the T4/Ollama or Z-Image worker lifecycle.
    let kaggleCompute: KaggleComputeService
    // A `let` of a `Sendable` `Task` is implicitly nonisolated, so the nonisolated `deinit` can cancel it.
    private let refreshTask: Task<Void, Never>
    /// The fresh-install credential-detection pass (see `FirstRunSeeder`); `nil` on every later launch.
    private let seedTask: Task<Void, Never>?
    /// The new-provider credential-detection pass (see `NewProviderSeeder`); `nil` unless this launch is
    /// the first with a provider the install has never seen.
    private let newProviderTask: Task<Void, Never>?
    /// Persists a fresh `ShellEnvironmentSnapshot` once the login-shell capture completes, so the next
    /// launch can read shell-exported facts (provider home overrides) even when its own capture is slow.
    private let shellEnvironmentSnapshotTask: Task<Void, Never>
    /// Drops parse caches when the OS warns about memory pressure.
    private let memoryPressureSource: DispatchSourceMemoryPressure

    /// `isFreshInstall` must be captured by the caller BEFORE `SettingsMigrator.migrate()` runs (the
    /// migrator's schema stamp makes the defaults domain non-empty). See `AppDelegate`.
    init(isFreshInstall: Bool = false) {
        // Capture the user's login-shell environment off-main so provider keys exported in a shell
        // profile (e.g. OPENROUTER_API_KEY) resolve in a Finder/Dock-launched build, not only when
        // run from a terminal. Warmed here so the first refresh finds the cache ready.
        LoginShellEnvironment.shared.prewarm()
        // Once the capture lands, persist its identity-relevant facts so the NEXT launch has them
        // even if that launch's own capture is slow (see `ShellEnvironmentSnapshot`).
        self.shellEnvironmentSnapshotTask = ShellEnvironmentSnapshotStore(defaults: .standard).startRefreshTask()
        // The launch account pass: which account is signed in at each family's default home. Feeds
        // the snapshot cache's account stamp and reconciles the account registry.
        let codexAccounts = CodexAccountRegistrationStore()
        let codexAccountRegistration = CodexAccountRegistrationService(accounts: codexAccounts)
        let accountAssembly = ProviderAccountAssembly.make(
            waitsForLoginShell: true,
            registeredCodexHomes: codexAccounts.registeredHomes
        )

        let providers = ProviderCatalog.make(
            claudeCards: accountAssembly.claudeCards,
            codexCards: accountAssembly.codexCards,
            claudeIdentityKeys: accountAssembly.identityKeysByCard,
            codexLogHomes: codexAccounts.registeredHomes
        )
        let registry = WidgetRegistry.from(providers)
        let apiKeyProviders = providers.compactMap { $0 as? any APIKeyManaging }
        let goKeyProviders = providers.compactMap { $0 as? any GoKeyManaging }
        let enablement = ProviderEnablementStore()
        let notificationSettings = NotificationSettingsStore()
        let additionalAccountIDsByFamily = Dictionary(grouping: providers.map(\.provider.id).filter { id in
            let family = ProviderAccountID.family(of: id)
            return id != family && ProviderAccountID.families.contains(family)
        }, by: ProviderAccountID.family)
        let accountDefaults: ([String]) -> [String] = { metricIDs in
            metricIDs.flatMap { metricID -> [String] in
                guard let separator = metricID.firstIndex(of: ".") else { return [metricID] }
                let family = String(metricID[..<separator])
                guard let additionalIDs = additionalAccountIDsByFamily[family], !additionalIDs.isEmpty else {
                    return [metricID]
                }
                let suffix = metricID[separator...]
                return [metricID] + additionalIDs.map { "\($0)\(suffix)" }
            }
        }
        let layout = LayoutStore(
            registry: registry,
            defaultMetricIDs: accountDefaults(DefaultLayout.metricIDs),
            defaultPinnedMetricIDs: accountDefaults(DefaultLayout.pinnedMetricIDs),
            defaultExpandedMetricIDs: accountDefaults(DefaultLayout.expandedMetricIDs),
            isProviderEnabled: { [enablement] in enablement.isEnabled($0) }
        )
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: providers,
            isProviderEnabled: { [enablement] in enablement.isEnabled($0) },
            orderedDescriptors: { [layout] in layout.visiblePlaced.compactMap { layout.descriptor(for: $0) } },
            pinnedMetricIDs: { [layout] in layout.pinnedMetricIDs },
            notificationSettings: { notificationSettings },
            providerIdentityKeys: accountAssembly.identityKeysByCard
        )
        let iCloudSync = ICloudUsageSyncStore(dataStore: dataStore)
        // Re-enabling a provider should fetch it promptly, so clear any leftover failure backoff before
        // the enablement wake refreshes. `weak` breaks the cycle (dataStore already captures enablement).
        enablement.onProviderEnabled = { [weak dataStore] id in dataStore?.clearFailureBackoff(for: id) }
        enablement.onChange = { [weak dataStore, weak iCloudSync] in
            dataStore?.providerEnablementDidChange()
            iCloudSync?.scheduleWrite()
        }
        // Fresh installs start minimal: seed the enabled-provider list (Claude/Codex/Cursor right away,
        // then the detected set once the local credential probe finishes). No-op on every later launch.
        let onboarding = OnboardingStore()
        self.seedTask = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: isFreshInstall,
            providers: providers,
            enablement: enablement,
            onboarding: onboarding
        )
        // Providers added by an update get the same credential detection on their first launch — enabled
        // only when the user actually has the tool. Runs every launch; a no-op unless the registry has a
        // provider this install has never seen (fresh installs were just baselined by FirstRunSeeder).
        self.newProviderTask = NewProviderSeeder.reconcileIfNeeded(
            providers: providers,
            enablement: enablement
        )
        self.providers = providers
        self.codexAccounts = codexAccounts
        self.codexAccountRegistration = codexAccountRegistration
        self.onboarding = onboarding
        self.registry = registry
        self.enablement = enablement
        self.apiKeyProviders = apiKeyProviders
        self.goKeyProviders = goKeyProviders
        self.notificationSettings = notificationSettings
        self.layout = layout
        self.dataStore = dataStore
        self.iCloudSync = iCloudSync

        // The resets popover's claim service shares a Codex provider's credential loading and HTTP
        // client so the claim's auth can't drift from the provider's. With more than one Codex account,
        // disable this write until the UI can explicitly choose a target account rather than guessing.
        let codexProviders = providers.compactMap { $0 as? CodexProvider }
        let writableCodex = codexProviders.count == 1 ? codexProviders[0] : nil
        self.codexResetClaim = writableCodex.map { codex in
            CodexResetClaimService(
                authStore: codex.authStore,
                usageClient: codex.usageClient,
                refreshAfterClaim: { [weak dataStore] in
                    // The bound must outlast the provider's slowest refresh: usage fetch (10s timeout)
                    // + token refresh (15s) + usage retry (10s) + reset-credit fetch (10s) ≈ 45s. The
                    // common race (the periodic timer's probe) clears in a couple of seconds; the
                    // pathological one keeps the popover's honest "Resetting…" up rather than showing
                    // a success banner over pre-claim meters. A `.failed` probe is retried a few times
                    // too — a transient flake right after the claim must not strand pre-claim meters
                    // behind a success banner — before giving up loudly (the provider error already
                    // shows on the card, so the staleness isn't silent).
                    var failures = 0
                    for attempt in 0..<45 {
                        guard let dataStore else { return }
                        let outcome = await withThrottledFullAccounting {
                            await dataStore.refresh(providerID: codex.provider.id, force: true)
                        }
                        switch outcome {
                        case .refreshed, .cacheHit, .backedOff:
                            return
                        case .failed:
                            failures += 1
                            guard failures < 3 else {
                                AppLog.error(LogTag.plugin("codex"), "post-claim refresh failed \(failures) times; meters may lag until the next cycle")
                                return
                            }
                            try? await Task.sleep(for: .seconds(2))
                        case .skipped:
                            AppLog.info(LogTag.plugin("codex"), "post-claim refresh waiting out an in-flight refresh (attempt \(attempt + 1))")
                            try? await Task.sleep(for: .seconds(1))
                        }
                    }
                    AppLog.error(LogTag.plugin("codex"), "post-claim refresh kept being skipped; meters may lag until the next cycle")
                }
            )
        }

        // Anonymous usage telemetry (mandatory daily activity and crashes, optional provider rollups).
        // Its state lives in a dedicated UserDefaults suite, kept separate from app settings so the user's
        // optional-analytics choice and the install id stay independent of any settings change. The
        // snapshot closure reads the live layout/enablement so `app_daily_active` always reflects
        // the current configuration.
        let telemetryStore = TelemetryStore()
        let telemetry = TelemetryRecorder(
            sink: PostHogTelemetrySink(enabled: telemetryStore.enabled),
            store: telemetryStore,
            snapshot: { [registry, enablement, layout] in
                // Report the *active* configuration: a metric whose provider is turned off is hidden
                // from the dashboard and menu bar, so exclude it here too — keeping the metric arrays
                // consistent with `enabledProviders` (which is also enablement-filtered).
                let providerOn: (String) -> Bool = { metricID in
                    guard let providerID = registry.descriptor(id: metricID)?.providerID else { return false }
                    return enablement.isEnabled(providerID)
                }
                return TelemetryConfigSnapshot(
                    enabledProviders: registry.providers.map(\.id).filter { enablement.isEnabled($0) },
                    enabledMetricIDs: layout.placed.map(\.descriptorID).filter(providerOn),
                    pinnedMetricIDs: layout.pinnedMetricIDs.filter(providerOn),
                    expandedMetricIDs: layout.expandedMetricIDs.filter(providerOn),
                    menuBarStyle: layout.menuBarStyle.rawValue
                )
            }
        )
        dataStore.onRefreshOutcome = { [weak telemetry] providerID, outcome, category, manual in
            telemetry?.record(providerID: providerID, outcome: outcome, category: category, manual: manual)
        }
        self.telemetry = telemetry
        self.transparency = PopoverTransparencyStore()
        self.privacy = MenuBarPrivacyStore()
        self.kaggleCompute = KaggleComputeService()
        // Polling is read-only and starts with a bounded local status command. Starting it here keeps
        // the card accurate before the user scrolls to it; no Kaggle notebook is started automatically.
        //
        // Skipped when the bridge is absent. The loop spawns a status subprocess every 30 seconds for the
        // life of the app, so without this guard an install that can never use the feature still paid for
        // a poll a minute, indefinitely, in exchange for a red error card nobody asked for.
        if self.kaggleCompute.isBridgeAvailable {
            self.kaggleCompute.startPolling()
        }
        self.localAPI = LocalUsageServer(state: { [layout, enablement, dataStore] in
            LocalUsageAPI.State(
                enabledOrderedIDs: layout.orderedProviderIDs().filter { enablement.isEnabled($0) },
                knownIDs: Set(registry.providers.map(\.id)),
                snapshots: dataStore.snapshots,
                limitDescriptors: registry.limitDescriptorsByProvider,
                errors: dataStore.providerErrors
            )
        })
        self.memoryPressureSource = Self.makeMemoryPressureSource(dataStore: dataStore)
        self.refreshTask = Self.startPeriodicRefresh(dataStore: dataStore, telemetry: telemetry, transparency: self.transparency)
        localAPI.start()
        // Become the notification-center delegate so banners show while frontmost — a menu-bar accessory
        // effectively always is. Notification authorization is requested the first time a trigger is
        // turned on in Settings, not at launch — triggers default off. No-op under tests.
        //
        // Defer one turn past `AppContainer` init / `applicationDidFinishLaunching` so Launch Services
        // has a bundle proxy (macOS 26 `UNUserNotificationCenter.current()` aborts otherwise — Sep 22
        // DiagnosticReports). `canUseUserNotifications` still skips naked-binary launches.
        DispatchQueue.main.async {
            AppNotifications.shared.registerAsDelegate()
        }
    }

    deinit {
        refreshTask.cancel()
        seedTask?.cancel()
        newProviderTask?.cancel()
        shellEnvironmentSnapshotTask.cancel()
        memoryPressureSource.cancel()
    }

    /// Re-runs first-launch credential detection on demand — the enablement half of the Customize
    /// "Reset All" action (`LayoutStore.resetToDefault` handles metrics, order, pins, and expansion).
    /// Delegates to `FirstRunSeeder.reseed`; returns its detection task so callers can await it.
    @discardableResult
    func reseedEnabledProviders() -> Task<Void, Never> {
        FirstRunSeeder.reseed(providers: providers, enablement: enablement)
    }

    /// The Settings "Reset All Settings" action: restores every user preference the container owns to
    /// its default (see `docs/settings.md` § Reset). Composes the Customize reset (`resetToDefault` +
    /// provider reseed) with the Settings-only preferences. Deliberately untouched: telemetry (the
    /// optional-analytics choice and install id stay independent of settings changes — see the
    /// `TelemetryStore` note above), the iCloud sync device identity, provider credentials, and
    /// cached usage snapshots.
    /// Launch at Login lives outside the container (in the system's login-item registry); the
    /// Settings screen resets that alongside this call.
    func resetAllSettings() {
        layout.resetToDefault()
        // The menu-bar Icon Style is a Settings preference, not part of the Customize layout reset.
        layout.menuBarStyle = .text
        reseedEnabledProviders()
        // Registered Codex homes are account data, not a presentation setting. Keep them intact when
        // Reset All Settings runs; an account can only be removed through its explicit account action.
        dataStore.resetDisplaySettings()
        notificationSettings.resetToDefaults()
        transparency.resetToDefaults()
        privacy.hideUsageWhileScreenSharing = false
        // Same as flipping the Settings toggle off: stops syncing and removes this Mac's document
        // from the shared iCloud container (peers keep their own history).
        iCloudSync.enabled = false
        // Removing an `@AppStorage` key restores its declared default; the Settings screen's
        // `@AppStorage` properties observe the change. New settings must be added here.
        for key in [
            AppearanceSetting.key, TimeFormatSetting.key, DensitySetting.key,
            ReduceAnimationsSetting.key, LogLevelSetting.key, TotalSpendSetting.key,
            TotalSpendSetting.periodKey, TotalSpendSetting.metricKey,
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        KeyboardShortcuts.reset(.togglePopover)
        AppearanceSetting.applyCurrent()
        AppLog.reloadLevel()
        AppLog.info(.config, "All settings reset to defaults")
    }

    /// Drives live updates: refresh on launch, then again every refresh interval. Each pass honors the
    /// cache, so it only hits the network once a snapshot has actually expired. `@Observable` propagates
    /// the resulting snapshot changes to the menu-bar label and any open widgets, so the UI refreshes on
    /// its own instead of only when the popover opens.
    ///
    /// Between passes the loop sleeps via `RefreshWakeSignal`, which wakes it early when the user
    /// enables/disables a provider so a newly-enabled provider is fetched promptly instead of waiting out
    /// the full interval. The signal subscribes BEFORE the first pass and buffers, so an enablement change
    /// landing while a pass is still running (first-run credential detection, `NewProviderSeeder`, the
    /// Customize "Reset All" reseed — all of which typically finish faster than the network fetches) is
    /// never lost. Each pass still honors the cache (and the per-provider failure backoff), so an early
    /// wake only hits the network for a provider whose snapshot has actually expired.
    ///
    /// The wake is deliberately scoped to `ProviderEnablementStore.didChangeNotification` — NOT the
    /// firehose `UserDefaults.didChangeNotification`, which fires for the app's own snapshot-cache writes,
    /// and unrelated global-domain changes from other processes. Waking on
    /// that, with no minimum interval before re-refreshing, collapsed the fixed 5-minute cadence into a
    /// refresh storm.
    private static func makeMemoryPressureSource(dataStore: WidgetDataStore) -> DispatchSourceMemoryPressure {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue.global(qos: .utility)
        )
        // Capture the store weakly: unloading mid-refresh races the shared CodexRouter tail / session
        // caches. Prefer waiting until the in-flight provider batch settles, then unload once.
        source.setEventHandler(handler: makeMemoryPressureHandler(
            unload: PersistentJSONLScanCaches.unloadForMemoryPressure,
            shouldDefer: { [weak dataStore] in
                await MainActor.run { !(dataStore?.refreshingProviderIDs.isEmpty ?? true) }
            }
        ))
        source.resume()
        return source
    }

    /// Runs `unload` on a background task. When `shouldDefer` is true (a provider refresh is in
    /// flight), waits briefly and retries so a kernel memory-pressure event does not clear the
    /// shared router tail mid-fold. Tests inject both hooks.
    nonisolated static func makeMemoryPressureHandler(
        unload: @escaping @Sendable () async -> Void = PersistentJSONLScanCaches.unloadForMemoryPressure,
        shouldDefer: (@Sendable () async -> Bool)? = nil
    ) -> @Sendable () -> Void {
        {
            Task {
                if let shouldDefer {
                    // Bounded wait (~5s): do not block unload forever if a provider is wedged.
                    for _ in 0..<50 {
                        if await !shouldDefer() { break }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                await unload()
            }
        }
    }

    private static func startPeriodicRefresh(dataStore: WidgetDataStore, telemetry: TelemetryRecorder, transparency: PopoverTransparencyStore) -> Task<Void, Never> {
        Task {
            let wakeSignal = RefreshWakeSignal(names: [
                ProviderEnablementStore.didChangeNotification,
                CodexRouterLedgerWatcher.didChangeNotification,
                BackgroundRefreshTrigger.didChangeNotification
            ])
            // Tap-free external trigger (see `BackgroundRefreshTrigger`). Armed here, outside the
            // loop body, so a request landing mid-pass is still observed and applied to the *next*
            // pass rather than being lost.
            let backgroundTrigger = BackgroundRefreshTrigger()
            backgroundTrigger.start()
            // Arm vnode watch on the CodexRouter ledger so panel-open spend updates within ~1s of a
            // routed turn (incremental tail parse). Closed-panel wakes are suppressed inside the watcher.
            let ledgerWatcher = CodexRouterLedgerWatcher(
                isPanelOpen: { PopoverTransparencyStore.isPopoverShownUnlocked }
            )
            ledgerWatcher.start()
            defer {
                backgroundTrigger.stop()
                ledgerWatcher.stop()
            }
            var isFirstPass = true
            /// Latched by an external trigger and consumed by the next pass. Unlike the ledger wake
            /// this one also needs `.full` scope: the panel may be closed, and `menuBar` scope skips
            /// the local JSONL/SQLite accounting entirely, so a trigger that did not widen the scope
            /// would do no measurable work at all.
            var pendingFullScopePass = false
            /// Rate limit for trigger-caused passes, and whether a pass must be dropped because the
            /// previous one has not cleared the cooldown yet.
            var triggerGate = BackgroundRefreshGate()
            var dropNextRefreshPass = false
            while !Task.isCancelled {
                if dropNextRefreshPass {
                    // A trigger arrived inside the gate's cooldown. The trigger's own debounce
                    // already collapsed the burst; this drops the one redundant pass that would
                    // otherwise be released the moment the prior pass ends. Notifications, telemetry,
                    // and the timer cadence below still run.
                    dropNextRefreshPass = false
                    pendingFullScopePass = false
                    AppLog.info(.refresh, "background refresh pass skipped (inside trigger cooldown)")
                } else {
                    // The first pass is the only refresh that can simultaneously cold-load every enabled
                    // local index after launch. Serialize provider starts once so a multi-account Codex
                    // corpus and the OpenCode gateway fold do not compete with each other and with remote
                    // providers for all cores; stale snapshots are already painted by the store. Return to
                    // the normal concurrent cadence after that initial burst.
                    //
                    // Serialize whenever we are *over the soft limit*, not just the hard one. The
                    // per-provider unload in `WidgetDataStore` only runs once a provider finishes, so
                    // concurrent folds each allocate their parse arrays unchecked and the peak is the sum
                    // of all of them. Measured on a 9.8 GB Codex corpus: five concurrent providers reached
                    // 982 MB with the soft-limit guard firing four times *after the fact*. One at a time
                    // caps the peak at a single provider's footprint. `WidgetDataStore.refreshAll` also
                    // re-checks between chunks, so this covers the first batch after a spike too.
                    let serializeProviders = isFirstPass || ProcessMemoryBudget.isOverSoftLimit
                    let panelOpen = transparency.popoverShown
                    if panelOpen && !ProcessMemoryBudget.isOverSoftLimit {
                        await CodexRouterUsageScanner.resumeSharedParsedItems()
                    }
                    // A trigger runs the full-scope pass so local accounting actually happens even
                    // while the panel is closed. It stays non-forced, so a provider with a fresh
                    // snapshot still answers from cache.
                    let scope: ProviderRefreshContext.Scope = (panelOpen || pendingFullScopePass) ? .full : .menuBar
                    pendingFullScopePass = false
                    await ProviderRefreshContext.$scope.withValue(scope) {
                        await ProviderRefreshContext.$accountingCPUThrottleEnabled.withValue(true) {
                            await dataStore.refreshAll(maxConcurrentProviders: serializeProviders ? 1 : nil)
                        }
                    }
                    isFirstPass = false
                }
                // Keep the bounded CodexRouter index warm while the panel is open so append-triggered
                // refreshes do not decode its parsed-event cache from disk each time. Hidden cycles and
                // memory pressure release it; the durable index remains available for the next scan.
                let keepRouterIndexWarm = transparency.popoverShown && !ProcessMemoryBudget.isOverSoftLimit
                await PersistentJSONLScanCaches.unloadAfterRefreshCycle(
                    keepRouterItemsResident: keepRouterIndexWarm
                )
                // Re-evaluate quota pace milestones every tick — after the refresh so it sees fresh data,
                // and on every loop (not just on a fetch) so pace worsening from elapsed time alone still
                // alerts even with the popover closed.
                await dataStore.evaluateNotifications()
                // Day-rollover beat: always emits `app_daily_active` once per local day; flushes
                // prior-day provider rollups only while optional analytics are on. Runs on launch
                // and every interval, so always-running instances still produce a daily-active signal.
                telemetry.tick()
                // Panel closed → icons-only cadence (may stretch on battery). Panel open → keep
                // the fixed 5-minute full cadence so meters stay live in the panel.
                let sleepInterval = transparency.popoverShown
                    ? RefreshSetting.interval
                    : RefreshSetting.backgroundInterval
                let wake = await wakeSignal.waitForWake(timeout: sleepInterval)
                // Ledger appends while the panel is open must bypass the snapshot TTL; otherwise the
                // wake resumes the loop into an all-cache-hit pass and Today/charts stay stale for up
                // to ~5 minutes despite the vnode watcher. Only Codex cards need the miss — Cursor
                // keeps its cache.
                if case .notification(let name) = wake {
                    switch name {
                    case CodexRouterLedgerWatcher.didChangeNotification:
                        dataStore.invalidateSessionFreshnessForCodexSpend()
                    case BackgroundRefreshTrigger.didChangeNotification:
                        if triggerGate.shouldAccept(at: Date()) {
                            pendingFullScopePass = true
                            dataStore.invalidateLocalAccountingFreshness()
                        } else {
                            dropNextRefreshPass = true
                        }
                    default:
                        break
                    }
                }
            }
        }
    }
}
