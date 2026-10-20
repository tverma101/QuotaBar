import XCTest
@testable import QuotaBar

final class DevinAuthStoreTests: XCTestCase {
    func testParsesCredentialsTomlAndAcceptsOnlyHTTPSServerURL() throws {
        func load(serverURL: String) throws -> DevinAuth? {
            try DevinAuthStore(
                files: FakeFiles([
                    DevinAuthStore.credentialsPath: """
                    windsurf_api_key = "devin-session-token$cli"
                    api_server_url = "\(serverURL)"
                    """
                ]),
                sqlite: FakeSQLite()
            ).loadCredentialsFile()
        }

        let https = try load(serverURL: "https://server.codeium.test/")
        XCTAssertEqual(https?.apiKey, "devin-session-token$cli")
        XCTAssertEqual(https?.apiServerUrl, "https://server.codeium.test", "trailing slash cleaned")

        // A plaintext URL is dropped; the key still parses (proving the file parsed at all).
        let http = try load(serverURL: "http://server.codeium.test")
        XCTAssertEqual(http?.apiKey, "devin-session-token$cli")
        XCTAssertNil(http?.apiServerUrl)
    }

    func testReadsAppAuthFromSQLiteState() throws {
        let sqlite = FakeSQLite(value: #"{"apiKey":"devin-session-token$app"}"#)
        let store = DevinAuthStore(files: FakeFiles(), sqlite: sqlite)

        let auth = try store.loadAppAuth()

        XCTAssertEqual(auth?.apiKey, "devin-session-token$app")
        XCTAssertEqual(sqlite.lastPath, DevinAuthStore.stateDBPath)
        XCTAssertEqual(sqlite.lastSQL?.contains("windsurfAuthStatus"), true)
    }

    func testUnreadableCredentialsFileThrowsButMissingFileRemainsNil() throws {
        let unreadable = DevinAuthStore(
            files: UnreadableDevinFiles(path: DevinAuthStore.credentialsPath),
            sqlite: FakeSQLite()
        )
        XCTAssertThrowsError(try unreadable.loadCredentialsFile()) { error in
            XCTAssertEqual(error as? DevinAuthError, .credentialsUnreadable)
        }

        let missing = DevinAuthStore(files: FakeFiles(), sqlite: FakeSQLite())
        XCTAssertNil(try missing.loadCredentialsFile())
    }

    func testUnreadableAppDatabaseThrowsButMissingRowRemainsNil() throws {
        let unreadable = DevinAuthStore(files: FakeFiles(), sqlite: UnreadableDevinSQLite())
        XCTAssertThrowsError(try unreadable.loadAppAuth()) { error in
            XCTAssertEqual(error as? DevinAuthError, .credentialsUnreadable)
        }

        let missing = DevinAuthStore(files: FakeFiles(), sqlite: FakeSQLite())
        XCTAssertNil(try missing.loadAppAuth())
    }
}

final class DevinUsageMapperTests: XCTestCase {
    /// The mapper only accepts a reset that is still ahead of the reference time, so the fixture's
    /// reset instants are read against a fixed "now" that sits before them.
    private let now = Date(timeIntervalSince1970: 1_773_000_000)

    func testMapsQuotaLinesAndExtraUsageBalance() throws {
        let mapped = try DevinUsageMapper.mapUserStatus(makeUserStatus(), now: now)

        XCTAssertEqual(mapped.plan, "Max")
        XCTAssertEqual(progress(mapped.lines, "Daily quota")?.used, 0)
        XCTAssertEqual(progress(mapped.lines, "Daily quota")?.periodDurationMs, DevinUsageMapper.dayPeriodMs)
        XCTAssertEqual(progress(mapped.lines, "Weekly quota")?.used, 60)
        XCTAssertEqual(progress(mapped.lines, "Weekly quota")?.periodDurationMs, DevinUsageMapper.weekPeriodMs)
        XCTAssertEqual(try XCTUnwrap(dollars(mapped.lines, "Extra usage balance")), 964.22, accuracy: 0.0001)
        XCTAssertNotNil(progress(mapped.lines, "Weekly quota")?.resetsAt)
    }

    func testStaleResetTimestampsAreDroppedSoTheCadenceAnswers() throws {
        // A zero (or an unadvanced) reset instant would otherwise read as "Resets soon" forever.
        var userStatus = makeUserStatus()
        var planStatus = userStatus["planStatus"] as! [String: Any]
        planStatus["dailyQuotaResetAtUnix"] = "0"
        planStatus["weeklyQuotaResetAtUnix"] = "0"
        userStatus["planStatus"] = planStatus

        let mapped = try DevinUsageMapper.mapUserStatus(userStatus, now: now)

        XCTAssertNil(progress(mapped.lines, "Daily quota")?.resetsAt)
        XCTAssertNil(progress(mapped.lines, "Weekly quota")?.resetsAt)
        XCTAssertEqual(progress(mapped.lines, "Weekly quota")?.periodDurationMs, DevinUsageMapper.weekPeriodMs,
                       "the meter's own cadence still answers when the reset instant is unusable")
    }

