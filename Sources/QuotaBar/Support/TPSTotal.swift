import Foundation

/// The TPS lens for the Total Spend panel — everything TPS, nothing about spend. Built purely from
/// the TPS data source's `ProviderSnapshot` (the `TPSTrackerProvider` fold of every local corpus
/// that carries per-report timing), never from spend tiles or history. Pure and synchronous.
struct TPSTotal: Equatable, Sendable {
    /// One provider's measured generation: its average rate, the output tokens the fold saw, and its
    /// own models ranked by tokens — so the lens can show a per-provider breakdown, not one merged blob.
    struct Slice: Identifiable, Equatable, Sendable {
        let provider: Provider
        let rate: Double
        let tokens: Double
        let models: [ModelRow]
        var id: String { provider.id }
    }

    /// One model's rate across every corpus, ranked by tokens (most generated first).
    struct ModelRow: Identifiable, Equatable, Sendable {
        let name: String
        let tokens: Double
        let rate: Double?
        var id: String { name }
    }

    /// Per-provider slices, ranked by rate (fastest first).
    var slices: [Slice]
    /// Per-model rows from the merged estimate's model breakdown, ranked by tokens (descending).
    var models: [ModelRow]
    /// Combined, token-weighted estimate across every corpus. `nil` until enough qualifying
    /// paired reports exist.
    var combinedRate: Double?
    var combinedTokens: Double
    var windowLabel: String

    var isEmpty: Bool { slices.isEmpty && models.isEmpty }

    /// The ring needs slices ranked by the arc weight — rate — so the fastest provider takes the
    /// largest share, exactly like Cost/MTok's rate-share arcs.
    func projection() -> TotalSpendProjection {
        let projected = slices.map {
            TotalSpendProjectedSlice(
                provider: $0.provider,
                displayAmount: $0.rate,
                displayAmountIsLowerBound: false,
                estimated: true
            )
        }
        return TotalSpendProjection(
            metric: .tps,
            slices: projected,
            centerValue: combinedRate ?? 0,
            isEstimated: true,
            hasIncompleteCost: false,
            hasPartialData: false,
            centerValueIsLowerBound: false,
            hasActiveSessionData: false,
            hasSaturatedTokenData: false
        )
    }

    /// Build the lens's data from the TPS provider's snapshot. `nil` when the provider never ran
    /// or its fold failed — the panel shows the empty state, never a fabricated zero. The window
    /// selects which of the fold's pre-bucketed views to render; switching never re-folds.
    static func from(
        _ snapshot: ProviderSnapshot?,
        window: TokensPerSecondWindow = .fourteenDays
    ) -> TPSTotal? {
        guard let snapshot else { return nil }
        let lines = Dictionary(snapshot.lines.map { ($0.label, $0) }, uniquingKeysWith: { first, _ in first })

        func numbers(in label: String) -> (rate: Double?, tokens: Double?, breakdown: ModelUsageBreakdown?) {
            guard case .values(_, let values, _, _, _, let breakdown)? = lines[label + window.labelSuffix] else {
                return (nil, nil, nil)
            }
            let rate = values.first { $0.label == "tok/s" }?.number
            let tokens = values.first { $0.label == "tokens" }?.number
            return (rate, tokens, breakdown)
        }

        let combined = numbers(in: "Est. TPS")
        var slices: [Slice] = []
        for (id, label) in TokensPerSecondMapper.providerLabels {
            let entry = numbers(in: label)
            guard let rate = entry.rate, rate > 0 else { continue }
            slices.append(Slice(
                provider: Provider(id: id, displayName: label, icon: .providerMark(id)),
                rate: rate,
                tokens: entry.tokens ?? 0,
                models: modelRows(entry.breakdown?.models ?? [])
            ))
        }
        slices.sort { lhs, rhs in
            if lhs.rate != rhs.rate { return lhs.rate > rhs.rate }
            return lhs.provider.displayName.localizedStandardCompare(rhs.provider.displayName) == .orderedAscending
        }

        let breakdownModels = combined.breakdown?.models ?? []
        let combinedTokens = combined.tokens
            ?? breakdownModels.reduce(0) { $0 + Double($1.totalTokens) }
        let models = modelRows(breakdownModels)
        // A panel with rates but zero token mass (some corpora report only deltas) still has slices.
        let isEmpty = slices.isEmpty && models.isEmpty
        guard !isEmpty || combined.rate != nil else { return nil }
        return TPSTotal(
            slices: slices,
            models: models,
            combinedRate: combined.rate,
            combinedTokens: combinedTokens,
            windowLabel: window.windowLabel
        )
    }

    /// Model rows ranked by tokens (descending), then name — shared by the merged list and each
    /// provider's own breakdown.
    private static func modelRows(_ models: [ModelUsageEntry]) -> [ModelRow] {
        models.map { ModelRow(name: $0.model, tokens: Double($0.totalTokens), rate: $0.tokensPerSecond) }
            .sorted { lhs, rhs in
                if lhs.tokens != rhs.tokens { return lhs.tokens > rhs.tokens }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
}
