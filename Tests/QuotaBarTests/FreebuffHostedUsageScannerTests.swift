import Foundation
import XCTest
@testable import QuotaBar

final class FreebuffHostedUsageScannerTests: XCTestCase {
    private let now = TestLocalInstant.date(2026, 10, 31, 18)
    private let auth = FreebuffAuth(token: "fixture-token")
    private let prefix = "/api/v1/cloud/history/"

    private func run(status: String = "completed", model: String = "vendor/model", agent: String = "codebuff") -> [String: Any] {
        ["id": "run-1", "chatId": "chat-1", "status": status, "model": model, "agent": agent,
         "createdAt": "2026-10-31T10:00:00Z", "finishedAt": status == "completed" ? "2026-10-31T10:10:00Z" : NSNull()]
    }
    private func chats(_ run: [String: Any], revision: String = "a") throws -> HTTPResponse {
        try page([["id": "chat-1", "updatedAt": revision, "latestRun": run]])
    }
    private func metric(_ input: Int, output: Int = 50) -> [String: Any] {
        ["kind": "metrics", "payload": ["usage": ["inputTokens": input, "outputTokens": output,
          "cachedInputTokens": input / 2, "totalTokens": input + output]]]
    }
    private func page(_ items: [[String: Any]], next: String? = nil, end: String? = nil) throws -> HTTPResponse {
        var value: [String: Any] = ["items": items, "nextCursor": next as Any? ?? NSNull()]
        if let end { value["endCursor"] = end }
        return HTTPResponse(statusCode: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: value))
    }

    func testOnlyLatestCumulativeReceiptCountsAndNonMetricContentIsIgnored() async throws {
        let http = HostedHTTP([
            prefix + "chats": [try chats(run())],
            prefix + "chats/chat-1/runs": [try page([run()])],
            prefix + "runs/run-1/events": [try page([
                ["kind": "user", "payload": "PRIVATE CONVERSATION"], metric(100), metric(550)
            ], end: "3")]
        ])
        let scanner = FreebuffHostedUsageScanner(cacheURL: nil)
        let receipts = try await scanner.scan(auth: auth, client: FreebuffUsageClient(http: http), now: now)
        XCTAssertEqual(receipts.count, 1)
        XCTAssertFalse(receipts[0].metricsJSON.contains("PRIVATE"))
        let local = FreebuffDesktopUsageScanner(databasePaths: { [] })
        let totals = try await local.scan(now: now, hostedReceipts: receipts)
        XCTAssertEqual(totals?.usage.series.daily.first?.totalTokens, 600, "150 then 600 are snapshots, not 750 tokens")
        XCTAssertEqual(totals?.usage.modelUsage?.daily.first?.models.first?.model, "vendor/model")
        _ = try await scanner.scan(auth: auth, client: FreebuffUsageClient(http: http), now: now)
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.url.path.hasSuffix("/events") }.count, 1)
        XCTAssertEqual(requests.filter { $0.url.path.hasSuffix("/runs") }.count, 1,
                       "unchanged completed chats require only the lightweight chat list")
    }

    func testActiveRunResumesCursorAndFinalReceiptSurvivesCompletionWithoutNewEvents() async throws {
        let active = run(status: "running")
        let http = HostedHTTP([
            prefix + "chats": [try chats(active), try chats(active), try chats(run(), revision: "b")],
            prefix + "chats/chat-1/runs": [try page([active]), try page([active]), try page([run()])],
            prefix + "runs/run-1/events": [try page([metric(100)], end: "event-1")],
            prefix + "runs/run-1/events?cursor=event-1": [try page([metric(200)], end: "event-2")],
            prefix + "runs/run-1/events?cursor=event-2": [try page([], end: "event-2")]
        ])
        let scanner = FreebuffHostedUsageScanner(cacheURL: nil)
        let client = FreebuffUsageClient(http: http)
        _ = try await scanner.scan(auth: auth, client: client, now: now)
        let updated = try await scanner.scan(auth: auth, client: client, now: now)
        let finished = try await scanner.scan(auth: auth, client: client, now: now)
        XCTAssertEqual(updated.first?.metricsJSON, finished.first?.metricsJSON)
        let local = FreebuffDesktopUsageScanner(databasePaths: { [] })
        let totals = try await local.scan(now: now, hostedReceipts: finished)
        XCTAssertEqual(totals?.usage.series.daily.first?.totalTokens, 250)
        XCTAssertEqual(finished.first?.timestampMs, OpenUsageISO8601.date(from: "2026-10-31T10:10:00Z")!.timeIntervalSince1970 * 1000)
    }

    func testCachePersistsOnlyReceiptsAndCannotCrossAccounts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("receipts.json")
        defer {
            let trash = Process()
            trash.executableURL = URL(fileURLWithPath: "/usr/bin/trash")
            trash.arguments = ["-v", directory.path]
            try? trash.run()
            trash.waitUntilExit()
        }
        let http = HostedHTTP([
            prefix + "chats": [try chats(run())],
            prefix + "chats/chat-1/runs": [try page([run()])],
            prefix + "runs/run-1/events": [try page([metric(100), ["kind": "user", "payload": "PRIVATE"]], end: "2")]
        ])
        let scanner = FreebuffHostedUsageScanner(cacheURL: url)
        let first = try await scanner.scan(auth: auth, client: FreebuffUsageClient(http: http), now: now)
        let file = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(file.contains(auth.token))
        XCTAssertFalse(file.contains("PRIVATE"))
        let restored = FreebuffHostedUsageScanner(cacheURL: url)
        let cached = await restored.cachedReceipts(auth: auth)
        XCTAssertEqual(cached, first)
        let wrongAccount = await restored.cachedReceipts(auth: FreebuffAuth(token: "other-token"))
        XCTAssertTrue(wrongAccount.isEmpty)
        _ = try await restored.scan(auth: auth, client: FreebuffUsageClient(http: http), now: now)
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.url.path.hasSuffix("/events") }.count, 1, "relaunch does not download completed runs again")
    }

    func testFailureOnLaterPageDoesNotAdvanceCachedCursorOrReplaceGoodReceipt() async throws {
        let active = run(status: "running")
        let http = HostedHTTP([
            prefix + "chats": [try chats(active)],
            prefix + "chats/chat-1/runs": [try page([active])],
            prefix + "runs/run-1/events": [try page([metric(100)], end: "1")],
            prefix + "runs/run-1/events?cursor=1": [try page([metric(200)], next: "2", end: "2")],
            prefix + "runs/run-1/events?cursor=2": [HTTPResponse(statusCode: 503, headers: [:], body: Data())]
        ])
        let scanner = FreebuffHostedUsageScanner(cacheURL: nil)
        let initial = try await scanner.scan(auth: auth, client: FreebuffUsageClient(http: http), now: now)
        do {
            _ = try await scanner.scan(auth: auth, client: FreebuffUsageClient(http: http), now: now)
            XCTFail("later-page failures must not publish partial history as complete")
        } catch { XCTAssertEqual(error as? FreebuffUsageError, .requestFailed(503)) }
        let cached = await scanner.cachedReceipts(auth: auth)
        XCTAssertEqual(cached, initial)
    }

    func testNativeAndBYOKRunsAreExcludedAndBadCountsFailLoudly() async throws {
        for excluded in [run(agent: "codex"), run(model: "byok:connection:1")] {
            let http = HostedHTTP([prefix + "chats": [try chats(excluded)], prefix + "chats/chat-1/runs": [try page([excluded])]])
            let scanner = FreebuffHostedUsageScanner(cacheURL: nil)
            let receipts = try await scanner.scan(auth: auth, client: FreebuffUsageClient(http: http), now: now)
            XCTAssertTrue(receipts.isEmpty)
            let requests = await http.requests
            XCTAssertFalse(requests.contains { $0.url.path.hasSuffix("/events") })
        }
        let http = HostedHTTP([
            prefix + "chats": [try chats(run())], prefix + "chats/chat-1/runs": [try page([run()])],
            prefix + "runs/run-1/events": [try page([metric(-1)])]
        ])
        do {
            _ = try await FreebuffHostedUsageScanner(cacheURL: nil).scan(auth: auth, client: FreebuffUsageClient(http: http), now: now)
            XCTFail("negative counts must not enter the cache")
        } catch { XCTAssertEqual(error as? FreebuffUsageError, .invalidResponse) }
    }

    func testHostedReceiptWinsOverOlderLocalCopyOfSameRun() async throws {
        let local = FreebuffDesktopUsageScanner(sqlite: ReceiptSQLite(), databasePaths: { ["/fixture/legacy.db"] })
        let metrics = #"{"usage":{"inputTokens":200,"outputTokens":50}}"#
        let receipt = FreebuffUsageReceipt(id: "cloud:run-1", timestampMs: now.addingTimeInterval(-60).timeIntervalSince1970 * 1000,
                                          metricsJSON: metrics, model: "vendor/model")
        let scan = try await local.scan(now: now, hostedReceipts: [receipt])
        XCTAssertEqual(scan?.usage.series.daily.reduce(0) { $0 + $1.totalTokens }, 250)
    }

    @MainActor
    func testProviderPublishesHostedTodayAndMetersNeverFetchHistoryOrCatalog() async throws {
        let http = HostedHTTP([
            "/api/v1/freebuff/session": [HTTPResponse(statusCode: 404, headers: [:], body: Data())],
            prefix + "chats": [try chats(run())], prefix + "chats/chat-1/runs": [try page([run()])],
            prefix + "runs/run-1/events": [try page([metric(100)], end: "1")],
            "/api/v1/freebuff/models": [HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"protocol":1,"rows":[{"key":"vendor/model","displayName":"Model"}]}"#.utf8))]
        ])
        let date = now
        let provider = FreebuffProvider(
            historyScanner: FreebuffDesktopUsageScanner(databasePaths: { [] }),
            hostedScanner: FreebuffHostedUsageScanner(cacheURL: nil),
            authStore: FreebuffAuthStore(
                files: FakeFiles(["/fixture/.config/manicode/credentials.json": #"{"default":{"authToken":"fixture-token"}}"#]),
                keychain: FakeKeychain(), environment: FakeEnvironment(), homeDirectory: { URL(fileURLWithPath: "/fixture") }),
            usageClient: FreebuffUsageClient(http: http), now: { date }, modelCatalog: FreebuffModelCatalog(cacheURL: nil),
            pricing: { .empty }
        )
        _ = await ProviderRefreshContext.$scope.withValue(.menuBar) { await provider.refresh() }
        let meterRequests = await http.requests
        XCTAssertEqual(meterRequests.map(\.url.path), ["/api/v1/freebuff/session"])
        let snapshot = await provider.refresh()
        guard case .values(_, let values, _, _, _, _) = snapshot.line(label: "Today") else {
            return XCTFail("hosted-only usage must publish Today without a legacy SQLite database")
        }
        XCTAssertEqual(values.first { $0.kind == .count }?.number, 150)
        XCTAssertNil(snapshot.warning)
        XCTAssertNil(snapshot.historyWarning)
        XCTAssertEqual(provider.widgetDescriptors.first { $0.historyResource != nil }?.historyResource?.scope, .accountWide)
    }

    @MainActor
    func testFailedHostedHistoryWarningSurvivesSuccessfulQuotaRefresh() async throws {
        let http = HostedHTTP([
            "/api/v1/freebuff/session": [HTTPResponse(statusCode: 404, headers: [:], body: Data())],
            prefix + "chats": [HTTPResponse(statusCode: 503, headers: [:], body: Data())]
        ])
        let provider = FreebuffProvider(
            historyScanner: FreebuffDesktopUsageScanner(databasePaths: { [] }),
            hostedScanner: FreebuffHostedUsageScanner(cacheURL: nil),
            authStore: FreebuffAuthStore(
                files: FakeFiles(["/fixture/.config/manicode/credentials.json": #"{"default":{"authToken":"fixture-token"}}"#]),
                keychain: FakeKeychain(), environment: FakeEnvironment(), homeDirectory: { URL(fileURLWithPath: "/fixture") }),
            usageClient: FreebuffUsageClient(http: http), modelCatalog: FreebuffModelCatalog(cacheURL: nil)
        )
        let failed = await provider.refresh()
        XCTAssertNotNil(failed.historyWarning)
        let meters = await ProviderRefreshContext.$scope.withValue(.menuBar) { await provider.refresh() }
        let merged = meters.mergingMenuBarUpdate(over: failed)
        XCTAssertEqual(merged.historyWarning, failed.historyWarning,
                       "a successful session poll says nothing about missing token receipts")
    }

    func testRealSQLiteCloudRequestIDIsDeduplicatedWithHostedReceipt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            let trash = Process()
            trash.executableURL = URL(fileURLWithPath: "/usr/bin/trash")
            trash.arguments = ["-v", directory.path]
            try? trash.run()
            trash.waitUntilExit()
        }
        let db = directory.appendingPathComponent("history.db").path
        let sqlite = SQLiteCLIAccessor()
        try sqlite.execute(path: db, sql: """
        CREATE TABLE threads(id TEXT, model TEXT, harness_id TEXT);
        CREATE TABLE messages(thread_id TEXT, seq INTEGER, request_id TEXT, ts INTEGER, metrics_json TEXT, role TEXT);
        INSERT INTO threads VALUES ('t', 'vendor/model', 'codebuff');
        INSERT INTO messages VALUES ('t', 1, 'cloud:run-1', 1793440800000,
          '{"usage":{"inputTokens":100,"outputTokens":50}}', 'assistant');
        """)
        let scanner = FreebuffDesktopUsageScanner(databasePaths: { [db] })
        let receipt = FreebuffUsageReceipt(id: "cloud:run-1", timestampMs: 1793440800000,
                                          metricsJSON: #"{"usage":{"inputTokens":200,"outputTokens":50}}"#, model: "vendor/model")
        let scan = try await scanner.scan(now: now, hostedReceipts: [receipt])
        XCTAssertEqual(scan?.usage.series.daily.reduce(0) { $0 + $1.totalTokens }, 250)
    }
}

private actor HostedHTTP: HTTPClient {
    var responses: [String: [HTTPResponse]]
    var requests: [HTTPRequest] = []
    init(_ responses: [String: [HTTPResponse]]) { self.responses = responses }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url.host, "www.codebuff.com")
        if request.url.path.contains("/cloud/history/") {
            XCTAssertEqual(request.headers["x-freebuff-device-chats"], "1", "the new Desktop histories are hidden without this compatibility header")
            let limit = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "limit" }?.value
            XCTAssertEqual(limit, request.url.path.hasSuffix("/events") ? "500" : "100")
        }
        XCTAssertNil(request.body)
        let cursor = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value
        let key = request.url.path + (cursor.map { "?cursor=" + $0 } ?? "")
        guard let response = responses[key]?.first else {
            XCTFail("unexpected history request: \(key)")
            throw FreebuffUsageError.invalidResponse
        }
        if responses[key]!.count > 1 { responses[key]?.removeFirst() }
        return response
    }
}

private struct ReceiptSQLite: SQLiteAccessing {
    func queryValue(path: String, sql: String) throws -> String? {
        #"[{"id":"cloud:run-1","timestamp":"1793440800000","metrics":"{\"usage\":{\"inputTokens\":100,\"outputTokens\":50}}"}]"#
    }
    func execute(path: String, sql: String) throws { XCTFail("read-only history") }
}
