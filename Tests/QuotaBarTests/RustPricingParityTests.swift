import XCTest
@testable import QuotaBar

/// Proves the Rust pricing mirror resolves exactly what `ModelPricing` resolves: same rates, same
/// unknown-model handling, same discovery candidates, and the same priced scans when the fold takes
/// model names instead of a Swift-built rate table.
final class RustPricingParityTests: XCTestCase {
    private typealias ClaudeEntry = ClaudeLogUsageScanner.Entry

    // MARK: - Fixtures

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []

        func record(_ name: String) {
            lock.lock()
            names.append(name)
            lock.unlock()
        }

        func drain() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return names
        }
    }

    private struct ResolveResult: Decodable {
        let rates: [String: ModelRates?]
        let recheckModels: [String]
    }

    private static func rule(_ pattern: String, _ canonical: String) -> PricingSupplement.AliasRule {
        PricingSupplement.AliasRule(
            pattern: try! NSRegularExpression(pattern: pattern),
            canonical: canonical
        )
    }

    private static func rates(_ input: Double, _ output: Double) -> ModelRates {
        ModelRates(
            inputPerMillion: input,
            outputPerMillion: output,
            cacheWritePerMillion: input,
            cacheReadPerMillion: input / 10,
            cacheWrite1hPerMillion: input * 1.5,
            promptRateTiers: [
                PromptRateTier(
                    thresholdPromptTokens: 200_000,
                    inputPerMillion: input * 2,
                    outputPerMillion: output * 2,
                    cacheReadPerMillion: input / 5
                )
            ],
            utcPriceOverrides: [
                UTCPriceRateOverride(
                    utcDays: ["monday", "tuesday"],
                    utcStartMinute: 600,
                    utcEndMinute: 1_080,
                    inputPerMillion: input * 0.8,
                    outputPerMillion: output * 0.8,
                    cacheReadPerMillion: input / 12
                )
            ],
            inputAbove200kPerMillion: input * 3,
            outputAbove200kPerMillion: output * 3,
            cacheWriteAbove200kPerMillion: input * 3,
            cacheReadAbove200kPerMillion: input / 4,
            cacheReadIsExplicit: true,
            longContextThresholdTokens: 100_000,
            fastMultiplier: 1
        )
    }

    /// Catalogues that exercise every lookup lane: curated overrides, alias rules, separator
    /// normalization, dated fast bases, fuzzy matches with version guards, exact fast cards, free
    /// suffixes, and OpenRouter timed lanes.
    private static func syntheticPricing(
        onRecheck: (@Sendable (String) -> Void)? = nil
    ) -> ModelPricing {
        let supplement = PricingSupplement(
            pricing: [
                "bench-curated": rates(7, 8),
                "bench-7.1": rates(2, 3)
            ],
            fastMultipliers: [
                "bench-base": 2,
                "bench-dated": 4,
                "bench-7.1": 1.5
            ],
            aliasRules: [
                rule("^bench-alias$", "bench-canonical"),
                rule("^(?:cursor-)?bench-7[.-]1$", "bench-7.1"),
                rule("^bench-fast-alias-fast$", "bench-fast-alias-fast")
            ]
        )
        let primary = PricingCatalog(entries: [
            "bench-canonical": rates(3, 15),
            "bench-base": rates(10, 20),
            "bench-dated-20260101": rates(1, 2),
            "bench-dated-20260301": rates(4, 5),
            "bench-normalized-key": rates(6, 7),
            "claude-sonnet-4-20250514": rates(3, 15)
        ])
        let secondary = PricingCatalog(entries: [
            "bench-fast-exact-fast": rates(9, 10),
            "bench-free": rates(0, 0),
            "bench-secondary": rates(11, 12)
        ])
        let openRouter = PricingCatalog(entries: [
            "bench-openrouter": rates(5, 6),
            "route/bench-route": rates(8, 9)
        ])
        return ModelPricing(
            supplement: supplement,
            primary: primary,
            secondary: secondary,
            openRouter: openRouter,
            onOpenRouterRecheckModel: onRecheck
        )
    }

    private static let syntheticModels: [String] = [
        "bench-canonical",
        "bench-alias",
        "bench-curated",
        "bench-base-fast",
        "bench-dated-fast",
        "bench-no-multiplier-fast",
        "bench-fast-exact-fast",
        "bench-free",
        "bench-free-something",
        "bench-openrouter",
        "bench-normalized_key",
        "bench normalize",
        "claude-sonnet-4",
        "claude-sonnet-4-5",
        "cursor-bench-7.1",
        "bench-7.1",
        "bench-secondary",
        "xai/bench-canonical-preview",
        "bench-fast-alias-fast",
        "unknown-model"
    ]

    private func rustResolve(
        pricing: ModelPricing,
        models: [String]
    ) throws -> (rates: [String: ModelRates?], recheck: [String]) {
        let handle = try XCTUnwrap(
            pricing.backendPricingHandle(),
            "the Rust pricing snapshot declined the fixture"
        )
        var canonicalNames: [String: String] = [:]
        for model in models {
            if let canonical = pricing.canonicalName(for: model) {
                canonicalNames[model] = canonical
            }
        }
        let result = try RustBackend.call(
            op: "pricing.resolve",
            params: [
                "handle": handle,
                "models": models,
                "canonicalNames": canonicalNames
            ]
        )
        let decoded = try JSONDecoder().decode(ResolveResult.self, from: result)
        return (decoded.rates, decoded.recheckModels)
    }

    // MARK: - Resolution parity

    func testSnapshotWirePreservesExactRates() throws {
        let pricing = Self.syntheticPricing()
        let request = try XCTUnwrap(PricingSnapshotWire.request(
            supplementPricing: pricing.supplement.pricing,
            fastMultipliers: pricing.supplement.fastMultipliers,
            primary: pricing.primary.entries,
            secondary: pricing.secondary.entries,
            openRouter: pricing.openRouter.entries
        ))
        let text = String(decoding: request, as: UTF8.self)
        XCTAssertTrue(
            text.contains("9.600000000000001"),
            "the wire lost a rate's last bits: \(text.prefix(600))"
        )
    }

    func testSyntheticResolutionMatchesSwiftOracle() throws {
        let models = Self.syntheticModels
        // Fresh instances: one records Swift's discovery hooks, the other owns the Rust snapshot.
        let recorder = Recorder()
        let oracle = Self.syntheticPricing(onRecheck: { recorder.record($0) })
        let backend = Self.syntheticPricing()

        var expected: [String: ModelRates?] = [:]
        for model in models {
            expected[model] = oracle.resolve(model: model)
        }
        let (rust, rustRecheck) = try rustResolve(pricing: backend, models: models)

        for model in models {
            XCTAssertEqual(
                rust[model] ?? nil,
                expected[model] ?? nil,
                "resolved rates diverged for `\(model)`"
            )
        }
        XCTAssertEqual(Set(rustRecheck), Set(recorder.drain()),
                       "discovery candidates diverged from the Swift resolver")
    }

    func testBundledCatalogResolutionMatchesSwiftOracle() throws {
        let bundled = TestPricing.bundled
        let primaryKeys = bundled.primary.entries.keys.sorted()
        let secondaryKeys = bundled.secondary.entries.keys.sorted()
        let openRouterKeys = bundled.openRouter.entries.keys.sorted()

        var models = Set(bundled.supplement.pricing.keys)
        models.formUnion(stride(from: 0, to: primaryKeys.count, by: 40).map { primaryKeys[$0] })
        models.formUnion(stride(from: 0, to: secondaryKeys.count, by: 40).map { secondaryKeys[$0] })
        models.formUnion(stride(from: 0, to: openRouterKeys.count, by: 20).map { openRouterKeys[$0] })
        models.formUnion([
            "claude-opus-5.5-thinking",
            "cursor-grok-4.7-high",
            "kimi-k2p7-code",
            "Grok 4.6 (Auto)",
            "gemini-3-pro",
            "gemini-3-pro-preview-high",
            "claude-opus-5-5-fast",
            "gpt-5.5-fast",
            "openai/gpt-5.5",
            "xai/grok-4.3",
            "totally-unknown-model-xyz"
        ])
        let sortedModels = models.sorted()

        let recorder = Recorder()
        let oracle = ModelPricing(
            supplement: bundled.supplement,
            primary: bundled.primary,
            secondary: bundled.secondary,
            openRouter: bundled.openRouter,
            onOpenRouterRecheckModel: { recorder.record($0) }
        )
        let backend = ModelPricing(
            supplement: bundled.supplement,
            primary: bundled.primary,
            secondary: bundled.secondary,
            openRouter: bundled.openRouter
        )

        var expected: [String: ModelRates?] = [:]
        for model in sortedModels {
            expected[model] = oracle.resolve(model: model)
        }
        let (rust, rustRecheck) = try rustResolve(pricing: backend, models: sortedModels)

        for model in sortedModels {
            XCTAssertEqual(
                rust[model] ?? nil,
                expected[model] ?? nil,
                "bundled-catalog rates diverged for `\(model)`"
            )
        }
        XCTAssertEqual(Set(rustRecheck), Set(recorder.drain()),
                       "bundled-catalog discovery candidates diverged")
    }

    // MARK: - Fold parity through the backend pricing path

    private func entries(now: Date) -> [ClaudeEntry] {
        let recent = now.addingTimeInterval(-3_600)
        let earlier = now.addingTimeInterval(-90_000)
        func entry(
            _ timestamp: Date,
            model: String?,
            input: Int = 0,
            output: Int = 0,
            cacheRead: Int = 0,
            costUSD: Double? = nil
        ) -> ClaudeEntry {
            ClaudeEntry(
                timestamp: timestamp,
                tokens: TokenBreakdown(
                    input: input,
                    cacheRead: cacheRead,
                    output: output
                ),
                messageID: nil,
                requestID: nil,
                isSidechain: false,
                hasSpeed: false,
                costUSD: costUSD,
                model: model
            )
        }
        return [
            entry(recent, model: " bench-alias ", input: 1_000_000, output: 10_000),
            entry(recent, model: "bench-base-fast", input: 2_000_000),
            entry(recent, model: "bench-curated", input: 100_000, cacheRead: 50_000),
            entry(recent, model: "bench-free-something", input: 1_000),
            entry(earlier, model: "bench-dated-fast", input: 500_000, output: 5_000),
            entry(earlier, model: "unknown-model", input: 300),
            // Outside the window: dropped from the scan, but still a discovery candidate.
            entry(now.addingTimeInterval(-10 * 86_400), model: "stale-unknown", input: 10)
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

    private func codexEvent(
        _ timestamp: Date,
        model: String,
        total: Int
    ) -> CodexLogUsageScanner.Event {
        CodexLogUsageScanner.Event(
            timestamp: timestamp,
            model: model,
            pricingModel: nil,
            input: total,
            cached: 0,
            output: 0,
            reasoning: 0,
            total: total,
            hasCompleteCostBreakdown: true,
            isFast: false,
            serviceTier: nil
        )
    }

    func testCodexFoldReportsSameDiscoveryCandidatesInBothModes() throws {
        let now = Date()
        let since = now.addingTimeInterval(-3 * 86_400)
        let events = [
            codexEvent(now.addingTimeInterval(-10 * 86_400), model: "stale-codex-unknown", total: 10),
            codexEvent(now.addingTimeInterval(-3_600), model: "bench-canonical", total: 100)
        ]

        let inlineRecorder = Recorder()
        let inlinePricing = Self.syntheticPricing(onRecheck: { inlineRecorder.record($0) })
        var inlineContext = CodexRustFold.FoldContext(
            since: since, pricing: inlinePricing, now: now, mode: .inline
        )
        XCTAssertNotNil(CodexRustFold.fold(events: events, context: &inlineContext))

        let backendRecorder = Recorder()
        let backendPricing = Self.syntheticPricing(onRecheck: { backendRecorder.record($0) })
        var backendContext = CodexRustFold.FoldContext(
            since: since, pricing: backendPricing, now: now, mode: .backend
        )
        XCTAssertNotNil(CodexRustFold.fold(events: events, context: &backendContext))

        XCTAssertEqual(
            Set(inlineRecorder.drain()), Set(backendRecorder.drain()),
            "the fold modes reported different discovery candidates"
        )
        XCTAssertTrue(backendRecorder.drain().contains("stale-codex-unknown"))
    }

    func testClaudeFoldUsesBackendPricingAndMatchesBothOracles() throws {
        let now = Date()
        let since = now.addingTimeInterval(-3 * 86_400)
        let fixture = entries(now: now)

        let inlineRecorder = Recorder()
        let backendRecorder = Recorder()
        let oraclePricing = Self.syntheticPricing()
        let oracle = ClaudeLogUsageScanner.aggregate(
            entries: ClaudeLogUsageScanner.dedup(fixture),
            since: since,
            pricing: oraclePricing
        )

        let inlinePricing = Self.syntheticPricing(onRecheck: { inlineRecorder.record($0) })
        let inline = try XCTUnwrap(ClaudeRustFold.fold(
            entries: fixture, since: since, pricing: inlinePricing, now: now, mode: .inline
        ))

        let backendPricing = Self.syntheticPricing(onRecheck: { backendRecorder.record($0) })
        #if DEBUG
        let loadsBefore = ModelPricing.backendLoadsForTesting
        let backendFoldsBefore = RustFoldSupport.backendPricedFoldsForTesting
        #endif
        let backend = try XCTUnwrap(ClaudeRustFold.fold(
            entries: fixture, since: since, pricing: backendPricing, now: now, mode: .backend
        ))
        #if DEBUG
        XCTAssertGreaterThan(ModelPricing.backendLoadsForTesting, loadsBefore,
                             "the backend fold never loaded a pricing snapshot")
        XCTAssertGreaterThan(RustFoldSupport.backendPricedFoldsForTesting, backendFoldsBefore,
                             "the fold silently fell back to the inline rate table")
        #endif

        XCTAssertEqual(inline, oracle)
        XCTAssertEqual(backend, oracle)
        XCTAssertEqual(renderedLines(for: backend, now: now), renderedLines(for: oracle, now: now))
        XCTAssertEqual(
            Set(inlineRecorder.drain()), Set(backendRecorder.drain()),
            "the fold modes reported different discovery candidates"
        )
        XCTAssertTrue(
            backendRecorder.drain().contains("stale-unknown"),
            "an out-of-window slug must still be offered for discovery"
        )
        XCTAssertEqual(
            Set(oracle.unknownModelsByDay.values.flatMap { $0 }),
            ["unknown-model", "bench-free-something"]
        )
        XCTAssertTrue(
            oracle.modelUsage?.daily.flatMap(\.models).contains { $0.model == "bench-alias" } == true,
            "the emitted slug should keep its own row identity"
        )
    }
}
