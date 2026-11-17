import AppKit
import SwiftUI
import XCTest
@testable import QuotaBar

@MainActor
final class MenuBarPanelTests: XCTestCase {
    /// The hosting view fills the panel's content view without being it, so SwiftUI lays out inside
    /// the window instead of sizing it (see `MenuBarPanel.host(_:)`).
    func testTheHostingViewFillsTheContentViewAndIsNeverTheContentViewItself() {
        let panel = MenuBarPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
                                 styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        let host = NSHostingView(rootView: Color.clear)
        panel.host(host)
        XCTAssertFalse(panel.contentView === host)
        XCTAssertTrue(host.superview === panel.contentView)
        panel.setContentSize(NSSize(width: 320, height: 500))
        XCTAssertEqual(host.frame, panel.contentView?.bounds)
    }
}
