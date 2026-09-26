import XCTest
@testable import QuotaBar

/// Menu-bar-scoped refreshes return quota meters only; the store must keep prior spend/history
/// lines so opening the panel does not flash empty token rows.
final class MenuBarSnapshotMergeTests: XCTestCase {
    func testMergingMenuBarUpdatePreservesValuesChartAndHistory() {
        let history = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-09-22", totalTokens: 15, costUSD: 0.01)
            ])
        )
        let previous = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            plan: "Plus",
            lines: [
                .progress(label: "Session", used: 10, limit: 100, format: .percent),
                .progress(label: "Weekly", used: 20, limit: 100, format: .percent),
                .values(label: "Today", values: [
                    MetricValue(number: 1_000, kind: .count, label: "tokens")
                ]),
                .chart(
                    label: "Usage Trend",
                    points: [MetricChartPoint(value: 1_000, label: "2026-09-22", valueLabel: "1k")],
                    note: "logs"
                ),
            ],
            refreshedAt: Date(timeIntervalSince1970: 1_000),
            usageHistory: history
        )
        let fresh = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            plan: "Plus",
            lines: [
                .progress(label: "Session", used: 55, limit: 100, format: .percent),
                .progress(label: "Weekly", used: 40, limit: 100, format: .percent),
                .badge(label: "Credits", text: "2 left", colorHex: "#22C55E"),
            ],
            refreshedAt: Date(timeIntervalSince1970: 2_000),
            usageHistory: nil
        )

        let merged = fresh.mergingMenuBarUpdate(over: previous)

        XCTAssertEqual(
            merged.line(label: "Session"),
            .progress(label: "Session", used: 55, limit: 100, format: .percent)
        )
        XCTAssertEqual(
            merged.line(label: "Weekly"),
            .progress(label: "Weekly", used: 40, limit: 100, format: .percent)
        )
        XCTAssertEqual(
            merged.line(label: "Credits"),
            .badge(label: "Credits", text: "2 left", colorHex: "#22C55E")
        )
        XCTAssertEqual(merged.line(label: "Today"), previous.line(label: "Today"))
        XCTAssertEqual(merged.line(label: "Usage Trend"), previous.line(label: "Usage Trend"))
        XCTAssertEqual(merged.usageHistory, history)
        XCTAssertEqual(merged.refreshedAt, fresh.refreshedAt)
    }

    func testMergingMenuBarUpdateWithNoPreviousReturnsSelf() {
        let fresh = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            lines: [.progress(label: "Session", used: 1, limit: 100, format: .percent)],
            refreshedAt: Date(timeIntervalSince1970: 3_000)
        )
        XCTAssertEqual(fresh.mergingMenuBarUpdate(over: nil), fresh)
    }

    /// Codex `localOnlySnapshot` on `.menuBar` returns no Session/Weekly meters (and often the
    /// shared "No usage data" badge). Merge must keep prior progress meters — otherwise a transient
    /// auth/API miss blanks the strip until the next successful quota fetch.
    func testMergingIncompleteMenuBarKeepsPriorProgressAndPlan() {
        let history = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-09-23", totalTokens: 9, costUSD: 0.02)
            ])
        )
        let previous = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            plan: "Plus",
            lines: [
                .progress(label: "Session", used: 33, limit: 100, format: .percent),
                .progress(label: "Weekly", used: 44, limit: 100, format: .percent),
                .badge(label: "Credits", text: "1 left", colorHex: "#22C55E"),
                .values(label: "Today", values: [
                    MetricValue(number: 9, kind: .count, label: "tokens")
                ]),
            ],
            refreshedAt: Date(timeIntervalSince1970: 1_000),
            usageHistory: history,
            warning: nil
        )
        var emptyLines: [MetricLine] = []
        MetricLine.appendNoDataIfNeeded(&emptyLines)
        let fresh = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            plan: nil,
            lines: emptyLines,
            refreshedAt: Date(timeIntervalSince1970: 2_000),
            usageHistory: nil,
            warning: "Live Codex limits unavailable: offline"
        )

        let merged = fresh.mergingMenuBarUpdate(over: previous)

        XCTAssertEqual(merged.plan, "Plus", "nil plan on incomplete menuBar must not wipe prior plan")
        XCTAssertEqual(
            merged.line(label: "Session"),
            .progress(label: "Session", used: 33, limit: 100, format: .percent)
        )
        XCTAssertEqual(
            merged.line(label: "Weekly"),
            .progress(label: "Weekly", used: 44, limit: 100, format: .percent)
        )
        XCTAssertEqual(merged.line(label: "Credits"), previous.line(label: "Credits"))
        XCTAssertEqual(merged.line(label: "Today"), previous.line(label: "Today"))
        XCTAssertEqual(merged.usageHistory, history)
        XCTAssertEqual(merged.warning, "Live Codex limits unavailable: offline")
        XCTAssertNil(merged.line(label: "Status"), "No usage data placeholder must drop once meters recovered")
        XCTAssertFalse(merged.lines.contains(MetricLine.noUsageData))
    }

    func testMergingDoesNotDuplicateTodayWhenFreshAlsoHasValues() {
        let previous = ProviderSnapshot(
            providerID: "cursor",
            displayName: "Cursor",
            lines: [
                .progress(label: "Auto", used: 10, limit: 100, format: .percent),
                .values(label: "Today", values: [
                    MetricValue(number: 1, kind: .dollars)
                ]),
            ],
            refreshedAt: Date(timeIntervalSince1970: 1_000)
        )
        let fresh = ProviderSnapshot(
            providerID: "cursor",
            displayName: "Cursor",
            lines: [
                .progress(label: "Auto", used: 20, limit: 100, format: .percent),
                .values(label: "Today", values: [
                    MetricValue(number: 99, kind: .dollars)
                ]),
            ],
            refreshedAt: Date(timeIntervalSince1970: 2_000)
        )
        let merged = fresh.mergingMenuBarUpdate(over: previous)
        let todays = merged.lines.filter { $0.label == "Today" }
        XCTAssertEqual(todays.count, 1, "label collision must not duplicate Today")
        XCTAssertEqual(todays.first, fresh.line(label: "Today"), "fresh Today must win")
    }

    func testMergingClearsWarningWhenFreshSucceeds() {
        let previous = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            lines: [.progress(label: "Session", used: 1, limit: 100, format: .percent)],
            refreshedAt: Date(timeIntervalSince1970: 1_000),
            warning: "Live Codex limits unavailable: offline"
        )
        let fresh = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            lines: [.progress(label: "Session", used: 2, limit: 100, format: .percent)],
            refreshedAt: Date(timeIntervalSince1970: 2_000),
            warning: nil
        )
        let merged = fresh.mergingMenuBarUpdate(over: previous)
        XCTAssertNil(merged.warning, "successful menuBar must clear prior warning")
        XCTAssertEqual(
            merged.line(label: "Session"),
            .progress(label: "Session", used: 2, limit: 100, format: .percent)
        )
    }

    func testFreshHistoryWinsOverPrevious() {
        let oldHistory = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-09-01", totalTokens: 1, costUSD: 0.01)
            ])
        )
        let newHistory = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-09-24", totalTokens: 50, costUSD: 0.5)
            ])
        )
        let previous = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            lines: [],
            refreshedAt: Date(timeIntervalSince1970: 1_000),
            usageHistory: oldHistory
        )
        let fresh = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            lines: [.progress(label: "Session", used: 1, limit: 100, format: .percent)],
            refreshedAt: Date(timeIntervalSince1970: 2_000),
            usageHistory: newHistory
        )
        let merged = fresh.mergingMenuBarUpdate(over: previous)
        XCTAssertEqual(merged.usageHistory, newHistory)
    }
}
