import Foundation

/// Defers work that would unmount a SwiftUI `Menu` / `contextMenu` host until after AppKit finishes
/// dismissing the menu window.
///
/// Options (and dashboard context menus) live only on `.dashboard`. Changing `layout.screen` from a
/// menu action synchronously tears that host down while `NSMenu` is still closing — a classic SwiftUI
/// + AppKit failure mode that blanks, freezes, or sticks the popover morph. Scheduling onto the next
/// main-queue turn lets the menu dismiss first, then runs the navigation safely.
enum MenuHostSafeNavigation {
    @MainActor
    static func afterMenuDismiss(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async(execute: work)
    }

    /// Toggle target used by the Options menu: requesting the current screen returns to dashboard.
    static func toggledScreen(current: PopoverScreen, requested: PopoverScreen) -> PopoverScreen {
        current == requested ? .dashboard : requested
    }
}
