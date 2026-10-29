import XCTest
@testable import QuotaBar

/// The launch account pass end to end: observer outcomes → account registry records → the per-card
/// identity map consumed by the snapshot cache stamp and the bare-id resolver.
@MainActor
final class ProviderAccountAssemblyTests: XCTestCase {
    private func makeScratchDefaults() -> UserDefaults {
        let suiteName = "OpenUsageTests.ProviderAccountAssembly.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    func testResolvedFamiliesFeedIdentityKeysAndTheRegistry() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                // Claude resolved at the default home; Codex has credentials that name no account.
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1", "emailAddress": "dev@example.com"}}"#,
                "/Users/dev/.codex/auth.json": #"{"tokens": {"access_token": "at-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = ProviderAccountAssembly.make(observer: observer, accountsStore: store)

        XCTAssertEqual(assembly.identityKeysByCard, ["claude": "acct-1"])
        // The registry recorded the resolved account under the bare id, holding the default badge.
        let record = try XCTUnwrap(store.defaultBadgeHolder(family: "claude"))
        XCTAssertEqual(record.id, "claude")
        XCTAssertEqual(record.label, "dev@example.com")
        XCTAssertEqual(record.sources.map(\.kind), [.defaultHome])
        // An unresolved family claims no account: no record, no identity key.
        XCTAssertNil(store.defaultBadgeHolder(family: "codex"))
    }

    /// A family whose home facts aren't readable this launch (first Finder/Dock launch racing a
    /// slow shell) is left out of the pass entirely: not observed, not reconciled — while a family
    /// whose home override is already in the process environment still resolves.
    func testFamiliesOutsideThePassAreNeitherObservedNorReconciled() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1"}}"#,
                "/Users/dev/.codex/auth.json": #"{"tokens": {"access_token": "at-1", "account_id": "CODEX-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = ProviderAccountAssembly.make(observer: observer, accountsStore: store, families: ["codex"])

        XCTAssertEqual(assembly.identityKeysByCard, ["codex": "codex-1"])
        XCTAssertNil(store.defaultBadgeHolder(family: "claude"), "an out-of-pass family must not be reconciled")
    }

    func testNothingObservedLeavesRegistryAndKeysEmpty() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([:]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = ProviderAccountAssembly.make(observer: observer, accountsStore: store)

        XCTAssertTrue(assembly.identityKeysByCard.isEmpty)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNil(defaults.data(forKey: ProviderAccountsStore.storageKey), "no observations, no write")
    }

    func testDefaultIdentitySourceScanRunsOffMainActor() async {
        let files = ThreadRecordingAccountFiles([
            "/Users/dev/.claude.json": #"{"oauthAccount":{"accountUuid":"ACCT-1","emailAddress":"dev@example.com"}}"#,
            "/Users/dev/.codex/auth.json": #"{"tokens":{"access_token":"token","account_id":"CODEX-1"}}"#
        ])
        let keychain = ThreadRecordingAccountKeychain()
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: files,
            keychain: keychain,
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let discovery = await loadOffMainActor {
            ProviderAccountAssembly.scan(
                observer: observer,
                families: ["claude", "codex"]
            )
        }

        XCTAssertEqual(files.lastReadWasOnMainThread, false)
        XCTAssertEqual(keychain.existenceProbeWasOnMainThread, false)
        guard case .resolved(let identityKey, _, _)? = discovery.defaultOutcomes.first(where: {
            $0.family == "claude"
        })?.outcome else {
            return XCTFail("expected Claude's source identity to remain resolved")
        }
        XCTAssertEqual(identityKey, "acct-1")
        guard case .resolved(let codexIdentity, _, _)? = discovery.defaultOutcomes.first(where: {
            $0.family == "codex"
        })?.outcome else {
            return XCTFail("expected Codex's source identity to remain resolved")
        }
        XCTAssertEqual(codexIdentity, "codex-1")
    }

    func testRegisteredCodexHomesStayInThePassWhenShellFactsAreUnavailable() {
        let families = ProviderAccountAssembly.familiesForAccountPass(
            shellFactsReadable: false,
            processEnvironment: [:],
            registeredCodexHomes: ["/Users/dev/codex-b"]
        )

        XCTAssertEqual(families, ["codex"])
    }

    func testProcessConfiguredCodexHomesStayInThePassWhenShellFactsAreUnavailable() {
        let families = ProviderAccountAssembly.familiesForAccountPass(
            shellFactsReadable: false,
            processEnvironment: ["OPENUSAGE_CODEX_HOMES": "/Users/dev/codex-b"],
            registeredCodexHomes: []
        )

        XCTAssertEqual(families, ["codex"])
    }

    func testExplicitClaudeEnableRetriesDiscoveryWhenShellFactsAreUnavailable() {
        let families = ProviderAccountAssembly.familiesForAccountPass(
            shellFactsReadable: false,
            processEnvironment: [:],
            registeredCodexHomes: [],
            forceClaudeAccountDiscovery: true
        )

        XCTAssertTrue(families.contains("claude"))
    }

    func testClaudeOmittedFromLaunchPassIsMarkedForRetryOnEnable() {
        let discovery = ProviderAccountAssembly.scan(
            observer: DefaultAccountObserver(
                environment: FakeEnvironment([:]),
                files: FakeFiles([:]),
                keychain: FakeKeychain(nil),
                homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
            ),
            families: ["codex"]
        )

        XCTAssertTrue(discovery.didSkipClaudeDesktopDiscovery)
    }
}

private final class ThreadRecordingAccountFiles: TextFileAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private let contents: [String: String]
    private var readWasOnMainThread: Bool?

    init(_ contents: [String: String]) {
        self.contents = contents
    }

    var lastReadWasOnMainThread: Bool? {
        lock.lock(); defer { lock.unlock() }
        return readWasOnMainThread
    }

    func exists(_ path: String) -> Bool {
        contents[path] != nil
    }

    func readTextIfPresent(_ path: String) throws -> String? {
        lock.lock()
        readWasOnMainThread = Thread.isMainThread
        lock.unlock()
        return contents[path]
    }

    func readText(_ path: String) throws -> String {
        lock.lock()
        readWasOnMainThread = Thread.isMainThread
        lock.unlock()
        return contents[path] ?? ""
    }

    func writeText(_ path: String, _ text: String) throws {}

    func remove(_ path: String) throws {}
}

private final class ThreadRecordingAccountKeychain: KeychainAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var probeWasOnMainThread: Bool?

    var existenceProbeWasOnMainThread: Bool? {
        lock.lock(); defer { lock.unlock() }
        return probeWasOnMainThread
    }

    func readGenericPassword(service: String) throws -> String? { nil }

    func writeGenericPassword(service: String, value: String) throws {}

    func genericPasswordExists(service: String) -> Bool? {
        lock.lock()
        probeWasOnMainThread = Thread.isMainThread
        lock.unlock()
        return false
    }
}
