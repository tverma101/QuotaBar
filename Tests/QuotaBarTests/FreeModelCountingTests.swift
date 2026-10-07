import XCTest
@testable import QuotaBar

/// A model the pricing feeds have never heard of, whose name says it is free.
///
/// This is not a hypothetical: `space-bunny-free` used to be served through CodexRouter, was priced in
/// no source, and the gateway fold dropped every unpriced row's tokens. A ledger carrying 2.09B tokens
/// of it showed ~20M on the card — the other 99% silently discarded as "unknown". It has since left the
/// free period (paid on the OpenCode GO plan, opencode.ai/docs/go verified 2026-10-06) and is pinned to
/// the GO card in the supplement with its calibration excluded — so the zero-count specimens below are
/// the still-unlisted `-free` names and the explicit $0 pins (`deepseek-v4-flash-free`, `mimo-v2.5-free`,
/// `mimo-v2.5-pro-free`).
///
/// Being absent from every catalog is not the same as being free, and withholding measured usage is the
/// worse error.
final class FreeModelCountingTests: XCTestCase {
    private let pricing = TestPricing.bundled

    func testAnUnlistedFreeModelCountsAtZeroRatherThanVanishing() throws {
        let model = "some-unlisted-model-free"
        let rates = try XCTUnwrap(pricing.resolve(model: model), "must resolve so its tokens are counted")
        XCTAssertEqual(rates.inputPerMillion, 0)
        XCTAssertEqual(rates.outputPerMillion, 0)

        let tokens = TokenBreakdown(input: 1_726_685_734, cacheRead: 300_000, output: 10_000)
        XCTAssertEqual(try XCTUnwrap(pricing.estimatedCostDollars(model: model, tokens: tokens)), 0)
    }

    /// The once-free codename outgrew the class: it is paid now, and the bare id must reach the GO
    /// card rather than a $0 free-variant fallback. The provider-prefixed spelling still resolves
    /// (counted) via the free-variant rule at $0 — inert in practice, because the scanner strips
    /// gateway prefixes before pricing and the fold always sees the bare name.
    func testFormerFreeCodenamePricesAtTheGOCard() throws {
        let rates = try XCTUnwrap(pricing.resolve(model: "space-bunny-free"), "must resolve")
        XCTAssertEqual(rates.inputPerMillion, 0.15, "GO input rate")
        XCTAssertEqual(rates.outputPerMillion, 0.6, "GO output rate")
        XCTAssertEqual(rates.cacheReadPerMillion, 0.03, "GO cache-read rate")
        XCTAssertNotNil(pricing.resolve(model: "opencode-free/space-bunny-free"))
    }

    /// The gateway fold reads the *bare* model name, so both spellings have to resolve.
    func testBothTheBareAndPrefixedSpellingsCount() {
        XCTAssertNotNil(pricing.resolve(model: "space-bunny-free"))
        XCTAssertNotNil(pricing.resolve(model: "opencode-free/space-bunny-free"))
    }

    /// Narrow on purpose: only a final `-free` segment qualifies, and a real rate always wins.
    func testPaidAndLookalikeModelsAreNotSweptUp() {
        for model in ["gpt-6-luna", "claude-opus-4-7", "grok-4.7"] {
            XCTAssertNotEqual(pricing.resolve(model: model)?.inputPerMillion, 0, "\(model) must keep its real rate")
        }
        XCTAssertNil(pricing.resolve(model: "free-tier-model"), "not a suffix")
        XCTAssertNil(pricing.resolve(model: "model-free-beta"), "not the final segment")
        XCTAssertNil(pricing.resolve(model: "some-unknown-paid-model"), "unknown paid models stay flagged")
    }

    /// The whole point: the fold's token count must survive an unpriced-rate lookup. An unpriced rate is
    /// what makes `foldGatewayRows` discard a row's tokens entirely, so this asserts the rate resolves.
    /// The legacy free slug now prices at the GO card — the poisoned $0 DB calibration is excluded.
    func testGatewayFoldWouldCountTokensForAnUnlistedFreeModel() throws {
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
