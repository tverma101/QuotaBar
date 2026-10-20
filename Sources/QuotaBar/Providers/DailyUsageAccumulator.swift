import Foundation

/// Accumulates priced per-day usage — tokens, cost, and the per-model breakdown — then assembles a
/// `LogUsageScan`. Shared by the log scanners (Claude, Codex, Grok) so the "accumulate then assemble"
/// tail lives in one place instead of a byte-identical copy per provider; each scanner keeps only its
/// format-specific parse/pricing loop.
///
/// Days are keyed by the shared local-calendar `dayKey`, matching `SpendTileMapper`'s Today / Yesterday
/// lookup — the day-key contract is one function, not five copies (drift here is the class of bug behind
/// the ccusage false-zero fix). Unpriced rows are added token-only (nil cost) and flagged for the
/// reveal system, so token totals stay complete while dollar subtotals retain priced usage.
struct DailyUsageAccumulator {
    private var tokensByDay: [String: Int] = [:]
    private var costByDay: [String: Double] = [:]
    private var estimatedCostDays: Set<String> = []
    private var apiEstimateByDay: [String: Double] = [:]
    private var apiEstimateIncompleteDays: Set<String> = []
    private var unknownModelsByDay: [String: Set<String>] = [:]
    private var incompleteCostDays: Set<String> = []
    private var structuralIncompleteCostDays: Set<String> = []
    private var incompleteModelCostsByDay: [String: Set<String>] = [:]
    private var tokenCountSaturatedDays: Set<String> = []
    private var modelsByDay: [String: [String: ModelAccumulator]] = [:]
    private var overflowedCostDays: Set<String> = []
    private var overflowedApiEstimateDays: Set<String> = []
    private var unmeasuredUsageDays: Set<String> = []

    mutating func markUnmeasuredUsage(day: String) {
        unmeasuredUsageDays.insert(day)
    }

