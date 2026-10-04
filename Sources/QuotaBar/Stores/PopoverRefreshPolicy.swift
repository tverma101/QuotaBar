/// The provider refresh a popover interaction is allowed to run.
///
/// Opening the dashboard used to force a full, uncached provider batch. That fanned out across every
/// enabled provider's local accounting (JSONL/CSV scans, pricing, subprocesses) while SwiftUI was
/// still mounting the panel, so an ordinary menu-bar tap could drive the app across a core. A tap now
/// presents the snapshot the store already holds: `AppContainer`'s periodic loop owns freshness, and
/// the user's explicit Refresh Now stays the only forced path.
enum PopoverRefreshPolicy {
    enum Trigger: Equatable, Sendable {
        /// The dashboard was presented: menu-bar tap, global shortcut, or a tapped notification.
        case panelPresentation
        /// The user asked for a full refresh (footer countdown / command-R, or a provider's action).
        case manualRefresh
    }

    enum Decision: Equatable, Sendable {
        /// Paint the current snapshot; start no provider work.
        case presentSnapshot
        /// Run a full-scope refresh that bypasses the snapshot cache.
        case forceFullRefresh
    }

    static func decision(for trigger: Trigger) -> Decision {
        switch trigger {
        case .panelPresentation: .presentSnapshot
        case .manualRefresh: .forceFullRefresh
        }
    }
}
