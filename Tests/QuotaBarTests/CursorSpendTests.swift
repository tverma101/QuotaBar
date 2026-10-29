import XCTest
@testable import QuotaBar

// MARK: - CSV parser

final class CursorCSVParserTests: XCTestCase {
    func testParsesQuotedCommasEscapedQuotesEmbeddedNewlinesAndCRLF() {
        let csv = "Date,Model,Note\r\n"
            + "2026-01-01T00:00:00Z,\"composer-1\",\"a, b \"\"quoted\"\" c\"\r\n"
            + "2026-01-02T00:00:00Z,composer-1,\"line one\r\nline two\"\r\n"
        var records: [[String: String]] = []

        let summary = CursorCSVParser.forEachRecord(in: csv) { records.append($0) }

        XCTAssertTrue(summary.isStructurallyComplete)
        XCTAssertEqual(summary.rejectedRecordCount, 0)
        XCTAssertEqual(records.count, 2)
        guard records.count == 2 else { return }
        XCTAssertEqual(records[0]["Note"], #"a, b "quoted" c"#)
        XCTAssertEqual(records[1]["Note"], "line one\r\nline two")
        XCTAssertEqual(records[1]["Model"], "composer-1")
    }

    func testParsesTrailingPartialRowWithoutNewline() {
        let csv = "Date,Model\n2026-01-01T00:00:00Z,composer-1"
        var records: [[String: String]] = []

        let summary = CursorCSVParser.forEachRecord(in: csv) { records.append($0) }

        XCTAssertTrue(summary.isStructurallyComplete)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["Date"], "2026-01-01T00:00:00Z")
        XCTAssertEqual(records[0]["Model"], "composer-1")
    }

    func testUsageCSVMapsColumnsToPricedRows() throws {
        let csv = """
        Date,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Cost
        2026-01-01T00:00:00Z,composer-1,No,0,0,0,1000000,Included
        2026-01-01T00:00:00Z,totally-unknown-model-xyz,No,0,100,0,0,Included
        ,skipped-no-date,No,0,0,0,0,Included
        """
        let parsed = try CursorUsageCSV.parse(csv: csv, pricing: TestPricing.bundled)

        XCTAssertEqual(parsed.rows.count, 2)
        XCTAssertEqual(parsed.rejectedRowCount, 1)
        XCTAssertEqual(parsed.rows[0].model, "composer-1")
        XCTAssertEqual(parsed.rows[0].tokens.output, 1_000_000)
        XCTAssertEqual(parsed.rows[0].imputedCostDollars!, 10.0, accuracy: 1e-9)
        XCTAssertEqual(parsed.rows[1].tokens.totalTokens, 100)
        XCTAssertNil(parsed.rows[1].imputedCostDollars)
    }

