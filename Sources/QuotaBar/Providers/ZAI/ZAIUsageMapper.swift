import Foundation

/// Builds metric lines from the Z.ai `/api/monitor/usage/quota/limit` payload and the plan name from
/// `/api/biz/subscription/list`. Ports and extends the legacy Tauri plugin's mapping:
/// - a `CREDIT_LIMIT` (or legacy `TOKENS_LIMIT`) entry whose window is sub-daily (`unit: 3`, hours)
///   is the 5-hour session meter,
/// - a `CREDIT_LIMIT` (or legacy `TOKENS_LIMIT`) entry whose window is multi-day (`unit: 6`, weeks)
///   is the weekly meter,
/// - a `TIME_LIMIT` entry (`unit: 5`, monthly) is the web-search/reader count meter (used / limit).
///
/// Both endpoints are undocumented internal APIs used by Z.ai's own subscription UI; the response
/// shapes are stable in practice. The mapper is pure (no I/O) so it tests cleanly against sample
/// payloads, exactly like the legacy plugin's fixture-based tests.
enum ZAIUsageMapper {
    /// One monthly web-search cycle, in milliseconds (Z.ai reports `unit: 5, number: 1`). The session
    /// and weekly meters instead carry the *payload's* actual window (see `classifyTokenWindow`), so
    /// their cadence tracks the plan rather than a hardcoded assumption; this monthly constant is only a
    /// fallback for the web-search line and the widget-descriptor default.
    static let monthlyPeriodMs = 30 * 24 * 60 * 60 * 1000

    /// How far ahead a reported reset may sit and still be believable. A payload that reports
    /// milliseconds where seconds were expected lands in the year 55000; a plan's real windows are
    /// hours or weeks.
    static let maximumResetHorizon: TimeInterval = 2 * 365 * 24 * 60 * 60

    /// `(plan, lines)` from the quota + subscription payloads. `subscription` may be `nil` (the
    /// request is best-effort) and the quota's `limits` array may carry one to three entries — only
    /// what's present is mapped, so a plan without web searches still shows the session meter.
    static func map(
        quotaBody: Data,
        subscriptionBody: Data?,
        now: Date = Date()
    ) throws -> (plan: String?, lines: [MetricLine]) {
        let plan = subscriptionBody.flatMap { planName(from: $0) }
        let lines = try mapQuota(quotaBody, now: now)
        return (plan, lines)
    }

    /// True when a 2xx quota body is the "valid key, but no GLM Coding Plan" signal: Z.ai answers
    /// `{"success":false,"code":500,"msg":"…coding plan"}` with no `data`. The provider turns this into a
    /// clear `.notAvailable` error (a header warning) instead of three blank "No data" meters that don't
    /// say why. Matched on the structured `success:false` plus the "coding plan" phrase the message
    /// carries (ASCII even in the localized string), so an unrelated business failure doesn't trip it.
    static func isNoCodingPlan(_ body: Data) -> Bool {
        guard let root = ProviderParse.jsonObject(body),
              (root["success"] as? Bool) == false else { return false }
        return ((root["msg"] as? String) ?? "").lowercased().contains("coding plan")
    }

