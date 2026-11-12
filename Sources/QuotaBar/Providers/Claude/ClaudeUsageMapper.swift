import Foundation

struct ClaudeMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
    /// Provider header notice (amber triangle + tooltip) riding along with this usage, e.g. the
    /// rate-limited warning. `nil` for a clean fetch.
    var warning: String?
}

enum ClaudeUsageMapper {
    static let sessionPeriodMs = MetricPeriod.sessionMs
    static let weeklyPeriodMs = MetricPeriod.weekMs

    static func mapUsageResponse(_ response: HTTPResponse, credentials: ClaudeOAuth, now: Date = Date()) throws -> ClaudeMappedUsage {
        try ProviderAuthRetry.requireSuccess(
            response,
            authExpired: ClaudeAuthError.tokenExpired,
            requestFailed: { ClaudeUsageError.requestFailed($0) }
        )

        guard let body = ProviderParse.jsonObject(response.body) else {
            throw ClaudeUsageError.invalidResponse
        }

        var lines: [MetricLine] = []
        appendUsageWindow(body["five_hour"], label: "Session", periodDurationMs: sessionPeriodMs, now: now, to: &lines)
        appendUsageWindow(body["seven_day"], label: "Weekly", periodDurationMs: weeklyPeriodMs, now: now, to: &lines)
        appendUsageWindow(body["seven_day_sonnet"], label: "Sonnet", periodDurationMs: weeklyPeriodMs, now: now, to: &lines)
        appendScopedWeeklyLimit(body["limits"], modelName: "Fable", label: "Fable", now: now, to: &lines)
        appendExtraUsage(body["extra_usage"], to: &lines)

        return ClaudeMappedUsage(
            plan: formatPlan(subscriptionType: credentials.subscriptionType, rateLimitTier: credentials.rateLimitTier),
            lines: lines
        )
    }

    /// Snapshot shown when the usage endpoint rate-limits us and there is no last-good usage to fall back
    /// on (e.g. the first fetch after launch): a status badge plus the staleness note, no live bars.
    static func rateLimitedUsage(credentials: ClaudeOAuth, retryAfterSeconds: Int?) -> ClaudeMappedUsage {
        let retryText = retryAfterSeconds.map(formatRateLimitMinutes)
        let waitText = retryText.map { "Rate limited, retry in ~\($0)" } ?? "Rate limited, try again later"
        return ClaudeMappedUsage(
            plan: formatPlan(subscriptionType: credentials.subscriptionType, rateLimitTier: credentials.rateLimitTier),
            lines: [
                .badge(label: "Status", text: waitText, colorHex: "#F59E0B"),
                rateLimitedNote(retryAfterSeconds: retryAfterSeconds)
            ],
            warning: rateLimitedWarning(retryAfterSeconds: retryAfterSeconds)
        )
    }

    /// Provider header warning (the amber triangle + tooltip) for the rate-limited state. The badge/note
    /// lines above only render when their metrics are enabled in the layout, so without this the default
    /// dashboard showed bare "No data" rows with no hint of why. Also warns the
    /// user off manual refreshes, which extend Anthropic's rate limiting.
    static func rateLimitedWarning(retryAfterSeconds: Int?) -> String {
        let base = "Updates blocked by Anthropic. Be patient — manual refreshes will make it worse."
        guard let retryText = retryAfterSeconds.map(formatRateLimitMinutes) else { return base }
        return "\(base) Retrying in ~\(retryText)."
    }

    /// Provider warning shown on the Claude header (the amber triangle + tooltip, like Z.ai's "no coding
    /// plan" notice) when the stored login can't read live usage because it lacks the `user:profile` scope
    /// (an inference-only token, e.g. from `claude setup-token`). Without it the Session / Weekly bars just
    /// read "No data" with no hint that a re-login restores them. The scanned spend tiles are unaffected
    /// and still load.
    static let missingProfileScopeWarning = "Re-login for live usage. Run `claude` and sign in again to restore session and weekly limits."

    /// The "live usage is rate limited" note appended to a last-good snapshot so the still-shown bars are
    /// flagged as possibly stale. Shared with `rateLimitedUsage` so the wording stays in one place.
    static func rateLimitedNote(retryAfterSeconds: Int?) -> MetricLine {
        let retryText = retryAfterSeconds.map(formatRateLimitMinutes)
        let noteText = retryText.map { "Live usage rate limited - retry in ~\($0)" } ?? "Live usage rate limited - data may be stale"
        return .text(label: "Note", value: noteText)
    }

    /// The longest Retry-After this build will honor. Live-usage windows are minutes; a day is
    /// already generous. Without a ceiling, a malformed header (or a millisecond value) parked the
    /// card behind a cooldown it could never leave, and its remaining time eventually reached
    /// `Int(_:)` beyond `Int.max` — a trap during refresh instead of the rate-limit notice. Copilot's
    /// org-probe cooldown is capped for the same reason.
    static let maximumRetryAfterSeconds = 24 * 60 * 60

