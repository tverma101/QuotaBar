import XCTest
@testable import QuotaBar

/// The Usage History screen's fold: window clipping (exactly 30 days including today), the
/// Today/7/30 period buckets, unpriced rows (tokens count, cost dashes), fold-time API-rate
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
        apiEstimate: [(offset: Int, estimate: Double)] = []
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
        return ProviderUsageHistory(
            series: series,
            modelUsage: modelUsage,
            unknownModelsByDay: [:],
            apiEstimateByDay: estimates
        )
    }

    private func makeReport(
        providers: [(id: String, name: String?, history: ProviderUsageHistory?)],
        now: Date? = nil
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
                )
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
        XCTAssertEqual(report.days.map(\.date), [dayKey(offsetFromToday: 0), dayKey(offsetFromToday: -29)],
                       "days list newest first")
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

    func testUnpricedDaysKeepTokensAndDashCost() {
        // A day whose rows were all unpriced shows tokens with a nil cost. A period mixing priced
        // and unpriced days sums only the priced ones — never a fabricated zero.
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
        XCTAssertEqual(mixedReport.last7.cost, 2.0, "cost sums only priced days")
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

    // MARK: - Empty state

    func testEmptyReportWhenNoEnabledProviderHasUsage() {
        let report = makeReport(providers: [("claude", "Claude", nil), ("codex", "Codex", makeHistory(daily: []))])
        XCTAssertTrue(report.isEmpty)
        XCTAssertTrue(report.days.isEmpty)
        XCTAssertTrue(report.sections.isEmpty)
    }
}
