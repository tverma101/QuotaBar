import XCTest
@testable import QuotaBar

final class ScanWorkerCommandOptionsTests: XCTestCase {
    func testParsesProvidersScopeAndPacing() throws {
        let options = try ScanWorkerCommand.Options.parse(
            ["--scan-worker", "--providers", "codex,claude", "--scope", "local-accounting", "--paced"]
        )
        XCTAssertEqual(options.providerIDs, ["codex", "claude"])
        XCTAssertEqual(options.scope, .localAccounting)
        XCTAssertTrue(options.paced)
    }

    func testDefaultsArePanelAccountingUnpaced() throws {
        let options = try ScanWorkerCommand.Options.parse(
            ["--scan-worker", "--providers", "freebuff"]
        )
        XCTAssertEqual(options.scope, .panelAccounting)
        XCTAssertFalse(options.paced)
        XCTAssertEqual(options.providerIDs, ["freebuff"])
    }

    func testRejectsMissingProviders() {
        XCTAssertThrowsError(try ScanWorkerCommand.Options.parse(["--scan-worker"]))
        XCTAssertThrowsError(try ScanWorkerCommand.Options.parse(["--scan-worker", "--providers", ""]))
    }

    func testRejectsUnknownScopeAndFlags() {
        XCTAssertThrowsError(try ScanWorkerCommand.Options.parse(
            ["--scan-worker", "--providers", "codex", "--scope", "full"]
        ))
        XCTAssertThrowsError(try ScanWorkerCommand.Options.parse(
            ["--scan-worker", "--providers", "codex", "--force"]
        ))
    }
}
