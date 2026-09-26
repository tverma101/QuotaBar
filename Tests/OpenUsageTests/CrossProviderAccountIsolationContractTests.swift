import Foundation
import XCTest
@testable import OpenUsage

/// Cross-provider identity contracts for machines signed into different accounts at the same time.
/// Claude and Codex are independent provider families; a login in one must never relabel or inherit
/// the other's card/cache identity.
@MainActor
final class CrossProviderAccountIsolationContractTests: XCTestCase {
    func testClaudeAccountAAndCodexAccountBRemainSeparateCardIdentities() throws {
        let suiteName = "OpenUsageTests.CrossProviderAccountIsolation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.claude.json": #"{"oauthAccount":{"accountUuid":"CLAUDE-A","emailAddress":"a@example.com"}}"#,
                "/Users/dev/.codex/auth.json": #"{"tokens":{"access_token":"codex-token","account_id":"CODEX-B"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = ProviderAccountAssembly.make(observer: observer, accountsStore: store)

        XCTAssertEqual(assembly.identityKeysByCard["claude"], "claude-a")
        XCTAssertEqual(assembly.identityKeysByCard["codex"], "codex-b")
        XCTAssertNotEqual(assembly.identityKeysByCard["claude"], assembly.identityKeysByCard["codex"])
        XCTAssertEqual(store.defaultBadgeHolder(family: "claude")?.label, "a@example.com")
        XCTAssertNotNil(store.defaultBadgeHolder(family: "codex"))
    }

    func testSameRawAccountIDAcrossClaudeAndCodexStillLivesInSeparateFamilies() throws {
        let suiteName = "OpenUsageTests.CrossProviderSameID.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.claude.json": #"{"oauthAccount":{"accountUuid":"SHARED-ID","emailAddress":"claude@example.com"}}"#,
                "/Users/dev/.codex/auth.json": #"{"tokens":{"access_token":"codex-token","account_id":"SHARED-ID"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = ProviderAccountAssembly.make(observer: observer, accountsStore: store)

        XCTAssertEqual(assembly.identityKeysByCard["claude"], "shared-id")
        XCTAssertEqual(assembly.identityKeysByCard["codex"], "shared-id")
        XCTAssertNotNil(store.defaultBadgeHolder(family: "claude"))
        XCTAssertNotNil(store.defaultBadgeHolder(family: "codex"))
        XCTAssertNotEqual(
            store.defaultBadgeHolder(family: "claude")?.id,
            store.defaultBadgeHolder(family: "codex")?.id,
            "provider family is part of card identity even when providers expose the same raw account id"
        )
    }
}
