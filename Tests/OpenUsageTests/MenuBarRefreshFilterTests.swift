import XCTest
@testable import OpenUsage

@MainActor
final class MenuBarRefreshFilterTests: XCTestCase {
    private let codex = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
    private let claude = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
    private let opencode = Provider(id: "opencode", displayName: "OpenCode", icon: .providerMark("opencode"))
    private let hermes = Provider(id: "hermes", displayName: "Hermes", icon: .providerMark("hermes"))

    private lazy var session = WidgetDescriptor.percent(
        id: "codex.session", provider: codex, title: "Session"
    )
    private lazy var weekly = WidgetDescriptor.percent(
        id: "codex.weekly", provider: codex, title: "Weekly"
    )
    private lazy var claudeSession = WidgetDescriptor.percent(
        id: "claude.session", provider: claude, title: "Session"
    )
    private lazy var openSpend = WidgetDescriptor.values(
        id: "opencode.today", provider: opencode, title: "Today", isUsagePeriod: true
    )
    private lazy var hermesToday = WidgetDescriptor.values(
        id: "hermes.today", provider: hermes, title: "Today", isUsagePeriod: true
    )
    private lazy var openSession = WidgetDescriptor.percent(
        id: "opencode.session", provider: opencode, title: "Session"
    )

    func testMenuBarKeepsOnlyPinnedProviders() {
        let ids = MenuBarRefreshFilter.providerIDs(
            enabledProviderIDs: ["codex", "claude", "opencode", "hermes"],
            pinnedMetricIDs: ["codex.session", "claude.session"],
            providerIDForMetric: providerID(for:),
            notificationRelevantProviderIDs: ["codex", "claude", "opencode"],
            notificationsEnabled: false
        )
        XCTAssertEqual(ids, ["codex", "claude"])
    }

    func testMenuBarEmptyPinsAndNoNotificationsSkipsEverything() {
        let ids = MenuBarRefreshFilter.providerIDs(
            enabledProviderIDs: ["codex", "claude", "opencode"],
            pinnedMetricIDs: [],
            providerIDForMetric: providerID(for:),
            notificationRelevantProviderIDs: ["codex", "claude", "opencode"],
            notificationsEnabled: false
        )
        XCTAssertTrue(ids.isEmpty)
    }

    func testMenuBarIncludesUnpinnedWhenNotificationsNeedThem() {
        let ids = MenuBarRefreshFilter.providerIDs(
            enabledProviderIDs: ["codex", "claude", "opencode", "hermes"],
            pinnedMetricIDs: ["codex.session"],
            providerIDForMetric: providerID(for:),
            notificationRelevantProviderIDs: ["codex", "claude", "opencode"],
            notificationsEnabled: true
        )
        // Hermes has only unbounded tiles → not notification-relevant → stays skipped.
        XCTAssertEqual(ids, ["codex", "claude", "opencode"])
    }

    func testNotificationRelevantUsesBoundedSamplesOnly() {
        let relevant = MenuBarRefreshFilter.notificationRelevantProviderIDs(
            descriptors: [session, weekly, claudeSession, openSpend, hermesToday, openSession]
        )
        XCTAssertEqual(relevant, ["codex", "claude", "opencode"])
        XCTAssertFalse(relevant.contains("hermes"))
    }

    func testFullScopePrioritizesPinnedFirst() {
        let ordered = MenuBarRefreshFilter.prioritize(
            providerIDs: ["opencode", "claude", "codex", "hermes"],
            pinnedMetricIDs: ["codex.session", "claude.session"],
            providerIDForMetric: providerID(for:)
        )
        XCTAssertEqual(ordered, ["claude", "codex", "opencode", "hermes"])
    }

    func testSelectProviderIDsFullPreservesAllEnabled() {
        let ids = WidgetDataStore.selectProviderIDsForRefresh(
            enabledProviderIDs: ["opencode", "claude", "codex"],
            scope: .full,
            pinnedMetricIDs: ["codex.session"],
            providerIDForMetric: providerID(for:),
            orderedDescriptors: [session, claudeSession, openSession],
            notificationsEnabled: false
        )
        XCTAssertEqual(ids, ["codex", "opencode", "claude"])
    }

    func testSelectProviderIDsMenuBarFilters() {
        let ids = WidgetDataStore.selectProviderIDsForRefresh(
            enabledProviderIDs: ["opencode", "claude", "codex"],
            scope: .menuBar,
            pinnedMetricIDs: ["codex.session"],
            providerIDForMetric: providerID(for:),
            orderedDescriptors: [session, claudeSession, openSession],
            notificationsEnabled: false
        )
        XCTAssertEqual(ids, ["codex"])
    }

