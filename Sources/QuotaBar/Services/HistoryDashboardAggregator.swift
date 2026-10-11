import Foundation

/// One provider-independent piece of the Usage History report: a single calendar day's measured
/// tokens, plan-priced cost, and the public-API-rate comparison computed at fold time. Cost is nil
/// when the day's rows were all unpriced (dash), never a fabricated zero.
struct HistoryDayPoint: Identifiable, Equatable, Sendable {
    /// `yyyy-MM-dd` day key — stable identity across refreshes.
    let date: String
    /// The app's localized "Jun 21" axis label.
    let label: String
    let tokens: Int
    let cost: Double?
    let apiEstimate: Double?
    var id: String { date }
}

/// One model's 30-day totals inside a provider section. `slug` is the display spelling the provider's
/// logs use. A row the pricing layer cannot price yet shows tokens with a dashed cost: the automatic
/// discovery path (unknown-slug → public-catalogue revalidation) prices it on a later fold, and the
/// cost backfills with no user action.
struct HistoryModelRow: Identifiable, Equatable, Sendable {
    let providerID: String
    let slug: String
    let tokens: Int
    /// Plan-priced total over the window; nil when no pricing source could price the row (dash).
    let cost: Double?

    var id: String { "\(providerID)|\(slug.lowercased())" }
}

/// One provider's 30-day totals plus its per-model rows (cost desc). Sections appear in the
/// caller's enabled-provider order and only for providers that actually have history.
struct HistoryProviderSection: Identifiable, Equatable, Sendable {
    let providerID: String
    let displayName: String
    let tokens: Int
    let cost: Double?
    let apiEstimate: Double?
    let rows: [HistoryModelRow]
    var id: String { providerID }
}

/// A period total (Today / 7 Days / 30 Days): measured tokens, plan-priced cost, and the honest
/// fold-time API-rate estimate. Nil cost means no priced rows in the period; nil estimate means no
/// row's tokens could be priced at API rates at all.
struct HistoryPeriodTotal: Equatable, Sendable {
    let tokens: Int
    let cost: Double?
    let apiEstimate: Double?
}

/// The full Usage History screen model: the daily trend across the 30-day window, period totals, and
/// per-provider sections. Built entirely from provider snapshots' `usageHistory` — the same data the
/// spend tiles render — so the report can never disagree with the cards above it.
struct HistoryReport: Equatable, Sendable {
    let days: [HistoryDayPoint]
    let today: HistoryPeriodTotal
    let last7: HistoryPeriodTotal
    let last30: HistoryPeriodTotal
    let sections: [HistoryProviderSection]
    /// All recorded time, not just the 30-day window: every day the folded histories carry, priced
    /// where pricing exists. Log-backed providers (Claude, Codex, Grok) fold their whole local log
    /// corpus on full passes, so this approaches true lifetime; sources bound to a provider API
    /// window contribute only what that window held.
    let lifetime: HistoryPeriodTotal
    /// The earliest recorded day with usage, display-formatted ("Mar 2025") — the hero's "since"
    /// caption. Nil when no provider has any usage.
    let lifetimeSinceLabel: String?
    /// True when any contributing provider's lifetime dollars are locally imputed (public-API-rate
    /// estimates from logs that carry no per-message cost) rather than provider-recorded. The hero
    /// marks its total with "(Est.)" then — the tiles' ⓘ convention, applied to the screen's
    /// headline figure.
    let lifetimeCostIsEstimated: Bool
    let generatedAt: Date

    /// Every section is empty (no enabled provider has local history) — the screen's empty state.
    var isEmpty: Bool {
        sections.isEmpty
            && lifetime.tokens == 0
            && lifetime.cost == nil
            && lifetime.apiEstimate == nil
    }

    /// The "if it were all API" figure — the sum of fold-time estimates across the same recorded
    /// span as `lifetime`. Distinct from the plan-priced totals: this is a what-if comparison, never
    /// a recorded amount.
    var apiEstimateTotal: Double? { lifetime.apiEstimate }

    /// Whether the "At Public API Rates (Est.)" card earns its row. When the what-if total displays
    /// the same dollars as the lifetime hero, the card restates the hero as if it were a different
    /// fact — subscription log providers carry no per-message cost, so the hero's imputed total and
    /// this estimate coincide exactly ($3.1K and $3.1K). Compared at display precision, not raw
    /// doubles: $3,099.61 and $3,100.02 both read "$3.1K", so the duplicate row hides either way.
    var showsAPIEstimateCard: Bool {
        guard let estimate = apiEstimateTotal else { return false }
        guard let heroCost = lifetime.cost else { return true }
        return MetricFormatter.number(estimate, kind: .dollars, style: .row)
            != MetricFormatter.number(heroCost, kind: .dollars, style: .row)
    }
}

