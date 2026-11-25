import XCTest
@testable import QuotaBar

/// Proves the Claude and Codex accounting folds served by Rust produce the same normalized scan and
/// the same rendered metric lines as the Swift implementations they replaced, and that the real
/// scanner/provider path actually reaches the backend (not just the direct fold call).
final class RustFoldParityTests: XCTestCase {
    private typealias ClaudeEntry = ClaudeLogUsageScanner.Entry

    // MARK: - Claude

    private func claudePricing() -> ModelPricing {
        ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: [
                "claude-sonnet-test": ModelRates(
                    inputPerMillion: 3, outputPerMillion: 15,
                    cacheWritePerMillion: 3.75, cacheReadPerMillion: 0.3,
                    promptRateTiers: [
                        PromptRateTier(
                            thresholdPromptTokens: 200_000,
                            inputPerMillion: 6,
                            outputPerMillion: 22.5,
                            cacheWritePerMillion: 7.5,
                            cacheReadPerMillion: 0.6
                        )
                    ],
                    fastMultiplier: 2
                ),
                "claude-opus-test": ModelRates(
                    inputPerMillion: 15, outputPerMillion: 75,
                    cacheWritePerMillion: 18.75, cacheReadPerMillion: 1.5
                )
            ]),
            secondary: PricingCatalog(entries: [:])
        )
    }

    private func entry(
        _ timestamp: Date,
        model: String?,
        input: Int = 0,
        output: Int = 0,
        cacheWrite5m: Int = 0,
        cacheWrite1h: Int = 0,
        cacheRead: Int = 0,
        costUSD: Double? = nil,
        messageID: String? = nil,
        requestID: String? = nil,
        isSidechain: Bool = false,
        hasSpeed: Bool = false,
        isFast: Bool = false
    ) -> ClaudeEntry {
        ClaudeEntry(
            timestamp: timestamp,
            tokens: TokenBreakdown(
                input: input,
                cacheWrite5m: cacheWrite5m,
                cacheWrite1h: cacheWrite1h,
                cacheRead: cacheRead,
                output: output,
                isFast: isFast
            ),
            messageID: messageID,
            requestID: requestID,
            isSidechain: isSidechain,
            hasSpeed: hasSpeed,
            costUSD: costUSD,
            model: model
        )
    }

    private func claudeEntries(now: Date) -> [ClaudeEntry] {
        let recent = now.addingTimeInterval(-3_600)
        let earlier = now.addingTimeInterval(-90_000)
        return [
            // Over the 200k prompt tier, no carried cost: priced from the catalog.
            entry(
                recent, model: " claude-sonnet-test ",
                input: 250_000, output: 1_000, cacheRead: 50_000,
                messageID: "msg_a", requestID: "req_a"
            ),
            // Fast request: the rate multiplier applies.
            entry(
                recent, model: "claude-sonnet-test",
                input: 1_000, output: 500, cacheWrite5m: 2_000, cacheWrite1h: 500,
                messageID: "msg_fast", requestID: "req_fast", hasSpeed: true, isFast: true
            ),
            // Exact replay with fewer tokens: the larger original wins.
            entry(
                recent, model: "claude-sonnet-test",
                input: 100, output: 10,
                messageID: "msg_a", requestID: "req_a"
            ),
            // Sidechain replay under a new request id: the parent row wins even with more tokens.
            entry(
                recent, model: "claude-sonnet-test",
                input: 900_000, output: 900_000,
                messageID: "msg_a", requestID: "req_sidechain", isSidechain: true
            ),
            // Provider-reported cost is carried verbatim.
            entry(
                recent, model: "claude-opus-test",
                input: 10_000, output: 2_000, cacheRead: 1_000, costUSD: 1.25,
                messageID: "msg_opus", requestID: "req_opus"
            ),
            // No catalog rate: tokens count, cost dashes, model is flagged.
            entry(
                recent, model: "mystery-model",
                input: 10_000, output: 2_000,
                messageID: "msg_mystery", requestID: "req_mystery"
            ),
            // Hosted gateway turns belong to the OpenCode card.
            entry(
                recent, model: "anthropic/opencode_go/deepseek-v4-flash",
                input: 500_000, output: 500_000,
                messageID: "msg_gateway", requestID: "req_gateway"
            ),
            // No message id: always kept, even if the tokens match another row.
            entry(
                recent, model: "claude-opus-test",
                input: 3_000, output: 700
            ),
            // Empty model: Unattributed, tokens still counted.
            entry(
                recent, model: nil,
                input: 400, output: 100,
                messageID: "msg_unattributed", requestID: "req_unattributed"
            ),
            // Earlier local day, inside the window.
            entry(
                earlier, model: "claude-sonnet-test",
                input: 5_000, output: 1_000,
                messageID: "msg_old", requestID: "req_old"
            ),
            // Outside the window: must be dropped identically.
            entry(
                now.addingTimeInterval(-10 * 86_400), model: "claude-sonnet-test",
                input: 999_999, output: 999_999,
                messageID: "msg_before", requestID: "req_before"
            )
        ]
    }

    private func renderedLines(for scan: LogUsageScan, now: Date) -> [MetricLine] {
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            scan.series,
            to: &lines,
            now: now,
            unknownModelsByDay: scan.unknownModelsByDay,
            modelUsage: scan.modelUsage,
            modelSourceNote: "From your Claude usage history",
            apiEstimateByDay: scan.apiEstimateByDay
        )
        SpendTileMapper.appendUsageTrend(
            scan.series,
            to: &lines,
            now: now,
            note: "From your Claude usage history"
        )
        return lines
    }

    func testClaudeFoldMatchesSwiftOracle() throws {
        let now = Date()
        let since = now.addingTimeInterval(-3 * 86_400)
        let pricing = claudePricing()
        let entries = claudeEntries(now: now)

        let oracle = ClaudeLogUsageScanner.aggregate(
            entries: ClaudeLogUsageScanner.dedup(entries),
            since: since,
            pricing: pricing
        )
        let rust = try XCTUnwrap(
            ClaudeRustFold.fold(entries: entries, since: since, pricing: pricing, now: now),
            "the Rust Claude fold declined the parity fixture"
        )

        XCTAssertEqual(rust.series, oracle.series)
        XCTAssertEqual(rust.modelUsage, oracle.modelUsage)
        XCTAssertEqual(rust.unknownModelsByDay, oracle.unknownModelsByDay)
        XCTAssertEqual(rust.apiEstimateByDay, oracle.apiEstimateByDay)
        XCTAssertEqual(rust.apiEstimateIncompleteDays, oracle.apiEstimateIncompleteDays)
        XCTAssertEqual(rust, oracle)
        XCTAssertEqual(renderedLines(for: rust, now: now), renderedLines(for: oracle, now: now))
        XCTAssertEqual(
            Set(oracle.unknownModelsByDay.values.flatMap { $0 }),
            ["mystery-model", "Unattributed"]
        )
    }

    @MainActor
    func testClaudeProviderRefreshIsServedByRust() async throws {
        let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let home = try ClaudeLogFixture.makeHome(files: [
            "project-a/today.jsonl": ClaudeLogFixture.usageLine(
                timestamp: "2026-02-20T16:00:00.000Z", input: 100, output: 50, costUSD: 0.25
            )
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(),
                files: FakeFiles(),
                keychain: FakeKeychain(),
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: FakeHTTPClient(
                response: HTTPResponse(statusCode: 200, headers: [:], body: Data())
            )),
            logUsageScanner: ClaudeLogFixture.scanner(home: home),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        #if DEBUG
        let before = RustFoldSupport.completedFoldsForTesting
        #endif
        let snapshot = await provider.refresh()
        #if DEBUG
        XCTAssertGreaterThan(
            RustFoldSupport.completedFoldsForTesting, before,
            "the provider refresh never reached the Rust Claude fold"
        )
        #endif

        XCTAssertEqual(snapshot.warning, ClaudeAuthError.notLoggedIn.localizedDescription)
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.totalTokens, 150)
        XCTAssertTrue(snapshot.lines.contains { $0.label == "Today" })
    }

    // MARK: - Codex

    private func codexPricing() -> ModelPricing {
        ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: [
                "gpt-5.5": ModelRates(
                    inputPerMillion: 10, outputPerMillion: 45,
                    cacheWritePerMillion: 10, cacheReadPerMillion: 1
                ),
                "gpt-5.5-pro": ModelRates(
                    inputPerMillion: 30, outputPerMillion: 180,
                    cacheWritePerMillion: 30, cacheReadPerMillion: 3
                ),
                "gpt-5.4": ModelRates(
                    inputPerMillion: 2.5, outputPerMillion: 15,
                    cacheWritePerMillion: 2.5, cacheReadPerMillion: 0.25
                ),
                "gpt-6.1-sol": ModelRates(
                    inputPerMillion: 5, outputPerMillion: 20,
                    cacheWritePerMillion: 5, cacheReadPerMillion: 0.5
                ),
                "gpt-5.2": ModelRates(
                    inputPerMillion: 1.25, outputPerMillion: 10,
                    cacheWritePerMillion: 1.25, cacheReadPerMillion: 0.125
                )
            ]),
            secondary: PricingCatalog(entries: [:])
        )
    }

    private func codexEvent(
        _ timestamp: Date,
        model: String,
        pricingModel: String? = nil,
        input: Int,
        cached: Int = 0,
        output: Int = 0,
        reasoning: Int = 0,
        total: Int? = nil,
        hasCompleteCostBreakdown: Bool = true,
        isFast: Bool = false,
        serviceTier: String? = nil
    ) -> CodexLogUsageScanner.Event {
        CodexLogUsageScanner.Event(
            timestamp: timestamp,
            model: model,
            pricingModel: pricingModel,
            input: input,
            cached: cached,
            output: output,
            reasoning: reasoning,
            total: total ?? (input + output),
            hasCompleteCostBreakdown: hasCompleteCostBreakdown,
            isFast: isFast,
            serviceTier: serviceTier
        )
    }

    private func codexEvents(now: Date) -> [CodexLogUsageScanner.Event] {
        let recent = now.addingTimeInterval(-3_600)
        let earlier = now.addingTimeInterval(-90_000)
        return [
            // Priority fast tier: 2.5x for gpt-5.5.
            codexEvent(
                recent, model: "gpt-5.5",
                input: 1_000_000, cached: 100_000, output: 10_000, total: 1_010_000,
                isFast: true
            ),
            // Duplicate of the previous event: deduped.
            codexEvent(
                recent, model: "gpt-5.5",
                input: 1_000_000, cached: 100_000, output: 10_000, total: 1_010_000,
                isFast: true
            ),
            // No cache discount + long-context lanes.
            codexEvent(
                recent, model: "gpt-5.5-pro",
                input: 500_000, cached: 50_000, output: 20_000, total: 520_000
            ),
            // Dated display slug priced through its base model: long-context lanes apply.
            codexEvent(
                recent, model: "gpt-5.4-2026-05-01", pricingModel: "gpt-5.4",
                input: 300_000, output: 1_000, total: 301_000
            ),
            // Published service-tier multipliers on gpt-6.1-sol.
            codexEvent(
                recent, model: "gpt-6.1-sol",
                input: 100_000, output: 10_000, total: 110_000,
                serviceTier: "priority"
            ),
            codexEvent(
                recent, model: "gpt-6.1-sol",
                input: 40_000, output: 4_000, total: 44_000,
                serviceTier: "flex"
            ),
            // Gateway-tagged slug: grouped under the resolved model identity.
            codexEvent(
                recent, model: "vendor/openai/gpt-5.2", pricingModel: "gpt-5.2",
                input: 20_000, cached: 2_000, output: 3_000, total: 23_000
            ),
            // Same model, untagged spelling: a variant of the row above.
            codexEvent(
                recent, model: "gpt-5.2",
                input: 5_000, output: 1_000, total: 6_000
            ),
            // Hosted gateway turns belong to the OpenCode card.
            codexEvent(
                recent, model: "anthropic/opencode_go/deepseek-v4",
                input: 50_000, output: 5_000, total: 55_000
            ),
            // No catalog rate: tokens count, cost dashes.
            codexEvent(
                recent, model: "unknown-codename",
                input: 7_000, output: 700, total: 7_700
            ),
            // Incomplete cost breakdown: tokens count, the row's cost is not presented as whole.
            codexEvent(
                earlier, model: "gpt-5.2",
                input: 3_000, output: 300, total: 3_300,
                hasCompleteCostBreakdown: false
            ),
            // Outside the window: dropped identically.
            codexEvent(
                now.addingTimeInterval(-10 * 86_400), model: "gpt-5.2",
                input: 99_999, output: 9_999, total: 109_998
            )
        ]
    }

    func testCodexFoldMatchesSwiftOracle() throws {
        let now = Date()
        let since = now.addingTimeInterval(-3 * 86_400)
        let pricing = codexPricing()
        let events = codexEvents(now: now)

        let oracle = CodexLogUsageScanner.aggregate(events: events, since: since, pricing: pricing)
        var context = CodexRustFold.FoldContext(since: since, pricing: pricing, now: now)
        let rust = try XCTUnwrap(
            CodexRustFold.fold(events: events, context: &context),
            "the Rust Codex fold declined the parity fixture"
        )

        XCTAssertEqual(rust.series, oracle.series)
        XCTAssertEqual(rust.modelUsage, oracle.modelUsage)
        XCTAssertEqual(rust.unknownModelsByDay, oracle.unknownModelsByDay)
        XCTAssertEqual(rust.apiEstimateByDay, oracle.apiEstimateByDay)
        XCTAssertEqual(rust.apiEstimateIncompleteDays, oracle.apiEstimateIncompleteDays)
        XCTAssertEqual(rust, oracle)
        XCTAssertEqual(renderedLines(for: rust, now: now), renderedLines(for: oracle, now: now))
        XCTAssertEqual(oracle.unknownModelsByDay.values.flatMap { $0 }, ["unknown-codename"])
    }

    func testCodexScannerIsServedByRust() async throws {
        let day = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3_600))
        let home = try CodexLogFixture.makeHome(files: [
            "sessions/2026/05/rollout-a.jsonl": [
                CodexLogFixture.turnContext(timestamp: day, model: "gpt-5.2"),
                CodexLogFixture.tokenCount(
                    timestamp: day,
                    last: CodexLogFixture.usage(input: 100, cached: 10, output: 50)
                )
            ].joined(separator: "\n")
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = CodexLogFixture.scanner(home: home)
        let pricing = ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: ["gpt-5.2": ModelRates(
                inputPerMillion: 1000, outputPerMillion: 3000,
                cacheWritePerMillion: 1000, cacheReadPerMillion: 100
            )]),
            secondary: PricingCatalog(entries: [:])
        )

        #if DEBUG
        let before = RustFoldSupport.completedFoldsForTesting
        #endif
        let scan = await scanner.scan(pricing: pricing)
        #if DEBUG
        XCTAssertGreaterThan(
            RustFoldSupport.completedFoldsForTesting, before,
            "the scanner never reached the Rust Codex fold"
        )
        #endif

        XCTAssertEqual(scan?.series.daily.reduce(0) { $0 + $1.totalTokens }, 150)
        XCTAssertNotNil(scan?.modelUsage?.daily.first?.models.first(where: { $0.model == "gpt-5.2" }))
    }
}
