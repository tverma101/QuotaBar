import XCTest
@testable import OpenUsage

final class ClaudeDesktopTokenCacheTests: XCTestCase {
    private let account = "14bca8dc-bac8-43e3-8fe5-102f5bc32a9f"
    private let otherAccount = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    private let client = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let organization = "f758c524-4c33-432b-af68-541d88490a5b"
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testLegacyKeyStillSelects() throws {
        XCTAssertEqual(try available(select(v2: [legacyKey(): token("legacy")])).accessToken, "legacy")
    }

    func testScopedKeySelectsForActiveAccount() throws {
        let key = "acct:\(account.uppercased())|\(client.uppercased()):\(organization.uppercased()):https://api.anthropic.com:user:profile"
        XCTAssertEqual(
            try available(select(activeAccountUUID: account, v2: [key: token("scoped")])).accessToken,
            "scoped"
        )
    }

    func testMalformedScopedKeysAreIgnored() {
        let malformed = [
            "acct:|\(legacyKey())",
            "acct:not-a-uuid|\(legacyKey())",
            "acct:\(account)\(legacyKey())",
            "acct:\(account)||\(legacyKey())",
            "acct:\(account)|acct:\(account)|\(legacyKey())",
            "acct:\(account)|",
            "acct:\(account)|not-a-client:\(organization):https://api.anthropic.com:user:profile",
        ]
        for key in malformed {
            XCTAssertEqual(select(v2: [key: token("nope")]), .notFound, "expected notFound for \(key)")
        }
    }

    func testWrongApiHostIgnored() {
        let bad = scopedKey().replacingOccurrences(
            of: "https://api.anthropic.com", with: "https://example.com"
        )
        XCTAssertEqual(select(v2: [bad: token("nope")]), .notFound)
    }

    func testScopedEntryOutranksLegacyAlias() throws {
        let cache = [legacyKey(): token("old", expiresIn: 86_400), scopedKey(): token("current")]
        XCTAssertEqual(try available(select(activeAccountUUID: account, v2: cache)).accessToken, "current")
    }

    func testScopedDeletionMarkerSuppressesLegacy() {
        let cache: [String: Any] = [legacyKey(): token("old"), scopedKey(): NSNull()]
        XCTAssertEqual(select(activeAccountUUID: account, v2: cache), .notFound)
    }

    func testForeignAccountScopedKeyDoesNotSuppressLegacy() throws {
        let foreignKey = "acct:\(otherAccount)|\(legacyKey())"
        let result = select(
            activeAccountUUID: account,
            v2: [foreignKey: token("foreign"), legacyKey(): token("legacy")]
        )
        XCTAssertEqual(try available(result).accessToken, "legacy")
    }

    func testExpiredScopedDoesNotReviveLegacyOrV1() {
        let result = select(
            activeAccountUUID: account,
            v2: [scopedKey(): token("expired", expiresIn: -1), legacyKey(): token("legacy")],
            v1: [legacyKey(): token("v1")]
        )
        guard case .stale = result else { return XCTFail("expected stale, got \(result)") }
    }

    func testInvalidScopedEntryDoesNotReviveLegacyAlias() {
        let result = select(
            activeAccountUUID: account,
            v2: [scopedKey(): ["token": " "], legacyKey(): token("legacy")]
        )
        guard case .invalid = result else { return XCTFail("expected invalid, got \(result)") }
    }

    func testFullScopeProductionClientOutranksLongerLivedOthers() throws {
        let productionClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        let profileOnly = "\(productionClientID):\(organization):https://api.anthropic.com:user:profile"
        let full = "\(productionClientID):\(organization):https://api.anthropic.com:user:profile user:inference"
        let otherClient = "a473d7bb-17ac-43a7-abc0-a1343d7c2805"
        let otherFull = "\(otherClient):\(organization):https://api.anthropic.com:user:profile user:inference"
        let result = select(
            v2: [
                profileOnly: token("profile", expiresIn: 999_999),
                otherFull: token("other-full", expiresIn: 999_999),
                full: token("prod-full", expiresIn: 300),
            ]
        )
        XCTAssertEqual(try available(result).accessToken, "prod-full")
    }

    func testScopedFullScopeOutranksScopedProfileOnly() throws {
        let result = select(
            activeAccountUUID: account,
            v2: [
                scopedKey(scopes: "user:profile"): token("profile-only", expiresIn: 86_400),
                scopedKey(): token("full-scope", expiresIn: 300),
            ]
        )
        XCTAssertEqual(try available(result).accessToken, "full-scope")
    }

    // MARK: - helpers

    private func select(
        activeOrganization: String? = nil,
        activeAccountUUID: String? = nil,
        v2: [String: Any]?,
        v1: [String: Any]? = nil
    ) -> ClaudeDesktopAuthStore.Selection {
        ClaudeDesktopAuthStore.selectCredential(
            activeOrganization: activeOrganization ?? organization,
            activeAccountUUID: activeAccountUUID,
            v2: v2,
            v1: v1,
            now: now
        )
    }

    private func available(_ selection: ClaudeDesktopAuthStore.Selection) throws -> ClaudeOAuth {
        guard case .available(let oauth) = selection else {
            XCTFail("expected available, got \(selection)")
            throw NSError(domain: "test", code: 1)
        }
        return oauth
    }

    private func legacyKey(organization: String? = nil, scopes: String = "user:profile user:inference") -> String {
        "\(client):\(organization ?? self.organization):https://api.anthropic.com:\(scopes)"
    }

    private func scopedKey(organization: String? = nil, scopes: String = "user:profile user:inference") -> String {
        "acct:\(account)|\(legacyKey(organization: organization, scopes: scopes))"
    }

    private func token(_ value: String, expiresIn: Double = 3600) -> [String: Any] {
        [
            "token": value,
            "expiresAt": (now.timeIntervalSince1970 + expiresIn) * 1000,
            "subscriptionType": "pro",
            "rateLimitTier": "default_claude_ai",
        ]
    }
}

extension ClaudeDesktopAuthStore.Selection: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.stale, .stale), (.notFound, .notFound), (.invalid, .invalid):
            return true
        case (.available(let a), .available(let b)):
            return a == b
        default:
            return false
        }
    }
}
