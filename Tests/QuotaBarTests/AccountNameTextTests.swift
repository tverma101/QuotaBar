import XCTest
@testable import QuotaBar

final class AccountNameTextTests: XCTestCase {
    func testOrdinaryProviderNameCarriesNoAccountSuffix() {
        XCTAssertNil(AccountNameText.splitAccountSuffix("Claude"))
        XCTAssertNil(AccountNameText.splitAccountSuffix("Codex"))
        XCTAssertNil(AccountNameText.splitAccountSuffix("OpenCode"))
    }

    func testManagedAccountNameSplitsAtTheFirstDash() {
        let parts = AccountNameText.splitAccountSuffix("Claude — Acme Corp")
        XCTAssertEqual(parts?.family, "Claude")
        XCTAssertEqual(parts?.account, "Acme Corp")
    }

    func testAccountLabelContainingDashesStaysIntactInTheSuffix() {
        let parts = AccountNameText.splitAccountSuffix("Codex — team — east")
        XCTAssertEqual(parts?.family, "Codex")
        XCTAssertEqual(parts?.account, "team — east")
    }

    func testEmptySuffixIsNotAccountShaped() {
        XCTAssertNil(AccountNameText.splitAccountSuffix("Claude — "))
    }

    func testNewDashSeparatorIsNotAccountShaped() {
        XCTAssertNil(AccountNameText.splitAccountSuffix("Claude - Acme Corp"))
    }
}
