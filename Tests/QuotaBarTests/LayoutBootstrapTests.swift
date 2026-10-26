import XCTest
@testable import QuotaBar

@MainActor
final class LayoutBootstrapTests: XCTestCase {
    func testFreshInstallUsesCurrentDefaults() {
        let (persistence, _) = makePersistence("Fresh")

        let state = LayoutBootstrap.load(
            registry: .mock,
            persistence: persistence,
            defaults: makeDefaultSet()
        )

        XCTAssertEqual(state.placed.map(\.descriptorID), ["claude.session", "claude.weekly"])
        XCTAssertEqual(state.pinnedMetricIDs, ["claude.session"])
        XCTAssertEqual(state.expandedMetricIDs, ["claude.weekly"])
        XCTAssertEqual(state.seededDefaultsToPersist, ["claude.session", "claude.weekly"])
        XCTAssertTrue(state.shouldPersistExpanded)
        XCTAssertTrue(state.shouldPersistExpandOnEnable)
        XCTAssertFalse(state.shouldPersistPlaced)
    }

    func testExistingLayoutUsesLegacyBaselineWithoutRestoringRemovedMetric() {
        let (persistence, _) = makePersistence("ExistingBaseline")
        persistence.savePlaced([PlacedWidget(descriptorID: "claude.session")])

        let state = LayoutBootstrap.load(
            registry: .mock,
            persistence: persistence,
            defaults: makeDefaultSet()
        )

        XCTAssertEqual(state.placed.map(\.descriptorID), ["claude.session"])
        XCTAssertFalse(state.expandedMetricIDs.contains("claude.weekly"))
        XCTAssertFalse(state.shouldPersistExpanded)
        XCTAssertTrue(state.shouldPersistExpandOnEnable)
        XCTAssertFalse(state.shouldPersistPlaced)
        XCTAssertEqual(state.seededDefaultsToPersist, ["claude.session", "claude.weekly"])
    }

    func testPreviouslySeededMetricStaysOffWhenUserDisabledIt() {
        let (persistence, _) = makePersistence("UserDisabled")
        persistence.savePlaced([PlacedWidget(descriptorID: "claude.session")])
        persistence.saveSeededDefaults(["claude.session", "claude.weekly"])

        let state = LayoutBootstrap.load(
            registry: .mock,
            persistence: persistence,
            defaults: makeDefaultSet()
        )

        XCTAssertEqual(state.placed.map(\.descriptorID), ["claude.session"])
        XCTAssertFalse(state.shouldPersistPlaced)
        XCTAssertNil(state.seededDefaultsToPersist)
    }

    func testExistingFamilyPinsAreSeededForNewAccountOnce() {
        let (persistence, _) = makePersistence("AccountPins")
        let registry = accountRegistry(providerIDs: ["codex", "codex@abc12345"])
        persistence.savePlaced([PlacedWidget(descriptorID: "codex.session")])
        persistence.savePins(["codex.session"])

        let defaults = LayoutDefaultSet(
            metricIDs: ["codex.session", "codex@abc12345.session"],
            migrationBaselineMetricIDs: ["codex.session"],
            pinnedMetricIDs: ["codex.session"],
            migrationBaselinePinnedMetricIDs: ["codex.session"],
            expandedMetricIDs: []
        )
        let state = LayoutBootstrap.load(registry: registry, persistence: persistence, defaults: defaults)

        XCTAssertEqual(state.pinnedMetricIDs, ["codex.session", "codex@abc12345.session"])
        XCTAssertTrue(state.shouldPersistPins)
        XCTAssertEqual(state.seededAccountPinsToPersist, ["codex@abc12345.session"])

        persistence.savePins(state.pinnedMetricIDs)
        persistence.saveSeededAccountPins(state.seededAccountPinsToPersist ?? [])
        // Simulate the user removing only the newly seeded account pin before the next launch.
        persistence.savePins(["codex.session"])

        let reloaded = LayoutBootstrap.load(registry: registry, persistence: persistence, defaults: defaults)

        XCTAssertEqual(reloaded.pinnedMetricIDs, ["codex.session"])
        XCTAssertFalse(reloaded.shouldPersistPins, "an explicit account pin removal must stay removed")
        XCTAssertNil(reloaded.seededAccountPinsToPersist)
    }

