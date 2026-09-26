import Observation

/// The screen showing inside the menu-bar popover. Customize and Settings replace the dashboard
/// in place (the popover has no window stack); Esc backs out to the dashboard first.
enum PopoverScreen: Hashable, Sendable {
    case dashboard
    case customize
    case settings

    /// Left-to-right order for the popover's horizontal screen-switch slide: the dashboard is home on
    /// the left, with Customize and Settings to its right. The slide reads its direction from these
    /// ranks — a higher-ranked target enters from the trailing edge, a lower one from the leading edge.
    var slideRank: Int {
        switch self {
        case .dashboard: 0
        case .customize: 1
        case .settings: 2
        }
    }
}

/// In-popover navigation: which screen is showing, the master/detail route inside Customize, and the
/// horizontal screen-switch slide bookkeeping. Split out of `LayoutStore` (which owns the *layout* —
/// enabled widgets, order, pins) so screen routing is its own concern; `LayoutStore` forwards its
/// existing `screen`/`isEditing`/`customizeProviderID`/`screenSlide*` surface to this store, so callers
/// are unchanged.
@MainActor
@Observable
final class PopoverNavigationStore {
    /// Which in-popover screen is showing. Drives the footer buttons, the Esc handler, and the
    /// popover-closed reset alike.
    var screen = PopoverScreen.dashboard {
        didSet {
            guard screen != oldValue else { return }
            // Close-path reset and cold-open presentation must not start a slide/morph — EmptyView
            // remounts DashboardView with `animatedSlideID = 0`, so a bumped `screenSlideID` would look
            // like an in-flight transition forever (blank/frozen pager, Settings hit-testing off).
            if !suppressSlideBookkeeping {
                // Recorded synchronously with the change — not via SwiftUI's `onChange`, which fires a
                // frame later and would let the popover paint the destination before the slide begins.
                // DashboardView reads these on its very next render to slide in from the screen being left.
                screenSlideFrom = oldValue
                screenSlideID += 1
            }
            // Leaving Customize drops the L2 detail selection so reopening Customize shows the list,
            // never a stranded detail screen. `resetForPopoverClose` also clears it explicitly.
            if screen != .customize { customizeProviderID = nil }
        }
    }
    /// Supports DashboardView's horizontal screen-switch slide: the screen being left, plus a counter
    /// that ticks on every switch so the view can detect and animate each transition. UI-only; not persisted.
    private(set) var screenSlideFrom = PopoverScreen.dashboard
    private(set) var screenSlideID = 0
    /// Whether the Customize screen is showing — a bridge over `screen` for the many call sites that
    /// think in terms of edit mode.
    var isEditing: Bool {
        get { screen == .customize }
        set { screen = newValue ? .customize : .dashboard }
    }
    /// The provider whose Customize detail (L2) is showing. nil shows the provider list (L1); a set id
    /// shows that provider's metric sections and API key. UI-only (not persisted): cleared when leaving
    /// Customize (see `screen`'s didSet) and on popover close.
    var customizeProviderID: String?

    /// Popover-close reset: return to the dashboard and clear Customize L2 **without** bumping
    /// `screenSlideID` / `screenSlideFrom`. Assigning `screen = .dashboard` goes through `didSet` and
    /// starts DashboardView's slide/height morph — disastrous while `hidePanel` is about to swap the
    /// host to `EmptyView` (the close-from-Customize glitch). Call this from close paths instead.
    func resetForPopoverClose() {
        customizeProviderID = nil
        guard screen != .dashboard else { return }
        assignScreenWithoutSlide(.dashboard)
    }

    /// Set the in-popover screen **without** bumping `screenSlideID` — for cold opens that must land
    /// on Settings/Customize already sized correctly (status-item context menu → Settings) before a
    /// fresh DashboardView mounts. A normal `screen =` assignment would leave `screenSlideID` ahead of
    /// the remounted view's `animatedSlideID == 0` and stick the pager in a phantom transition.
    func presentWithoutSlide(_ newScreen: PopoverScreen) {
        if newScreen != .customize {
            customizeProviderID = nil
        }
        guard screen != newScreen else { return }
        assignScreenWithoutSlide(newScreen)
    }

    private func assignScreenWithoutSlide(_ newScreen: PopoverScreen) {
        suppressSlideBookkeeping = true
        screen = newScreen
        suppressSlideBookkeeping = false
    }

    /// True only while a silent assign writes `screen`, so didSet skips slide bookkeeping.
    private var suppressSlideBookkeeping = false
}
