import XCTest
@testable import QuotaBar

/// Fetch/cache/TTL behavior of the pricing store, with stubbed HTTP, an injected clock, and tiny
/// fixture feeds.
final class ModelPricingStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pricing-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private static let bundledFixtures: @Sendable (String) -> Data? = { name in
        switch name {
        case "pricing_supplement":
            return Data("""
            {"pricing": {"auto": {"input_per_million": 1.25, "output_per_million": 6.0}},
             "fast_multipliers": {}, "alias_rules": []}
            """.utf8)
        case "pricing_litellm_snapshot":
            return Data(#"{"retrieved_at":"2026-10-13T22:08:54Z","models":{"bundled-model":{"i":1,"o":2,"cw":1,"cr":0.1}}}"#.utf8)
        case "pricing_models_dev_snapshot":
            return Data(#"{"retrieved_at":"2026-10-13T22:08:54Z","models":{"bundled-dev-model":{"i":3,"o":4,"cw":3,"cr":0.3}}}"#.utf8)
        default:
            return nil
        }
    }

    private static let litellmFeed = """
    {"fetched-model": {"input_cost_per_token": 5e-06, "output_cost_per_token": 1e-05,
                       "cache_read_input_token_cost": 5e-07}}
    """

    private static let modelsDevFeed = """
    {"xai": {"models": {"fetched-dev-model": {"cost": {"input": 1, "output": 2, "cache_read": 0.2}}}}}
    """

    private static let openRouterFeed = """
    {"data": [
      {"id": "example/fetched-openrouter-model", "pricing": {"prompt": "0.000007", "completion": "0.00002"}},
      {"id": "example/free-model:free", "pricing": {"prompt": "0", "completion": "0"}}
    ], "total_count": 2, "links": {"next": null}}
    """

    private static let supplementFeed = """
    {"pricing": {"auto": {"input_per_million": 9.0, "output_per_million": 9.0}},
     "fast_multipliers": {}, "alias_rules": []}
    """

    private func makeStore(
        handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse,
        now: @escaping @Sendable () -> Date = Date.init
    ) -> (ModelPricingStore, RoutingHTTPClient) {
        let http = RoutingHTTPClient(handler: handler)
        let store = ModelPricingStore(
            http: http,
            cacheDirectory: tempDir,
            now: now,
            bundledData: Self.bundledFixtures
        )
        return (store, http)
    }

    private static func respond(to request: HTTPRequest) -> HTTPResponse {
        let body: String
        if request.url.absoluteString.contains("litellm") {
            body = litellmFeed
        } else if request.url.host() == "openrouter.ai" {
            body = openRouterFeed
        } else if request.url.host() == "models.dev" {
            body = modelsDevFeed
        } else {
            body = supplementFeed
        }
        return HTTPResponse(statusCode: 200, headers: ["etag": "\"v1\""], body: Data(body.utf8))
    }

    func testServesBundledDataBeforeAnyFetch() async throws {
        let (store, _) = makeStore(handler: { _ in
            throw URLError(.notConnectedToInternet)
        })
        let pricing = await store.current()
        XCTAssertEqual(pricing.resolve(model: "bundled-model")?.inputPerMillion, 1)
        XCTAssertEqual(pricing.resolve(model: "bundled-dev-model")?.inputPerMillion, 3)
        XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, 1.25)
    }

