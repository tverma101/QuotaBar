import XCTest
@testable import QuotaBar

/// The TPS lens's Today / 7 Days / 14 Days switcher: one fold bucketed by local calendar day, so
/// switching windows never re-reads a log file. These tests pin the bucketing, the per-window
/// minimum-interval gates, the wire labels, and the lens's window selection.
final class TokensPerSecondWindowTests: XCTestCase {
    /// Local noon today — day boundaries are stable regardless of when the suite runs.
    private let now = Calendar.current.date(byAdding: .hour, value: 12, to: Calendar.current.startOfDay(for: Date()))!

    private func day(_ daysAgo: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -daysAgo, to: Calendar.current.startOfDay(for: now))!
            .addingTimeInterval(12 * 3600)
    }

    func testIntervalsBucketByLocalCalendarDay() {
        var accumulator = TokensPerSecondAccumulator()
        accumulator.ingest(outputTokens: 100, at: day(0), model: "m", directInterval: 10)
        accumulator.ingest(outputTokens: 200, at: day(3), model: "m", directInterval: 20)
        accumulator.ingest(outputTokens: 300, at: day(10), model: "m", directInterval: 30)

        let today = accumulator.corpus(since: TokensPerSecondWindow.today.sinceDate(now: now))
        XCTAssertEqual(today.outputTokens, 100)
        XCTAssertEqual(today.seconds, 10)
        XCTAssertEqual(today.intervals, 1)

        let sevenDays = accumulator.corpus(since: TokensPerSecondWindow.sevenDays.sinceDate(now: now))
        XCTAssertEqual(sevenDays.outputTokens, 300)
        XCTAssertEqual(sevenDays.intervals, 2)

        let fourteenDays = accumulator.corpus(since: TokensPerSecondWindow.fourteenDays.sinceDate(now: now))
        XCTAssertEqual(fourteenDays.outputTokens, 600)
        XCTAssertEqual(fourteenDays.intervals, 3)
        XCTAssertEqual(fourteenDays, accumulator.corpus)

        XCTAssertEqual(accumulator.modelShares(since: TokensPerSecondWindow.today.sinceDate(now: now)).map(\.outputTokens), [100])
        XCTAssertEqual(accumulator.modelShares(since: TokensPerSecondWindow.sevenDays.sinceDate(now: now)).map(\.outputTokens), [300])
    }

    func testEstimateWindowsCarryOnlyTheirDaysProviders() {
        var claude = TokensPerSecondAccumulator()
        var codex = TokensPerSecondAccumulator()
        for _ in 0..<5 {
            claude.ingest(outputTokens: 100, at: day(0), model: "sonnet", directInterval: 10)
            codex.ingest(outputTokens: 300, at: day(10), model: "gpt", directInterval: 10)
        }
        let estimate = TokensPerSecondEstimate.from(["claude": claude, "codex": codex], now: now)

        XCTAssertEqual(estimate.windows[.today]?.corpora.keys.sorted(), ["claude"])
        XCTAssertEqual(estimate.windows[.sevenDays]?.corpora.keys.sorted(), ["claude"])
        XCTAssertEqual(estimate.windows[.fourteenDays]?.corpora.keys.sorted(), ["claude", "codex"])
        XCTAssertEqual(estimate.windows[.today]?.combined.tokensPerSecond, 10)
        // Token-weighted across both corpora: (500 + 1500) / (50 + 50).
        XCTAssertEqual(estimate.windows[.fourteenDays]?.combined.tokensPerSecond, 20)
    }

    func testWindowGatesApplyPerWindowNotJustTheFold() {
        // Five intervals qualify the fold, but only two land today — today's rate must stay nil
        // rather than dressing up two data points as an estimate.
        var accumulator = TokensPerSecondAccumulator()
        for _ in 0..<3 {
            accumulator.ingest(outputTokens: 100, at: day(5), model: "m", directInterval: 10)
        }
        for _ in 0..<2 {
            accumulator.ingest(outputTokens: 100, at: day(0), model: "m", directInterval: 10)
        }
        let estimate = TokensPerSecondEstimate.from(["claude": accumulator], now: now)
        XCTAssertNil(estimate.windows[.today]?.corpora["claude"]?.tokensPerSecond)
        XCTAssertEqual(estimate.windows[.fourteenDays]?.corpora["claude"]?.tokensPerSecond, 10)
    }

    func testMapperLabelsAndLensSelectionPerWindow() throws {
        var claude = TokensPerSecondAccumulator()
        var codex = TokensPerSecondAccumulator()
        for _ in 0..<5 {
            claude.ingest(outputTokens: 100, at: day(0), model: "sonnet", directInterval: 10)
            codex.ingest(outputTokens: 300, at: day(10), model: "gpt", directInterval: 10)
        }
        let estimate = TokensPerSecondEstimate.from(["claude": claude, "codex": codex], now: now)
        let lines = TokensPerSecondWindow.allCases.flatMap { TokensPerSecondMapper.lines(estimate, window: $0) }

        // The full window keeps the historical bare labels; the sub-windows carry suffixes.
        XCTAssertTrue(lines.contains { $0.label == "Est. TPS" })
        XCTAssertTrue(lines.contains { $0.label == "Est. TPS (Today)" })
        XCTAssertTrue(lines.contains { $0.label == "Claude (7 Days)" })

        let snapshot = ProviderSnapshot.make(
            provider: Provider(id: "tps", displayName: "TPS Tracker", icon: .providerMark("tps")),
            plan: nil,
            lines: lines,
            refreshedAt: now
        )
        let today = try XCTUnwrap(TPSTotal.from(snapshot, window: .today))
        XCTAssertEqual(today.combinedRate, 10)
        XCTAssertEqual(today.slices.map(\.provider.id), ["claude"])
        XCTAssertEqual(today.windowLabel, "Today")

        let full = try XCTUnwrap(TPSTotal.from(snapshot))
        XCTAssertEqual(full.combinedRate, 20)
        XCTAssertEqual(full.slices.map(\.provider.id), ["codex", "claude"])
        XCTAssertEqual(full.windowLabel, "Last 14 days")

        let sevenDays = try XCTUnwrap(TPSTotal.from(snapshot, window: .sevenDays))
        XCTAssertEqual(sevenDays.slices.map(\.provider.id), ["claude"])
        XCTAssertEqual(sevenDays.windowLabel, "Last 7 days")
    }
}
