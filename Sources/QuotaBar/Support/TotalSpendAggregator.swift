import Foundation

/// The spend period the Total Spend card can show — matching the three per-provider spend tiles
/// `SpendTileMapper` emits, whose line labels double as the lookup keys here.
enum TotalSpendPeriod: String, CaseIterable, Identifiable, Sendable {
    case today = "Today"
    case yesterday = "Yesterday"
    case last30 = "Last 30 Days"

    var id: String { rawValue }

    /// The metric-line label this period sums across providers (identical to the raw value today,
    /// but kept as its own accessor so the two meanings can diverge without a hunt).
    var lineLabel: String { rawValue }

    /// Compact segment title for the period switcher — "Last 30 Days" doesn't fit three-across
    /// in the 320pt popover without shrinking every segment.
    var shortLabel: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .last30: "30 Days"
        }
    }
}

/// Which quantity the Total Spend card's ring, center, and legend show. The title menu persists this
/// choice; the aggregator always collects both dollars and tokens so flipping modes doesn't re-scan.
/// Raw value `apiSpend` is kept so existing installs don't lose their stored Cost selection.
enum TotalSpendMetric: String, CaseIterable, Identifiable, Sendable {
    /// Menu order is declaration order: Cost → Cost/MTok → Tokens. Cost is the default.
    case cost = "apiSpend"
    case costPerMtok
    case tokens

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cost: "Cost"
        case .costPerMtok: "Cost/MTok"
        case .tokens: "Tokens"
        }
    }

    /// Empty-state copy when no provider qualifies for this metric in the selected period.
    var emptyMessage: String {
        switch self {
        case .cost: "No cost data for this period"
        case .costPerMtok: "No cost-per-token data for this period"
        case .tokens: "No token data for this period"
        }
    }

    /// Dollar-backed modes can inherit the local-estimate note when any contributor's spend is imputed.
    var usesDollarEstimateNote: Bool {
        switch self {
        case .cost, .costPerMtok: true
        case .tokens: false
        }
    }
}

/// One provider's contribution to a period's total: dollars and tokens from the same spend line,
/// plus whether the dollars are a local estimate (log-scanned providers) or measured (Cursor's CSV).
struct TotalSpendSlice: Identifiable, Equatable {
    let provider: Provider
    let amountUSD: Double
    let hasDollarAmount: Bool
    let tokenCount: Double
    let tokenCountSaturated: Bool
    let estimated: Bool
    let isPartial: Bool
    let hasIncompleteCost: Bool

    var id: String { provider.id }

    /// Dollars per million tokens for this provider alone. `nil` when either side is missing.
    var costPerMtok: Double? {
        guard hasDollarAmount, tokenCount > 0 else { return nil }
        let rate = (amountUSD / tokenCount) * 1_000_000
        return rate.isFinite ? rate : nil
    }
}

/// One provider's ready-to-draw contribution under a chosen metric: the amount that sizes the ring
/// and ranks the legend, plus the formatted value surfaces read through `MetricFormatter`.
struct TotalSpendProjectedSlice: Identifiable, Equatable {
    let provider: Provider
    let displayAmount: Double
    let displayAmountIsLowerBound: Bool
    let estimated: Bool

    var id: String { provider.id }
}

/// A period's cross-provider totals under one metric: ranked slices, center value, and estimate flag.
struct TotalSpendProjection: Equatable {
    let metric: TotalSpendMetric
    let slices: [TotalSpendProjectedSlice]
    let centerValue: Double
    let isEstimated: Bool
    let hasIncompleteCost: Bool
    let hasPartialData: Bool
    let centerValueIsLowerBound: Bool
    let hasActiveSessionData: Bool
    let hasSaturatedTokenData: Bool

    var isEmpty: Bool { slices.isEmpty }
}

/// A period's cross-provider raw totals: every spend-capable provider that contributed dollars and/or
/// tokens. Presentation (include / rank / center) is `projection(for:)`.
struct TotalSpend: Equatable {
    let period: TotalSpendPeriod
    let slices: [TotalSpendSlice]

    var totalUSD: Double {
        var total = 0.0
        for slice in slices {
            let next = total + slice.amountUSD
            guard next.isFinite else { return total }
            total = next
        }
        return total
    }
    var totalTokens: Double {
        var total = 0.0
        for slice in slices {
            let next = total + slice.tokenCount
            guard next.isFinite else { return total }
            total = next
        }
        return total
    }
    /// The combined number is an estimate as soon as any contributor's dollars are imputed locally.
    var isEstimated: Bool { slices.contains(where: \.estimated) }
    /// Raw storage empty — no provider had dollars or tokens for the period.
    var isEmpty: Bool { slices.isEmpty }

