import SwiftUI

/// The Usage History screen: measured tokens and provider-reported charges or a separate API-rate
/// estimate view, built from the same per-provider histories the dashboard's spend tiles render.
struct HistoryDashboardView: View {
    var now: () -> Date = Date.init
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var costMode: HistoryCostMode = .reportedOnly

    var body: some View {
        PopoverScrollView {
            content
        }
        .scrollPosition($scrollPosition)
        .onChange(of: layout.screen) { _, screen in
            if screen == .history { scrollPosition.scrollTo(edge: .top) }
        }
    }

    // MARK: - Report

    /// Projects the enabled providers' cached histories onto the selected cost source.
    private var report: HistoryReport {
        let enabledIDs = layout.orderedProviderIDs().filter { layout.isProviderEnabled($0) }
        var names: [String: String] = [:]
        var histories: [String: ProviderUsageHistory] = [:]
        for id in enabledIDs {
            names[id] = layout.provider(id: id)?.displayName ?? id
            histories[id] = dataStore.snapshots[id]?.usageHistory
        }
        return HistoryDashboardAggregator.report(
            .init(
                enabledProviderIDs: enabledIDs,
                displayNameByProviderID: names,
                historyByProviderID: histories
            ),
            costMode: costMode,
            now: now()
        )
    }

