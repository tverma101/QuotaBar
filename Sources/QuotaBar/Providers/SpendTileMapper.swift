import Foundation
import os

/// Turns local daily token/cost data into the shared Today / Yesterday / Last 30 Days spend tiles.
/// Every spend-tracking provider funnels through here so the tiles render identically regardless of
/// source: Claude / Codex / Grok feed token/cost from their CLI logs, while Cursor feeds token/cost
/// derived from its CSV export. The data shape
/// (`DailyUsageSeries`) is a provider-neutral per-day carrier shared by every source.
enum SpendTileMapper {
    /// Append the three spend tiles (Today / Yesterday / Last 30 Days). A period with no usage is left
    /// unbacked so the tile reads "No data" — a zero here is indistinguishable from "the source hasn't
    /// accounted for this day yet," and a confident `$0.00 · 0 tokens` contradicts a live session meter
    /// that proves otherwise. This holds for every source (the Claude/Codex/Grok log scanners,
    /// Cursor's CSV export); there's no per-source branching. "No data" is also what a tile shows when
    /// the source couldn't be read at all (missing log, failed API/CSV), where the caller appends
    /// nothing. `estimated` controls whether the dollar value carries the local-estimate marker (ⓘ).
    /// `unknownModelsByDay` maps a `yyyy-MM-dd` day key to model names no pricing source can price.
    /// Their tokens still count, and any known priced subtotal remains visible beside the warning.
    /// Today / Yesterday pick up their own day's set; Last 30 Days carries the union across the whole
    /// window. Empty (the default) for sources without unknown-model detection.
    ///
    /// `apiEstimateByDay` carries a parallel per-day figure: what the same tokens would have cost at
    /// each model's public API rates. It is not rendered here — the Usage History screen's
    /// "At Public API Rates" total line consumes it. Nil (the default) for sources without an
    /// API-rate computation.
    static func appendTokenUsage(
        _ usage: DailyUsageSeries,
        to lines: inout [MetricLine],
        now: Date = Date(),
        estimated: Bool = true,
        unknownModelsByDay: [String: Set<String>] = [:],
        modelUsage: ModelUsageSeries? = nil,
        modelSourceNote: String? = nil,
        partialDays: Set<String> = [],
        apiEstimateByDay: [String: Double]? = nil,
        estimatedCostDays: Set<String>? = nil
    ) {
        let today = dayKey(from: now)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now).map(dayKey(from:))
        func estimatedCost(on day: String?) -> Bool {
            guard let estimatedCostDays else { return estimated }
            guard let day else { return false }
            return estimatedCostDays.contains(day)
        }
        let unexplainedIncompleteDays = Set(usage.daily.compactMap { entry -> String? in
            guard let day = dayKey(fromUsageDate: entry.date) else { return nil }
            if entry.hasUnexplainedIncompleteCost == true
                || (!entry.costIsComplete && entry.hasUnexplainedIncompleteCost == nil
                    && unknownModelsByDay[day]?.isEmpty != false && !partialDays.contains(day))
            {
                return day
            }
            return nil
        })

