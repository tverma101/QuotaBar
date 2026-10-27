import Foundation

/// Resolved, ordered, capped data for the menu-bar strip, built from the pinned metrics and their live
/// values. The renderers consume this: `groups` drives the Text style (one segment per pinned provider,
/// each with its 1–2 pinned metrics), `bars` drives the Bars style (the first four bounded metrics — any
/// with a fill, not just percentages — in order). `isEmpty` means render the plain app icon.
struct MenuBarContent: Equatable {
    /// One resolved pinned metric.
    struct Metric: Equatable {
        let id: String          // descriptor id
        /// The metric's full name, e.g. "Weekly". Used for accessibility and anywhere the strip has
        /// room; never shortened, because a screen reader announcing "Wk 12%" is worse than useless.
        let label: String
        /// Strip-only abbreviation of `label` (e.g. "Wk"), drawn beside the value in a stacked pair
        /// where width is scarce. Falls back to `label` for names that need no shortening.
        let trayLabel: String
        let value: String       // tray display: a "%" for bounded metrics, the raw value (e.g. "$5.23") for unbounded, or the no-data marker
        let fraction: Double     // 0...1 fill, meaningful for bounded metrics (drives the bars)
        let isBounded: Bool      // has a limit → has a fill, so it can render as a bar
        let hasData: Bool

        /// `trayLabel` defaults to the full `label`, so a caller that has no abbreviation to offer
        /// (tests, fixtures, simple descriptors) cannot accidentally ship an empty or mismatched
        /// strip label.
        init(
            id: String,
            label: String,
            trayLabel: String? = nil,
            value: String,
            fraction: Double,
            isBounded: Bool,
            hasData: Bool
        ) {
            self.id = id
            self.label = label
            self.trayLabel = trayLabel ?? label
            self.value = value
            self.fraction = fraction
            self.isBounded = isBounded
            self.hasData = hasData
        }
    }

    /// A provider and its pinned metrics, in order. One segment of the Text strip.
    struct Group: Equatable {
        let providerID: String
        let displayName: String
        let icon: IconSource
        let metrics: [Metric]
    }

    /// Provider groups for the Text style, in Customize order. Dynamic: only metrics that currently
    /// have real data appear, and a provider whose pinned metrics all lack data drops out entirely
    /// (no orphan icon) — so the strip never renders "—" placeholders.
    let groups: [Group]
    /// Bounded metrics (those with a fill) for the Bars style, flattened in order and capped to four.
    let bars: [Metric]

    /// Nothing is pinned, every pinned provider is disabled, or no pinned metric has data yet — the
    /// menu bar falls back to the app icon.
    var isEmpty: Bool { groups.isEmpty }

    /// VoiceOver summary for the rendered strip image, e.g.
    /// "Claude Session 41%, Weekly 12%; Cursor Credits $12".
    var accessibilityText: String {
        groups.map { group in
            let metrics = group.metrics.map { "\($0.label) \($0.value)" }.joined(separator: ", ")
            return "\(group.displayName) \(metrics)"
        }
        .joined(separator: "; ")
    }
}

@MainActor
enum MenuBarContentBuilder {
    /// Max bars the compact style renders (matches the original OpenUsage tray).
    static let maxBars = 4

    /// Resolve pinned provider groups into menu-bar content. `groups` is `LayoutStore.pinnedGroups`
    /// (already ordered, disabled providers excluded); `data` resolves each descriptor to its live
    /// `WidgetData` (i.e. `WidgetDataStore.data(for:)`), so the values follow the global meter style
    /// just like the dashboard tiles.
    ///
    /// The strip is dynamic: a pinned metric without data is dropped (one of two pins renders alone at
    /// full size), and a provider with no data-carrying pins contributes no icon at all. Pins are
    /// membership; the strip shows whatever subset is real right now.
    static func build(
        groups: [ProviderMetrics],
        hiddenProviderIDs: Set<String> = [],
        data: (WidgetDescriptor) -> WidgetData
    ) -> MenuBarContent {
        let resolvedGroups = groups.compactMap { group -> MenuBarContent.Group? in
            guard !hiddenProviderIDs.contains(group.provider.id) else { return nil }
            let metrics = group.metrics.map { resolve($0, data($0)) }.filter(\.hasData)
            guard !metrics.isEmpty else { return nil }
            return MenuBarContent.Group(
                providerID: group.provider.id,
                displayName: group.provider.displayName,
                icon: group.provider.icon,
                metrics: metrics
            )
        }
        // Bars show any *bounded* metric (it has a fill), not just percentages. Unbounded values (raw
        // spend/credits, no limit) have no fill and are dropped.
        let bars = resolvedGroups
            .flatMap(\.metrics)
            .filter(\.isBounded)
            .prefix(maxBars)
        return MenuBarContent(groups: resolvedGroups, bars: Array(bars))
    }

    private static func resolve(_ descriptor: WidgetDescriptor, _ data: WidgetData) -> MenuBarContent.Metric {
        MenuBarContent.Metric(
            id: descriptor.id,
            label: descriptor.metricLabel,
            trayLabel: trayLabel(descriptor.metricLabel),
            value: data.menuBarValue,
            fraction: data.fraction,
            isBounded: data.isBounded,
            hasData: data.hasData
        )
    }

    /// Tray-only label shortening (the dashboard keeps the full names). A stacked pair of metrics puts
    /// these beside each value, so each has to stay to a few characters while still distinguishing the
    /// windows. Long spend windows collapse to one letter; Freebuff's hour budgets shorten to their
    /// window name; anything unrecognized passes through unchanged.
    private static func trayLabel(_ metricLabel: String) -> String {
        switch metricLabel.lowercased() {
        case "today": return "T"
        case "yesterday": return "Y"
        case "last 30 days": return "M"
        case "daily hours": return "Day"
        case "hours balance": return "Bal"
        case "weekly": return "Wk"
        case "5-day": return "5d"
        case "monthly": return "Mo"
        case "session pool": return "Pool"
        case "premium sessions": return "Prem"
        case "free premium sessions": return "Free"
        default: return metricLabel
        }
    }
}
