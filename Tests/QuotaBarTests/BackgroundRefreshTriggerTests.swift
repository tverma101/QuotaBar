import Foundation
import XCTest
@testable import QuotaBar

/// Covers the external, tap-free refresh trigger.
///
/// The regression these lock down is the one that made the first version unusable: the trigger
/// observed the same local notification name it *emitted*, so each wake re-posted itself and the
/// refresh loop settled into a self-sustaining ~1 Hz refresh storm. Two properties matter and both
/// are asserted here — one distributed post produces exactly one local wake, and a stopped trigger
/// is deaf.
final class BackgroundRefreshTriggerTests: XCTestCase {
    /// One distributed post must produce exactly one local wake.
    ///
    /// Uses a real `DistributedNotificationCenter` on both ends (the distributed center has no useful
    /// in-process test seam), with a unique name per run so concurrent tests cannot cross-fire.
    /// Distributed delivery lands on the main run loop, so the test pumps it rather than sleeping.
    func testSingleDistributedPostYieldsExactlyOneLocalWake() throws {
        let name = Notification.Name("com.quotabar.refresh.tests.\(UUID().uuidString)")
        let localCenter = NotificationCenter()
        let counter = WakeCounter()
        let observer = localCenter.addObserver(forName: BackgroundRefreshTrigger.didChangeNotification, object: nil, queue: nil) { _ in
            counter.increment()
        }
        defer { localCenter.removeObserver(observer) }

        let trigger = BackgroundRefreshTrigger(
            localCenter: localCenter,
            distributedCenter: DistributedNotificationCenter(),
            observedDistributedName: name,
            // Short enough to keep the test fast; the production value is 1s.
            debounceNanoseconds: 20_000_000
        )
        trigger.start()
        defer { trigger.stop() }
        pumpRunLoop(for: 0.2)  // let `start()` arm the observer

        DistributedNotificationCenter().postNotificationName(
            name,
            object: nil,
            deliverImmediately: true
        )

        // Debounce (20ms) + distributed delivery + local wake, all inside a pumped window.
        pumpRunLoop(for: 1.0)
        XCTAssertEqual(counter.count, 1, "one distributed post must produce exactly one local wake")
        // Then nothing else: a self-feeding trigger would keep incrementing here forever.
        pumpRunLoop(for: 0.6)
        XCTAssertEqual(
            counter.count,
            1,
            "a trigger must not re-post its own wake; count climbing past 1 is the feedback loop"
        )
    }

    /// A burst of distributed posts collapses into a single wake.
    func testDistributedBurstDebouncesIntoOneWake() throws {
        let name = Notification.Name("com.quotabar.refresh.tests.\(UUID().uuidString)")
        let localCenter = NotificationCenter()
        let counter = WakeCounter()
        let observer = localCenter.addObserver(forName: BackgroundRefreshTrigger.didChangeNotification, object: nil, queue: nil) { _ in
            counter.increment()
        }
        defer { localCenter.removeObserver(observer) }

        let trigger = BackgroundRefreshTrigger(
            localCenter: localCenter,
            distributedCenter: DistributedNotificationCenter(),
            observedDistributedName: name,
            debounceNanoseconds: 200_000_000
        )
        trigger.start()
        defer { trigger.stop() }
        pumpRunLoop(for: 0.2)

        // Ten posts well inside the 200ms debounce window → one wake.
        for _ in 0..<10 {
            DistributedNotificationCenter().postNotificationName(
                name,
                object: nil,
                deliverImmediately: true
            )
        }

        pumpRunLoop(for: 1.0)
        XCTAssertEqual(counter.count, 1, "burst must coalesce into exactly one wake")
        pumpRunLoop(for: 0.6)
        XCTAssertEqual(
            counter.count,
            1,
            "ten posts inside the debounce window must coalesce into one wake"
        )
    }

