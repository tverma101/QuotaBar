import XCTest
@testable import QuotaBar

/// Covers the Total Spend card's aggregation and metric projection: which providers contribute,
/// how slices rank per metric, Cost/MTok math, and when the combined number counts as estimated.
final class TotalSpendAggregatorTests: XCTestCase {
    private let claude = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
    private let codex = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
    private let cursor = Provider(id: "cursor", displayName: "Cursor", icon: .providerMark("cursor"))

    private func snapshot(_ provider: Provider, lines: [MetricLine]) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: lines,
            refreshedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func spendLine(
        _ label: String,
        dollars: Double? = nil,
        tokens: Double? = 1_000_000,
        estimated: Bool = false,
        unknownModels: [String] = [],
        isPartial: Bool = false,
        tokenCountSaturated: Bool = false
    ) -> MetricLine {
        var values: [MetricValue] = []
        if let dollars {
            values.append(MetricValue(
                number: dollars,
                kind: .dollars,
                estimated: estimated,
                isPartial: isPartial
            ))
        }
        if let tokens {
            values.append(MetricValue(
                number: tokens,
                kind: .count,
                label: "tokens",
                tokenCountSaturated: tokenCountSaturated ? true : nil,
                isPartial: isPartial
            ))
        }
        return .values(label: label, values: values, unknownModels: unknownModels)
    }