    static func parseRetryAfterSeconds(_ response: HTTPResponse, now: Date = Date()) -> Int? {
        guard let raw = response.header("retry-after")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        if let seconds = Int(raw), seconds >= 0 {
            return min(seconds, maximumRetryAfterSeconds)
        }
        if let date = HTTPDateFormatter.date(from: raw) {
            let seconds = ceil(date.timeIntervalSince(now))
            guard seconds.isFinite, seconds > 0 else { return 0 }
            return Int(min(seconds, Double(maximumRetryAfterSeconds)))
        }
        return nil
    }

    static func formatPlan(subscriptionType: String?, rateLimitTier: String?) -> String? {
        guard let raw = subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        let base = raw.titleCased(separator: { $0 == " " }, lowercasingTail: true)

        guard let tier = rateLimitTier,
              let match = tier.range(of: #"\d+x"#, options: .regularExpression)
        else {
            return base
        }
        return "\(base) \(tier[match])"
    }

    private static func appendUsageWindow(
        _ value: Any?,
        label: String,
        periodDurationMs: Int,
        now: Date,
        to lines: inout [MetricLine]
    ) {
        guard let object = value as? [String: Any],
              let used = ProviderParse.number(object["utilization"])
        else {
            return
        }
        lines.append(.progress(
            label: label,
            used: used,
            limit: 100,
            format: .percent,
            resetsAt: resetDate(object["resets_at"], now: now),
            periodDurationMs: periodDurationMs
        ))
    }

    /// A model-scoped weekly limit from the `limits` array — `kind: "weekly_scoped"` with
    /// `scope.model.display_name` naming the model (e.g. "Fable"). Anthropic moved the per-model
    /// weekly windows off the legacy top-level `seven_day_<model>` keys (which now come back null)
    /// and into this array, so each scoped row is read by display name. `percent` is 0–100.
    private static func appendScopedWeeklyLimit(
        _ limits: Any?,
        modelName: String,
        label: String,
        now: Date,
        to lines: inout [MetricLine]
    ) {
        guard let array = limits as? [Any] else { return }
        for entry in array {
            guard let object = entry as? [String: Any],
                  object["kind"] as? String == "weekly_scoped",
                  let scope = object["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  model["display_name"] as? String == modelName,
                  let used = ProviderParse.number(object["percent"])
            else { continue }
            lines.append(.progress(
                label: label,
                used: used,
                limit: 100,
                format: .percent,
                resetsAt: resetDate(object["resets_at"], now: now),
                periodDurationMs: weeklyPeriodMs
            ))
            return
        }
    }

    private static func appendExtraUsage(_ value: Any?, to lines: inout [MetricLine]) {
        guard let object = value as? [String: Any],
              object["is_enabled"] as? Bool == true,
              let usedCents = ProviderParse.number(object["used_credits"])
        else {
            return
        }

        let used = ProviderParse.centsToDollars(usedCents)
        if let limitCents = ProviderParse.number(object["monthly_limit"]), limitCents > 0 {
            lines.append(.progress(
                label: "Extra usage spent",
                used: used,
                limit: ProviderParse.centsToDollars(limitCents),
                format: .dollars
            ))
        } else if used > 0 {
            // No monthly cap: an unbounded spend, carried raw so it formats through `MetricFormatter`
            // (compact like the spend tiles, e.g. "$1.2K spent") instead of a baked full-currency string.
            lines.append(.values(label: "Extra usage spent", values: [MetricValue(number: used, kind: .dollars)]))
        }
    }

    /// The furthest future instant accepted as a reset. Claude's windows are five hours and a week;
    /// this is a sanity bound for unit mix-ups and corrupted values, not a semantic window. It stays
    /// below the range where duration formatting could overflow `Int`, while still accepting any
    /// legitimately parsed timestamp.
    static let maximumResetHorizon: TimeInterval = 100 * 365 * 24 * 60 * 60

    private static func resetDate(_ value: Any?, now: Date) -> Date? {
        let parsed: Date?
        if let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            parsed = OpenUsageISO8601.date(from: text)
        } else if let number = ProviderParse.number(value), number.isFinite {
            let milliseconds = abs(number) < 1e10 ? number * 1000 : number
            parsed = Date(timeIntervalSince1970: milliseconds / 1000)
        } else {
            parsed = nil
        }
        guard let parsed,
              parsed > now,
              parsed.timeIntervalSince(now) <= maximumResetHorizon
        else { return nil }
        return parsed
    }

    private static func formatRateLimitMinutes(_ seconds: Int) -> String {
        guard seconds > 0 else { return "now" }
        return "\(Int(ceil(Double(seconds) / 60)))m"
    }

}

private enum HTTPDateFormatter {
    /// Built once: `DateFormatter` construction dominates parsing, and this is called for every
    /// rate-limit response that carries an HTTP-date `Retry-After`. `DateFormatter` is documented
    /// thread-safe once configured and this one is never mutated.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter
    }()

    static func date(from value: String) -> Date? {
        formatter.date(from: value)
    }
}

