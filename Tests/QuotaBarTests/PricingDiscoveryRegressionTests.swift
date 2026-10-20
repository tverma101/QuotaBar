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

    private func store(
        http: any HTTPClient,
        clock: DiscoveryClock,
        liteLLMSnapshot: Data = Data("{\"models\":{}}".utf8)
    ) -> ModelPricingStore {
        ModelPricingStore(
            http: http, cacheDirectory: directory, now: { clock.date },
            sourceURLs: [.openRouter: URL(string: "https://openrouter.ai/api/v1/models")!],
            bundledData: { name in
                if name == "pricing_supplement" { return Data("{}".utf8) }
                if name == "pricing_litellm_snapshot" { return liteLLMSnapshot }
                return Data("{\"models\":{}}".utf8)
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
        XCTAssertTrue(requests.allSatisfy { $0.url.path == "/api/v1/models" })
        XCTAssertTrue(requests.allSatisfy {
            URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems?
                .contains(where: { $0.name == "limit" && $0.value == "1000" }) == true
        })
        XCTAssertTrue(requests.allSatisfy { $0.headers["Authorization"] == nil })
        XCTAssertTrue(requests.allSatisfy { $0.headers["If-None-Match"] == nil })
    }

    func testOpenRouterFetchCollectsEveryPageBeforePricingModels() async throws {
        let clock = DiscoveryClock()
        let http = PaginatedDiscoveryHTTP(totalCount: 1_002, pageSize: 1_000)
        let store = store(http: http, clock: clock)

        await store.refreshNow()
        let pricing = await store.current()
        XCTAssertEqual(pricing.resolve(model: "example/model-1001")?.inputPerMillion, 2)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
        let offsets = requests.compactMap { request -> Int? in
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "offset" })?.value.flatMap(Int.init)
        }
        XCTAssertEqual(offsets, [0, 1_000])
        let limits = requests.compactMap { request in
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "limit" })?.value
        }
        XCTAssertEqual(limits, ["1000", "1000"])
    }

    func testFallbackPricedModelRechecksAndUsesNewOpenRouterRoute() async throws {
        let clock = DiscoveryClock()
        let http = DiscoveryHTTP()
        let fallback = PricingCatalog(entries: [
            "gemini-3.8-flash": ModelRates(
                inputPerMillion: 9, outputPerMillion: 27, cacheWritePerMillion: 9, cacheReadPerMillion: 9
            )
        ])
        let store = store(
            http: http,
            clock: clock,
            liteLLMSnapshot: try PricingCatalogCodecs.compactData(from: fallback)
        )
        await store.refreshNow()
        clock.advance(301)
        await http.setModel("gemini-3.8-flash-n")

        let before = await store.current()
        let fallbackRate = try XCTUnwrap(before.resolve(model: "gemini-3.8-flash-n"))
        XCTAssertEqual(fallbackRate.inputPerMillion, 9, "the estimate remains available during discovery")
        XCTAssertFalse(before.hasExactOpenRouterRate("gemini-3.8-flash-n"))

        await eventually { await http.count == 2 }
        await eventually { await store.current().hasExactOpenRouterRate("gemini-3.8-flash-n") }
        let updated = await store.current()
        XCTAssertEqual(updated.resolve(model: "gemini-3.8-flash-n")?.inputPerMillion, 2)
        XCTAssertNotEqual(before.aggregateCacheToken, updated.aggregateCacheToken)
        let requestCount = await http.count
        XCTAssertEqual(requestCount, 2, "the exact route clears the pending discovery candidate")
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

    func testPermanentlyUnpricedModelStopsDrivingDiscoveryFetches() async throws {
        let clock = DiscoveryClock()
        let http = DiscoveryHTTP()
        let store = store(http: http, clock: clock)
        await store.refreshNow()
        let snapshot = await store.current()
        XCTAssertNil(snapshot.resolve(model: "example/never-listed"))

        // A name the catalogue cannot price may drive at most one revalidation per 5-minute floor,
        // and only for a bounded streak of misses: every round below fetches the same catalog, so
        // the streak climbs until the name stops queuing fetches.
        // Sink-driven rounds also run asynchronously, so drive well more than the streak's worth of
        // floor-spaced rounds and assert the bound instead of a round-to-count mapping.
        var maxCount = 0
        for _ in 0..<10 {
            clock.advance(301)
            _ = await store.current()
            await store.runUnresolvedDiscoveryIfNeeded()
            let count = await http.count
            maxCount = max(maxCount, count)
        }
        XCTAssertLessThanOrEqual(maxCount, 4, "refresh + at most one fetch per miss round")

        // Past the cap the name is dropped, so elapsed time and current() calls fetch nothing. A
        // later hourly OpenRouter refresh still sees a new exact route without a per-model retry.
        clock.advance(500)
        _ = await store.current()
        await store.runUnresolvedDiscoveryIfNeeded()
        let final = await http.count
        XCTAssertEqual(final, maxCount, "a permanently unpriced name must not fetch forever")
        let pending = await store.pendingUnknownModels
        XCTAssertTrue(pending.isEmpty, "the capped name must leave the discovery queue")

        // Rebuilding from an unrelated source or a fresh hourly pass must not reset a capped model
        // and revive per-model discovery. The regular OpenRouter hourly refresh remains responsible
        // for finding future releases.
        await store.rebuildPricing()
        let rebuilt = await store.current()
        XCTAssertNil(rebuilt.resolve(model: "example/never-listed"))
        await store.runUnresolvedDiscoveryIfNeeded()
        let countAfterRebuild = await http.count
        let pendingAfterRebuild = await store.pendingUnknownModels
        XCTAssertEqual(countAfterRebuild, final, "an unrelated snapshot rebuild must preserve the miss cap")
        XCTAssertTrue(pendingAfterRebuild.isEmpty)
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
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(
            "{\"data\":[{\"id\":\"example/\(model)\",\"pricing\":{\"prompt\":\"0.000002\",\"completion\":\"0.000003\"}}],\"total_count\":1,\"links\":{\"next\":null}}".utf8
        ))
    }
}

private actor PaginatedDiscoveryHTTP: HTTPClient {
    private(set) var requests: [HTTPRequest] = []
    private let totalCount: Int
    private let pageSize: Int

    init(totalCount: Int, pageSize: Int) {
        self.totalCount = totalCount
        self.pageSize = pageSize
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false),
              let offsetValue = components.queryItems?.first(where: { $0.name == "offset" })?.value,
              let offset = Int(offsetValue),
              let limitValue = components.queryItems?.first(where: { $0.name == "limit" })?.value,
              let limit = Int(limitValue), limit == pageSize,
              offset >= 0, offset < totalCount else {
            throw URLError(.badURL)
        }

        let end = min(offset + limit, totalCount)
        let models = (offset..<end).map { index in
            [
                "id": "example/model-\(index)",
                "pricing": ["prompt": "0.000002", "completion": "0.000003"]
            ] as [String: Any]
        }
        let next: Any = end < totalCount
            ? "/api/v1/models?offset=\(end)&limit=\(limit)"
            : NSNull()
        let body = try JSONSerialization.data(withJSONObject: [
            "data": models,
            "total_count": totalCount,
            "links": ["next": next]
        ])
        return HTTPResponse(statusCode: 200, headers: [:], body: body)
    }
}
