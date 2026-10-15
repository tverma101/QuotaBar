import XCTest
@testable import QuotaBar

final class FreebuffAuthStoreTests: XCTestCase {
    func testDefaultPathUsesProductionFreebuffConfigDirectory() throws {
        let store = FreebuffAuthStore(
            files: FakeFiles(),
            keychain: FakeKeychain(),
            environment: FakeEnvironment(),
            homeDirectory: { URL(fileURLWithPath: "/Users/tester") }
        )
        XCTAssertEqual(
            try store.credentialsFilePath(),
            "/Users/tester/.config/manicode/credentials.json"
        )
    }

    func testNonProductionEnvironmentSelectsItsOwnDefaultConfigDirectory() throws {
        let store = FreebuffAuthStore(
            files: FakeFiles(), keychain: FakeKeychain(),
            environment: FakeEnvironment(["NEXT_PUBLIC_CB_ENVIRONMENT": "staging"]),
            homeDirectory: { URL(fileURLWithPath: "/Users/tester") }
        )
        XCTAssertEqual(
            try store.credentialsFilePath(),
            "/Users/tester/.config/manicode-staging/credentials.json"
        )
    }

    func testCustomConfigDirectoryMustBeAbsolute() {
        let store = FreebuffAuthStore(
            files: FakeFiles(), keychain: FakeKeychain(),
            environment: FakeEnvironment(["FREEBUFF_CONFIG_DIR": "relative/config"])
        )
        XCTAssertThrowsError(try store.credentialsFilePath()) {
            XCTAssertEqual($0 as? FreebuffAuthError, .invalidConfigDirectory)
        }
    }

