import Foundation

struct FreebuffMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

/// Maps Freebuff's read-only session endpoint. The current meter supersedes legacy session caps;
/// its wire values remain Freebucks but the provider displays five Freebucks as one hour.
enum FreebuffUsageMapper {
    static let fiveDayPeriodMs = 5 * MetricPeriod.dayMs
    static let freebucksPerHour = 5.0

    static func map(response: HTTPResponse) throws -> FreebuffMappedUsage {
        let root: [String: Any]
        if response.statusCode == 404 {
            root = ["status": "none"]
        } else if let parsed = ProviderParse.jsonObject(response.body) {
            root = parsed
        } else {
            throw FreebuffUsageError.invalidResponse
        }
        guard root["status"] is String else { throw FreebuffUsageError.invalidResponse }

        let subscription = root["subscription"] as? [String: Any]
        let subscriptionUsage = subscription?["usage"] as? [String: Any]
        let freeWindows = root["freeWindows"] as? [String: Any]
        let freebucks = root["freebucks"] as? [String: Any]
        var lines: [MetricLine] = []

        if root.keys.contains("freebucks") {
            // Legacy free/subscription windows are still sent for compatibility. They no longer
            // describe the available budget when the account has the current hours meter.
        } else if let usage = subscriptionUsage {
            appendProgress(
                label: "Daily",
                used: usage["dayUsed"], limit: usage["dayLimit"],
                format: .count(suffix: "sessions"), resetsAt: usage["dayResetAt"],
                periodDurationMs: MetricPeriod.dayMs, to: &lines
            )
            appendProgress(
                label: "5-Day",
                used: usage["fiveDayUsed"], limit: usage["fiveDayLimit"],
                format: .count(suffix: "sessions"), resetsAt: nil,
                periodDurationMs: Self.fiveDayPeriodMs, to: &lines
            )
            appendProgress(
                label: "Monthly",
                used: usage["monthUsed"], limit: usage["monthLimit"],
                format: .count(suffix: "sessions"), resetsAt: usage["periodEndsAt"],
                periodDurationMs: nil, to: &lines
            )
            appendProgress(
                label: "Premium Sessions",
                used: usage["dayPremiumUsed"], limit: usage["dayPremiumLimit"],
                format: .count(suffix: "sessions"), resetsAt: usage["dayResetAt"],
                periodDurationMs: MetricPeriod.dayMs, detail: "Luna / DeepSeek V4 Pro", to: &lines
            )
            appendProgress(
                label: "Free Premium Sessions",
                used: usage["freeDayUsed"], limit: usage["freeDayLimit"],
                format: .count(suffix: "sessions"), resetsAt: usage["dayResetAt"],
                periodDurationMs: MetricPeriod.dayMs, to: &lines
            )
        } else if let windows = freeWindows {
            appendProgress(
                label: "Daily",
                used: windows["dayUsed"], limit: windows["dayLimit"],
                format: .count(suffix: "sessions"), resetsAt: windows["dayResetAt"],
                periodDurationMs: MetricPeriod.dayMs, to: &lines
            )
            appendProgress(
                label: "Weekly",
                used: windows["weekUsed"], limit: windows["weekLimit"],
                format: .count(suffix: "sessions"), resetsAt: nil,
                periodDurationMs: MetricPeriod.weekMs, to: &lines
            )
            appendProgress(
                label: "Monthly",
                used: windows["monthUsed"], limit: windows["monthLimit"],
                format: .count(suffix: "sessions"), resetsAt: windows["monthResetAt"],
                periodDurationMs: nil, to: &lines
            )
        } else if let pool = mostUsedRateLimit(root["rateLimitsByModel"] as? [String: Any] ?? [:]) {
            // Limited-access accounts may expose only model pools. Pools are grouped by their opaque
            // server key before choosing the most-used one, so shared per-model rows are never added
            // together and double-counted.
            appendProgress(
                label: "Session Pool",
                used: pool.recentCount, limit: pool.limit,
                format: .count(suffix: "sessions"), resetsAt: pool.resetAt,
                periodDurationMs: pool.periodDurationMs,
                detail: pool.poolLabel.map { "Most used pool: \($0)" }, to: &lines
            )
        }

        if let daily = freebucks?["daily"] as? [String: Any] {
            appendProgress(
                label: "Daily Hours",
                used: ProviderParse.number(daily["spent"]).map { $0 / freebucksPerHour },
                limit: ProviderParse.number(daily["limit"]).map { $0 / freebucksPerHour },
                format: .count(suffix: "hours"), resetsAt: daily["resetAt"],
                periodDurationMs: MetricPeriod.dayMs, to: &lines
            )
        }
        if let balance = ProviderParse.number(freebucks?["balance"]), balance >= 0 {
            lines.append(.values(
                label: "Hours Balance",
                values: [MetricValue(number: floor(balance / freebucksPerHour + 1e-9), kind: .count, label: "hours")]
            ))
        }

        appendMonthlySpend(subscriptionUsage: subscriptionUsage, freebucks: freebucks, to: &lines)
        MetricLine.appendNoDataIfNeeded(&lines)

        let tier = (subscription?["tierId"] as? String)?.nilIfEmpty
        let accessTier = (root["accessTier"] as? String)?.nilIfEmpty
        return FreebuffMappedUsage(plan: tier ?? accessTier?.capitalized, lines: lines)
    }

