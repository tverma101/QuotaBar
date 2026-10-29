import Foundation

/// A provider-neutral per-day token/cost series — the shared carrier every spend-tracking provider
/// funnels through `SpendTileMapper` (the Today / Yesterday / Last 30 Days tiles and the Usage Trend
/// chart).
///
/// Sources build it from very different inputs and hand `SpendTileMapper` the same shape so the tiles
/// render identically regardless of origin: Claude/Codex/Grok from their native log scanners, Cursor
/// from its usage CSV export.
///
/// These are internal types with no serialization impact: the local HTTP API serializes `MetricLine`,
/// not these.
struct DailyUsageEntry: Hashable, Sendable, Codable {
    var date: String
    var totalTokens: Int
    var costUSD: Double?
    /// False when some usage for this day has no reliable price. Kept beyond the 30-day model-detail
    /// window so lifetime totals never mistake a priced subtotal for the full cost.
    var costIsComplete: Bool
    /// True when some incompleteness is unrelated to a named unknown model (for example, a known
    /// model's reported token breakdown failed reconciliation). A separate unknown-model warning
    /// cannot explain this gap.
    /// False records that a known subtotal is safe to show even though it is incomplete, including
    /// a finite lower bound retained after numeric overflow. Nil means the record predates cause
    /// tracking, so the spend mapper requires named unknown models before showing a subtotal.
    /// Explicit true continues to guard structural gaps.
    var hasUnexplainedIncompleteCost: Bool?
    /// True when the source token total exceeded `Int.max` and was clipped to a lower bound.
    var tokenCountSaturated: Bool

    init(
        date: String,
        totalTokens: Int,
        costUSD: Double?,
        costIsComplete: Bool = true,
        hasUnexplainedIncompleteCost: Bool? = nil,
        tokenCountSaturated: Bool? = nil
    ) {
        self.date = date
        self.totalTokens = totalTokens
        self.costUSD = costUSD
        self.costIsComplete = costIsComplete
        self.hasUnexplainedIncompleteCost = hasUnexplainedIncompleteCost
        self.tokenCountSaturated = tokenCountSaturated ?? (totalTokens == .max)
    }

    private enum CodingKeys: String, CodingKey {
        case date, totalTokens, costUSD, costIsComplete, hasUnexplainedIncompleteCost, tokenCountSaturated
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        date = try values.decode(String.self, forKey: .date)
        totalTokens = try values.decode(Int.self, forKey: .totalTokens)
        costUSD = try values.decodeIfPresent(Double.self, forKey: .costUSD)
        // Old persisted days do not say whether a non-nil amount is a subtotal. Treat them as
        // incomplete until the next source scan replaces them with explicit coverage evidence.
        costIsComplete = try values.decodeIfPresent(Bool.self, forKey: .costIsComplete) ?? false
        hasUnexplainedIncompleteCost = try values.decodeIfPresent(
            Bool.self,
            forKey: .hasUnexplainedIncompleteCost
        )
        tokenCountSaturated = try values.decodeIfPresent(Bool.self, forKey: .tokenCountSaturated)
            ?? (totalTokens == .max)
    }
}

struct DailyUsageSeries: Hashable, Sendable, Codable {
    var daily: [DailyUsageEntry]
}

/// The calendar window shared by local scanners, combined iCloud history, and the usage trend.
enum UsageHistoryWindow {
    /// Total calendar days in the window, **including today**.
    ///
    /// This is the number the user sees: the tile is labelled "Last 30 Days", and
    /// `TotalSpendAggregator` sums each provider's tile into one cross-provider figure. So the window
    /// has to be exactly this many days, and every provider has to agree.
    ///
    /// It previously was not. `previousDays` was 30 and the window was built as `0...previousDays`,
    /// which is 31 days — so every log-scanner and iCloud-backed provider reported 31 days under a
    /// "Last 30 Days" label, while Cursor used `-29` and genuinely reported 30. Two identically
    /// labelled rows on the same dashboard, one week apart, summed into a single total.
    static let totalDays = 30

    /// Days strictly *before* today, i.e. `totalDays - 1`.
    ///
    /// Named for its only other use, the `daysBack:` scan-window argument, where an off-by-one silently
    /// widens the scan. Derived from `totalDays` so the two cannot drift apart again.
    static var previousDays: Int { totalDays - 1 }

