import Foundation
import XCTest
@testable import QuotaBar

/// The snapshot blob is shared by two processes (the app and `quotabar-cli`), so every write path
/// has to re-read it — but re-*decoding* it on every provider store made each refresh pass pay a
/// full JSON parse of every provider's snapshot, several times, on the MainActor.
///
/// The mirror exists for exactly that. These tests count the whole-blob reads, decodes and writes a
/// cache performs so a regression (a write path that bypasses the mirror) fails loudly.
final class ProviderSnapshotCachePersistenceTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "providerSnapshotCache.persistence.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func snapshot(_ id: String, used: Double, now: Date) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: id,
            displayName: id.capitalized,
            lines: [.progress(label: "Session", used: used, limit: 100, format: .percent)],
            refreshedAt: now
        )
    }

    /// Every provider store used to re-decode the whole all-providers blob. With the mirror the
    /// blob is parsed once — and only again when another process changed it.
    func testStoringSeveralProvidersDoesNotReparseTheBlob() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let metrics = ProviderSnapshotCacheMetrics()
        let cache = ProviderSnapshotCache(
            userDefaults: defaults,
            storageKey: "k",
            ttl: 9_999,
            now: { now },
            metrics: metrics
        )

        cache.store(snapshot("alpha", used: 10, now: now))
        cache.store(snapshot("beta", used: 20, now: now))
        cache.store(snapshot("gamma", used: 30, now: now))

        XCTAssertEqual(
            metrics.decodes, 0,
            "the blob must be parsed once, not once per provider store"
        )
        XCTAssertEqual(metrics.writes, 3, "one blob write per provider store")
        XCTAssertEqual(cache.loadSnapshots(providerIDs: ["alpha", "beta", "gamma"]).count, 3)
    }

    /// The mirror is only trusted while the blob's bytes are unchanged: the other process writes the
    /// same key, so the next read has to decode the new blob instead of trusting the stale mirror.
    func testExternalWriteInvalidatesTheMirrorExactlyOnce() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let metrics = ProviderSnapshotCacheMetrics()
        let cache = ProviderSnapshotCache(
            userDefaults: defaults,
            storageKey: "k",
            ttl: 9_999,
            now: { now },
            metrics: metrics
        )
        cache.store(snapshot("alpha", used: 10, now: now))

        // Another process (the CLI) writes the same blob.
        let other = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
        other.store(snapshot("beta", used: 20, now: now))

        cache.store(snapshot("gamma", used: 30, now: now))

        XCTAssertEqual(
            metrics.decodes, 1,
            "the changed blob must be decoded once — and only once"
        )
        XCTAssertEqual(
            cache.loadSnapshots(providerIDs: ["alpha", "beta", "gamma"]).count, 3,
            "the other process's entry must survive our write"
        )
    }

    /// Allocating a refresh order must not rewrite the snapshot blob: it only bumps a counter, and
    /// the blob is the largest thing this cache writes.
    func testAllocatingARefreshOrderDoesNotRewriteTheBlob() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let metrics = ProviderSnapshotCacheMetrics()
        let cache = ProviderSnapshotCache(
            userDefaults: defaults,
            storageKey: "k",
            ttl: 9_999,
            now: { now },
            metrics: metrics
        )
        cache.store(snapshot("alpha", used: 10, now: now))

        let writesBefore = metrics.writes
        let order = cache.beginRefreshOrder(providerID: "alpha")
        XCTAssertNotNil(order)
        XCTAssertEqual(
            metrics.writes, writesBefore,
            "allocating an order must not rewrite the snapshot blob"
        )
    }

    /// The cross-process lock file was re-created (mkdir + chmod + open) on every cache operation.
    /// It is opened once per process and reused, so the number of opens must not grow with the
    /// number of operations.
    func testTheLockFileIsOpenedOnceAndReused() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })

        let opensBefore = PersistentStoreLock.openCount.withLock { $0 }
        for index in 0..<5 {
            cache.store(snapshot("alpha", used: Double(index), now: now))
            cache.beginRefreshOrder(providerID: "alpha")
            cache.isCurrentRefresh(
                providerID: "alpha",
                order: 1,
                scope: .full,
                hasHistoryDomain: false
            )
        }
        let opensAfter = PersistentStoreLock.openCount.withLock { $0 }
        XCTAssertLessThanOrEqual(
            opensAfter - opensBefore, 1,
            "the lock file must be opened once and reused"
        )
    }

    /// A write whose refresh order could not be allocated used to be dropped: the provider's fresh
    /// meters, plan and history never reached the cache while the store kept showing them. The write
    /// must be persisted instead.
    func testASnapshotIsPersistedEvenWithoutARefreshOrder() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })

        let result = cache.store(
            snapshot("alpha", used: 42, now: now),
            refreshOrder: nil,
            scope: .full,
            now: now
        )
        guard case .stored(let stored) = result, let stored else {
            return XCTFail("the snapshot must be persisted even without a refresh order")
        }
        XCTAssertEqual(
            stored.lines.first,
            .progress(label: "Session", used: 42, limit: 100, format: .percent)
        )

        // A later reader — another process, or the next launch — must see it.
        let reader = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
        XCTAssertNotNil(reader.loadSnapshots(providerIDs: ["alpha"])["alpha"])
    }

    /// The refresh order fences a late result against a newer one, so it has to keep growing across
    /// the processes that share the blob — even though the counter no longer lives in the blob.
    func testRefreshOrdersStayMonotonicAcrossCaches() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let app = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
        let cli = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })

        let appOrder = try XCTUnwrap(app.beginRefreshOrder(providerID: "alpha"))
        let cliOrder = try XCTUnwrap(cli.beginRefreshOrder(providerID: "alpha"))
        XCTAssertGreaterThan(cliOrder, appOrder, "the second process must not reuse the first's order")

        let nextOrder = try XCTUnwrap(app.beginRefreshOrder(providerID: "alpha"))
        XCTAssertGreaterThan(nextOrder, cliOrder)
    }
}