    @ViewBuilder
    private var content: some View {
        let report = report
        VStack(alignment: .leading, spacing: density.sectionSpacing) {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Cost Source", selection: $costMode) {
                    ForEach(HistoryCostMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Cost Source")
                Text(costMode == .reportedOnly
                     ? "Only dollar amounts recorded by providers. Missing costs are not estimated."
                     : "What the measured tokens would cost at published API rates, not a bill.")
                    .font(.system(size: density.supportingPointSize - 1))
                    .foregroundStyle(.secondary)
            }
            if report.isEmpty {
                emptyState
            } else {
                lifetimeHeroCard(report)
                periodCard(report)
                trendCard(report)
                ForEach(report.sections) { section in
                    providerSection(section)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.tertiary)
            Text("No Local Usage In The Last 30 Days")
                .font(.system(size: density.headerPointSize, weight: .semibold))
                .foregroundStyle(.primary)
            Text("Usage appears after your tools log activity while QuotaBar is running.")
                .font(.system(size: density.supportingPointSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .cardSurface()
    }

    // MARK: - Lifetime hero

    /// The selected dollar source for every recorded day's measured tokens, dated by the earliest day
    /// the logs still hold.
    private func lifetimeHeroCard(_ report: HistoryReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Lifetime")
                    .font(.system(size: density.headerPointSize, weight: .semibold))
                    .foregroundStyle(.primary)
                if report.lifetimeCostIsEstimated {
                    Text("Est.")
                        .font(.system(size: density.supportingPointSize - 1, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let since = report.lifetimeSinceLabel {
                    Text("Since \(since)")
                        .font(.system(size: density.supportingPointSize - 1))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(costText(report.lifetime.cost, isPartial: report.lifetime.hasIncompleteCost, style: .row))
                    .font(.system(size: density.headerPointSize + 6, weight: .bold))
                    .monospacedDigit()
                Spacer(minLength: 8)
                Text(MetricFormatter.string(for: MetricValue(
                    number: Double(report.lifetime.tokens),
                    kind: .count,
                    label: "tokens",
                    tokenCountSaturated: report.lifetime.tokenCountSaturated
                ), style: .row))
                    .font(.system(size: density.supportingPointSize))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(14)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }

    // MARK: - Period totals

    /// Today / 7 Days / 30 Days: tokens always, with the selected cost source or a dash.
    private func periodCard(_ report: HistoryReport) -> some View {
        HStack(alignment: .top, spacing: 0) {
            periodColumn("Today", total: report.today)
            periodColumn("7 Days", total: report.last7)
            periodColumn("30 Days", total: report.last30)
        }
        .cardSurface()
    }

    private func periodColumn(_ title: String, total: HistoryPeriodTotal) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title)
                    .font(.system(size: density.supportingPointSize - 1, weight: .medium))
                    .foregroundStyle(.secondary)
                if total.hasEstimatedCost {
                    Text("Est.")
                        .font(.system(size: density.supportingPointSize - 2, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            Text(costText(total.cost, isPartial: total.hasIncompleteCost, style: .row))
                .font(.system(size: density.headerPointSize, weight: .semibold))
                .monospacedDigit()
            Text(MetricFormatter.string(for: MetricValue(
                number: Double(total.tokens),
                kind: .count,
                label: "tokens",
                tokenCountSaturated: total.tokenCountSaturated
            ), style: .row))
                .font(.system(size: density.supportingPointSize - 1))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    // MARK: - Trend

    /// 30 vertical bars, one per day of the window, heights proportional to the day's tokens —
    /// the sparkline's visual language stretched to the full window.
    private func trendCard(_ report: HistoryReport) -> some View {
        let peak = report.days.map(\.tokens).max() ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Daily Tokens")
                    .font(.system(size: density.supportingPointSize, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if let first = report.days.first, let last = report.days.last {
                    Text("\(first.label) – \(last.label)")
                        .font(.system(size: density.supportingPointSize - 2))
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(report.days) { day in
                    let tokenReadout = MetricFormatter.string(for: MetricValue(
                        number: Double(day.tokens),
                        kind: .count,
                        label: "tokens",
                        tokenCountSaturated: day.tokenCountSaturated
                    ), style: .row)
                    let partialNote = day.hasIncompleteCost ? ", partial" : ""
                    Capsule()
                        .fill(day.tokens > 0 ? AnyShapeStyle(Theme.meterFill(.normal)) : AnyShapeStyle(.quaternary))
                        .frame(height: Self.barHeight(tokens: day.tokens, peak: peak))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("\(day.label): \(tokenReadout)\(partialNote)")
                }
            }
            .frame(height: 36)
        }
        .padding(12)
        .cardSurface()
    }

    private static func barHeight(tokens: Int, peak: Int) -> CGFloat {
        guard peak > 0 else { return 2 }
        return tokens > 0 ? max(3, 36 * CGFloat(tokens) / CGFloat(peak)) : 2
    }

    // MARK: - Provider sections

    private func providerSection(_ section: HistoryProviderSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                AccountNameText(
                    text: section.displayName,
                    font: .system(size: density.headerPointSize, weight: .semibold),
                    foregroundStyle: AnyShapeStyle(.primary)
                )
                Spacer(minLength: 8)
                Text(MetricFormatter.string(for: MetricValue(
                    number: Double(section.tokens),
                    kind: .count,
                    label: "tokens",
                    tokenCountSaturated: section.tokenCountSaturated
                ), style: .row))
                    .font(.system(size: density.supportingPointSize - 1))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if section.hasEstimatedCost {
                        Text("Est.")
                            .font(.system(size: density.supportingPointSize - 2, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                    Text(costText(section.cost, isPartial: section.hasIncompleteCost, style: .row))
                        .font(.system(size: density.supportingPointSize, weight: .semibold))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if section.hasIncompleteCost {
                Text(costMode == .reportedOnly
                     ? "Some usage has no recorded dollar amount."
                     : "Some usage is still changing or could not be priced completely.")
                    .font(.system(size: density.supportingPointSize - 1))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }

            ForEach(section.rows) { row in
                modelRow(row)
            }
        }
        .cardSurface()
    }

    /// One model: name on top, tokens beneath, the selected cost source (or dash) trailing.
    private func modelRow(_ row: HistoryModelRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.slug)
                    .font(.system(size: density.supportingPointSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(costText(row.cost, isPartial: row.hasIncompleteCost, style: .row))
                    .foregroundStyle(row.cost == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .monospacedDigit()
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Spacer(minLength: 8)
                Text(MetricFormatter.string(for: MetricValue(
                    number: Double(row.tokens),
                    kind: .count,
                    label: "tokens",
                    tokenCountSaturated: row.tokenCountSaturated
                ), style: .row))
                    .font(.system(size: density.supportingPointSize - 1))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.textRowPadding)
        .accessibilityElement(children: .combine)
    }

    private func costText(_ cost: Double?, isPartial: Bool, style: MetricFormatter.Style) -> String {
        guard let cost else { return "\u{2014}" }
        let value = MetricFormatter.number(cost, kind: .dollars, style: style)
        return isPartial ? "≥\(value)" : value
    }
}
