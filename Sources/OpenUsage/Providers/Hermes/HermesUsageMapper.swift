import Foundation

/// Turns a Hermes scan into the card's rows: Today / This Week / This Month token rows (with cost when
/// Hermes priced the sessions and a per-model breakdown on hover) plus the Usage Trend chart. A period
/// with no usage at all is left unbacked so the tile reads "No data" — the same rule as every other
/// provider's spend tiles.
enum HermesUsageMapper {
    /// Names the local source on hover. Token counts are measured by Hermes itself; the cost is Hermes'
    /// own per-session estimate (`estimated_cost_usd`), so dollars carry the local-estimate marker (ⓘ).
    static let sourceNote = "From your Hermes state database"

    /// Models above this count fold into "Other" (mirrors the spend tiles' `namedModelCap`).
    private static let namedModelCap = 5

    static func lines(scan: HermesUsageScan, now: Date) -> [MetricLine] {
        var lines: [MetricLine] = []

        for period in HermesPeriod.allCases {
            guard let usage = scan.periods.first(where: { $0.period == period }), hasUsage(usage) else {
                continue
            }
            lines.append(.values(
                label: period.displayName,
                values: values(usage),
                modelBreakdown: breakdown(
                    models: scan.modelUsageByPeriod[period] ?? [],
                    totalTokens: usage.counts.total,
                    totalCostUSD: usage.costUSD
                )
            ))
        }

        if !scan.daily.daily.isEmpty {
            SpendTileMapper.appendUsageTrend(scan.daily, to: &lines, now: now, note: sourceNote)
        }

        MetricLine.appendNoDataIfNeeded(&lines)
        return lines
    }

    /// A period with any real usage: tokens used or dollars priced. A zero-token, zero-cost period is
    /// idle and gets no tile (→ "No data"), not a fabricated "0 tokens".
    private static func hasUsage(_ usage: HermesPeriodUsage) -> Bool {
        usage.counts.total > 0 || (usage.costUSD ?? 0) > 0
    }

    /// The row's values: estimated dollars first (Hermes' own per-session estimate), then the measured
    /// token count — rendered combined as "$4.08 · 1.2M tokens", like every spend tile.
    private static func values(_ usage: HermesPeriodUsage) -> [MetricValue] {
        var values: [MetricValue] = []
        if let costUSD = usage.costUSD {
            values.append(MetricValue(number: costUSD, kind: .dollars, estimated: true))
        }
        values.append(MetricValue(number: Double(usage.counts.total), kind: .count, label: "tokens"))
        return values
    }

    /// Per-model attribution for the period's hover panel: ranked by tokens, top `namedModelCap` named
    /// and the rest folded into "Other" (which still lists them in its tooltip).
    private static func breakdown(
        models: [HermesModelUsage],
        totalTokens: Int,
        totalCostUSD: Double?
    ) -> ModelUsageBreakdown? {
        guard !models.isEmpty else { return nil }

        var named: [ModelUsageEntry] = []
        var otherTokens = 0
        var otherCost: Double?
        var otherModels: [ModelUsageVariant] = []

        for model in models {
            let name = model.model.nilIfEmpty ?? ModelUsageEntry.unattributedModelName
            let entry = ModelUsageEntry(model: name, totalTokens: model.tokens, costUSD: model.costUSD)
            if named.count < namedModelCap {
                named.append(entry)
            } else {
                otherTokens += model.tokens
                if let cost = model.costUSD {
                    otherCost = (otherCost ?? 0) + cost
                }
                otherModels.append(ModelUsageVariant(model: name, totalTokens: model.tokens, costUSD: model.costUSD))
            }
        }
        if otherTokens > 0 || (otherCost ?? 0) > 0 {
            named.append(ModelUsageEntry(
                model: ModelUsageEntry.otherModelName,
                totalTokens: otherTokens,
                costUSD: otherCost,
                variants: otherModels
            ))
        }
        guard !named.isEmpty else { return nil }
        return ModelUsageBreakdown(
            totalTokens: totalTokens,
            totalCostUSD: totalCostUSD,
            models: named,
            sourceNote: sourceNote
        )
    }
}
