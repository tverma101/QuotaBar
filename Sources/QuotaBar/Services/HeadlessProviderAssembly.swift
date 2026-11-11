import Foundation

/// Shared headless assembly for the one-shot CLI (`UsageReader`) and the scan-worker child
/// (`ScanWorkerCommand`): settings migration, shell-environment capture, account discovery,
/// provider construction, and cache-identity keys. Both entry points must resolve the same
/// credential sources in the same order, so the sequence lives in exactly one place — a second
/// copy here would let the child classify accounts differently from the app and CLI.
///
/// `forceEnabledFamilies` forces provider families on top of saved enablement while the catalog
/// is built: the CLI names one provider family, and the scan worker names the families of the
/// exact cards its parent asked it to fold. Extra cards built by a forced family are never
/// refreshed unless requested.
@MainActor
struct HeadlessProviderAssembly {
    let defaults: UserDefaults
    let settingsDomainName: String
    let providers: [ProviderRuntime]
    let registry: WidgetRegistry
    let providerIdentityKeys: [String: String]

    static func assemble(
        defaults: UserDefaults,
        settingsDomainName: String,
        forceEnabledFamilies: Set<String>
    ) async throws -> HeadlessProviderAssembly {
        // The CLI and the scan worker share the app's provider settings, so migrate them before a
        // store interprets the enabled/disabled lists. If migration stops partway through, fail
        // closed before discovery can read optional providers' local credentials under the legacy
        // "everything on" rule.
        let version = SettingsMigrator.migrate(defaults: defaults, domainName: settingsDomainName)
        guard version >= SettingsSchema.current else {
            throw UsageReaderError.refreshFailed(
                "Provider settings could not be updated safely. Launch QuotaBar and try again."
            )
        }

        // Warm the login-shell capture FIRST (off-main, one bounded subprocess). Identity-relevant
        // keys are pinned to the persisted shell-environment snapshot, but a headless process
        // spawned without the user's shell exports AND without a snapshot (the app never ran here)
        // still needs the live capture warm before the identity read — a MainActor read never
        // triggers the capture itself, so identity would read one home while the providers'
        // off-main reads (which do trigger it) fetch usage from another.
        let captured = await Task.detached(priority: .userInitiated) {
            LoginShellEnvironment.shared.ensureCaptured()
        }.value
        if !captured {
            await Task.detached(priority: .utility) {
                _ = LoginShellEnvironment.shared.retryCaptureAfterFailure()
            }.value
        }
        let registeredCodexHomes = CodexAccountRegistrationStore(defaults: defaults).registeredHomes
        let enablement = ProviderEnablementStore(defaults: defaults)
        let discoverClaudeDesktopOrganizations = enablement.hasEnabledProviderFamily("claude")
            || forceEnabledFamilies.contains("claude")
        // Account discovery reads provider auth files and performs silent Keychain metadata
        // queries. Keep that synchronous work off the MainActor, matching app launch.
        let discovery = await loadOffMainActor {
            ProviderAccountAssembly.scanForLaunch(
                waitsForLoginShell: false,
                rawRegisteredCodexHomes: registeredCodexHomes,
                discoverClaudeDesktopOrganizations: discoverClaudeDesktopOrganizations
            )
        }
        let accountAssembly = ProviderAccountAssembly.make(
            observer: DefaultAccountObserver(),
            accountsStore: ProviderAccountsStore(defaults: defaults),
            precomputedDiscovery: discovery
        )
        if !accountAssembly.claudeCards.isEmpty,
           !accountAssembly.claudeCards.contains(where: { $0.id == "claude" })
        {
            _ = enablement.transferEnabledGenericClaudeFamily(
                to: accountAssembly.claudeCards.map(\.id)
            )
        }
        let shouldDiscoverOpenCodeAccounts = enablement.hasEnabledProviderFamily("opencode")
            || forceEnabledFamilies.contains("opencode")
        let openCodeAccountInventory: OpenCodeGoAccountInventory?
        if shouldDiscoverOpenCodeAccounts {
            openCodeAccountInventory = await OpenCodeProvider.discoverAccountInventory()
        } else {
            openCodeAccountInventory = nil
        }
        let providers = ProviderCatalog.make(
            defaults: defaults,
            claudeCards: accountAssembly.claudeCards,
            codexCards: accountAssembly.codexCards,
            claudeIdentityKeys: accountAssembly.identityKeysByCard,
            claudeDesktopKeyCache: accountAssembly.desktopKeyCache,
            codexDefaultIdentityKey: accountAssembly.identityKeysByCard["codex"],
            codexDefaultHome: accountAssembly.defaultCodexHome,
            codexLogHomes: registeredCodexHomes,
            openCodeGoAccountInventory: openCodeAccountInventory,
            openCodeAccountInventoryDeferred: !shouldDiscoverOpenCodeAccounts,
            // A requested family's cards are built (and their local sources readable) for this
            // action even when saved enablement turned them off; the caller refreshes only the
            // providers it actually wants.
            isProviderEnabled: { id in
                enablement.isEnabled(id)
                    || forceEnabledFamilies.contains(ProviderAccountID.family(of: id))
            }
        )
        var providerIdentityKeys = accountAssembly.identityKeysByCard
        providerIdentityKeys["cursor"] = await loadOffMainActor {
            CursorAuthStore().cacheIdentityKeyForLaunch()
        }
        providerIdentityKeys["antigravity"] = await loadOffMainActor {
            AntigravityAuthStore().cacheIdentityKeyForLaunch()
        }
        if let openCodeAccountInventory {
            providerIdentityKeys["opencode"] = openCodeAccountInventory.cacheIdentityKey
        }
        let registry = WidgetRegistry.from(providers)
        return HeadlessProviderAssembly(
            defaults: defaults,
            settingsDomainName: settingsDomainName,
            providers: providers,
            registry: registry,
            providerIdentityKeys: providerIdentityKeys
        )
    }
}
