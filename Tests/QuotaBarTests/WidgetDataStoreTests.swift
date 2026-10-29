import XCTest
@testable import QuotaBar

@MainActor
final class WidgetDataStoreTests: XCTestCase {
    func testBackgroundTaskCreatedDuringManualRefreshDoesNotInheritKeychainPermission() async {
        let context = await withManualRefresh {
            await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
                await ProviderRefreshContext.$accountingCPUThrottleEnabled.withValue(true) {
                    await ProviderRefreshContext.$accountingCPUInteractiveBudgetEnabled.withValue(true) {
                        await ProviderRefreshContext.$skipModelCatalogRefresh.withValue(true) {
                            let task = ProviderRefreshContext.withBackgroundContext {
                                Task {
                                    (
                                        ProviderRefreshContext.scope,
                                        ProviderRefreshContext.isManual,
                                        ProviderRefreshContext.credentialInteractionGate != nil,
                                        ProviderRefreshContext.manualActionID != nil,
                                        ProviderRefreshContext.accountingCPUThrottleEnabled,
                                        ProviderRefreshContext.accountingCPUInteractiveBudgetEnabled,
                                        ProviderRefreshContext.skipModelCatalogRefresh
                                    )
                                }
                            }
                            return await task.value
                        }
                    }
                }
            }
        }

