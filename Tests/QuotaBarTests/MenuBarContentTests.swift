import XCTest
@testable import QuotaBar

/// Covers `MenuBarContentBuilder`: it resolves pinned provider groups into Text groups (order, labels,
/// and values preserved) and Bars entries (bounded metrics only, first four in order), and reports empty
/// when nothing is pinned.
@MainActor
final class MenuBarContentTests: XCTestCase {
    func testEmptyWhenNoGroups() {
        let content = MenuBarContentBuilder.build(groups: [], data: { $0.sample })
        XCTAssertTrue(content.isEmpty)
        XCTAssertTrue(content.bars.isEmpty)
    }

    func testTextGroupsPreserveOrderLabelsAndValues() {
        let m1 = percent("a.m1", "Session", 97)
        let m2 = percent("a.m2", "Weekly", 12)
        let b1 = percent("b.m1", "Total", 50)
        let content = MenuBarContentBuilder.build(groups: [group("a", m1, m2), group("b", b1)], data: { $0.sample })

        XCTAssertEqual(content.groups.map(\.providerID), ["a", "b"])
        XCTAssertEqual(content.groups[0].metrics.map(\.id), ["a.m1", "a.m2"])
        XCTAssertEqual(content.groups[0].metrics[0].label, "Session")
        XCTAssertEqual(content.groups[0].metrics[0].value, m1.sample.valueText)
        XCTAssertEqual(content.groups[1].metrics.map(\.id), ["b.m1"])
    }

    func testMenuBarContentCanRepresentMultipleCodexCards() {
        let first = group("codex", percent("codex.session", "Session", 15))
        let second = group(
            "codex@0577ce6e",
            percent("codex@0577ce6e.session", "Session", 85)
        )
        let cursor = group("cursor", percent("cursor.models", "Models", 30))

        let content = MenuBarContentBuilder.build(groups: [first, second, cursor], data: { $0.sample })

        XCTAssertEqual(content.groups.map(\.providerID), ["codex", "codex@0577ce6e", "cursor"])
        XCTAssertFalse(content.isEmpty)
        XCTAssertNotNil(MenuBarStripRenderer.image(for: content, style: .text))
    }

    func testMultipleCodexAccountsUseOneAggregateStatusItem() {
        XCTAssertEqual(StatusItemController.statusItemScopes(), [nil])
    }

    func testBarsIncludeBoundedMetricsAndDropUnbounded() {
        // A bounded dollar metric has a fill, so it belongs in Bars. An unbounded value (raw spend,
        // no limit) has no fill and is dropped.
        let content = MenuBarContentBuilder.build(
            groups: [group("a",
                percent("a.pct", "Pct", 40),
                boundedDollars("a.credits", "Credits", used: 12000, limit: 18000),
                unbounded("a.spend", "Spend"))],
            data: { $0.sample }
        )

        XCTAssertEqual(content.groups[0].metrics.map(\.id), ["a.pct", "a.credits", "a.spend"])  // Text: all
        XCTAssertEqual(content.bars.map(\.id), ["a.pct", "a.credits"])                          // Bars: bounded only
    }

    func testBarsCappedToFourInOrder() {
        let content = MenuBarContentBuilder.build(
            groups: [
                group("a", percent("a.m1", "M1", 10), percent("a.m2", "M2", 20)),
                group("b", percent("b.m1", "M1", 30), percent("b.m2", "M2", 40)),
                group("c", percent("c.m1", "M1", 50), percent("c.m2", "M2", 60))
            ],
            data: { $0.sample }
        )

        XCTAssertEqual(content.bars.count, 4)
        XCTAssertEqual(content.bars.map(\.id), ["a.m1", "a.m2", "b.m1", "b.m2"])
    }

    func testNoDataMetricsDropFromStrip() {
        // The strip is dynamic: a pinned metric without data vanishes instead of rendering "—", and
        // the surviving pin renders alone (full size). A provider whose pins all lack data
        // contributes no icon at all.
        let content = MenuBarContentBuilder.build(
            groups: [
                group("a", percent("a.live", "Session", 41), noDataPercent("a.dark", "Weekly")),
                group("b", noDataPercent("b.nd", "ND"))
            ],
            data: { $0.sample }
        )

        XCTAssertEqual(content.groups.map(\.providerID), ["a"])
        XCTAssertEqual(content.groups[0].metrics.map(\.id), ["a.live"])
        XCTAssertEqual(content.bars.map(\.id), ["a.live"])
    }