    /// Filters, ranks, and computes the center value for the title menu's selected metric.
    func projection(for metric: TotalSpendMetric) -> TotalSpendProjection {
        let included: [(slice: TotalSpendSlice, display: Double)] = slices.compactMap { slice in
            switch metric {
            case .cost:
                // Show each known priced subtotal; the projection keeps the Partial marker when
                // another model/provider contribution has no known price.
                guard slice.hasDollarAmount else { return nil }
                return (slice, slice.amountUSD)
            case .tokens:
                guard slice.tokenCount > 0 else { return nil }
                return (slice, slice.tokenCount)
            case .costPerMtok:
                guard !slice.hasIncompleteCost else { return nil }
                guard !slice.tokenCountSaturated else { return nil }
                guard let rate = slice.costPerMtok else { return nil }
                return (slice, rate)
            }
        }

        let ranked = included.sorted { lhs, rhs in
            if lhs.display != rhs.display { return lhs.display > rhs.display }
            return lhs.slice.provider.displayName.localizedStandardCompare(rhs.slice.provider.displayName) == .orderedAscending
        }

        let projected = ranked.map {
            TotalSpendProjectedSlice(
                provider: $0.slice.provider,
                displayAmount: $0.display,
                displayAmountIsLowerBound: (metric == .cost && $0.slice.hasIncompleteCost)
                    || (metric == .tokens && ($0.slice.tokenCountSaturated || $0.slice.isPartial)),
                estimated: $0.slice.estimated
            )
        }

        let center: Double
        let estimated: Bool
        var aggregateCostOverflowed = false
        var aggregateTokenOverflowed = false
        switch metric {
        case .cost:
            var total = 0.0
            for item in ranked {
                let next = total + item.slice.amountUSD
                guard next.isFinite else {
                    aggregateCostOverflowed = true
                    break
                }
                total = next
            }
            center = total
            estimated = ranked.contains { $0.slice.estimated }
        case .tokens:
            var total = 0.0
            for item in ranked {
                let next = total + item.slice.tokenCount
                guard next.isFinite else {
                    aggregateTokenOverflowed = true
                    break
                }
                total = next
            }
            center = total
            estimated = false
        case .costPerMtok:
            var weightedRate = 0.0
            let largestTokenCount = ranked.map(\.slice.tokenCount).max() ?? 0
            let normalizedTokenTotal = largestTokenCount > 0
                ? ranked.reduce(0) { $0 + ($1.slice.tokenCount / largestTokenCount) }
                : 0
            if normalizedTokenTotal > 0, normalizedTokenTotal.isFinite {
                for item in ranked {
                    guard let rate = item.slice.costPerMtok else { continue }
                    let weight = (item.slice.tokenCount / largestTokenCount) / normalizedTokenTotal
                    let next = weightedRate + (rate * weight)
                    guard next.isFinite else {
                        aggregateCostOverflowed = true
                        break
                    }
                    weightedRate = next
                }
            }
            center = weightedRate
            estimated = ranked.contains { $0.slice.estimated }
        }

        let hasIncompleteCost: Bool
        let hasPartialData: Bool
        switch metric {
        case .cost:
            hasIncompleteCost = aggregateCostOverflowed || slices.contains(where: \.hasIncompleteCost)
            hasPartialData = hasIncompleteCost
        case .costPerMtok:
            hasIncompleteCost = aggregateCostOverflowed || slices.contains(where: {
                $0.hasIncompleteCost || $0.tokenCountSaturated
                    || ($0.hasDollarAmount && $0.tokenCount > 0 && $0.costPerMtok == nil)
            })
            hasPartialData = hasIncompleteCost
        case .tokens:
            hasIncompleteCost = false
            hasPartialData = aggregateTokenOverflowed || slices.contains(where: {
                $0.isPartial || $0.tokenCountSaturated
            })
        }
        return TotalSpendProjection(
            metric: metric,
            slices: projected,
            centerValue: center,
            isEstimated: estimated,
            hasIncompleteCost: hasIncompleteCost,
            hasPartialData: hasPartialData,
            centerValueIsLowerBound: (metric == .cost && hasIncompleteCost)
                || (metric == .tokens && hasPartialData),
            hasActiveSessionData: slices.contains(where: \.isPartial),
            hasSaturatedTokenData: slices.contains(where: \.tokenCountSaturated)
        )
    }
}