        XCTAssertEqual(context.0, .full)
        XCTAssertFalse(context.1)
        XCTAssertFalse(context.2)
        XCTAssertFalse(context.3)
        XCTAssertFalse(context.4)
        XCTAssertFalse(context.5)
        XCTAssertFalse(context.6)
    }

    func testCatalogReloadCancelsEveryProviderRefresh() async {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor.percent(id: "test.session", provider: provider, title: "Session")
        let runtime = CatalogReloadCancellationRuntime(provider: provider, descriptors: [descriptor])
        let defaults = makeUserDefaults("catalog-reload-cancel")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600),
            defaults: defaults
        )
        let refresh = Task { await store.refresh(providerID: provider.id, force: true, bypassSnapshotCache: true) }
        for _ in 0..<1_000 where !runtime.didStart { await Task.yield() }
        XCTAssertTrue(runtime.didStart)

        store.cancelActiveProviderRefreshesForCatalogReload()

        let outcome = await refresh.value
        XCTAssertEqual(outcome, .skipped)
        XCTAssertTrue(runtime.observedCancellation)
    }

    func testOpenCodeQuotaInvalidationKeepsLocalHistoryAcrossCatalogReload() {
        let provider = Provider(id: "opencode", displayName: "OpenCode", icon: .providerMark("opencode"))
        let session = WidgetDescriptor.percent(id: "opencode.session", provider: provider, title: "Session")
        let accountSession = WidgetDescriptor.percent(
            id: "opencode.session.account.work", provider: provider, title: "Session (Work)"
        )
        let today = WidgetDescriptor.spendTiles(provider: provider).first { $0.metricLabel == "Today" }!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: "Go",
            lines: [
                .progress(label: "Session", used: 30, limit: 100, format: .percent),
                .progress(label: "Session (Work)", used: 70, limit: 100, format: .percent),
                .values(label: "Today", values: [MetricValue(number: 5, kind: .dollars, label: "spend")])
            ],
            refreshedAt: now,
            usageHistory: ProviderUsageHistory(series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-10-14", totalTokens: 500, costUSD: 5)
            ]))
        )
        let defaults = makeUserDefaults("catalog-reload-opencode-cache")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { now })
        cache.store(previous, producedByIdentityKey: nil)
        let registry = WidgetRegistry(providers: [provider], descriptors: [session, accountSession, today])
        let runtime = SequenceProviderRuntime(provider: provider, descriptors: [session, accountSession, today], snapshots: [])
        let store = WidgetDataStore(registry: registry, providers: [runtime], cache: cache, defaults: defaults, now: { now })

        store.invalidateQuotaStateForCatalogReload(providerID: provider.id)

        let replacement = WidgetDataStore(registry: registry, providers: [runtime], cache: cache, defaults: defaults, now: { now })
        let reloaded = replacement.localSnapshots[provider.id]
        XCTAssertNil(reloaded?.plan)
        XCTAssertNil(reloaded?.line(label: "Session"))
        XCTAssertNil(reloaded?.line(label: "Session (Work)"))
        XCTAssertNotNil(reloaded?.line(label: "Today"))
        XCTAssertEqual(reloaded?.usageHistory?.series.daily.first?.totalTokens, 500)
    }

    func testOpenCodeAccountSelectionInvalidationClearsCachedMetersBeforeSelectionRefresh() {
        let provider = Provider(id: "opencode", displayName: "OpenCode", icon: .providerMark("opencode"))
        let session = WidgetDescriptor.percent(id: "opencode.session", provider: provider, title: "Session")
        let today = WidgetDescriptor.spendTiles(provider: provider).first { $0.metricLabel == "Today" }!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: "Go",
            lines: [
                .progress(label: "Session", used: 65, limit: 100, format: .percent),
                .values(label: "Today", values: [MetricValue(number: 5, kind: .dollars, label: "spend")])
            ],
            refreshedAt: now,
            usageHistory: ProviderUsageHistory(series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-10-14", totalTokens: 500, costUSD: 5)
            ]))
        )
        let defaults = makeUserDefaults("opencode-selection-invalidation")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { now })
        cache.store(previous)
        let registry = WidgetRegistry(providers: [provider], descriptors: [session, today])
        let runtime = SequenceProviderRuntime(provider: provider, descriptors: [session, today], snapshots: [])
        let store = WidgetDataStore(registry: registry, providers: [runtime], cache: cache, defaults: defaults, now: { now })

        store.invalidateQuotaStateForAccountSelectionChange(providerID: provider.id)

        let replacement = WidgetDataStore(registry: registry, providers: [runtime], cache: cache, defaults: defaults, now: { now })
        let reloaded = replacement.localSnapshots[provider.id]
        XCTAssertNil(reloaded?.plan)
        XCTAssertNil(reloaded?.line(label: "Session"))
        XCTAssertNotNil(reloaded?.line(label: "Today"))
        XCTAssertEqual(reloaded?.usageHistory?.series.daily.first?.totalTokens, 500)
    }

    func testInFlightProviderRefreshIsDeferredAndSignaledWhenConflictCompletes() async {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor.percent(id: "test.session", provider: provider, title: "Session")
        let runtime = SuspendedProviderRuntime(provider: provider, descriptors: [descriptor])
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(
                userDefaults: makeUserDefaults("deferred-refresh-cache"),
                storageKey: "snapshots",
                ttl: 300
            ),
            defaults: makeUserDefaults("deferred-refresh-store")
        )
        var ready: [WidgetDataStore.DeferredRefreshRequest] = []
        store.onDeferredRefreshReady = { ready.append($0) }

        let fullRefresh = Task {
            await ProviderRefreshContext.$scope.withValue(.full) {
                await store.refresh(providerID: provider.id, force: true)
            }
        }
        while !runtime.didStart { await Task.yield() }

        let outcome = await ProviderRefreshContext.$scope.withValue(.panelMeters) {
            await store.refresh(providerID: provider.id)
        }
        XCTAssertEqual(outcome, .inFlight)
        XCTAssertTrue(ready.isEmpty, "the request remains queued while a full refresh owns the provider")

        runtime.resume()
        let fullOutcome = await fullRefresh.value
        XCTAssertEqual(fullOutcome, .refreshed)
        XCTAssertEqual(ready, [WidgetDataStore.DeferredRefreshRequest(
            providerID: provider.id,
            scope: .panelMeters,
            bypassSnapshotCache: false,
            bypassFailureBackoff: false,
            requestGeneration: 0
        )])
    }

    func testForcedPanelMeterRetryOverlapsHeldAccountingFoldAndPreservesNewMeters() async throws {
        for foldScope in [ProviderRefreshContext.Scope.localAccounting, .panelAccounting] {
            let provider = Provider(id: "antigravity", displayName: "Antigravity", icon: .providerMark("antigravity"))
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let meter = WidgetDescriptor.percent(id: "antigravity.session", provider: provider, title: "Session")
            let historyDescriptor = WidgetDescriptor.usageTrend(provider: provider).exportingHistory(
                scope: .machineLocal,
                estimatedCost: true,
                sourceNote: "local"
            )
            let history = ProviderUsageHistory(series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-10-13", totalTokens: 18, costUSD: 0.08)
            ]))
            let freshMeters = ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                plan: "Fresh plan",
                lines: [.progress(label: "Session", used: 44, limit: 100, format: .percent)],
                refreshedAt: now
            )
            // This fold began before the meter retry and carries no quota work. Its completion must
            // merge against the newer local snapshot instead of replacing the retry's live meters.
            let staleFold = ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [],
                refreshedAt: now.addingTimeInterval(-60),
                usageHistory: history
            )
            let runtime = PanelMeterOverlapProviderRuntime(
                provider: provider,
                descriptors: [meter, historyDescriptor],
                freshMeters: freshMeters,
                staleFold: staleFold
            )
            let store = WidgetDataStore(
                registry: WidgetRegistry(providers: [provider], descriptors: [meter, historyDescriptor]),
                providers: [runtime],
                cache: ProviderSnapshotCache(
                    userDefaults: makeUserDefaults("forced-panel-meter-overlap-\(foldScope)"),
                    storageKey: "snapshots",
                    ttl: 600,
                    now: { now }
                ),
                defaults: makeUserDefaults("forced-panel-meter-overlap-store-\(foldScope)"),
                now: { now }
            )
            let foldStarted = expectation(description: "\(foldScope) fold started")
            let metersStarted = expectation(description: "forced panel meters started during \(foldScope) fold")
            runtime.onFoldStart = { foldStarted.fulfill() }
            runtime.onPanelMetersStart = { metersStarted.fulfill() }

            let foldTask = Task {
                await ProviderRefreshContext.$scope.withValue(foldScope) {
                    await store.refresh(providerID: provider.id, force: true, bypassSnapshotCache: true)
                }
            }
            await fulfillment(of: [foldStarted], timeout: 1)

            let retryTask = Task {
                await ProviderRefreshContext.$scope.withValue(.panelMeters) {
                    await store.refresh(providerID: provider.id, force: true, bypassSnapshotCache: true)
                }
            }
            await fulfillment(of: [metersStarted], timeout: 1)
            let metersStartedBeforeFoldFinished = runtime.didStartPanelMeters && !runtime.didFinishFold

            var retryOutcome: WidgetDataStore.RefreshOutcome
            if metersStartedBeforeFoldFinished {
                // The quota retry must finish while local history is still held, which proves it is
                // not waiting for the fold's provider deadline or completion.
                retryOutcome = await retryTask.value
                XCTAssertFalse(runtime.didFinishFold)
                let interim = try XCTUnwrap(store.localSnapshots[provider.id])
                XCTAssertEqual(interim.line(label: "Session"), freshMeters.line(label: "Session"))
                runtime.resumeFold()
            } else {
                // Release the fold on the old serialized path as well, so a regression reports as an
                // assertion failure instead of leaving a suspended provider task behind.
                runtime.resumeFold()
                retryOutcome = await retryTask.value
            }
            let foldOutcome = await foldTask.value

            XCTAssertTrue(
                metersStartedBeforeFoldFinished,
                "an explicit panel-meter retry must overlap the fold-only \(foldScope) scope"
            )
            XCTAssertEqual(retryOutcome, .refreshed)
            XCTAssertEqual(foldOutcome, .refreshed)
            let final = try XCTUnwrap(store.localSnapshots[provider.id])
            XCTAssertEqual(final.plan, "Fresh plan")
            XCTAssertEqual(final.line(label: "Session"), freshMeters.line(label: "Session"))
            XCTAssertEqual(final.usageHistory, history)
            XCTAssertEqual(final.quotaRefreshedAt, freshMeters.refreshedAt)
        }
    }

    func testDeferredVisibleRetryPreservesFailureBackoffBypass() async throws {
        let provider = Provider(id: "antigravity", displayName: "Antigravity", icon: .providerMark("antigravity"))
        let meter = WidgetDescriptor.percent(id: "antigravity.session", provider: provider, title: "Session")
        let history = WidgetDescriptor.usageTrend(provider: provider).exportingHistory(
            scope: .machineLocal,
            estimatedCost: true,
            sourceNote: "local"
        )
        let runtime = SuspendedProviderRuntime(provider: provider, descriptors: [meter, history])
        let defaults = makeUserDefaults("deferred-history-retry-bypass")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [meter, history]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600),
            defaults: defaults
        )
        var ready: [WidgetDataStore.DeferredRefreshRequest] = []
        store.onDeferredRefreshReady = { ready.append($0) }

        let meterRefresh = Task {
            await ProviderRefreshContext.$scope.withValue(.panelMeters) {
                await store.refresh(providerID: provider.id, force: true)
            }
        }
        while !runtime.didStart { await Task.yield() }

        let foldRetry = try await withManualRefresh {
            let manualActionID = try XCTUnwrap(ProviderRefreshContext.manualActionID)
            let interactionGate = try XCTUnwrap(ProviderRefreshContext.credentialInteractionGate)
            let outcome = await store.refreshProviderHistoryAfterRetry(
                providerID: provider.id,
                manualActionID: manualActionID,
                credentialInteractionGate: interactionGate
            )
            return (outcome, manualActionID, interactionGate)
        }
        XCTAssertEqual(foldRetry.0, .inFlight)
        runtime.resume()
        _ = await meterRefresh.value

        XCTAssertEqual(ready, [WidgetDataStore.DeferredRefreshRequest(
            providerID: provider.id,
            scope: .panelAccounting,
            bypassSnapshotCache: true,
            bypassFailureBackoff: true,
            requestGeneration: 1,
            manualActionID: foldRetry.1,
            credentialInteractionGate: foldRetry.2
        )])

        let resumed = await store.resumeDeferredManualHistoryRetry(try XCTUnwrap(ready.first))
        XCTAssertEqual(resumed, .refreshed)
        XCTAssertEqual(runtime.observedScopes.last, .panelAccounting)
        XCTAssertEqual(runtime.observedManualValues.last, true)
        XCTAssertEqual(runtime.observedManualActionIDs.compactMap { $0 }.last, foldRetry.1)
        let observedGate = try XCTUnwrap(runtime.observedInteractionGates.last ?? nil)
        XCTAssertTrue(observedGate === foldRetry.2)
        XCTAssertEqual(runtime.observedThrottleValues.last, true)
    }

    func testDisablingProviderInvalidatesReadyManualHistoryRetryAfterReenable() async throws {
        let enablement = ProviderEnablementStore(defaults: makeUserDefaults("disable-deferred-retry-enablement"))
        let provider = Provider(id: "antigravity", displayName: "Antigravity", icon: .providerMark("antigravity"))
        enablement.setEnabled(true, for: provider.id)
        let meter = WidgetDescriptor.percent(id: "antigravity.session", provider: provider, title: "Session")
        let history = WidgetDescriptor.usageTrend(provider: provider).exportingHistory(
            scope: .machineLocal,
            estimatedCost: true,
            sourceNote: "local"
        )
        let runtime = SuspendedProviderRuntime(provider: provider, descriptors: [meter, history])
        let defaults = makeUserDefaults("disable-deferred-retry-store")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [meter, history]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600),
            defaults: defaults,
            isProviderEnabled: { enablement.isEnabled($0) }
        )
        let wakeSignal = RefreshWakeSignal(
            name: Notification.Name("QuotaBarTests.deferredHistoryRetry"),
            center: NotificationCenter()
        )
        var readyRequest: WidgetDataStore.DeferredRefreshRequest?
        store.onDeferredRefreshReady = { request in
            readyRequest = request
            wakeSignal.signalDeferredRefreshReady(request)
        }
        store.onDeferredRefreshesInvalidated = { providerIDs in
            wakeSignal.cancelDeferredRefreshes(forProviderIDs: providerIDs)
        }
        enablement.onChange = { changedProviderIDs in
            store.providerEnablementDidChange(changedProviderIDs: changedProviderIDs)
        }

        let meterRefresh = Task {
            await ProviderRefreshContext.$scope.withValue(.panelMeters) {
                await store.refresh(providerID: provider.id, force: true)
            }
        }
        while !runtime.didStart { await Task.yield() }

        let deferred = try await withManualRefresh {
            let manualActionID = try XCTUnwrap(ProviderRefreshContext.manualActionID)
            let interactionGate = try XCTUnwrap(ProviderRefreshContext.credentialInteractionGate)
            let outcome = await store.refreshProviderHistoryAfterRetry(
                providerID: provider.id,
                manualActionID: manualActionID,
                credentialInteractionGate: interactionGate
            )
            return (outcome, manualActionID, interactionGate)
        }
        XCTAssertEqual(deferred.0, .inFlight)

        runtime.resume()
        _ = await meterRefresh.value
        let request = try XCTUnwrap(readyRequest)
        XCTAssertEqual(request.manualActionID, deferred.1)
        let requestGate = try XCTUnwrap(request.credentialInteractionGate)
        XCTAssertTrue(requestGate === deferred.2)

        // Disable and re-enable before the scheduler consumes the ready request. The old action's
        // prompt allowance and provider generation must not become valid again on re-enable.
        enablement.setEnabled(false, for: provider.id)
        enablement.setEnabled(true, for: provider.id)
        XCTAssertEqual(wakeSignal.takePendingDeferredRefreshes().count, 0)
        let resumed = await store.resumeDeferredManualHistoryRetry(request)
        XCTAssertEqual(resumed, .skipped)
        let latePhase = await store.refreshProviderHistoryAfterRetry(
            providerID: provider.id,
            manualActionID: deferred.1,
            credentialInteractionGate: deferred.2
        )
        XCTAssertEqual(latePhase, .skipped, "a disabled provider's original manual action stays revoked after re-enable")
        XCTAssertEqual(runtime.observedScopes, [.panelMeters])
    }

    func testDisablingProviderDropsQueuedManualHistoryRetryBeforeItBecomesReady() async throws {
        let enablement = ProviderEnablementStore(defaults: makeUserDefaults("disable-queued-retry-enablement"))
        let provider = Provider(id: "antigravity", displayName: "Antigravity", icon: .providerMark("antigravity"))
        enablement.setEnabled(true, for: provider.id)
        let meter = WidgetDescriptor.percent(id: "antigravity.session", provider: provider, title: "Session")
        let history = WidgetDescriptor.usageTrend(provider: provider).exportingHistory(
            scope: .machineLocal,
            estimatedCost: true,
            sourceNote: "local"
        )
        let runtime = SuspendedProviderRuntime(provider: provider, descriptors: [meter, history])
        let defaults = makeUserDefaults("disable-queued-retry-store")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [meter, history]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600),
            defaults: defaults,
            isProviderEnabled: { enablement.isEnabled($0) }
        )
        var ready: [WidgetDataStore.DeferredRefreshRequest] = []
        store.onDeferredRefreshReady = { ready.append($0) }
        enablement.onChange = { changedProviderIDs in
            store.providerEnablementDidChange(changedProviderIDs: changedProviderIDs)
        }

        let meterRefresh = Task {
            await ProviderRefreshContext.$scope.withValue(.panelMeters) {
                await store.refresh(providerID: provider.id, force: true)
            }
        }
        while !runtime.didStart { await Task.yield() }

        let deferred = try await withManualRefresh {
            let manualActionID = try XCTUnwrap(ProviderRefreshContext.manualActionID)
            let interactionGate = try XCTUnwrap(ProviderRefreshContext.credentialInteractionGate)
            return await store.refreshProviderHistoryAfterRetry(
                providerID: provider.id,
                manualActionID: manualActionID,
                credentialInteractionGate: interactionGate
            )
        }
        XCTAssertEqual(deferred, .inFlight)

        enablement.setEnabled(false, for: provider.id)
        enablement.setEnabled(true, for: provider.id)
        runtime.resume()
        _ = await meterRefresh.value

        XCTAssertTrue(ready.isEmpty, "disabling the provider removes its queued manual history retry")
        XCTAssertEqual(runtime.observedScopes, [.panelMeters])
    }

    func testSupersededVisibleMeterRetrySilentlyCompletesItsHistoryFold() async throws {
        let provider = Provider(id: "antigravity", displayName: "Antigravity", icon: .providerMark("antigravity"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let meter = WidgetDescriptor.percent(id: "antigravity.session", provider: provider, title: "Session")
        let historyDescriptor = WidgetDescriptor.usageTrend(provider: provider).exportingHistory(
            scope: .machineLocal,
            estimatedCost: true,
            sourceNote: "local"
        )
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: DailyUsageAccumulator.dayKey(from: now), totalTokens: 42, costUSD: 0.02)
        ]))
        let meters = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: "Pro",
            lines: [.progress(label: "Session", used: 30, limit: 100, format: .percent)],
            refreshedAt: now
        )
        let folded = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [],
            refreshedAt: now,
            usageHistory: history
        )
        let runtime = SequenceProviderRuntime(
            provider: provider,
            descriptors: [meter, historyDescriptor],
            snapshots: [meters, folded]
        )
        let defaults = makeUserDefaults("superseded-visible-meter-retry-fold")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [meter, historyDescriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { now }),
            defaults: defaults,
            now: { now }
        )
        let gate = KeychainPermissionGate.shared
        let supersededAction = gate.beginManualAction()
        _ = gate.beginManualAction()

        let firstAttempt = await withThrottledPanelMeters {
            await ProviderRefreshContext.$manualActionID.withValue(supersededAction) {
                await store.refresh(providerID: provider.id, force: true)
            }
        }

        XCTAssertEqual(firstAttempt, .skipped)
        for _ in 0..<2_000 where store.localSnapshots[provider.id]?.usageHistory != history {
            try await Task.sleep(for: .milliseconds(1))
        }

        XCTAssertEqual(runtime.refreshCount, 2, "the silent retry should fetch meters and then fold local history")
        XCTAssertEqual(runtime.observedScopes, [.panelMeters, .panelAccounting])
        XCTAssertEqual(runtime.observedManualValues, [false, false])
        XCTAssertEqual(runtime.observedThrottleValues, [true, true])
        XCTAssertEqual(runtime.observedInteractiveBudgetValues, [true, true])
        XCTAssertEqual(runtime.observedCPUFractions, [0.25, 0.25])
        let snapshot = try XCTUnwrap(store.localSnapshots[provider.id])
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(snapshot.line(label: "Session"), meters.line(label: "Session"))
        XCTAssertEqual(snapshot.usageHistory, history)
    }

    func testSupersededHermesMeterRetryUsesInteractiveBudgetWithoutDuplicateFold() async throws {
        let provider = Provider(id: "hermes", displayName: "Hermes", icon: .providerMark("hermes"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let meter = WidgetDescriptor.percent(id: "hermes.session", provider: provider, title: "Session")
        let historyDescriptor = WidgetDescriptor.usageTrend(provider: provider).exportingHistory(
            scope: .machineLocal,
            estimatedCost: true,
            sourceNote: "local"
        )
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: DailyUsageAccumulator.dayKey(from: now), totalTokens: 42, costUSD: 0.02)
        ]))
        let snapshot = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Session", used: 30, limit: 100, format: .percent)],
            refreshedAt: now,
            usageHistory: history
        )
        let runtime = SequenceProviderRuntime(
            provider: provider,
            descriptors: [meter, historyDescriptor],
            snapshots: [snapshot],
            panelMetersRefreshIncludesHistory: true
        )
        let defaults = makeUserDefaults("superseded-hermes-retry-pacing")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [meter, historyDescriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { now }),
            defaults: defaults,
            now: { now }
        )
        let gate = KeychainPermissionGate.shared
        let supersededAction = gate.beginManualAction()
        _ = gate.beginManualAction()

        let firstAttempt = await withThrottledPanelMeters {
            await ProviderRefreshContext.$manualActionID.withValue(supersededAction) {
                await store.refresh(providerID: provider.id, force: true)
            }
        }

        XCTAssertEqual(firstAttempt, .skipped)
        for _ in 0..<2_000 where store.localSnapshots[provider.id]?.usageHistory == nil {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(runtime.refreshCount, 1, "Hermes' meter pass already includes its SQLite history scan")
        XCTAssertEqual(runtime.observedScopes, [.panelMeters])
        XCTAssertEqual(runtime.observedManualValues, [false])
        XCTAssertEqual(runtime.observedThrottleValues, [true])
        XCTAssertEqual(runtime.observedInteractiveBudgetValues, [true])
        XCTAssertEqual(runtime.observedCPUFractions, [0.25])
        XCTAssertEqual(store.localSnapshots[provider.id]?.usageHistory, history)
    }

    /// The cache's freshness gate reads the OLDER of `refreshedAt` and `quotaRefreshedAt`. A
    /// fold-only pass (`.localAccounting` / `.panelAccounting`) writes a fresh `refreshedAt` while
    /// carrying meters the live quota API answered hours ago; gating on `refreshedAt` alone let a
    /// closed-panel ledger wake (one per routed turn) keep such a snapshot TTL-fresh forever, so
    /// panel-open passes cache-hit and the subscription meters never updated (regression: meter %
    /// stuck all day while routing continued).
    func testSnapshotCacheFreshnessReadsTheOlderMeterStamp() {
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let defaults = makeUserDefaults("cache-meter-stamp-gate")
        var clock = Date(timeIntervalSince1970: 10_000)
        let cache = ProviderSnapshotCache(
            userDefaults: defaults,
            storageKey: "snapshots",
            ttl: 300,
            now: { clock }
        )

        // A meters-only pass answered the live API at T=10_000.
        var fresh = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Session", used: 5, limit: 100, format: .percent)],
            refreshedAt: clock
        )
        cache.store(fresh)
        XCTAssertNotNil(cache.snapshot(providerID: provider.id))

        // A fold-only pass 200s later re-stamps refreshedAt but recovers the meters' stamp.
        clock = Date(timeIntervalSince1970: 10_200)
        fresh.refreshedAt = clock
        fresh.quotaRefreshedAt = Date(timeIntervalSince1970: 10_000)
        cache.store(fresh)
        XCTAssertNotNil(cache.snapshot(providerID: provider.id), "meter stamp still within TTL")

        // 200s further: refreshedAt is young (100s old) but the meter stamp is 400s old — past
        // TTL. The older stamp governs, so the entry is stale and the next pass refetches meters.
        clock = Date(timeIntervalSince1970: 10_400)
        XCTAssertNil(cache.snapshot(providerID: provider.id),
                     "recovered meters must age out by their own stamp, not the fold's clock")

        // A fold that also produced a fresh meter fetch (panelMeters phase) is fresh by both.
        clock = Date(timeIntervalSince1970: 10_500)
        fresh.refreshedAt = clock
        fresh.quotaRefreshedAt = clock
        cache.store(fresh)
        XCTAssertNotNil(cache.snapshot(providerID: provider.id))
    }

    /// The panel's accounting phase must fall through to the fold when the cached snapshot carries
    /// NO history at all (fresh install / newly enabled provider): otherwise the phase would
    /// cache-hit on the meters-only phase's write and the first fold would never run.
    func testPanelAccountingFoldsWhenCacheHasNoHistory() async {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        var descriptor = WidgetDescriptor.percent(
            id: "test.session", provider: provider, title: "Session"
        )
        descriptor = descriptor.exportingHistory(
            scope: .machineLocal,
            estimatedCost: false,
            sourceNote: "test"
        )
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: "2026-10-11", totalTokens: 10, costUSD: 0.05)
        ]))
        let defaults = makeUserDefaults("panel-accounting-no-history")
        let cache = ProviderSnapshotCache(
            userDefaults: defaults,
            storageKey: "snapshots",
            ttl: 600,
            now: { Date() }
        )
        // Phase 1's write: meters only, no history, no carry marker.
        cache.store(ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Session", used: 5, limit: 100, format: .percent)],
            refreshedAt: Date()
        ))
        let runtime = CountingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Session", used: 6, limit: 100, format: .percent)],
                refreshedAt: Date(),
                usageHistory: history
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: cache,
            defaults: makeUserDefaults("panel-accounting-no-history-store")
        )

        await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await store.refreshAll()
        }

        XCTAssertEqual(runtime.refreshCount, 1, "no cached history — the fold must run")
        XCTAssertNotNil(store.localSnapshots[provider.id]?.usageHistory)
    }

    /// And the mirror: a cached snapshot WITH history and no carry marker is the fold pass's own
    /// fresh work — the accounting phase cache-hits within the TTL instead of refolding.
    func testPanelAccountingCacheHitsFreshFold() async {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        var descriptor = WidgetDescriptor.percent(
            id: "test.session", provider: provider, title: "Session"
        )
        descriptor = descriptor.exportingHistory(
            scope: .machineLocal,
            estimatedCost: false,
            sourceNote: "test"
        )
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: "2026-10-11", totalTokens: 10, costUSD: 0.05)
        ]))
        let defaults = makeUserDefaults("panel-accounting-fresh-fold")
        let cache = ProviderSnapshotCache(
            userDefaults: defaults,
            storageKey: "snapshots",
            ttl: 600,
            now: { Date() }
        )
        cache.store(ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Session", used: 5, limit: 100, format: .percent)],
            refreshedAt: Date(),
            usageHistory: history
        ))
        let runtime = CountingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Session", used: 6, limit: 100, format: .percent)],
                refreshedAt: Date(),
                usageHistory: history
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: cache,
            defaults: makeUserDefaults("panel-accounting-fresh-fold-store")
        )

        await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await store.refreshAll()
        }

        XCTAssertEqual(runtime.refreshCount, 0, "fresh fold within TTL — cache hit")
    }

    func testRetryHistoryPassSkipsProvidersWithoutHistoryExporters() async {
        let provider = Provider(id: "zai", displayName: "Z.AI", icon: .providerMark("zai"))
        let descriptor = WidgetDescriptor.percent(id: "zai.usage", provider: provider, title: "Usage")
        let runtime = CountingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Usage", used: 20, limit: 100, format: .percent)],
                refreshedAt: Date()
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            defaults: makeUserDefaults("retry-history-pure-api")
        )

        let outcome = await store.refreshProviderHistoryAfterRetry(providerID: provider.id, manualActionID: nil)

        XCTAssertEqual(outcome, .skipped)
        XCTAssertEqual(runtime.refreshCount, 0, "a retry must not repeat live API work for a provider with no local history")
    }

    func testRetryHistoryPassMergesFreshHistoryWithoutDroppingRecoveredQuota() async {
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        var descriptor = WidgetDescriptor.percent(id: "claude.session", provider: provider, title: "Session")
        descriptor = descriptor.exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "local")
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: "2026-10-14", totalTokens: 12, costUSD: 0.03)
        ]))
        let previous = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: "Pro",
            lines: [.progress(label: "Session", used: 15, limit: 100, format: .percent)],
            refreshedAt: Date()
        )
        let cache = ProviderSnapshotCache(
            userDefaults: makeUserDefaults("retry-history-merge-cache"),
            storageKey: "snapshots",
            ttl: 600
        )
        cache.store(previous)
        let runtime = CountingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [],
                refreshedAt: Date(),
                usageHistory: history
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: cache,
            defaults: makeUserDefaults("retry-history-merge-store")
        )

        let outcome = await store.refreshProviderHistoryAfterRetry(providerID: provider.id, manualActionID: nil)

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertEqual(runtime.refreshCount, 1)
        XCTAssertEqual(store.localSnapshots[provider.id]?.plan, "Pro")
        XCTAssertTrue(store.localSnapshots[provider.id]?.lines.contains(
            .progress(label: "Session", used: 15, limit: 100, format: .percent)
        ) == true)
        XCTAssertEqual(store.localSnapshots[provider.id]?.usageHistory, history)
    }

    /// A scheduled five-minute history pass must actually refold a fresh cached snapshot. This cache
    /// bypass stays separate from `force`, so a fold-only result still recovers quota meters.
    func testSupersededPanelFoldRetriesSilentlyWithoutDroppingQuotaMeters() async throws {
        let provider = Provider(id: "opencode", displayName: "OpenCode", icon: .providerMark("opencode"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: DailyUsageAccumulator.dayKey(from: now), totalTokens: 42, costUSD: 0.01)
        ]))
        let meter = WidgetDescriptor.percent(id: "opencode.session", provider: provider, title: "Session")
        let historyDescriptor = WidgetDescriptor.usageTrend(provider: provider).exportingHistory(
            scope: .machineLocal,
            estimatedCost: true,
            sourceNote: "local"
        )
        let previous = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: "Go",
            lines: [.progress(label: "Session", used: 27, limit: 100, format: .percent)],
            refreshedAt: now
        )
        let folded = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [],
            refreshedAt: now,
            usageHistory: history
        )
        let runtime = SequenceProviderRuntime(
            provider: provider,
            descriptors: [meter, historyDescriptor],
            snapshots: [previous, folded]
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [meter, historyDescriptor]),
            providers: [runtime],
            defaults: makeUserDefaults("superseded-panel-fold"),
            now: { now }
        )
        let first = await ProviderRefreshContext.$scope.withValue(.panelMeters) {
            await store.refresh(providerID: provider.id, force: true)
        }
        XCTAssertEqual(first, .refreshed)

        let gate = KeychainPermissionGate.shared
        let oldAction = gate.beginManualAction()
        _ = gate.beginManualAction() // a newer refresh for a different provider supersedes oldAction
        let staleFold = await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await ProviderRefreshContext.$manualActionID.withValue(oldAction) {
                await store.refresh(
                    providerID: provider.id,
                    force: false,
                    bypassSnapshotCache: true
                )
            }
        }
        XCTAssertEqual(staleFold, .skipped)

        for _ in 0..<500 where store.localSnapshots[provider.id]?.usageHistory != history {
            await Task.yield()
        }

        XCTAssertEqual(runtime.refreshCount, 2, "the stale fold is replaced by one silent local fold")
        XCTAssertEqual(store.localSnapshots[provider.id]?.plan, "Go")
        XCTAssertEqual(store.localSnapshots[provider.id]?.line(label: "Session"), previous.line(label: "Session"))
        XCTAssertEqual(store.localSnapshots[provider.id]?.usageHistory, history)
    }

    func testScheduledPanelAccountingBypassesFreshFoldCacheAndKeepsMeters() async throws {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let now = ISO8601DateFormatter().date(from: "2026-10-11T12:00:00Z")!
        var descriptor = WidgetDescriptor.percent(
            id: "test.session", provider: provider, title: "Session"
        )
        descriptor = descriptor.exportingHistory(
            scope: .machineLocal,
            estimatedCost: false,
            sourceNote: "test"
        )
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: "2026-10-11", totalTokens: 10, costUSD: 0.05)
        ]))
        let defaults = makeUserDefaults("panel-accounting-scheduled-bypass")
        let cache = ProviderSnapshotCache(
            userDefaults: defaults,
            storageKey: "snapshots",
            ttl: 600,
            now: { now }
        )
        cache.store(ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Session", used: 5, limit: 100, format: .percent)],
            refreshedAt: now,
            usageHistory: history
        ))
        let runtime = CountingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.values(label: "Today", values: [
                    MetricValue(number: 20, kind: .count, label: "tokens")
                ])],
                refreshedAt: now,
                usageHistory: history
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: cache,
            defaults: makeUserDefaults("panel-accounting-scheduled-bypass-store"),
            now: { now }
        )

        await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await store.refreshAll(bypassSnapshotCache: true)
        }

        XCTAssertEqual(runtime.refreshCount, 1, "a due history pass must not reuse the prior fold")
        let refreshed = try XCTUnwrap(store.localSnapshots[provider.id])
        XCTAssertTrue(refreshed.lines.contains { line in
            if case .progress(label: "Session", used: 5, limit: 100, format: .percent, resetsAt: nil, periodDurationMs: nil, colorHex: nil, detail: nil) = line {
                return true
            }
            return false
        }, "fold-only work must keep the cached live meter")
        XCTAssertTrue(refreshed.lines.contains { $0.label == "Today" })
    }

    func testFirstPassConcurrencyCapSerializesProviderStarts() async {
        let probe = RefreshConcurrencyProbe()
        let providers = (0..<3).map { index -> TestConcurrencyProviderRuntime in
            let provider = Provider(id: "provider-\(index)", displayName: "Provider \(index)", icon: .providerMark("codex"))
            return TestConcurrencyProviderRuntime(provider: provider, probe: probe)
        }
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: providers.map { $0.provider }, descriptors: []),
            providers: providers,
            defaults: makeUserDefaults("refresh-concurrency-cap")
        )

        await store.refreshAll(maxConcurrentProviders: 1)

        let maximumActive = await probe.maximumActive()
        let refreshCount = await probe.refreshCount()
        XCTAssertEqual(maximumActive, 1)
        XCTAssertEqual(refreshCount, 3)
    }

    func testHeavyLocalLogProvidersDoNotRunConcurrently() async {
        let probe = RefreshConcurrencyProbe()
        let providers = ["claude", "codex", "opencode"].map { id -> TestConcurrencyProviderRuntime in
            let provider = Provider(id: id, displayName: id, icon: .providerMark("codex"))
            return TestConcurrencyProviderRuntime(provider: provider, probe: probe)
        }
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: providers.map(\.provider), descriptors: []),
            providers: providers,
            defaults: makeUserDefaults("heavy-provider-concurrency")
        )

        await store.refreshAll()

        let maximumActive = await probe.maximumActive()
        let refreshCount = await probe.refreshCount()
        XCTAssertEqual(maximumActive, 1)
        XCTAssertEqual(refreshCount, 3)
    }

    func testQuotaOnlyRefreshDoesNotNotifyHistorySync() async {
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let historyDescriptor = WidgetDescriptor.usageTrend(provider: provider).exportingHistory(
            scope: .machineLocal,
            estimatedCost: true,
            sourceNote: "test"
        )
        let history = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-10-07", totalTokens: 100, costUSD: 1)
            ]),
            unknownModelsByDay: [:]
        )
        let runtime = SequenceProviderRuntime(
            provider: provider,
            descriptors: [historyDescriptor],
            snapshots: [
                ProviderSnapshot(providerID: provider.id, displayName: provider.displayName,
                                 lines: [.progress(label: "Session", used: 20, limit: 100, format: .percent)],
                                 usageHistory: history),
                ProviderSnapshot(providerID: provider.id, displayName: provider.displayName,
                                 lines: [.progress(label: "Session", used: 21, limit: 100, format: .percent)],
                                 usageHistory: history)
            ]
        )
        let defaults = makeUserDefaults("history-change-notification")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [historyDescriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults
        )
        var notificationCount = 0
        store.onLocalHistoryChanged = { notificationCount += 1 }

        await store.refreshAll(force: true)
        await store.refreshAll(force: true)

        XCTAssertEqual(notificationCount, 1, "the quota row changes, but the history payload does not")
    }

    func testLoadedHistoryBoundsTotalsToTenYearsAndDetailsToThirtyDays() {
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 12))!
        let ancientDay = "2000-01-01"
        let olderDetailDay = "2026-08-01"
        let recentDay = "2026-10-01"
        let history = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: ancientDay, totalTokens: 1, costUSD: 0.01),
                DailyUsageEntry(date: olderDetailDay, totalTokens: 2, costUSD: 0.02),
                DailyUsageEntry(date: recentDay, totalTokens: 3, costUSD: 0.03)
            ]),
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(date: olderDetailDay, models: [ModelUsageEntry(model: "old", totalTokens: 2)]),
                DailyModelUsageEntry(date: recentDay, models: [ModelUsageEntry(model: "new", totalTokens: 3)])
            ]),
            unknownModelsByDay: [olderDetailDay: ["old"], recentDay: ["new"]],
            apiEstimateByDay: [ancientDay: 1, olderDetailDay: 2, recentDay: 3]
        )
        let defaults = makeUserDefaults("history-cache-compaction")
        let writerCache = ProviderSnapshotCache(
            userDefaults: defaults,
            storageKey: "snapshots",
            ttl: 600,
            now: { now }
        )
        writerCache.store(ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [],
            refreshedAt: now,
            usageHistory: history
        ))
        let cache = ProviderSnapshotCache(
            userDefaults: defaults,
            storageKey: "snapshots",
            ttl: 600,
            now: { now }
        )

        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: []),
            providers: [],
            cache: cache,
            defaults: makeUserDefaults("history-cache-compaction-meter"),
            now: { now }
        )

        let retained = store.localSnapshots[provider.id]?.usageHistory
        XCTAssertEqual(retained?.series.daily.map(\.date), [olderDetailDay, recentDay])
        XCTAssertEqual(retained?.modelUsage?.daily.map(\.date), [recentDay])
        XCTAssertEqual(retained?.unknownModelsByDay, [recentDay: ["new"]])
        XCTAssertEqual(retained?.apiEstimateByDay, [olderDetailDay: 2, recentDay: 3])
        let persisted = cache.loadSnapshots(providerIDs: [provider.id])[provider.id]?.usageHistory
        XCTAssertEqual(persisted, retained, "startup compaction also rewrites the persisted snapshot blob")
        XCTAssertNil(cache.snapshot(providerID: provider.id), "compaction must not mark the previous-session snapshot fresh")
    }

    func testResolvesProgressSnapshotIntoWidgetData() async {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor(
            id: "test.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100, displayMode: .remaining)
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(
                    label: "Session",
                    used: 42,
                    limit: 100,
                    format: .percent,
                    resetsAt: Date(timeIntervalSinceNow: 60 * 60),
                    periodDurationMs: 5 * 60 * 60 * 1000,
                    detail: "$4.00 of $12"
                )]
            )
        )
        let registry = WidgetRegistry(providers: [provider], descriptors: [descriptor])
        // Hermetic: pin the meter style via an isolated suite so a persisted `.used` in `.standard`
        // can't flip the expected "remaining" output.
        let store = WidgetDataStore(registry: registry, providers: [runtime], defaults: makeUserDefaults("resolve-progress"))

        await store.refreshAll()
        let data = store.data(for: descriptor)

        XCTAssertEqual(data.used, 42)
        XCTAssertEqual(data.displayedValue, 58)
        XCTAssertEqual(data.valueText, "58%")
        XCTAssertEqual(data.boundedHeadline, "58% left")
        XCTAssertEqual(data.boundedDetail, "$4.00 of $12")
        XCTAssertEqual(data.boundedSubtitle?.hasPrefix("Resets in "), true)
    }

    func testSoftWarningSurfacesOnHeaderWhilePartialDataStillLoads() async {
        // A *successful* snapshot carrying a `warning` (e.g. Claude's "Re-login for live usage" when the
        // login lacks user:profile) surfaces as the header's amber triangle via `warningMessage(for:)`,
        // while the partial data still loads and it is NOT treated as a hard refresh error.
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("claude"))
        let meter = WidgetDescriptor(
            id: "test.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [meter],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Session", used: 42, limit: 100, format: .percent)],
                warning: "Re-login for live usage. Run `claude` and sign in again."
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [meter]),
            providers: [runtime],
            defaults: makeUserDefaults("soft-warning")
        )

        await store.refreshAll()

        XCTAssertEqual(store.warningMessage(for: provider.id), "Re-login for live usage. Run `claude` and sign in again.")
        XCTAssertNil(store.errorMessage(for: provider.id))  // soft warning, not a hard error
        XCTAssertTrue(store.data(for: meter).hasData)       // partial data still loads
    }

    func testHardErrorTakesPrecedenceOverStaleSoftWarning() async {
        // Bugbot: after a failed refresh the store keeps the last good snapshot (with its `warning`) while
        // setting `providerErrors`. The header must show the current hard error, not the stale soft warning
        // from the prior success — so `headerNotice(for:)` is `errorMessage ?? warningMessage`.
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("claude"))
        let meter = WidgetDescriptor(
            id: "test.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        let runtime = SequenceProviderRuntime(
            provider: provider,
            descriptors: [meter],
            snapshots: [
                ProviderSnapshot(
                    providerID: provider.id,
                    displayName: provider.displayName,
                    lines: [.progress(label: "Session", used: 42, limit: 100, format: .percent)],
                    warning: "Re-login for live usage."
                ),
                ProviderSnapshot.error(provider: provider, message: "Token expired. Run `claude` to log in again.")
            ]
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [meter]),
            providers: [runtime],
            defaults: makeUserDefaults("header-notice")
        )

        await store.refreshAll(force: true)  // success with warning
        XCTAssertEqual(store.warningMessage(for: provider.id), "Re-login for live usage.")
        XCTAssertEqual(store.headerNotice(for: provider.id), "Re-login for live usage.")

        await store.refreshAll(force: true)  // failure
        XCTAssertEqual(store.errorMessage(for: provider.id), "Token expired. Run `claude` to log in again.")
        XCTAssertEqual(store.warningMessage(for: provider.id), "Re-login for live usage.")  // stale, still present
        XCTAssertEqual(store.headerNotice(for: provider.id), "Token expired. Run `claude` to log in again.")  // error wins
    }

    func testFailedRefreshMergesNewHistoryWithoutRefreshingOrDroppingQuota() async throws {
        let provider = Provider(id: "antigravity", displayName: "Antigravity", icon: .providerMark("antigravity"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let quotaTime = now.addingTimeInterval(-900)
        let day = DailyUsageAccumulator.dayKey(from: now)
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: day, totalTokens: 1_500, costUSD: 0.02)
        ]))
        let meter = WidgetDescriptor.percent(id: "antigravity.session", provider: provider, title: "Session")
        let historyDescriptor = WidgetDescriptor.usageTrend(provider: provider).exportingHistory(
            scope: .machineLocal,
            estimatedCost: true,
            sourceNote: "local"
        )
        var failed = ProviderSnapshot.error(provider: provider, message: "Usage is temporarily unavailable.")
        failed.usageHistory = history
        let runtime = SequenceProviderRuntime(
            provider: provider,
            descriptors: [meter, historyDescriptor],
            snapshots: [
                ProviderSnapshot(
                    providerID: provider.id,
                    displayName: provider.displayName,
                    plan: "Pro",
                    lines: [.progress(label: "Session", used: 25, limit: 100, format: .percent)],
                    refreshedAt: quotaTime
                ),
                failed
            ]
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [meter, historyDescriptor]),
            providers: [runtime],
            defaults: makeUserDefaults("failed-refresh-history-merge"),
            now: { now }
        )

        await store.refreshAll(force: true)
        await store.refreshAll(force: true)

        let snapshot = try XCTUnwrap(store.localSnapshots[provider.id])
        XCTAssertEqual(store.errorMessage(for: provider.id), "Usage is temporarily unavailable.")
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(snapshot.line(label: "Session"), .progress(label: "Session", used: 25, limit: 100, format: .percent))
        XCTAssertEqual(snapshot.quotaRefreshedAt, quotaTime)
        XCTAssertEqual(snapshot.usageHistory, history)
        XCTAssertNotNil(snapshot.line(label: "Last 30 Days"))
    }

    func testFirstRunFailedRefreshCanPublishHistoryWithoutFreshQuota() async throws {
        let provider = Provider(id: "antigravity", displayName: "Antigravity", icon: .providerMark("antigravity"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day = DailyUsageAccumulator.dayKey(from: now)
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: day, totalTokens: 1_500, costUSD: 0.02)
        ]))
        let meter = WidgetDescriptor.percent(id: "antigravity.session", provider: provider, title: "Session")
        let historyDescriptor = WidgetDescriptor.usageTrend(provider: provider).exportingHistory(
            scope: .machineLocal,
            estimatedCost: true,
            sourceNote: "local"
        )
        var failed = ProviderSnapshot.error(provider: provider, message: "Usage is temporarily unavailable.")
        failed.usageHistory = history
        let runtime = SequenceProviderRuntime(provider: provider, descriptors: [meter, historyDescriptor], snapshots: [failed])
        let defaults = makeUserDefaults("first-run-failed-history")
        let cache = ProviderSnapshotCache(
            userDefaults: defaults,
            storageKey: "snapshots",
            ttl: 600,
            now: { now }
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [meter, historyDescriptor]),
            providers: [runtime],
            cache: cache,
            defaults: defaults,
            now: { now }
        )

        await store.refreshAll(force: true)

        let snapshot = try XCTUnwrap(store.localSnapshots[provider.id])
        XCTAssertEqual(store.errorMessage(for: provider.id), "Usage is temporarily unavailable.")
        XCTAssertEqual(snapshot.usageHistory, history)
        XCTAssertNil(snapshot.plan)
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertEqual(snapshot.quotaRefreshedAt, .distantPast)
        XCTAssertNotNil(snapshot.line(label: "Last 30 Days"))
    }

    func testFailedQuotaRetryCanFoldHistoryWithoutClearingQuotaError() async throws {
        let provider = Provider(id: "antigravity", displayName: "Antigravity", icon: .providerMark("antigravity"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let quotaTime = now.addingTimeInterval(-300)
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: DailyUsageAccumulator.dayKey(from: now), totalTokens: 1_500, costUSD: 0.02)
        ]))
        let meter = WidgetDescriptor.percent(id: "antigravity.session", provider: provider, title: "Session")
        let historyDescriptor = WidgetDescriptor.usageTrend(provider: provider).exportingHistory(
            scope: .machineLocal,
            estimatedCost: true,
            sourceNote: "local"
        )
        let quota = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: "Pro",
            lines: [.progress(label: "Session", used: 25, limit: 100, format: .percent)],
            refreshedAt: quotaTime
        )
        let failed = ProviderSnapshot.error(provider: provider, message: "Usage is temporarily unavailable.")
        let folded = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [],
            refreshedAt: now,
            usageHistory: history
        )
        let runtime = SequenceProviderRuntime(
            provider: provider,
            descriptors: [meter, historyDescriptor],
            snapshots: [quota, failed, folded]
        )
        let defaults = makeUserDefaults("failed-quota-history-retry")
        let cache = ProviderSnapshotCache(
            userDefaults: defaults,
            storageKey: "snapshots",
            ttl: 600,
            now: { now }
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [meter, historyDescriptor]),
            providers: [runtime],
            cache: cache,
            defaults: defaults,
            now: { now }
        )

        let initial = await ProviderRefreshContext.$scope.withValue(.panelMeters) {
            await store.refresh(providerID: provider.id, force: true)
        }
        let failure = await ProviderRefreshContext.$scope.withValue(.panelMeters) {
            await store.refresh(providerID: provider.id, force: true)
        }
        let historyRetry = await store.refreshProviderHistoryAfterRetry(providerID: provider.id, manualActionID: nil)

        XCTAssertEqual(initial, .refreshed)
        XCTAssertEqual(failure, .failed)
        XCTAssertEqual(historyRetry, .refreshed)
        XCTAssertEqual(runtime.refreshCount, 3)
        XCTAssertEqual(store.errorMessage(for: provider.id), "Usage is temporarily unavailable.")
        let snapshot = try XCTUnwrap(store.localSnapshots[provider.id])
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(snapshot.line(label: "Session"), quota.line(label: "Session"))
        XCTAssertEqual(snapshot.quotaRefreshedAt, quotaTime)
        XCTAssertEqual(snapshot.usageHistory, history)
    }

    func testVisibleTwoPhaseRetryClearsRecoveredFullRefreshError() async throws {
        let provider = Provider(id: "antigravity", displayName: "Antigravity", icon: .providerMark("antigravity"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let meter = WidgetDescriptor.percent(id: "antigravity.session", provider: provider, title: "Session")
        let historyDescriptor = WidgetDescriptor.usageTrend(provider: provider).exportingHistory(
            scope: .machineLocal,
            estimatedCost: true,
            sourceNote: "local"
        )
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: DailyUsageAccumulator.dayKey(from: now), totalTokens: 8, costUSD: 0.01)
        ]))
        let fullFailure = ProviderSnapshot.error(provider: provider, message: "Usage is temporarily unavailable.")
        let meters = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: "Pro",
            lines: [.progress(label: "Session", used: 20, limit: 100, format: .percent)],
            refreshedAt: now
        )
        let folded = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [],
            refreshedAt: now,
            usageHistory: history
        )
        let runtime = SequenceProviderRuntime(
            provider: provider,
            descriptors: [meter, historyDescriptor],
            snapshots: [fullFailure, meters, folded]
        )
        let defaults = makeUserDefaults("visible-retry-clears-full-error")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [meter, historyDescriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { now }),
            defaults: defaults,
            now: { now }
        )

        let initial = await store.refresh(providerID: provider.id, force: true)
        let quotaRetry = await ProviderRefreshContext.$scope.withValue(.panelMeters) {
            await store.refresh(providerID: provider.id, force: true)
        }
        XCTAssertEqual(initial, .failed)
        XCTAssertEqual(quotaRetry, .refreshed)
        XCTAssertEqual(store.errorMessage(for: provider.id), "Usage is temporarily unavailable.",
                        "the local history portion of the full error remains until its fold succeeds")

        let historyRetry = await store.refreshProviderHistoryAfterRetry(providerID: provider.id, manualActionID: nil)

        XCTAssertEqual(historyRetry, .refreshed)
        XCTAssertNil(store.errorMessage(for: provider.id))
        let snapshot = try XCTUnwrap(store.localSnapshots[provider.id])
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(snapshot.usageHistory, history)
    }

    /// A provider whose every scope resolves to no narrower domain records its failure under the
    /// catch-all `.full` bucket. A later successful pass clears only its own (narrower) domains, so
    /// without clearing the catch-all too the error — and its Retry affordance — would stay forever.
    func testFallbackFullFailureIsClearedByALaterSuccessfulPass() async throws {
        let provider = Provider(id: "freebuff", displayName: "Freebuff", icon: .providerMark("freebuff"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let failure = ProviderSnapshot.error(provider: provider, message: "Usage is temporarily unavailable.")
        let recovered = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [],
            refreshedAt: now
        )
        let runtime = SequenceProviderRuntime(
            provider: provider,
            descriptors: [],
            snapshots: [failure, recovered]
        )
        let defaults = makeUserDefaults("fallback-full-failure-recovery")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: []),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { now }),
            defaults: defaults,
            now: { now }
        )

        let failedOutcome = await store.refresh(providerID: provider.id, force: true)
        XCTAssertEqual(failedOutcome, .failed)
        XCTAssertEqual(store.errorMessage(for: provider.id), "Usage is temporarily unavailable.")

        // A user-initiated retry bypasses the negative cache, exactly like the visible retry path.
        let recoveredOutcome = await store.refresh(providerID: provider.id, bypassFailureBackoff: true)
        XCTAssertEqual(recoveredOutcome, .refreshed)
        XCTAssertNil(store.errorMessage(for: provider.id),
                     "the catch-all failure must not outlive a pass that proved the provider works")
    }

    func testForcedPanelMetersRetryKeepsItsScopeInsideProviderDeadline() async throws {
        let provider = Provider(id: "antigravity", displayName: "Antigravity", icon: .providerMark("antigravity"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let meter = WidgetDescriptor.percent(id: "antigravity.session", provider: provider, title: "Session")
        let historyDescriptor = WidgetDescriptor.usageTrend(provider: provider).exportingHistory(
            scope: .machineLocal,
            estimatedCost: true,
            sourceNote: "local"
        )
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: DailyUsageAccumulator.dayKey(from: now), totalTokens: 42, costUSD: 0.02)
        ]))
        let initial = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: "Pro",
            lines: [.progress(label: "Session", used: 20, limit: 100, format: .percent)],
            refreshedAt: now,
            usageHistory: history
        )
        let meters = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: "Pro",
            lines: [.progress(label: "Session", used: 25, limit: 100, format: .percent)],
            refreshedAt: now.addingTimeInterval(1)
        )
        let runtime = SequenceProviderRuntime(
            provider: provider,
            descriptors: [meter, historyDescriptor],
            snapshots: [initial, meters]
        )
        let defaults = makeUserDefaults("forced-panel-meter-keeps-scope")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [meter, historyDescriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { now }),
            defaults: defaults,
            now: { now }
        )

        _ = await store.refresh(providerID: provider.id, force: true)
        let retry = await ProviderRefreshContext.$scope.withValue(.panelMeters) {
            await store.refresh(providerID: provider.id, force: true)
        }

        XCTAssertEqual(retry, .refreshed)
        XCTAssertEqual(runtime.observedScopes, [.full, .panelMeters])
        let snapshot = try XCTUnwrap(store.localSnapshots[provider.id])
        XCTAssertEqual(snapshot.line(label: "Session"), meters.line(label: "Session"))
        XCTAssertEqual(snapshot.usageHistory, history)
    }

    func testHermesPanelMeterRecoveryClearsItsAccountingError() async {
        let provider = Provider(id: "hermes", displayName: "Hermes", icon: .providerMark("hermes"))
        let today = WidgetDescriptor.values(id: "hermes.today", provider: provider, title: "Today")
        let historyDescriptor = WidgetDescriptor.usageTrend(provider: provider).exportingHistory(
            scope: .machineLocal,
            estimatedCost: true,
            sourceNote: "local"
        )
        let failed = ProviderSnapshot.error(provider: provider, message: "Local database unavailable")
        let recovered = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.values(label: "Today", values: [MetricValue(number: 42, kind: .count, label: "tokens")])],
            usageHistory: ProviderUsageHistory(series: DailyUsageSeries(daily: []))
        )
        let runtime = SequenceProviderRuntime(
            provider: provider,
            descriptors: [today, historyDescriptor],
            snapshots: [failed, recovered],
            panelMetersRefreshIncludesHistory: true
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [today, historyDescriptor]),
            providers: [runtime],
            defaults: makeUserDefaults("hermes-recovery-clears-accounting-error")
        )

        let initial = await store.refresh(providerID: provider.id, force: true)
        let retry = await ProviderRefreshContext.$scope.withValue(.panelMeters) {
            await store.refresh(providerID: provider.id, force: true)
        }

        XCTAssertEqual(initial, .failed)
        XCTAssertEqual(retry, .refreshed)
        XCTAssertNil(store.errorMessage(for: provider.id))
    }

    func testFullRefreshFailureBacksOffQuotaAndAccountingPhases() async {
        let provider = Provider(id: "antigravity", displayName: "Antigravity", icon: .providerMark("antigravity"))
        let meter = WidgetDescriptor.percent(id: "antigravity.session", provider: provider, title: "Session")
        let historyDescriptor = WidgetDescriptor.usageTrend(provider: provider).exportingHistory(
            scope: .machineLocal,
            estimatedCost: true,
            sourceNote: "local"
        )
        let failure = ProviderSnapshot.error(provider: provider, message: "Usage unavailable")
        let runtime = SequenceProviderRuntime(
            provider: provider,
            descriptors: [meter, historyDescriptor],
            snapshots: [failure]
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [meter, historyDescriptor]),
            providers: [runtime],
            defaults: makeUserDefaults("full-refresh-failure-shares-component-backoff"),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let full = await store.refresh(providerID: provider.id, force: true)
        let quota = await ProviderRefreshContext.$scope.withValue(.panelMeters) {
            await store.refresh(providerID: provider.id)
        }
        let accounting = await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await store.refresh(providerID: provider.id)
        }

        XCTAssertEqual(full, .failed)
        XCTAssertEqual(quota, .backedOff)
        XCTAssertEqual(accounting, .backedOff)
        XCTAssertEqual(runtime.refreshCount, 1)
    }

    func testAccountingFailureDoesNotBlockMetersOrGetClearedByMeterSuccess() async throws {
        let provider = Provider(id: "opencode", displayName: "OpenCode", icon: .providerMark("opencode"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let meter = WidgetDescriptor.percent(id: "opencode.session", provider: provider, title: "Session")
        let historyDescriptor = WidgetDescriptor.usageTrend(provider: provider).exportingHistory(
            scope: .machineLocal,
            estimatedCost: true,
            sourceNote: "local"
        )
        let foldFailure = ProviderSnapshot.error(provider: provider, message: "Local history unavailable")
        let quota = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: "Go",
            lines: [.progress(label: "Session", used: 27, limit: 100, format: .percent)],
            refreshedAt: now
        )
        let runtime = SequenceProviderRuntime(
            provider: provider,
            descriptors: [meter, historyDescriptor],
            snapshots: [foldFailure, quota]
        )
        let defaults = makeUserDefaults("accounting-failure-does-not-block-meters")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [meter, historyDescriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { now }),
            defaults: defaults,
            now: { now }
        )

        let fold = await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await store.refresh(providerID: provider.id, force: true)
        }
        let meters = await ProviderRefreshContext.$scope.withValue(.panelMeters) {
            await store.refresh(providerID: provider.id, bypassSnapshotCache: true)
        }

        XCTAssertEqual(fold, .failed)
        XCTAssertEqual(meters, .refreshed, "an accounting scan failure must not back off the independent quota request")
        XCTAssertEqual(runtime.refreshCount, 2)
        XCTAssertEqual(store.errorMessage(for: provider.id), "Local history unavailable")
        let snapshot = try XCTUnwrap(store.localSnapshots[provider.id])
        XCTAssertEqual(snapshot.plan, "Go")
        XCTAssertEqual(snapshot.line(label: "Session"), quota.line(label: "Session"))
    }

    func testQuotaFailureDoesNotBlockAccountingFold() async throws {
        let provider = Provider(id: "antigravity", displayName: "Antigravity", icon: .providerMark("antigravity"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: DailyUsageAccumulator.dayKey(from: now), totalTokens: 12, costUSD: 0.01)
        ]))
        let meter = WidgetDescriptor.percent(id: "antigravity.session", provider: provider, title: "Session")
        let historyDescriptor = WidgetDescriptor.usageTrend(provider: provider).exportingHistory(
            scope: .machineLocal,
            estimatedCost: true,
            sourceNote: "local"
        )
        let quotaFailure = ProviderSnapshot.error(provider: provider, message: "Quota unavailable")
        let fold = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [],
            refreshedAt: now,
            usageHistory: history
        )
        let runtime = SequenceProviderRuntime(
            provider: provider,
            descriptors: [meter, historyDescriptor],
            snapshots: [quotaFailure, fold]
        )
        let defaults = makeUserDefaults("quota-failure-does-not-block-accounting")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [meter, historyDescriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { now }),
            defaults: defaults,
            now: { now }
        )

        let quota = await ProviderRefreshContext.$scope.withValue(.panelMeters) {
            await store.refresh(providerID: provider.id, force: true)
        }
        let accounting = await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await store.refresh(providerID: provider.id, bypassSnapshotCache: true)
        }

        XCTAssertEqual(quota, .failed)
        XCTAssertEqual(accounting, .refreshed, "a quota API failure must not suppress local history")
        XCTAssertEqual(runtime.refreshCount, 2)
        XCTAssertEqual(store.errorMessage(for: provider.id), "Quota unavailable")
        XCTAssertEqual(store.localSnapshots[provider.id]?.usageHistory, history)
    }

    func testFoldFailureCannotClearNewlyFetchedQuotaMeters() async throws {
        let provider = Provider(id: "opencode", displayName: "OpenCode", icon: .providerMark("opencode"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let meter = WidgetDescriptor.percent(id: "opencode.session", provider: provider, title: "Session")
        let historyDescriptor = WidgetDescriptor.usageTrend(provider: provider).exportingHistory(
            scope: .machineLocal,
            estimatedCost: true,
            sourceNote: "local"
        )
        let quota = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: "Go",
            lines: [.progress(label: "Session", used: 27, limit: 100, format: .percent)],
            refreshedAt: now
        )
        let foldFailure = ProviderSnapshot.error(
            provider: provider,
            message: "Local history unavailable",
            category: .network,
            clearsPriorMenuBarQuotaState: true
        )
        let runtime = SequenceProviderRuntime(
            provider: provider,
            descriptors: [meter, historyDescriptor],
            snapshots: [quota, foldFailure]
        )
        let defaults = makeUserDefaults("fold-failure-keeps-fresh-quota")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [meter, historyDescriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { now }),
            defaults: defaults,
            now: { now }
        )

        _ = await ProviderRefreshContext.$scope.withValue(.panelMeters) {
            await store.refresh(providerID: provider.id, force: true)
        }
        let retry = await store.refreshProviderHistoryAfterRetry(providerID: provider.id, manualActionID: nil)

        XCTAssertEqual(retry, .failed)
        XCTAssertEqual(store.errorMessage(for: provider.id), "Local history unavailable")
        let snapshot = try XCTUnwrap(store.localSnapshots[provider.id])
        XCTAssertEqual(snapshot.plan, "Go")
        XCTAssertEqual(snapshot.line(label: "Session"), quota.line(label: "Session"))
    }

    func testMeterlessLocalProviderKeepsItsHistoryCacheFreshAfterFold() async throws {
        let provider = Provider(id: "hermes", displayName: "Hermes", icon: .providerMark("hermes"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = WidgetDescriptor.values(id: "hermes.today", provider: provider, title: "Today")
        let historyDescriptor = WidgetDescriptor.usageTrend(provider: provider).exportingHistory(
            scope: .machineLocal,
            estimatedCost: true,
            sourceNote: "local"
        )
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: DailyUsageAccumulator.dayKey(from: now), totalTokens: 42, costUSD: 0.02)
        ]))
        let snapshot = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.values(label: "Today", values: [MetricValue(number: 42, kind: .count, label: "tokens")])],
            refreshedAt: now,
            usageHistory: history
        )
        let runtime = SequenceProviderRuntime(provider: provider, descriptors: [today, historyDescriptor], snapshots: [snapshot])
        let defaults = makeUserDefaults("meterless-local-history-cache")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { now })
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [today, historyDescriptor]),
            providers: [runtime],
            cache: cache,
            defaults: defaults,
            now: { now }
        )

        let outcome = await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await store.refresh(providerID: provider.id, bypassSnapshotCache: true)
        }

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertNotNil(cache.snapshot(providerID: provider.id), "history-only providers must not get an expired quota stamp")
    }

    func testPanelMeterRetryDoesNotImmediatelyRepeatProvidersWhoseMeterPassScansHistory() async {
        let provider = Provider(id: "hermes", displayName: "Hermes", icon: .providerMark("hermes"))
        let today = WidgetDescriptor.values(id: "hermes.today", provider: provider, title: "Today")
        let history = WidgetDescriptor.usageTrend(provider: provider).exportingHistory(
            scope: .machineLocal,
            estimatedCost: true,
            sourceNote: "local"
        )
        let runtime = SequenceProviderRuntime(
            provider: provider,
            descriptors: [today, history],
            snapshots: [],
            panelMetersRefreshIncludesHistory: true
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [today, history]),
            providers: [runtime],
            defaults: makeUserDefaults("hermes-retry-no-double-scan")
        )

        let outcome = await store.refreshProviderHistoryAfterRetry(providerID: provider.id, manualActionID: nil)

        XCTAssertEqual(outcome, .skipped)
        XCTAssertEqual(runtime.refreshCount, 0)
    }

    func testPanelAccountingSkipsProviderWhoseMeterPassAlreadyScansHistory() async {
        let provider = Provider(id: "hermes", displayName: "Hermes", icon: .providerMark("hermes"))
        let today = WidgetDescriptor.values(id: "hermes.today", provider: provider, title: "Today")
        let historyDescriptor = WidgetDescriptor.usageTrend(provider: provider).exportingHistory(
            scope: .machineLocal,
            estimatedCost: true,
            sourceNote: "local"
        )
        let runtime = SequenceProviderRuntime(
            provider: provider,
            descriptors: [today, historyDescriptor],
            snapshots: [],
            panelMetersRefreshIncludesHistory: true
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [today, historyDescriptor]),
            providers: [runtime],
            defaults: makeUserDefaults("hermes-panel-accounting-is-not-repeated")
        )

        await ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            await store.refreshAll()
        }

        XCTAssertEqual(runtime.refreshCount, 0)
    }

    func testVisibleHistoryRetryPreservesManualCredentialContextAndCPUThrottle() async throws {
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let historyDescriptor = WidgetDescriptor.usageTrend(provider: provider).exportingHistory(
            scope: .machineLocal,
            estimatedCost: true,
            sourceNote: "local"
        )
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: []))
        let snapshot = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [],
            refreshedAt: Date(),
            usageHistory: history
        )
        let runtime = RefreshContextRecordingProviderRuntime(
            provider: provider,
            descriptors: [historyDescriptor],
            snapshot: snapshot
        )
        let defaults = makeUserDefaults("manual-history-retry-context")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [historyDescriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600),
            defaults: defaults
        )

        let attempt = try await withManualRefresh {
            let manualActionID = try XCTUnwrap(ProviderRefreshContext.manualActionID)
            let interactionGate = try XCTUnwrap(ProviderRefreshContext.credentialInteractionGate)
            let outcome = await store.refreshProviderHistoryAfterRetry(
                providerID: provider.id,
                manualActionID: manualActionID,
                credentialInteractionGate: interactionGate
            )
            return (outcome, manualActionID, interactionGate)
        }

        XCTAssertEqual(attempt.0, .refreshed)
        XCTAssertEqual(runtime.observedScope, .panelAccounting)
        XCTAssertTrue(runtime.observedIsManual)
        XCTAssertEqual(runtime.observedManualActionID, attempt.1)
        XCTAssertTrue(runtime.observedInteractionGate === attempt.2)
        XCTAssertTrue(runtime.observedAccountingCPUThrottleEnabled)
    }

    func testPanelMeterHistoryOnlyProviderDoesNotAdvanceQuotaDeadline() async {
        let provider = Provider(id: "hermes", displayName: "Hermes", icon: .providerMark("hermes"))
        let today = WidgetDescriptor.values(id: "hermes.today", provider: provider, title: "Today")
        let historyDescriptor = WidgetDescriptor.usageTrend(provider: provider).exportingHistory(
            scope: .machineLocal,
            estimatedCost: true,
            sourceNote: "local"
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: DailyUsageAccumulator.dayKey(from: now), totalTokens: 42, costUSD: 0.02)
        ]))
        let snapshot = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.values(label: "Today", values: [MetricValue(number: 42, kind: .count, label: "tokens")])],
            refreshedAt: now,
            usageHistory: history
        )
        let runtime = SequenceProviderRuntime(
            provider: provider,
            descriptors: [today, historyDescriptor],
            snapshots: [snapshot],
            panelMetersRefreshIncludesHistory: true
        )
        let defaults = makeUserDefaults("hermes-does-not-advance-quota-deadline")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [today, historyDescriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { now }),
            defaults: defaults,
            now: { now }
        )

        await ProviderRefreshContext.$scope.withValue(.panelMeters) {
            await store.refreshAll(force: true)
        }

        XCTAssertEqual(runtime.refreshCount, 1)
        XCTAssertNil(store.lastLiveQuotaRefreshUptime,
                     "a local-only Hermes scan must not postpone the next remote quota request")
    }

    func testDefinitiveAuthenticationErrorClearsCachedQuotaButKeepsHistory() async throws {
        let provider = Provider(id: "opencode", displayName: "OpenCode", icon: .providerMark("opencode"))
        let historyDescriptor = WidgetDescriptor.usageTrend(provider: provider).exportingHistory(
            scope: .machineLocal,
            estimatedCost: true,
            sourceNote: "test"
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: "2026-10-13", totalTokens: 135_900_000, costUSD: 1.47)
        ]))
        let previous = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: "Go",
            lines: [
                .progress(label: "Session", used: 0, limit: 100, format: .percent),
                .progress(label: "Weekly", used: 0, limit: 100, format: .percent),
                .progress(label: "Monthly", used: 0, limit: 100, format: .percent),
                .values(label: "Today", values: [MetricValue(number: 1.47, kind: .dollars, label: "cost")])
            ],
            refreshedAt: now,
            usageHistory: history
        )
        let logout = ProviderSnapshot.error(
            provider: provider,
            message: "Not signed in",
            category: .notLoggedIn,
            clearsPriorMenuBarQuotaState: true
        )
        let runtime = SequenceProviderRuntime(
            provider: provider,
            descriptors: [historyDescriptor],
            snapshots: [previous, logout]
        )
        let defaults = makeUserDefaults("clear-quota-on-logout")
        let cache = ProviderSnapshotCache(
            userDefaults: defaults,
            storageKey: "snapshots",
            ttl: 600,
            now: { now }
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [historyDescriptor]),
            providers: [runtime],
            cache: cache,
            defaults: defaults,
            now: { now }
        )

        await store.refreshAll(force: true)
        await store.refreshAll(force: true)

        let retained = try XCTUnwrap(store.localSnapshots[provider.id])
        XCTAssertNil(retained.plan)
        XCTAssertNil(retained.line(label: "Session"))
        XCTAssertNil(retained.line(label: "Weekly"))
        XCTAssertNil(retained.line(label: "Monthly"))
        XCTAssertNotNil(retained.line(label: "Today"))
        XCTAssertEqual(retained.usageHistory, history)
        XCTAssertEqual(store.errorMessage(for: provider.id), "Not signed in")

        let persisted = cache.loadSnapshots(providerIDs: [provider.id])[provider.id]
        XCTAssertNil(persisted?.plan)
        XCTAssertNil(persisted?.line(label: "Session"))
        XCTAssertEqual(persisted?.usageHistory, history)
    }

    func testRemainingProgressWithoutResetUsesPeriodDurationLabel() {
        for (period, expected) in [
            (ClaudeUsageMapper.sessionPeriodMs, "Resets in 5h"),
            (ClaudeUsageMapper.weeklyPeriodMs, "Resets in 7d 0h")
        ] {
            let data = WidgetData(
                title: "Usage", icon: .providerMark("claude"), kind: .percent,
                used: 0, limit: 100, displayMode: .remaining, periodDurationMs: period
            )
            XCTAssertEqual(data.boundedSubtitle, expected)
        }
    }

    func testDonutFractionMatchesRoundedHeadline() {
        for (used, headline, fraction) in [
            (0.3915, "0%", 0.0), (0.6, "1%", 0.01), (99.6, "100%", 1.0)
        ] {
            let data = WidgetData(
                title: "Total usage", icon: .providerMark("cursor"), kind: .percent,
                used: used, limit: 100
            )
            XCTAssertEqual(data.valueText, headline)
            XCTAssertEqual(data.fraction, fraction, accuracy: 0.0001)
        }
    }

    func testBoundedDollarSubtitlesAppendLimitNoun() {
        for (title, limit, expected) in [("On-Demand", 100.0, "$100 limit"), ("Credits", 20.0, "$20 limit")] {
            let data = WidgetData(
                title: title, icon: .providerMark("cursor"), kind: .dollars,
                used: 0, limit: limit, limitNoun: "limit"
            )
            XCTAssertEqual(data.boundedSubtitle, expected)
        }
    }

    func testPartialUnboundedValuesKeepOnlyExplicitSubtitle() {
        var data = WidgetData(title: "Hermes", icon: .providerMark("hermes"), kind: .dollars, used: 0, limit: nil)
        data.values = [
            MetricValue(number: 1.25, kind: .dollars, estimated: true, isPartial: true),
            MetricValue(number: 100, kind: .count, label: "tokens", isPartial: true)
        ]
        XCTAssertNil(data.unboundedSubtitle, "completeness belongs in existing detail views, without another row badge")

        data.subtitleOverride = "From local history"
        XCTAssertEqual(data.unboundedSubtitle, "From local history")
    }

    func testRequestsShowsBillingResetInsteadOfSuffix() {
        // The requests tile resets on the billing cycle, so it shows the cadence rather than "requests".
        let requests = WidgetData(
            title: "Requests",
            icon: .providerMark("cursor"),
            kind: .count,
            used: 0,
            limit: 500,
            countSuffix: "requests",
            periodDurationMs: CursorUsageMapper.billingPeriodMs
        )
        XCTAssertEqual(requests.boundedSubtitle, "Resets in 30d 0h")
    }

    func testCreditsRenderDollarAndCountCombinedInvariantToMeterStyle() async {
        // Codex flex credits show the dollar value and the raw count combined ("$40.00 · 1,000
        // credits"), invariant to the Used/Left meter style, while the dollar value drives the menu
        // bar's compact reading — all from one `.values` row, no string re-parse.
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor.combined(
            id: "codex.credits", provider: provider, title: "Extra Usage", metricLabel: "Credits"
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.values(label: "Credits", values: CodexUsageMapper.creditValues(remaining: 1000))]
            )
        )
        let defaults = makeUserDefaults("codex-credits")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )
        await store.refreshAll()

        store.meterStyle = .remaining
        let remaining = store.data(for: descriptor)
        XCTAssertFalse(remaining.isBounded)
        XCTAssertEqual(remaining.unboundedDetail, "$40.00 · 1K credits")
        XCTAssertEqual(remaining.menuBarValue, "$40")   // dollar value → compact tray reading
        XCTAssertNil(remaining.unboundedSubtitle)

        store.meterStyle = .used
        let used = store.data(for: descriptor)
        XCTAssertEqual(used.unboundedDetail, remaining.unboundedDetail)
        XCTAssertEqual(used.headline, remaining.headline)
    }

    func testRateLimitResetsTileShowsCountInTrayAndPopover() async {
        // Regression (#641): the menu-bar tile and the popover row resolve from one raw number, so a
        // pinned tile can't read "0" while the popover reads "1". The popover keeps Codex's "available"
        // wording, while the tighter tray reads "resets".
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor.values(
            id: "codex.rateLimitResets",
            provider: provider,
            title: "Rate Limit Resets",
            metricLabel: "Rate Limit Resets",
            traySuffix: "resets"
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.values(label: "Rate Limit Resets",
                                values: [MetricValue(number: 1, kind: .count, label: "available")])]
            )
        )
        let defaults = makeUserDefaults("codex-resets")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )
        await store.refreshAll()

        let data = store.data(for: descriptor)
        XCTAssertTrue(data.hasData)
        XCTAssertFalse(data.isBounded)
        XCTAssertEqual(data.unboundedDetail, "1 available")
        XCTAssertEqual(data.menuBarValue, "1 resets")
    }

    func testZeroRateLimitResetsStillFlagsResetPopoverForEmptyState() async {
        // The descriptor opt-in must survive resolve even at "0 available" (no expiries): that's exactly
        // when the value column needs to stay a hover target so the popover can show the empty state.
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor.values(
            id: "codex.rateLimitResets",
            provider: provider,
            title: "Rate Limit Resets",
            metricLabel: "Rate Limit Resets",
            traySuffix: "resets",
            showsResetExpiries: true
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.values(label: "Rate Limit Resets",
                                values: [MetricValue(number: 0, kind: .count, label: "available")])]
            )
        )
        let defaults = makeUserDefaults("codex-resets-empty")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )
        await store.refreshAll()

        let data = store.data(for: descriptor)
        XCTAssertTrue(data.showsResetExpiries)
        XCTAssertTrue(data.hasData)
        XCTAssertTrue(data.expiriesAt.isEmpty)
        XCTAssertNil(data.expirySeverity())          // no dot at zero
        XCTAssertEqual(data.unboundedDetail, "0 available")
    }

    func testBoundedDollarAndCountTrayValuesHonorMeterStyleWithoutPercentConversion() async {
        let provider = Provider(id: "example", displayName: "Example", icon: .providerMark("cursor"))
        let budget = WidgetDescriptor.boundedDollars(id: "example.budget", provider: provider, title: "Budget", limit: 100)
        let requests = WidgetDescriptor.boundedCount(
            id: "example.requests",
            provider: provider,
            title: "Requests",
            limit: 500,
            suffix: "requests",
            periodDurationMs: CursorUsageMapper.billingPeriodMs
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [budget, requests],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [
                    .progress(label: "Budget", used: 12.48, limit: 20, format: .dollars),
                    .progress(label: "Requests", used: 412, limit: 500, format: .count(suffix: "requests"))
                ]
            )
        )
        let defaults = makeUserDefaults("cursor-tray-units")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [budget, requests]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )
        await store.refreshAll()

        store.meterStyle = .used
        XCTAssertEqual(store.data(for: budget).menuBarValue, "$12")
        XCTAssertEqual(store.data(for: requests).menuBarValue, "412")

        store.meterStyle = .remaining
        XCTAssertEqual(store.data(for: budget).menuBarValue, "$8")
        XCTAssertEqual(store.data(for: requests).menuBarValue, "88")
    }

    func testCursorCreditsRenderAsUnboundedBalance() async {
        let provider = Provider(id: "cursor", displayName: "Cursor", icon: .providerMark("cursor"))
        let descriptor = WidgetDescriptor.dollarBalance(
            id: "cursor.credits",
            provider: provider,
            title: "Credits",
            valueWord: "left"
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.values(label: "Credits", values: [MetricValue(number: 7_909.64, kind: .dollars)])]
            )
        )
        let defaults = makeUserDefaults("cursor-credits-balance")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )
        await store.refreshAll()

        store.meterStyle = .remaining
        let remaining = store.data(for: descriptor)
        XCTAssertFalse(remaining.isBounded)
        XCTAssertEqual(remaining.unboundedDetail, "$7.9K left")
        XCTAssertEqual(remaining.menuBarValue, "$7.9K")

        store.meterStyle = .used
        let used = store.data(for: descriptor)
        XCTAssertEqual(used.unboundedDetail, remaining.unboundedDetail)
        XCTAssertEqual(used.menuBarValue, remaining.menuBarValue)
    }

    func testUncappedExtraUsageRendersCompactAndUnbounded() async {
        // Regression (#658): Claude's `claude.extra` is a `boundedDollars` descriptor (a meter when the
        // provider reports a monthly cap), but an uncapped spend arrives as a `.values` line. It must
        // resolve to an unbounded tile — the sample's placeholder limit dropped — and read in the same
        // compact shorthand as the spend tiles ("$1.2K spent"), not full currency, in both row and tray.
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let descriptor = WidgetDescriptor.boundedDollars(
            id: "claude.extra", provider: provider, title: "Extra Usage",
            metricLabel: "Extra usage spent", limit: 100, valueWord: "spent"
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.values(label: "Extra usage spent",
                                values: [MetricValue(number: 1234.56, kind: .dollars)])]
            )
        )
        let defaults = makeUserDefaults("claude-extra")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )
        await store.refreshAll()

        let data = store.data(for: descriptor)
        XCTAssertTrue(data.hasData)
        XCTAssertFalse(data.isBounded)                          // sample's limit: 100 dropped for a .values row
        XCTAssertEqual(data.unboundedDetail, "$1.2K spent")     // popover row — compact, not "$1,234.56"
        XCTAssertEqual(data.menuBarValue, "$1.2K")              // tray — same shorthand
        XCTAssertEqual(data.unboundedTooltip, "$1,234.56")      // hover still reveals the exact figure
    }

    func testCreditValuesFloorAndClampBalance() {
        var data = WidgetData(title: "Extra Usage", icon: .providerMark("codex"), kind: .dollars, used: 0, limit: nil)
        data.values = CodexUsageMapper.creditValues(remaining: 820.9)
        XCTAssertEqual(data.unboundedDetail, "$32.80 · 820 credits")
        // An exhausted/negative balance clamps to a real, measured zero — "$0.00 · 0 credits", not "No data".
        data.values = CodexUsageMapper.creditValues(remaining: -5)
        XCTAssertEqual(data.unboundedDetail, "$0.00 · 0 credits")
    }

    func testCreditsRenderUpToOneDecimalPlace() {
        let credits = WidgetData(
            title: "Extra Usage",
            icon: .providerMark("codex"),
            kind: .count,
            used: 820.55,
            limit: nil,
            countSuffix: "credits",
            unboundedValueWord: "left"
        )

        XCTAssertEqual(credits.valueText, "820.6")
        XCTAssertEqual(credits.unboundedDetail, "820.6 credits left")
    }

    func testCcusageSpendSplitsIntoCostTokensAndCombined() async {
        // One `.values` spend row backs three tiles: cost-only (dollars + ⓘ), tokens-only (the
        // measured count, no ⓘ), and combined (both, ⓘ because a shown value is estimated).
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let cost = WidgetDescriptor.values(id: "test.last30", provider: provider, title: "Last 30 Days",
                                           selection: .kind(.dollars), valueWord: "spent")
        let tokens = WidgetDescriptor.values(id: "test.last30.tokens", provider: provider,
                                             title: "Tokens", metricLabel: "Last 30 Days", selection: .kind(.count))
        let combined = WidgetDescriptor.combined(id: "test.last30.combined", provider: provider,
                                                 title: "Combined", metricLabel: "Last 30 Days")
        let todayCost = WidgetDescriptor.values(id: "test.today", provider: provider, title: "Today",
                                                selection: .kind(.dollars), valueWord: "spent")
        let descriptors = [cost, tokens, combined, todayCost]
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: descriptors,
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [
                    .values(label: "Last 30 Days", values: [
                        MetricValue(number: 478.0, kind: .dollars, estimated: true),
                        MetricValue(number: 891_000, kind: .count, label: "tokens")
                    ]),
                    // An unpriced day: real tokens, no dollar (cost unknown, not zero).
                    .values(label: "Today", values: [MetricValue(number: 123_000, kind: .count, label: "tokens")])
                ]
            )
        )
        let registry = WidgetRegistry(providers: [provider], descriptors: descriptors)
        let cache = ProviderSnapshotCache(
            userDefaults: makeUserDefaults("local-estimate"),
            storageKey: "snapshots",
            ttl: 600,
            now: { Date() }
        )
        let store = WidgetDataStore(registry: registry, providers: [runtime], cache: cache)
        await store.refreshAll()

        // Cost-only: the dollars, locally estimated.
        let costData = store.data(for: cost)
        XCTAssertEqual(costData.valueText, "$478.00")
        XCTAssertEqual(costData.unboundedDetail, "$478.00 spent")
        XCTAssertEqual(costData.infoNote, WidgetData.localEstimateNote)

        // Tokens-only: the measured count with its "tokens" unit; the tooltip has every digit.
        let tokenData = store.data(for: tokens)
        XCTAssertEqual(tokenData.unboundedDetail, "891K tokens")
        XCTAssertEqual(tokenData.menuBarValue, "891K tokens")
        XCTAssertEqual(tokenData.unboundedTooltip, "891,000 tokens")
        XCTAssertNil(tokenData.infoNote)

        // Combined: both values joined; the tray glances at the leading dollar value, the tooltip is full.
        let combinedData = store.data(for: combined)
        XCTAssertEqual(combinedData.unboundedDetail, "$478.00 · 891K tokens")
        XCTAssertEqual(combinedData.menuBarValue, "$478")
        XCTAssertEqual(combinedData.unboundedTooltip, "$478.00 · 891,000 tokens")
        XCTAssertEqual(combinedData.infoNote, WidgetData.localEstimateNote)

        // The value hover carries exact figures plus the source note.
        XCTAssertEqual(combinedData.unboundedValueTooltip, "$478.00 · 891,000 tokens\n\(WidgetData.localEstimateNote)")
        XCTAssertEqual(costData.unboundedValueTooltip, "$478.00\n\(WidgetData.localEstimateNote)")
        // The measured tokens tile has no source note, so it has only the exact-number value hover.
        XCTAssertNil(tokenData.infoNote)
        XCTAssertEqual(tokenData.unboundedValueTooltip, "891,000 tokens")

        // An unpriced day (real tokens, no dollar): the cost-only tile finds no dollar value, so it reads
        // "No data" rather than a fabricated $0.00.
        let todayData = store.data(for: todayCost)
        XCTAssertFalse(todayData.hasData)
        XCTAssertEqual(todayData.valueText, WidgetData.noDataHeadline)
    }

    func testCursorSpendValueTooltipUsesUsageHistorySourceNote() async {
        let cursor = CursorProvider()
        let provider = cursor.provider
        let combined = cursor.widgetDescriptors.first { $0.id == "cursor.last30" }!
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [combined],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [
                    .values(label: "Last 30 Days", values: [
                        MetricValue(number: 15.80, kind: .dollars),
                        MetricValue(number: 8_100_000_000, kind: .count, label: "tokens")
                    ])
                ]
            )
        )
        let store = WidgetDataStore(registry: WidgetRegistry(providers: [provider], descriptors: [combined]), providers: [runtime])
        await store.refreshAll()

        let data = store.data(for: combined)
        XCTAssertEqual(data.unboundedDetail, "$15.80 · 8.1B tokens")
        XCTAssertNil(data.infoNote)
        XCTAssertEqual(data.unboundedValueTooltip, "$15.80 · 8,100,000,000 tokens\n\(WidgetData.cursorUsageHistoryNote)")
    }

    func testUsesFreshCachedSnapshotInsteadOfRefreshingProvider() async {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor(
            id: "test.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100, displayMode: .remaining)
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = ProviderSnapshotCache(
            userDefaults: makeUserDefaults("fresh-cache"),
            storageKey: "snapshots",
            ttl: 600,
            now: { now }
        )
        cache.store(ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Session", used: 20, limit: 100, format: .percent)],
            refreshedAt: now.addingTimeInterval(-60)
        ))
        let runtime = CountingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Session", used: 80, limit: 100, format: .percent)],
                refreshedAt: now
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: cache,
            defaults: makeUserDefaults("fresh-cache-meter")
        )

        await store.refreshAll()

        XCTAssertEqual(runtime.refreshCount, 0)
        XCTAssertEqual(store.data(for: descriptor).valueText, "80%")
    }

    func testExpiredCacheRefreshesAndReplacesSnapshot() async {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor(
            id: "test.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100, displayMode: .remaining)
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let defaults = makeUserDefaults("expired-cache")
        let cache = ProviderSnapshotCache(
            userDefaults: defaults,
            storageKey: "snapshots",
            ttl: 600,
            now: { now }
        )
        cache.store(ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Session", used: 20, limit: 100, format: .percent)],
            refreshedAt: now.addingTimeInterval(-601)
        ))
        let runtime = CountingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Session", used: 80, limit: 100, format: .percent)],
                refreshedAt: now
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: cache,
            defaults: makeUserDefaults("expired-cache-meter")
        )

        await store.refreshAll()

        XCTAssertEqual(runtime.refreshCount, 1)
        XCTAssertEqual(store.data(for: descriptor).valueText, "20%")
    }

    func testResetDisplaySettingsRestoresDefaultsAndPersists() {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let registry = WidgetRegistry(providers: [provider], descriptors: [])
        let defaults = makeUserDefaults("reset-display-settings")
        let store = WidgetDataStore(registry: registry, providers: [], defaults: defaults)
        store.meterStyle = .used
        store.resetDisplayMode = .absolute
        store.alwaysShowPacing = true

        store.resetDisplaySettings()

        XCTAssertEqual(store.meterStyle, .remaining)
        XCTAssertEqual(store.resetDisplayMode, .relative)
        XCTAssertFalse(store.alwaysShowPacing)
        // A second store on the same suite must load the defaults back, not the pre-reset values.
        let reloaded = WidgetDataStore(registry: registry, providers: [], defaults: defaults)
        XCTAssertEqual(reloaded.meterStyle, .remaining)
        XCTAssertEqual(reloaded.resetDisplayMode, .relative)
        XCTAssertFalse(reloaded.alwaysShowPacing)
    }

    private func makeUserDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@MainActor