/// Folds enabled providers' daily usage histories into the Usage History report. Pure and
/// deterministic: same snapshots + reveals in, same report out (no dictionary-order leakage).
enum HistoryDashboardAggregator {
    /// Names for a report's inputs, so call sites can't mis-order the dictionaries.
    struct Input {
        var enabledProviderIDs: [String]
        var displayNameByProviderID: [String: String]
        var historyByProviderID: [String: ProviderUsageHistory]
        /// Which providers' folded `costUSD` is locally imputed (the history descriptor's
        /// `estimatedCost`): logs that carry no per-message cost, priced at public API rates at fold
        /// time. Drives the hero's "(Est.)" mark — the same flag the spend tiles' ⓘ uses.
        var estimatedCostByProviderID: [String: Bool] = [:]
    }

    /// Folds the window's histories. `now` anchors the 30-day window and the Today/7-day buckets;
    /// `calendar` decides local day keys, exactly like the scanners.
    static func report(_ input: Input, now: Date = Date(), calendar: Calendar = .current) -> HistoryReport {
        let windowKeys = UsageHistoryWindow.dayKeys(through: now, calendar: calendar)
        let todayKey = DailyUsageAccumulator.dayKey(from: now, calendar: calendar)
        // The 7-day bucket is today back through today-6. `windowKeys` is a Set — unordered — so
        // `.suffix(7)` on it would pick an arbitrary subset of days; derive the range from dates.
        let sevenDayKeys = Set(
            (0..<7).compactMap { offset -> String? in
                calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now))
                    .map { DailyUsageAccumulator.dayKey(from: $0, calendar: calendar) }
            }
        )

        var daysByDate: [String: (tokens: Int, cost: Double?, sawCost: Bool, estimate: Double?, sawEstimate: Bool)] = [:]
        var sections: [HistoryProviderSection] = []

        // Lifetime: every recorded day of every provider's history, unclipped by the 30-day window.
        // Cost semantics match the period totals (nil until some day carries a price).
        var lifetimeTokens = 0
        var lifetimeCost: Double?
        var lifetimeCostSeen = false
        var lifetimeCostIsEstimated = false
        var lifetimeEstimate: Double?
        var lifetimeEstimateSeen = false
        var earliestDayKey: String?

        for providerID in input.enabledProviderIDs {
            guard let history = input.historyByProviderID[providerID] else { continue }
            let dollarsAreEstimated = input.estimatedCostByProviderID[providerID] == true
            var tokens = 0
            var cost: Double?
            var sawCost = false
            var estimate: Double?
            var sawEstimate = false
            var rowsBySlug: [String: (tokens: Int, cost: Double?, sawCost: Bool, spelling: String)] = [:]

            for day in history.series.daily {
                // The lifetime fold runs over every recorded day; the windowed fold below re-enters
                // only window days. Days with neither tokens nor a price don't extend "since" — an
                // idle zero-filled day is not evidence of when recording began.
                if day.totalTokens > 0 || day.costUSD != nil {
                    lifetimeTokens = ProviderParse.addingSaturating(lifetimeTokens, day.totalTokens)
                    if let dayCost = day.costUSD {
                        lifetimeCost = (lifetimeCost ?? 0) + dayCost
                        lifetimeCostSeen = true
                        // A subscription-log provider's dollars are imputed at fold time (no
                        // per-message cost in its logs), so the hero's headline is an estimate,
                        // not recorded billing.
                        if dollarsAreEstimated {
                            lifetimeCostIsEstimated = true
                        }
                    }
                    if let dayEstimate = history.apiEstimateByDay?[day.date] {
                        lifetimeEstimate = (lifetimeEstimate ?? 0) + dayEstimate
                        lifetimeEstimateSeen = true
                    }
                    if earliestDayKey == nil || day.date < earliestDayKey! {
                        earliestDayKey = day.date
                    }
                }
            }

            for day in history.series.daily where windowKeys.contains(day.date) {
                var bucket = daysByDate[day.date] ?? (0, nil, false, nil, false)
                bucket.tokens = ProviderParse.addingSaturating(bucket.tokens, day.totalTokens)
                if let dayCost = day.costUSD {
                    bucket.cost = (bucket.cost ?? 0) + dayCost
                    bucket.sawCost = true
                }
                if let dayEstimate = history.apiEstimateByDay?[day.date] {
                    bucket.estimate = (bucket.estimate ?? 0) + dayEstimate
                    bucket.sawEstimate = true
                }
                daysByDate[day.date] = bucket

                // The section's totals cover the whole labeled 30-day window — not just today and
                // the 7-day slice, or a provider whose usage sits 8-30 days back would read idle.
                tokens = ProviderParse.addingSaturating(tokens, day.totalTokens)
                if let dayCost = day.costUSD {
                    cost = (cost ?? 0) + dayCost
                    sawCost = true
                }
                if let dayEstimate = history.apiEstimateByDay?[day.date] {
                    estimate = (estimate ?? 0) + dayEstimate
                    sawEstimate = true
                }
            }

            for day in history.modelUsage?.daily ?? [] where windowKeys.contains(day.date) {
                for model in day.models {
                    let key = model.model.lowercased()
                    var row = rowsBySlug[key] ?? (0, nil, false, model.model)
                    row.tokens = ProviderParse.addingSaturating(row.tokens, model.totalTokens)
                    if let modelCost = model.costUSD {
                        row.cost = (row.cost ?? 0) + modelCost
                        row.sawCost = true
                    }
                    rowsBySlug[key] = row
                }
            }

            // Skip a provider whose whole window is idle: an empty section is noise, and the screen's
            // empty state keys off every section being empty.
            guard tokens > 0 || sawCost || !rowsBySlug.isEmpty else { continue }

            let rows = rowsBySlug.values
                .map { value -> HistoryModelRow in
                    HistoryModelRow(
                        providerID: providerID,
                        slug: value.spelling,
                        tokens: value.tokens,
                        cost: value.sawCost ? value.cost : nil
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.cost != rhs.cost { return (lhs.cost ?? 0) > (rhs.cost ?? 0) }
                    if lhs.tokens != rhs.tokens { return lhs.tokens > rhs.tokens }
                    return lhs.slug.localizedStandardCompare(rhs.slug) == .orderedAscending
                }

            sections.append(HistoryProviderSection(
                providerID: providerID,
                displayName: input.displayNameByProviderID[providerID] ?? providerID,
                tokens: tokens,
                cost: sawCost ? cost : nil,
                apiEstimate: sawEstimate ? estimate : nil,
                rows: rows
            ))
        }

        let days = earliestDayKey == nil ? [] : windowKeys.sorted(by: >).map { date -> HistoryDayPoint in
            let bucket = daysByDate[date] ?? (0, nil, false, nil, false)
            let day = parseDay(date, calendar: calendar)
            return HistoryDayPoint(
                date: date,
                label: day.map(Formatters.monthDayLabel) ?? date,
                tokens: bucket.tokens,
                cost: bucket.sawCost ? bucket.cost : nil,
                apiEstimate: bucket.sawEstimate ? bucket.estimate : nil
            )
        }

        var todayTokens = 0
        var todayCost: Double?
        var todayCostSeen = false
        var todayEstimate: Double?
        var todayEstimateSeen = false
        if let bucket = daysByDate[todayKey] {
            todayTokens = bucket.tokens
            if bucket.sawCost { todayCost = bucket.cost; todayCostSeen = true }
            if bucket.sawEstimate { todayEstimate = bucket.estimate; todayEstimateSeen = true }
        }

        var weekTokens = 0
        var weekCost: Double?
        var weekCostSeen = false
        var weekEstimate: Double?
        var weekEstimateSeen = false
        var monthTokens = 0
        var monthCost: Double?
        var monthCostSeen = false
        var monthEstimate: Double?
        var monthEstimateSeen = false
        for (date, bucket) in daysByDate {
            if sevenDayKeys.contains(date) {
                weekTokens = ProviderParse.addingSaturating(weekTokens, bucket.tokens)
                if bucket.sawCost, let dayCost = bucket.cost {
                    weekCost = (weekCost ?? 0) + dayCost
                    weekCostSeen = true
                }
                if bucket.sawEstimate, let dayEstimate = bucket.estimate {
                    weekEstimate = (weekEstimate ?? 0) + dayEstimate
                    weekEstimateSeen = true
                }
            }
            monthTokens = ProviderParse.addingSaturating(monthTokens, bucket.tokens)
            if bucket.sawCost, let dayCost = bucket.cost {
                monthCost = (monthCost ?? 0) + dayCost
                monthCostSeen = true
            }
            if bucket.sawEstimate, let dayEstimate = bucket.estimate {
                monthEstimate = (monthEstimate ?? 0) + dayEstimate
                monthEstimateSeen = true
            }
        }

        return HistoryReport(
            days: days,
            today: HistoryPeriodTotal(
                tokens: todayTokens,
                cost: todayCostSeen ? todayCost : nil,
                apiEstimate: todayEstimateSeen ? todayEstimate : nil
            ),
            last7: HistoryPeriodTotal(
                tokens: weekTokens,
                cost: weekCostSeen ? weekCost : nil,
                apiEstimate: weekEstimateSeen ? weekEstimate : nil
            ),
            last30: HistoryPeriodTotal(
                tokens: monthTokens,
                cost: monthCostSeen ? monthCost : nil,
                apiEstimate: monthEstimateSeen ? monthEstimate : nil
            ),
            sections: sections,
            lifetime: HistoryPeriodTotal(
                tokens: lifetimeTokens,
                cost: lifetimeCostSeen ? lifetimeCost : nil,
                apiEstimate: lifetimeEstimateSeen ? lifetimeEstimate : nil
            ),
            lifetimeSinceLabel: earliestDayKey.flatMap { Self.sinceLabel(for: $0, calendar: calendar) },
            lifetimeCostIsEstimated: lifetimeCostIsEstimated,
            generatedAt: now
        )
    }

    /// The hero's "since" caption: the earliest recorded day as the app's localized month + year
    /// ("Mar 2025"). Nil when the day key isn't parseable — the caption just disappears.
    private static func sinceLabel(for dayKey: String, calendar: Calendar) -> String? {
        guard let day = parseDay(dayKey, calendar: calendar) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: day)
    }

    /// `yyyy-MM-dd` → Date at local midnight, for the axis label. Nil keeps the raw key as the label.
    private static func parseDay(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
