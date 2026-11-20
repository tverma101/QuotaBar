import SwiftUI

/// Hover detail for a spend period: a flat ranked list of the leading models, each with
/// name/cost and share-percent/token lines over a proportional bar — the period's top models are
/// named outright and the rest fold into Other, whose contributors (name, tokens and price each)
/// stay collapsed behind a chevron until expanded. The header carries only the period name — the
/// hovered row right below already shows the period total, so repeating it here would duplicate
/// (and wrap on) long figures.
/// Mirrors `UsageTrendDetail`'s calm — header + flat list + source note.
struct ModelUsageDetail: View {
    let title: String
    let breakdown: ModelUsageBreakdown
    var onHoverChange: (Bool) -> Void

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @State private var otherExpanded = false

    private static let width: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            fullList
            if let note = breakdown.sourceNote {
                PopoverSourceNote(text: note)
            }
        }
        .padding(14)
        .frame(width: Self.width)
        // Hug the content vertically so collapsing Other shrinks the popover back — NSPopover
        // grows to the largest measured height and never rescales on its own.
        .fixedSize(horizontal: false, vertical: true)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                onHoverChange(true)
            case .ended:
                onHoverChange(false)
            }
        }
    }

    private var header: some View {
        Text(title)
            .font(.system(size: density.headerPointSize, weight: .semibold))
            .foregroundStyle(.primary)
    }

    private var fullList: some View {
        let models = breakdown.models.flatMap { $0.presentedRows() }.sorted(by: ModelUsageEntry.ranksBefore)
        let usesSpend = ModelSpendShares(models) != nil
        let aggregateTokenCountSaturated = breakdown.tokenCountSaturated == true
        let sharesAreReliable = Self.sharesAreReliable(
            for: models,
            aggregateTokenCountSaturated: aggregateTokenCountSaturated
        )
        let shares = Self.shares(
            for: models,
            aggregateTokenCountSaturated: aggregateTokenCountSaturated
        )
        let percents = Self.wholePercents(shares)
        return VStack(alignment: .leading, spacing: 0) {
            if sharesAreReliable {
                Text(usesSpend ? "Share of Known Spend" : "Share of Measured Tokens")
                    .font(.system(size: density.supportingPointSize - 1))
                    .foregroundStyle(.secondary)
            }
            ForEach(models.indices, id: \.self) { index in
                let hasShare = sharesAreReliable && (!usesSpend || models[index].costUSD != nil)
                modelRow(
                    models[index],
                    share: hasShare ? shares[index] : nil,
                    percent: hasShare ? percents[index] : nil,
                    contributors: Self.otherContributors(for: models[index])
                )
            }
            if !sharesAreReliable {
                Text("Shares unavailable because a token total is only a lower bound.")
                    .font(.system(size: density.supportingPointSize - 1))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Model name / cost on top, share percent / tokens beneath. The Other row can add a compact
    /// contributor line below its label; the percent line answers what the bar can't say precisely.
    private func modelRow(
        _ model: ModelUsageEntry, share: Double?, percent: Int?, contributors: [ModelUsageVariant]
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(model.model)
                        .font(.system(size: density.supportingPointSize, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !contributors.isEmpty {
                        Button {
                            otherExpanded.toggle()
                        } label: {
                            Image(systemName: otherExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: density.supportingPointSize - 3, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(otherExpanded ? "Hide Other Models" : "Show Other Models")
                    }
                }
                Spacer(minLength: 8)
                if let cost = model.costUSD {
                    Text(Self.costText(cost, incomplete: model.hasIncompleteCost))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                } else {
                    Text("Unpriced")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: density.supportingPointSize))

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(percent.map { $0 == 0 && (share ?? 0) > 0 ? "<1%" : "\($0)%" } ?? "—")
                    .monospacedDigit()
                Spacer(minLength: 8)
                Text(MetricFormatter.string(
                    for: MetricValue(
                        number: Double(model.totalTokens),
                        kind: .count,
                        label: "tokens",
                        tokenCountSaturated: model.tokenCountSaturated
                    ),
                    style: .row
                ))
                .monospacedDigit()
            }
            .font(.system(size: density.supportingPointSize))
            .foregroundStyle(.secondary)

            GeometryReader { proxy in
                Capsule()
                    .fill(.quaternary)
                    .overlay(alignment: .leading) {
                        if let share {
                            Capsule()
                                .fill(Theme.meterFill(.normal))
                                .frame(width: proxy.size.width * share)
                        }
                    }
            }
            .frame(height: density.meterHeight)
            .padding(.top, 2)

            if otherExpanded && !contributors.isEmpty {
                Group {
                    if contributors.count <= 8 {
                        contributorRows(contributors)
                    } else {
                        // Tall enough that a long tail (many small models folded into Other) reads as
                        // real usage rather than a sliver — ~8 rows visible, the rest scrollable.
                        ScrollView(.vertical) {
                            contributorRows(contributors)
                        }
                        .frame(height: 260)
                    }
                }
                .font(.system(size: density.supportingPointSize - 1))
                .padding(.top, 5)
            }
        }
        .padding(.vertical, density.textRowPadding)
    }

    private func contributorRows(_ contributors: [ModelUsageVariant]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(contributors, id: \.model) { contributor in
                VStack(alignment: .leading, spacing: 1) {
                    Text(contributor.model)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        if let cost = contributor.costUSD {
                            Text(Self.costText(cost, incomplete: contributor.hasIncompleteCost))
                        } else {
                            Text("Unpriced")
                        }
                        Spacer(minLength: 4)
                        Text(MetricFormatter.string(for: MetricValue(
                            number: Double(contributor.totalTokens), kind: .count, label: "tokens",
                            tokenCountSaturated: contributor.tokenCountSaturated
                        ), style: .row))
                    }
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func costText(_ cost: Double, incomplete: Bool) -> String {
        if cost > 0, cost < 0.005, !incomplete { return "<$0.01" }
        return (incomplete ? "≥" : "") + MetricFormatter.number(cost, kind: .dollars, style: .row)
    }

    /// Rank contributors by spend, followed by token volume for ties and unpriced usage.
    static func otherContributors(for model: ModelUsageEntry) -> [ModelUsageVariant] {
        guard model.model.caseInsensitiveCompare(ModelUsageEntry.otherModelName) == .orderedSame,
              let variants = model.variants,
              !variants.isEmpty
        else { return [] }

        return variants.sorted { lhs, rhs in
            let lhsCost = lhs.costUSD ?? 0
            let rhsCost = rhs.costUSD ?? 0
            if lhsCost != rhsCost { return lhsCost > rhsCost }
            if (lhs.costUSD != nil) != (rhs.costUSD != nil) { return lhs.costUSD != nil }
            if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
            return lhs.model.localizedStandardCompare(rhs.model) == .orderedAscending
        }
    }

    /// Price shares use the listed models' known dollars. Tokens are the fallback for periods
    /// with no positive known cost.
    static func shares(
        for models: [ModelUsageEntry],
        aggregateTokenCountSaturated: Bool = false
    ) -> [Double] {
        if let spend = ModelSpendShares(models) {
            return models.map { spend.share(of: $0) }
        }
        guard sharesAreReliable(for: models, aggregateTokenCountSaturated: aggregateTokenCountSaturated)
        else { return models.map { _ in 0 } }
        let tokenTotal = models.reduce(0) { ProviderParse.addingSaturating($0, $1.totalTokens) }
        guard tokenTotal > 0 else { return models.map { _ in 0 } }
        return models.map { model in
            min(max(Double(model.totalTokens) / Double(tokenTotal), 0), 1)
        }
    }

    static func sharesAreReliable(
        for models: [ModelUsageEntry],
        aggregateTokenCountSaturated: Bool = false
    ) -> Bool {
        if ModelSpendShares(models) != nil { return true }
        guard !aggregateTokenCountSaturated,
              !models.contains(where: { $0.tokenCountSaturated == true })
        else { return false }
        var tokenTotal = 0
        for model in models {
            if model.totalTokens < 0 { return false }
            if model.totalTokens > 0 && tokenTotal > Int.max - model.totalTokens { return false }
            tokenTotal += model.totalTokens
        }
        return true
    }

    /// Integer percentages that always total exactly 100 (largest-remainder rounding): rounding each
    /// share independently can print a column that sums to 99 or 101, so every share is floored and
    /// the leftover points go to the rows with the biggest fractional remainders. All-zero shares
    /// (an empty period) stay all zero.
    static func wholePercents(_ shares: [Double]) -> [Int] {
        guard shares.contains(where: { $0 > 0 }) else { return shares.map { _ in 0 } }
        // Shares come from cost division and can be non-finite if an upstream cost overflowed. A raw
        // `Int(_:)` on NaN/infinity traps — inside a SwiftUI body, that kills the app. Clamp first.
        let raw = shares.map { share -> Double in
            guard share.isFinite else { return 0 }
            return min(max(share * 100, 0), 100)
        }
        // Every share was non-finite: there is no meaningful distribution to complete to 100%.
        guard raw.contains(where: { $0 > 0 }) else { return raw.map { _ in 0 } }
        var percents = raw.map { Int($0.rounded(.down)) }
        var leftover = 100 - percents.reduce(0, +)
        guard leftover > 0 else { return percents }
        let byRemainder = raw.indices.sorted {
            let lhs = raw[$0] - raw[$0].rounded(.down)
            let rhs = raw[$1] - raw[$1].rounded(.down)
            if lhs != rhs { return lhs > rhs }
            return $0 < $1
        }
        for index in byRemainder where leftover > 0 {
            percents[index] += 1
            leftover -= 1
        }
        return percents
    }
}
