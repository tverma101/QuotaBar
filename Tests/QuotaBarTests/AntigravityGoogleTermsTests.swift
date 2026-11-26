import XCTest
@testable import QuotaBar

/// Public builds must follow Google's Antigravity terms: no Google login reads, no Google or
/// Antigravity endpoints, and no local language-server probing. Only local conversation history is read.
final class AntigravityGoogleTermsTests: XCTestCase {
    func testDefaultBuildIsPublicAndReadsOnlyLocalHistory() {
        // The test target is compiled without QUOTABAR_GOOGLE_PRIVATE_ACCESS, like every public build.
        XCTAssertFalse(GoogleTermsPolicy.allowsPrivateGoogleAccess)
        XCTAssertEqual(AntigravityQuotaAccess.current, .localHistoryOnly)
        XCTAssertFalse(AntigravityQuotaAccess.localHistoryOnly.readsLiveQuota)
    }

    @MainActor
    func testPublicDescriptorsOfferHistoryAndSpendButNoLimits() {
        let ids = AntigravityProvider(quotaAccess: .localHistoryOnly).widgetDescriptors.map(\.id)
        XCTAssertEqual(ids, ["antigravity.trend", "antigravity.today", "antigravity.yesterday", "antigravity.last30"])

        let ownerIDs = AntigravityProvider(quotaAccess: .ownerBuild).widgetDescriptors.map(\.id)
        XCTAssertTrue(ownerIDs.contains(AntigravityMetric.geminiID))
    }

    @MainActor
    func testPublicSetupDetectionReadsNeitherKeychainNorProcessTable() async throws {
        let keychain = CountingKeychain()
        let processRunner = RecordingProcessRunner()
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data()))
        let empty = try makeConversationDirectory(withDatabase: false)
        let provider = makeProvider(
            keychain: keychain, processRunner: processRunner, http: http, conversationsDirectory: empty
        )

        let detectedWithoutHistory = await provider.hasLocalCredentials()
        XCTAssertFalse(detectedWithoutHistory)

        let withHistory = try makeConversationDirectory(withDatabase: true)
        let historyProvider = makeProvider(
            keychain: keychain, processRunner: processRunner, http: http, conversationsDirectory: withHistory
        )
        let detectedWithHistory = await historyProvider.hasLocalCredentials()
        XCTAssertTrue(detectedWithHistory)

        XCTAssertEqual(keychain.reads, 0, "public builds must not read Antigravity's Google login")
        XCTAssertTrue(processRunner.executables.isEmpty, "public builds must not look for the language server")
        XCTAssertTrue(http.requests.isEmpty)
    }

    @MainActor
    func testPublicRefreshWithoutHistoryExplainsLocalOnlySourceWithoutContactingAnyone() async throws {
        let keychain = CountingKeychain()
        let processRunner = RecordingProcessRunner()
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data()))
        let empty = try makeConversationDirectory(withDatabase: false)
        let provider = makeProvider(
            keychain: keychain, processRunner: processRunner, http: http, conversationsDirectory: empty
        )

        for scope in [ProviderRefreshContext.Scope.full, .menuBar, .panelMeters] {
            let snapshot = await ProviderRefreshContext.$scope.withValue(scope) { await provider.refresh() }
            XCTAssertEqual(snapshot.errorCategory, .notLoggedIn, "\(scope)")
            XCTAssertEqual(snapshot.lines.first?.label, MetricLine.errorBadgeLabel, "\(scope)")
        }

        XCTAssertEqual(keychain.reads, 0)
        XCTAssertTrue(processRunner.executables.isEmpty)
        XCTAssertTrue(http.requests.isEmpty, "no Google, Antigravity, or loopback request may be made")
    }

    @MainActor
    func testPublicMeterPassWithHistoryIsQuietAndEmpty() async throws {
        let keychain = CountingKeychain()
        let processRunner = RecordingProcessRunner()
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data()))
        let withHistory = try makeConversationDirectory(withDatabase: true)
        let provider = makeProvider(
            keychain: keychain, processRunner: processRunner, http: http, conversationsDirectory: withHistory
        )

        let snapshot = await ProviderRefreshContext.$scope.withValue(.panelMeters) { await provider.refresh() }

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.warning)
        XCTAssertFalse(snapshot.lines.contains { if case .progress = $0 { return true } else { return false } })
        XCTAssertEqual(keychain.reads, 0)
        XCTAssertTrue(processRunner.executables.isEmpty)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testConversationRootsIncludeT3CodeAndXDGStores() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let gemini = home.appendingPathComponent(".gemini/antigravity/conversations")
        let xdg = home.appendingPathComponent(".config/antigravity/conversations")
        let t3 = home.appendingPathComponent(".t3/userdata/providers/antigravity/abc123/antigravity-acp/conversations")
        let t3WithoutStore = home.appendingPathComponent(".t3/userdata/providers/antigravity/empty/antigravity-acp")
        for directory in [gemini, xdg, t3, t3WithoutStore] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let discovery = AntigravityConversationRoots.discover(home: home)

        XCTAssertEqual(
            Set(discovery.directories.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }),
            Set([gemini, xdg, t3].map { $0.resolvingSymlinksInPath().path })
        )
        XCTAssertTrue(discovery.failures.isEmpty)
    }

    func testMissingRootsAreNotFailures() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let discovery = AntigravityConversationRoots.discover(home: home)
        XCTAssertTrue(discovery.directories.isEmpty)
        XCTAssertTrue(discovery.failures.isEmpty)
    }

    // MARK: - Helpers

    @MainActor
    private func makeProvider(
        keychain: CountingKeychain,
        processRunner: RecordingProcessRunner,
        http: FakeHTTPClient,
        conversationsDirectory: URL
    ) -> AntigravityProvider {
        let token = #"{"token":{"access_token":"ya29.test","refresh_token":"1//test","expiry":"2099-01-01T00:00:00Z"}}"#
        keychain.value = "go-keyring-base64:" + Data(token.utf8).base64EncodedString()
        return AntigravityProvider(
            authStore: AntigravityAuthStore(keychain: keychain, files: FakeFiles()),
            usageClient: AntigravityUsageClient(lsHTTP: http, http: http),
            discovery: LanguageServerDiscovery(processRunner: processRunner),
            dbUsageScanner: AntigravityDbUsageScanner(
                sqlite: AntigravityFakeSQLite(),
                conversationsDirectory: { conversationsDirectory.path }
            ),
            quotaAccess: .localHistoryOnly
        )
    }

    private func makeConversationDirectory(withDatabase: Bool) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if withDatabase {
            try Data().write(to: directory.appendingPathComponent("conversation.db"))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

private final class CountingKeychain: KeychainAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var readCount = 0
    var value: String?

    var reads: Int {
        lock.lock(); defer { lock.unlock() }
        return readCount
    }

    func readGenericPassword(service: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        readCount += 1
        return value
    }

    func writeGenericPassword(service: String, value: String) throws {
        self.value = value
    }
}

private final class RecordingProcessRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var executables: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
        lock.lock(); defer { lock.unlock() }
        recorded.append(executable)
        return ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
}
