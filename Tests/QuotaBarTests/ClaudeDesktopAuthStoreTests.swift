import CommonCrypto
import CryptoKit
import Foundation
import XCTest
@testable import QuotaBar

final class ClaudeDesktopAuthStoreTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/fixture-home", isDirectory: true)
    private let organization = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let otherOrganization = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private let accountUUID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
    private let clientID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    private let otherClientID = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    private let password = "fixture-safe-storage-password"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var safeStoragePermissionKey: KeychainItemKey {
        KeychainItemKey(
            service: ClaudeDesktopSafeStorageKeyReader.service,
            account: ClaudeDesktopSafeStorageKeyReader.account
        )
    }

    func testDecryptsElectronSafeStorageValue() throws {
        let key = try ClaudeDesktopAuthStore.deriveKey(password: password)
        let plaintext = Data(#"{"token":"secret"}"#.utf8)
        let encrypted = try encrypt(plaintext, key: key)

        XCTAssertEqual(try ClaudeDesktopAuthStore.decrypt(encrypted, key: key), plaintext)
        XCTAssertThrowsError(try ClaudeDesktopAuthStore.decrypt(Data("v11bad".utf8), key: key))
    }

    func testSelectsActiveOrganizationFromV2Cache() throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [
                cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600),
                cacheKey(organization: otherOrganization): tokenEntry("other-token", expiresIn: 7_200)
            ],
            v1: [
                cacheKey(organization: organization): tokenEntry("old-token", expiresIn: 10_800)
            ]
        )

        let result = fixture.store.load(allowInteraction: false)

        XCTAssertEqual(result.status, .available)
        XCTAssertEqual(result.oauth?.accessToken, "desktop-token")
        XCTAssertNil(result.oauth?.refreshToken)
        XCTAssertEqual(result.oauth?.scopes, ["user:profile", "user:inference"])
    }

    func testPinnedInactiveOrganizationRequiresTheCurrentDesktopAccount() throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [
                cacheKey(organization: organization): tokenEntry("active-token", expiresIn: 3_600),
                cacheKey(organization: otherOrganization): tokenEntry("other-token", expiresIn: 3_600),
            ],
            accountUUID: accountUUID
        )

        let result = fixture.store.load(
            allowInteraction: false, organization: otherOrganization, expectedAccountUUID: accountUUID
        )

        XCTAssertEqual(result.status, .available)
        XCTAssertEqual(result.organization, otherOrganization)
        XCTAssertEqual(result.oauth?.accessToken, "other-token")
        XCTAssertEqual(fixture.store.load(
            allowInteraction: false, organization: otherOrganization,
            expectedAccountUUID: "ffffffff-ffff-4fff-8fff-ffffffffffff"
        ).status, .notFound)
    }

    func testBatchOrganizationLoadRejectsAccountSwitchDuringSafeStorageRead() async throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("account-a-token", expiresIn: 3_600)],
            accountUUID: accountUUID
        )
        let keyReader = AccountSwitchingClaudeDesktopKeyReader(password: password)
        let fixtureHome = home
        let fixtureNow = now
        let expectedAccountUUID = accountUUID
        let organizationID = organization
        let store = ClaudeDesktopAuthStore(
            files: fixture.files,
            sqlite: fixture.sqlite,
            keyReader: keyReader,
            homeDirectory: { fixtureHome },
            now: { fixtureNow },
            keyCache: SafeStorageKeyCache()
        )
        let task = Task.detached {
            store.loadOrganizations(
                [organizationID],
                allowInteraction: false,
                expectedAccountUUID: expectedAccountUUID
            )
        }
        XCTAssertEqual(keyReader.readStarted.wait(timeout: .now() + 5), .success)
        defer { keyReader.allowRead.signal() }

        let configPath = home.appendingPathComponent("Library/Application Support/Claude/config.json").path
        let config = try XCTUnwrap(fixture.files.files[configPath])
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any]
        )
        object["lastKnownAccountUuid"] = "ffffffff-ffff-4fff-8fff-ffffffffffff"
        let switchedConfig = try JSONSerialization.data(withJSONObject: object)
        fixture.files.files[configPath] = String(decoding: switchedConfig, as: UTF8.self)
        keyReader.allowRead.signal()

        let result = await task.value

        XCTAssertEqual(result.credentialsByOrganization[organization]?.status, .notFound)
        XCTAssertNil(result.credentialsByOrganization[organization]?.oauth)
    }

    func testLogoutWithRetainedDatabaseAndCacheDoesNotExposeCredentials() throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("retained-token", expiresIn: 3_600)],
            accountUUID: accountUUID
        )
        let fixtureHome = home
        let loggedOut = ClaudeDesktopAuthStore(
            files: fixture.files,
            sqlite: FakeClaudeDesktopSQLite(value: nil),
            keyReader: fixture.keyReader,
            homeDirectory: { fixtureHome }
        )

        XCTAssertFalse(loggedOut.hasCredentialMaterial())
        XCTAssertEqual(loggedOut.load(
            allowInteraction: false, organization: organization, expectedAccountUUID: accountUUID
        ).status, .notFound)
        XCTAssertTrue(fixture.keyReader.calls.isEmpty)
    }

    func testUnreadableDesktopConfigCountsAsMaterialWithoutReadingKeychain() throws {
        let fixtureHome = home
        let files = ClaudeDesktopUnreadableConfigFiles(
            path: fixtureHome.appendingPathComponent("Library/Application Support/Claude/config.json").path
        )
        let keyReader = FakeClaudeDesktopKeyReader(password: password, requiresInteraction: true)
        let store = ClaudeDesktopAuthStore(
            files: files,
            sqlite: FakeClaudeDesktopSQLite(value: "1"),
            keyReader: keyReader,
            homeDirectory: { fixtureHome }
        )

        XCTAssertEqual(store.credentialMaterialStatus(), .unreadable)
        XCTAssertTrue(store.hasCredentialMaterial())
        XCTAssertEqual(store.load(allowInteraction: true).status, .unreadable)
        XCTAssertTrue(keyReader.calls.isEmpty, "detection and failed config reads must not prompt for Safe Storage")
    }

    func testUnreadableDesktopCookieDatabaseCountsAsMaterialWithoutReadingKeychain() throws {
        let fixtureHome = home
        let configPath = fixtureHome.appendingPathComponent("Library/Application Support/Claude/config.json").path
        let cookiesPath = fixtureHome.appendingPathComponent("Library/Application Support/Claude/Cookies").path
        let files = FakeFiles([configPath: #"{"oauth:tokenCacheV2":"encrypted-cache"}"#, cookiesPath: "sqlite-fixture"])
        let keyReader = FakeClaudeDesktopKeyReader(password: password, requiresInteraction: true)
        let store = ClaudeDesktopAuthStore(
            files: files,
            sqlite: UnreadableClaudeDesktopSQLite(),
            keyReader: keyReader,
            homeDirectory: { fixtureHome }
        )

        XCTAssertEqual(store.credentialMaterialStatus(), .unreadable)
        XCTAssertTrue(store.hasCredentialMaterial())
        XCTAssertEqual(store.load(allowInteraction: true).status, .unreadable)
        XCTAssertTrue(keyReader.calls.isEmpty, "a failed local probe must not escalate to a Keychain prompt")
    }

    @MainActor
    func testUnreadableClaudeEnvironmentSkipsDesktopDiscoveryWhileReconcilingCodex() throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)],
            accountUUID: accountUUID
        )
        fixture.files.files["\(home.path)/.codex/auth.json"] =
            #"{"tokens":{"access_token":"codex-token","account_id":"CODEX-1"}}"#
        let suite = "OpenUsageTests.UnreadableClaudeEnvironment.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixtureHome = home
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment(), files: fixture.files, keychain: FakeKeychain(),
            homeDirectory: { fixtureHome }
        )
        let accountsStore = ProviderAccountsStore(defaults: defaults)
        let organizations = [organization]

        let assembly = ProviderAccountAssembly.make(
            observer: observer, accountsStore: accountsStore, families: ["codex"],
            desktop: fixture.store, listDesktopOrganizationDirectories: { _ in organizations }
        )

        XCTAssertTrue(assembly.claudeCards.isEmpty)
        XCTAssertEqual(assembly.identityKeysByCard, ["codex": "codex-1"])
        XCTAssertEqual(accountsStore.records.map(\.family), ["codex"])
        XCTAssertTrue(fixture.keyReader.calls.isEmpty)
    }

    func testDisabledClaudeSkipsSafeStorageDuringDesktopAccountDiscovery() throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)],
            accountUUID: accountUUID
        )
        let fixtureHome = home
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment(), files: fixture.files, keychain: FakeKeychain(),
            homeDirectory: { fixtureHome }
        )

        let discovery = ProviderAccountAssembly.scan(
            observer: observer,
            families: ["claude"],
            desktop: fixture.store,
            discoverClaudeDesktopOrganizations: false
        )

        XCTAssertTrue(discovery.didSkipClaudeDesktopDiscovery)
        XCTAssertTrue(discovery.desktopOrganizations.isEmpty)
        XCTAssertTrue(fixture.keyReader.calls.isEmpty, "a disabled provider must not read Desktop Safe Storage")
    }

    @MainActor
    func testGenericClaudeFallbackReusesDiscoverySafeStorageKeyCache() throws {
        let keyCache = SafeStorageKeyCache()
        let provider = try XCTUnwrap(
            ProviderCatalog.make(claudeDesktopKeyCache: keyCache).compactMap { $0 as? ClaudeProvider }.first
        )

        XCTAssertTrue(provider.authStore.desktop.keyCache === keyCache)
    }

    @MainActor
    func testOrganizationSwitchKeepsPersistedCardIDsAndDistinctScopedRuntimes() throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [
                cacheKey(organization: organization): tokenEntry("personal-token", expiresIn: 3_600),
                cacheKey(organization: otherOrganization): tokenEntry("work-token", expiresIn: 3_600),
            ],
            accountUUID: accountUUID
        )
        let previousIdentity = "\(accountUUID)|\(organization)"
        let currentIdentity = "\(accountUUID)|\(otherOrganization)"
        let suite = "OpenUsageTests.OrganizationSwitch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let existing = ProviderAccountRecord(
            id: "claude", family: "claude", identityKey: previousIdentity,
            label: "Personal",
            sources: [.init(kind: .defaultHome, anchor: "\(home.path)/.claude", holdsDefaultSource: true)]
        )
        defaults.set(try JSONEncoder().encode([existing]), forKey: ProviderAccountsStore.storageKey)
        fixture.files.files["\(home.path)/.claude.json"] =
            #"{"oauthAccount":{"accountUuid":"\#(accountUUID)","organizationUuid":"\#(otherOrganization)","emailAddress":"work@example.com","organizationName":"SUNSTORY"}}"#
        let fixtureHome = home
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment(), files: fixture.files, keychain: FakeKeychain(),
            homeDirectory: { fixtureHome }
        )
        let organizations = [organization, otherOrganization]
        let assembly = ProviderAccountAssembly.make(
            observer: observer, accountsStore: ProviderAccountsStore(defaults: defaults), families: ["claude"],
            desktop: fixture.store, listDesktopOrganizationDirectories: { _ in organizations }
        )
        let workID = ProviderAccountID.make(family: "claude", identityKey: currentIdentity)

        XCTAssertEqual(assembly.claudeCards.map(\.id), [workID, "claude"])
        XCTAssertEqual(assembly.identityKeysByCard, [workID: currentIdentity, "claude": previousIdentity])
        XCTAssertEqual(assembly.claudeCards.map(\.displayName), ["Claude — SUNSTORY", "Claude — Personal"])
        let providers = ProviderCatalog.make(
            claudeCards: assembly.claudeCards,
            claudeIdentityKeys: assembly.identityKeysByCard,
            claudeDesktopKeyCache: assembly.desktopKeyCache
        ).compactMap { $0 as? ClaudeProvider }
        XCTAssertTrue(providers.allSatisfy { $0.authStore.desktop.keyCache === assembly.desktopKeyCache })
        XCTAssertEqual(fixture.keyReader.calls.count, 1, "discovery performs one successful Safe Storage read")
        _ = try assembly.desktopKeyCache.getOrLoad {
            try fixture.keyReader.readPassword(allowInteraction: false).map { Data($0.utf8) }
        }
        XCTAssertEqual(fixture.keyReader.calls.count, 1, "the provider cache reuses the discovery key")
        XCTAssertEqual(providers.map { $0.provider.id }, [workID, "claude"])
        XCTAssertEqual(providers.map { $0.authStore.desktopOnly }, [false, true])
        XCTAssertEqual(providers.map { $0.authStore.preferOrganizationScopedDesktop }, [true, false])
        XCTAssertFalse(providers.contains { $0.allowsUnattributedPiUsage })

        let withoutDesktop = ProviderAccountAssembly.make(
            observer: observer, accountsStore: ProviderAccountsStore(defaults: defaults), families: ["claude"],
            desktop: ClaudeDesktopAuthStore(files: FakeFiles(), homeDirectory: { fixtureHome })
        )
        XCTAssertEqual(withoutDesktop.claudeCards.count, 1)
        XCTAssertFalse(try XCTUnwrap(withoutDesktop.claudeCards.first).allowsUnattributedPiUsage)

        fixture.files.files["\(home.path)/.claude.json"] =
            #"{"oauthAccount":{"accountUuid":"\#(accountUUID)"}}"#
        let legacy = ProviderAccountAssembly.make(
            observer: observer, accountsStore: ProviderAccountsStore(defaults: defaults), families: ["claude"],
            desktop: fixture.store, listDesktopOrganizationDirectories: { _ in organizations }
        )
        XCTAssertTrue(legacy.claudeCards.isEmpty)
        XCTAssertEqual(legacy.identityKeysByCard["claude"], accountUUID)
    }

    func testV1FallbackDoesNotOverrideTombstonedV2Key() throws {
        let key = cacheKey(organization: organization)
        let selection = ClaudeDesktopAuthStore.selectCredential(
            activeOrganization: organization,
            v2: [key: NSNull()],
            v1: [key: tokenEntry("resurrected-token", expiresIn: 3_600)],
            now: now
        )

        guard case .notFound = selection else {
            return XCTFail("V2 tombstone should suppress the matching V1 token")
        }
    }

    func testFullScopeProductionClientOutranksLongerLivedProfileOnlyEntry() throws {
        // Two live entries under the same org: a long-TTL profile-only leftover carrying a stale 5x
        // tier, and the current full-scope Claude Code production login (20x) expiring sooner. Expiry
        // alone would pick the stale 5x token; the ranking must pick the production login.
        let productionClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        let selection = ClaudeDesktopAuthStore.selectCredential(
            activeOrganization: organization,
            v2: [
                cacheKey(organization: organization, scopes: "user:profile"):
                    tokenEntry("stale-5x-token", expiresIn: 86_400, rateLimitTier: "default_claude_max_5x"),
                cacheKey(
                    organization: organization,
                    clientID: productionClientID,
                    scopes: "user:profile user:inference"
                ):
                    tokenEntry("current-20x-token", expiresIn: 1_800, rateLimitTier: "default_claude_max_20x")
            ],
            v1: nil,
            now: now
        )

        guard case .available(let oauth) = selection else {
            return XCTFail("expected an available credential, got \(selection)")
        }
        XCTAssertEqual(oauth.accessToken, "current-20x-token")
        XCTAssertEqual(oauth.rateLimitTier, "default_claude_max_20x")
    }

    func testFullScopeEntryOutranksProfileOnlyEntryForNonProductionClients() throws {
        let selection = ClaudeDesktopAuthStore.selectCredential(
            activeOrganization: organization,
            v2: [
                cacheKey(organization: organization, scopes: "user:profile"):
                    tokenEntry("profile-only-token", expiresIn: 86_400),
                cacheKey(organization: organization, clientID: otherClientID, scopes: "user:profile user:inference"):
                    tokenEntry("full-scope-token", expiresIn: 1_800)
            ],
            v1: nil,
            now: now
        )

        guard case .available(let oauth) = selection else {
            return XCTFail("expected an available credential, got \(selection)")
        }
        XCTAssertEqual(oauth.accessToken, "full-scope-token")
    }

    func testBackgroundReadDoesNotPromptButManualReadCan() throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)],
            requiresInteraction: true
        )

        XCTAssertEqual(fixture.store.load(allowInteraction: false).status, .permissionRequired)
        XCTAssertEqual(fixture.keyReader.calls, [false])

        // A manual read still probes silently first and only escalates when that is proven necessary.
        // Going straight to the interactive call would open a dialog even when the item has since
        // become accessible, and `allowInteraction` is permission to prompt — not an instruction to.
        // So the recorded sequence is a second silent attempt, then the interactive one.
        XCTAssertEqual(fixture.store.load(allowInteraction: true).status, .available)
        XCTAssertEqual(fixture.keyReader.calls, [false, false, true])

        // The derived key is cached after approval, so later background refreshes are prompt-free and
        // never touch the Keychain again. This is the property that matters: without it the app would
        // re-prompt every cycle, which is the failure the whole silent-first design exists to prevent.
        XCTAssertEqual(fixture.store.load(allowInteraction: false).status, .available)
        XCTAssertEqual(fixture.keyReader.calls, [false, false, true])
    }

    func testParallelDesktopCardsShareSuccessfulSafeStoragePrompt() async throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
        )
        let keyCache = SafeStorageKeyCache()
        let keyReader = BlockingClaudeDesktopKeyReader(password: password, blockInteraction: true)
        let fixtureHome = home
        let fixtureNow = now
        let firstStore = ClaudeDesktopAuthStore(
            files: fixture.files,
            sqlite: fixture.sqlite,
            keyReader: keyReader,
            homeDirectory: { fixtureHome },
            now: { fixtureNow },
            keyCache: keyCache
        )
        let siblingStore = ClaudeDesktopAuthStore(
            files: fixture.files,
            sqlite: fixture.sqlite,
            keyReader: keyReader,
            homeDirectory: { fixtureHome },
            now: { fixtureNow },
            keyCache: keyCache
        )
        let interactionGate = CredentialInteractionGate()
        let permissionKey = KeychainItemKey(
            service: ClaudeDesktopSafeStorageKeyReader.service,
            account: ClaudeDesktopSafeStorageKeyReader.account
        )
        KeychainPermissionGate.shared.reset(permissionKey)
        defer { KeychainPermissionGate.shared.reset(permissionKey) }
        let first = Task.detached {
            firstStore.load(allowInteraction: true, interactionGate: interactionGate)
        }
        XCTAssertEqual(keyReader.interactiveReadStarted.wait(timeout: .now() + 5), .success)

        let siblingStarted = DispatchSemaphore(value: 0)
        let sibling = Task.detached {
            siblingStarted.signal()
            return siblingStore.load(allowInteraction: true, interactionGate: interactionGate)
        }
        XCTAssertEqual(siblingStarted.wait(timeout: .now() + 5), .success)
        let siblingWaitedForKey = waitUntil(timeout: 5) { keyCache.waitingReaderCount == 1 }
        keyReader.allowInteractiveRead.signal()

        let firstResult = await first.value
        let siblingResult = await sibling.value

        XCTAssertTrue(siblingWaitedForKey, "the second account card should wait for the first Safe Storage read")
        XCTAssertEqual(firstResult.status, .available)
        XCTAssertEqual(siblingResult.status, .available)
        XCTAssertEqual(firstResult.oauth?.accessToken, "desktop-token")
        XCTAssertEqual(siblingResult.oauth?.accessToken, "desktop-token")
        XCTAssertEqual(keyReader.calls, [false, true], "only one silent probe and one approval dialog should run")
    }

    func testSeparateSafeStorageCachesRecoverAfterSiblingGrantWithoutSecondPrompt() async throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
        )
        let keyReader = GrantingAfterInteractiveClaudeDesktopKeyReader(password: password)
        let fixtureHome = home
        let fixtureNow = now
        let firstStore = ClaudeDesktopAuthStore(
            files: fixture.files,
            sqlite: fixture.sqlite,
            keyReader: keyReader,
            homeDirectory: { fixtureHome },
            now: { fixtureNow },
            keyCache: SafeStorageKeyCache()
        )
        let siblingStore = ClaudeDesktopAuthStore(
            files: fixture.files,
            sqlite: fixture.sqlite,
            keyReader: keyReader,
            homeDirectory: { fixtureHome },
            now: { fixtureNow },
            keyCache: SafeStorageKeyCache()
        )
        let interactionGate = CredentialInteractionGate()
        KeychainPermissionGate.shared.reset(safeStoragePermissionKey)
        defer { KeychainPermissionGate.shared.reset(safeStoragePermissionKey) }

        let first = Task.detached {
            firstStore.load(allowInteraction: true, interactionGate: interactionGate)
        }
        XCTAssertEqual(keyReader.interactiveReadStarted.wait(timeout: .now() + 2), .success)
        let sibling = Task.detached {
            siblingStore.load(allowInteraction: true, interactionGate: interactionGate)
        }

        let siblingWaited = waitUntil(timeout: 2) {
            KeychainPermissionGate.shared.interactiveQueryWaiterCountForTesting() > 0
        }
        keyReader.releaseInteractiveRead.signal()

        let firstResult = await first.value
        let siblingResult = await sibling.value
        XCTAssertTrue(siblingWaited, "the sibling must wait for the same item's interactive result")
        XCTAssertEqual(firstResult.status, .available)
        XCTAssertEqual(siblingResult.status, .available)
        XCTAssertEqual(keyReader.calls, [false, true, false], "only the owner may prompt; the sibling retries silently")
    }

    func testSpentManualPromptBudgetDoesNotRepeatSafeStorageReadForSiblingCard() async throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
        )
        let keyReader = FakeClaudeDesktopKeyReader(password: password, requiresInteraction: true)
        let keyCache = SafeStorageKeyCache()
        let fixtureHome = home
        let fixtureNow = now
        let firstStore = ClaudeDesktopAuthStore(
            files: fixture.files, sqlite: fixture.sqlite, keyReader: keyReader,
            homeDirectory: { fixtureHome }, now: { fixtureNow }, keyCache: keyCache
        )
        let siblingStore = ClaudeDesktopAuthStore(
            files: fixture.files, sqlite: fixture.sqlite, keyReader: keyReader,
            homeDirectory: { fixtureHome }, now: { fixtureNow }, keyCache: keyCache
        )
        KeychainPermissionGate.shared.reset(safeStoragePermissionKey)
        defer { KeychainPermissionGate.shared.reset(safeStoragePermissionKey) }

        let result = await withManualRefresh {
            let interactionGate = ProviderRefreshContext.credentialInteractionGate
            let spent = interactionGate?.claim() ?? false
            let first = firstStore.load(allowInteraction: true, interactionGate: interactionGate)
            let sibling = siblingStore.load(allowInteraction: true, interactionGate: interactionGate)
            return (spent, first, sibling)
        }

        XCTAssertTrue(result.0, "another provider has already used this action's shared prompt budget")
        XCTAssertEqual(result.1.status, .permissionRequired)
        XCTAssertEqual(result.2.status, .permissionRequired)
        XCTAssertEqual(keyReader.calls, [false], "a sibling card must reuse the declined-item result")
        XCTAssertTrue(KeychainPermissionGate.shared.isDeclined(safeStoragePermissionKey))
    }

    func testCancelledSafeStorageCacheWaiterReturnsBeforeLeaderFinishes() async throws {
        let cache = SafeStorageKeyCache()
        let loaderCalls = SafeStorageLoadCounter()
        let leaderStarted = DispatchSemaphore(value: 0)
        let releaseLeader = DispatchSemaphore(value: 0)
        let waiterFinished = SafeStorageLoadCounter()
        defer { releaseLeader.signal() }

        let leader = Task.detached {
            try cache.getOrLoad {
                loaderCalls.increment()
                leaderStarted.signal()
                _ = releaseLeader.wait(timeout: .now() + 5)
                return Data([1])
            }
        }
        XCTAssertEqual(leaderStarted.wait(timeout: .now() + 5), .success)

        let waiterStarted = DispatchSemaphore(value: 0)
        let waiter = Task.detached {
            waiterStarted.signal()
            return try cache.getOrLoad {
                loaderCalls.increment()
                return Data([2])
            }
        }
        XCTAssertEqual(waiterStarted.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(waitUntil(timeout: 5) { cache.waitingReaderCount == 1 })
        let observer = Task.detached {
            do {
                _ = try await waiter.value
                waiterFinished.increment()
                return false
            } catch is CancellationError {
                waiterFinished.increment()
                return true
            } catch {
                waiterFinished.increment()
                return false
            }
        }

        waiter.cancel()
        let returnedBeforeLeaderRelease = waitUntil(timeout: 1) { waiterFinished.value > 0 }
        releaseLeader.signal()
        let leaderValue = try await leader.value
        let waiterWasCancelled = await observer.value

        XCTAssertTrue(returnedBeforeLeaderRelease, "a canceled waiter must not occupy a worker until Security returns")
        XCTAssertTrue(waiterWasCancelled)
        XCTAssertEqual(leaderValue, Data([1]))
        XCTAssertEqual(loaderCalls.value, 1, "the canceled waiter must not start another Safe Storage read")
    }

    func testCurrentSafeStorageWaiterRetriesWhenStaleLeaderIsSuperseded() async throws {
        let cache = SafeStorageKeyCache()
        let loaderCalls = SafeStorageLoadCounter()
        let leaderStarted = SafeStorageLoadCounter()
        let releaseLeader = DispatchSemaphore(value: 0)
        let staleAction = SafeStorageActionValidity(true)
        let currentAction = SafeStorageActionValidity(true)
        defer { releaseLeader.signal() }

        let leader = Task.detached {
            try cache.getOrLoad({
                loaderCalls.increment()
                leaderStarted.increment()
                _ = releaseLeader.wait(timeout: .now() + 5)
                throw CancellationError()
            }, isCurrent: { staleAction.isCurrent })
        }
        XCTAssertTrue(waitUntil(timeout: 5) { leaderStarted.value == 1 })

        let currentWaiter = Task.detached {
            try cache.getOrLoad({
                loaderCalls.increment()
                return Data([2])
            }, isCurrent: { currentAction.isCurrent })
        }
        XCTAssertTrue(waitUntil(timeout: 5) { cache.waitingReaderCount == 1 })
        staleAction.setCurrent(false)
        releaseLeader.signal()

        do {
            _ = try await leader.value
            XCTFail("the superseded leader should receive cancellation")
        } catch is CancellationError {
            // Expected: the leader's manual action no longer owns this read.
        }
        let currentValue = try await currentWaiter.value
        XCTAssertEqual(currentValue, Data([2]))
        XCTAssertEqual(loaderCalls.value, 2, "the current action must perform its own cache load")
    }

    func testStaleSafeStorageKeychainFailureDoesNotPoisonCurrentWaiter() async throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
        )
        let cache = SafeStorageKeyCache()
        let reader = StaleFailureClaudeDesktopKeyReader(password: password)
        let fixtureHome = home
        let fixtureNow = now
        func store() -> ClaudeDesktopAuthStore {
            ClaudeDesktopAuthStore(
                files: fixture.files,
                sqlite: fixture.sqlite,
                keyReader: reader,
                homeDirectory: { fixtureHome },
                now: { fixtureNow },
                keyCache: cache
            )
        }
        let staleStore = store()
        let currentStore = store()
        KeychainPermissionGate.shared.reset(safeStoragePermissionKey)
        defer { KeychainPermissionGate.shared.reset(safeStoragePermissionKey) }
        defer { reader.releaseFirstRead.signal() }

        let staleAction = Task.detached {
            await withManualRefresh {
                await loadOffMainActor {
                    staleStore.load(
                        allowInteraction: ProviderRefreshContext.isManual,
                        interactionGate: ProviderRefreshContext.credentialInteractionGate
                    )
                }
            }
        }
        XCTAssertEqual(reader.firstReadStarted.wait(timeout: .now() + 5), .success)

        let currentAction = Task.detached {
            await withManualRefresh {
                await loadOffMainActor {
                    currentStore.load(
                        allowInteraction: ProviderRefreshContext.isManual,
                        interactionGate: ProviderRefreshContext.credentialInteractionGate
                    )
                }
            }
        }
        XCTAssertTrue(waitUntil(timeout: 5) { cache.waitingReaderCount == 1 })
        reader.releaseFirstRead.signal()

        let staleResult = await staleAction.value
        let currentResult = await currentAction.value

        XCTAssertEqual(staleResult.status, .notChecked, "the superseded Keychain failure belongs to the stale action")
        XCTAssertEqual(currentResult.status, .available, "the current action must perform its own Safe Storage read")
        XCTAssertEqual(reader.calls, [false, false])
    }

    func testConcurrentSafeStorageWaitersShareAbsenceAndFailuresUntilNextRefresh() async throws {
        for shouldThrow in [false, true] {
            let cache = SafeStorageKeyCache()
            let loaderCalls = SafeStorageLoadCounter()
            let leaderStarted = DispatchSemaphore(value: 0)
            let releaseLeader = DispatchSemaphore(value: 0)
            defer { releaseLeader.signal() }

            let leader = Task.detached {
                try cache.getOrLoad {
                    loaderCalls.increment()
                    leaderStarted.signal()
                    _ = releaseLeader.wait(timeout: .now() + 5)
                    if shouldThrow { throw SafeStorageLoadFailure.failed }
                    return nil
                }
            }
            XCTAssertEqual(leaderStarted.wait(timeout: .now() + 5), .success)

            let waiterStarted = DispatchSemaphore(value: 0)
            let waiter = Task.detached {
                waiterStarted.signal()
                return try cache.getOrLoad {
                    loaderCalls.increment()
                    return Data([2])
                }
            }
            XCTAssertEqual(waiterStarted.wait(timeout: .now() + 5), .success)
            XCTAssertTrue(waitUntil(timeout: 5) { cache.waitingReaderCount == 1 })
            releaseLeader.signal()

            if shouldThrow {
                do { _ = try await leader.value; XCTFail("expected the leader failure") }
                catch SafeStorageLoadFailure.failed { }
                do { _ = try await waiter.value; XCTFail("the waiter should share the leader failure") }
                catch SafeStorageLoadFailure.failed { }
            } else {
                let leaderValue = try await leader.value
                let waiterValue = try await waiter.value
                XCTAssertNil(leaderValue)
                XCTAssertNil(waiterValue, "the waiter must share absence instead of retrying")
            }
            XCTAssertEqual(loaderCalls.value, 1)

            let retried = try cache.getOrLoad { loaderCalls.increment(); return Data([3]) }
            XCTAssertEqual(retried, Data([3]), "a later independent refresh may retry the failed/absent item")
            XCTAssertEqual(loaderCalls.value, 2)
        }
    }

    func testNewManualActionCannotPromptWhileSafeStorageReadIsInFlight() async throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
        )
        let fixtureHome = home
        let fixtureNow = now
        let blockingReader = BlockingClaudeDesktopKeyReader(password: password, blockInteraction: true)
        let firstStore = ClaudeDesktopAuthStore(
            files: fixture.files,
            sqlite: fixture.sqlite,
            keyReader: blockingReader,
            homeDirectory: { fixtureHome },
            now: { fixtureNow }
        )
        let retryReader = FakeClaudeDesktopKeyReader(password: password, requiresInteraction: true)
        let retryStore = ClaudeDesktopAuthStore(
            files: fixture.files,
            sqlite: fixture.sqlite,
            keyReader: retryReader,
            homeDirectory: { fixtureHome },
            now: { fixtureNow }
        )
        let permissionKey = KeychainItemKey(
            service: ClaudeDesktopSafeStorageKeyReader.service,
            account: ClaudeDesktopSafeStorageKeyReader.account
        )
        KeychainPermissionGate.shared.reset(permissionKey)
        defer { KeychainPermissionGate.shared.reset(permissionKey) }

        let firstAction = Task.detached {
            await withManualRefresh {
                firstStore.load(
                    allowInteraction: ProviderRefreshContext.isManual,
                    interactionGate: ProviderRefreshContext.credentialInteractionGate
                )
            }
        }
        XCTAssertEqual(
            blockingReader.interactiveReadStarted.wait(timeout: .now() + 5), .success,
            "the first action must be paused inside the interactive Safe Storage read"
        )

        let overlappingResult = await withManualRefresh {
            retryStore.load(
                allowInteraction: ProviderRefreshContext.isManual,
                interactionGate: ProviderRefreshContext.credentialInteractionGate
            )
        }
        XCTAssertEqual(overlappingResult.status, .permissionRequired)
        XCTAssertEqual(retryReader.calls, [false], "a newer action must not start another Keychain query")

        blockingReader.allowInteractiveRead.signal()
        let staleResult = await firstAction.value
        XCTAssertEqual(staleResult.status, .notChecked, "the superseded action must not publish its result")

        let retryResult = await withManualRefresh {
            retryStore.load(
                allowInteraction: ProviderRefreshContext.isManual,
                interactionGate: ProviderRefreshContext.credentialInteractionGate
            )
        }
        XCTAssertEqual(retryResult.status, .available)
        XCTAssertEqual(retryReader.calls, [false, false, true])
    }

    func testQueuedOlderManualActionCannotPromptAfterNewerManualActionBegins() async throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
        )
        let fixtureHome = home
        let fixtureNow = now
        let keyReader = BlockingClaudeDesktopKeyReader(password: password, blockInteraction: false)
        let store = ClaudeDesktopAuthStore(
            files: fixture.files,
            sqlite: fixture.sqlite,
            keyReader: keyReader,
            homeDirectory: { fixtureHome },
            now: { fixtureNow }
        )
        let permissionKey = KeychainItemKey(
            service: ClaudeDesktopSafeStorageKeyReader.service,
            account: ClaudeDesktopSafeStorageKeyReader.account
        )
        KeychainPermissionGate.shared.reset(permissionKey)
        defer { KeychainPermissionGate.shared.reset(permissionKey) }

        // The older manual action reaches its detached credential load and pauses on the silent
        // Keychain probe. A later Refresh starts before that probe returns.
        let olderAction = Task.detached {
            await withManualRefresh {
                await loadOffMainActor {
                    store.load(
                        allowInteraction: ProviderRefreshContext.isManual,
                        interactionGate: ProviderRefreshContext.credentialInteractionGate
                    )
                }
            }
        }
        XCTAssertEqual(keyReader.silentReadStarted.wait(timeout: .now() + 5), .success)

        let newerActionID = await withManualRefresh {
            ProviderRefreshContext.manualActionID
        }
        XCTAssertNotNil(newerActionID, "the newer Refresh must advance the action identity")

        keyReader.allowSilentRead.signal()
        let staleResult = await olderAction.value

        XCTAssertEqual(staleResult.status, .notChecked, "a superseded action must not publish a stale Keychain permission result")
        XCTAssertEqual(keyReader.calls, [false], "a stale Desktop read may not open a Keychain prompt")
        XCTAssertFalse(KeychainPermissionGate.shared.isDeclined(permissionKey))
        XCTAssertFalse(KeychainPermissionGate.shared.isBlocked(permissionKey), "stale work must not block the newer action")

        // The stale refusal must leave the next explicit action free to claim its own prompt.
        let retry = Task.detached {
            await withManualRefresh {
                await loadOffMainActor {
                    store.load(
                        allowInteraction: ProviderRefreshContext.isManual,
                        interactionGate: ProviderRefreshContext.credentialInteractionGate
                    )
                }
            }
        }
        XCTAssertEqual(keyReader.silentReadStarted.wait(timeout: .now() + 5), .success)
        keyReader.allowSilentRead.signal()
        let retryResult = await retry.value
        XCTAssertEqual(retryResult.status, .available)
        XCTAssertEqual(keyReader.calls, [false, false, true])
    }

    func testCancellationBeforeInteractiveReadDoesNotRecordUserDecline() async throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
        )
        let fixtureHome = home
        let fixtureNow = now
        let permissionKey = KeychainItemKey(
            service: ClaudeDesktopSafeStorageKeyReader.service,
            account: ClaudeDesktopSafeStorageKeyReader.account
        )
        KeychainPermissionGate.shared.reset(permissionKey)
        defer { KeychainPermissionGate.shared.reset(permissionKey) }
        let keyReader = BlockingClaudeDesktopKeyReader(password: password, blockInteraction: false)
        let store = ClaudeDesktopAuthStore(
            files: fixture.files,
            sqlite: fixture.sqlite,
            keyReader: keyReader,
            homeDirectory: { fixtureHome },
            now: { fixtureNow }
        )
        let task = Task.detached {
            store.load(allowInteraction: true, interactionGate: CredentialInteractionGate())
        }
        XCTAssertEqual(keyReader.silentReadStarted.wait(timeout: .now() + 5), .success)
        task.cancel()
        keyReader.allowSilentRead.signal()

        let result = await task.value

        XCTAssertEqual(result.status, .notChecked)
        XCTAssertEqual(keyReader.calls, [false], "the canceled refresh must stop before the interactive Keychain query")
        XCTAssertFalse(KeychainPermissionGate.shared.isDeclined(permissionKey))
    }

    func testCancellationDuringInteractiveSafeStorageReadDoesNotRecordDecline() throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
        )
        let permissionKey = KeychainItemKey(
            service: ClaudeDesktopSafeStorageKeyReader.service,
            account: ClaudeDesktopSafeStorageKeyReader.account
        )
        KeychainPermissionGate.shared.reset(permissionKey)
        defer { KeychainPermissionGate.shared.reset(permissionKey) }

        let fixtureHome = home
        let fixtureNow = now
        let keyReader = CancellingClaudeDesktopKeyReader()
        let token = KeychainReadCancellationToken(invalidateContext: { _ in })
        let store = ClaudeDesktopAuthStore(
            files: fixture.files,
            sqlite: fixture.sqlite,
            keyReader: keyReader,
            homeDirectory: { fixtureHome },
            now: { fixtureNow }
        )

        let result = try ProviderRefreshContext.$keychainReadCancellationToken.withValue(token) {
            store.load(allowInteraction: true, interactionGate: CredentialInteractionGate())
        }

        XCTAssertEqual(result.status, .notChecked)
        XCTAssertEqual(keyReader.calls, [false, true])
        XCTAssertTrue(KeychainPermissionGate.shared.isBlocked(permissionKey))
        XCTAssertFalse(KeychainPermissionGate.shared.isDeclined(permissionKey), "load cancellation is not a declined prompt")
    }

    func testExpiredDesktopTokenIsStale() throws {
        KeychainPermissionGate.shared.reset(safeStoragePermissionKey)
        defer { KeychainPermissionGate.shared.reset(safeStoragePermissionKey) }
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("expired", expiresIn: -1)]
        )

        XCTAssertEqual(fixture.store.load(allowInteraction: false).status, .stale)
    }

    func testWorkingCLICredentialsSkipDesktopProbe() throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
        )
        let authStore = makeAuthStore(fixture, keychainJSON: cliCredentials(token: "cli-token"))

        let load = authStore.loadCredentialSet()

        XCTAssertEqual(load.candidates.first?.oauth.accessToken, "cli-token")
        XCTAssertEqual(load.desktopStatus, .notChecked)
        XCTAssertTrue(fixture.keyReader.calls.isEmpty)
    }

    func testMultiOrganizationCLICardPrefersItsOwnScopedDesktopCredential() throws {
        KeychainPermissionGate.shared.reset(safeStoragePermissionKey)
        defer { KeychainPermissionGate.shared.reset(safeStoragePermissionKey) }
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [
                cacheKey(organization: organization): tokenEntry("personal-token", expiresIn: 3_600),
                cacheKey(organization: otherOrganization): tokenEntry("work-token", expiresIn: 3_600),
            ],
            accountUUID: accountUUID
        )
        let fixtureNow = now
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: fixture.files,
            keychain: FakeKeychain(cliCredentials(token: "personal-token")),
            desktop: fixture.store,
            desktopOrganization: otherOrganization,
            expectedIdentityKey: "\(accountUUID)|\(otherOrganization)",
            preferOrganizationScopedDesktop: true,
            now: { fixtureNow }
        )

        let load = authStore.loadCredentialSet()

        XCTAssertEqual(load.desktopStatus, .available)
        XCTAssertEqual(load.candidates.map(\.oauth.accessToken), ["work-token", "personal-token"])
        XCTAssertEqual(load.candidates.first?.source, .desktop)
    }

    func testWhitespaceOnlyCLIEntryDoesNotBlockDesktop() throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
        )
        let authStore = makeAuthStore(fixture, keychainJSON: cliCredentials(token: "   "))

        let load = authStore.loadCredentialSet()

        XCTAssertEqual(load.candidates.first?.source, .desktop)
        XCTAssertEqual(load.candidates.first?.oauth.accessToken, "desktop-token")
        XCTAssertEqual(fixture.keyReader.calls, [false])
    }

    @MainActor
    func testDesktopPermissionIsNotMaskedByScopedCLIToken() async throws {
        KeychainPermissionGate.shared.reset(safeStoragePermissionKey)
        defer { KeychainPermissionGate.shared.reset(safeStoragePermissionKey) }
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)],
            requiresInteraction: true
        )
        let httpClient = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data()))
        let provider = makeProvider(
            fixture,
            keychainJSON: cliCredentials(token: "inference-only-cli", scope: "user:inference"),
            httpClient: httpClient
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(badge(snapshot.lines, "Error"))
        XCTAssertEqual(snapshot.warning, ClaudeAuthError.desktopPermissionRequired.localizedDescription)
        XCTAssertTrue(httpClient.requests.isEmpty)
        XCTAssertEqual(fixture.keyReader.calls, [false])
    }

    func testDesktopCredentialsAreNeverSaved() throws {
        let files = FakeFiles()
        let keychain = FakeKeychain()
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
        )
        let authStore = makeAuthStore(fixture, environment: [:], files: files, keychain: keychain)
        let state = authStore.loadCredentialCandidates().first!

        XCTAssertFalse(try authStore.save(state, ifUnchanged: ClaudeCredentialGeneration([state])))
        XCTAssertTrue(files.files.isEmpty)
        XCTAssertNil(keychain.value)
    }

    @MainActor
    func testDesktop401NeverAttemptsRefreshTokenExchange() async throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
        )
        let httpClient = RoutingHTTPClient { request in
            XCTAssertTrue(request.url.absoluteString.hasSuffix("/api/oauth/usage"))
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let provider = makeProvider(fixture, environment: [:], keychainJSON: nil, httpClient: httpClient)

        let snapshot = await ProviderRefreshContext.$isManual.withValue(true) {
            await provider.refresh()
        }

        XCTAssertEqual(badge(snapshot.lines, "Error"), ClaudeAuthError.desktopTokenExpired.localizedDescription)
        XCTAssertEqual(httpClient.requests.count, 1)
    }

    @MainActor
    func testRevokedCLILoginFallsBackToDesktopBeforeEnvironmentToken() async throws {
        // The stored CLI login 401s (revoked); the desktop token must be the next candidate tried —
        // even when a lower-priority environment token is also available.
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
        )
        let httpClient = RoutingHTTPClient { request in
            let authorization = request.headers["Authorization"] ?? ""
            if authorization.contains("desktop-token") {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
                )
            }
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let provider = makeProvider(
            fixture,
            environment: [
                "CLAUDE_CONFIG_DIR": "/tmp/claude",
                "CLAUDE_CODE_OAUTH_TOKEN": "inference-only-env"
            ],
            keychainJSON: nil,
            keychain: CountingClaudeAuthKeychain(cliCredentials(token: "revoked-cli")),
            httpClient: httpClient
        )

        let snapshot = await ProviderRefreshContext.$isManual.withValue(true) {
            await provider.refresh()
        }

        XCTAssertNil(badge(snapshot.lines, "Error"))
        XCTAssertEqual(httpClient.requests.count, 2)
        XCTAssertTrue(httpClient.requests.last?.headers["Authorization"]?.contains("desktop-token") == true)
        XCTAssertEqual(
            (provider.authStore.keychain as? CountingClaudeAuthKeychain)?.calls,
            [false],
            "the Desktop-only fallback must not reread the rejected CLI Keychain credential"
        )
    }

    @MainActor
    func testStaleDesktopDoesNotMaskRevokedCLIError() async throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("expired-desktop", expiresIn: -1)]
        )
        let httpClient = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let provider = makeProvider(fixture, keychainJSON: cliCredentials(token: "revoked-cli"), httpClient: httpClient)

        let snapshot = await ProviderRefreshContext.$isManual.withValue(true) {
            await provider.refresh()
        }

        XCTAssertEqual(badge(snapshot.lines, "Error"), ClaudeAuthError.tokenExpired.localizedDescription)
        XCTAssertEqual(httpClient.requests.count, 1)
    }

    /// The stock CLI keychain payload: one far-future OAuth token with the given scope.
    private func cliCredentials(token: String, scope: String = "user:profile") -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(token)","expiresAt":4102444800000,"scopes":["\#(scope)"]}}"#
    }

    private func makeAuthStore(
        _ fixture: DesktopFixture,
        environment: [String: String] = ["CLAUDE_CONFIG_DIR": "/tmp/claude"],
        keychainJSON: String? = nil,
        files: FakeFiles? = nil,
        keychain: (any KeychainAccessing)? = nil
    ) -> ClaudeAuthStore {
        let now = now
        return ClaudeAuthStore(
            environment: FakeEnvironment(environment),
            files: files ?? fixture.files,
            keychain: keychain ?? FakeKeychain(keychainJSON),
            desktop: fixture.store,
            now: { now }
        )
    }

    @MainActor
    private func makeProvider(
        _ fixture: DesktopFixture,
        environment: [String: String] = ["CLAUDE_CONFIG_DIR": "/tmp/claude"],
        keychainJSON: String?,
        keychain: (any KeychainAccessing)? = nil,
        httpClient: any HTTPClient
    ) -> ClaudeProvider {
        let now = now
        return ClaudeProvider(
            authStore: makeAuthStore(fixture, environment: environment, keychainJSON: keychainJSON, keychain: keychain),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )
    }

    private func makeFixture(
        activeOrganization: String,
        v2: [String: Any],
        v1: [String: Any]? = nil,
        requiresInteraction: Bool = false,
        accountUUID: String? = nil
    ) throws -> DesktopFixture {
        let key = try ClaudeDesktopAuthStore.deriveKey(password: password)
        let cookieHost = ".claude.ai"
        let cookiePlaintext = Data(SHA256.hash(data: Data(cookieHost.utf8))) + Data(activeOrganization.utf8)
        let encryptedCookie = try encrypt(cookiePlaintext, key: key)
        let v2Data = try JSONSerialization.data(withJSONObject: v2)
        let encryptedV2 = try encrypt(v2Data, key: key)
        var config: [String: Any] = ["oauth:tokenCacheV2": encryptedV2.base64EncodedString()]
        if let accountUUID { config["lastKnownAccountUuid"] = accountUUID }
        if let v1 {
            let v1Data = try JSONSerialization.data(withJSONObject: v1)
            config["oauth:tokenCache"] = try encrypt(v1Data, key: key).base64EncodedString()
        }
        let configText = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        let configPath = home.appendingPathComponent("Library/Application Support/Claude/config.json").path
        let cookiesPath = home.appendingPathComponent("Library/Application Support/Claude/Cookies").path
        let files = FakeFiles([configPath: configText, cookiesPath: "sqlite-fixture"])
        let sqlite = FakeClaudeDesktopSQLite(value: "encrypted:\(hex(encryptedCookie))")
        let keyReader = FakeClaudeDesktopKeyReader(password: password, requiresInteraction: requiresInteraction)
        let fixtureHome = home
        let fixtureNow = now
        let store = ClaudeDesktopAuthStore(
            files: files,
            sqlite: sqlite,
            keyReader: keyReader,
            homeDirectory: { fixtureHome },
            now: { fixtureNow }
        )
        return DesktopFixture(store: store, files: files, sqlite: sqlite, keyReader: keyReader)
    }

    private func cacheKey(
        organization: String,
        clientID: String? = nil,
        scopes: String = "user:profile user:inference"
    ) -> String {
        "\(clientID ?? self.clientID):\(organization):https://api.anthropic.com:\(scopes)"
    }

    private func tokenEntry(
        _ token: String,
        expiresIn seconds: TimeInterval,
        rateLimitTier: String = "default"
    ) -> [String: Any] {
        [
            "token": token,
            "expiresAt": (now.timeIntervalSince1970 + seconds) * 1000,
            "subscriptionType": "max",
            "rateLimitTier": rateLimitTier
        ]
    }

    private func encrypt(_ plaintext: Data, key: Data) throws -> Data {
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: plaintext.count + kCCBlockSizeAES128)
        var outputLength = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            plaintext.withUnsafeBytes { plaintextBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            plaintextBytes.baseAddress,
                            plaintext.count,
                            outputBytes.baseAddress,
                            capacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw ClaudeDesktopCredentialError.decryptionFailed(status)
        }
        output.count = outputLength
        return Data("v10".utf8) + output
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }

    private func badge(_ lines: [MetricLine], _ label: String) -> String? {
        guard case .badge(_, let text, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return text
    }
}