    func testZeroOverageBalanceReadsZeroDollarsNotNoData() throws {
        var userStatus = makeUserStatus()
        var planStatus = userStatus["planStatus"] as! [String: Any]
        planStatus["overageBalanceMicros"] = "0"
        userStatus["planStatus"] = planStatus

        let mapped = try DevinUsageMapper.mapUserStatus(userStatus)

        // A present balance of zero is a real, measured value → 0, not "No data" (that's reserved
        // for the field being absent entirely).
        XCTAssertEqual(dollars(mapped.lines, "Extra usage balance"), 0)
    }

    func testUsesHiddenDailyQuotaAsWeeklyUsageWhenWeeklyIsAbsent() throws {
        var userStatus = makeUserStatus()
        var planStatus = userStatus["planStatus"] as! [String: Any]
        var planInfo = planStatus["planInfo"] as! [String: Any]
        planInfo["hideDailyQuota"] = true
        planStatus["planInfo"] = planInfo
        planStatus["dailyQuotaRemainingPercent"] = 30
        planStatus.removeValue(forKey: "weeklyQuotaRemainingPercent")
        userStatus["planStatus"] = planStatus

        let mapped = try DevinUsageMapper.mapUserStatus(userStatus)

        XCTAssertNil(progress(mapped.lines, "Daily quota"))
        // The hidden daily quota fills the missing Weekly row and is still flipped from "remaining"
        // to "used": 30% remaining -> 70% used (not passed through raw as 30).
        XCTAssertEqual(progress(mapped.lines, "Weekly quota")?.used, 70)
    }

    func testThrowsQuotaUnavailableWhenNoDisplayableFieldsExist() {
        let userStatus: [String: Any] = [
            "planStatus": [
                "planInfo": ["planName": "Max"]
            ]
        ]

        XCTAssertThrowsError(try DevinUsageMapper.mapUserStatus(userStatus)) { error in
            XCTAssertEqual(error as? DevinUsageError, .quotaUnavailable)
        }
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, resetsAt, periodDurationMs)
    }

    /// The first dollar value's raw number on a `.values` line (the shape extra-usage balance now uses).
    private func dollars(_ lines: [MetricLine], _ label: String) -> Double? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return values.first(where: { $0.kind == .dollars })?.number
    }
}

