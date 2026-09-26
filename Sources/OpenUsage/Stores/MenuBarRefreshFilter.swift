import Foundation

/// Decides which enabled providers a `.menuBar` background pass should actually refresh.
///
/// The status-item strip only shows pinned meters. Quota notifications (when any trigger is on)
/// additionally need fresh bounded meters for every visible layout row they evaluate. Everything
/// else can wait for a `.full` pass (panel open / manual refresh).
enum MenuBarRefreshFilter {
    /// Returns the subset of `enabledProviderIDs` that a menu-bar pass should refresh, preserving
    /// the incoming order. An empty result means the pass can no-op (empty pin strip and nothing
    /// notification-relevant).
    static func providerIDs(
        enabledProviderIDs: [String],
        pinnedMetricIDs: Set<String>,
        providerIDForMetric: (String) -> String?,
        notificationRelevantProviderIDs: Set<String>,
        notificationsEnabled: Bool
    ) -> [String] {
        var needed = Set(pinnedMetricIDs.compactMap(providerIDForMetric))
        if notificationsEnabled {
            needed.formUnion(notificationRelevantProviderIDs)
        }
        guard !needed.isEmpty else { return [] }
        return enabledProviderIDs.filter { needed.contains($0) }
    }

    /// Providers that carry at least one visible, bounded metric — the same population
    /// `WidgetDataStore.evaluateNotifications` walks when toggles are on.
    static func notificationRelevantProviderIDs(
        descriptors: [WidgetDescriptor]
    ) -> Set<String> {
        Set(descriptors.compactMap { descriptor in
            descriptor.sample.isBounded ? descriptor.providerID : nil
        })
    }

    /// Prefer pinned (and otherwise notification-visible) providers first so a panel-open full
    /// refresh paints the strip / top cards sooner.
    static func prioritize(
        providerIDs: [String],
        pinnedMetricIDs: Set<String>,
        providerIDForMetric: (String) -> String?,
        notificationRelevantProviderIDs: Set<String> = [],
        notificationsEnabled: Bool = false
    ) -> [String] {
        var priority = Set(pinnedMetricIDs.compactMap(providerIDForMetric))
        if notificationsEnabled {
            priority.formUnion(notificationRelevantProviderIDs)
        }
        guard !priority.isEmpty else { return providerIDs }
        let head = providerIDs.filter { priority.contains($0) }
        let tail = providerIDs.filter { !priority.contains($0) }
        return head + tail
    }
}
