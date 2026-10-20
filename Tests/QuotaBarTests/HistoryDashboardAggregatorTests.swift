import XCTest
@testable import QuotaBar

/// The Usage History screen's fold: window clipping (exactly 30 days including today), the
/// Today/7/30 period buckets, unpriced rows (tokens count, known cost subtotal), fold-time API-rate
/// estimate totals, section ordering, and the deterministic per-model row order.
final class HistoryDashboardAggregatorTests: XCTestCase {
    private let calendar = Calendar.current

    /// Local midday, so no fixture can straddle a local midnight when the suite runs in any zone.
    private var now: Date { TestLocalInstant.date(2026, 7, 13, 12) }

    private func dayKey(offsetFromToday: Int) -> String {
        let date = calendar.date(byAdding: .day, value: offsetFromToday, to: calendar.startOfDay(for: now))!
        return DailyUsageAccumulator.dayKey(from: date, calendar: calendar)
    }

    private func makeHistory(
        daily: [(offset: Int, tokens: Int, cost: Double?)] = [],
        models: [(offset: Int, name: String, tokens: Int, cost: Double?)] = [],
        apiEstimate: [(offset: Int, estimate: Double)] = [],
        unknownModels: [(offset: Int, name: String)] = [],
        estimatedCostDays: Set<String> = []
    ) -> ProviderUsageHistory {
        let series = DailyUsageSeries(daily: daily.map { entry in
            DailyUsageEntry(date: dayKey(offsetFromToday: entry.offset), totalTokens: entry.tokens, costUSD: entry.cost)
        })
        let modelUsage = models.isEmpty ? nil : ModelUsageSeries(daily: models.map { model in
            DailyModelUsageEntry(
                date: dayKey(offsetFromToday: model.offset),
                models: [ModelUsageEntry(model: model.name, totalTokens: model.tokens, costUSD: model.cost)]
            )
        })
        let estimates = apiEstimate.isEmpty
            ? nil
            : Dictionary(uniqueKeysWithValues: apiEstimate.map { (dayKey(offsetFromToday: $0.offset), $0.estimate) })
        var unknownByDay: [String: Set<String>] = [:]
        for unknown in unknownModels {
            unknownByDay[dayKey(offsetFromToday: unknown.offset), default: []].insert(unknown.name)
        }
        return ProviderUsageHistory(
            series: series,
            modelUsage: modelUsage,
            unknownModelsByDay: unknownByDay,
            apiEstimateByDay: estimates,
            estimatedCostDays: estimatedCostDays.isEmpty ? nil : estimatedCostDays
        )
    }

    private func makeReport(
        providers: [(id: String, name: String?, history: ProviderUsageHistory?)],
        now: Date? = nil,
        estimatedCosts: [String: Bool] = [:]
    ) -> HistoryReport {
        HistoryDashboardAggregator.report(
            .init(
                enabledProviderIDs: providers.map(\.id),
                displayNameByProviderID: Dictionary(
                    providers.map { ($0.id, $0.name ?? $0.id) },
                    uniquingKeysWith: { first, _ in first }
                ),
                historyByProviderID: Dictionary(
                    providers.compactMap { provider in provider.history.map { (provider.id, $0) } },
                    uniquingKeysWith: { first, _ in first }
                ),
                estimatedCostByProviderID: estimatedCosts
            ),
            now: now ?? self.now,
            calendar: calendar
        )
    }

    // MARK: - Window