    func testRefreshAllMenuBarSkipsUnpinnedProviders() async {
        let providers: [(Provider, WidgetDescriptor)] = [
            (codex, session),
            (claude, claudeSession),
            (opencode, openSession),
        ]
        let runtimes = providers.map { provider, descriptor in
            CountingProviderRuntime(
                provider: provider,
                descriptors: [descriptor],
                snapshot: ProviderSnapshot(
                    providerID: provider.id,
                    displayName: provider.displayName,
                    lines: [.progress(label: descriptor.metricLabel, used: 1, limit: 100, format: .percent)],
                    refreshedAt: Date(timeIntervalSince1970: 1_000)
                )
            )
        }
        let registry = WidgetRegistry(
            providers: providers.map(\.0),
            descriptors: providers.map(\.1)
        )
        let store = WidgetDataStore(
            registry: registry,
            providers: runtimes,
            defaults: makeUserDefaults("menu-bar-filter"),
            pinnedMetricIDs: { ["codex.session"] }
        )

        await ProviderRefreshContext.$scope.withValue(.menuBar) {
            await store.refreshAll()
        }

        XCTAssertEqual(runtimes[0].refreshCount, 1, "pinned Codex must refresh")
        XCTAssertEqual(runtimes[1].refreshCount, 0, "unpinned Claude must skip on menuBar")
        XCTAssertEqual(runtimes[2].refreshCount, 0, "unpinned OpenCode must skip on menuBar")
    }

    func testRefreshAllFullStillHitsEveryonePinnedFirst() async {
        let providers: [(Provider, WidgetDescriptor)] = [
            (opencode, openSession),
            (claude, claudeSession),
            (codex, session),
        ]
        var order: [String] = []
        let runtimes: [ProviderRuntime] = providers.map { provider, descriptor in
            OrderRecordingProviderRuntime(
                provider: provider,
                descriptors: [descriptor],
                snapshot: ProviderSnapshot(
                    providerID: provider.id,
                    displayName: provider.displayName,
                    lines: [.progress(label: descriptor.metricLabel, used: 1, limit: 100, format: .percent)],
                    refreshedAt: Date(timeIntervalSince1970: 1_000)
                ),
                onRefresh: { order.append(provider.id) }
            )
        }
        let registry = WidgetRegistry(
            providers: providers.map(\.0),
            descriptors: providers.map(\.1)
        )
        let store = WidgetDataStore(
            registry: registry,
            providers: runtimes,
            defaults: makeUserDefaults("full-priority"),
            pinnedMetricIDs: { ["codex.session"] }
        )

        await ProviderRefreshContext.$scope.withValue(.full) {
            await store.refreshAll(force: true, maxConcurrentProviders: 1)
        }

        XCTAssertEqual(order, ["codex", "opencode", "claude"])
    }