    /// The lifetime scan window for the Usage History screen's retained-history card. Calendar year
    /// arithmetic keeps the cutoff on the same month/day ten years ago, including leap days.
    static func lifetimeDays(through now: Date, calendar: Calendar = .current) -> Int {
        let today = calendar.startOfDay(for: now)
        let firstDay = calendar.date(byAdding: .year, value: -10, to: today)
            ?? calendar.date(byAdding: .day, value: -3650, to: today)
            ?? today
        return max(1, (calendar.dateComponents([.day], from: firstDay, to: today).day ?? 0) + 1)
    }

    static func dayKeys(through now: Date, calendar: Calendar = .current) -> Set<String> {
        dayKeys(through: now, count: totalDays, calendar: calendar)
    }

    /// Calendar keys retained for the Usage History lifetime report, including today.
    static func lifetimeDayKeys(through now: Date, calendar: Calendar = .current) -> Set<String> {
        dayKeys(through: now, count: lifetimeDays(through: now, calendar: calendar), calendar: calendar)
    }

    private static func dayKeys(through now: Date, count: Int, calendar: Calendar) -> Set<String> {
        let today = calendar.startOfDay(for: now)
        return Set((0..<max(0, count)).compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today)
                .map { DailyUsageAccumulator.dayKey(from: $0, calendar: calendar) }
        })
    }
}

/// Token/cost totals for one model before a period collapses it into a spend row. Costs stay unrounded
/// here; `SpendTileMapper` snaps them to cents once for the displayed Today / Yesterday / Last 30 Days
/// breakdown, matching the spend-row totals.
///
/// `variants` carries the raw slugs folded into this entry when a provider groups by base model —
/// Cursor's thinking-effort/fast CSV slugs (`claude-opus-4-8-thinking-max` under `claude-opus-4-8`) —
/// and the models rolled into the `Other` row. Nil when the entry is exactly one raw model (the log
/// scanners' entries), so the hover panel knows there is no finer breakdown to offer.
struct ModelUsageEntry: Hashable, Sendable, Codable {
    static let unattributedModelName = "Unattributed"
    static let otherModelName = "Other"

    var model: String
    var totalTokens: Int
    var costUSD: Double?
    var variants: [ModelUsageVariant]? = nil
    /// False when `costUSD` is a known subtotal because some usage for this model is unpriced or
    /// could not be reconciled. Optional so older persisted entries decode using their prior shape.
    var costIsComplete: Bool? = nil
    var tokenCountSaturated: Bool? = nil

    var hasIncompleteCost: Bool {
        if let costIsComplete { return !costIsComplete }
        return totalTokens > 0 && costUSD == nil
    }
}

/// One raw slug inside a grouped `ModelUsageEntry` — the "per thinking effort" line of the hover
/// panel's row tooltip.
struct ModelUsageVariant: Hashable, Sendable, Codable {
    var model: String
    var totalTokens: Int
    var costUSD: Double?
    var costIsComplete: Bool? = nil
    var tokenCountSaturated: Bool? = nil

    var hasIncompleteCost: Bool {
        if let costIsComplete { return !costIsComplete }
        return totalTokens > 0 && costUSD == nil
    }
}

struct DailyModelUsageEntry: Hashable, Sendable, Codable {
    var date: String
    var models: [ModelUsageEntry]
}

struct ModelUsageSeries: Hashable, Sendable, Codable {
    var daily: [DailyModelUsageEntry]
}

/// The presentation-free daily history retained on a provider snapshot. The same normalized values
/// feed the local spend rows and, when explicitly classified as machine-local by the provider's
/// descriptor, the private iCloud sync file.
struct ProviderUsageHistory: Hashable, Sendable, Codable {
    var series: DailyUsageSeries
    var modelUsage: ModelUsageSeries?
    var unknownModelsByDay: [String: Set<String>]
    /// Per-day public-API-rate estimate (see `LogUsageScan.apiEstimateByDay`). Additive optional so
    /// snapshots persisted before the field decode with nil and backfill on the next full pass.
    var apiEstimateByDay: [String: Double]? = nil
    /// Days whose public-rate estimate is partial. Kept for the full lifetime window even though
    /// model names are retained only for the 30-day spend detail. Optional for older snapshots.
    var apiEstimateIncompleteDays: Set<String>? = nil
    /// Days with a still-running local session. Spend rows and trends mark their current token counts
    /// partial until the source session ends. Optional for older snapshots.
    var partialDays: Set<String>? = nil
    /// Days whose plan-priced dollars contain locally imputed rows. Optional for providers whose
    /// estimate status is uniform or snapshots written before per-day provenance was added.
    var estimatedCostDays: Set<String>? = nil