        if let entry = usage.daily.first(where: { dayKey(fromUsageDate: $0.date) == today }), hasUsage(entry) {
            lines.append(dayUsageLine(label: "Today", entry: entry, costUSD: displayableCost(
                                          entry, day: today, unknownModelsByDay: unknownModelsByDay,
                                          partialDays: partialDays
                                      ), estimated: estimatedCost(on: today),
                                      partial: partialDays.contains(today),
                                      costIsLowerBound: partialDays.contains(today)
                                        || hasKnownPartialCost(entry, day: today, unknownModelsByDay: unknownModelsByDay),
                                      tokenCountSaturated: entry.tokenCountSaturated,
                                      unknownModels: sortedModels(unknownModelsByDay[today]),
                                      modelBreakdown: modelBreakdown(
                                        modelUsage,
                                        days: [today],
                                        totalTokens: entry.totalTokens,
                                        tokenCountSaturated: entry.tokenCountSaturated,
                                        totalCostUSD: displayableCost(
                                            entry,
                                            day: today,
                                            unknownModelsByDay: unknownModelsByDay,
                                            partialDays: partialDays
                                        ),
                                        sourceNote: modelSourceNote,
                                        unexplainedIncompleteDays: unexplainedIncompleteDays
                                      )))
        }
        if let entry = usage.daily.first(where: { dayKey(fromUsageDate: $0.date) == yesterday }), hasUsage(entry) {
            lines.append(dayUsageLine(label: "Yesterday", entry: entry, costUSD: yesterday.flatMap {
                                          displayableCost(entry, day: $0, unknownModelsByDay: unknownModelsByDay,
                                                          partialDays: partialDays)
                                      }, estimated: estimatedCost(on: yesterday),
                                      partial: yesterday.map(partialDays.contains) == true,
                                      costIsLowerBound: yesterday.map {
                                        partialDays.contains($0)
                                            || hasKnownPartialCost(entry, day: $0, unknownModelsByDay: unknownModelsByDay)
                                      } ?? false,
                                      tokenCountSaturated: entry.tokenCountSaturated,
                                      unknownModels: sortedModels(yesterday.flatMap { unknownModelsByDay[$0] }),
                                      modelBreakdown: modelBreakdown(
                                        modelUsage,
                                        days: Set([yesterday].compactMap { $0 }),
                                        totalTokens: entry.totalTokens,
                                        tokenCountSaturated: entry.tokenCountSaturated,
                                        totalCostUSD: yesterday.flatMap {
                                            displayableCost(entry, day: $0, unknownModelsByDay: unknownModelsByDay,
                                                            partialDays: partialDays)
                                        },
                                        sourceNote: modelSourceNote,
                                        unexplainedIncompleteDays: unexplainedIncompleteDays
                                      )))
        }