    func testWindowCoversExactly30DaysIncludingToday() {
        // Offsets -0 and -29 are inside the window; -30 is the first day outside it. UsageHistoryWindow
        // previously had an off-by-one (31 days under a "Last 30 Days" label) — pin the fix here too.
        let history = makeHistory(daily: [
            (0, 100, 1.0),
            (-29, 200, 2.0),
            (-30, 400, 4.0)
        ])
        let report = makeReport(providers: [("claude", "Claude", history)])

        XCTAssertEqual(report.last30.tokens, 300)
        XCTAssertEqual(report.days.count, 30, "the chart always contains one point per calendar day")
        XCTAssertEqual(report.days.map(\.date).first, dayKey(offsetFromToday: 0), "days list newest first")
        XCTAssertEqual(report.days.map(\.date).last, dayKey(offsetFromToday: -29))
        XCTAssertEqual(report.days.first?.tokens, 100)
        XCTAssertEqual(report.days[1].tokens, 0, "idle dates remain visible as zero-usage bars")
        XCTAssertEqual(report.days.last?.tokens, 200)
        XCTAssertFalse(report.days.contains { $0.date == dayKey(offsetFromToday: -30) })
    }

    // MARK: - Period buckets

    func testPeriodTotalsSplitTodaySevenAndThirtyDayBuckets() {
        let history = makeHistory(daily: [
            (0, 100, 1.0),
            (-3, 200, 2.0),
            (-10, 400, 4.0)
        ])
        let report = makeReport(providers: [("claude", "Claude", history)])

        XCTAssertEqual(report.today.tokens, 100)
        XCTAssertEqual(report.today.cost, 1.0)
        // 7-day bucket: offsets 0 and -3, not -10. 30-day: everything.
        XCTAssertEqual(report.last7.tokens, 300)
        XCTAssertEqual(report.last7.cost, 3.0)
        XCTAssertEqual(report.last30.tokens, 700)
        XCTAssertEqual(report.last30.cost, 7.0)
    }

    func testEstimatedCostMarkersFollowDaysIncludedByEachPeriod() throws {
        let estimatedDay = dayKey(offsetFromToday: -10)
        let history = makeHistory(
            daily: [(0, 100, 1), (-3, 200, 2), (-10, 300, 3)],
            estimatedCostDays: [estimatedDay]
        )
        let report = makeReport(
            providers: [("opencode", "OpenCode", history)],
            estimatedCosts: ["opencode": false]
        )

        XCTAssertFalse(report.today.hasEstimatedCost)
        XCTAssertFalse(report.last7.hasEstimatedCost)
        XCTAssertTrue(report.last30.hasEstimatedCost)
        XCTAssertTrue(try XCTUnwrap(report.sections.first).hasEstimatedCost)
    }

    func testUnpricedDaysKeepTokensAndShowAnyPricedSubtotalAsPartial() {
        // A day whose rows were all unpriced shows tokens with a nil cost. A period mixing priced
        // and unpriced days keeps its priced subtotal and marks it incomplete.
        let unpricedOnly = makeHistory(daily: [(0, 100, nil)])
        let report = makeReport(providers: [("claude", "Claude", unpricedOnly)])
        XCTAssertEqual(report.today.tokens, 100)
        XCTAssertNil(report.today.cost)
        XCTAssertNil(report.last30.cost)
        XCTAssertFalse(report.isEmpty)

        let mixed = makeHistory(daily: [
            (0, 100, nil),
            (-1, 200, 2.0)
        ])
        let mixedReport = makeReport(providers: [("claude", "Claude", mixed)])
        XCTAssertEqual(mixedReport.last7.tokens, 300, "unpriced tokens still count")
        XCTAssertEqual(mixedReport.last7.cost, 2, "the known priced amount stays visible as a subtotal")
        XCTAssertTrue(mixedReport.last7.hasIncompleteCost)
    }

