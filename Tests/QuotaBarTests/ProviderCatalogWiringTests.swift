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

    func testFreebuffProductionConfigIsOfflineInThisBuild() throws {
        let freebuff = try XCTUnwrap(
            ProviderCatalog.make().compactMap { $0 as? RustFreebuffProvider }.first
        )
        let config = try XCTUnwrap(freebuff.engineConfig?.values)
        #if QUOTABAR_LOCAL_FREEBUFF
        XCTAssertEqual(config["liveSessionEnabled"] as? Bool, true)
        #else
        XCTAssertEqual(config["liveSessionEnabled"] as? Bool, false)
        #endif
        XCTAssertEqual(
            config["hostedDetailEnabled"] as? Bool,
            false,
            "neither public nor private local builds may request hosted history or the model catalogue"
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

    func testOpenCodeEngineConfigCarriesCodexIdentityReconciliationInputs() throws {
        let home = "/synthetic/codex-home"
        let config = try XCTUnwrap(
            ProviderCatalog.make(
                codexDefaultIdentityKey: "acct-a",
                codexDefaultHome: home,
                codexLogHomes: [home]
            ).compactMap { $0 as? RustOpenCodeProvider }.first?.engineConfig?.values
        )

        let homeIdentities = try XCTUnwrap(config["codexHomeIdentityKeys"] as? [String: String])
        XCTAssertEqual(homeIdentities[home], "acct-a")
        let allAliases = try XCTUnwrap(config["codexAccountIdentityKeys"] as? [String: String])
        XCTAssertEqual(allAliases["acct-a"], "acct-a")
        if let fingerprint = CodexProxyUsageScanner.accountFingerprint(for: "acct-a") {
            XCTAssertEqual(allAliases[fingerprint.lowercased()], "acct-a")
        }
        XCTAssertNil(
            config["enabledCodexIdentityKeys"],
            "without account cards the legacy unscoped rows must remain additive"
        )
    }

    func testOpenCodeEngineConfigCarriesOnlyEnabledCodexAccountReconciliationInputs() throws {
        let homeA = "/synthetic/codex-home-a"
        let homeB = "/synthetic/codex-home-b"
        let cardA = CodexAccountCard(
            id: "codex@account-a",
            identityKey: "acct-a",
            home: homeA,
            logHomes: [homeA],
            authHomes: [homeA],
            displayName: "Codex A",
            allowsKeychainFallback: false,
            allowsUnattributedPiUsage: false,
            attributionSharedHome: nil
        )
        let cardB = CodexAccountCard(
            id: "codex@account-b",
            identityKey: "acct-b",
            home: homeB,
            logHomes: [homeB],
            authHomes: [homeB],
            displayName: "Codex B",
            allowsKeychainFallback: false,
            allowsUnattributedPiUsage: false,
            attributionSharedHome: nil
        )
        let config = try XCTUnwrap(
            ProviderCatalog.make(
                codexCards: [cardA, cardB],
                isProviderEnabled: { $0 != "codex@account-b" }
            ).compactMap { $0 as? RustOpenCodeProvider }.first?.engineConfig?.values
        )

        XCTAssertEqual(config["enabledCodexIdentityKeys"] as? [String], ["acct-a"])
        XCTAssertEqual(config["codexHomeIdentityKeys"] as? [String: String], [homeA: "acct-a"])
        XCTAssertEqual(config["codexHomes"] as? [String], [homeA])

        let allAliases = try XCTUnwrap(config["codexAccountIdentityKeys"] as? [String: String])
        XCTAssertEqual(allAliases["acct-a"], "acct-a")
        XCTAssertEqual(allAliases["acct-b"], "acct-b")
        let enabledAliases = try XCTUnwrap(config["routerAccountIdentityKeys"] as? [String: String])
        XCTAssertEqual(enabledAliases["acct-a"], "acct-a")
        XCTAssertNil(enabledAliases["acct-b"])
        if let fingerprintA = CodexProxyUsageScanner.accountFingerprint(for: "acct-a") {
            XCTAssertEqual(enabledAliases[fingerprintA.lowercased()], "acct-a")
        }
        if let fingerprintB = CodexProxyUsageScanner.accountFingerprint(for: "acct-b") {
            XCTAssertNil(enabledAliases[fingerprintB.lowercased()])
        }
    }

    func testOpenCodeEngineConfigCarriesOnlyEnabledClaudeAccountConfigs() throws {
        let cardA = ClaudeAccountCard(
            id: "claude@account-a",
            identityKey: "user-a|org-a",
            organizationID: "org-a",
            displayName: "Claude A",
            usesDesktopCredentials: true,
            allowsUnattributedPiUsage: false
        )
        let cardB = ClaudeAccountCard(
            id: "claude@account-b",
            identityKey: "user-b|org-b",
            organizationID: "org-b",
            displayName: "Claude B",
            usesDesktopCredentials: true,
            allowsUnattributedPiUsage: false
        )
        let config = try XCTUnwrap(
            ProviderCatalog.make(
                claudeCards: [cardA, cardB],
                isProviderEnabled: { $0 != "claude@account-b" }
            ).compactMap { $0 as? RustOpenCodeProvider }.first?.engineConfig?.values
        )

        let configs = try XCTUnwrap(config["claudeAccountConfigs"] as? [[String: Any]])
        XCTAssertEqual(configs.count, 1)
        XCTAssertEqual(configs.first?["cardID"] as? String, "claude@account-a")
        XCTAssertEqual(configs.first?["organizationUUID"] as? String, "org-a")
        XCTAssertEqual(configs.first?["expectedIdentityKey"] as? String, "user-a|org-a")
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
