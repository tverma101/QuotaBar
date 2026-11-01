import XCTest
@testable import QuotaBar

/// End-to-end check against the *shipped* pricing resources, not a synthetic catalog.
///
/// The report that prompted this was a real dashboard showing `anthropic/openai/gpt-5.6-luna` and
/// `gpt-5.6-luna` as two rows of one model. A synthetic-catalog test can prove the identity rule; only
/// this can prove the shipped supplement actually resolves the tagged slug to the same canonical key, so
/// the fix works for the names users really have.
final class GatewaySlugRealPricingTests: XCTestCase {
    /// The four models from the report, in both the bare and gateway-tagged spelling.
    private static let pairs: [(tagged: String, bare: String)] = [
        ("anthropic/openai/gpt-6-sol", "gpt-6-sol"),
        ("anthropic/openai/gpt-5.6-luna", "gpt-5.6-luna"),
        ("anthropic/openai/gpt-6-luna", "gpt-6-luna"),
        ("anthropic/openai/gpt-5.6-terra", "gpt-5.6-terra")
    ]

    /// Cursor's export spells DeepSeek V4.1 Flash 10/17 once per thinking effort
    /// (`deepseek-v41-flash-1017-high`). Those rows showed tokens with no dollars on the dashboard
    /// even though OpenRouter publishes the route: no bundled snapshot carries the id, and the
    /// effort-suffixed slug matched no alias, so it never reached a rate at all. The alias now
    /// collapses every effort onto the dated route, and the supplement prices that route so the
    /// dollars appear offline too, not only after a live catalogue revalidation.
    func testCursorDeepSeekEffortSlugsPriceFromTheShippedSupplement() throws {
        let pricing = TestPricing.bundled
        for slug in [
            "deepseek-v41-flash-1017-high",
            "deepseek-v41-flash-1017-medium",
            "deepseek-v41-flash-1017-max",
            "deepseek-v41-flash-1017",
            "deepseek-v4.1-flash-1017"
        ] {
            XCTAssertEqual(
                pricing.canonicalName(for: slug), "deepseek-v4.1-flash-1017",
                "\(slug) must collapse onto the dated DeepSeek route"
            )
            let cost = try XCTUnwrap(
                pricing.estimatedCursorCostDollars(
                    model: slug,
                    tokens: TokenBreakdown(input: 1_000_000, output: 1_000_000),
                    applyLongContextRates: false
                ),
                "\(slug) must price from the shipped supplement, not only the live catalogue"
            )
            // $0.15 input + $0.60 output per million.
            XCTAssertEqual(cost, 0.75, accuracy: 1e-9, slug)
        }
    }

    /// The undated spelling maps to its own route, and the dated rule wins for the dated spelling —
    /// otherwise a snapshot-specific slug would silently inherit the base route's different rates.
    func testDeepSeekEffortSlugsKeepTheDatedRouteDistinctFromTheBase() throws {
        let pricing = TestPricing.bundled
        XCTAssertEqual(
            pricing.canonicalName(for: "deepseek-v41-flash-high"), "deepseek-v4.1-flash"
        )
        let dated = try XCTUnwrap(pricing.resolve(model: "deepseek-v4.1-flash-1017"))
        let base = try XCTUnwrap(pricing.resolve(model: "deepseek-v4.1-flash"))
        XCTAssertNotEqual(dated.outputPerMillion, base.outputPerMillion)
    }

    /// The pricing was never wrong: every model prices, and the tagged and bare spellings price
    /// identically. That is why the defect was invisible in the dollars and only showed up as two rows.
    func testTaggedAndBareSpellingsPriceIdentically() throws {
        for pair in Self.pairs {
            let tagged = try XCTUnwrap(
                TestPricing.bundled.resolve(model: pair.tagged),
                "\(pair.tagged) must price"
            )
            let bare = try XCTUnwrap(
                TestPricing.bundled.resolve(model: pair.bare),
                "\(pair.bare) must price"
            )
            XCTAssertEqual(tagged.inputPerMillion, bare.inputPerMillion, pair.tagged)
            XCTAssertEqual(tagged.outputPerMillion, bare.outputPerMillion, pair.tagged)
        }
    }

    /// Identity is the fix: the tagged slug resolves to the bare model id, so both spellings land on one
    /// row. `canonicalKey` prefers an exact supplement alias over the fuzzy match that previously adopted
    /// the whole prefixed string.
    func testTaggedSlugResolvesToTheBareModelIdentity() {
        for pair in Self.pairs {
            // The candidate ladder a scanner builds: full slug, then each suffix, shortest identity first.
            let segments = pair.tagged.split(separator: "/").map(String.init)
            let candidates = [pair.tagged] + segments.dropFirst()
            let identity = TestPricing.bundled.canonicalKey(for: candidates)
            XCTAssertEqual(
                identity, pair.bare,
                "\(pair.tagged) must be identified as \(pair.bare), not as the routing path"
            )
        }
    }

    /// The gate that keeps bare slugs distinct. `gpt-reserve` and `codex-auto-review` borrow another
    /// model's rate on purpose and must keep their own identity — "priced like" is not "is".
    func testBareSlugsThatBorrowRatesKeepTheirOwnIdentity() {
        for (slug, pricedAs) in [("gpt-reserve", "gpt-6-luna"), ("codex-auto-review", "gpt-5.2")] {
            XCTAssertEqual(
                GatewaySlug.identity(of: slug, resolvedPricingModel: pricedAs),
                slug,
                "\(slug) is its own identity even though it prices as \(pricedAs)"
            )
        }
        // `gpt-reserve` resolves through a supplement alias. `codex-auto-review` does not resolve from the
        // supplement at all — the scanner reaches it through the dated auto-review fallback, which is a
        // separate mechanism and deliberately not aliased. Either way the identity guarantee holds, which
        // is what this test is about: the rate comes from wherever it comes from, the row is still its own.
        XCTAssertNotNil(TestPricing.bundled.resolve(model: "gpt-reserve"))
        XCTAssertNil(
            TestPricing.bundled.resolve(model: "codex-auto-review"),
            "auto-review is priced by the scanner's dated fallback, not by a supplement alias"
        )
    }
}
