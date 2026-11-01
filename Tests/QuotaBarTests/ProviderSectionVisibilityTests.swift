import XCTest
@testable import QuotaBar

@MainActor
final class ProviderSectionVisibilityTests: XCTestCase {
    func testProviderSectionStaysVisibleForHeaderOnlyPlanAndStatusStates() {
        XCTAssertTrue(ProviderSectionVisibility.shouldRender(
            hasVisibleMetric: false,
            hasPlan: true,
            hasNotice: false,
            isRefreshing: false,
            hasStaleness: false
        ))
        XCTAssertTrue(ProviderSectionVisibility.shouldRender(
            hasVisibleMetric: false,
            hasPlan: false,
            hasNotice: true,
            isRefreshing: false,
            hasStaleness: false
        ))
        XCTAssertTrue(ProviderSectionVisibility.shouldRender(
            hasVisibleMetric: false,
            hasPlan: false,
            hasNotice: false,
            isRefreshing: true,
            hasStaleness: false
        ))
        XCTAssertFalse(ProviderSectionVisibility.shouldRender(
            hasVisibleMetric: false,
            hasPlan: false,
            hasNotice: false,
            isRefreshing: false,
            hasStaleness: false
        ))
    }

    func testZAIEmptyCoreRowsHideForNoPlanButRemainForActivePlanWithoutUsableLimits() async throws {
        let provider = ZAIProvider()
        let activePlan = ProviderSnapshot.make(
            provider: provider.provider,
            plan: "GLM Coding Max",
            lines: [
                .progress(label: "Session", used: 12, limit: 100, format: .percent),
                .progress(label: "Weekly", used: 28, limit: 100, format: .percent)
            ],
            refreshedAt: Date()
        )
        let unknownLimits = ProviderSnapshot.make(
            provider: provider.provider,
            plan: "GLM Coding Max",
            lines: [.noUsageData],
            refreshedAt: Date()
        )
        let noPlan = ProviderSnapshot.error(
            provider: provider.provider,
            error: ZAIUsageError.noCodingPlan,
            clearsPriorMenuBarQuotaState: true
        )
        let runtime = SequenceProviderRuntime(
            provider: provider.provider,
            descriptors: provider.widgetDescriptors,
            snapshots: [activePlan, noPlan, unknownLimits]
        )
        let registry = WidgetRegistry.from([runtime])
        let suiteName = "QuotaBarTests.ZAINoPlanVisibility.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "zai-no-plan.snapshot", ttl: 600),
            defaults: defaults
        )
        let layout = LayoutStore(
            registry: registry,
            defaults: defaults,
            defaultMetricIDs: ["zai.session", "zai.weekly"]
        )
        let session = try XCTUnwrap(registry.descriptor(id: "zai.session"))
        let weekly = try XCTUnwrap(registry.descriptor(id: "zai.weekly"))

        await dataStore.refresh(providerID: "zai", force: true)
        let activeSessionHasData = dataStore.data(for: session).hasData
        let activeWeeklyHasData = dataStore.data(for: weekly).hasData
        let activePlanName = dataStore.plan(for: "zai")
        XCTAssertTrue(activeSessionHasData)
        XCTAssertTrue(activeWeeklyHasData)
        XCTAssertEqual(activePlanName, "GLM Coding Max")

        await dataStore.refresh(providerID: "zai", force: true)
        let noPlanErrorCategory = dataStore.errorCategory(for: "zai")
        let noPlanNotice = dataStore.headerNotice(for: "zai")
        let noPlanName = dataStore.plan(for: "zai")
        XCTAssertEqual(noPlanErrorCategory, .notAvailable)
        XCTAssertNotNil(noPlanNotice)
        XCTAssertNil(noPlanName, "a lost plan must not leave stale plan/cap state visible")
        for descriptor in [session, weekly] {
            let data = dataStore.data(for: descriptor)
            let explicitlyEnabled = layout.explicitlyEnabledMetricIDs.contains(descriptor.id)
            let shouldRender = ProviderSectionVisibility.shouldRenderZAIQuotaRow(
                descriptorID: descriptor.id,
                hasData: data.hasData,
                errorCategory: noPlanErrorCategory,
                explicitlyEnabled: explicitlyEnabled
            )
            XCTAssertFalse(data.hasData)
            XCTAssertFalse(shouldRender)
            XCTAssertTrue(ProviderSectionVisibility.shouldRenderZAIQuotaRow(
                descriptorID: descriptor.id,
                hasData: false,
                errorCategory: .notAvailable,
                explicitlyEnabled: true
            ), "an explicit Customize choice keeps the no-data state visible")
        }

        await dataStore.refresh(providerID: "zai", force: true)
        let recoveredErrorCategory = dataStore.errorCategory(for: "zai")
        let recoveredPlanName = dataStore.plan(for: "zai")
        XCTAssertNil(recoveredErrorCategory)
        XCTAssertEqual(recoveredPlanName, "GLM Coding Max")
        for descriptor in [session, weekly] {
            let data = dataStore.data(for: descriptor)
            let explicitlyEnabled = layout.explicitlyEnabledMetricIDs.contains(descriptor.id)
            let shouldRender = ProviderSectionVisibility.shouldRenderZAIQuotaRow(
                descriptorID: descriptor.id,
                hasData: data.hasData,
                errorCategory: recoveredErrorCategory,
                explicitlyEnabled: explicitlyEnabled
            )
            XCTAssertFalse(data.hasData)
            XCTAssertTrue(shouldRender, "active plan with unknown limits keeps the documented No data rows")
        }
    }

    func testSharedMetricRowFilterKeepsShareAndDashboardInSync() {
        XCTAssertFalse(ProviderSectionVisibility.shouldRenderMetricRow(
            providerID: "zai",
            descriptorID: "zai.session",
            hasData: false,
            errorCategory: .notAvailable,
            explicitlyEnabled: false
        ))
        XCTAssertTrue(ProviderSectionVisibility.shouldRenderMetricRow(
            providerID: "zai",
            descriptorID: "zai.session",
            hasData: false,
            errorCategory: .notAvailable,
            explicitlyEnabled: true
        ))
        XCTAssertTrue(ProviderSectionVisibility.shouldRenderMetricRow(
            providerID: "zai",
            descriptorID: "zai.session",
            hasData: true,
            errorCategory: .notAvailable,
            explicitlyEnabled: false
        ))
        XCTAssertTrue(ProviderSectionVisibility.shouldRenderMetricRow(
            providerID: "claude",
            descriptorID: "claude.session",
            hasData: false,
            errorCategory: .notAvailable,
            explicitlyEnabled: false
        ))
    }
}
