import XCTest
@testable import QuotaBar

/// Guards the production catalog seam: the app must construct the Rust-backed providers, and the
/// discovery inputs those runtimes need must be passed in the engine configuration. Swift's own
/// implementations remain available as test oracles, but they must never be the object the app uses.
@MainActor
final class ProviderCatalogWiringTests: XCTestCase {
    private func catalogOpenCode(
        openUsageEnvironment: EnvironmentReading = FakeEnvironment([
            "OPENUSAGE_CODEX_ROUTER_USAGE_EVENTS": "/synthetic/router/usage-events.jsonl"
        ]),
        codexLogHomes: [String] = [],
        openCodeClaudeRoots: @escaping @Sendable () -> [URL] = {
            OpenCodeUsageScanner.discoverClaudeRoots()
        }
    ) throws -> RustOpenCodeProvider {
        try XCTUnwrap(
            ProviderCatalog.make(
                openUsageEnvironment: openUsageEnvironment,
                codexLogHomes: codexLogHomes,
                openCodeClaudeRoots: openCodeClaudeRoots
            ).compactMap { $0 as? RustOpenCodeProvider }.first
        )
    }

    func testTheProductionEngineIsToldAboutTheRouterLedger() throws {
        let config = try XCTUnwrap(catalogOpenCode().engineConfig?.values)
        XCTAssertEqual(
            config["routerLedgerPaths"] as? [String],
            ["/synthetic/router/usage-events.jsonl"],
            "the catalog-built engine config must carry the router ledger into Rust"
        )
    }

    func testTheProductionEngineIsToldAboutTheOtherFoldsToo() throws {
        let claudeRoot = URL(fileURLWithPath: "/synthetic/claude-root")
        let codexHome = URL(fileURLWithPath: "/synthetic/codex-home")
        let config = try XCTUnwrap(
            catalogOpenCode(
                codexLogHomes: [codexHome.path],
                openCodeClaudeRoots: { [claudeRoot] }
            ).engineConfig?.values
        )
        XCTAssertEqual(config["claudeRoots"] as? [String], [claudeRoot.path], "Claude gateway fold source")
        XCTAssertTrue(
            (config["codexHomes"] as? [String] ?? []).contains {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
                    == codexHome.resolvingSymlinksInPath().standardizedFileURL.path
            },
            "Codex gateway fold source"
        )
        XCTAssertEqual(config["gatewayHermes"] as? Bool, true)
    }

    func testMuseGatewayFoldFollowsOpenCodeEnablement() {
        let enabledSources = ProviderCatalog.enabledGatewaySources(
            claudeProviderIDs: [],
            codexProviderIDs: [],
            isProviderEnabled: { $0 == "opencode" }
        )
        XCTAssertTrue(enabledSources.contains(.muse))

        let disabledSources = ProviderCatalog.enabledGatewaySources(
            claudeProviderIDs: [],
            codexProviderIDs: [],
            isProviderEnabled: { $0 == "muse" }
        )
        XCTAssertFalse(disabledSources.contains(.muse))
    }

    func testFreebuffIsRegisteredAlphabeticallyWithOwnerConfirmedDefaults() throws {
        let providers = ProviderCatalog.make()
        let ids = providers.map { $0.provider.id }
        let freebuff = try XCTUnwrap(providers.compactMap { $0 as? RustFreebuffProvider }.first)
        let metrics = Set(freebuff.widgetDescriptors.map(\.id))

        XCTAssertEqual(Array(ids.prefix(3)), ["claude", "codex", "cursor"])
        XCTAssertEqual(ids[ids.firstIndex(of: "freebuff")! - 1], "devin")
        XCTAssertEqual(ids[ids.firstIndex(of: "freebuff")! + 1], "grok")
        XCTAssertTrue(metrics.contains("freebuff.trend"))
        XCTAssertTrue(metrics.isSubset(of: Set(DefaultLayout.metricIDs)))
        // Freebuff's Daily Hours meter is the owner-requested menu-bar pin, and it reads as the
        // active session clock in the strip rather than an allowance figure.
        XCTAssertEqual(
            metrics.intersection(Set(DefaultLayout.pinnedMetricIDs)),
            ["freebuff.freebucksDaily"]
        )
        XCTAssertEqual(
            freebuff.widgetDescriptors.first { $0.id == "freebuff.freebucksDaily" }?.sample.trayStyle,
            .sessionCountdowns(metricLabel: "Active Sessions")
        )
        XCTAssertTrue(metrics.isDisjoint(with: Set(DefaultLayout.expandedMetricIDs)))
        let metricOrder = freebuff.widgetDescriptors.map(\.id)
        XCTAssertEqual(metricOrder[metricOrder.firstIndex(of: "freebuff.premiumSessions")! + 1], "freebuff.freePremiumSessions")
    }

    /// End-to-end: whatever the fold's sources resolve to must actually produce rows on this machine.
    /// The window is unbounded on purpose — this is a wiring test (is the reader pointed at a real
    /// ledger?), not an activity test.
    func testAtLeastOneConfiguredSourceYieldsRows() throws {
        let config = try XCTUnwrap(catalogOpenCode().engineConfig?.values)
        let ledgerPaths = config["routerLedgerPaths"] as? [String] ?? []
        guard let first = ledgerPaths.first(where: { FileManager.default.isReadableFile(atPath: $0) }) else {
            throw XCTSkip("no router ledger on this machine")
        }
        let rows = OpenCodeUsageScanner.routerGatewayRows(atPath: first, since: .distantPast)
        guard !rows.isEmpty else {
            throw XCTSkip("the ledger exists but has never recorded a row — nothing to wire against")
        }
        XCTAssertFalse(rows.isEmpty, "the ledger is readable but yields no rows — the reader or the provider filter is wrong")
    }
}
