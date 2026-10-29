import XCTest
@testable import QuotaBar

final class GrokAuthStoreTests: XCTestCase {
    func testReadsTokenExpiryFromJWT() {
        let store = GrokAuthStore(now: { OpenUsageISO8601.date(from: "2026-02-02T00:00:00.000Z")! })
        let token = makeJWT(exp: 1_770_000_000)

        let expiry = store.tokenExpiresAt(token)

        XCTAssertEqual(expiry?.timeIntervalSince1970, 1_770_000_000)
    }

    func testLoadsAuthCandidatesFromGrokAuthFile() throws {
        let files = FakeFiles([
            GrokAuthStore.authPath: #"{"https://auth.x.ai::client":{"key":"token","refresh_token":"refresh"}}"#
        ])
        let store = GrokAuthStore(files: files)

        let candidates = try store.loadAuthCandidates()

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.token, "token")
        XCTAssertEqual(candidates.first?.entryKey, "https://auth.x.ai::client")
    }

    func testUnreadablePresentAuthFileThrowsCredentialAccessError() {
        let store = GrokAuthStore(files: UnreadableFiles(present: [GrokAuthStore.authPath]))

        XCTAssertThrowsError(try store.loadAuthCandidates()) { error in
            XCTAssertTrue(error is GrokCredentialsUnreadableError)
            XCTAssertEqual((error as? CategorizedError)?.errorCategory, .credentialAccess)
        }
    }

    func testMalformedPresentAuthFileThrowsInvalidAuth() {
        let store = GrokAuthStore(files: FakeFiles([GrokAuthStore.authPath: "not json"]))

        XCTAssertThrowsError(try store.loadAuthCandidates()) { error in
            XCTAssertEqual(error as? GrokAuthError, .invalidAuth)
        }
    }

    func testSaveRefusesToOverwriteACorruptAuthFile() throws {
        // A present-but-corrupt auth.json must NOT be silently rebuilt from in-memory state (which
        // would drop other accounts' entries). save() must throw and leave the file untouched.
        let validJSON = #"{"https://auth.x.ai::client":{"key":"token","refresh_token":"refresh","expires_at":"2026-07-01T00:00:00.000Z"}}"#
        let files = FakeFiles([GrokAuthStore.authPath: validJSON])
        let store = GrokAuthStore(files: files, now: { OpenUsageISO8601.date(from: "2026-02-02T00:00:00.000Z")! })
        var state = try XCTUnwrap(store.loadAuthCandidates().first)
        state.entry.key = "rotated-token"

        // Corrupt the file on disk, then attempt to persist the rotation.
        let corrupt = "{ not valid json"
        files.files[GrokAuthStore.authPath] = corrupt

        XCTAssertThrowsError(try store.save(state))
        XCTAssertEqual(files.files[GrokAuthStore.authPath], corrupt, "corrupt file must be left untouched, not clobbered")
    }

    func testSaveDoesNotOverwritePresentUnreadableAuthFile() {
        let key = "https://auth.x.ai::client"
        let entry = GrokAuthEntry(
            key: "rotated-token",
            refreshToken: "refresh",
            refresh: nil,
            idToken: nil,
            expiresAt: nil,
            expires: nil,
            oidcClientID: nil
        )
        let otherEntry = GrokAuthEntry(
            key: "other-account-token",
            refreshToken: nil,
            refresh: nil,
            idToken: nil,
            expiresAt: nil,
            expires: nil,
            oidcClientID: nil
        )
        let state = GrokAuthState(
            auth: [key: entry, "https://auth.x.ai::other": otherEntry],
            entryKey: key,
            entry: entry,
            token: "rotated-token"
        )
        let files = UnreadableTrackingFiles()
        let store = GrokAuthStore(files: files)

        XCTAssertThrowsError(try store.save(state)) { error in
            XCTAssertTrue(error is GrokCredentialsUnreadableError)
            XCTAssertEqual((error as? CategorizedError)?.errorCategory, .credentialAccess)
        }
        XCTAssertEqual(files.writeCount, 0, "an unreadable multi-account file must never be replaced")
    }
}

private final class UnreadableTrackingFiles: TextFileAccessing, @unchecked Sendable {
    private(set) var writeCount = 0

    func exists(_ path: String) -> Bool { path == GrokAuthStore.authPath }

    func readText(_ path: String) throws -> String {
        throw CocoaError(.fileReadNoPermission)
    }

    func readTextIfPresent(_ path: String) throws -> String? {
        throw CocoaError(.fileReadNoPermission)
    }

    func writeText(_ path: String, _ text: String) throws { writeCount += 1 }
    func remove(_ path: String) throws {}
}

private func makeJWT(exp: Int) -> String {
    let header = base64URL(Data(#"{"alg":"none"}"#.utf8))
    let payload = base64URL(Data(#"{"exp":\#(exp)}"#.utf8))
    return "\(header).\(payload).signature"
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