    func testMenuBarMergeStillPreservesHistoryAfterQuotaOnlyRefresh() async {
        let history = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-09-22", totalTokens: 42, costUSD: 0.02)
            ])
        )
        let first = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            lines: [
                .progress(label: "Session", used: 10, limit: 100, format: .percent),
                .values(label: "Today", values: [
                    MetricValue(number: 42, kind: .count, label: "tokens")
                ]),
            ],
            refreshedAt: Date(timeIntervalSince1970: 1_000),
            usageHistory: history
        )
        let second = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            lines: [.progress(label: "Session", used: 55, limit: 100, format: .percent)],
            refreshedAt: Date(timeIntervalSince1970: 2_000),
            usageHistory: nil
        )
        let runtime = SequenceProviderRuntime(
            provider: codex,
            descriptors: [session],
            snapshots: [first, second]
        )
        // ttl: 0 so the menuBar pass (force: false, matching production) is never a cache hit.
        let defaults = makeUserDefaults("menu-bar-merge-store")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [codex], descriptors: [session]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 0),
            defaults: defaults,
            pinnedMetricIDs: { ["codex.session"] }
        )

        await ProviderRefreshContext.$scope.withValue(.full) {
            await store.refreshAll(force: true)
        }
        await ProviderRefreshContext.$scope.withValue(.menuBar) {
            await store.refreshAll(force: false)
        }

        let snap = store.snapshots["codex"]
        XCTAssertEqual(snap?.line(label: "Session"),
                       .progress(label: "Session", used: 55, limit: 100, format: .percent))
        XCTAssertEqual(snap?.line(label: "Today"), first.line(label: "Today"))
        XCTAssertEqual(snap?.usageHistory, history)
    }


    func testMenuBarPinsResolveMultiAccountCodexCardIDs() {
        let ids = MenuBarRefreshFilter.providerIDs(
            enabledProviderIDs: ["codex", "codex@0577ce6e", "cursor"],
            pinnedMetricIDs: ["codex.session", "codex@0577ce6e.weekly", "cursor.auto"],
            providerIDForMetric: { id in
                if id.hasPrefix("codex@0577ce6e.") { return "codex@0577ce6e" }
                if id.hasPrefix("codex.") { return "codex" }
                if id.hasPrefix("cursor.") { return "cursor" }
                return nil
            },
            notificationRelevantProviderIDs: [],
            notificationsEnabled: false
        )
        XCTAssertEqual(ids, ["codex", "codex@0577ce6e", "cursor"])
    }

    func testForceRefreshWaitsForInFlightMenuBarThenAppliesFullSnapshot() async {
        let history = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-09-24", totalTokens: 77, costUSD: 0.07)
            ])
        )
        let seeded = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            lines: [
                .progress(label: "Session", used: 1, limit: 100, format: .percent),
                .values(label: "Today", values: [
                    MetricValue(number: 1, kind: .count, label: "tokens")
                ]),
            ],
            refreshedAt: Date(timeIntervalSince1970: 500),
            usageHistory: ProviderUsageHistory(
                series: DailyUsageSeries(daily: [
                    DailyUsageEntry(date: "2026-09-20", totalTokens: 1, costUSD: 0.01)
                ])
            )
        )
        let menuBarSnap = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            lines: [.progress(label: "Session", used: 11, limit: 100, format: .percent)],
            refreshedAt: Date(timeIntervalSince1970: 1_000),
            usageHistory: nil
        )
        let fullSnap = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            lines: [
                .progress(label: "Session", used: 22, limit: 100, format: .percent),
                .values(label: "Today", values: [
                    MetricValue(number: 77, kind: .count, label: "tokens")
                ]),
            ],
            refreshedAt: Date(timeIntervalSince1970: 2_000),
            usageHistory: history
        )
        let runtime = SeedThenGateProviderRuntime(
            provider: codex,
            descriptors: [session],
            seed: seeded,
            menuBarSnapshot: menuBarSnap,
            fullSnapshot: fullSnap
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [codex], descriptors: [session]),
            providers: [runtime],
            defaults: makeUserDefaults("force-wait-race"),
            pinnedMetricIDs: { ["codex.session"] }
        )

        await ProviderRefreshContext.$scope.withValue(.full) {
            await store.refreshAll(force: true)
        }
        XCTAssertEqual(store.snapshots["codex"]?.usageHistory, seeded.usageHistory)

        runtime.armGateForNext()
        let menuBarTask = Task {
            await ProviderRefreshContext.$scope.withValue(.menuBar) {
                await store.refreshAll(force: true)
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !runtime.isWaiting, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        guard runtime.isWaiting else {
            runtime.releaseGate()
            _ = await menuBarTask.value
            return XCTFail("menuBar refresh did not enter the gate")
        }

        let forceTask = Task {
            await ProviderRefreshContext.$scope.withValue(.full) {
                await store.refreshAll(force: true)
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        runtime.releaseGate()
        _ = await menuBarTask.value
        _ = await forceTask.value

        let snap = store.snapshots["codex"]
        XCTAssertEqual(
            snap?.line(label: "Session"),
            .progress(label: "Session", used: 22, limit: 100, format: .percent),
            "force must run after in-flight menuBar and apply full Session"
        )
        XCTAssertEqual(snap?.line(label: "Today"), fullSnap.line(label: "Today"))
        XCTAssertEqual(
            snap?.usageHistory,
            history,
            "force must not leave the panel on menuBar-merged stale history"
        )
        XCTAssertEqual(runtime.refreshCount, 3, "seed + menuBar + force")
    }

    private func providerID(for metricID: String) -> String? {
        switch metricID {
        case "codex.session", "codex.weekly": return "codex"
        case "claude.session": return "claude"
        case "opencode.session", "opencode.today": return "opencode"
        case "hermes.today": return "hermes"
        default: return nil
        }
    }

    private func makeUserDefaults(_ name: String) -> UserDefaults {
        let suite = "openusage.tests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

@MainActor
private final class OrderRecordingProviderRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor]
    let snapshot: ProviderSnapshot
    let onRefresh: () -> Void

    init(
        provider: Provider,
        descriptors: [WidgetDescriptor],
        snapshot: ProviderSnapshot,
        onRefresh: @escaping () -> Void
    ) {
        self.provider = provider
        self.widgetDescriptors = descriptors
        self.snapshot = snapshot
        self.onRefresh = onRefresh
    }

    func refresh() async -> ProviderSnapshot {
        onRefresh()
        return snapshot
    }
}

/// Returns `seed` once, then gates the next refresh (menuBar), then returns `fullSnapshot`.
@MainActor
private final class SeedThenGateProviderRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor]
    private let seed: ProviderSnapshot
    private let menuBarSnapshot: ProviderSnapshot
    private let fullSnapshot: ProviderSnapshot
    private(set) var refreshCount = 0
    private(set) var isWaiting = false
    private var gateArmed = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(
        provider: Provider,
        descriptors: [WidgetDescriptor],
        seed: ProviderSnapshot,
        menuBarSnapshot: ProviderSnapshot,
        fullSnapshot: ProviderSnapshot
    ) {
        self.provider = provider
        self.widgetDescriptors = descriptors
        self.seed = seed
        self.menuBarSnapshot = menuBarSnapshot
        self.fullSnapshot = fullSnapshot
    }

    func armGateForNext() { gateArmed = true }

    func releaseGate() {
        continuation?.resume()
        continuation = nil
    }

    func refresh() async -> ProviderSnapshot {
        defer { refreshCount += 1 }
        if refreshCount == 0 {
            return seed
        }
        if gateArmed {
            gateArmed = false
            isWaiting = true
            await withCheckedContinuation { continuation = $0 }
            isWaiting = false
            return menuBarSnapshot
        }
        return fullSnapshot
    }
}