    func testSumsDollarsAndTokensAcrossProviders() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 2.50, tokens: 100_000, estimated: true)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 7.25, tokens: 500_000)])
        ]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude, codex, cursor], snapshots: snapshots)

        XCTAssertEqual(Set(total.slices.map(\.provider.id)), Set(["cursor", "claude"]))
        XCTAssertEqual(total.totalUSD, 9.75, accuracy: 0.0001)
        XCTAssertEqual(total.totalTokens, 600_000, accuracy: 0.0001)

        let spend = total.projection(for: .cost)
        XCTAssertEqual(spend.slices.map(\.provider.id), ["cursor", "claude"])
        XCTAssertEqual(spend.centerValue, 9.75, accuracy: 0.0001)
    }

    func testProviderWithoutPeriodLineIsExcludedNotZero() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 1.00)]),
            // Codex has spend for yesterday only — it must not appear in today's slices.
            "codex": snapshot(codex, lines: [spendLine("Yesterday", dollars: 3.00)])
        ]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude, codex], snapshots: snapshots)

        XCTAssertEqual(total.slices.map(\.provider.id), ["claude"])
    }

    func testTokensOnlyLineContributesTokensButNotSpendOrCostPerMtok() {
        let tokensOnly = spendLine("Today", dollars: nil, tokens: 500_000)
        let snapshots = ["claude": snapshot(claude, lines: [tokensOnly])]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude], snapshots: snapshots)

        XCTAssertFalse(total.isEmpty)
        XCTAssertEqual(total.slices.first?.tokenCount, 500_000)
        XCTAssertEqual(total.slices.first?.amountUSD, 0)

        XCTAssertTrue(total.projection(for: .cost).isEmpty)
        XCTAssertTrue(total.projection(for: .costPerMtok).isEmpty)

        let tokens = total.projection(for: .tokens)
        XCTAssertEqual(tokens.slices.map(\.provider.id), ["claude"])
        XCTAssertEqual(tokens.centerValue, 500_000, accuracy: 0.0001)
    }

    func testDollarsOnlyLineContributesSpendButNotCostPerMtok() {
        let dollarsOnly = spendLine("Today", dollars: 4.00, tokens: nil)
        let snapshots = ["claude": snapshot(claude, lines: [dollarsOnly])]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude], snapshots: snapshots)

        XCTAssertEqual(total.projection(for: .cost).centerValue, 4.00, accuracy: 0.0001)
        XCTAssertTrue(total.projection(for: .tokens).isEmpty)
        XCTAssertTrue(total.projection(for: .costPerMtok).isEmpty)
    }

    func testTotalIsEstimatedWhenAnySliceIsEstimated() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 2.00, estimated: true)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 4.00)])
        ]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude, cursor], snapshots: snapshots)

        XCTAssertTrue(total.isEstimated)
        XCTAssertTrue(total.projection(for: .cost).isEstimated)
        XCTAssertTrue(total.projection(for: .costPerMtok).isEstimated)
        XCTAssertFalse(total.projection(for: .tokens).isEstimated)
    }

    func testCostPerMtokRanksByRateAndBlendsTotals() {
        // Claude: $10 / 1M tokens = $10/MTok
        // Cursor: $30 / 1M tokens = $30/MTok — ranks first by rate
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 10, tokens: 1_000_000)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 30, tokens: 1_000_000)])
        ]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude, cursor], snapshots: snapshots)
        let rates = total.projection(for: .costPerMtok)

        XCTAssertEqual(rates.slices.map(\.provider.id), ["cursor", "claude"])
        XCTAssertEqual(rates.slices[0].displayAmount, 30, accuracy: 0.0001)
        XCTAssertEqual(rates.slices[1].displayAmount, 10, accuracy: 0.0001)
        // Blended center: ($40 / 2M) * 1e6 = $20/MTok
        XCTAssertEqual(rates.centerValue, 20, accuracy: 0.0001)
    }

    func testCostPerMtokExcludesIncompleteProvidersFromBlend() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 10, tokens: 1_000_000)]),
            "codex": snapshot(codex, lines: [spendLine("Today", dollars: nil, tokens: 9_000_000)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 5, tokens: nil)])
        ]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude, codex, cursor], snapshots: snapshots)
        let rates = total.projection(for: .costPerMtok)

        XCTAssertEqual(rates.slices.map(\.provider.id), ["claude"])
        XCTAssertEqual(rates.centerValue, 10, accuracy: 0.0001)
    }

    func testMixedPricedAndUnpricedUsageShowsPricedSubtotalAndMarksPartial() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine(
                "Today", dollars: 1, tokens: 1_000, unknownModels: ["opaque-model"]
            )]),
            "codex": snapshot(codex, lines: [spendLine("Today", dollars: 2, tokens: 1_000)])
        ]
        let total = TotalSpendAggregator.total(for: .today, providers: [claude, codex], snapshots: snapshots)

        let cost = total.projection(for: .cost)
        XCTAssertEqual(cost.centerValue, 3, accuracy: 0.0001)
        XCTAssertEqual(cost.slices.map(\.provider.id), ["codex", "claude"])
        XCTAssertTrue(cost.hasIncompleteCost)
        XCTAssertTrue(cost.centerValueIsLowerBound)
        XCTAssertFalse(try XCTUnwrap(cost.slices.first { $0.provider.id == "codex" }).displayAmountIsLowerBound)
        XCTAssertTrue(try XCTUnwrap(cost.slices.first { $0.provider.id == "claude" }).displayAmountIsLowerBound)
        XCTAssertFalse(cost.hasActiveSessionData, "unknown models do not imply an active session")

        let rate = total.projection(for: .costPerMtok)
        XCTAssertEqual(rate.centerValue, 2_000, accuracy: 0.0001)
        XCTAssertEqual(rate.slices.map(\.provider.id), ["codex"])
        XCTAssertTrue(rate.hasIncompleteCost)

        let tokens = total.projection(for: .tokens)
        XCTAssertEqual(tokens.centerValue, 2_000, accuracy: 0.0001)
        XCTAssertFalse(tokens.hasIncompleteCost)
    }

    func testActiveSessionIsPartialAndExcludedFromCostPerMtok() throws {
        let opencode = Provider(id: "opencode", displayName: "OpenCode", icon: .providerMark("opencode"))
        let snapshots = [
            "opencode": snapshot(opencode, lines: [spendLine(
                "Today", dollars: 2, tokens: 500, isPartial: true
            )])
        ]
        let total = TotalSpendAggregator.total(for: .today, providers: [opencode], snapshots: snapshots)
        let slice = try XCTUnwrap(total.slices.first)

        XCTAssertTrue(slice.isPartial)
        XCTAssertTrue(slice.hasIncompleteCost)
        XCTAssertEqual(total.projection(for: .cost).centerValue, 2, accuracy: 0.0001)
        XCTAssertTrue(total.projection(for: .cost).hasPartialData)
        XCTAssertTrue(total.projection(for: .cost).centerValueIsLowerBound)
        XCTAssertTrue(total.projection(for: .cost).slices.first?.displayAmountIsLowerBound == true)

        let rate = total.projection(for: .costPerMtok)
        XCTAssertTrue(rate.slices.isEmpty)
        XCTAssertTrue(rate.hasPartialData)

        let tokens = total.projection(for: .tokens)
        XCTAssertEqual(tokens.centerValue, 500, accuracy: 0.0001)
        XCTAssertTrue(tokens.hasPartialData)
        XCTAssertTrue(tokens.hasActiveSessionData)
        XCTAssertTrue(tokens.centerValueIsLowerBound)
        XCTAssertTrue(tokens.slices.first?.displayAmountIsLowerBound == true)
        XCTAssertFalse(tokens.hasIncompleteCost)
    }

    func testSaturatedTokenTotalsAreLowerBoundsAndExcludedFromCostPerMtok() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine(
                "Today", dollars: 2, tokens: Double(Int.max), tokenCountSaturated: true
            )])
        ]
        let total = TotalSpendAggregator.total(for: .today, providers: [claude], snapshots: snapshots)

        let cost = total.projection(for: .cost)
        XCTAssertEqual(cost.centerValue, 2, accuracy: 0.0001)
        XCTAssertEqual(cost.slices.map(\.provider.id), ["claude"])

        let rate = total.projection(for: .costPerMtok)
        XCTAssertTrue(rate.slices.isEmpty)
        XCTAssertTrue(rate.hasIncompleteCost)
        XCTAssertFalse(rate.hasActiveSessionData)
        XCTAssertTrue(rate.hasSaturatedTokenData)

        let tokens = total.projection(for: .tokens)
        XCTAssertTrue(tokens.centerValueIsLowerBound)
        XCTAssertTrue(tokens.slices.first?.displayAmountIsLowerBound == true)
    }

    func testFiniteDollarSumsThatOverflowRemainFiniteAndPartial() throws {
        let overflowingLine = MetricLine.values(
            label: "Today",
            values: [
                MetricValue(number: 1e308, kind: .dollars),
                MetricValue(number: 1e308, kind: .dollars),
                MetricValue(number: 100, kind: .count, label: "tokens")
            ]
        )
        let snapshots = [
            "claude": snapshot(claude, lines: [overflowingLine]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 1e308, tokens: 100)])
        ]
        let total = TotalSpendAggregator.total(for: .today, providers: [claude, cursor], snapshots: snapshots)

        let claudeSlice = try XCTUnwrap(total.slices.first { $0.provider.id == "claude" })
        XCTAssertTrue(claudeSlice.amountUSD.isFinite)
        XCTAssertEqual(claudeSlice.amountUSD, 1e308)
        XCTAssertTrue(claudeSlice.hasIncompleteCost)
        XCTAssertTrue(total.totalUSD.isFinite)

        let projection = total.projection(for: .cost)
        XCTAssertTrue(projection.centerValue.isFinite)
        XCTAssertEqual(projection.centerValue, 1e308)
        XCTAssertTrue(projection.centerValueIsLowerBound)
        XCTAssertTrue(projection.hasPartialData)
        XCTAssertTrue(try XCTUnwrap(projection.slices.first { $0.provider.id == "claude" }).displayAmountIsLowerBound)
    }

    func testSourceMarkedDollarSubtotalStaysLowerBoundAndIsExcludedFromCostRate() throws {
        let line = MetricLine.values(label: "Last 30 Days", values: [
            MetricValue(number: 1e308, kind: .dollars, isLowerBound: true),
            MetricValue(number: 1_000, kind: .count, label: "tokens")
        ])
        let total = TotalSpendAggregator.total(
            for: .last30,
            providers: [claude],
            snapshots: ["claude": snapshot(claude, lines: [line])]
        )

        let cost = total.projection(for: .cost)
        XCTAssertEqual(cost.centerValue, 1e308)
        XCTAssertTrue(cost.hasIncompleteCost)
        XCTAssertTrue(cost.centerValueIsLowerBound)
        XCTAssertTrue(try XCTUnwrap(cost.slices.first).displayAmountIsLowerBound)

        let rate = total.projection(for: .costPerMtok)
        XCTAssertTrue(rate.slices.isEmpty)
        XCTAssertTrue(rate.hasIncompleteCost)
    }

    func testFiniteTokenSumsThatOverflowRemainFiniteLowerBounds() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine(
                "Today", dollars: nil, tokens: Double.greatestFiniteMagnitude
            )]),
            "cursor": snapshot(cursor, lines: [spendLine(
                "Today", dollars: nil, tokens: Double.greatestFiniteMagnitude
            )])
        ]
        let total = TotalSpendAggregator.total(for: .today, providers: [claude, cursor], snapshots: snapshots)
        let projection = total.projection(for: .tokens)

        XCTAssertTrue(projection.centerValue.isFinite)
        XCTAssertEqual(projection.centerValue, Double.greatestFiniteMagnitude)
        XCTAssertTrue(projection.centerValueIsLowerBound)
        XCTAssertTrue(projection.hasPartialData)
    }

    func testCostPerMtokBlendsVeryLargeFiniteTokenCountsWithoutOverflow() {
        let largeTokenCount = Double.greatestFiniteMagnitude
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine(
                "Today", dollars: 1e308, tokens: largeTokenCount
            )]),
            "cursor": snapshot(cursor, lines: [spendLine(
                "Today", dollars: 1e308, tokens: largeTokenCount
            )])
        ]
        let total = TotalSpendAggregator.total(for: .today, providers: [claude, cursor], snapshots: snapshots)
        let rates = total.projection(for: .costPerMtok)

        XCTAssertTrue(rates.centerValue.isFinite)
        XCTAssertEqual(rates.centerValue, (1e308 / largeTokenCount) * 1_000_000, accuracy: 0.0001)
        XCTAssertEqual(rates.slices.count, 2)
    }

    func testVerifiedZeroCostUsageContributesTokensToBlendedCostRate() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 10, tokens: 1_000_000)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 0, tokens: 1_000_000)])
        ]
        let total = TotalSpendAggregator.total(for: .today, providers: [claude, cursor], snapshots: snapshots)

        XCTAssertEqual(total.projection(for: .costPerMtok).centerValue, 5, accuracy: 0.0001)
        XCTAssertEqual(Set(total.projection(for: .costPerMtok).slices.map(\.provider.id)), Set(["claude", "cursor"]))
    }

    func testTokensProjectionRanksByTokenCount() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 50, tokens: 100_000)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 1, tokens: 900_000)])
        ]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude, cursor], snapshots: snapshots)
        let tokens = total.projection(for: .tokens)

        XCTAssertEqual(tokens.slices.map(\.provider.id), ["cursor", "claude"])
        XCTAssertEqual(tokens.centerValue, 1_000_000, accuracy: 0.0001)
    }

    func testEmptyProjectionWhenNothingQualifies() {
        let total = TotalSpendAggregator.total(for: .today, providers: [claude], snapshots: [:])
        XCTAssertTrue(total.isEmpty)
        XCTAssertTrue(total.projection(for: .cost).isEmpty)
        XCTAssertTrue(total.projection(for: .tokens).isEmpty)
        XCTAssertTrue(total.projection(for: .costPerMtok).isEmpty)
    }
}