private final class CountingClaudeAuthKeychain: KeychainAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private let value: String
    private var recorded: [Bool] = []

    init(_ value: String) { self.value = value }

    var calls: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func read(allowInteraction: Bool) -> String {
        lock.lock()
        recorded.append(allowInteraction)
        lock.unlock()
        return value
    }

    func readGenericPassword(service: String) throws -> String? { read(allowInteraction: true) }
    func readGenericPassword(service: String, allowInteraction: Bool) throws -> String? {
        read(allowInteraction: allowInteraction)
    }
    func readGenericPasswordForCurrentUser(service: String) throws -> String? { read(allowInteraction: true) }
    func readGenericPasswordForCurrentUser(service: String, allowInteraction: Bool) throws -> String? {
        read(allowInteraction: allowInteraction)
    }
    func writeGenericPassword(service: String, value: String) throws {}
}

private struct DesktopFixture {
    var store: ClaudeDesktopAuthStore
    var files: FakeFiles
    var sqlite: FakeClaudeDesktopSQLite
    var keyReader: FakeClaudeDesktopKeyReader
}

private final class FakeClaudeDesktopKeyReader: ClaudeDesktopSafeStorageKeyReading, @unchecked Sendable {
    let password: String
    let requiresInteraction: Bool
    private let lock = NSLock()
    private var recordedCalls: [Bool] = []
    var calls: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return recordedCalls
    }

    init(password: String, requiresInteraction: Bool) {
        self.password = password
        self.requiresInteraction = requiresInteraction
    }

    func readPassword(allowInteraction: Bool) throws -> String? {
        lock.lock(); recordedCalls.append(allowInteraction); lock.unlock()
        if requiresInteraction, !allowInteraction {
            throw ClaudeDesktopCredentialError.permissionRequired
        }
        return password
    }
}

