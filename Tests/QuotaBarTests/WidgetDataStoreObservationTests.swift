import os
import XCTest
@testable import QuotaBar

/// `@Observable` publishes every write, even when the value did not change. The provider error map
/// is read for every provider group, so a no-op assignment re-rendered the whole dashboard on every
/// successful refresh.
@MainActor
final class WidgetDataStoreObservationTests: XCTestCase {
    /// A flag the observation callback can set from any executor.
    private final class ObservationFlag: @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(initialState: false)
        var value: Bool { state.withLock { $0 } }
        func set() { state.withLock { $0 = true } }
    }

    private func makeUserDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeStore(
        provider: Provider,
        descriptor: WidgetDescriptor,
        defaults: UserDefaults,
        now: Date
    ) -> WidgetDataStore {
        let cache = ProviderSnapshotCache(
            userDefaults: defaults,
            storageKey: "snapshots",
            ttl: 600,
            now: { now }
        )
        let registry = WidgetRegistry(providers: [provider], descriptors: [descriptor])
        let snapshot = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Session", used: 42, limit: 100, format: .percent)],
            refreshedAt: now
        )
        let runtime = SequenceProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshots: [snapshot]
        )
        return WidgetDataStore(
            registry: registry,
            providers: [runtime],
            cache: cache,
            defaults: defaults,
            now: { now }
        )
    }

    func testASuccessfulRefreshDoesNotRepublishTheProviderErrorMap() async {
        let provider = Provider(id: "alpha", displayName: "Alpha", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor.percent(id: "alpha.session", provider: provider, title: "Session")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = makeStore(
            provider: provider,
            descriptor: descriptor,
            defaults: makeUserDefaults("provider-error-observation"),
            now: now
        )

        let republished = ObservationFlag()
        withObservationTracking {
            _ = store.providerErrors
        } onChange: {
            republished.set()
        }

        _ = await store.refresh(providerID: provider.id, force: true, bypassSnapshotCache: true)

        XCTAssertFalse(
            republished.value,
            "a provider without an error must not republish the error map"
        )
    }
}
