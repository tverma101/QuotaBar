import XCTest
@testable import QuotaBar

/// Opening the dashboard must not start provider work.
///
/// The tap used to force a full, uncached batch, which fanned out across every enabled provider's
/// local accounting while SwiftUI mounted the panel and could push the app past a core. These tests
/// pin both halves of the rule so neither can drift: presentation paints the cached snapshot, and the
/// user's explicit Refresh Now stays the forced path.
final class PopoverRefreshPolicyTests: XCTestCase {
    func testPanelPresentationUsesTheCachedSnapshot() {
        XCTAssertEqual(
            PopoverRefreshPolicy.decision(for: .panelPresentation),
            .presentSnapshot
        )
    }

    func testManualRefreshStillForcesAFullPass() {
        XCTAssertEqual(
            PopoverRefreshPolicy.decision(for: .manualRefresh),
            .forceFullRefresh
        )
    }
}
