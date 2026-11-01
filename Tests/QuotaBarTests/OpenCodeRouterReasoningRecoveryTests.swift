import XCTest
@testable import QuotaBar

final class OpenCodeRouterReasoningRecoveryTests: XCTestCase {
    private let line = #"{"at":"2026-10-21T12:00:00Z","model":"opencode-free/space-bunny-free","provider":"opencode-free","status":200,"inputTokens":0,"outputTokens":0,"reasoningTokens":11856,"totalTokens":0,"estimatedInputTokens":452406}"#

    func testReasoningOnlyMeasurementDoesNotFreezeIndependentNativeHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.trashItem(at: directory, resultingItemURL: nil) }
        let ledger = directory.appendingPathComponent("usage-events.jsonl")
        try (line + "\n").write(to: ledger, atomically: true, encoding: .utf8)
        let now = OpenUsageISO8601.date(from: "2026-10-21T16:00:00Z")!
        let native = "[[\(now.timeIntervalSince1970 * 1000),1.0,50,\"native-model\",\"opencode\"]]"
        let scanner = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(data: ["/native.db": native]),
            databasePaths: { ["/native.db"] }, routerLedgerPaths: { [ledger.path] }
        )
        let result = try await scanner.scan(now: now, gatewaySources: [.codex])
        let day = try XCTUnwrap(result?.logScan.series.daily.first)
        XCTAssertEqual(day.totalTokens, 11906, "only the 11856 measured reasoning tokens join the 50 native tokens")
        XCTAssertFalse(day.costIsComplete, "missing input must keep the combined cost incomplete")
        let initialRead = try XCTUnwrap(OpenCodeUsageScanner.routerLedgerReadStatisticsForTesting(path: ledger.path)?.bytesRead)
        XCTAssertGreaterThan(initialRead, 0)
        let warm = try await scanner.scan(now: now, gatewaySources: [.codex])
        XCTAssertEqual(warm?.logScan.series.daily.first?.totalTokens, 11906)
        XCTAssertEqual(OpenCodeUsageScanner.routerLedgerReadStatisticsForTesting(path: ledger.path)?.bytesRead, initialRead,
                       "an unchanged recovered ledger must not be parsed again")
    }

    func testRecoveredRowKeepsIncompleteAccountingAndDoesNotClaimNativeCoverage() throws {
        let row = try XCTUnwrap(OpenCodeUsageScanner.routerGatewayRow(from: Data(line.utf8)))
        XCTAssertEqual(row.tokens, 11856)
        XCTAssertEqual(row.input, 0)
        XCTAssertEqual(row.output, 11856)
        XCTAssertEqual(row.routerCostBreakdownIsComplete, false)
        XCTAssertFalse(row.hasCompleteRouterCounts)
    }
}