    func testUsageCSVDoesNotTreatAggregatedRowsAsSingleLongContextRequests() throws {
        var rates = ModelRates(
            inputPerMillion: 3,
            outputPerMillion: 15,
            cacheWritePerMillion: 3.75,
            cacheReadPerMillion: 0.3
        )
        rates.inputAbove200kPerMillion = 6
        rates.outputAbove200kPerMillion = 22.5
        let pricing = ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: ["test-model": rates]),
            secondary: PricingCatalog()
        )
        let csv = """
        Date,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Cost
        2026-01-01T00:00:00Z,test-model,No,0,300000,0,100000,Included
        """

        let row = try XCTUnwrap(CursorUsageCSV.parse(csv: csv, pricing: pricing).rows.first)

        // A CSV row combines many requests, so its total cannot prove that any one request crossed 200k.
        XCTAssertEqual(row.imputedCostDollars!, 2.4, accuracy: 0.0001)
    }

    func testUsageCSVAggregatesGrokAtCursorRateWithoutChangingPublicTier() throws {
        let pricing = TestPricing.bundled
        let tokens = TokenBreakdown(input: 220_000)
        let csv = """
        Date,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Cost
        2026-01-01T00:00:00Z,grok-4.7,No,0,220000,0,0,Included
        """

        let row = try XCTUnwrap(CursorUsageCSV.parse(csv: csv, pricing: pricing).rows.first)

        XCTAssertEqual(row.imputedCostDollars!, 0.44, accuracy: 0.000_001,
                       "Cursor's aggregate CSV uses the Cursor base rate")
        XCTAssertEqual(try XCTUnwrap(pricing.estimatedCostDollars(model: "grok-4.7", tokens: tokens)), 0.88,
                       "the generic xAI model uses its public long-context tier above 200K")
    }

    /// Cursor names Grok Bot work by product, never by the model that served it. Keep measured tokens
    /// under the product label while leaving cost unpriced and the serving model unattributed — and
    /// because the product label is a known name (not an unidentified model), the day's gap is
    /// explained: the priced subtotal keeps its lower-bound marker and no unknown-model warning fires.
    func testOpaqueGrokBotCSVRowsKeepMeasuredTokensWithoutInferringServingModel() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let date = ISO8601DateFormatter().string(from: now)
        let csv = """
        Date,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Cost
        \(date),grok-bot-cua,No,0,100,0,0,Included
        \(date),grok-bot-default,No,0,200,0,0,Included
        \(date),sand-automation,No,0,300,0,0,Included
        \(date),grok-4.7,No,0,50000,0,0,Included
        """

        let parsed = try CursorUsageCSV.parse(csv: csv, pricing: TestPricing.bundled, maximumTimestamp: now)
        XCTAssertEqual(parsed.unpricedGrokBotRowCount, 3)
        XCTAssertEqual(parsed.rejectedRowCount, 0)
        XCTAssertEqual(parsed.rows.map(\.model), ["grok-bot-cua", "grok-bot-default", "sand-automation", "grok-4.7"])
        XCTAssertEqual(parsed.rows.prefix(3).map(\.tokens.totalTokens), [100, 200, 300])
        XCTAssertTrue(parsed.rows.prefix(3).allSatisfy { $0.imputedCostDollars == nil })

        var lines: [MetricLine] = []
        let history = try CursorUsageMapper.appendSpendLines(
            rows: parsed.rows,
            now: now,
            pricing: TestPricing.bundled,
            to: &lines
        )
        XCTAssertEqual(history.series.daily.first?.totalTokens, 50_600,
                       "opaque product rows carry measured tokens even when their serving model is unknown")
        XCTAssertEqual(history.series.daily.first?.costIsComplete, false)
        XCTAssertTrue(history.series.daily.first?.hasUnexplainedIncompleteCost == false,
                      "a product label names the work; the missing price is explained, not unexplained")
        XCTAssertNil(history.unknownModelsByDay[DailyUsageAccumulator.dayKey(from: now)],
                     "known product labels are not unknown models and must not raise the warning")
        XCTAssertEqual(history.modelUsage?.daily.first?.models.reduce(0) {
            ProviderParse.addingSaturating($0, $1.totalTokens)
        }, 50_600)
        guard case .values(_, let todayValues, _, _, let unknownModels, _) = try XCTUnwrap(
            lines.first(where: { $0.label == "Today" })
        ) else {
            return XCTFail("the Today spend row must contain the priced subtotal and token total")
        }
        XCTAssertEqual(todayValues, [
            MetricValue(number: 0.10, kind: .dollars, estimated: true, isLowerBound: true),
            MetricValue(number: 50_600, kind: .count, label: "tokens")
        ], "the known Grok subtotal remains visible with its lower-bound marker")
        XCTAssertTrue(unknownModels.isEmpty, "no warning triangle fires for known product labels")
        XCTAssertEqual(history.modelUsage?.daily.first?.models.first { $0.model == "Grok Bot" }?.totalTokens, 600,
                       "the product rows fold into one Grok Bot family row")
    }

    func testUsageCSVKeepsLargeNonOverflowingTokenCounts() throws {
        let csv = """
        Date,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Cost
        2026-01-01T00:00:00Z,unknown-a,No,0,1000000000000001,0,0,Included
        2026-01-02T00:00:00Z,unknown-b,No,0,1,0,0,Included
        """

        let parsed = try CursorUsageCSV.parse(csv: csv, pricing: TestPricing.bundled)

        XCTAssertEqual(parsed.rows.count, 2)
        XCTAssertEqual(parsed.rows.map(\.tokens.totalTokens), [1_000_000_000_000_001, 1])
        XCTAssertEqual(parsed.rejectedRowCount, 0)
    }

    func testUsageCSVOmitsZeroTokenRowsFromUsageHistory() throws {
        let csv = """
        Date,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Cost
        2026-01-01T00:00:00Z,composer-1,No,0,0,0,0,Included
        """

        let parsed = try CursorUsageCSV.parse(csv: csv, pricing: TestPricing.bundled)
        XCTAssertTrue(parsed.rows.isEmpty)
        XCTAssertEqual(parsed.rejectedRowCount, 0)

        var lines: [MetricLine] = []
        let history = try CursorUsageMapper.appendSpendLines(
            rows: parsed.rows,
            now: Date(timeIntervalSince1970: 1_800_000_000),
            pricing: TestPricing.bundled,
            to: &lines
        )
        XCTAssertTrue(history.series.daily.isEmpty)
        XCTAssertTrue(history.modelUsage?.daily.isEmpty == true)
        XCTAssertTrue(lines.isEmpty)
    }
}

