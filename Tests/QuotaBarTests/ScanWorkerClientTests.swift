import XCTest
@testable import QuotaBar

/// Records spawn requests and replays a canned result, so the client's contract is exercised
/// without touching the real app bundle.
private final class CannedScanWorkerRunner: ProcessRunning, @unchecked Sendable {
    enum Outcome {
        case success(stdout: String)
        case exit(exitCode: Int32, stderr: String)
        case timeout
        case spawnFailure
    }

    private(set) var lastArguments: [String] = []
    private(set) var lastEnvironment: [String: String] = [:]
    private(set) var lastExecutable: String = ""
    private(set) var spawnCount = 0
    let outcome: Outcome

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        spawnCount += 1
        lastExecutable = executable
        lastArguments = arguments
        lastEnvironment = environment
        switch outcome {
        case .success(let stdout):
            return ProcessResult(exitCode: 0, stdout: stdout, stderr: "")
        case .exit(let exitCode, let stderr):
            return ProcessResult(exitCode: exitCode, stdout: "", stderr: stderr)
        case .timeout:
            throw ProcessRunnerError.timedOut(executable: executable, timeout: timeout)
        case .spawnFailure:
            throw CocoaError(.fileNoSuchFile)
        }
    }
}

@MainActor
final class ScanWorkerClientTests: XCTestCase {
    private let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
    private var fallbackRunCount = 0

    private func makeClient(runner: CannedScanWorkerRunner) -> ScanWorkerClient {
        ScanWorkerClient(
            runner: runner,
            timeout: 110,
            executableURLOverride: URL(fileURLWithPath: "/tmp/fake.app/Contents/MacOS/QuotaBar")
        )
    }

    private func fallback() async -> ProviderSnapshot {
        fallbackRunCount += 1
        return ProviderSnapshot.make(provider: provider, plan: nil, lines: [], refreshedAt: TestLocalInstant.date(2026, 11, 10, 12))
    }

    private func encodeResponse(_ response: ScanWorkerCommand.Response) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(data: try encoder.encode(response), encoding: .utf8)!
    }

    override func tearDown() {
        fallbackRunCount = 0
        super.tearDown()
    }

    /// The error text a failed refresh surfaces lives in the badge line the error snapshot carries.
    private func errorMessage(in snapshot: ProviderSnapshot) -> String? {
        guard let badge = snapshot.lines.first(where: {
            if case .badge(let label, _, _, _) = $0 { return label == MetricLine.errorBadgeLabel }
            return false
        }),
        case .badge(_, let text, _, _) = badge
        else { return nil }
        return text
    }

    func testSuccessfulFoldReturnsChildSnapshotWithoutFallingBack() async throws {
        let snapshot = ProviderSnapshot.make(
            provider: provider, plan: nil, lines: [], refreshedAt: TestLocalInstant.date(2026, 11, 10, 12)
        )
        let payload = try encodeResponse(ScanWorkerCommand.Response(
            schema: ScanWorkerCommand.schemaName,
            snapshots: [provider.id: snapshot],
            errors: [:],
            identityKeys: [provider.id: "identity-1"]
        ))
        let runner = CannedScanWorkerRunner(outcome: .success(stdout: payload))
        let client = makeClient(runner: runner)

        let result = await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await client.foldOnlySnapshot(provider: provider, inProcessFallback: { await self.fallback() })
        }

        XCTAssertEqual(result.providerID, provider.id)
        XCTAssertNil(result.errorCategory)
        XCTAssertEqual(fallbackRunCount, 0)
        XCTAssertEqual(runner.spawnCount, 1)
        XCTAssertEqual(runner.lastEnvironment["QUOTABAR_IN_SCAN_WORKER"], "1")
        XCTAssertTrue(runner.lastArguments.contains("--scan-worker"))
    }

    func testChildErrorBecomesErrorSnapshotWithoutRescan() async throws {
        let payload = try encodeResponse(ScanWorkerCommand.Response(
            schema: ScanWorkerCommand.schemaName,
            snapshots: [:],
            errors: [provider.id: "local history unreadable"],
            identityKeys: [:]
        ))
        let client = makeClient(runner: CannedScanWorkerRunner(outcome: .success(stdout: payload)))

        let result = await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await client.foldOnlySnapshot(provider: provider, inProcessFallback: { await self.fallback() })
        }

        XCTAssertNotNil(result.errorCategory)
        XCTAssertEqual(errorMessage(in: result), "local history unreadable")
        XCTAssertEqual(fallbackRunCount, 0, "a reported child failure must not trigger an in-process rescan")
    }

    func testCancelledChildResultFallsBackInProcess() async throws {
        let cancelled = ProviderSnapshot.error(
            provider: provider,
            error: CancellationError(),
            clearsPriorMenuBarQuotaState: false
        )
        let payload = try encodeResponse(ScanWorkerCommand.Response(
            schema: ScanWorkerCommand.schemaName,
            snapshots: [provider.id: cancelled],
            errors: [:],
            identityKeys: [:]
        ))
        let client = makeClient(runner: CannedScanWorkerRunner(outcome: .success(stdout: payload)))

        let result = await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await client.foldOnlySnapshot(provider: provider, inProcessFallback: { await self.fallback() })
        }

        XCTAssertEqual(fallbackRunCount, 1)
        XCTAssertNil(result.errorCategory)
    }

    func testTimeoutBecomesTimeoutErrorSnapshot() async throws {
        let client = makeClient(runner: CannedScanWorkerRunner(outcome: .timeout))

        let result = await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await client.foldOnlySnapshot(provider: provider, inProcessFallback: { await self.fallback() })
        }

        XCTAssertEqual(fallbackRunCount, 0)
        XCTAssertEqual(errorMessage(in: result), "Refresh timed out after 110s")
    }

    func testNonzeroExitBecomesErrorSnapshot() async throws {
        let client = makeClient(runner: CannedScanWorkerRunner(outcome: .exit(exitCode: 4, stderr: "quotabar: settings could not migrate")))

        let result = await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await client.foldOnlySnapshot(provider: provider, inProcessFallback: { await self.fallback() })
        }

        XCTAssertEqual(fallbackRunCount, 0)
        XCTAssertEqual(errorMessage(in: result), "quotabar: settings could not migrate")
    }

    func testUnavailableWorkerUsesInProcessFallback() async {
        // No executable override: the xctest runner is not an app bundle, so the worker is inert.
        let runner = CannedScanWorkerRunner(outcome: .success(stdout: "{}"))
        let client = ScanWorkerClient(runner: runner, timeout: 110)

        let result = await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await client.foldOnlySnapshot(provider: provider, inProcessFallback: { await self.fallback() })
        }

        XCTAssertFalse(client.isAvailable)
        XCTAssertEqual(runner.spawnCount, 0)
        XCTAssertEqual(fallbackRunCount, 1)
        XCTAssertEqual(result.providerID, provider.id)
    }

    func testMeterScopesNeverSpawn() async {
        let runner = CannedScanWorkerRunner(outcome: .success(stdout: ""))
        let client = makeClient(runner: runner)

        let result = await ProviderRefreshContext.$scope.withValue(.panelMeters) {
            await client.foldOnlySnapshot(provider: provider, inProcessFallback: { await self.fallback() })
        }

        XCTAssertEqual(runner.spawnCount, 0)
        XCTAssertEqual(fallbackRunCount, 1)
        XCTAssertEqual(result.providerID, provider.id)
    }
}
