import Foundation
import XCTest
@testable import QuotaBar

@MainActor
final class PanelOpenDebounceTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    private func makeUserDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.PanelOpenDebounce.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testSecondPanelOpenInsideDebounceWindowSkipsTheForcedPass() async {
        let provider = Provider(id: "probe", displayName: "Probe", icon: .providerMark("cursor"))
        let meter = WidgetDescriptor(
            id: "probe.auto",
            providerID: provider.id,
            metricLabel: "Probe",
            sample: WidgetData(title: "Probe", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        let runtime = SequenceProviderRuntime(
            provider: provider,
            descriptors: [meter],
            snapshots: [
                ProviderSnapshot(
                    providerID: provider.id,
                    displayName: provider.displayName,
                    lines: [.progress(label: "Probe", used: 10, limit: 100, format: .percent)]
                )
            ]
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [meter]),
            providers: [runtime],
            defaults: makeUserDefaults("skip-inside-window"),
            now: { self.clock }
        )

        await ProviderRefreshContext.$scope.withValue(.full) {
            await store.refreshAllForPanelOpen()
        }
        XCTAssertEqual(runtime.refreshCount, 1)

        // Rapid second tap: inside the debounce window, no provider is re-probed.
        clock = clock.addingTimeInterval(3)
        await ProviderRefreshContext.$scope.withValue(.full) {
            await store.refreshAllForPanelOpen()
        }
        XCTAssertEqual(runtime.refreshCount, 1, "a reopen inside the debounce window must not re-run the forced pass")

        // Later open: outside the window, the pass runs again.
        clock = clock.addingTimeInterval(WidgetDataStore.panelOpenRefreshDebounce + 1)
        await ProviderRefreshContext.$scope.withValue(.full) {
            await store.refreshAllForPanelOpen()
        }
        XCTAssertEqual(runtime.refreshCount, 2)
    }

    func testManualForcedRefreshBypassesThePanelOpenDebounce() async {
        let provider = Provider(id: "probe", displayName: "Probe", icon: .providerMark("cursor"))
        let meter = WidgetDescriptor(
            id: "probe.auto",
            providerID: provider.id,
            metricLabel: "Probe",
            sample: WidgetData(title: "Probe", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        let runtime = SequenceProviderRuntime(
            provider: provider,
            descriptors: [meter],
            snapshots: [
                ProviderSnapshot(
                    providerID: provider.id,
                    displayName: provider.displayName,
                    lines: [.progress(label: "Probe", used: 10, limit: 100, format: .percent)]
                )
            ]
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [meter]),
            providers: [runtime],
            defaults: makeUserDefaults("manual-bypass"),
            now: { self.clock }
        )

        await ProviderRefreshContext.$scope.withValue(.full) {
            await store.refreshAllForPanelOpen()
        }
        // The user's explicit Refresh Now must never be swallowed by the debounce.
        await store.refreshAll(force: true)
        XCTAssertEqual(runtime.refreshCount, 2)
    }
}