    /// Local calendar day as `yyyy-MM-dd`. The single day-key contract shared by the accumulator,
    /// `SpendTileMapper`, and the Cursor CSV aggregation. `calendar` is injectable for tests; production
    /// uses `.current`.
    static func dayKey(from date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// Add a row's tokens + cost, attributed to `model` on `day`.
    ///
    /// `canonical` is the model's *identity*; `model` is the slug the provider actually emitted. They
    /// differ when a gateway tags its slugs: the Codex router stamps the upstream path, so one model
    /// arrives as both `gpt-5.6-luna` and `anthropic/openai/gpt-5.6-luna`. Keying rows by the raw slug
    /// split that one model into two rows that were then summed into the same total, and the tagged one
    /// displayed its routing prefix as if it were part of the model's name. Scanners that resolve pricing
    /// pass the catalog key as `canonical`, so anything priced alike collapses into one row titled with
    /// the catalog id, while the observed spellings survive as tooltip variants.
    ///
    /// `cost` is nil for a row no pricing source can price (a stealth codename slug, an unattributed
    /// stream). Those rows count their tokens and leave their own model cost blank; priced models on
    /// the same day retain their subtotal with an incomplete-cost marker. `apiEstimate` carries what the
    /// same tokens would cost at public API rates when a rate exists for the row (the "if it were all
    /// API" comparison); nil when the model is unidentified.
    ///
    /// Defaults to `model`, so a scanner with no aliasing is unaffected.
    mutating func add(
        day: String,
        tokens: Int,
        cost: Double?,
        model: String,
        canonical: String? = nil,
        costIsComplete: Bool = true,
        tokenCountSaturated: Bool = false
    ) {
        let priorTokens = tokensByDay[day, default: 0]
        if tokens > 0 && priorTokens > Int.max - tokens {
            tokenCountSaturatedDays.insert(day)
        }
        if tokenCountSaturated { tokenCountSaturatedDays.insert(day) }
        tokensByDay[day] = ProviderParse.addingSaturating(priorTokens, tokens)
        if let cost {
            if overflowedCostDays.contains(day) {
                incompleteCostDays.insert(day)
            } else if let total = Self.addingFiniteCost(costByDay[day], cost) {
                costByDay[day] = total
            } else {
                overflowedCostDays.insert(day)
                incompleteCostDays.insert(day)
            }
        } else if tokens > 0 {
            incompleteCostDays.insert(day)
            incompleteModelCostsByDay[day, default: []].insert(model)
        }
        if !costIsComplete {
            incompleteCostDays.insert(day)
            incompleteModelCostsByDay[day, default: []].insert(model)
        }
        let identity = canonical ?? model
        modelsByDay[day, default: [:]][identity, default: ModelAccumulator()]
            .add(tokens: tokens, costUSD: cost, spelling: model, costIsComplete: costIsComplete,
                 sourceTokenCountSaturated: tokenCountSaturated)
    }

    /// Keep a known component subtotal available internally while preventing it from being presented
    /// as the complete cost for this day or model. Used when a source reports measured tokens but its
    /// billing breakdown does not cover the reported total.
    mutating func markCostIncomplete(day: String, model: String, canonical: String? = nil) {
        incompleteCostDays.insert(day)
        structuralIncompleteCostDays.insert(day)
        markModelCostIncomplete(day: day, model: model, canonical: canonical)
    }

    /// Mark one model's subtotal as unsettled without making the whole day's known subtotal
    /// unpresentable. Used for an active session when sibling models on the same day are complete.
    mutating func markModelCostIncomplete(day: String, model: String, canonical: String? = nil) {
        let identity = canonical ?? model
        guard var dailyModels = modelsByDay[day],
              var modelAccumulator = dailyModels[identity]
        else { return }
        modelAccumulator.markCostIncomplete(spelling: model)
        dailyModels[identity] = modelAccumulator
        modelsByDay[day] = dailyModels
    }

    /// Add the public-API-rate estimate for one row (see `add`). Sums per day; rows without any
    /// resolvable rate contribute nothing, so the estimate is honest about coverage.
    mutating func addApiEstimate(day: String, cost: Double) {
        guard !overflowedApiEstimateDays.contains(day) else {
            apiEstimateIncompleteDays.insert(day)
            return
        }
        guard let total = Self.addingFiniteCost(apiEstimateByDay[day], cost) else {
            apiEstimateByDay.removeValue(forKey: day)
            overflowedApiEstimateDays.insert(day)
            apiEstimateIncompleteDays.insert(day)
            return
        }
        apiEstimateByDay[day] = total
    }

    private static func addingFiniteCost(_ current: Double?, _ addition: Double) -> Double? {
        guard addition.isFinite, addition >= 0 else { return nil }
        let total = (current ?? 0) + addition
        return total.isFinite ? total : nil
    }

    /// Mark a day's plan-priced dollars as imputed rather than provider-recorded.
    mutating func markEstimatedCost(day: String) {
        estimatedCostDays.insert(day)
    }

    /// Record public-rate coverage for a row. Provider-specific or carried dollars can exist even
    /// when the shared public catalog cannot price that model; those rows must make the day's API
    /// comparison explicitly incomplete instead of leaving a misleading partial total.
    mutating func recordApiEstimate(day: String, cost: Double?, tokens: Int) {
        guard tokens > 0 else { return }
        if let cost {
            addApiEstimate(day: day, cost: cost)
        } else {
            apiEstimateIncompleteDays.insert(day)
        }
    }

    /// Merge already-built scans (a provider's native log scan plus its pi slice) into one, by replaying
    /// each scan's per-model daily usage through a fresh accumulator so the combined `series`,
    /// `modelUsage`, and unknown-model set stay consistent. Every input must be accumulator-built (its
    /// `series` derived from the same per-model maps), which the native and pi scanners guarantee. Nil
    /// inputs are skipped; returns nil when they are all nil (the provider then folds in nothing).
    ///
    /// `droppingDaysBefore` clips the merged result to a narrower requested window without re-folding:
    /// scanners that serve cache-window aggregates (`CodexLogUsageScanner`) pass the requested window's
    /// first day key. Day keys are zero-padded `yyyy-MM-dd`, so lexicographic order is chronological.
    static func merged(
        _ scans: [LogUsageScan?],
        droppingDaysBefore minDayKey: String? = nil
    ) -> LogUsageScan? {
        let present = scans.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        var accumulator = DailyUsageAccumulator()
        for scan in present {
            accumulator.merge(scan, droppingDaysBefore: minDayKey)
        }
        return accumulator.build()
    }

    /// Merge a previously assembled scan without losing gateway spellings preserved as variants.
    /// Nil-cost rows (unpriced/unidentified models) replay as token-only rows so the merged scan keeps
    /// counting their tokens; the unknown-model flags merge separately below.
    private mutating func merge(_ scan: LogUsageScan, droppingDaysBefore minDayKey: String? = nil) {
        for day in scan.unmeasuredUsageDays ?? [] where minDayKey.map({ day >= $0 }) ?? true {
            unmeasuredUsageDays.insert(day)
        }
        for (day, models) in scan.unknownModelsByDay
        where minDayKey.map({ day >= $0 }) ?? true {
            for model in models {
                addUnknownModel(day: day, model: model)
            }
        }
        for day in scan.modelUsage?.daily ?? [] where minDayKey.map({ day.date >= $0 }) ?? true {
            for model in day.models {
                if let variants = model.variants, !variants.isEmpty {
                    for variant in variants {
                        add(
                            day: day.date,
                            tokens: variant.totalTokens,
                            cost: variant.costUSD,
                            model: variant.model,
                            canonical: model.model,
                            costIsComplete: variant.costIsComplete ?? true,
                            tokenCountSaturated: variant.tokenCountSaturated == true
                                || model.tokenCountSaturated == true
                        )
                    }
                } else {
                    add(
                        day: day.date,
                        tokens: model.totalTokens,
                        cost: model.costUSD,
                        model: model.model,
                        costIsComplete: model.costIsComplete ?? true,
                        tokenCountSaturated: model.tokenCountSaturated == true
                    )
                }
            }
        }
        for day in scan.series.daily
        where minDayKey.map({ day.date >= $0 }) ?? true {
            if !day.costIsComplete {
                incompleteCostDays.insert(day.date)
            }
            if day.hasUnexplainedIncompleteCost == true {
                structuralIncompleteCostDays.insert(day.date)
            }
            if day.tokenCountSaturated {
                tokenCountSaturatedDays.insert(day.date)
            }
        }
        for day in scan.apiEstimateIncompleteDays ?? Set(scan.unknownModelsByDay.keys)
        where minDayKey.map({ day >= $0 }) ?? true {
            apiEstimateIncompleteDays.insert(day)
        }
        for (day, estimate) in scan.apiEstimateByDay ?? [:]
        where minDayKey.map({ day >= $0 }) ?? true {
            addApiEstimate(day: day, cost: estimate)
        }
    }

    /// Merge a primary scan with optional gap-fill supplements.
    ///
    /// Days already present on `primary` (any priced model row) keep only the primary numbers —
    /// supplements are skipped for those days. Supplements still contribute days the primary never
    /// saw. Use this when two ledgers can observe the same traffic (Codex session logs + FCC proxy)
    /// so card tiles / Total Spend do not double-count overlapping days. Additive merges that are
    /// intentionally complementary (native + pi) should keep using `merged(_:)`.
    ///
    /// Returns `(scan, usedSupplement)` so callers can omit "FCC proxy" from the source note when
    /// every supplement day was already covered by primary logs.
    static func mergedPreferringPrimary(
        _ primary: LogUsageScan?,
        fillingGapsFrom supplements: [LogUsageScan?]
    ) -> (scan: LogUsageScan?, usedSupplement: Bool) {
        let primaryDays: Set<String> = Set(
            (primary?.modelUsage?.daily ?? []).compactMap { day in
                day.models.contains(where: { $0.totalTokens > 0 || ($0.costUSD ?? 0) > 0 })
                    ? day.date
                    : nil
            }
        )

        var accumulator = DailyUsageAccumulator()
        var sawAny = false
        var usedSupplement = false

        func absorb(_ scan: LogUsageScan, skipping daysToSkip: Set<String>) -> Bool {
            var absorbed = false
            for (day, models) in scan.unknownModelsByDay where !daysToSkip.contains(day) {
                for model in models {
                    accumulator.addUnknownModel(day: day, model: model)
                    absorbed = true
                }
            }
            for day in scan.modelUsage?.daily ?? [] {
                guard !daysToSkip.contains(day.date) else { continue }
                for model in day.models {
                    if let variants = model.variants, !variants.isEmpty {
                        for variant in variants {
                            accumulator.add(
                                day: day.date,
                                tokens: variant.totalTokens,
                                cost: variant.costUSD,
                                model: variant.model,
                                canonical: model.model,
                                costIsComplete: variant.costIsComplete ?? true,
                                tokenCountSaturated: variant.tokenCountSaturated == true
                                    || model.tokenCountSaturated == true
                            )
                            absorbed = true
                        }
                    } else {
                        accumulator.add(
                            day: day.date,
                            tokens: model.totalTokens,
                            cost: model.costUSD,
                            model: model.model,
                            costIsComplete: model.costIsComplete ?? true,
                            tokenCountSaturated: model.tokenCountSaturated == true
                        )
                        absorbed = true
                    }
                }
            }
            for day in scan.series.daily where !daysToSkip.contains(day.date) {
                if !day.costIsComplete { accumulator.incompleteCostDays.insert(day.date) }
                if day.hasUnexplainedIncompleteCost == true {
                    accumulator.structuralIncompleteCostDays.insert(day.date)
                }
                if day.tokenCountSaturated { accumulator.tokenCountSaturatedDays.insert(day.date) }
            }
            for day in scan.apiEstimateIncompleteDays ?? Set(scan.unknownModelsByDay.keys)
            where !daysToSkip.contains(day) {
                accumulator.apiEstimateIncompleteDays.insert(day)
            }
            for (day, estimate) in scan.apiEstimateByDay ?? [:] where !daysToSkip.contains(day) {
                accumulator.addApiEstimate(day: day, cost: estimate)
                absorbed = true
            }
            return absorbed
        }

        if let primary {
            sawAny = absorb(primary, skipping: []) || sawAny
        }
        for supplement in supplements.compactMap({ $0 }) {
            if absorb(supplement, skipping: primaryDays) {
                sawAny = true
                usedSupplement = true
            }
        }
        guard sawAny else { return (nil, false) }
        return (accumulator.build(), usedSupplement)
    }

    /// Merge Codex sources by day and canonical model. A router row for one model must not hide a
    /// different native model observed on that same day. When both sources contain the same model,
    /// the primary row wins because the sources do not share a request identifier for event-level
    /// deduplication. If a supplement adds a model to a day already covered by another source, the
    /// aggregate API-rate estimate becomes incomplete: those estimates are daily totals and cannot
    /// be safely split into model-level pieces here.
    static func mergedPreferringPrimaryByModel(
        _ primary: LogUsageScan?,
        fillingGapsFrom supplements: [LogUsageScan?],
        modelIdentity: (String) -> String = { $0.lowercased() }
    ) -> (scan: LogUsageScan?, usedSupplement: Bool) {
        struct DayModel: Hashable {
            let day: String
            let model: String
        }

        var accumulator = DailyUsageAccumulator()
        var seenModels: Set<DayModel> = []
        var coveredDays: Set<String> = []
        var sawAny = false
        var usedSupplement = false

        func absorbRows(_ scan: LogUsageScan, skippingSeenModels: Bool) -> Set<String> {
            var addedDays: Set<String> = []
            for day in scan.modelUsage?.daily ?? [] {
                for model in day.models {
                    guard model.totalTokens > 0 || (model.costUSD ?? 0) > 0 else { continue }
                    let key = DayModel(day: day.date, model: modelIdentity(model.model))
                    if skippingSeenModels, seenModels.contains(key) { continue }
                    seenModels.insert(key)
                    addedDays.insert(day.date)

                    if let variants = model.variants, !variants.isEmpty {
                        for variant in variants {
                            accumulator.add(
                                day: day.date,
                                tokens: variant.totalTokens,
                                cost: variant.costUSD,
                                model: variant.model,
                                canonical: model.model,
                                costIsComplete: variant.costIsComplete ?? true,
                                tokenCountSaturated: variant.tokenCountSaturated == true
                                    || model.tokenCountSaturated == true
                            )
                        }
                    } else {
                        accumulator.add(
                            day: day.date,
                            tokens: model.totalTokens,
                            cost: model.costUSD,
                            model: model.model,
                            costIsComplete: model.costIsComplete ?? true,
                            tokenCountSaturated: model.tokenCountSaturated == true
                        )
                    }
                }
            }
            for day in addedDays {
                guard let entry = scan.series.daily.first(where: { $0.date == day }) else { continue }
                if !entry.costIsComplete { accumulator.incompleteCostDays.insert(day) }
                if entry.hasUnexplainedIncompleteCost == true {
                    accumulator.structuralIncompleteCostDays.insert(day)
                }
                if entry.tokenCountSaturated { accumulator.tokenCountSaturatedDays.insert(day) }
            }
            return addedDays
        }

        if let primary {
            for day in primary.series.daily where day.totalTokens > 0 || (day.costUSD ?? 0) > 0 {
                coveredDays.insert(day.date)
            }
            for (day, models) in primary.unknownModelsByDay {
                for model in models { accumulator.addUnknownModel(day: day, model: model) }
            }
            let addedDays = absorbRows(primary, skippingSeenModels: false)
            coveredDays.formUnion(addedDays)
            sawAny = !addedDays.isEmpty
            sawAny = sawAny || !primary.unknownModelsByDay.isEmpty
            coveredDays.formUnion(primary.unknownModelsByDay.keys)
            for day in primary.apiEstimateIncompleteDays ?? Set(primary.unknownModelsByDay.keys) {
                accumulator.apiEstimateIncompleteDays.insert(day)
            }
            for (day, estimate) in primary.apiEstimateByDay ?? [:] {
                accumulator.addApiEstimate(day: day, cost: estimate)
            }
        }

        for supplement in supplements.compactMap({ $0 }) {
            let priorCoverage = coveredDays
            var addedUnknownDays: Set<String> = []
            for (day, models) in supplement.unknownModelsByDay {
                for model in models where !accumulator.unknownModelsByDay[day, default: []].contains(model) {
                    accumulator.addUnknownModel(day: day, model: model)
                    addedUnknownDays.insert(day)
                }
            }
            let addedDays = absorbRows(supplement, skippingSeenModels: true)
            let incompleteEstimateDays = supplement.apiEstimateIncompleteDays
                ?? Set(supplement.unknownModelsByDay.keys)
            guard !addedDays.isEmpty || !addedUnknownDays.isEmpty else { continue }

            sawAny = true
            usedSupplement = true
            for day in addedDays {
                if priorCoverage.contains(day) {
                    accumulator.apiEstimateIncompleteDays.insert(day)
                } else {
                    if incompleteEstimateDays.contains(day) {
                        accumulator.apiEstimateIncompleteDays.insert(day)
                    }
                    if let estimate = supplement.apiEstimateByDay?[day] {
                        accumulator.addApiEstimate(day: day, cost: estimate)
                    }
                }
                coveredDays.insert(day)
            }
            for day in addedUnknownDays {
                accumulator.apiEstimateIncompleteDays.insert(day)
            }
            coveredDays.formUnion(addedUnknownDays)
        }

        guard sawAny else { return (nil, false) }
        return (accumulator.build(), usedSupplement)
    }

    /// Codex native logs and routed rows can spell one model differently: pricing aliases may rewrite
    /// mode suffixes (for example `gpt-5.6-sol-ultra` to `gpt-5.6-sol`). Resolve every known pricing
    /// alias before cross-source reconciliation, then fold fast tiers into the base model. Displayed
    /// model spellings remain untouched.
    static func codexCrossSourceModelIdentity(_ model: String, pricing: ModelPricing) -> String {
        let normalized = model.lowercased()
        let canonical = pricing.canonicalName(for: model)?.lowercased() ?? normalized
        guard canonical.hasPrefix("gpt-"), canonical.hasSuffix("-fast") else { return canonical }
        return String(canonical.dropLast("-fast".count))
    }

    /// Note a model that couldn't be priced but still carried tokens — surfaced as the tile's warning
    /// triangle. Its cost is excluded, while known priced usage remains in the displayed subtotal.
    mutating func addUnknownModel(day: String, model: String) {
        unknownModelsByDay[day, default: []].insert(model)
        incompleteCostDays.insert(day)
        apiEstimateIncompleteDays.insert(day)
    }

    /// Assemble the scan: per-day tokens/cost (days sorted newest-first), the per-day model breakdown,
    /// and the unknown-model set. Days with unpriced rows carry all tokens and any known priced subtotal;
    /// `apiEstimateByDay` carries the public-API-rate comparison when any row could be priced.
    func build() -> LogUsageScan {
        let days = tokensByDay.keys.sorted(by: >).map { day in
            let hasStructuralGap = structuralIncompleteCostDays.contains(day)
                || !incompleteModelCostsByDay[day, default: []]
                    .subtracting(unknownModelsByDay[day, default: []]).isEmpty
            let hasKnownCostGap = overflowedCostDays.contains(day)
                || !unknownModelsByDay[day, default: []].isEmpty
            let hasUnexplainedIncompleteCost: Bool? = hasStructuralGap ? true : (hasKnownCostGap ? false : nil)
            return DailyUsageEntry(
                date: day,
                totalTokens: tokensByDay[day] ?? 0,
                costUSD: costByDay[day],
                costIsComplete: !incompleteCostDays.contains(day),
                hasUnexplainedIncompleteCost: hasUnexplainedIncompleteCost,
                tokenCountSaturated: tokenCountSaturatedDays.contains(day)
            )
        }
        let modelUsage = ModelUsageSeries(daily: modelsByDay.keys.sorted(by: >).map { day in
            DailyModelUsageEntry(
                date: day,
                // Deterministic order (dictionary iteration is randomized): cost desc with nil as $0,
                // then tokens desc, then name — the same total order the spend-tile breakdown uses,
                // so scans and history agree row-for-row.
                models: modelsByDay[day, default: [:]]
                    .map { model, accumulator in accumulator.entry(model: model) }
                    .sorted { lhs, rhs in
                        let lhsCost = lhs.costUSD ?? 0
                        let rhsCost = rhs.costUSD ?? 0
                        if lhsCost != rhsCost { return lhsCost > rhsCost }
                        if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
                        return lhs.model.localizedStandardCompare(rhs.model) == .orderedAscending
                    }
            )
        })
        return LogUsageScan(
            series: DailyUsageSeries(daily: days),
            modelUsage: modelUsage,
            unknownModelsByDay: unknownModelsByDay,
            apiEstimateByDay: apiEstimateByDay.isEmpty ? nil : apiEstimateByDay,
            apiEstimateIncompleteDays: apiEstimateIncompleteDays,
            estimatedCostDays: estimatedCostDays.isEmpty ? nil : estimatedCostDays,
            unmeasuredUsageDays: unmeasuredUsageDays.isEmpty ? nil : unmeasuredUsageDays
        )
    }

    private struct ModelAccumulator {
        var tokens = 0
        var tokenCountSaturated = false
        var costUSD: Double?
        var costIsComplete = true
        var costOverflowed = false
        /// The exact slugs this row absorbed, keyed case-folded. These are what the hover panel lists, so a
        /// gateway-tagged spelling is still visible — just no longer as a row of its own.
        private var spellings: [String: (
            tokens: Int,
            costUSD: Double?,
            spelling: String,
            costIsComplete: Bool,
            tokenCountSaturated: Bool,
            costOverflowed: Bool
        )] = [:]

        mutating func add(
            tokens: Int,
            costUSD: Double?,
            spelling: String,
            costIsComplete: Bool = true,
            sourceTokenCountSaturated: Bool = false
        ) {
            if tokens > 0 && self.tokens > Int.max - tokens { self.tokenCountSaturated = true }
            self.tokens = ProviderParse.addingSaturating(self.tokens, tokens)
            self.tokenCountSaturated = self.tokenCountSaturated || sourceTokenCountSaturated
            if let costUSD {
                if !self.costOverflowed {
                    if let total = DailyUsageAccumulator.addingFiniteCost(self.costUSD, costUSD) {
                        self.costUSD = total
                    } else {
                        self.costOverflowed = true
                        self.costIsComplete = false
                    }
                }
            } else if tokens > 0 {
                self.costIsComplete = false
            }
            if !costIsComplete { self.costIsComplete = false }
            let key = spelling.lowercased()
            var existing = spellings[key] ?? (tokens: 0, costUSD: nil, spelling: spelling,
                                               costIsComplete: true, tokenCountSaturated: false,
                                               costOverflowed: false)
            if tokens > 0 && existing.tokens > Int.max - tokens { existing.tokenCountSaturated = true }
            existing.tokens = ProviderParse.addingSaturating(existing.tokens, tokens)
            existing.tokenCountSaturated = existing.tokenCountSaturated || sourceTokenCountSaturated
            if let costUSD {
                if !existing.costOverflowed {
                    if let total = DailyUsageAccumulator.addingFiniteCost(existing.costUSD, costUSD) {
                        existing.costUSD = total
                    } else {
                        existing.costOverflowed = true
                        existing.costIsComplete = false
                    }
                }
            } else if tokens > 0 {
                existing.costIsComplete = false
            }
            if !costIsComplete { existing.costIsComplete = false }
            spellings[key] = existing
        }

        mutating func markCostIncomplete(spelling: String) {
            costIsComplete = false
            let key = spelling.lowercased()
            guard var existing = spellings[key] else { return }
            existing.costIsComplete = false
            spellings[key] = existing
        }

        func entry(model: String) -> ModelUsageEntry {
            let variants = spellings.values
                .map { value in
                    ModelUsageVariant(
                        model: value.spelling,
                        totalTokens: value.tokens,
                        costUSD: value.costUSD,
                        costIsComplete: value.costIsComplete ? nil : false,
                        tokenCountSaturated: value.tokenCountSaturated ? true : nil
                    )
                }
                .sorted { $0.totalTokens > $1.totalTokens }
            // A single spelling that is just the row's own name is no breakdown; nil keeps the tooltip on
            // plain figures for the overwhelmingly common untagged case.
            let isTrivial = variants.count == 1 && variants[0].model.lowercased() == model.lowercased()
            return ModelUsageEntry(
                model: model,
                totalTokens: tokens,
                costUSD: costUSD,
                variants: isTrivial ? nil : (variants.isEmpty ? nil : variants),
                costIsComplete: costIsComplete ? nil : false,
                tokenCountSaturated: tokenCountSaturated ? true : nil
            )
        }
    }
}
