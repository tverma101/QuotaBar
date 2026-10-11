import Foundation

/// Accumulates priced per-day usage — tokens, cost, and the per-model breakdown — then assembles a
/// `LogUsageScan`. Shared by the log scanners (Claude, Codex, Grok) so the "accumulate then assemble"
/// tail lives in one place instead of a byte-identical copy per provider; each scanner keeps only its
/// format-specific parse/pricing loop.
///
/// Days are keyed by the shared local-calendar `dayKey`, matching `SpendTileMapper`'s Today / Yesterday
/// lookup — the day-key contract is one function, not five copies (drift here is the class of bug behind
/// the ccusage false-zero fix). Unpriced rows are added token-only (nil cost) and flagged for the
/// reveal system, so token totals stay complete while dollars only count priced usage.
struct DailyUsageAccumulator {
    private var tokensByDay: [String: Int] = [:]
    private var costByDay: [String: Double] = [:]
    private var apiEstimateByDay: [String: Double] = [:]
    private var unknownModelsByDay: [String: Set<String>] = [:]
    private var modelsByDay: [String: [String: ModelAccumulator]] = [:]

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
    /// stream). Those rows count their tokens and show a dash for cost — the owner's "count tokens,
    /// dash cost" policy — instead of being withheld from every total. `apiEstimate` carries what the
    /// same tokens would cost at public API rates when a rate exists for the row (the "if it were all
    /// API" comparison); nil when the model is unidentified.
    ///
    /// Defaults to `model`, so a scanner with no aliasing is unaffected.
    mutating func add(
        day: String,
        tokens: Int,
        cost: Double?,
        model: String,
        canonical: String? = nil
    ) {
        tokensByDay[day] = ProviderParse.addingSaturating(tokensByDay[day, default: 0], tokens)
        if let cost {
            costByDay[day, default: 0] += cost
        }
        let identity = canonical ?? model
        modelsByDay[day, default: [:]][identity, default: ModelAccumulator()]
            .add(tokens: tokens, costUSD: cost, spelling: model)
    }

    /// Add the public-API-rate estimate for one row (see `add`). Sums per day; rows without any
    /// resolvable rate contribute nothing, so the estimate is honest about coverage.
    mutating func addApiEstimate(day: String, cost: Double) {
        apiEstimateByDay[day, default: 0] += cost
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
        for day in scan.modelUsage?.daily ?? [] where minDayKey.map({ day.date >= $0 }) ?? true {
            for model in day.models {
                if let variants = model.variants, !variants.isEmpty {
                    for variant in variants {
                        add(
                            day: day.date,
                            tokens: variant.totalTokens,
                            cost: variant.costUSD,
                            model: variant.model,
                            canonical: model.model
                        )
                    }
                } else {
                    add(
                        day: day.date,
                        tokens: model.totalTokens,
                        cost: model.costUSD,
                        model: model.model
                    )
                }
            }
        }
        for (day, models) in scan.unknownModelsByDay
        where minDayKey.map({ day >= $0 }) ?? true {
            for model in models {
                addUnknownModel(day: day, model: model)
            }
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
                                canonical: model.model
                            )
                            absorbed = true
                        }
                    } else {
                        accumulator.add(
                            day: day.date,
                            tokens: model.totalTokens,
                            cost: model.costUSD,
                            model: model.model
                        )
                        absorbed = true
                    }
                }
            }
            for (day, models) in scan.unknownModelsByDay where !daysToSkip.contains(day) {
                for model in models {
                    accumulator.addUnknownModel(day: day, model: model)
                    absorbed = true
                }
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

    /// Note a model that couldn't be priced but still carried tokens — surfaced as the tile's warning
    /// triangle, the only place unpriceable usage appears (it's excluded from every displayed total).
    mutating func addUnknownModel(day: String, model: String) {
        unknownModelsByDay[day, default: []].insert(model)
    }

    /// Assemble the scan: per-day tokens/cost (days sorted newest-first), the per-day model breakdown,
    /// and the unknown-model set. Days with unpriced rows carry their tokens (cost shows the priced
    /// subtotal); `apiEstimateByDay` carries the public-API-rate comparison when any row could be priced.
    func build() -> LogUsageScan {
        let days = tokensByDay.keys.sorted(by: >).map { day in
            DailyUsageEntry(date: day, totalTokens: tokensByDay[day] ?? 0, costUSD: costByDay[day])
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
            apiEstimateByDay: apiEstimateByDay.isEmpty ? nil : apiEstimateByDay
        )
    }

    private struct ModelAccumulator {
        var tokens = 0
        var costUSD: Double?
        /// The exact slugs this row absorbed, keyed case-folded. These are what the hover panel lists, so a
        /// gateway-tagged spelling is still visible — just no longer as a row of its own.
        private var spellings: [String: (tokens: Int, costUSD: Double?, spelling: String)] = [:]

        mutating func add(tokens: Int, costUSD: Double?, spelling: String) {
            self.tokens = ProviderParse.addingSaturating(self.tokens, tokens)
            if let costUSD {
                self.costUSD = (self.costUSD ?? 0) + costUSD
            }
            let key = spelling.lowercased()
            var existing = spellings[key] ?? (0, nil, spelling)
            existing.tokens = ProviderParse.addingSaturating(existing.tokens, tokens)
            existing.costUSD = costUSD.map { (existing.costUSD ?? 0) + $0 } ?? existing.costUSD
            spellings[key] = existing
        }

        func entry(model: String) -> ModelUsageEntry {
            let variants = spellings.values
                .map { value in
                    ModelUsageVariant(
                        model: value.spelling,
                        totalTokens: value.tokens,
                        costUSD: value.costUSD
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
                variants: isTrivial ? nil : (variants.isEmpty ? nil : variants)
            )
        }
    }
}
