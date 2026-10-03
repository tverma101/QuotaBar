import XCTest
@testable import QuotaBar

/// Direct pins for the shared accumulate-then-assemble contract behind the Claude/Codex/Grok scanners
/// (the class of drift behind the ccusage false-zero fix): one `dayKey` spelling, newest-first day
/// order, per-model accumulation, always-priced days, and unknown models isolated from the series.
final class DailyUsageAccumulatorTests: XCTestCase {
    func testDayKeyUsesInjectedCalendarAndZeroPads() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // 2024-03-07 23:30 UTC — pads month and day to two digits.
        let date = calendar.date(from: DateComponents(year: 2024, month: 3, day: 7, hour: 23, minute: 30))!
        XCTAssertEqual(DailyUsageAccumulator.dayKey(from: date, calendar: calendar), "2024-03-07")

        // The key is local-calendar: one instant, two time zones, two different days.
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(DailyUsageAccumulator.dayKey(from: date, calendar: tokyo), "2024-03-08")
    }

    func testBuildSortsDaysNewestFirstAndSumsPerModel() {
        var accumulator = DailyUsageAccumulator()
        accumulator.add(day: "2024-06-01", tokens: 100, cost: 1.0, model: "sonnet")
        accumulator.add(day: "2024-06-03", tokens: 50, cost: 0.5, model: "sonnet")
        accumulator.add(day: "2024-06-01", tokens: 200, cost: 2.0, model: "sonnet")
        accumulator.add(day: "2024-06-01", tokens: 10, cost: 0.1, model: "opus")

        let scan = accumulator.build()
        XCTAssertEqual(scan.series.daily.map(\.date), ["2024-06-03", "2024-06-01"])
        XCTAssertEqual(scan.series.daily.map(\.totalTokens), [50, 310])
        // Every counted day is priced — a real cost, never nil-by-omission.
        XCTAssertEqual(scan.series.daily[1].costUSD ?? -1, 3.1, accuracy: 0.0001)

        let june1 = scan.modelUsage?.daily.first { $0.date == "2024-06-01" }
        let models = Dictionary(uniqueKeysWithValues: (june1?.models ?? []).map { ($0.model, $0) })
        XCTAssertEqual(models["sonnet"]?.totalTokens, 300)
        XCTAssertEqual(models["sonnet"]?.costUSD ?? -1, 3.0, accuracy: 0.0001)
        XCTAssertEqual(models["opus"]?.totalTokens, 10)
    }

    func testMergingIncrementalScansPreservesObservedModelVariants() throws {
        var originalAccumulator = DailyUsageAccumulator()
        originalAccumulator.add(day: "2026-10-02", tokens: 50, cost: 0.5, model: "gpt-5.6-luna")

        var deltaAccumulator = DailyUsageAccumulator()
        deltaAccumulator.add(
            day: "2026-10-02",
            tokens: 25,
            cost: 0.25,
            model: "anthropic/openai/gpt-5.6-luna",
            canonical: "gpt-5.6-luna"
        )

        let merged = try XCTUnwrap(DailyUsageAccumulator.merged([
            originalAccumulator.build(),
            deltaAccumulator.build()
        ]))
        XCTAssertEqual(merged.series.daily.first?.totalTokens, 75)
        XCTAssertEqual(merged.series.daily.first?.costUSD ?? -1, 0.75, accuracy: 0.0001)
        let model = try XCTUnwrap(merged.modelUsage?.daily.first?.models.first)
        XCTAssertEqual(model.model, "gpt-5.6-luna")
        XCTAssertEqual(Set(model.variants?.map(\.model) ?? []), [
            "gpt-5.6-luna",
            "anthropic/openai/gpt-5.6-luna"
        ])
    }

    func testUnknownModelsStayOutOfTheSeries() {
        var accumulator = DailyUsageAccumulator()
        accumulator.addUnknownModel(day: "2024-06-02", model: "mystery-model")

        let scan = accumulator.build()
        // A day with only unpriceable usage never enters the series or the model breakdown — it
        // surfaces solely through the warning-triangle set.
        XCTAssertTrue(scan.series.daily.isEmpty)
        XCTAssertEqual(scan.modelUsage?.daily.isEmpty, true)
        XCTAssertEqual(scan.unknownModelsByDay, ["2024-06-02": ["mystery-model"]])
    }

    func testMergedPreferringPrimaryKeepsPrimaryDaysAndFillsGapsOnly() throws {
        var primaryAcc = DailyUsageAccumulator()
        primaryAcc.add(day: "2024-06-01", tokens: 100, cost: 1.0, model: "gpt-5")
        primaryAcc.add(day: "2024-06-02", tokens: 50, cost: 0.5, model: "gpt-5")
        let primary = primaryAcc.build()

        var proxyAcc = DailyUsageAccumulator()
        // Overlaps 2024-06-01 — must NOT add on top of primary.
        proxyAcc.add(day: "2024-06-01", tokens: 999, cost: 9.0, model: "gpt-5.6-luna")
        // Gap day only primary never saw.
        proxyAcc.add(day: "2024-06-03", tokens: 20, cost: 0.2, model: "gpt-5.6-luna")
        let proxy = proxyAcc.build()

        let result = DailyUsageAccumulator.mergedPreferringPrimary(primary, fillingGapsFrom: [proxy])
        XCTAssertTrue(result.usedSupplement)
        let scan = try XCTUnwrap(result.scan)
        let byDay = Dictionary(uniqueKeysWithValues: scan.series.daily.map { ($0.date, $0) })
        XCTAssertEqual(byDay["2024-06-01"]?.totalTokens, 100)
        XCTAssertEqual(byDay["2024-06-01"]?.costUSD ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertEqual(byDay["2024-06-02"]?.totalTokens, 50)
        XCTAssertEqual(byDay["2024-06-03"]?.totalTokens, 20)
        XCTAssertEqual(byDay["2024-06-03"]?.costUSD ?? -1, 0.2, accuracy: 0.0001)
    }

    func testMergedPreferringPrimaryReportsNoSupplementWhenFullyOverlapped() throws {
        var primaryAcc = DailyUsageAccumulator()
        primaryAcc.add(day: "2024-06-01", tokens: 100, cost: 1.0, model: "gpt-5")
        let primary = primaryAcc.build()

        var proxyAcc = DailyUsageAccumulator()
        proxyAcc.add(day: "2024-06-01", tokens: 999, cost: 9.0, model: "gpt-5.6-luna")
        let proxy = proxyAcc.build()

        let result = DailyUsageAccumulator.mergedPreferringPrimary(primary, fillingGapsFrom: [proxy])
        XCTAssertFalse(result.usedSupplement)
        let scan = try XCTUnwrap(result.scan)
        XCTAssertEqual(scan.series.daily.map(\.totalTokens), [100])
    }

}
