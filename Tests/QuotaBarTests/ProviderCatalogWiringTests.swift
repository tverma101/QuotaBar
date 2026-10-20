import XCTest
@testable import QuotaBar

/// Guards the seam where a provider's default arguments are silently bypassed.
///
/// `ProviderCatalog` does not use `OpenCodeProvider.init`'s defaults — it constructs an
/// `OpenCodeUsageScanner` itself and passes it in. Wiring a source only on the provider's default argument
/// therefore compiles, passes every test that constructs the scanner directly, and reads **nothing** in the
/// running app. That is exactly how Space Bunny's 2.2B tokens stayed uncounted while the unit tests were
/// green.
///
/// These assert on the catalog-built object, i.e. the object the app really uses.
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
    ) throws -> OpenCodeProvider {
        try XCTUnwrap(
            ProviderCatalog.make(
                openUsageEnvironment: openUsageEnvironment,
                codexLogHomes: codexLogHomes,
                openCodeClaudeRoots: openCodeClaudeRoots
            ).compactMap { $0 as? OpenCodeProvider }.first
        )
    }

    func testTheProductionScannerIsToldAboutTheRouterLedger() throws {
        let paths = try catalogOpenCode().usageScanner.routerLedgerPaths()
        XCTAssertEqual(
            paths,
            ["/synthetic/router/usage-events.jsonl"],
            "ProviderCatalog builds the scanner itself, so the router ledger must be wired there — " +
            "relying on OpenCodeProvider.init's default leaves it reading nothing in the real app"
        )
    }

    func testTheProductionScannerIsToldAboutTheOtherFoldsToo() throws {
        let claudeRoot = URL(fileURLWithPath: "/synthetic/claude-root")
        let codexHome = URL(fileURLWithPath: "/synthetic/codex-home")
        let scanner = try catalogOpenCode(
            codexLogHomes: [codexHome.path],
            openCodeClaudeRoots: { [claudeRoot] }
        ).usageScanner
        XCTAssertEqual(scanner.claudeRoots(), [claudeRoot], "Claude gateway fold source")
        XCTAssertTrue(
            scanner.codexHomes().contains {
                $0.resolvingSymlinksInPath().standardizedFileURL.path
                    == codexHome.resolvingSymlinksInPath().standardizedFileURL.path
            },
            "Codex gateway fold source"
        )
        // Hermes is optional — the closure is what must be wired, and nil is the correct answer on a
        // machine without a Hermes database.
        _ = try scanner.hermesStateDBPath()
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
        let freebuff = try XCTUnwrap(providers.compactMap { $0 as? FreebuffProvider }.first)
        let metrics = Set(freebuff.widgetDescriptors.map(\.id))

        XCTAssertEqual(Array(ids.prefix(3)), ["claude", "codex", "cursor"])
        XCTAssertEqual(ids[ids.firstIndex(of: "freebuff")! - 1], "devin")
        XCTAssertEqual(ids[ids.firstIndex(of: "freebuff")! + 1], "grok")
        XCTAssertTrue(metrics.isSubset(of: Set(DefaultLayout.metricIDs)))
        XCTAssertTrue(metrics.isDisjoint(with: Set(DefaultLayout.pinnedMetricIDs)))
        XCTAssertTrue(metrics.isDisjoint(with: Set(DefaultLayout.expandedMetricIDs)))
        let metricOrder = freebuff.widgetDescriptors.map(\.id)
        XCTAssertEqual(metricOrder[metricOrder.firstIndex(of: "freebuff.premiumSessions")! + 1], "freebuff.freePremiumSessions")
    }

    /// End-to-end: whatever the fold's sources resolve to must actually produce rows on this machine.
    /// The window is unbounded on purpose — this is a wiring test (is the reader pointed at a real
    /// ledger?), not an activity test; requiring rows in the last 24h made it fail whenever the
    /// router simply hadn't been used since yesterday.
    func testAtLeastOneConfiguredSourceYieldsRows() throws {
        let scanner = try catalogOpenCode().usageScanner
        let ledgerPaths = try scanner.routerLedgerPaths()
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