private final class CancellingClaudeDesktopKeyReader: ClaudeDesktopSafeStorageKeyReading, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [Bool] = []

    var calls: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return recordedCalls
    }

    func readPassword(allowInteraction: Bool) throws -> String? {
        lock.lock(); recordedCalls.append(allowInteraction); lock.unlock()
        guard allowInteraction else {
            throw ClaudeDesktopCredentialError.permissionRequired
        }
        ProviderRefreshContext.keychainReadCancellationToken?.cancel()
        throw ClaudeDesktopCredentialError.permissionRequired
    }
}

private final class BlockingClaudeDesktopKeyReader: ClaudeDesktopSafeStorageKeyReading, @unchecked Sendable {
    let password: String
    let blockInteraction: Bool
    let silentReadStarted = DispatchSemaphore(value: 0)
    let interactiveReadStarted = DispatchSemaphore(value: 0)
    let allowSilentRead = DispatchSemaphore(value: 0)
    let allowInteractiveRead = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var recordedCalls: [Bool] = []

    var calls: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return recordedCalls
    }

    init(password: String, blockInteraction: Bool) {
        self.password = password
        self.blockInteraction = blockInteraction
    }

    func readPassword(allowInteraction: Bool) throws -> String? {
        lock.lock(); recordedCalls.append(allowInteraction); lock.unlock()
        if allowInteraction == blockInteraction {
            if allowInteraction {
                interactiveReadStarted.signal()
                allowInteractiveRead.wait()
            } else {
                silentReadStarted.signal()
                allowSilentRead.wait()
            }
        }
        if !allowInteraction {
            throw ClaudeDesktopCredentialError.permissionRequired
        }
        return password
    }
}

