import XCTest
@testable import QuotaBar

@MainActor
final class MixedProviderFailureTests: XCTestCase {
    func testQuotaFailureWithValidHistoryRemainsAnErrorAndPersistsOnlyHistory() async throws {
        let provider = FreebuffProvider().provider
        let descriptors = FreebuffProvider().widgetDescriptors
        let now = Date()
        let day = DailyUsageAccumulator.dayKey(from: now)
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: day, totalTokens: 123, costUSD: nil)
        ]))
        var failed = ProviderSnapshot.error(provider: provider, error: FreebuffAuthError.credentialPermissionRequired)
        failed.usageHistory = history
        failed.lines.append(.values(label: "Today", values: [MetricValue(number: 123, kind: .count, label: "tokens")]))
        let runtime = SequenceProviderRuntime(provider: provider, descriptors: descriptors, snapshots: [failed])
        let defaults = UserDefaults(suiteName: "MixedProviderFailure.\(UUID())")!
        let cache = ProviderSnapshotCache(userDefaults: defaults)
        let previous = ProviderSnapshot(providerID: provider.id, displayName: provider.displayName, lines: [
            .progress(label: "Daily Hours", used: 1, limit: 53, format: .count(suffix: "hours")),
            .values(label: "Hours Balance", values: [MetricValue(number: 73, kind: .count, label: "hours")])
        ], refreshedAt: now.addingTimeInterval(-600))
        cache.store(previous)
        let store = WidgetDataStore(registry: WidgetRegistry.from([runtime]), providers: [runtime], cache: cache, defaults: defaults)
        let outcome = await store.refresh(providerID: provider.id, force: true)
        XCTAssertEqual(outcome, .failed, "history must never turn failed credentials into a successful quota refresh")
        XCTAssertEqual(store.errorMessage(for: provider.id), FreebuffAuthError.credentialPermissionRequired.localizedDescription)
        XCTAssertEqual(store.snapshots[provider.id]?.usageHistory, history)
        XCTAssertEqual(store.snapshots[provider.id]?.quotaRefreshedAt, previous.quotaRefreshedAt)
        let persisted = try XCTUnwrap(cache.loadSnapshots(providerIDs: [provider.id])[provider.id])
        XCTAssertFalse(persisted.lines.contains(where: \.isError))
        XCTAssertEqual(persisted.usageHistory, history)
    }

    func testHeadlessSignedAppArgumentsRejectAmbiguousRequests() throws {
        XCTAssertEqual(try DiagnosticOptions.parse(["--diagnose", "Freebuff", "--force"]),
                       DiagnosticOptions(providerID: "freebuff", force: true))
        XCTAssertThrowsError(try DiagnosticOptions.parse(["--diagnose", "freebuff", "codex"]))
        XCTAssertThrowsError(try DiagnosticOptions.parse(["--diagnose", "--bogus"]))
    }

    func testSignedAppUsesItsOwnStandardDefaultsAndHelperUsesAppSuite() throws {
        XCTAssertTrue(try HeadlessDiagnosticCommand.settingsDefaults(domain: "app.id", bundleIdentifier: "app.id") === UserDefaults.standard)
        let helper = try HeadlessDiagnosticCommand.settingsDefaults(domain: "HeadlessDefaults.\(UUID())", bundleIdentifier: "helper.id")
        XCTAssertFalse(helper === UserDefaults.standard)
    }
}
