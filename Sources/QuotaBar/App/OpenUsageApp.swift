import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var container: AppContainer?
    private var statusItemController: StatusItemController?
    private var loadingStatusItem: NSStatusItem?
    private var accountDiscovery: ProviderAccountDiscovery?
    private var accountAssembly: ProviderAccountAssembly?
    private var singleInstanceLock: SingleInstanceLock.Token?
    private var isReloadingProviderCatalog = false
    private var pendingProviderCatalogReloads = ProviderCatalogReloadQueue()

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Open/trim the file log, seed the cached level, and emit the startup line BEFORE anything
        // else logs, so the first lines of a session are captured.
        AppLog.bootstrap()
        // Kernel-level single-instance lock (#874): rejects a duplicate even when two copies launch
        // so close together that the workspace guard's LaunchServices snapshot misses the peer.
        var holdsLock = false
        if let bundleID = Bundle.main.bundleIdentifier {
            switch SingleInstanceLock.acquire(bundleIdentifier: bundleID) {
            case .acquired(let token):
                singleInstanceLock = token
                holdsLock = true
            case .alreadyRunning:
                SingleInstanceGuard.activateExistingInstance()
                AppLog.info(.lifecycle, "duplicate launch detected by process lock; terminating")
                NSApp.terminate(nil)
                return
            case .failed(let message):
                AppLog.error(.lifecycle, "single-instance lock unavailable: \(message)")
            }
        }
        // The lock winner must NOT consult the workspace guard: its snapshot can still contain a
        // lock loser that is mid-exit (alive, lower PID), and yielding to it leaves ZERO instances
        // (reproduced in #874). The guard remains only as the fallback for unbundled launches
        // (`swift run` has no bundle ID) or lock setup failure. `terminate(_:)` unwinds
        // asynchronously and is cancellable, so we MUST return here — otherwise this method keeps
        // running and creates the very duplicate it was meant to prevent.
        if !holdsLock, SingleInstanceGuard.deferToExistingInstance() {
            AppLog.info(.lifecycle, "duplicate launch detected; handing off to the running instance and terminating")
            NSApp.terminate(nil)
            return
        }
        // Versioned settings migration — replaces the old beta-era "wipe all settings on every update".
        // MUST run before anything reads or writes UserDefaults (AppKit below, AppearanceSetting, and the
        // AppContainer stores), so migrated values are in place when the stores load and a genuine fresh
        // install still presents an empty domain — how the migrator tells a first launch from an upgrade.
        // Nothing is wiped now; settings carry across updates. See `SettingsMigrator`.
        // The fresh-install answer is captured BEFORE migrating (the schema stamp makes the domain
        // non-empty) and handed to `AppContainer`, whose `FirstRunSeeder` seeds a minimal provider set.
        let isFreshInstall = SettingsMigrator.isFreshInstall()
        SettingsMigrator.migrate()
        // Let only the `SMAppService` login item drive startup: opt out of AppKit's reopen-on-login
        // so a reboot doesn't also restore us and race the login item in the first place. The lock
        // above resolves same-bundle startup races even if both launch triggers fire; this just avoids
        // the wasted second launch.
        NSApp.disableRelaunchOnLogin()
        // The legacy Tauri edition's autostart agent (~/Library/LaunchAgents/QuotaBar.plist)
        // survives the upgrade and re-launches this binary at every login, racing the login item —
        // the double launch behind #874 and the "SUNSTORY LLC" Login Items entry from #607.
        // Deleting it (only when it provably points into our bundle) stops that race at the source;
        // the instance guard above stays as the referee for the remaining triggers. Runs after the
        // guard on purpose, so only the surviving copy touches the file.
        LegacyLaunchAgentCleanup.removeLeftoverAgent()
        // App-wide theme override (NSApp.appearance): the popover ignores SwiftUI's
        // preferredColorScheme, so the override is applied at the AppKit level once at launch;
        // the Theme picker on the Settings screen re-applies it on change.
        AppearanceSetting.applyCurrent()
        showLoadingStatusItem()

        if ShellEnvironmentSnapshotStore.launchSnapshot == nil,
           !LoginShellEnvironment.shared.capturedSuccessfully {
            Task { [weak self] in
                let captured = await Task.detached(priority: .userInitiated) {
                    _ = LoginShellEnvironment.shared.ensureCaptured()
                    return LoginShellEnvironment.shared.capturedSuccessfully
                }.value
                if !captured {
                    await Task.detached(priority: .utility) {
                        _ = LoginShellEnvironment.shared.retryCaptureAfterFailure()
                    }.value
                }
                self?.finishLaunching(isFreshInstall: isFreshInstall)
            }
            return
        }
        finishLaunching(isFreshInstall: isFreshInstall)
    }

    private func finishLaunching(
        isFreshInstall: Bool,
        completesCodexReload: Bool = false,
        completesClaudeReload: Bool = false,
        previouslyDiscoveredCodexAccountIDs: Set<String> = [],
        restorePresentationState: StatusItemController.ReplacementPresentationState? = nil
    ) {
        let rawRegisteredHomes = UserDefaults.standard.stringArray(
            forKey: CodexAccountRegistrationStore.storageKey
        ) ?? []
        let shouldDiscoverOpenCodeAccounts = ProviderEnablementStore()
            .hasEnabledProviderFamily("opencode")
        let discoverClaudeDesktopOrganizations = ProviderEnablementStore()
            .hasEnabledProviderFamily("claude")
        _ = ProviderRefreshContext.withBackgroundContext {
            Task { [weak self] in
                async let discoveryLoad = loadOffMainActor {
                    ProviderAccountAssembly.scanForLaunch(
                        waitsForLoginShell: true,
                        rawRegisteredCodexHomes: rawRegisteredHomes,
                        discoverClaudeDesktopOrganizations: discoverClaudeDesktopOrganizations,
                        forceClaudeAccountDiscovery: completesClaudeReload
                    )
                }
                async let cursorHistoryIdentityKeyLoad = loadOffMainActor {
                    CursorAuthStore().cacheIdentityKeyForLaunch()
                }
                async let antigravityIdentityKeyLoad = loadOffMainActor {
                    AntigravityAuthStore().cacheIdentityKeyForLaunch()
                }
                async let openCodeAccountLoad: OpenCodeGoAccountInventory? = shouldDiscoverOpenCodeAccounts
                    ? OpenCodeProvider.discoverAccountInventory()
                    : nil
                let (discovery, cursorHistoryIdentityKey, antigravityIdentityKey, openCodeGoAccountInventory) = await (
                    discoveryLoad,
                    cursorHistoryIdentityKeyLoad,
                    antigravityIdentityKeyLoad,
                    openCodeAccountLoad
                )
                guard let self else { return }
                self.accountDiscovery = discovery
                let assembly = ProviderAccountAssembly.make(
                    observer: DefaultAccountObserver(),
                    accountsStore: ProviderAccountsStore(),
                    precomputedDiscovery: discovery
                )
                self.accountAssembly = assembly
                if completesCodexReload {
                    ProviderEnablementStore().enableNewlyRegisteredCodexAccounts(
                        discoveredIDs: Set(assembly.codexCards.map(\.id)),
                        previouslyDiscoveredIDs: previouslyDiscoveredCodexAccountIDs
                    )
                }
                let container = AppContainer(
                    isFreshInstall: isFreshInstall,
                    accountDiscovery: discovery,
                    accountAssembly: assembly,
                    cursorHistoryIdentityKey: cursorHistoryIdentityKey,
                    antigravityIdentityKey: antigravityIdentityKey,
                    openCodeGoAccountInventory: openCodeGoAccountInventory,
                    onOpenCodeGoKeysChanged: { [weak self] in
                        self?.reloadAfterOpenCodeGoKeysChanged()
                    },
                    onOpenCodeEnablementRequiresCatalogReload: { [weak self] in
                        self?.reloadAfterOpenCodeEnablement()
                    },
                    onClaudeEnablementRequiresCatalogReload: { [weak self] in
                        self?.reloadAfterClaudeEnablement()
                    }
                )
                container.codexAccountRegistration.onAccountRegistered = { [weak self] in
                    self?.reloadAfterCodexAccountRegistration()
                }
                self.container = container
                let controller = StatusItemController(container: container)
                self.statusItemController = controller
                self.removeLoadingStatusItem()
                if let restorePresentationState { controller.restorePresentation(restorePresentationState) }
                if completesCodexReload {
                    self.isReloadingProviderCatalog = false
                    self.continuePendingProviderCatalogReload()
                } else if completesClaudeReload {
                    self.isReloadingProviderCatalog = false
                    self.continuePendingProviderCatalogReload()
                }
            }
        }
    }

    /// Account discovery is normally a launch-time operation because provider runtimes own their
    /// account-scoped home and identity. Rebuild the small composition root after Codex finishes an
    /// additional login so the new provider/card/status item appears immediately in this session.
    private func reloadAfterCodexAccountRegistration() {
        guard !isReloadingProviderCatalog else {
            pendingProviderCatalogReloads.enqueue(.codexAccounts)
            return
        }
        isReloadingProviderCatalog = true
        AppLog.info(.lifecycle, "reloading provider catalog after Codex account registration")
        let previousCodexAccountIDs = Set(
            container?.registry.providers.map(\.id).filter { $0.hasPrefix("codex@") } ?? []
        )
        container?.prepareForProviderCatalogReload()
        let presentation = statusItemController?.replacementPresentationState()
        statusItemController?.tearDown()
        statusItemController = nil
        container = nil
        showLoadingStatusItem()
        finishLaunching(
            isFreshInstall: false,
            completesCodexReload: true,
            previouslyDiscoveredCodexAccountIDs: previousCodexAccountIDs,
            restorePresentationState: presentation
        )
    }

    /// A disabled Claude family skips Desktop organization credential discovery. The first explicit
    /// enable re-runs account discovery before the replacement container can paint a cached org row.
    private func reloadAfterClaudeEnablement() {
        guard accountDiscovery?.didSkipClaudeDesktopDiscovery == true else { return }
        guard !isReloadingProviderCatalog else {
            pendingProviderCatalogReloads.enqueue(.claudeAccounts)
            return
        }
        isReloadingProviderCatalog = true
        AppLog.info(.lifecycle, "reloading provider catalog after Claude was enabled")
        container?.prepareForProviderCatalogReload()
        let presentation = statusItemController?.replacementPresentationState()
        statusItemController?.tearDown()
        statusItemController = nil
        container = nil
        showLoadingStatusItem()
        finishLaunching(
            isFreshInstall: false,
            completesClaudeReload: true,
            restorePresentationState: presentation
        )
    }

    /// Account discovery is unchanged when the user adds or removes a saved OpenCode Go key. Rebuild
    /// the registry from the launch snapshot so the new account-specific meter descriptors are live
    /// immediately without repeating the slow Claude Desktop/account scan.
    private func reloadAfterOpenCodeEnablement() {
        reloadAfterOpenCodeGoKeysChanged(invalidateOpenCodeQuota: false)
    }

    private func reloadAfterOpenCodeGoKeysChanged(invalidateOpenCodeQuota: Bool = true) {
        guard !isReloadingProviderCatalog else {
            pendingProviderCatalogReloads.enqueue(
                invalidateOpenCodeQuota ? .openCodeGoKeys : .openCodeEnablement
            )
            return
        }
        guard let accountDiscovery, let accountAssembly else { return }
        isReloadingProviderCatalog = true
        let reason = invalidateOpenCodeQuota ? "OpenCode Go key change" : "OpenCode enablement"
        AppLog.info(.lifecycle, "reloading provider catalog after \(reason)")
        container?.prepareForProviderCatalogReload(invalidateOpenCodeQuota: invalidateOpenCodeQuota)
        let presentation = statusItemController?.replacementPresentationState()
        statusItemController?.tearDown()
        statusItemController = nil
        container = nil
        showLoadingStatusItem()

        _ = ProviderRefreshContext.withBackgroundContext {
            Task { [weak self] in
                async let openCodeGoAccountInventoryLoad = OpenCodeProvider.discoverAccountInventory()
                async let cursorHistoryIdentityKeyLoad = loadOffMainActor {
                    CursorAuthStore().cacheIdentityKeyForLaunch()
                }
                async let antigravityIdentityKeyLoad = loadOffMainActor {
                    AntigravityAuthStore().cacheIdentityKeyForLaunch()
                }
                let (openCodeGoAccountInventory, cursorHistoryIdentityKey, antigravityIdentityKey) = await (
                    openCodeGoAccountInventoryLoad,
                    cursorHistoryIdentityKeyLoad,
                    antigravityIdentityKeyLoad
                )
                guard let self else { return }
                let replacement = AppContainer(
                    isFreshInstall: false,
                    accountDiscovery: accountDiscovery,
                    accountAssembly: accountAssembly,
                    cursorHistoryIdentityKey: cursorHistoryIdentityKey,
                    antigravityIdentityKey: antigravityIdentityKey,
                    openCodeGoAccountInventory: openCodeGoAccountInventory,
                    onOpenCodeGoKeysChanged: { [weak self] in
                        self?.reloadAfterOpenCodeGoKeysChanged()
                    },
                    onOpenCodeEnablementRequiresCatalogReload: { [weak self] in
                        self?.reloadAfterOpenCodeEnablement()
                    },
                    onClaudeEnablementRequiresCatalogReload: { [weak self] in
                        self?.reloadAfterClaudeEnablement()
                    }
                )
                replacement.codexAccountRegistration.onAccountRegistered = { [weak self] in
                    self?.reloadAfterCodexAccountRegistration()
                }
                self.container = replacement
                let controller = StatusItemController(container: replacement)
                self.statusItemController = controller
                self.removeLoadingStatusItem()
                if let presentation { controller.restorePresentation(presentation) }
                self.isReloadingProviderCatalog = false
                self.continuePendingProviderCatalogReload()
            }
        }
    }

    private func continuePendingProviderCatalogReload() {
        guard !isReloadingProviderCatalog,
              let request = pendingProviderCatalogReloads.takeNext()
        else { return }
        switch request {
        case .codexAccounts:
            reloadAfterCodexAccountRegistration()
        case .claudeAccounts:
            reloadAfterClaudeEnablement()
        case .openCodeGoKeys:
            reloadAfterOpenCodeGoKeysChanged()
        case .openCodeEnablement:
            reloadAfterOpenCodeEnablement()
        }
    }

    private func showLoadingStatusItem() {
        guard loadingStatusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "QuotaBar is loading")
        item.button?.image = image
        item.button?.toolTip = "QuotaBar is loading provider accounts"
        let menu = NSMenu()
        let loading = NSMenuItem(title: "QuotaBar Is Loading…", action: nil, keyEquivalent: "")
        loading.isEnabled = false
        menu.addItem(loading)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit QuotaBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        item.menu = menu
        loadingStatusItem = item
    }

    private func removeLoadingStatusItem() {
        guard let loadingStatusItem else { return }
        NSStatusBar.system.removeStatusItem(loadingStatusItem)
        self.loadingStatusItem = nil
    }

    /// Flush queued telemetry on quit. The SDK's lifecycle autocapture is off (we emit our own daily
    /// rollups), so it won't auto-flush on termination — this explicit flush keeps low-frequency events
    /// from being stranded across a clean quit.
    public func applicationWillTerminate(_ notification: Notification) {
        container?.codexAccountRegistration.cancelLogin()
        container?.telemetry.flush()
    }
}