    func testRefreshFetchesAllSourcesAndAppliesData() async throws {
        let (store, http) = makeStore(handler: { Self.respond(to: $0) })
        await store.refreshNow()
        XCTAssertEqual(http.requests.count, 4)

        let cachedCatalog = try PricingCatalogCodecs.catalogFromCompact(
            Data(contentsOf: tempDir.appendingPathComponent("litellm.json"))
        )
        XCTAssertNotNil(cachedCatalog.retrievedAt, "fresh caches retain a timestamp for bundle precedence")

        let pricing = await store.current()
        XCTAssertEqual(pricing.resolve(model: "fetched-model")?.inputPerMillion, 5)
        XCTAssertEqual(pricing.resolve(model: "fetched-dev-model")?.inputPerMillion, 1)
        XCTAssertEqual(pricing.resolve(model: "fetched-openrouter-model")?.inputPerMillion, 7)
        XCTAssertEqual(pricing.resolve(model: "example/free-model:free")?.inputPerMillion, 0)
        XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, 9, "fetched supplement replaces bundled")
        XCTAssertEqual(pricing.resolve(model: "bundled-model")?.inputPerMillion, 1, "bundled entries survive the merge")
    }

    func testCachePersistsAcrossStoreInstances() async throws {
        let (store, _) = makeStore(handler: { Self.respond(to: $0) })
        await store.refreshNow()

        // Second store, network dead: cached fetch results still apply.
        let (revived, http) = makeStore(handler: { _ in throw URLError(.notConnectedToInternet) })
        let pricing = await revived.current()
        XCTAssertEqual(pricing.resolve(model: "fetched-model")?.inputPerMillion, 5)
        XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, 9)
        // Fresh state file -> nothing due until the TTL elapses.
        await revived.refreshNow()
        XCTAssertTrue(http.requests.isEmpty, "sources within TTL must not refetch")
    }

    func testOlderCachedCatalogCannotOverrideNewerBundledSnapshot() async throws {
        let cached = Data(#"{"retrieved_at":"2026-01-01T00:00:00Z","models":{"bundled-model":{"i":9,"o":18,"cw":9,"cr":0.9},"cached-only-model":{"i":7,"o":14,"cw":7,"cr":0.7}}}"#.utf8)
        try cached.write(to: tempDir.appendingPathComponent("litellm.json"), options: .atomic)

        let (store, _) = makeStore(handler: { _ in throw URLError(.notConnectedToInternet) })
        let pricing = await store.current()

        XCTAssertEqual(pricing.resolve(model: "bundled-model")?.inputPerMillion, 1,
                       "the newer shipped snapshot wins conflicting cached rates while offline")
        XCTAssertEqual(pricing.resolve(model: "cached-only-model")?.inputPerMillion, 7,
                       "older cache-only models remain available")
    }

    func testNewerLegacyModelsDevCacheCannotUndoBundledConflictTombstone() async throws {
        let cached = Data(#"{"retrieved_at":"2026-10-15T00:00:00Z","models":{"ambiguous":{"i":9,"o":18,"cw":9,"cr":1.8}}}"#.utf8)
        try cached.write(to: tempDir.appendingPathComponent("models_dev.json"), options: .atomic)
        let bundledModelsDev = Data(#"{"retrieved_at":"2026-10-14T21:35:38Z","models":{},"retired":["ambiguous"]}"#.utf8)

        let store = ModelPricingStore(
            http: RoutingHTTPClient(handler: { _ in throw URLError(.notConnectedToInternet) }),
            cacheDirectory: tempDir,
            bundledData: { name in
                name == "pricing_models_dev_snapshot" ? bundledModelsDev : Self.bundledFixtures(name)
            }
        )
        let pricing = await store.current()

        XCTAssertNil(pricing.resolve(model: "ambiguous"),
                     "a legacy cache entry must not restore a model the current snapshot marks provider-conflicted")
    }

    func testNewerCompleteModelsDevCacheCanResolveBundledConflictTombstone() async throws {
        let cached = Data(#"{"retrieved_at":"2026-10-15T00:00:00Z","models":{"ambiguous":{"i":9,"o":18,"cw":9,"cr":1.8}},"retired":[]}"#.utf8)
        try cached.write(to: tempDir.appendingPathComponent("models_dev.json"), options: .atomic)
        let bundledModelsDev = Data(#"{"retrieved_at":"2026-10-14T21:35:38Z","models":{},"retired":["ambiguous"]}"#.utf8)

        let store = ModelPricingStore(
            http: RoutingHTTPClient(handler: { _ in throw URLError(.notConnectedToInternet) }),
            cacheDirectory: tempDir,
            bundledData: { name in
                name == "pricing_models_dev_snapshot" ? bundledModelsDev : Self.bundledFixtures(name)
            }
        )
        let pricing = await store.current()

        XCTAssertEqual(pricing.resolve(model: "ambiguous")?.inputPerMillion, 9,
                       "a complete refreshed cache can clear a conflict tombstone once rates agree")
    }

    func testRefetchAfterTTLSendsETagAndHandles304() async throws {
        let (store, _) = makeStore(handler: { Self.respond(to: $0) })
        await store.refreshNow()

        let later = Date().addingTimeInterval(2 * 60 * 60)
        let (aged, http) = makeStore(
            handler: { request in
                XCTAssertEqual(request.headers["If-None-Match"], "\"v1\"")
                return HTTPResponse(statusCode: 304, headers: [:], body: Data())
            },
            now: { later }
        )
        await aged.refreshNow()
        XCTAssertEqual(http.requests.count, 4, "all sources past TTL revalidate")

        let pricing = await aged.current()
        XCTAssertEqual(pricing.resolve(model: "fetched-model")?.inputPerMillion, 5, "304 keeps cached data")
    }

    func testFetchFailureKeepsServingCachedData() async throws {
        let (store, _) = makeStore(handler: { Self.respond(to: $0) })
        await store.refreshNow()

        let later = Date().addingTimeInterval(2 * 60 * 60)
        let (aged, _) = makeStore(handler: { _ in
            HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }, now: { later })
        await aged.refreshNow()
        let pricing = await aged.current()
        XCTAssertEqual(pricing.resolve(model: "fetched-model")?.inputPerMillion, 5)
        XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, 9)
    }

    func testGarbageFeedDoesNotReplaceGoodCache() async throws {
        let (store, _) = makeStore(handler: { Self.respond(to: $0) })
        await store.refreshNow()

        let later = Date().addingTimeInterval(2 * 60 * 60)
        let (aged, _) = makeStore(handler: { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data("not json".utf8))
        }, now: { later })
        await aged.refreshNow()
        let pricing = await aged.current()
        XCTAssertEqual(pricing.resolve(model: "fetched-model")?.inputPerMillion, 5)
    }

    func testSupplementSelectionPrefersTheMostRecentDatedSource() async throws {
        let scenarios: [(name: String, bundled: String?, cached: String?, expected: Double)] = [
            ("newer bundle", "2026-06-01", "2026-01-01", 4),
            ("same-day precise bundle", "2026-08-11T07:01:30Z", "2026-08-11", 4),
            ("newer cache", "2026-01-01", "2026-06-01", 9),
            ("undated cache", "2026-06-01", nil, 4),
            ("undated bundle", nil, "2026-06-01", 9)
        ]

        for scenario in scenarios {
            try writeSupplementCache(updatedAt: scenario.cached, autoInput: 9)
            let pricing = await makeStoreWithBundledSupplement(updatedAt: scenario.bundled, autoInput: 4).current()
            XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, scenario.expected, scenario.name)
        }
    }

    func testNewerBundledSupplementRetiresRemovedCachedRates() async throws {
        let cached = #"""
        {"updated_at":"2026-10-13T22:22:57Z","pricing":{"grok-4.7":{"input_per_million":2,"output_per_million":6},"grok-4.7-fast":{"input_per_million":4,"output_per_million":12},"gemini-4-argon":{"input_per_million":2,"output_per_million":10}},"alias_rules":[]}
        """#
        let bundled = #"""
        {"updated_at":"2026-10-14T13:27:52Z","pricing":{"cursor-grok-4.7":{"input_per_million":2,"output_per_million":6},"cursor-grok-4.7-fast":{"input_per_million":4,"output_per_million":12},"cursor-gemini-4-argon":{"input_per_million":2,"output_per_million":10}},"alias_rules":[],"cursor_alias_rules":[],"retired_pricing_keys":["grok-4.7","grok-4.7-fast","gemini-4-argon"]}
        """#
        try Data(cached.utf8).write(to: tempDir.appendingPathComponent("supplement.json"), options: .atomic)

        let store = ModelPricingStore(
            http: RoutingHTTPClient(handler: { _ in throw URLError(.notConnectedToInternet) }),
            cacheDirectory: tempDir,
            bundledData: { name in
                name == "pricing_supplement" ? Data(bundled.utf8) : Self.bundledFixtures(name)
            }
        )
        let pricing = await store.current()

        XCTAssertNil(pricing.supplement.pricing["grok-4.7"], "the newer bundle retires the old shared Cursor key")
        XCTAssertNil(pricing.supplement.pricing["grok-4.7-fast"])
        XCTAssertNil(pricing.supplement.pricing["gemini-4-argon"])
        XCTAssertEqual(pricing.supplement.pricing["cursor-grok-4.7"]?.inputPerMillion, 2)
    }

    func testNewerCachedSupplementCannotUndoBundledRateRetirements() async throws {
        let cached = #"""
        {"updated_at":"2026-10-15T13:27:52Z","pricing":{"grok-4.7":{"input_per_million":2,"output_per_million":6},"grok-4.7-fast":{"input_per_million":4,"output_per_million":12},"gemini-4-argon":{"input_per_million":2,"output_per_million":10}},"alias_rules":[]}
        """#
        let bundled = #"""
        {"updated_at":"2026-10-14T13:27:52Z","pricing":{"cursor-grok-4.7":{"input_per_million":2,"output_per_million":6},"cursor-grok-4.7-fast":{"input_per_million":4,"output_per_million":12},"cursor-gemini-4-argon":{"input_per_million":2,"output_per_million":10}},"alias_rules":[],"cursor_alias_rules":[],"retired_pricing_keys":["grok-4.7","grok-4.7-fast","gemini-4-argon"]}
        """#
        try Data(cached.utf8).write(to: tempDir.appendingPathComponent("supplement.json"), options: .atomic)

        let store = ModelPricingStore(
            http: RoutingHTTPClient(handler: { _ in throw URLError(.notConnectedToInternet) }),
            cacheDirectory: tempDir,
            bundledData: { name in
                name == "pricing_supplement" ? Data(bundled.utf8) : Self.bundledFixtures(name)
            }
        )
        let pricing = await store.current()

        XCTAssertNil(pricing.supplement.pricing["grok-4.7"], "a newer cache cannot undo the bundle's explicit retirement")
        XCTAssertNil(pricing.supplement.pricing["grok-4.7-fast"])
        XCTAssertNil(pricing.supplement.pricing["gemini-4-argon"])
        XCTAssertNil(pricing.resolve(model: "grok-4.7"), "retired shared Cursor pricing must not leak into provider-wide resolution")
        XCTAssertEqual(pricing.supplement.pricing["cursor-grok-4.7"]?.inputPerMillion, 2)
    }

    func testBundledAliasRetirementSuppressesNewerLegacyCachedRuleButKeepsCanonicalRate() async throws {
        let cachedSupplement = #"""
        {"updated_at":"2026-10-15T00:00:00Z","pricing":{"grok-4.7":{"input_per_million":2,"output_per_million":6}},"alias_rules":[{"pattern":"^grok-bot-cua$","canonical":"grok-4.7"}]}
        """#
        let bundledSupplement = #"""
        {"updated_at":"2026-10-14T21:49:44Z","pricing":{"cursor-grok-4.7":{"input_per_million":2,"output_per_million":6}},"alias_rules":[],"cursor_alias_rules":[],"retired_pricing_keys":["grok-4.7"],"retired_alias_patterns":["^grok-bot-cua$"]}
        """#
        let openRouterCache = Data(#"{"retrieved_at":"2026-10-14T21:00:00Z","models":{"x-ai/grok-4.7":{"i":2,"o":6,"cw":2,"cr":0.5},"grok-4.7":{"i":2,"o":6,"cw":2,"cr":0.5}}}"#.utf8)
        try Data(cachedSupplement.utf8).write(to: tempDir.appendingPathComponent("supplement.json"), options: .atomic)
        try openRouterCache.write(to: tempDir.appendingPathComponent("openrouter.json"), options: .atomic)

        let store = ModelPricingStore(
            http: RoutingHTTPClient(handler: { _ in throw URLError(.notConnectedToInternet) }),
            cacheDirectory: tempDir,
            bundledData: { name in
                name == "pricing_supplement" ? Data(bundledSupplement.utf8) : Self.bundledFixtures(name)
            }
        )
        let pricing = await store.current()

        XCTAssertNil(pricing.resolve(model: "grok-bot-cua"),
                     "the retired global product-label alias must not map an opaque label to a serving model")
        XCTAssertEqual(pricing.resolve(model: "grok-4.7")?.inputPerMillion, 2,
                       "retiring the alias must not suppress the legitimate canonical route price")
    }

    func testNewerCompleteSupplementCanReenableBundledRetiredAlias() async throws {
        let cachedSupplement = #"""
        {"updated_at":"2026-10-15T00:00:00Z","pricing":{"grok-4.7":{"input_per_million":2,"output_per_million":6}},"alias_rules":[{"pattern":"^grok-bot-cua$","canonical":"grok-4.7"}],"retired_alias_patterns":[]}
        """#
        let bundledSupplement = #"""
        {"updated_at":"2026-10-14T21:49:44Z","pricing":{"cursor-grok-4.7":{"input_per_million":2,"output_per_million":6}},"alias_rules":[],"retired_pricing_keys":["grok-4.7"],"retired_alias_patterns":["^grok-bot-cua$"]}
        """#
        let openRouterCache = Data(#"{"retrieved_at":"2026-10-14T21:00:00Z","models":{"x-ai/grok-4.7":{"i":2,"o":6,"cw":2,"cr":0.5},"grok-4.7":{"i":2,"o":6,"cw":2,"cr":0.5}}}"#.utf8)
        try Data(cachedSupplement.utf8).write(to: tempDir.appendingPathComponent("supplement.json"), options: .atomic)
        try openRouterCache.write(to: tempDir.appendingPathComponent("openrouter.json"), options: .atomic)

        let store = ModelPricingStore(
            http: RoutingHTTPClient(handler: { _ in throw URLError(.notConnectedToInternet) }),
            cacheDirectory: tempDir,
            bundledData: { name in
                name == "pricing_supplement" ? Data(bundledSupplement.utf8) : Self.bundledFixtures(name)
            }
        )
        let pricing = await store.current()

        XCTAssertTrue(pricing.supplement.retiredAliasPatternsAreAuthoritative)
        XCTAssertEqual(pricing.canonicalName(for: "grok-bot-cua"), "grok-4.7",
                       "a newer complete feed can restore a deliberately reintroduced alias")
        XCTAssertEqual(pricing.resolve(model: "grok-bot-cua")?.inputPerMillion, 2)
    }

    private static func supplementJSON(updatedAt: String?, autoInput: Double) -> String {
        let dateField = updatedAt.map { "\"updated_at\": \"\($0)\", " } ?? ""
        return """
        {\(dateField)"pricing": {"auto": {"input_per_million": \(autoInput), "output_per_million": 6.0}},
         "fast_multipliers": {}, "alias_rules": []}
        """
    }

    private func writeSupplementCache(updatedAt: String?, autoInput: Double) throws {
        try Data(Self.supplementJSON(updatedAt: updatedAt, autoInput: autoInput).utf8)
            .write(to: tempDir.appendingPathComponent("supplement.json"), options: .atomic)
    }

    /// A store whose bundled supplement carries `updatedAt`, with the network dead so only the
    /// cache-vs-bundled choice is under test.
    private func makeStoreWithBundledSupplement(updatedAt: String?, autoInput: Double) -> ModelPricingStore {
        let json = Self.supplementJSON(updatedAt: updatedAt, autoInput: autoInput)
        return ModelPricingStore(
            http: RoutingHTTPClient(handler: { _ in throw URLError(.notConnectedToInternet) }),
            cacheDirectory: tempDir,
            bundledData: { name in
                name == "pricing_supplement" ? Data(json.utf8) : Self.bundledFixtures(name)
            }
        )
    }

    func testFailureRetryIntervalPreventsHammering() async throws {
        let counter = OSAllocatedUnfairLockedCounter()
        let (store, _) = makeStore(handler: { _ in
            counter.increment()
            throw URLError(.notConnectedToInternet)
        })
        await store.refreshNow()
        XCTAssertEqual(counter.value, 4)
        // Immediately after a failure, nothing is due.
        await store.refreshNow()
        XCTAssertEqual(counter.value, 4)
    }
}

/// Tiny thread-safe counter for request counting across Sendable closures.
private final class OSAllocatedUnfairLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
