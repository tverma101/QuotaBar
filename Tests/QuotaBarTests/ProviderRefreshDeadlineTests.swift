import Foundation
import XCTest
@testable import QuotaBar

/// The per-provider refresh deadline leaves a cancellation-grace task behind: the provider is
/// cancelled when the deadline wins, and once it answers, the grace sleep that was waiting to give up
/// had no reason to keep running — but it did, for the whole grace period, holding the continuation
/// and the provider's in-flight snapshot.
@MainActor
final class ProviderRefreshDeadlineTests: XCTestCase {
    private func makeProvider() -> (Provider, WidgetDescriptor) {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor(
            id: "test.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        return (provider, descriptor)
    }

    func testTheCancellationGraceTaskDoesNotOutliveTheRefresh() async {
        let (provider, descriptor) = makeProvider()
        let runtime = HangingProviderRuntime(provider: provider, descriptors: [descriptor])
        let liveBefore = liveRefreshGraceTaskCount.withLock { $0 }

        // The deadline wins, the provider is cancelled and answers.
        let snapshot = await ProviderRefreshDeadline.snapshot(from: runtime, timeout: 0.05)
        XCTAssertNil(snapshot)

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while liveRefreshGraceTaskCount.withLock({ $0 }) > liveBefore, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            liveRefreshGraceTaskCount.withLock { $0 },
            liveBefore,
            "the grace task must not keep sleeping after the provider answered"
        )
    }
}