    init(
        series: DailyUsageSeries,
        modelUsage: ModelUsageSeries? = nil,
        unknownModelsByDay: [String: Set<String>] = [:],
        apiEstimateByDay: [String: Double]? = nil,
        apiEstimateIncompleteDays: Set<String>? = nil,
        partialDays: Set<String>? = nil,
        estimatedCostDays: Set<String>? = nil
    ) {
        self.unknownModelsByDay = unknownModelsByDay
        let adjustedModelUsage = Self.markingNamedUnknownCostsIncomplete(
            modelUsage,
            unknownModelsByDay: unknownModelsByDay
        )
        self.series = Self.classifyingLegacyIncompleteDays(
            series,
            modelUsage: adjustedModelUsage,
            unknownModelsByDay: unknownModelsByDay
        )
        self.modelUsage = adjustedModelUsage
        self.apiEstimateByDay = apiEstimateByDay
        self.apiEstimateIncompleteDays = apiEstimateIncompleteDays ?? Set(unknownModelsByDay.keys)
        self.partialDays = partialDays
        self.estimatedCostDays = estimatedCostDays
    }

    private enum CodingKeys: String, CodingKey {
        case series, modelUsage, unknownModelsByDay, apiEstimateByDay, apiEstimateIncompleteDays, partialDays, estimatedCostDays
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            series: try values.decode(DailyUsageSeries.self, forKey: .series),
            modelUsage: try values.decodeIfPresent(ModelUsageSeries.self, forKey: .modelUsage),
            unknownModelsByDay: try values.decodeIfPresent([String: Set<String>].self, forKey: .unknownModelsByDay) ?? [:],
            apiEstimateByDay: try values.decodeIfPresent([String: Double].self, forKey: .apiEstimateByDay),
            apiEstimateIncompleteDays: try values.decodeIfPresent(Set<String>.self, forKey: .apiEstimateIncompleteDays),
            partialDays: try values.decodeIfPresent(Set<String>.self, forKey: .partialDays),
            estimatedCostDays: try values.decodeIfPresent(Set<String>.self, forKey: .estimatedCostDays)
        )
    }

    private static func markingNamedUnknownCostsIncomplete(
        _ series: ModelUsageSeries?,
        unknownModelsByDay: [String: Set<String>]
    ) -> ModelUsageSeries? {
        guard let series else { return nil }
        return ModelUsageSeries(daily: series.daily.map { day in
            let unknownNames = Set(unknownModelsByDay[day.date, default: []].map { $0.lowercased() })
            guard !unknownNames.isEmpty else { return day }
            return DailyModelUsageEntry(date: day.date, models: day.models.map { model in
                var adjusted = model
                if var variants = adjusted.variants {
                    variants = variants.map { variant in
                        var adjustedVariant = variant
                        if unknownNames.contains(variant.model.lowercased()) {
                            adjustedVariant.costIsComplete = false
                        }
                        return adjustedVariant
                    }
                    adjusted.variants = variants
                }
                if unknownNames.contains(model.model.lowercased())
                    || adjusted.variants?.contains(where: { unknownNames.contains($0.model.lowercased()) }) == true
                {
                    adjusted.costIsComplete = false
                }
                return adjusted
            })
        })
    }

    /// Old synced documents do not carry the cause of incomplete cost. Treat named unknowns as a
    /// sufficient explanation only when their model rows account for the full day and every
    /// incomplete model row is named. Otherwise preserve the conservative structural-gap behavior.
    private static func classifyingLegacyIncompleteDays(
        _ series: DailyUsageSeries,
        modelUsage: ModelUsageSeries?,
        unknownModelsByDay: [String: Set<String>]
    ) -> DailyUsageSeries {
        var modelsByDay: [String: [ModelUsageEntry]] = [:]
        for modelDay in modelUsage?.daily ?? [] {
            modelsByDay[modelDay.date, default: []].append(contentsOf: modelDay.models)
        }
        return DailyUsageSeries(daily: series.daily.map { day in
            guard !day.costIsComplete,
                  day.hasUnexplainedIncompleteCost == nil
            else { return day }

            guard let unknownNames = unknownModelsByDay[day.date], !unknownNames.isEmpty else {
                var adjustedDay = day
                adjustedDay.hasUnexplainedIncompleteCost = true
                return adjustedDay
            }

            guard let modelRows = modelsByDay[day.date], !modelRows.isEmpty else {
                var adjustedDay = day
                adjustedDay.hasUnexplainedIncompleteCost = true
                return adjustedDay
            }

            var modelTokens = 0
            var modelTokensSaturated = false
            for model in modelRows {
                if model.totalTokens > 0 && modelTokens > Int.max - model.totalTokens {
                    modelTokensSaturated = true
                }
                modelTokens = ProviderParse.addingSaturating(modelTokens, model.totalTokens)
                modelTokensSaturated = modelTokensSaturated || model.tokenCountSaturated == true
            }
            let normalizedUnknownNames = Set(unknownNames.map { $0.lowercased() })
            let representedNames = Set(modelRows.flatMap { model in
                [model.model] + (model.variants ?? []).map(\.model)
            }.map { $0.lowercased() })
            let incompleteModels = modelRows.filter(\.hasIncompleteCost)
            let allIncompleteModelsAreNamed = !incompleteModels.isEmpty
                && incompleteModels.allSatisfy { model in
                    normalizedUnknownNames.contains(model.model.lowercased())
                        || (model.variants ?? []).contains {
                            normalizedUnknownNames.contains($0.model.lowercased())
                        }
                }
            let unknownNamesAreRepresented = normalizedUnknownNames.isSubset(of: representedNames)
            var adjustedDay = day
            adjustedDay.hasUnexplainedIncompleteCost = modelTokensSaturated
                || day.tokenCountSaturated
                || modelTokens != day.totalTokens
                || !unknownNamesAreRepresented
                || !allIncompleteModelsAreNamed
            return adjustedDay
        })
    }
}

