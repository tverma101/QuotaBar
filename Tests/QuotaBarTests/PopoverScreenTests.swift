import XCTest
@testable import QuotaBar

/// The in-popover screen mode (dashboard / Customize / Settings) and its `isEditing` bridge,
/// which older call sites still drive Customize through.
@MainActor
final class PopoverScreenTests: XCTestCase {
    func testStartsOnDashboard() {
        let store = makeStore("Default")
        XCTAssertEqual(store.screen, .dashboard)
        XCTAssertFalse(store.isEditing)
    }

    func testIsEditingBridgesCustomizeScreen() {
        let store = makeStore("Bridge")

        store.isEditing = true
        XCTAssertEqual(store.screen, .customize)

        store.isEditing = false
        XCTAssertEqual(store.screen, .dashboard)
    }

    func testSettingsScreenIsNotEditing() {
        let store = makeStore("Settings")

        store.screen = .settings
        XCTAssertFalse(store.isEditing)
    }

    func testScreensReplaceEachOther() {
        let store = makeStore("Switch")

        store.screen = .customize
        store.screen = .settings
        XCTAssertEqual(store.screen, .settings)
        XCTAssertFalse(store.isEditing)

        store.screen = .customize
        XCTAssertTrue(store.isEditing)
    }


    func testOptionsMenuToggleTargetLeavesDashboardForCustomizeAndSettings() {
        XCTAssertEqual(
            MenuHostSafeNavigation.toggledScreen(current: .dashboard, requested: .customize),
            .customize
        )
        XCTAssertEqual(
            MenuHostSafeNavigation.toggledScreen(current: .dashboard, requested: .settings),
            .settings
        )
        XCTAssertEqual(
            MenuHostSafeNavigation.toggledScreen(current: .customize, requested: .customize),
            .dashboard,
            "requesting the current screen toggles back home"
        )
    }

    /// Options ▸ Customize/Settings must not mutate `layout.screen` on the menu-action stack — that
    /// unmounts the dashboard-only Menu host mid-dismiss. `afterMenuDismiss` schedules onto the next
    /// main turn so NSMenu can finish closing first (see HeaderView.toggle / WidgetGroupedListView).
    func testMenuHostSafeNavigationRunsAfterCurrentTurn() async {
        let exp = expectation(description: "deferred menu-host navigation")
        var ran = false
        MenuHostSafeNavigation.afterMenuDismiss {
            ran = true
            exp.fulfill()
        }
        XCTAssertFalse(ran, "menu-host navigation must not run synchronously on the action stack")
        await fulfillment(of: [exp], timeout: 1.0)
        XCTAssertTrue(ran)
    }


    /// Close-from-Customize must reset to dashboard without bumping `screenSlideID` — a normal
    /// `screen = .dashboard` assignment would start DashboardView's slide/height morph into a host
    /// that `hidePanel` is about to tear down to EmptyView.
    func testResetForPopoverCloseFromCustomizeDoesNotBumpSlideID() {
        let store = makeStore("CloseCustomize")
        store.screen = .customize
        let slideID = store.screenSlideID
        XCTAssertGreaterThan(slideID, 0)

        store.resetForPopoverClose()

        XCTAssertEqual(store.screen, .dashboard)
        XCTAssertNil(store.customizeProviderID)
        XCTAssertEqual(store.screenSlideID, slideID, "close reset must not start a screen-slide morph")
    }

    func testResetForPopoverCloseFromCustomizeL2ClearsDetailWithoutSlide() {
        let store = makeStore("CloseCustomizeL2")
        store.screen = .customize
        store.customizeProviderID = "claude"
        let slideID = store.screenSlideID

        store.resetForPopoverClose()

        XCTAssertEqual(store.screen, .dashboard)
        XCTAssertNil(store.customizeProviderID, "L2 detail must not survive popover close")
        XCTAssertEqual(store.screenSlideID, slideID)
    }

    func testResetForPopoverCloseFromSettingsDoesNotBumpSlideID() {
        let store = makeStore("CloseSettings")
        store.screen = .settings
        let slideID = store.screenSlideID

        store.resetForPopoverClose()

        XCTAssertEqual(store.screen, .dashboard)
        XCTAssertEqual(store.screenSlideID, slideID)
    }

    func testNormalScreenAssignToDashboardDoesBumpSlideID() {
        let store = makeStore("UserBackHome")
        store.screen = .customize
        let slideID = store.screenSlideID

        store.screen = .dashboard

        XCTAssertEqual(store.screen, .dashboard)
        XCTAssertEqual(store.screenSlideID, slideID + 1, "user navigation must still drive the slide")
        XCTAssertEqual(store.screenSlideFrom, .customize)
    }

