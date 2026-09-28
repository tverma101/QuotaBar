import Foundation
import XCTest
@testable import QuotaBar

/// The "Last 30 Days" tile is summed across providers by `TotalSpendAggregator`, so the underlying
/// window has to be the same number of calendar days for every provider. It was not.
///
/// `UsageHistoryWindow.previousDays` was 30 and the window was built as `0...previousDays` — 31 days —
/// so every log-scanner and iCloud-backed provider reported 31 days under a "Last 30 Days" label,
/// while Cursor used a literal `-29` and genuinely reported 30. Two identically labelled rows sitting
/// next to each other on the dashboard, a week apart, were then added together into one total.
final class UsageHistoryWindowConsistencyTests: XCTestCase {
    /// The label is a fixed contract in the descriptor ids, so the data is what has to match it.
    func testWindowIsExactlyThirtyCalendarDays() {
        XCTAssertEqual(UsageHistoryWindow.totalDays, 30)
        XCTAssertEqual(
            UsageHistoryWindow.dayKeys(through: Date()).count,
            UsageHistoryWindow.totalDays,
            "dayKeys must yield exactly one key per day in the labelled window"
        )
    }

    /// `previousDays` feeds `daysBack:` scanner arguments, where `startOfDay(now - daysBack)` is
    /// inclusive of that day — so an off-by-one there silently widens every scan by a day. It has to be
    /// derived, not hand-maintained, which is how the two drifted apart in the first place.
    func testPreviousDaysIsDerivedFromTheTotalRatherThanHandSet() {
        XCTAssertEqual(UsageHistoryWindow.previousDays, UsageHistoryWindow.totalDays - 1)
    }

    /// The regression itself: the day-key window and the scanner's `sinceDate` lower bound must select
    /// the same days. These are two separate code paths that both had to agree.
    func testDayKeysAndScannerCutoffSelectTheSameDays() throws {
        let now = try XCTUnwrap(
            Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 13, hour: 12)),
            "a fixed midday instant, so no boundary case depends on the wall clock"
        )
        let keys = UsageHistoryWindow.dayKeys(through: now)
        let cutoff = JSONLScanning.sinceDate(
            daysBack: UsageHistoryWindow.previousDays,
            now: now
        )

        // Compare *local calendar days*, not instants. The scanner cutoff is a local start-of-day
        // (which in a non-UTC zone is not midnight UTC), and the keys are local day strings, so
        // comparing instants across the two would fail on any machine that is not on UTC.
        let calendar = Calendar.current
        let earliestKey = try XCTUnwrap(keys.min(), "the window must not be empty")
        let cutoffDay = DateFormatter.isoDay.string(from: cutoff)
        XCTAssertEqual(
            earliestKey, cutoffDay,
            "the earliest window key and the scanner cutoff must be the same local day"
        )

        // And the day before the window start must be excluded, so the two paths cannot be a day apart.
        let dayBefore = try XCTUnwrap(
            calendar.date(byAdding: .day, value: -1, to: cutoff)
        )
        XCTAssertFalse(
            keys.contains(DateFormatter.isoDay.string(from: dayBefore)),
            "the day before the window starts must be outside the key set"
        )
    }

    /// Guards the count that reaches the user: a 30-day window is 30 bars and 30 daily keys, not 31.
    func testWindowIsNotOffByOne() {
        XCTAssertEqual(
            UsageHistoryWindow.dayKeys(through: Date()).count,
            30,
            "a 31-day window under a 'Last 30 Days' label is the bug this fixes"
        )
    }
}

private extension DateFormatter {
    /// Local-time `yyyy-MM-dd`, matching the local calendar the window is computed in. Forcing UTC here
    /// would make every key shift by a day in any non-UTC zone.
    static let isoDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