extension ProviderUsageHistory {
    /// Model rows and unknown-model names are only consumed by the 30-day spend details. Keep daily
    /// totals and API estimates for the ten-year lifetime report while dropping older array entries.
    func retainingHistory(through now: Date, calendar: Calendar = .current) -> ProviderUsageHistory {
        retainingHistory(
            lifetimeDayKeys: UsageHistoryWindow.lifetimeDayKeys(through: now, calendar: calendar),
            detailDayKeys: UsageHistoryWindow.dayKeys(through: now, calendar: calendar)
        )
    }

    func retainingHistory(
        lifetimeDayKeys: Set<String>,
        detailDayKeys: Set<String>
    ) -> ProviderUsageHistory {
        let modelDays = modelUsage?.daily.filter { detailDayKeys.contains($0.date) } ?? []
        let apiEstimates = apiEstimateByDay?.filter { lifetimeDayKeys.contains($0.key) }
        let incompleteEstimateDays = apiEstimateIncompleteDays ?? Set(unknownModelsByDay.keys)
        return ProviderUsageHistory(
            series: DailyUsageSeries(daily: series.daily.filter { lifetimeDayKeys.contains($0.date) }),
            modelUsage: modelDays.isEmpty ? nil : ModelUsageSeries(daily: modelDays),
            unknownModelsByDay: unknownModelsByDay.filter { detailDayKeys.contains($0.key) },
            apiEstimateByDay: apiEstimates?.isEmpty == false ? apiEstimates : nil,
            apiEstimateIncompleteDays: Set(incompleteEstimateDays.filter { lifetimeDayKeys.contains($0) }),
            // Partial markers qualify lifetime totals too. Keep them for the full lifetime window;
            // detail-only screens can still limit which day rows they display.
            partialDays: partialDays.map { Set($0.filter(lifetimeDayKeys.contains)) },
            estimatedCostDays: estimatedCostDays.map { Set($0.filter(lifetimeDayKeys.contains)) }
        )
    }
}

