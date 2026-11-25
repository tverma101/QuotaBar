import Foundation

/// Keeps provider identity and actionable status visible even when every optional metric row is empty.
enum ProviderSectionVisibility {
    /// A collapsed card with no visible main rows still needs a caret if it has an available
    /// On Demand metric. In that case, stop as soon as one eligible row is found.
    static func resolveMetrics<Row>(
        always: [PlacedWidget],
        onDemand: [PlacedWidget],
        isExpanded: Bool,
        resolve: (PlacedWidget) -> Row?
    ) -> (always: [Row], expanded: [Row], hasVisibleMetric: Bool) {
        let alwaysRows = always.compactMap(resolve)
        let expandedRows = isExpanded ? onDemand.compactMap(resolve) : []
        let hasVisibleMetric = !alwaysRows.isEmpty || !expandedRows.isEmpty
            || (!isExpanded && onDemand.contains { resolve($0) != nil })
        return (alwaysRows, expandedRows, hasVisibleMetric)
    }

    static func shouldRenderMetricRow(
        providerID: String,
        descriptorID: String,
        hasData: Bool,
        errorCategory: ErrorCategory?,
        explicitlyEnabled: Bool
    ) -> Bool {
        guard providerID == "zai" else { return true }
        return shouldRenderZAIQuotaRow(
            descriptorID: descriptorID,
            hasData: hasData,
            errorCategory: errorCategory,
            explicitlyEnabled: explicitlyEnabled
        )
    }

    static func shouldRenderZAIQuotaRow(
        descriptorID: String,
        hasData: Bool,
        errorCategory: ErrorCategory?,
        explicitlyEnabled: Bool
    ) -> Bool {
        let isCoreQuotaRow = descriptorID == "zai.session" || descriptorID == "zai.weekly"
        guard isCoreQuotaRow, !hasData, (errorCategory == .notAvailable || errorCategory == .notLoggedIn) else { return true }
        return explicitlyEnabled
    }

    static func shouldRender(
        hasVisibleMetric: Bool,
        hasPlan: Bool,
        hasNotice: Bool,
        isRefreshing: Bool,
        hasStaleness: Bool
    ) -> Bool {
        hasVisibleMetric || hasPlan || hasNotice || isRefreshing || hasStaleness
    }
}