// MARK: - Range aggregation

final class CursorSpendRangeTests: XCTestCase {
    func testAppendSpendLinesBucketsRowsByLocalDay() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        let startOfLast30 = cal.date(byAdding: .day, value: -29, to: startOfToday)!

        let rows = [
            makeRow(date: now, cost: 1.00, tokens: 100),                                              // today
            makeRow(date: cal.date(byAdding: .day, value: -1, to: now)!, cost: 2.00, tokens: 200),    // yesterday
            makeRow(date: startOfLast30, cost: 0.50, tokens: 50),                                     // -29d edge: last30 only
            makeRow(date: cal.date(byAdding: .day, value: -40, to: now)!, cost: 5.00, tokens: 999)    // old (provider scopes the fetch)
        ]

        var lines: [MetricLine] = []
        try CursorUsageMapper.appendSpendLines(rows: rows, now: now, pricing: TestPricing.bundled, to: &lines)

        // Tokens come from Cursor; dollars are calculated locally and marked as estimated.
        XCTAssertEqual(values(lines, "Today"), [MetricValue(number: 1.00, kind: .dollars, estimated: true), MetricValue(number: 100, kind: .count, label: "tokens")])
        XCTAssertEqual(values(lines, "Yesterday"), [MetricValue(number: 2.00, kind: .dollars, estimated: true), MetricValue(number: 200, kind: .count, label: "tokens")])
        // Last 30 Days sums exactly the labeled window: a row older than the window is excluded
        // even when the provider's export returns it, so the tile can't silently overcount if the
        // fetch ever ignores its startDate.
        XCTAssertEqual(values(lines, "Last 30 Days"), [MetricValue(number: 3.50, kind: .dollars, estimated: true), MetricValue(number: 350, kind: .count, label: "tokens")])

