import Foundation

/// Resolved, ordered, capped data for the menu-bar strip, built from the pinned metrics and their live
/// values. The renderers consume this: `groups` drives the Text style (one segment per pinned provider
/// or account; multiple Codex accounts share one provider mark, and a provider's session clocks share
/// one mark too),
/// `bars` drives the Bars style (the first four bounded metrics — any with a fill, not just percentages
/// — in order). `isEmpty` means render the plain app icon.
struct MenuBarContent: Equatable {
    /// One resolved pinned metric.
    struct Metric: Equatable {
        let id: String          // descriptor id
        /// The metric's full name, e.g. "Weekly". Used for accessibility, and never shortened —
        /// a screen reader announcing "Wk 12%" is worse than useless. The strip itself shows values
        /// only, read positionally.
        let label: String
        let value: String       // tray display: a "%" for bounded metrics, the raw value (e.g. "$5.23") for unbounded, or the no-data marker
        let fraction: Double     // 0...1 fill, meaningful for bounded metrics (drives the bars)
        let isBounded: Bool      // has a limit → has a fill, so it can render as a bar
        let hasData: Bool
    }

    /// A provider and its pinned metrics, in order. One segment of the Text strip.
    struct Group: Equatable, Identifiable {
        let id: String
        let providerID: String
        let displayName: String
        let icon: IconSource
        let metrics: [Metric]
        /// Multiple Codex accounts share one mark; each account keeps its own metric segment.
        var showsProviderIcon: Bool = true
        /// Session clocks keep the same small type as stacked usage values, even for one clock.
        var usesCompactValues: Bool = false

        init(
            id: String? = nil,
            providerID: String,
            displayName: String,
            icon: IconSource,
            metrics: [Metric],
            showsProviderIcon: Bool = true,
            usesCompactValues: Bool = false
        ) {
            self.id = id ?? providerID
            self.providerID = providerID
            self.displayName = displayName
            self.icon = icon
            self.metrics = metrics
            self.showsProviderIcon = showsProviderIcon
            self.usesCompactValues = usesCompactValues
        }
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
        snoozedProviderIDs: Set<String> = [],
        now: Date = Date(),
        data: (WidgetDescriptor) -> WidgetData
    ) -> MenuBarContent {
        var hasShownCodexIcon = false
        let resolvedGroups = groups.flatMap { group -> [MenuBarContent.Group] in
            guard !hiddenProviderIDs.contains(group.provider.id),
                  !snoozedProviderIDs.contains(group.provider.id) else { return [] }
            // A row can opt out of the strip while it has nothing worth showing — a session timer with
            // no session running drops out along with its provider's icon, so an idle provider costs
            // no menu-bar space at all.
            // A provider opting into session clocks contributes only those clocks, including when
            // older saved layouts still pin its wallet or daily allowance as well.
            let sessionMetrics = group.metrics.filter {
                if case .sessionCountdowns = $0.sample.trayStyle { return true }
                return false
            }
            if let descriptor = sessionMetrics.first {
                let sessionData = data(descriptor)
                let activeSessions = sessionData.activeSessions
                let sessionItems: [(Date, String?)]
                if !activeSessions.isEmpty {
                    sessionItems = activeSessions
                        .filter { $0.expiresAt > now }
                        .sorted { $0.expiresAt < $1.expiresAt }
                        .prefix(4)
                        .map { ($0.expiresAt, $0.chatTitle) }
                } else {
                    sessionItems = sessionData.traySessionExpiriesAt
                        .filter { $0 > now }
                        .sorted()
                        .prefix(4)
                        .map { ($0, nil) }
                }
                guard !sessionItems.isEmpty else { return [] }
                // Every live clock stays under one provider mark. A second mark for the third
                // session doubled the strip's width without adding information.
                let metrics = sessionItems.enumerated().map { index, item in
                    let (expiry, chatTitle) = item
                    let label: String
                    if let title = chatTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                        label = "Session \(index + 1) (\(title))"
                    } else {
                        label = "Session \(index + 1)"
                    }
                    return MenuBarContent.Metric(
                        id: "\(descriptor.id).session.\(index)",
                        label: label,
                        value: Formatters.compactDuration(expiry.timeIntervalSince(now)) ?? "<1m",
                        fraction: 0,
                        isBounded: false,
                        hasData: true
                    )
                }
                return [MenuBarContent.Group(
                    id: group.provider.id,
                    providerID: group.provider.id,
                    displayName: group.provider.displayName,
                    icon: group.provider.icon,
                    metrics: metrics,
                    showsProviderIcon: true,
                    usesCompactValues: true
                )]
            } else {
                let metrics = group.metrics.map { resolve($0, data($0), now: now) }.filter(\.hasData)
                guard !metrics.isEmpty else { return [] }
                let isCodexAccount = ProviderAccountID.family(of: group.provider.id) == "codex"
                let showsProviderIcon = !isCodexAccount || !hasShownCodexIcon
                if isCodexAccount { hasShownCodexIcon = true }
                return [MenuBarContent.Group(
                    id: group.provider.id,
                    providerID: group.provider.id,
                    displayName: group.provider.displayName,
                    icon: group.provider.icon,
                    metrics: metrics,
                    showsProviderIcon: showsProviderIcon,
                    usesCompactValues: false
                )]
            }
        }
        // Bars show any *bounded* metric (it has a fill), not just percentages. Unbounded values (raw
        // spend/credits, no limit) have no fill and are dropped.
        let bars = resolvedGroups
            .flatMap(\.metrics)
            .filter(\.isBounded)
            .prefix(maxBars)
        return MenuBarContent(groups: resolvedGroups, bars: Array(bars))
    }

    private static func resolve(
        _ descriptor: WidgetDescriptor,
        _ data: WidgetData,
        now: Date
    ) -> MenuBarContent.Metric {
        MenuBarContent.Metric(
            id: descriptor.id,
            label: descriptor.metricLabel,
            value: data.menuBarValue,
            fraction: data.fraction,
            isBounded: data.isBounded,
            hasData: data.showsInMenuBar(now: now)
                && !(["claude", "antigravity"].contains(ProviderAccountID.family(of: descriptor.providerID))
                    && data.isBounded
                    && data.resetsAt.map { now.timeIntervalSince($0) > 5 * 60 } == true)
        )
    }
}
