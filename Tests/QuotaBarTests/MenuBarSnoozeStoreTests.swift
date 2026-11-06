import XCTest
@testable import QuotaBar

@MainActor
final class MenuBarSnoozeStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "MenuBarSnoozeStoreTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    func testDefaultValues() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MenuBarSnoozeStore(defaults: defaults)
        XCTAssertFalse(store.isEnabled)
        XCTAssertEqual(store.threshold, .outOfUsage)
        XCTAssertTrue(store.excludedProviderIDs.isEmpty)
        XCTAssertTrue(store.manualSnoozeUntil.isEmpty)
    }

    func testAutoSnoozeDisabledDoesNotSnooze() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MenuBarSnoozeStore(defaults: defaults)
        store.isEnabled = false

        let descriptor = WidgetDescriptor.percent(
            id: "codex.weekly", provider: Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex")),
            title: "Weekly", metricLabel: "Weekly"
        )
        let data = WidgetData(
            title: "Weekly", icon: .providerMark("codex"), kind: .percent,
            used: 100, limit: 100, displayMode: .remaining
        )

        let isSnoozed = store.isSnoozed(
            providerID: "codex",
            pinnedMetrics: [descriptor],
            data: { _ in data },
            now: now
        )
        XCTAssertFalse(isSnoozed)
    }

    func testAutoSnoozeWhenOutOfUsage() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MenuBarSnoozeStore(defaults: defaults)
        store.isEnabled = true
        store.threshold = .outOfUsage

        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let sessionDesc = WidgetDescriptor.percent(
            id: "codex.session", provider: provider, title: "Session", metricLabel: "Session"
        )
        let weeklyDesc = WidgetDescriptor.percent(
            id: "codex.weekly", provider: provider, title: "Weekly", metricLabel: "Weekly"
        )

        // Session at 100% remaining, but Weekly at 0% remaining (100 used of 100)
        let sessionData = WidgetData(
            title: "Session", icon: .providerMark("codex"), kind: .percent,
            used: 0, limit: 100, displayMode: .remaining
        )
        let weeklyData = WidgetData(
            title: "Weekly", icon: .providerMark("codex"), kind: .percent,
            used: 100, limit: 100, displayMode: .remaining,
            resetsAt: now.addingTimeInterval(3600 * 24 * 3)
        )

        let isSnoozed = store.isSnoozed(
            providerID: "codex",
            pinnedMetrics: [sessionDesc, weeklyDesc],
            data: { desc in desc.id == "codex.session" ? sessionData : weeklyData },
            now: now
        )
        XCTAssertTrue(isSnoozed)

        let status = store.statusText(
            for: "codex",
            pinnedMetrics: [sessionDesc, weeklyDesc],
            data: { desc in desc.id == "codex.session" ? sessionData : weeklyData },
            now: now
        )
        XCTAssertEqual(status?.isSnoozed, true)
        XCTAssertTrue(status?.text.contains("out of usage") == true)
        XCTAssertTrue(status?.text.contains("Resets in") == true)
    }

    func testThresholdBands() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MenuBarSnoozeStore(defaults: defaults)
        store.isEnabled = true

        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let sessionDesc = WidgetDescriptor.percent(
            id: "claude.session", provider: provider, title: "Session", metricLabel: "Session"
        )
        // 3% remaining (97% used)
        let sessionData = WidgetData(
            title: "Session", icon: .providerMark("claude"), kind: .percent,
            used: 97, limit: 100, displayMode: .remaining
        )

        // At 0% (out of usage): 3% remaining is NOT snoozed
        store.threshold = .outOfUsage
        XCTAssertFalse(store.isSnoozed(providerID: "claude", pinnedMetrics: [sessionDesc], data: { _ in sessionData }, now: now))

        // At 5% threshold: 3% remaining IS snoozed
        store.threshold = .fivePercent
        XCTAssertTrue(store.isSnoozed(providerID: "claude", pinnedMetrics: [sessionDesc], data: { _ in sessionData }, now: now))

        // At 10% threshold: 3% remaining IS snoozed
        store.threshold = .tenPercent
        XCTAssertTrue(store.isSnoozed(providerID: "claude", pinnedMetrics: [sessionDesc], data: { _ in sessionData }, now: now))
    }

    func testPerSubscriptionEnableDisable() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MenuBarSnoozeStore(defaults: defaults)
        store.isEnabled = true
        store.threshold = .outOfUsage

        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let weeklyDesc = WidgetDescriptor.percent(
            id: "codex.weekly", provider: provider, title: "Weekly", metricLabel: "Weekly"
        )
        let weeklyData = WidgetData(
            title: "Weekly", icon: .providerMark("codex"), kind: .percent,
            used: 100, limit: 100, displayMode: .remaining
        )

        XCTAssertTrue(store.isSubscriptionEnabled("codex"))
        XCTAssertTrue(store.isSnoozed(providerID: "codex", pinnedMetrics: [weeklyDesc], data: { _ in weeklyData }, now: now))

        // Exclude codex
        store.setSubscriptionEnabled("codex", enabled: false)
        XCTAssertFalse(store.isSubscriptionEnabled("codex"))
        XCTAssertFalse(store.isSnoozed(providerID: "codex", pinnedMetrics: [weeklyDesc], data: { _ in weeklyData }, now: now))

        // Re-enable codex
        store.setSubscriptionEnabled("codex", enabled: true)
        XCTAssertTrue(store.isSubscriptionEnabled("codex"))
        XCTAssertTrue(store.isSnoozed(providerID: "codex", pinnedMetrics: [weeklyDesc], data: { _ in weeklyData }, now: now))
    }

    func testManualSnoozeUntilReset() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MenuBarSnoozeStore(defaults: defaults)
        store.isEnabled = false // Auto-snooze disabled

        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let sessionDesc = WidgetDescriptor.percent(
            id: "claude.session", provider: provider, title: "Session", metricLabel: "Session"
        )
        let healthyData = WidgetData(
            title: "Session", icon: .providerMark("claude"), kind: .percent,
            used: 10, limit: 100, displayMode: .remaining
        )

        XCTAssertFalse(store.isSnoozed(providerID: "claude", pinnedMetrics: [sessionDesc], data: { _ in healthyData }, now: now))

        // Manual snooze for 2 hours
        store.snoozeUntilReset(providerID: "claude", resetsAt: now.addingTimeInterval(7200))
        XCTAssertTrue(store.isSnoozed(providerID: "claude", pinnedMetrics: [sessionDesc], data: { _ in healthyData }, now: now))

        // Un-snooze
        store.unSnooze(providerID: "claude")
        XCTAssertFalse(store.isSnoozed(providerID: "claude", pinnedMetrics: [sessionDesc], data: { _ in healthyData }, now: now))
    }

    func testActiveSessionCountdownsAreNotAutoSnoozed() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MenuBarSnoozeStore(defaults: defaults)
        store.isEnabled = true
        store.threshold = .twentyPercent

        let provider = Provider(id: "freebuff", displayName: "Freebuff", icon: .providerMark("freebuff"))
        let dailyDesc = WidgetDescriptor.boundedCount(
            id: "freebuff.freebucksDaily", provider: provider, title: "Daily Hours",
            limit: 1, suffix: "hours"
        ).showingSessionTimersInMenuBar(metricLabel: "Active Sessions")

        var data = WidgetData(
            title: "Daily Hours", icon: provider.icon, kind: .count,
            used: 1, limit: 1, countSuffix: "hours"
        )
        data.trayStyle = .sessionCountdowns(metricLabel: "Active Sessions")
        data.traySessionExpiriesAt = [now.addingTimeInterval(1800)] // 30m left

        XCTAssertFalse(store.isSnoozed(providerID: "freebuff", pinnedMetrics: [dailyDesc], data: { _ in data }, now: now))
    }

    func testResetToDefaults() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MenuBarSnoozeStore(defaults: defaults)
        store.isEnabled = true
        store.threshold = .twentyPercent
        store.setSubscriptionEnabled("codex", enabled: false)
        store.snoozeUntilReset(providerID: "claude", resetsAt: now.addingTimeInterval(3600))

        store.resetToDefaults()

        XCTAssertFalse(store.isEnabled)
        XCTAssertEqual(store.threshold, .outOfUsage)
        XCTAssertTrue(store.excludedProviderIDs.isEmpty)
        XCTAssertTrue(store.manualSnoozeUntil.isEmpty)
    }

    func testMenuBarContentBuilderFiltersSnoozedProviders() {
        let providerA = Provider(id: "a", displayName: "A", icon: .providerMark("a"))
        let providerB = Provider(id: "b", displayName: "B", icon: .providerMark("b"))
        let mA = WidgetDescriptor.percent(id: "a.m", provider: providerA, title: "M", metricLabel: "M")
        let mB = WidgetDescriptor.percent(id: "b.m", provider: providerB, title: "M", metricLabel: "M")

        let groupA = ProviderMetrics(provider: providerA, alwaysShownMetrics: [mA], expandedMetrics: [])
        let groupB = ProviderMetrics(provider: providerB, alwaysShownMetrics: [mB], expandedMetrics: [])

        let dataA = WidgetData(title: "M", icon: providerA.icon, kind: .percent, used: 50, limit: 100, displayMode: .remaining)
        let dataB = WidgetData(title: "M", icon: providerB.icon, kind: .percent, used: 50, limit: 100, displayMode: .remaining)

        // Without snooze: both appear
        let normal = MenuBarContentBuilder.build(
            groups: [groupA, groupB],
            data: { $0.id == "a.m" ? dataA : dataB }
        )
        XCTAssertEqual(normal.groups.map { $0.providerID }, ["a", "b"])

        // Snooze provider A
        let snoozed = MenuBarContentBuilder.build(
            groups: [groupA, groupB],
            snoozedProviderIDs: ["a"],
            data: { $0.id == "a.m" ? dataA : dataB }
        )
        XCTAssertEqual(snoozed.groups.map { $0.providerID }, ["b"])
    }
}

