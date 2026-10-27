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
    ///
    /// `hiddenProviderIDs` are providers the user removed from the strip ("Show in menu bar" off).
    /// The strip cannot paint them, so a closed-panel pass has nothing to update on their behalf: a
    /// pin they still carry is invisible, and refreshing them every tick burned network, CPU, and
    /// Keychain probes for a value nobody sees. Their metrics come back the moment the provider is
    /// shown again, because a full pass (panel open) refreshes every enabled provider.
    static func providerIDs(
        enabledProviderIDs: [String],
        pinnedMetricIDs: Set<String>,
        providerIDForMetric: (String) -> String?,
        notificationRelevantProviderIDs: Set<String>,
        notificationsEnabled: Bool,
        hiddenProviderIDs: Set<String> = []
    ) -> [String] {
        var needed = Set(
            pinnedMetricIDs
                .compactMap(providerIDForMetric)
                .filter { !hiddenProviderIDs.contains($0) }
        )
        if notificationsEnabled {
            // Notifications read the layout, not the strip, so a hidden provider still needs fresh
            // meters to alert on.
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

    /// Decides whether a ledger append can produce any visible change while the panel is closed.
    ///
    /// When the panel is closed, only pinned metrics are visible to the user. Quota meters
    /// (Session, Weekly, Spark) are API-driven, so ledger appends do not affect them.
    /// Only pinned spend tiles (Codex unbounded/usagePeriod metrics) or OpenCode metrics
    /// (which can fold router events) require a ledger-driven fold while closed.
    static func closedPanelLedgerWakeAffectsVisibleMetrics(
        pinnedMetricIDs: Set<String>,
        descriptorForMetric: (String) -> WidgetDescriptor?
    ) -> Bool {
        for id in pinnedMetricIDs {
            guard let descriptor = descriptorForMetric(id) else { continue }
            let family = ProviderAccountID.family(of: descriptor.providerID)
            if family == "opencode" {
                return true
            }
            if family == "codex" && (!descriptor.sample.isBounded || descriptor.sample.isUsagePeriod) {
                return true
            }
        }
        return false
    }
}
