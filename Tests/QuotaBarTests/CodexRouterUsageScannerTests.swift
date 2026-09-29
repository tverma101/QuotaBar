import XCTest
@testable import QuotaBar

final class CodexRouterUsageScannerTests: XCTestCase {
    private func pricing() -> ModelPricing {
        ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: [
                "gpt-5.6-terra": ModelRates(
                    inputPerMillion: 1_000,
                    outputPerMillion: 3_000,
                    cacheWritePerMillion: 1_000,
                    cacheReadPerMillion: 100
                ),
                "gpt-5.6-luna": ModelRates(
                    inputPerMillion: 1_000,
                    outputPerMillion: 3_000,
                    cacheWritePerMillion: 1_000,
                    cacheReadPerMillion: 100
                ),
                "gpt-6-luna": ModelRates(
                    inputPerMillion: 1_000,
                    outputPerMillion: 3_000,
                    cacheWritePerMillion: 1_000,
                    cacheReadPerMillion: 100
                )
            ]),
            secondary: PricingCatalog(entries: [:])
        )
    }

    private func ledger(_ events: [[String: Any]]) -> String {
        events.map { object in
            let data = try! JSONSerialization.data(withJSONObject: object)
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n") + "\n"
    }

    func testPricesSuccessfulRouterEventsAndIgnoresFailures() async throws {
        let accountID = "1118f6f1-8697-4e7b-9112-1771b3e36099"
        let fingerprint = CodexProxyUsageScanner.accountFingerprint(for: accountID)!
        let contents = ledger([
            [
                "at": TestLocalInstant.iso(2026, 9, 2, 15),
                "model": "gpt-5.6-terra",
                "provider": "openai",
                "status": 200,
                "inputTokens": 100,
                "cachedInputTokens": 25,
                "outputTokens": 50,
                "reasoningTokens": 10,
                "totalTokens": 160,
                "accountFingerprint": fingerprint,
                "accountId": accountID
            ],
            [
                "at": TestLocalInstant.iso(2026, 9, 2, 16),
                "model": "gpt-5.6-terra",
                "provider": "openai",
                "status": 502,
                "inputTokens": 999,
                "outputTokens": 999,
                "totalTokens": 1998,
                "accountFingerprint": fingerprint
            ]
        ])
        let scanner = CodexRouterUsageScanner(
            ledgerPaths: { ["/tmp/usage-events.jsonl"] },
            readFile: { _ in contents }
        )
        let now = TestLocalInstant.date(2026, 9, 3, 12)

        let optionalScan = await scanner.scan(
            accountIdentityKey: accountID,
            allowsUnscopedEvents: false,
            daysBack: 30,
            now: now,
            pricing: pricing()
        )
        let scan = try XCTUnwrap(optionalScan)

        // Cost: non-cached input 75 @ 1000/M + cacheRead 25 @ 100/M + output 50 @ 3000/M
        // = 0.075 + 0.0025 + 0.15 = 0.2275; tokens from totalTokens = 160
        XCTAssertEqual(scan.series.daily.count, 1)
        // The scanner buckets by *local* calendar day, so the expectation is derived from the same local
        // clock rather than hardcoded to the UTC date. These fixtures used UTC instants with a UTC
        // expectation, which is only self-consistent when the suite runs on UTC: at UTC+9 the 15:00Z event
        // falls on the following local day and the assertion fails.
        XCTAssertEqual(scan.series.daily[0].date, TestLocalInstant.isoDay(2026, 9, 2))
        XCTAssertEqual(scan.series.daily[0].totalTokens, 160)
        XCTAssertEqual(scan.series.daily[0].costUSD!, 0.2275, accuracy: 0.000_000_1)
    }

    func testLegacyUnscopedEventsOnlyWhenAllowed() async {
        let contents = ledger([
            [
                "at": "2026-09-02T15:00:00.000Z",
                "model": "gpt-5.6-luna",
                "provider": "openai",
                "status": 200,
                "inputTokens": 10,
                "outputTokens": 5,
                "totalTokens": 15
            ]
        ])
        let scanner = CodexRouterUsageScanner(
            ledgerPaths: { ["/tmp/usage-events.jsonl"] },
            readFile: { _ in contents }
        )
        let now = OpenUsageISO8601.date(from: "2026-09-03T12:00:00.000Z")!

        let blocked = await scanner.scan(
            accountIdentityKey: "1118f6f1-8697-4e7b-9112-1771b3e36099",
            allowsUnscopedEvents: false,
            now: now,
            pricing: pricing()
        )
        XCTAssertNil(blocked)

        let allowed = await scanner.scan(
            accountIdentityKey: nil,
            allowsUnscopedEvents: true,
            now: now,
            pricing: pricing()
        )
        XCTAssertNotNil(allowed)
        XCTAssertEqual(allowed?.series.daily.first?.totalTokens, 15)
    }

    func testRejectsOtherAccountFingerprint() async {
        let contents = ledger([
            [
                "at": "2026-09-02T15:00:00.000Z",
                "model": "gpt-5.6-luna",
                "provider": "openai",
                "status": 200,
                "inputTokens": 10,
                "outputTokens": 5,
                "totalTokens": 15,
                "accountFingerprint": "acct_deadbeefdead"
            ]
        ])
        let scanner = CodexRouterUsageScanner(
            ledgerPaths: { ["/tmp/usage-events.jsonl"] },
            readFile: { _ in contents }
        )
        let result = await scanner.scan(
            accountIdentityKey: "1118f6f1-8697-4e7b-9112-1771b3e36099",
            allowsUnscopedEvents: false,
            now: OpenUsageISO8601.date(from: "2026-09-03T12:00:00.000Z")!,
            pricing: pricing()
        )
        XCTAssertNil(result)
    }

    func testDefaultLedgerPathsPreferOverrideEnv() {
        let environment = FakeEnvironment([
            "OPENUSAGE_CODEX_ROUTER_USAGE_EVENTS": "/custom/events.jsonl"
        ])
        let paths = CodexRouterUsageScanner.defaultLedgerPaths(
            environment: environment,
            homeDirectory: URL(fileURLWithPath: "/Users/test")
        )
        XCTAssertEqual(paths, ["/custom/events.jsonl"])
    }

    func testRoutesStampedEventsToMatchingAccountOnly() async {
        let accountA = "9de63544-5afb-4036-9e7d-89ee160af849"
        let accountB = "1118f6f1-8697-4e7b-9112-1771b3e36099"
        let fpA = CodexProxyUsageScanner.accountFingerprint(for: accountA)!
        let fpB = CodexProxyUsageScanner.accountFingerprint(for: accountB)!
        let contents = ledger([
            [
                "at": "2026-09-02T15:00:00.000Z",
                "model": "gpt-5.6-terra",
                "provider": "openai",
                "status": 200,
                "inputTokens": 100,
                "outputTokens": 10,
                "totalTokens": 110,
                "accountFingerprint": fpA,
                "accountId": accountA
            ],
            [
                "at": "2026-09-02T16:00:00.000Z",
                "model": "gpt-5.6-luna",
                "provider": "openai",
                "status": 200,
                "inputTokens": 50,
                "outputTokens": 5,
                "totalTokens": 55,
                "accountFingerprint": fpB,
                "accountId": accountB
            ]
        ])
        let scanner = CodexRouterUsageScanner(
            ledgerPaths: { ["/tmp/usage-events.jsonl"] },
            readFile: { _ in contents }
        )
        let now = OpenUsageISO8601.date(from: "2026-09-03T12:00:00.000Z")!

        let scanA = await scanner.scan(
            accountIdentityKey: accountA,
            allowsUnscopedEvents: false,
            now: now,
            pricing: pricing()
        )
        let scanB = await scanner.scan(
            accountIdentityKey: accountB,
            allowsUnscopedEvents: false,
            now: now,
            pricing: pricing()
        )
        XCTAssertEqual(scanA?.series.daily.first?.totalTokens, 110)
        XCTAssertEqual(scanB?.series.daily.first?.totalTokens, 55)
    }

    func testMatchesPoolOpaqueAccountIdAlias() async {
        let accountID = "1118f6f1-8697-4e7b-9112-1771b3e36099"
        let poolId = "acct_B_gacrRVPlhAScqI"
        let contents = ledger([
            [
                "at": "2026-09-02T15:00:00.000Z",
                "model": "gpt-5.6-luna",
                "provider": "openai",
                "status": 200,
                "inputTokens": 20,
                "outputTokens": 5,
                "totalTokens": 25,
                "accountId": poolId
            ]
        ])
        let scanner = CodexRouterUsageScanner(
            ledgerPaths: { ["/tmp/usage-events.jsonl"] },
            readFile: { _ in contents },
            identityAliases: { [poolId.lowercased(): accountID.lowercased()] }
        )
        let scan = await scanner.scan(
            accountIdentityKey: accountID,
            allowsUnscopedEvents: false,
            now: OpenUsageISO8601.date(from: "2026-09-03T12:00:00.000Z")!,
            pricing: pricing()
        )
        XCTAssertEqual(scan?.series.daily.first?.totalTokens, 25)
    }


    func testPriorityServiceTierAppliesCodexMultiplier() async throws {
        let accountID = "1118f6f1-8697-4e7b-9112-1771b3e36099"
        let fingerprint = CodexProxyUsageScanner.accountFingerprint(for: accountID)!
        let contents = ledger([
            [
                "at": "2026-09-02T15:00:00.000Z",
                "model": "gpt-5.6-terra",
                "provider": "openai",
                "status": 200,
                "inputTokens": 100,
                "cachedInputTokens": 25,
                "outputTokens": 50,
                "totalTokens": 150,
                "serviceTier": "priority",
                "accountFingerprint": fingerprint,
                "accountId": accountID
            ]
        ])
        let scanner = CodexRouterUsageScanner(
            ledgerPaths: { ["/tmp/usage-events.jsonl"] },
            readFile: { _ in contents }
        )
        let now = OpenUsageISO8601.date(from: "2026-09-03T12:00:00.000Z")!
        let optionalScan = await scanner.scan(
            accountIdentityKey: accountID,
            allowsUnscopedEvents: false,
            daysBack: 30,
            now: now,
            pricing: pricing()
        )
        let scan = try XCTUnwrap(optionalScan)
        // Base 0.2275 × Codex priority multiplier 2 for gpt-5.6-terra
        XCTAssertEqual(scan.series.daily[0].costUSD!, 0.455, accuracy: 0.000_000_1)
    }

    func testDefaultServiceTierKeepsStandardRates() async throws {
        let accountID = "1118f6f1-8697-4e7b-9112-1771b3e36099"
        let fingerprint = CodexProxyUsageScanner.accountFingerprint(for: accountID)!
        let contents = ledger([
            [
                "at": "2026-09-02T15:00:00.000Z",
                "model": "gpt-5.6-terra",
                "provider": "openai",
                "status": 200,
                "inputTokens": 100,
                "cachedInputTokens": 25,
                "outputTokens": 50,
                "totalTokens": 150,
                "serviceTier": "default",
                "accountFingerprint": fingerprint,
                "accountId": accountID
            ]
        ])
        let scanner = CodexRouterUsageScanner(
            ledgerPaths: { ["/tmp/usage-events.jsonl"] },
            readFile: { _ in contents }
        )
        let now = OpenUsageISO8601.date(from: "2026-09-03T12:00:00.000Z")!
        let optionalScan = await scanner.scan(
            accountIdentityKey: accountID,
            allowsUnscopedEvents: false,
            daysBack: 30,
            now: now,
            pricing: pricing()
        )
        let scan = try XCTUnwrap(optionalScan)
        XCTAssertEqual(scan.series.daily[0].costUSD!, 0.2275, accuracy: 0.000_000_1)
    }

    func testMultiSegmentModelSlugPricesViaSuffixCandidates() async throws {
        let accountID = "1118f6f1-8697-4e7b-9112-1771b3e36099"
        let fingerprint = CodexProxyUsageScanner.accountFingerprint(for: accountID)!
        let contents = ledger([
            [
                "at": "2026-09-02T15:00:00.000Z",
                "model": "anthropic/openai/gpt-5.6-luna",
                "provider": "openai",
                "status": 200,
                "inputTokens": 100_000,
                "cachedInputTokens": 0,
                "outputTokens": 0,
                "totalTokens": 100_000,
                "accountFingerprint": fingerprint,
                "accountId": accountID
            ]
        ])
        // Price only the bare luna key so a single-segment strip (`openai/gpt-5.6-luna`) would miss.
        let pricing = ModelPricing(
            supplement: PricingSupplement(pricing: [
                "gpt-5.6-luna": ModelRates(
                    inputPerMillion: 0.2,
                    outputPerMillion: 1.2,
                    cacheWritePerMillion: 0.25,
                    cacheReadPerMillion: 0.02
                )
            ]),
            primary: PricingCatalog(entries: [:]),
            secondary: PricingCatalog(entries: [:])
        )
        let scanner = CodexRouterUsageScanner(
            ledgerPaths: { ["/tmp/usage-events.jsonl"] },
            readFile: { _ in contents }
        )
        let now = OpenUsageISO8601.date(from: "2026-09-03T12:00:00.000Z")!
        let optionalScan = await scanner.scan(
            accountIdentityKey: accountID,
            allowsUnscopedEvents: false,
            daysBack: 30,
            now: now,
            pricing: pricing
        )
        let scan = try XCTUnwrap(optionalScan)
        XCTAssertEqual(scan.series.daily[0].costUSD!, 0.02, accuracy: 0.000_000_1)
        XCTAssertTrue(scan.unknownModelsByDay.isEmpty)
    }

    func testMissingTotalTokensDoesNotDoubleCountReasoning() async throws {
        let accountID = "9de63544-5afb-4036-9e7d-89ee160af849"
        let fingerprint = CodexProxyUsageScanner.accountFingerprint(for: accountID)!
        let contents = ledger([
            [
                "at": "2026-09-24T15:00:00.000Z",
                "model": "gpt-5.6-luna",
                "provider": "openai",
                "status": 200,
                "inputTokens": 1000,
                "cachedInputTokens": 100,
                "outputTokens": 50,
                "reasoningTokens": 40,
                "accountFingerprint": fingerprint,
                "accountId": accountID
            ]
        ])
        let scanner = CodexRouterUsageScanner(
            ledgerPaths: { ["/tmp/usage-events.jsonl"] },
            readFile: { _ in contents }
        )
        let now = OpenUsageISO8601.date(from: "2026-09-24T18:00:00.000Z")!
        let optionalScan = await scanner.scan(
            accountIdentityKey: accountID,
            allowsUnscopedEvents: false,
            daysBack: 2,
            now: now,
            pricing: pricing()
        )
        let scan = try XCTUnwrap(optionalScan)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 1050)
    }

    func testReserveSlugStillCountsTokensViaDatedFallback() async throws {
        let accountID = "1118f6f1-8697-4e7b-9112-1771b3e36099"
        let fingerprint = CodexProxyUsageScanner.accountFingerprint(for: accountID)!
        let contents = ledger([
            [
                "at": "2026-09-24T15:00:00.000Z",
                "model": "gpt-reserve",
                "provider": "openai",
                "status": 200,
                "inputTokens": 1_000_000,
                "cachedInputTokens": 0,
                "outputTokens": 0,
                "totalTokens": 1_000_000,
                "accountFingerprint": fingerprint,
                "accountId": accountID
            ]
        ])
        let scanner = CodexRouterUsageScanner(
            ledgerPaths: { ["/tmp/usage-events.jsonl"] },
            readFile: { _ in contents }
        )
        let now = OpenUsageISO8601.date(from: "2026-09-24T18:00:00.000Z")!
        let optionalScan = await scanner.scan(
            accountIdentityKey: accountID,
            allowsUnscopedEvents: false,
            daysBack: 2,
            now: now,
            pricing: pricing()
        )
        let scan = try XCTUnwrap(optionalScan)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 1_000_000)
        XCTAssertNotNil(scan.series.daily.first?.costUSD)
        XCTAssertTrue(scan.unknownModelsByDay.isEmpty)
    }
}