private final class SuspendedProviderRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor]
    private var continuation: CheckedContinuation<ProviderSnapshot, Never>?
    private(set) var didStart = false
    private(set) var observedScopes: [ProviderRefreshContext.Scope] = []
    private(set) var observedManualValues: [Bool] = []
    private(set) var observedManualActionIDs: [UInt64?] = []
    private(set) var observedInteractionGates: [CredentialInteractionGate?] = []
    private(set) var observedThrottleValues: [Bool] = []
    private var refreshCount = 0

    init(provider: Provider, descriptors: [WidgetDescriptor]) {
        self.provider = provider
        self.widgetDescriptors = descriptors
    }

    func refresh() async -> ProviderSnapshot {
        observedScopes.append(ProviderRefreshContext.scope)
        observedManualValues.append(ProviderRefreshContext.isManual)
        observedManualActionIDs.append(ProviderRefreshContext.manualActionID)
        observedInteractionGates.append(ProviderRefreshContext.credentialInteractionGate)
        observedThrottleValues.append(ProviderRefreshContext.accountingCPUThrottleEnabled)
        refreshCount += 1
        if refreshCount > 1 {
            return ProviderSnapshot.make(
                provider: provider,
                plan: nil,
                lines: [],
                refreshedAt: Date()
            )
        }
        didStart = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        continuation?.resume(returning: ProviderSnapshot.make(
            provider: provider,
            plan: nil,
            lines: [],
            refreshedAt: Date()
        ))
        continuation = nil
    }
}

