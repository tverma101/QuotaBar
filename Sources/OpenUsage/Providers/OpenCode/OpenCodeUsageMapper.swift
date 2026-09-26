import Foundation

/// Turns the Go plan windows into the three cap meters. The published OpenCode Go caps are dollar-based
/// ($12 / rolling 5h, $30 / week, $60 / month), but the meters render as 0–100% consumption against the
/// cap so the same rows serve both sources:
///
/// - the account-wide `/zen/go/v1/usage` API (authoritative percentages, all machines and clients), and
/// - the local-log fallback (observed spend on this Mac ÷ the published cap).
///
/// The meters show ONLY the official subscription numbers when the API answers: the percent is
/// OpenCode's own accounting, and the dollar context is derived from that same percent against the
/// published cap (remaining allowance) — local estimates never mix into these rows, because they can
/// overshoot the cap and mislead. The spend tiles carry the local actual-spend view instead.
enum OpenCodeUsageMapper {
    static let sessionCap: Double = 12   // per rolling 5 hours
    static let weeklyCap: Double = 30    // per UTC week
    static let monthlyCap: Double = 60   // per anchored month

    /// Local fallback meters: this Mac's observed `opencode-go` spend as a share of the published cap.
    /// Used only when the account API is unreachable — local spend can undercount true account usage
    /// (other machines, sessions OpenCode hasn't finished writing), which is why the card also carries
    /// the honest spend tiles and why the API is preferred whenever it answers.
    static func meterLines(_ windows: OpenCodeGoWindows) -> [MetricLine] {
        [
            .progress(
                label: "Session", used: percent(windows.sessionSpend, cap: sessionCap), limit: 100,
                format: .percent, resetsAt: windows.sessionResetsAt, periodDurationMs: MetricPeriod.sessionMs,
                detail: dollarDetail(spend: windows.sessionSpend, cap: sessionCap)
            ),
            .progress(
                label: "Weekly", used: percent(windows.weeklySpend, cap: weeklyCap), limit: 100,
                format: .percent, resetsAt: windows.weeklyResetsAt, periodDurationMs: MetricPeriod.weekMs,
                detail: dollarDetail(spend: windows.weeklySpend, cap: weeklyCap)
            ),
            .progress(
                label: "Monthly", used: percent(windows.monthlySpend, cap: monthlyCap), limit: 100,
                format: .percent, resetsAt: windows.monthlyResetsAt, periodDurationMs: windows.monthlyPeriodMs,
                detail: dollarDetail(spend: windows.monthlySpend, cap: monthlyCap)
            )
        ]
    }

    /// Account-wide meters straight from the API: the percentages are OpenCode's own account accounting,
    /// so no cap math is applied here — the values are used as-is. The monthly window's reset is known
    /// but not its period length, so that row carries no period duration (the local fallback's anchored
    /// month does). `labelSuffix` disambiguates rows when several keys authenticate to different
    /// accounts ("Session (opencode-go)"). Each row's dollar context is the OFFICIAL remaining
    /// allowance (percent against the published cap) — purely derived from the API, never local.
    static func accountMeterLines(
        _ usage: OpenCodeGoAccountUsage,
        labelSuffix: String? = nil
    ) -> [MetricLine] {
        func label(_ base: String) -> String {
            labelSuffix.map { "\(base) (\($0))" } ?? base
        }
        return [
            .progress(
                label: label("Session"), used: Double(usage.rolling.percent ?? 0), limit: 100,
                format: .percent, resetsAt: usage.rolling.resetsAt, periodDurationMs: MetricPeriod.sessionMs,
                detail: usage.rolling.percent.map { remainingDollarDetail(percent: $0, cap: sessionCap) }
            ),
            .progress(
                label: label("Weekly"), used: Double(usage.weekly.percent ?? 0), limit: 100,
                format: .percent, resetsAt: usage.weekly.resetsAt, periodDurationMs: MetricPeriod.weekMs,
                detail: usage.weekly.percent.map { remainingDollarDetail(percent: $0, cap: weeklyCap) }
            ),
            .progress(
                label: label("Monthly"), used: Double(usage.monthly.percent ?? 0), limit: 100,
                format: .percent, resetsAt: usage.monthly.resetsAt, periodDurationMs: nil,
                detail: usage.monthly.percent.map { remainingDollarDetail(percent: $0, cap: monthlyCap) }
            )
        ]
    }

    /// The account row's dollar context: what's LEFT of the published cap, derived purely from the
    /// API's own percent — e.g. "80% used" pairs with "$12.00 of $60". Local estimates never appear
    /// here (they can overshoot the cap and read as broken); the tiles carry the local view.
    private static func remainingDollarDetail(percent: Int, cap: Double) -> String {
        let remaining = max(0, cap * (100 - Double(percent)) / 100)
        return "\(MetricFormatter.number(remaining, kind: .dollars, style: .row)) of \(MetricFormatter.number(cap, kind: .dollars, style: .tray))"
    }

    /// The fallback row's dollar context: observed local spend against the published cap, e.g.
    /// "$1.08 of $12". In fallback mode the percent above is derived from exactly these dollars.
    private static func dollarDetail(spend: Double, cap: Double) -> String {
        "\(MetricFormatter.number(spend, kind: .dollars, style: .row)) of \(MetricFormatter.number(cap, kind: .dollars, style: .tray))"
    }

    private static func percent(_ spend: Double, cap: Double) -> Double {
        guard cap > 0 else { return 0 }
        return spend / cap * 100
    }
}
