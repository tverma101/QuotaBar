import XCTest
@testable import QuotaBar

/// A failed or cancelled Freebuff run never produced a complete usage receipt by design, and the
/// API's `import-` runs are imported legacy history with no token metrics. Those days stay honest
/// lower bounds (`partialDays`) but must not raise the provider's actionable "missing receipt"
/// warning every cycle for a month. A completed live run that lost its receipt, or a run that
/// reported incomplete usage, is a genuine gap and keeps warning.
final class FreebuffExplainedGapTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func receipt(id: String, status: String?, metrics: String) -> FreebuffUsageReceipt {
        FreebuffUsageReceipt(
            id: id,
            timestampMs: now.addingTimeInterval(-60).timeIntervalSince1970 * 1000,
            metricsJSON: metrics,
            model: "vendor/model",
            runStatus: status
        )
    }

    private func scan(_ receipts: [FreebuffUsageReceipt]) async throws -> FreebuffDesktopUsageScanner.Scan {
        let scanner = FreebuffDesktopUsageScanner(databasePaths: { [] })
        let result = try await scanner.scan(now: now, hostedReceipts: receipts)
        return try XCTUnwrap(result)
    }

    func testFailedAndCancelledRunsWithoutUsageAreExplainedLowerBounds() async throws {
        for status in ["failed", "cancelled"] {
            let result = try await scan([receipt(id: "cloud:run-1", status: status, metrics: "{}")])
            let day = DailyUsageAccumulator.dayKey(from: now)
            XCTAssertEqual(result.partialDays, [day], "the day stays a lower bound")
            XCTAssertTrue(result.unexplainedPartialDays.isEmpty,
                          "a \(status) run never had a complete receipt by design — no actionable warning")
            XCTAssertTrue(result.usage.series.daily.isEmpty, "no usage is never manufactured into a measured zero")
        }
    }

    func testImportedLegacyHistoryWithoutUsageIsExplained() async throws {
        let result = try await scan([receipt(id: "import-abc123", status: "completed", metrics: "{}")])
        XCTAssertEqual(result.partialDays, [DailyUsageAccumulator.dayKey(from: now)])
        XCTAssertTrue(result.unexplainedPartialDays.isEmpty, "imported legacy history carries no metrics by design")
    }

    func testCompletedLiveRunMissingItsReceiptStillWarns() async throws {
        let result = try await scan([receipt(id: "cloud:run-1", status: "completed", metrics: "{}")])
        let day = DailyUsageAccumulator.dayKey(from: now)
        XCTAssertEqual(result.partialDays, [day])
        XCTAssertEqual(result.unexplainedPartialDays, [day], "a completed live run that lost its receipt is a real gap")
    }

    func testReportedIncompleteUsageStillWarnsRegardlessOfStatus() async throws {
        let metrics = #"{"usage":{"inputTokens":100,"outputTokens":50},"usageIncomplete":true}"#
        let result = try await scan([receipt(id: "cloud:run-1", status: "failed", metrics: metrics)])
        let day = DailyUsageAccumulator.dayKey(from: now)
        XCTAssertEqual(result.partialDays, [day])
        XCTAssertEqual(result.unexplainedPartialDays, [day], "a partial measurement is actionable even on a failed run")
    }

    func testFullyMeasuredReceiptIsNeitherPartialNorUnexplained() async throws {
        let metrics = #"{"usage":{"inputTokens":100,"outputTokens":50}}"#
        let result = try await scan([receipt(id: "cloud:run-1", status: "completed", metrics: metrics)])
        XCTAssertTrue(result.partialDays.isEmpty)
        XCTAssertTrue(result.unexplainedPartialDays.isEmpty)
        XCTAssertEqual(result.usage.series.daily.first?.totalTokens, 150)
    }
}
