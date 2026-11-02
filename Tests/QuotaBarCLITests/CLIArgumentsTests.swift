import XCTest
@testable import QuotaBarCLI

final class CLIArgumentsTests: XCTestCase {
    func testParsesProviderAndForce() throws {
        let parsed = try CLIArguments.parse(["Codex", "--force"])
        XCTAssertEqual(parsed.providerID, "codex")
        XCTAssertTrue(parsed.force)
    }

    func testRejectsUnknownOptionsAndMultipleProviders() {
        XCTAssertThrowsError(try CLIArguments.parse(["--json"]))
        XCTAssertThrowsError(try CLIArguments.parse(["claude", "codex"]))
    }

    func testHeadlessDiagnosticCanNameAProviderAndForceALiveRefresh() throws {
        let parsed = try CLIArguments.parse(["freebuff", "--diagnose", "--force"])
        XCTAssertEqual(parsed.providerID, "freebuff")
        XCTAssertTrue(parsed.diagnostic)
        XCTAssertTrue(parsed.force)
        XCTAssertFalse(try CLIArguments.parse([]).diagnostic)
    }
}
