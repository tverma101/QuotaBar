import Foundation
import XCTest
@testable import QuotaBar

final class DevinNativePricingTests: XCTestCase {
    private let meteredTokens = TokenBreakdown(input: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)

    func testSweRatesChangeAtPublishedPacificBoundaries() throws {
        try assertEstimate(.swe2, at: "2026-12-01T07:59:59Z", equals: 0)
        try assertEstimate(.swe2, at: "2026-12-01T08:00:00Z", equals: 3.05)
        try assertEstimate(.swe2, at: "2027-01-01T08:00:00Z", equals: 18.30)
        try assertEstimate(.swe21, at: "2026-12-09T07:59:59Z", equals: 0)
        try assertEstimate(.swe21, at: "2026-12-09T08:00:00Z", equals: 3.05)
        try assertEstimate(.swe21, at: "2027-01-31T07:59:59Z", equals: 3.05)
        try assertEstimate(.swe21, at: "2027-01-31T08:00:00Z", equals: 12.20)
        try assertEstimate(.ultrafast, at: "2026-11-25T08:00:00Z", equals: 30.50)
    }

    func testFlashStopsBeingFreeAtThePublishedUTCInstant() throws {
        var tokens = meteredTokens
        tokens.cacheWrite5m = 1_000_000
        try assertEstimate(.flash, at: "2026-12-04T17:59:59Z", equals: 0, tokens: tokens)
        try assertEstimate(.flash, at: "2026-12-04T18:00:00Z", equals: 0.735, tokens: tokens)
        let paid = try XCTUnwrap(OpenUsageISO8601.date(from: "2026-12-09T08:00:00Z"))
        XCTAssertNil(DevinNativePricing.swe21.estimate(tokens: tokens, at: paid))
    }

    func testReasoningVariantsFormOneRowAndUltrafastKeepsItsOwnRates() throws {
        let timestamp = try XCTUnwrap(OpenUsageISO8601.date(from: "2026-12-09T20:00:00Z"))
        let labels = ["swe-2-1-xhigh", "SWE-2.1 (Max)", "swe-2.1-ultrafast-high"]
        let scan = DevinTranscriptUsageScanner.aggregate(
            entries: labels.map { .init(timestamp: timestamp, model: $0, tokens: meteredTokens) },
            since: timestamp,
            pricing: .empty
        )
        let day = try XCTUnwrap(scan.series.daily.first)
        let models = try XCTUnwrap(scan.modelUsage?.daily.first?.models)
        XCTAssertEqual(Set(models.map(\.model)), ["swe-2.1", "swe-2.1-ultrafast"])
        XCTAssertEqual(models.first { $0.model == "swe-2.1" }?.totalTokens, 6_000_000)
        XCTAssertEqual(day.totalTokens, 9_000_000)
        XCTAssertEqual(try XCTUnwrap(day.costUSD), 36.60, accuracy: 0.000001)
        XCTAssertTrue(scan.apiEstimateIncompleteDays?.isEmpty ?? true)
    }

    private func assertEstimate(
        _ model: DevinNativePricing,
        at instant: String,
        equals cost: Double,
        tokens: TokenBreakdown? = nil
    ) throws {
        let date = try XCTUnwrap(OpenUsageISO8601.date(from: instant))
        let estimate = try XCTUnwrap(model.estimate(tokens: tokens ?? meteredTokens, at: date))
        XCTAssertEqual(estimate, cost, accuracy: 0.000001, instant)
    }
}
