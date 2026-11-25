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
    /// A blob written before the native-source switch (or by a build without the marker) still
    /// holds foreign-source Antigravity rows; decoding drops only that provider's data.
    func testPreNativeSourcePayloadDropsAntigravityRows() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
        cache.store(snapshot("antigravity", used: 10, now: now))
        cache.store(snapshot("codex", used: 20, now: now))

        let data = try XCTUnwrap(defaults.data(forKey: "k"))
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "antigravityUsesNativeSources")
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: "k")

        let reloaded = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
        let survivors = reloaded.loadSnapshots(providerIDs: ["antigravity", "codex"])
        XCTAssertNil(survivors["antigravity"], "foreign-source antigravity rows must not load")
        XCTAssertNotNil(survivors["codex"], "other providers are untouched")

        // A native store writes the marker back and does not resurrect the dropped row.
        reloaded.store(snapshot("antigravity", used: 30, now: now))
        let again = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
        XCTAssertEqual(again.loadSnapshots(providerIDs: ["antigravity"]).count, 1)
    }

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

    /// An Antigravity fold is history-only and machine-local: it can never prove which Google
    /// account owns the cached quota. A fold committed by a process whose launch identity differs
    /// from the stamped account must still merge its history under the ORIGINAL stamp — while its
    /// own returned view shows no quota at all, so the other account's meters never paint.
    func testAntigravityFoldPreservesStampedQuotaFromMismatchedCaller() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let quotaStamp = Date(timeIntervalSince1970: 1_800_000_000)
        let foldStamp = Date(timeIntervalSince1970: 1_900_000_000)
        let now = Date(timeIntervalSince1970: 1_950_000_000)
        let writer = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
        // A second cache instance stands in for the other process sharing the blob.
        let reader = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })

        var quotaSnapshot = snapshot("antigravity", used: 30, now: quotaStamp)
        quotaSnapshot.plan = "Pro"
        quotaSnapshot.quotaRefreshedAt = quotaStamp
        writer.store(quotaSnapshot, producedByIdentityKey: "google-acct-A")

        let historyDescriptor = UsageHistoryDescriptor(
            scope: .machineLocal, estimatedCost: true, sourceNote: "test"
        )
        let fold = ProviderSnapshot(
            providerID: "antigravity",
            displayName: "Antigravity",
            lines: [],
            refreshedAt: foldStamp,
            usageHistory: ProviderUsageHistory(series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-10-14", totalTokens: 500, costUSD: 5)
            ]))
        )
        let order = try XCTUnwrap(reader.beginRefreshOrder(providerID: "antigravity"))
        let result = reader.store(
            fold,
            producedByIdentityKey: "google-acct-B",
            refreshOrder: order,
            scope: .localAccounting,
            historyDescriptor: historyDescriptor,
            now: foldStamp
        )

        guard case .stored(let stored) = result, let stored else {
            return XCTFail("the history fold must still commit its history")
        }
        // The mismatched caller is handed local history only — never the other account's meters.
        XCTAssertNil(stored.plan)
        XCTAssertNil(stored.line(label: "Session"))
        XCTAssertEqual(stored.quotaRefreshedAt, .distantPast)
        XCTAssertEqual(stored.usageHistory?.series.daily.first?.totalTokens, 500)

        // The persisted blob keeps the original account's quota, stamp and freshness.
        let persisted = reader.loadSnapshots(providerIDs: ["antigravity"])["antigravity"]
        XCTAssertEqual(persisted?.plan, "Pro")
        XCTAssertEqual(
            persisted?.line(label: "Session"),
            .progress(label: "Session", used: 30, limit: 100, format: .percent)
        )
        XCTAssertEqual(persisted?.quotaRefreshedAt, quotaStamp)
        XCTAssertEqual(reader.producedByIdentityKey(providerID: "antigravity"), "google-acct-A")
        XCTAssertEqual(persisted?.usageHistory?.series.daily.first?.totalTokens, 500)

        // A fold that produced no history is `.unchanged`; the mismatched caller still sees no quota.
        let emptyOrder = try XCTUnwrap(reader.beginRefreshOrder(providerID: "antigravity"))
        let noHistory = reader.store(
            ProviderSnapshot(
                providerID: "antigravity",
                displayName: "Antigravity",
                lines: [],
                refreshedAt: foldStamp
            ),
            producedByIdentityKey: "google-acct-B",
            refreshOrder: emptyOrder,
            scope: .localAccounting,
            historyDescriptor: historyDescriptor,
            now: foldStamp
        )
        guard case .unchanged(let unchanged) = noHistory, let unchanged else {
            return XCTFail("a fold without history must leave the persisted entry unchanged")
        }
        XCTAssertNil(unchanged.plan)
        XCTAssertNil(unchanged.line(label: "Session"))
        XCTAssertEqual(reader.producedByIdentityKey(providerID: "antigravity"), "google-acct-A")
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
