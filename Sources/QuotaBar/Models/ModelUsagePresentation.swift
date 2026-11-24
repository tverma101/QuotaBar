import Foundation

/// Uses the known dollar subtotal whenever it is positive. Scaling before adding keeps the
/// shares usable even when the sum of individually finite costs would overflow.
struct ModelSpendShares {
    private let largestCost: Double
    private let scaledTotal: Double

    init?(_ models: [ModelUsageEntry]) {
        guard let largest = models.compactMap(\.costUSD).filter(\.isFinite).max(), largest > 0 else { return nil }
        largestCost = largest
        scaledTotal = models.reduce(0) { $0 + Self.positiveCost($1.costUSD) / largest }
    }

    func share(of model: ModelUsageEntry) -> Double {
        (Self.positiveCost(model.costUSD) / largestCost) / scaledTotal
    }

    private static func positiveCost(_ cost: Double?) -> Double {
        guard let cost, cost.isFinite, cost > 0 else { return 0 }
        return cost
    }
}

extension ModelUsageEntry {
    static func ranksBefore(_ lhs: ModelUsageEntry, _ rhs: ModelUsageEntry) -> Bool {
        let lhsCost = lhs.costUSD ?? 0
        let rhsCost = rhs.costUSD ?? 0
        if lhsCost != rhsCost { return lhsCost > rhsCost }
        if (lhs.costUSD != nil) != (rhs.costUSD != nil) { return lhs.costUSD != nil }
        if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
        return lhs.model.localizedStandardCompare(rhs.model) == .orderedAscending
    }

    /// Other is a group of models. One model inside it is not a group: the row and that model
    /// would show the same tokens and cost. A lone named model becomes its own row. A lone
    /// unattributed bucket stays Other, without a second line that repeats it.
    func collapsingRestatedOther() -> ModelUsageEntry {
        guard model.caseInsensitiveCompare(Self.otherModelName) == .orderedSame,
              let variants, variants.count == 1, let only = variants.first,
              only.totalTokens == totalTokens,
              restatesCost(only.costUSD)
        else { return self }
        if only.model.caseInsensitiveCompare(Self.unattributedModelName) == .orderedSame {
            var row = self
            row.variants = nil
            return row
        }
        return ModelUsageEntry(
            model: only.model,
            totalTokens: totalTokens,
            costUSD: costUSD,
            variants: nil,
            costIsComplete: costIsComplete,
            tokenCountSaturated: tokenCountSaturated
        )
    }

    /// Hover rows for this entry. One model that carries an Other row's entire price is listed on
    /// its own, and so is each leftover model. Cursor, Antigravity, Codex, and the other spend
    /// hovers were printing that price twice: once as Other, again as the only priced contributor.
    func presentedRows() -> [ModelUsageEntry] {
        let collapsed = collapsingRestatedOther()
        guard collapsed.model.caseInsensitiveCompare(Self.otherModelName) == .orderedSame,
              let variants = collapsed.variants, variants.count > 1,
              let cost = collapsed.costUSD, cost > 0
        else { return [collapsed.droppingRestatedVariant()] }

        let echoIndexes = variants.indices.filter { index in
            guard let part = variants[index].costUSD, part > 0 else { return false }
            return abs(part - cost) < 0.005
        }
        let (contributorTokens, overflow) = variants.reduce(into: (0, false)) { subtotal, variant in
            guard !subtotal.1 else { return }
            subtotal = subtotal.0.addingReportingOverflow(variant.totalTokens)
        }
        guard echoIndexes.count == 1, let echoIndex = echoIndexes.first,
              !overflow, contributorTokens == collapsed.totalTokens,
              collapsed.tokenCountSaturated != true else {
            return [collapsed]
        }
        let rest = variants.enumerated().compactMap { index, variant in
            index == echoIndex ? nil : variant
        }
        guard rest.allSatisfy({ ($0.costUSD ?? 0) == 0 }) else { return [collapsed] }
        return [Self.row(for: variants[echoIndex])] + Self.rows(forRemaining: rest)
    }

    /// A single raw slug that repeats this row's own tokens and cost is not a breakdown.
    func droppingRestatedVariant() -> ModelUsageEntry {
        guard let variants, variants.count == 1, let only = variants.first,
              only.totalTokens == totalTokens, restatesCost(only.costUSD)
        else { return self }
        var row = self
        row.variants = nil
        return row
    }

    private static func row(for variant: ModelUsageVariant) -> ModelUsageEntry {
        ModelUsageEntry(
            model: variant.model,
            totalTokens: variant.totalTokens,
            costUSD: variant.costUSD,
            variants: nil,
            costIsComplete: variant.costIsComplete,
            tokenCountSaturated: variant.tokenCountSaturated
        )
    }

    private static func rows(forRemaining variants: [ModelUsageVariant]) -> [ModelUsageEntry] {
        guard !variants.isEmpty else { return [] }
        if variants.count == 1, let only = variants.first {
            if only.model.caseInsensitiveCompare(unattributedModelName) == .orderedSame {
                return [ModelUsageEntry(
                    model: otherModelName,
                    totalTokens: only.totalTokens,
                    costUSD: only.costUSD,
                    variants: nil,
                    costIsComplete: only.costIsComplete,
                    tokenCountSaturated: only.tokenCountSaturated
                )]
            }
            return [row(for: only)]
        }
        let tokens = variants.reduce(0) { ProviderParse.addingSaturating($0, $1.totalTokens) }
        var cost: Double?
        var incomplete = false
        var saturated = false
        for variant in variants {
            if let part = variant.costUSD {
                cost = (cost ?? 0) + part
            }
            incomplete = incomplete || variant.hasIncompleteCost
            saturated = saturated || variant.tokenCountSaturated == true
        }
        return [ModelUsageEntry(
            model: otherModelName,
            totalTokens: tokens,
            costUSD: cost,
            variants: variants,
            costIsComplete: incomplete ? false : (cost == nil ? false : nil),
            tokenCountSaturated: saturated ? true : nil
        )]
    }

    private func restatesCost(_ other: Double?) -> Bool {
        switch (costUSD, other) {
        case (nil, nil):
            return true
        case let (row?, part?):
            guard row.isFinite, part.isFinite else { return false }
            return abs(row - part) < 0.005
        default:
            return false
        }
    }
}
