import XCTest
@testable import QuotaBar

@MainActor
final class CodexMultiAccountTests: XCTestCase {
    private func makeScratchDefaults() -> UserDefaults {
        let suiteName = "OpenUsageTests.CodexMultiAccount.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func codexAuth(accountID: String, accessToken: String) -> String {
        #"{"tokens":{"access_token":"\#(accessToken)","account_id":"\#(accountID)"}}"#
    }

    func testTwoConfiguredHomesBecomeTwoStableCodexCards() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let files = FakeFiles([
            "/Users/dev/codex-a/auth.json": codexAuth(accountID: "ACCOUNT-A", accessToken: "token-a"),
            "/Users/dev/codex-b/auth.json": codexAuth(accountID: "ACCOUNT-B", accessToken: "token-b"),
        ])
        let firstObserver = DefaultAccountObserver(
            environment: FakeEnvironment([
                "OPENUSAGE_CODEX_HOMES": "/Users/dev/codex-a, /Users/dev/codex-b"
            ]),
            files: files,
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let first = ProviderAccountAssembly.make(
            observer: firstObserver,
            accountsStore: store,
            families: ["codex"]
        )

        XCTAssertEqual(first.codexCards.count, 2)
        XCTAssertEqual(Set(first.codexCards.map(\.identityKey)), ["account-a", "account-b"])
        XCTAssertEqual(Set(first.codexCards.map(\.home)), ["/Users/dev/codex-a", "/Users/dev/codex-b"])
        XCTAssertEqual(Set(first.codexCards.map(\.id)), [
            "codex",
            ProviderAccountID.make(family: "codex", identityKey: "account-b"),
        ])
        XCTAssertTrue(first.codexCards.allSatisfy { !$0.allowsKeychainFallback })
        XCTAssertTrue(first.codexCards.allSatisfy { !$0.allowsUnattributedPiUsage })
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: first.codexCards.map { ($0.id, $0.identityKey) }),
            first.identityKeysByCard
        )
        XCTAssertEqual(store.records.filter { $0.family == "codex" }.count, 2)

        let firstIDsByIdentity = Dictionary(uniqueKeysWithValues: first.codexCards.map {
            ($0.identityKey, $0.id)
        })

        // Home ordering is presentation/discovery order only. The registry owns stable ids, so
        // changing the export order on a later launch cannot swap cached usage between accounts.
        let secondObserver = DefaultAccountObserver(
            environment: FakeEnvironment([
                "OPENUSAGE_CODEX_HOMES": "/Users/dev/codex-b\n/Users/dev/codex-a"
            ]),
            files: files,
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let second = ProviderAccountAssembly.make(
            observer: secondObserver,
            accountsStore: store,
            families: ["codex"]
        )
        let secondIDsByIdentity = Dictionary(uniqueKeysWithValues: second.codexCards.map {
            ($0.identityKey, $0.id)
        })

        XCTAssertEqual(secondIDsByIdentity, firstIDsByIdentity)
    }

    func testDefaultHomeAndConfiguredSecondAccountBecomeTwoCards() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let files = FakeFiles([
            "/Users/dev/.codex/auth.json": codexAuth(accountID: "ACCOUNT-A", accessToken: "token-a"),
            "/Users/dev/codex-b/auth.json": codexAuth(accountID: "ACCOUNT-B", accessToken: "token-b"),
        ])
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([
                "OPENUSAGE_CODEX_HOMES": "/Users/dev/codex-b"
            ]),
            files: files,
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: store,
            families: ["codex"]
        )

        XCTAssertEqual(assembly.codexCards.count, 2)
        XCTAssertEqual(Set(assembly.codexCards.map(\.identityKey)), ["account-a", "account-b"])
        XCTAssertEqual(Set(assembly.codexCards.map(\.home)), ["/Users/dev/.codex", "/Users/dev/codex-b"])
        XCTAssertEqual(store.records.filter { $0.family == "codex" && !$0.removedTombstone }.count, 2)

        let defaultCard = try XCTUnwrap(assembly.codexCards.first { $0.identityKey == "account-a" })
        let secondCard = try XCTUnwrap(assembly.codexCards.first { $0.identityKey == "account-b" })
        XCTAssertEqual(defaultCard.id, "codex")
        XCTAssertTrue(defaultCard.allowsKeychainFallback)
        XCTAssertFalse(secondCard.allowsKeychainFallback)
        XCTAssertFalse(defaultCard.allowsUnattributedPiUsage)
        XCTAssertFalse(secondCard.allowsUnattributedPiUsage)
    }

    func testTwoHomesForSameAccountCollapseToOneRegistryCard() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let files = FakeFiles([
            "/Users/dev/codex-a/auth.json": codexAuth(accountID: "ACCOUNT-A", accessToken: "token-a"),
            "/Users/dev/codex-a-copy/auth.json": codexAuth(accountID: "ACCOUNT-A", accessToken: "token-copy"),
        ])
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([
                "OPENUSAGE_CODEX_HOMES": "/Users/dev/codex-a,/Users/dev/codex-a-copy"
            ]),
            files: files,
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: store,
            families: ["codex"]
        )

        XCTAssertEqual(assembly.codexCards.count, 1)
        let card = try XCTUnwrap(assembly.codexCards.first)
        XCTAssertEqual(card.identityKey, "account-a")
        XCTAssertEqual(card.home, "/Users/dev/codex-a")
        XCTAssertEqual(Set(card.logHomes), Set(["/Users/dev/codex-a", "/Users/dev/codex-a-copy"]))
        XCTAssertEqual(store.records.filter { $0.family == "codex" && !$0.removedTombstone }.count, 1)
        XCTAssertEqual(store.records.first { $0.family == "codex" }?.sources.count, 2)
    }

    func testConfiguredHomesAreTrimmedAndDeduplicated() {
        let homes = ProviderAccountAssembly.configuredCodexHomes(
            environment: FakeEnvironment([
                "OPENUSAGE_CODEX_HOMES": " /a/codex/ , /b/codex\n/a/codex ,, "
            ]),
            discoveredOrcaHomes: []
        )

        XCTAssertEqual(homes, ["/a/codex", "/b/codex"])
    }

    func testRegisteredHomesAreMergedWithEnvironmentHomesWithoutDuplicateSpellings() {
        let homes = ProviderAccountAssembly.configuredCodexHomes(
            environment: FakeEnvironment([
                "OPENUSAGE_CODEX_HOMES": " /Users/dev/codex-b/ , /Users/dev/codex-c "
            ]),
            registeredHomes: ["/Users/dev/codex-a", "/Users/dev/codex-b"],
            discoveredOrcaHomes: []
        )

        XCTAssertEqual(homes, [
            "/Users/dev/codex-a", "/Users/dev/codex-b", "/Users/dev/codex-c"
        ])
    }

    func testRegisteredHomeStorePersistsNormalizedUniqueHomes() {
        let defaults = makeScratchDefaults()
        let store = CodexAccountRegistrationStore(
            defaults: defaults,
            homeDirectory: URL(fileURLWithPath: "/Users/dev")
        )

        XCTAssertTrue(store.register(home: " ~/codex-a/ "))
        XCTAssertFalse(store.register(home: "/Users/dev/codex-a"))
        XCTAssertEqual(store.registeredHomes, ["/Users/dev/codex-a"])

        let reloaded = CodexAccountRegistrationStore(
            defaults: defaults,
            homeDirectory: URL(fileURLWithPath: "/Users/dev")
        )
        XCTAssertEqual(reloaded.registeredHomes, ["/Users/dev/codex-a"])
    }

    func testRegisteredHomeFeedsAccountAssembly() {
        let defaults = makeScratchDefaults()
        let accounts = ProviderAccountsStore(defaults: defaults)
        let files = FakeFiles([
            "/Users/dev/codex-b/auth.json": codexAuth(accountID: "ACCOUNT-B", accessToken: "token-b")
        ])
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: files,
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: accounts,
            families: ["codex"],
            registeredCodexHomes: [" /Users/dev/codex-b/ "]
        )

        XCTAssertEqual(assembly.codexCards.count, 1)
        XCTAssertEqual(assembly.codexCards.first?.home, "/Users/dev/codex-b")
        XCTAssertEqual(assembly.codexCards.first?.identityKey, "account-b")
    }

    func testLoginLaunchSpecUsesOfficialCodexOAuthAndOnlyScopesHome() {
        let spec = CodexAccountRegistrationService.loginLaunchSpec(
            homePath: "/Users/dev/O'Brien",
            path: "/Users/dev/.local/bin:/opt/homebrew/bin"
        )

        XCTAssertEqual(spec.executable, "/usr/bin/env")
        XCTAssertEqual(spec.arguments, ["codex", "login"])
        XCTAssertEqual(spec.environment["CODEX_HOME"], "/Users/dev/O'Brien")
        XCTAssertEqual(spec.environment["PATH"], "/Users/dev/.local/bin:/opt/homebrew/bin")
        XCTAssertFalse(spec.arguments.contains { $0.contains("Terminal") })
        XCTAssertFalse(spec.environment.keys.contains { $0.localizedCaseInsensitiveContains("token") })
        XCTAssertFalse(spec.environment.values.contains { $0.localizedCaseInsensitiveContains("access_token") })
    }

    func testManagedLoginHomeNameIsUniqueAndNotAPlaceholder() {
        let first = CodexAccountRegistrationService.managedHomeName(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        )
        let second = CodexAccountRegistrationService.managedHomeName(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        )

        XCTAssertEqual(first, "Account-AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.contains("(Self."))
    }

    func testRegistrationStateOnlyMarksSigningInWhileCodexOwnsTheFlow() {
        let defaults = makeScratchDefaults()
        let accounts = CodexAccountRegistrationStore(
            defaults: defaults,
            homeDirectory: URL(fileURLWithPath: "/Users/dev")
        )
        let service = CodexAccountRegistrationService(accounts: accounts)

        XCTAssertEqual(service.state, .idle)
        XCTAssertFalse(service.state.isSigningIn)
    }

    func testExistingHomeRegistrationRequiresCodexIdentityAndDeduplicates() throws {
        let defaults = makeScratchDefaults()
        let accounts = CodexAccountRegistrationStore(defaults: defaults)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests-CodexHome-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("account", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(codexAuth(accountID: "ACCOUNT-IMPORTED", accessToken: "token-imported").utf8)
            .write(to: home.appendingPathComponent("auth.json"))

        let service = CodexAccountRegistrationService(accounts: accounts)
        var reloadCount = 0
        service.onAccountRegistered = { reloadCount += 1 }
        XCTAssertNil(try service.registerExistingHome(at: home))
        XCTAssertEqual(accounts.registeredHomes, [home.resolvingSymlinksInPath().standardizedFileURL.path])
        XCTAssertEqual(reloadCount, 1)
        XCTAssertThrowsError(try service.registerExistingHome(at: home)) { error in
            XCTAssertEqual(error as? CodexAccountRegistrationService.RegistrationError, .alreadyRegistered)
        }
    }

    func testExistingHomeRegistrationRejectsAuthWithoutAccountIdentity() throws {
        let defaults = makeScratchDefaults()
        let accounts = CodexAccountRegistrationStore(defaults: defaults)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests-CodexHome-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("account", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(#"{"tokens":{"access_token":"token-without-account"}}"#.utf8)
            .write(to: home.appendingPathComponent("auth.json"))

        let service = CodexAccountRegistrationService(accounts: accounts)
        XCTAssertThrowsError(try service.registerExistingHome(at: home)) { error in
            XCTAssertEqual(error as? CodexAccountRegistrationService.RegistrationError, .existingHomeNoAccount)
        }
        XCTAssertTrue(accounts.registeredHomes.isEmpty)
    }

    func testProviderCatalogBuildsOneScopedRuntimePerCodexCard() {
        let secondID = ProviderAccountID.make(family: "codex", identityKey: "account-b")
        let cards = [
            CodexAccountCard(
                id: "codex",
                identityKey: "account-a",
                home: "/Users/dev/codex-a",
                logHomes: ["/Users/dev/codex-a"],
                displayName: "Codex — A",
                allowsKeychainFallback: false,
                allowsUnattributedPiUsage: false
            ),
            CodexAccountCard(
                id: secondID,
                identityKey: "account-b",
                home: "/Users/dev/codex-b",
                logHomes: ["/Users/dev/codex-b"],
                displayName: "Codex — B",
                allowsKeychainFallback: false,
                allowsUnattributedPiUsage: false
            ),
        ]

        let runtimes = ProviderCatalog.make(codexCards: cards)
            .compactMap { $0 as? CodexProvider }

        XCTAssertEqual(runtimes.map(\.provider.id), ["codex", secondID])
        XCTAssertEqual(runtimes.map(\.provider.displayName), ["Codex — A", "Codex — B"])
        XCTAssertEqual(runtimes.map { $0.authStore.codexHome() }, [
            "/Users/dev/codex-a", "/Users/dev/codex-b"
        ])
        XCTAssertEqual(runtimes.compactMap(\.expectedIdentityKey), ["account-a", "account-b"])
        XCTAssertEqual(runtimes.map(\.allowsKeychainFallback), [false, false])
        XCTAssertTrue(runtimes[0].widgetDescriptors.allSatisfy { $0.providerID == "codex" })
        XCTAssertTrue(runtimes[1].widgetDescriptors.allSatisfy { $0.providerID == secondID })
    }

    func testProviderCatalogScansAllLogHomesWithoutCommaInAuthHome() async throws {
        let card = CodexAccountCard(
            id: "codex",
            identityKey: "account-a",
            home: "/Users/dev/OpenUsage/Account-A",
            logHomes: [
                "/Users/dev/OpenUsage/Account-A",
                "/Users/dev/Library/Application Support/orca/codex-accounts/acct/home",
            ],
            displayName: "Codex — A",
            allowsKeychainFallback: false,
            allowsUnattributedPiUsage: false
        )

        let runtime = try XCTUnwrap(
            ProviderCatalog.make(codexCards: [card]).compactMap { $0 as? CodexProvider }.first
        )

        XCTAssertEqual(runtime.authStore.codexHome(), "/Users/dev/OpenUsage/Account-A")
        XCTAssertFalse((runtime.authStore.codexHome() ?? "").contains(","))
        let homes = await runtime.logUsageScanner.discoveredHomesForTesting().map(\.path)
        XCTAssertEqual(Set(homes), Set([
            "/Users/dev/OpenUsage/Account-A",
            "/Users/dev/Library/Application Support/orca/codex-accounts/acct/home",
        ]))
    }

    func testOpenCodeGatewayIncludesRegisteredCodexHomesWithoutAliases() throws {
        let secondID = ProviderAccountID.make(family: "codex", identityKey: "account-b")
        let cards = [
            CodexAccountCard(
                id: "codex", identityKey: "account-a", home: "/Users/dev/codex-a",
                logHomes: ["/Users/dev/codex-a"],
                displayName: "Codex — A", allowsKeychainFallback: false,
                allowsUnattributedPiUsage: false
            ),
            CodexAccountCard(
                id: secondID, identityKey: "account-b", home: "/Users/dev/OpenUsage/Account-B",
                logHomes: [
                    "/Users/dev/OpenUsage/Account-B",
                    "/Users/dev/Library/Application Support/orca/codex-accounts/b/home",
                ],
                displayName: "Codex — B", allowsKeychainFallback: false,
                allowsUnattributedPiUsage: false
            )
        ]

        let openCode = try XCTUnwrap(
            ProviderCatalog.make(
                codexCards: cards,
                codexLogHomes: ["/Users/dev/codex-a/", "/Users/dev/OpenUsage/Account-B"]
            ).compactMap { $0 as? OpenCodeProvider }.first
        )
        let homes = openCode.usageScanner.codexHomes().map { $0.standardizedFileURL.path }

        XCTAssertTrue(homes.contains("/Users/dev/codex-a"))
        XCTAssertTrue(homes.contains("/Users/dev/OpenUsage/Account-B"))
        XCTAssertTrue(homes.contains(
            "/Users/dev/Library/Application Support/orca/codex-accounts/b/home"
        ))
        XCTAssertEqual(homes.count, Set(homes).count)
    }

    func testScopedProviderRejectsCredentialFromTheOtherAccount() async {
        let files = FakeFiles([
            "/Users/dev/codex-a/auth.json": codexAuth(accountID: "ACCOUNT-A", accessToken: "token-a")
        ])
        let authStore = CodexAuthStore(
            environment: FakeEnvironment(["CODEX_HOME": "/Users/dev/codex-a"]),
            files: files,
            keychain: FakeKeychain(nil)
        )
        let matching = CodexProvider(
            authStore: authStore,
            expectedIdentityKey: "account-a",
            allowsKeychainFallback: false
        )
        let wrong = CodexProvider(
            authStore: authStore,
            expectedIdentityKey: "account-b",
            allowsKeychainFallback: false
        )

        let matchingHasCredentials = await matching.hasLocalCredentials()
        let wrongHasCredentials = await wrong.hasLocalCredentials()
        XCTAssertTrue(matchingHasCredentials)
        XCTAssertFalse(wrongHasCredentials)
    }

    func testDiscoveredOrcaHomesRequireAuthJSONUnderAccountHome() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests-Orca-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let accounts = root.appendingPathComponent(
            "Library/Application Support/orca/codex-accounts", isDirectory: true
        )
        let good = accounts.appendingPathComponent("good-acct/home", isDirectory: true)
        let missingAuth = accounts.appendingPathComponent("no-auth/home", isDirectory: true)
        let notHome = accounts.appendingPathComponent("other/not-home", isDirectory: true)
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: missingAuth, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: notHome, withIntermediateDirectories: true)
        try Data(codexAuth(accountID: "ORCA-1", accessToken: "token-orca").utf8)
            .write(to: good.appendingPathComponent("auth.json"))

        let discovered = ProviderAccountAssembly.discoveredOrcaCodexHomes(homeDirectory: root)
        XCTAssertEqual(discovered, [good.resolvingSymlinksInPath().standardizedFileURL.path])
    }

    func testDiscoveredOrcaHomesIncludeAuthenticatedRuntimeBridge() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests-OrcaRuntime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtimeHome = root.appendingPathComponent(
            "Library/Application Support/orca/codex-runtime-home/home", isDirectory: true
        )
        try FileManager.default.createDirectory(at: runtimeHome, withIntermediateDirectories: true)
        let auth = codexAuth(accountID: "ORCA-RUNTIME", accessToken: "token-runtime")
        try Data(auth.utf8).write(to: runtimeHome.appendingPathComponent("auth.json"))

        let discovered = ProviderAccountAssembly.discoveredOrcaCodexHomes(homeDirectory: root)

        XCTAssertEqual(discovered, [runtimeHome.resolvingSymlinksInPath().standardizedFileURL.path])
    }

    func testDiscoveredOrcaHomesMergeIntoConfiguredCodexHomes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests-OrcaMerge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let orcaHome = root.appendingPathComponent(
            "Library/Application Support/orca/codex-accounts/acct/home", isDirectory: true
        )
        try FileManager.default.createDirectory(at: orcaHome, withIntermediateDirectories: true)
        try Data(codexAuth(accountID: "ORCA-2", accessToken: "token-orca-2").utf8)
            .write(to: orcaHome.appendingPathComponent("auth.json"))

        let homes = ProviderAccountAssembly.configuredCodexHomes(
            environment: FakeEnvironment([
                "OPENUSAGE_CODEX_HOMES": "/Users/dev/codex-env"
            ]),
            registeredHomes: ["/Users/dev/codex-reg"],
            homeDirectory: root,
            discoveredOrcaHomes: [orcaHome.path]
        )

        let orcaPath = orcaHome.resolvingSymlinksInPath().standardizedFileURL.path
        XCTAssertEqual(homes, ["/Users/dev/codex-reg", "/Users/dev/codex-env", orcaPath])
    }

    func testOrcaHomesAreNotImplicitlyAddedToConfiguredCodexHomes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests-OrcaOptIn-(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }

        let orcaHome = root.appendingPathComponent(
            "Library/Application Support/orca/codex-accounts/acct/home", isDirectory: true
        )
        try FileManager.default.createDirectory(at: orcaHome, withIntermediateDirectories: true)
        try Data(codexAuth(accountID: "ORCA-OPT-IN", accessToken: "token-orca").utf8)
            .write(to: orcaHome.appendingPathComponent("auth.json"))

        let homes = ProviderAccountAssembly.configuredCodexHomes(
            environment: FakeEnvironment([:]),
            registeredHomes: ["/Users/dev/codex-registered"],
            homeDirectory: root
        )

        XCTAssertEqual(homes, ["/Users/dev/codex-registered"])
    }

    func testRegisteredOpenUsageHomeDoesNotCollapseWithUnregisteredOrcaHomes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests-OrcaCollapse-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }

        let openUsageHome = root.appendingPathComponent("OpenUsage/Account-A", isDirectory: true)
        let orcaHome = root.appendingPathComponent(
            "Library/Application Support/orca/codex-accounts/acct/home", isDirectory: true
        )
        let runtimeHome = root.appendingPathComponent(
            "Library/Application Support/orca/codex-runtime-home/home", isDirectory: true
        )
        try FileManager.default.createDirectory(at: openUsageHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: orcaHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtimeHome, withIntermediateDirectories: true)
        let auth = codexAuth(accountID: "ACCOUNT-SHARED", accessToken: "token-shared")
        try Data(auth.utf8).write(to: openUsageHome.appendingPathComponent("auth.json"))
        try Data(auth.utf8).write(to: orcaHome.appendingPathComponent("auth.json"))
        try Data(auth.utf8).write(to: runtimeHome.appendingPathComponent("auth.json"))

        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let openUsagePath = openUsageHome.resolvingSymlinksInPath().standardizedFileURL.path
        let orcaPath = orcaHome.resolvingSymlinksInPath().standardizedFileURL.path
        let runtimePath = runtimeHome.resolvingSymlinksInPath().standardizedFileURL.path
        let files = FakeFiles([
            "\(openUsagePath)/auth.json": auth,
            "\(orcaPath)/auth.json": auth,
            "\(runtimePath)/auth.json": auth,
        ])
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: files,
            keychain: FakeKeychain(nil),
            homeDirectory: { root }
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: store,
            families: ["codex"],
            registeredCodexHomes: [openUsagePath]
        )

        XCTAssertEqual(assembly.codexCards.count, 1)
        let card = try XCTUnwrap(assembly.codexCards.first)
        XCTAssertEqual(card.identityKey, "account-shared")
        // The registered home remains the sole source. Orca is intentionally opt-in so its
        // backfilled/runtime copies cannot inflate this card just because auth.json matches.
        XCTAssertEqual(card.home, openUsagePath)
        XCTAssertEqual(card.logHomes, [openUsagePath])
    }

    func testOrcaHomeWithSameIdentityCannotAugmentAnExistingCard() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests-OrcaIsolation-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }

        let defaultHome = root.appendingPathComponent(".codex", isDirectory: true)
        let orcaHome = root.appendingPathComponent(
            "Library/Application Support/orca/codex-accounts/account/home", isDirectory: true
        )
        let auth = codexAuth(accountID: "ACCOUNT-SHARED", accessToken: "token-shared")
        let defaultPath = defaultHome.resolvingSymlinksInPath().standardizedFileURL.path
        let orcaPath = orcaHome.resolvingSymlinksInPath().standardizedFileURL.path
        let files = FakeFiles([
            "\(defaultPath)/auth.json": auth,
            "\(orcaPath)/auth.json": auth,
        ])
        let defaults = makeScratchDefaults()
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment(["OPENUSAGE_CODEX_HOMES": orcaPath]),
            files: files,
            keychain: FakeKeychain(nil),
            homeDirectory: { root }
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: ProviderAccountsStore(defaults: defaults),
            families: ["codex"]
        )

        XCTAssertEqual(assembly.codexCards.count, 1)
        let card = try XCTUnwrap(assembly.codexCards.first)
        XCTAssertEqual(card.identityKey, "account-shared")
        XCTAssertEqual(card.home, defaultPath)
        XCTAssertEqual(card.logHomes, [defaultPath])
    }


    func testProviderCatalogWiresPeerHomesAcrossCodexCards() async throws {
        let secondID = ProviderAccountID.make(family: "codex", identityKey: "account-b")
        let cards = [
            CodexAccountCard(
                id: "codex",
                identityKey: "account-a",
                home: "/Users/dev/.codex",
                logHomes: ["/Users/dev/.codex"],
                displayName: "Codex — A",
                allowsKeychainFallback: false,
                allowsUnattributedPiUsage: false
            ),
            CodexAccountCard(
                id: secondID,
                identityKey: "account-b",
                home: "/Users/dev/orca/account-b",
                logHomes: ["/Users/dev/orca/account-b", "/Users/dev/OpenUsage/Account-B"],
                displayName: "Codex — B",
                allowsKeychainFallback: false,
                allowsUnattributedPiUsage: false
            ),
        ]

        let runtimes = ProviderCatalog.make(codexCards: cards)
            .compactMap { $0 as? CodexProvider }
        XCTAssertEqual(runtimes.count, 2)

        // Auth stays single-home; log env is still the comma-joined logHomes list.
        XCTAssertEqual(runtimes[0].authStore.codexHome(), "/Users/dev/.codex")
        XCTAssertEqual(runtimes[1].authStore.codexHome(), "/Users/dev/orca/account-b")
        let homesA = await runtimes[0].logUsageScanner.discoveredHomesForTesting().map(\.path)
        let homesB = await runtimes[1].logUsageScanner.discoveredHomesForTesting().map(\.path)
        XCTAssertEqual(homesA, ["/Users/dev/.codex"])
        XCTAssertEqual(Set(homesB), Set([
            "/Users/dev/orca/account-b",
            "/Users/dev/OpenUsage/Account-B",
        ]))

        let peersA = await runtimes[0].logUsageScanner.peerHomesForTesting().map(\.path)
        let peersB = await runtimes[1].logUsageScanner.peerHomesForTesting().map(\.path)
        XCTAssertEqual(Set(peersA), Set([
            "/Users/dev/orca/account-b",
            "/Users/dev/OpenUsage/Account-B",
        ]))
        XCTAssertEqual(peersB, ["/Users/dev/.codex"])
    }


    func testDiscoveredCodexRouterChatGPTHomesFindsAuthProfiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests-RouterHomes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let accounts = root.appendingPathComponent(
            ".codex/codex-router/chatgpt-accounts", isDirectory: true
        )
        let a = accounts.appendingPathComponent("acct_LEdkU4MiY7gAqOeN", isDirectory: true)
        let b = accounts.appendingPathComponent("acct_B_gacrRVPlhAScqI", isDirectory: true)
        let junk = accounts.appendingPathComponent("._acct_ignore", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        try Data(codexAuth(accountID: "9de63544-5afb-4036-9e7d-89ee160af849", accessToken: "tok-a").utf8)
            .write(to: a.appendingPathComponent("auth.json"))
        try Data(codexAuth(accountID: "1118f6f1-8697-4e7b-9112-1771b3e36099", accessToken: "tok-b").utf8)
            .write(to: b.appendingPathComponent("auth.json"))

        let discovered = ProviderAccountAssembly.discoveredCodexRouterChatGPTHomes(
            environment: FakeEnvironment([:]),
            homeDirectory: root
        )
        let expected = [
            a.resolvingSymlinksInPath().standardizedFileURL.path,
            b.resolvingSymlinksInPath().standardizedFileURL.path
        ].sorted()
        XCTAssertEqual(discovered.sorted(), expected)
    }

    func testDiscoveredRouterHomesMergeIntoConfiguredCodexHomes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests-RouterMerge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let routerHome = root.appendingPathComponent(
            ".codex/codex-router/chatgpt-accounts/acct_LEdkU4MiY7gAqOeN", isDirectory: true
        )
        try FileManager.default.createDirectory(at: routerHome, withIntermediateDirectories: true)
        try Data(codexAuth(accountID: "9de63544-5afb-4036-9e7d-89ee160af849", accessToken: "tok").utf8)
            .write(to: routerHome.appendingPathComponent("auth.json"))

        let homes = ProviderAccountAssembly.configuredCodexHomes(
            environment: FakeEnvironment([:]),
            registeredHomes: ["/Users/dev/codex-registered"],
            homeDirectory: root,
            discoveredRouterHomes: [routerHome.path]
        )
        let routerPath = routerHome.resolvingSymlinksInPath().standardizedFileURL.path
        XCTAssertEqual(homes, ["/Users/dev/codex-registered", routerPath])
    }

}