    /// After `stop()`, a distributed post is ignored.
    func testStoppedTriggerIgnoresPosts() throws {
        let name = Notification.Name("com.quotabar.refresh.tests.\(UUID().uuidString)")
        let localCenter = NotificationCenter()
        let counter = WakeCounter()
        let observer = localCenter.addObserver(forName: BackgroundRefreshTrigger.didChangeNotification, object: nil, queue: nil) { _ in
            counter.increment()
        }
        defer { localCenter.removeObserver(observer) }

        let trigger = BackgroundRefreshTrigger(
            localCenter: localCenter,
            distributedCenter: DistributedNotificationCenter(),
            observedDistributedName: name,
            debounceNanoseconds: 20_000_000
        )
        trigger.start()
        pumpRunLoop(for: 0.2)
        trigger.stop()
        pumpRunLoop(for: 0.2)

        DistributedNotificationCenter().postNotificationName(
            name,
            object: nil,
            deliverImmediately: true
        )
        pumpRunLoop(for: 0.5)
        XCTAssertEqual(counter.count, 0, "a stopped trigger must be deaf")
    }

    /// After `stop()`, a post that arrives mid-debounce must not be flushed to the local center.
    /// Without the `started` guard on the queue, `stop()` could unregister the observer while the
    /// already-scheduled work item still posts — a wake for nobody, and (in the loop) a free pass.
    func testStopDuringDebounceDoesNotFlushAWake() throws {
        let name = Notification.Name("com.quotabar.refresh.tests.\(UUID().uuidString)")
        let localCenter = NotificationCenter()
        let counter = WakeCounter()
        let observer = localCenter.addObserver(forName: BackgroundRefreshTrigger.didChangeNotification, object: nil, queue: nil) { _ in
            counter.increment()
        }
        defer { localCenter.removeObserver(observer) }

        let trigger = BackgroundRefreshTrigger(
            localCenter: localCenter,
            distributedCenter: DistributedNotificationCenter(),
            observedDistributedName: name,
            debounceNanoseconds: 500_000_000
        )
        trigger.start()
        pumpRunLoop(for: 0.2)

        DistributedNotificationCenter().postNotificationName(
            name,
            object: nil,
            deliverImmediately: true
        )
        // Stop while the 500ms debounce is still pending (the wake work item is armed).
        pumpRunLoop(for: 0.1)
        trigger.stop()
        // Wait past the original debounce deadline.
        pumpRunLoop(for: 0.7)
        XCTAssertEqual(counter.count, 0, "stop must cancel a pending debounced wake")
    }

    // MARK: - Loop-side rate limit (BackgroundRefreshGate)

    /// The gate the refresh loop actually calls must accept a first trigger, reject a burst inside
    /// the cooldown, and accept again once the cooldown expires. Uses the production gate type and
    /// the production default interval, so a regression in the gate itself fails here.
    func testGateAcceptsFirstRejectsBurstThenAcceptsAfterCooldown() {
        var gate = BackgroundRefreshGate()
        let t0 = Date()
        let cooldown = BackgroundRefreshTrigger.minimumPassInterval

        XCTAssertTrue(gate.shouldAccept(at: t0), "the first trigger must be accepted")

        // A burst inside the cooldown is rejected, however fast it arrives.
        for offset in [0.0, 1.0, cooldown - 0.001] {
            XCTAssertFalse(
                gate.shouldAccept(at: t0.addingTimeInterval(offset)),
                "a trigger \(offset)s into a \(cooldown)s cooldown must be rejected"
            )
        }

        // Past the cooldown, accepted again.
        XCTAssertTrue(
            gate.shouldAccept(at: t0.addingTimeInterval(cooldown + 0.001)),
            "a trigger past the cooldown must be accepted"
        )
    }

    /// A steady 1 Hz poster — the exact storm debouncing cannot stop — yields at most one pass per
    /// cooldown window.
    func testGateBoundsSustainedOneHertzBurst() {
        var gate = BackgroundRefreshGate(minimumInterval: 15)
        let t0 = Date()
        var accepted = 0
        for second in 0..<300 {
            if gate.shouldAccept(at: t0.addingTimeInterval(Double(second))) {
                accepted += 1
            }
        }
        // 300 one-second posts against a 15s cooldown is 20 passes, never 300.
        XCTAssertEqual(accepted, 20, "a 1 Hz poster must be bounded to one pass per cooldown window")
    }

