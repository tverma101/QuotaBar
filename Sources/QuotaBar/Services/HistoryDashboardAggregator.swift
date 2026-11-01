import Foundation

/// One provider-independent piece of the Usage History report: a single calendar day's measured
/// tokens, the known plan-priced subtotal, and the public-API-rate comparison computed at fold time.
/// Cost is nil when the day's rows were all unpriced (dash), never a fabricated zero. Incomplete
/// subtotals remain visible and `hasIncompleteCost` tells the UI to label them Partial.
struct HistoryDayPoint: Identifiable, Equatable, Sendable {
    /// `yyyy-MM-dd` day key — stable identity across refreshes.
    let date: String
    /// The app's localized "Jun 21" axis label.
    let label: String
    let tokens: Int
    let tokenCountSaturated: Bool
    let cost: Double?
    let hasIncompleteCost: Bool
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
    /// Plan-priced amount over the window; nil when no pricing source could price the row (dash).
    let cost: Double?
    /// True when `cost` is a subtotal because part of this model's usage was unpriced or incomplete.
    let hasIncompleteCost: Bool
    let tokenCountSaturated: Bool

    var id: String { "\(providerID)|\(slug.lowercased())" }
}

/// One provider's 30-day totals plus its per-model rows (cost desc). Sections appear in the
/// caller's enabled-provider order and only for providers that actually have history.
struct HistoryProviderSection: Identifiable, Equatable, Sendable {
    let providerID: String
    let displayName: String
    let tokens: Int
    let tokenCountSaturated: Bool
    let cost: Double?
    /// True when any included dollar amount is locally imputed rather than provider-recorded.
    let hasEstimatedCost: Bool
    let hasIncompleteCost: Bool
    let apiEstimate: Double?
    let rows: [HistoryModelRow]
    var id: String { providerID }
}

/// A period total (Today / 7 Days / 30 Days): measured tokens, the known plan-priced subtotal, and
/// the honest fold-time API-rate estimate. Incomplete costs remain visible with the partial flag.
/// Nil cost means no priced rows; nil estimate means no row's tokens could be priced at API rates.
struct HistoryPeriodTotal: Equatable, Sendable {
    let tokens: Int
    let tokenCountSaturated: Bool
    let cost: Double?
    /// True when any included dollar amount is locally imputed rather than provider-recorded.
    let hasEstimatedCost: Bool
    let apiEstimate: Double?
    let hasIncompleteCost: Bool
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
    /// True when lifetime history includes tokens that could not be priced completely. Any known
    /// dollar subtotal remains visible and is labeled Partial.
    let lifetimeHasIncompleteCost: Bool
    /// True when the public-rate estimate includes a still-active session and can grow on refresh.
    let apiEstimateHasPartialData: Bool
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
        /// Providers whose folded `costUSD` is uniformly locally imputed (the history descriptor's
        /// `estimatedCost`). Histories with mixed sources also carry `estimatedCostDays`, which adds
        /// the hero's "(Est.)" mark only when an included day contains an imputed amount.
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

        var daysByDate: [String: (
            tokens: Int,
            cost: Double?,
            sawCost: Bool,
            estimate: Double?,
            sawEstimate: Bool,
            incompleteCost: Bool,
            incompleteEstimate: Bool,
            tokenCountSaturated: Bool,
            costOverflowed: Bool,
            estimateOverflowed: Bool
        )] = [:]
        var sections: [HistoryProviderSection] = []
        var estimatedCostDates: Set<String> = []

        // Lifetime: every recorded day of every provider's history, unclipped by the 30-day window.
        // Cost semantics match the period totals (nil until some day carries a price).
        var lifetimeTokens = 0
        var lifetimeTokenCountSaturated = false
        var lifetimeCost: Double?
        var lifetimeCostSeen = false
        var lifetimeCostOverflowed = false
        var lifetimeCostIsEstimated = false
        var lifetimeCostIncomplete = false
        var lifetimeEstimate: Double?
        var lifetimeEstimateSeen = false
        var lifetimeEstimateIncomplete = false
        var lifetimeEstimateOverflowed = false
        var lifetimeEstimatePartial = false
        var earliestDayKey: String?

