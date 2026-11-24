import SwiftUI

/// Hover detail for a spend period: a flat ranked list of models, each with name/cost and
/// share-percent/token lines over a proportional bar. The Other row keeps the ranked list honest
/// without dumping its whole tail on the reader: its contributors (name, tokens and price each)
/// stay collapsed behind a chevron until expanded. The header carries only the period name — the hovered row right below
/// already shows the period total, so repeating it here would duplicate (and wrap on) long figures.
/// Mirrors `UsageTrendDetail`'s calm — header + flat list + source note.
struct ModelUsageDetail: View {
    let title: String
    let breakdown: ModelUsageBreakdown
    /// Collapses the model list behind a tap for windows whose full breakdown is a wall of rows
    /// (the Last 30 Days spend tile). The header and a one-line total stay visible; tapping the
    /// button reveals the full per-model detail.
    var loadOnTap: Bool = false
    var onHoverChange: (Bool) -> Void

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @State private var revealed = false
    /// Other rows whose contributor lists are currently revealed. Kept per presentation (not
    /// persisted like the dashboard's per-provider carets): reopening a popover collapses again,
    /// so a quick value glance never has to wade past the long tail.
    @State private var expandedOthers: Set<String> = []

    private static let width: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if loadOnTap, !revealed {
                collapsedSummary
            } else {
                fullList
            }
            if let note = breakdown.sourceNote {
                PopoverSourceNote(text: note)
            }
        }
        .padding(14)
        .frame(width: Self.width)
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

    /// The Last 30 Days tile's resting state: the period's aggregate figures plus the deferred
    /// disclosure. Everything the popover is for is one tap away — it just isn't unfolded up front.
    private var collapsedSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(MetricFormatter.string(
                    for: MetricValue(
                        number: Double(breakdown.totalTokens),
                        kind: .count,
                        label: "tokens",
                        tokenCountSaturated: breakdown.tokenCountSaturated
                    ),
                    style: .row
                ))
                .monospacedDigit()
                Spacer(minLength: 8)
                if let cost = breakdown.totalCostUSD {
                    let incomplete = breakdown.models.contains { $0.hasIncompleteCost }
                    Text((incomplete ? "≥" : "") + MetricFormatter.number(cost, kind: .dollars, style: .row))
                        .monospacedDigit()
                }
            }
            .font(.system(size: density.supportingPointSize))
            .foregroundStyle(.secondary)

            Button("Show Model Breakdown") {
                revealed = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.system(size: density.supportingPointSize))
            .frame(maxWidth: .infinity)
        }
    }

    private var fullList: some View {
        let models = breakdown.models.flatMap { $0.presentedRows() }
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
            ForEach(models.indices, id: \.self) { index in
                modelRow(
                    models[index],
                    share: sharesAreReliable ? shares[index] : nil,
                    percent: sharesAreReliable ? percents[index] : nil
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

    /// Model name / cost on top, share percent / tokens beneath. The Other row adds a chevron next
    /// to its name that reveals its compact contributor list below; the percent line answers what
    /// the bar can't say precisely.
    private func modelRow(_ model: ModelUsageEntry, share: Double?, percent: Int?) -> some View {
        let contributors = Self.otherContributors(for: model)
        let isExpanded = expandedOthers.contains(model.model)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(model.model)
                        .font(.system(size: density.supportingPointSize, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !contributors.isEmpty {
                        otherExpandToggle(model, isExpanded: isExpanded)
                    }
                }
                Spacer(minLength: 8)
                if model.costUSD != nil {
                    HStack(spacing: 4) {
                        let cost = MetricFormatter.number(model.costUSD ?? 0, kind: .dollars, style: .row)
                        Text(model.hasIncompleteCost ? "≥\(cost)" : cost)
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                    }
                } else {
                    Text("\u{2014}")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: density.supportingPointSize))

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(percent.map { "\($0)%" } ?? "—")
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

            if !contributors.isEmpty && isExpanded {
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

    /// Chevron revealing an Other row's contributor list — the same idiom as the dashboard's
    /// per-provider caret (`WidgetGroupedListView.expandToggle`). Collapsed by default so the
    /// ranked list stays scannable; the chevron signals that the folded tail is one tap away.
    private func otherExpandToggle(_ model: ModelUsageEntry, isExpanded: Bool) -> some View {
        Button {
            withAnimation(Motion.spring) {
                if isExpanded {
                    expandedOthers.remove(model.model)
                } else {
                    expandedOthers.insert(model.model)
                }
            }
        } label: {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: density.supportingPointSize - 3, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Show less" : "Show more")
    }

    private func contributorRows(_ contributors: [ModelUsageVariant]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(contributors, id: \.model) { contributor in
                VStack(alignment: .leading, spacing: 1) {
                    Text(contributor.model)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(MetricFormatter.string(for: MetricValue(
                            number: Double(contributor.totalTokens), kind: .count, label: "tokens",
                            tokenCountSaturated: contributor.tokenCountSaturated
                        ), style: .row))
                        Spacer(minLength: 4)
                        if let cost = contributor.costUSD {
                            Text((contributor.hasIncompleteCost ? "≥" : "")
                                 + MetricFormatter.number(cost, kind: .dollars, style: .row))
                        } else {
                            Text("Unpriced")
                        }
                    }
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The collapsed row must still identify the models that contributed to it. Lead with token
    /// volume because a zero-cost model can dominate tokens while contributing no spend.
    static func otherContributors(for model: ModelUsageEntry) -> [ModelUsageVariant] {
        guard model.model.caseInsensitiveCompare(ModelUsageEntry.otherModelName) == .orderedSame,
              let variants = model.variants,
              !variants.isEmpty
        else { return [] }

        return variants.sorted { lhs, rhs in
            if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
            return lhs.model.localizedStandardCompare(rhs.model) == .orderedAscending
        }
    }

    /// Share against the sum of the listed models' own (display-rounded) figures, not the spend row's
    /// `totalCostUSD` — that total is rounded per day on a different path, so using it would let the
    /// percentages drift from the numbers printed right next to them.
    ///
    /// One basis for the whole list: cost shares only when every listed model is priced — otherwise a
    /// column mixing cost shares (priced rows) with token shares (unpriced rows) would sum past 100%.
    /// With any unpriced model present, every row falls back to its token share.
    static func shares(
        for models: [ModelUsageEntry],
        aggregateTokenCountSaturated: Bool = false
    ) -> [Double] {
        guard sharesAreReliable(for: models, aggregateTokenCountSaturated: aggregateTokenCountSaturated)
        else { return models.map { _ in 0 } }
        let allPriced = models.allSatisfy { $0.costUSD != nil && !$0.hasIncompleteCost }
        if allPriced {
            let costTotal = models.reduce(0.0) { $0 + ($1.costUSD ?? 0) }
            if costTotal.isFinite && costTotal > 0 {
                return models.map { model in
                    min(max((model.costUSD ?? 0) / costTotal, 0), 1)
                }
            }
        }
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