        // The tile is labelled "Last 30 Days" and `TotalSpendAggregator` sums it cross-provider, so the
        // sum must cover exactly the labeled window. Filter instead of trusting the input: scan
        // windows are day-granular and a source that sweeps one day extra (or a persisted series that
        // outlived a window change) would otherwise be summed under the 30-day label.
        let windowKeys = UsageHistoryWindow.dayKeys(through: now)
        let windowed = usage.daily.filter { entry in
            dayKey(fromUsageDate: entry.date).map { windowKeys.contains($0) } == true
        }
        var totalTokens = 0
        var totalTokensSaturated = false
        for entry in windowed {
            totalTokensSaturated = totalTokensSaturated || entry.tokenCountSaturated
            if entry.totalTokens > 0 && totalTokens > Int.max - entry.totalTokens {
                totalTokensSaturated = true
            }
            totalTokens = ProviderParse.addingSaturating(totalTokens, entry.totalTokens)
        }
        let allUnknown = unknownModelsByDay
            .filter { windowKeys.contains($0.key) }
            .values
            .reduce(into: Set<String>()) { $0.formUnion($1) }
        // Keep the priced subtotal when incompleteness is explained by named unknown models. Other
        // incomplete accounting (for example, a provider-reported token mismatch) remains hidden until
        // its source can produce a trustworthy subtotal and a matching warning.
        let hasUnexplainedIncompleteCost = windowed.contains { entry in
            guard !entry.costIsComplete,
                  let day = dayKey(fromUsageDate: entry.date)
            else { return false }
            return entry.hasUnexplainedIncompleteCost == true
                || (entry.hasUnexplainedIncompleteCost == nil && unknownModelsByDay[day]?.isEmpty != false
                    && !partialDays.contains(day))
        }
        let costSamples = windowed.compactMap { entry -> Double? in
            guard let day = dayKey(fromUsageDate: entry.date) else { return nil }
            return displayableCost(entry, day: day, unknownModelsByDay: unknownModelsByDay,
                                   partialDays: partialDays)
        }
        var finiteCostTotal = 0.0
        var finiteCostTotalOverflowed = false
        for sample in costSamples {
            let next = finiteCostTotal + sample
            guard next.isFinite else {
                finiteCostTotalOverflowed = true
                break
            }
            finiteCostTotal = next
        }
        let totalCost = !hasUnexplainedIncompleteCost && !costSamples.isEmpty
            ? finiteCostTotal
            : nil
        if totalTokens > 0 || (totalCost ?? 0) > 0 {
            // The 30-day total is incomplete whenever ANY day in the window is partial — a running
            // Hermes session keeps growing, so the sum is real but not final.
            let windowPartial = windowed.contains { dayKey(fromUsageDate: $0.date).map(partialDays.contains) == true }
            let costIsLowerBound = finiteCostTotalOverflowed || windowPartial || windowed.contains { entry in
                guard !entry.costIsComplete, let day = dayKey(fromUsageDate: entry.date) else { return false }
                return entry.hasUnexplainedIncompleteCost == false || unknownModelsByDay[day]?.isEmpty == false
            }
            let windowEstimated = estimatedCostDays.map { estimatedDays in
                windowed.contains { dayKey(fromUsageDate: $0.date).map(estimatedDays.contains) == true }
            } ?? estimated
            lines.append(.values(label: "Last 30 Days",
                                 values: spendValues(tokens: totalTokens, costUSD: totalCost, estimated: windowEstimated,
                                                     tokensEstimated: windowPartial,
                                                     costIsLowerBound: costIsLowerBound,
                                                     tokenCountSaturated: totalTokensSaturated),
                                 unknownModels: sortedModels(allUnknown),
                                 modelBreakdown: modelBreakdown(
                                    modelUsage,
                                    days: Set(windowed.compactMap { dayKey(fromUsageDate: $0.date) }),
                                    totalTokens: totalTokens,
                                    tokenCountSaturated: totalTokensSaturated,
                                    totalCostUSD: totalCost,
                                    sourceNote: modelSourceNote,
                                    unexplainedIncompleteDays: unexplainedIncompleteDays
                                 )))
        }