        for providerID in input.enabledProviderIDs {
            guard let history = input.historyByProviderID[providerID] else { continue }
            // Pre-provenance OpenCode snapshots can contain gateway-priced dollars without a
            // per-day marker. Treat nil as unknown until a fresh scan writes an explicit empty set.
            let dollarsAreEstimated = input.estimatedCostByProviderID[providerID] == true
                || (providerID == "opencode" && history.estimatedCostDays == nil)
            var tokens = 0
            var sectionTokenCountSaturated = false
            var cost: Double?
            var sawCost = false
            var sectionCostIsEstimated = false
            var sectionCostIncomplete = false
            var costOverflowed = false
            var estimate: Double?
            var sawEstimate = false
            var sectionEstimateIncomplete = false
            var estimateOverflowed = false
            let structurallyIncompleteDays = Set(history.series.daily.compactMap { day in
                day.hasUnexplainedIncompleteCost == true
                    || day.costUSD.map { !$0.isFinite || $0 < 0 } == true
                    ? day.date : nil
            })
            let activeSessionDays = history.partialDays ?? []
            var rowsBySlug: [String: (
                tokens: Int,
                cost: Double?,
                sawCost: Bool,
                spelling: String,
                incompleteCost: Bool,
                tokenCountSaturated: Bool,
                costOverflowed: Bool
            )] = [:]

            for day in history.series.daily {
                // The lifetime fold runs over every recorded day; the windowed fold below re-enters
                // only window days. Days with neither tokens nor a price don't extend "since" — an
                // idle zero-filled day is not evidence of when recording began.
                if day.totalTokens > 0 || day.costUSD != nil {
                    if day.totalTokens > 0 && lifetimeTokens > Int.max - day.totalTokens {
                        lifetimeTokenCountSaturated = true
                    }
                    lifetimeTokens = ProviderParse.addingSaturating(lifetimeTokens, day.totalTokens)
                    lifetimeTokenCountSaturated = lifetimeTokenCountSaturated || day.tokenCountSaturated
                    let dayIncomplete = hasIncompleteCost(day, history: history)
                    if dayIncomplete { lifetimeCostIncomplete = true }
                    if let dayCost = displayableCost(day, history: history) {
                        lifetimeCostSeen = true
                        if !lifetimeCostOverflowed {
                            if let total = Self.addingFiniteCost(lifetimeCost, dayCost) {
                                lifetimeCost = total
                            } else {
                                lifetimeCostOverflowed = true
                                lifetimeCostIncomplete = true
                            }
                        }
                        // A subscription-log provider's dollars are imputed at fold time (no
                        // per-message cost in its logs), so the hero's headline is an estimate,
                        // not recorded billing.
                        if dollarsAreEstimated || history.estimatedCostDays?.contains(day.date) == true {
                            lifetimeCostIsEstimated = true
                        }
                    }
                    let estimateIncomplete = history.apiEstimateIncompleteDays?.contains(day.date) == true
                        || history.unknownModelsByDay[day.date]?.isEmpty == false
                    if estimateIncomplete { lifetimeEstimateIncomplete = true }
                    if !estimateIncomplete, let dayEstimate = history.apiEstimateByDay?[day.date] {
                        lifetimeEstimateSeen = true
                        if !lifetimeEstimateOverflowed {
                            if let total = Self.addingFiniteCost(lifetimeEstimate, dayEstimate) {
                                lifetimeEstimate = total
                                if activeSessionDays.contains(day.date) {
                                    lifetimeEstimatePartial = true
                                }
                            } else {
                                lifetimeEstimate = nil
                                lifetimeEstimateOverflowed = true
                                lifetimeEstimateIncomplete = true
                            }
                        }
                    }
                    if earliestDayKey == nil || day.date < earliestDayKey! {
                        earliestDayKey = day.date
                    }
                }
            }

            for day in history.series.daily where windowKeys.contains(day.date) {
                var bucket = daysByDate[day.date]
                    ?? (0, nil, false, nil, false, false, false, false, false, false)
                if day.totalTokens > 0 && bucket.tokens > Int.max - day.totalTokens {
                    bucket.tokenCountSaturated = true
                }
                bucket.tokens = ProviderParse.addingSaturating(bucket.tokens, day.totalTokens)
                bucket.tokenCountSaturated = bucket.tokenCountSaturated || day.tokenCountSaturated
                let dayIncomplete = hasIncompleteCost(day, history: history)
                if dayIncomplete {
                    bucket.incompleteCost = true
                    sectionCostIncomplete = true
                }
                if let dayCost = displayableCost(day, history: history) {
                    bucket.sawCost = true
                    if !bucket.costOverflowed {
                        if let total = Self.addingFiniteCost(bucket.cost, dayCost) {
                            bucket.cost = total
                        } else {
                            bucket.costOverflowed = true
                            bucket.incompleteCost = true
                            sectionCostIncomplete = true
                        }
                    }
                    if dollarsAreEstimated || history.estimatedCostDays?.contains(day.date) == true {
                        estimatedCostDates.insert(day.date)
                        sectionCostIsEstimated = true
                    }
                }
                let estimateIncomplete = history.apiEstimateIncompleteDays?.contains(day.date) == true
                    || history.unknownModelsByDay[day.date]?.isEmpty == false
                if estimateIncomplete {
                    bucket.incompleteEstimate = true
                    sectionEstimateIncomplete = true
                }
                if !estimateIncomplete, let dayEstimate = history.apiEstimateByDay?[day.date] {
                    bucket.sawEstimate = true
                    if !bucket.estimateOverflowed {
                        if let total = Self.addingFiniteCost(bucket.estimate, dayEstimate) {
                            bucket.estimate = total
                        } else {
                            bucket.estimate = nil
                            bucket.estimateOverflowed = true
                            bucket.incompleteEstimate = true
                            sectionEstimateIncomplete = true
                        }
                    }
                }
                daysByDate[day.date] = bucket

                // The section's totals cover the whole labeled 30-day window — not just today and
                // the 7-day slice, or a provider whose usage sits 8-30 days back would read idle.
                if day.totalTokens > 0 && tokens > Int.max - day.totalTokens {
                    sectionTokenCountSaturated = true
                }
                tokens = ProviderParse.addingSaturating(tokens, day.totalTokens)
                sectionTokenCountSaturated = sectionTokenCountSaturated || day.tokenCountSaturated
                if let dayCost = displayableCost(day, history: history) {
                    sawCost = true
                    if !costOverflowed {
                        if let total = Self.addingFiniteCost(cost, dayCost) {
                            cost = total
                        } else {
                            costOverflowed = true
                            sectionCostIncomplete = true
                        }
                    }
                }
                if !estimateIncomplete,
                   let dayEstimate = history.apiEstimateByDay?[day.date] {
                    sawEstimate = true
                    if !estimateOverflowed {
                        if let total = Self.addingFiniteCost(estimate, dayEstimate) {
                            estimate = total
                        } else {
                            estimate = nil
                            estimateOverflowed = true
                            sectionEstimateIncomplete = true
                        }
                    }
                }
            }

            for day in history.modelUsage?.daily ?? [] where windowKeys.contains(day.date) {
                for model in day.models {
                    let key = model.model.lowercased()
                    var row = rowsBySlug[key] ?? (0, nil, false, model.model, false, false, false)
                    if model.totalTokens > 0 && row.tokens > Int.max - model.totalTokens {
                        row.tokenCountSaturated = true
                    }
                    row.tokens = ProviderParse.addingSaturating(row.tokens, model.totalTokens)
                    row.tokenCountSaturated = row.tokenCountSaturated || model.tokenCountSaturated == true
                    if structurallyIncompleteDays.contains(day.date) {
                        row.incompleteCost = true
                    } else if let modelCost = model.costUSD {
                        row.sawCost = true
                        if !row.costOverflowed {
                            if let total = Self.addingFiniteCost(row.cost, modelCost) {
                                row.cost = total
                            } else {
                                row.costOverflowed = true
                                row.incompleteCost = true
                            }
                        }
                    }
                    if model.hasIncompleteCost {
                        row.incompleteCost = true
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
                        cost: value.sawCost ? value.cost : nil,
                        hasIncompleteCost: value.incompleteCost,
                        tokenCountSaturated: value.tokenCountSaturated
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
                tokenCountSaturated: sectionTokenCountSaturated,
                cost: sawCost ? cost : nil,
                hasEstimatedCost: sectionCostIsEstimated,
                hasIncompleteCost: sectionCostIncomplete,
                apiEstimate: sawEstimate && !sectionEstimateIncomplete ? estimate : nil,
                rows: rows
            ))
        }

        let days = earliestDayKey == nil ? [] : windowKeys.sorted(by: >).map { date -> HistoryDayPoint in
            let bucket = daysByDate[date]
                ?? (0, nil, false, nil, false, false, false, false, false, false)
            let day = parseDay(date, calendar: calendar)
            return HistoryDayPoint(
                date: date,
                label: day.map(Formatters.monthDayLabel) ?? date,
                tokens: bucket.tokens,
                tokenCountSaturated: bucket.tokenCountSaturated,
                cost: bucket.sawCost ? bucket.cost : nil,
                hasIncompleteCost: bucket.incompleteCost,
                apiEstimate: bucket.sawEstimate && !bucket.incompleteEstimate ? bucket.estimate : nil
            )
        }

        var todayTokens = 0
        var todayTokenCountSaturated = false
        var todayCost: Double?
        var todayCostSeen = false
        let todayCostIsEstimated = estimatedCostDates.contains(todayKey)
        var todayCostIncomplete = false
        var todayEstimate: Double?
        var todayEstimateSeen = false
        var todayEstimateIncomplete = false
        if let bucket = daysByDate[todayKey] {
            todayTokens = bucket.tokens
            todayTokenCountSaturated = bucket.tokenCountSaturated
            if bucket.sawCost { todayCost = bucket.cost; todayCostSeen = true }
            todayCostIncomplete = bucket.incompleteCost
            if bucket.sawEstimate { todayEstimate = bucket.estimate; todayEstimateSeen = true }
            todayEstimateIncomplete = bucket.incompleteEstimate
        }

        var weekTokens = 0
        var weekTokenCountSaturated = false
        var weekCost: Double?
        var weekCostSeen = false
        var weekCostIsEstimated = false
        var weekCostIncomplete = false
        var weekCostOverflowed = false
        var weekEstimate: Double?
        var weekEstimateSeen = false
        var weekEstimateIncomplete = false
        var weekEstimateOverflowed = false
        var monthTokens = 0
        var monthTokenCountSaturated = false
        var monthCost: Double?
        var monthCostSeen = false
        var monthCostIsEstimated = false
        var monthCostIncomplete = false
        var monthCostOverflowed = false
        var monthEstimate: Double?
        var monthEstimateSeen = false
        var monthEstimateIncomplete = false
        var monthEstimateOverflowed = false
        for (date, bucket) in daysByDate {
            if sevenDayKeys.contains(date) {
                if bucket.tokens > 0 && weekTokens > Int.max - bucket.tokens {
                    weekTokenCountSaturated = true
                }
                weekTokens = ProviderParse.addingSaturating(weekTokens, bucket.tokens)
                weekTokenCountSaturated = weekTokenCountSaturated || bucket.tokenCountSaturated
                if bucket.incompleteCost { weekCostIncomplete = true }
                if bucket.incompleteEstimate { weekEstimateIncomplete = true }
                if bucket.sawCost, let dayCost = bucket.cost {
                    weekCostSeen = true
                    if !weekCostOverflowed {
                        if let total = Self.addingFiniteCost(weekCost, dayCost) {
                            weekCost = total
                        } else {
                            weekCostOverflowed = true
                            weekCostIncomplete = true
                        }
                    }
                }
                if estimatedCostDates.contains(date) { weekCostIsEstimated = true }
                if bucket.sawEstimate, let dayEstimate = bucket.estimate {
                    weekEstimateSeen = true
                    if !weekEstimateOverflowed {
                        if let total = Self.addingFiniteCost(weekEstimate, dayEstimate) {
                            weekEstimate = total
                        } else {
                            weekEstimate = nil
                            weekEstimateOverflowed = true
                            weekEstimateIncomplete = true
                        }
                    }
                }
            }
            if bucket.tokens > 0 && monthTokens > Int.max - bucket.tokens {
                monthTokenCountSaturated = true
            }
            monthTokens = ProviderParse.addingSaturating(monthTokens, bucket.tokens)
            monthTokenCountSaturated = monthTokenCountSaturated || bucket.tokenCountSaturated
            if bucket.incompleteCost { monthCostIncomplete = true }
            if bucket.incompleteEstimate { monthEstimateIncomplete = true }
            if bucket.sawCost, let dayCost = bucket.cost {
                monthCostSeen = true
                if !monthCostOverflowed {
                    if let total = Self.addingFiniteCost(monthCost, dayCost) {
                        monthCost = total
                    } else {
                        monthCostOverflowed = true
                        monthCostIncomplete = true
                    }
                }
            }
            if estimatedCostDates.contains(date) { monthCostIsEstimated = true }
            if bucket.sawEstimate, let dayEstimate = bucket.estimate {
                monthEstimateSeen = true
                if !monthEstimateOverflowed {
                    if let total = Self.addingFiniteCost(monthEstimate, dayEstimate) {
                        monthEstimate = total
                    } else {
                        monthEstimate = nil
                        monthEstimateOverflowed = true
                        monthEstimateIncomplete = true
                    }
                }
            }
        }

        return HistoryReport(
            days: days,
            today: HistoryPeriodTotal(
                tokens: todayTokens,
                tokenCountSaturated: todayTokenCountSaturated,
                cost: todayCostSeen ? todayCost : nil,
                hasEstimatedCost: todayCostIsEstimated,
                apiEstimate: todayEstimateSeen && !todayEstimateIncomplete ? todayEstimate : nil,
                hasIncompleteCost: todayCostIncomplete
            ),
            last7: HistoryPeriodTotal(
                tokens: weekTokens,
                tokenCountSaturated: weekTokenCountSaturated,
                cost: weekCostSeen ? weekCost : nil,
                hasEstimatedCost: weekCostIsEstimated,
                apiEstimate: weekEstimateSeen && !weekEstimateIncomplete ? weekEstimate : nil,
                hasIncompleteCost: weekCostIncomplete
            ),
            last30: HistoryPeriodTotal(
                tokens: monthTokens,
                tokenCountSaturated: monthTokenCountSaturated,
                cost: monthCostSeen ? monthCost : nil,
                hasEstimatedCost: monthCostIsEstimated,
                apiEstimate: monthEstimateSeen && !monthEstimateIncomplete ? monthEstimate : nil,
                hasIncompleteCost: monthCostIncomplete
            ),
            sections: sections,
            lifetime: HistoryPeriodTotal(
                tokens: lifetimeTokens,
                tokenCountSaturated: lifetimeTokenCountSaturated,
                cost: lifetimeCostSeen ? lifetimeCost : nil,
                hasEstimatedCost: lifetimeCostIsEstimated,
                apiEstimate: lifetimeEstimateSeen && !lifetimeEstimateIncomplete ? lifetimeEstimate : nil,
                hasIncompleteCost: lifetimeCostIncomplete
            ),
            lifetimeSinceLabel: earliestDayKey.flatMap { Self.sinceLabel(for: $0, calendar: calendar) },
            lifetimeCostIsEstimated: lifetimeCostIsEstimated,
            lifetimeHasIncompleteCost: lifetimeCostIncomplete,
            apiEstimateHasPartialData: lifetimeEstimatePartial,
            generatedAt: now
        )
    }

