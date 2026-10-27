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

    func testTrayLabelsShortenLongTimeWindows() {
        let content = MenuBarContentBuilder.build(
            groups: [group("a", percent("a.today", "Today", 5), percent("a.month", "Last 30 Days", 80))],
            data: { $0.sample }
        )
        XCTAssertEqual(content.groups[0].metrics.map(\.trayLabel), ["T", "M"])
        // The full name survives for accessibility — a screen reader must not read out "M 80%".
        XCTAssertEqual(content.groups[0].metrics.map(\.label), ["Today", "Last 30 Days"])
    }

    /// Freebuff's hour meters are the pair that exposed the unreadable strip: a bare "13" beside a
    /// bare "20" with a dot for a provider mark. Each metric now carries a short window label, and
    /// the hour unit rides the value so "20" cannot be mistaken for tokens, a percent, or a session.
    func testFreebuffHoursPairReadsAsLabeledHourBudgets() {
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
        XCTAssertEqual(metrics.map(\.trayLabel), ["Day", "Bal"])
        XCTAssertEqual(metrics.map(\.value), ["13h", "35h"])
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
