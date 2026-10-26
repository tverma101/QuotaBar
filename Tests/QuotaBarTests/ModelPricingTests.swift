import XCTest
@testable import QuotaBar

/// Resolution and cost math for the pricing engine, against small fixture catalogs.
final class ModelPricingTests: XCTestCase {
    private func makePricing(
        supplementJSON: String? = nil,
        primary: [String: ModelRates] = [:],
        secondary: [String: ModelRates] = [:],
        openRouter: [String: ModelRates] = [:]
    ) throws -> ModelPricing {
        let supplement: PricingSupplement
        if let supplementJSON {
            supplement = try PricingSupplement.decode(from: Data(supplementJSON.utf8))
        } else {
            supplement = PricingSupplement()
        }
        return ModelPricing(
            supplement: supplement,
            primary: PricingCatalog(entries: primary),
            secondary: PricingCatalog(entries: secondary),
            openRouter: PricingCatalog(entries: openRouter)
        )
    }

    private func rates(
        _ input: Double, _ output: Double, cacheWrite: Double? = nil, cacheRead: Double? = nil,
        fast: Double = 1
    ) -> ModelRates {
        ModelRates(
            inputPerMillion: input,
            outputPerMillion: output,
            cacheWritePerMillion: cacheWrite ?? input,
            cacheReadPerMillion: cacheRead ?? input,
            fastMultiplier: fast
        )
    }

    // MARK: - Resolution

    func testModelResolutionNormalizesDatesProviderPrefixesAndSeparators() throws {
        let scenarios: [(catalogKey: String, model: String, expected: Double)] = [
            ("gpt-5.5", "gpt-5.5", 5),
            ("claude-sonnet-4-20250514", "claude-sonnet-4", 3),
            ("claude-sonnet-4-5", "claude-sonnet-4-5-20250929", 3),
            ("xai/grok-4.3", "grok-4.3", 1.25),
            ("xai/grok-4.3", "grok-4-3", 1.25)
        ]

        for scenario in scenarios {
            let pricing = try makePricing(primary: [scenario.catalogKey: rates(scenario.expected, 15)])
            XCTAssertEqual(pricing.resolve(model: scenario.model)?.inputPerMillion, scenario.expected, scenario.model)
        }
    }

