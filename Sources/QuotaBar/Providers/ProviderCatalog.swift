import Foundation

/// The installed provider set and its canonical order. Both the menu-bar app and one-shot CLI build
/// their runtimes here so credentials, refresh behavior, pricing, and normalization can never drift.
@MainActor
enum ProviderCatalog {
    static func make(
        defaults: UserDefaults = .standard,
        claudeCards: [ClaudeAccountCard] = [],
        codexCards: [CodexAccountCard] = [],
        claudeIdentityKeys: [String: String] = [:],
        claudeDesktopKeyCache: SafeStorageKeyCache? = nil,
        codexDefaultIdentityKey: String? = nil,
        codexDefaultHome: String? = nil,
        codexLogHomes: [String] = [],
        openCodeClaudeRoots: @escaping @Sendable () -> [URL] = {
            OpenCodeUsageScanner.discoverClaudeRoots()
        },
        openCodeGoAccountIdentities: [OpenCodeGoAccountIdentity]? = nil,
        openCodeGoAccountInventory: OpenCodeGoAccountInventory? = nil,
        openCodeAccountInventoryDeferred: Bool = false,
        onOpenCodeGoKeysChanged: @escaping @MainActor () -> Void = {},
        isProviderEnabled: @escaping @MainActor (String) -> Bool = { _ in true }
    ) -> [ProviderRuntime] {
        let openUsageEnvironment = QuotaBarEnvironmentReader()
        // Discovery and every runtime must share this cache, including the generic fallback used
        // when no account card could be materialized. Otherwise a successful launch-time Safe Storage
        // read can be repeated by the fallback provider on its first refresh.
        let desktopKeyCache = claudeDesktopKeyCache ?? SafeStorageKeyCache()
        var providers: [ProviderRuntime]
        if claudeCards.isEmpty {
            providers = [ClaudeProvider(
                authStore: ClaudeAuthStore(desktop: ClaudeDesktopAuthStore(keyCache: desktopKeyCache))
            )]
        } else {
            // All Claude account cards decrypt the same read-only Desktop Safe Storage secret. Share
            // the cache so one explicit approval serves the whole refresh instead of prompting per card.
            providers = claudeCards.map { card in
                let identity = claudeIdentityKeys[card.id] ?? card.identityKey
                let user = identity.split(separator: "|").first.map(String.init)
                let scanner = ClaudeLogUsageScanner(
                    accountUUID: user, organizationUUID: card.organizationID,
                    allowsUnattributedSessions: card.allowsUnattributedPiUsage
                )
                return ClaudeProvider(
                    provider: ClaudeProvider.makeProvider(
                        id: card.id,
                        displayName: claudeCards.count == 1 ? "Claude" : card.displayName
                    ),
                    authStore: ClaudeAuthStore(
                        desktop: ClaudeDesktopAuthStore(keyCache: desktopKeyCache),
                        desktopOrganization: card.organizationID,
                        expectedIdentityKey: identity,
                        desktopOnly: card.usesDesktopCredentials,
                        preferOrganizationScopedDesktop: claudeCards.count > 1 && !card.usesDesktopCredentials
                    ),
                    logUsageScanner: scanner,
                    allowsUnattributedPiUsage: card.allowsUnattributedPiUsage
                )
            }
        }

        let claudeProviders = providers.compactMap { $0 as? ClaudeProvider }
        let codexProviders: [ProviderRuntime]
        if codexCards.isEmpty {
            codexProviders = [CodexProvider(
                authStore: CodexAuthStore(environment: openUsageEnvironment),
                logUsageScanner: CodexLogUsageScanner(environment: openUsageEnvironment),
                initialAccountIdentityKey: codexDefaultIdentityKey
            )]
        } else {
            codexProviders = codexCards.map { card in
                // Auth must stay on a single home; commas would break AuthStore path resolution.
                let authEnvironment = OverrideEnvironmentReader(
                    ["CODEX_HOME": card.home],
                    base: openUsageEnvironment
                )
                let logHomeList = card.logHomes.isEmpty ? [card.home] : card.logHomes
                let logEnvironment = OverrideEnvironmentReader(
                    ["CODEX_HOME": logHomeList.joined(separator: ",")],
                    base: openUsageEnvironment
                )
                // Peer homes are identity-only sources: they let a managed card exclude hardlinked
                // rollout files copied from another account. Keep higher-priority owners in this map
                // even when their card is disabled; their provider is not refreshed or folded while off.
                let peerHomes: @MainActor () -> [URL] = {
                    let defaultHome = CodexAccountRegistrationStore.normalizedHome(
                        "~/.codex", homeDirectory: FileManager.default.homeDirectoryForCurrentUser
                    )
                    @MainActor func normalizedHomes(_ value: CodexAccountCard) -> [String] {
                        (value.logHomes.isEmpty ? [value.home] : value.logHomes)
                            .compactMap {
                                CodexAccountRegistrationStore.normalizedHome(
                                    $0, homeDirectory: FileManager.default.homeDirectoryForCurrentUser
                                )
                            }
                    }
                    @MainActor func priority(_ value: CodexAccountCard) -> (Int, String) {
                        let homes = normalizedHomes(value).sorted()
                        if let defaultHome, homes.contains(defaultHome) { return (0, defaultHome) }
                        return (1, homes.first ?? value.id)
                    }
                    let currentPriority = priority(card)
                    return codexCards
                        .filter { other in
                            guard other.id != card.id else { return false }
                            let otherPriority = priority(other)
                            return otherPriority.0 < currentPriority.0
                                || (otherPriority.0 == currentPriority.0 && otherPriority.1 < currentPriority.1)
                        }
                        .flatMap { normalizedHomes($0).map { URL(fileURLWithPath: $0) } }
                }
                return CodexProvider(
                    provider: CodexProvider.makeProvider(
                        id: card.id,
                        displayName: codexCards.count == 1 ? "Codex" : card.displayName
                    ),
                    authStore: CodexAuthStore(
                        environment: authEnvironment,
                        expectedIdentityKey: card.identityKey
                    ),
                    logUsageScanner: CodexLogUsageScanner(environment: logEnvironment),
                    expectedIdentityKey: card.identityKey,
                    allowsKeychainFallback: card.allowsKeychainFallback,
                    allowsUnattributedPiUsage: card.allowsUnattributedPiUsage,
                    peerHomes: peerHomes
                )
            }
        }

        providers += codexProviders
        let claudeProviderIDs = providers.map(\.provider.id).filter {
            ProviderAccountID.family(of: $0) == "claude"
        }
        let codexProviderIDs = codexProviders.map { $0.provider.id }
        let codexHomesByProviderID = Dictionary(uniqueKeysWithValues: zip(codexProviderIDs, codexCards).map { id, card in
            (id, card.logHomes.isEmpty ? [card.home] : card.logHomes)
        })
        var homeIdentityCandidates: [String: Set<String>] = [:]
        func recordCodexHome(_ rawHome: String, identityKey: String) {
            guard let normalized = CodexAccountRegistrationStore.normalizedHome(
                rawHome, homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            ) else { return }
            let path = URL(fileURLWithPath: normalized).resolvingSymlinksInPath().standardizedFileURL.path
            homeIdentityCandidates[path, default: []].insert(identityKey.lowercased())
        }
        for card in codexCards {
            for home in card.logHomes.isEmpty ? [card.home] : card.logHomes {
                recordCodexHome(home, identityKey: card.identityKey)
            }
        }
        if codexCards.isEmpty,
           let codexDefaultHome,
           let codexDefaultIdentityKey
        {
            recordCodexHome(codexDefaultHome, identityKey: codexDefaultIdentityKey)
        }
        let codexHomeIdentityKeys = homeIdentityCandidates.compactMapValues { identities in
            identities.count == 1 ? identities.first : nil
        }
        @MainActor func allCodexRouterAccountIdentityKeys() -> [String: String] {
            let identities = Set(
                codexCards.isEmpty
                    ? codexDefaultIdentityKey.map { [$0.lowercased()] } ?? []
                    : codexCards.map { $0.identityKey.lowercased() }
            )
            guard !identities.isEmpty else { return [:] }
            var identitiesByIdentifier: [String: Set<String>] = [:]
            for identity in identities {
                identitiesByIdentifier[identity, default: []].insert(identity)
                if let fingerprint = CodexProxyUsageScanner.accountFingerprint(for: identity) {
                    identitiesByIdentifier[fingerprint.lowercased(), default: []].insert(identity)
                }
            }
            let aliases = CodexRouterUsageScanner.loadPoolIdentityAliases(
                environment: openUsageEnvironment,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            )
            for (alias, identity) in aliases where identities.contains(identity.lowercased()) {
                identitiesByIdentifier[alias.lowercased(), default: []].insert(identity.lowercased())
            }
            return identitiesByIdentifier.compactMapValues { identities in
                identities.count == 1 ? identities.first : nil
            }
        }
        @MainActor func enabledCodexIdentityKeys() -> Set<String> {
            guard !codexCards.isEmpty else { return [] }
            return Set(
                zip(codexProviderIDs, codexCards)
                    .filter { isProviderEnabled($0.0) }
                    .map { $0.1.identityKey.lowercased() }
            )
        }
        @MainActor func enabledRouterAccountIdentityKeys() -> [String: String] {
            let enabledIdentities: Set<String>
            if codexCards.isEmpty {
                enabledIdentities = isProviderEnabled("codex")
                    ? Set(codexDefaultIdentityKey.map { [$0.lowercased()] } ?? [])
                    : []
            } else {
                enabledIdentities = enabledCodexIdentityKeys()
            }
            guard !enabledIdentities.isEmpty else { return [:] }
            return allCodexRouterAccountIdentityKeys().filter {
                enabledIdentities.contains($0.value)
            }
        }
        let registeredCodexURLs = (
            codexLogHomes + codexCards.flatMap { card in
                card.logHomes.isEmpty ? [card.home] : card.logHomes
            }
        ).compactMap {
            URL(fileURLWithPath: $0)
        }
        let openCode = OpenCodeProvider(
            usageScanner: OpenCodeUsageScanner(
                claudeRoots: openCodeClaudeRoots,
                codexHomes: {
                    OpenCodeUsageScanner.uniqueCodexHomes(
                        CodexLogUsageScanner.discoverCodexHomes(environment: openUsageEnvironment)
                            + registeredCodexURLs
                    )
                },
                hermesStateDBPath: {
                    try OpenCodeUsageScanner.configuredHermesStateDBPath(
                        environment: openUsageEnvironment,
                        homeDirectory: FileManager.default.homeDirectoryForCurrentUser
                    )
                },
                // Production builds the scanner here and hands it to the provider, so the provider's own
                // default argument is never used — wiring the router ledger only there left it reading
                // nothing in the real app, and Space Bunny's 2.2B tokens uncounted while the unit tests
                // (which construct the scanner directly) all passed.
                routerLedgerPaths: {
                    OpenCodeUsageScanner.configuredRouterLedgerPaths(
                        environment: openUsageEnvironment,
                        homeDirectory: FileManager.default.homeDirectoryForCurrentUser
                    )
                },
                museRoots: { [OpenCodeUsageScanner.museSessionsRoot()] }
            ),
            enabledGatewaySources: {
                Self.enabledGatewaySources(
                    claudeProviderIDs: claudeProviderIDs,
                    codexProviderIDs: codexProviderIDs,
                    isProviderEnabled: isProviderEnabled
                )
            },
            enabledCodexHomes: {
                if !codexCards.isEmpty {
                    // Account cards own separate homes. Do not let OpenCode's gateway fold walk a
                    // disabled Codex account's session corpus just because another Codex card is on.
                    let enabledHomes = codexHomesByProviderID
                        .filter { isProviderEnabled($0.key) }
                        .flatMap(\.value)
                        .map { URL(fileURLWithPath: $0) }
                    return OpenCodeUsageScanner.uniqueCodexHomes(enabledHomes)
                }
                return OpenCodeUsageScanner.uniqueCodexHomes(
                    CodexLogUsageScanner.discoverCodexHomes(environment: openUsageEnvironment)
                        + registeredCodexURLs
                )
            },
            enabledCodexHomeIdentityKeys: {
                let enabledIdentities: Set<String>
                if codexCards.isEmpty {
                    enabledIdentities = isProviderEnabled("codex")
                        ? Set(codexDefaultIdentityKey.map { [$0.lowercased()] } ?? [])
                        : []
                } else {
                    enabledIdentities = Set(
                        zip(codexProviderIDs, codexCards)
                            .filter { isProviderEnabled($0.0) }
                            .map { $0.1.identityKey.lowercased() }
                    )
                }
                return codexHomeIdentityKeys.filter { enabledIdentities.contains($0.value) }
            },
            enabledClaudeScanners: {
                claudeProviders
                    .filter { isProviderEnabled($0.provider.id) }
                    .map(\.logUsageScanner)
            },
            enabledCodexIdentityKeys: {
                // With per-account cards, omit rows positively attributed to disabled identities.
                // Unresolved/legacy rows remain available as additive evidence.
                guard !codexCards.isEmpty else { return nil }
                return enabledCodexIdentityKeys()
            },
            codexAccountIdentityKeys: allCodexRouterAccountIdentityKeys,
            routerAccountIdentityKeys: enabledRouterAccountIdentityKeys,
            onGoKeysChanged: onOpenCodeGoKeysChanged,
            // The app and CLI decide whether credential inventory is authorized before catalog
            // construction. An empty preload means "not discovered this pass" and prevents this
            // synchronous descriptor fallback from reading OpenCode credentials while disabled.
            preloadedAccountIdentities: openCodeGoAccountInventory?.identities
                ?? openCodeGoAccountIdentities
                ?? [],
            preloadedAccountInventory: openCodeGoAccountInventory,
            accountInventoryDiscoveryDeferred: openCodeAccountInventoryDeferred
        )
        providers += [
            CursorProvider(),
            AntigravityProvider(),
            CopilotProvider(defaults: defaults),
            DevinProvider(),
            FreebuffProvider(authStore: FreebuffAuthStore(environment: openUsageEnvironment)),
            GrokProvider(),
            HermesProvider(),
            openCode,
            OpenRouterProvider(),
            ZAIProvider()
        ]
        return providers
    }

    static func enabledGatewaySources(
        claudeProviderIDs: [String],
        codexProviderIDs: [String],
        isProviderEnabled: @MainActor (String) -> Bool
    ) -> Set<OpenCodeUsageScanner.GatewaySource> {
        Set(OpenCodeUsageScanner.GatewaySource.allCases.filter { source in
            let providerIDs: [String]
            switch source {
            case .claude: providerIDs = claudeProviderIDs
            case .codex: providerIDs = codexProviderIDs
            case .hermes: providerIDs = ["hermes"]
            case .muse: providerIDs = ["opencode"]
            }
            return providerIDs.contains(where: isProviderEnabled)
        })
    }
}