    private static func hasIncompleteCost(_ day: DailyUsageEntry, history: ProviderUsageHistory) -> Bool {
        if day.costUSD.map({ !$0.isFinite || $0 < 0 }) == true { return true }
        if history.partialDays?.contains(day.date) == true { return true }
        guard day.totalTokens > 0 else { return false }
        return !day.costIsComplete
            || day.costUSD == nil
            || history.unknownModelsByDay[day.date]?.isEmpty == false
    }

    /// Keep a known subtotal only when an unknown-model warning accounts for the incomplete day.
    /// Persisted `false` cause metadata preserves that verification after old model details age out.
    /// A separate structural gap makes even the known-looking dollars unsafe to present.
    private static func displayableCost(_ day: DailyUsageEntry, history: ProviderUsageHistory) -> Double? {
        guard let cost = day.costUSD, cost.isFinite, cost >= 0 else { return nil }
        guard day.hasUnexplainedIncompleteCost != true,
              day.costIsComplete
                || day.hasUnexplainedIncompleteCost == false
                || history.partialDays?.contains(day.date) == true
                || history.unknownModelsByDay[day.date]?.isEmpty == false
        else { return nil }
        return cost
    }

    private static func addingFiniteCost(_ current: Double?, _ addition: Double) -> Double? {
        guard addition.isFinite, addition >= 0 else { return nil }
        let total = (current ?? 0) + addition
        return total.isFinite ? total : nil
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
