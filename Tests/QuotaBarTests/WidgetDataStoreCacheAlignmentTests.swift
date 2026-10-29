import XCTest
@testable import QuotaBar

/// The store merges a provider's new result over its own in-memory copy, while the cache merges it
/// over the persisted blob. The two copies only agree while every write reaches the blob: a write
/// that could not be persisted used to leave the store holding a value the blob never saw, and the
/// next write folded the new result over the stale persisted copy — rolling the card back to older
/// data, silently.
@MainActor
final class WidgetDataStoreCacheAlignmentTests: XCTestCase {
    private func makeUserDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// A NaN meter cannot be encoded, so the cache write fails while the refresh itself succeeds.
    private func makeStore(
        provider: Provider,
        descriptor: WidgetDescriptor,
        snapshots: [ProviderSnapshot],
        defaults: UserDefaults,
        now: Date
    ) -> (WidgetDataStore, ProviderSnapshotCache) {
        let cache = ProviderSnapshotCache(
            userDefaults: defaults,
            storageKey: "snapshots",
            ttl: 600,
            now: { now }
        )
        let registry = WidgetRegistry(providers: [provider], descriptors: [descriptor])
        let runtime = SequenceProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshots: snapshots
        )
        let store = WidgetDataStore(
            registry: registry,
            providers: [runtime],
            cache: cache,
            defaults: defaults,
            now: { now }
        )
        return (store, cache)
    }

    func testAFailedCacheWriteKeepsTheStoreAlignedWithTheBlob() async {
        let provider = Provider(id: "alpha", displayName: "Alpha", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor.percent(id: "alpha.session", provider: provider, title: "Session")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let unencodable = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Session", used: .nan, limit: 100, format: .percent)],
            refreshedAt: now
        )
        let good = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Session", used: 42, limit: 100, format: .percent)],
            refreshedAt: now
        )
        let defaults = makeUserDefaults("cache-write-alignment")
        let (store, cache) = makeStore(
            provider: provider,
            descriptor: descriptor,
            snapshots: [unencodable, good],
            defaults: defaults,
            now: now
        )

        _ = await store.refresh(providerID: provider.id, force: true, bypassSnapshotCache: true)

        // The failed write must not leave the store holding data the blob never saw.
        XCTAssertNil(store.localSnapshots[provider.id])
        XCTAssertNil(cache.loadSnapshots(providerIDs: [provider.id])[provider.id])

        // The next successful write persists the value, and the store follows the blob.
        _ = await store.refresh(providerID: provider.id, force: true, bypassSnapshotCache: true)
        let persisted = cache.loadSnapshots(providerIDs: [provider.id])[provider.id]
        XCTAssertEqual(
            persisted?.line(label: "Session"),
            .progress(label: "Session", used: 42, limit: 100, format: .percent)
        )
        XCTAssertEqual(
            store.localSnapshots[provider.id]?.line(label: "Session"),
            persisted?.line(label: "Session"),
            "the store and the blob must hold the same value"
        )
    }
}