@MainActor
private final class CatalogReloadCancellationRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor]
    private(set) var didStart = false
    private(set) var observedCancellation = false

    init(provider: Provider, descriptors: [WidgetDescriptor]) {
        self.provider = provider
        self.widgetDescriptors = descriptors
    }

    func refresh() async -> ProviderSnapshot {
        didStart = true
        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            observedCancellation = Task<Never, Never>.isCancelled
        }
        return ProviderSnapshot.error(provider: provider, error: CancellationError())
    }
}

private actor RefreshConcurrencyProbe {
    private var active = 0
    private var maximum = 0
    private var total = 0

    func begin() {
        active += 1
        total += 1
        maximum = max(maximum, active)
    }

    func end() {
        active -= 1
    }

    func maximumActive() -> Int { maximum }
    func refreshCount() -> Int { total }
}

@MainActor
private final class PanelMeterOverlapProviderRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor]
    private let freshMeters: ProviderSnapshot
    private let staleFold: ProviderSnapshot
    private var foldContinuation: CheckedContinuation<ProviderSnapshot, Never>?
    private(set) var didStartFold = false
    private(set) var didStartPanelMeters = false
    private(set) var didFinishFold = false
    var onFoldStart: (() -> Void)?
    var onPanelMetersStart: (() -> Void)?

    init(
        provider: Provider,
        descriptors: [WidgetDescriptor],
        freshMeters: ProviderSnapshot,
        staleFold: ProviderSnapshot
    ) {
        self.provider = provider
        self.widgetDescriptors = descriptors
        self.freshMeters = freshMeters
        self.staleFold = staleFold
    }

    func refresh() async -> ProviderSnapshot {
        switch ProviderRefreshContext.scope {
        case .localAccounting, .panelAccounting:
            didStartFold = true
            onFoldStart?()
            let result = await withCheckedContinuation { (continuation: CheckedContinuation<ProviderSnapshot, Never>) in
                foldContinuation = continuation
            }
            didFinishFold = true
            return result
        case .panelMeters:
            didStartPanelMeters = true
            onPanelMetersStart?()
            return freshMeters
        case .menuBar, .full:
            return freshMeters
        }
    }

    func resumeFold() {
        foldContinuation?.resume(returning: staleFold)
        foldContinuation = nil
    }
}

