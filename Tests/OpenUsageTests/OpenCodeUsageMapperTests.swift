import XCTest
@testable import OpenUsage

/// The Go cap meters: percent format for both sources — the account-wide API (authoritative
/// percentages) and the local-log fallback (observed spend ÷ published cap). Both carry the
/// row's dollar context ("$1.08 of $12") when local windows are known.
final class OpenCodeUsageMapperTests: XCTestCase {
    func testAccountMeterLinesCarryPercentsResetsAndPeriods() {
        let reset = OpenUsageISO8601.date(from: "2026-07-12T13:30:00.000Z")!
        let usage = OpenCodeGoAccountUsage(
            rolling: .init(status: "ok", percent: 4, resetsAt: reset),
            weekly: .init(status: "ok", percent: 25, resetsAt: reset),
            monthly: .init(status: "ok", percent: 78, resetsAt: reset)
        )
        let lines = OpenCodeUsageMapper.accountMeterLines(usage)
        XCTAssertEqual(lines.map(\.label), ["Session", "Weekly", "Monthly"])

        guard case let .progress(_, sessionUsed, sessionLimit, sessionFormat, sessionReset, sessionPeriod, _, sessionDetail) = lines[0] else {
            return XCTFail("session is not a progress line")
        }
        XCTAssertEqual(sessionUsed, 4)
        XCTAssertEqual(sessionLimit, 100)
        XCTAssertEqual(sessionFormat, .percent)
        XCTAssertEqual(sessionReset, reset)
        XCTAssertEqual(sessionPeriod, 5 * 60 * 60 * 1000)
        // The dollar context is the OFFICIAL remaining allowance derived from the API percent:
        // 96% of the $12 cap left.
        XCTAssertEqual(sessionDetail, "$11.52 of $12")

        guard case let .progress(_, weeklyUsed, weeklyLimit, weeklyFormat, _, weeklyPeriod, _, _) = lines[1] else {
            return XCTFail("weekly is not a progress line")
        }
        XCTAssertEqual(weeklyUsed, 25)
        XCTAssertEqual(weeklyLimit, 100)
        XCTAssertEqual(weeklyFormat, .percent)
        XCTAssertEqual(weeklyPeriod, 7 * 24 * 60 * 60 * 1000)

        guard case let .progress(_, monthlyUsed, monthlyLimit, monthlyFormat, _, monthlyPeriod, _, monthlyDetail) = lines[2] else {
            return XCTFail("monthly is not a progress line")
        }
        XCTAssertEqual(monthlyUsed, 78)
        XCTAssertEqual(monthlyLimit, 100)
        XCTAssertEqual(monthlyFormat, .percent)
        // The API reports the monthly reset but not its period length.
        XCTAssertNil(monthlyPeriod)
        XCTAssertEqual(monthlyDetail, "$13.20 of $60")   // 22% of $60 left
    }

    func testAccountMeterLinesRemainingDollarsAreOfficialNeverLocal() {
        let reset = OpenUsageISO8601.date(from: "2026-07-12T13:30:00.000Z")!
        let usage = OpenCodeGoAccountUsage(
            rolling: .init(status: "ok", percent: 100, resetsAt: reset),
            weekly: .init(status: "ok", percent: 0, resetsAt: reset),
            monthly: .init(status: "ok", percent: 50, resetsAt: reset)
        )
        let lines = OpenCodeUsageMapper.accountMeterLines(usage)

        // The detail derives from the API percent against the published cap — local observed spend
        // (which can overshoot the cap, e.g. an estimated $46 on a $30 week) never appears here.
        guard case let .progress(_, _, _, _, _, _, _, sessionDetail) = lines[0],
              case let .progress(_, _, _, _, _, _, _, weeklyDetail) = lines[1],
              case let .progress(_, _, _, _, _, _, _, monthlyDetail) = lines[2] else {
            return XCTFail("expected three progress lines")
        }
        XCTAssertEqual(sessionDetail, "$0.00 of $12")
        XCTAssertEqual(weeklyDetail, "$30.00 of $30")
        XCTAssertEqual(monthlyDetail, "$30.00 of $60")
    }

    func testLocalMeterLinesConvertSpendToPercentOfCap() {
        let reset = OpenUsageISO8601.date(from: "2026-07-12T13:30:00.000Z")!
        let windows = OpenCodeGoWindows(
            sessionSpend: 6.0, sessionResetsAt: reset,
            weeklySpend: 12.0, weeklyResetsAt: reset,
            monthlySpend: 40.0, monthlyResetsAt: reset, monthlyPeriodMs: 2_592_000_000
        )
        let lines = OpenCodeUsageMapper.meterLines(windows)

        guard case let .progress(_, sessionUsed, sessionLimit, sessionFormat, sessionReset, sessionPeriod, _, sessionDetail) = lines[0] else {
            return XCTFail("session is not a progress line")
        }
        XCTAssertEqual(sessionUsed, 50)          // 6.0 / 12
        XCTAssertEqual(sessionLimit, 100)
        XCTAssertEqual(sessionFormat, .percent)
        XCTAssertEqual(sessionReset, reset)
        XCTAssertEqual(sessionPeriod, 5 * 60 * 60 * 1000)
        XCTAssertEqual(sessionDetail, "$6.00 of $12")

        guard case let .progress(_, weeklyUsed, _, _, _, weeklyPeriod, _, weeklyDetail) = lines[1] else {
            return XCTFail("weekly is not a progress line")
        }
        XCTAssertEqual(weeklyUsed, 40)           // 12.0 / 30
        XCTAssertEqual(weeklyPeriod, 7 * 24 * 60 * 60 * 1000)
        XCTAssertEqual(weeklyDetail, "$12.00 of $30")

        guard case let .progress(_, monthlyUsed, _, _, _, monthlyPeriod, _, monthlyDetail) = lines[2] else {
            return XCTFail("monthly is not a progress line")
        }
        XCTAssertEqual(monthlyUsed, 66.66666666666666)  // 40.0 / 60
        XCTAssertEqual(monthlyPeriod, 2_592_000_000)
        XCTAssertEqual(monthlyDetail, "$40.00 of $60")
    }

    func testZeroSpendMetersReadZeroPercent() {
        let windows = OpenCodeGoWindows(
            sessionSpend: 0, sessionResetsAt: nil,
            weeklySpend: 0, weeklyResetsAt: nil,
            monthlySpend: 0, monthlyResetsAt: nil, monthlyPeriodMs: nil
        )
        let lines = OpenCodeUsageMapper.meterLines(windows)
        guard case let .progress(_, sessionUsed, _, _, _, _, _, _)? = lines.first else {
            return XCTFail("expected a Session meter")
        }
        XCTAssertEqual(sessionUsed, 0)
    }
}
