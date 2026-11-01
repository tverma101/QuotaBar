import XCTest
@testable import QuotaBar

/// Covers the launch-time account guard on the snapshot cache (v9): when an account-aware card's
/// CURRENT account identity is known, a cached entry only paints if the account that produced it
/// (`producedByIdentityKey` stamp) matches. After an account swap at the same home the card id still
/// matches, so without the stamp check the previous account's limits/plan would show under the new
/// account until the first successful refresh. A card whose current identity is unresolved keeps its
/// cache (behavior identical to before the guard), and non-account providers are untouched.
@MainActor
final class WidgetDataStoreAccountCacheTests: XCTestCase {
    private func makeUserDefaults(_ name: String) -> UserDefaults {
        let suiteName = "WidgetDataStoreAccountCacheTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func provider(_ id: String) -> Provider {
        Provider(id: id, displayName: id.capitalized, icon: .providerMark("codex"))
    }

    private func snapshot(_ id: String, used: Double) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: id,
            displayName: id.capitalized,
            lines: [.progress(label: "Session", used: used, limit: 100, format: .percent)],
            refreshedAt: Date()
        )
    }

    private func makeStore(
        providers: [Provider],
        cache: ProviderSnapshotCache,
        defaults: UserDefaults,
        identityKeys: [String: String]
    ) -> WidgetDataStore {
        WidgetDataStore(
            registry: WidgetRegistry(providers: providers, descriptors: []),
            providers: [],
            cache: cache,
            defaults: defaults,
            providerIdentityKeys: identityKeys
        )
    }

    /// A mismatched stamp drops ONLY that entry: the swapped card starts blank until its refresh,
    /// while the other family's card with a matching stamp keeps painting.
    func testMismatchedStampDropsOnlyThatEntry() {
        let defaults = makeUserDefaults("mismatch")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })
        cache.store(snapshot("claude", used: 40), producedByIdentityKey: "acct-OLD")
        cache.store(snapshot("codex", used: 50), producedByIdentityKey: "acct-B")

        let store = makeStore(
            providers: [provider("claude"), provider("codex")],
            cache: cache,
            defaults: defaults,
            identityKeys: ["claude": "acct-NEW", "codex": "acct-B"]
        )
        XCTAssertNil(store.snapshots["claude"], "swapped account's cached snapshot must not paint")
        XCTAssertNotNil(store.snapshots["codex"], "unswapped card must keep its cache")
    }

    /// OpenCode's Go caps belong to its credential inventory, while its local spend history belongs
    /// to this machine. Rotating the only Go key must clear the account quota but keep local history.
    func testOpenCodeCredentialMismatchClearsQuotaAndRetainsHistory() {
        let defaults = makeUserDefaults("opencode-mismatch")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { now })
        var previous = snapshot("opencode", used: 70)
        previous.plan = "Go"
        previous.usageHistory = ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: "2026-10-14", totalTokens: 500, costUSD: 5)
        ]))
        cache.store(previous, producedByIdentityKey: "opencode-key-K1")

        let changedAccount = makeStore(
            providers: [provider("opencode")],
            cache: cache,
            defaults: defaults,
            identityKeys: ["opencode": "opencode-key-K2"]
        )
        let reloaded = changedAccount.snapshots["opencode"]
        XCTAssertNotNil(reloaded, "OpenCode history remains available while the replacement key refreshes")
        XCTAssertNil(reloaded?.plan)
        XCTAssertNil(reloaded?.line(label: "Session"))
        XCTAssertEqual(reloaded?.usageHistory?.series.daily.first?.totalTokens, 500)

        let unknownInventory = makeStore(
            providers: [provider("opencode")],
            cache: cache,
            defaults: defaults,
            identityKeys: ["opencode": OpenCodeGoAccountInventory.incompleteCacheIdentityKey]
        )
        XCTAssertNil(unknownInventory.snapshots["opencode"]?.plan)
        XCTAssertNil(unknownInventory.snapshots["opencode"]?.line(label: "Session"))
        XCTAssertEqual(unknownInventory.snapshots["opencode"]?.usageHistory?.series.daily.first?.totalTokens, 500)

        let sameAccount = makeStore(
            providers: [provider("opencode")],
            cache: cache,
            defaults: defaults,
            identityKeys: ["opencode": "opencode-key-K1"]
        )
        XCTAssertEqual(sameAccount.snapshots["opencode"]?.plan, "Go")
        XCTAssertNotNil(sameAccount.snapshots["opencode"]?.line(label: "Session"))
    }

    func testAntigravityCredentialMismatchClearsQuotaAndRetainsMachineHistory() {
        let defaults = makeUserDefaults("antigravity-mismatch")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { now })
        var previous = snapshot("antigravity", used: 70)
        previous.plan = "Old Plan"
        previous.warning = "Old quota warning"
        previous.historyWarning = "Machine history is partial"
        previous.usageHistory = ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: "2026-10-14", totalTokens: 500, costUSD: 5)
        ]))
        cache.store(previous, producedByIdentityKey: "antigravity-account-old")

        let store = makeStore(
            providers: [provider("antigravity")],
            cache: cache,
            defaults: defaults,
            identityKeys: ["antigravity": "antigravity-account-new"]
        )

        let reloaded = store.snapshots["antigravity"]
        XCTAssertNotNil(reloaded)
        XCTAssertNil(reloaded?.plan)
        XCTAssertNil(reloaded?.line(label: "Session"))
        XCTAssertNil(reloaded?.warning)
        XCTAssertEqual(reloaded?.historyWarning, "Machine history is partial")
        XCTAssertEqual(reloaded?.usageHistory?.series.daily.first?.totalTokens, 500)
        XCTAssertEqual(store.warningMessage(for: "antigravity"), "Machine history is partial")
    }

    func testExternalRefreshInvalidatesAntigravityLocalHistoryFreshness() {
        let defaults = makeUserDefaults("antigravity-history-trigger")
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let provider = provider("antigravity")
        let historyDescriptors = WidgetDescriptor.spendTiles(provider: provider).map {
            $0.exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "local")
        }
        let descriptors = [WidgetDescriptor.percent(id: "antigravity.session", provider: provider, title: "Session")]
            + historyDescriptors
        let registry = WidgetRegistry(providers: [provider], descriptors: descriptors)
        let runtime = SequenceProviderRuntime(provider: provider, descriptors: descriptors, snapshots: [snapshot("antigravity", used: 40)])
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { now })
        var fresh = snapshot("antigravity", used: 40)
        fresh.refreshedAt = now
        fresh.quotaRefreshedAt = now
        fresh.usageHistory = ProviderUsageHistory(series: DailyUsageSeries(daily: []))
        fresh.historyRefreshedAt = now
        cache.store(fresh, now: now)
        let store = WidgetDataStore(
            registry: registry,
            providers: [runtime],
            cache: cache,
            defaults: defaults,
            now: { now }
        )

        XCTAssertNotNil(cache.snapshot(providerID: provider.id))
        store.invalidateLocalAccountingFreshness()
        XCTAssertNil(cache.snapshot(providerID: provider.id), "external refresh must force Antigravity's local DB fold")
    }

    func testOpenCodeLabelReassignmentCannotReuseAnotherAccountCaps() {
        let defaults = makeUserDefaults("opencode-label-reassignment")
        let firstKey = OpenCodeGoAccountIdentity(
            credentialID: "credential-a",
            descriptorKey: "source-a",
            displayName: "Work"
        )
        let secondKey = OpenCodeGoAccountIdentity(
            credentialID: "credential-b",
            descriptorKey: "source-b",
            displayName: "Personal"
        )
        let originalInventory = OpenCodeGoAccountInventory(
            accountIdentities: [firstKey, secondKey],
            isComplete: true
        )
        let reassignedInventory = OpenCodeGoAccountInventory(
            accountIdentities: [
                OpenCodeGoAccountIdentity(
                    credentialID: "credential-a",
                    descriptorKey: "source-a",
                    displayName: "Personal"
                ),
                OpenCodeGoAccountIdentity(
                    credentialID: "credential-b",
                    descriptorKey: "source-b",
                    displayName: "Work"
                )
            ],
            isComplete: true
        )
        XCTAssertEqual(originalInventory.credentialIDs, reassignedInventory.credentialIDs)
        XCTAssertNotEqual(originalInventory.cacheIdentityKey, reassignedInventory.cacheIdentityKey)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { now })
        var previous = snapshot("opencode", used: 35)
        previous.plan = "Go"
        previous.lines = [
            .progress(label: "Session (Work)", used: 35, limit: 100, format: .percent),
            .progress(label: "Session (Personal)", used: 65, limit: 100, format: .percent)
        ]
        previous.usageHistory = ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: "2026-10-14", totalTokens: 500, costUSD: 5)
        ]))
        cache.store(previous, producedByIdentityKey: originalInventory.cacheIdentityKey)

        let store = makeStore(
            providers: [provider("opencode")],
            cache: cache,
            defaults: defaults,
            identityKeys: ["opencode": reassignedInventory.cacheIdentityKey]
        )

        XCTAssertNil(store.snapshots["opencode"]?.plan)
        XCTAssertNil(store.snapshots["opencode"]?.line(label: "Session (Work)"))
        XCTAssertNil(store.snapshots["opencode"]?.line(label: "Session (Personal)"))
        XCTAssertEqual(store.snapshots["opencode"]?.usageHistory?.series.daily.first?.totalTokens, 500)
    }

    /// An unstamped entry on an account-aware card whose current identity IS known was written while
    /// the identity was unresolved — unattributable, so conservatively dropped.
    func testNilStampWithKnownIdentityIsDropped() {
        let defaults = makeUserDefaults("nil-stamp")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })
        cache.store(snapshot("codex", used: 40))

        let store = makeStore(
            providers: [provider("codex")],
            cache: cache,
            defaults: defaults,
            identityKeys: ["codex": "acct-A"]
        )
        XCTAssertNil(store.snapshots["codex"])
    }

    /// A card whose CURRENT identity is unresolved (logged out, keyring-mode Codex) can't verify a
    /// stamp either way — it keeps its cache, exactly as before the guard existed. Dropping here
    /// would blank the card at every launch for users whose identity never resolves.
    func testUnresolvedCurrentIdentityKeepsEntry() {
        let defaults = makeUserDefaults("no-identity")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })
        cache.store(snapshot("claude", used: 40), producedByIdentityKey: "acct-A")
        cache.store(snapshot("codex", used: 50))

        let store = makeStore(
            providers: [provider("claude"), provider("codex")],
            cache: cache,
            defaults: defaults,
            identityKeys: [:]
        )
        XCTAssertNotNil(store.snapshots["claude"])
        XCTAssertNotNil(store.snapshots["codex"])
    }

    /// Non-account providers are untouched by the guard: their entries load with or without a stamp
    /// (they never carry one in production, but even a stray stamp must not gate them).
    func testNonAccountProviderLoadsRegardlessOfStamp() {
        let defaults = makeUserDefaults("non-account")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })
        cache.store(snapshot("cursor", used: 40))
        cache.store(snapshot("grok", used: 50), producedByIdentityKey: "stray-stamp")

        let store = makeStore(
            providers: [provider("cursor"), provider("grok")],
            cache: cache,
            defaults: defaults,
            identityKeys: [:]
        )
        XCTAssertNotNil(store.snapshots["cursor"])
        XCTAssertNotNil(store.snapshots["grok"])
    }

    /// A TTL-fresh entry with a mismatched stamp must not short-circuit `refresh` as a cache hit —
    /// under persisted freshness (the one-shot CLI) that would copy the previous account's snapshot
    /// back in. A matching stamp keeps the normal cache-hit path.
    func testRefreshNeverCacheHitsAMismatchedStampEntry() async {
        let defaults = makeUserDefaults("refresh-gate")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })
        cache.store(snapshot("claude", used: 40), producedByIdentityKey: "acct-OLD")

        let swapped = makeStore(
            providers: [provider("claude")],
            cache: cache,
            defaults: defaults,
            identityKeys: ["claude": "acct-NEW"]
        )
        // No provider runtime is registered, so passing the cache gate surfaces as `.skipped` (a
        // fetch attempt), while honoring the stale entry would surface as `.cacheHit`.
        let gated = await swapped.refresh(providerID: "claude")
        XCTAssertEqual(gated, .skipped, "a mismatched stamp must fall through to a real fetch")

        let sameAccount = makeStore(
            providers: [provider("claude")],
            cache: cache,
            defaults: defaults,
            identityKeys: ["claude": "acct-OLD"]
        )
        let honored = await sameAccount.refresh(providerID: "claude")
        XCTAssertEqual(honored, .cacheHit)
    }

    /// A refresh writes the card's launch-resolved identity as the stamp, and a nil identity CLEARS
    /// any prior stamp — leaving the old account's stamp would falsely bless the new snapshot.
    func testStoreStampsAndClearsProducerIdentity() {
        let defaults = makeUserDefaults("stamp-write")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })

        cache.store(snapshot("claude", used: 40), producedByIdentityKey: "acct-A")
        XCTAssertEqual(cache.producedByIdentityKey(providerID: "claude"), "acct-A")

        cache.store(snapshot("claude", used: 41))
        XCTAssertNil(cache.producedByIdentityKey(providerID: "claude"))
    }
}
