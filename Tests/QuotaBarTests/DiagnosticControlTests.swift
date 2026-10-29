import XCTest
@testable import QuotaBar

final class DiagnosticControlTests: XCTestCase {
    func testCommandsAreExplicitAndProviderInputIsTyped() {
        XCTAssertEqual(DiagnosticRequest(command: "show", providerID: nil), .show(providerID: nil))
        XCTAssertEqual(DiagnosticRequest(command: "show", providerID: "freebuff"), .show(providerID: "freebuff"))
        XCTAssertEqual(DiagnosticRequest(command: "close", providerID: nil), .close)
        XCTAssertEqual(DiagnosticRequest(command: "refresh", providerID: " freebuff "), .refresh(providerID: "freebuff"))
        XCTAssertEqual(DiagnosticRequest(command: "refresh", providerID: " "), .refresh(providerID: nil))
        XCTAssertNil(DiagnosticRequest(command: "refresh", providerID: 17))
        XCTAssertNil(DiagnosticRequest(command: "reset", providerID: nil))
    }
}