private final class AccountSwitchingClaudeDesktopKeyReader: ClaudeDesktopSafeStorageKeyReading, @unchecked Sendable {
    let password: String
    let readStarted = DispatchSemaphore(value: 0)
    let allowRead = DispatchSemaphore(value: 0)

    init(password: String) {
        self.password = password
    }

    func readPassword(allowInteraction: Bool) throws -> String? {
        readStarted.signal()
        _ = allowRead.wait(timeout: .now() + 5)
        return password
    }
}

private final class GrantingAfterInteractiveClaudeDesktopKeyReader: ClaudeDesktopSafeStorageKeyReading, @unchecked Sendable {
    let password: String
    let interactiveReadStarted = DispatchSemaphore(value: 0)
    let releaseInteractiveRead = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var authorizationGranted = false
    private var recordedCalls: [Bool] = []

    var calls: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return recordedCalls
    }

    init(password: String) { self.password = password }

    func readPassword(allowInteraction: Bool) throws -> String? {
        lock.lock()
        recordedCalls.append(allowInteraction)
        if allowInteraction {
            lock.unlock()
            interactiveReadStarted.signal()
            _ = releaseInteractiveRead.wait(timeout: .now() + 5)
            lock.lock()
            authorizationGranted = true
            lock.unlock()
            return password
        }
        let isAuthorized = authorizationGranted
        lock.unlock()
        guard isAuthorized else { throw ClaudeDesktopCredentialError.permissionRequired }
        return password
    }
}