/// Sums per-provider daily spend into one cross-provider total — the data source for the dashboard's
/// Total Spend ring card. Pure and synchronous: it reads already-refreshed `ProviderSnapshot`s and
/// never fetches. A provider contributes when its snapshot carries a `.values` line with the period's
/// label *and* that line has dollars and/or tokens — idle periods (no line) are excluded, never zero.
enum TotalSpendAggregator {
    /// Build a period's slice from a provider's retained daily history instead of its spend tiles.
    ///
    /// Used for **dormant** providers — spend-capable providers the user has turned off. Their last
    /// snapshot is never refreshed, so its "Today" tile describes whatever day it was last computed
    /// (possibly weeks ago) and must never be summed as today's spend. The dated series can be
    /// re-windowed against `now` however, so historical usage still lands on the days it happened.
    /// Without this, disabling a heavily used provider silently dropped it out of the total, so the
    /// combined figure understated real spend.
    ///
    /// `history.series` is filtered to the window here rather than trusting the caller, mirroring
    /// `SpendTileMapper`: a persisted series can outlive a window change.
    static func slice(
        for provider: Provider,
        period: TotalSpendPeriod,
        history: ProviderUsageHistory,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TotalSpendSlice? {
        let days = windowDayKeys(for: period, now: now, calendar: calendar)
        guard !days.isEmpty else { return nil }

        var amount = 0.0
        var hasValidDollarAmount = false
        var dollarsOverflowed = false
        var tokens = 0.0
        var tokenCountSaturated = false
        var estimated = false
        var hasIncompleteCost = false

        for entry in history.series.daily {
            guard let day = dayKey(fromUsageDate: entry.date, calendar: calendar), days.contains(day)
            else { continue }
            if entry.tokenCountSaturated { tokenCountSaturated = true }
            if entry.totalTokens > 0 {
                let next = tokens + Double(entry.totalTokens)
                if next.isFinite { tokens = next } else { tokenCountSaturated = true }
            }
            // A day whose cost is incomplete but unexplained (and not a running local session) has no
            // trustworthy subtotal; keep its tokens and mark the period's dollars incomplete.
            let dayCostIsTrustworthy = entry.costIsComplete
                || entry.hasUnexplainedIncompleteCost == false
                || history.partialDays?.contains(day) == true
                || history.unknownModelsByDay[day]?.isEmpty == false
            guard let cost = entry.costUSD, cost.isFinite, cost >= 0 else {
                if entry.totalTokens > 0 { hasIncompleteCost = true }
                continue
            }
            guard dayCostIsTrustworthy else {
                hasIncompleteCost = true
                continue
            }
            guard !dollarsOverflowed else { continue }
            let next = amount + cost
            if next.isFinite {
                amount = next
                hasValidDollarAmount = true
            } else {
                dollarsOverflowed = true
                hasIncompleteCost = true
            }
            if !entry.costIsComplete { hasIncompleteCost = true }
            if history.estimatedCostDays?.contains(day) == true { estimated = true }
        }

        // A partial (still-running) day inside the window makes the period's figures lower bounds.
        let windowIsPartial = days.contains { history.partialDays?.contains($0) == true }
        if windowIsPartial { hasIncompleteCost = true }
        guard hasValidDollarAmount || tokens > 0 || tokenCountSaturated else { return nil }

        return TotalSpendSlice(
            provider: provider,
            amountUSD: amount,
            hasDollarAmount: hasValidDollarAmount,
            tokenCount: tokens,
            tokenCountSaturated: tokenCountSaturated,
            estimated: estimated,
            isPartial: windowIsPartial,
            hasIncompleteCost: hasIncompleteCost || (tokens > 0 && !hasValidDollarAmount)
        )
    }

    /// The `yyyy-MM-dd` keys one Total Spend period covers, including today: `today` and `yesterday`
    /// are single days, `last30` matches `UsageHistoryWindow.totalDays` so the ring and the per-provider
    /// "Last 30 Days" tile cannot disagree.
    static func windowDayKeys(
        for period: TotalSpendPeriod,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Set<String> {
        switch period {
        case .today:
            return [DailyUsageAccumulator.dayKey(from: now, calendar: calendar)]
        case .yesterday:
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return [] }
            return [DailyUsageAccumulator.dayKey(from: yesterday, calendar: calendar)]
        case .last30:
            return UsageHistoryWindow.dayKeys(through: now, calendar: calendar)
        }
    }

    /// A history entry's `yyyy-MM-dd` key, accepting the bare, ISO-8601, and 8-digit shapes the
    /// scanners emit. Mirrors `SpendTileMapper`'s normalization so a dormant provider's day lands on
    /// the same key its live tiles would have used.
    private static func dayKey(fromUsageDate rawDate: String, calendar: Calendar) -> String? {
        let value = rawDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil { return value }
        if let date = OpenUsageISO8601.date(from: value) {
            return DailyUsageAccumulator.dayKey(from: date, calendar: calendar)
        }
        if let match = value.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
            return String(value[match])
        }
        if value.range(of: #"^\d{8}$"#, options: .regularExpression) != nil {
            return "\(value.prefix(4))-\(value.dropFirst(4).prefix(2))-\(value.suffix(2))"
        }
        return nil
    }

