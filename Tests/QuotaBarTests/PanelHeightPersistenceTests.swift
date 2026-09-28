import AppKit
import XCTest
@testable import QuotaBar

/// Close→open height memory: Customize/Settings height must not stick as the next dashboard open guess.
@MainActor
final class PanelHeightPersistenceTests: XCTestCase {
    func testHeightDefaultsKeysAreStablePerScreen() {
        XCTAssertEqual(
            PanelHeightController.heightDefaultsKey(for: .dashboard),
            "openusage.panel.height.dashboard"
        )
        XCTAssertEqual(
            PanelHeightController.heightDefaultsKey(for: .customize),
            "openusage.panel.height.customize"
        )
        XCTAssertEqual(
            PanelHeightController.heightDefaultsKey(for: .settings),
            "openusage.panel.height.settings"
        )
    }

    /// saveBeforeClosing(customize) → resetForPopoverClose → prepareForOpening must load the
    /// **dashboard** remembered height, not the Customize morph height left on the panel.
    func testReopenAfterCustomizeUsesDashboardRememberedHeightNotCustomize() {
        let suiteName = "OpenUsageTests.PanelHeightPersistence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(520.0, forKey: PanelHeightController.heightDefaultsKey(for: .dashboard))
        defaults.set(780.0, forKey: PanelHeightController.heightDefaultsKey(for: .customize))

        let layoutDefaultsSuite = "OpenUsageTests.PanelHeightPersistence.Layout.\(UUID().uuidString)"
        let layoutDefaults = UserDefaults(suiteName: layoutDefaultsSuite)!
        layoutDefaults.removePersistentDomain(forName: layoutDefaultsSuite)
        defer { layoutDefaults.removePersistentDomain(forName: layoutDefaultsSuite) }
        let layout = LayoutStore(registry: .mock, defaults: layoutDefaults, storageKey: "layout")

        let panel = MenuBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: PanelHeightController.panelWidth, height: 780),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        let controller = PanelHeightController(panel: panel, defaults: defaults) { layout.screen }

        layout.screen = .customize
        // saveBeforeClosing only records while visible — mirror a live Customize panel.
        panel.setFrame(
            NSRect(x: 80, y: 200, width: PanelHeightController.panelWidth, height: 780),
            display: false
        )
        panel.orderFront(nil)
        XCTAssertTrue(panel.isVisible)

        controller.saveBeforeClosing()
        XCTAssertEqual(
            defaults.double(forKey: PanelHeightController.heightDefaultsKey(for: .customize)),
            780.0,
            accuracy: 0.5
        )

        layout.resetForPopoverClose()
        XCTAssertEqual(layout.screen, .dashboard)

        let buttonRect = NSRect(x: 100, y: 900, width: 40, height: 22)
        controller.prepareForOpening(below: buttonRect)

