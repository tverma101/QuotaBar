import Foundation
@testable import QuotaBar

/// Test-only helper for building instants that mean the same *local* wall-clock time everywhere.
///
/// Usage scanners bucket spend by local calendar day — correctly, because the number a user reads is
/// "what did I spend today". Fixtures anchored to UTC instants are only self-consistent when the suite
/// runs on UTC: at UTC+9 a `15:00Z` event lands on the following local day, and any expectation written
/// as the UTC date fails. The same applies to a clock the fixture is compared against — two instants hours
/// apart in UTC can straddle a local midnight.
///
/// Every other timezone the suite has been run under (UTC-4, UTC, UTC+9) hid at least one of these, so
/// they are anchored here instead: the numbers are local hours, and the day key is derived with the same
/// `Calendar.current` the production code uses.
enum TestLocalInstant {
    /// `hour` is a local hour, so 12 is midday wherever the suite runs.
    static func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int, _ minute: Int = 0, _ second: Int = 0
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = DateComponents(
            timeZone: .current,
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        )
        guard let date = calendar.date(from: components) else {
            preconditionFailure("invalid test instant \(year)-\(month)-\(day) \(hour):\(minute)")
        }
        return date
    }

    /// The same instant as an ISO-8601 UTC string, for fixtures that are written as text.
    static func iso(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int, _ minute: Int = 0, _ second: Int = 0
    ) -> String {
        OpenUsageISO8601.string(from: date(year, month, day, hour, minute, second))
    }

    /// The `yyyy-MM-dd` local day key a scanner would bucket that instant into.
    static func isoDay(_ year: Int, _ month: Int, _ day: Int) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date(year, month, day, 12))
    }
}