    func testMixedPricedAndUnpricedUsageOnSameDayMarksEveryCostTotalPartial() {
        let history = makeHistory(
            daily: [(0, 300, 1.0)],
            apiEstimate: [(0, 0.8)],
            unknownModels: [(0, "mystery-model")]
        )
        let report = makeReport(providers: [("claude", "Claude", history)])

        XCTAssertEqual(report.today.tokens, 300)
        XCTAssertEqual(report.today.cost, 1)
        XCTAssertTrue(report.today.hasIncompleteCost)
        XCTAssertEqual(report.last7.cost, 1)
        XCTAssertTrue(report.last7.hasIncompleteCost)
        XCTAssertEqual(report.last30.cost, 1)
        XCTAssertTrue(report.last30.hasIncompleteCost)
        XCTAssertEqual(report.lifetime.cost, 1)
        XCTAssertTrue(report.lifetimeHasIncompleteCost)
        XCTAssertNil(report.apiEstimateTotal, "unknown models also make the API-rate comparison incomplete")
        XCTAssertTrue(try XCTUnwrap(report.sections.first).hasIncompleteCost)
        XCTAssertEqual(report.sections.first?.cost, 1)
        XCTAssertEqual(report.sections.first?.tokens, 300, "measured tokens stay visible")
    }