        XCTAssertEqual(
            panel.frame.height,
            520,
            accuracy: 1,
            "reopen after Customize close must use dashboard remembered height, not Customize's 780"
        )
        XCTAssertFalse(controller.isMorphing, "prepareForOpening must clear any prior morph flag")
        panel.orderOut(nil)
        controller.finishClosing()
    }

    func testReopenAfterSettingsUsesDashboardRememberedHeightNotSettings() {
        let suiteName = "OpenUsageTests.PanelHeightPersistence.Settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(480.0, forKey: PanelHeightController.heightDefaultsKey(for: .dashboard))
        defaults.set(640.0, forKey: PanelHeightController.heightDefaultsKey(for: .settings))

        let layoutDefaultsSuite = "OpenUsageTests.PanelHeightPersistence.SettingsLayout.\(UUID().uuidString)"
        let layoutDefaults = UserDefaults(suiteName: layoutDefaultsSuite)!
        layoutDefaults.removePersistentDomain(forName: layoutDefaultsSuite)
        defer { layoutDefaults.removePersistentDomain(forName: layoutDefaultsSuite) }
        let layout = LayoutStore(registry: .mock, defaults: layoutDefaults, storageKey: "layout")

        let panel = MenuBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: PanelHeightController.panelWidth, height: 640),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        let controller = PanelHeightController(panel: panel, defaults: defaults) { layout.screen }

        layout.presentWithoutSlide(.settings)
        panel.setFrame(
            NSRect(x: 80, y: 200, width: PanelHeightController.panelWidth, height: 640),
            display: false
        )
        panel.orderFront(nil)

        controller.saveBeforeClosing()
        layout.resetForPopoverClose()

        controller.prepareForOpening(below: NSRect(x: 120, y: 880, width: 36, height: 22))
        XCTAssertEqual(panel.frame.height, 480, accuracy: 1)
        panel.orderOut(nil)
        controller.finishClosing()
    }

    /// Cold-open Settings (status-item menu) should open at the Settings remembered height after a
    /// silent present — same contract openSettings relies on.
    func testColdOpenSettingsUsesSettingsRememberedHeight() {
        let suiteName = "OpenUsageTests.PanelHeightPersistence.ColdSettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(500.0, forKey: PanelHeightController.heightDefaultsKey(for: .dashboard))
        defaults.set(700.0, forKey: PanelHeightController.heightDefaultsKey(for: .settings))

        let layoutDefaultsSuite = "OpenUsageTests.PanelHeightPersistence.ColdSettingsLayout.\(UUID().uuidString)"
        let layoutDefaults = UserDefaults(suiteName: layoutDefaultsSuite)!
        layoutDefaults.removePersistentDomain(forName: layoutDefaultsSuite)
        defer { layoutDefaults.removePersistentDomain(forName: layoutDefaultsSuite) }
        let layout = LayoutStore(registry: .mock, defaults: layoutDefaults, storageKey: "layout")

        let panel = MenuBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: PanelHeightController.panelWidth, height: 500),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        // A tall, fixed display so the assertion is about the remembered height, not about whatever
        // screen the machine running this has. Without this the test read the real `NSScreen`, and on a
        // headless CI runner there is none — the remembered 700 pt was then clamped to the runner's
        // available height and the test failed at 572 pt.
        let display = NSRect(x: 0, y: 0, width: 1920, height: 1200)
        let controller = PanelHeightController(
            panel: panel,
            defaults: defaults,
            currentScreen: { layout.screen },
            visibleFrameProvider: { _ in display }
        )

        let slideID = layout.screenSlideID
        layout.presentWithoutSlide(.settings)
        XCTAssertEqual(layout.screenSlideID, slideID)

        controller.prepareForOpening(below: NSRect(x: 100, y: 900, width: 40, height: 22))
        XCTAssertEqual(panel.frame.height, 700, accuracy: 1)
        controller.finishClosing()
    }

    /// Guards the guard: if the injected display were ignored in favour of the real `NSScreen`, the test
    /// above would pass on a developer Mac and fail on a runner for the same reason it always did. A
    /// deliberately short display must clamp the remembered height, which is only observable if the seam
    /// is genuinely consulted.
    func testInjectedDisplayGovernsTheHeightClamp() {
        let suiteName = "OpenUsageTests.PanelHeightPersistence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let layoutDefaultsSuite = "OpenUsageTests.PanelHeightPersistence.Layout.\(UUID().uuidString)"
        let layoutDefaults = UserDefaults(suiteName: layoutDefaultsSuite)!
        defer { layoutDefaults.removePersistentDomain(forName: layoutDefaultsSuite) }
        let layout = LayoutStore(registry: .mock, defaults: layoutDefaults, storageKey: "layout")

        let panel = MenuBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: PanelHeightController.panelWidth, height: 500),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false

        // Short enough that the remembered 700 pt cannot fit above a button near the top of it.
        let short = NSRect(x: 0, y: 0, width: 1920, height: 500)
        let controller = PanelHeightController(
            panel: panel,
            defaults: defaults,
            currentScreen: { layout.screen },
            visibleFrameProvider: { _ in short }
        )
        layout.presentWithoutSlide(.settings)
        defaults.set(700, forKey: PanelHeightController.heightDefaultsKey(for: layout.screen))

        controller.prepareForOpening(below: NSRect(x: 100, y: 450, width: 40, height: 22))
        XCTAssertLessThan(
            panel.frame.height, 700,
            "a short injected display must clamp the remembered height, proving the seam is consulted"
        )
        controller.finishClosing()
    }
}
