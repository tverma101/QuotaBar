import XCTest
@testable import QuotaBar

/// Records spawn requests and replays a canned child response, so the store's batched fold path
/// is exercised without touching the real app bundle.
private final class CannedBatchRunner: ProcessRunning, @unchecked Sendable {
    enum Outcome {
        case success(stdout: String)
        case exit(exitCode: Int32, stderr: String)
    }

    private(set) var lastArguments: [String] = []
    private(set) var lastEnvironment: [String: String] = [:]
    private(set) var spawnCount = 0
    private let outcome: Outcome

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
        lastArguments = arguments
        lastEnvironment = environment
        switch outcome {
        case .success(let stdout):
            return ProcessResult(exitCode: 0, stdout: stdout, stderr: "")
        case .exit(let exitCode, let stderr):
            return ProcessResult(exitCode: exitCode, stdout: "", stderr: stderr)
        }
    }

    var providersArgument: String {
        lastArguments.firstIndex(of: "--providers").map { lastArguments[$0 + 1] } ?? ""
    }
}

@MainActor
final class ScanWorkerStorePrefetchTests: XCTestCase {
    private final class RecordingRuntime: ProviderRuntime {
        let provider: Provider
        let widgetDescriptors: [WidgetDescriptor]
        private(set) var refreshCount = 0
        let planMarker: String

        init(id: String, planMarker: String) {
            let provider = Provider(id: id, displayName: id.uppercased(), icon: .providerMark("codex"))
            self.provider = provider
            self.widgetDescriptors = [
                WidgetDescriptor.percent(id: "\(id).session", provider: provider, title: "Session")
                    .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "test"),
            ]
            self.planMarker = planMarker
        }