    func testExplicitlyEmptyPinsDoNotSeedNewAccountPins() {
        let (persistence, _) = makePersistence("EmptyAccountPins")
        let registry = accountRegistry(providerIDs: ["codex", "codex@abc12345"])
        persistence.savePlaced([PlacedWidget(descriptorID: "codex.session")])
        persistence.savePins([])

        let state = LayoutBootstrap.load(
            registry: registry,
            persistence: persistence,
            defaults: LayoutDefaultSet(
                metricIDs: ["codex.session", "codex@abc12345.session"],
                migrationBaselineMetricIDs: ["codex.session"],
                pinnedMetricIDs: ["codex.session"],
                migrationBaselinePinnedMetricIDs: ["codex.session"],
                expandedMetricIDs: []
            )
        )

        XCTAssertTrue(state.pinnedMetricIDs.isEmpty)
        XCTAssertFalse(state.shouldPersistPins)
    }

    func testNewDefaultPinSeedsIntoExistingLayoutOnce() {
        let (persistence, _) = makePersistence("DefaultPinSeed")
        persistence.savePlaced([PlacedWidget(descriptorID: "claude.session")])
        persistence.savePins(["claude.session"])
        // A pre-existing layout has never seen the new default pin (`claude.weekly`).
        let defaults = LayoutDefaultSet(
            metricIDs: ["claude.session", "claude.weekly"],
            migrationBaselineMetricIDs: ["claude.session", "claude.weekly"],
            pinnedMetricIDs: ["claude.session", "claude.weekly"],
            migrationBaselinePinnedMetricIDs: ["claude.session"],
            expandedMetricIDs: []
        )

        let state = LayoutBootstrap.load(registry: .mock, persistence: persistence, defaults: defaults)

        XCTAssertEqual(state.pinnedMetricIDs, ["claude.session", "claude.weekly"])
        XCTAssertTrue(state.shouldPersistPins)
        XCTAssertEqual(state.seededDefaultPinsToPersist, ["claude.session", "claude.weekly"])

        persistence.savePins(state.pinnedMetricIDs)
        persistence.saveSeededDefaultPins(state.seededDefaultPinsToPersist ?? [])
        // Simulate the user unpinning only the newly seeded default before the next launch.
        persistence.savePins(["claude.session"])

        let reloaded = LayoutBootstrap.load(registry: .mock, persistence: persistence, defaults: defaults)

        XCTAssertEqual(reloaded.pinnedMetricIDs, ["claude.session"])
        XCTAssertFalse(reloaded.shouldPersistPins, "an explicit unpin of a seeded default must stay removed")
    }

    func testBaselineDefaultPinsAreNotReSeededOverUserUnpins() {
        let (persistence, _) = makePersistence("DefaultPinBaseline")
        persistence.savePlaced([PlacedWidget(descriptorID: "claude.session")])
        // The user unpinned everything before pin seeding existed; the baseline is what they saw.
        persistence.savePins([])
        let defaults = LayoutDefaultSet(
            metricIDs: ["claude.session", "claude.weekly"],
            migrationBaselineMetricIDs: ["claude.session", "claude.weekly"],
            pinnedMetricIDs: ["claude.session", "claude.weekly"],
            migrationBaselinePinnedMetricIDs: ["claude.session", "claude.weekly"],
            expandedMetricIDs: []
        )

        let state = LayoutBootstrap.load(registry: .mock, persistence: persistence, defaults: defaults)

        XCTAssertTrue(state.pinnedMetricIDs.isEmpty)
        XCTAssertFalse(state.shouldPersistPins)
        XCTAssertEqual(state.seededDefaultPinsToPersist, ["claude.session", "claude.weekly"])
    }

    private func makeDefaultSet() -> LayoutDefaultSet {
        LayoutDefaultSet(
            metricIDs: ["claude.session", "claude.weekly"],
            migrationBaselineMetricIDs: ["claude.session", "claude.weekly"],
            pinnedMetricIDs: ["claude.session"],
            migrationBaselinePinnedMetricIDs: ["claude.session"],
            expandedMetricIDs: ["claude.weekly"]
        )
    }

    private func makePersistence(_ name: String) -> (LayoutPersistence, UserDefaults) {
        let suite = "OpenUsageTests.LayoutBootstrap.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (LayoutPersistence(defaults: defaults, storageKey: "layout"), defaults)
    }

    private func accountRegistry(providerIDs: [String]) -> WidgetRegistry {
        let providers = providerIDs.map {
            Provider(id: $0, displayName: $0, icon: .providerMark("codex"))
        }
        let descriptors = providers.map { provider in
            WidgetDescriptor(
                id: "\(provider.id).session",
                providerID: provider.id,
                metricLabel: "Session",
                sample: WidgetData(
                    title: "Session",
                    icon: provider.icon,
                    kind: .percent,
                    used: 50,
                    limit: 100
                )
            )
        }
        return WidgetRegistry(providers: providers, descriptors: descriptors)
    }
}