extension CodexRouterUsageScannerTests {
    /// The regression from the real dashboard: one model, two rows, counted twice.
    ///
    /// The Codex router stamps the upstream path onto its slugs, so `gpt-5.6-luna` also arrived as
    /// `anthropic/openai/gpt-5.6-luna`. Both priced fine — the candidate resolver already tried every
    /// suffix after a `/` — but the per-model row was keyed on the raw slug, so the period showed two
    /// rows for one model, each displaying its own slug, and their costs were summed into the same
    /// "Last 30 Days" total. The tagged row's cost was real; it was just also counted again under a
    /// second name.
    func testGatewayTaggedSlugCollapsesOntoTheModelItRoutes() async throws {
        let accountID = "1118f6f1-8697-4e7b-9112-1771b3e36099"
        let fingerprint = CodexProxyUsageScanner.accountFingerprint(for: accountID)!
        let contents = ledger([
            [
                "at": TestLocalInstant.iso(2026, 9, 2, 15),
                "model": "gpt-5.6-luna",
                "provider": "openai",
                "status": 200,
                "inputTokens": 100, "cachedInputTokens": 0, "outputTokens": 50,
                "reasoningTokens": 0, "totalTokens": 150,
                "accountFingerprint": fingerprint, "accountId": accountID
            ],
            [
                // Same model, routed through a stamped path.
                "at": TestLocalInstant.iso(2026, 9, 2, 16),
                "model": "anthropic/openai/gpt-5.6-luna",
                "provider": "anthropic",
                "status": 200,
                "inputTokens": 200, "cachedInputTokens": 0, "outputTokens": 50,
                "reasoningTokens": 0, "totalTokens": 250,
                "accountFingerprint": fingerprint, "accountId": accountID
            ]
        ])
        let scanner = CodexRouterUsageScanner(
            ledgerPaths: { ["/tmp/usage-events.jsonl"] },
            readFile: { _ in contents }
        )
        let scanned = await scanner.scan(
            accountIdentityKey: accountID,
            allowsUnscopedEvents: false,
            daysBack: 30,
            now: TestLocalInstant.date(2026, 9, 3, 12),
            pricing: pricing()
        )
        let scan = try XCTUnwrap(scanned)

        let models = try XCTUnwrap(scan.modelUsage?.daily.flatMap(\.models))
        XCTAssertEqual(
            models.map(\.model), ["gpt-5.6-luna"],
            "one model, one row — the routing path is not part of the model's name"
        )
        XCTAssertEqual(
            models[0].totalTokens, 400,
            "both events belong to the same model and must sum, not split"
        )
        // Rates are 1000/1M in, 3000/1M out.
        //   event 1: 100 in + 50 out = 0.10 + 0.15 = 0.25
        //   event 2: 200 in + 50 out = 0.20 + 0.15 = 0.35
        XCTAssertEqual(models[0].costUSD ?? 0, 0.60, accuracy: 0.000_001)

        // The observed spelling is not lost — it moves to the hover breakdown, which is where a routing
        // tag is actually informative.
        XCTAssertEqual(
            models[0].variants?.map(\.model).sorted(),
            ["anthropic/openai/gpt-5.6-luna", "gpt-5.6-luna"],
            "the tagged spelling survives as a tooltip variant"
        )
    }

