import Foundation
import XCTest
@testable import QuotaBar

final class PricingDiscoveryRegressionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pricing-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func store(http: DiscoveryHTTP, clock: DiscoveryClock) -> ModelPricingStore {
        ModelPricingStore(
            http: http, cacheDirectory: directory, now: { clock.date },
            sourceURLs: [.openRouter: URL(string: "https://openrouter.ai/api/v1/models")!],
            bundledData: { name in
                Data((name == "pricing_supplement" ? "{}" : "{\"models\":{}}").utf8)
            }
        )
    }

    func testTenThousandRepeatedMissesDiscoverOneModelWithoutRequestStorm() async throws {
        let clock = DiscoveryClock()
        let http = DiscoveryHTTP()
        let store = store(http: http, clock: clock)
        await store.refreshNow()
        let initial = await store.current()
        clock.advance(301)
        await http.setModel("new-model")
        for _ in 0..<10_000 { XCTAssertNil(initial.resolve(model: "example/new-model")) }
        await eventually {
            _ = await store.current()
            return await http.count == 2
        }
        await eventually { await store.current().isPriced("example/new-model") }
        let priced = await store.current()
        XCTAssertEqual(priced.resolve(model: "example/new-model")?.inputPerMillion, 2)
        XCTAssertNotEqual(initial.aggregateCacheToken, priced.aggregateCacheToken)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.url.absoluteString == "https://openrouter.ai/api/v1/models" })
        XCTAssertTrue(requests.allSatisfy { $0.headers["Authorization"] == nil })
    }

    func testMissDuringCooldownRetriesWithoutNeedingAnotherResolve() async throws {
        let clock = DiscoveryClock()
        let http = DiscoveryHTTP()
        let store = store(http: http, clock: clock)
        await store.refreshNow()
        let snapshot = await store.current()
        XCTAssertNil(snapshot.resolve(model: "example/new-model"))
        await store.runUnresolvedDiscoveryIfNeeded()
        let before = await http.count
        XCTAssertEqual(before, 1)
        await http.setModel("new-model")
        clock.advance(301)
        _ = await store.current()
        await eventually {
            _ = await store.current()
            return await http.count >= 2
        }
        await eventually { await store.current().isPriced("example/new-model") }
        let retryCount = await http.count
        XCTAssertEqual(retryCount, 2)
    }

    func testDiscoveryCannotBypassThirtyMinuteFailureBackoff() async throws {
        let clock = DiscoveryClock()
        let http = DiscoveryHTTP()
        let store = store(http: http, clock: clock)
        await store.refreshNow()
        clock.advance(301)
        await http.setFailure(true)
        let snapshot = await store.current()
        XCTAssertNil(snapshot.resolve(model: "example/new-model"))
        await eventually { await http.count == 2 }
        await store.runUnresolvedDiscoveryIfNeeded()
        clock.advance(301)
        await store.reportUnknownModels(["example/another-model"])
        await store.runUnresolvedDiscoveryIfNeeded()
        let backedOff = await http.count
        XCTAssertEqual(backedOff, 2)
        await http.setFailure(false)
        await http.setModel("new-model")
        clock.advance(1_501)
        _ = await store.current()
        await eventually {
            _ = await store.current()
            return await http.count >= 3
        }
        await eventually { await store.current().isPriced("example/new-model") }
        let recoveredCount = await http.count
        XCTAssertEqual(recoveredCount, 3)
    }

    func testMenuScopeParksMissUntilFullScopeReturns() async throws {
        let clock = DiscoveryClock()
        let http = DiscoveryHTTP()
        let store = store(http: http, clock: clock)
        await store.refreshNow()
        clock.advance(301)
        await http.setModel("new-model")
        await ProviderRefreshContext.$skipModelCatalogRefresh.withValue(true) {
            let snapshot = await store.current()
            XCTAssertNil(snapshot.resolve(model: "example/new-model"))
            await store.runUnresolvedDiscoveryIfNeeded()
        }
        let parked = await http.count
        XCTAssertEqual(parked, 1)
        _ = await store.current()
        await eventually { await http.count == 2 }
        await eventually { await store.current().isPriced("example/new-model") }
    }

    private func eventually(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Discovery did not settle within two seconds", file: file, line: line)
    }
}

private final class DiscoveryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = Date(timeIntervalSince1970: 1_780_000_000)
    var date: Date { lock.withLock { instant } }
    func advance(_ seconds: TimeInterval) { lock.withLock { instant.addTimeInterval(seconds) } }
}

private actor DiscoveryHTTP: HTTPClient {
    private(set) var requests: [HTTPRequest] = []
    private var model = "old-model"
    private var fails = false
    var count: Int { requests.count }
    func setModel(_ model: String) { self.model = model }
    func setFailure(_ fails: Bool) { self.fails = fails }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        if fails { throw URLError(.notConnectedToInternet) }
        return HTTPResponse(statusCode: 200, headers: ["etag": "v\(requests.count)"], body: Data(
            "{\"data\":[{\"id\":\"example/\(model)\",\"pricing\":{\"prompt\":\"0.000002\",\"completion\":\"0.000003\"}}],\"total_count\":1,\"links\":{\"next\":null}}".utf8
        ))
    }
}
