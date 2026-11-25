import XCTest
@testable import QuotaBar

/// Records engine batch requests and replays a canned response, so the store's batched fold path
/// is exercised without touching the real provider corpora.
@MainActor
private final class RecordingEngineBatch: @unchecked Sendable {
    enum Outcome {
        case success(RustEngine.BatchResponse)
        case failure(String)
    }

    private(set) var callCount = 0
    private(set) var providerIDs: [String] = []
    private(set) var configsByProviderID: [[String: [String: Any]]] = []
    private(set) var scopes: [ProviderRefreshContext.Scope] = []
    private(set) var pacedValues: [Bool] = []
    private let outcome: Outcome

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    func execute(
        items: [RustEngine.BatchItem],
        scope: ProviderRefreshContext.Scope,
        paced: Bool
    ) async throws -> RustEngine.BatchResponse {
        callCount += 1
        providerIDs = items.map(\.providerID)
        configsByProviderID.append(
            Dictionary(uniqueKeysWithValues: items.compactMap { item in
                item.config.map { (item.providerID, $0) }
            })
        )
        scopes.append(scope)
        pacedValues.append(paced)
        switch outcome {
        case .success(let response): return response
        case .failure(let message): throw EngineFoldBatchError(message: message)
        }
    }
}

@MainActor
final class EngineBatchStorePrefetchTests: XCTestCase {
    private final class RecordingRuntime: ProviderRuntime {
        let provider: Provider
        let widgetDescriptors: [WidgetDescriptor]
        private(set) var refreshCount = 0
        let planMarker: String
        let engineConfig: EngineProviderConfig?

        init(id: String, planMarker: String, engineConfig: EngineProviderConfig? = nil) {
            let provider = Provider(id: id, displayName: id.uppercased(), icon: .providerMark("codex"))
            self.provider = provider
            self.widgetDescriptors = [
                WidgetDescriptor.percent(id: "\(id).session", provider: provider, title: "Session")
                    .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "test"),
            ]
            self.planMarker = planMarker
            self.engineConfig = engineConfig
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
        seededIdentityKey: String? = nil,
        engineConfigs: [String: EngineProviderConfig] = [:]
    ) -> (WidgetDataStore, [String: RecordingRuntime], ProviderSnapshotCache) {
        let suiteName = "OpenUsageTests.Prefetch.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        let runtimes = Dictionary(uniqueKeysWithValues: runtimeIDs.map { id in
            (id, RecordingRuntime(id: id, planMarker: "in-process-\(id)", engineConfig: engineConfigs[id]))
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

    private func attachBatch(
        _ store: WidgetDataStore,
        outcome: RecordingEngineBatch.Outcome
    ) -> RecordingEngineBatch {
        let recorder = RecordingEngineBatch(outcome: outcome)
        store.foldBatch = EngineFoldBatchClient(batchExecutor: recorder.execute)
        return recorder
    }

    private func snapshot(for provider: Provider, plan: String, refreshedAt: Date = Date()) -> ProviderSnapshot {
        ProviderSnapshot.make(provider: provider, plan: plan, lines: [], refreshedAt: refreshedAt)
    }

    private func response(
        _ snapshots: [String: ProviderSnapshot],
        errors: [String: String] = [:],
        identityKeys: [String: String] = [:]
    ) -> RustEngine.BatchResponse {
        RustEngine.BatchResponse(snapshots: snapshots, errors: errors, identityKeys: identityKeys)
    }

    func testStaleProvidersFoldInSingleEngineBatchWithoutTouchingRuntimes() async throws {
        let (store, runtimes, _) = makeStore(runtimeIDs: ["a", "b"])
        let recorder = attachBatch(store, outcome: .success(response([
            "a": snapshot(for: runtimes["a"]!.provider, plan: "batch-a"),
            "b": snapshot(for: runtimes["b"]!.provider, plan: "batch-b"),
        ], identityKeys: ["a": "identity-a", "b": "identity-b"])))

        await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await store.refreshAll(force: true)
        }

        XCTAssertEqual(recorder.callCount, 1, "one engine batch folds the whole provider set")
        XCTAssertEqual(recorder.providerIDs, ["a", "b"])
        XCTAssertEqual(recorder.scopes, [.panelAccounting])
        XCTAssertEqual(runtimes["a"]?.refreshCount, 0, "batch-covered members must not fold through their runtimes")
        XCTAssertEqual(runtimes["b"]?.refreshCount, 0)
        XCTAssertEqual(store.localSnapshots["a"]?.plan, "batch-a")
        XCTAssertEqual(store.localSnapshots["b"]?.plan, "batch-b")
    }

