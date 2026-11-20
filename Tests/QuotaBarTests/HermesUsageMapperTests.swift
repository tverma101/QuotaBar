import Foundation
import XCTest
@testable import QuotaBar

// Fold parity with the spend tiles: top-3 named, Other expands, unpriced slivers fold unless
// their token volume is material (tenth of the leader's, >=10M) — and an Other holding unpriced
// tokens must not present a complete-looking dollar total.

final class HermesUsageMapperTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_777_507_200)

    private func scan(models: [HermesModelUsage]) -> HermesUsageScan {
        let total = models.reduce(0) { $0 + $1.tokens }
        let cost = models.compactMap(\.costUSD).reduce(0, +)
        return HermesUsageScan(
            periods: [HermesPeriodUsage(
                period: .today,
                counts: HermesTokenCounts(input: 0, output: total, cacheRead: 0, cacheWrite: 0, reasoning: 0),
                costUSD: cost > 0 ? cost : nil,
                apiCallCount: models.count
            )],
            daily: DailyUsageSeries(daily: []),
            modelUsageByPeriod: [.today: models]
        )
    }

    private func breakdown(for models: [HermesModelUsage]) -> ModelUsageBreakdown? {
        let lines = HermesUsageMapper.lines(scan: scan(models: models), now: now)
        guard case .values(_, _, _, _, _, let breakdown) = lines.first else { return nil }
        return breakdown
    }

    func testTopThreeStayNamedAndTailFoldsIntoOther() {
        let models = (1...5).map {
            HermesModelUsage(model: "m\($0)", tokens: 1_000_000 * (6 - $0), costUSD: Double($0))
        }
        let rows = breakdown(for: models)?.models ?? []
        XCTAssertEqual(rows.map(\.model), ["m1", "m2", "m3", ModelUsageEntry.otherModelName])
        XCTAssertEqual(rows.last?.variants?.map(\.model), ["m4", "m5"])
        XCTAssertEqual(rows.last?.totalTokens, 3_000_000)
    }

    func testUnpricedSliverFoldsButMaterialUnpricedModelStaysNamed() {
        let models = [
            HermesModelUsage(model: "leader", tokens: 100_000_000, costUSD: 10),
            HermesModelUsage(model: "b", tokens: 50_000_000, costUSD: 5),
            HermesModelUsage(model: "c", tokens: 30_000_000, costUSD: 3),
            HermesModelUsage(model: "d", tokens: 20_000_000, costUSD: 2),
            // 15M unpriced: >= leader/10 and >= 10M — material, keeps its row.
            HermesModelUsage(model: "swe-2-max", tokens: 15_000_000, costUSD: nil),
            HermesModelUsage(model: "e", tokens: 10_000_000, costUSD: 1),
            // 1.5M unpriced: below the floor — folds.
            HermesModelUsage(model: "compactor", tokens: 1_500_000, costUSD: nil)
        ]
        let rows = breakdown(for: models)?.models ?? []
        XCTAssertEqual(rows.map(\.model), ["leader", "b", "c", "swe-2-max", ModelUsageEntry.otherModelName])
        XCTAssertEqual(rows.last?.variants?.map(\.model), ["d", "e", "compactor"])
    }

    func testOtherWithFoldedUnpricedTokensReportsIncompleteCost() {
        let models = [
            HermesModelUsage(model: "a", tokens: 100_000_000, costUSD: 10),
            HermesModelUsage(model: "b", tokens: 50_000_000, costUSD: 5),
            HermesModelUsage(model: "c", tokens: 30_000_000, costUSD: 3),
            HermesModelUsage(model: "d", tokens: 20_000_000, costUSD: 2),
            HermesModelUsage(model: "e", tokens: 10_000_000, costUSD: 1),
            HermesModelUsage(model: "unpriced-tail", tokens: 1_000_000, costUSD: nil)
        ]
        let other = breakdown(for: models)?.models.last
        XCTAssertEqual(other?.model, ModelUsageEntry.otherModelName)
        XCTAssertEqual(other?.hasIncompleteCost, true,
                       "an Other holding unpriced tokens must render its dollars as a lower bound")
    }
}
