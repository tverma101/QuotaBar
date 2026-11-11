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

    public func read(providerID requestedProviderID: String? = nil, force: Bool = false,
                     diagnostic: Bool = false) async throws -> UsageReadResult {
        let requestedToken = requestedProviderID?.lowercased()
        let requestedFamily = requestedToken.map(ProviderAccountID.family(of:))

        let providers: [ProviderRuntime]
        let registry: WidgetRegistry
        let providerIdentityKeys: [String: String]
        let enablement = ProviderEnablementStore(defaults: defaults)
        if let providersOverride {
            // Test-injected providers have no real homes to read, so the migration, shell capture,
            // and account discovery that a real headless process needs are all skipped.
            providers = providersOverride
            registry = WidgetRegistry.from(providers)
            providerIdentityKeys = [:]
        } else {
            let isFreshInstall = SettingsMigrator.isFreshInstall(defaults: defaults, domainName: settingsDomainName)
            let assembly = try await HeadlessProviderAssembly.assemble(
                defaults: defaults,
                settingsDomainName: settingsDomainName,
                forceEnabledFamilies: requestedFamily.map { Set([$0]) } ?? []
            )
            providers = assembly.providers
            registry = assembly.registry
            providerIdentityKeys = assembly.providerIdentityKeys
            _ = FirstRunSeeder.seedIfNeeded(
                isFreshInstall: isFreshInstall,
                providers: providers,
                enablement: enablement,
                onboarding: OnboardingStore(defaults: defaults)
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

        if diagnostic {
            let report = UsageDiagnostics.make(providerIDs: enabledOrderedIDs, snapshots: snapshots, errors: errors,
                                               registry: registry, runtimes: providers, defaults: defaults)
            return UsageReadResult(data: try UsageDiagnostics.encode(report), warnings: report.findings.map {
                "\($0.providerID): \($0.severity): \($0.message)"
            })
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
