import XCTest
@testable import QuotaBar

final class FreebuffModelCatalogTests: XCTestCase {
    func testOpaqueIdentityUsesExactVersionAndDoesNotConfuseFastOrFreeRoutes() {
        let rates = ModelRates(inputPerMillion: 2, outputPerMillion: 10,
                               cacheWritePerMillion: 2, cacheReadPerMillion: 0.2)
        let pricing = ModelPricing(supplement: PricingSupplement(), primary: PricingCatalog(),
                                   secondary: PricingCatalog(), openRouter: PricingCatalog(entries: [
                                    "deepseek/deepseek-v4.1-flash": rates,
                                    "deepseek-v4.1-flash": rates,
                                    "deepseek/deepseek-v4-flash": rates,
                                    "deepseek/deepseek-v4.1-flash:free": rates
                                   ]))
        let entries = ["m-known": FreebuffModelCatalog.Entry(key: "m-known", displayName: "DeepSeek V4.1 Flash")]
        XCTAssertEqual(FreebuffModelCatalog.pricingRoute(for: "m-known", entries: entries, pricing: pricing),
                       "deepseek/deepseek-v4.1-flash")
        XCTAssertNil(FreebuffModelCatalog.pricingRoute(for: "m-other", entries: entries, pricing: pricing))
    }

    func testFailingCatalogueBacksOffInsteadOfRetryingEveryTick() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("identities.json")
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 503, headers: [:], body: Data()))
        let catalog = FreebuffModelCatalog(cacheURL: url)
        let client = FreebuffUsageClient(http: http)
        let start = Date()

        for minute in 0..<5 {
            do {
                try await catalog.refresh(auth: FreebuffAuth(token: "test-token"), client: client, now: start.addingTimeInterval(Double(minute) * 60))
                XCTFail("the failing endpoint must keep reporting its failure")
            } catch {
                XCTAssertEqual(error as? FreebuffUsageError, .requestFailed(503))
            }
        }

        XCTAssertEqual(http.requests.count, 1, "a broken endpoint must not be re-requested on every tick")

        // The backoff expires with the retry interval.
        do {
            try await catalog.refresh(auth: FreebuffAuth(token: "test-token"), client: client, now: start.addingTimeInterval(FreebuffModelCatalog.retryInterval + 60))
            XCTFail("the endpoint is still failing")
        } catch {
            XCTAssertEqual(error as? FreebuffUsageError, .requestFailed(503))
        }
        XCTAssertEqual(http.requests.count, 2)
    }

    func testFuturePersistedFetchStampAfterClockRollbackRefetches() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("identities.json")
        let stamp = Date().addingTimeInterval(7 * 24 * 60 * 60)
        let firstHTTP = FakeHTTPClient(response: HTTPResponse(
            statusCode: 200, headers: [:],
            body: Data(#"{"protocol":1,"rows":[{"key":"old","displayName":"Old"}]}"#.utf8)
        ))
        let first = FreebuffModelCatalog(cacheURL: url)
        try await first.refresh(
            auth: FreebuffAuth(token: "test-token"),
            client: FreebuffUsageClient(http: firstHTTP),
            now: stamp
        )
        XCTAssertEqual(firstHTTP.requests.count, 1)

        // A new process reads the persisted stamp while the wall clock is a day behind it. That is
        // an expired cache, not a fresh one, so the catalogue must be fetched again.
        let secondHTTP = FakeHTTPClient(response: HTTPResponse(
            statusCode: 200, headers: [:],
            body: Data(#"{"protocol":1,"rows":[{"key":"new","displayName":"New"}]}"#.utf8)
        ))
        let restored = FreebuffModelCatalog(cacheURL: url)
        try await restored.refresh(
            auth: FreebuffAuth(token: "test-token"),
            client: FreebuffUsageClient(http: secondHTTP),
            now: stamp.addingTimeInterval(-24 * 60 * 60)
        )
        XCTAssertEqual(secondHTTP.requests.count, 1)
        let entries = await restored.current()
        XCTAssertEqual(entries["new"]?.displayName, "New")
        XCTAssertNil(entries["old"])
    }

    /// The retry backoff is an in-session stamp, but a backward clock correction (NTP, manual
    /// change) puts it in the future, where a plain `elapsed < retryInterval` check keeps the
    /// catalogue suppressed for the whole skew. Negative elapsed means elapsed: retry now.
    func testRetryBackoffAfterClockRollbackRetriesInsteadOfWaitingForTheSkew() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("identities.json")
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 503, headers: [:], body: Data()))
        let catalog = FreebuffModelCatalog(cacheURL: url)
        let client = FreebuffUsageClient(http: http)
        let start = Date()

        do {
            try await catalog.refresh(auth: FreebuffAuth(token: "test-token"), client: client, now: start)
            XCTFail("the failing endpoint must report its failure")
        } catch {
            XCTAssertEqual(error as? FreebuffUsageError, .requestFailed(503))
        }
        XCTAssertEqual(http.requests.count, 1)

        // Ten minutes backwards: the stamp is ahead of the clock, not a cooldown that runs to it.
        do {
            try await catalog.refresh(
                auth: FreebuffAuth(token: "test-token"),
                client: client,
                now: start.addingTimeInterval(-600)
            )
            XCTFail("the endpoint is still failing")
        } catch {
            XCTAssertEqual(error as? FreebuffUsageError, .requestFailed(503))
        }
        XCTAssertEqual(http.requests.count, 2, "a backward clock jump must not suppress the retry")
    }

    func testCatalogueReadUsesCanonicalHostAndCachesWithoutHandles() async throws {        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("identities.json")
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"protocol":1,"rows":[{"key":"m-known","displayName":"Model 1","handle":"must-not-persist"}]}"#.utf8)))
        let catalog = FreebuffModelCatalog(cacheURL: url)
        let client = FreebuffUsageClient(http: http)
        let now = Date()
        try await catalog.refresh(auth: FreebuffAuth(token: "test-token"), client: client, now: now)
        try await catalog.refresh(auth: FreebuffAuth(token: "test-token"), client: client, now: now.addingTimeInterval(100))
        XCTAssertEqual(http.requests.count, 1)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.url.absoluteString, "https://www.codebuff.com/api/v1/freebuff/models")
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.headers["x-freebuff-catalog-protocol"], "1")
        let saved = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(saved.contains("must-not-persist"))
        XCTAssertFalse(saved.contains("test-token"))
        let restored = FreebuffModelCatalog(cacheURL: url)
        let entries = await restored.current()
        XCTAssertEqual(entries["m-known"]?.displayName, "Model 1")
    }
}