        guard case .chart(let label, let points, let note) = lines.first(where: { $0.label == "Usage Trend" }) else {
            return XCTFail("expected a Usage Trend chart line")
        }
        XCTAssertEqual(label, "Usage Trend")
        // Cursor's tokens come from its server export, so the note names that source, not local logs.
        XCTAssertEqual(note, "From your Cursor usage export")
        XCTAssertEqual(
            points.count,
            UsageHistoryWindow.totalDays,
            "one bar per calendar day across the same 30-day window the tile reports"
        )
        XCTAssertEqual(points.last?.value, 100, "today's tokens land on the last bar")
        XCTAssertEqual(
            points[UsageHistoryWindow.totalDays - 2].value, 200,
            "yesterday's tokens land on the second-to-last bar"
        )
    }

    func testEmptyExportLeavesSpendTilesAndUsageTrendUnbacked() throws {
        var lines: [MetricLine] = []
        try CursorUsageMapper.appendSpendLines(rows: [], now: Date(), pricing: TestPricing.bundled, to: &lines)
        XCTAssertTrue(lines.isEmpty)
    }

    func testUnknownModelsAttachToTheRightPeriods() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cal = Calendar.current
        let rows = [
            makeRow(date: now, cost: 1.00, tokens: 100, model: "composer-1"),                                  // priced, today
            makeRow(date: now, cost: nil, tokens: 50, model: "totally-unknown-model-xyz"),                      // unknown, today
            makeRow(date: cal.date(byAdding: .day, value: -1, to: now)!, cost: 2.00, tokens: 200, model: "composer-1"), // priced, yesterday
            makeRow(date: cal.date(byAdding: .day, value: -3, to: now)!, cost: nil, tokens: 80, model: "another-unknown-abc") // unknown, last30 only
        ]

        var lines: [MetricLine] = []
        try CursorUsageMapper.appendSpendLines(rows: rows, now: now, pricing: TestPricing.bundled, to: &lines)

        // Today carries its own unknown model; a fully-priced Yesterday stays clean; Last 30 Days carries
        // the de-duplicated, sorted union across the whole window.
        XCTAssertEqual(unknown(lines, "Today"), ["totally-unknown-model-xyz"])
        XCTAssertEqual(unknown(lines, "Yesterday"), [])
        XCTAssertEqual(unknown(lines, "Last 30 Days"), ["another-unknown-abc", "totally-unknown-model-xyz"])
        XCTAssertEqual(values(lines, "Today"), [
            MetricValue(number: 1.00, kind: .dollars, estimated: true, isLowerBound: true),
            MetricValue(number: 150, kind: .count, label: "tokens")
        ], "the same-day priced subtotal remains visible beside the unknown-model warning")
        XCTAssertEqual(values(lines, "Yesterday"), [
            MetricValue(number: 2.00, kind: .dollars, estimated: true),
            MetricValue(number: 200, kind: .count, label: "tokens")
        ])
        XCTAssertEqual(values(lines, "Last 30 Days"), [
            MetricValue(number: 3.00, kind: .dollars, estimated: true, isLowerBound: true),
            MetricValue(number: 430, kind: .count, label: "tokens")
        ], "the 30-day priced subtotal remains visible beside unknown-model warnings")
    }

    func testUnknownModelWithZeroTokensIsNotFlagged() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // A zero-token row of an unknown model changes no cost, so it never raises the warning. The day
        // also has real priced usage, so the tile exists (an all-idle day gets no tile at all) — proving
        // the zero-token unknown is filtered out, not just hidden by an absent tile.
        let rows = [
            makeRow(date: now, cost: 1.00, tokens: 100, model: "composer-1"),
            makeRow(date: now, cost: nil, tokens: 0, model: "totally-unknown-model-xyz")
        ]

        var lines: [MetricLine] = []
        try CursorUsageMapper.appendSpendLines(rows: rows, now: now, pricing: TestPricing.bundled, to: &lines)

        XCTAssertNotNil(values(lines, "Today"), "the priced row keeps the tile present")
        XCTAssertEqual(unknown(lines, "Today"), [])
        XCTAssertEqual(unknown(lines, "Last 30 Days"), [])
    }

    func testAppendSpendLinesAttachesModelBreakdown() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [
            makeRow(date: now, cost: 1.004, tokens: 100, model: "composer-1"),
            makeRow(date: now, cost: 2.006, tokens: 200, model: "gpt-5.5"),
            makeRow(date: now, cost: nil, tokens: 300, model: "unpriced-cursor-model")
        ]

        var lines: [MetricLine] = []
        try CursorUsageMapper.appendSpendLines(rows: rows, now: now, pricing: TestPricing.bundled, to: &lines)

        // The unpriced row keeps counting tokens and joins the breakdown with a nil cost. The tile
        // shows the known subtotal beside the unknown-model warning.
        XCTAssertEqual(values(lines, "Today"), [
            MetricValue(number: 3.01, kind: .dollars, estimated: true, isLowerBound: true),
            MetricValue(number: 600, kind: .count, label: "tokens")
        ])
        XCTAssertEqual(unknown(lines, "Today"), ["unpriced-cursor-model"])
        let breakdown = try XCTUnwrap(modelBreakdown(lines, "Today"))
        XCTAssertEqual(breakdown.sourceNote, "From your Cursor usage export")
        XCTAssertEqual(breakdown.totalCostUSD, 3.01, "the breakdown header keeps the known dollar subtotal")
        XCTAssertEqual(breakdown.models.map(\.model), ["gpt-5.5", "composer-1", "unpriced-cursor-model"])
        XCTAssertEqual(breakdown.models.map(\.totalTokens), [200, 100, 300])
        XCTAssertEqual(breakdown.models[0].costUSD, 2.01, "model cost rounds once at the displayed aggregate")
        XCTAssertNil(breakdown.models[2].costUSD, "the unpriced row claims no cost")
    }

    func testModelBreakdownGroupsThinkingEffortSlugsIntoFamilies() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Cursor exports one slug per thinking-effort/fast combination; the panel row must group them
        // under the canonical base model (via the supplement alias rules, with `-fast` folded into its
        // base) and keep the raw slugs as the tooltip's per-effort variants.
        let rows = [
            makeRow(date: now, cost: 3.00, tokens: 300, model: "claude-opus-4-8-thinking-max"),
            makeRow(date: now, cost: 1.00, tokens: 100, model: "claude-opus-4-8-thinking-high"),
            makeRow(date: now, cost: 2.00, tokens: 200, model: "gpt-5.5-extra-high-fast"),
            makeRow(date: now, cost: 0.50, tokens: 50, model: "gpt-5.5")
        ]

        var lines: [MetricLine] = []
        try CursorUsageMapper.appendSpendLines(rows: rows, now: now, pricing: TestPricing.bundled, to: &lines)

        let breakdown = try XCTUnwrap(modelBreakdown(lines, "Today"))
        XCTAssertEqual(breakdown.models.map(\.model), ["claude-opus-4-8", "gpt-5.5"])

        let opus = try XCTUnwrap(breakdown.models.first { $0.model == "claude-opus-4-8" })
        XCTAssertEqual(opus.totalTokens, 400)
        XCTAssertEqual(opus.costUSD, 4.00)
        XCTAssertEqual(opus.variants?.map(\.model), ["claude-opus-4-8-thinking-max", "claude-opus-4-8-thinking-high"],
                       "variants keep the raw slugs, largest spend first")
        XCTAssertEqual(opus.variants?.map(\.costUSD), [3.00, 1.00])

        let gpt = try XCTUnwrap(breakdown.models.first { $0.model == "gpt-5.5" })
        XCTAssertEqual(gpt.variants?.map(\.model), ["gpt-5.5-extra-high-fast", "gpt-5.5"],
                       "a -fast canonical folds into its base family")
    }

    func testUnpricedOnlyDayCountsTokensWithoutCost() throws {
        // A day whose every row is unpriceable still shows its tokens — on the tiles and the trend
        // — but claims no cost (dash). The usage also lands in `unknownModelsByDay` for the warning
        // triangle and the history screen's reveal affordance.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [
            makeRow(date: now, cost: nil, tokens: 100, model: "totally-unknown-model-xyz")
        ]

        var lines: [MetricLine] = []
        try CursorUsageMapper.appendSpendLines(rows: rows, now: now, pricing: TestPricing.bundled, to: &lines)

        XCTAssertEqual(values(lines, "Today"), [MetricValue(number: 100, kind: .count, label: "tokens")])
        XCTAssertEqual(values(lines, "Last 30 Days"), [MetricValue(number: 100, kind: .count, label: "tokens")])
        guard case .chart(_, let points, _) = lines.first(where: { $0.label == "Usage Trend" }) else {
            return XCTFail("the usage trend must stay present on an unpriced-only day")
        }
        XCTAssertEqual(points.last?.value, 100, "the trend keeps the day's token volume")
    }

    func testExtremeSameDayTokenTotalsSaturate() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [
            CursorUsageCSVRow(date: now, model: "unknown-a", tokens: TokenBreakdown(input: .max), imputedCostDollars: nil),
            CursorUsageCSVRow(date: now, model: "unknown-b", tokens: TokenBreakdown(input: 1), imputedCostDollars: nil)
        ]
        var lines: [MetricLine] = []

        let history = try CursorUsageMapper.appendSpendLines(rows: rows, now: now, pricing: TestPricing.bundled, to: &lines)

        XCTAssertEqual(history.series.daily.first?.totalTokens, .max)
        XCTAssertEqual(history.modelUsage?.daily.first?.models.reduce(0) {
            ProviderParse.addingSaturating($0, $1.totalTokens)
        }, .max)
    }

    @MainActor
    func testDistinctModelRowsCannotShowSharesWhenDailyTotalSaturates() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [
            makeRow(date: now, cost: nil, tokens: 6_000_000_000_000_000_000, model: "unknown-alpha"),
            makeRow(date: now, cost: nil, tokens: 6_000_000_000_000_000_000, model: "unknown-beta")
        ]
        var lines: [MetricLine] = []

        let history = try CursorUsageMapper.appendSpendLines(
            rows: rows, now: now, pricing: TestPricing.bundled, to: &lines
        )

        XCTAssertTrue(history.series.daily.first?.tokenCountSaturated == true)
        XCTAssertTrue(history.modelUsage?.daily.first?.models.allSatisfy { $0.tokenCountSaturated != true } == true,
                      "each distinct model remains below Int.max on its own")
        let breakdown = try XCTUnwrap(modelBreakdown(lines, "Today"))
        XCTAssertTrue(breakdown.tokenCountSaturated == true,
                      "the period breakdown carries aggregate lower-bound provenance")
        XCTAssertEqual(ModelUsageDetail.shares(
            for: breakdown.models,
            aggregateTokenCountSaturated: breakdown.tokenCountSaturated == true
        ), [0, 0])
    }

    func testFiniteSourceCostsThatOverflowDailySumKeepLowerBoundAndRemainEncodable() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [
            makeRow(date: now, cost: 1e308, tokens: 1, model: "unknown-alpha"),
            makeRow(date: now, cost: 1e308, tokens: 1, model: "unknown-beta")
        ]
        var lines: [MetricLine] = []

        let history = try CursorUsageMapper.appendSpendLines(
            rows: rows, now: now, pricing: TestPricing.bundled, to: &lines
        )

        let day = try XCTUnwrap(history.series.daily.first)
        XCTAssertEqual(day.totalTokens, 2)
        XCTAssertEqual(day.costUSD, 1e308)
        XCTAssertFalse(day.costIsComplete)
        XCTAssertTrue(day.hasUnexplainedIncompleteCost == false)
        let todayValues = try XCTUnwrap(values(lines, "Today"))
        XCTAssertEqual(todayValues.map(\.number), [1e308, 2])
        XCTAssertTrue(todayValues[0].isLowerBound == true)
        XCTAssertTrue(MetricFormatter.string(for: todayValues[0], style: .row).hasPrefix("≥"))
        XCTAssertNoThrow(try JSONEncoder().encode(history),
                         "finite row amounts cannot create an unencodable infinite daily/model sum")
    }

    private func modelBreakdown(_ lines: [MetricLine], _ label: String) -> ModelUsageBreakdown? {
        guard case .values(_, _, _, _, _, let breakdown) = lines.first(where: { $0.label == label }) else { return nil }
        return breakdown
    }

    private func unknown(_ lines: [MetricLine], _ label: String) -> [String]? {
        guard case .values(_, _, _, _, let unknownModels, _) = lines.first(where: { $0.label == label }) else { return nil }
        return unknownModels
    }

    /// `cost: nil` models a row no pricing source could price (the unknown-model case).
    private func makeRow(date: Date, cost: Double?, tokens: Int, model: String = "composer-1") -> CursorUsageCSVRow {
        CursorUsageCSVRow(
            date: date,
            model: model,
            tokens: TokenBreakdown(input: tokens),
            imputedCostDollars: cost
        )
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else { return nil }
        return values
    }
}

