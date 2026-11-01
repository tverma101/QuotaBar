import XCTest
@testable import QuotaBar

/// Guards the in-memory write-through mirror: reads must reflect writes, a second store must not drop
/// the first, and the mirror must stay a cache over real persistence (a fresh instance reads from disk).
final class ProviderSnapshotCacheTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "providerSnapshotCache.test.\(UUID().uuidString)"
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

    func testStoreAccumulatesAcrossProvidersAndReadsReflectWrites() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })

        cache.store(snapshot("alpha", used: 10, now: now))
        cache.store(snapshot("beta", used: 20, now: now))

        // The second store must not drop the first, and reads come back from the mirror unchanged.
        XCTAssertEqual(cache.loadSnapshots(providerIDs: ["alpha", "beta"]).count, 2)
        XCTAssertEqual(cache.snapshot(providerID: "alpha")?.lines.first,
                       .progress(label: "Session", used: 10, limit: 100, format: .percent))
        XCTAssertEqual(cache.snapshot(providerID: "beta")?.lines.first,
                       .progress(label: "Session", used: 20, limit: 100, format: .percent))
    }

    /// #697 core guarantee: a snapshot persisted by a *previous* session and reloaded on launch must not
    /// satisfy the refresh gate, even when its `refreshedAt` is still well within TTL — otherwise the app
    /// would wait out the previous session's remaining interval before refetching. It must still *display*
    /// (instant paint), so `loadSnapshots` returns it.
    func testRelaunchLoadedSnapshotIsStaleEvenWithinTTL() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        // Session 1 writes a snapshot 1s ago — comfortably inside the 9_999s TTL.
        ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
            .store(snapshot("alpha", used: 42, now: now.addingTimeInterval(-1)))

        // Session 2 (fresh instance = relaunch) reloads it from disk.
        let relaunched = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
        XCTAssertEqual(
            relaunched.loadSnapshots(providerIDs: ["alpha"])["alpha"]?.lines.first,
            .progress(label: "Session", used: 42, limit: 100, format: .percent)
        )
        XCTAssertNil(relaunched.snapshot(providerID: "alpha"))
    }

    /// A snapshot written this session still expires once it ages past TTL, so the periodic loop resumes
    /// refetching on the normal cadence (the session-write flag widens freshness on launch, it doesn't
    /// pin a snapshot fresh forever).
    func testSnapshotWrittenThisSessionExpiresAfterTTL() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date()
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 100, now: { now })

        cache.store(snapshot("alpha", used: 42, now: now))
        now = now.addingTimeInterval(101)
        XCTAssertNil(cache.snapshot(providerID: "alpha"))
    }

    func testFullRefreshFreshnessIncludesHistoryStampButMeterOnlyFreshnessDoesNot() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let oldHistory = now.addingTimeInterval(-14_400)
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
        var value = ProviderSnapshot(
            providerID: "antigravity",
            displayName: "Antigravity",
            lines: [.progress(label: "Session", used: 20, limit: 100, format: .percent)],
            refreshedAt: now,
            usageHistory: ProviderUsageHistory(series: DailyUsageSeries(daily: []))
        )
        value.quotaRefreshedAt = now
        value.historyRefreshedAt = oldHistory
        cache.store(value, now: now)

        XCTAssertNil(cache.snapshot(providerID: "antigravity"), "a full refresh must redo stale local accounting")
        XCTAssertNotNil(
            cache.snapshot(providerID: "antigravity", freshnessInterval: 60),
            "a meter-only refresh only depends on the fresh quota domain"
        )
    }

    func testInvalidateSessionFreshnessForcesCacheMiss() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        var cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
        cache.store(snapshot("codex", used: 10, now: now))
        cache.store(snapshot("cursor", used: 20, now: now))
        XCTAssertNotNil(cache.snapshot(providerID: "codex"))
        XCTAssertNotNil(cache.snapshot(providerID: "cursor"))

        cache.invalidateSessionFreshness(providerIDs: ["codex"])
        XCTAssertNil(cache.snapshot(providerID: "codex"), "codex must miss after ledger-style invalidate")
        XCTAssertNotNil(cache.snapshot(providerID: "cursor"), "non-codex stays fresh")
        // Persisted blob still available for launch paint / SWR.
        XCTAssertEqual(cache.loadSnapshots(providerIDs: ["codex"])["codex"]?.lines.isEmpty, false)
    }

    func testFullIncompleteQuotaRefreshRetainsOmittedMetersAndIndependentHistoryStamp() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let old = now.addingTimeInterval(-3 * 60 * 60)
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: []), unknownModelsByDay: [:])
        var previous = ProviderSnapshot(
            providerID: "antigravity",
            displayName: "Antigravity",
            plan: "Pro",
            lines: [
                .progress(label: "Session", used: 50, limit: 100, format: .percent),
                .progress(label: "Weekly", used: 70, limit: 100, format: .percent)
            ],
            refreshedAt: old,
            usageHistory: history
        )
        previous.quotaRefreshedAt = old
        previous.historyRefreshedAt = old
        cache.store(previous, now: old)

        let incomplete = ProviderSnapshot(
            providerID: "antigravity",
            displayName: "Antigravity",
            lines: [.progress(label: "Session", used: 20, limit: 100, format: .percent)],
            refreshedAt: now,
            warning: "Some quota limits are missing.",
            replacesPriorQuotaProgress: false
        )
        let result = cache.store(incomplete, refreshOrder: 1, scope: .full, now: now)
        guard case .stored(let storedValue) = result,
              let stored = storedValue
        else {
            return XCTFail("The full refresh should be stored")
        }

        XCTAssertEqual(stored.lines.compactMap { line -> String? in
            guard case .progress = line else { return nil }
            return line.label
        }, ["Session", "Weekly"])
        XCTAssertEqual(stored.line(label: "Weekly"), previous.line(label: "Weekly"))
        XCTAssertEqual(stored.quotaRefreshedAt?.timeIntervalSince(old) ?? .infinity, 0, accuracy: 0.01)
        XCTAssertEqual(stored.refreshedAt, now)
        XCTAssertEqual(stored.historyRefreshedAt?.timeIntervalSince(old) ?? .infinity, 0, accuracy: 0.01)
        XCTAssertEqual(stored.usageHistory, history)
    }

    func testPanelMeterCacheMergeKeepsCarriedHistoryMarkedForPanelRefold() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let old = now.addingTimeInterval(-30)
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
        let provider = Provider(id: "antigravity", displayName: "Antigravity", icon: .providerMark("antigravity"))
        let historyDescriptor = UsageHistoryDescriptor(
            scope: .machineLocal,
            estimatedCost: true,
            sourceNote: "local"
        )
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: "2030-03-17", totalTokens: 42, costUSD: 0.02)
        ]))
        var previous = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Session", used: 20, limit: 100, format: .percent)],
            refreshedAt: old,
            usageHistory: history,
            historyWarning: "Older history rows are unavailable."
        )
        previous.historyRefreshedAt = old
        cache.store(previous, now: old)

        let meters = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Session", used: 35, limit: 100, format: .percent)],
            refreshedAt: now
        )
        let result = cache.store(
            meters,
            refreshOrder: 1,
            scope: .panelMeters,
            historyDescriptor: historyDescriptor,
            now: now
        )

        guard case .stored(let storedValue) = result, let stored = storedValue else {
            return XCTFail("The meter refresh should be stored")
        }
        XCTAssertEqual(stored.usageHistory, history)
        XCTAssertEqual(stored.historyWarning, "Older history rows are unavailable.")
        XCTAssertEqual(stored.historyRefreshedAt, old)
        XCTAssertEqual(stored.refreshedAt, now)
        XCTAssertEqual(stored.carriesPriorHistory, true,
                       "The following panel-accounting phase must bypass the fresh quota cache")
    }

    func testPanelAccountingWarningPersistsWithoutRefreshingEitherDataDomain() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let old = now.addingTimeInterval(-600)
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
        let provider = Provider(id: "antigravity", displayName: "Antigravity", icon: .providerMark("antigravity"))
        let descriptor = UsageHistoryDescriptor(
            scope: .machineLocal,
            estimatedCost: true,
            sourceNote: "local"
        )
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: "2030-03-17", totalTokens: 42, costUSD: 0.02)
        ]))
        var previous = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Session", used: 20, limit: 100, format: .percent)],
            refreshedAt: old,
            usageHistory: history
        )
        previous.historyRefreshedAt = old
        previous.quotaRefreshedAt = old
        cache.store(previous, now: old)

        let warning = "Some Antigravity conversation stores could not be read."
        let fold = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [],
            refreshedAt: now,
            historyWarning: warning
        )
        let writeOrder = try XCTUnwrap(cache.beginRefreshOrder(providerID: provider.id))
        let result = cache.store(
            fold,
            refreshOrder: writeOrder,
            scope: .panelAccounting,
            historyDescriptor: descriptor,
            now: now
        )

        guard case .stored(let storedValue) = result, let stored = storedValue else {
            return XCTFail("The fold warning should update without asserting fresh history")
        }
        XCTAssertEqual(stored.historyWarning, warning)
        XCTAssertEqual(stored.usageHistory, history)
        XCTAssertEqual(stored.historyRefreshedAt, old)
        XCTAssertEqual(stored.quotaRefreshedAt, old)
        XCTAssertEqual(stored.refreshedAt, old)
    }

    func testAntigravityAccountSwitchUsesNewQuotaAndKeepsMachineLocalHistory() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
        let provider = Provider(id: "antigravity", displayName: "Antigravity", icon: .providerMark("antigravity"))
        let descriptor = UsageHistoryDescriptor(
            scope: .machineLocal,
            estimatedCost: true,
            sourceNote: "local"
        )
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: "2030-03-17", totalTokens: 42, costUSD: 0.02)
        ]))
        var previous = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: "Old Plan",
            lines: [.progress(label: "Session", used: 80, limit: 100, format: .percent)],
            refreshedAt: now.addingTimeInterval(-60),
            usageHistory: history,
            warning: "Old account warning",
            historyWarning: "Machine history is partial"
        )
        previous.historyRefreshedAt = now.addingTimeInterval(-120)
        cache.store(previous, producedByIdentityKey: "antigravity-account-old")

        let incoming = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: "New Plan",
            lines: [.progress(label: "Session", used: 25, limit: 100, format: .percent)],
            refreshedAt: now
        )
        let writeOrder = try XCTUnwrap(cache.beginRefreshOrder(providerID: provider.id))
        let result = cache.store(
            incoming,
            producedByIdentityKey: "antigravity-account-new",
            refreshOrder: writeOrder,
            scope: .panelMeters,
            historyDescriptor: descriptor,
            now: now
        )

        guard case .stored(let storedValue) = result, let stored = storedValue else {
            return XCTFail("The new account quota should store")
        }
        XCTAssertEqual(stored.plan, "New Plan")
        XCTAssertEqual(stored.line(label: "Session"), incoming.line(label: "Session"))
        XCTAssertEqual(stored.usageHistory, history)
        XCTAssertEqual(stored.historyWarning, "Machine history is partial")
        XCTAssertEqual(stored.carriesPriorHistory, true)
        XCTAssertEqual(cache.producedByIdentityKey(providerID: provider.id), "antigravity-account-new")
    }
}
