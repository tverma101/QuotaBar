import XCTest
@testable import QuotaBar

final class PricingMemoryOptimizationTests: XCTestCase {
    private func rates(_ input: Double, _ output: Double) -> ModelRates {
        ModelRates(
            inputPerMillion: input,
            outputPerMillion: output,
            cacheWritePerMillion: input,
            cacheReadPerMillion: input * 0.1
        )
    }

    func testLazyFuzzyIndexInitialization() {
        let catalog = PricingCatalog(entries: [
            "anthropic/claude-3-7-sonnet": rates(3, 15),
            "openai/gpt-4o": rates(2.5, 10)
        ])

        // Exact match should not require fuzzyIndex building
        let exact = catalog.findExact("openai/gpt-4o")
        XCTAssertNotNil(exact)
        XCTAssertEqual(exact?.rates.inputPerMillion, 2.5)

        // findFuzzy builds index on-demand and resolves variants
        let fuzzy = catalog.findFuzzy("claude-3-7-sonnet")
        XCTAssertNotNil(fuzzy)
        XCTAssertEqual(fuzzy?.key, "anthropic/claude-3-7-sonnet")
        XCTAssertEqual(fuzzy?.rates.inputPerMillion, 3)

        // Clear fuzzy index drops the cached index
        catalog.clearFuzzyIndex()

        // Re-resolving works seamlessly by reconstructing on-demand
        let reFuzzy = catalog.findFuzzy("gpt-4o")
        XCTAssertNotNil(reFuzzy)
        XCTAssertEqual(reFuzzy?.key, "openai/gpt-4o")
    }

    func testModelPricingClearCaches() {
        let catalog = PricingCatalog(entries: [
            "claude-sonnet-4": rates(3, 15)
        ])
        let pricing = ModelPricing(
            supplement: PricingSupplement(),
            primary: catalog,
            secondary: PricingCatalog()
        )

        // Resolve populates memo
        let rates = pricing.resolve(model: "claude-sonnet-4")
        XCTAssertNotNil(rates)
        XCTAssertEqual(rates?.inputPerMillion, 3)

        // clearCaches flushes internal memo and fuzzy indices without error
        pricing.clearCaches()

        // Subsequent lookup still resolves correctly
        let ratesAfter = pricing.resolve(model: "claude-sonnet-4")
        XCTAssertNotNil(ratesAfter)
        XCTAssertEqual(ratesAfter?.inputPerMillion, 3)
    }

    func testContainsWithArraySliceBoundaryBehavior() {
        let value = Array("prefix-claude-3-5-sonnet-20241022-suffix".utf8)
        let key = Array("claude-3-5-sonnet".utf8)
        XCTAssertTrue(PricingCatalog.containsKey(value, key: key))

        // Continuation of numeric version should be rejected
        let numericKey = Array("claude-sonnet-4".utf8)
        let numericContinuation = Array("claude-sonnet-4-5".utf8)
        XCTAssertFalse(PricingCatalog.containsKey(numericContinuation, key: numericKey))

        // Date suffix should be accepted
        let dateSuffix = Array("claude-sonnet-4-20250514".utf8)
        XCTAssertTrue(PricingCatalog.containsKey(dateSuffix, key: numericKey))
    }

    func testFreebuffDeepSeekRouting() {
        let pricing = TestPricing.bundled
        // Generic supplement aliases (Cursor exports etc.) still collapse bare DeepSeek spellings
        // onto the dated 10/17 route.
        XCTAssertEqual(pricing.supplement.canonicalName(for: "DeepSeek Fast"), "deepseek-v4.1-flash-1017")
        XCTAssertEqual(pricing.supplement.canonicalName(for: "DeepSeek"), "deepseek-v4.1-flash-1017")

        // The catalogue's real display names. Freebuff removed the Flash Fast mode: the key that
        // used to name it now serves the base Flash model (hosted receipts carry only the plain
        // slug), so it must price as the base model, never at the retired Fast-tier rates.
        let entries = [
            "m-096e75164d": FreebuffModelCatalog.Entry(key: "m-096e75164d", displayName: "DeepSeek V4.1 Flash Fast"),
            "m-8db1ccbba6": FreebuffModelCatalog.Entry(key: "m-8db1ccbba6", displayName: "DeepSeek V4.1 Flash"),
            "m-61c26317cc": FreebuffModelCatalog.Entry(key: "m-61c26317cc", displayName: "DeepSeek V4.1 Flash Slow")
        ]
        let routes = FreebuffModelCatalog.pricingRoutes(entries: entries, pricing: pricing)
        XCTAssertEqual(routes["m-096e75164d"], "deepseek-v4.1-flash")
        XCTAssertEqual(routes["m-8db1ccbba6"], "deepseek-v4.1-flash")
        XCTAssertNil(routes["m-61c26317cc"], "Slow mode variant should remain unpriced")
    }

    func testProcessMemoryBudgetReleaseFreePages() {
        let released = ProcessMemoryBudget.releaseAllocatorFreePages()
        XCTAssertGreaterThanOrEqual(released, 0)
    }
}
