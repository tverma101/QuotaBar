import XCTest
@testable import QuotaBar

/// The dashboard's card list is `LayoutStore.displayGroups` → descriptor → resolved `WidgetData` →
/// `ProviderSectionVisibility`. A data-layer snapshot can be perfect while this path drops or merges
/// an account, so these tests exercise the exact list the `ForEach` in `WidgetGroupedListView` walks.
@MainActor
final class DashboardAccountRenderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeDefaults() -> UserDefaults {
        let name = "DashboardAccountRenderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func snapshot(
        providerID: String,
        displayName: String,
        sessionUsed: Double,
        weeklyUsed: Double
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: providerID,
            displayName: displayName,
            lines: [
                .progress(label: "Session", used: sessionUsed, limit: 100, format: .percent),
                .progress(label: "Weekly", used: weeklyUsed, limit: 100, format: .percent)
            ],
            refreshedAt: now
        )
    }

    func testBothCodexAccountCardsResolveTheirOwnRowsLabelsAndVisibility() throws {
        let defaults = makeDefaults()
        let first = CodexProvider(provider: Provider(
            id: "codex",
            displayName: "Codex — personal@example.com",
            icon: .providerMark("codex")
        ))
        let second = CodexProvider(provider: Provider(
            id: "codex@ab12cd34",
            displayName: "Codex — work@example.com",
            icon: .providerMark("codex")
        ))
        let registry = WidgetRegistry.from([first, second])

        // Mirror the production seed so the second account's own descriptors are placed, not just
        // the family's `codex.*` rows.
        let layout = LayoutStore(
            registry: registry,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: AppContainer.accountScopedDefaults(DefaultLayout.metricIDs, registry: registry),
            migrationBaselineMetricIDs: [],
            defaultPinnedMetricIDs: [],
            migrationBaselinePinnedMetricIDs: [],
            defaultExpandedMetricIDs: [],
            isProviderEnabled: { _ in true }
        )

        let cache = ProviderSnapshotCache(
            userDefaults: defaults,
            storageKey: "snapshots",
            ttl: 600,
            now: { self.now }
        )
        cache.store(snapshot(
            providerID: "codex",
            displayName: "Codex — personal@example.com",
            sessionUsed: 0,
            weeklyUsed: 57
        ))
        cache.store(snapshot(
            providerID: "codex@ab12cd34",
            displayName: "Codex — work@example.com",
            sessionUsed: 42,
            weeklyUsed: 100
        ))
        let store = WidgetDataStore(
            registry: registry,
            providers: [],
            cache: cache,
            defaults: defaults,
            now: { self.now }
        )

        // The render path must keep both providers as separate sections, in registry order and with
        // their own labels — not collapse them onto the family id.
        let groups = layout.displayGroups
        XCTAssertEqual(groups.map(\.provider.id), ["codex", "codex@ab12cd34"])
        XCTAssertEqual(
            groups.map(\.provider.displayName),
            ["Codex — personal@example.com", "Codex — work@example.com"]
        )

        var renderedLabels: [String: [String: WidgetData]] = [:]
        for group in groups {
            // Reproduce `WidgetGroupedListView.resolveRows`: descriptor, resolved data, per-row
            // visibility, then the section decision. Nothing here reads the provider's raw snapshot.
            let rows = group.widgets.compactMap { widget -> (WidgetDescriptor, WidgetData)? in
                guard let descriptor = layout.descriptor(for: widget) else { return nil }
                let data = store.data(for: descriptor)
                guard ProviderSectionVisibility.shouldRenderMetricRow(
                    providerID: descriptor.providerID,
                    descriptorID: descriptor.id,
                    hasData: data.hasData,
                    errorCategory: store.errorCategory(for: descriptor.providerID),
                    explicitlyEnabled: layout.explicitlyEnabledMetricIDs.contains(descriptor.id)
                ), layout.showsRow(descriptor, hasData: data.hasData) else {
                    return nil
                }
                return (descriptor, data)
            }
            XCTAssertFalse(rows.isEmpty, "\(group.provider.id) must keep at least one visible row")
            XCTAssertTrue(
                ProviderSectionVisibility.shouldRender(
                    hasVisibleMetric: !rows.isEmpty,
                    hasPlan: store.plan(for: group.provider.id) != nil,
                    hasNotice: store.headerNotice(for: group.provider.id) != nil,
                    isRefreshing: store.refreshingProviderIDs.contains(group.provider.id),
                    hasStaleness: store.stalenessHint(for: group.provider.id) != nil
                ),
                "\(group.provider.id) must render its section"
            )
            renderedLabels[group.provider.id] = Dictionary(
                uniqueKeysWithValues: rows.map { ($0.0.metricLabel, $0.1) }
            )
        }

        let personal = try XCTUnwrap(renderedLabels["codex"])
        let work = try XCTUnwrap(renderedLabels["codex@ab12cd34"])

        // A zero-usage session window is data, not "No data": it must keep its row and read 0.
        XCTAssertEqual(personal["Session"]?.used, 0)
        XCTAssertEqual(personal["Session"]?.hasData, true)
        XCTAssertEqual(personal["Session"]?.limit, 100)
        XCTAssertEqual(personal["Weekly"]?.used, 57)
        XCTAssertEqual(
            try XCTUnwrap(personal["Weekly"]?.remainingFraction),
            0.43,
            accuracy: 0.0001
        )

        // The second account's rows carry its own numbers, never the first account's.
        XCTAssertEqual(work["Session"]?.used, 42)
        XCTAssertEqual(work["Session"]?.hasData, true)
        XCTAssertEqual(work["Weekly"]?.used, 100)
        XCTAssertEqual(try XCTUnwrap(work["Weekly"]?.remainingFraction), 0, accuracy: 0.0001)
        XCTAssertNotEqual(personal["Weekly"]?.used, work["Weekly"]?.used)

        // Labels come from each card's own descriptors, not a shared family label.
        XCTAssertEqual(personal["Session"]?.title, "Session")
        XCTAssertEqual(work["Session"]?.title, "Session")
    }
}