@MainActor
final class DevinProviderTests: XCTestCase {
    func testRefreshUsesCredentialsFileBeforeAppState() async throws {
        let httpClient = QueueHTTPClient(responses: [
            HTTPResponse(statusCode: 200, headers: [:], body: try makeUserStatusBody())
        ])
        let provider = DevinProvider(
            authStore: DevinAuthStore(
                files: FakeFiles([
                    DevinAuthStore.credentialsPath: """
                    windsurf_api_key = "devin-session-token$cli"
                    api_server_url = "https://server.codeium.test"
                    """
                ]),
                sqlite: FakeSQLite(value: #"{"apiKey":"devin-session-token$app"}"#)
            ),
            usageClient: DevinUsageClient(http: httpClient),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Max")
        XCTAssertEqual(snapshot.lines.count, 3)
        XCTAssertEqual(httpClient.requests.count, 1)
        XCTAssertEqual(httpClient.requests.first?.url.absoluteString, "https://server.codeium.test/exa.seat_management_pb.SeatManagementService/GetUserStatus")
        let body = try requestBody(httpClient.requests.first)
        let metadata = body["metadata"] as? [String: Any]
        XCTAssertEqual(metadata?["apiKey"] as? String, "devin-session-token$cli")
        XCTAssertEqual(metadata?["ideName"] as? String, "devin")
        XCTAssertEqual(metadata?["extensionVersion"] as? String, DevinUsageClient.cloudCompatVersion)
    }

    func testRefreshFallsBackToAppStateAfterExpiredCredentials() async throws {
        let httpClient = QueueHTTPClient(responses: [
            HTTPResponse(statusCode: 401, headers: [:], body: Data("{}".utf8)),
            HTTPResponse(statusCode: 200, headers: [:], body: try makeUserStatusBody(planName: "Teams"))
        ])
        let provider = DevinProvider(
            authStore: DevinAuthStore(
                files: FakeFiles([
                    DevinAuthStore.credentialsPath: """
                    windsurf_api_key = "devin-session-token$cli"
                    api_server_url = "https://server.codeium.test"
                    """
                ]),
                sqlite: FakeSQLite(value: #"{"apiKey":"devin-session-token$app"}"#)
            ),
            usageClient: DevinUsageClient(http: httpClient)
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Teams")
        XCTAssertEqual(httpClient.requests.map(\.url.absoluteString), [
            "https://server.codeium.test/exa.seat_management_pb.SeatManagementService/GetUserStatus",
            "https://server.codeium.com/exa.seat_management_pb.SeatManagementService/GetUserStatus"
        ])
    }

    func testCancellationOfFirstCredentialSourceStopsBeforeAppAuthFallback() async {
        let httpClient = RoutingHTTPClient { _ in throw CancellationError() }
        let provider = DevinProvider(
            authStore: DevinAuthStore(
                files: FakeFiles([
                    DevinAuthStore.credentialsPath: "windsurf_api_key = \"devin-session-token$cli\"\napi_server_url = \"https://server.codeium.test\""
                ]),
                sqlite: FakeSQLite(value: #"{"apiKey":"devin-session-token$app"}"#)
            ),
            usageClient: DevinUsageClient(http: httpClient)
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .cancelled)
        XCTAssertEqual(httpClient.requests.count, 1)
        XCTAssertTrue(httpClient.requests[0].url.absoluteString.contains("server.codeium.test"))
    }

    func testRefreshReturnsLoginHintWithoutAuth() async {
        let provider = DevinProvider(
            authStore: DevinAuthStore(files: FakeFiles(), sqlite: FakeSQLite()),
            usageClient: DevinUsageClient(http: QueueHTTPClient())
        )

        let detected = await provider.hasLocalCredentials()
        XCTAssertFalse(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.lines.first?.label, "Error")
        XCTAssertEqual(errorText(snapshot.lines), DevinAuthError.notLoggedIn.localizedDescription)
        // The final fallback must carry a real telemetry category (regression: it once used the
        // message-only factory, leaving errorCategory nil so failures bucketed as `other`).
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    func testUnreadableCredentialsFileKeepsProviderVisibleAndReportsCredentialAccess() async {
        let http = QueueHTTPClient()
        let provider = DevinProvider(
            authStore: DevinAuthStore(
                files: UnreadableDevinFiles(path: DevinAuthStore.credentialsPath),
                sqlite: FakeSQLite()
            ),
            usageClient: DevinUsageClient(http: http)
        )

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        XCTAssertEqual(errorText(snapshot.lines), DevinAuthError.credentialsUnreadable.localizedDescription)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testUnreadableAppDatabaseKeepsProviderVisibleAndReportsCredentialAccess() async {
        let http = QueueHTTPClient()
        let provider = DevinProvider(
            authStore: DevinAuthStore(files: FakeFiles(), sqlite: UnreadableDevinSQLite()),
            usageClient: DevinUsageClient(http: http)
        )

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        XCTAssertEqual(errorText(snapshot.lines), DevinAuthError.credentialsUnreadable.localizedDescription)
        XCTAssertTrue(http.requests.isEmpty)
    }

    private func errorText(_ lines: [MetricLine]) -> String? {
        guard case .badge(_, let text, _, _) = lines.first else {
            return nil
        }
        return text
    }

    func testServerErrorIsReportedWithItsStatusAndLogged() async throws {
        DiagnosticGate.clearFailure(DevinProvider.httpFailureDiagnosticKeyPrefix + "503")
        let http = QueueHTTPClient(responses: [
            HTTPResponse(statusCode: 503, headers: [:], body: Data("{}".utf8))
        ])
        let provider = DevinProvider(
            authStore: DevinAuthStore(files: FakeFiles(), sqlite: FakeSQLite(value: #"{"apiKey":"devin-session-token$app"}"#)),
            usageClient: DevinUsageClient(http: http)
        )

        let (snapshot, logs) = try await captureLogs { await provider.refresh() }

        XCTAssertEqual(snapshot.errorCategory, .http5xx)
        XCTAssertTrue(errorText(snapshot.lines)?.contains("503") == true, errorText(snapshot.lines) ?? "no message")
        XCTAssertTrue(logs.contains("HTTP 503"), "a server failure must leave a log line: \(logs)")
    }

    func testUnreadableResponseIsReportedAsADecodingProblemAndLogged() async throws {
        DiagnosticGate.clearFailure(DevinProvider.invalidResponseDiagnosticKey)
        let http = QueueHTTPClient(responses: [
            HTTPResponse(statusCode: 200, headers: [:], body: Data("{\"unexpected\":true}".utf8))
        ])
        let provider = DevinProvider(
            authStore: DevinAuthStore(files: FakeFiles(), sqlite: FakeSQLite(value: #"{"apiKey":"devin-session-token$app"}"#)),
            usageClient: DevinUsageClient(http: http)
        )

        let (snapshot, logs) = try await captureLogs { await provider.refresh() }

        XCTAssertEqual(snapshot.errorCategory, .decoding)
        XCTAssertNotEqual(errorText(snapshot.lines), DevinUsageError.quotaUnavailable.localizedDescription,
                          "a schema change must not read like a missing quota")
        XCTAssertTrue(logs.contains("could not be read"), "an unreadable payload must leave a log line: \(logs)")
    }

    func testTransportFailureIsReportedAsAConnectionProblemAndLogged() async throws {
        DiagnosticGate.clearFailure(DevinProvider.transportFailureDiagnosticKey)
        let provider = DevinProvider(
            authStore: DevinAuthStore(files: FakeFiles(), sqlite: FakeSQLite(value: #"{"apiKey":"devin-session-token$app"}"#)),
            usageClient: DevinUsageClient(http: ThrowingDevinHTTPClient())
        )

        let (snapshot, logs) = try await captureLogs { await provider.refresh() }

        XCTAssertEqual(snapshot.errorCategory, .network)
        XCTAssertTrue(errorText(snapshot.lines)?.contains("reach Devin") == true, errorText(snapshot.lines) ?? "no message")
        XCTAssertTrue(logs.contains("transport"), "a transport failure must leave a log line: \(logs)")
    }

    /// Run a refresh with the log sink pointed at a temporary file so the diagnostics it writes can
    /// be asserted.
    private func captureLogs(
        _ operation: () async -> ProviderSnapshot
    ) async throws -> (ProviderSnapshot, String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.Devin.\(UUID().uuidString)", isDirectory: true)
        let sink = LogFile(directory: directory, fileName: "OpenUsage.log")
        sink.open()
        let originalSink = AppLog.sink
        AppLog.sink = sink
        AppLog.reloadLevel(.warn)
        defer {
            AppLog.sink = originalSink
            AppLog.reloadLevel()
            try? FileManager.default.removeItem(at: directory)
        }

        let snapshot = await operation()
        let logs = try String(contentsOf: sink.fileURL, encoding: .utf8)
        return (snapshot, logs)
    }
}

private func makeUserStatus(planName: String = "Max") -> [String: Any] {
    [
        "planStatus": [
            "planInfo": [
                "planName": planName,
                "billingStrategy": "BILLING_STRATEGY_QUOTA"
            ],
            "dailyQuotaRemainingPercent": 100,
            "weeklyQuotaRemainingPercent": 40,
            "overageBalanceMicros": "964220000",
            "dailyQuotaResetAtUnix": "1774080000",
            "weeklyQuotaResetAtUnix": "1774166400"
        ]
    ]
}

private func makeUserStatusBody(planName: String = "Max") throws -> Data {
    try JSONSerialization.data(withJSONObject: ["userStatus": makeUserStatus(planName: planName)])
}

private func requestBody(_ request: HTTPRequest?) throws -> [String: Any] {
    let data = try XCTUnwrap(request?.body)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private final class FakeSQLite: SQLiteAccessing, @unchecked Sendable {
    var value: String?
    var lastPath: String?
    var lastSQL: String?

    init(value: String? = nil) {
        self.value = value
    }

    func queryValue(path: String, sql: String) throws -> String? {
        lastPath = path
        lastSQL = sql
        return value
    }

    func execute(path: String, sql: String) throws {}
}

private struct UnreadableDevinSQLite: SQLiteAccessing {
    func queryValue(path: String, sql: String) throws -> String? {
        throw SQLiteError.queryFailed("injected Devin state database read failure")
    }

    func execute(path: String, sql: String) throws {}
}

private struct UnreadableDevinFiles: TextFileAccessing {
    let path: String

    func exists(_ path: String) -> Bool {
        path == self.path
    }

    func readTextIfPresent(_ path: String) throws -> String? {
        guard path == self.path else { return nil }
        throw CocoaError(.fileReadNoPermission)
    }

    func readText(_ path: String) throws -> String {
        throw CocoaError(.fileReadNoPermission)
    }

    func writeText(_ path: String, _ text: String) throws {}
    func remove(_ path: String) throws {}
}

private final class QueueHTTPClient: HTTPClient, @unchecked Sendable {    var responses: [HTTPResponse]
    var requests: [HTTPRequest] = []

    init(responses: [HTTPResponse] = []) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            return HTTPResponse(statusCode: 500, headers: [:], body: Data("{}".utf8))
        }
        return responses.removeFirst()
    }
}

private struct ThrowingDevinHTTPClient: HTTPClient {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw URLError(.notConnectedToInternet)
    }
}
