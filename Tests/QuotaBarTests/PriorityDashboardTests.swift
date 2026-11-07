import XCTest
@testable import QuotaBar

@MainActor
final class PriorityDashboardTests: XCTestCase {
    func testPrioritySectionsRespectMeterAndPin() {
        func data(_ used: Double) -> WidgetData {
            WidgetData(title: "Session", icon: .providerMark("zai"), kind: .percent, used: used, limit: 100)
        }
        XCTAssertNil(PriorityDashboardView.section(for: data(20), pinned: false))
        XCTAssertEqual(PriorityDashboardView.section(for: data(20), pinned: true), .pinned)
        XCTAssertEqual(PriorityDashboardView.section(for: data(95), pinned: true), .runningOut)
        XCTAssertEqual(PriorityDashboardView.section(for: data(100), pinned: true), .usedUp)
        var unavailable = data(95)
        unavailable.hasData = false
        XCTAssertNil(PriorityDashboardView.section(for: unavailable, pinned: true))
    }
}
