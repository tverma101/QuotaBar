import Foundation
import XCTest
@testable import QuotaBar

final class OpenCodePathsTests: XCTestCase {
    private func makeHome(_ suffix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodePaths-\(suffix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A launcher that runs OpenCode inside its own sandbox exports `XDG_DATA_HOME` pointing at a
    /// private root. That root contains an `opencode/` directory, so trusting it blindly made QuotaBar
    /// read a database with no OpenCode-hosted usage and report that local history could not be read,
    /// while the user's real sessions sat in the default location untouched.
    func testInheritedSandboxRootWithoutOpenCodeDataFallsBackToDefault() throws {
        let home = try makeHome("sandbox")
        defer { try? FileManager.default.removeItem(at: home) }
        let sandboxRoot = home.appendingPathComponent("sandbox-data", isDirectory: true)
        // A launcher's sandbox root: it has an `opencode/` directory and its own database (its runs
        // record usage under other provider ids), but no OpenCode login of the user's own.
        let sandboxOpenCode = sandboxRoot.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxOpenCode, withIntermediateDirectories: true)
        try Data().write(to: sandboxOpenCode.appendingPathComponent("opencode.db"))
        let environment = FakeEnvironment(["XDG_DATA_HOME": sandboxRoot.path])

        XCTAssertEqual(
            OpenCodePaths.dataDirectory(environment: environment, homeDirectory: home),
            home.appendingPathComponent(".local/share/opencode").path,
            "an empty sandbox root must not shadow the user's real OpenCode data"
        )
    }

    /// A genuine `XDG_DATA_HOME` install — one that has been logged in or has run — is still honoured.
    func testInheritedRootHoldingOpenCodeDataIsHonoured() throws {
        let home = try makeHome("honour")
        defer { try? FileManager.default.removeItem(at: home) }
        let xdgRoot = home.appendingPathComponent("xdg-data", isDirectory: true)
        let openCodeDir = xdgRoot.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: openCodeDir, withIntermediateDirectories: true)
        try "{}".write(
            to: openCodeDir.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8
        )
        let environment = FakeEnvironment(["XDG_DATA_HOME": xdgRoot.path])

        XCTAssertEqual(
            OpenCodePaths.dataDirectory(environment: environment, homeDirectory: home),
            openCodeDir.path
        )
    }

    /// An explicit request always wins, even when the directory is new or empty.
    func testExplicitOverrideWinsWithoutData() throws {
        let home = try makeHome("override")
        defer { try? FileManager.default.removeItem(at: home) }
        let explicit = home.appendingPathComponent("custom", isDirectory: true)
        let environment = FakeEnvironment([
            "OPENCODE_DATA_DIR": explicit.path,
            "XDG_DATA_HOME": home.appendingPathComponent("xdg", isDirectory: true).path,
        ])

        XCTAssertEqual(
            OpenCodePaths.dataDirectory(environment: environment, homeDirectory: home),
            explicit.path
        )
    }

    func testNoEnvironmentResolvesToDefaultLocation() throws {
        let home = try makeHome("default")
        defer { try? FileManager.default.removeItem(at: home) }

        XCTAssertEqual(
            OpenCodePaths.dataDirectory(environment: FakeEnvironment(), homeDirectory: home),
            home.appendingPathComponent(".local/share/opencode").path
        )
    }
}
