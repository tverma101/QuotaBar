import XCTest
@testable import QuotaBar

/// Guards the shipped pricing resources: the bundled supplement and snapshots must load, and every
/// alias canonical must resolve against them — so a LiteLLM/models.dev key rename or a supplement
/// typo fails CI instead of silently pricing models at $0.
final class PricingBundledResourceTests: XCTestCase {
    private static let pricing = TestPricing.bundled

    func testBundledResourcesLoadAndAreNonTrivial() {
        let pricing = Self.pricing
        XCTAssertGreaterThan(pricing.primary.entries.count, 500, "LiteLLM snapshot suspiciously small")
        XCTAssertGreaterThan(pricing.secondary.entries.count, 500, "models.dev snapshot suspiciously small")
        XCTAssertFalse(pricing.supplement.pricing.isEmpty)
        XCTAssertFalse(pricing.supplement.aliasRules.isEmpty)
    }

    func testEveryAliasCanonicalResolves() {
        let pricing = Self.pricing
        for rule in pricing.supplement.aliasRules {
            XCTAssertNotNil(
                pricing.resolve(model: rule.canonical),
                "alias canonical '\(rule.canonical)' resolves against no pricing source"
            )
        }
    }

    func testCursorScopedPricingAliasesResolveToTheirCursorRates() throws {
        let pricing = Self.pricing
        for model in [
            "grok-4.7",
            "grok-4.7-fast",
            "Grok 4.7 (Auto Balanced)",
            "Gemini 4 Argon (Auto Balanced)"
        ] {
            XCTAssertNotNil(pricing.cursorCanonicalName(for: model), model)
            XCTAssertNotNil(
                pricing.estimatedCursorCostDollars(model: model, tokens: TokenBreakdown(input: 1_000_000)),
                model
            )
        }
    }

    func testEveryFastMultiplierBaseResolves() {
        let pricing = Self.pricing
        for base in Self.pricing.supplement.fastMultipliers.keys {
            XCTAssertNotNil(pricing.resolve(model: base), "fast-multiplier base '\(base)' resolves nowhere")
        }
    }

    /// Spot-check Cursor CSV slugs end to end against known rates (the old manifest's assertions,
    /// now against live catalogs — update the constants if the providers themselves reprice).
    func testKnownCursorSlugsPriceCorrectly() {
        let pricing = Self.pricing
        let expectedInputRates: [(String, Double)] = [
            ("auto", 1.25), ("claude-4.5-sonnet-thinking", 3),
            ("claude-4.6-opus-max-thinking", 5), ("claude-4.6-opus-max-thinking-fast", 30),
            ("gpt-5.5-xhigh-fast", 12.5),
            ("gpt-5.6-sol-ultra", 4), ("gpt-5.6-sol-ultra-fast", 8),
            ("gpt-5.6-terra-high", 2), ("gpt-5.6-terra-high-fast", 4),
            ("gpt-5.6-luna", 0.2), ("gpt-5.6-luna-fast", 0.4),
            ("gemini-3.6-flash-high", 1.5), ("gemini-3.7-flash-high", 0.75),
            ("grok-4-20-thinking", 1.25), ("grok-4.5", 2),
            ("grok-4.5-fast-high", 4), ("grok-4.5-high-fast", 4),
            ("cursor-grok-4.5-high-fast", 4), ("cursor-grok-4.6-high", 2),
            ("cursor-grok-4.6-high-fast", 4), ("grok-4-6-xhigh", 2),
            ("grok-4-6-xhigh-fast", 4), ("kimi-k2p5", 0.6),
            ("kimi-k2.7-code", 0.95), ("kimi-k2p7", 0.95), ("kimi-k3-max", 3),
            ("claude-4.7-opus-high-thinking", 5), ("claude-4.7-opus-max-thinking-fast", 30),
            ("glm-5.2-max", 1.4)
        ]
        for (model, expected) in expectedInputRates {
            XCTAssertEqual(pricing.resolve(model: model)?.inputPerMillion, expected, model)
        }
        XCTAssertEqual(pricing.resolve(model: "gemini-3.7-flash-high")?.outputPerMillion, 3.75)
        XCTAssertEqual(pricing.resolve(model: "github_bugbot")?.outputPerMillion, 30)
        XCTAssertEqual(pricing.resolve(model: "Premium (GPT-5.3-Codex)")?.inputPerMillion, 1.75)
    }

    /// Raw model ids as they appear in Claude/Codex/Grok logs (no alias rewriting).
    func testKnownLogModelIDsPriceCorrectly() {
        let pricing = Self.pricing
        XCTAssertEqual(pricing.resolve(model: "claude-sonnet-4-5-20250929")?.inputPerMillion, 3)
        XCTAssertEqual(pricing.resolve(model: "claude-opus-4-1-20250805")?.inputPerMillion, 15)
        XCTAssertNotNil(pricing.resolve(model: "gpt-5.1-codex"))
        XCTAssertEqual(pricing.resolve(model: "gpt-daybreak-blue-latest"), pricing.resolve(model: "gpt-5.6-sol"))
        XCTAssertEqual(pricing.resolve(model: "daybreak-blue-latest"), pricing.resolve(model: "gpt-5.6-sol"))
        XCTAssertEqual(pricing.resolve(model: "grok-build-0.1")?.inputPerMillion, 1)
        XCTAssertEqual(pricing.resolve(model: "grok-4.3")?.inputPerMillion, 1.25)
    }

