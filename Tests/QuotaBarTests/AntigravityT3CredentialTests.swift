import XCTest
@testable import QuotaBar

/// T3 Code runs Antigravity through private ACP instances: their conversation stores and file-based
/// OAuth credentials live under `~/.t3/userdata/providers/antigravity/<key>/antigravity-acp`, outside
/// `~/.gemini`. These tests pin the discovery, the credential boundary, and the quota fallback that
/// keeps meters fresh when the Keychain ACL blocks a rebuilt app.
final class AntigravityT3CredentialTests: XCTestCase {
    private var temporaryHomes: [URL] = []

    override func tearDownWithError() throws {
        for home in temporaryHomes {
            try? FileManager.default.removeItem(at: home)
        }
        temporaryHomes.removeAll()
        KeychainPermissionGate.shared.reset(KeychainItemKey(
            service: AntigravityAuthStore.keychainService,
            account: AntigravityAuthStore.keychainAccount
        ))
    }

    private func makeHome() throws -> URL {
        // Canonicalize like the discovery code does (/var → /private/var on macOS).
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .resolvingSymlinksInPath()
            .appendingPathComponent("AntigravityT3Tests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        temporaryHomes.append(home)
        return home
    }

    @discardableResult
    private func makeProfile(
        home: URL,
        key: String,
        conversations: Bool = true,
        credential: String? = nil,
        activity: Date? = nil
    ) throws -> URL {
        let profile = home
            .appendingPathComponent(AntigravityT3Support.profilesRootSubpath, isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
            .appendingPathComponent("antigravity-acp", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        if conversations {
            let directory = profile.appendingPathComponent("conversations", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let activity {
                try FileManager.default.setAttributes([.modificationDate: activity], ofItemAtPath: directory.path)
            }
        }
        if let credential {
            try credential.write(
                to: profile.appendingPathComponent(AntigravityT3Support.credentialFileName),
                atomically: true,
                encoding: .utf8
            )
        }
        return profile
    }

    private static func credentialJSON(refresh: String = "file-refresh", clientID: String = "file-client") -> String {
        """
        {"client_id":"\(clientID)","client_secret":"file-secret","refresh_token":"\(refresh)",\
        "token_uri":"https://oauth2.googleapis.com/token","scopes":["https://www.googleapis.com/auth/aicode"],\
        "project_id":"file-project"}
        """
    }

    // MARK: - Discovery

    func testConversationDirectoriesDiscoverPrivateInstancesAndDedupeAliases() throws {
        let home = try makeHome()
        let first = try makeProfile(home: home, key: "aaa")
        try makeProfile(home: home, key: "bbb", conversations: false)
        let third = try makeProfile(home: home, key: "ccc")
        // An alias root pointing at the same conversations must be counted once.
        let aliasParent = home.appendingPathComponent(AntigravityT3Support.profilesRootSubpath, isDirectory: true)
            .appendingPathComponent("ddd", isDirectory: true)
        try FileManager.default.createDirectory(at: aliasParent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: aliasParent.appendingPathComponent("antigravity-acp"),
            withDestinationURL: first
        )

        let directories = try AntigravityT3Support.conversationDirectories(home: home)
        XCTAssertEqual(directories, [
            first.appendingPathComponent("conversations").resolvingSymlinksInPath().path,
            third.appendingPathComponent("conversations").resolvingSymlinksInPath().path
        ].sorted())
    }

    func testMissingProfilesRootIsNormalAbsence() throws {
        let home = try makeHome()
        XCTAssertEqual(try AntigravityT3Support.conversationDirectories(home: home), [])
        XCTAssertEqual(AntigravityT3Support.credentialFiles(home: home), [])
    }

    /// Production history is the native store only: config parity roots and T3 profiles are valid
    /// fixtures for their own tests but are never discovered for this app's usage.
    func testScannerDefaultDiscoveryIncludesOnlyTheNativeRoot() throws {
        let home = try makeHome()
        let geminiConversations = home
            .appendingPathComponent(".gemini/antigravity/conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: geminiConversations, withIntermediateDirectories: true)
        let configConversations = home
            .appendingPathComponent(".config/antigravity/conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: configConversations, withIntermediateDirectories: true)
        _ = try makeProfile(home: home, key: "aaa")

        let discovery = try AntigravityDbUsageScanner.discoverAllConversationDirectories(home: home)
        XCTAssertTrue(discovery.failures.isEmpty)
        XCTAssertEqual(discovery.directories, [geminiConversations.resolvingSymlinksInPath().path])
    }

    func testCredentialFilesOrderMostRecentlyActiveFirst() throws {
        let home = try makeHome()
        let old = try makeProfile(
            home: home, key: "aaa",
            credential: Self.credentialJSON(refresh: "old-refresh"),
            activity: Date(timeIntervalSince1970: 1_000)
        )
        let active = try makeProfile(
            home: home, key: "bbb",
            credential: Self.credentialJSON(refresh: "active-refresh"),
            activity: Date(timeIntervalSince1970: 2_000)
        )
        try makeProfile(home: home, key: "ccc") // no credential file

        let files = AntigravityT3Support.credentialFiles(home: home)
        XCTAssertEqual(files.map(\.lastPathComponent), [
            AntigravityT3Support.credentialFileName,
            AntigravityT3Support.credentialFileName
        ])
        XCTAssertEqual(files.first?.deletingLastPathComponent().path, active.path)
        XCTAssertEqual(files.last?.deletingLastPathComponent().path, old.path)
    }

    // MARK: - Credential boundary

    func testFileCredentialParsingRequiresGoogleTokenURIAndClientPair() throws {
        let files = FakeFiles()
        let store = AntigravityAuthStore(keychain: FakeKeychain(nil), files: files, fileCredentialPaths: { [] })
        let path = "/fixture/acp_token.json"

        files.files[path] = Self.credentialJSON()
        let credential = try XCTUnwrap(store.loadFileCredential(atPath: path))
        XCTAssertEqual(credential.refreshToken, "file-refresh")
        XCTAssertEqual(credential.clientID, "file-client")
        XCTAssertEqual(credential.clientSecret, "file-secret")
        XCTAssertEqual(credential.projectID, "file-project")
        XCTAssertEqual(credential.sourcePath, path)

        // A refresh token must never be sent to an arbitrary endpoint.
        files.files[path] = Self.credentialJSON().replacingOccurrences(
            of: "https://oauth2.googleapis.com/token", with: "https://example.com/token"
        )
        XCTAssertNil(store.loadFileCredential(atPath: path))

        files.files[path] = #"{"refresh_token":"r","token_uri":"https://oauth2.googleapis.com/token"}"#
        XCTAssertNil(store.loadFileCredential(atPath: path), "the issuing client pair is required")

        files.files[path] = "not json"
        XCTAssertNil(store.loadFileCredential(atPath: path))
    }

    func testDerivedCacheBindsToFileRefreshCredential() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let files = FakeFiles()
        let store = AntigravityAuthStore(
            keychain: FakeKeychain(nil), files: files, now: { now }, fileCredentialPaths: { [] }
        )
        let cached = try store.cacheToken(
            "file-access", expiresIn: 3600, matchingRefreshToken: "file-refresh",
            revalidate: { "file-refresh" }
        )
        XCTAssertTrue(cached)
        XCTAssertEqual(store.loadCachedToken(matchingRefreshToken: "file-refresh"), "file-access")
        // A different instance's credential must not reuse the derived token.
        XCTAssertNil(store.loadCachedToken(matchingRefreshToken: "other-refresh"))
    }

    func testCacheRevalidationDiscardsWhenFileLoginChanged() throws {
        let files = FakeFiles()
        let store = AntigravityAuthStore(keychain: FakeKeychain(nil), files: files, fileCredentialPaths: { [] })
        let cached = try store.cacheToken(
            "file-access", expiresIn: 3600, matchingRefreshToken: "file-refresh",
            revalidate: { "rotated-refresh" }
        )
        XCTAssertFalse(cached)
        XCTAssertNil(files.files[AntigravityAuthStore.cachePath])
    }

    // MARK: - Quota fallback

    private static let completeSummary = """
    {"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":0.8},\
    {"bucketId":"gemini-weekly","remainingFraction":0.7},\
    {"bucketId":"3p-5h","remainingFraction":0.6},\
    {"bucketId":"3p-weekly","remainingFraction":0.5}]}]}
    """

    private static func ok(_ json: String) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
    }

    @MainActor
    private func makeProvider(
        keychain: KeychainAccessing,
        files: FakeFiles,
        credentialPaths: @escaping @Sendable () -> [URL],
        http: RoutingHTTPClient
    ) -> AntigravityProvider {
        AntigravityProvider(
            quotaSource: .legacyTestFixture,
            authStore: AntigravityAuthStore(
                keychain: keychain, files: files, fileCredentialPaths: credentialPaths
            ),
            usageClient: AntigravityUsageClient(lsHTTP: http, http: http),
            discovery: LanguageServerDiscovery(processRunner: EmptyProcessRunner()),
            dbUsageScanner: AntigravityDbUsageScanner(conversationsDirectory: { "/nonexistent-antigravity-t3-test" })
        )
    }

    /// Regression: every rebuild changes the app's cdhash, so the Keychain ACL refuses silent reads
    /// and quota stayed stale for days while T3 Code's Antigravity kept working. The file credential
    /// T3 already keeps on disk must carry quota without any Keychain grant.
    @MainActor
    func testBlockedKeychainFallsBackToFileCredentialWithoutWarning() async throws {
        let http = RoutingHTTPClient { request in
            if request.url.host == "oauth2.googleapis.com" {
                return Self.ok(#"{"access_token":"file-access","expires_in":3599}"#)
            }
            if request.url.path == AntigravityUsageClient.quotaSummaryPath {
                return Self.ok(Self.completeSummary)
            }
            if request.url.path == AntigravityUsageClient.loadCodeAssistPath {
                return Self.ok(#"{"paidTier":{"id":"g1-ultra-lite-tier"}}"#)
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let credentialPath = "/fixture/profile/antigravity-acp/acp_token.json"
        let files = FakeFiles([credentialPath: Self.credentialJSON()])
        let provider = makeProvider(
            keychain: T3BlockedKeychain(), files: files,
            credentialPaths: { [URL(fileURLWithPath: credentialPath)] }, http: http
        )

        let snapshot = await ProviderRefreshContext.$scope.withValue(.menuBar) { await provider.refresh() }
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Claude", "Claude Weekly"])
        XCTAssertNil(snapshot.warning)
        XCTAssertEqual(snapshot.plan, "Ultra Lite")

        // The refresh used the instance's own client pair, not the bundled Antigravity one.
        let oauth = try XCTUnwrap(http.requests.first { $0.url.host == "oauth2.googleapis.com" })
        let form = String(decoding: oauth.body ?? Data(), as: UTF8.self)
        XCTAssertTrue(form.contains("client_id=file-client"))
        XCTAssertTrue(form.contains("refresh_token=file-refresh"))
        // Quota requests identify as the hub client so Google reports the full pool set.
        let summary = try XCTUnwrap(http.requests.first { $0.url.path == AntigravityUsageClient.quotaSummaryPath })
        XCTAssertEqual(summary.headers["User-Agent"], AntigravityUsageClient.clientUserAgent)
        XCTAssertTrue(AntigravityUsageClient.clientUserAgent.hasPrefix("antigravity/hub/"))
        // The derived token is cached against the file credential for the next cycle.
        XCTAssertNotNil(files.files[AntigravityAuthStore.cachePath])
    }

    @MainActor
    func testReadableKeychainIsPreferredOverFileCredentials() async throws {
        let http = RoutingHTTPClient { request in
            if request.url.path == AntigravityUsageClient.quotaSummaryPath {
                return Self.ok(Self.completeSummary)
            }
            if request.url.path == AntigravityUsageClient.loadCodeAssistPath {
                return Self.ok("{}")
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let token = #"{"token":{"access_token":"kc-access","expiry":"2099-01-01T00:00:00Z"}}"#
        let credentialPath = "/fixture/profile/antigravity-acp/acp_token.json"
        let files = FakeFiles([credentialPath: Self.credentialJSON()])
        let provider = makeProvider(
            keychain: FakeKeychain("go-keyring-base64:" + Data(token.utf8).base64EncodedString()),
            files: files,
            credentialPaths: { [URL(fileURLWithPath: credentialPath)] }, http: http
        )

        let snapshot = await ProviderRefreshContext.$scope.withValue(.menuBar) { await provider.refresh() }
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Claude", "Claude Weekly"])
        XCTAssertFalse(http.requests.contains { $0.url.host == "oauth2.googleapis.com" })
        let summary = try XCTUnwrap(http.requests.first { $0.url.path == AntigravityUsageClient.quotaSummaryPath })
        XCTAssertEqual(summary.headers["Authorization"], "Bearer kc-access")
    }

    @MainActor
    func testNoKeychainAndNoFilesReportsNotSignedIn() async throws {
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = makeProvider(
            keychain: FakeKeychain(nil), files: FakeFiles(), credentialPaths: { [] }, http: http
        )
        let snapshot = await ProviderRefreshContext.$scope.withValue(.menuBar) { await provider.refresh() }
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertTrue(http.requests.isEmpty, "no credential means no network probe")
    }

    @MainActor
    func testDeadFileGrantTriesTheNextInstance() async throws {
        let http = RoutingHTTPClient { request in
            if request.url.host == "oauth2.googleapis.com" {
                let form = String(decoding: request.body ?? Data(), as: UTF8.self)
                if form.contains("refresh_token=dead-refresh") {
                    return HTTPResponse(statusCode: 400, headers: [:], body: Data(#"{"error":"invalid_grant"}"#.utf8))
                }
                return Self.ok(#"{"access_token":"live-access","expires_in":3599}"#)
            }
            if request.url.path == AntigravityUsageClient.quotaSummaryPath {
                return Self.ok(Self.completeSummary)
            }
            if request.url.path == AntigravityUsageClient.loadCodeAssistPath {
                return Self.ok("{}")
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let deadPath = "/fixture/dead/antigravity-acp/acp_token.json"
        let livePath = "/fixture/live/antigravity-acp/acp_token.json"
        let files = FakeFiles([
            deadPath: Self.credentialJSON(refresh: "dead-refresh"),
            livePath: Self.credentialJSON(refresh: "live-refresh")
        ])
        let provider = makeProvider(
            keychain: T3BlockedKeychain(), files: files,
            credentialPaths: { [URL(fileURLWithPath: deadPath), URL(fileURLWithPath: livePath)] }, http: http
        )

        let snapshot = await ProviderRefreshContext.$scope.withValue(.menuBar) { await provider.refresh() }
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Claude", "Claude Weekly"])
        XCTAssertNil(snapshot.warning)
    }

    /// Ported from upstream openusage#1676: the hub identity is what makes Google report Argon and
    /// the paid tier; a bare client string is marked unsupported.
    func testQuotaSummaryIdentifiesAsTheHubClient() async throws {
        let http = RoutingHTTPClient { _ in Self.ok(Self.completeSummary) }
        _ = try await AntigravityUsageClient(http: http).cloudCodeSummaries(token: "test")
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertTrue(try XCTUnwrap(request.headers["User-Agent"]).hasPrefix("antigravity/hub/"))
    }
}

/// Silent reads always refuse — the per-build cdhash lockout this fallback exists for.
private final class T3BlockedKeychain: KeychainAccessing, @unchecked Sendable {
    func readGenericPassword(service: String) throws -> String? {
        throw KeychainError.interactionNotAllowed
    }
    func writeGenericPassword(service: String, value: String) throws {}
}
