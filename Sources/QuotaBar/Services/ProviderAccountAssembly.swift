import Foundation

struct ClaudeAccountCard: Equatable, Sendable {
    let id: String
    let identityKey: String
    let organizationID: String
    let displayName: String
    let usesDesktopCredentials: Bool
    let allowsUnattributedPiUsage: Bool
}

struct CodexAccountCard: Equatable, Sendable {
    let id: String
    let identityKey: String
    /// Preferred auth home for this identity (default source first, else configured).
    let home: String
    /// All unique Codex homes that belong to this identity and should be scanned for session logs.
    let logHomes: [String]
    let displayName: String
    let allowsKeychainFallback: Bool
    let allowsUnattributedPiUsage: Bool
}

/// The launch-time account pass: read which account is signed in at each family's known homes,
/// reconcile the account registry, and expose the per-card identity map that guards snapshot caches.
@MainActor
struct ProviderAccountAssembly {
    let identityKeysByCard: [String: String]
    var claudeCards: [ClaudeAccountCard] = []
    var codexCards: [CodexAccountCard] = []

    static func make(
        defaults: UserDefaults = .standard,
        waitsForLoginShell: Bool,
        registeredCodexHomes: [String]? = nil
    ) -> ProviderAccountAssembly {
        let registeredHomes = registeredCodexHomes
            ?? CodexAccountRegistrationStore(defaults: defaults).registeredHomes
        let observer = DefaultAccountObserver(environment: QuotaBarEnvironmentReader())
        let shellFactsReadable = !waitsForLoginShell
            || LoginShellEnvironment.shared.capturedSuccessfully
            || ShellEnvironmentSnapshotStore.launchSnapshot != nil
        let routerHomes = discoveredCodexRouterChatGPTHomes(
            environment: QuotaBarEnvironmentReader(),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        let families = familiesForAccountPass(
            shellFactsReadable: shellFactsReadable,
            processEnvironment: ProcessInfo.processInfo.environment,
            registeredCodexHomes: registeredHomes,
            hasRouterChatGPTHomes: !routerHomes.isEmpty
        )
        if families.count < ProviderAccountID.families.count {
            AppLog.info(.config, "account identity read skipped for \(ProviderAccountID.families.subtracting(families).sorted().joined(separator: ", ")): login shell cold and no shell-environment snapshot exists yet")
        }
        return make(
            observer: observer,
            accountsStore: ProviderAccountsStore(defaults: defaults),
            families: families,
            registeredCodexHomes: registeredHomes
        )
    }

    private static let homeOverrideKeys: [String: String] = [
        "claude": "CLAUDE_CONFIG_DIR",
        "codex": "CODEX_HOME",
    ]

    /// Select the account families that can be read before the login-shell environment is ready.
    /// App-registered Codex homes and an explicit process-level `OPENUSAGE_CODEX_HOMES` override do
    /// not depend on shell capture, so keeping Codex in this pass prevents a cold/failed capture from
    /// hiding an account the user deliberately registered.
    static func familiesForAccountPass(
        shellFactsReadable: Bool,
        processEnvironment: [String: String],
        registeredCodexHomes: [String],
        hasRouterChatGPTHomes: Bool = false
    ) -> Set<String> {
        guard !shellFactsReadable else { return ProviderAccountID.families }
        return ProviderAccountID.families.filter { family in
            if family == "codex",
               !registeredCodexHomes.isEmpty
                || processEnvironment["OPENUSAGE_CODEX_HOMES"]?.nilIfEmpty != nil
                || hasRouterChatGPTHomes
            {
                return true
            }
            guard let key = Self.homeOverrideKeys[family] else { return false }
            return processEnvironment[key]?.nilIfEmpty != nil
        }
    }

    static func make(
        observer: DefaultAccountObserver,
        accountsStore: ProviderAccountsStore,
        families: Set<String> = ProviderAccountID.families,
        registeredCodexHomes: [String] = [],
        desktop: ClaudeDesktopAuthStore? = nil,
        listDesktopOrganizationDirectories: @escaping @Sendable (URL) -> [String] = { root in
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return urls.compactMap { url in
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true
                else { return nil }
                return url.lastPathComponent
            }
        }
    ) -> ProviderAccountAssembly {
        var identityKeys: [String: String] = [:]
        var observations: [ProviderAccountsStore.Observation] = []

        let outcomes: [(family: String, outcome: DefaultAccountObserver.Outcome)] = [
            ("claude", { observer.observeClaude() }),
            ("codex", { observer.observeCodex() }),
        ].compactMap { family, observe in
            families.contains(family) ? (family, observe()) : nil
        }
        for (family, outcome) in outcomes {
            switch outcome {
            case .resolved(let identityKey, let label, let anchor):
                identityKeys[family] = identityKey
                observations.append(ProviderAccountsStore.Observation(
                    family: family,
                    identityKey: identityKey,
                    label: label,
                    sources: [ProviderAccountSource(kind: .defaultHome, anchor: anchor, holdsDefaultSource: true)]
                ))
                AppLog.info(.config, "accounts: \(family) default identity resolved (\(ProviderAccountID.make(family: family, identityKey: identityKey)))")
            case .unresolved(let reason):
                AppLog.info(.config, "accounts: \(family) default identity unresolved — \(reason)")
            case .absent:
                AppLog.debug(.config, "accounts: \(family) has no default login")
            }
        }

        let configuredCodexHomes = families.contains("codex")
            ? configuredCodexHomes(
                environment: observer.environment,
                registeredHomes: registeredCodexHomes,
                homeDirectory: observer.homeDirectory(),
                discoveredRouterHomes: discoveredCodexRouterChatGPTHomes(
                    environment: observer.environment,
                    homeDirectory: observer.homeDirectory()
                )
            )
            : []
        // Resolve ordinary QuotaBar homes first. If an old registration or an inherited explicit
        // list also names an Orca home carrying the same OAuth identity, the Orca source must not be
        // appended to the ordinary card's logHomes. This ordering makes the rule independent of
        // registration/list order and prevents the two roots from becoming one accounting source.
        let orderedConfiguredCodexHomes = configuredCodexHomes.filter {
            !isOrcaManagedCodexHome($0, environment: observer.environment)
        } + configuredCodexHomes.filter {
            isOrcaManagedCodexHome($0, environment: observer.environment)
        }
        for home in orderedConfiguredCodexHomes {
            let isOrcaManagedHome = isOrcaManagedCodexHome(home, environment: observer.environment)
            switch observer.observeCodex(home: home) {
            case .resolved(let identityKey, let label, let anchor):
                if isOrcaManagedHome,
                   observations.contains(where: {
                       $0.family == "codex" && $0.identityKey == identityKey
                   })
                {
                    AppLog.info(.config, "accounts: ignored Orca Codex home for an identity already bound to an earlier source")
                    continue
                }
                let source = ProviderAccountSource(
                    kind: .configuredHome,
                    anchor: anchor,
                    holdsDefaultSource: false
                )
                if let index = observations.firstIndex(where: {
                    $0.family == "codex" && $0.identityKey == identityKey
                }) {
                    if !observations[index].sources.contains(source) {
                        observations[index].sources.append(source)
                    }
                    if observations[index].label == nil { observations[index].label = label }
                } else {
                    observations.append(ProviderAccountsStore.Observation(
                        family: "codex", identityKey: identityKey, label: label, sources: [source]
                    ))
                }
                AppLog.info(.config, "accounts: codex configured home resolved (\(ProviderAccountID.make(family: "codex", identityKey: identityKey)))")
            case .unresolved(let reason):
                AppLog.warn(.config, "accounts: configured Codex home \(home) is unattributed — \(reason)")
            case .absent:
                AppLog.debug(.config, "accounts: configured Codex home \(home) has no login")
            }
        }

        var desktopOrganizations: [DesktopOrganization] = []
        if families.contains("claude"), identityKeys["claude"]?.contains("|") != false {
            let desktop = desktop ?? ClaudeDesktopAuthStore(
                files: observer.files, homeDirectory: observer.homeDirectory
            )
            desktopOrganizations = discoverDesktopOrganizations(
                desktop: desktop,
                cliIdentity: identityKeys["claude"],
                listDirectories: listDesktopOrganizationDirectories
            )
            let desktopAnchor = desktop.homeDirectory()
                .appendingPathComponent("Library/Application Support/Claude").path
            for organization in desktopOrganizations {
                let source = ProviderAccountSource(
                    kind: .defaultHome, anchor: desktopAnchor, holdsDefaultSource: false
                )
                if let index = observations.firstIndex(where: {
                    $0.family == "claude" && $0.identityKey == organization.identityKey
                }) {
                    observations[index].sources.append(source)
                } else {
                    observations.append(ProviderAccountsStore.Observation(
                        family: "claude", identityKey: organization.identityKey,
                        label: organization.label, sources: [source]
                    ))
                }
            }
        }

        let defaultClaudeIdentity = identityKeys["claude"]
        let records = accountsStore.reconcile(with: observations)

        let allowsUnattributedClaudeUsage = records.count {
            $0.family == "claude" && !$0.removedTombstone
        } == 1
        var claudeCards: [ClaudeAccountCard] = []
        if let defaultIdentity = defaultClaudeIdentity,
           let organization = defaultIdentity.split(separator: "|").last,
           defaultIdentity.contains("|"),
           let record = records.first(where: {
               $0.family == "claude" && $0.identityKey == defaultIdentity && !$0.removedTombstone
           })
        {
            let label = outcomes.first(where: { $0.family == "claude" }).flatMap { outcome -> String? in
                guard case .resolved(_, let value, _) = outcome.outcome else { return nil }
                return organizationLabel(value)
            } ?? "Organization"
            claudeCards.append(ClaudeAccountCard(
                id: record.id, identityKey: defaultIdentity, organizationID: String(organization),
                displayName: "Claude — \(label)", usesDesktopCredentials: false,
                allowsUnattributedPiUsage: allowsUnattributedClaudeUsage
            ))
            identityKeys.removeValue(forKey: "claude")
            identityKeys[record.id] = defaultIdentity
        }
        for organization in desktopOrganizations where organization.identityKey != defaultClaudeIdentity {
            guard let record = records.first(where: {
                $0.family == "claude" && $0.identityKey == organization.identityKey && !$0.removedTombstone
            }) else { continue }
            let cardID = record.id
            guard !claudeCards.contains(where: { $0.id == cardID }) else { continue }
            claudeCards.append(ClaudeAccountCard(
                id: cardID, identityKey: organization.identityKey, organizationID: organization.id,
                displayName: "Claude — \(organizationLabel(record.label) ?? organization.label)",
                usesDesktopCredentials: true, allowsUnattributedPiUsage: allowsUnattributedClaudeUsage
            ))
            identityKeys[cardID] = organization.identityKey
        }

        var codexCards: [CodexAccountCard] = []
        if !configuredCodexHomes.isEmpty {
            let observedCodex = observations.filter { $0.family == "codex" }
            let allowsUnattributedPiUsage = records.count {
                $0.family == "codex" && !$0.removedTombstone
            } == 1
            let routerAccountHomeCount = observedCodex.reduce(into: Set<String>()) { seen, observation in
                for entry in observation.sources {
                    guard let anchor = entry.anchor?.nilIfEmpty,
                          anchor.contains("codex-router/chatgpt-accounts")
                    else { continue }
                    if let normalized = CodexAccountRegistrationStore.normalizedHome(
                        anchor, homeDirectory: observer.homeDirectory()
                    ) {
                        seen.insert(normalized)
                    }
                }
            }.count
            let defaultCodexHome = CodexAccountRegistrationStore.normalizedHome(
                observer.homeDirectory().appendingPathComponent(".codex").path,
                homeDirectory: observer.homeDirectory()
            )
            for observation in observedCodex {
                guard let record = records.first(where: {
                    $0.family == "codex" && $0.identityKey == observation.identityKey && !$0.removedTombstone
                }) else { continue }
                guard !codexCards.contains(where: { $0.id == record.id }) else { continue }
                // Prefer the per-account CodexRouter home for auth when the pool owns credentials.
                let preferredSource = observation.sources.first(where: {
                    ($0.anchor ?? "").contains("codex-router/chatgpt-accounts")
                })
                    ?? observation.sources.first(where: \.holdsDefaultSource)
                    ?? observation.sources.first(where: { $0.kind == .configuredHome })
                guard let source = preferredSource, let home = source.anchor?.nilIfEmpty else { continue }
                var seenLogHomes = Set<String>()
                let logHomes = observation.sources.compactMap { entry -> String? in
                    guard let anchor = entry.anchor?.nilIfEmpty else { return nil }
                    return CodexAccountRegistrationStore.normalizedHome(
                        anchor, homeDirectory: observer.homeDirectory()
                    )
                }.filter { candidate in
                    // With 2+ router account homes, shared ~/.codex mixes both accounts' rollouts
                    // and double-counts Total Spend / daily charts across cards.
                    if routerAccountHomeCount >= 2,
                       let defaultCodexHome,
                       candidate == defaultCodexHome {
                        return false
                    }
                    return seenLogHomes.insert(candidate).inserted
                }
                let label = observation.label?.nilIfEmpty ?? record.label?.nilIfEmpty
                codexCards.append(CodexAccountCard(
                    id: record.id,
                    identityKey: observation.identityKey,
                    home: home,
                    logHomes: logHomes.isEmpty ? [home] : logHomes,
                    displayName: label.map { "Codex — \($0)" } ?? "Codex — \(record.id == "codex" ? "Account" : String(record.id.suffix(8)))",
                    allowsKeychainFallback: source.holdsDefaultSource,
                    allowsUnattributedPiUsage: allowsUnattributedPiUsage
                ))
            }
            if !codexCards.isEmpty {
                identityKeys.removeValue(forKey: "codex")
                for card in codexCards { identityKeys[card.id] = card.identityKey }
            }
        }

        return ProviderAccountAssembly(
            identityKeysByCard: identityKeys,
            claudeCards: claudeCards,
            codexCards: codexCards
        )
    }

    /// Additional Codex homes are deliberately explicit. Registered homes are persisted by the app;
    /// `OPENUSAGE_CODEX_HOMES` remains supported for scripts, harnesses, and existing setups. Orca
    /// homes are not implicitly attached: Orca maintains a runtime bridge and a backfilled copy of
    /// `~/.codex`, so auto-discovery would silently merge another application's rollouts into the
    /// default card. Callers that intentionally want an Orca home must pass it explicitly. All
    /// sources share one path normalizer so slash/tilde/symlink spellings cannot duplicate a source.
    static func configuredCodexHomes(
        environment: EnvironmentReading,
        registeredHomes: [String] = [],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        discoveredOrcaHomes: [String] = [],
        discoveredRouterHomes: [String] = []
    ) -> [String] {
        var seen: Set<String> = []
        var rawHomes = registeredHomes
        if let raw = environment.value(for: "OPENUSAGE_CODEX_HOMES")?.nilIfEmpty {
            rawHomes.append(contentsOf: raw.split(whereSeparator: { $0 == "," || $0 == "\n" }).map(String.init))
        }
        // CodexRouter subscription profiles are first-class Codex homes (auth + optional
        // sessions). Auto-discover them so both pool accounts keep separate QuotaBar cards
        // when the router owns credentials under chatgpt-accounts/*/.
        rawHomes.append(contentsOf: discoveredRouterHomes)
        rawHomes.append(contentsOf: discoveredOrcaHomes)
        return rawHomes.compactMap {
            CodexAccountRegistrationStore.normalizedHome($0, homeDirectory: homeDirectory)
        }
        .filter { seen.insert($0).inserted }
    }

    private static func isOrcaManagedCodexHome(
        _ home: String,
        environment: EnvironmentReading
    ) -> Bool {
        OrcaCodexHomeBoundary.isManaged(
            home,
            orcaUserDataPath: environment.value(for: "ORCA_USER_DATA_PATH")?.nilIfEmpty
        )
    }

    /// Find authenticated Orca-managed Codex homes for an explicit opt-in flow: account-scoped
    /// `~/Library/Application Support/orca/codex-accounts/*/home` directories plus Orca's runtime
    /// bridge `~/Library/Application Support/orca/codex-runtime-home/home`. The normal QuotaBar
    /// account pass deliberately does not call this helper because Orca backfills copies of the
    /// default history and matching OAuth ids are not a safe source boundary.
    static func discoveredOrcaCodexHomes(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        listDirectory: @escaping (URL) -> [URL] = { root in
            (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        }
    ) -> [String] {
        let orcaRoot = homeDirectory
            .appendingPathComponent("Library/Application Support/orca", isDirectory: true)
        let accountsRoot = orcaRoot
            .appendingPathComponent("codex-accounts", isDirectory: true)
        let runtimeHome = orcaRoot
            .appendingPathComponent("codex-runtime-home/home", isDirectory: true)

        var homes: [String] = []
        var seen: Set<String> = []
        var candidates: [URL] = []
        if fileExists(accountsRoot.path) {
            candidates.append(contentsOf: listDirectory(accountsRoot).map {
                $0.appendingPathComponent("home", isDirectory: true)
            })
        }
        candidates.append(runtimeHome)

        for home in candidates {
            let auth = home.appendingPathComponent("auth.json")
            guard fileExists(auth.path),
                  let normalized = CodexAccountRegistrationStore.normalizedHome(
                      home.path, homeDirectory: homeDirectory
                  ),
                  seen.insert(normalized).inserted
            else { continue }
            homes.append(normalized)
        }
        return homes
    }

    /// Find CodexRouter-managed ChatGPT subscription homes:
    /// `~/.codex/codex-router/chatgpt-accounts/*/auth.json` (and env overrides for the router state
    /// dir). Unlike Orca, these homes are the router's authoritative per-account auth boundary and
    /// must be auto-discovered so QuotaBar keeps a card + meters for every pool account.
    static func discoveredCodexRouterChatGPTHomes(
        environment: EnvironmentReading = QuotaBarEnvironmentReader(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        listDirectory: @escaping (URL) -> [URL] = { root in
            (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        }
    ) -> [String] {
        var roots: [URL] = []
        if let override = environment.value(for: "MODEL_ROUTER_CHATGPT_ACCOUNT_HOMES")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            roots.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        for key in ["CODEX_ROUTER_STATE_DIR", "MODEL_ROUTER_STATE_DIR"] {
            if let state = environment.value(for: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                roots.append(
                    URL(fileURLWithPath: state, isDirectory: true)
                        .appendingPathComponent("chatgpt-accounts", isDirectory: true)
                )
            }
        }
        roots.append(
            homeDirectory
                .appendingPathComponent(".codex/codex-router/chatgpt-accounts", isDirectory: true)
        )

        var homes: [String] = []
        var seen: Set<String> = []
        for accountsRoot in roots {
            guard fileExists(accountsRoot.path) else { continue }
            for accountDir in listDirectory(accountsRoot) {
                // Pool opaque ids look like acct_<base64url>; skip AppleDouble noise.
                let name = accountDir.lastPathComponent
                if name.hasPrefix("._") { continue }
                let auth = accountDir.appendingPathComponent("auth.json")
                guard fileExists(auth.path),
                      let normalized = CodexAccountRegistrationStore.normalizedHome(
                          accountDir.path, homeDirectory: homeDirectory
                      ),
                      seen.insert(normalized).inserted
                else { continue }
                homes.append(normalized)
            }
        }
        return homes
    }


    private struct DesktopOrganization {
        var id: String
        var identityKey: String
        var label: String
    }

    private static func organizationLabel(_ value: String?) -> String? {
        guard let value, let opening = value.lastIndex(of: "("), value.last == ")" else { return value }
        return String(value[value.index(after: opening)..<value.index(before: value.endIndex)])
    }

    private static func discoverDesktopOrganizations(
        desktop: ClaudeDesktopAuthStore,
        cliIdentity: String?,
        listDirectories: @Sendable (URL) -> [String]
    ) -> [DesktopOrganization] {
        guard let user = desktop.lastKnownAccountUUID(), desktop.hasCredentialMaterial() else { return [] }
        let active = desktop.load(allowInteraction: false, expectedAccountUUID: user)
        let activeOrganization = active.organization

        let root = desktop.homeDirectory().appendingPathComponent("Library/Application Support/Claude")
        let memberships = Set(["claude-code-sessions", "local-agent-mode-sessions"].flatMap { directory in
            listDirectories(root.appendingPathComponent(directory).appendingPathComponent(user))
                .compactMap { UUID(uuidString: $0)?.uuidString.lowercased() }
        })
        var organizations = memberships
        if let activeOrganization { organizations.insert(activeOrganization) }
        if let text = try? desktop.files.readTextIfPresent(root.appendingPathComponent("config.json").path),
           let rootObject = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        {
            organizations.formUnion(rootObject.keys.compactMap {
                $0.split(separator: ":").last.flatMap { UUID(uuidString: String($0))?.uuidString.lowercased() }
            })
        }
        if let text = try? desktop.files.readTextIfPresent(
            root.appendingPathComponent("plan-usage-history.json").path
        ), let history = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
           let samples = history["samples"] as? [[String: Any]]
        {
            organizations.formUnion(samples.compactMap {
                ($0["org"] as? String).flatMap { UUID(uuidString: $0)?.uuidString.lowercased() }
            })
        }
        let cliOrganization = cliIdentity.flatMap { identity -> String? in
            let parts = identity.split(separator: "|")
            guard parts.count == 2,
                  String(parts[0]).caseInsensitiveCompare(user) == .orderedSame
            else { return nil }
            return String(parts[1]).lowercased()
        }

        return organizations.sorted { lhs, rhs in
            lhs == activeOrganization ? true : rhs == activeOrganization ? false : lhs < rhs
        }.compactMap { organization in
            guard memberships.contains(organization)
                || organization == activeOrganization || organization == cliOrganization
            else { return nil }
            let result = organization == activeOrganization ? active : desktop.load(
                allowInteraction: false, organization: organization, expectedAccountUUID: user
            )
            guard result.status == .available || result.status == .permissionRequired else { return nil }
            let plan = result.oauth?.subscriptionType?.lowercased()
            let label = plan.map { ["max", "pro", "free"].contains($0) } == true ? "Personal"
                : plan?.capitalized ?? "Organization \(organization.prefix(8))"
            return DesktopOrganization(id: organization, identityKey: "\(user)|\(organization)", label: label)
        }
    }
}
