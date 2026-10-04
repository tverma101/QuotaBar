import Foundation

/// External, tap-free way to ask the running app for one background accounting pass.
///
/// Posted as a **distributed** notification, so any local process can drive a repeatable refresh
/// without touching the menu bar. Foundation is the documented poster:
///
/// ```sh
/// swift -e 'import Foundation
/// DistributedNotificationCenter().postNotificationName(
///     Notification.Name("com.quotabar.refresh"), object: nil, deliverImmediately: true)'
/// ```
///
/// (`notifyutil -p` sends a Darwin notification, which is a different channel and does *not* reach
/// this observer. Use the Swift one-liner above, or any wrapper built on Foundation.
/// `deliverImmediately` is required: without it the distributed center only coalesces within a run
/// loop, and a one-shot script has none. The Swift overlay's
/// `post(name:object:deliverImmediately:)` overload does not exist on this toolchain, hence the
/// `postNotificationName` spelling.)
///
/// ## What one trigger costs
///
/// The wake runs one `.full`-scope, non-forced refresh pass with session freshness cleared for the
/// local accounting cards (`WidgetDataStore.invalidateLocalAccountingFreshness`). Those cards
/// re-fold their local histories, and a Codex card's `refresh()` also re-reads its live quota API, so
/// a trigger is a normal background refresh brought forward — it can cost local CPU *and* provider
/// API calls.
///
/// ## Anti-storm limits
///
/// Debouncing alone cannot bound the pass rate: posts arriving *during* a multi-second pass are
/// coalesced into a buffer and released the instant the pass ends, so a 1 Hz poster would still drive
/// one pass per second. `BackgroundRefreshGate` is the loop-side bound: it accepts a trigger only
/// when at least `minimumPassInterval` has passed since the last accepted one, measured against the
/// clock rather than against arrivals.
final class BackgroundRefreshTrigger: @unchecked Sendable {
    /// In-process notification the refresh loop wakes on.
    static let didChangeNotification = Notification.Name("QuotaBar.BackgroundRefreshRequested")

    /// Distributed name to post. Stable, public, and the only channel this trigger listens on.
    static let distributedNotificationName = Notification.Name("com.quotabar.refresh")

    /// Floor between two trigger-caused passes, enforced by the refresh loop.
    static let minimumPassInterval: TimeInterval = 15

    /// How long a burst of distributed posts is collapsed before one wake is posted. Write storms
    /// (a loop posting once per line) must not turn into one refresh per line.
    static let debounceNanoseconds: UInt64 = 1_000_000_000

    private let localCenter: NotificationCenter
    private let distributedCenter: DistributedNotificationCenter
    /// The distributed name this trigger listens on. Production uses
    /// `distributedNotificationName`; tests inject a unique per-run name so concurrent test cases
    /// (and any other distributed notification traffic on the bus) cannot cross-fire.
    private let observedDistributedName: Notification.Name
    private let debounceNanoseconds: UInt64
    private let queue = DispatchQueue(label: "QuotaBar.BackgroundRefreshTrigger")
    private var debounceWorkItem: DispatchWorkItem?
    private var started = false
    private nonisolated(unsafe) var observer: (any NSObjectProtocol)?

    init(
        localCenter: NotificationCenter = .default,
        distributedCenter: DistributedNotificationCenter = DistributedNotificationCenter(),
        observedDistributedName: Notification.Name = BackgroundRefreshTrigger.distributedNotificationName,
        debounceNanoseconds: UInt64 = BackgroundRefreshTrigger.debounceNanoseconds
    ) {
        self.localCenter = localCenter
        self.distributedCenter = distributedCenter
        self.observedDistributedName = observedDistributedName
        self.debounceNanoseconds = debounceNanoseconds
    }

    /// Posts the trigger from a Swift caller. `deliverImmediately` is required because the
    /// distributed center only coalesces within a run loop, and a one-shot benchmark script has
    /// none.
    static func requestRefresh(
        distributedCenter: DistributedNotificationCenter = DistributedNotificationCenter()
    ) {
        distributedCenter.postNotificationName(
            distributedNotificationName,
            object: nil,
            deliverImmediately: true
        )
    }

    deinit {
        // `stop()` is async on `queue`; deinit cannot await, so tear down synchronously here.
        removeObserver()
        debounceWorkItem?.cancel()
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            // Only the distributed channel is observed. The local name this trigger *emits* is
            // deliberately not an input, or each wake would re-post itself forever.
            //
            // `queue: nil` delivers on an arbitrary thread, so the handler only forwards to
            // `queue`; every mutable field is owned by that queue and nothing here touches it
            // inline.
            self.observer = self.distributedCenter.addObserver(
                forName: self.observedDistributedName,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                self.queue.async { [weak self] in
                    guard let self, self.started else { return }
                    self.scheduleDebouncedWake()
                }
            }
            AppLog.debug(
                .refresh,
                "background refresh trigger armed (post \(self.observedDistributedName.rawValue))"
            )
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.started = false
            self.removeObserver()
            self.debounceWorkItem?.cancel()
            self.debounceWorkItem = nil
        }
    }

    private func removeObserver() {
        if let observer {
            distributedCenter.removeObserver(observer)
            self.observer = nil
        }
    }

    private func scheduleDebouncedWake() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Re-check on the queue: `stop()` clears `started` on this same queue, but the work item
            // may already have been handed to the executor when it ran, so a cancel race must not
            // deliver a wake for a stopped trigger.
            guard self.started else { return }
            AppLog.info(.refresh, "background refresh requested (external)")
            self.localCenter.post(name: Self.didChangeNotification, object: nil)
        }
        debounceWorkItem = work
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(debounceNanoseconds)), execute: work)
    }
}

/// Loop-side rate limit for external triggers.
///
/// This is the real gate the refresh loop calls (`AppContainer.startPeriodicRefresh`), not a test
/// double: it holds the timestamp of the last accepted trigger and rejects anything inside
/// `minimumPassInterval`. Time is injected so a test can drive the burst pattern without sleeping.
struct BackgroundRefreshGate {
    var minimumInterval: TimeInterval
    private var lastAcceptedAt: Date?

    init(minimumInterval: TimeInterval = BackgroundRefreshTrigger.minimumPassInterval) {
        self.minimumInterval = minimumInterval
    }

    /// True when this trigger should cause a pass; records the acceptance so the next call compares
    /// against it.
    mutating func shouldAccept(at now: Date) -> Bool {
        if let lastAcceptedAt, now.timeIntervalSince(lastAcceptedAt) < minimumInterval {
            return false
        }
        lastAcceptedAt = now
        return true
    }

    /// Drop the recorded acceptance (used when the accepted trigger's pass never actually ran, e.g.
    /// the loop shut down first, so the next trigger is not penalised for a pass that never happened).
    mutating func reset() {
        lastAcceptedAt = nil
    }
}
