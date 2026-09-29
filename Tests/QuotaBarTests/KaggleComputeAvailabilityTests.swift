import Foundation
import XCTest
@testable import QuotaBar

/// The Kaggle operator bridge is a separate binary QuotaBar does not ship — `build_and_run.sh` copies it
/// in only when it finds one in the developer's own checkout. So on any normal install the card could
/// never do anything, and it used to sit at the bottom of every dashboard reporting a red "Needs
/// attention" for a feature the user never enabled, with the remedy "reinstall QuotaBar" — which cannot
/// work, because no reinstall produces the binary. `AppContainer` also started a status poll every 30
/// seconds for the life of the app regardless.
@MainActor
final class KaggleComputeAvailabilityTests: XCTestCase {
    /// A runner that records any attempt to spawn; with no bridge, nothing should be launched.
    private final class RecordingRunner: ProcessRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }

        func run(
            executable: String,
            arguments: [String],
            environment: [String: String],
            timeout: TimeInterval
        ) throws -> ProcessResult {
            lock.lock(); _calls += 1; lock.unlock()
            return ProcessResult(exitCode: 0, stdout: "{\"ok\":true}", stderr: "")
        }
    }

    func testBridgeIsUnavailableWithoutAConfiguredOrBundledBinary() {
        let service = KaggleComputeService(runner: RecordingRunner(), environment: [:])
        XCTAssertFalse(
            service.isBridgeAvailable,
            "no configured path and no bundled binary means the feature cannot run"
        )
    }

    /// The gate is availability, not a blanket removal: an operator who has the bridge keeps the card.
    func testConfiguredBridgeIsReportedAvailable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KaggleBridge.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("kaggle-glm53-control")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)

        let service = KaggleComputeService(
            runner: RecordingRunner(),
            environment: ["KAGGLE_GLM53_CONTROL_BIN": binary.path]
        )
        XCTAssertTrue(service.isBridgeAvailable)
    }

    /// The missing-bridge path must not spawn anything. The poll loop runs every 30 seconds for the life
    /// of the app, so an unguarded install paid for a subprocess a minute indefinitely.
    func testMissingBridgeNeverSpawnsTheStatusCommand() {
        let runner = RecordingRunner()
        let service = KaggleComputeService(runner: runner, environment: [:])

        // The same call `AppContainer` makes, minus the availability guard the container now applies.
        // Exercised directly so the guard itself is the thing under test rather than incidental.
        service.refresh()

        XCTAssertEqual(runner.calls, 0, "nothing should be launched when the bridge is absent")
    }
}