    func testResetForPopoverCloseWhenAlreadyDashboardIsIdempotent() {
        let store = makeStore("CloseAlreadyHome")
        store.screen = .customize
        store.customizeProviderID = "codex"
        store.resetForPopoverClose()
        let slideID = store.screenSlideID

        store.customizeProviderID = "stale" // should not stick across a second close reset
        // Force a stranded detail while already on dashboard (shouldn't happen in UI, but close must clear).
        store.resetForPopoverClose()

        XCTAssertEqual(store.screen, .dashboard)
        XCTAssertNil(store.customizeProviderID)
        XCTAssertEqual(store.screenSlideID, slideID)
    }

    /// Status-item context menu → Settings must land on Settings without bumping `screenSlideID`,
    /// otherwise EmptyView remount starts `animatedSlideID` at 0 and the Settings overlay stays
    /// non-hit-testable inside a phantom slide (`allowsHitTesting(... && !isSliding)`).
    func testPresentWithoutSlideToSettingsDoesNotBumpSlideID() {
        let store = makeStore("ColdOpenSettings")
        store.screen = .customize
        let slideID = store.screenSlideID

        store.presentWithoutSlide(.settings)

        XCTAssertEqual(store.screen, .settings)
        XCTAssertFalse(store.isEditing)
        XCTAssertNil(store.customizeProviderID)
        XCTAssertEqual(store.screenSlideID, slideID, "cold-open present must not start a screen slide")
    }

    func testPresentWithoutSlideToCustomizeKeepsIdempotentL2() {
        let store = makeStore("ColdOpenCustomize")
        store.screen = .dashboard
        let slideID = store.screenSlideID

        store.presentWithoutSlide(.customize)
        XCTAssertEqual(store.screen, .customize)
        XCTAssertNil(store.customizeProviderID)
        XCTAssertEqual(store.screenSlideID, slideID)

        store.customizeProviderID = "claude"
        store.presentWithoutSlide(.customize)
        XCTAssertEqual(store.customizeProviderID, "claude", "idempotent present on customize keeps L2")
        XCTAssertEqual(store.screenSlideID, slideID)
    }

    func testPresentWithoutSlideLeavingCustomizeClearsL2() {
        let store = makeStore("ColdOpenLeavesL2")
        store.screen = .customize
        store.customizeProviderID = "codex"
        let slideID = store.screenSlideID

        store.presentWithoutSlide(.settings)

        XCTAssertEqual(store.screen, .settings)
        XCTAssertNil(store.customizeProviderID)
        XCTAssertEqual(store.screenSlideID, slideID)
    }

    /// EmptyView remount: store slide id is sticky, view starts at animatedSlideID 0 — adoption must
    /// clear the phantom transition so Settings hit-testing and the single-page pager recover.
    func testAdoptedSlideStateAfterRemountClearsPhantomTransition() {
        let adopted = DashboardView.adoptedSlideState(storeSlideID: 4, animatedSlideID: 0)
        XCTAssertEqual(adopted.animatedSlideID, 4)
        XCTAssertEqual(adopted.slideProgress, 1)
        XCTAssertFalse(
            DashboardView.screenTransitionIsActive(
                reduceAnimations: false,
                screenSlideID: 4,
                animatedSlideID: adopted.animatedSlideID,
                slideProgress: adopted.slideProgress
            ),
            "after remount adoption the pager must be at rest"
        )
    }

    func testAdoptedSlideStateWhenAlreadyInSyncStaysAtRest() {
        let adopted = DashboardView.adoptedSlideState(storeSlideID: 2, animatedSlideID: 2)
        XCTAssertEqual(adopted.animatedSlideID, 2)
        XCTAssertEqual(adopted.slideProgress, 1)
    }

    /// MenuHostSafeNavigation coverage for Options-adjacent deferred actions (About / Updates) —
    /// same deferral primitive as Customize/Settings toggles.
    func testMenuHostSafeNavigationDeferralIsReusableForNonNavigationActions() async {
        let exp = expectation(description: "deferred about/updates-style work")
        var order: [String] = []
        order.append("action-stack")
        MenuHostSafeNavigation.afterMenuDismiss {
            order.append("after-dismiss")
            exp.fulfill()
        }
        XCTAssertEqual(order, ["action-stack"])
        await fulfillment(of: [exp], timeout: 1.0)
        XCTAssertEqual(order, ["action-stack", "after-dismiss"])
    }

    private func makeStore(_ name: String) -> LayoutStore {
        let suiteName = "OpenUsageTests.PopoverScreen.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
    }
}
