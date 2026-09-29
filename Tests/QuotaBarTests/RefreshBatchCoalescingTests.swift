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
        private let gate: AsyncGate

        init(provider: Provider, descriptors: [WidgetDescriptor], gate: AsyncGate) {
            self.provider = provider
            self.widgetDescriptors = descriptors
            self.gate = gate
        }

        func refresh() async -> ProviderSnapshot {
            refreshCount += 1
            await gate.wait()
            return .error(provider: provider, message: "Not logged in")
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
        private var released = false

        init(provider: Provider, descriptors: [WidgetDescriptor]) {
            self.provider = provider
            self.widgetDescriptors = descriptors
        }

        var refreshCount: Int { entries }

        func release() {
            lock.lock()
            released = true
            lock.unlock()
        }

        /// All lock access lives in synchronous helpers: Swift 6 forbids `NSLock` in an `async` context,
        /// and the poll below needs the flag re-read on every turn.
        private func enter() -> Bool {
            lock.lock()
            _count += 1
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
            if !enter() {
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
}