        // The All-At-API-Rates figure is intentionally NOT a dashboard row — the owner rejected the
        // estimate tile; the plan-versus-API comparison lives only on the Usage History screen's
        // total line, computed from the same `apiEstimateByDay` input.
    }

    /// A period with any real usage: tokens used, dollars priced, or both. A zero-token, zero-cost day
    /// is idle and gets no tile (→ "No data"), not a fabricated `$0.00 · 0 tokens`.
    private static func hasUsage(_ entry: DailyUsageEntry) -> Bool {
        entry.totalTokens > 0 || (entry.costUSD ?? 0) > 0
    }

    /// Append the Usage Trend chart line: one bar per calendar day over the window, value = tokens used
    /// that day. Tokens are always measured (no estimate flag), so the chart needs only the per-day
    /// counts plus a source note. Appends nothing when the whole window is idle, so a source with no
    /// usage leaves "No data" rather than a flat row of zero bars.
    static func appendUsageTrend(
        _ usage: DailyUsageSeries,
        to lines: inout [MetricLine],
        now: Date = Date(),
        note: String,
        partialDays: Set<String> = [],
        partialNote: String? = nil
    ) {
        let points = trendPoints(usage, now: now)
        guard !points.isEmpty else { return }
        var trendNote = note
        if !partialDays.isEmpty {
            // Some providers have an explicit partial-day cause such as an active session or a
            // skipped oversized source record; retain the established Hermes copy by default.
            trendNote += " · " + (partialNote ?? "days with an active Hermes session are partial until it ends")
        }
        lines.append(.chart(label: "Usage Trend", points: points, note: trendNote))
    }

    /// Per-day token points across the queried window (today + the previous 30 days), oldest first.
    /// Tokens are summed per calendar day, so two source rows that normalize to the same date (mixed
    /// formats) become one bar carrying their total rather than two bars splitting it. Idle days are
    /// zero-filled, not dropped, so the sparkline stays calendar-true: a gap shows as a short bar in
    /// place instead of collapsing two non-adjacent days into neighbors, and the cap is calendar days,
    /// not active ones. Returns empty when nothing was used in the window — there's no trend to draw.
    /// Each point carries a "Jun 21" axis label and a pre-formatted "222M tokens" readout.
    private static func trendPoints(_ usage: DailyUsageSeries, now: Date) -> [MetricChartPoint] {
        var tokensByDay: [String: Int] = [:]
        var saturatedDays: Set<String> = []
        for day in usage.daily {
            guard day.totalTokens >= 0, let key = dayKey(fromUsageDate: day.date) else { continue }
            let previous = tokensByDay[key, default: 0]
            if day.totalTokens > 0 && previous > Int.max - day.totalTokens {
                saturatedDays.insert(key)
            }
            tokensByDay[key] = ProviderParse.addingSaturating(previous, day.totalTokens)
            if day.tokenCountSaturated { saturatedDays.insert(key) }
        }
        guard tokensByDay.values.contains(where: { $0 > 0 }) else { return [] }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return (0..<UsageHistoryWindow.totalDays).reversed().compactMap { offset -> MetricChartPoint? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let key = dayKey(from: day)
            let tokens = tokensByDay[key] ?? 0
            return MetricChartPoint(
                value: Double(tokens),
                // The app's localized "Jun 21" month/day, not a hardcoded "6/21".
                label: Formatters.monthDayLabel(day),
                valueLabel: MetricFormatter.string(for: MetricValue(
                    number: Double(tokens),
                    kind: .count,
                    label: "tokens",
                    tokenCountSaturated: saturatedDays.contains(key)
                ), style: .row)
            )
        }
    }

    private static func dayKey(from date: Date) -> String {
        DailyUsageAccumulator.dayKey(from: date)
    }

    private static func dayKey(fromUsageDate rawDate: String) -> String? {
        let value = rawDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            return value
        }

        if let date = OpenUsageISO8601.date(from: value) {
            return dayKey(from: date)
        }

        if let match = value.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
            return String(value[match])
        }
        if value.range(of: #"^\d{8}$"#, options: .regularExpression) != nil {
            let year = value.prefix(4)
            let month = value.dropFirst(4).prefix(2)
            let day = value.suffix(2)
            return "\(year)-\(month)-\(day)"
        }

        return fallbackDateFormatterAccess.withLock { $0.date(from: value) }.map(dayKey(from:))
    }

    /// The "MMM dd, yyyy" fallback's formatter, built once and locked for use — `DateFormatter`
    /// construction dominates that path's cost, and folds re-derive day keys for the same rows on
    /// every refresh (a lifetime-wide series multiplies the traffic). Folds run on provider
    /// executors rather than one fixed thread, so the formatter itself lives behind a lock.
    private static let fallbackDateFormatterAccess = OSAllocatedUnfairLock<DateFormatter>(initialState: {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM dd, yyyy"
        return formatter
    }())

    private static func dayUsageLine(
        label: String,
        entry: DailyUsageEntry,
        costUSD: Double?,
        estimated: Bool,
        partial: Bool,
        costIsLowerBound: Bool,
        tokenCountSaturated: Bool,
        unknownModels: [String],
        modelBreakdown: ModelUsageBreakdown?
    ) -> MetricLine {
        .values(label: label, values: spendValues(tokens: entry.totalTokens,
                                                  costUSD: costUSD,
                                                  estimated: estimated, tokensEstimated: partial,
                                                  costIsLowerBound: costIsLowerBound,
                                                  tokenCountSaturated: tokenCountSaturated),
                unknownModels: unknownModels, modelBreakdown: modelBreakdown)
    }

    private static func displayableCost(
        _ entry: DailyUsageEntry,
        day: String,
        unknownModelsByDay: [String: Set<String>],
        partialDays: Set<String>
    ) -> Double? {
        guard let cost = entry.costUSD, cost.isFinite, cost >= 0 else { return nil }
        guard entry.costIsComplete
            || entry.hasUnexplainedIncompleteCost == false
            || partialDays.contains(day)
            || (entry.hasUnexplainedIncompleteCost != true && unknownModelsByDay[day]?.isEmpty == false)
        else { return nil }
        return cost
    }

    private static func hasKnownPartialCost(
        _ entry: DailyUsageEntry,
        day: String,
        unknownModelsByDay: [String: Set<String>]
    ) -> Bool {
        guard !entry.costIsComplete, entry.hasUnexplainedIncompleteCost != true else { return false }
        return entry.hasUnexplainedIncompleteCost == false || unknownModelsByDay[day]?.isEmpty == false
    }

    /// Stable, de-duplicated display order for a period's unknown-model names (the set is unordered).
    private static func sortedModels(_ models: Set<String>?) -> [String] {
        (models ?? []).sorted()
    }

    /// One period's spend as raw values: the estimated dollars followed by the measured token count,
    /// rendered combined as "$4.08 · 1.2M tokens". The token value carries the "tokens" unit (the same
    /// way Codex credits carry "credits"), so the three spend tiles read consistently.
    ///
    /// Only called for a period with real usage (see `hasUsage`). Some token-only callers may not provide
    /// a dollar value. `estimated` flags locally calculated dollars with the ⓘ; token counts are always
    /// measured, never flagged. `tokensEstimated` marks the period PARTIAL (a Hermes session is still
    /// running, so the recorded total is real but not final) — both values carry the ⓘ then, so a
    /// live-session day is never presented as a settled number.
    private static func spendValues(
        tokens: Int,
        costUSD: Double?,
        estimated: Bool,
        tokensEstimated: Bool = false,
        costIsLowerBound: Bool = false,
        tokenCountSaturated: Bool = false
    ) -> [MetricValue] {
        var values: [MetricValue] = []
        if let costUSD {
            values.append(MetricValue(
                number: costUSD,
                kind: .dollars,
                estimated: estimated || tokensEstimated,
                isPartial: tokensEstimated,
                isLowerBound: costIsLowerBound
            ))
        }
        values.append(MetricValue(
            number: Double(tokens),
            kind: .count,
            label: "tokens",
            estimated: tokensEstimated,
            tokenCountSaturated: tokenCountSaturated ? true : nil,
            isPartial: tokensEstimated
        ))
        return values
    }

    private static let namedModelCap = 5

    /// Tracks the casings seen for one case-folded name and elects the one that carried the most
    /// tokens (ties prefer the all-lowercase spelling, then alphabetical) — so `GLM-5.2` and `glm-5.2`
    /// collapse into one row titled with whichever spelling dominated the period.
    private struct SpellingVote {
        private var tokensBySpelling: [String: Int] = [:]

        mutating func note(_ spelling: String, weight: Int) {
            // Zero-token entries (cost-only lines) still get a say.
            tokensBySpelling[spelling] = ProviderParse.addingSaturating(
                tokensBySpelling[spelling, default: 0],
                max(weight, 1)
            )
        }

        var best: String? {
            tokensBySpelling.min { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                let lhsLower = lhs.key == lhs.key.lowercased()
                let rhsLower = rhs.key == rhs.key.lowercased()
                if lhsLower != rhsLower { return lhsLower }
                return lhs.key < rhs.key
            }?.key
        }
    }

    private struct ModelAccumulator {
        var tokens = 0
        private var tokenCountSaturated = false
        var costUSD: Double?
        private var costIsComplete = true
        private var costOverflowed = false
        private var nameVote = SpellingVote()
        /// Keyed by the case-folded slug; the vote inside restores a display spelling.
        private var variants: [String: (
            tokens: Int,
            costUSD: Double?,
            costIsComplete: Bool,
            tokenCountSaturated: Bool,
            costOverflowed: Bool,
            vote: SpellingVote
        )] = [:]

        /// The display spelling for this model, elected across every casing that merged into it.
        var displayName: String? { nameVote.best }

        /// Merge a same-model day entry: variants (raw slugs) merge line-by-line so a multi-day period
        /// keeps one line per slug.
        mutating func add(_ entry: ModelUsageEntry, spelledAs name: String) {
            addTotals(of: entry, spelledAs: name)
            for variant in entry.variants ?? [ModelUsageVariant(
                model: name,
                totalTokens: entry.totalTokens,
                costUSD: entry.costUSD,
                costIsComplete: entry.costIsComplete,
                tokenCountSaturated: entry.tokenCountSaturated
            )] {
                mergeVariant(variant.model, tokens: variant.totalTokens, costUSD: variant.costUSD,
                             costIsComplete: !variant.hasIncompleteCost,
                             tokenCountSaturated: variant.tokenCountSaturated == true)
            }
        }

        /// Fold a different model into this accumulator (the Other row): one variant per folded model —
        /// its hover detail lists models, not their raw effort slugs. The Other row's own name is
        /// fixed, so folded spellings only vote inside the variant lines.
        mutating func fold(_ entry: ModelUsageEntry) {
            if entry.totalTokens > 0 && tokens > Int.max - entry.totalTokens { tokenCountSaturated = true }
            tokens = ProviderParse.addingSaturating(tokens, entry.totalTokens)
            tokenCountSaturated = tokenCountSaturated || entry.tokenCountSaturated == true
            if let cost = entry.costUSD {
                accumulateCost(cost)
            }
            if entry.hasIncompleteCost {
                costIsComplete = false
            }
            mergeVariant(entry.model, tokens: entry.totalTokens, costUSD: entry.costUSD,
                         costIsComplete: !entry.hasIncompleteCost,
                         tokenCountSaturated: entry.tokenCountSaturated == true)
        }

        private mutating func addTotals(of entry: ModelUsageEntry, spelledAs name: String) {
            if entry.totalTokens > 0 && tokens > Int.max - entry.totalTokens { tokenCountSaturated = true }
            tokens = ProviderParse.addingSaturating(tokens, entry.totalTokens)
            tokenCountSaturated = tokenCountSaturated || entry.tokenCountSaturated == true
            if let cost = entry.costUSD {
                accumulateCost(cost)
            }
            if entry.hasIncompleteCost {
                costIsComplete = false
            }
            nameVote.note(name, weight: entry.totalTokens)
        }

        private mutating func mergeVariant(
            _ model: String,
            tokens: Int,
            costUSD: Double?,
            costIsComplete: Bool,
            tokenCountSaturated: Bool
        ) {
            let key = model.lowercased()
            var existing = variants[key] ?? (tokens: 0, costUSD: nil, costIsComplete: true,
                                              tokenCountSaturated: false, costOverflowed: false,
                                              vote: SpellingVote())
            if tokens > 0 && existing.tokens > Int.max - tokens { existing.tokenCountSaturated = true }
            existing.tokens = ProviderParse.addingSaturating(existing.tokens, tokens)
            existing.tokenCountSaturated = existing.tokenCountSaturated || tokenCountSaturated
            if let costUSD, !existing.costOverflowed {
                if let total = SpendTileMapper.addingFiniteCost(existing.costUSD, costUSD) {
                    existing.costUSD = total
                } else {
                    existing.costOverflowed = true
                    existing.costIsComplete = false
                }
            }
            if !costIsComplete || (tokens > 0 && costUSD == nil) {
                existing.costIsComplete = false
            }
            existing.vote.note(model, weight: tokens)
            variants[key] = existing
        }

        private mutating func accumulateCost(_ cost: Double) {
            guard !costOverflowed else { return }
            if let total = SpendTileMapper.addingFiniteCost(costUSD, cost) {
                costUSD = total
            } else {
                costOverflowed = true
                costIsComplete = false
            }
        }

        func entry(model: String) -> ModelUsageEntry {
            let list = variants
                .map { key, value in
                    ModelUsageVariant(model: value.vote.best ?? key, totalTokens: value.tokens,
                                      costUSD: value.costUSD.map(SpendTileMapper.roundToCents),
                                      costIsComplete: value.costIsComplete ? nil : false,
                                      tokenCountSaturated: value.tokenCountSaturated ? true : nil)
                }
                .sorted(by: variantSortPrecedes)
            // One variant carrying the row's own name is no breakdown — nil keeps the tooltip on plain figures.
            let isTrivial = list.count == 1 && list[0].model.lowercased() == model.lowercased()
            return ModelUsageEntry(model: model, totalTokens: tokens,
                                   costUSD: costUSD.map(SpendTileMapper.roundToCents),
                                   variants: isTrivial ? nil : list,
                                   costIsComplete: costIsComplete ? nil : false,
                                   tokenCountSaturated: tokenCountSaturated ? true : nil)
        }
    }

    private static func variantSortPrecedes(_ lhs: ModelUsageVariant, _ rhs: ModelUsageVariant) -> Bool {
        let lhsCost = lhs.costUSD ?? 0
        let rhsCost = rhs.costUSD ?? 0
        if lhsCost != rhsCost { return lhsCost > rhsCost }
        if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
        return lhs.model.localizedStandardCompare(rhs.model) == .orderedAscending
    }

    private static func modelBreakdown(
        _ usage: ModelUsageSeries?,
        days: Set<String>,
        totalTokens: Int,
        tokenCountSaturated: Bool,
        totalCostUSD: Double?,
        sourceNote: String?,
        unexplainedIncompleteDays: Set<String>
    ) -> ModelUsageBreakdown? {
        guard let usage, let sourceNote, !days.isEmpty else { return nil }

        // Keyed by the case-folded name so `GLM-5.2` and `glm-5.2` land in one row; the accumulator's
        // spelling vote decides which casing titles it.
        var byModel: [String: ModelAccumulator] = [:]
        for day in usage.daily where dayKey(fromUsageDate: day.date).map(days.contains) == true {
            guard let dayKey = dayKey(fromUsageDate: day.date) else { continue }
            for model in day.models where model.totalTokens > 0 || (model.costUSD ?? 0) > 0 {
                let name = normalizedModelName(model.model)
                var adjustedModel = model
                if unexplainedIncompleteDays.contains(dayKey) {
                    adjustedModel = hidingCost(of: adjustedModel)
                }
                byModel[name.lowercased(), default: ModelAccumulator()].add(adjustedModel, spelledAs: name)
            }
        }

        let sorted = byModel.map { key, accumulator in accumulator.entry(model: accumulator.displayName ?? key) }
            .sorted(by: modelSortPrecedes)
        let folded = foldModelList(sorted)
        guard !folded.isEmpty else { return nil }
        return ModelUsageBreakdown(
            totalTokens: totalTokens,
            tokenCountSaturated: tokenCountSaturated ? true : nil,
            totalCostUSD: totalCostUSD,
            models: folded,
            sourceNote: sourceNote
        )
    }

    private static func hidingCost(of model: ModelUsageEntry) -> ModelUsageEntry {
        var adjusted = model
        adjusted.costUSD = nil
        adjusted.costIsComplete = false
        if let variants = adjusted.variants {
            adjusted.variants = variants.map { variant in
                var adjustedVariant = variant
                adjustedVariant.costUSD = nil
                adjustedVariant.costIsComplete = false
                return adjustedVariant
            }
        }
        return adjusted
    }

    private static func normalizedModelName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ModelUsageEntry.unattributedModelName : trimmed
    }

    private static func modelSortPrecedes(_ lhs: ModelUsageEntry, _ rhs: ModelUsageEntry) -> Bool {
        let lhsCost = lhs.costUSD ?? 0
        let rhsCost = rhs.costUSD ?? 0
        if lhsCost != rhsCost { return lhsCost > rhsCost }
        if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
        return lhs.model.localizedStandardCompare(rhs.model) == .orderedAscending
    }

    /// Models below this share of the period fold into Other — a stack of sub-5% slivers is noise,
    /// and the Other row lists its leading contributors.
    private static let minVisibleShare = 0.05

    private static func foldModelList(_ entries: [ModelUsageEntry]) -> [ModelUsageEntry] {
        // The threshold uses the same basis as the panel's percent labels (cost shares only when
        // every model is priced, token shares otherwise — see `ModelUsageDetail.share`). A model is
        // only minor enough to fold when it is a sliver on BOTH bases: its display share and its
        // raw token share. The token floor is what keeps a cheap-but-heavy model visible — tokens
        // are the measured quantity and cost is the imputed one, so a model holding half the
        // period's tokens must never disappear behind "Other" just because its cost share is small
        // (the bug that hid 488M glm tokens under a 3% Other row).
        let allCostsComplete = entries.allSatisfy { $0.costUSD != nil && !$0.hasIncompleteCost }
        let largestCost = entries.compactMap(\.costUSD).max() ?? 0
        // Normalize by the largest entry before summing so a finite set of prices cannot overflow
        // the denominator and make every model appear to have a zero share.
        let normalizedCostTotal = largestCost > 0 && largestCost.isFinite
            ? entries.reduce(0.0) { $0 + (($1.costUSD ?? 0) / largestCost) }
            : 0
        let canUseCostShares = allCostsComplete && normalizedCostTotal.isFinite && normalizedCostTotal > 0
        let tokenTotal = entries.reduce(0) { ProviderParse.addingSaturating($0, $1.totalTokens) }
        func share(_ entry: ModelUsageEntry) -> Double {
            if canUseCostShares {
                return ((entry.costUSD ?? 0) / largestCost) / normalizedCostTotal
            }
            guard tokenTotal > 0 else { return 0 }
            return Double(entry.totalTokens) / Double(tokenTotal)
        }
        func tokenShareLeader(_ entry: ModelUsageEntry) -> Bool {
            guard tokenTotal > 0 else { return false }
            return Double(entry.totalTokens) / Double(tokenTotal) >= minVisibleShare
        }

        var visible: [ModelUsageEntry] = []
        var other = ModelAccumulator()
        var namedCount = 0

        for entry in entries {
            // Tokens the logs couldn't tie to a model (Grok) read as noise under their own
            // "Unattributed" row — the panel is an insight, not an accounting ledger, so they just
            // count into Other however large they are.
            let isUnattributed = entry.model.caseInsensitiveCompare(ModelUsageEntry.unattributedModelName) == .orderedSame
            if isUnattributed {
                other.fold(entry)
            } else if share(entry) < minVisibleShare && !tokenShareLeader(entry) {
                other.fold(entry)
            } else if entry.costUSD == nil {
                visible.append(entry)
                namedCount += 1
            } else if tokenShareLeader(entry) {
                // A substantial token consumer stays named regardless of cost share, without
                // spending a paid-model slot — its usage must stay identifiable.
                visible.append(entry)
            } else if namedCount < namedModelCap {
                visible.append(entry)
                namedCount += 1
            } else {
                other.fold(entry)
            }
        }

        if other.tokens > 0 || (other.costUSD ?? 0) > 0 {
            visible.append(other.entry(model: ModelUsageEntry.otherModelName))
        }
        return visible
    }

    private static func addingFiniteCost(_ current: Double?, _ addition: Double) -> Double? {
        guard addition.isFinite, addition >= 0 else { return nil }
        let total = (current ?? 0) + addition
        return total.isFinite ? total : nil
    }

    private static func roundToCents(_ value: Double) -> Double {
        let scaled = value * 100
        guard value.isFinite, scaled.isFinite else { return value }
        return scaled.rounded() / 100
    }
}
