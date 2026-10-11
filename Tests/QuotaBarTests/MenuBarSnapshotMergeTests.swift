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

    /// A day-labeled spend tile computed before local midnight must not ride along under the merged
    /// snapshot's fresh timestamp: the merge re-stamps `refreshedAt`, so a preserved "Today" line
    /// from yesterday would read as current until the next `.full` pass. The day-rollover pass
    /// rebuilds the tile; until then the stale line is dropped rather than mislabeled as fresh.
    func testMergingMenuBarUpdateDropsPriorDaySpendTiles() {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!
        let previous = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            lines: [
                .values(label: "Today", values: [
                    MetricValue(number: 1_000, kind: .count, label: "tokens")
                ]),
                .values(label: "Yesterday", values: [
                    MetricValue(number: 500, kind: .count, label: "tokens")
                ]),
                .chart(
                    label: "Usage Trend",
                    points: [MetricChartPoint(value: 1_000, label: "2026-09-22", valueLabel: "1k")],
                    note: "logs"
                ),
            ],
            refreshedAt: yesterday,
            usageHistory: nil
        )
        let fresh = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            lines: [.progress(label: "Session", used: 55, limit: 100, format: .percent)],
            refreshedAt: Date()
        )

        let merged = fresh.mergingMenuBarUpdate(over: previous)

        XCTAssertNil(merged.line(label: "Today"), "yesterday's Today tile must not read as current")
        XCTAssertNil(merged.line(label: "Yesterday"), "a two-day-old Yesterday tile must not survive")
        XCTAssertEqual(merged.line(label: "Usage Trend"), previous.line(label: "Usage Trend"),
                       "non-day-labeled lines still merge across midnight")
        XCTAssertEqual(merged.line(label: "Session"), fresh.line(label: "Session"))
    }

    func testMergingMenuBarUpdateWithNoPreviousReturnsSelf() {        let fresh = ProviderSnapshot(
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

    func testExplicitQuotaInvalidationClearsPlanAndProgressButKeepsSpend() {
        let history = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-09-23", totalTokens: 9, costUSD: 0.02)
            ])
        )
        let previous = ProviderSnapshot(
            providerID: "opencode",
            displayName: "OpenCode",
            plan: "Go",
            lines: [
                .progress(label: "Session", used: 33, limit: 100, format: .percent),
                .progress(label: "Weekly", used: 44, limit: 100, format: .percent),
                .values(label: "Today", values: [
                    MetricValue(number: 9, kind: .count, label: "tokens")
                ]),
            ],
            refreshedAt: Date(timeIntervalSince1970: 1_000),
            usageHistory: history
        )
        let fresh = ProviderSnapshot(
            providerID: "opencode",
            displayName: "OpenCode",
            lines: [.noUsageData],
            refreshedAt: Date(timeIntervalSince1970: 2_000),
            warning: "OpenCode couldn't confirm a Go subscription for this key.",
            clearsPriorMenuBarQuotaState: true
        )

        let merged = fresh.mergingMenuBarUpdate(over: previous)

        XCTAssertNil(merged.plan)
        XCTAssertNil(merged.line(label: "Session"))
        XCTAssertNil(merged.line(label: "Weekly"))
        XCTAssertEqual(merged.line(label: "Today"), previous.line(label: "Today"))
        XCTAssertEqual(merged.usageHistory, history)
        XCTAssertNil(merged.clearsPriorMenuBarQuotaState)
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

    // MARK: - carriesPriorHistory (full passes must recompute menu-bar-carried history)

    /// A menu-bar merge that preserved prior history must mark the result as carried, so the next
    /// full pass re-runs the deferred fold instead of cache-hitting forever (menu-bar ticks re-stamp
    /// `refreshedAt` every TTL, which would otherwise starve the recompute permanently).
    func testMenuBarMergeMarksCarriedHistory() {
        let previous = ProviderSnapshot(
            providerID: "cursor",
            displayName: "Cursor",
            lines: [.values(label: "Today", values: [
                MetricValue(number: 5, kind: .dollars, label: "spend")
            ])],
            refreshedAt: Date(timeIntervalSince1970: 1_000),
            usageHistory: ProviderUsageHistory(
                series: DailyUsageSeries(daily: [
                    DailyUsageEntry(date: "2026-10-04", totalTokens: 10, costUSD: 0.02)
                ])
            )
        )
        let fresh = ProviderSnapshot(
            providerID: "cursor",
            displayName: "Cursor",
            lines: [.progress(label: "Total usage", used: 5, limit: 100, format: .percent)],
            refreshedAt: Date(timeIntervalSince1970: 2_000),
            usageHistory: nil
        )

        let merged = fresh.mergingMenuBarUpdate(over: previous)

        XCTAssertEqual(merged.carriesPriorHistory, true)
        XCTAssertNotNil(merged.usageHistory)
    }

    /// A merge with no prior history to preserve must not claim carried history — meter-only
    /// providers would otherwise re-run in every full pass for nothing.
    func testMenuBarMergeWithoutPriorHistoryLeavesCarriedFlagNil() {
        let previous = ProviderSnapshot(
            providerID: "cursor",
            displayName: "Cursor",
            lines: [.progress(label: "Total usage", used: 5, limit: 100, format: .percent)],
            refreshedAt: Date(timeIntervalSince1970: 1_000),
            usageHistory: nil
        )
        let fresh = ProviderSnapshot(
            providerID: "cursor",
            displayName: "Cursor",
            lines: [.progress(label: "Total usage", used: 6, limit: 100, format: .percent)],
            refreshedAt: Date(timeIntervalSince1970: 2_000),
            usageHistory: nil
        )

        let merged = fresh.mergingMenuBarUpdate(over: previous)

        XCTAssertNil(merged.carriesPriorHistory)
    }

    /// History computed by this refresh (a real full fold) is not carried — the flag must clear so
    /// subsequent full passes can honor the TTL again.
    func testFreshHistoryClearsCarriedFlag() {
        let previous = ProviderSnapshot(
            providerID: "cursor",
            displayName: "Cursor",
            lines: [],
            refreshedAt: Date(timeIntervalSince1970: 1_000),
            usageHistory: ProviderUsageHistory(
                series: DailyUsageSeries(daily: [
                    DailyUsageEntry(date: "2026-10-04", totalTokens: 10, costUSD: 0.02)
                ])
            ),
            carriesPriorHistory: true
        )
        let fresh = ProviderSnapshot(
            providerID: "cursor",
            displayName: "Cursor",
            lines: [.progress(label: "Total usage", used: 7, limit: 100, format: .percent)],
            refreshedAt: Date(timeIntervalSince1970: 2_000),
            usageHistory: ProviderUsageHistory(
                series: DailyUsageSeries(daily: [
                    DailyUsageEntry(date: "2026-10-05", totalTokens: 99, costUSD: 0.2)
                ])
            )
        )

        let merged = fresh.mergingMenuBarUpdate(over: previous)

        XCTAssertEqual(merged.usageHistory?.series.daily.first?.date, "2026-10-05")
        XCTAssertNil(merged.carriesPriorHistory)
    }

    /// The marker must survive the JSON round-trip through the persisted snapshot cache, so the
    /// gate works across the cache's decode path (old blobs without the key decode as nil).
    func testCarriedHistoryFlagSurvivesCacheRoundTrip() throws {
        let snapshot = ProviderSnapshot(
            providerID: "cursor",
            displayName: "Cursor",
            lines: [.progress(label: "Total usage", used: 5, limit: 100, format: .percent)],
            refreshedAt: Date(timeIntervalSince1970: 1_000),
            usageHistory: ProviderUsageHistory(series: DailyUsageSeries(daily: [])),
            carriesPriorHistory: true
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ProviderSnapshot.self, from: data)
        XCTAssertEqual(decoded.carriesPriorHistory, true)

        let legacyJSON = """
        {"providerID":"cursor","displayName":"Cursor","lines":[],"refreshedAt":1000.0}
        """
        let legacy = try JSONDecoder().decode(ProviderSnapshot.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(legacy.carriesPriorHistory)
    }

    // MARK: - quotaRefreshedAt (meters' freshness must not be re-vouched by fold-only passes)

    /// A fold-only pass (`.localAccounting` / `.panelAccounting`) produces a snapshot whose history
    /// is fresh but whose meters were recovered by the merge. The merged snapshot must carry the
    /// PRIOR meters' freshness stamp — stamping the merge's own clock would let every closed-panel
    /// ledger wake keep hours-old subscription meters TTL-fresh forever, and panel-open passes
    /// would cache-hit instead of re-reading the live quota API (the "meter % never updates" bug).
    func testFoldOnlyMergeCarriesMetersStampNotFreshClock() {
        let meterStamp = Date(timeIntervalSince1970: 1_000)
        let previous = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            plan: "Plus",
            lines: [
                .progress(label: "Session", used: 33, limit: 100, format: .percent),
                .values(label: "Today", values: [
                    MetricValue(number: 9, kind: .count, label: "tokens")
                ]),
            ],
            refreshedAt: meterStamp,
            usageHistory: nil
        )
        XCTAssertEqual(previous.quotaRefreshedAt, meterStamp)
        let fresh = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            plan: nil,
            lines: [],
            refreshedAt: Date(timeIntervalSince1970: 2_000),
            usageHistory: ProviderUsageHistory(
                series: DailyUsageSeries(daily: [
                    DailyUsageEntry(date: "2026-10-11", totalTokens: 90, costUSD: 0.3)
                ])
            )
        )

        let merged = fresh.mergingMenuBarUpdate(over: previous)

        XCTAssertEqual(merged.quotaRefreshedAt, meterStamp,
                       "recovered meters keep the prior meter stamp, not the merge clock")
        XCTAssertEqual(merged.refreshedAt, fresh.refreshedAt,
                       "the fold's own work still stamps refreshedAt")
    }

    /// A pass that produced live quota meters (menuBar / panelMeters) owns a fresh meter stamp —
    /// the merge must not drag an older one forward.
    func testMeterProducingMergeKeepsFreshMeterStamp() {
        let previous = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            lines: [.progress(label: "Session", used: 33, limit: 100, format: .percent)],
            refreshedAt: Date(timeIntervalSince1970: 1_000)
        )
        let freshStamp = Date(timeIntervalSince1970: 2_000)
        let fresh = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            lines: [.progress(label: "Session", used: 44, limit: 100, format: .percent)],
            refreshedAt: freshStamp
        )

        let merged = fresh.mergingMenuBarUpdate(over: previous)

        XCTAssertEqual(merged.quotaRefreshedAt, freshStamp)
    }

    /// Merged snapshots preserve prior day-labeled spend tiles only within the same local day; the
    /// recovered meters' stamp must behave the same way for a snapshot whose fresh pass wrote fresh
    /// history but no meters — the stamp comes from `previous`, whatever era it names.
    func testFoldOnlyMergePrefersPreviousQuotaStampOverPreviousRefreshedAt() {
        // The prior snapshot's meters were answered by the live API at 1_000 but a later menu-bar
        // merge re-stamped refreshedAt to 1_500. A fold-only pass at 2_000 must recover the METER
        // stamp (1_000), not the most recent re-stamp.
        var previous = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            plan: "Plus",
            lines: [
                .progress(label: "Session", used: 33, limit: 100, format: .percent),
                .values(label: "Today", values: [
                    MetricValue(number: 9, kind: .count, label: "tokens")
                ]),
            ],
            refreshedAt: Date(timeIntervalSince1970: 1_000)
        )
        previous.quotaRefreshedAt = Date(timeIntervalSince1970: 1_000)
        previous.refreshedAt = Date(timeIntervalSince1970: 1_500)
        let fresh = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            lines: [],
            refreshedAt: Date(timeIntervalSince1970: 2_000),
            usageHistory: ProviderUsageHistory(series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-10-11", totalTokens: 90, costUSD: 0.3)
            ]))
        )

        let merged = fresh.mergingMenuBarUpdate(over: previous)

        XCTAssertEqual(merged.quotaRefreshedAt, Date(timeIntervalSince1970: 1_000))
    }

    /// A provider whose snapshot never carries `.progress` meters (Hermes's always-full refresh, a
    /// meterless plan) must not inherit a carried stamp: the fold work in a fold-only pass IS fresh,
    /// and a carried never-refreshing stamp would make it cache-miss on every pass.
    func testMeterlessPreviousKeepsFreshStamp() {
        let previous = ProviderSnapshot(
            providerID: "hermes",
            displayName: "Hermes",
            lines: [.values(label: "Today", values: [
                MetricValue(number: 9, kind: .count, label: "tokens")
            ])],
            refreshedAt: Date(timeIntervalSince1970: 1_000),
            usageHistory: ProviderUsageHistory(series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-10-10", totalTokens: 5, costUSD: 0.01)
            ]))
        )
        XCTAssertNil(previous.line(label: "Session"))
        let freshStamp = Date(timeIntervalSince1970: 2_000)
        let fresh = ProviderSnapshot(
            providerID: "hermes",
            displayName: "Hermes",
            lines: [.values(label: "Today", values: [
                MetricValue(number: 10, kind: .count, label: "tokens")
            ])],
            refreshedAt: freshStamp,
            usageHistory: ProviderUsageHistory(series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-10-11", totalTokens: 6, costUSD: 0.02)
            ]))
        )

        let merged = fresh.mergingMenuBarUpdate(over: previous)

        XCTAssertEqual(merged.quotaRefreshedAt, freshStamp,
                       "no meters on either side — the fold's own stamp governs")
    }

    /// A fold-only pass's fresh success says nothing about the recovered meters' condition, so the
    /// prior warning travels WITH the recovered meters (the user keeps the "limits unavailable"
    /// triangle until a pass that produces its own meters succeeds). An explicit quota invalidation
    /// replaces the state wholesale — warning included.
    func testFoldOnlyMergeCarriesMetersWarning() {
        let warning = "Live Codex limits unavailable: offline"
        let previous = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            plan: "Plus",
            lines: [.progress(label: "Session", used: 33, limit: 100, format: .percent)],
            refreshedAt: Date(timeIntervalSince1970: 1_000),
            warning: warning
        )
        let fresh = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            lines: [],
            refreshedAt: Date(timeIntervalSince1970: 2_000),
            usageHistory: ProviderUsageHistory(series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-10-11", totalTokens: 90, costUSD: 0.3)
            ]))
        )

        let merged = fresh.mergingMenuBarUpdate(over: previous)

        XCTAssertEqual(merged.warning, warning, "recovered meters keep their caveat")
        XCTAssertEqual(merged.line(label: "Session"), previous.line(label: "Session"))
    }

    func testInvalidationDoesNotCarryMetersWarning() {
        let previous = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            plan: "Plus",
            lines: [.progress(label: "Session", used: 33, limit: 100, format: .percent)],
            refreshedAt: Date(timeIntervalSince1970: 1_000),
            warning: "Live Codex limits unavailable: offline"
        )
        let fresh = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            lines: [.noUsageData],
            refreshedAt: Date(timeIntervalSince1970: 2_000),
            clearsPriorMenuBarQuotaState: true
        )

        let merged = fresh.mergingMenuBarUpdate(over: previous)

        XCTAssertNil(merged.warning, "explicit invalidation replaces the meters' state wholesale")
    }

    /// The meter stamp must survive the JSON round-trip through the persisted snapshot cache, and
    /// a legacy payload without the key must decode as nil (the cache then falls back to
    /// `refreshedAt` — today's behavior for pre-upgrade blobs).
    func testQuotaStampSurvivesCacheRoundTrip() throws {
        var snapshot = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            lines: [.progress(label: "Session", used: 5, limit: 100, format: .percent)],
            refreshedAt: Date(timeIntervalSince1970: 2_000)
        )
        snapshot.quotaRefreshedAt = Date(timeIntervalSince1970: 1_000)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ProviderSnapshot.self, from: data)
        XCTAssertEqual(decoded.quotaRefreshedAt, Date(timeIntervalSince1970: 1_000))

        let legacyJSON = """
        {"providerID":"codex","displayName":"Codex","lines":[],"refreshedAt":2000.0}
        """
        let legacy = try JSONDecoder().decode(ProviderSnapshot.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(legacy.quotaRefreshedAt)
    }
}