    func testCursorGeminiRateDoesNotReplacePublicOpenRouterCacheWriteRate() throws {
        let supplement = #"""
        {
          "pricing": {
            "cursor-gemini-4-argon": {
              "input_per_million": 2,
              "output_per_million": 10,
              "cache_write_per_million": 2,
              "cache_read_per_million": 0.1
            }
          },
          "alias_rules": [],
          "cursor_alias_rules": [
            {"pattern":"^gemini-4-argon$","canonical":"gemini-4-argon"},
            {"pattern":"(?i)^Gemini 4 Argon(?: \\(Auto[^)]*\\))?$","canonical":"gemini-4-argon"}
          ]
        }
        """#
        let route = rates(4, 20, cacheWrite: 0.1875, cacheRead: 0.2)
        let pricing = try makePricing(
            supplementJSON: supplement,
            openRouter: ["google/gemini-4-argon": route, "gemini-4-argon": route]
        )
        let cacheWrite = TokenBreakdown(cacheWrite5m: 1_000_000)

        XCTAssertEqual(
            try XCTUnwrap(pricing.estimatedCostDollars(model: "gemini-4-argon", tokens: cacheWrite)),
            0.1875,
            accuracy: 0.000_001,
            "the public API slug uses the OpenRouter route rate"
        )
        XCTAssertEqual(
            try XCTUnwrap(pricing.estimatedCursorCostDollars(model: "Gemini 4 Argon (Auto Balanced)", tokens: cacheWrite)),
            2,
            accuracy: 0.000_001,
            "Cursor's scoped alias uses its own published cache-write rate"
        )
    }

    func testNumericVersionsDoNotConflate() throws {
        // claude-sonnet-4 must not price as claude-sonnet-4-5 (or vice versa).
        let pricing = try makePricing(primary: ["claude-sonnet-4-5": rates(3, 15)])
        XCTAssertNil(pricing.resolve(model: "claude-sonnet-4"))
        let reverse = try makePricing(primary: ["claude-sonnet-4": rates(1, 2)])
        XCTAssertNil(reverse.resolve(model: "claude-sonnet-4-5"))
    }

    func testLongestKeyPreferred() throws {
        let pricing = try makePricing(primary: [
            "gemini-3-pro": rates(1, 2),
            "gemini/gemini-3-pro-preview": rates(2, 12)
        ])
        XCTAssertEqual(pricing.resolve(model: "gemini-3-pro-preview")?.inputPerMillion, 2)
    }

    func testSecondaryCatalogFillsGaps() throws {
        let pricing = try makePricing(
            primary: ["gpt-5.5": rates(5, 30)],
            secondary: ["grok-build-0.1": rates(1, 2)]
        )
        XCTAssertEqual(pricing.resolve(model: "grok-build-0.1")?.inputPerMillion, 1)
    }

    func testOpenRouterExactRatesBeatLiteLLMAndSupplementFillsMissingModels() throws {
        let supplement = #"{"pricing":{"gpt-5.6":{"input_per_million":1,"output_per_million":2},"auto":{"input_per_million":3,"output_per_million":4}},"alias_rules":[]}"#
        let pricing = try makePricing(
            supplementJSON: supplement,
            primary: ["gpt-5.6": rates(5, 10)],
            openRouter: ["gpt-5.6": rates(7, 14), "new-model": rates(8, 16)]
        )

        XCTAssertEqual(pricing.resolve(model: "new-model")?.inputPerMillion, 8)
        XCTAssertEqual(pricing.resolve(model: "gpt-5.6")?.inputPerMillion, 1, "curated supplement prices must remain authoritative")
        XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, 3)
    }

    func testCuratedSupplementCacheRatesBeatOpenRouterPromptOnlyRate() throws {
        let supplement = #"{"pricing":{"claude-opus-5":{"input_per_million":5,"output_per_million":25,"cache_write_per_million":6.25,"cache_read_per_million":0.5}},"alias_rules":[]}"#
        let pricing = try makePricing(
            supplementJSON: supplement,
            openRouter: ["claude-opus-5": rates(5, 25, cacheWrite: 5, cacheRead: 5)]
        )

        let resolved = try XCTUnwrap(pricing.resolve(model: "claude-opus-5"))
        XCTAssertEqual(resolved.inputPerMillion, 5)
        XCTAssertEqual(resolved.cacheWritePerMillion, 6.25)
        XCTAssertEqual(resolved.cacheReadPerMillion, 0.5)
    }

    func testOpenRouterCatalogDoesNotFuzzyMatch() throws {
        let pricing = try makePricing(openRouter: ["vendor/gpt-5.6": rates(7, 14)])

        XCTAssertNil(pricing.resolve(model: "gpt-5.6-preview"))
        XCTAssertEqual(pricing.resolve(model: "vendor/gpt-5.6")?.inputPerMillion, 7)
    }

    func testFallbackPricedModelQueuesOneOpenRouterRecheck() {
        let reports = PricingModelReportRecorder()
        let model = "gemini-3.8-flash-n"
        let pricing = ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: ["gemini-3.8-flash": rates(9, 27)]),
            secondary: PricingCatalog(),
            onOpenRouterRecheckModel: { reports.append($0) }
        )

        XCTAssertTrue(pricing.isPriced(model), "the existing LiteLLM fallback remains usable")
        XCTAssertFalse(pricing.hasExactOpenRouterRate(model), "fallback pricing is not an OpenRouter match")
        for _ in 0..<10 {
            XCTAssertEqual(pricing.resolve(model: model)?.inputPerMillion, 9)
        }
        XCTAssertEqual(reports.values, [model], "a repeated ledger row queues one catalog check")
    }

    func testCuratedAndExactOpenRouterPricesDoNotQueueRechecks() {
        let reports = PricingModelReportRecorder()
        let pricing = ModelPricing(
            supplement: PricingSupplement(pricing: ["curated-model": rates(1, 2)]),
            primary: PricingCatalog(entries: ["fallback-model": rates(3, 4)]),
            secondary: PricingCatalog(),
            openRouter: PricingCatalog(entries: ["router-model": rates(5, 6)]),
            onOpenRouterRecheckModel: { reports.append($0) }
        )

        XCTAssertEqual(pricing.resolve(model: "curated-model")?.inputPerMillion, 1)
        XCTAssertEqual(pricing.resolve(model: "router-model")?.inputPerMillion, 5)
        XCTAssertTrue(reports.values.isEmpty)
    }

    func testCodenameSpellingVariantsResolveToCatalogEntries() throws {
        // Stealth/codename models reach the logs with spellings the public catalogues never use
        // verbatim: spaces or underscores where the catalogue hyphenates ("space bunny" vs
        // "space-bunny"). The normalized exact retry closes that gap, so the moment a catalogue
        // lists the codename (OpenRouter's stealth listings carry the real rates) discovery prices
        // it — and the checkpoint invalidation backfills older days. No manual reveal step.
        let pricing = try makePricing(
            openRouter: ["openrouter/space-bunny": rates(7, 14), "space-bunny": rates(7, 14)]
        )
        XCTAssertEqual(pricing.resolve(model: "space bunny")?.inputPerMillion, 7, "spaces normalize to the catalogue's hyphens")
        XCTAssertEqual(pricing.resolve(model: "space_bunny")?.inputPerMillion, 7, "underscores normalize too")
        XCTAssertEqual(pricing.resolve(model: "space-bunny")?.inputPerMillion, 7, "the plain slug keeps working")

        // The hyphenated form wins via the bare OpenRouter alias, and the route-prefixed entry
        // still prices its own exact id.
        XCTAssertEqual(pricing.resolve(model: "openrouter/space-bunny")?.inputPerMillion, 7)

        // Normalization must not invent matches: a distinct slug stays unpriced (discovery reports
        // it instead of fabricating dollars from a look-alike entry).
        let miss = try makePricing(openRouter: ["space-bunny": rates(7, 14)])
        XCTAssertNil(miss.resolve(model: "space bunny 2"))
        XCTAssertNil(miss.resolve(model: "bunny"))
    }

    func testUnknownModelReturnsNil() throws {
        let pricing = try makePricing(primary: ["gpt-5.5": rates(5, 30)])
        XCTAssertNil(pricing.resolve(model: "made-up-model-9000"))
    }

    // MARK: - Supplement precedence, aliases, fast multipliers

    func testSupplementPricingBeatsPublicCatalogs() throws {
        let supplement = """
        {"pricing": {"auto": {"input_per_million": 1.25, "output_per_million": 6.0, "cache_read_per_million": 0.25}}, "alias_rules": []}
        """
        let pricing = try makePricing(
            supplementJSON: supplement,
            primary: ["auto": rates(99, 99)],
            openRouter: ["auto": rates(88, 88)]
        )
        XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, 1.25)
        XCTAssertEqual(pricing.resolve(model: "auto")?.cacheWritePerMillion, 1.25, "cache write defaults to input")
    }

    func testAliasRuleRewritesSlug() throws {
        let supplement = """
        {"pricing": {}, "alias_rules": [
            {"pattern": "^claude-4\\\\.5-sonnet(?:-thinking)?$", "canonical": "claude-sonnet-4-5"}
        ]}
        """
        let pricing = try makePricing(supplementJSON: supplement, primary: ["claude-sonnet-4-5": rates(3, 15)])
        XCTAssertEqual(pricing.resolve(model: "claude-4.5-sonnet-thinking")?.inputPerMillion, 3)
    }

    func testAliasMissFallsBackToRawName() throws {
        let supplement = """
        {"pricing": {}, "alias_rules": [{"pattern": "^gpt-x$", "canonical": "key-not-anywhere"}]}
        """
        let pricing = try makePricing(supplementJSON: supplement, primary: ["gpt-x": rates(1, 2)])
        XCTAssertEqual(pricing.resolve(model: "gpt-x")?.inputPerMillion, 1)
    }

    func testFastSuffixUsesSupplementMultiplier() throws {
        let supplement = """
        {"pricing": {}, "fast_multipliers": {"gpt-5.5": 2.5}, "alias_rules": []}
        """
        let pricing = try makePricing(supplementJSON: supplement, primary: ["gpt-5.5": rates(5, 30, cacheRead: 0.5)])
        let fast = pricing.resolve(model: "gpt-5.5-fast")
        XCTAssertEqual(fast?.inputPerMillion, 12.5)
        XCTAssertEqual(fast?.outputPerMillion, 75)
        XCTAssertEqual(fast?.cacheReadPerMillion, 1.25)
    }

    func testFastSuffixUsesEntryMultiplier() throws {
        let pricing = try makePricing(primary: ["claude-opus-4-6": rates(5, 25, fast: 6)])
        let fast = pricing.resolve(model: "claude-opus-4-6-fast")
        XCTAssertEqual(fast?.inputPerMillion, 30)
        XCTAssertEqual(fast?.fastMultiplier, 1, "multiplier folded into the scaled rates")
    }

    func testFastSuffixWithoutMultiplierReturnsNil() throws {
        let pricing = try makePricing(primary: ["gpt-9": rates(1, 2)])
        XCTAssertNil(pricing.resolve(model: "gpt-9-fast"))
    }

    func testFastSuffixWithoutMultiplierUsesSecondaryExactEntry() throws {
        let pricing = try makePricing(
            primary: ["gpt-9": rates(1, 2)],
            secondary: ["gpt-9-fast": rates(2.5, 5)]
        )
        XCTAssertEqual(pricing.resolve(model: "gpt-9-fast")?.inputPerMillion, 2.5)
    }

    func testDatedBaseKeyStillFindsFastMultiplier() throws {
        let supplement = """
        {"pricing": {}, "fast_multipliers": {"gpt-5.5": 2.5}, "alias_rules": []}
        """
        let pricing = try makePricing(supplementJSON: supplement, primary: ["gpt-5.5-20260423": rates(5, 30)])
        XCTAssertEqual(pricing.resolve(model: "gpt-5.5-fast")?.inputPerMillion, 12.5)
    }

    func testDatedFastBasePrefersNewestCatalogDate() throws {
        let supplement = """
        {"pricing": {}, "fast_multipliers": {"gpt-5.5": 2.5}, "alias_rules": []}
        """
        let pricing = try makePricing(supplementJSON: supplement, primary: [
            "gpt-5.5-20250423": rates(2, 8),
            "gpt-5.5-20260423": rates(5, 30)
        ])
        XCTAssertEqual(pricing.resolve(model: "gpt-5.5-fast")?.inputPerMillion, 12.5)
        XCTAssertEqual(pricing.resolve(model: "gpt-5.5-fast")?.outputPerMillion, 75)
    }

    func testDatedFastMultiplierChoosesMostSpecificBase() throws {
        let supplement = """
        {"pricing": {}, "fast_multipliers": {"gpt-5": 2, "gpt-5.5": 2.5}, "alias_rules": []}
        """
        let pricing = try makePricing(supplementJSON: supplement)

        XCTAssertEqual(pricing.supplement.fastMultiplier(for: "gpt-5.5-2026-04-23"), 2.5)
    }

    func testFastVariantDoesNotBorrowFuzzySiblingRates() throws {
        let supplement = """
        {"pricing": {}, "fast_multipliers": {"gpt-9": 2}, "alias_rules": []}
        """
        let pricing = try makePricing(
            supplementJSON: supplement,
            primary: ["gpt-9-pro": rates(5, 30)]
        )

        XCTAssertNil(pricing.resolve(model: "gpt-9-fast"))
    }

    func testFreeSuffixDoesNotBorrowPaidFuzzySiblingRates() throws {
        let pricing = try makePricing(primary: ["gpt-5.5": rates(5, 30)])
        XCTAssertNil(pricing.resolve(model: "gpt-5.5-free"))
    }

    func testCatalogCodecsPreserveSynthesizedCacheReadProvenance() throws {
        let source = Data(#"""
        {
            "explicit": {
                "input_cost_per_token": 0.000005,
                "output_cost_per_token": 0.00003,
                "cache_read_input_token_cost": 0.0000005
            },
            "missing": {
                "input_cost_per_token": 0.000005,
                "output_cost_per_token": 0.00003
            }
        }
        """#.utf8)

        let decoded = try PricingCatalogCodecs.catalogFromLiteLLM(source)
        let explicitRates = try XCTUnwrap(decoded.entries["explicit"])
        let missingRates = try XCTUnwrap(decoded.entries["missing"])
        XCTAssertTrue(explicitRates.cacheReadIsExplicit)
        XCTAssertFalse(missingRates.cacheReadIsExplicit)
        XCTAssertEqual(missingRates.cacheReadPerMillion, missingRates.inputPerMillion)
        XCTAssertEqual(
            missingRates.costDollars(for: TokenBreakdown(cacheRead: 1_000_000)),
            missingRates.inputPerMillion,
            accuracy: 0.000_001,
            "a missing published cache-read rate must not invent a discount"
        )

        let restored = try PricingCatalogCodecs.catalogFromCompact(
            PricingCatalogCodecs.compactData(from: decoded)
        )
        XCTAssertTrue(try XCTUnwrap(restored.entries["explicit"]).cacheReadIsExplicit)
        XCTAssertFalse(try XCTUnwrap(restored.entries["missing"]).cacheReadIsExplicit)
        XCTAssertEqual(try XCTUnwrap(restored.entries["missing"]).cacheReadPerMillion, missingRates.inputPerMillion)
    }

    func testLiteLLMImportsAllPublishedPromptThresholdsAndRoundTripsThem() throws {
        let source = Data(#"""
        {
          "tiered": {
            "input_cost_per_token": 0.000001,
            "output_cost_per_token": 0.000002,
            "cache_creation_input_token_cost": 0.00000125,
            "cache_read_input_token_cost": 0.0000001,
            "input_cost_per_token_above_200k_tokens": 0.000002,
            "output_cost_per_token_above_200k_tokens": 0.000003,
            "cache_creation_input_token_cost_above_200k_tokens": 0.0000025,
            "cache_read_input_token_cost_above_200k_tokens": 0.0000002,
            "input_cost_per_token_above_272k_tokens": 0.000003,
            "output_cost_per_token_above_272k_tokens": 0.0000045,
            "cache_creation_input_token_cost_above_272k_tokens": 0.00000375,
            "cache_read_input_token_cost_above_272k_tokens": 0.0000003
          }
        }
        """#.utf8)

        let catalog = try PricingCatalogCodecs.catalogFromLiteLLM(source)
        let rates = try XCTUnwrap(catalog.entries["tiered"])
        XCTAssertEqual(rates.promptRateTiers.map(\.thresholdPromptTokens), [200_000, 272_000])
        XCTAssertEqual(try XCTUnwrap(rates.promptRateTiers.last?.inputPerMillion), 3, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(rates.promptRateTiers.last?.cacheWritePerMillion), 3.75, accuracy: 0.000_001)

        let restored = try PricingCatalogCodecs.catalogFromCompact(PricingCatalogCodecs.compactData(from: catalog))
        XCTAssertEqual(restored.entries["tiered"]?.promptRateTiers, rates.promptRateTiers)
    }

    func testModelsDevImportsContextTiersAndOmitsConflictingDuplicateIDs() throws {
        let source = Data(#"""
        {
          "provider-a": {"models": {
            "tiered": {"cost": {
              "input": 1, "output": 2, "cache_read": 0.1,
              "tiers": [
                {"input": 2, "output": 3, "cache_read": 0.2, "tier": {"type": "context", "size": 32000}},
                {"input": 3, "output": 4, "cache_read": 0.3, "tier": {"type": "context", "size": 128000}}
              ],
              "context_over_200k": {"input": 4, "output": 5, "cache_read": 0.4}
            }},
            "ambiguous": {"cost": {"input": 1, "output": 2}}
          }},
          "provider-b": {"models": {
            "tiered": {"cost": {
              "input": 1, "output": 2, "cache_read": 0.1,
              "tiers": [
                {"input": 2, "output": 3, "cache_read": 0.2, "tier": {"type": "context", "size": 32000}},
                {"input": 3, "output": 4, "cache_read": 0.3, "tier": {"type": "context", "size": 128000}}
              ],
              "context_over_200k": {"input": 4, "output": 5, "cache_read": 0.4}
            }},
            "ambiguous": {"cost": {"input": 9, "output": 9}}
          }}
        }
        """#.utf8)

        let catalog = try PricingCatalogCodecs.catalogFromModelsDev(source)
        let tieredRates = try XCTUnwrap(catalog.entries["tiered"])
        XCTAssertEqual(tieredRates.promptRateTiers.map(\.thresholdPromptTokens), [32_000, 128_000, 200_000])
        XCTAssertEqual(tieredRates.promptRateTiers.last?.inputPerMillion, 4)
        XCTAssertTrue(try XCTUnwrap(tieredRates.promptRateTiers.first?.includesThreshold))
        XCTAssertEqual(
            tieredRates.costDollars(for: TokenBreakdown(input: 32_000)),
            0.064,
            accuracy: 0.000_001,
            "models.dev context tiers begin at the stated threshold"
        )
        XCTAssertNil(catalog.entries["ambiguous"], "different reseller prices must not pick an arbitrary provider")
        XCTAssertEqual(catalog.retiredKeys, Set(["ambiguous"]))
        XCTAssertTrue(catalog.retiredKeysAreAuthoritative)

        let restored = try PricingCatalogCodecs.catalogFromCompact(PricingCatalogCodecs.compactData(from: catalog))
        XCTAssertTrue(restored.retiredKeysAreAuthoritative)
        let withOldBundle = PricingCatalog(entries: ["ambiguous": rates(7, 9)]).merging(restored)
        XCTAssertNil(withOldBundle.entries["ambiguous"], "the live conflict tombstone must beat an older bundled rate")
    }

    func testModelsDevUsesExplicitPromptTierCacheReadRateWithoutBaseCacheRate() throws {
        let source = Data(#"{"provider":{"models":{"tiered":{"cost":{"input":1,"output":2,"tiers":[{"input":3,"output":4,"cache_read":0.5,"tier":{"type":"context","size":1000}}]}}}}}"#.utf8)

        let catalog = try PricingCatalogCodecs.catalogFromModelsDev(source)
        let rates = try XCTUnwrap(catalog.entries["tiered"])

        XCTAssertTrue(rates.cacheReadIsExplicit)
        XCTAssertEqual(rates.costDollars(for: TokenBreakdown(input: 1_000, cacheRead: 2_000)), 0.004, accuracy: 0.000_001)
    }

    func testLiteLLMTierOnlyCacheReadRateIsExplicitAndSurvivesCompaction() throws {
        let source = Data(#"{"tiered":{"input_cost_per_token":0.000001,"output_cost_per_token":0.000002,"cache_read_input_token_cost_above_272k_tokens":0.0000002}}"#.utf8)

        let catalog = try PricingCatalogCodecs.catalogFromLiteLLM(source)
        let original = try XCTUnwrap(catalog.entries["tiered"])
        XCTAssertTrue(original.cacheReadIsExplicit)

        let compact = try PricingCatalogCodecs.compactData(from: catalog)
        let restored = try XCTUnwrap(PricingCatalogCodecs.catalogFromCompact(compact).entries["tiered"])
        XCTAssertTrue(restored.cacheReadIsExplicit)
        XCTAssertEqual(
            restored.costDollars(for: TokenBreakdown(cacheRead: 272_001)),
            272_001 * 0.2 / 1_000_000,
            accuracy: 0.000_001
        )
    }

    func testOpenRouterCodecAddsOnlyUniqueBaseAliasesAndKeepsVariantPricingExact() throws {
        let source = Data(#"""
        {
          "data": [
            {"id":"vendor/model-a","pricing":{"prompt":"0.000003","completion":"0.000012"}},
            {"id":"vendor/model-a:free","pricing":{"prompt":"0","completion":"0"}},
            {"id":"vendor/ambiguous","pricing":{"prompt":0.000004,"completion":0.000016}},
            {"id":"other/ambiguous","pricing":{"prompt":0.000006,"completion":0.000018}},
            {"id":"vendor/bad","pricing":{"prompt":-1,"completion":"NaN"}}
          ],
          "total_count": 5,
          "links": {"next": null}
        }
        """#.utf8)

        let catalog = try PricingCatalogCodecs.catalogFromOpenRouter(source)

        XCTAssertEqual(catalog.findExact("vendor/model-a")?.rates.inputPerMillion, 3)
        XCTAssertEqual(catalog.findExact("model-a")?.rates.inputPerMillion, 3)
        XCTAssertEqual(catalog.findExact("vendor/model-a:free")?.rates.inputPerMillion, 0)
        XCTAssertNil(catalog.findExact("ambiguous"), "ambiguous bare ids must not pick a route price")
        XCTAssertNil(catalog.findExact("bad"), "invalid rates must be skipped")
        let rates = try XCTUnwrap(catalog.findExact("model-a")?.rates)
        XCTAssertEqual(rates.cacheReadPerMillion, 3, "unknown caching must not assume a discount")
        XCTAssertFalse(rates.cacheReadIsExplicit)
    }

    func testOpenRouterCachePricesAndMultiplePromptTiersSurviveCompactCaching() throws {
        let source = Data(#"""
        {
          "data": [
            {
              "id": "qwen/qwen3.7-flash",
              "pricing": {
                "prompt": "0.00000003",
                "completion": "0.00000013",
                "input_cache_read": "0.000000006",
                "input_cache_write": "0.000000038",
                "input_cache_write_1h": "0.00000006",
                "overrides": [
                  {
                    "min_prompt_tokens": 32000,
                    "prompt": "0.0000001",
                    "completion": "0.0000004",
                    "input_cache_read": "0.00000002",
                    "input_cache_write": "0.000000125",
                    "input_cache_write_1h": "0.0000002"
                  },
                  {
                    "min_prompt_tokens": 256000,
                    "prompt": "0.0000002",
                    "completion": "0.0000008",
                    "input_cache_read": "0.00000004",
                    "input_cache_write": "0.00000025",
                    "input_cache_write_1h": "0.0000005"
                  },
                  {"utc_days": ["monday"], "prompt": "0.0001", "completion": "0.0002"}
                ]
              }
            }
          ],
          "total_count": 1,
          "links": {"next": null}
        }
        """#.utf8)

        let fetched = try PricingCatalogCodecs.catalogFromOpenRouter(source)
        let original = try XCTUnwrap(fetched.findExact("qwen/qwen3.7-flash")?.rates)
        XCTAssertEqual(original.cacheWritePerMillion, 0.038, accuracy: 0.000_001)
        XCTAssertEqual(original.cacheReadPerMillion, 0.006, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(original.cacheWrite1hPerMillion), 0.06, accuracy: 0.000_001)
        XCTAssertTrue(original.cacheReadIsExplicit)
        XCTAssertEqual(original.promptRateTiers.count, 2, "time-of-day overrides are not prompt-length tiers")
        XCTAssertEqual(original.utcPriceOverrides?.count, 1, "UTC-day rates are retained separately from prompt tiers")
        XCTAssertTrue(original.promptRateTiers[0].includesThreshold)

        let cached = try PricingCatalogCodecs.catalogFromCompact(
            PricingCatalogCodecs.compactData(from: fetched)
        )
        let restored = try XCTUnwrap(cached.findExact("qwen/qwen3.7-flash")?.rates)
        XCTAssertEqual(restored, original)

        XCTAssertEqual(
            original.costDollars(for: TokenBreakdown(input: 31_999)),
            Double(31_999) * 0.03 / 1_000_000,
            accuracy: 0.000_000_001
        )
        XCTAssertEqual(
            original.costDollars(for: TokenBreakdown(input: 32_000)),
            32_000 * 0.1 / 1_000_000,
            accuracy: 0.000_000_001,
            "OpenRouter's min_prompt_tokens threshold is inclusive"
        )
        XCTAssertEqual(
            original.costDollars(for: TokenBreakdown(input: 256_000)),
            256_000 * 0.2 / 1_000_000,
            accuracy: 0.000_000_001
        )

        var allBuckets = TokenBreakdown(input: 1_000_000, cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        XCTAssertEqual(original.costDollars(for: allBuckets), 1.79, accuracy: 0.000_001)
        allBuckets.isFast = true
        XCTAssertEqual(original.costDollars(for: allBuckets), 1.79, accuracy: 0.000_001)
    }

    func testOpenRouterUTCPriceWindowsApplyByEventTimestampAndSurviveCache() throws {
        let source = Data(#"""
        {
          "data": [{
            "id": "deepseek/deepseek-v4.1-flash-1017",
            "pricing": {
              "prompt": "0.00000015",
              "completion": "0.0000006",
              "input_cache_read": "0.000000003",
              "overrides": [
                {"utc_days":["saturday","sunday"],"prompt":"0.00000015","completion":"0.0000006","input_cache_read":"0.000000003"},
                {"utc_days":["monday","tuesday","wednesday","thursday","friday"],"utc_start":100,"utc_end":400,"prompt":"0.0000003","completion":"0.0000012","input_cache_read":"0.000000006"},
                {"utc_days":["monday","tuesday","wednesday","thursday","friday"],"utc_start":400,"utc_end":600,"prompt":"0.00000015","completion":"0.0000006","input_cache_read":"0.000000003"},
                {"utc_days":["monday","tuesday","wednesday","thursday","friday"],"utc_start":600,"utc_end":1000,"prompt":"0.0000003","completion":"0.0000012","input_cache_read":"0.000000006"},
                {"utc_days":["monday","tuesday","wednesday","thursday","friday"],"utc_start":1000,"utc_end":0,"prompt":"0.00000015","completion":"0.0000006","input_cache_read":"0.000000003"}
              ]
            }
          }],
          "total_count": 1,
          "links": {"next": null}
        }
        """#.utf8)

        let catalog = try PricingCatalogCodecs.catalogFromOpenRouter(source)
        let cached = try PricingCatalogCodecs.catalogFromCompact(PricingCatalogCodecs.compactData(from: catalog))
        let rates = try XCTUnwrap(cached.findExact("deepseek/deepseek-v4.1-flash-1017")?.rates)
        let tokens = TokenBreakdown(input: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        let formatter = ISO8601DateFormatter()
        let peak = try XCTUnwrap(formatter.date(from: "2026-10-26T02:00:00Z"))
        let offPeak = try XCTUnwrap(formatter.date(from: "2026-10-26T04:00:00Z"))
        let weekend = try XCTUnwrap(formatter.date(from: "2026-10-25T02:00:00Z"))

        XCTAssertEqual(rates.costDollars(for: tokens, at: peak), 1.506, accuracy: 0.000_001)
        XCTAssertEqual(rates.costDollars(for: tokens, at: offPeak), 0.753, accuracy: 0.000_001)
        XCTAssertEqual(rates.costDollars(for: tokens, at: weekend), 0.753, accuracy: 0.000_001)
        XCTAssertEqual(rates.utcPriceOverrides?.last?.utcEndMinute, 1_440,
                       "an end of 00:00 after a daytime start denotes midnight at the end of that day")
    }

    func testOpenRouterGPT61Sol272KBoundaryIsExclusiveForStandardAndBatch() throws {
        let source = Data(#"""
        {
          "data": [
            {
              "id": "openai/gpt-6.1-sol",
              "pricing": {
                "prompt": "0.000002", "completion": "0.00001",
                "overrides": [{"min_prompt_tokens":272000,"prompt":"0.000004","completion":"0.000015"}]
              }
            },
            {
              "id": "openai/gpt-6.1-sol:batch",
              "pricing": {
                "prompt": "0.000001", "completion": "0.000005",
                "overrides": [{"min_prompt_tokens":272000,"prompt":"0.000002","completion":"0.0000075"}]
              }
            },
            {
              "id": "vendor/other-model",
              "pricing": {
                "prompt": "0.000001", "completion": "0.000002",
                "overrides": [{"min_prompt_tokens":32000,"prompt":"0.000003","completion":"0.000004"}]
              }
            }
          ],
          "total_count": 3,
          "links": {"next": null}
        }
        """#.utf8)

        let catalog = try PricingCatalogCodecs.catalogFromOpenRouter(source)
        let standard = try XCTUnwrap(catalog.findExact("openai/gpt-6.1-sol")?.rates)
        let batch = try XCTUnwrap(catalog.findExact("openai/gpt-6.1-sol:batch")?.rates)
        let ordinary = try XCTUnwrap(catalog.findExact("vendor/other-model")?.rates)

        XCTAssertFalse(try XCTUnwrap(standard.promptRateTiers.first).includesThreshold)
        XCTAssertFalse(try XCTUnwrap(batch.promptRateTiers.first).includesThreshold)
        XCTAssertEqual(standard.costDollars(for: TokenBreakdown(input: 272_000)), 0.544, accuracy: 0.000_001)
        XCTAssertEqual(standard.costDollars(for: TokenBreakdown(input: 272_001)), 1.088004, accuracy: 0.000_001)
        XCTAssertEqual(batch.costDollars(for: TokenBreakdown(input: 272_000)), 0.272, accuracy: 0.000_001)
        XCTAssertEqual(batch.costDollars(for: TokenBreakdown(input: 272_001)), 0.544002, accuracy: 0.000_001)
        XCTAssertTrue(try XCTUnwrap(ordinary.promptRateTiers.first).includesThreshold,
                      "other OpenRouter min_prompt_tokens tiers remain inclusive")
        XCTAssertEqual(ordinary.costDollars(for: TokenBreakdown(input: 32_000)), 0.096, accuracy: 0.000_001)
    }

    func testOpenRouterCodecRejectsIncompletePaginatedFeed() {
        let source = Data(#"{"data":[{"id":"vendor/model","pricing":{"prompt":"0.000001","completion":"0.000002"}}],"total_count":2,"links":{"next":"/api/v1/models?offset=1"}}"#.utf8)

        XCTAssertThrowsError(try PricingCatalogCodecs.catalogFromOpenRouter(source)) { error in
            XCTAssertEqual(error as? PricingCodecError, .incompleteModelList)
        }
    }

    func testLegacyCompactCatalogTreatsUnmarkedCacheReadAsExplicit() throws {
        // Snapshots created before `cre` existed cannot distinguish source and synthesized rates.
        // Treating omission as explicit preserves their historical behavior; refreshed snapshots
        // carry `cre: false` whenever a source omits the rate.
        let legacy = Data(#"{"models":{"gpt-test":{"i":5,"o":30,"cw":5,"cr":0.5}}}"#.utf8)

        let decoded = try PricingCatalogCodecs.catalogFromCompact(legacy)

        XCTAssertTrue(try XCTUnwrap(decoded.entries["gpt-test"]).cacheReadIsExplicit)
    }

    // MARK: - Cost math

    func testCostUsesAllTokenBuckets() throws {
        let entry = ModelRates(
            inputPerMillion: 3, outputPerMillion: 15,
            cacheWritePerMillion: 3.75, cacheReadPerMillion: 0.3
        )
        let pricing = try makePricing(primary: ["claude-sonnet-4-5": entry])
        let tokens = TokenBreakdown(input: 1_000_000, cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        // input 3 + cacheWrite5m 3.75 + cacheWrite1h (3x2=6) + cacheRead 0.3 + output 15 = 28.05
        XCTAssertEqual(pricing.estimatedCostDollars(model: "claude-sonnet-4-5", tokens: tokens)!, 28.05, accuracy: 0.0001)
    }

    func testLongContextRatesApplyOnlyWhenPromptExceedsTheThreshold() throws {
        var entry = ModelRates(inputPerMillion: 3, outputPerMillion: 15, cacheWritePerMillion: 3.75, cacheReadPerMillion: 0.3)
        entry.inputAbove200kPerMillion = 6
        entry.outputAbove200kPerMillion = 22.5
        let pricing = try makePricing(primary: ["claude-sonnet-4-5": entry])
        let scenarios: [(name: String, tokens: TokenBreakdown, expected: Double)] = [
            ("above threshold", TokenBreakdown(input: 300_000), 1.8),
            ("exactly at threshold", TokenBreakdown(input: 200_000, output: 10_000), 0.75),
            ("large output alone", TokenBreakdown(input: 10_000, output: 300_000), 4.53)
        ]

        for scenario in scenarios {
            let actual = try XCTUnwrap(pricing.estimatedCostDollars(model: "claude-sonnet-4-5", tokens: scenario.tokens))
            XCTAssertEqual(actual, scenario.expected, accuracy: 0.0001, scenario.name)
        }
    }

    func testCombinedPromptBucketsSelectLongContextRatesForEveryBucket() throws {
        var entry = ModelRates(inputPerMillion: 3, outputPerMillion: 15, cacheWritePerMillion: 3.75, cacheReadPerMillion: 0.3)
        entry.inputAbove200kPerMillion = 6
        entry.outputAbove200kPerMillion = 22.5
        entry.cacheWriteAbove200kPerMillion = 7.5
        entry.cacheReadAbove200kPerMillion = 0.6
        let pricing = try makePricing(primary: ["claude-sonnet-4-5": entry])
        let tokens = TokenBreakdown(input: 100_000, cacheWrite5m: 60_000, cacheRead: 50_000, output: 20_000)

        // The 210k prompt selects the higher tier for input, cache, and output alike.
        let expected = 0.6 + 0.45 + 0.03 + 0.45
        XCTAssertEqual(pricing.estimatedCostDollars(model: "claude-sonnet-4-5", tokens: tokens)!, expected, accuracy: 0.0001)
    }

    func testCustomLongContextThresholdUsesWholeRequestRates() {
        var entry = ModelRates(
            inputPerMillion: 5,
            outputPerMillion: 30,
            cacheWritePerMillion: 5,
            cacheReadPerMillion: 0.5
        )
        entry.inputAbove200kPerMillion = 10
        entry.outputAbove200kPerMillion = 45
        entry.cacheReadAbove200kPerMillion = 1
        entry.longContextThresholdTokens = 272_000

        let atThreshold = TokenBreakdown(input: 200_000, cacheRead: 72_000, output: 1_000)
        let overThreshold = TokenBreakdown(input: 200_001, cacheRead: 72_000, output: 1_000)

        XCTAssertEqual(entry.costDollars(for: atThreshold), 1.066, accuracy: 0.000_001)
        XCTAssertEqual(entry.costDollars(for: overThreshold), 2.117_01, accuracy: 0.000_001)
    }

    func testCostWithoutTierRatesUsesBaseRateThroughout() throws {
        let pricing = try makePricing(primary: ["gpt-5.5": rates(5, 30)])
        let tokens = TokenBreakdown(input: 300_000)
        XCTAssertEqual(pricing.estimatedCostDollars(model: "gpt-5.5", tokens: tokens)!, 1.5, accuracy: 0.0001)
    }

    func testFastSpeedAppliesEntryMultiplier() throws {
        let pricing = try makePricing(primary: ["claude-opus-4-6": rates(5, 25, fast: 6)])
        var tokens = TokenBreakdown(input: 1_000_000)
        XCTAssertEqual(pricing.estimatedCostDollars(model: "claude-opus-4-6", tokens: tokens)!, 5, accuracy: 0.0001)
        tokens.isFast = true
        XCTAssertEqual(pricing.estimatedCostDollars(model: "claude-opus-4-6", tokens: tokens)!, 30, accuracy: 0.0001)
    }

    func testUnknownModelCostIsNil() throws {
        let pricing = try makePricing()
        XCTAssertNil(pricing.estimatedCostDollars(model: "mystery", tokens: TokenBreakdown(input: 100)))
    }
}

private final class PricingModelReportRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func append(_ value: String) {
        lock.withLock { recorded.append(value) }
    }

    var values: [String] {
        lock.withLock { recorded }
    }
}