    private struct RateLimitPool {
        var key: String
        var poolLabel: String?
        var limit: Double
        var recentCount: Double
        var resetAt: Date?
        var periodDurationMs: Int?
    }

    private static func mostUsedRateLimit(_ models: [String: Any]) -> RateLimitPool? {
        var pools: [String: RateLimitPool] = [:]
        for (model, raw) in models {
            guard let value = raw as? [String: Any],
                  let limit = ProviderParse.number(value["limit"]), limit > 0,
                  let recentCount = ProviderParse.number(value["recentCount"]), recentCount >= 0
            else { continue }
            let key = (value["pool"] as? String)?.nilIfEmpty ?? "model:\(model)"
            let period = value["period"] as? String
            let candidate = RateLimitPool(
                key: key,
                poolLabel: (value["poolLabel"] as? String)?.nilIfEmpty,
                limit: limit,
                recentCount: recentCount,
                resetAt: date(value["resetAt"]),
                periodDurationMs: periodDuration(period)
            )
            if let existing = pools[key] {
                if candidate.recentCount / candidate.limit > existing.recentCount / existing.limit {
                    pools[key] = candidate
                }
            } else {
                pools[key] = candidate
            }
        }
        return pools.values.sorted {
            let left = $0.recentCount / $0.limit
            let right = $1.recentCount / $1.limit
            if left != right { return left > right }
            return $0.key < $1.key
        }.first
    }

    private static func periodDuration(_ value: String?) -> Int? {
        switch value {
        case "pacific_day": MetricPeriod.dayMs
        case "pacific_week": MetricPeriod.weekMs
        case "pacific_month": 30 * MetricPeriod.dayMs
        default: nil
        }
    }

    private static func appendMonthlySpend(
        subscriptionUsage: [String: Any]?,
        freebucks: [String: Any]?,
        to lines: inout [MetricLine]
    ) {
        let monthly = freebucks?["monthly"] as? [String: Any]
        let usage = subscriptionUsage
        let spent = ProviderParse.number(monthly?["spentUsd"] ?? usage?["monthSpendUsd"])
        let limit = ProviderParse.number(monthly?["limitUsd"] ?? usage?["monthSpendLimitUsd"])
        guard let spent, spent >= 0 else { return }
        let reset = date(monthly?["resetAt"] ?? usage?["periodEndsAt"])
        if let limit, limit > 0 {
            lines.append(.progress(
                label: "Monthly Spend", used: spent, limit: limit,
                format: .dollars, resetsAt: reset
            ))
        } else {
            lines.append(.values(
                label: "Monthly Spend",
                values: [MetricValue(number: spent, kind: .dollars)]
            ))
        }
    }

    private static func appendProgress(
        label: String,
        used rawUsed: Any?,
        limit rawLimit: Any?,
        format: ProgressFormat,
        resetsAt rawReset: Any?,
        periodDurationMs: Int?,
        detail: String? = nil,
        to lines: inout [MetricLine]
    ) {
        guard let used = ProviderParse.number(rawUsed), used >= 0,
              let limit = ProviderParse.number(rawLimit), limit >= 0 else { return }
        lines.append(.progress(
            label: label, used: used, limit: limit, format: format,
            resetsAt: date(rawReset), periodDurationMs: periodDurationMs, detail: detail
        ))
    }

    /// A reset timestamp from the payload. The shared ISO-8601 helper parses both the plain and the
    /// fractional form with pre-built formatters; building one per reset date was pure overhead.
    private static func date(_ value: Any?) -> Date? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return OpenUsageISO8601.date(from: value)
    }
}
