import XCTest
@testable import QuotaBar

/// The experimental TPS rows seeded for one launch (2026-11-16) must be retracted exactly once: the
/// feature now lives in the Total Spend panel's TPS lens, never as a dashboard card. Existing
/// layouts keep everything else untouched.
@MainActor
final class LayoutTpsRetractionTests: XCTestCase {
    private let tpsIDs = ["tps.overall", "tps.claude", "tps.codex"]

    private func tpsRegistry() -> WidgetRegistry {
        let tps = Provider(id: "tps", displayName: "TPS Tracker", icon: .providerMark("tps"))
        let tpsDescriptors = [
            WidgetDescriptor(
                id: "tps.overall", providerID: "tps", metricLabel: "Est. TPS",
                sample: WidgetData(title: "Est. TPS", icon: tps.icon, kind: .count, used: 0, limit: nil)
            ),
            WidgetDescriptor(
                id: "tps.claude", providerID: "tps", metricLabel: "Claude",
                sample: WidgetData(title: "Claude", icon: tps.icon, kind: .count, used: 0, limit: nil)
            ),
            WidgetDescriptor(
                id: "tps.codex", providerID: "tps", metricLabel: "Codex",
                sample: WidgetData(title: "Codex", icon: tps.icon, kind: .count, used: 0, limit: nil)
            )
        ]
        return WidgetRegistry(
            providers: MockData.providers + [tps],
            descriptors: MockData.descriptors + tpsDescriptors
        )
    }

    private func saveStored<T: Encodable>(_ value: T, forKey key: String, in defaults: UserDefaults) {
        defaults.set(try! JSONEncoder().encode(value), forKey: key)
    }

    private func makeDefaults() -> (defaults: UserDefaults, suite: String) {
        let suite = "LayoutTpsRetractionTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    func testSeededTPSRowsAreRetractedExactlyOnce() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        saveStored(
            [
                PlacedWidget(descriptorID: "claude.session"),
                PlacedWidget(descriptorID: "tps.overall"),
                PlacedWidget(descriptorID: "tps.claude"),
                PlacedWidget(descriptorID: "tps.codex"),
                PlacedWidget(descriptorID: "claude.weekly")
            ],
            forKey: "layout",
            in: defaults
        )
        defaults.set(["tps.claude", "claude.weekly"], forKey: "layout.expandedMetrics")
        defaults.set(["claude.session", "tps.overall"], forKey: "layout.menuBarPins")
        defaults.set(try! JSONEncoder().encode(["claude.session", "tps.overall"]), forKey: "layout.seededDefaults")

        let reloaded = LayoutStore(
            registry: tpsRegistry(),
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session"],
            migrationBaselineMetricIDs: ["claude.session"]
        )

        XCTAssertFalse(reloaded.placed.contains { tpsIDs.contains($0.descriptorID) }, "TPS rows out of dashboards")
        XCTAssertEqual(reloaded.placed.map(\.descriptorID), ["claude.session", "claude.weekly"])
        XCTAssertFalse(reloaded.expandedMetricIDs.contains(where: tpsIDs.contains))
        XCTAssertTrue(reloaded.expandedMetricIDs.contains("claude.weekly"), "unrelated expanded rows stay")
        XCTAssertFalse(reloaded.pinnedMetricIDs.contains(where: tpsIDs.contains))
        XCTAssertTrue(reloaded.pinnedMetricIDs.contains("claude.session"))
        XCTAssertTrue(defaults.bool(forKey: "layout.tpsRowsRemoved.v1"), "marker must persist")

        // A second reload keeps the retraction: no TPS rows come back and the marker stays.
        let twice = LayoutStore(
            registry: tpsRegistry(),
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session"],
            migrationBaselineMetricIDs: ["claude.session"]
        )
        XCTAssertFalse(twice.placed.contains { tpsIDs.contains($0.descriptorID) })
        XCTAssertTrue(defaults.bool(forKey: "layout.tpsRowsRemoved.v1"))
    }

    func testFreshLayoutNeverGetsTPSRowsAndMarksNothingToRemove() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LayoutStore(registry: tpsRegistry(), defaults: defaults, storageKey: "layout")
        XCTAssertFalse(store.placed.contains { tpsIDs.contains($0.descriptorID) })
        XCTAssertFalse(defaults.bool(forKey: "layout.tpsRowsRemoved.v1"), "fresh installs have nothing to retract")
    }
}
