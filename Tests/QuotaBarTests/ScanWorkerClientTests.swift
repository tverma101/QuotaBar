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
    private(set) var allArguments: [[String]] = []
    private let lock = NSLock()
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
        lock.lock()
        spawnCount += 1
        lastExecutable = executable
        lastArguments = arguments
        lastEnvironment = environment
        allArguments.append(arguments)
        lock.unlock()
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
        XCTAssertTrue(runner.lastArguments.contains("--return-only"))
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

    /// A batch fold splits the list across concurrent children (up to three, round-robin) and
    /// serves each provider's `foldOnlySnapshot` out of the stash — no per-provider respawn.
    func testBatchFoldServesStashedResultsWithoutRespawn() async throws {
        let other = Provider(id: "grok", displayName: "Grok", icon: .providerMark("grok"))
        let snapshotA = ProviderSnapshot.make(
            provider: provider, plan: nil, lines: [], refreshedAt: TestLocalInstant.date(2026, 11, 10, 12)
        )
        let snapshotB = ProviderSnapshot.make(
            provider: other, plan: nil, lines: [], refreshedAt: TestLocalInstant.date(2026, 11, 10, 12)
        )
        let payload = try encodeResponse(ScanWorkerCommand.Response(
            schema: ScanWorkerCommand.schemaName,
            snapshots: [provider.id: snapshotA, other.id: snapshotB],
            errors: [:],
            identityKeys: [provider.id: "identity-1"]
        ))
        let runner = CannedScanWorkerRunner(outcome: .success(stdout: payload))
        let client = makeClient(runner: runner)

        await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await client.batchFold(providerIDs: [provider.id, other.id])
            XCTAssertEqual(runner.spawnCount, 2)
            XCTAssertTrue(runner.allArguments.allSatisfy { $0.contains("--return-only") })
            let spawnedProviders = Set(runner.allArguments.compactMap { args in
                args.firstIndex(of: "--providers").map { args[$0 + 1] }
            })
            XCTAssertEqual(spawnedProviders, ["codex", "grok"])

            let first = await client.foldOnlySnapshot(provider: provider, inProcessFallback: { await self.fallback() })
            let second = await client.foldOnlySnapshot(provider: other, inProcessFallback: { await self.fallback() })
            XCTAssertEqual(first.providerID, provider.id)
            XCTAssertEqual(second.providerID, other.id)
            XCTAssertNil(first.errorCategory)
        }

        XCTAssertEqual(runner.spawnCount, 2, "consumed stash entries must not respawn the child")
        XCTAssertEqual(fallbackRunCount, 0)
    }

    /// A provider absent from the batch (or a stale batch entry) keeps the per-provider child path.
    func testBatchFoldMissFallsBackToIndividualSpawn() async throws {
        let other = Provider(id: "grok", displayName: "Grok", icon: .providerMark("grok"))
        let payload = try encodeResponse(ScanWorkerCommand.Response(
            schema: ScanWorkerCommand.schemaName,
            snapshots: [provider.id: ProviderSnapshot.make(
                provider: provider, plan: nil, lines: [], refreshedAt: TestLocalInstant.date(2026, 11, 10, 12)
            )],
            errors: [:],
            identityKeys: [:]
        ))
        let runner = CannedScanWorkerRunner(outcome: .success(stdout: payload))
        let client = makeClient(runner: runner)

        await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await client.batchFold(providerIDs: [provider.id, other.id])
            _ = await client.foldOnlySnapshot(provider: other, inProcessFallback: { await self.fallback() })
        }

        // `other` had no batch result: it gets one solo worker attempt (the per-provider path),
        // whose canned response also lacks it, and only then the in-process fallback runs.
        XCTAssertEqual(fallbackRunCount, 1)
        XCTAssertEqual(runner.spawnCount, 3)
    }

    /// A failed batch leaves the stash empty and each provider falls back to its own child.
    func testFailedBatchLeavesPerProviderPathIntact() async throws {
        let snapshot = ProviderSnapshot.make(
            provider: provider, plan: nil, lines: [], refreshedAt: TestLocalInstant.date(2026, 11, 10, 12)
        )
        let payload = try encodeResponse(ScanWorkerCommand.Response(
            schema: ScanWorkerCommand.schemaName,
            snapshots: [provider.id: snapshot],
            errors: [:],
            identityKeys: [:]
        ))
        let runner = CannedScanWorkerRunner(outcome: .exit(exitCode: 3, stderr: "child crashed"))
        let client = makeClient(runner: runner)

        // Both batch children fail, then the individual spawn succeeds on a fresh runner result.
        await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await client.batchFold(providerIDs: [provider.id, "grok"])
            XCTAssertEqual(runner.spawnCount, 2)
            let result = await client.foldOnlySnapshot(provider: provider, inProcessFallback: { await self.fallback() })
            // The runner still reports the canned failure for the individual spawn too — that is
            // the error-snapshot path, not the in-process fallback.
            XCTAssertEqual(errorMessage(in: result), "child crashed")
        }

        XCTAssertEqual(runner.spawnCount, 3, "a failed batch must not suppress the per-provider child")
        XCTAssertEqual(fallbackRunCount, 0)
        _ = payload
    }
}
