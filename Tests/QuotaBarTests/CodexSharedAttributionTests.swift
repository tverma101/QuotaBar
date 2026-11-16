import XCTest
@testable import QuotaBar

/// When 2+ CodexRouter account homes exist, the anti-double-count rule keeps the shared `~/.codex`
/// tree from being scanned by *managed* cards. The default-anchored card instead scans it with
/// per-file attribution (`session_meta.creator_account_id`), so rollouts written by either account
/// land on their own card — including rollouts from tools that bypass the router (e.g. T3 Code
/// running Codex direct-to-OpenAI). Files without the marker stay with the default-anchored card.
@MainActor
final class CodexSharedAttributionTests: XCTestCase {
    private func makeUserHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-attribution-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    private func sessionMeta(creator: String?) -> String {
        if let creator {
            return #"{"timestamp":"2026-11-12T00:00:00.000Z","type":"session_meta","payload":{"creator_account_id":"\#(creator)","session_id":"s","id":"s"}}"#
        }
        return #"{"timestamp":"2026-11-12T00:00:00.000Z","type":"session_meta","payload":{"session_id":"s","id":"s"}}"#
    }

    private func writeRollout(_ home: URL, relativePath: String, creator: String?) throws {
        let url = home.appendingPathComponent("sessions/\(relativePath)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sessionMeta(creator: creator).write(to: url, atomically: true, encoding: .utf8)
    }

    private func normalize(_ url: URL) -> String {
        CodexLogUsageScanner.realpathString(url.path)
    }

    private func attributed(
        homes: [URL],
        homeDirectory: URL,
        identity: String,
        keepsUnattributed: Bool
    ) -> [String] {
        CodexLogUsageScanner.sessionFiles(
            homes: homes,
            peerHomes: [],
            homeDirectory: { homeDirectory },
            sharedAttribution: CodexLogUsageScanner.SharedAttribution(
                home: normalize(homeDirectory.appendingPathComponent(".codex")),
                identity: identity,
                keepsUnattributed: keepsUnattributed
            )
        )
        .map { CodexLogUsageScanner.realpathString($0.path) }
        .sorted()
    }

    func testDefaultCardKeepsOwnAndUnattributedRolloutsDropsForeign() throws {
        let home = try makeUserHome()
        let defaultCodex = home.appendingPathComponent(".codex", isDirectory: true)
        try writeRollout(defaultCodex, relativePath: "2026/11/12/a.jsonl", creator: "ACCOUNT-A")
        try writeRollout(defaultCodex, relativePath: "2026/11/12/b.jsonl", creator: "ACCOUNT-B")
        try writeRollout(defaultCodex, relativePath: "2026/11/12/u.jsonl", creator: nil)

        let kept = attributed(homes: [defaultCodex], homeDirectory: home, identity: "account-a", keepsUnattributed: true)

        XCTAssertEqual(
            kept,
            [
                normalize(defaultCodex.appendingPathComponent("sessions/2026/11/12/a.jsonl")),
                normalize(defaultCodex.appendingPathComponent("sessions/2026/11/12/u.jsonl")),
            ],
            "the default-anchored card keeps its own account's rollouts and the ones with no marker; got \(kept)"
        )
    }

    func testManagedCardDropsUnattributedAndForeignRollouts() throws {
        let home = try makeUserHome()
        let defaultCodex = home.appendingPathComponent(".codex", isDirectory: true)
        try writeRollout(defaultCodex, relativePath: "2026/11/12/a.jsonl", creator: "ACCOUNT-A")
        try writeRollout(defaultCodex, relativePath: "2026/11/12/b.jsonl", creator: "ACCOUNT-B")
        try writeRollout(defaultCodex, relativePath: "2026/11/12/u.jsonl", creator: nil)

        let kept = attributed(homes: [defaultCodex], homeDirectory: home, identity: "account-b", keepsUnattributed: false)

        XCTAssertEqual(
            kept,
            [normalize(defaultCodex.appendingPathComponent("sessions/2026/11/12/b.jsonl"))],
            "a managed card keeps only its own account's rollouts; got \(kept)"
        )
    }

    func testAttributionIsCaseInsensitive() throws {
        let home = try makeUserHome()
        let defaultCodex = home.appendingPathComponent(".codex", isDirectory: true)
        try writeRollout(defaultCodex, relativePath: "2026/11/12/a.jsonl", creator: "DEADBEEF-CAFE-1234")

        let kept = attributed(homes: [defaultCodex], homeDirectory: home, identity: "deadbeef-cafe-1234", keepsUnattributed: false)

        XCTAssertEqual(kept, [normalize(defaultCodex.appendingPathComponent("sessions/2026/11/12/a.jsonl"))])
    }

    func testFilesOutsideSharedHomePassThroughUntouched() throws {
        let home = try makeUserHome()
        let defaultCodex = home.appendingPathComponent(".codex", isDirectory: true)
        let managed = home.appendingPathComponent("router/acct_x", isDirectory: true)
        try writeRollout(managed, relativePath: "2026/11/12/c.jsonl", creator: "ACCOUNT-A")

        let kept = attributed(
            homes: [defaultCodex, managed],
            homeDirectory: home,
            identity: "account-a",
            keepsUnattributed: true
        )

        XCTAssertEqual(
            kept,
            [normalize(managed.appendingPathComponent("sessions/2026/11/12/c.jsonl"))],
            "attribution must filter only files under the shared default home"
        )
    }

    func testPeekCreatorAccountIDHandlesMarkerSpacingAndAbsence() throws {
        let home = try makeUserHome()
        let file = home.appendingPathComponent("rollout.jsonl")
        let compact = #"{"type":"session_meta","payload":{"creator_account_id":"ACCOUNT-A","session_id":"s"}}"#
        try compact.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(CodexLogUsageScanner.peekCreatorAccountID(path: file.path), "ACCOUNT-A")

        let absent = #"{"type":"session_meta","payload":{"session_id":"s"}}"#
        try absent.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNil(CodexLogUsageScanner.peekCreatorAccountID(path: file.path))

        XCTAssertNil(CodexLogUsageScanner.peekCreatorAccountID(path: home.appendingPathComponent("missing.jsonl").path))
    }

    // MARK: - Assembly: the default-anchored card keeps the shared home with attribution

    func testTwoRouterHomesKeepSharedDefaultHomeOnlyForDefaultAnchoredCard() throws {
        let home = try makeUserHome()

        // The shared default home: a live CLI session for account-a.
        let defaultAuth = home.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(at: defaultAuth.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(codexAuth(accountID: "ACCOUNT-A", accessToken: "cli-token").utf8).write(to: defaultAuth)

        // Two router homes for two different accounts.
        let routerA = home.appendingPathComponent(".codex/codex-router/chatgpt-accounts/acct_AAA", isDirectory: true)
        let routerB = home.appendingPathComponent(".codex/codex-router/chatgpt-accounts/acct_BBB", isDirectory: true)
        for (dir, id) in [(routerA, "ACCOUNT-A"), (routerB, "ACCOUNT-B")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(codexAuth(accountID: id, accessToken: "router-\(id)-token").utf8).write(to: dir.appendingPathComponent("auth.json"))
        }

        let defaultsName = "OpenUsageTests.AttributionAssembly.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: defaultsName) }
        var fileMap: [String: String] = [:]
        let auth = codexAuth(accountID: "ACCOUNT-A", accessToken: "cli-token")
        // Register both path spellings the resolver might hand the observer (this volume spells
        // "/var" and "/private/var" differently).
        fileMap[normalize(defaultAuth)] = auth
        fileMap[defaultAuth.path] = auth
        for (dir, id) in [(routerA, "ACCOUNT-A"), (routerB, "ACCOUNT-B")] {
            let authFile = dir.appendingPathComponent("auth.json")
            let text = codexAuth(accountID: id, accessToken: "router-\(id)-token")
            fileMap[normalize(authFile)] = text
            fileMap[authFile.path] = text
        }
        let store = ProviderAccountsStore(defaults: defaults)
        let files = FakeFiles(fileMap)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: files,
            keychain: FakeKeychain(nil),
            homeDirectory: { home }
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: store,
            families: ["codex"]
        )

        let primary = try XCTUnwrap(assembly.codexCards.first { $0.identityKey == "account-a" })
        let secondary = try XCTUnwrap(assembly.codexCards.first { $0.identityKey == "account-b" })

        let normalizedDefault = try XCTUnwrap(
            CodexAccountRegistrationStore.normalizedHome(home.appendingPathComponent(".codex").path, homeDirectory: home)
        )
        let normalizedRouterA = try XCTUnwrap(
            CodexAccountRegistrationStore.normalizedHome(routerA.path, homeDirectory: home)
        )
        let normalizedRouterB = try XCTUnwrap(
            CodexAccountRegistrationStore.normalizedHome(routerB.path, homeDirectory: home)
        )

        // Default-anchored card: shared home re-included and flagged for attributed scanning.
        XCTAssertEqual(primary.attributionSharedHome, normalizedDefault)
        XCTAssertTrue(primary.logHomes.contains(normalizedDefault), "primary logHomes: \(primary.logHomes)")
        XCTAssertTrue(primary.logHomes.contains(normalizedRouterA))

        // Managed card: shared home stays excluded, no attribution.
        XCTAssertNil(secondary.attributionSharedHome)
        XCTAssertEqual(secondary.logHomes, [normalizedRouterB])
    }

    private func codexAuth(accountID: String, accessToken: String) -> String {
        #"{"tokens":{"access_token":"\#(accessToken)","account_id":"\#(accountID)"}}"#
    }
}
