import XCTest
@testable import QuotaBar

/// A `-free` suffix cannot establish that an unknown model costs $0. Known free models have explicit
/// zero-rate supplement entries, while unknown models remain visible as token-only usage with a warning.
final class FreeModelCountingTests: XCTestCase {
    private let pricing = TestPricing.bundled

    func testAnUnlistedFreeSlugRemainsUnpricedAndItsTokensStayVisible() throws {
        let model = "some-unlisted-model-free"
        XCTAssertNil(pricing.resolve(model: model), "a name suffix is not a verified rate")

        var accumulator = DailyUsageAccumulator()
        accumulator.add(day: "2026-10-13", tokens: 1_726_995_734, cost: nil, model: model)
        accumulator.addUnknownModel(day: "2026-10-13", model: model)
        let scan = accumulator.build()
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 1_726_995_734)
        XCTAssertNil(scan.modelUsage?.daily.first?.models.first?.costUSD)
        XCTAssertEqual(scan.unknownModelsByDay["2026-10-13"], [model])
    }

    /// The once-free codename outgrew the class: its explicit supplement rate beats the old free catalog entry.
    func testFormerFreeCodenamePricesAtTheGOCard() throws {
        let rates = try XCTUnwrap(pricing.resolve(model: "space-bunny-free"), "must resolve")
        XCTAssertEqual(rates.inputPerMillion, 0.15, "GO input rate")
        XCTAssertEqual(rates.outputPerMillion, 0.6, "GO output rate")
        XCTAssertEqual(rates.cacheReadPerMillion, 0.03, "GO cache-read rate")
    }

    /// The gateway fold normalizes routed model names to the bare model before pricing.
    func testGatewayModelNormalizationKeepsTheCuratedRate() {
        XCTAssertNotNil(pricing.resolve(model: "space-bunny-free"))
        XCTAssertEqual(pricing.resolve(model: "space-bunny-free")?.inputPerMillion, 0.15)
    }

    /// Unknown names stay flagged, while the curated model rates remain intact.
    func testUnknownNamesStayUnpricedAndCuratedRatesWin() {
        for model in ["gpt-6-luna", "claude-opus-4-7", "grok-4.7"] {
            XCTAssertNotEqual(pricing.resolve(model: model)?.inputPerMillion, 0, "\(model) must keep its real rate")
        }
        XCTAssertNil(pricing.resolve(model: "free-tier-model"), "not a suffix")
        XCTAssertNil(pricing.resolve(model: "model-free-beta"), "not the final segment")
        XCTAssertNil(pricing.resolve(model: "some-unknown-paid-model"), "unknown paid models stay flagged")
        XCTAssertNil(pricing.resolve(model: "some-unlisted-model-free"), "unknown free-shaped slugs need a verified rate too")
    }

    /// The legacy free slug now prices at the GO card — the poisoned $0 DB calibration is excluded.
    func testGatewayFoldCountsTokensForTheFormerFreeSlugAtPaidRates() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("qb-free-\(UUID().uuidString).jsonl")
        let stamp = OpenUsageISO8601.string(from: Date().addingTimeInterval(-600))
        let line = #"{"at":""# + stamp + #"","model":"opencode-free/space-bunny-free","provider":"opencode-free","status":200,"inputTokens":1000000,"cachedInputTokens":400000,"outputTokens":250000}"#
        try (line + "\n").write(to: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: path) }

        let rows = OpenCodeUsageScanner.routerGatewayRows(atPath: path.path, since: Date().addingTimeInterval(-3600))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].model, "space-bunny-free")
        XCTAssertEqual(rows[0].input, 600_000)
        XCTAssertEqual(rows[0].cacheRead, 400_000)
        XCTAssertEqual(rows[0].output, 250_000)

        // The figure the fold bills: the GO card at these tokens — 600k×$0.15/M + 400k×$0.03/M
        // + 250k×$0.60/M = $0.252. Without a rate this is nil and the row's tokens are dropped
        // from every total; at the free-period $0 calibration this read $0.
        let breakdown = TokenBreakdown(
            input: rows[0].input, cacheWrite5m: rows[0].cacheWrite,
            cacheRead: rows[0].cacheRead, output: rows[0].output
        )
        XCTAssertEqual(try XCTUnwrap(pricing.estimatedCostDollars(model: rows[0].model, tokens: breakdown)), 0.252, accuracy: 1e-9)
        XCTAssertEqual(rows[0].input + rows[0].cacheRead + rows[0].output, 1_250_000)
    }
}
