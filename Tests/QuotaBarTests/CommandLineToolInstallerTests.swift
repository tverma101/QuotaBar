import Foundation
import XCTest
@testable import QuotaBar

@MainActor
final class CommandLineToolInstallerTests: XCTestCase {
    func testDefaultHelperAndCommandMatchBuildScript() throws {
        XCTAssertEqual(CommandLineToolInstaller.bundledHelperRelativePath, "Contents/Helpers/quotabar")
        XCTAssertEqual(CommandLineToolInstaller.defaultCommandPath, "/usr/local/bin/quotabar")

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent("script/build_and_run.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(buildScript.contains(#"CLI_BINARY="$APP_HELPERS/quotabar""#))
        XCTAssertTrue(buildScript.contains(#"ps -p "$pid" -o command="#))
        XCTAssertFalse(buildScript.contains("-o comm="), "bundle checks need ps's full executable path")

        let settings = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/QuotaBar/Views/SettingsScreen.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(settings.contains("Adds a global `quotabar` command"))
        XCTAssertFalse(settings.contains("`openusage` command"))
    }

    private func fixture() throws -> (root: URL, source: String, destination: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("QuotaBar.app/Contents/Helpers/quotabar")
        let destination = root.appendingPathComponent("bin/quotabar")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        return (root, source.path, destination.path)
    }

    func testInstallAndUninstallOwnSymlink() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let installer = CommandLineToolInstaller(
            sourcePath: fixture.source,
            destinationPath: fixture.destination,
            performPrivileged: { operation, source, destination in
                do {
                    switch operation {
                    case .install:
                        try FileManager.default.createDirectory(
                            atPath: (destination as NSString).deletingLastPathComponent,
                            withIntermediateDirectories: true
                        )
                        try FileManager.default.createSymbolicLink(atPath: destination, withDestinationPath: source)
                    case .uninstall:
                        try FileManager.default.removeItem(atPath: destination)
                    }
                    return .success
                } catch {
                    return .failure(error.localizedDescription)
                }
            }
        )

        XCTAssertEqual(installer.status, .notInstalled)
        installer.install()
        XCTAssertEqual(installer.status, .installed)
        installer.uninstall()
        XCTAssertEqual(installer.status, .notInstalled)
    }

    func testForeignPathIsNeverOverwritten() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(
            atPath: (fixture.destination as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data("foreign".utf8).write(to: URL(fileURLWithPath: fixture.destination))
        var operationRan = false
        let installer = CommandLineToolInstaller(
            sourcePath: fixture.source,
            destinationPath: fixture.destination,
            performPrivileged: { _, _, _ in
                operationRan = true
                return .success
            }
        )

        XCTAssertEqual(installer.status, .conflict)
        installer.install()
        XCTAssertFalse(operationRan)
        XCTAssertNotNil(installer.errorMessage)
        XCTAssertEqual(try String(contentsOfFile: fixture.destination, encoding: .utf8), "foreign")
    }

    func testForeignSymlinkIsNeverClaimedOrRemoved() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(
            atPath: (fixture.destination as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: fixture.destination,
            withDestinationPath: "/tmp/another-quotabar"
        )
        var operationRan = false
        let installer = CommandLineToolInstaller(
            sourcePath: fixture.source,
            destinationPath: fixture.destination,
            performPrivileged: { _, _, _ in
                operationRan = true
                return .success
            }
        )

        XCTAssertEqual(installer.status, .conflict)
        installer.uninstall()
        XCTAssertFalse(operationRan)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: fixture.destination),
            "/tmp/another-quotabar"
        )
    }
}
