import Foundation
import XCTest
@testable import QuotaBar

final class OpenCodeGatewayMergeRegressionTests: XCTestCase {
    func testNativeCodexGatewayOutputIncludesReasoningExactlyOnce() {
        let event = CodexLogUsageScanner.Event(timestamp: Date(),
            model: "anthropic/opencode_go/space-bunny-free", input: 100, cached: 25,
            output: 50, reasoning: 20, total: 150)
        let row = OpenCodeUsageScanner.codexGatewayRows(from: [event]).first
        XCTAssertEqual(row?.tokens, event.total)
        XCTAssertEqual(row?.output, 50)
        XCTAssertEqual(row?.cacheRead, 25)
    }

    func testEstimatedRouterInputKeepsMeasuredTokensButNotCompleteCost() {
        let date = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3_600)
        let day = DailyUsageAccumulator.dayKey(from: date)
        let row = OpenCodeUsageScanner.ClaudeGatewayRow(
            date: date, input: 0, output: 25, cacheWrite: 0, cacheRead: 0,
            model: "known-model", burnsGoQuota: true, isInProgress: false,
            routerInputWasEstimated: true
        )
        let pricing = ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: [
                "known-model": ModelRates(
                    inputPerMillion: 1, outputPerMillion: 1,
                    cacheWritePerMillion: 1, cacheReadPerMillion: 1
                )
            ]),
            secondary: PricingCatalog()
        )
        var accumulator = DailyUsageAccumulator()
        var goWindowCosts: [(ms: Double, cost: Double)] = []
        var includesEstimatedCost = false
        var partialDays: Set<String> = []

        OpenCodeUsageScanner.foldGatewayRows(
            [row], since: .distantPast, pricing: pricing, effectiveRates: [:],
            accumulator: &accumulator, goWindowCosts: &goWindowCosts,
            includesEstimatedCost: &includesEstimatedCost, partialDays: &partialDays
        )

        let scan = accumulator.build()
        let daily = scan.series.daily.first
        XCTAssertEqual(daily?.totalTokens, 25, "router-authored estimated input must not become tokens")
        XCTAssertFalse(daily?.costIsComplete ?? true)
        XCTAssertTrue(scan.apiEstimateIncompleteDays?.contains(day) ?? false)
        XCTAssertNil(scan.modelUsage?.daily.first?.models.first?.costUSD)
        XCTAssertTrue(scan.unknownModelsByDay.isEmpty, "known model is incomplete, not unknown")
        XCTAssertTrue(goWindowCosts.isEmpty, "an incomplete subtotal cannot feed Go dollar context")
        XCTAssertTrue(includesEstimatedCost)
    }

    func testCompactGoRetentionKeepsLifetimeHistoryAndExactRecentQuotaRows() {
        let now = Date()
        let aggregate = OpenCodeRouterLedgerAggregate.empty(path: "/tmp/synthetic-go-retention",
            revision: .init(device: 1, inode: 1, size: 0))
        for days in [60, 1] {
            aggregate.addRow(.init(date: now.addingTimeInterval(-Double(days * 86400)),
                input: 50, output: 0, cacheWrite: 0, cacheRead: 0,
                model: "space-bunny-free", burnsGoQuota: true, isInProgress: false))
        }
        XCTAssertTrue(aggregate.prune(
            before: now.addingTimeInterval(-3_660 * 86_400),
            detailedGoCutoff: now.addingTimeInterval(-45 * 86_400)
        ))
        let retained = aggregate.materialize(since: .distantPast)
        XCTAssertEqual(retained.count, 2)
        XCTAssertEqual(retained.reduce(0) { $0 + $1.tokens }, 100)
        XCTAssertEqual(retained.filter(\.isAggregated).count, 1, "old Go events compact to one daily bucket")
        XCTAssertEqual(retained.filter { !$0.isAggregated }.count, 1, "the recent quota row keeps its exact timestamp")
        XCTAssertTrue(retained.allSatisfy(\.burnsGoQuota))
        XCTAssertFalse(aggregate.prune(
            before: now.addingTimeInterval(-3_660 * 86_400),
            detailedGoCutoff: now.addingTimeInterval(-45 * 86_400)
        ))
    }

    func testCompactRouterAggregatePreservesEstimatedInputStatus() {
        let date = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3_600)
        let aggregate = OpenCodeRouterLedgerAggregate.empty(path: "/tmp/synthetic-router-completeness",
            revision: .init(device: 1, inode: 1, size: 0))
        aggregate.addRow(.init(date: date, input: 10, output: 4, cacheWrite: 0, cacheRead: 0,
            model: "space-bunny", burnsGoQuota: false, isInProgress: false,
            routerInputWasEstimated: false))
        aggregate.addRow(.init(date: date, input: 0, output: 3, cacheWrite: 0, cacheRead: 0,
            model: "space-bunny", burnsGoQuota: false, isInProgress: false,
            routerInputWasEstimated: true))

        let rows = aggregate.materialize(since: .distantPast)
        XCTAssertEqual(Set(rows.compactMap(\.routerInputWasEstimated)), Set([false, true]))
        XCTAssertTrue(OpenCodeUsageScanner.completeRouterCoverage(from: rows).isEmpty,
                      "a daily bucket with estimated input cannot suppress a complete native row")
    }

    func testSchemaFiveRouterAggregateIsRejectedForSourceRebuild() throws {
        let path = "/tmp/synthetic-router-v5-\(UUID().uuidString)"
        let url = OpenCodeRouterLedgerAggregate.fileURL(path: path)
        defer { OpenCodeRouterLedgerAggregate.removePersistedAggregate(path: path) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let legacy = [
            "schema": 5,
            "path": path,
            "timeZoneIdentifier": Calendar.current.timeZone.identifier,
            "device": 1,
            "inode": 2,
            "size": 0,
            "mtimeMillis": 0,
            "offset": 0,
            "partial": "",
            "discarding": false,
            "anchor": "",
            "buckets": [["day": "2026-10-13", "model": "space-bunny", "input": 5, "output": 0, "cacheRead": 0]],
            "goRows": []
        ] as [String: Any]
        try JSONSerialization.data(withJSONObject: legacy).write(to: url, options: .atomic)

        XCTAssertNil(OpenCodeRouterLedgerAggregate.load(path: path),
                     "v5 buckets did not carry router total-breakdown completeness and must rebuild from source")
    }

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
