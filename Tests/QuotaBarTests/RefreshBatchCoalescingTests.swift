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
}
