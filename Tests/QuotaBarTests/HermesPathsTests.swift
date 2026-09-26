import XCTest
@testable import QuotaBar

final class HermesPathsTests: XCTestCase {
    func testDefaultHomeIsDotHermesUnderUserHome() {
        let path = HermesPaths.stateDBPath(
            environment: FakeEnvironment([:]),
            homeDirectory: URL(fileURLWithPath: "/Users/test")
        )
        XCTAssertEqual(path, "/Users/test/.hermes/state.db")
    }

    func testHermesHomeOverrideWins() {
        let path = HermesPaths.stateDBPath(
            environment: FakeEnvironment(["HERMES_HOME": "/custom/hermes"]),
            homeDirectory: URL(fileURLWithPath: "/Users/test")
        )
        XCTAssertEqual(path, "/custom/hermes/state.db")
    }

    func testTildeHermesHomeIsExpanded() {
        let path = HermesPaths.stateDBPath(
            environment: FakeEnvironment(["HERMES_HOME": "~/hermes-data"]),
            homeDirectory: URL(fileURLWithPath: "/Users/test")
        )
        XCTAssertEqual(path, "/Users/test/hermes-data/state.db")
    }

    func testBlankHermesHomeFallsBackToDefault() {
        let path = HermesPaths.stateDBPath(
            environment: FakeEnvironment(["HERMES_HOME": "   "]),
            homeDirectory: URL(fileURLWithPath: "/Users/test")
        )
        XCTAssertEqual(path, "/Users/test/.hermes/state.db")
    }
}
