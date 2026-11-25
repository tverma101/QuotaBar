import Foundation
import XCTest
@testable import QuotaBar

/// Regression: the settled footprint sits above the 96 MB soft limit, so every panel-open meter
/// pass ran its providers one at a time and cards filled in one by one. Meter passes parse no local
/// corpora; only the hard limit serializes them.
@MainActor
final class MeterPassConcurrencyTests: XCTestCase {
    private final class HeldRuntime: ProviderRuntime {
        let provider: Provider
        let widgetDescriptors: [WidgetDescriptor]
        private(set) var entries = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(id: String) {
            provider = Provider(id: id, displayName: id.uppercased(), icon: .providerMark("codex"))
            widgetDescriptors = [WidgetDescriptor.percent(
                id: "\(id).session", provider: provider, title: "Session"
            )]
        }

        func refresh() async -> ProviderSnapshot {
            entries += 1
            await withCheckedContinuation { waiters.append($0) }
            return ProviderSnapshot.make(provider: provider, plan: "ok", lines: [], refreshedAt: Date())
        }

        func release() {
            let pending = waiters
            waiters = []
            pending.forEach { $0.resume() }
        }
    }

    func testMeterPassOverTheSoftLimitStillRunsProvidersTogether() async {
        let runtimes = [HeldRuntime(id: "a"), HeldRuntime(id: "b")]
        let store = makeStore(runtimes: runtimes, overSoft: true, overHard: false)
        let pass = Task {
            await ProviderRefreshContext.$scope.withValue(.panelMeters) {
                await store.refreshAll(force: true)
            }
        }
        await waitUntil({ runtimes.allSatisfy { $0.entries == 1 } }, timeout: .seconds(10), "both meters in flight")
        runtimes.forEach { $0.release() }
        await pass.value
    }

    func testMeterPassOverTheHardLimitSerializes() async {
        let runtimes = [HeldRuntime(id: "a"), HeldRuntime(id: "b")]
        let store = makeStore(runtimes: runtimes, overSoft: true, overHard: true)
        let pass = Task {
            await ProviderRefreshContext.$scope.withValue(.panelMeters) {
                await store.refreshAll(force: true)
            }
        }
        await waitUntil({ runtimes.contains { $0.entries == 1 } }, timeout: .seconds(10), "first meter in flight")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(runtimes.map(\.entries).reduce(0, +), 1, "over the hard limit, meters run one at a time")
        runtimes.forEach { $0.release() }
        await waitUntil({ runtimes.allSatisfy { $0.entries == 1 } }, timeout: .seconds(10), "second meter after the first")
        runtimes.forEach { $0.release() }
        await pass.value
    }

    func testMeterConcurrencyHelperKeysOffTheHardLimit() {
        let megabyte: UInt64 = 1024 * 1024
        XCTAssertNil(ProcessMemoryBudget.meterPassMaxConcurrentProviders(footprintBytes: 139 * megabyte))
        XCTAssertNil(ProcessMemoryBudget.meterPassMaxConcurrentProviders(footprintBytes: nil))
        XCTAssertEqual(
            ProcessMemoryBudget.meterPassMaxConcurrentProviders(footprintBytes: ProcessMemoryBudget.hardLimitBytes),
            1
        )
    }

    private func makeStore(runtimes: [HeldRuntime], overSoft: Bool, overHard: Bool) -> WidgetDataStore {
        let suiteName = "QuotaBarTests.MeterPassConcurrency.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        return WidgetDataStore(
            registry: WidgetRegistry(
                providers: runtimes.map(\.provider),
                descriptors: runtimes.flatMap(\.widgetDescriptors)
            ),
            providers: runtimes,
            cache: ProviderSnapshotCache(userDefaults: suite, storageKey: "snapshots", ttl: 600),
            defaults: suite,
            isOverSoftMemoryLimit: { overSoft },
            isOverHardMemoryLimit: { overHard }
        )
    }
}