    func testActiveHermesSessionMarksHistoryTotalsAndModelRowsPartial() throws {
        let today = dayKey(offsetFromToday: 0)
        let history = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: today, totalTokens: 500, costUSD: 2)
            ]),
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(date: today, models: [
                    ModelUsageEntry(model: "opus", totalTokens: 400, costUSD: 1.6, costIsComplete: false),
                    ModelUsageEntry(model: "finished-model", totalTokens: 100, costUSD: 0.4)
                ])
            ]),
            apiEstimateByDay: [today: 0.75],
            partialDays: [today]
        )

        let report = makeReport(providers: [("opencode", "OpenCode", history)])

        XCTAssertEqual(report.days.first?.cost, 2)
        XCTAssertTrue(report.days.first?.hasIncompleteCost == true)
        XCTAssertEqual(report.today.cost, 2)
        XCTAssertTrue(report.today.hasIncompleteCost)
        XCTAssertTrue(report.last7.hasIncompleteCost)
        XCTAssertTrue(report.last30.hasIncompleteCost)
        XCTAssertEqual(report.lifetime.cost, 2)
        XCTAssertTrue(report.lifetimeHasIncompleteCost)
        XCTAssertEqual(report.apiEstimateTotal, 0.75)
        XCTAssertTrue(report.apiEstimateHasPartialData)
        let section = try XCTUnwrap(report.sections.first)
        XCTAssertEqual(section.cost, 2)
        XCTAssertTrue(section.hasIncompleteCost)
        XCTAssertTrue(section.rows.first?.hasIncompleteCost == true)
        XCTAssertFalse(try XCTUnwrap(section.rows.first { $0.slug == "finished-model" }).hasIncompleteCost)
    }

    func testLifetimeEstimateMarkerUsesPerDayProvenance() {
        let estimatedDay = dayKey(offsetFromToday: -31)
        let today = dayKey(offsetFromToday: 0)
        let history = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: estimatedDay, totalTokens: 200, costUSD: 2),
                DailyUsageEntry(date: today, totalTokens: 100, costUSD: 1)
            ]),
            estimatedCostDays: [estimatedDay]
        )

        let report = makeReport(
            providers: [("opencode", "OpenCode", history)],
            estimatedCosts: ["opencode": false]
        )

        XCTAssertTrue(report.lifetimeCostIsEstimated,
                      "a lifetime total with an older imputed day still needs the estimate marker")
    }

    func testLifetimeCoverageSurvivesPruningOfThirtyDayModelDetails() {
        let oldDay = dayKey(offsetFromToday: -31)
        let history = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: dayKey(offsetFromToday: 0), totalTokens: 100, costUSD: 1),
                DailyUsageEntry(date: oldDay, totalTokens: 200, costUSD: 2, costIsComplete: false)
            ]),
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(date: oldDay, models: [
                    ModelUsageEntry(model: "known-model", totalTokens: 100, costUSD: 2),
                    ModelUsageEntry(model: "mystery-model", totalTokens: 100, costUSD: nil)
                ])
            ]),
            unknownModelsByDay: [oldDay: ["mystery-model"]],
            partialDays: [oldDay],
            estimatedCostDays: [oldDay]
        )
        let retained = history.retainingHistory(through: now, calendar: calendar)
        XCTAssertNil(retained.modelUsage?.daily.first(where: { $0.date == oldDay }))
        XCTAssertNil(retained.unknownModelsByDay[oldDay])
        XCTAssertEqual(retained.partialDays, [oldDay], "lifetime partial status must survive after 30-day detail expires")
        XCTAssertEqual(retained.estimatedCostDays, [oldDay], "estimate provenance survives after 30-day detail expires")
        XCTAssertEqual(retained.series.daily.first(where: { $0.date == oldDay })?.hasUnexplainedIncompleteCost, false)
        let report = makeReport(providers: [("claude", "Claude", retained)])

        XCTAssertEqual(report.last30.tokens, 100)
        XCTAssertEqual(report.last30.cost, 1)
        XCTAssertEqual(report.lifetime.tokens, 300)
        XCTAssertEqual(report.lifetime.cost, 3, "lifetime keeps the known subtotal from incomplete days")
        XCTAssertTrue(report.lifetimeHasIncompleteCost)
    }

    func testLifetimeAPIEstimateRemainsIncompleteAfterUnknownNamesAgeOut() {
        let oldDay = dayKey(offsetFromToday: -31)
        let history = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: oldDay, totalTokens: 100, costUSD: 1)
            ]),
            unknownModelsByDay: [:],
            apiEstimateByDay: [oldDay: 0.50],
            apiEstimateIncompleteDays: [oldDay]
        )

        let report = makeReport(providers: [("claude", "Claude", history)])

        XCTAssertNil(report.lifetime.apiEstimate,
                     "the lifetime rollup must not present a partial old-day estimate as complete")
        XCTAssertNil(report.apiEstimateTotal)
    }

    // MARK: - API estimates

    func testAPIEstimateTotalsComeFromFoldTimeDayEstimates() {
        let history = makeHistory(
            daily: [(0, 100, 1.0), (-3, 200, 2.0), (-10, 400, 4.0)],
            apiEstimate: [(0, 1.5), (-3, 2.5), (-10, 5.5)]
        )
        let report = makeReport(providers: [("claude", "Claude", history)])

        XCTAssertEqual(report.today.apiEstimate, 1.5)
        XCTAssertEqual(report.last7.apiEstimate, 4.0, "only in-window estimates sum")
        XCTAssertEqual(report.last30.apiEstimate, 9.5)
        XCTAssertEqual(report.apiEstimateTotal, 9.5, "the header figure spans the recorded history")
    }

    func testNoEstimateAnywhereLeavesTheHeaderFigureOut() {
        let history = makeHistory(daily: [(0, 100, 1.0)])
        let report = makeReport(providers: [("claude", "Claude", history)])
        XCTAssertNil(report.apiEstimateTotal)
        XCTAssertNil(report.today.apiEstimate)
    }

    // MARK: - Lifetime

    func testLifetimeCountsDaysOutsideThe30DayWindow() {
        // Offset -30 is the first day outside the window (see the window test above); -90 is far
        // outside it. Both must lift the lifetime total above every period bucket — the hero figure
        // the dashboard's cards cannot show.
        let history = makeHistory(daily: [
            (0, 100, 1.0),
            (-29, 200, 2.0),
            (-30, 400, 4.0),
            (-90, 800, 8.0)
        ])
        let report = makeReport(providers: [("claude", "Claude", history)])

        XCTAssertEqual(report.last30.tokens, 300)
        XCTAssertEqual(report.lifetime.tokens, 1500)
        XCTAssertEqual(report.lifetime.cost, 15.0)
        XCTAssertGreaterThan(report.lifetime.tokens, report.last30.tokens)
    }

    func testLifetimeSinceLabelIsTheEarliestRecordedDay() {
        // -400 days back from the fixture's 2026-07-13 anchor lands in June 2025; the since caption
        // shows that month, not the anchor's.
        let history = makeHistory(daily: [
            (0, 100, 1.0),
            (-400, 900, 9.0)
        ])
        let report = makeReport(providers: [("claude", "Claude", history)])
        XCTAssertEqual(report.lifetimeSinceLabel, "Jun 2025")
    }

    func testIdleZeroFilledDaysDoNotExtendTheSinceCaption() {
        // A zero-token, nil-cost day carries no evidence usage existed then — it must not drag the
        // "since" caption back to an idle day.
        let history = makeHistory(daily: [
            (0, 100, 1.0),
            (-400, 0, nil)
        ])
        let report = makeReport(providers: [("claude", "Claude", history)])
        XCTAssertEqual(report.lifetimeSinceLabel, "Jul 2026", "only the day with usage sets the caption")
        XCTAssertEqual(report.lifetime.tokens, 100)
    }

    func testLifetimeAcrossProvidersSumsEveryRecordedDay() {
        let old = makeHistory(daily: [(-200, 5000, 50.0)])
        let recent = makeHistory(daily: [(0, 100, 1.0)])
        let report = makeReport(providers: [
            ("claude", "Claude", old),
            ("codex", "Codex", recent)
        ])
        XCTAssertEqual(report.lifetime.tokens, 5100)
        XCTAssertEqual(report.lifetime.cost, 51.0)
    }

    func testFiniteDailyCostsThatOverflowHistoryTotalsKeepPartialSubtotals() {
        let history = makeHistory(
            daily: [(0, 10, 1e308), (-1, 20, 1e308)],
            models: [(0, "large-model", 10, 1e308), (-1, "large-model", 20, 1e308)],
            apiEstimate: [(0, 1e308), (-1, 1e308)]
        )
        let report = makeReport(providers: [("claude", "Claude", history)])

        XCTAssertEqual(report.lifetime.tokens, 30)
        XCTAssertEqual(report.lifetime.cost, 1e308)
        XCTAssertTrue(report.lifetime.hasIncompleteCost)
        XCTAssertEqual(report.last30.cost, 1e308)
        XCTAssertTrue(report.last30.hasIncompleteCost)
        XCTAssertNil(report.last30.apiEstimate)
        XCTAssertFalse(report.apiEstimateHasPartialData, "overflow does not mean an active session is still growing")
        XCTAssertEqual(report.sections.first?.cost, 1e308)
        XCTAssertTrue(report.sections.first?.hasIncompleteCost == true)
        XCTAssertTrue(report.sections.first?.rows.first?.hasIncompleteCost == true)
        XCTAssertEqual(report.sections.first?.rows.first?.cost, 1e308)
        XCTAssertTrue(report.days.allSatisfy { $0.cost?.isFinite != false })
    }

    func testLifetimeOnlyHistoryDoesNotShowTheEmptyState() {
        let history = makeHistory(daily: [(-90, 800, 8.0)])
        let report = makeReport(providers: [("claude", "Claude", history)])

        XCTAssertFalse(report.isEmpty)
        XCTAssertEqual(report.lifetime.tokens, 800)
        XCTAssertTrue(report.sections.isEmpty, "provider detail rows are limited to the 30-day window")
        XCTAssertEqual(report.days.count, 30)
        XCTAssertTrue(report.days.allSatisfy { $0.tokens == 0 })
    }

    func testTokenTotalsSaturateAtIntMax() {
        let largest = makeHistory(daily: [(0, .max, nil)])
        let additional = makeHistory(daily: [(0, 1, nil)])
        let report = makeReport(providers: [
            ("claude", "Claude", largest),
            ("codex", "Codex", additional)
        ])

        XCTAssertEqual(report.today.tokens, .max)
        XCTAssertEqual(report.last30.tokens, .max)
        XCTAssertEqual(report.days.first?.tokens, .max)
        XCTAssertEqual(report.lifetime.tokens, .max)
    }

    // MARK: - Sections

    func testSectionsFollowEnabledOrderAndSkipIdleProviders() {
        let busy = makeHistory(daily: [(0, 100, 1.0)])
        let other = makeHistory(daily: [(-1, 50, 0.5)])
        let idle = makeHistory(daily: []) // enabled but nothing in the window

        let report = makeReport(providers: [
            ("zai", "Z.ai", busy),
            ("claude", "Claude", other),
            ("codex", "Codex", idle),
            ("grok", "Grok", nil) // enabled with no snapshot at all
        ])

        XCTAssertEqual(report.sections.map(\.providerID), ["zai", "claude"],
                       "sections follow the enabled-provider order, and idle providers are dropped")
        XCTAssertEqual(report.sections.map(\.displayName), ["Z.ai", "Claude"])
        XCTAssertEqual(report.sections[0].tokens, 100)
    }

    // MARK: - Model rows

    func testModelRowsSortCostDescThenTokensThenName() {
        // Two priced rows (cost ranks), then tied-token unpriced rows (tokens, then name as the
        // final tiebreak — the order the fold must reproduce even though it walks a dictionary).
        let history = makeHistory(models: [
            (0, "b-unpriced", 300, nil),
            (0, "zeta-priced", 100, 2.0),
            (0, "a-unpriced", 300, nil),
            (0, "alpha-priced", 500, 1.0)
        ])
        let report = makeReport(providers: [("claude", "Claude", history)])

        XCTAssertEqual(report.sections[0].rows.map(\.slug), [
            "zeta-priced", "alpha-priced", "a-unpriced", "b-unpriced"
        ])
        XCTAssertNil(report.sections[0].rows[2].cost)
        XCTAssertEqual(report.sections[0].rows[0].cost, 2.0)
    }

    func testModelRowsFoldAcrossDaysAndCaseFoldSlugs() {
        let history = makeHistory(models: [
            (0, "Space-Bunny", 100, nil),
            (-2, "space-bunny", 50, nil),
            (-1, "grok-4.20", 10, 0.25)
        ])
        let report = makeReport(providers: [("grok", "Grok", history)])

        XCTAssertEqual(report.sections[0].rows.count, 2, "the same slug on different days folds into one row")
        let bunny = report.sections[0].rows.first { $0.slug == "Space-Bunny" }
        XCTAssertEqual(bunny?.tokens, 150, "tokens fold across the window; the first spelling is kept")
        XCTAssertEqual(bunny?.id, "grok|space-bunny")
    }

    func testModelRowKeepsKnownSubtotalAndMarksPartial() throws {
        let today = dayKey(offsetFromToday: 0)
        let history = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(
                    date: today,
                    totalTokens: 300,
                    costUSD: 2,
                    costIsComplete: false,
                    hasUnexplainedIncompleteCost: false
                )
            ]),
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(date: today, models: [
                    ModelUsageEntry(model: "shared-model", totalTokens: 300, costUSD: 2, costIsComplete: false)
                ])
            ]),
            unknownModelsByDay: [today: ["shared-model"]]
        )

        let report = makeReport(providers: [("claude", "Claude", history)])
        let row = try XCTUnwrap(report.sections.first?.rows.first)
        XCTAssertEqual(row.cost, 2)
        XCTAssertTrue(row.hasIncompleteCost)
    }

    func testSaturatedSourceTokensReachHistorySummaries() throws {
        let today = dayKey(offsetFromToday: 0)
        let history = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: today, totalTokens: 900, costUSD: 2, tokenCountSaturated: true)
            ]),
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(date: today, models: [
                    ModelUsageEntry(model: "large-model", totalTokens: 900, costUSD: 2, tokenCountSaturated: true)
                ])
            ]),
            unknownModelsByDay: [:]
        )

        let report = makeReport(providers: [("claude", "Claude", history)])
        XCTAssertTrue(try XCTUnwrap(report.days.first).tokenCountSaturated)
        XCTAssertTrue(report.today.tokenCountSaturated)
        XCTAssertTrue(report.last7.tokenCountSaturated)
        XCTAssertTrue(report.last30.tokenCountSaturated)
        XCTAssertTrue(report.lifetime.tokenCountSaturated)
        XCTAssertTrue(try XCTUnwrap(report.sections.first).tokenCountSaturated)
        XCTAssertTrue(try XCTUnwrap(report.sections.first?.rows.first).tokenCountSaturated)
    }

    func testHistoryMarksOverflowAcrossDaysAsLowerBound() throws {
        let history = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: dayKey(offsetFromToday: 0), totalTokens: Int.max - 5, costUSD: 1),
                DailyUsageEntry(date: dayKey(offsetFromToday: -1), totalTokens: 10, costUSD: 1)
            ]),
            unknownModelsByDay: [:]
        )

        let report = makeReport(providers: [("claude", "Claude", history)])
        XCTAssertFalse(try XCTUnwrap(report.days.first).tokenCountSaturated)
        XCTAssertTrue(report.last7.tokenCountSaturated)
        XCTAssertTrue(report.last30.tokenCountSaturated)
        XCTAssertTrue(report.lifetime.tokenCountSaturated)
        XCTAssertTrue(try XCTUnwrap(report.sections.first).tokenCountSaturated)
    }

    func testUnexplainedStructuralGapHidesCostAcrossHistoryTotals() throws {
        let today = dayKey(offsetFromToday: 0)
        let history = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(
                    date: today,
                    totalTokens: 300,
                    costUSD: 2,
                    costIsComplete: false,
                    hasUnexplainedIncompleteCost: true
                )
            ]),
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(date: today, models: [
                    ModelUsageEntry(model: "known-model", totalTokens: 300, costUSD: 2)
                ])
            ]),
            unknownModelsByDay: [today: ["mystery-model"]]
        )

        let report = makeReport(providers: [("claude", "Claude", history)])
        XCTAssertNil(report.today.cost)
        XCTAssertNil(report.last30.cost)
        XCTAssertNil(report.lifetime.cost)
        XCTAssertTrue(report.today.hasIncompleteCost)
        XCTAssertTrue(try XCTUnwrap(report.sections.first).hasIncompleteCost)
        XCTAssertNil(report.sections.first?.rows.first?.cost)
        XCTAssertTrue(report.sections.first?.rows.first?.hasIncompleteCost == true)
    }

    // MARK: - Empty state

    func testEmptyReportWhenNoEnabledProviderHasUsage() {
        let report = makeReport(providers: [("claude", "Claude", nil), ("codex", "Codex", makeHistory(daily: []))])
        XCTAssertTrue(report.isEmpty)
        XCTAssertTrue(report.days.isEmpty)
        XCTAssertTrue(report.sections.isEmpty)
    }

    // MARK: - Lifetime hero estimate mark + redundant estimate card

    /// Subscription log providers (Claude, Codex on plan) carry no per-message cost, so their
    /// folded `costUSD` is imputed at public API rates — the hero's headline is an estimate, and
    /// `lifetimeCostIsEstimated` must say so (the tiles' `estimatedCost` descriptor flag drives it).
    func testLifetimeCostIsEstimatedMarksFoldImputedProviders() {
        let report = makeReport(
            providers: [
                (id: "claude", name: "Claude", history: makeHistory(daily: [(0, 100, 3.09)])),
                (id: "codex", name: "Codex", history: makeHistory(daily: [(0, 200, 2.0)])),
            ],
            estimatedCosts: ["claude": true, "codex": true]
        )
        XCTAssertTrue(report.lifetimeCostIsEstimated)
        XCTAssertTrue(report.lifetime.hasEstimatedCost)

        // Recorded billing (OpenCode's authoritative per-message cost) keeps the hero unmarked.
        let recordedHistory = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: dayKey(offsetFromToday: 0), totalTokens: 100, costUSD: 3.09)
            ]),
            estimatedCostDays: []
        )
        let recorded = makeReport(
            providers: [
                (id: "opencode", name: "OpenCode", history: recordedHistory),
            ],
            estimatedCosts: ["opencode": false]
        )
        XCTAssertFalse(recorded.lifetimeCostIsEstimated)

        let legacy = makeReport(
            providers: [
                (id: "opencode", name: "OpenCode", history: makeHistory(daily: [(0, 100, 3.09)])),
            ],
            estimatedCosts: ["opencode": false]
        )
        XCTAssertTrue(legacy.lifetimeCostIsEstimated)
        XCTAssertTrue(legacy.today.hasEstimatedCost)
        XCTAssertTrue(try XCTUnwrap(legacy.sections.first).hasEstimatedCost)
    }

    /// The "At Public API Rates (Est.)" card must disappear when it would display the same dollars
    /// as the hero: subscription logs with no per-message cost make the hero's imputed total and
    /// the what-if total coincide, and showing both presented one fact as two. Compared at display
    /// precision — $3,099.61 and $3,100.02 both read "$3.1K".
    func testEstimateCardSuppressedWhenItMatchesTheHeroAtDisplayPrecision() {
        let report = makeReport(
            providers: [
                (id: "claude", name: "Claude", history: makeHistory(
                    daily: [(0, 100, 3_099.61)],
                    apiEstimate: [(0, 3_100.02)]
                )),
            ],
            estimatedCosts: ["claude": true]
        )
        XCTAssertEqual(report.lifetime.cost, 3_099.61)
        XCTAssertEqual(report.apiEstimateTotal, 3_100.02)
        XCTAssertFalse(report.showsAPIEstimateCard,
                       "identical display dollars — the card would duplicate the hero")
    }

    /// Genuinely different totals keep the what-if card: a provider whose logs DO record cost
    /// (hero = recorded) alongside a what-if restatement (estimate = everything at API rates)
    /// produces two different display figures.
    func testEstimateCardShownWhenTotalsDifferAtDisplayPrecision() {
        let report = makeReport(
            providers: [
                (id: "opencode", name: "OpenCode", history: makeHistory(
                    daily: [(0, 100, 2_599.61)],
                    apiEstimate: [(0, 3_100.02)]
                )),
            ],
            estimatedCosts: ["opencode": false]
        )
        XCTAssertTrue(report.showsAPIEstimateCard)
    }

    /// Below the abbreviation threshold the row style keeps cents, so a sub-$1k match must also
    /// suppress — and a one-cent difference must not (it displays differently).
    func testEstimateCardSuppressionUsesRowPrecisionBelowThousand() {
        let matching = makeReport(
            providers: [
                (id: "claude", name: "Claude", history: makeHistory(
                    daily: [(0, 100, 40.76)],
                    apiEstimate: [(0, 40.76)]
                )),
            ],
            estimatedCosts: ["claude": true]
        )
        XCTAssertFalse(matching.showsAPIEstimateCard)

        let differing = makeReport(
            providers: [
                (id: "claude", name: "Claude", history: makeHistory(
                    daily: [(0, 100, 40.76)],
                    apiEstimate: [(0, 40.77)]
                )),
            ],
            estimatedCosts: ["claude": true]
        )
        XCTAssertTrue(differing.showsAPIEstimateCard)
    }

    /// An estimate with no hero cost at all (nothing recorded or priced into `costUSD`) still shows
    /// the what-if card — there is nothing to duplicate.
    func testEstimateCardShownWhenHeroHasNoCost() {
        let report = makeReport(
            providers: [
                (id: "claude", name: "Claude", history: makeHistory(
                    daily: [(0, 100, nil)],
                    apiEstimate: [(0, 12.34)]
                )),
            ],
            estimatedCosts: ["claude": true]
        )
        XCTAssertNil(report.lifetime.cost)
        XCTAssertEqual(report.apiEstimateTotal, 12.34)
        XCTAssertTrue(report.showsAPIEstimateCard)
    }
}
