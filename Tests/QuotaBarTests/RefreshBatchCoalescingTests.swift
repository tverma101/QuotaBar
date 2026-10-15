import Foundation
import XCTest
@testable import QuotaBar

/// The panel fires a forced full-scope batch on every popover open, and it used to fire them
/// fire-and-forget. Combined with a forced-wait path that was a bare `Task.yield()` spin, a user
/// opening and closing the panel repeatedly stacked un-cancellable batches, each with a task per
/// provider, each spinning on the MainActor while any provider was in flight.
///
/// `refreshAll` now coalesces callers asking for identical work. These tests pin that, plus the
/// deliberate exception: a caller with a *different* (force, scope) must not be handed the wrong pass.
@MainActor
final class RefreshBatchCoalescingTests: XCTestCase {
    /// A slow provider: `refresh()` suspends until the test releases it, so a second batch genuinely
    /// overlaps the first instead of racing to completion.
    private final class SuspendableRuntime: ProviderRuntime {
        let provider: Provider
        let widgetDescriptors: [WidgetDescriptor]
        private(set) var refreshCount = 0
        private(set) var cancellationStates: [Bool] = []
        private(set) var manualActionIDs: [UInt64?] = []
        private let gate: AsyncGate

        init(provider: Provider, descriptors: [WidgetDescriptor], gate: AsyncGate) {
            self.provider = provider
            self.widgetDescriptors = descriptors
            self.gate = gate
        }

        func refresh() async -> ProviderSnapshot {
            refreshCount += 1
            manualActionIDs.append(ProviderRefreshContext.manualActionID)
            await withTaskCancellationHandler {
                await gate.wait()
            } onCancel: {
                gate.openGate()
            }
            cancellationStates.append(Task.isCancelled)
            return .error(provider: provider, message: "Not logged in")
        }

        func waitForEntries(_ count: Int) async {
            while refreshCount < count { await Task.yield() }
        }
    }

    /// A minimal one-shot async gate, so a test can hold a provider "in flight" deterministically.
    private final class AsyncGate: @unchecked Sendable {
        private let lock = NSLock()
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if open {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        func openGate() {
            lock.lock()
            open = true
            let pending = waiters
            waiters = []
            lock.unlock()
            for continuation in pending { continuation.resume() }
        }
    }

