import XCTest
@testable import QuotaBar

final class AntigravityHistoryRenderingTests: XCTestCase {
    func testIncompleteAntigravityTrendKeepsItsOwnExplanationAfterSnapshotMerge() throws {
        let now = TestLocalInstant.date(2026, 10, 21, 12)
        let day = DailyUsageAccumulator.dayKey(from: now)
        let history = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [DailyUsageEntry(date: day, totalTokens: 100, costUSD: 1)]),
            partialDays: [day]
        )
        let snapshot = ProviderSnapshot(providerID: "antigravity", displayName: "Antigravity", lines: [])
        let rendered = UsageHistorySnapshotRenderer.render(
            local: snapshot, history: history,
            descriptor: UsageHistoryDescriptor(scope: .machineLocal, estimatedCost: true, sourceNote: "From conversations"),
            now: now, combined: false
        )
        guard case .chart(_, _, let note) = rendered.line(label: "Usage Trend") else {
            return XCTFail("expected a usage trend")
        }
        XCTAssertTrue(try XCTUnwrap(note).contains("incomplete Antigravity history"))
        XCTAssertFalse(try XCTUnwrap(note).contains("Hermes"))
    }
}
