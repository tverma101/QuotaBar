import Foundation
import os

/// The refresh loop's between-passes wait: waits for the remaining time to its quota deadline, but
/// wakes early when a relevant provider, panel, ledger, or external-trigger change lands — including
/// changes posted *during* a pass.
///
/// The bug this replaces: the loop used to subscribe to
/// `ProviderEnablementStore.didChangeNotification` only inside its wait, after `refreshAll()` had
/// finished. First-run credential detection is local-only and fast while the first refresh pass does
/// network I/O and is slow, so the "providers enabled" notification almost always fired mid-pass with
/// nobody listening — `NotificationCenter.notifications(named:)` doesn't buffer events from before
/// iteration starts. The wake was silently dropped and the newly detected providers sat dataless until
/// the next scheduled pass or a manual refresh. The same lost wake hit `NewProviderSeeder` and the
/// Customize "Reset All" reseed.
///
/// Here the subscription is installed once, synchronously, in `init` — before the loop's first pass.
/// The stream uses `.bufferingNewest(1)` only as a wake token; a locked set separately retains every
/// distinct notification kind while the loop is busy. Repeats coalesce, but a provider toggle cannot
/// overwrite a ledger append or panel transition.
///
/// Additional names (e.g. CodexRouter ledger appends while the panel is open) share the same signal so
/// spend tiles refresh within about a second of a routed turn without shortening the idle cadence.
/// `waitForWake` reports whether the resume came from a named notification or the sleep timer so the
/// loop can invalidate Codex spend caches on ledger wakes (snapshot TTL would otherwise no-op them).
@MainActor
final class RefreshWakeSignal {
    enum WakeReason: Equatable, Sendable {
        case timeout
        case notification(Notification.Name)
    }

    private let stream: AsyncStream<WakeReason>
    private let continuation: AsyncStream<WakeReason>.Continuation
    private let center: NotificationCenter
    /// Keep one pending copy of each cause while the refresh loop is busy. The stream is only a wake
    /// token; buffering every ledger event would queue redundant scans, while buffering only the newest
    /// event could erase a distinct provider toggle or panel transition.
    private let pendingNotificationNames = OSAllocatedUnfairLock(initialState: Set<String>())
    /// A skipped refresh carries work that must be re-queued after its conflicting provider task ends.
    /// Like notification causes, these requests survive while the scheduler is busy and coalesce by
    /// provider, scope, cache-bypass requirement, request generation, and manual action identity.
    private let pendingDeferredRefreshes = OSAllocatedUnfairLock(
        initialState: Set<WidgetDataStore.DeferredRefreshRequest>()
    )
    /// `nonisolated(unsafe)` so the nonisolated `deinit` can unregister observers; immutable after
    /// `init`, and `NotificationCenter` is documented thread-safe.
    private nonisolated(unsafe) let observers: [NSObjectProtocol]

    init(
        names: [Notification.Name] = [ProviderEnablementStore.didChangeNotification],
        center: NotificationCenter = .default
    ) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: WakeReason.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.stream = stream
        self.continuation = continuation
        self.center = center
        let pendingNames = self.pendingNotificationNames
        // Registered synchronously, so no notification posted after `init` returns can be missed.
        self.observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in
                _ = pendingNames.withLock { $0.insert(name.rawValue) }
                continuation.yield(.notification(name))
            }
        }
    }

    /// Compatibility: single-name initializer used by tests.
    convenience init(
        name: Notification.Name,
        center: NotificationCenter = .default
    ) {
        self.init(names: [name], center: center)
    }

    deinit {
        for observer in observers {
            center.removeObserver(observer)
        }
        continuation.finish()
    }

    /// Returns when a wake has been posted — including one buffered while the caller was doing other
    /// work — or when `timeout` elapses, whichever comes first (the timer feeds the same stream). Also
    /// returns promptly when the surrounding task is cancelled. Distinct notification names are
    /// drained separately by `takePendingNotifications()` after this returns.
    @discardableResult
    func waitForWake(timeout: TimeInterval) async -> WakeReason {
        let timer = Task { [continuation] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            continuation.yield(.timeout)
        }
        defer { timer.cancel() }
        var iterator = stream.makeAsyncIterator()
        return await iterator.next() ?? .timeout
    }

    /// Drains the distinct notification causes retained while a pass was running. Repeated events of
    /// the same kind coalesce, but different kinds survive the stream's one-token buffer.
    func takePendingNotifications() -> [Notification.Name] {
        let names = pendingNotificationNames.withLock { pending -> [String] in
            let names = pending
            pending.removeAll(keepingCapacity: true)
            return names.sorted()
        }
        return names.map { Notification.Name($0) }
    }

    /// Drains provider requests whose conflicting work has completed. The caller resumes a targeted
    /// manual fold directly or maps scheduled scopes back to their latches.
    func takePendingDeferredRefreshes() -> Set<WidgetDataStore.DeferredRefreshRequest> {
        pendingDeferredRefreshes.withLock { pending -> Set<WidgetDataStore.DeferredRefreshRequest> in
            let requests = pending
            pending.removeAll(keepingCapacity: true)
            return requests
        }
    }

    /// Retains a ready request before yielding the shared wake token, so it cannot be lost while the
    /// scheduler is awaiting another provider or accounting task.
    func signalDeferredRefreshReady(_ request: WidgetDataStore.DeferredRefreshRequest) {
        _ = pendingDeferredRefreshes.withLock { $0.insert(request) }
        continuation.yield(.timeout)
    }

    /// Drops delayed work that became invalid when its provider was disabled. A wake token may already
    /// be buffered, but the provider-toggle notification will wake the loop and it will find no request.
    func cancelDeferredRefreshes(forProviderIDs providerIDs: Set<String>) {
        guard !providerIDs.isEmpty else { return }
        pendingDeferredRefreshes.withLock { pending in
            pending = pending.filter { !providerIDs.contains($0.providerID) }
        }
    }

    /// Wakes the scheduler when background accounting work finishes. The wake carries no new request;
    /// it only lets the loop consume already-latched work or recompute its next absolute deadline.
    func signalWorkCompletion() {
        continuation.yield(.timeout)
    }
}