    func testAntigravityGeminiModelVariantsReuseExistingCatalogRates() {
        let pricing = Self.pricing
        let expected: [String: String] = [
            "gemini-2.5-flash-none": "gemini-2.5-flash",
            "gemini-3-flash-a": "gemini-3-flash-preview",
            "gemini-3-flash-b-high": "gemini-3-flash-preview",
            "gemini-3-flash-none-preview": "gemini-3-flash-preview",
            "gemini-3.5-flash-high-preview": "gemini-3.5-flash",
            "gemini-3.6-flash-none": "gemini-3.6-flash",
            "gemini-3.7-flash-xhigh-preview": "gemini-3.7-flash",
            "gemini-3-pro-low": "gemini-3-pro-preview",
            "gemini-3-pro-high-preview": "gemini-3-pro-preview",
            "gemini-3.1-pro-none-preview": "gemini-3.1-pro-preview"
        ]

        for (variant, canonical) in expected {
            XCTAssertEqual(pricing.supplement.canonicalName(for: variant), canonical, "wrong alias for '\(variant)'")
            XCTAssertEqual(pricing.resolve(model: variant), pricing.resolve(model: canonical), "wrong rates for '\(variant)'")
        }
        XCTAssertNil(pricing.supplement.canonicalName(for: "gemini-3-pro"))
    }

    /// Claude Fable 5 (carried over from the old manifest tests): priced at 2x standard Claude 4.8
    /// Opus, with thinking/effort slug variants resolving to the same rates.
    func testClaudeFable5PricingAndAliases() throws {
        let pricing = Self.pricing
        let fable = try XCTUnwrap(pricing.resolve(model: "claude-fable-5-thinking"))
        XCTAssertEqual(pricing.resolve(model: "claude-fable-5-thinking-xhigh"), fable)
        XCTAssertEqual(fable.inputPerMillion, 10.0)
        XCTAssertEqual(fable.outputPerMillion, 50.0)

        let opus48 = try XCTUnwrap(pricing.resolve(model: "claude-opus-4-8"))
        XCTAssertEqual(fable.inputPerMillion, opus48.inputPerMillion * 2)
        XCTAssertEqual(fable.outputPerMillion, opus48.outputPerMillion * 2)
    }

    /// Claude Sonnet 5: Anthropic made the introductory $2/$10 pricing permanent
    /// (anthropic.com/news/claude-sonnet-5), with 1.25x cache writes and 0.1x cache hits; the
    /// catalogues moved off the original $3/$15 standard rate. thinking/effort slugs resolve to
    /// the one canonical entry, which no longer shares Sonnet 4.6's pool rates.
    func testClaudeSonnet5PricingAndAliases() throws {
        let pricing = Self.pricing
        let sonnet5 = try XCTUnwrap(pricing.resolve(model: "claude-sonnet-5-thinking-high"))
        XCTAssertEqual(sonnet5.inputPerMillion, 2.0)
        XCTAssertEqual(sonnet5.outputPerMillion, 10.0)
        XCTAssertEqual(sonnet5.cacheWritePerMillion, 2.5)
        XCTAssertEqual(sonnet5.cacheReadPerMillion, 0.2, accuracy: 0.0001)

        // Sonnet 4.6 keeps the old $3/$15 pool rate; Sonnet 5's permanent intro rate must not
        // collapse into it.
        let sonnet46 = try XCTUnwrap(pricing.resolve(model: "claude-4.6-sonnet"))
        XCTAssertEqual(sonnet46.inputPerMillion, 3.0)
        XCTAssertNotEqual(sonnet5.inputPerMillion, sonnet46.inputPerMillion)
        XCTAssertNotEqual(sonnet5.outputPerMillion, sonnet46.outputPerMillion)
    }

    /// Claude Opus 5: standard Opus-tier rates from the supplement (no public catalog lists it yet),
    /// with the `[1m]`, thinking/effort, and fast slug variants resolving to the right entry.
    func testClaudeOpus5PricingAndAliases() throws {
        let pricing = Self.pricing
        let opus5 = try XCTUnwrap(pricing.resolve(model: "claude-opus-5"))
        XCTAssertEqual(opus5.inputPerMillion, 5.0)
        XCTAssertEqual(opus5.cacheWritePerMillion, 6.25)
        XCTAssertEqual(opus5.cacheReadPerMillion, 0.5)
        XCTAssertEqual(opus5.outputPerMillion, 25.0)
        XCTAssertEqual(pricing.resolve(model: "claude-opus-5[1m]"), opus5)
        XCTAssertEqual(pricing.resolve(model: "claude-opus-5-thinking-xhigh"), opus5)

        let opus5Fast = try XCTUnwrap(pricing.resolve(model: "claude-opus-5-thinking-high-fast"))
        XCTAssertEqual(opus5Fast.inputPerMillion, opus5.inputPerMillion * 2)
        XCTAssertEqual(opus5Fast.outputPerMillion, opus5.outputPerMillion * 2)

        let opus48 = try XCTUnwrap(pricing.resolve(model: "claude-opus-4-8"))
        XCTAssertEqual(opus5.inputPerMillion, opus48.inputPerMillion)
        XCTAssertEqual(opus5.outputPerMillion, opus48.outputPerMillion)
        XCTAssertEqual(opus5.fastMultiplier, opus48.fastMultiplier)
    }