    func testConcurrentIdenticalBatchesShareOneProviderPass() async {
        let gate = AsyncGate()
        let provider = Provider(id: "devin", displayName: "Devin", icon: .providerMark("devin"))
        let descriptor = WidgetDescriptor(
            id: "devin.weekly", providerID: provider.id, metricLabel: "Weekly quota",
            sample: WidgetData(title: "Weekly", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        let runtime = SuspendableRuntime(provider: provider, descriptors: [descriptor], gate: gate)
        let store = makeStore(runtime: runtime)

        // Three overlapping callers asking for exactly the same batch.
        async let first: Void = store.refreshAll(force: true)
        // Let the first batch actually reach the provider before the others arrive.
        await Task.yield()
        async let second: Void = store.refreshAll(force: true)
        async let third: Void = store.refreshAll(force: true)

        gate.openGate()
        _ = await (first, second, third)

        XCTAssertEqual(
            runtime.refreshCount, 1,
            "identical concurrent batches must coalesce into one provider pass, not one per caller"
        )
    }

    func testIdenticalBatchesWithinOneManualActionShareOneProviderPass() async {
        let gate = AsyncGate()
        let provider = Provider(id: "devin", displayName: "Devin", icon: .providerMark("devin"))
        let descriptor = WidgetDescriptor(
            id: "devin.weekly", providerID: provider.id, metricLabel: "Weekly quota",
            sample: WidgetData(title: "Weekly", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        let runtime = SuspendableRuntime(provider: provider, descriptors: [descriptor], gate: gate)
        let store = makeStore(runtime: runtime)

        await withManualRefresh {
            let first = Task { await store.refreshAll(force: true) }
            await runtime.waitForEntries(1)
            let second = Task { await store.refreshAll(force: true) }
            let third = Task { await store.refreshAll(force: true) }
            gate.openGate()
            await first.value
            await second.value
            await third.value
        }

        XCTAssertEqual(runtime.refreshCount, 1, "same-action callers must retain batch coalescing")
    }

    func testNewManualActionDoesNotJoinSupersededBatch() async throws {
        let provider = Provider(id: "devin", displayName: "Devin", icon: .providerMark("devin"))
        let descriptor = WidgetDescriptor(
            id: "devin.weekly", providerID: provider.id, metricLabel: "Weekly quota",
            sample: WidgetData(title: "Weekly", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        let runtime = CountingBlockingRuntime(provider: provider, descriptors: [descriptor])
        let store = makeStore(runtime: runtime)

        let first = Task {
            await withManualRefresh { await store.refreshAll(force: true) }
        }
        try await runtime.waitForEntries(1)
        let second = Task {
            await withManualRefresh { await store.refreshAll(force: true) }
        }

        // The second action owns a distinct batch, but its per-provider forced work waits for the
        // in-flight pass to release. It must then enter under the new action ID.
        try await runtime.waitForEntriesOrTimeout(2, milliseconds: 80)
        XCTAssertEqual(runtime.refreshCount, 1, "the new action waits instead of duplicating active provider work")
        runtime.release()
        await first.value
        await second.value

        XCTAssertEqual(runtime.refreshCount, 2, "a later action must perform its own provider pass")
        XCTAssertEqual(runtime.manualActionIDs.count, 2)
        XCTAssertNotEqual(runtime.manualActionIDs[0], runtime.manualActionIDs[1])
        XCTAssertTrue(runtime.manualActionIDs.allSatisfy { $0 != nil })
    }

    func testCancelledJoinerDoesNotCancelTheSharedBatch() async {
        let gate = AsyncGate()
        let provider = Provider(id: "devin", displayName: "Devin", icon: .providerMark("devin"))
        let descriptor = WidgetDescriptor(
            id: "devin.weekly", providerID: provider.id, metricLabel: "Weekly quota",
            sample: WidgetData(title: "Weekly", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        let runtime = SuspendableRuntime(provider: provider, descriptors: [descriptor], gate: gate)
        let store = makeStore(runtime: runtime)

        let owner = Task { await store.refreshAll(force: true) }
        while runtime.refreshCount == 0 { await Task.yield() }
        let joiner = Task { await store.refreshAll(force: true) }
        await Task.yield()
        joiner.cancel()
        await Task.yield()
        gate.openGate()
        await owner.value
        await joiner.value

        XCTAssertEqual(runtime.refreshCount, 1)
        XCTAssertEqual(runtime.cancellationStates, [false], "a canceled waiter cannot cancel shared provider work")
    }

    func testCancellingOlderManualBatchLeavesNewerSameScopeBatchAlive() async {
        let gate = AsyncGate()
        let provider = Provider(id: "devin", displayName: "Devin", icon: .providerMark("devin"))
        let descriptor = WidgetDescriptor(
            id: "devin.weekly", providerID: provider.id, metricLabel: "Weekly quota",
            sample: WidgetData(title: "Weekly", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        let runtime = SuspendableRuntime(provider: provider, descriptors: [descriptor], gate: gate)
        let store = makeStore(runtime: runtime)

        let older = Task {
            await withManualRefresh { await store.refreshAll(force: true) }
        }
        while runtime.refreshCount == 0 { await Task.yield() }
        let olderActionID = runtime.manualActionIDs[0]
        let newer = Task {
            await withManualRefresh { await store.refreshAll(force: true) }
        }
        while KeychainPermissionGate.shared.isCurrentManualAction(olderActionID) {
            await Task.yield()
        }

        older.cancel()
        while runtime.refreshCount < 2 { await Task.yield() }
        gate.openGate()
        await older.value
        await newer.value

        XCTAssertEqual(runtime.refreshCount, 2)
        XCTAssertEqual(runtime.manualActionIDs.count, 2)
        XCTAssertNotEqual(runtime.manualActionIDs[0], runtime.manualActionIDs[1])
        XCTAssertEqual(runtime.cancellationStates, [true, false])
    }

    func testTargetedManualRefreshKeepsOtherCardsAndRetriesSupersededCancellationSilently() async {
        let runtimes = ["a", "b", "c"].map { id in
            ControlledRuntime(provider: Provider(id: id, displayName: id.uppercased(), icon: .providerMark("codex")))
        }
        let store = makeStore(runtimes: runtimes)
        let runtimeA = runtimes[0]
        let runtimeB = runtimes[1]
        let runtimeC = runtimes[2]

        let fullRefresh = Task {
            await withManualRefresh { await store.refreshAll(force: true) }
        }
        for runtime in runtimes { await runtime.waitForEntries(1) }
        let originalActionID = runtimeA.calls[0].manualActionID

        let targetedRefresh = Task {
            await withManualRefresh { await store.refresh(providerID: "b", force: true) }
        }
        while KeychainPermissionGate.shared.isCurrentManualAction(originalActionID) {
            await Task.yield()
        }

        // A and B model Keychain reads cancelled when the newer action begins. C's unrelated work
        // succeeds under the old action and must still be allowed to publish.
        runtimeA.resolve(1, with: .error(provider: runtimeA.provider, error: CancellationError()))
        runtimeB.resolve(1, with: .error(provider: runtimeB.provider, error: CancellationError()))
        runtimeC.resolve(1, with: snapshot(runtimeC.provider, plan: "C old pass"))

        await runtimeA.waitForEntries(2)
        await runtimeB.waitForEntries(2)
        runtimeA.resolve(2, with: snapshot(runtimeA.provider, plan: "A silent retry"))
        runtimeB.resolve(2, with: snapshot(runtimeB.provider, plan: "B targeted pass"))
        await fullRefresh.value
        let targetedOutcome = await targetedRefresh.value
        XCTAssertEqual(targetedOutcome, .refreshed)

        XCTAssertEqual(store.localSnapshots["a"]?.plan, "A silent retry")
        XCTAssertEqual(store.localSnapshots["b"]?.plan, "B targeted pass")
        XCTAssertEqual(store.localSnapshots["c"]?.plan, "C old pass")
        XCTAssertNil(store.providerErrors["a"], "cancellation is not a provider failure")
        XCTAssertNil(store.providerErrors["b"], "superseded work must not set failure/backoff")
        XCTAssertEqual(runtimeA.calls.count, 2)
        XCTAssertNil(runtimeA.calls[1].manualActionID, "the retry cannot inherit an expired prompt budget")
        XCTAssertFalse(runtimeA.calls[1].isManual, "the retry must stay prompt-free")
        XCTAssertEqual(runtimeB.calls.count, 2, "the targeted action must run after old work settles")
    }

    /// The exception that keeps the join honest: a forced caller must never be handed a pass that ran
    /// with different settings, because that is how the panel ends up on quota-only merge data.
    func testADifferentForceOrScopeIsNotCoalescedIntoAnInFlightBatch() async {
        let gate = AsyncGate()
        let provider = Provider(id: "devin", displayName: "Devin", icon: .providerMark("devin"))
        let descriptor = WidgetDescriptor(
            id: "devin.weekly", providerID: provider.id, metricLabel: "Weekly quota",
            sample: WidgetData(title: "Weekly", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        let runtime = SuspendableRuntime(provider: provider, descriptors: [descriptor], gate: gate)
        let store = makeStore(runtime: runtime)

        // A non-forced batch in flight, then a forced caller. The forced one must run its own pass.
        async let background: Void = store.refreshAll(force: false)
        await Task.yield()
        async let forced: Void = store.refreshAll(force: true)

        gate.openGate()
        _ = await (background, forced)

        XCTAssertEqual(
            runtime.refreshCount, 2,
            "a forced caller must not be served by a non-forced in-flight batch"
        )
    }

    // MARK: - Helpers

    private func makeStore(runtime: some ProviderRuntime) -> WidgetDataStore {
        let suiteName = "OpenUsageTests.BatchCoalescing.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        return WidgetDataStore(
            registry: WidgetRegistry(
                providers: [runtime.provider],
                descriptors: runtime.widgetDescriptors
            ),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: suite, storageKey: "snapshots", ttl: 600),
            defaults: suite
        )
    }

    private func makeStore(runtimes: [ControlledRuntime]) -> WidgetDataStore {
        let suiteName = "OpenUsageTests.BatchCoalescing.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        let providers = runtimes.map(\.provider)
        let descriptors = runtimes.flatMap(\.widgetDescriptors)
        return WidgetDataStore(
            registry: WidgetRegistry(providers: providers, descriptors: descriptors),
            providers: runtimes,
            cache: ProviderSnapshotCache(userDefaults: suite, storageKey: "snapshots", ttl: 600),
            defaults: suite
        )
    }

    private func snapshot(_ provider: Provider, plan: String) -> ProviderSnapshot {
        ProviderSnapshot.make(provider: provider, plan: plan, lines: [], refreshedAt: Date())
    }


    /// A different-signature batch must not un-register one that is still running.
    ///
    /// The registration was a single slot. The periodic tick (non-forced) routinely overlaps a forced
    /// panel-open batch and finishes first, because a non-forced caller *skips* providers already in
    /// flight — its completion then cleared the forced batch's registration while that batch was still
    /// fetching. The next popover open saw an empty slot, started a second batch, and re-fetched every
    /// provider: double API calls, a second full parse of the JSONL corpus, and a spinner for the sum of
    /// both passes.
    ///
    /// Ordering is the whole test: the forced batch is held open, a non-forced batch completes over it,
    /// and only then does a second *forced* caller arrive. It must join, so the provider is entered once.
    func testAFastBatchCompletingDoesNotUnregisterTheSlowOneStillRunning() async throws {
        let provider = Provider(id: "devin", displayName: "Devin", icon: .providerMark("devin"))
        let descriptor = WidgetDescriptor(
            id: "devin.weekly", providerID: provider.id, metricLabel: "Weekly quota",
            sample: WidgetData(title: "Weekly", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        let runtime = CountingBlockingRuntime(provider: provider, descriptors: [descriptor])
        let store = makeStore(runtime: runtime)

        // 1. A forced batch starts and blocks inside the provider.
        async let slow: Void = store.refreshAll(force: true)
        try await runtime.waitForEntries(1)

        // 2. A non-forced batch overlaps it and completes: the provider is in flight, so this caller
        //    skips and returns. This is what used to wipe the forced batch's registration.
        await store.refreshAll(force: false)
        XCTAssertEqual(runtime.refreshCount, 1, "the non-forced caller must skip, not re-fetch")

        // 3. A second forced caller arrives while the first is *still* running. It must join it, which
        //    means the provider must NOT be entered a second time. So we wait for a second entry with a
        //    bounded timeout and require that it never arrives: waiting for it unconditionally would
        //    deadlock, because the fixed behaviour is precisely that the count stays at 1.
        async let third: Void = store.refreshAll(force: true)
        try await runtime.waitForEntriesOrTimeout(2, milliseconds: 250)

        XCTAssertEqual(
            runtime.refreshCount, 1,
            "a forced caller must join the in-flight batch, not start a second pass"
        )

        // 4. Release, then let both forced callers finish.
        runtime.release()
        _ = await (slow, third)

        XCTAssertEqual(
            runtime.refreshCount, 1,
            "a completed batch of a different signature must not let a later forced caller re-fetch"
        )
    }

    /// Counts entries into `refresh()` and holds each one until `release()`. Lets a test hold a batch in
    /// flight deterministically rather than racing a timer.
    private final class CountingBlockingRuntime: ProviderRuntime, @unchecked Sendable {
        let provider: Provider
        let widgetDescriptors: [WidgetDescriptor]
        private let lock = NSLock()
        private var _count = 0
        private var _manualActionIDs: [UInt64?] = []
        private var released = false

        init(provider: Provider, descriptors: [WidgetDescriptor]) {
            self.provider = provider
            self.widgetDescriptors = descriptors
        }

        var refreshCount: Int { entries }
        var manualActionIDs: [UInt64?] {
            lock.lock(); defer { lock.unlock() }
            return _manualActionIDs
        }

        func release() {
            lock.lock()
            released = true
            lock.unlock()
        }

        /// All lock access lives in synchronous helpers: Swift 6 forbids `NSLock` in an `async` context,
        /// and the poll below needs the flag re-read on every turn.
        private func enter(manualActionID: UInt64?) -> Bool {
            lock.lock()
            _count += 1
            _manualActionIDs.append(manualActionID)
            let isOpen = released
            lock.unlock()
            return isOpen
        }

        private var isReleased: Bool {
            lock.lock(); defer { lock.unlock() }
            return released
        }

        private var entries: Int {
            lock.lock(); defer { lock.unlock() }
            return _count
        }

        func refresh() async -> ProviderSnapshot {
            if !enter(manualActionID: ProviderRefreshContext.manualActionID) {
                while !isReleased {
                    try? await Task.sleep(for: .milliseconds(2))
                }
            }
            return .error(provider: provider, message: "Not logged in")
        }

        func waitForEntries(_ n: Int) async throws {
            while entries < n {
                try await Task.sleep(for: .milliseconds(2))
            }
        }

        /// Returns as soon as `n` entries are reached, or after `milliseconds` elapses. Used where the
        /// *absence* of an entry is the assertion, so an unconditional wait would hang.
        func waitForEntriesOrTimeout(_ n: Int, milliseconds: Int) async throws {
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(milliseconds))
            while entries < n {
                if ContinuousClock.now >= deadline { return }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    @MainActor
    private final class ControlledRuntime: ProviderRuntime {
        struct Call {
            let manualActionID: UInt64?
            let isManual: Bool
        }

        let provider: Provider
        let widgetDescriptors: [WidgetDescriptor]
        private(set) var calls: [Call] = []
        private var continuations: [Int: CheckedContinuation<ProviderSnapshot, Never>] = [:]
        private var earlyResults: [Int: ProviderSnapshot] = [:]

        init(provider: Provider) {
            self.provider = provider
            self.widgetDescriptors = [WidgetDescriptor.percent(
                id: "\(provider.id).session", provider: provider, title: "Session"
            )]
        }

        func refresh() async -> ProviderSnapshot {
            calls.append(Call(
                manualActionID: ProviderRefreshContext.manualActionID,
                isManual: ProviderRefreshContext.isManual
            ))
            let index = calls.count
            return await withCheckedContinuation { continuation in
                if let result = earlyResults.removeValue(forKey: index) {
                    continuation.resume(returning: result)
                } else {
                    continuations[index] = continuation
                }
            }
        }

        func resolve(_ index: Int, with snapshot: ProviderSnapshot) {
            if let continuation = continuations.removeValue(forKey: index) {
                continuation.resume(returning: snapshot)
            } else {
                earlyResults[index] = snapshot
            }
        }

        func waitForEntries(_ count: Int) async {
            while calls.count < count { await Task.yield() }
        }
    }
}

