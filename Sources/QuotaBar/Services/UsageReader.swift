import Foundation

public struct UsageReadResult: Sendable {
    public let data: Data
    public let warnings: [String]
}

public enum UsageReaderError: LocalizedError, Sendable {
    case unknownProvider(String)
    case refreshFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unknownProvider(let providerID):
            "Unknown provider: \(providerID)"
        case .refreshFailed(let message):
            "Refresh failed: \(message)"
        }
    }
}

/// One-shot access to the same provider cache and refresh engine used by the menu-bar app.
/// It owns no timer, local server, status item, updater, or other long-lived app service.
@MainActor
public struct UsageReader {
    private let defaults: UserDefaults
    private let settingsDomainName: String
    private let providersOverride: [ProviderRuntime]?

    public init(
        userDefaults: UserDefaults,
        settingsDomainName: String = Bundle.main.bundleIdentifier ?? ""
    ) {
        self.defaults = userDefaults
        self.settingsDomainName = settingsDomainName
        self.providersOverride = nil
    }

    init(userDefaults: UserDefaults, providers: [ProviderRuntime]) {
        self.defaults = userDefaults
        self.settingsDomainName = ""
        self.providersOverride = providers
    }

    public func read(providerID requestedProviderID: String? = nil, force: Bool = false) async throws -> UsageReadResult {
        // The CLI shares the app's provider settings, so migrate them before a store interprets the
        // enabled/disabled lists. If migration stops partway through, fail closed before discovery can
        // read optional providers' local credentials under the legacy "everything on" rule.
        let isFreshInstall = providersOverride == nil
            ? SettingsMigrator.isFreshInstall(defaults: defaults, domainName: settingsDomainName)
            : false
        if providersOverride == nil {
            let version = SettingsMigrator.migrate(defaults: defaults, domainName: settingsDomainName)
            guard version >= SettingsSchema.current else {
                throw UsageReaderError.refreshFailed(
                    "Provider settings could not be updated safely. Launch QuotaBar and try again."
                )
            }
        }

        // The launch account pass (see `ProviderAccountAssembly`): resolves each family's default
        // account so cached snapshots are guarded — and refreshed ones stamped — with the correct
        // account. Skipped when a test injects its own providers — they have no real homes to read.
        //
        // Warm the login-shell capture FIRST (off-main, one bounded subprocess). Identity-relevant
        // keys are pinned to the persisted shell-environment snapshot, but a CLI spawned without the
        // user's shell exports AND without a snapshot (the app never ran here) still needs the live
        // capture warm before the identity read — a MainActor read never triggers the capture itself,
        // so identity would read one home while the providers' off-main reads (which do trigger it)
        // fetch usage from another. From an interactive terminal the capture is redundant but harmless.
        if providersOverride == nil {
            let captured = await Task.detached(priority: .userInitiated) {
                LoginShellEnvironment.shared.ensureCaptured()
            }.value
            if !captured {
                await Task.detached(priority: .utility) {
                    _ = LoginShellEnvironment.shared.retryCaptureAfterFailure()
                }.value
            }
        }
        let registeredCodexHomes = providersOverride == nil
            ? CodexAccountRegistrationStore(defaults: defaults).registeredHomes
            : []
        let enablement = ProviderEnablementStore(defaults: defaults)
        let requestedToken = requestedProviderID?.lowercased()
        let requestedProviderFamily = requestedToken.map(ProviderAccountID.family(of:))
        let requestedProviderNeedsClaudeAccounts = requestedProviderID.map {
            ProviderAccountID.family(of: $0.lowercased()) == "claude"
        } ?? false
        let requestedProviderNeedsOpenCodeAccounts = requestedProviderID.map {
            ProviderAccountID.family(of: $0.lowercased()) == "opencode"
        } ?? false
        let discoverClaudeDesktopOrganizations = enablement.hasEnabledProviderFamily("claude")
            || requestedProviderNeedsClaudeAccounts
        let accountAssembly: ProviderAccountAssembly
        if providersOverride == nil {
            // Account discovery reads provider auth files and performs silent Keychain metadata
            // queries. Keep that synchronous work off the CLI's MainActor, matching app launch.
            let discovery = await loadOffMainActor {
                ProviderAccountAssembly.scanForLaunch(
                    waitsForLoginShell: false,
                    rawRegisteredCodexHomes: registeredCodexHomes,
                    discoverClaudeDesktopOrganizations: discoverClaudeDesktopOrganizations
                )
            }
            accountAssembly = ProviderAccountAssembly.make(
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
        } else {
            accountAssembly = ProviderAccountAssembly(identityKeysByCard: [:])
        }
        let shouldDiscoverOpenCodeAccounts = providersOverride == nil
            && (enablement.hasEnabledProviderFamily("opencode") || requestedProviderNeedsOpenCodeAccounts)
        let openCodeAccountInventory: OpenCodeGoAccountInventory?
        if shouldDiscoverOpenCodeAccounts {
            openCodeAccountInventory = await OpenCodeProvider.discoverAccountInventory()
        } else {
            openCodeAccountInventory = nil
        }
        let providers = providersOverride ?? ProviderCatalog.make(
            defaults: defaults,
            claudeCards: accountAssembly.claudeCards,
            codexCards: accountAssembly.codexCards,
            claudeIdentityKeys: accountAssembly.identityKeysByCard,
            claudeDesktopKeyCache: accountAssembly.desktopKeyCache,
            codexDefaultIdentityKey: accountAssembly.identityKeysByCard["codex"],
            codexDefaultHome: accountAssembly.defaultCodexHome,
            codexLogHomes: registeredCodexHomes,
            openCodeGoAccountInventory: openCodeAccountInventory,
            openCodeAccountInventoryDeferred: providersOverride == nil && !shouldDiscoverOpenCodeAccounts,
            // A named CLI request may read that provider's own local sources for this action. Other
            // providers folded into OpenCode keep following the saved enablement choices.
            isProviderEnabled: { id in
                enablement.isEnabled(id)
                    || requestedProviderFamily == ProviderAccountID.family(of: id)
            }
        )
        var providerIdentityKeys = accountAssembly.identityKeysByCard
        if providersOverride == nil {
            providerIdentityKeys["cursor"] = await loadOffMainActor {
                CursorAuthStore().cacheIdentityKeyForLaunch()
            }
            providerIdentityKeys["antigravity"] = await loadOffMainActor {
                AntigravityAuthStore().cacheIdentityKeyForLaunch()
            }
        }
        if let openCodeAccountInventory {
            providerIdentityKeys["opencode"] = openCodeAccountInventory.cacheIdentityKey
        }
        let registry = WidgetRegistry.from(providers)
        if providersOverride == nil {
            let onboarding = OnboardingStore(defaults: defaults)
            _ = FirstRunSeeder.seedIfNeeded(
                isFreshInstall: isFreshInstall,
                providers: providers,
                enablement: enablement,
                onboarding: onboarding
            )
            _ = NewProviderSeeder.reconcileIfNeeded(providers: providers, enablement: enablement)
        }
        let knownIDs = Set(registry.providers.map(\.id))
        // A requested id names cards by plain string matching — an exact card id, or a family id
        // naming all of that family's cards — mirroring the local HTTP API exactly (see
        // `LocalUsageAPI.State.matchingCardIDs`). Never resolved from runtime state: the same
        // request names the same cards no matter who is logged in or what's enabled.
        let matchedIDs: Set<String>? = requestedToken.map { token in
            knownIDs.filter { $0 == token || ProviderAccountID.family(of: $0) == token }
        }
        if let requestedToken, let matchedIDs, matchedIDs.isEmpty {
            throw UsageReaderError.unknownProvider(requestedToken)
        }

        let includesProvider: @MainActor (String) -> Bool = { id in
            matchedIDs?.contains(id) ?? enablement.isEnabled(id)
        }
        let cache = ProviderSnapshotCache(userDefaults: defaults, allowsPersistedFreshness: true)
        let allProviderIDs = registry.providers.map(\.id)
        // The same account guard the app applies at launch: an entry that provably belongs to another
        // account (swap since it was written) is never served, and its provider counts as needing a
        // refresh even while the stale entry is TTL-fresh.
        let staleAccountStampIDs = Set(allProviderIDs.filter {
            cache.hasStaleAccountStamp(providerID: $0, currentIdentityKey: providerIdentityKeys[$0])
        })
        var cachedSnapshots = cache.loadSnapshots(providerIDs: allProviderIDs)
        for providerID in staleAccountStampIDs {
            guard let snapshot = cachedSnapshots[providerID] else { continue }
            if providerID == "opencode" || providerID == "antigravity" {
                cachedSnapshots[providerID] = WidgetDataStore.snapshotByClearingQuotaState(snapshot)
            } else {
                cachedSnapshots.removeValue(forKey: providerID)
            }
        }
        let savedOrder = LayoutPersistence(
            defaults: defaults,
            storageKey: "openusage.layout.v1"
        ).loadProviderOrder() ?? []
        let orderedIDs = registry.orderedProviderIDs(savedOrder: savedOrder)
        let enabledOrderedIDs = orderedIDs.filter(includesProvider)
        let needsRefresh = force || enabledOrderedIDs.contains {
            cache.snapshot(providerID: $0) == nil || staleAccountStampIDs.contains($0)
        }
        var snapshots = cachedSnapshots
        var warnings: [String] = []
        var errors: [String: String] = [:]

        if needsRefresh {
            LoginShellEnvironment.shared.prewarm()
            let dataStore = WidgetDataStore(
                registry: registry,
                providers: providers,
                cache: cache,
                defaults: defaults,
                isProviderEnabled: includesProvider,
                // The CLI shares the app's snapshot cache, so its writes must carry the same account
                // stamp — an unstamped claude/codex entry would be discarded at the app's next launch.
                providerIdentityKeys: providerIdentityKeys
            )
            let shouldFlushPersistence = providersOverride == nil
            await withThrottledFullAccounting {
                if let matchedIDs {
                    for providerID in orderedIDs.filter(matchedIDs.contains) {
                        _ = await dataStore.refresh(providerID: providerID, force: force)
                    }
                } else {
                    await dataStore.refreshAll(force: force)
                }
                if shouldFlushPersistence {
                    await PersistentJSONLScanCaches.flushPendingWrites()
                }
            }
            snapshots = dataStore.snapshots
            errors = dataStore.providerErrors
            warnings = orderedIDs
                .compactMap { id in errors[id].map { "\(id): \($0)" } }
        }

        let state = LocalUsageAPI.State(
            enabledOrderedIDs: enabledOrderedIDs,
            knownIDs: knownIDs,
            snapshots: snapshots,
            limitDescriptors: registry.limitDescriptorsByProvider,
            errors: errors
        )
        let path = requestedToken.map { "/v1/limits/\($0)" } ?? "/v1/limits"
        let response = LocalUsageAPI.respond(method: "GET", path: path, state: state)
        guard let data = response.body else {
            // Unreachable in practice: the token was validated above and the limits routes always
            // produce a body for a known token. Fail loudly rather than print nothing.
            throw UsageReaderError.refreshFailed(warnings.first ?? "local read produced no data")
        }
        return UsageReadResult(data: data, warnings: warnings)
    }

}