    /// Claude logs signal fast mode with a `speed` field while the model stays `claude-opus-5`, so
    /// the base entry itself must carry the 2x multiplier — the `-fast` slug is never involved.
    func testClaudeOpus5FastModeBillsAtTwiceBaseRate() throws {
        let pricing = Self.pricing
        let opus5 = try XCTUnwrap(pricing.resolve(model: "claude-opus-5"))
        XCTAssertEqual(opus5.fastMultiplier, 2.0)

        let tokens = TokenBreakdown(input: 1_000_000, cacheWrite5m: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        var fastTokens = tokens
        fastTokens.isFast = true
        XCTAssertEqual(opus5.costDollars(for: fastTokens), opus5.costDollars(for: tokens) * 2, accuracy: 0.000_001)
    }

    /// Opus 4.6/4.7 fast mode: same scanner-flagged `speed` path as Opus 5, but these bases resolve
    /// from the LiteLLM catalogue — whose feed dropped the per-entry `fast` field in October 2026 —
    /// so the supplement's `fast_multipliers` pin must supply the 6x onto the catalog-resolved entry.
    /// Guards against a silent 6x under-estimate on speed-flagged requests.
    func testClaudeOpus46And47FastModeBillsAtSixTimesBaseRate() throws {
        let pricing = Self.pricing
        for model in ["claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-6-20260205", "claude-opus-4-7-20260416"] {
            let entry = try XCTUnwrap(pricing.resolve(model: model), model)
            XCTAssertEqual(entry.fastMultiplier, 6.0, model)

            let tokens = TokenBreakdown(input: 1_000_000, cacheWrite5m: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
            var fastTokens = tokens
            fastTokens.isFast = true
            XCTAssertEqual(
                entry.costDollars(for: fastTokens), entry.costDollars(for: tokens) * 6,
                accuracy: 0.000_001, model
            )
        }
        // The dedicated -fast slug keeps scaling off the base card and must not be re-multiplied.
        let fastSlug = try XCTUnwrap(pricing.resolve(model: "claude-opus-4-6-fast"))
        XCTAssertEqual(fastSlug.inputPerMillion, 30.0)
    }

    /// Kimi K3: Cursor's published rates. Cursor lists no separate cache-write fee, so cache writes
    /// bill at the input rate, and the effort suffixes Cursor's CSV uses fold into the one entry.
    func testKimiK3PricingAndAliases() throws {
        let pricing = Self.pricing
        let k3 = try XCTUnwrap(pricing.resolve(model: "kimi-k3"))
        XCTAssertEqual(k3.inputPerMillion, 3.0)
        XCTAssertEqual(k3.cacheWritePerMillion, 3.0)
        XCTAssertEqual(k3.cacheReadPerMillion, 0.3)
        XCTAssertEqual(k3.outputPerMillion, 15.0)
        XCTAssertEqual(pricing.resolve(model: "kimi-k3-max"), k3)
        XCTAssertEqual(pricing.resolve(model: "kimi-k3-high"), k3)
        XCTAssertEqual(pricing.resolve(model: "kimi-k3-code"), k3)
        // K3 must not collapse into the cheaper K2.7 entry.
        XCTAssertNotEqual(pricing.resolve(model: "kimi-k2.7-code"), k3)
    }

    func testCursorGLM53CSVSlugsUsePublishedRates() throws {
        let pricing = Self.pricing
        for version in ["5.3", "5p3", "5-3"] {
            for effort in ["", "-low", "-high", "-max"] {
                let flash = try XCTUnwrap(pricing.resolve(model: "glm-\(version)-flash\(effort)"))
                XCTAssertEqual(flash.inputPerMillion, 0.15)
                XCTAssertEqual(flash.cacheReadPerMillion, 0.029)
                XCTAssertEqual(flash.outputPerMillion, 0.5)
                let base = try XCTUnwrap(pricing.resolve(model: "glm-\(version)\(effort)"))
                XCTAssertEqual(base.inputPerMillion, 1.4)
                XCTAssertEqual(base.cacheReadPerMillion, 0.26)
                XCTAssertEqual(base.outputPerMillion, 4.4)
                XCTAssertNotEqual(flash, base)
            }
        }
        for unknown in ["glm-5p3-flash-fast", "glm-5p3-flash-max-extra", "glm-5p4-flash-low"] {
            XCTAssertNil(pricing.supplement.canonicalName(for: unknown))
        }
    }

    /// Cursor's CSV still carries a bare, unversioned `composer` slug from before the model was
    /// numbered. It maps to the current non-fast Composer so those rows price instead of tripping
    /// the unknown-model warning, and must not pick up the fast variant's higher rates.
    func testBareComposerSlugPricesAsCurrentComposer() throws {
        let pricing = Self.pricing
        let composer = try XCTUnwrap(pricing.resolve(model: "composer"))
        XCTAssertEqual(composer, pricing.resolve(model: "composer-2.5"))
        XCTAssertNotEqual(composer, pricing.resolve(model: "composer-2.5-fast"))
    }

    /// Cursor Router rows name the routed model in prose ("Opus 5 (Auto Balanced)") instead of a
    /// slug, so each label needs its own alias. The mode inside the parentheses is free-form: Cursor
    /// has shipped plain `(Auto)` and `(Auto Balanced)`, and the docs also name Cost and Intelligence.
    func testCursorRouterLabelsPriceAsTheRoutedModel() throws {
        let pricing = Self.pricing
        let expected: [String: String] = [
            "Opus 5 (Auto Balanced)": "claude-opus-5",
            "Claude Opus 5 (Auto)": "claude-opus-5",
            "Opus 4.8 (Auto)": "claude-opus-4-8",
            "Sonnet 5 (Auto Intelligence)": "claude-sonnet-5",
            "Fable 5 (Auto Balanced)": "claude-fable-5",
            "Haiku 4.5 (Auto Cost)": "claude-haiku-4-5",
            "Composer 2.5 (Auto)": "composer-2.5",
            "Composer 2.5 Fast (Auto)": "composer-2.5-fast",
            "Composer 2 (Auto Balanced)": "composer-2",
            "Grok 4.6 (Auto Intelligence)": "grok-4.6",
            "Cursor Grok 4.6 Fast (Auto)": "grok-4.6-fast",
            "Grok 4.5 (Auto Intelligence)": "grok-4.5",
            "Cursor Grok 4.5 Fast (Auto)": "grok-4.5-fast",
            "GPT-5.5 (Auto)": "gpt-5.5",
            "GPT-5.6 Sol (Auto Cost)": "gpt-5.6-sol",
            "GPT-5.6 Luna (Auto)": "gpt-5.6-luna",
            "Gemini 3.1 Pro (Auto Balanced)": "gemini-3.1-pro-preview",
            "Gemini 3.6 Flash (Auto)": "gemini-3.6-flash",
            "Gemini 3.7 Flash (Auto Balanced)": "gemini-3.7-flash",
            "GLM 5.2 (Auto)": "glm-5.2",
            "Kimi K3 (Auto Intelligence)": "kimi-k3"
        ]
        for (label, canonical) in expected {
            XCTAssertEqual(
                pricing.supplement.canonicalName(for: label), canonical,
                "router label '\(label)' should canonicalize to \(canonical)"
            )
            XCTAssertEqual(
                pricing.resolve(model: label), pricing.resolve(model: canonical),
                "router label '\(label)' should price exactly like \(canonical)"
            )
        }
        // A directly picked model keeps its own slug: the router alias must not swallow plain names.
        XCTAssertNil(pricing.supplement.canonicalName(for: "Opus 5"))
    }

    func testGPT56PricingAndAliases() throws {
        let pricing = Self.pricing
        let expectedRates: [(String, [Double])] = [
            ("gpt-5.6-sol-ultra", [4, 5, 0.4, 20]),
            ("gpt-5.6-sol-ultra-fast", [8, 10, 0.8, 40]),
            ("gpt-5.6-terra-high", [2, 2.5, 0.2, 12]),
            ("gpt-5.6-terra-high-fast", [4, 5, 0.4, 24]),
            ("gpt-5.6-luna", [0.2, 0.25, 0.02, 1.2]),
            ("gpt-5.6-luna-fast", [0.4, 0.5, 0.04, 2.4])
        ]
        for (model, expected) in expectedRates {
            let actual = try XCTUnwrap(pricing.resolve(model: model))
            XCTAssertEqual(
                [actual.inputPerMillion, actual.cacheWritePerMillion, actual.cacheReadPerMillion, actual.outputPerMillion],
                expected,
                model
            )
        }
    }

    /// Opus 4.7/4.8 fast modes: Cursor's published rates (supplement overrides) win over the
    /// stale models.dev entries. Per Cursor, 4.8 fast is 3x cheaper per token than 4.7 fast.
    func testOpusFastModeSupplementOverrides() throws {
        let pricing = Self.pricing
        let opus47Fast = try XCTUnwrap(pricing.resolve(model: "claude-opus-4-7-thinking-high-fast"))
        XCTAssertEqual(opus47Fast.inputPerMillion, 30)
        XCTAssertEqual(opus47Fast.cacheWritePerMillion, 37.5)
        XCTAssertEqual(opus47Fast.cacheReadPerMillion, 3)
        XCTAssertEqual(opus47Fast.outputPerMillion, 150)

        let opus48Fast = try XCTUnwrap(pricing.resolve(model: "claude-opus-4-8-thinking-high-fast"))
        XCTAssertEqual(opus48Fast.inputPerMillion, opus47Fast.inputPerMillion / 3)
        XCTAssertEqual(opus48Fast.outputPerMillion, opus47Fast.outputPerMillion / 3)
    }

    /// GLM 5.2: the high/max effort slugs resolve to the shared entry (LiteLLM's Cloudflare listing);
    /// no separate cache-write price, so cache writes bill at the input rate. Slugs outside the
    /// high/max allowlist stay unpriced.
    func testGPT6PricingAndAliases() throws {
        let pricing = Self.pricing
        let expectedRates: [(String, [Double])] = [
            ("gpt-6-luna", [0.1, 0.125, 0.01, 0.5]),
            ("gpt-6-luna-fast", [0.2, 0.25, 0.02, 1.0]),
            ("gpt-6-sol", [2, 2.5, 0.2, 10]),
            ("gpt-6-sol-high", [2, 2.5, 0.2, 10]),
            ("gpt-6-astra", [10, 12.5, 1, 50]),
            ("gpt-6-terra", [2, 2.5, 0.2, 12]),
            ("anthropic/openai/gpt-6-luna", [0.1, 0.125, 0.01, 0.5]),
            ("openai/gpt-6-sol", [2, 2.5, 0.2, 10])
        ]
        for (model, expected) in expectedRates {
            let actual = try XCTUnwrap(pricing.resolve(model: model), model)
            XCTAssertEqual(
                [actual.inputPerMillion, actual.cacheWritePerMillion, actual.cacheReadPerMillion, actual.outputPerMillion],
                expected,
                model
            )
        }
    }

    func testGLM52PricingAndAliases() throws {
        let pricing = Self.pricing
        let glm = try XCTUnwrap(pricing.resolve(model: "glm-5.2-max"))
        XCTAssertEqual(glm.inputPerMillion, 1.4)
        XCTAssertEqual(glm.cacheWritePerMillion, 1.4)
        XCTAssertEqual(glm.cacheReadPerMillion, 0.26)
        XCTAssertEqual(glm.outputPerMillion, 4.4)

        let outputOnly = TokenBreakdown(output: 1_000_000)
        XCTAssertEqual(pricing.estimatedCostDollars(model: "glm-5.2-high", tokens: outputOnly)!, 4.4, accuracy: 1e-9)
        XCTAssertNil(pricing.estimatedCostDollars(model: "glm-5.2-bogus", tokens: outputOnly))
    }

    /// Grok CLI model ids route through the alias rules to their catalog entries.
    func testGrokCLIModelAliases() {
        let pricing = Self.pricing
        XCTAssertEqual(pricing.resolve(model: "grok-build")?.inputPerMillion, 1)
        // grok-proxy is the recent Grok Build CLI log slug for the same model.
        XCTAssertEqual(pricing.resolve(model: "grok-proxy"), pricing.resolve(model: "grok-build-0.1"))
        XCTAssertEqual(pricing.resolve(model: "grok-composer-2.5-fast")?.inputPerMillion, 3)
    }

    /// Grok Bot product labels do not identify the serving model. Keep the ordinary Grok 4.7 rate
    /// available for genuine model rows, but never price a Grok Bot surface label as that model.
    func testGrokBotProductLabelIsNotPricedAsServingModel() {
        let pricing = Self.pricing
        XCTAssertNotNil(pricing.resolve(model: "grok-4.7"))
        XCTAssertNil(pricing.resolve(model: "grok-bot-cua"))
        XCTAssertNil(pricing.resolve(model: "sand-automation"))
    }

    /// Both first-party Grok versions share rates and accept effort, separator, and Cursor-prefix variants.
    func testGrokPricingAndAliases() throws {
        let pricing = Self.pricing
        for version in ["4.5", "4.6"] {
            let dashedVersion = version.replacingOccurrences(of: ".", with: "-")
            let standard = try XCTUnwrap(pricing.resolve(model: "grok-\(version)-high"))
            let fast = try XCTUnwrap(pricing.resolve(model: "grok-\(version)-fast"))
            let expectedFastOutput = version == "4.5" ? 18.0 : 12.0
            // xAI's published cached-input price differs per version: $0.30/M for Grok 4.5, $0.50/M
            // for Grok 4.6. Cursor's own rates live under the `cursor-grok-*` keys.
            let expectedCacheRead = version == "4.5" ? 0.3 : 0.5
            XCTAssertEqual(
                [standard.inputPerMillion, standard.cacheWritePerMillion, standard.cacheReadPerMillion, standard.outputPerMillion],
                [2, 2, expectedCacheRead, 6],
                version
            )
            XCTAssertEqual(
                [fast.inputPerMillion, fast.cacheWritePerMillion, fast.cacheReadPerMillion, fast.outputPerMillion],
                [4, 4, 1, expectedFastOutput],
                version
            )

            for alias in [
                "grok-\(version)", "grok-\(version)-build", "grok-\(version)-low",
                "grok-\(version)-xhigh", "grok-\(dashedVersion)-xhigh", "cursor-grok-\(version)-high"
            ] {
                XCTAssertEqual(pricing.resolve(model: alias), standard, alias)
            }
            for alias in [
                "grok-\(version)-fast-high", "grok-\(version)-fast-medium", "grok-\(version)-fast-xhigh",
                "grok-\(version)-high-fast", "grok-\(version)-medium-fast", "grok-\(dashedVersion)-xhigh-fast",
                "cursor-grok-\(version)-high-fast", "cursor-grok-\(version)-fast-high"
            ] {
                XCTAssertEqual(pricing.resolve(model: alias), fast, alias)
            }
            XCTAssertEqual(pricing.supplement.canonicalName(for: "cursor-grok-\(version)-high"), "grok-\(version)")
            XCTAssertEqual(pricing.supplement.canonicalName(for: "cursor-grok-\(version)-high-fast"), "grok-\(version)-fast")
        }
    }

    func testNewCursorModelLabelsResolveToVerifiedCurrentRates() throws {
        let pricing = Self.pricing
        let expected: [(label: String, canonical: String, input: Double, cacheRead: Double, output: Double)] = [
            ("Claude Fable 5.1 (Auto Balanced)", "claude-fable-5-1", 10, 0.25, 50),
            ("Claude Haiku 5.5 (Auto Cost)", "claude-haiku-5-5", 0.1, 0.01, 0.5),
            ("Claude Opus 5.5 (Auto)", "claude-opus-5-5", 4, 0.2, 20),
            ("Claude Opus 5.5 Fast (Auto)", "claude-opus-5-5-fast", 8, 0.4, 40),
            ("Claude Sonnet 5.5 (Auto)", "claude-sonnet-5-5", 2, 0.1, 10),
            ("Gemini 4 Argon (Auto Balanced)", "gemini-4-argon", 2, 0.1, 10),
            ("Gemini 3.8 Flash (Auto)", "gemini-3.8-flash", 0.75, 0.075, 3.75),
            ("Muse Spark 1.3 (Auto)", "muse-spark-1.3", 1.25, 0.15, 4.25)
        ]

        for item in expected {
            if item.canonical == "gemini-4-argon" {
                XCTAssertEqual(pricing.cursorCanonicalName(for: item.label), item.canonical, item.label)
                let tokens = TokenBreakdown(input: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
                XCTAssertEqual(
                    try XCTUnwrap(pricing.estimatedCursorCostDollars(model: item.label, tokens: tokens)),
                    item.input + item.cacheRead + item.output,
                    accuracy: 0.000_001,
                    item.label
                )
                continue
            }
            XCTAssertEqual(pricing.canonicalName(for: item.label), item.canonical, item.label)
            let rates = try XCTUnwrap(pricing.resolve(model: item.label), item.label)
            XCTAssertEqual(rates.inputPerMillion, item.input, item.label)
            XCTAssertEqual(rates.cacheReadPerMillion, item.cacheRead, item.label)
            XCTAssertEqual(rates.outputPerMillion, item.output, item.label)
        }

        let haiku = try XCTUnwrap(pricing.resolve(model: "claude-haiku-5.5"))
        XCTAssertEqual(haiku.costDollars(for: TokenBreakdown(input: 100_000)), 0.01, accuracy: 0.000_001)
        XCTAssertEqual(haiku.costDollars(for: TokenBreakdown(input: 100_001)), 0.0500005, accuracy: 0.000_001)
        XCTAssertEqual(haiku.cacheWrite1hPerMillion, 0.2)
        XCTAssertEqual(pricing.resolve(model: "claude-opus-5.5")?.fastMultiplier, 2)

        let contributor = try XCTUnwrap(pricing.resolve(model: "meta/muse-spark-1.3-contributor"))
        XCTAssertEqual(contributor.inputPerMillion, 0.1)
        XCTAssertEqual(contributor.cacheReadPerMillion, 0.002)
        XCTAssertEqual(contributor.outputPerMillion, 0.2)

        let grok500k = try XCTUnwrap(pricing.resolve(model: "Grok 4.7 500k"))
        let grok500kFast = try XCTUnwrap(pricing.resolve(model: "Grok 4.7 500k (Fast)"))
        XCTAssertEqual([grok500k.inputPerMillion, grok500k.cacheReadPerMillion, grok500k.outputPerMillion], [4, 1, 12])
        XCTAssertEqual([grok500kFast.inputPerMillion, grok500kFast.cacheReadPerMillion, grok500kFast.outputPerMillion], [6, 1.5, 18])

        XCTAssertEqual(
            try XCTUnwrap(pricing.estimatedCursorCostDollars(model: "grok-4.7", tokens: TokenBreakdown(input: 256_000))),
            0.512,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(pricing.estimatedCursorCostDollars(model: "grok-4.7", tokens: TokenBreakdown(input: 256_001))),
            1.024004,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(pricing.estimatedCursorCostDollars(model: "grok-4.7-fast", tokens: TokenBreakdown(input: 256_001))),
            1.536006,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(pricing.estimatedCostDollars(model: "grok-4.7", tokens: TokenBreakdown(input: 220_000))),
            0.88,
            accuracy: 0.000_001,
            "the generic xAI route uses its >200K tier independently of Cursor's >256K tier"
        )
    }

    func testGrok45And46UseProviderScopedCursorPrices() throws {
        let pricing = Self.pricing

        // The prose label names the routed model, so it canonicalizes everywhere; the provider
        // split lives in the rate keys (cursor-grok-4.5 vs grok-4.5), not in the alias.
        XCTAssertEqual(pricing.canonicalName(for: "Grok 4.5 (Auto Balanced)"), "grok-4.5")
        XCTAssertEqual(pricing.cursorCanonicalName(for: "Grok 4.5 (Auto Balanced)"), "grok-4.5")
        XCTAssertEqual(pricing.cursorCanonicalName(for: "Grok 4.5 Fast (Auto Balanced)"), "grok-4.5-fast")
        XCTAssertEqual(pricing.cursorCanonicalName(for: "Cursor Grok 4.6 (Auto Balanced)"), "grok-4.6")
        XCTAssertEqual(pricing.cursorCanonicalName(for: "grok-4.6-fast-high"), "grok-4.6-fast")

        let xai45 = try XCTUnwrap(pricing.resolve(model: "grok-4.5"))
        XCTAssertEqual(xai45.cacheReadPerMillion, 0.3, "xAI cached input is $0.30/M")
        XCTAssertEqual(
            xai45.costDollars(for: TokenBreakdown(input: 199_999)),
            0.399998,
            accuracy: 0.000_001,
            "xAI's short-context rate applies below 200K"
        )
        XCTAssertEqual(
            xai45.costDollars(for: TokenBreakdown(input: 200_000)),
            0.8,
            accuracy: 0.000_001,
            "xAI's long-context tier begins at 200K"
        )
        XCTAssertEqual(
            xai45.costDollars(for: TokenBreakdown(input: 200_000, cacheRead: 1_000_000)),
            1.4,
            accuracy: 0.000_001,
            "the xAI tier carries its published $0.60/M cached-input price"
        )
        XCTAssertEqual(
            try XCTUnwrap(pricing.estimatedCursorCostDollars(
                model: "grok-4.5", tokens: TokenBreakdown(cacheRead: 1_000_000), applyLongContextRates: false
            )),
            0.5,
            accuracy: 0.000_001,
            "Cursor Grok 4.5 cached input is $0.50/M"
        )
        XCTAssertEqual(
            try XCTUnwrap(pricing.estimatedCursorCostDollars(
                model: "Grok 4.5 Fast (Auto Balanced)", tokens: TokenBreakdown(input: 1_000_000),
                applyLongContextRates: false
            )),
            4,
            accuracy: 0.000_001,
            "Cursor Fast rates stay provider-scoped"
        )
        XCTAssertEqual(
            try XCTUnwrap(pricing.estimatedCursorCostDollars(
                model: "grok-4.5-fast", tokens: TokenBreakdown(output: 1_000_000),
                applyLongContextRates: false
            )),
            18,
            accuracy: 0.000_001
        )

        let xai46 = try XCTUnwrap(pricing.resolve(model: "grok-4.6"))
        XCTAssertEqual(xai46.cacheReadPerMillion, 0.5)
        XCTAssertEqual(
            xai46.costDollars(for: TokenBreakdown(input: 200_000)),
            0.8,
            accuracy: 0.000_001,
            "xAI Grok 4.6 also enters its long-context tier at 200K"
        )
        XCTAssertEqual(
            try XCTUnwrap(pricing.estimatedCursorCostDollars(
                model: "grok-4.6", tokens: TokenBreakdown(input: 1_000_000), applyLongContextRates: false
            )),
            2,
            accuracy: 0.000_001,
            "Cursor's 256K model uses its normal aggregate CSV rate"
        )
        XCTAssertEqual(
            try XCTUnwrap(pricing.estimatedCursorCostDollars(
                model: "grok-4.6-fast", tokens: TokenBreakdown(input: 1_000_000), applyLongContextRates: false
            )),
            4,
            accuracy: 0.000_001
        )
        // The plain `-fast` keys carry xAI's published Fast rates. For these two models Cursor
        // charges the same Fast rates, so they coincide; the base cached-input rate above is where
        // the two providers genuinely differ.
        XCTAssertEqual(pricing.resolve(model: "grok-4.5-fast"), pricing.resolve(model: "cursor-grok-4.5-fast"))
        XCTAssertEqual(pricing.resolve(model: "grok-4.6-fast"), pricing.resolve(model: "cursor-grok-4.6-fast"))
    }

    /// Kimi K2.7 Code: Cursor's published rates override messy public-catalog entries.
    func testKimiK27CodePricingAndAliases() throws {
        let pricing = Self.pricing
        let kimi = try XCTUnwrap(pricing.resolve(model: "kimi-k2.7-code"))
        XCTAssertEqual(kimi.inputPerMillion, 0.95)
        XCTAssertEqual(kimi.cacheWritePerMillion, 0.95)
        XCTAssertEqual(kimi.cacheReadPerMillion, 0.19)
        XCTAssertEqual(kimi.outputPerMillion, 4.0)
        XCTAssertEqual(pricing.resolve(model: "kimi-k2.7"), kimi)
        XCTAssertEqual(pricing.resolve(model: "kimi-k2p7"), kimi)
        XCTAssertEqual(pricing.resolve(model: "kimi-k2p7-code"), kimi)
    }

    func testCostSumsAllBucketsAndUnpricedIsNil() throws {
        let pricing = Self.pricing
        let entry = try XCTUnwrap(pricing.resolve(model: "composer-1"))
        let tokens = TokenBreakdown(input: 1_000_000, cacheWrite5m: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        let expected = entry.inputPerMillion + entry.cacheWritePerMillion + entry.cacheReadPerMillion + entry.outputPerMillion
        XCTAssertEqual(pricing.estimatedCostDollars(model: "composer-1", tokens: tokens)!, expected, accuracy: 1e-9)
        XCTAssertNil(pricing.estimatedCostDollars(model: "nope", tokens: tokens))
    }
    /// DeepSeek V4 Flash is the model the OpenCode gateway serves to Claude/Codex/Hermes sessions,
    /// so its rates drive most of the OpenCode tiles' imputed dollars. Assert the full rate card
    /// against DeepSeek's official API pricing (api-docs.deepseek.com/quick_start/pricing,
    /// verified 2026-08-11 against OpenRouter/Requesty/BenchLM): $0.14 input, $0.28 output,
    /// $0.0028 cache-hit input — the 98% cache discount is the easy constant to get wrong.
    /// Both the canonical id and the bare gateway-stripped name must resolve identically.
    func testDeepSeekV4FlashRatesMatchOfficialPricing() {
        let pricing = Self.pricing
        for model in ["deepseek/deepseek-v4-flash", "deepseek-v4-flash"] {
            let rates = pricing.resolve(model: model)
            XCTAssertNotNil(rates, "\(model) resolves against no pricing source")
            XCTAssertEqual(rates?.inputPerMillion, 0.14, "\(model) input rate")
            XCTAssertEqual(rates?.outputPerMillion, 0.28, "\(model) output rate")
            XCTAssertEqual(rates?.cacheReadPerMillion, 0.0028, "\(model) cache-hit rate")
            XCTAssertEqual(rates?.cacheWritePerMillion, 0.14, "\(model) cache-write rate")
        }
        // The gateway-free tier is a real $0 model (counts tokens, costs nothing) — it must never
        // silently fall back to the paid rate.
        XCTAssertEqual(pricing.resolve(model: "deepseek-v4-flash-free")?.inputPerMillion, 0)
        XCTAssertEqual(pricing.resolve(model: "deepseek-v4-flash-free")?.outputPerMillion, 0)
    }
    /// DeepSeek V4 Pro is the premium tier on the OpenCode gateway. Official API rates
    /// (api-docs.deepseek.com/quick_start/pricing, verified 2026-08-12 against OpenRouter and
    /// deepseek.ai): $0.435 input, $0.87 output, $0.003625 cache-hit input — the 31 May 2026 cut
    /// from $1.74/$3.48 (75% off). The bundled LiteLLM snapshot omits the cache-write lane
    /// (resolves $0) and models.dev's capitalized deepseek-ai/DeepSeek-V4-Pro entry still carries
    /// the pre-cut rates, so the supplement pins the full card. Both the canonical id and the
    /// bare gateway-stripped name must resolve identically.
    func testDeepSeekV4ProRatesMatchOfficialPricing() {
        let pricing = Self.pricing
        for model in ["deepseek/deepseek-v4-pro", "deepseek-v4-pro"] {
            let rates = pricing.resolve(model: model)
            XCTAssertNotNil(rates, "V4 Pro resolves against no pricing source")
            XCTAssertEqual(rates?.inputPerMillion, 0.435, "V4 Pro input rate")
            XCTAssertEqual(rates?.outputPerMillion, 0.87, "V4 Pro output rate")
            XCTAssertEqual(rates?.cacheReadPerMillion, 0.003625, "V4 Pro cache-hit rate")
            XCTAssertEqual(rates?.cacheWritePerMillion, 0.435, "V4 Pro cache-write rate")
        }
    }
    /// Xiaomi MiMo-V2.5 family: official overseas rates (mimo.mi.com/docs/price/pay-as-you-go,
    /// verified 2026-08-19 vs OpenRouter xiaomi/mimo-v2.5). Base $0.14/$0.28 with 98% cache-read discount
    /// (0.0028), Pro $0.435/$0.87 with $0.0036 cache hit. Pinned in supplement because models.dev's
    /// XiaomiMiMo entries carry the higher provider rate ($0.40/$2 and $1/$3) and LiteLLM has no entry.
    /// All bare, provider-prefixed, and capitalised variants must resolve identically; free tiers stay $0.
    func testMimoV25RatesMatchOfficialPricing() {
        let pricing = Self.pricing
        for model in ["mimo-v2.5", "mimo/mimo-v2.5", "xiaomi/mimo-v2.5", "XiaomiMiMo/MiMo-V2.5"] {
            let rates = pricing.resolve(model: model)
            XCTAssertNotNil(rates, "\(model) resolves against no pricing source")
            XCTAssertEqual(rates?.inputPerMillion, 0.14, "\(model) input rate")
            XCTAssertEqual(rates?.outputPerMillion, 0.28, "\(model) output rate")
            XCTAssertEqual(rates?.cacheReadPerMillion, 0.0028, "\(model) cache-hit rate")
            XCTAssertEqual(rates?.cacheWritePerMillion, 0.14, "\(model) cache-write rate")
        }
        for model in ["mimo-v2.5-pro", "mimo/mimo-v2.5-pro", "xiaomi/mimo-v2.5-pro", "XiaomiMiMo/MiMo-V2.5-Pro"] {
            let rates = pricing.resolve(model: model)
            XCTAssertNotNil(rates, "\(model) pro resolves against no pricing source")
            XCTAssertEqual(rates?.inputPerMillion, 0.435, "\(model) input rate")
            XCTAssertEqual(rates?.outputPerMillion, 0.87, "\(model) output rate")
            XCTAssertEqual(rates?.cacheReadPerMillion, 0.0036, "\(model) cache-hit rate")
            XCTAssertEqual(rates?.cacheWritePerMillion, 0.435, "\(model) cache-write rate")
        }
        XCTAssertEqual(pricing.resolve(model: "mimo-v2.5-free")?.inputPerMillion, 0)
        XCTAssertEqual(pricing.resolve(model: "mimo-v2.5-free")?.outputPerMillion, 0)
        XCTAssertEqual(pricing.resolve(model: "mimo-v2.5-pro-free")?.inputPerMillion, 0)
        XCTAssertEqual(pricing.resolve(model: "mimo-v2.5-pro-free")?.outputPerMillion, 0)
    }

    /// Space Bunny left its free period on the OpenCode GO plan: published rates
    /// (opencode.ai/docs/go, verified 2026-10-06) are $0.15 input / $0.60 output / $0.03 cache
    /// read per 1M with no cache-write lane. The bundled catalogues only carry zero-rate
    /// space-bunny-free / stealth/space-bunny-alpha cards, so the supplement pins the paid card.
    /// The router ledger kept the legacy '-free' id for current usage after the switch, so
    /// space-bunny-free must resolve at the GO rates too — the supplement pin overrides the
    /// zero-rate bundled catalog entry. The spaced log slug reaches the same entry via the
    /// separator-normalized retry.
    func testSpaceBunnyGORatesMatchOfficialPricing() {
        let pricing = Self.pricing
        for model in ["space-bunny", "space bunny", "space-bunny-free", "space bunny free"] {
            let rates = pricing.resolve(model: model)
            XCTAssertNotNil(rates, "'\(model)' resolves against no pricing source")
            XCTAssertEqual(rates?.inputPerMillion, 0.15, "\(model) input rate")
            XCTAssertEqual(rates?.outputPerMillion, 0.6, "\(model) output rate")
            XCTAssertEqual(rates?.cacheReadPerMillion, 0.03, "\(model) cache-hit rate")
        }
    }

}