    func testReadsLegacyFileTokenAndEnvironmentFallback() throws {
        let path = "/Users/tester/.config/manicode/credentials.json"
        let fileStore = FreebuffAuthStore(
            files: FakeFiles([path: #"{"default":{"authToken":" file-token "}}"#]),
            keychain: FakeKeychain(), environment: FakeEnvironment(["CODEBUFF_API_KEY": "env-token"]),
            homeDirectory: { URL(fileURLWithPath: "/Users/tester") }
        )
        XCTAssertEqual(try fileStore.loadAuth()?.token, "file-token")

        let environmentStore = FreebuffAuthStore(
            files: FakeFiles(), keychain: FakeKeychain(),
            environment: FakeEnvironment(["CODEBUFF_API_KEY": " env-token "]),
            homeDirectory: { URL(fileURLWithPath: "/Users/tester") }
        )
        XCTAssertEqual(try environmentStore.loadAuth()?.token, "env-token")
    }

    func testReadsKeychainPointerScopedToCredentialFilePath() throws {
        let path = "/Users/tester/.config/manicode/credentials.json"
        let keychain = AccountScopedFreebuffKeychain(token: "keychain-token")
        let store = FreebuffAuthStore(
            files: FakeFiles([path: #"{"default":{"tokenStore":"keychain"}}"#]),
            keychain: keychain, environment: FakeEnvironment(),
            homeDirectory: { URL(fileURLWithPath: "/Users/tester") }
        )
        XCTAssertEqual(try store.loadAuth()?.token, "keychain-token")
        XCTAssertEqual(keychain.lastService, FreebuffAuthStore.keychainService)
        XCTAssertEqual(keychain.lastAccount, path)
        XCTAssertFalse(keychain.lastAllowInteraction ?? true)
    }

    func testUsesEnvironmentKeyWhenKeychainPointerCannotBeResolved() throws {
        let path = "/Users/tester/.config/manicode/credentials.json"
        let key = KeychainItemKey(service: FreebuffAuthStore.keychainService, account: path)
        for failure in [KeychainError.interactionNotAllowed, KeychainError.readFailed("fixture failure")] {
            KeychainPermissionGate.shared.reset(key)
            let keychain = AccountScopedFreebuffKeychain(token: nil, readError: failure)
            let store = FreebuffAuthStore(
                files: FakeFiles([path: #"{"default":{"tokenStore":"keychain"}}"#]),
                keychain: keychain,
                environment: FakeEnvironment(["CODEBUFF_API_KEY": " env-fallback "]),
                homeDirectory: { URL(fileURLWithPath: "/Users/tester") }
            )

            XCTAssertEqual(try store.loadAuth()?.token, "env-fallback")
            XCTAssertEqual(keychain.readCount, 1)
        }
        KeychainPermissionGate.shared.reset(key)
    }

    func testKeychainPermissionWithoutEnvironmentFallbackRemainsActionable() throws {
        let path = "/Users/tester/.config/manicode/credentials.json"
        let key = KeychainItemKey(service: FreebuffAuthStore.keychainService, account: path)
        KeychainPermissionGate.shared.reset(key)
        defer { KeychainPermissionGate.shared.reset(key) }
        let store = FreebuffAuthStore(
            files: FakeFiles([path: #"{"default":{"tokenStore":"keychain"}}"#]),
            keychain: AccountScopedFreebuffKeychain(token: nil, readError: .interactionNotAllowed),
            environment: FakeEnvironment(),
            homeDirectory: { URL(fileURLWithPath: "/Users/tester") }
        )

        XCTAssertThrowsError(try store.loadAuth()) {
            XCTAssertEqual($0 as? FreebuffAuthError, .credentialPermissionRequired)
        }
    }

    func testKeychainCancellationStaysCancellationAndDoesNotLogCredentialFailure() throws {
        let path = "/Users/tester/.config/manicode/credentials.json"
        let key = KeychainItemKey(service: FreebuffAuthStore.keychainService, account: path)
        KeychainPermissionGate.shared.reset(key)
        defer { KeychainPermissionGate.shared.reset(key) }
        let store = FreebuffAuthStore(
            files: FakeFiles([path: #"{"default":{"tokenStore":"keychain"}}"#]),
            keychain: CancellationKeychain(), environment: FakeEnvironment(),
            homeDirectory: { URL(fileURLWithPath: "/Users/tester") }
        )

        let (error, logs) = try captureFreebuffAuthStoreLogs {
            _ = try store.loadAuth()
        }

        XCTAssertTrue(error is CancellationError)
        XCTAssertFalse(logs.contains("Keychain credential read failed"), logs)
        XCTAssertFalse(logs.contains("[ERROR] [auth:freebuff]"), logs)
    }

    func testMissingProfileAndKeyIsNotLoggedIn() {
        let store = FreebuffAuthStore(
            files: FakeFiles(), keychain: FakeKeychain(), environment: FakeEnvironment(),
            homeDirectory: { URL(fileURLWithPath: "/Users/tester") }
        )
        XCTAssertNil(try store.loadAuth())
    }
}

final class FreebuffUsageMapperTests: XCTestCase {
    func testMapsFreeSessionWindowsCreditsAndReportedMonthlyDollars() throws {
        let mapped = try FreebuffUsageMapper.map(response: response([
            "status": "none",
            "accessTier": "full",
            "freeWindows": [
                "dayUsed": 2, "dayLimit": 10, "dayResetAt": "2026-10-14T07:00:00Z",
                "weekUsed": 7, "weekLimit": 30,
                "monthUsed": 21, "monthLimit": 100, "monthResetAt": "2026-11-01T07:00:00Z"
            ],
            "freebucks": [
                "balance": 75,
                "daily": ["limit": 100, "spent": 25, "remaining": 75, "resetAt": "2026-10-14T07:00:00Z"],
                "wallet": ["balance": 50, "monthlyBonus": 0],
                "monthly": ["limitUsd": 12, "spentUsd": 3.5, "remainingUsd": 8.5, "resetAt": "2026-11-01T07:00:00Z"]
            ]
        ]))

        XCTAssertEqual(mapped.plan, "Full")
        XCTAssertEqual(progress(mapped.lines, "Daily")?.used, 2)
        XCTAssertEqual(progress(mapped.lines, "Weekly")?.used, 7)
        XCTAssertEqual(progress(mapped.lines, "Monthly")?.used, 21)
        XCTAssertEqual(progress(mapped.lines, "Freebucks Daily")?.used, 25)
        XCTAssertEqual(progress(mapped.lines, "Freebucks Daily")?.limit, 100)
        XCTAssertEqual(values(mapped.lines, "Freebucks Balance")?.first?.number, 75)
        XCTAssertEqual(progress(mapped.lines, "Monthly Spend")?.used, 3.5)
        XCTAssertEqual(progress(mapped.lines, "Monthly Spend")?.limit, 12)
    }

    func testMapsSubscriberFiveDayAndMonthlyMetersAndActualUsdSpend() throws {
        let mapped = try FreebuffUsageMapper.map(response: response([
            "status": "none",
            "subscription": [
                "tierId": "pro",
                "usage": [
                    "dayUsed": 4, "dayLimit": 20, "dayResetAt": "2026-10-14T07:00:00Z",
                    "fiveDayUsed": 10, "fiveDayLimit": 60,
                    "monthUsed": 40, "monthLimit": 300, "periodEndsAt": "2026-11-10T00:00:00Z",
                    "dayPremiumUsed": 1, "dayPremiumLimit": 4,
                    "freeDayUsed": 2, "freeDayLimit": 5,
                    "monthSpendUsd": 1.75, "monthSpendLimitUsd": 25
                ]
            ]
        ]))

        XCTAssertEqual(mapped.plan, "pro")
        XCTAssertEqual(progress(mapped.lines, "Daily")?.used, 4)
        XCTAssertEqual(progress(mapped.lines, "5-Day")?.used, 10)
        XCTAssertEqual(progress(mapped.lines, "Monthly")?.limit, 300)
        XCTAssertEqual(progress(mapped.lines, "Premium Sessions")?.used, 1)
        XCTAssertEqual(progress(mapped.lines, "Free Premium Sessions")?.used, 2)
        XCTAssertEqual(progress(mapped.lines, "Free Premium Sessions")?.limit, 5)
        XCTAssertEqual(progress(mapped.lines, "Free Premium Sessions")?.resetsAt?.timeIntervalSince1970, 1_791_961_200)
        XCTAssertEqual(progress(mapped.lines, "Monthly Spend")?.used, 1.75)
        XCTAssertEqual(progress(mapped.lines, "Monthly Spend")?.limit, 25)
    }

    func testOlderSubscriberResponseWithoutFreePoolOmitsThatOptionalMeter() throws {
        let mapped = try FreebuffUsageMapper.map(response: response([
            "status": "none",
            "subscription": ["tierId": "pro", "usage": [
                "dayUsed": 4, "dayLimit": 20, "dayResetAt": "2026-10-14T07:00:00Z",
                "monthUsed": 40, "monthLimit": 300,
                "dayPremiumUsed": 1, "dayPremiumLimit": 4
            ]]
        ]))

        XCTAssertNil(mapped.lines.first { $0.label == "Free Premium Sessions" })
    }

    func testDoesNotInventMonthlyDollarSpendFromFreebucks() throws {
        let mapped = try FreebuffUsageMapper.map(response: response([
            "status": "none",
            "freeWindows": ["dayUsed": 0, "dayLimit": 10, "weekUsed": 1, "weekLimit": 20,
                             "monthUsed": 2, "monthLimit": 50],
            "freebucks": ["balance": 99, "daily": ["limit": 100, "spent": 1], "wallet": ["balance": 0]]
        ]))

        XCTAssertNil(mapped.lines.first { $0.label == "Monthly Spend" })
        XCTAssertEqual(values(mapped.lines, "Freebucks Balance")?.first?.kind, .count)
    }

    func testDeduplicatesModelsByOpaquePoolAndUsesMostDepletedPool() throws {
        let mapped = try FreebuffUsageMapper.map(response: response([
            "status": "none",
            "rateLimitsByModel": [
                "model-a": ["pool": "shared", "poolLabel": "Shared", "limit": 10, "recentCount": 8,
                            "period": "pacific_day", "resetAt": "2026-10-14T07:00:00Z"],
                "model-b": ["pool": "shared", "poolLabel": "Shared", "limit": 10, "recentCount": 2,
                            "period": "pacific_day", "resetAt": "2026-10-14T07:00:00Z"],
                "model-c": ["pool": "other", "poolLabel": "Other", "limit": 5, "recentCount": 4,
                            "period": "pacific_week", "resetAt": "2026-10-18T07:00:00Z"]
            ]
        ]))

        let pool = try XCTUnwrap(progress(mapped.lines, "Session Pool"))
        XCTAssertEqual(pool.used, 4)
        XCTAssertEqual(pool.limit, 5)
    }

    func testRejectsResponseWithoutStatus() {
        XCTAssertThrowsError(try FreebuffUsageMapper.map(response: response(["freeWindows": [:]]))) {
            XCTAssertEqual($0 as? FreebuffUsageError, .invalidResponse)
        }
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (
        used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?
    )? {
        guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, resetsAt, periodDurationMs)
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else { return nil }
        return values
    }

    private func response(_ object: [String: Any]) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: try! JSONSerialization.data(withJSONObject: object))
    }
}

@MainActor
final class FreebuffProviderTests: XCTestCase {
    func testUsageClientUsesReadOnlySessionGetAndTimezone() async throws {
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 404, headers: [:], body: Data()))
        let client = FreebuffUsageClient(http: http, timeZone: { "America/New_York" })
        _ = try await client.fetchSession(auth: FreebuffAuth(token: "test-token"))

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url.absoluteString, FreebuffUsageClient.sessionURL)
        XCTAssertEqual(request.headers["Authorization"], "Bearer test-token")
        XCTAssertEqual(request.headers["x-fb-timezone"], "America/New_York")
        XCTAssertNil(request.body)
    }

    func testUsageTransportFailureMapsToFriendlyNetworkError() async {
        let path = "/Users/tester/.config/manicode/credentials.json"
        let provider = FreebuffProvider(
            authStore: FreebuffAuthStore(
                files: FakeFiles([path: #"{"default":{"authToken":"test-token"}}"#]),
                keychain: FakeKeychain(), environment: FakeEnvironment(),
                homeDirectory: { URL(fileURLWithPath: "/Users/tester") }
            ),
            usageClient: FreebuffUsageClient(http: ThrowingFreebuffHTTPClient(error: URLError(.timedOut)))
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .network)
        guard case .badge(_, let message, _, _) = snapshot.lines.first else {
            return XCTFail("expected the network error badge")
        }
        XCTAssertEqual(message, "Couldn't reach Freebuff. Check your connection and try again.")
    }

    func testUsageClientPreservesCancellationErrors() async {
        let client = FreebuffUsageClient(http: ThrowingFreebuffHTTPClient(error: URLError(.cancelled)))

        do {
            _ = try await client.fetchSession(auth: FreebuffAuth(token: "test-token"))
            XCTFail("expected cancellation to be rethrown")
        } catch is CancellationError {
            // Cancellation must continue to reach the provider's cancellation handler.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testRefreshUsesLocalAuthAndMapsNotFoundToNoUsageSnapshot() async throws {
        let path = "/Users/tester/.config/manicode/credentials.json"
        let files = FakeFiles([path: #"{"default":{"authToken":"test-token"}}"#])
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 404, headers: [:], body: Data()))
        let provider = FreebuffProvider(
            authStore: FreebuffAuthStore(
                files: files, keychain: FakeKeychain(), environment: FakeEnvironment(),
                homeDirectory: { URL(fileURLWithPath: "/Users/tester") }
            ),
            usageClient: FreebuffUsageClient(http: http)
        )

        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertFalse(snapshot.lines.contains(where: \.isError))
        XCTAssertNotNil(snapshot.line(label: "Status"))
        XCTAssertEqual(http.requests.first?.method, "GET")
    }

    func testHasLocalCredentialsDoesNotCallNetwork() async {
        let path = "/Users/tester/.config/manicode/credentials.json"
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data()))
        let provider = FreebuffProvider(
            authStore: FreebuffAuthStore(
                files: FakeFiles([path: #"{"default":{"authToken":"test-token"}}"#]),
                keychain: FakeKeychain(), environment: FakeEnvironment(),
                homeDirectory: { URL(fileURLWithPath: "/Users/tester") }
            ),
            usageClient: FreebuffUsageClient(http: http)
        )

        let hasCredentials = await provider.hasLocalCredentials()
        XCTAssertTrue(hasCredentials)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testInvalidConfiguredDirectoryRemainsDetectedAndSurfacesTypedError() async {
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data()))
        let provider = FreebuffProvider(
            authStore: FreebuffAuthStore(
                files: FakeFiles(),
                keychain: FakeKeychain(),
                environment: FakeEnvironment(["FREEBUFF_CONFIG_DIR": "relative/config"])
            ),
            usageClient: FreebuffUsageClient(http: http)
        )

        let detected = await provider.hasLocalCredentials()
        let snapshot = await provider.refresh()

        XCTAssertTrue(detected, "an invalid configured source must remain visible for repair")
        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
        XCTAssertTrue(http.requests.isEmpty, "invalid local configuration must fail before the API call")
    }
}

private struct ThrowingFreebuffHTTPClient: HTTPClient {
    let error: any Error

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw error
    }
}

private struct CancellationKeychain: KeychainAccessing {
    func readGenericPassword(service: String) throws -> String? { throw CancellationError() }
    func writeGenericPassword(service: String, value: String) throws {}
}

private func captureFreebuffAuthStoreLogs(
    _ operation: () throws -> Void
) throws -> (error: Error?, logs: String) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("OpenUsageTests.FreebuffCancellation.\(UUID().uuidString)", isDirectory: true)
    let sink = LogFile(directory: directory, fileName: "OpenUsage.log")
    sink.open()
    let originalSink = AppLog.sink
    AppLog.sink = sink
    AppLog.reloadLevel(.error)
    defer {
        AppLog.sink = originalSink
        AppLog.reloadLevel()
        try? FileManager.default.removeItem(at: directory)
    }

    var caught: Error?
    do { try operation() } catch { caught = error }
    return (caught, try String(contentsOf: sink.fileURL, encoding: .utf8))
}

private final class AccountScopedFreebuffKeychain: KeychainAccessing, @unchecked Sendable {
    var token: String?
    let readError: KeychainError?
    private(set) var readCount = 0
    var lastService: String?
    var lastAccount: String?
    var lastAllowInteraction: Bool?

    init(token: String?, readError: KeychainError? = nil) {
        self.token = token
        self.readError = readError
    }

    private func read() throws -> String? {
        readCount += 1
        if let readError { throw readError }
        return token
    }

    func writeGenericPassword(service: String, value: String) throws {}
    func readGenericPassword(service: String) throws -> String? { try read() }
    func readGenericPassword(service: String, allowInteraction: Bool) throws -> String? {
        lastAllowInteraction = allowInteraction
        return try read()
    }
    func readGenericPassword(service: String, account: String) throws -> String? {
        lastService = service
        lastAccount = account
        return try read()
    }
    func readGenericPassword(service: String, account: String, allowInteraction: Bool) throws -> String? {
        lastService = service
        lastAccount = account
        lastAllowInteraction = allowInteraction
        return try read()
    }
}
