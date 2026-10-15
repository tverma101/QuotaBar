import XCTest
@testable import QuotaBar

@MainActor
final class ProviderSectionHeaderTests: XCTestCase {
    func testWarningAndRetryRemainVisibleWhileAccountingSpinnerRuns() {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let header = ProviderSectionHeader(
            provider: provider,
            warning: "Usage is temporarily unavailable.",
            refreshing: true,
            onRefresh: {}
        )

        XCTAssertTrue(header.statusPresentation.showsWarning)
        XCTAssertTrue(header.statusPresentation.showsRetry)
        XCTAssertTrue(header.statusPresentation.showsSpinner)
    }
}