// MARK: - Provider integration + render shape

@MainActor
final class CursorSpendProviderTests: XCTestCase {
    func testSpendTrackingDownloadsCSVExposesSpendTilesAndFlagsUnknownModels() async {
        // The provider downloads the usage CSV, exposes the spend-tile + trend descriptors, and emits
        // Today / Yesterday / Last 30 Days / Usage Trend lines
        // alongside the live quota meters. A row that used a model no pricing source can price carries
        // that model's name so the tile can warn its cost is incomplete.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let iso = ISO8601DateFormatter()
        let todayStr = iso.string(from: now)
        let yesterdayStr = iso.string(from: Calendar.current.date(byAdding: .day, value: -1, to: now)!)
        // A priced model and an unknown one both used today, plus a priced row yesterday.
        let csv = """
        Date,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Cost
        \(todayStr),composer-1,No,0,1000000,0,0,Included
        \(todayStr),totally-unknown-model-xyz,No,0,500000,0,0,Included
        \(yesterdayStr),composer-1,No,0,200000,0,0,Included
        """

        let accessToken = makeCursorJWT(sub: "google-oauth2|user_abc123")
        let http = RoutingHTTPClient { request in
            let url = request.url.absoluteString
            if url.contains("export-usage-events-csv") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(csv.utf8))
            }
            if url.contains("GetCurrentPeriodUsage") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("""
                {
                  "enabled": true,
                  "billingCycleEnd": 1772592000000,
                  "planUsage": { "limit": 40000, "remaining": 32000, "totalPercentUsed": 20 }
                }
                """.utf8))
            }
            if url.contains("GetPlanInfo") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"planInfo":{"planName":"pro plan"}}"#.utf8))
            }
            if url.contains("GetCreditGrantsBalance") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"hasCreditGrants":false}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: KeyValueSQLite(values: [CursorAuthStore.accessTokenKey: accessToken]),
                keychain: FakeKeychain()
            ),
            usageClient: CursorUsageClient(http: http),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertTrue(http.requests.contains { $0.url.absoluteString.contains("export-usage-events-csv") },
                      "Cursor refresh must download the usage CSV for spend metrics")
        // Live quota meter survives; spend tiles + trend are present.
        XCTAssertTrue(snapshot.lines.contains { $0.label == "Total usage" })
        for label in ["Today", "Yesterday", "Last 30 Days", "Usage Trend"] {
            XCTAssertNotNil(snapshot.lines.first { $0.label == label }, "\(label) line must be present")
        }
        let ids = Set(provider.widgetDescriptors.map(\.id))
        for id in ["cursor.today", "cursor.yesterday", "cursor.last30", "cursor.trend"] {
            XCTAssertTrue(ids.contains(id), "\(id) descriptor must be present")
        }

        // The unknown model rode onto Today (and the Last 30 Days union); a fully-priced Yesterday stays clean.
        XCTAssertEqual(unknownModels(snapshot.lines, "Today"), ["totally-unknown-model-xyz"])
        XCTAssertEqual(unknownModels(snapshot.lines, "Yesterday"), [])
        XCTAssertEqual(unknownModels(snapshot.lines, "Last 30 Days"), ["totally-unknown-model-xyz"])
    }

    func testMalformedRowWithholdsPartialSpendExportButKeepsQuotaMeters() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let todayStr = ISO8601DateFormatter().string(from: now)
        let csv = """
        Date,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Cost
        \(todayStr),composer-1,No,0,1000000,0,0,Included
        \(todayStr),composer-1,No,0,500000,0,not-a-number,Included
        """
        let accessToken = makeCursorJWT(sub: "google-oauth2|user_abc123")
        let http = RoutingHTTPClient { request in
            let url = request.url.absoluteString
            if url.contains("export-usage-events-csv") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(csv.utf8))
            }
            if url.contains("GetCurrentPeriodUsage") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("""
                {
                  "enabled": true,
                  "billingCycleEnd": 1772592000000,
                  "planUsage": { "limit": 40000, "remaining": 32000, "totalPercentUsed": 20 }
                }
                """.utf8))
            }
            if url.contains("GetPlanInfo") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"planInfo":{"planName":"pro plan"}}"#.utf8))
            }
            if url.contains("GetCreditGrantsBalance") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"hasCreditGrants":false}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: KeyValueSQLite(values: [CursorAuthStore.accessTokenKey: accessToken]),
                keychain: FakeKeychain()
            ),
            usageClient: CursorUsageClient(http: http),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertTrue(http.requests.contains { $0.url.absoluteString.contains("export-usage-events-csv") })
        XCTAssertTrue(snapshot.lines.contains { $0.label == "Total usage" })
        XCTAssertNil(snapshot.usageHistory)
        for label in ["Today", "Yesterday", "Last 30 Days", "Usage Trend"] {
            XCTAssertNil(snapshot.lines.first { $0.label == label }, "partial CSV must not publish \(label)")
        }
    }

    private func unknownModels(_ lines: [MetricLine], _ label: String) -> [String]? {
        guard case .values(_, _, _, _, let unknownModels, _) = lines.first(where: { $0.label == label }) else { return nil }
        return unknownModels
    }

    func testSpendTileRendersCombinedCostAndTokensWithValueTooltip() async {
        let cursor = CursorProvider()
        let descriptor = try! XCTUnwrap(cursor.widgetDescriptors.first { $0.id == "cursor.today" })

        // The combined tile joins the dollar and the labeled token count. The render shape for a zero
        // line is still "$0.00 · 0 tokens" — the mapper no longer produces these (an idle period is left
        // unbacked → "No data"), but a provider that reports a real $0.00 (e.g. OpenRouter) still renders
        // it rather than hiding the figure.
        let cases: [(Double, Int, String, String)] = [
            (12.34, 891_000, "$12.34", "$12.34 · 891K tokens"),
            (0.0, 0, "$0.00", "$0.00 · 0 tokens")
        ]
        for (dollars, tokens, expectedValue, expectedDetail) in cases {
            let runtime = TestProviderRuntime(
                provider: cursor.provider,
                descriptors: [descriptor],
                snapshot: ProviderSnapshot(
                    providerID: cursor.provider.id,
                    displayName: cursor.provider.displayName,
                    lines: [.values(label: "Today", values: [
                        MetricValue(number: dollars, kind: .dollars, estimated: true),
                        MetricValue(number: Double(tokens), kind: .count, label: "tokens")
                    ])]
                )
            )
            let defaults = isolatedDefaults("render-\(expectedValue)")
            let store = WidgetDataStore(
                registry: WidgetRegistry(providers: [cursor.provider], descriptors: [descriptor]),
                providers: [runtime],
                cache: isolatedCache(defaults),
                defaults: defaults
            )
            await store.refreshAll()

            store.meterStyle = .remaining
            let remaining = store.data(for: descriptor)
            store.meterStyle = .used
            let used = store.data(for: descriptor)

            XCTAssertTrue(remaining.hasData)
            XCTAssertEqual(remaining.valueText, expectedValue)
            XCTAssertEqual(remaining.unboundedDetail, expectedDetail)
            XCTAssertEqual(remaining.infoNote, WidgetData.localEstimateNote)
            // Unbounded: identical under both meter styles.
            XCTAssertEqual(used.valueText, remaining.valueText)
            XCTAssertEqual(used.unboundedDetail, remaining.unboundedDetail)
            XCTAssertEqual(used.infoNote, remaining.infoNote)
        }
    }

    // MARK: helpers

    private func isolatedDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.CursorSpend.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func isolatedCache(_ defaults: UserDefaults) -> ProviderSnapshotCache {
        ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })
    }
}

