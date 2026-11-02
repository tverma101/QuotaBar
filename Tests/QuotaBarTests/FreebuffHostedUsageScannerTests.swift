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

    func testSparseMetricsPreserveEarlierUsageAndIncompleteFlagAcrossPagesAndRefreshes() async throws {
        let active = run(status: "running")
        var incomplete = metric(100)
        incomplete["payload"] = ["usage": ["inputTokens": 100, "outputTokens": 50], "usageIncomplete": true]
        let context: [String: Any] = ["kind": "metrics", "payload": ["context": ["usedTokens": 20]]]
        let http = HostedHTTP([
            prefix + "chats": [try chats(active)],
            prefix + "chats/chat-1/runs": [try page([active])],
            prefix + "runs/run-1/events": [try page([incomplete], next: "1", end: "1")],
            prefix + "runs/run-1/events?cursor=1": [try page([context], end: "2")],
            prefix + "runs/run-1/events?cursor=2": [try page([context], end: "3")]
        ])
        let scanner = FreebuffHostedUsageScanner(cacheURL: nil)
        let client = FreebuffUsageClient(http: http)
        for _ in 0..<2 {
            let receipts = try await scanner.scan(auth: auth, client: client, now: now)
            let totals = try await FreebuffDesktopUsageScanner(databasePaths: { [] }).scan(now: now, hostedReceipts: receipts)
            XCTAssertEqual(totals?.usage.series.daily.first?.totalTokens, 150,
                           "context-only updates must not erase previously measured tokens")
            XCTAssertEqual(totals?.partialDays, [DailyUsageAccumulator.dayKey(from: now)])
        }
    }

    func testMissingAndContextOnlyReceiptsAreUnknownRatherThanCompleteZero() async throws {
        for events: [[String: Any]] in [[], [["kind": "metrics", "payload": ["context": ["usedTokens": 20]]]]] {
            let http = HostedHTTP([
                prefix + "chats": [try chats(run())],
                prefix + "chats/chat-1/runs": [try page([run()])],
                prefix + "runs/run-1/events": [try page(events, end: "1")]
            ])
            let scanner = FreebuffHostedUsageScanner(cacheURL: nil)
            let receipts = try await scanner.scan(auth: auth, client: FreebuffUsageClient(http: http), now: now)
            XCTAssertEqual(receipts.count, 1, "a run without measurements must still report its coverage gap")
            let totals = try await FreebuffDesktopUsageScanner(databasePaths: { [] }).scan(now: now, hostedReceipts: receipts)
            XCTAssertTrue(totals?.usage.series.daily.isEmpty == true, "unknown usage must never become measured zero")
            XCTAssertEqual(totals?.partialDays, [DailyUsageAccumulator.dayKey(from: now)])
            let cached = try await scanner.cachedReceipts(auth: auth)
            XCTAssertEqual(cached, receipts)
        }
    }

    func testMissingCompletedReceiptIsRetriedWithoutChatOrRunMetadataChanging() async throws {
        let http = HostedHTTP([
            prefix + "chats": [try chats(run())],
            prefix + "chats/chat-1/runs": [try page([run()])],
            prefix + "runs/run-1/events": [try page([], end: "1")],
            prefix + "runs/run-1/events?cursor=1": [try page([metric(100)], end: "2")]
        ])
        let scanner = FreebuffHostedUsageScanner(cacheURL: nil)
        let client = FreebuffUsageClient(http: http)
        _ = try await scanner.scan(auth: auth, client: client, now: now)
        _ = try await scanner.scan(auth: auth, client: client, now: now.addingTimeInterval(60))
        let beforeRetry = await http.requests.filter { $0.url.path.hasSuffix("/events") }.count
        XCTAssertEqual(beforeRetry, 1, "missing receipts do not trigger a tight retry loop")
        let receipts = try await scanner.scan(auth: auth, client: client,
                                              now: now.addingTimeInterval(FreebuffHostedUsageScanner.incompleteReceiptRetryInterval))
        let totals = try await FreebuffDesktopUsageScanner(databasePaths: { [] }).scan(now: now, hostedReceipts: receipts)
        XCTAssertEqual(totals?.usage.series.daily.first?.totalTokens, 150)
        XCTAssertTrue(totals?.partialDays.isEmpty == true, "an actually measured receipt resolves the unknown coverage")
    }

    func testOldCacheReplaysCompletedEventsToRecoverDiscardedUsage() async throws {
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
            prefix + "runs/run-1/events": [try page([metric(100)], end: "last-event")]
        ])
        let client = FreebuffUsageClient(http: http)
        _ = try await FreebuffHostedUsageScanner(cacheURL: url).scan(auth: auth, client: client, now: now)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var runs = try XCTUnwrap(old["runs"] as? [String: [String: Any]])
        var run = try XCTUnwrap(runs["run-1"])
        run.removeValue(forKey: "metricsVersion")
        var receipt = try XCTUnwrap(run["receipt"] as? [String: Any])
        receipt["metricsJSON"] = "{}"
        run["receipt"] = receipt
        runs["run-1"] = run
        old["runs"] = runs
        try JSONSerialization.data(withJSONObject: old).write(to: url)
        let restored = FreebuffHostedUsageScanner(cacheURL: url)
        let receipts = try await restored.scan(auth: auth, client: client, now: now)
        let totals = try await FreebuffDesktopUsageScanner(databasePaths: { [] }).scan(now: now, hostedReceipts: receipts)
        XCTAssertEqual(totals?.usage.series.daily.first?.totalTokens, 150)
        let events = await http.requests.filter { $0.url.path.hasSuffix("/events") }
        XCTAssertEqual(events.count, 2, "old caches must replay once, even with unchanged completed metadata")
        XCTAssertTrue(events.allSatisfy { !($0.url.query?.contains("cursor=") ?? false) })
    }

    func testRemovingChatFromHistoryDoesNotEraseItsMeasuredUsage() async throws {
        let http = HostedHTTP([
            prefix + "chats": [try chats(run()), try page([])],
            prefix + "chats/chat-1/runs": [try page([run()])],
            prefix + "runs/run-1/events": [try page([metric(100)], end: "1")]
        ])
        let scanner = FreebuffHostedUsageScanner(cacheURL: nil)
        let client = FreebuffUsageClient(http: http)
        let before = try await scanner.scan(auth: auth, client: client, now: now)
        let after = try await scanner.scan(auth: auth, client: client, now: now)
        XCTAssertEqual(after, before, "removing a chat cannot undo tokens already consumed")
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
        await scanner.unloadCachesForMemoryPressure()
        let reloaded = try await scanner.cachedReceipts(auth: auth)
        XCTAssertEqual(reloaded, first, "memory pressure must not remove hosted tokens from offline accounting")
        let restored = FreebuffHostedUsageScanner(cacheURL: url)
        let cached = try await restored.cachedReceipts(auth: auth)
        XCTAssertEqual(cached, first)
        let wrongAccount = try await restored.cachedReceipts(auth: FreebuffAuth(token: "other-token"))
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
        let cached = try await scanner.cachedReceipts(auth: auth)
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
    func testMissingTokenReceiptPublishesCoverageWarningAndSurvivesMeterRefresh() async throws {
        let http = HostedHTTP([
            "/api/v1/freebuff/session": [HTTPResponse(statusCode: 404, headers: [:], body: Data())],
            prefix + "chats": [try chats(run())], prefix + "chats/chat-1/runs": [try page([run()])],
            prefix + "runs/run-1/events": [try page([])],
            "/api/v1/freebuff/models": [HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"protocol":1,"rows":[{"key":"vendor/model","displayName":"Model"}]}"#.utf8))]
        ])
        let date = now
        let provider = FreebuffProvider(
            historyScanner: FreebuffDesktopUsageScanner(databasePaths: { [] }),
            hostedScanner: FreebuffHostedUsageScanner(cacheURL: nil),
            authStore: FreebuffAuthStore(
                files: FakeFiles(["/fixture/.config/manicode/credentials.json": #"{"default":{"authToken":"fixture-token"}}"#]),
                keychain: FakeKeychain(), environment: FakeEnvironment(), homeDirectory: { URL(fileURLWithPath: "/fixture") }),
            usageClient: FreebuffUsageClient(http: http), now: { date }, modelCatalog: FreebuffModelCatalog(cacheURL: nil)
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.historyWarning, "Some Freebuff runs have no complete token receipt. Totals include only measured usage.")
        XCTAssertEqual(snapshot.usageHistory?.partialDays, [DailyUsageAccumulator.dayKey(from: now)])
        XCTAssertNil(snapshot.line(label: "Today"), "missing measurements do not fabricate a zero-token tile")
        let meters = await ProviderRefreshContext.$scope.withValue(.menuBar) { await provider.refresh() }
        XCTAssertEqual(meters.mergingMenuBarUpdate(over: snapshot).historyWarning, snapshot.historyWarning)
    }

    func testUnmeasuredHostedReceiptKeepsMeasuredDesktopCopyAndMarksCoverageGap() async throws {
        let local = FreebuffDesktopUsageScanner(sqlite: ReceiptSQLite(), databasePaths: { ["/fixture/legacy.db"] })
        let receipt = FreebuffUsageReceipt(id: "cloud:run-1", timestampMs: 1793440800000,
                                          metricsJSON: "{}", model: "vendor/model")
        let scan = try await local.scan(now: now, hostedReceipts: [receipt])
        XCTAssertEqual(scan?.usage.series.daily.reduce(0) { $0 + $1.totalTokens }, 150)
        XCTAssertEqual(scan?.partialDays, [DailyUsageAccumulator.dayKey(from: now)])
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

    func testLegacyAssistantRowsWithoutMetricsKeepTheirCoverageGap() async throws {
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
        INSERT INTO messages VALUES ('t', 1, 'r1', 1793440800000, NULL, 'assistant');
        INSERT INTO messages VALUES ('t', 2, 'r2', 1793440800000, '{}', 'assistant');
        INSERT INTO messages VALUES ('t', 3, 'r3', 1793440800000, '', 'assistant');
        """)
        let scan = try await FreebuffDesktopUsageScanner(databasePaths: { [db] }).scan(now: now)
        XCTAssertTrue(scan?.usage.series.daily.isEmpty == true)
        XCTAssertEqual(scan?.partialDays, [DailyUsageAccumulator.dayKey(from: now)],
                       "filtering empty metrics out of SQLite makes missing history look complete")
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
