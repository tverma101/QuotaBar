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
    /// Provider runtimes, kept so Customize's Reset All can restore the owner-selected default set and
    /// register the current provider IDs.
    private let providers: [ProviderRuntime]
    /// Shared with the enablement callback so turning off the final Codex card disarms ledger watches
    /// immediately, without waiting for the periodic refresh loop to consume its buffered wake.
    @ObservationIgnored private let ledgerWatcher: CodexRouterLedgerWatcher
    /// Read-only usage API on 127.0.0.1:6736 for other local apps (silently off when the port is taken).
    private let localAPI: LocalUsageServer
    // A `let` of a `Sendable` `Task` is implicitly nonisolated, so the nonisolated `deinit` can cancel it.
    private let refreshTask: Task<Void, Never>
    /// Synchronous fresh-install provider seeding (`FirstRunSeeder`); nil when no seeding is needed.
    private let seedTask: Task<Void, Never>?
    /// Synchronous registry bookkeeping (`NewProviderSeeder`); it never starts a credential probe.
    private let newProviderTask: Task<Void, Never>?
    /// Persists a fresh `ShellEnvironmentSnapshot` once the login-shell capture completes, so the next
    /// launch can read shell-exported facts (provider home overrides) even when its own capture is slow.
    private let shellEnvironmentSnapshotTask: Task<Void, Never>
    /// Drops parse caches when the OS warns about memory pressure.
    private let memoryPressureSource: DispatchSourceMemoryPressure

    /// `isFreshInstall` must be captured by the caller BEFORE `SettingsMigrator.migrate()` runs (the
    /// migrator's schema stamp makes the defaults domain non-empty). See `AppDelegate`.
    init(
        isFreshInstall: Bool = false,
        accountDiscovery: ProviderAccountDiscovery,
        accountAssembly: ProviderAccountAssembly,
        cursorHistoryIdentityKey: String? = nil,
        antigravityIdentityKey: String = AntigravityAuthStore.unresolvedCacheIdentityKey,
        openCodeGoAccountIdentities: [OpenCodeGoAccountIdentity]? = nil,
        openCodeGoAccountInventory: OpenCodeGoAccountInventory? = nil,
        onOpenCodeGoKeysChanged: @escaping @MainActor () -> Void = {},
        onOpenCodeEnablementRequiresCatalogReload: @escaping @MainActor () -> Void = {},
        onClaudeEnablementRequiresCatalogReload: @escaping @MainActor () -> Void = {}
    ) {
        // Capture the user's login-shell environment off-main so provider keys exported in a shell
        // profile (e.g. OPENROUTER_API_KEY) resolve in a Finder/Dock-launched build, not only when
        // run from a terminal. Warmed here so the first refresh finds the cache ready.
        LoginShellEnvironment.shared.prewarm()
        // Once the capture lands, persist its identity-relevant facts so the NEXT launch has them
        // even if that launch's own capture is slow (see `ShellEnvironmentSnapshot`).
        self.shellEnvironmentSnapshotTask = ShellEnvironmentSnapshotStore(defaults: .standard).startRefreshTask()
        // The launch account pass: which account is signed in at each family's default home. Feeds
        // the snapshot cache's account stamp and reconciles the account registry.
        let codexAccounts = CodexAccountRegistrationStore(
            preNormalizedHomes: accountDiscovery.registeredCodexHomes
        )
        let codexAccountRegistration = CodexAccountRegistrationService(accounts: codexAccounts)
        let enablement = ProviderEnablementStore()
        if !accountAssembly.claudeCards.isEmpty,
           !accountAssembly.claudeCards.contains(where: { $0.id == "claude" })
        {
            _ = enablement.transferEnabledGenericClaudeFamily(
                to: accountAssembly.claudeCards.map(\.id)
            )
        }
        let hasPreloadedOpenCodeAccountInventory = openCodeGoAccountInventory != nil
            || openCodeGoAccountIdentities != nil
        let providers = ProviderCatalog.make(
            claudeCards: accountAssembly.claudeCards,
            codexCards: accountAssembly.codexCards,
            claudeIdentityKeys: accountAssembly.identityKeysByCard,
            claudeDesktopKeyCache: accountAssembly.desktopKeyCache,
            codexDefaultIdentityKey: accountAssembly.identityKeysByCard["codex"],
            codexDefaultHome: accountAssembly.defaultCodexHome,
            codexLogHomes: codexAccounts.registeredHomes,
            openCodeGoAccountIdentities: openCodeGoAccountIdentities,
            openCodeGoAccountInventory: openCodeGoAccountInventory,
            openCodeAccountInventoryDeferred: !hasPreloadedOpenCodeAccountInventory,
            onOpenCodeGoKeysChanged: onOpenCodeGoKeysChanged,
            isProviderEnabled: { [enablement] in enablement.isEnabled($0) }
        )
        let registry = WidgetRegistry.from(providers)
        let apiKeyProviders = providers.compactMap { $0 as? any APIKeyManaging }
        let goKeyProviders = providers.compactMap { $0 as? any GoKeyManaging }
        let notificationSettings = NotificationSettingsStore()
        let layout = LayoutStore(
            registry: registry,
            defaultMetricIDs: Self.accountScopedDefaults(DefaultLayout.metricIDs, registry: registry),
            defaultPinnedMetricIDs: Self.accountScopedDefaults(DefaultLayout.pinnedMetricIDs, registry: registry),
            defaultExpandedMetricIDs: Self.accountScopedDefaults(DefaultLayout.expandedMetricIDs, registry: registry),
            isProviderEnabled: { [enablement] in enablement.isEnabled($0) }
        )
        var providerIdentityKeys = accountAssembly.identityKeysByCard
        providerIdentityKeys["cursor"] = cursorHistoryIdentityKey
            ?? "cursor-unresolved-\(UUID().uuidString)"
        providerIdentityKeys["antigravity"] = antigravityIdentityKey
        if let openCodeGoAccountInventory {
            providerIdentityKeys["opencode"] = openCodeGoAccountInventory.cacheIdentityKey
        }
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: providers,
            isProviderEnabled: { [enablement] in enablement.isEnabled($0) },
            orderedDescriptors: { [layout] in layout.visiblePlaced.compactMap { layout.descriptor(for: $0) } },
            pinnedMetricIDs: { [layout] in layout.pinnedMetricIDs },
            notificationSettings: { notificationSettings },
            providerIdentityKeys: providerIdentityKeys
        )
        let iCloudSync = ICloudUsageSyncStore(dataStore: dataStore)
        let ledgerWatcher = CodexRouterLedgerWatcher(
            isPanelOpen: { PopoverTransparencyStore.isPopoverShownUnlocked }
        )
        // Re-enabling a provider should fetch it promptly, so clear any leftover failure backoff before
        // the enablement wake refreshes. `weak` breaks the cycle (dataStore already captures enablement).
        enablement.onProviderEnabled = { [weak dataStore] id in dataStore?.clearFailureBackoff(for: id) }
        enablement.onChange = { [weak dataStore, weak iCloudSync, weak ledgerWatcher, weak enablement] changedProviderIDs in
            dataStore?.providerEnablementDidChange(changedProviderIDs: changedProviderIDs)
            iCloudSync?.scheduleWrite()
            ledgerWatcher?.setEnabled(dataStore?.hasEnabledProviderFamily("codex") ?? false)
            if !hasPreloadedOpenCodeAccountInventory,
               changedProviderIDs.contains("opencode"),
               enablement?.isEnabled("opencode") == true
            {
                onOpenCodeEnablementRequiresCatalogReload()
            }
            if accountDiscovery.didSkipClaudeDesktopDiscovery,
               changedProviderIDs.contains(where: {
                   ProviderAccountID.family(of: $0) == "claude"
                       && enablement?.isEnabled($0) == true
               })
            {
                onClaudeEnablementRequiresCatalogReload()
            }
        }
        // Fresh installs start with the owner-selected defaults; no provider credential scan is needed.
        let onboarding = OnboardingStore()
        self.seedTask = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: isFreshInstall,
            providers: providers,
            enablement: enablement,
            onboarding: onboarding
        )
        // Providers added by an update are registered for Customize but remain off. Runs every launch;
        // fresh installs were just baselined by FirstRunSeeder.
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
        self.ledgerWatcher = ledgerWatcher

        // The resets popover's claim service shares a Codex provider's credential loading and HTTP
        // client so the claim's auth can't drift from the provider's. With more than one Codex account,
        // disable this write until the UI can explicitly choose a target account rather than guessing.
        let codexProviders = providers.compactMap { $0 as? CodexProvider }
        let writableCodex = codexProviders.count == 1 ? codexProviders[0] : nil
        self.codexResetClaim = writableCodex.map { codex in
            CodexResetClaimService(
                authStore: codex.authStore,
                usageClient: codex.usageClient,
                allowsKeychainFallback: codex.allowsKeychainFallback,
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
                        case .skipped, .inFlight:
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
        self.refreshTask = Self.startPeriodicRefresh(
            dataStore: dataStore,
            telemetry: telemetry,
            transparency: self.transparency,
            ledgerWatcher: ledgerWatcher
        )
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

    /// Copies each family metric onto registered account cards and each OpenCode cap onto the
    /// configured account-specific descriptors. The registry is the single source for the account
    /// inventory, so new OpenCode keys added during this run become placed by the same default seeder.
    static func accountScopedDefaults(_ metricIDs: [String], registry: WidgetRegistry) -> [String] {
        let additionalAccountIDsByFamily = Dictionary(
            grouping: registry.providers.map(\.id).filter { id in
                let family = ProviderAccountID.family(of: id)
                return id != family && ProviderAccountID.families.contains(family)
            },
            by: ProviderAccountID.family
        )
        let additionalOpenCodeMetricIDsByMetricID = Dictionary(
            grouping: registry.descriptors.compactMap { descriptor -> (String, String)? in
                guard let marker = descriptor.id.range(of: ".account.") else { return nil }
                return (String(descriptor.id[..<marker.lowerBound]), descriptor.id)
            },
            by: { $0.0 }
        ).mapValues { $0.map(\.1) }

        return metricIDs.flatMap { metricID -> [String] in
            guard let separator = metricID.firstIndex(of: ".") else { return [metricID] }
            let family = String(metricID[..<separator])
            var accountMetricIDs = [metricID]
            if let additionalIDs = additionalAccountIDsByFamily[family], !additionalIDs.isEmpty {
                let suffix = metricID[separator...]
                accountMetricIDs += additionalIDs.map { "\($0)\(suffix)" }
            }
            accountMetricIDs += additionalOpenCodeMetricIDsByMetricID[metricID] ?? []
            return accountMetricIDs
        }
    }

    deinit {
        refreshTask.cancel()
        seedTask?.cancel()
        newProviderTask?.cancel()
        shellEnvironmentSnapshotTask.cancel()
        memoryPressureSource.cancel()
    }

    /// Restores the owner-selected default enabled-provider set for Customize's "Reset All" action
    /// (`LayoutStore.resetToDefault` handles metrics, order, pins, and expansion).
    /// Delegates to `FirstRunSeeder.reseed`; the returned task is completed after synchronous updates.
    @discardableResult
    func reseedEnabledProviders() -> Task<Void, Never> {
        FirstRunSeeder.reseed(providers: providers, enablement: enablement)
    }

    /// Stop work owned by the old account registry before a replacement store starts refreshing.
    /// OpenCode key inventory changes also invalidate its quota meters: the new descriptor label may
    /// be the same while the credential behind that label has rotated.
    func prepareForProviderCatalogReload(invalidateOpenCodeQuota: Bool = false) {
        if invalidateOpenCodeQuota {
            dataStore.invalidateQuotaStateForCatalogReload(providerID: "opencode")
        }
        dataStore.cancelActiveProviderRefreshesForCatalogReload()
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
        // Persist the provider-reset intent before touching any other settings so a crash during this
        // action cannot leave credential-detected optional providers enabled on the next launch.
        reseedEnabledProviders()
        layout.resetToDefault()
        // The menu-bar Icon Style is a Settings preference, not part of the Customize layout reset.
        layout.menuBarStyle = .text
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

    /// Drives live updates: refresh on launch, then again at each quota deadline. Each pass honors the
    /// cache, so it only hits the network once a snapshot has actually expired. `@Observable` propagates
    /// the resulting snapshot changes to the menu-bar label and any open widgets. Fold-only accounting
    /// wakes can run between quota passes, but do not restart that deadline.
    ///
    /// Between passes the loop waits via `RefreshWakeSignal` for only the remaining time until the next
    /// quota deadline. It also wakes early for provider enablement, panel visibility, ledger, and external
    /// refresh notifications. The signal subscribes BEFORE the first pass and buffers, so a change that
    /// lands during a pass (a provider toggle, registry bookkeeping, or Customize's "Reset All" reseed)
    /// is never lost. Early passes still honor the cache and per-provider failure
    /// backoff.
    ///
    /// Wake subscriptions are limited to relevant named changes — not the firehose
    /// `UserDefaults.didChangeNotification`, which fires for the app's own snapshot-cache writes and
    /// unrelated global-domain changes from other processes. Those writes previously collapsed the
    /// fixed cadence into a refresh storm.
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

    private static func startPeriodicRefresh(
        dataStore: WidgetDataStore,
        telemetry: TelemetryRecorder,
        transparency: PopoverTransparencyStore,
        ledgerWatcher: CodexRouterLedgerWatcher
    ) -> Task<Void, Never> {
        ProviderRefreshContext.withBackgroundContext {
            Task {
            let wakeSignal = RefreshWakeSignal(names: [
                ProviderEnablementStore.didChangeNotification,
                CodexRouterLedgerWatcher.didChangeNotification,
                BackgroundRefreshTrigger.didChangeNotification,
                PopoverTransparencyStore.panelVisibilityDidChangeNotification
            ])
            dataStore.onDeferredRefreshReady = { [weak wakeSignal] request in
                wakeSignal?.signalDeferredRefreshReady(request)
            }
            dataStore.onDeferredRefreshesInvalidated = { [weak wakeSignal] providerIDs in
                wakeSignal?.cancelDeferredRefreshes(forProviderIDs: providerIDs)
            }
            // Tap-free external trigger (see `BackgroundRefreshTrigger`). Armed here, outside the
            // loop body, so a request landing mid-pass is still observed and applied to the *next*
            // pass rather than being lost.
            let backgroundTrigger = BackgroundRefreshTrigger()
            backgroundTrigger.start()
            // Arm vnode watch on the CodexRouter ledger so routed-turn spend updates within ~1s
            // (incremental tail parse). Open and closed panel turns run the same narrow
            // `localAccounting` scope—Codex/OpenCode folds only, without quota API re-reads.
            ledgerWatcher.setEnabled(dataStore.hasEnabledProviderFamily("codex"))
            defer {
                backgroundTrigger.stop()
                ledgerWatcher.stop()
            }
            var isFirstPass = true
            /// `.localAccounting` wakes do not reset this deadline. The closed-panel ledger watcher
            /// can wake faster than its local folds finish; measuring the next wait from every fold
            /// let a buffered ledger wake keep postponing menu-bar quota refreshes indefinitely.
            var lastQuotaRefreshUptime: TimeInterval?
            /// Detect manual/panel meter attempts made outside this loop so their already-fresh cache
            /// does not make the next due tick postpone the real fetch by another full interval.
            var lastObservedLiveQuotaRefreshUptime = dataStore.lastLiveQuotaRefreshUptime
            /// Full history folds have a separate cadence from live meters. While the panel remains
            /// open, quota meters can update every minute without re-folding every local corpus too.
            var lastHistoryRefreshUptime: TimeInterval?
            /// Latched by an external trigger; all enabled meters refresh first, followed by a fold.
            var pendingFullScopePass = false
            /// A due `.menuBar` request skipped behind a conflicting provider task. Retry just the
            /// pinned meter scope as soon as that task completes; this does not widen into history work.
            var pendingMenuBarMeterRetry = false
            /// Latched by a closed-panel ledger wake and consumed by the next pass, which then runs
            /// `.localAccounting` scope: the codex/opencode local folds recompute without re-reading
            /// live quota APIs, so Today tracks routed turns even while the panel is closed.
            var pendingLocalAccountingPass = false
            /// Latched by the panel-open edge and consumed by the next pass, which runs the
            /// two-phase panel sequence (`.panelMeters` then `.panelAccounting`). Unlike the old
            /// `.full` latch this one never widens to a full pass: the panel's own two phases cover
            /// both the meters and the local accounting. Set when the panel closes again before the
            /// pass starts, the phases still run — the meter stamps they produce stay fresh for the
            /// next open.
            var pendingPanelPass = false
            /// Accounting folds run in a tracked task so they cannot block the next meter deadline.
            var pendingHistoryAccountingPass = false
            /// A scheduled history deadline must perform a new fold even when its cached snapshot has
            /// no carry marker. This is separate from `force`, which changes merge and backoff rules.
            var pendingForcedHistoryAccountingPass = false
            /// A visible retry can queue its history fold behind a meters pass; retain the retry's
            /// explicit backoff bypass when that deferred request is routed through this loop.
            var pendingHistoryFailureBackoffBypass = false
            var accountingTask: Task<Void, Never>?
            /// Rate limit for trigger-caused passes, and whether a pass must be dropped because the
            /// previous one has not cleared the cooldown yet.
            var triggerGate = BackgroundRefreshGate()
            var dropNextRefreshPass = false
            // Local day the last pass ran in. Crossing midnight while the app runs must widen the
            // next pass to full scope: menuBar passes skip local accounting and re-stamp yesterday's
            // "Today" tile with a fresh timestamp, so without this trigger the menu bar kept showing
            // yesterday's spend until the user opened the panel (or an external trigger landed).
            var lastRefreshDay = DailyUsageAccumulator.dayKey(from: Date())
            defer {
                accountingTask?.cancel()
                dataStore.cancelProviderRefreshes(scopes: [.localAccounting, .panelAccounting])
            }
            while !Task.isCancelled {
                let panelOpen = transparency.popoverShown
                let quotaRefreshInterval = panelOpen
                    ? RefreshSetting.quotaInterval
                    : RefreshSetting.backgroundInterval
                let nowUptime = ProcessInfo.processInfo.systemUptime
                let quotaRefreshDue = lastQuotaRefreshUptime.map {
                    nowUptime - $0 >= quotaRefreshInterval
                } ?? true
                let historyRefreshDue = lastHistoryRefreshUptime.map {
                    nowUptime - $0 >= RefreshSetting.interval
                } ?? true
                let newlyDueHistoryPass = historyRefreshDue && !pendingHistoryAccountingPass
                if historyRefreshDue {
                    // Latch the cache bypass even when another panel/full pass already queued the
                    // accounting work. That queued fold may not begin until after the deadline, and
                    // must then still perform a fresh scan instead of hitting its recent cache.
                    pendingForcedHistoryAccountingPass = true
                    if newlyDueHistoryPass {
                        pendingHistoryAccountingPass = true
                        // Anchor when requested: a long or queued fold must not keep retriggering itself.
                        lastHistoryRefreshUptime = nowUptime
                    }
                }
                let hasPriorityPass = Self.hasPriorityRefreshPass(
                    quotaRefreshDue: quotaRefreshDue,
                    panelPassPending: pendingPanelPass,
                    fullScopePassPending: pendingFullScopePass,
                    historyAccountingPassPending: pendingHistoryAccountingPass,
                    localAccountingPassPending: pendingLocalAccountingPass,
                    menuBarMeterRetryPending: pendingMenuBarMeterRetry
                )
                if dropNextRefreshPass && !hasPriorityPass {
                    // A trigger arrived inside the gate's cooldown. The trigger's own debounce
                    // already collapsed the burst; this drops the one redundant pass that would
                    // otherwise be released the moment the prior pass ends. Notifications, telemetry,
                    // and the timer cadence below still run. A latched ledger wake is preserved:
                    // the cooldown drop is about the trigger's redundant full pass, and dropping
                    // Today's freshness with it would stall local accounting until the next wake.
                    dropNextRefreshPass = false
                    AppLog.info(.refresh, "background refresh pass skipped (inside trigger cooldown)")
                } else if !quotaRefreshDue && !pendingPanelPass && !pendingFullScopePass
                    && !pendingHistoryAccountingPass && !pendingLocalAccountingPass
                    && !pendingMenuBarMeterRetry {
                    // A timeout/notification race can leave a stale wake token in the shared stream
                    // after its cause has already been drained. With no deadline or latched work,
                    // consume the token without starting an early/default menu-bar pass.
                    AppLog.debug(.refresh, "ignoring wake with no pending refresh work")
                } else {
                    if dropNextRefreshPass {
                        // Discard the redundant full trigger, but never let it suppress a quota
                        // deadline or a panel-open refresh that is independently due.
                        dropNextRefreshPass = false
                        AppLog.info(
                            .refresh,
                            "background trigger pass skipped; servicing due quota or panel refresh"
                        )
                    }
                    // The first accounting pass can cold-load local indexes. Serialize those folds so
                    // large Codex and OpenCode corpora do not stack their parse arrays in memory. A
                    // closed-panel launch starts with quota-only menu-bar work instead; those independent
                    // provider requests stay concurrent so one slow endpoint cannot hold other pinned
                    // meters in line. Stale snapshots are already painted by the store.
                    let overSoftMemoryLimit = ProcessMemoryBudget.isOverSoftLimit
                    let serializeAccountingProviders = isFirstPass || overSoftMemoryLimit
                    let currentDay = DailyUsageAccumulator.dayKey(from: Date())
                    if currentDay != lastRefreshDay {
                        lastRefreshDay = currentDay
                        if !isFirstPass {
                            pendingFullScopePass = true
                            dataStore.invalidateLocalAccountingFreshness()
                            AppLog.info(.refresh, "local day rolled over; scheduling full accounting pass")
                        }
                    }
                    if panelOpen && !ProcessMemoryBudget.isOverSoftLimit {
                        await CodexRouterUsageScanner.resumeSharedParsedItems()
                    }
                    // All-enabled meter work runs before history folds, whether caused by a panel open,
                    // external refresh, daily rollover, or the five-minute history cadence. Closed-panel
                    // minute ticks stay pinned-only. Every fold then runs asynchronously so a slow local
                    // corpus cannot hold later subscription meter deadlines.
                    let runAllMeters = pendingFullScopePass || pendingPanelPass
                        || (panelOpen && quotaRefreshDue)
                    if runAllMeters || quotaRefreshDue || pendingMenuBarMeterRetry {
                        let requestsHistoryFold = pendingFullScopePass || pendingPanelPass || newlyDueHistoryPass
                        let meterScope: ProviderRefreshContext.Scope = runAllMeters ? .panelMeters : .menuBar
                        await ProviderRefreshContext.$scope.withValue(meterScope) {
                            await ProviderRefreshContext.$skipModelCatalogRefresh.withValue(true) {
                                await ProviderRefreshContext.$accountingCPUThrottleEnabled.withValue(true) {
                                    await dataStore.refreshAll(
                                        maxConcurrentProviders: overSoftMemoryLimit ? 1 : nil
                                    )
                                }
                            }
                        }
                        // Only a live provider attempt can move an early pass's deadline. A cache-hit
                        // panel open at 49s must not move the 60s tick to 109s. A due pass still
                        // advances when every provider is disabled, backed off, or otherwise skipped,
                        // preventing an immediate no-work loop.
                        if let liveRefreshUptime = dataStore.lastLiveQuotaRefreshUptime,
                           liveRefreshUptime != lastObservedLiveQuotaRefreshUptime {
                            lastObservedLiveQuotaRefreshUptime = liveRefreshUptime
                            lastQuotaRefreshUptime = liveRefreshUptime
                        } else if quotaRefreshDue {
                            lastQuotaRefreshUptime = ProcessInfo.processInfo.systemUptime
                            dataStore.markQuotaRefreshCheckCompleted()
                        }
                        if runAllMeters {
                            pendingFullScopePass = false
                            pendingPanelPass = false
                            if requestsHistoryFold {
                                pendingHistoryAccountingPass = true
                                pendingLocalAccountingPass = false
                            }
                        }
                        pendingMenuBarMeterRetry = false
                    }

                    if accountingTask == nil,
                       pendingHistoryAccountingPass || pendingLocalAccountingPass {
                        let accountingScope: ProviderRefreshContext.Scope = pendingHistoryAccountingPass
                            ? .panelAccounting
                            : .localAccounting
                        let bypassSnapshotCache = accountingScope == .panelAccounting
                            && pendingForcedHistoryAccountingPass
                        let bypassFailureBackoff = accountingScope == .panelAccounting
                            && pendingHistoryFailureBackoffBypass
                        pendingHistoryAccountingPass = false
                        pendingLocalAccountingPass = false
                        pendingForcedHistoryAccountingPass = false
                        pendingHistoryFailureBackoffBypass = false
                        if accountingScope == .panelAccounting {
                            lastHistoryRefreshUptime = ProcessInfo.processInfo.systemUptime
                        }
                        let maxConcurrentProviders = accountingScope == .panelAccounting
                            ? (serializeAccountingProviders ? 1 : nil)
                            : (overSoftMemoryLimit ? 1 : nil)
                        accountingTask = Task { @MainActor in
                            await ProviderRefreshContext.$scope.withValue(accountingScope) {
                                await ProviderRefreshContext.$skipModelCatalogRefresh.withValue(
                                    accountingScope == .localAccounting
                                ) {
                                    await ProviderRefreshContext.$accountingCPUThrottleEnabled.withValue(
                                        accountingScope == .localAccounting
                                    ) {
                                        await dataStore.refreshAll(
                                            bypassSnapshotCache: bypassSnapshotCache,
                                            bypassFailureBackoff: bypassFailureBackoff,
                                            maxConcurrentProviders: maxConcurrentProviders
                                        )
                                    }
                                }
                            }
                            accountingTask = nil
                            wakeSignal.signalWorkCompletion()
                        }
                    }
                    isFirstPass = false
                }
                // Keep the bounded CodexRouter index warm while the panel is open so append-triggered
                // refreshes do not decode its parsed-event cache from disk each time. Hidden cycles and
                // memory pressure release it; the durable index remains available for the next scan.
                let keepRouterIndexWarm = transparency.popoverShown && !ProcessMemoryBudget.isOverSoftLimit
                if accountingTask == nil {
                    await PersistentJSONLScanCaches.unloadAfterRefreshCycle(
                        keepRouterItemsResident: keepRouterIndexWarm
                    )
                }
                // Re-evaluate quota pace milestones every tick — after the refresh so it sees fresh data,
                // and on every loop (not just on a fetch) so pace worsening from elapsed time alone still
                // alerts even with the popover closed.
                await dataStore.evaluateNotifications()
                // Day-rollover beat: always emits `app_daily_active` once per local day; flushes
                // prior-day provider rollups only while optional analytics are on. Runs on launch
                // and every interval, so always-running instances still produce a daily-active signal.
                telemetry.tick()
                // Live quota meters and full history folds have separate cadences while the panel is
                // open. Closed-panel quota cadence still follows the power source.
                let sleepInterval = transparency.popoverShown
                    ? RefreshSetting.quotaInterval
                    : RefreshSetting.backgroundInterval
                let waitNow = ProcessInfo.processInfo.systemUptime
                let quotaElapsed = lastQuotaRefreshUptime.map { waitNow - $0 } ?? 0
                let quotaWaitRemaining = max(0, sleepInterval - quotaElapsed)
                let historyElapsed = lastHistoryRefreshUptime.map { waitNow - $0 } ?? 0
                let historyWaitRemaining = max(0, RefreshSetting.interval - historyElapsed)
                let hasRunnableAccounting = accountingTask == nil
                    && (pendingHistoryAccountingPass || pendingLocalAccountingPass)
                let hasRunnableMeters = pendingFullScopePass || pendingPanelPass || pendingMenuBarMeterRetry
                let wakeTimeout = hasRunnableAccounting || hasRunnableMeters
                    ? 0
                    : min(quotaWaitRemaining, historyWaitRemaining)
                _ = await wakeSignal.waitForWake(timeout: wakeTimeout)
                // Ledger appends invalidate only the enabled Codex/OpenCode accounting snapshots and
                // schedule their narrow local fold. Meter snapshots and unrelated history providers
                // keep their cache state; this wake never re-reads live quota APIs.
                for name in wakeSignal.takePendingNotifications() {
                    switch name {
                    case CodexRouterLedgerWatcher.didChangeNotification:
                        if dataStore.hasEnabledProviderFamily("codex") {
                            let affectsVisible = transparency.popoverShown
                                || dataStore.closedPanelLedgerWakeAffectsVisibleMetrics()
                            if affectsVisible {
                                pendingLocalAccountingPass = true
                                dataStore.invalidateLocalAccountingFreshness()
                                if transparency.popoverShown {
                                    AppLog.info(.refresh, "panel ledger wake; scheduling Codex/OpenCode local accounting")
                                } else {
                                    AppLog.info(.refresh, "closed-panel ledger wake; scheduling local accounting pass")
                                }
                            } else {
                                AppLog.debug(.refresh, "ignoring closed-panel ledger wake (no pinned spend or OpenCode metrics)")
                            }
                        } else {
                            AppLog.debug(.refresh, "ignoring CodexRouter ledger wake (no enabled Codex cards)")
                        }
                    case PopoverTransparencyStore.panelVisibilityDidChangeNotification:
                        // The store posts on the open edge only. Latch the two-phase panel pass so
                        // the panel's first paint is followed by fresh meters and folds even if the
                        // user closes it again before the pass starts.
                        pendingPanelPass = true
                    case ProviderEnablementStore.didChangeNotification:
                        // A full pass covers the newly-enabled provider and runs alongside any distinct
                        // ledger wake retained by RefreshWakeSignal. Its cache keeps unrelated providers cheap.
                        // Only keep the CodexRouter vnode sources armed while a Codex card is enabled.
                        ledgerWatcher.setEnabled(dataStore.hasEnabledProviderFamily("codex"))
                        pendingFullScopePass = true
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
                for request in wakeSignal.takePendingDeferredRefreshes() {
                    switch request.scope {
                    case .menuBar:
                        pendingMenuBarMeterRetry = true
                    case .panelMeters:
                        pendingPanelPass = true
                    case .localAccounting:
                        pendingLocalAccountingPass = true
                    case .panelAccounting:
                        if request.manualActionID != nil {
                            // A visible retry may have deferred its provider-local fold behind
                            // conflicting work. Resume that exact request with its original Keychain
                            // action context; a global scheduled pass would be silent and lose the
                            // one-dialog budget that phase one established.
                            Task { @MainActor in
                                _ = await dataStore.resumeDeferredManualHistoryRetry(request)
                            }
                        } else {
                            pendingHistoryAccountingPass = true
                            if request.bypassSnapshotCache {
                                pendingForcedHistoryAccountingPass = true
                            }
                            if request.bypassFailureBackoff {
                                pendingHistoryFailureBackoffBypass = true
                            }
                        }
                    case .full:
                        pendingFullScopePass = true
                    }
                    AppLog.info(
                        .refresh,
                        "resuming deferred provider refresh (\(request.providerID), scope=\(WidgetDataStore.batchScopeLabel(request.scope)))"
                    )
                }
            }
            }
        }
    }

    nonisolated static func hasPriorityRefreshPass(
        quotaRefreshDue: Bool,
        panelPassPending: Bool,
        fullScopePassPending: Bool,
        historyAccountingPassPending: Bool,
        localAccountingPassPending: Bool,
        menuBarMeterRetryPending: Bool = false
    ) -> Bool {
        quotaRefreshDue || panelPassPending || fullScopePassPending
            || historyAccountingPassPending || localAccountingPassPending || menuBarMeterRetryPending
    }
}
