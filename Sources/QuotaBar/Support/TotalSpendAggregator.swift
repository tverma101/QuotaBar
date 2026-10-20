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
    /// The total for one period across `providers` (pass them in display order; ties keep it).
    /// Slices keep provider display order input only as a stable traversal; metric projection re-ranks.
    static func total(
        for period: TotalSpendPeriod,
        providers: [Provider],
        snapshots: [String: ProviderSnapshot]
    ) -> TotalSpend {
        let slices = providers.compactMap { provider -> TotalSpendSlice? in
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
