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
        XCTAssertTrue(total.projection(for: .costPerMtok).isEmpty)
        XCTAssertTrue(total.projection(for: .tokens).isEmpty)
    }

    // MARK: - Dormant (disabled) contributors

    /// A turned-off provider keeps the history it already recorded, and that usage still happened.
    /// Leaving it out made the combined figure understate real spend, most visibly when a heavily
    /// used provider was switched off.
    func testDisabledProviderContributesFromItsRetainedHistory() throws {
        let now = try date("2026-10-27T18:00:00Z")
        let history = history(days: [
            ("2026-10-27", 2_000_000, 40.0),
            ("2026-10-26", 1_000_000, 20.0)
        ])

        let total = TotalSpendAggregator.total(
            for: .today,
            providers: [claude],
            snapshots: [:],
            dormantHistories: ["claude": history],
            now: now
        )

        let slice = try XCTUnwrap(total.slices.first)
        XCTAssertEqual(slice.provider.id, "claude")
        XCTAssertEqual(slice.amountUSD, 40.0, accuracy: 0.0001)
        XCTAssertEqual(slice.tokenCount, 2_000_000, accuracy: 0.0001)
        XCTAssertEqual(total.projection(for: .cost).centerValue, 40.0, accuracy: 0.0001)
    }

    /// The frozen spend tiles cannot be trusted for a dormant provider: their "Today" was computed
    /// whenever the provider was last refreshed, which may be weeks ago. The dated history is what
    /// places usage on the right day.
    func testDormantPeriodsFollowTheCalendarNotTheFrozenTiles() throws {
        let now = try date("2026-10-27T18:00:00Z")
        let history = history(days: [
            ("2026-10-27", 2_000_000, 40.0),
            ("2026-10-26", 1_000_000, 20.0),
            ("2026-10-25", 500_000, 10.0)
        ])
        // A stale snapshot whose Today tile still describes an old day.
        let stale = snapshot(claude, lines: [spendLine("Today", dollars: 999, tokens: 5_000_000)])

        let today = TotalSpendAggregator.total(
            for: .today, providers: [claude], snapshots: ["claude": stale],
            dormantHistories: [:], now: now
        )
        XCTAssertEqual(today.slices.first?.amountUSD ?? 0, 999, "an enabled provider keeps using its tiles")

        // Dormant: no snapshot at all, so the history decides — and only today's row counts.
        let dormantToday = TotalSpendAggregator.total(
            for: .today, providers: [claude], snapshots: [:],
            dormantHistories: ["claude": history], now: now
        )
        XCTAssertEqual(dormantToday.slices.first?.amountUSD ?? 0, 40.0, accuracy: 0.0001)

        let dormantYesterday = TotalSpendAggregator.total(
            for: .yesterday, providers: [claude], snapshots: [:],
            dormantHistories: ["claude": history], now: now
        )
        XCTAssertEqual(dormantYesterday.slices.first?.amountUSD ?? 0, 20.0, accuracy: 0.0001)

        let dormantLast30 = TotalSpendAggregator.total(
            for: .last30, providers: [claude], snapshots: [:],
            dormantHistories: ["claude": history], now: now
        )
        XCTAssertEqual(dormantLast30.slices.first?.amountUSD ?? 0, 70.0, accuracy: 0.0001)
    }

    /// A dormant provider with nothing in the selected window contributes nothing — it is not a
    /// fabricated zero slice, and it does not block other providers from appearing.
    func testDormantProviderWithNoUsageInTheWindowIsExcluded() throws {
        let now = try date("2026-10-27T18:00:00Z")
        let history = history(days: [("2026-09-01", 1_000_000, 25.0)])

        let total = TotalSpendAggregator.total(
            for: .today,
            providers: [claude, cursor],
            snapshots: ["cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 3, tokens: 1_000)])],
            dormantHistories: ["claude": history],
            now: now
        )

        XCTAssertEqual(total.slices.map(\.provider.id), ["cursor"])
        XCTAssertEqual(total.projection(for: .cost).centerValue, 3, accuracy: 0.0001)
    }

    /// A dormant day whose dollars are a partial subtotal keeps its known amount but still marks the
    /// combined figure as a lower bound, exactly like a live provider with unpriced models.
    func testDormantIncompleteCostKeepsSubtotalAndMarksItPartial() throws {
        let now = try date("2026-10-27T18:00:00Z")
        var history = history(days: [("2026-10-27", 1_000_000, 12.0)])
        history.series.daily[0].costIsComplete = false
        history.series.daily[0].hasUnexplainedIncompleteCost = false
        history.unknownModelsByDay = ["2026-10-27": ["some-unpriced-model"]]

        let total = TotalSpendAggregator.total(
            for: .today, providers: [claude], snapshots: [:],
            dormantHistories: ["claude": history], now: now
        )

        let cost = total.projection(for: .cost)
        XCTAssertEqual(cost.centerValue, 12.0, accuracy: 0.0001)
        XCTAssertTrue(cost.hasIncompleteCost)
        XCTAssertTrue(cost.centerValueIsLowerBound)
        XCTAssertTrue(try XCTUnwrap(cost.slices.first).displayAmountIsLowerBound)
    }

    /// The dangerous case: a dormant provider still has a retained snapshot, so a naive "use history
    /// only when there is no snapshot" rule would fall back to its frozen tiles and report weeks-old
    /// spend as today. Presence in `dormantHistories` alone must route to the dated history.
    func testDormantProviderWithARetainedSnapshotStillNeverUsesItsFrozenTiles() throws {
        let now = try date("2026-10-27T18:00:00Z")
        let stale = snapshot(claude, lines: [spendLine("Today", dollars: 500, tokens: 9_000_000)])

        // Turned off, with history for yesterday only — today has nothing.
        let history = history(days: [("2026-10-26", 1_000_000, 20.0)])
        let total = TotalSpendAggregator.total(
            for: .today,
            providers: [claude],
            snapshots: ["claude": stale],
            dormantHistories: ["claude": history],
            now: now
        )

        XCTAssertTrue(
            total.slices.isEmpty,
            "a turned-off provider's frozen Today tile must not be reported as today's spend"
        )
    }

    private func history(days: [(String, Int, Double?)]) -> ProviderUsageHistory {
        ProviderUsageHistory(series: DailyUsageSeries(daily: days.map { date, tokens, cost in
            DailyUsageEntry(date: date, totalTokens: tokens, costUSD: cost, costIsComplete: cost != nil)
        }))
    }

    private func date(_ iso: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: iso))
    }
}