    func testAllPinsWithoutDataFallBackToAppIcon() {
        let content = MenuBarContentBuilder.build(
            groups: [group("a", noDataPercent("a.nd", "ND"))],
            data: { $0.sample }
        )
        XCTAssertTrue(content.isEmpty)
    }

    func testAccessibilityTextSummarizesGroups() {
        let content = MenuBarContentBuilder.build(
            groups: [group("a", percent("a.m1", "Session", 41), percent("a.m2", "Weekly", 12))],
            data: { $0.sample }
        )
        XCTAssertEqual(content.accessibilityText, "A Session 41%, Weekly 12%")
    }

    func testTrayLabelsAreNotDrawnBesideStackedValues() {
        let content = MenuBarContentBuilder.build(
            groups: [group("a", percent("a.today", "Today", 5), percent("a.month", "Last 30 Days", 80))],
            data: { $0.sample }
        )
        // The strip shows values only and reads positionally — adding a word to every stacked pair
        // made an always-clear "87% / 32%" read "Session 87% / Wk 32%". The full name still survives
        // for accessibility, because a screen reader has no positional context to fall back on.
        XCTAssertEqual(content.groups[0].metrics.map(\.label), ["Today", "Last 30 Days"])
        XCTAssertEqual(content.groups[0].metrics.map(\.value), ["5%", "80%"])
    }

    /// Freebuff's hour meters are the pair that exposed the unreadable strip: a bare "13" beside a
    /// bare "20" with a dot for a provider mark. The fix is the hour unit on each value, not a label —
    /// "13h / 35h" is unambiguous on its own, so the strip stays as terse as it is for percentages.
    func testFreebuffHoursPairReadsAsHourBudgetsWithoutLabels() {
        let provider = Provider(
            id: "freebuff", displayName: "Freebuff", icon: .providerMark("freebuff")
        )
        let daily = WidgetDescriptor.boundedCount(
            id: "freebuff.freebucksDaily", provider: provider, title: "Daily Hours",
            limit: 1, suffix: "hours"
        )
        let balance = WidgetDescriptor.values(
            id: "freebuff.freebucksBalance", provider: provider, title: "Hours Balance",
            selection: .kind(.count)
        )
        let content = MenuBarContentBuilder.build(
            groups: [group("freebuff", daily, balance)],
            data: { descriptor in
                if descriptor.id == "freebuff.freebucksDaily" {
                    // 13 of 33 hours left, matching the meter style this build defaults to.
                    return WidgetData(
                        title: "Daily Hours", icon: provider.icon, kind: .count,
                        used: 20, limit: 33, countSuffix: "hours", displayMode: .remaining
                    )
                }
                var sample = descriptor.sample
                sample.values = [MetricValue(number: 35, kind: .count, label: "hours")]
                return sample
            }
        )

        let metrics = content.groups.first?.metrics ?? []
        XCTAssertEqual(metrics.count, 2, "both hour meters render, so the strip stacks the pair")
        XCTAssertEqual(metrics.map(\.value), ["13h", "35h"])
    }

