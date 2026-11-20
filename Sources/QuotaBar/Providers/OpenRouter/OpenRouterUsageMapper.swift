import Foundation

/// Period spend summed from a `/api/v1/keys` page entry, in dollars.
struct OpenRouterSpend: Equatable, Sendable {
    var today: Double
    var week: Double
    var month: Double

    static let zero = OpenRouterSpend(today: 0, week: 0, month: 0)

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(today: lhs.today + rhs.today, week: lhs.week + rhs.week, month: lhs.month + rhs.month)
    }
}

/// Builds metric lines from the OpenRouter `/credits`, `/key` and `/keys` payloads. Each endpoint maps
/// independently so the provider can show whatever came back: `/credits` carries the balance, `/key`
/// the tier and period spend (or the management-key flag), `/keys` the per-key spend a management key
/// needs, and either one failing still leaves the other's rows usable.
enum OpenRouterUsageMapper {
    /// Diagnostic key for a per-key cap whose remaining amount never arrived.
    static let missingLimitRemainingDiagnosticKey = "openrouter.key.limit-remaining-missing"

    /// A management key cannot run inference, so `/key` carries no spend for it; the account's spend
    /// is the sum over the keys `/api/v1/keys` lists.
    static func isManagementKey(_ data: [String: Any]) -> Bool {
        data["is_management_key"] as? Bool == true
    }

    /// One `/api/v1/keys` page: `{ "data": [ { usage_daily, usage_weekly, usage_monthly }, … ] }`.
    /// Returns the number of entries too, so the caller can stop paginating on a short page.
    static func keysPageSpend(_ body: Data) throws -> (spend: [OpenRouterSpend], count: Int) {
        guard let keys = ProviderParse.jsonObject(body)?["data"] as? [[String: Any]] else {
            throw OpenRouterUsageError.invalidResponse
        }
        return (try keys.map(spend(from:)), keys.count)
    }

    /// Today / This Week / This Month value rows for a summed spend.
    static func spendLines(_ spend: OpenRouterSpend) -> [MetricLine] {
        [("Today", spend.today), ("This Week", spend.week), ("This Month", spend.month)].map { label, amount in
            .values(label: label, values: [MetricValue(number: max(0, amount), kind: .dollars)])
        }
    }

    private static func spend(from key: [String: Any]) throws -> OpenRouterSpend {
        guard let today = ProviderParse.number(key["usage_daily"]),
              let week = ProviderParse.number(key["usage_weekly"]),
              let month = ProviderParse.number(key["usage_monthly"])
        else { throw OpenRouterUsageError.invalidResponse }
        return OpenRouterSpend(today: max(0, today), week: max(0, week), month: max(0, month))
    }

    /// OpenRouter wraps every payload in `{ "data": { ... } }`.
    static func dataObject(_ body: Data) -> [String: Any]? {
        ProviderParse.jsonObject(body)?["data"] as? [String: Any]
    }

    /// Credits meter + Balance from `/credits`. Both totals are required: a missing purchased-total
    /// field cannot be treated as a measured $0 balance just because lifetime usage is present.
    static func creditsLines(from data: [String: Any]) -> [MetricLine] {
        guard let totalUsage = ProviderParse.number(data["total_usage"]),
              let reportedCredits = ProviderParse.number(data["total_credits"])
        else { return [] }

        let used = max(0, totalUsage)
        // `total_credits` is the lifetime amount added to the account; balance is what's left of it.
        let totalCredits = max(0, reportedCredits)

        var lines: [MetricLine] = []
        // Credits meter: spend against the credits purchased. Only a positive ceiling makes a meter
        // meaningful (a free/never-topped-up account reports 0 here) — those accounts still get Balance.
        if totalCredits > 0 {
            lines.append(.progress(label: "Credits", used: used, limit: totalCredits, format: .dollars))
        }
        // Balance: prepaid credits remaining. A real zero is shown ("$0.00 left"), never "No data".
        lines.append(.values(
            label: "Balance",
            values: [MetricValue(number: max(0, totalCredits - used), kind: .dollars)]
        ))
        return lines
    }

    /// Period spend + optional per-key cap from `/key`, plus the tier surfaced as the plan name.
    static func keyMetrics(from data: [String: Any]) -> (plan: String?, lines: [MetricLine]) {
        var lines: [MetricLine] = []

        // Period spend straight from the API (not a local log scan), so a real zero is a measured zero.
        appendSpend(data["usage_daily"], label: "Today", into: &lines)
        appendSpend(data["usage_weekly"], label: "This Week", into: &lines)
        appendSpend(data["usage_monthly"], label: "This Month", into: &lines)

        // Per-key spend cap, when this key is configured with one. `usage` is lifetime spend on
        // the key; `limit_remaining` is what's left in the current window (daily/weekly/monthly
        // or lifetime), so used = limit - remaining.
        //
        // `limit_remaining` is the only evidence of how much of the cap is left. A payload that
        // carries `limit` without it cannot be measured, and treating the missing field as zero
        // would publish the cap as fully spent. Omit the row instead and say so in the log.
        if let limit = ProviderParse.number(data["limit"]), limit > 0 {
            if let remaining = ProviderParse.number(data["limit_remaining"]) {
                lines.append(.progress(
                    label: "Key Limit",
                    used: max(0, limit - max(0, remaining)),
                    limit: limit,
                    format: .dollars
                ))
            } else {
                DiagnosticGate.logOnce(for: missingLimitRemainingDiagnosticKey) {
                    AppLog.warn(
                        LogTag.plugin("openrouter"),
                        "key limit reported without a remaining amount; the Key Limit meter is hidden"
                    )
                }
            }
        }

        let plan = (data["is_free_tier"] as? Bool).map { $0 ? "Free tier" : "Pay as you go" }
        return (plan, lines)
    }

    private static func appendSpend(_ value: Any?, label: String, into lines: inout [MetricLine]) {
        guard let amount = ProviderParse.number(value) else { return }
        lines.append(.values(label: label, values: [MetricValue(number: max(0, amount), kind: .dollars)]))
    }
}
