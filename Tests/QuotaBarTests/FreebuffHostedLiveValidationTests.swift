import Foundation
import XCTest
@testable import QuotaBar

/// Explicit opt-in only: uses the owner's existing silent CLI login against read-only history.
final class FreebuffHostedLiveValidationTests: XCTestCase {
    func testLiveHostedReceiptsAndWarmRequestBudget() async throws {
        guard ProcessInfo.processInfo.environment["QUOTABAR_FREEBUFF_LIVE_VALIDATION"] == "1" else {
            throw XCTSkip("set QUOTABAR_FREEBUFF_LIVE_VALIDATION=1 for the authorized live check")
        }
        let auth = try XCTUnwrap(FreebuffAuthStore().loadAuth())
        let http = CountingFreebuffHTTP()
        let client = FreebuffUsageClient(http: http)
        let scanner = FreebuffHostedUsageScanner(cacheURL: nil)
        let date = Date()
        let start = ContinuousClock.now
        let receipts = try await scanner.scan(auth: auth, client: client, now: date)
        let coldDuration = start.duration(to: .now)
        let cold = await http.counts()
        let warmStart = ContinuousClock.now
        let warmReceipts = try await scanner.scan(auth: auth, client: client, now: date)
        let warmDuration = warmStart.duration(to: .now)
        let warm = await http.counts()
        XCTAssertFalse(receipts.isEmpty, "this verification requires existing hosted usage")
        let local = FreebuffDesktopUsageScanner()
        let combined = try await local.scan(now: date, hostedReceipts: warmReceipts)
        let day = DailyUsageAccumulator.dayKey(from: date)
        let tokens = combined?.usage.series.daily.first { $0.date == day }?.totalTokens
        print("FREEBUFF LIVE: runs=\(receipts.count), warmRuns=\(warmReceipts.count), todayTokens=\(tokens ?? 0)")
        print("FREEBUFF LIVE: cold=\(coldDuration), requests=\(cold.requests), eventRequests=\(cold.events), bytes=\(cold.bytes)")
        print("FREEBUFF LIVE: warm=\(warmDuration), requests=\(warm.requests-cold.requests), eventRequests=\(warm.events-cold.events), bytes=\(warm.bytes-cold.bytes)")
        XCTAssertNotNil(tokens)
    }
}

private actor CountingFreebuffHTTP: HTTPClient {
    private var requests = 0
    private var events = 0
    private var bytes = 0
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests += 1
        if request.url.path.hasSuffix("/events") { events += 1 }
        let response = try await URLSessionHTTPClient().send(request)
        bytes += response.body.count
        return response
    }
    func counts() -> (requests: Int, events: Int, bytes: Int) { (requests, events, bytes) }
}
