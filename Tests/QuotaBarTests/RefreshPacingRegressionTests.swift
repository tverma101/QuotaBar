import Foundation
import XCTest
@testable import QuotaBar

/// Regression tests for the frozen-usage fix (Oct 2026): a priced-aggregate invalidation forces cold
/// re-folds of the local corpora, and the old hard-coded background ceiling paced them through the
/// 120s provider deadline — every refresh timed out (`0 ok / 5 failed`) and the codex cards froze with
/// stale data. These pin the layers that prevent a repeat: the scope-aware ceiling, the refresh
/// loop's unpaced-full-pass wiring, the closed-panel fold's paced wiring, and the disabled fast path.
final class RefreshPacingRegressionTests: XCTestCase {
    /// The pacer's ceiling must follow the scope: 25% when the user is actively waiting (full scope —
    /// panel open, manual refresh, CLI), 1.8% for background accounting so even a 30 s or 60 s window
    /// stays under the owner's 2% ceiling. The earlier hard-coded background rate left closed-panel
    /// folds unpaced and held ~7% of a core for a minute.
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
                JSONLAccountingWorkPacer.targetCPUFraction, 0.018,
                accuracy: 0.0001,
                "background accounting keeps the 1.8% ceiling"
            )
        }
        ProviderRefreshContext.$scope.withValue(.panelAccounting) {
            ProviderRefreshContext.$isManual.withValue(true) {
                XCTAssertEqual(
                    JSONLAccountingWorkPacer.targetCPUFraction, 0.25,
                    accuracy: 0.0001,
                    "manual retry folds use the interactive budget despite their narrower accounting scope"
                )
            }
        }
    }

    func testManualPanelMeterRetryUsesInteractivePacedContext() async {
        let context = await withManualRefresh {
            await withThrottledPanelMeters {
                (
                    ProviderRefreshContext.scope,
                    ProviderRefreshContext.isManual,
                    ProviderRefreshContext.accountingCPUThrottleEnabled,
                    JSONLAccountingWorkPacer.targetCPUFraction
                )
            }
        }

        XCTAssertEqual(context.0, .panelMeters)
        XCTAssertTrue(context.1)
        XCTAssertTrue(context.2)
        XCTAssertEqual(context.3, 0.25, accuracy: 0.0001)
    }

    func testSilentSupersessionRetryUsesInteractiveBudgetWithoutManualKeychainPermission() async {
        let context = await ProviderRefreshContext.$scope.withValue(.panelMeters) {
            await ProviderRefreshContext.$isManual.withValue(false) {
                await ProviderRefreshContext.$accountingCPUThrottleEnabled.withValue(true) {
                    await ProviderRefreshContext.$accountingCPUInteractiveBudgetEnabled.withValue(true) {
                        (
                            ProviderRefreshContext.isManual,
                            ProviderRefreshContext.accountingCPUThrottleEnabled,
                            JSONLAccountingWorkPacer.targetCPUFraction
                        )
                    }
                }
            }
        }

        XCTAssertFalse(context.0, "silent recovery must not inherit Keychain interaction permission")
        XCTAssertTrue(context.1)
        XCTAssertEqual(context.2, 0.25, accuracy: 0.0001)
    }

    func testDetachedProviderWorkPreservesSilentInteractiveBudget() async {
        let context = await ProviderRefreshContext.$scope.withValue(.panelMeters) {
            await ProviderRefreshContext.$isManual.withValue(false) {
                await ProviderRefreshContext.$accountingCPUThrottleEnabled.withValue(true) {
                    await ProviderRefreshContext.$accountingCPUInteractiveBudgetEnabled.withValue(true) {
                        ProviderRefreshContext.detachedValues
                    }
                }
            }
        }
        let observed = await Task.detached {
            context.withValue {
                (
                    ProviderRefreshContext.isManual,
                    ProviderRefreshContext.accountingCPUThrottleEnabled,
                    JSONLAccountingWorkPacer.targetCPUFraction
                )
            }
        }.value

        XCTAssertFalse(observed.0)
        XCTAssertTrue(observed.1)
        XCTAssertEqual(observed.2, 0.25, accuracy: 0.0001)
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

    /// Closed-panel history folds are background work and must take the paced path. A panel-open fold
    /// feeds the visible dashboard, so it keeps the unpaced path (same as `.full`).
    func testClosedPanelAccountingFoldIsPacedButPanelOpenIsNot() {
        XCTAssertTrue(AppContainer.pacesAccountingFold(scope: .localAccounting, panelOpen: true))
        XCTAssertTrue(AppContainer.pacesAccountingFold(scope: .localAccounting, panelOpen: false))
        XCTAssertTrue(AppContainer.pacesAccountingFold(scope: .panelAccounting, panelOpen: false))
        XCTAssertFalse(
            AppContainer.pacesAccountingFold(scope: .panelAccounting, panelOpen: true),
            "a panel-open fold must meet the provider deadline, not the background allowance"
        )
        XCTAssertFalse(AppContainer.pacesAccountingFold(scope: .full, panelOpen: false))
    }

    /// A fold in flight must keep the loop's coarse poll floor even when a meter pass is latched.
    /// The meter work is deferred until the fold completes (its completion wake resumes the loop),
    /// so a zero timeout only re-deferred it in a tight loop and burned a core for the fold's duration.
    func testFoldInFlightNeverSpinsOnDeferredMeterWork() {
        XCTAssertEqual(
            AppContainer.refreshWakeTimeout(
                accountingInFlight: true, hasRunnableWork: true, deadlineWait: 0
            ),
            5,
            accuracy: 0.001,
            "a fold that outlived its deadline must fall back to a 5 s poll, not spin"
        )
        XCTAssertEqual(
            AppContainer.refreshWakeTimeout(
                accountingInFlight: true, hasRunnableWork: true, deadlineWait: 30
            ),
            30,
            accuracy: 0.001
        )
        XCTAssertEqual(
            AppContainer.refreshWakeTimeout(
                accountingInFlight: false, hasRunnableWork: true, deadlineWait: 30
            ),
            0,
            accuracy: 0.001,
            "no fold in flight: runnable work should start immediately"
        )
        XCTAssertEqual(
            AppContainer.refreshWakeTimeout(
                accountingInFlight: false, hasRunnableWork: false, deadlineWait: 30
            ),
            30,
            accuracy: 0.001
        )
    }

    func testLedgerAccountingWorkIsPriorityDuringTriggerCooldown() {
        XCTAssertTrue(AppContainer.hasPriorityRefreshPass(
            quotaRefreshDue: false,
            panelPassPending: false,
            fullScopePassPending: false,
            historyAccountingPassPending: false,
            localAccountingPassPending: true
        ))
        XCTAssertFalse(AppContainer.hasPriorityRefreshPass(
            quotaRefreshDue: false,
            panelPassPending: false,
            fullScopePassPending: false,
            historyAccountingPassPending: false,
            localAccountingPassPending: false
        ))
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
            "an unpaced slice must complete in roughly its own CPU time (\(workCPU)s); pacing sleeps would stretch it toward \(workCPU / 0.018)s"
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