    /// `reset()` releases a recorded acceptance, so a trigger whose pass never ran does not block
    /// the next one for a whole cooldown.
    func testGateResetReleasesCooldown() {
        var gate = BackgroundRefreshGate(minimumInterval: 15)
        let t0 = Date()
        XCTAssertTrue(gate.shouldAccept(at: t0))
        XCTAssertFalse(gate.shouldAccept(at: t0.addingTimeInterval(1)))
        gate.reset()
        XCTAssertTrue(
            gate.shouldAccept(at: t0.addingTimeInterval(1)),
            "reset must let the next trigger through without waiting out a cooldown"
        )
    }

    // MARK: - Store invalidation the accepted trigger performs

    /// A trigger must make the local accounting cards actually re-fold, and only those.
    ///
    /// `WidgetDataStore.invalidateLocalAccountingFreshness()` is the store half of the trigger path.
    /// The regression it guards: invalidating Codex alone leaves OpenCode served from a TTL-fresh
    /// snapshot even though both fold the same ledger, so a triggered pass would leave the cards
    /// disagreeing. A remote card (cursor) must keep its cache so a trigger does not fan out to
    /// unrelated network calls.
    @MainActor
    func testLocalAccountingInvalidationMissesOnlyCodexAndOpenCode() async {
        let codex = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let opencode = Provider(id: "opencode", displayName: "OpenCode", icon: .providerMark("opencode"))
        let cursor = Provider(id: "cursor", displayName: "Cursor", icon: .providerMark("cursor"))
        let descriptors = [codex, opencode, cursor].map {
            WidgetDescriptor.percent(
                id: "\($0.id).auto",
                provider: $0,
                title: $0.displayName,
                sessionStartSignal: .zeroUsage
            )
        }
        let runtimes = [codex, opencode, cursor].map {
            CountingProviderRuntime(
                provider: $0,
                descriptors: descriptors,
                snapshot: ProviderSnapshot(
                    providerID: $0.id,
                    displayName: $0.displayName,
                    lines: [.progress(label: $0.displayName, used: 1, limit: 2, format: .percent)]
                )
            )
        }
        let suiteName = "OpenUsageTests.bg-trigger.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [codex, opencode, cursor], descriptors: descriptors),
            providers: runtimes,
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults
        )

        // Prime every card, then let a non-forced pass be served entirely from cache.
        await store.refreshAll(force: true)
        let primed = runtimes.map(\.refreshCount)
        await store.refreshAll()
        XCTAssertEqual(
            runtimes.map(\.refreshCount),
            primed,
            "a non-forced pass inside the TTL must be all cache hits"
        )

        // What the accepted trigger does.
        store.invalidateLocalAccountingFreshness()
        await store.refreshAll()

        XCTAssertEqual(runtimes[0].refreshCount, primed[0] + 1, "codex must re-fold after a trigger")
        XCTAssertEqual(
            runtimes[1].refreshCount,
            primed[1] + 1,
            "opencode must re-fold after a trigger — it folds the same local ledger"
        )
        XCTAssertEqual(
            runtimes[2].refreshCount,
            primed[2],
            "an unrelated remote card must keep its cache, so a trigger does not fan out to it"
        )
    }

    /// Thread-safe wake counter for the cross-thread notification callbacks.
    private final class WakeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var seen = 0

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return seen
        }

        func increment() {
            lock.lock()
            seen += 1
            lock.unlock()
        }
    }

    /// Spins the main run loop so `DistributedNotificationCenter` can deliver. The distributed
    /// center hands notifications to the main run loop regardless of the poster, so a plain sleep
    /// would never observe the wake.
    private func pumpRunLoop(for seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
