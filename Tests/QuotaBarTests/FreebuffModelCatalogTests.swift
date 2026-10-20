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
        XCTAssertEqual(FreebuffModelCatalog.openRouterRoute(for: "m-known", entries: entries, pricing: pricing),
                       "deepseek/deepseek-v4.1-flash")
        XCTAssertNil(FreebuffModelCatalog.openRouterRoute(for: "m-other", entries: entries, pricing: pricing))
    }

    func testCatalogueReadUsesCanonicalHostAndCachesWithoutHandles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