    /// Freebuff's pinned segment is the active session clock, not an allowance figure: hours and
    /// minutes until the window resets. The hour unit still rides a non-timer hour row so a count is
    /// never an unlabeled number, but the timer segment itself is a duration.
    func testFreebuffDailyHoursReadsAsASessionCountdownInTheStrip() {
        let provider = Provider(
            id: "freebuff", displayName: "Freebuff", icon: .providerMark("freebuff")
        )
        let daily = WidgetDescriptor.boundedCount(
            id: "freebuff.freebucksDaily", provider: provider, title: "Daily Hours",
            limit: 1, suffix: "hours", periodDurationMs: MetricPeriod.dayMs
        ).showingResetTimerInMenuBar()

        // Built through the descriptor, exactly as the store does after a `.progress` line resolves.
        var timer = WidgetData(
            title: "Daily Hours", icon: provider.icon, kind: .count,
            used: 18, limit: 33, countSuffix: "hours", displayMode: .remaining,
            resetsAt: Date().addingTimeInterval(2 * 3600 + 14 * 60)
        )
        timer.trayStyle = daily.sample.trayStyle
        XCTAssertEqual(daily.sample.trayStyle, .resetCountdown, "the opt-in must reach the sample")

        let balance = WidgetDescriptor.values(
            id: "freebuff.freebucksBalance", provider: provider, title: "Hours Balance",
            selection: .kind(.count)
        )
        var balanceData = balance.sample
        balanceData.values = [MetricValue(number: 30, kind: .count, label: "hours")]

        let content = MenuBarContentBuilder.build(
            groups: [group("freebuff", daily, balance)],
            data: { $0.id == daily.id ? timer : balanceData }
        )

        let metrics = content.groups.first?.metrics ?? []
        XCTAssertEqual(metrics.count, 2)
        // Timer: hours and minutes, no allowance unit, no label word.
        XCTAssertTrue(metrics[0].value.hasSuffix("m"), "expected a minute-granular countdown, got \(metrics[0].value)")
        XCTAssertTrue(metrics[0].value.contains("h"), "expected hours in the countdown, got \(metrics[0].value)")
        XCTAssertFalse(metrics[0].value.hasSuffix("h"), "a bare hour count is the allowance, not a timer")
        // Non-timer hour row keeps its unit.
        XCTAssertEqual(metrics[1].value, "30h")
    }

    /// A timer row with no reset instant (a stale snapshot, or a server that reported no window) must
    /// fall back to its ordinary value rather than rendering an empty segment.
    func testTimerRowWithoutAResetInstantFallsBackToItsValue() {
        var data = WidgetData(
            title: "Daily Hours", icon: .providerMark("freebuff"), kind: .count,
            used: 18, limit: 33, countSuffix: "hours", displayMode: .remaining
        )
        data.trayStyle = .resetCountdown

        XCTAssertNil(data.resetsAt)
        XCTAssertEqual(data.menuBarValue, "15h")
    }

    /// A session timer has nothing to say when no session is running, and the strip is contested
    /// space: with no usage in the window the Freebuff segment drops out entirely, icon included.
    /// Any usage brings it back, so the timer is a live session clock rather than a permanent label.
    func testIdleSessionTimerDropsOutOfTheStripEntirely() {
        let provider = Provider(id: "freebuff", displayName: "Freebuff", icon: .providerMark("freebuff"))
        let daily = WidgetDescriptor.boundedCount(
            id: "freebuff.freebucksDaily", provider: provider, title: "Daily Hours",
            limit: 1, suffix: "hours", periodDurationMs: MetricPeriod.dayMs
        ).showingResetTimerInMenuBar()

        func timer(used: Double, resetsAt: Date?) -> WidgetData {
            var data = WidgetData(
                title: "Daily Hours", icon: provider.icon, kind: .count,
                used: used, limit: 33, countSuffix: "hours", displayMode: .remaining,
                resetsAt: resetsAt
            )
            data.trayStyle = .resetCountdown
            return data
        }
        let future = Date().addingTimeInterval(3 * 3600 + 14 * 60)

        // Idle window: nothing spent, so nothing to count down.
        let idle = MenuBarContentBuilder.build(
            groups: [group("freebuff", daily)],
            data: { _ in timer(used: 0, resetsAt: future) }
        )
        XCTAssertTrue(idle.isEmpty, "an idle session must not occupy menu-bar space")
        XCTAssertNil(MenuBarStripRenderer.image(for: idle, style: .text))

        // Active window: the timer returns.
        let active = MenuBarContentBuilder.build(
            groups: [group("freebuff", daily)],
            data: { _ in timer(used: 4, resetsAt: future) }
        )
        XCTAssertEqual(active.groups.count, 1)
        XCTAssertTrue(active.groups[0].metrics[0].value.hasSuffix("m"))
    }

