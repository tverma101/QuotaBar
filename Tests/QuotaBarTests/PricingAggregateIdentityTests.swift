import XCTest
@testable import QuotaBar

final class PricingAggregateIdentityTests: XCTestCase {
    private let rates = ModelRates(inputPerMillion: 1, outputPerMillion: 2,
                                   cacheWritePerMillion: 3, cacheReadPerMillion: 0.1)

    private func snapshot(_ rates: ModelRates, retrievedAt: String? = nil,
                          supplement: PricingSupplement = PricingSupplement()) -> ModelPricing {
        ModelPricing(supplement: supplement,
                     primary: PricingCatalog(entries: ["model": rates], retrievedAt: retrievedAt),
                     secondary: PricingCatalog())
    }

    func testCatalogueRetrievalTimeDoesNotInvalidateAggregate() {
        XCTAssertEqual(snapshot(rates, retrievedAt: "2026-10-01").aggregateCacheToken,
                       snapshot(rates, retrievedAt: "2026-10-04").aggregateCacheToken)
    }

    func testEveryPricingBehaviorChangeInvalidatesAggregate() throws {
        let baseline = snapshot(rates).aggregateCacheToken
        var longContext = rates
        longContext.inputAbove200kPerMillion = 5
        var threshold = rates
        threshold.longContextThresholdTokens = 100_000
        var cachePolicy = rates
        cachePolicy.cacheReadIsExplicit = false
        var cacheWrite = rates
        cacheWrite.cacheWritePerMillion = 4
        for changed in [longContext, threshold, cachePolicy, cacheWrite] {
            XCTAssertNotEqual(baseline, snapshot(changed).aggregateCacheToken)
        }
        let alias = PricingSupplement(aliasRules: [PricingSupplement.AliasRule(
            pattern: try NSRegularExpression(pattern: "^alias$"), canonical: "model"
        )])
        XCTAssertNotEqual(baseline, snapshot(rates, supplement: alias).aggregateCacheToken)
        let fast = PricingSupplement(fastMultipliers: ["model": 6])
        XCTAssertNotEqual(baseline, snapshot(rates, supplement: fast).aggregateCacheToken)
    }
}
