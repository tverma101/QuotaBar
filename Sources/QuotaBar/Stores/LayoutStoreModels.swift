/// A provider and its placed (visible) widgets, split into Always Visible rows and On Demand rows
/// behind the dashboard's caret. Drives the grouped dashboard list.
struct ProviderGroup: Identifiable {
    let provider: Provider
    let alwaysShownWidgets: [PlacedWidget]
    let expandedWidgets: [PlacedWidget]
    var id: String { provider.id }

    /// Every visible widget in display order (always-shown first, then expanded). Used where the split
    /// doesn't matter — reorder id lists and the lifted drag preview.
    var widgets: [PlacedWidget] { alwaysShownWidgets + expandedWidgets }
    var hasExpandedMetrics: Bool { !expandedWidgets.isEmpty }

    /// The rows of this group that survive a visibility filter, keeping the always-shown/expanded split.
    ///
    /// Exists because "does this provider have anything left to show?" cannot be answered from
    /// `alwaysShownWidgets`/`expandedWidgets` alone. `displayGroups` drops a provider only when it has no
    /// *placed* widgets, and that check runs before the `hidesWhenEmpty` presentation filter — so a
    /// provider whose last non-conditional row was switched off in Customize still produced a group, and
    /// the dashboard then rendered it as an empty rounded card, or as a lone caret above nothing when the
    /// provider had On Demand content. This is where the post-filter emptiness becomes observable, so the
    /// dashboard and the share-card export can both ask the same question.
    func visibleRows(
        keeping rowIsVisible: (PlacedWidget) -> Bool
    ) -> (alwaysShown: [PlacedWidget], expanded: [PlacedWidget]) {
        (
            alwaysShownWidgets.filter(rowIsVisible),
            expandedWidgets.filter(rowIsVisible)
        )
    }

    /// Whether any row survives `keeping`. A group with no visible row has nothing to render, so callers
    /// should omit it entirely rather than draw the card chrome.
    func hasVisibleRow(keeping rowIsVisible: (PlacedWidget) -> Bool) -> Bool {
        alwaysShownWidgets.contains(where: rowIsVisible) || expandedWidgets.contains(where: rowIsVisible)
    }
}

/// A provider and every metric it supports, in the provider's custom order, split between Always
/// Visible and On Demand. Drives the Customize screen and the menu-bar pin grouping.
struct ProviderMetrics: Identifiable {
    let provider: Provider
    let alwaysShownMetrics: [WidgetDescriptor]
    let expandedMetrics: [WidgetDescriptor]
    var id: String { provider.id }

    init(provider: Provider, alwaysShownMetrics: [WidgetDescriptor], expandedMetrics: [WidgetDescriptor]) {
        self.provider = provider
        self.alwaysShownMetrics = alwaysShownMetrics
        self.expandedMetrics = expandedMetrics
    }

    /// Convenience for callers that don't partition (e.g. tests): everything is always-shown.
    init(provider: Provider, metrics: [WidgetDescriptor]) {
        self.init(provider: provider, alwaysShownMetrics: metrics, expandedMetrics: [])
    }

    /// Every supported metric in custom order (always-shown first, then expanded).
    var metrics: [WidgetDescriptor] { alwaysShownMetrics + expandedMetrics }
}

/// One row in the Customize provider list (L1): the provider plus the derived bits the row renders —
/// whether it's enabled (the master toggle + Active/Inactive label), how many metrics it supports
/// (the badge), and how many are pinned. Drives `CustomizeProviderListView`. Unlike `ProviderMetrics`,
/// this includes disabled providers so they stay visible in the list.
struct ProviderRow: Identifiable {
    let provider: Provider
    let isEnabled: Bool
    let metricCount: Int
    var id: String { provider.id }
}

/// Tone for the transient in-Customize pill (`LayoutStore.customizationNotice`): green success or
/// orange denial.
enum CustomizationNoticeTone {
    case positive
    case notice
}

/// The message + tone carried by the Customize pill's `TransientNotice`, so its two fields clear together.
struct CustomizationNoticeContent {
    var message: String
    var tone: CustomizationNoticeTone
}