    /// The total for one period across `providers` (pass them in display order; ties keep it).
    /// Slices keep provider display order input only as a stable traversal; metric projection re-ranks.
    ///
    /// `dormantHistories` carries the retained history of spend-capable providers the user has turned
    /// off, keyed by provider ID. A dormant provider has no fresh spend tiles (its snapshot is frozen
    /// at whenever it was last refreshed), so its period is rebuilt from those dated rows instead —
    /// see `slice(for:period:history:)`. A dormant provider whose history has nothing in the window
    /// simply contributes nothing, exactly like an idle enabled one.
    static func total(
        for period: TotalSpendPeriod,
        providers: [Provider],
        snapshots: [String: ProviderSnapshot],
        dormantHistories: [String: ProviderUsageHistory] = [:],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TotalSpend {
        let slices = providers.compactMap { provider -> TotalSpendSlice? in
            // Dormant providers are keyed in `dormantHistories` whether or not they have a retained
            // history — presence is what marks them as turned off, so their frozen spend tiles are
            // never trusted for a period. An empty history contributes nothing.
            if let history = dormantHistories[provider.id] {
                return slice(for: provider, period: period, history: history, now: now, calendar: calendar)
            }
            guard let snapshot = snapshots[provider.id],
                  let line = snapshot.line(label: period.lineLabel),
                  case .values(_, let values, _, _, let unknownModels, _) = line else { return nil }

            let dollars = values.filter { $0.kind == .dollars }
            var amount = 0.0
            var hasValidDollarAmount = false
            var dollarAggregationIncomplete = false
            let hasLowerBoundDollar = dollars.contains { $0.isLowerBound == true }
            var estimated = false
            for dollar in dollars {
                guard dollar.number.isFinite, dollar.number >= 0 else {
                    dollarAggregationIncomplete = true
                    continue
                }
                hasValidDollarAmount = true
                estimated = estimated || dollar.estimated
                guard !dollarAggregationIncomplete else { continue }
                let next = amount + dollar.number
                guard next.isFinite else {
                    dollarAggregationIncomplete = true
                    continue
                }
                amount = next
            }
            let tokenValues = values
                .filter { $0.kind == .count && $0.label == "tokens" }
            var tokens = 0.0
            var tokenCountSaturated = tokenValues.contains { $0.tokenCountSaturated == true }
            for tokenValue in tokenValues {
                guard tokenValue.number.isFinite, tokenValue.number >= 0 else {
                    tokenCountSaturated = true
                    continue
                }
                let next = tokens + tokenValue.number
                guard next.isFinite else {
                    tokenCountSaturated = true
                    continue
                }
                tokens = next
            }
            guard !dollars.isEmpty || tokens > 0 || tokenCountSaturated else { return nil }
            let isPartial = values.contains { $0.isPartial == true }

            return TotalSpendSlice(
                provider: provider,
                amountUSD: amount,
                hasDollarAmount: hasValidDollarAmount,
                tokenCount: tokens,
                tokenCountSaturated: tokenCountSaturated,
                estimated: estimated,
                isPartial: isPartial,
                hasIncompleteCost: !unknownModels.isEmpty || (tokens > 0 && !hasValidDollarAmount)
                    || dollarAggregationIncomplete || hasLowerBoundDollar || isPartial
            )
        }
        return TotalSpend(period: period, slices: slices)
    }
}