        func refresh() async -> ProviderSnapshot {
            refreshCount += 1
            return ProviderSnapshot.make(
                provider: provider, plan: planMarker, lines: [], refreshedAt: Date()
            )
        }
    }

    private func makeStore(
        runtimeIDs: [String],
        identityKeys: [String: String] = [:],
        seededSnapshot: ProviderSnapshot? = nil,
        seededIdentityKey: String? = nil
    ) -> (WidgetDataStore, [String: RecordingRuntime], ProviderSnapshotCache) {
        let suiteName = "OpenUsageTests.Prefetch.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        let runtimes = Dictionary(uniqueKeysWithValues: runtimeIDs.map { id in
            (id, RecordingRuntime(id: id, planMarker: "in-process-\(id)"))
        })
        let cache = ProviderSnapshotCache(userDefaults: suite, storageKey: "snapshots", ttl: 600)
        if let seededSnapshot {
            cache.store(seededSnapshot, producedByIdentityKey: seededIdentityKey)
        }
        let store = WidgetDataStore(
            registry: WidgetRegistry(
                providers: runtimes.values.map(\.provider),
                descriptors: runtimes.values.flatMap(\.widgetDescriptors)
            ),
            providers: Array(runtimes.values),
            cache: cache,
            defaults: suite,
            isProviderEnabled: { _ in true },
            providerIdentityKeys: identityKeys
        )
        return (store, runtimes, cache)
    }

    private func attachRunner(_ store: WidgetDataStore, outcome: CannedBatchRunner.Outcome) -> CannedBatchRunner {
        let runner = CannedBatchRunner(outcome: outcome)
        store.scanWorker = ScanWorkerClient(
            runner: runner,
            timeout: 110,
            executableURLOverride: URL(fileURLWithPath: "/tmp/fake.app/Contents/MacOS/QuotaBar")
        )
        return runner
    }

    private func snapshot(for provider: Provider, plan: String, refreshedAt: Date = Date()) -> ProviderSnapshot {
        ProviderSnapshot.make(provider: provider, plan: plan, lines: [], refreshedAt: refreshedAt)
    }

    private func encodeResponse(
        _ snapshots: [String: ProviderSnapshot],
        errors: [String: String] = [:],
        identityKeys: [String: String] = [:]
    ) throws -> String {
        let response = ScanWorkerCommand.Response(
            schema: ScanWorkerCommand.schemaName,
            snapshots: snapshots,
            errors: errors,
            identityKeys: identityKeys
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(data: try encoder.encode(response), encoding: .utf8)!
    }

    func testStaleProvidersFoldInSingleChildWithoutTouchingRuntimes() async throws {
        let (store, runtimes, _) = makeStore(runtimeIDs: ["a", "b"])
        let runner = attachRunner(store, outcome: .success(stdout: try encodeResponse([
            "a": snapshot(for: runtimes["a"]!.provider, plan: "child-a"),
            "b": snapshot(for: runtimes["b"]!.provider, plan: "child-b"),
        ], identityKeys: ["a": "identity-a", "b": "identity-b"])))

        await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await store.refreshAll(force: true)
        }

        XCTAssertEqual(runner.spawnCount, 1, "one child folds the whole batch")
        XCTAssertEqual(runner.providersArgument, "a,b")
        XCTAssertEqual(runner.lastEnvironment["QUOTABAR_IN_SCAN_WORKER"], "1")
        XCTAssertEqual(runtimes["a"]?.refreshCount, 0, "child-covered members must not fold in-process")
        XCTAssertEqual(runtimes["b"]?.refreshCount, 0)
        XCTAssertEqual(store.localSnapshots["a"]?.plan, "child-a")
        XCTAssertEqual(store.localSnapshots["b"]?.plan, "child-b")
    }

    func testFreshMemberIsExcludedFromChildAndKeepsCachedValue() async throws {
        let (store, runtimes, cache) = makeStore(runtimeIDs: ["a", "b"])
        var cachedSnapshot = snapshot(for: runtimes["a"]!.provider, plan: "cached-a")
        // A history-bearing entry so the fold-phase "first fold" exception doesn't force a re-fold:
        // a historyless snapshot must re-fold even when fresh (see WidgetDataStore's fold-phase rule).
        cachedSnapshot.usageHistory = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-11-16", totalTokens: 42, costUSD: 0.5),
            ])
        )
        cache.store(
            cachedSnapshot,
            scope: .panelAccounting,
            historyDescriptor: UsageHistoryDescriptor(
                scope: .machineLocal, estimatedCost: true, sourceNote: "test"
            )
        )
        let runner = attachRunner(store, outcome: .success(stdout: try encodeResponse([
            "b": snapshot(for: runtimes["b"]!.provider, plan: "child-b"),
        ])))

        await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await store.refreshAll()
        }
        XCTAssertEqual(runner.spawnCount, 1)
        XCTAssertEqual(runner.providersArgument, "b", "the TTL-fresh member is not handed to the child")
        XCTAssertEqual(runtimes["a"]?.refreshCount, 0)
        XCTAssertEqual(runtimes["b"]?.refreshCount, 0)
        // The history-only fold-scope cache strips the plan (it cannot vouch for quota meters),
        // so "cached-a" is planless by design; the important part is the member was not re-folded,
        // not re-delegated, and its cached entry published.
        XCTAssertNotNil(store.localSnapshots["a"])
        XCTAssertEqual(store.localSnapshots["a"]?.refreshedAt, cachedSnapshot.refreshedAt)
        XCTAssertEqual(store.localSnapshots["b"]?.plan, "child-b")
    }

    /// A delegated Antigravity fold produces machine-local history only — it can never prove which
    /// Google account owns the cached quota. Even when an older or misbehaving child reports an
    /// identity for it, the fold must not re-stamp or clear the live quota: the persisted entry,
    /// its account stamp, and the in-memory card keep the original meters and pick up only the new
    /// history.
    func testAntigravityPrefetchedHistoryCannotReplaceLiveQuotaIdentity() async throws {
        let originalQuotaStamp = Date(timeIntervalSince1970: 1_800_000_000)
        var seeded = ProviderSnapshot(
            providerID: "antigravity",
            displayName: "Antigravity",
            plan: "Pro",
            lines: [.progress(label: "Session", used: 30, limit: 100, format: .percent)],
            refreshedAt: originalQuotaStamp
        )
        seeded.quotaRefreshedAt = originalQuotaStamp
        let (store, runtimes, cache) = makeStore(
            runtimeIDs: ["antigravity"],
            identityKeys: ["antigravity": "google-acct-A"],
            seededSnapshot: seeded,
            seededIdentityKey: "google-acct-A"
        )
        let childSnapshot = ProviderSnapshot.make(
            provider: runtimes["antigravity"]!.provider,
            plan: nil,
            lines: [],
            refreshedAt: Date(),
            usageHistory: ProviderUsageHistory(series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-10-14", totalTokens: 42, costUSD: 0.42)
            ]))
        )
        let runner = attachRunner(store, outcome: .success(stdout: try encodeResponse(
            ["antigravity": childSnapshot],
            identityKeys: ["antigravity": AntigravityAuthStore.unresolvedCacheIdentityKey]
        )))

        await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await store.refreshAll(force: true)
        }

        XCTAssertEqual(runner.spawnCount, 1)
        XCTAssertEqual(runtimes["antigravity"]?.refreshCount, 0)
        // The unresolved identity the child reported must not replace the live account stamp...
        XCTAssertEqual(cache.producedByIdentityKey(providerID: "antigravity"), "google-acct-A")
        // ...nor the persisted quota under it.
        let persisted = cache.loadSnapshots(providerIDs: ["antigravity"])["antigravity"]
        XCTAssertEqual(persisted?.plan, "Pro")
        XCTAssertEqual(
            persisted?.line(label: "Session"),
            .progress(label: "Session", used: 30, limit: 100, format: .percent)
        )
        XCTAssertEqual(persisted?.quotaRefreshedAt, originalQuotaStamp)
        XCTAssertEqual(persisted?.usageHistory?.series.daily.first?.totalTokens, 42)
        // The visible snapshot is the merge of the same two halves: original meters, fresh history.
        let current = store.localSnapshots["antigravity"]
        XCTAssertEqual(current?.plan, "Pro")
        XCTAssertEqual(
            current?.line(label: "Session"),
            .progress(label: "Session", used: 30, limit: 100, format: .percent)
        )
        XCTAssertEqual(current?.quotaRefreshedAt, originalQuotaStamp)
        XCTAssertEqual(current?.usageHistory?.series.daily.first?.totalTokens, 42)
    }

    func testChildDroppingAMemberFallsBackToInProcessFold() async throws {
        let (store, runtimes, _) = makeStore(runtimeIDs: ["a", "b"])
        // Child answers only for a; b reports nothing — b must fold in-process.
        let runner = attachRunner(store, outcome: .success(stdout: try encodeResponse([
            "a": snapshot(for: runtimes["a"]!.provider, plan: "child-a"),
        ])))

        await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await store.refreshAll(force: true)
        }

        XCTAssertEqual(runner.spawnCount, 1)
        XCTAssertEqual(runtimes["a"]?.refreshCount, 0)
        XCTAssertEqual(runtimes["b"]?.refreshCount, 1, "absent member falls back to the in-process fold")
        XCTAssertEqual(store.localSnapshots["a"]?.plan, "child-a")
        XCTAssertEqual(store.localSnapshots["b"]?.plan, "in-process-b")
    }

    func testChildSpawnFailureFallsBackToInProcessFold() async {
        let (store, runtimes, _) = makeStore(runtimeIDs: ["a", "b"])
        let runner = attachRunner(store, outcome: .exit(exitCode: 4, stderr: "quotabar: boom"))

        await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await store.refreshAll(force: true)
        }

        XCTAssertEqual(runner.spawnCount, 1)
        XCTAssertEqual(runtimes["a"]?.refreshCount, 1)
        XCTAssertEqual(runtimes["b"]?.refreshCount, 1, "spawn failure folds every member in-process")
    }
}