    /// The distinction that must NOT be collapsed: a bare slug that merely borrows another model's price
    /// is its own identity. `gpt-reserve` and `codex-auto-review` are deliberate rows, so "priced like"
    /// cannot be read as "is" — that mistake is what the narrow `GatewaySlug` rule exists to prevent.
    func testBareSlugKeepsItsOwnIdentityEvenWhenPricedAsAnotherModel() async throws {
        let accountID = "1118f6f1-8697-4e7b-9112-1771b3e36099"
        let fingerprint = CodexProxyUsageScanner.accountFingerprint(for: accountID)!
        let contents = ledger([
            [
                "at": TestLocalInstant.iso(2026, 9, 2, 15),
                "model": "gpt-5.6-luna",
                "provider": "openai", "status": 200,
                "inputTokens": 100, "cachedInputTokens": 0, "outputTokens": 50,
                "reasoningTokens": 0, "totalTokens": 150,
                "accountFingerprint": fingerprint, "accountId": accountID
            ]
        ])
        let scanner = CodexRouterUsageScanner(
            ledgerPaths: { ["/tmp/usage-events.jsonl"] },
            readFile: { _ in contents }
        )
        let scanned = await scanner.scan(
            accountIdentityKey: accountID,
            allowsUnscopedEvents: false,
            daysBack: 30,
            now: TestLocalInstant.date(2026, 9, 3, 12),
            pricing: pricing()
        )
        let scan = try XCTUnwrap(scanned)
        let models = try XCTUnwrap(scan.modelUsage?.daily.flatMap(\.models))
        XCTAssertEqual(models.map(\.model), ["gpt-5.6-luna"])
        XCTAssertNil(models[0].variants, "a single untagged spelling is no breakdown")

        // And the rule itself, stated directly: only a `/` marks a routing path.
        XCTAssertTrue(GatewaySlug.hasRoutingPath("anthropic/openai/gpt-5.6-luna"))
        XCTAssertFalse(GatewaySlug.hasRoutingPath("gpt-5.6-luna"))
        XCTAssertFalse(GatewaySlug.hasRoutingPath("gpt-reserve"))
        XCTAssertEqual(
            GatewaySlug.identity(of: "anthropic/openai/gpt-5.6-luna", resolvedPricingModel: "gpt-5.6-luna"),
            "gpt-5.6-luna"
        )
        // A bare slug ignores the resolved model entirely, even when pricing found one.
        XCTAssertEqual(
            GatewaySlug.identity(of: "gpt-reserve", resolvedPricingModel: "gpt-6-luna"),
            "gpt-reserve"
        )
    }
}