    /// A non-timer row keeps showing whatever its value is — a zero balance or an exhausted meter is
    /// information, and only a session clock is meaningless while idle.
    func testNonTimerRowsStillShowAtZero() {
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let credits = WidgetDescriptor.values(
            id: "codex.credits", provider: provider, title: "Credits"
        )
        var data = credits.sample
        data.values = [MetricValue(number: 0, kind: .dollars)]
        let content = MenuBarContentBuilder.build(
            groups: [group("codex", credits)],
            data: { _ in data }
        )
        XCTAssertEqual(content.groups.count, 1, "a zero balance is still worth showing")
    }

    func testUnboundedCountKeepsItsUnitInTheTray() {
        let balance = WidgetData(
            title: "Hours Balance", icon: .providerMark("freebuff"), kind: .count, used: 0, limit: nil,
            values: [MetricValue(number: 35, kind: .count, label: "hours")]
        )
        XCTAssertEqual(balance.menuBarValue, "35h")

        // Units that would abbreviate ambiguously stay bare: "sessions" must never read as "s".
        let sessions = WidgetData(
            title: "Sessions", icon: .providerMark("freebuff"), kind: .count, used: 3, limit: 5,
            countSuffix: "sessions"
        )
        XCTAssertEqual(sessions.menuBarValue, "3")
        XCTAssertNil(WidgetData.trayUnit("sessions"))
        XCTAssertEqual(WidgetData.trayUnit("hours"), "h")
    }

    func testBoundedTrayValuesStayUnitAware() {
        // Percent meters still read as percentages, while bounded dollars/counts keep their natural
        // unit in the strip instead of collapsing to "used / limit" percentages.
        let usage = percent("a.usage", "Usage", 67)
        let credits = boundedDollars("a.credits", "Credits", used: 12000, limit: 18000)
        let requests = boundedCount("a.requests", "Requests", used: 412, limit: 500)
        let spend = unbounded("a.spend", "Spend")   // unbounded $42
        let content = MenuBarContentBuilder.build(groups: [group("a", usage, credits, requests, spend)], data: { $0.sample })

        XCTAssertEqual(content.groups[0].metrics.map(\.value), ["67%", "$12K", "412", "$42"])
    }

    // Compact-notation rules for tray values (abbreviation, decimal rounding) are pinned exactly in
    // MetricFormatterTests — the strip only relays MetricFormatter output.
    // MARK: - Fixtures

    private func group(_ providerID: String, _ metrics: WidgetDescriptor...) -> ProviderMetrics {
        let provider = Provider(
            id: providerID,
            displayName: providerID.uppercased(),
            icon: .providerMark("cursor")
        )
        return ProviderMetrics(provider: provider, metrics: metrics)
    }
    private func percent(_ id: String, _ label: String, _ used: Double) -> WidgetDescriptor {
        descriptor(id, label, WidgetData(title: label, icon: .providerMark("cursor"), kind: .percent, used: used, limit: 100))
    }

    private func boundedDollars(_ id: String, _ label: String, used: Double, limit: Double) -> WidgetDescriptor {
        descriptor(id, label, WidgetData(title: label, icon: .providerMark("cursor"), kind: .dollars, used: used, limit: limit))
    }

    private func boundedCount(_ id: String, _ label: String, used: Double, limit: Double) -> WidgetDescriptor {
        descriptor(id, label, WidgetData(title: label, icon: .providerMark("cursor"), kind: .count, used: used, limit: limit))
    }

    private func unbounded(_ id: String, _ label: String, _ used: Double = 42) -> WidgetDescriptor {
        descriptor(id, label, WidgetData(title: label, icon: .providerMark("cursor"), kind: .dollars, used: used, limit: nil))
    }

    private func noDataPercent(_ id: String, _ label: String) -> WidgetDescriptor {
        var sample = WidgetData(title: label, icon: .providerMark("cursor"), kind: .percent, used: 0, limit: 100)
        sample.hasData = false
        return descriptor(id, label, sample)
    }

    private func descriptor(_ id: String, _ label: String, _ sample: WidgetData) -> WidgetDescriptor {
        WidgetDescriptor(
            id: id,
            providerID: String(id.prefix { $0 != "." }),
            metricLabel: label,
            sample: sample
        )
    }
}