    /// Session + weekly + web-search meters from the quota payload. An unreadable entry is skipped
    /// with a warning (its siblings' meters still render); a payload where a recognized entry
    /// existed but *no* meter could be built remains an invalid response rather than zero usage,
    /// and an explicit empty array remains a valid no-data state.
    static func mapQuota(_ body: Data, now: Date = Date()) throws -> [MetricLine] {
        guard let root = ProviderParse.jsonObject(body) else {
            throw ZAIUsageError.invalidResponse
        }
        // The limits array lives under `data.limits`; the legacy plugin also tolerated the root object
        // being the container directly (no `data` wrapper), so honor both.
        let container: [String: Any]
        if let data = root["data"] {
            guard let data = data as? [String: Any] else { throw ZAIUsageError.invalidResponse }
            container = data
        } else {
            container = root
        }
        guard let limits = container["limits"] as? [[String: Any]] else {
            throw ZAIUsageError.invalidResponse
        }
        guard !limits.isEmpty else {
            return [.noUsageData]
        }

        var lines: [MetricLine] = []
        var sawRecognizedLimit = false

        // Split the percentage quota entries by window length: a sub-daily window is the session
        // meter, and a multi-day window is the weekly meter. Current responses call these
        // CREDIT_LIMIT; older plans used TOKENS_LIMIT for the same shape.
        let percentageLimits = limits.filter {
            let type = ($0["type"] as? String) ?? ($0["name"] as? String)
            return type == "CREDIT_LIMIT" || type == "TOKENS_LIMIT"
        }
        for entry in percentageLimits {
            switch classifyTokenWindow(entry) {
            case .recognized(let window):
                sawRecognizedLimit = true
                switch window {
                case .session(let periodMs):
                    if let line = percentLine(entry, label: "Session", periodMs: periodMs, now: now) {
                        lines.append(line)
                    }
                case .weekly(let periodMs):
                    if let line = percentLine(entry, label: "Weekly", periodMs: periodMs, now: now) {
                        lines.append(line)
                    }
                }
            case .unknownWindow:
                break
            case .damaged:
                // The entry clearly claims a usage window we failed to read. If no other entry
                // yields a meter either, the payload is invalid rather than "no usage".
                sawRecognizedLimit = true
            }
        }
        if let web = findLimit(limits, type: "TIME_LIMIT") {
            switch webSearchLine(from: web, now: now) {
            case .yielded(let line):
                sawRecognizedLimit = true
                lines.append(line)
            case .notApplicable:
                break
            case .damaged:
                sawRecognizedLimit = true
            }
        }

        guard !lines.isEmpty else {
            if sawRecognizedLimit { throw ZAIUsageError.invalidResponse }
            return [.noUsageData]
        }
        return lines
    }

    /// `productName` from the first valid subscription entry (e.g. "GLM Coding Max").
    static func planName(from body: Data) -> String? {
        guard let root = ProviderParse.jsonObject(body),
              let list = root["data"] as? [[String: Any]],
              let first = list.first,
              let name = (first["productName"] as? String)?.nilIfEmpty
        else {
            return nil
        }
        return name
    }

    // MARK: - Private

    /// How a percentage quota entry's window maps to a meter. Z.ai encodes the window as a
    /// `(unit, number)` pair: `unit: 3` is hours (session), `unit: 6` is weeks (weekly), `unit: 5` is
    /// months. A sub-daily window is the session meter; a multi-day window is the weekly meter.
    /// Unknown units are ignored so a future Z.ai window cannot hide meters whose units QuotaBar
    /// still understands.
    private enum TokenWindow {
        case session(periodMs: Int)
        case weekly(periodMs: Int)
    }

    /// Result of classifying a percentage quota entry's window.
    private enum WindowOutcome {
        /// Parsed window that maps to a meter (session or weekly).
        case recognized(TokenWindow)
        /// A window unit QuotaBar doesn't know yet — ignored quietly so a future Z.ai window
        /// cannot hide meters whose units QuotaBar still understands.
        case unknownWindow
        /// The entry claims a usage window but its fields are unreadable — skipped with a
        /// warning instead of failing the whole payload.
        case damaged
    }

    /// Result of reading the TIME_LIMIT (web-search) entry.
    private enum WebSearchOutcome {
        case yielded(MetricLine)
        /// A zero cap is a plan without web searches, not a measurement of zero use — no meter.
        case notApplicable
        /// The entry claims the web-search allowance but its fields are unreadable — skipped
        /// with a warning instead of failing the whole payload.
        case damaged
    }

    private static func classifyTokenWindow(_ entry: [String: Any]) -> WindowOutcome {
        guard let unit = ProviderParse.number(entry["unit"]),
              let number = ProviderParse.number(entry["number"]),
              number > 0 else {
            return damagedWindowEntry(entry, reason: "missing or non-positive unit/number")
        }
        let unitMs: Double
        switch unit {
        case 3: unitMs = 60 * 60 * 1000
        case 4: unitMs = 24 * 60 * 60 * 1000
        case 6: unitMs = 7 * 24 * 60 * 60 * 1000
        case 5: unitMs = 30 * 24 * 60 * 60 * 1000
        default: return .unknownWindow
        }
        let duration = unitMs * number
        guard duration >= 1, duration < Double(Int.max) else {
            return damagedWindowEntry(entry, reason: "unbelievable window duration")
        }
        let periodMs = Int(duration)
        // Sub-daily → session; multi-day → weekly. The computed window rides along so the meter's
        // cadence reflects the payload instead of a hardcoded constant.
        if periodMs < 24 * 60 * 60 * 1000 {
            return .recognized(.session(periodMs: periodMs))
        }
        return .recognized(.weekly(periodMs: periodMs))
    }