    func testFreshMemberIsExcludedFromEngineBatchAndKeepsCachedValue() async throws {
        let (store, runtimes, cache) = makeStore(runtimeIDs: ["a", "b"])
        var cachedSnapshot = snapshot(for: runtimes["a"]!.provider, plan: "cached-a")
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
        let recorder = attachBatch(store, outcome: .success(response([
            "b": snapshot(for: runtimes["b"]!.provider, plan: "batch-b"),
        ])))

        await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await store.refreshAll()
        }
        XCTAssertEqual(recorder.callCount, 1)
        XCTAssertEqual(recorder.providerIDs, ["b"], "the TTL-fresh member is not handed to the batch")
        XCTAssertEqual(runtimes["a"]?.refreshCount, 0)
        XCTAssertEqual(runtimes["b"]?.refreshCount, 0)
        XCTAssertNotNil(store.localSnapshots["a"])
        XCTAssertEqual(store.localSnapshots["a"]?.refreshedAt, cachedSnapshot.refreshedAt)
        XCTAssertEqual(store.localSnapshots["b"]?.plan, "batch-b")
    }

    /// A delegated Antigravity fold produces machine-local history only — it can never prove which
    /// Google account owns the cached quota. Even when a response reports an unresolved identity,
    /// the fold must not re-stamp or clear the live quota: the persisted entry, its account stamp,
    /// and the in-memory card keep the original meters and pick up only the new history.
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
        let batchSnapshot = ProviderSnapshot.make(
            provider: runtimes["antigravity"]!.provider,
            plan: nil,
            lines: [],
            refreshedAt: Date(),
            usageHistory: ProviderUsageHistory(series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-10-14", totalTokens: 42, costUSD: 0.42)
            ]))
        )
        let recorder = attachBatch(store, outcome: .success(response(
            ["antigravity": batchSnapshot],
            identityKeys: ["antigravity": AntigravityAuthStore.unresolvedCacheIdentityKey]
        )))

        await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await store.refreshAll(force: true)
        }

        XCTAssertEqual(recorder.callCount, 1)
        XCTAssertEqual(runtimes["antigravity"]?.refreshCount, 0)
        XCTAssertEqual(cache.producedByIdentityKey(providerID: "antigravity"), "google-acct-A")
        let persisted = cache.loadSnapshots(providerIDs: ["antigravity"])["antigravity"]
        XCTAssertEqual(persisted?.plan, "Pro")
        XCTAssertEqual(
            persisted?.line(label: "Session"),
            .progress(label: "Session", used: 30, limit: 100, format: .percent)
        )
        XCTAssertEqual(persisted?.quotaRefreshedAt, originalQuotaStamp)
        XCTAssertEqual(persisted?.usageHistory?.series.daily.first?.totalTokens, 42)
        let current = store.localSnapshots["antigravity"]
        XCTAssertEqual(current?.plan, "Pro")
        XCTAssertEqual(
            current?.line(label: "Session"),
            .progress(label: "Session", used: 30, limit: 100, format: .percent)
        )
        XCTAssertEqual(current?.quotaRefreshedAt, originalQuotaStamp)
        XCTAssertEqual(current?.usageHistory?.series.daily.first?.totalTokens, 42)
    }

    func testAccountScopedEngineConfigsAreIncludedInBatchItems() async throws {
        let configA = EngineProviderConfig([
            "cardID": "claude@acct-a",
            "expectedIdentityKey": "user-a|org-a",
            "organizationUUID": "org-a",
        ])
        let configB = EngineProviderConfig([
            "cardID": "claude@acct-b",
            "expectedIdentityKey": "user-b|org-b",
            "organizationUUID": "org-b",
        ])
        let (store, runtimes, _) = makeStore(
            runtimeIDs: ["claude@acct-a", "claude@acct-b"],
            engineConfigs: ["claude@acct-a": configA, "claude@acct-b": configB]
        )
        let recorder = attachBatch(store, outcome: .success(response([
            "claude@acct-a": snapshot(for: runtimes["claude@acct-a"]!.provider, plan: "batch-a"),
            "claude@acct-b": snapshot(for: runtimes["claude@acct-b"]!.provider, plan: "batch-b"),
        ])))

        await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await store.refreshAll(force: true)
        }

        XCTAssertEqual(recorder.callCount, 1)
        let configs = try XCTUnwrap(recorder.configsByProviderID.first)
        XCTAssertEqual(configs["claude@acct-a"]?["cardID"] as? String, "claude@acct-a")
        XCTAssertEqual(configs["claude@acct-a"]?["expectedIdentityKey"] as? String, "user-a|org-a")
        XCTAssertEqual(configs["claude@acct-b"]?["cardID"] as? String, "claude@acct-b")
        XCTAssertEqual(configs["claude@acct-b"]?["organizationUUID"] as? String, "org-b")
        XCTAssertEqual(runtimes["claude@acct-a"]?.refreshCount, 0)
        XCTAssertEqual(runtimes["claude@acct-b"]?.refreshCount, 0)
    }

    func testBatchDroppingAMemberFallsBackToProviderRuntime() async throws {
        let (store, runtimes, _) = makeStore(runtimeIDs: ["a", "b"])
        let recorder = attachBatch(store, outcome: .success(response([
            "a": snapshot(for: runtimes["a"]!.provider, plan: "batch-a"),
        ])))

        await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await store.refreshAll(force: true)
        }

        XCTAssertEqual(recorder.callCount, 1)
        XCTAssertEqual(runtimes["a"]?.refreshCount, 0)
        XCTAssertEqual(runtimes["b"]?.refreshCount, 1, "absent member falls back to its provider runtime")
        XCTAssertEqual(store.localSnapshots["a"]?.plan, "batch-a")
        XCTAssertEqual(store.localSnapshots["b"]?.plan, "in-process-b")
    }

    func testEngineBatchFailureFallsBackToProviderRuntimes() async {
        let (store, runtimes, _) = makeStore(runtimeIDs: ["a", "b"])
        let recorder = attachBatch(store, outcome: .failure("engine exploded"))

        await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await store.refreshAll(force: true)
        }

        XCTAssertEqual(recorder.callCount, 1)
        XCTAssertEqual(runtimes["a"]?.refreshCount, 1)
        XCTAssertEqual(runtimes["b"]?.refreshCount, 1, "batch failure folds every member through its runtime")
    }
}
