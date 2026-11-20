import XCTest
@testable import QuotaBar

/// Regression: the batched fold child pre-marks providers in `refreshingProviderIDs` while
/// `runningProviderRefreshScopes` stays empty for the whole child lifetime. The deferred-refresh
/// emitter used to treat "no running scopes" as ready, so every meter pass that deferred behind the
/// window was re-emitted by its own batch's unregisters, re-latched, and re-deferred — a millisecond
/// spin of all-deferred batches that lasted as long as the fold (minutes on a deep corpus). Emission
/// must mirror the admission gate: only emit a request a resumed pass would actually run.
@MainActor
final class DeferredRefreshFoldWindowTests: XCTestCase {
    private final class RecordingRuntime: ProviderRuntime {
        let provider: Provider
        let widgetDescriptors: [WidgetDescriptor]

        init(id: String) {
            let provider = Provider(id: id, displayName: id.uppercased(), icon: .providerMark("codex"))
            self.provider = provider
            self.widgetDescriptors = [
                WidgetDescriptor.percent(id: "\(id).session", provider: provider, title: "Session")
                    .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "test"),
            ]
        }

        func refresh() async -> ProviderSnapshot {
            ProviderSnapshot.make(provider: provider, plan: "in-process-\(provider.id)", lines: [], refreshedAt: Date())
        }
    }

    /// Blocks inside `run` (which executes off the main actor) until the test opens the gate, so the
    /// pre-mark window can be held open deterministically.
    private final class BlockingBatchRunner: ProcessRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var _entered = false
        private let gate = DispatchSemaphore(value: 0)
        private let stdout: String

        init(stdout: String) {
            self.stdout = stdout
        }

        var entered: Bool {
            lock.lock(); defer { lock.unlock() }
            return _entered
        }

        func open() {
            gate.signal()
        }

        func run(
            executable: String,
            arguments: [String],
            environment: [String: String],
            timeout: TimeInterval
        ) throws -> ProcessResult {
            lock.lock()
            _entered = true
            lock.unlock()
            gate.wait()
            return ProcessResult(exitCode: 0, stdout: stdout, stderr: "")
        }
    }

    func testDeferredMetersDoNotReEmitWhileTheFoldChildPreMarksProviders() async throws {
        let suiteName = "OpenUsageTests.FoldWindow.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        defer { suite.removePersistentDomain(forName: suiteName) }
        let runtimes = [RecordingRuntime(id: "a"), RecordingRuntime(id: "b")]
        let store = WidgetDataStore(
            registry: WidgetRegistry(
                providers: runtimes.map(\.provider),
                descriptors: runtimes.flatMap(\.widgetDescriptors)
            ),
            providers: runtimes,
            cache: ProviderSnapshotCache(userDefaults: suite, storageKey: "snapshots", ttl: 600),
            defaults: suite,
            isProviderEnabled: { _ in true }
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let response = ScanWorkerCommand.Response(
            schema: ScanWorkerCommand.schemaName,
            snapshots: Dictionary(uniqueKeysWithValues: runtimes.map { runtime in
                (runtime.provider.id, ProviderSnapshot.make(
                    provider: runtime.provider, plan: "child-\(runtime.provider.id)", lines: [], refreshedAt: Date()
                ))
            }),
            errors: [:],
            identityKeys: ["a": "identity-a", "b": "identity-b"]
        )
        let runner = BlockingBatchRunner(stdout: String(data: try encoder.encode(response), encoding: .utf8)!)
        store.scanWorker = ScanWorkerClient(
            runner: runner,
            timeout: 110,
            executableURLOverride: URL(fileURLWithPath: "/tmp/fake.app/Contents/MacOS/QuotaBar")
        )

        var ready: [WidgetDataStore.DeferredRefreshRequest] = []
        store.onDeferredRefreshReady = { ready.append($0) }

        let fold = Task {
            await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
                await store.refreshAll(force: true)
            }
        }
        await waitUntil(
            { runner.entered && store.refreshingProviderIDs.contains("a") && store.refreshingProviderIDs.contains("b") },
            "the fold child holds the pre-mark window open"
        )

        // Non-forced meter passes during the window defer — and must NOT be re-emitted: the gate
        // would instantly re-defer them, which is the spin.
        let outcomeA = await ProviderRefreshContext.$scope.withValue(.panelMeters) {
            await store.refresh(providerID: "a")
        }
        let outcomeB = await ProviderRefreshContext.$scope.withValue(.panelMeters) {
            await store.refresh(providerID: "b")
        }
        XCTAssertEqual(outcomeA, .inFlight)
        XCTAssertEqual(outcomeB, .inFlight)
        XCTAssertTrue(ready.isEmpty, "a request the gate would re-defer must stay queued, not spin the scheduler")

        runner.open()
        await fold.value

        // The window closed: each queued request resumes exactly once, with its scope intact.
        XCTAssertEqual(Set(ready.map(\.providerID)), ["a", "b"])
        XCTAssertEqual(ready.count, 2)
        XCTAssertTrue(ready.allSatisfy { $0.scope == .panelMeters })

        // No work was lost: a resumed meter pass now runs instead of deferring again.
        let resumed = await ProviderRefreshContext.$scope.withValue(.panelMeters) {
            await store.refresh(providerID: "a", force: true)
        }
        XCTAssertEqual(resumed, .refreshed)
    }
}
