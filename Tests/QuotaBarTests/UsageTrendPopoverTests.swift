import AppKit
import SwiftUI
import XCTest
@testable import QuotaBar

@MainActor
final class UsageTrendPopoverTests: XCTestCase {
    func testHoverPopoverOwnsDismissalAndHonorsReduceMotion() {
        var isPresented = true
        let controller = HoverPopoverController(isPresented: Binding(
            get: { isPresented },
            set: { isPresented = $0 }
        ))
        // Application-owned dismissal: taps elsewhere in the panel must not tear the popover down.
        XCTAssertEqual(controller.popover.behavior, .applicationDefined)
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 20))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 20),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        // A programmatically created NSWindow releases itself on close, which over-releases it under
        // ARC and crashes the test's autorelease pool drain.
        window.isReleasedWhenClosed = false
        window.contentView = anchor
        window.orderFront(nil)
        defer { window.close() }

        controller.update(
            content: AnyView(Text("Detail").frame(width: 100, height: 50)),
            reduceAnimations: true,
            anchor: anchor
        )
        XCTAssertFalse(controller.popover.animates, "reduced motion presents without the fade")

        controller.update(
            content: AnyView(Text("Detail").frame(width: 100, height: 50)),
            reduceAnimations: false,
            anchor: anchor
        )
        XCTAssertTrue(controller.popover.animates, "the standard motion setting keeps the fade")
    }

    func testClosedPopoverSkipsHiddenContentSizing() {
        var isPresented = false
        let controller = HoverPopoverController(isPresented: Binding(
            get: { isPresented },
            set: { isPresented = $0 }
        ))
        let originalSize = NSSize(width: 17, height: 19)
        controller.popover.contentSize = originalSize

        controller.update(
            content: AnyView(Color.clear.frame(width: 300, height: 200)),
            reduceAnimations: true,
            anchor: NSView()
        )

        XCTAssertEqual(controller.popover.contentSize, originalSize)
    }

    func testDismissAllClosesPresentedPopoverImmediately() {
        var isPresented = true
        let controller = HoverPopoverController(isPresented: Binding(
            get: { isPresented },
            set: { isPresented = $0 }
        ))
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 20))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 20),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        // A programmatically created NSWindow releases itself on close, which over-releases it under
        // ARC and crashes the test's autorelease pool drain.
        window.isReleasedWhenClosed = false
        window.contentView = anchor
        window.orderFront(nil)
        defer { window.close() }

        controller.update(
            content: AnyView(Text("Detail").frame(width: 100, height: 50)),
            reduceAnimations: true,
            anchor: anchor
        )
        XCTAssertTrue(controller.popover.isShown)

        isPresented = false
        HoverPopoverController.dismissAll()

        XCTAssertFalse(controller.popover.isShown)
    }
}
