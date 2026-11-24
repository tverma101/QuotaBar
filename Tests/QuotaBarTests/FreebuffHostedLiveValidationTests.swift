import XCTest
@testable import QuotaBar

final class FreebuffOfflineTransportTests: XCTestCase {
    func testDefaultClientCannotFetchAnyLiveData() async {
        let client = FreebuffUsageClient()
        let auth = FreebuffAuth(token: "fixture-only")
        XCTAssertFalse(client.hasTransport)
        let requests: [() async throws -> HTTPResponse] = [
            { try await client.fetchSession(auth: auth) },
            { try await client.fetchModelCatalog(auth: auth) },
            { try await client.fetchHistory(path: "chats", cursor: nil, auth: auth) }
        ]
        for request in requests {
            do {
                _ = try await request()
                XCTFail("a default client must not make a live request")
            } catch {
                XCTAssertEqual(error as? FreebuffUsageError, .liveAccessUnavailable)
            }
        }
    }

    @MainActor
    func testOfflineMeterRefreshClearsCachedLiveValuesButKeepsTokenHistory() async {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let provider = FreebuffProvider(
            historyScanner: FreebuffDesktopUsageScanner(databasePaths: { [] }),
            hostedScanner: FreebuffHostedUsageScanner(cacheURL: nil),
            now: { now }, modelCatalog: FreebuffModelCatalog(cacheURL: nil)
        )
        let today = MetricLine.values(label: "Today", values: [MetricValue(number: 1, kind: .count)])
        let previous = ProviderSnapshot.make(provider: provider.provider, plan: "Old Plan", lines: [
            .values(label: "Hours Balance", values: [MetricValue(number: 6, kind: .count)]),
            .values(label: "Monthly Spend", values: [MetricValue(number: 12, kind: .dollars)]),
            .values(label: "Active Sessions", values: [], expiriesAt: [now.addingTimeInterval(3_600)]),
            today
        ], refreshedAt: now)
        let offline = await ProviderRefreshContext.$scope.withValue(.menuBar) { await provider.refresh() }
        let result = offline.mergingMenuBarUpdate(over: previous)
        XCTAssertEqual(result.line(label: "Today"), today)
        XCTAssertNil(result.plan)
        XCTAssertEqual(result.activeSessions, [])
        XCTAssertEqual(result.line(label: "Hours Balance"), .values(label: "Hours Balance", values: []))
        XCTAssertEqual(result.line(label: "Monthly Spend"), .values(label: "Monthly Spend", values: []))
        XCTAssertEqual(result.line(label: "Active Sessions"), .values(label: "Active Sessions", values: [], expiriesAt: []))
    }
}
