import Foundation
import XCTest
@testable import QuotaBar

final class OpenCodeGatewayMergeRegressionTests: XCTestCase {
    func testRouterCoverageReplacesOverlapAndNativeFillsMissingDayAndModel() {
        let today = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3_600)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        func row(_ date: Date, _ model: String, _ tokens: Int, go: Bool = true) -> OpenCodeUsageScanner.ClaudeGatewayRow {
            .init(date: date, input: tokens, output: 0, cacheWrite: 0, cacheRead: 0,
                  model: model, burnsGoQuota: go, isInProgress: false)
        }
        let router = [row(today, "space-bunny-free", 150)]
        let native = [row(today, "space-bunny-free", 100),
                      row(yesterday, "space-bunny-free", 30),
                      row(today, "another-model", 20, go: false)]
        let pricing = ModelPricing(supplement: PricingSupplement(), primary: PricingCatalog(entries: [
            "space-bunny-free": .init(inputPerMillion: 1, outputPerMillion: 1, cacheWritePerMillion: 1, cacheReadPerMillion: 1),
            "another-model": .init(inputPerMillion: 1, outputPerMillion: 1, cacheWritePerMillion: 1, cacheReadPerMillion: 1)
        ]), secondary: PricingCatalog())
        var accumulator = DailyUsageAccumulator()
        var quota: [(ms: Double, cost: Double)] = []
        var estimated = false
        var partial: Set<String> = []
        let coverage = Set(router.map(OpenCodeUsageScanner.dayModelKey))
        OpenCodeUsageScanner.foldGatewayRows(native, since: .distantPast, pricing: pricing,
            effectiveRates: [:], accumulator: &accumulator, goWindowCosts: &quota,
            includesEstimatedCost: &estimated, partialDays: &partial, skippingDayModels: coverage)
        OpenCodeUsageScanner.foldGatewayRows(router, since: .distantPast, pricing: pricing,
            effectiveRates: [:], accumulator: &accumulator, goWindowCosts: &quota,
            includesEstimatedCost: &estimated, partialDays: &partial)
        XCTAssertEqual(accumulator.build().series.daily.reduce(0) { $0 + $1.totalTokens }, 200)
        XCTAssertEqual(quota.count, 2, "the duplicated native Go turn must not burn quota twice")
        XCTAssertEqual(quota.reduce(0) { $0 + $1.cost }, 0.00018, accuracy: 1e-10)
    }
}
