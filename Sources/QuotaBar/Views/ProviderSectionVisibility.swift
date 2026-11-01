import Foundation

/// Keeps provider identity and actionable status visible even when every optional metric row is empty.
enum ProviderSectionVisibility {
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
        guard isCoreQuotaRow, !hasData, errorCategory == .notAvailable else { return true }
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
