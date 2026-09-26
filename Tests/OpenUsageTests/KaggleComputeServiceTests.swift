import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class KaggleComputeServiceTests: XCTestCase {
    func testStatusSnapshotParsesAllocationAndTokenAccounting() {
        let snapshot = KaggleComputeSnapshot(json: [
            "ok": true,
            "state": "running",
            "model": "glm-5.3-flash",
            "kernel_state": "RUNNING",
            "endpoint_ready": true,
            "started_at": 1_800_000_000,
            "elapsed_seconds": 120,
            "allocation_limit_seconds": 32_400,
            "remaining_seconds": 32_280,
            "requests": 3,
            "input_tokens": 8_000,
            "output_tokens": 1_000,
            "cached_input_tokens": 6_000,
            "estimated_api_cost_usd": 0.012345,
        ])

        XCTAssertEqual(snapshot.state, .running)
        XCTAssertEqual(snapshot.kernelState, "RUNNING")
        XCTAssertTrue(snapshot.endpointReady)
        XCTAssertEqual(snapshot.startedAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(snapshot.elapsedSeconds, 120)
        XCTAssertEqual(snapshot.remainingSeconds, 32_280)
        XCTAssertEqual(snapshot.requests, 3)
        XCTAssertEqual(snapshot.inputTokens, 8_000)
        XCTAssertEqual(snapshot.outputTokens, 1_000)
        XCTAssertEqual(snapshot.cachedInputTokens, 6_000)
        XCTAssertEqual(snapshot.estimatedAPICostUSD, 0.012345, accuracy: 0.0000001)
        XCTAssertNil(snapshot.errorMessage)
    }

    func testInvalidStatusFailsClosed() {
        let snapshot = KaggleComputeSnapshot(jsonData: Data("not-json".utf8))
        XCTAssertEqual(snapshot.state, .error)
        XCTAssertEqual(snapshot.errorMessage, "The Kaggle bridge returned invalid status data.")
        XCTAssertFalse(snapshot.endpointReady)
    }

    func testUnconfiguredStatusIsNotActive() {
        let snapshot = KaggleComputeSnapshot(json: [
            "ok": true,
            "state": "unconfigured",
            "endpoint_ready": false,
            "requests": 0,
            "input_tokens": 0,
            "output_tokens": 0,
        ])
        XCTAssertEqual(snapshot.state, .unconfigured)
        XCTAssertFalse(snapshot.endpointReady)
        XCTAssertEqual(snapshot.remainingSeconds, 0)
    }

    func testTurnOnUsesExplicitBridgeAndUpdatesState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-kaggle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let actionFile = directory.appendingPathComponent("action")
        let executable = directory.appendingPathComponent("bridge")
        let script = "#!/bin/sh\nprintf '%s' \"$1\" > '\(actionFile.path)'\nprintf '%s' '{\"ok\":true,\"state\":\"starting\",\"model\":\"glm-5.3-flash\"}'\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let service = KaggleComputeService(environment: [
            "HOME": directory.path,
            "KAGGLE_GLM53_CONTROL_BIN": executable.path,
        ])
        service.turnOn()
        while service.isExecuting {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(service.snapshot.state, .starting)
        XCTAssertEqual(try String(contentsOf: actionFile, encoding: .utf8), "on")
    }
}
