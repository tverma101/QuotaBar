import XCTest
@testable import QuotaBar

final class ScanWorkerCommandOptionsTests: XCTestCase {
    func testParsesProvidersScopeAndPacing() throws {
        let options = try ScanWorkerCommand.Options.parse(
            ["--scan-worker", "--providers", "codex,claude", "--scope", "local-accounting", "--paced", "--return-only"]
        )
        XCTAssertEqual(options.providerIDs, ["codex", "claude"])
        XCTAssertEqual(options.scope, .localAccounting)
        XCTAssertTrue(options.paced)
        XCTAssertTrue(options.returnOnly)
    }

    func testDefaultsArePanelAccountingUnpaced() throws {
        let options = try ScanWorkerCommand.Options.parse(
            ["--scan-worker", "--providers", "freebuff"]
        )
        XCTAssertEqual(options.scope, .panelAccounting)
        XCTAssertFalse(options.paced)
        XCTAssertFalse(options.returnOnly)
        XCTAssertEqual(options.providerIDs, ["freebuff"])
    }

    @MainActor
    func testDelegatedFoldLeavesParentAsTheSnapshotWriter() async throws {
        // The delegated worker must not open a second snapshot transaction: the parent reserved
        // the refresh order and is the only writer allowed to publish the fold's result.
        let suiteName = "quotabar-scan-worker-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = ProviderSnapshotCache(userDefaults: defaults)
        let order = try XCTUnwrap(cache.beginRefreshOrder(providerID: "opencode"))

        let options = try ScanWorkerCommand.Options.parse(["--providers", "opencode", "--return-only"])
        let response = await ScanWorkerCommand.collectUnpublishedSnapshots(
            options: options,
            providers: [UnpublishedWorkerTestProvider()],
            defaultIdentityKeys: ["opencode": "fallback"]
        )

        let snapshot = try XCTUnwrap(response.snapshots["opencode"])
        XCTAssertNotNil(snapshot.usageHistory)
        XCTAssertEqual(response.identityKeys["opencode"], "actual")
        XCTAssertTrue(response.errors.isEmpty)
        XCTAssertTrue(cache.loadSnapshots(providerIDs: ["opencode"]).isEmpty)
        XCTAssertTrue(cache.isCurrentRefresh(
            providerID: "opencode",
            order: order,
            scope: .panelAccounting,
            hasHistoryDomain: true
        ))
    }

    func testParsesBatchBudgetFlags() throws {
        let options = try ScanWorkerCommand.Options.parse(
            ["--scan-worker", "--providers", "claude,devin", "--return-only",
             "--per-provider-timeout", "40", "--batch-budget", "100"]
        )
        XCTAssertEqual(options.perProviderTimeout, 40)
        XCTAssertEqual(options.batchBudget, 100)
        XCTAssertNil(try ScanWorkerCommand.Options.parse(
            ["--scan-worker", "--providers", "claude"]
        ).perProviderTimeout)
    }

    func testRejectsInvalidBatchBudgetFlags() {
        XCTAssertThrowsError(try ScanWorkerCommand.Options.parse(
            ["--scan-worker", "--providers", "claude", "--per-provider-timeout", "abc"]
        ))
        XCTAssertThrowsError(try ScanWorkerCommand.Options.parse(
            ["--scan-worker", "--providers", "claude", "--batch-budget", "-5"]
        ))
        XCTAssertThrowsError(try ScanWorkerCommand.Options.parse(
            ["--scan-worker", "--providers", "claude", "--per-provider-timeout"]
        ))
    }

    func testRejectsMissingProviders() {
        XCTAssertThrowsError(try ScanWorkerCommand.Options.parse(["--scan-worker"]))
        XCTAssertThrowsError(try ScanWorkerCommand.Options.parse(["--scan-worker", "--providers", ""]))
    }

    func testRejectsUnknownScopeAndFlags() {
        XCTAssertThrowsError(try ScanWorkerCommand.Options.parse(
            ["--scan-worker", "--providers", "codex", "--scope", "full"]
        ))
        XCTAssertThrowsError(try ScanWorkerCommand.Options.parse(
            ["--scan-worker", "--providers", "codex", "--force"]
        ))
    }
}

@MainActor
private final class UnpublishedWorkerTestProvider: ProviderRuntime {
    let provider = Provider(id: "opencode", displayName: "OpenCode", icon: .providerMark("opencode"))
    let widgetDescriptors: [WidgetDescriptor] = []

    func hasLocalCredentials() async -> Bool { false }

    func refresh() async -> ProviderSnapshot {
        ProviderRefreshContext.cacheIdentityResult?.set("actual")
        return .make(
            provider: provider,
            plan: nil,
            lines: [],
            refreshedAt: Date(),
            usageHistory: ProviderUsageHistory(series: DailyUsageSeries(daily: []))
        )
    }
}
