import Foundation
import os

/// Test instrumentation: how many cancellation-grace tasks are alive right now.
///
/// A grace task used to keep sleeping for the full grace period after the provider answered,
/// holding the continuation, the claim and — through the work task — the provider's in-flight
/// snapshot. Every provider refresh left one behind.
let liveRefreshGraceTaskCount = OSAllocatedUnfairLock(initialState: 0)

/// Runs one provider's `refresh()` under a hard deadline (#1081).
///
/// A provider that never returns — a subprocess that doesn't exit, a credential read that blocks — used
/// to hold the store's in-flight entry forever, so the dashboard spinner turned for the rest of the
/// session. The refresh therefore runs in its own task: when the deadline wins we cancel that task and
/// stop waiting for it. Structured concurrency can't do this — a `TaskGroup` still waits for a child
/// that ignores cancellation, which is exactly the case being bounded.
///
/// Cancelling the refresh is best-effort (it only lands where the provider's own work is
/// cancellation-aware). What the deadline guarantees is that the *store* stops waiting.
@MainActor
enum ProviderRefreshDeadline {
    /// How long a cancelled refresh may keep winding down after the deadline before the store stops
    /// caring. The scanners observe cancellation at bounded loop boundaries (~100 ms), so this is
    /// generous; a refresh that ignores even the grace is abandoned in place.
    static let cancellationGraceSeconds: UInt64 = 5

    /// The refreshed snapshot, or `nil` if `timeout` elapsed first.
    static func snapshot(
        from provider: ProviderRuntime,
        timeout: TimeInterval
    ) async -> ProviderSnapshot? {
        let work = Task { @MainActor in
            // `force` is handled by the store's cache and in-flight policy. Preserve the caller's
            // TaskLocal scope: a forced `.panelMeters` retry must stay meters-only so a slow local
            // history scan cannot hold the visible quota retry open or be repeated in phase two.
            // User-interaction permission is a separate TaskLocal, so panel opens stay silent.
            await provider.refresh()
        }
        let claim = ContinuationClaim()
        let grace = GraceTaskHandle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ProviderSnapshot?, Never>) in
                // Detached, so a busy MainActor can't delay the one thing that bounds the wait.
                let deadline = Task.detached {
                    try? await Task.sleep(for: .seconds(timeout))
                    guard !Task.isCancelled, claim.beginTimeout() else { return }
                    work.cancel()
                    // Return as soon as cooperative work stops. Only a provider that ignores
                    // cancellation keeps the store waiting through the bounded grace period.
                    Task.detached {
                        _ = await work.value
                        guard claim.finishTimeout() else { return }
                        // The provider answered: the grace sleep has no reason to outlive it. Without
                        // this the grace task kept sleeping for the whole grace period, holding the
                        // continuation and the provider's in-flight snapshot.
                        grace.cancel()
                        continuation.resume(returning: nil)
                    }
                    liveRefreshGraceTaskCount.withLock { $0 += 1 }
                    let graceTask = Task.detached {
                        defer { liveRefreshGraceTaskCount.withLock { $0 -= 1 } }
                        try? await Task.sleep(for: .seconds(Self.cancellationGraceSeconds))
                        guard claim.finishTimeout() else { return }
                        continuation.resume(returning: nil)
                    }
                    grace.store(graceTask)
                }
                Task { @MainActor in
                    let snapshot = await work.value
                    // Cancel the deadline the moment the snapshot lands, so a fast refresh doesn't leave
                    // a timer sleeping per provider until it expires.
                    deadline.cancel()
                    guard claim.claimSnapshot() else { return }
                    continuation.resume(returning: snapshot)
                }
            }
        } onCancel: {
            // An unstructured task doesn't inherit cancellation, so forward the caller's explicitly —
            // otherwise a cancelled refresh pass would leave its provider work running.
            work.cancel()
        }
    }
}

/// Holds the cancellation-grace task so the winner of the claim can cancel it.
///
/// The handle remembers a cancel that arrives before the task exists, so the grace sleep never
/// outlives the refresh no matter which of the two racers gets there first.
private final class GraceTaskHandle: @unchecked Sendable {
    private struct State {
        var task: Task<Void, Never>?
        var cancelled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func store(_ task: Task<Void, Never>) {
        let cancelNow = state.withLock { state -> Bool in
            state.task = task
            return state.cancelled
        }
        if cancelNow { task.cancel() }
    }

    func cancel() {
        let task = state.withLock { state -> Task<Void, Never>? in
            state.cancelled = true
            return state.task
        }
        task?.cancel()
    }
}

/// The one-shot right to resume a `CheckedContinuation` two tasks are racing for: the first `claim()`
/// returns true and every later one returns false. The racers run on different executors, so the
/// check-and-set has to be atomic — with a plain `Bool` both can read it as unclaimed and resume, and a
/// second resume is a fatal error, not a caught one.
private struct ContinuationClaim: Sendable {
    private enum State: Sendable, Equatable {
        case pending
        case timedOut
        case finished
    }

    private let state = OSAllocatedUnfairLock(initialState: State.pending)

    func claimSnapshot() -> Bool {
        state.withLock { state in
            guard state == .pending else { return false }
            state = .finished
            return true
        }
    }

    func beginTimeout() -> Bool {
        state.withLock { state in
            guard state == .pending else { return false }
            state = .timedOut
            return true
        }
    }

    func finishTimeout() -> Bool {
        state.withLock { state in
            guard state == .timedOut else { return false }
            state = .finished
            return true
        }
    }
}