private final class StaleFailureClaudeDesktopKeyReader: ClaudeDesktopSafeStorageKeyReading, @unchecked Sendable {
    let firstReadStarted = DispatchSemaphore(value: 0)
    let releaseFirstRead = DispatchSemaphore(value: 0)
    let password: String
    private let lock = NSLock()
    private var recordedCalls: [Bool] = []

    var calls: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return recordedCalls
    }

    init(password: String) { self.password = password }

    func readPassword(allowInteraction: Bool) throws -> String? {
        lock.lock()
        recordedCalls.append(allowInteraction)
        let isFirstCall = recordedCalls.count == 1
        lock.unlock()
        if isFirstCall {
            firstReadStarted.signal()
            _ = releaseFirstRead.wait(timeout: .now() + 5)
            throw ClaudeDesktopCredentialError.keychainFailure(-25293)
        }
        return password
    }
}

private struct ClaudeDesktopUnreadableConfigFiles: TextFileAccessing {
    let path: String

    func exists(_ candidate: String) -> Bool { candidate == path }
    func readTextIfPresent(_ candidate: String) throws -> String? {
        guard exists(candidate) else { return nil }
        throw CocoaError(.fileReadNoPermission)
    }
    func readText(_ candidate: String) throws -> String { throw CocoaError(.fileReadNoPermission) }
    func writeText(_ candidate: String, _ text: String) throws { throw CocoaError(.fileWriteNoPermission) }
    func remove(_ candidate: String) throws { throw CocoaError(.fileWriteNoPermission) }
}

private struct UnreadableClaudeDesktopSQLite: SQLiteAccessing {
    func queryValue(path: String, sql: String) throws -> String? {
        throw CocoaError(.fileReadNoPermission)
    }

    func execute(path: String, sql: String) throws {
        throw CocoaError(.fileReadNoPermission)
    }
}

private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.001)
    }
    return condition()
}

private final class FakeClaudeDesktopSQLite: SQLiteAccessing, @unchecked Sendable {
    let value: String?

    init(value: String?) {
        self.value = value
    }

    func queryValue(path: String, sql: String) throws -> String? {
        value
    }

    func execute(path: String, sql: String) throws {}
}

private enum SafeStorageLoadFailure: Error {
    case failed
}

private final class SafeStorageLoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class SafeStorageActionValidity: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Bool

    init(_ current: Bool) { self.current = current }

    var isCurrent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func setCurrent(_ current: Bool) {
        lock.lock()
        self.current = current
        lock.unlock()
    }
}