// MARK: - Client request contract

final class CursorUsageClientRequestTests: XCTestCase {
    // Pin the request contract directly at the client level — endpoint, epoch-ms range,
    // `strategy=tokens`, the session cookie, and `Accept: text/csv` — so a silent regression in
    // URL/header construction cannot slip through.
    func testFetchUsageCSVBuildsTokenStrategyRequestWithSessionCookie() async throws {
        let accessToken = makeCursorJWT(sub: "google-oauth2|user_abc123")
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data("Date,Model\n".utf8))
        }

        let response = try await CursorUsageClient(http: http).fetchUsageCSV(
            accessToken: accessToken,
            start: Date(timeIntervalSince1970: 1_000),   // 1_000_000 ms
            end: Date(timeIntervalSince1970: 2_000)      // 2_000_000 ms
        )

        XCTAssertEqual(response?.statusCode, 200)
        // A nil session would skip the HTTP call entirely, so requiring a recorded request guards that
        // the assertions below actually ran against a real request.
        let request = try XCTUnwrap(http.requests.first, "fetchUsageCSV must issue a request")
        let url = request.url.absoluteString
        XCTAssertTrue(url.contains("export-usage-events-csv"), "hits the CSV export endpoint")
        XCTAssertTrue(url.contains("startDate=1000000"), "start as epoch-ms query param")
        XCTAssertTrue(url.contains("endDate=2000000"), "end as epoch-ms query param")
        XCTAssertTrue(url.contains("strategy=tokens"), "token strategy")
        XCTAssertEqual(request.headers["Cookie"], "WorkosCursorSessionToken=user_abc123%3A%3A\(accessToken)")
        XCTAssertEqual(request.headers["Accept"], "text/csv")
    }
}

// makeCursorJWT, KeyValueSQLite, and RoutingHTTPClient live in TestSupport.swift.
