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
        codexLogHomes: [String] = [],
        openCodeClaudeRoots: @escaping @Sendable () -> [URL] = {
            OpenCodeUsageScanner.discoverClaudeRoots()
        }
    ) -> [ProviderRuntime] {
        let openUsageEnvironment = QuotaBarEnvironmentReader()
        var providers: [ProviderRuntime]
        if claudeCards.isEmpty {
            providers = [ClaudeProvider()]
        } else {
            // All Claude account cards decrypt the same read-only Desktop Safe Storage secret. Share
            // the cache so one explicit approval serves the whole refresh instead of prompting per card.
            let desktopKeyCache = SafeStorageKeyCache()
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

        let codexProviders: [ProviderRuntime]
        if codexCards.isEmpty {
            codexProviders = [CodexProvider(
                authStore: CodexAuthStore(environment: openUsageEnvironment),
                logUsageScanner: CodexLogUsageScanner(environment: openUsageEnvironment)
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
                // Other cards' log homes — used so managed/Orca homes skip hardlinks that also
                // exist under default ~/.codex (system root → orca backfill); default keeps them.
                let peerHomes: [URL] = codexCards
                    .filter { $0.id != card.id }
                    .flatMap { other -> [URL] in
                        let homes = other.logHomes.isEmpty ? [other.home] : other.logHomes
                        return homes.map { URL(fileURLWithPath: $0) }
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
                    logUsageScanner: CodexLogUsageScanner(
                        environment: logEnvironment,
                        peerHomes: peerHomes
                    ),
                    expectedIdentityKey: card.identityKey,
                    allowsKeychainFallback: card.allowsKeychainFallback,
                    allowsUnattributedPiUsage: card.allowsUnattributedPiUsage
                )
            }
        }

        providers += codexProviders
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
                hermesStateDBPath: { (try? HermesUsageScanner.defaultDatabasePaths())?.first },
                // Production builds the scanner here and hands it to the provider, so the provider's own
                // default argument is never used — wiring the router ledger only there left it reading
                // nothing in the real app, and Space Bunny's 2.2B tokens uncounted while the unit tests
                // (which construct the scanner directly) all passed.
                routerLedgerPaths: {
                    CodexRouterUsageScanner.defaultLedgerPaths(
                        environment: openUsageEnvironment,
                        homeDirectory: FileManager.default.homeDirectoryForCurrentUser
                    )
                },
                museRoots: { [OpenCodeUsageScanner.museSessionsRoot()] }
            )
        )
        providers += [
            CursorProvider(),
            AntigravityProvider(),
            CopilotProvider(defaults: defaults),
            DevinProvider(),
            GrokProvider(),
            HermesProvider(),
            openCode,
            OpenRouterProvider(),
            ZAIProvider()
        ]
        return providers
    }
}
