import Foundation

/// Accumulates priced per-day usage — tokens, cost, and the per-model breakdown — then assembles a
/// `LogUsageScan`. Shared by the log scanners (Claude, Codex, Grok) so the "accumulate then assemble"
/// tail lives in one place instead of a byte-identical copy per provider; each scanner keeps only its
/// format-specific parse/pricing loop.
///
/// Days are keyed by the shared local-calendar `dayKey`, matching `SpendTileMapper`'s Today / Yesterday
/// lookup — the day-key contract is one function, not five copies (drift here is the class of bug behind
/// the ccusage false-zero fix). Only priced rows are added (every scanner skips unpriceable rows before
/// counting), so every counted day carries a real cost; unpriceable models are tracked separately for
/// the tile's warning triangle.
struct DailyUsageAccumulator {
    private var tokensByDay: [String: Int] = [:]
    private var costByDay: [String: Double] = [:]
    private var unknownModelsByDay: [String: Set<String>] = [:]
    private var modelsByDay: [String: [String: ModelAccumulator]] = [:]

    /// Local calendar day as `yyyy-MM-dd`. The single day-key contract shared by the accumulator,
    /// `SpendTileMapper`, and the Cursor CSV aggregation. `calendar` is injectable for tests; production
    /// uses `.current`.
    static func dayKey(from date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// Add a priced row's tokens + cost, attributed to `model` on `day`.
    ///
    /// `canonical` is the model's *identity*; `model` is the slug the provider actually emitted. They
    /// differ when a gateway tags its slugs: the Codex router stamps the upstream path, so one model
    /// arrives as both `gpt-5.6-luna` and `anthropic/openai/gpt-5.6-luna`. Keying rows by the raw slug
    /// split that one model into two rows that were then summed into the same total, and the tagged one
    /// displayed its routing prefix as if it were part of the model's name. Scanners that resolve pricing
    /// pass the catalog key as `canonical`, so anything priced alike collapses into one row titled with
    /// the catalog id, while the observed spellings survive as tooltip variants.
    ///
    /// Defaults to `model`, so a scanner with no aliasing is unaffected.
    mutating func add(
        day: String,
        tokens: Int,
        cost: Double,
        model: String,
        canonical: String? = nil
    ) {
        tokensByDay[day, default: 0] += tokens
        costByDay[day, default: 0] += cost
        let identity = canonical ?? model
        modelsByDay[day, default: [:]][identity, default: ModelAccumulator()]
            .add(tokens: tokens, costUSD: cost, spelling: model)
    }

    /// Merge already-built scans (a provider's native log scan plus its pi slice) into one, by replaying
    /// each scan's per-model daily usage through a fresh accumulator so the combined `series`,
    /// `modelUsage`, and unknown-model set stay consistent. Every input must be accumulator-built (its
    /// `series` derived from the same per-model maps), which the native and pi scanners guarantee. Nil
    /// inputs are skipped; returns nil when they are all nil (the provider then folds in nothing).
    static func merged(_ scans: [LogUsageScan?]) -> LogUsageScan? {
        let present = scans.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        var accumulator = DailyUsageAccumulator()
        for scan in present {
            for day in scan.modelUsage?.daily ?? [] {
                for model in day.models {
                    // Skip cost-unknown entries rather than treating nil as $0 — their unknown-model
                    // metadata is already carried through via unknownModelsByDay below.
                    guard let cost = model.costUSD else { continue }
                    accumulator.add(day: day.date, tokens: model.totalTokens, cost: cost, model: model.model)
                }
            }
            for (day, models) in scan.unknownModelsByDay {
                for model in models {
                    accumulator.addUnknownModel(day: day, model: model)
                }
            }
        }
        return accumulator.build()
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
                    guard let cost = model.costUSD else { continue }
                    accumulator.add(day: day.date, tokens: model.totalTokens, cost: cost, model: model.model)
                    absorbed = true
                }
            }
            for (day, models) in scan.unknownModelsByDay where !daysToSkip.contains(day) {
                for model in models {
                    accumulator.addUnknownModel(day: day, model: model)
                    absorbed = true
                }
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
    /// and the unknown-model set. Every counted day is priced, so its `costUSD` is always the real total.
    func build() -> LogUsageScan {
        let days = tokensByDay.keys.sorted(by: >).map { day in
            DailyUsageEntry(date: day, totalTokens: tokensByDay[day] ?? 0, costUSD: costByDay[day] ?? 0)
        }
        let modelUsage = ModelUsageSeries(daily: modelsByDay.keys.sorted(by: >).map { day in
            DailyModelUsageEntry(
                date: day,
                models: modelsByDay[day, default: [:]].map { model, accumulator in accumulator.entry(model: model) }
            )
        })
        return LogUsageScan(
            series: DailyUsageSeries(daily: days),
            modelUsage: modelUsage,
            unknownModelsByDay: unknownModelsByDay
        )
    }

    private struct ModelAccumulator {
        var tokens = 0
        var costUSD: Double?
        /// The exact slugs this row absorbed, keyed case-folded. These are what the hover panel lists, so a
        /// gateway-tagged spelling is still visible — just no longer as a row of its own.
        private var spellings: [String: (tokens: Int, costUSD: Double?, spelling: String)] = [:]

        mutating func add(tokens: Int, costUSD: Double?, spelling: String) {
            self.tokens += tokens
            if let costUSD {
                self.costUSD = (self.costUSD ?? 0) + costUSD
            }
            let key = spelling.lowercased()
            var existing = spellings[key] ?? (0, nil, spelling)
            existing.tokens += tokens
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