    /// A recognized quota entry we could not read is skipped with a one-time warning (fail loudly
    /// into the log) — its siblings' meters still render.
    private static func damagedWindowEntry(_ entry: [String: Any], reason: String) -> WindowOutcome {
        DiagnosticGate.logOnce(for: "zai.quota.damaged-window-entry") {
            AppLog.warn(LogTag.auth("zai"), "skipped unreadable quota window entry (\(reason)): \(entry)")
        }
        return .damaged
    }

    /// A percentage meter (Session or Weekly) from a credit/token quota entry. `nil` (with a
    /// warning) when the entry's percentage is unreadable — its siblings' meters still render.
    private static func percentLine(
        _ entry: [String: Any],
        label: String,
        periodMs: Int,
        now: Date
    ) -> MetricLine? {
        guard let rawPercentage = ProviderParse.number(entry["percentage"]) else {
            DiagnosticGate.logOnce(for: "zai.quota.damaged-percentage-entry") {
                AppLog.warn(LogTag.auth("zai"), "skipped \(label) quota entry with unreadable percentage: \(entry)")
            }
            return nil
        }
        let percentage = ProviderParse.clampPercent(rawPercentage)
        let resetsAt = resetDate(entry["nextResetTime"], now: now)
        return .progress(
            label: label,
            used: percentage,
            limit: 100,
            format: .percent,
            resetsAt: resetsAt,
            periodDurationMs: periodMs
        )
    }

    /// TIME_LIMIT → a count meter (used / limit) for monthly web-search/reader calls.
    /// `.notApplicable` when the plan carries no web-search allowance at all (a zero cap) — there
    /// is no meter to draw.
    private static func webSearchLine(from entry: [String: Any], now: Date) -> WebSearchOutcome {
        guard let used = ProviderParse.number(entry["currentValue"]),
              let limit = ProviderParse.number(entry["usage"]),
              used >= 0,
              limit >= 0 else {
            DiagnosticGate.logOnce(for: "zai.quota.damaged-time-limit") {
                AppLog.warn(LogTag.auth("zai"), "skipped unreadable TIME_LIMIT entry: \(entry)")
            }
            return .damaged
        }
        // A zero cap is a plan without web searches, not a measurement of zero use. A meter with a
        // zero limit reads as an empty allowance that the user has not touched, which is misleading.
        guard limit > 0 else { return .notApplicable }
        // TIME_LIMIT carries a nextResetTime in current payloads (monthly renewal); honor it when
        // present so the countdown shows the real reset, otherwise the period cadence reads "monthly".
        let resetsAt = resetDate(entry["nextResetTime"], now: now)
        return .yielded(.progress(
            label: "Web Searches",
            used: used,
            limit: limit,
            format: .count(suffix: "searches"),
            resetsAt: resetsAt,
            periodDurationMs: monthlyPeriodMs
        ))
    }

    /// A reset instant, but only when it is still ahead of `now` and inside a believable horizon.
    ///
    /// `nextResetTime` arrives as epoch milliseconds (e.g. `1770648402389`). A zero, a stale value
    /// the server forgot to advance, or a payload that reports seconds where milliseconds were
    /// expected would otherwise render as "Resets soon" — or as a reset in the year 55000 — on every
    /// refresh. Dropping the instant lets the meter's own cadence ("Resets in 5h") answer instead.
    private static func resetDate(_ value: Any?, now: Date) -> Date? {
        guard let milliseconds = ProviderParse.number(value), milliseconds > 0 else { return nil }
        let date = Date(timeIntervalSince1970: milliseconds / 1000)
        guard date > now, date.timeIntervalSince(now) <= maximumResetHorizon else { return nil }
        return date
    }

    /// A limit entry matches by `type` or `name`; the legacy plugin checked both because Z.ai's
    /// payload has used either field across revisions.
    private static func findLimit(_ limits: [[String: Any]], type: String) -> [String: Any]? {
        for entry in limits {
            if (entry["type"] as? String) == type || (entry["name"] as? String) == type {
                return entry
            }
        }
        return nil
    }
}