@MainActor
private final class TestConcurrencyProviderRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor] = []
    private let probe: RefreshConcurrencyProbe

    init(provider: Provider, probe: RefreshConcurrencyProbe) {
        self.provider = provider
        self.probe = probe
    }

    func refresh() async -> ProviderSnapshot {
        await probe.begin()
        try? await Task.sleep(for: .milliseconds(20))
        await probe.end()
        return ProviderSnapshot(providerID: provider.id, displayName: provider.displayName, lines: [])
    }
}

@MainActor
private final class RefreshContextRecordingProviderRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor]
    private let snapshot: ProviderSnapshot

    private(set) var observedScope: ProviderRefreshContext.Scope?
    private(set) var observedIsManual = false
    private(set) var observedManualActionID: UInt64?
    private(set) var observedInteractionGate: CredentialInteractionGate?
    private(set) var observedAccountingCPUThrottleEnabled = false

    init(provider: Provider, descriptors: [WidgetDescriptor], snapshot: ProviderSnapshot) {
        self.provider = provider
        self.widgetDescriptors = descriptors
        self.snapshot = snapshot
    }

    func refresh() async -> ProviderSnapshot {
        observedScope = ProviderRefreshContext.scope
        observedIsManual = ProviderRefreshContext.isManual
        observedManualActionID = ProviderRefreshContext.manualActionID
        observedInteractionGate = ProviderRefreshContext.credentialInteractionGate
        observedAccountingCPUThrottleEnabled = ProviderRefreshContext.accountingCPUThrottleEnabled
        return snapshot
    }

    func hasLocalCredentials() async -> Bool { true }
}
