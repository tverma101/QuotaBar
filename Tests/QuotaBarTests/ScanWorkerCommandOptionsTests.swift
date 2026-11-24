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

    @MainActor
    func testAntigravityFoldDoesNotResolveQuotaIdentity() async throws {
        // Antigravity's fold produces machine-local history only: it can never prove which Google
        // account owns the cached quota, so the response must carry no identity for it — and must
        // not even fire the launch-identity fallback probe.
        let options = try ScanWorkerCommand.Options.parse(["--providers", "antigravity", "--return-only"])
        var defaultIdentityCalls: [String] = []
        let response = await ScanWorkerCommand.collectUnpublishedSnapshots(
            options: options,
            providers: [UnpublishedWorkerTestProvider(id: "antigravity", reportedIdentity: nil)],
            defaultIdentityKey: { id in
                defaultIdentityCalls.append(id)
                return AntigravityAuthStore.unresolvedCacheIdentityKey
            }
        )

        let snapshot = try XCTUnwrap(response.snapshots["antigravity"])
        XCTAssertNotNil(snapshot.usageHistory)
        XCTAssertNil(
            response.identityKeys["antigravity"],
            "a history-only fold must not advertise a quota account identity"
        )
        XCTAssertTrue(
            defaultIdentityCalls.isEmpty,
            "the fold must not trigger the launch-identity fallback for Antigravity"
        )
        XCTAssertTrue(response.errors.isEmpty)
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
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor] = []
    private let reportedIdentity: String?

    init(id: String = "opencode", reportedIdentity: String? = "actual") {
        provider = Provider(id: id, displayName: id.capitalized, icon: .providerMark(id))
        self.reportedIdentity = reportedIdentity
    }

    func hasLocalCredentials() async -> Bool { false }

    func refresh() async -> ProviderSnapshot {
        if let reportedIdentity {
            ProviderRefreshContext.cacheIdentityResult?.set(reportedIdentity)
        }
        return .make(
            provider: provider,
            plan: nil,
            lines: [],
            refreshedAt: Date(),
            usageHistory: ProviderUsageHistory(series: DailyUsageSeries(daily: []))
        )
    }
}