/// A period-scoped, UI-ready breakdown attached to the same `.values` line as the spend row it explains.
/// The header total mirrors that row's values; individual model costs are rounded at this display boundary.
struct ModelUsageBreakdown: Hashable, Sendable, Codable {
    var totalTokens: Int
    /// True when the period total was clamped during aggregation. Individual model rows can each be
    /// exact while their combined total is only a lower bound, so share bars must remain unavailable.
    var tokenCountSaturated: Bool? = nil
    var totalCostUSD: Double?
    var models: [ModelUsageEntry]
    var sourceNote: String
}

/// Daily token/cost series plus the per-day models the pricing sources couldn't price — the inputs
/// `SpendTileMapper.appendTokenUsage` needs to render the spend tiles with unknown-model warnings.
/// Shared result shape of the native log scanners (Claude, Codex).
struct LogUsageScan: Sendable, Codable {
    var series: DailyUsageSeries
    var modelUsage: ModelUsageSeries?
    /// `yyyy-MM-dd` day key → models used that day whose usage was left out because no price was available.
    var unknownModelsByDay: [String: Set<String>]
    /// `yyyy-MM-dd` day key → what that day's usage would cost at public API rates (the "if it were all
    /// API" comparison). Rows without any resolvable rate contribute nothing, so the estimate is honest
    /// about coverage; nil when no row in the window could be estimated at all.
    var apiEstimateByDay: [String: Double]?
    /// Full-retention marker for days where public-rate rows were unpriceable. Unknown model names
    /// remain a shorter-lived spend-detail field, but estimate completeness must survive to lifetime.
    var apiEstimateIncompleteDays: Set<String>? = nil
    /// Day keys whose plan-priced costs contain locally imputed rows.
    var estimatedCostDays: Set<String>? = nil
    /// A valid routed request was recorded without any measured usage fields. Keep measured totals
    /// and mark these days partial; never turn the absent measurement into zero or an estimate.
    var unmeasuredUsageDays: Set<String>? = nil

    /// Trim an unchanged cached aggregate as its rolling lifetime window advances. This avoids
    /// repricing every retained event at midnight; the per-database cache can discard whole days.
    func droppingDays(before firstDay: String) -> LogUsageScan {
        var trimmed = self
        trimmed.series.daily.removeAll { $0.date < firstDay }
        if var models = trimmed.modelUsage {
            models.daily.removeAll { $0.date < firstDay }
            trimmed.modelUsage = models
        }
        trimmed.unknownModelsByDay = trimmed.unknownModelsByDay.filter { $0.key >= firstDay }
        trimmed.apiEstimateByDay = trimmed.apiEstimateByDay?.filter { $0.key >= firstDay }
        trimmed.apiEstimateIncompleteDays = trimmed.apiEstimateIncompleteDays.map {
            Set($0.filter { $0 >= firstDay })
        }
        trimmed.estimatedCostDays = trimmed.estimatedCostDays.map {
            Set($0.filter { $0 >= firstDay })
        }
        trimmed.unmeasuredUsageDays = trimmed.unmeasuredUsageDays.map {
            Set($0.filter { $0 >= firstDay })
        }
        return trimmed
    }

    func markingUnmeasuredUsage(on days: Set<String>) -> LogUsageScan {
        guard !days.isEmpty else { return self }
        var marked = self
        marked.unmeasuredUsageDays = (marked.unmeasuredUsageDays ?? []).union(days)
        return marked
    }

    init(
        series: DailyUsageSeries,
        modelUsage: ModelUsageSeries? = nil,
        unknownModelsByDay: [String: Set<String>],
        apiEstimateByDay: [String: Double]? = nil,
        apiEstimateIncompleteDays: Set<String>? = nil,
        estimatedCostDays: Set<String>? = nil,
        unmeasuredUsageDays: Set<String>? = nil
    ) {
        self.series = series
        self.modelUsage = modelUsage
        self.unknownModelsByDay = unknownModelsByDay
        self.apiEstimateByDay = apiEstimateByDay
        self.apiEstimateIncompleteDays = apiEstimateIncompleteDays ?? Set(unknownModelsByDay.keys)
        self.estimatedCostDays = estimatedCostDays
        self.unmeasuredUsageDays = unmeasuredUsageDays
    }
}
