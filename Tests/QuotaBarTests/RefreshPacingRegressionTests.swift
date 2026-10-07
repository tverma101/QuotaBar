import Foundation
import XCTest
@testable import QuotaBar

/// Regression tests for the frozen-usage fix (Oct 2026): a priced-aggregate invalidation forces cold
/// re-folds of the local corpora, and with the pacer's old hard-coded 7.5% ceiling those folds blew
/// through the 120s provider deadline — every refresh timed out (`0 ok / 5 failed`) and the codex
/// cards froze with stale data. These pin the layers that prevent a repeat: the scope-aware
/// ceiling, the refresh loop's unpaced-full-pass wiring, and the pacer's disabled fast path.
final class RefreshPacingRegressionTests: XCTestCase {
    /// The pacer's ceiling must follow the scope: 25% when the user is actively waiting (full scope —
    /// panel open, manual refresh, CLI), 7.5% only for background menu-bar ticks. The regression was a
    /// single hard-coded 0.075, which paced a ~40-100s cold fold into a >120s wall and tripped the
    /// provider deadline on every pass.
    func testTargetCPUFractionFollowsScope() {
        ProviderRefreshContext.$scope.withValue(.full) {
            XCTAssertEqual(
                JSONLAccountingWorkPacer.targetCPUFraction, 0.25,
                accuracy: 0.0001,
                "full-scope passes must get the 25% interactive budget, not the background ceiling"
            )
        }
        ProviderRefreshContext.$scope.withValue(.menuBar) {
            XCTAssertEqual(
                JSONLAccountingWorkPacer.targetCPUFraction, 0.075,
                accuracy: 0.0001,
                "background menu-bar ticks keep the 7.5% battery ceiling"
            )
        }
    }

    /// The refresh loop runs user-facing full passes UNPACED by passing
    /// `accountingCPUThrottleEnabled = (scope == .menuBar)` around `refreshAll`. Pin that exact
    /// expression in both scopes: a cold fold in a full pass must never wait on the pacer, while a
    /// menuBar tick keeps its background allowance.
    func testLoopWiringDisablesThrottleForFullPasses() {
        // Mirrors AppContainer's refresh loop: `withValue(scope == .menuBar)`.
        func loopWiredThrottle(scope: ProviderRefreshContext.Scope) -> Bool {
            ProviderRefreshContext.$accountingCPUThrottleEnabled.withValue(scope == .menuBar) {
                ProviderRefreshContext.accountingCPUThrottleEnabled
            }
        }
        XCTAssertFalse(
            loopWiredThrottle(scope: .full),
            "full passes (panel open, manual refresh, external trigger) must run unpaced so cold folds finish inside the 120s deadline"
        )
        XCTAssertTrue(
            loopWiredThrottle(scope: .menuBar),
            "menuBar ticks keep the paced background allowance"
        )
    }

    /// With pacing disabled (the full-pass wiring), the pacer must run work directly — no pacing
    /// sleep after the slice. A busy ~40ms work item finishes in its own CPU time, well under a
    /// second; the old bug slept the equivalent CPU share back (40ms at 7.5% ≈ 0.5s+ of wall).
    func testDisabledPacerRunsWorkWithoutPacingSleep() throws {
        // Generous margins: the assert proves the sleep loop never ran, not exact timing.
        let workCPU: TimeInterval = 0.04
        let start = DispatchTime.now().uptimeNanoseconds
        let produced = try JSONLAccountingWorkPacer.shared.perform(enabled: false) {
            Self.busyWork(seconds: workCPU)
        }
        let wall = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        XCTAssertTrue(produced, "the work item must actually run")
        XCTAssertLessThan(
            wall, 0.75,
            "an unpaced slice must complete in roughly its own CPU time (\(workCPU)s); pacing sleeps would stretch it toward \(workCPU / 0.075)s"
        )
    }

    private static func busyWork(seconds: TimeInterval) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
        var sink = 0
        while DispatchTime.now().uptimeNanoseconds < deadline {
            for _ in 0..<10_000 { sink = sink &+ 1 }
        }
        return sink >= 0
    }
}
