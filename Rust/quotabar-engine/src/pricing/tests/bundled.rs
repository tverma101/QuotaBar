//! Swift `PricingBundledResourceTests` and `GatewaySlugRealPricingTests`: assertions against the
//! shipped supplement and snapshots, loaded offline the way Swift's `TestPricing.bundled` does.

use super::*;
use crate::pricing::codecs::{catalog_from_compact};
use crate::pricing::gateway_identity;
use crate::pricing::store::{bundled_data, SourceId};
use std::sync::{Arc, OnceLock};

fn pricing() -> &'static ModelPricing {
    static BUNDLED: OnceLock<ModelPricing> = OnceLock::new();
    BUNDLED.get_or_init(|| {
        let supplement = PricingSupplement::decode(bundled_data(SourceId::Supplement).expect("bundled supplement"))
            .expect("bundled supplement decodes");
        let primary = catalog_from_compact(bundled_data(SourceId::Litellm).expect("bundled litellm")).expect("litellm decodes");
        let secondary =
            catalog_from_compact(bundled_data(SourceId::ModelsDev).expect("bundled models.dev")).expect("models.dev decodes");
        ModelPricing::new(supplement, primary, secondary, PricingCatalog::default(), None)
    })
}

fn r(model: &str) -> Option<Arc<ModelRates>> {
    pricing().resolve(model)
}

fn lanes(rates: &ModelRates) -> [f64; 4] {
    [rates.input_per_million, rates.cache_write_per_million, rates.cache_read_per_million, rates.output_per_million]
}

fn cursor_cost(model: &str, t: &TokenBreakdown, long: bool) -> Option<f64> {
    pricing().estimated_cursor_cost_dollars(model, t, long)
}

#[test]
fn bundled_resources_load_and_are_non_trivial() {
    let p = pricing();
    assert!(p.primary.entries.len() > 500, "LiteLLM snapshot suspiciously small");
    assert!(p.secondary.entries.len() > 500, "models.dev snapshot suspiciously small");
    assert!(!p.supplement.pricing.is_empty());
    assert!(!p.supplement.alias_rules.is_empty());
}

#[test]
fn every_alias_canonical_resolves() {
    for rule in &pricing().supplement.alias_rules {
        assert!(r(&rule.canonical).is_some(), "alias canonical '{}' resolves against no pricing source", rule.canonical);
    }
}

#[test]
fn cursor_scoped_pricing_aliases_resolve_to_their_cursor_rates() {
    for model in ["grok-4.7", "grok-4.7-fast", "Grok 4.7 (Auto Balanced)", "Gemini 4 Argon (Auto Balanced)"] {
        assert!(pricing().cursor_canonical_name(model).is_some(), "{model}");
        assert!(cursor_cost(model, &input_tokens(1_000_000), true).is_some(), "{model}");
    }
}

#[test]
fn every_fast_multiplier_base_resolves() {
    for base in pricing().supplement.fast_multipliers.keys() {
        assert!(r(base).is_some(), "fast-multiplier base '{base}' resolves nowhere");
    }
}

/// Spot-check Cursor CSV slugs end to end against known rates.
#[test]
fn known_cursor_slugs_price_correctly() {
    let expected_input_rates = [
        ("auto", 1.25), ("claude-4.5-sonnet-thinking", 3.0),
        ("claude-4.6-opus-max-thinking", 5.0), ("claude-4.6-opus-max-thinking-fast", 30.0),
        ("gpt-5.5-xhigh-fast", 12.5),
        ("gpt-5.6-sol-ultra", 4.0), ("gpt-5.6-sol-ultra-fast", 8.0),
        ("gpt-5.6-terra-high", 2.0), ("gpt-5.6-terra-high-fast", 4.0),
        ("gpt-5.6-luna", 0.2), ("gpt-5.6-luna-fast", 0.4),
        ("gemini-3.6-flash-high", 1.5), ("gemini-3.7-flash-high", 0.75),
        ("grok-4-20-thinking", 1.25), ("grok-4.5", 2.0),
        ("grok-4.5-fast-high", 4.0), ("grok-4.5-high-fast", 4.0),
        ("cursor-grok-4.5-high-fast", 4.0), ("cursor-grok-4.6-high", 2.0),
        ("cursor-grok-4.6-high-fast", 4.0), ("grok-4-6-xhigh", 2.0),
        ("grok-4-6-xhigh-fast", 4.0), ("kimi-k2p5", 0.6),
        ("kimi-k2.7-code", 0.95), ("kimi-k2p7", 0.95), ("kimi-k3-max", 3.0),
        ("claude-4.7-opus-high-thinking", 5.0), ("claude-4.7-opus-max-thinking-fast", 30.0),
        ("glm-5.2-max", 1.4),
    ];
    for (model, expected) in expected_input_rates {
        assert_eq!(input_of(pricing(), model), Some(expected), "{model}");
    }
    assert_eq!(r("gemini-3.7-flash-high").map(|x| x.output_per_million), Some(3.75));
    assert_eq!(r("github_bugbot").map(|x| x.output_per_million), Some(30.0));
    assert_eq!(input_of(pricing(), "Premium (GPT-5.3-Codex)"), Some(1.75));
}

/// Raw model ids as they appear in Claude/Codex/Grok logs (no alias rewriting).
#[test]
fn known_log_model_ids_price_correctly() {
    assert_eq!(input_of(pricing(), "claude-sonnet-4-5-20250929"), Some(3.0));
    assert_eq!(input_of(pricing(), "claude-opus-4-1-20250805"), Some(15.0));
    assert!(r("gpt-5.1-codex").is_some());
    assert_eq!(r("gpt-daybreak-blue-latest"), r("gpt-5.6-sol"));
    assert_eq!(r("daybreak-blue-latest"), r("gpt-5.6-sol"));
    assert_eq!(input_of(pricing(), "grok-build-0.1"), Some(1.0));
    assert_eq!(input_of(pricing(), "grok-4.3"), Some(1.25));
}

#[test]
fn antigravity_gemini_model_variants_reuse_existing_catalog_rates() {
    let expected = [
        ("gemini-2.5-flash-none", "gemini-2.5-flash"),
        ("gemini-3-flash-a", "gemini-3-flash-preview"),
        ("gemini-3-flash-b-high", "gemini-3-flash-preview"),
        ("gemini-3-flash-none-preview", "gemini-3-flash-preview"),
        ("gemini-3.5-flash-high-preview", "gemini-3.5-flash"),
        ("gemini-3.6-flash-none", "gemini-3.6-flash"),
        ("gemini-3.7-flash-xhigh-preview", "gemini-3.7-flash"),
        ("gemini-3-pro-low", "gemini-3-pro-preview"),
        ("gemini-3-pro-high-preview", "gemini-3-pro-preview"),
        ("gemini-3.1-pro-none-preview", "gemini-3.1-pro-preview"),
    ];
    for (variant, canonical) in expected {
        assert_eq!(pricing().supplement.canonical_name(variant).as_deref(), Some(canonical), "wrong alias for '{variant}'");
        assert_eq!(r(variant), r(canonical), "wrong rates for '{variant}'");
    }
    assert_eq!(pricing().supplement.canonical_name("gemini-3-pro"), None);
}

/// Claude Fable 5: priced at 2x standard Claude 4.8 Opus, with thinking/effort slug variants
/// resolving to the same rates.
#[test]
fn claude_fable_5_pricing_and_aliases() {
    let fable = r("claude-fable-5-thinking").unwrap();
    assert_eq!(r("claude-fable-5-thinking-xhigh").as_ref(), Some(&fable));
    assert_eq!(fable.input_per_million, 10.0);
    assert_eq!(fable.output_per_million, 50.0);

    let opus48 = r("claude-opus-4-8").unwrap();
    assert_eq!(fable.input_per_million, opus48.input_per_million * 2.0);
    assert_eq!(fable.output_per_million, opus48.output_per_million * 2.0);
}

#[test]
fn claude_sonnet_5_pricing_and_aliases() {
    let sonnet5 = r("claude-sonnet-5-thinking-high").unwrap();
    assert_eq!(sonnet5.input_per_million, 2.0);
    assert_eq!(sonnet5.output_per_million, 10.0);
    assert_eq!(sonnet5.cache_write_per_million, 2.5);
    assert_close(sonnet5.cache_read_per_million, 0.2, 0.0001, "sonnet 5 cache read");

    // Sonnet 4.6 keeps the old $3/$15 pool rate; Sonnet 5's permanent intro rate must not collapse into it.
    let sonnet46 = r("claude-4.6-sonnet").unwrap();
    assert_eq!(sonnet46.input_per_million, 3.0);
    assert_ne!(sonnet5.input_per_million, sonnet46.input_per_million);
    assert_ne!(sonnet5.output_per_million, sonnet46.output_per_million);
}

#[test]
fn claude_opus_5_pricing_and_aliases() {
    let opus5 = r("claude-opus-5").unwrap();
    assert_eq!(opus5.input_per_million, 5.0);
    assert_eq!(opus5.cache_write_per_million, 6.25);
    assert_eq!(opus5.cache_read_per_million, 0.5);
    assert_eq!(opus5.output_per_million, 25.0);
    assert_eq!(r("claude-opus-5[1m]").as_ref(), Some(&opus5));
    assert_eq!(r("claude-opus-5-thinking-xhigh").as_ref(), Some(&opus5));

    let opus5_fast = r("claude-opus-5-thinking-high-fast").unwrap();
    assert_eq!(opus5_fast.input_per_million, opus5.input_per_million * 2.0);
    assert_eq!(opus5_fast.output_per_million, opus5.output_per_million * 2.0);

    let opus48 = r("claude-opus-4-8").unwrap();
    assert_eq!(opus5.input_per_million, opus48.input_per_million);
    assert_eq!(opus5.output_per_million, opus48.output_per_million);
    assert_eq!(opus5.fast_multiplier, opus48.fast_multiplier);
}

#[test]
fn claude_opus_5_fast_mode_bills_at_twice_base_rate() {
    let opus5 = r("claude-opus-5").unwrap();
    assert_eq!(opus5.fast_multiplier, 2.0);

    let t = tokens(1_000_000, 1_000_000, 0, 1_000_000, 1_000_000);
    let mut fast = t;
    fast.is_fast = true;
    assert_close(cost(&opus5, &fast), cost(&opus5, &t) * 2.0, 0.000_001, "fast opus 5");
}

#[test]
fn claude_opus_4_6_and_4_7_fast_mode_bills_at_six_times_base_rate() {
    for model in ["claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-6-20260205", "claude-opus-4-7-20260416"] {
        let entry = r(model).unwrap_or_else(|| panic!("{model} must price"));
        assert_eq!(entry.fast_multiplier, 6.0, "{model}");

        let t = tokens(1_000_000, 1_000_000, 0, 1_000_000, 1_000_000);
        let mut fast = t;
        fast.is_fast = true;
        assert_close(cost(&entry, &fast), cost(&entry, &t) * 6.0, 0.000_001, model);
    }
    // The dedicated -fast slug keeps scaling off the base card and must not be re-multiplied.
    assert_eq!(r("claude-opus-4-6-fast").unwrap().input_per_million, 30.0);
}

#[test]
fn kimi_k3_pricing_and_aliases() {
    let k3 = r("kimi-k3").unwrap();
    assert_eq!(k3.input_per_million, 3.0);
    assert_eq!(k3.cache_write_per_million, 3.0);
    assert_eq!(k3.cache_read_per_million, 0.3);
    assert_eq!(k3.output_per_million, 15.0);
    assert_eq!(r("kimi-k3-max").as_ref(), Some(&k3));
    assert_eq!(r("kimi-k3-high").as_ref(), Some(&k3));
    assert_eq!(r("kimi-k3-code").as_ref(), Some(&k3));
    // K3 must not collapse into the cheaper K2.7 entry.
    assert_ne!(r("kimi-k2.7-code").as_ref(), Some(&k3));
}

#[test]
fn cursor_glm_5_3_csv_slugs_use_published_rates() {
    for version in ["5.3", "5p3", "5-3"] {
        for effort in ["", "-low", "-high", "-max"] {
            let flash = r(&format!("glm-{version}-flash{effort}")).unwrap_or_else(|| panic!("glm-{version}-flash{effort}"));
            assert_eq!(flash.input_per_million, 0.15);
            assert_eq!(flash.cache_read_per_million, 0.029);
            assert_eq!(flash.output_per_million, 0.5);
            let base = r(&format!("glm-{version}{effort}")).unwrap_or_else(|| panic!("glm-{version}{effort}"));
            assert_eq!(base.input_per_million, 1.4);
            assert_eq!(base.cache_read_per_million, 0.26);
            assert_eq!(base.output_per_million, 4.4);
            assert_ne!(flash, base);
        }
    }
    for unknown in ["glm-5p3-flash-fast", "glm-5p3-flash-max-extra", "glm-5p4-flash-low"] {
        assert_eq!(pricing().supplement.canonical_name(unknown), None, "{unknown}");
    }
}

#[test]
fn bare_composer_slug_prices_as_current_composer() {
    let composer = r("composer").unwrap();
    assert_eq!(Some(&composer), r("composer-2.5").as_ref());
    assert_ne!(Some(&composer), r("composer-2.5-fast").as_ref());
}

#[test]
fn cursor_router_labels_price_as_the_routed_model() {
    let expected = [
        ("Opus 5 (Auto Balanced)", "claude-opus-5"),
        ("Claude Opus 5 (Auto)", "claude-opus-5"),
        ("Opus 4.8 (Auto)", "claude-opus-4-8"),
        ("Sonnet 5 (Auto Intelligence)", "claude-sonnet-5"),
        ("Fable 5 (Auto Balanced)", "claude-fable-5"),
        ("Haiku 4.5 (Auto Cost)", "claude-haiku-4-5"),
        ("Composer 2.5 (Auto)", "composer-2.5"),
        ("Composer 2.5 Fast (Auto)", "composer-2.5-fast"),
        ("Composer 2 (Auto Balanced)", "composer-2"),
        ("Grok 4.6 (Auto Intelligence)", "grok-4.6"),
        ("Cursor Grok 4.6 Fast (Auto)", "grok-4.6-fast"),
        ("Grok 4.5 (Auto Intelligence)", "grok-4.5"),
        ("Cursor Grok 4.5 Fast (Auto)", "grok-4.5-fast"),
        ("GPT-5.5 (Auto)", "gpt-5.5"),
        ("GPT-5.6 Sol (Auto Cost)", "gpt-5.6-sol"),
        ("GPT-5.6 Luna (Auto)", "gpt-5.6-luna"),
        ("Gemini 3.1 Pro (Auto Balanced)", "gemini-3.1-pro-preview"),
        ("Gemini 3.6 Flash (Auto)", "gemini-3.6-flash"),
        ("Gemini 3.7 Flash (Auto Balanced)", "gemini-3.7-flash"),
        ("GLM 5.2 (Auto)", "glm-5.2"),
        ("Kimi K3 (Auto Intelligence)", "kimi-k3"),
    ];
    for (label, canonical) in expected {
        assert_eq!(
            pricing().supplement.canonical_name(label).as_deref(),
            Some(canonical),
            "router label '{label}' should canonicalize to {canonical}"
        );
        assert_eq!(r(label), r(canonical), "router label '{label}' should price exactly like {canonical}");
    }
    // A directly picked model keeps its own slug: the router alias must not swallow plain names.
    assert_eq!(pricing().supplement.canonical_name("Opus 5"), None);
}

#[test]
fn gpt_5_6_pricing_and_aliases() {
    let expected = [
        ("gpt-5.6-sol-ultra", [4.0, 5.0, 0.4, 20.0]),
        ("gpt-5.6-sol-ultra-fast", [8.0, 10.0, 0.8, 40.0]),
        ("gpt-5.6-terra-high", [2.0, 2.5, 0.2, 12.0]),
        ("gpt-5.6-terra-high-fast", [4.0, 5.0, 0.4, 24.0]),
        ("gpt-5.6-luna", [0.2, 0.25, 0.02, 1.2]),
        ("gpt-5.6-luna-fast", [0.4, 0.5, 0.04, 2.4]),
    ];
    for (model, want) in expected {
        let actual = r(model).unwrap_or_else(|| panic!("{model} must price"));
        assert_eq!(lanes(&actual), want, "{model}");
    }
}

/// Opus 4.7/4.8 fast modes: Cursor's published rates (supplement overrides) win over the stale
/// models.dev entries. Per Cursor, 4.8 fast is 3x cheaper per token than 4.7 fast.
#[test]
fn opus_fast_mode_supplement_overrides() {
    let opus47_fast = r("claude-opus-4-7-thinking-high-fast").unwrap();
    assert_eq!(opus47_fast.input_per_million, 30.0);
    assert_eq!(opus47_fast.cache_write_per_million, 37.5);
    assert_eq!(opus47_fast.cache_read_per_million, 3.0);
    assert_eq!(opus47_fast.output_per_million, 150.0);

    let opus48_fast = r("claude-opus-4-8-thinking-high-fast").unwrap();
    assert_eq!(opus48_fast.input_per_million, opus47_fast.input_per_million / 3.0);
    assert_eq!(opus48_fast.output_per_million, opus47_fast.output_per_million / 3.0);
}

#[test]
fn gpt_6_pricing_and_aliases() {
    let expected = [
        ("gpt-6-luna", [0.1, 0.125, 0.01, 0.5]),
        ("gpt-6-luna-fast", [0.2, 0.25, 0.02, 1.0]),
        ("gpt-6-sol", [2.0, 2.5, 0.2, 10.0]),
        ("gpt-6-sol-high", [2.0, 2.5, 0.2, 10.0]),
        ("gpt-6-astra", [10.0, 12.5, 1.0, 50.0]),
        ("gpt-6-terra", [2.0, 2.5, 0.2, 12.0]),
        ("anthropic/openai/gpt-6-luna", [0.1, 0.125, 0.01, 0.5]),
        ("openai/gpt-6-sol", [2.0, 2.5, 0.2, 10.0]),
    ];
    for (model, want) in expected {
        let actual = r(model).unwrap_or_else(|| panic!("{model} must price"));
        assert_eq!(lanes(&actual), want, "{model}");
    }
}

#[test]
fn glm_5_2_pricing_and_aliases() {
    let glm = r("glm-5.2-max").unwrap();
    assert_eq!(glm.input_per_million, 1.4);
    assert_eq!(glm.cache_write_per_million, 1.4);
    assert_eq!(glm.cache_read_per_million, 0.26);
    assert_eq!(glm.output_per_million, 4.4);

    let output_only = TokenBreakdown { output: 1_000_000, ..Default::default() };
    assert_close(pricing().estimated_cost_dollars("glm-5.2-high", &output_only, None, true).unwrap(), 4.4, 1e-9, "glm-5.2-high");
    assert!(pricing().estimated_cost_dollars("glm-5.2-bogus", &output_only, None, true).is_none());
}

/// Grok CLI model ids route through the alias rules to their catalog entries.
#[test]
fn grok_cli_model_aliases() {
    assert_eq!(input_of(pricing(), "grok-build"), Some(1.0));
    // grok-proxy is the recent Grok Build CLI log slug for the same model.
    assert_eq!(r("grok-proxy"), r("grok-build-0.1"));
    assert_eq!(input_of(pricing(), "grok-composer-2.5-fast"), Some(3.0));
}

#[test]
fn grok_bot_product_label_is_not_priced_as_serving_model() {
    assert!(r("grok-4.7").is_some());
    assert!(r("grok-bot-cua").is_none());
    assert!(r("sand-automation").is_none());
}

/// Both first-party Grok versions share rates and accept effort, separator, and Cursor-prefix variants.
#[test]
fn grok_pricing_and_aliases() {
    for version in ["4.5", "4.6"] {
        let dashed = version.replace('.', "-");
        let standard = r(&format!("grok-{version}-high")).unwrap();
        let fast = r(&format!("grok-{version}-fast")).unwrap();
        let expected_fast_output = if version == "4.5" { 18.0 } else { 12.0 };
        let expected_cache_read = if version == "4.5" { 0.3 } else { 0.5 };
        assert_eq!(lanes(&standard), [2.0, 2.0, expected_cache_read, 6.0], "{version}");
        assert_eq!(lanes(&fast), [4.0, 4.0, 1.0, expected_fast_output], "{version}");

        for alias in [
            format!("grok-{version}"), format!("grok-{version}-build"), format!("grok-{version}-low"),
            format!("grok-{version}-xhigh"), format!("grok-{dashed}-xhigh"), format!("cursor-grok-{version}-high"),
        ] {
            assert_eq!(r(&alias).as_ref(), Some(&standard), "{alias}");
        }
        for alias in [
            format!("grok-{version}-fast-high"), format!("grok-{version}-fast-medium"), format!("grok-{version}-fast-xhigh"),
            format!("grok-{version}-high-fast"), format!("grok-{version}-medium-fast"), format!("grok-{dashed}-xhigh-fast"),
            format!("cursor-grok-{version}-high-fast"), format!("cursor-grok-{version}-fast-high"),
        ] {
            assert_eq!(r(&alias).as_ref(), Some(&fast), "{alias}");
        }
        assert_eq!(
            pricing().supplement.canonical_name(&format!("cursor-grok-{version}-high")).as_deref(),
            Some(format!("grok-{version}").as_str())
        );
        assert_eq!(
            pricing().supplement.canonical_name(&format!("cursor-grok-{version}-high-fast")).as_deref(),
            Some(format!("grok-{version}-fast").as_str())
        );
    }
}

#[test]
fn new_cursor_model_labels_resolve_to_verified_current_rates() {
    // (label, canonical, input, cache read, output)
    let expected = [
        ("Claude Fable 5.1 (Auto Balanced)", "claude-fable-5-1", 10.0, 0.25, 50.0),
        ("Claude Haiku 5.5 (Auto Cost)", "claude-haiku-5-5", 0.1, 0.01, 0.5),
        ("Claude Opus 5.5 (Auto)", "claude-opus-5-5", 4.0, 0.2, 20.0),
        ("Claude Opus 5.5 Fast (Auto)", "claude-opus-5-5-fast", 8.0, 0.4, 40.0),
        ("Claude Sonnet 5.5 (Auto)", "claude-sonnet-5-5", 2.0, 0.1, 10.0),
        ("Gemini 4 Argon (Auto Balanced)", "gemini-4-argon", 2.0, 0.1, 10.0),
        ("Gemini 3.8 Flash (Auto)", "gemini-3.8-flash", 0.75, 0.075, 3.75),
        ("Muse Spark 1.3 (Auto)", "muse-spark-1.3", 1.25, 0.15, 4.25),
    ];

    for (label, canonical, input, cache_read, output) in expected {
        if canonical == "gemini-4-argon" {
            assert_eq!(pricing().cursor_canonical_name(label).as_deref(), Some(canonical), "{label}");
            let t = tokens(1_000_000, 0, 0, 1_000_000, 1_000_000);
            assert_close(cursor_cost(label, &t, true).unwrap(), input + cache_read + output, 0.000_001, label);
            continue;
        }
        assert_eq!(pricing().canonical_name(label).as_deref(), Some(canonical), "{label}");
        let rates = r(label).unwrap_or_else(|| panic!("{label} must price"));
        assert_eq!(rates.input_per_million, input, "{label}");
        assert_eq!(rates.cache_read_per_million, cache_read, "{label}");
        assert_eq!(rates.output_per_million, output, "{label}");
    }

    let haiku = r("claude-haiku-5.5").unwrap();
    assert_close(cost(&haiku, &input_tokens(100_000)), 0.01, 0.000_001, "haiku at tier boundary");
    assert_close(cost(&haiku, &input_tokens(100_001)), 0.0500005, 0.000_001, "haiku above tier boundary");
    assert_eq!(haiku.cache_write_1h_per_million, Some(0.2));
    assert_eq!(r("claude-opus-5.5").map(|x| x.fast_multiplier), Some(2.0));

    let contributor = r("meta/muse-spark-1.3-contributor").unwrap();
    assert_eq!(contributor.input_per_million, 0.1);
    assert_eq!(contributor.cache_read_per_million, 0.002);
    assert_eq!(contributor.output_per_million, 0.2);

    let grok500k = r("Grok 4.7 500k").unwrap();
    let grok500k_fast = r("Grok 4.7 500k (Fast)").unwrap();
    assert_eq!([grok500k.input_per_million, grok500k.cache_read_per_million, grok500k.output_per_million], [4.0, 1.0, 12.0]);
    assert_eq!(
        [grok500k_fast.input_per_million, grok500k_fast.cache_read_per_million, grok500k_fast.output_per_million],
        [6.0, 1.5, 18.0]
    );

    assert_close(cursor_cost("grok-4.7", &input_tokens(256_000), true).unwrap(), 0.512, 0.000_001, "grok-4.7 at 256k");
    assert_close(cursor_cost("grok-4.7", &input_tokens(256_001), true).unwrap(), 1.024004, 0.000_001, "grok-4.7 over 256k");
    assert_close(cursor_cost("grok-4.7-fast", &input_tokens(256_001), true).unwrap(), 1.536006, 0.000_001, "grok-4.7-fast over 256k");
    assert_close(
        pricing().estimated_cost_dollars("grok-4.7", &input_tokens(220_000), None, true).unwrap(),
        0.88,
        0.000_001,
        "the generic xAI route uses its >200K tier independently of Cursor's >256K tier",
    );
}

#[test]
fn grok_4_5_and_4_6_use_provider_scoped_cursor_prices() {
    let p = pricing();
    // The prose label names the routed model, so it canonicalizes everywhere; the provider split
    // lives in the rate keys (cursor-grok-4.5 vs grok-4.5), not in the alias.
    assert_eq!(p.canonical_name("Grok 4.5 (Auto Balanced)").as_deref(), Some("grok-4.5"));
    assert_eq!(p.cursor_canonical_name("Grok 4.5 (Auto Balanced)").as_deref(), Some("grok-4.5"));
    assert_eq!(p.cursor_canonical_name("Grok 4.5 Fast (Auto Balanced)").as_deref(), Some("grok-4.5-fast"));
    assert_eq!(p.cursor_canonical_name("Cursor Grok 4.6 (Auto Balanced)").as_deref(), Some("grok-4.6"));
    assert_eq!(p.cursor_canonical_name("grok-4.6-fast-high").as_deref(), Some("grok-4.6-fast"));

    let xai45 = r("grok-4.5").unwrap();
    assert_eq!(xai45.cache_read_per_million, 0.3, "xAI cached input is $0.30/M");
    assert_close(cost(&xai45, &input_tokens(199_999)), 0.399998, 0.000_001, "xAI's short-context rate applies below 200K");
    assert_close(cost(&xai45, &input_tokens(200_000)), 0.8, 0.000_001, "xAI's long-context tier begins at 200K");
    assert_close(
        cost(&xai45, &TokenBreakdown { input: 200_000, cache_read: 1_000_000, ..Default::default() }),
        1.4,
        0.000_001,
        "the xAI tier carries its published $0.60/M cached-input price",
    );
    assert_close(
        cursor_cost("grok-4.5", &TokenBreakdown { cache_read: 1_000_000, ..Default::default() }, false).unwrap(),
        0.5,
        0.000_001,
        "Cursor Grok 4.5 cached input is $0.50/M",
    );
    assert_close(
        cursor_cost("Grok 4.5 Fast (Auto Balanced)", &input_tokens(1_000_000), false).unwrap(),
        4.0,
        0.000_001,
        "Cursor Fast rates stay provider-scoped",
    );
    assert_close(
        cursor_cost("grok-4.5-fast", &TokenBreakdown { output: 1_000_000, ..Default::default() }, false).unwrap(),
        18.0,
        0.000_001,
        "grok-4.5-fast output",
    );

    let xai46 = r("grok-4.6").unwrap();
    assert_eq!(xai46.cache_read_per_million, 0.5);
    assert_close(cost(&xai46, &input_tokens(200_000)), 0.8, 0.000_001, "xAI Grok 4.6 also enters its long-context tier at 200K");
    assert_close(
        cursor_cost("grok-4.6", &input_tokens(1_000_000), false).unwrap(),
        2.0,
        0.000_001,
        "Cursor's 256K model uses its normal aggregate CSV rate",
    );
    assert_close(cursor_cost("grok-4.6-fast", &input_tokens(1_000_000), false).unwrap(), 4.0, 0.000_001, "grok-4.6-fast");
    // The plain `-fast` keys carry xAI's published Fast rates. For these two models Cursor charges
    // the same Fast rates, so they coincide.
    assert_eq!(r("grok-4.5-fast"), r("cursor-grok-4.5-fast"));
    assert_eq!(r("grok-4.6-fast"), r("cursor-grok-4.6-fast"));
}

#[test]
fn kimi_k2_7_code_pricing_and_aliases() {
    let kimi = r("kimi-k2.7-code").unwrap();
    assert_eq!(kimi.input_per_million, 0.95);
    assert_eq!(kimi.cache_write_per_million, 0.95);
    assert_eq!(kimi.cache_read_per_million, 0.19);
    assert_eq!(kimi.output_per_million, 4.0);
    assert_eq!(r("kimi-k2.7").as_ref(), Some(&kimi));
    assert_eq!(r("kimi-k2p7").as_ref(), Some(&kimi));
    assert_eq!(r("kimi-k2p7-code").as_ref(), Some(&kimi));
}

#[test]
fn cost_sums_all_buckets_and_unpriced_is_nil() {
    let entry = r("composer-1").unwrap();
    let t = tokens(1_000_000, 1_000_000, 0, 1_000_000, 1_000_000);
    let expected = entry.input_per_million + entry.cache_write_per_million + entry.cache_read_per_million + entry.output_per_million;
    assert_close(pricing().estimated_cost_dollars("composer-1", &t, None, true).unwrap(), expected, 1e-9, "composer-1");
    assert!(pricing().estimated_cost_dollars("nope", &t, None, true).is_none());
}

#[test]
fn deepseek_v4_flash_rates_match_official_pricing() {
    for model in ["deepseek/deepseek-v4-flash", "deepseek-v4-flash"] {
        let rates = r(model).unwrap_or_else(|| panic!("{model} resolves against no pricing source"));
        assert_eq!(rates.input_per_million, 0.14, "{model} input rate");
        assert_eq!(rates.output_per_million, 0.28, "{model} output rate");
        assert_eq!(rates.cache_read_per_million, 0.0028, "{model} cache-hit rate");
        assert_eq!(rates.cache_write_per_million, 0.14, "{model} cache-write rate");
    }
    // The gateway-free tier is a real $0 model: it must never silently fall back to the paid rate.
    assert_eq!(input_of(pricing(), "deepseek-v4-flash-free"), Some(0.0));
    assert_eq!(r("deepseek-v4-flash-free").map(|x| x.output_per_million), Some(0.0));
}

#[test]
fn deepseek_v4_pro_rates_match_official_pricing() {
    for model in ["deepseek/deepseek-v4-pro", "deepseek-v4-pro"] {
        let rates = r(model).unwrap_or_else(|| panic!("{model} V4 Pro resolves against no pricing source"));
        assert_eq!(rates.input_per_million, 0.435, "V4 Pro input rate");
        assert_eq!(rates.output_per_million, 0.87, "V4 Pro output rate");
        assert_eq!(rates.cache_read_per_million, 0.003625, "V4 Pro cache-hit rate");
        assert_eq!(rates.cache_write_per_million, 0.435, "V4 Pro cache-write rate");
    }
}

#[test]
fn mimo_v2_5_rates_match_official_pricing() {
    for model in ["mimo-v2.5", "mimo/mimo-v2.5", "xiaomi/mimo-v2.5", "XiaomiMiMo/MiMo-V2.5"] {
        let rates = r(model).unwrap_or_else(|| panic!("{model} resolves against no pricing source"));
        assert_eq!(rates.input_per_million, 0.14, "{model} input rate");
        assert_eq!(rates.output_per_million, 0.28, "{model} output rate");
        assert_eq!(rates.cache_read_per_million, 0.0028, "{model} cache-hit rate");
        assert_eq!(rates.cache_write_per_million, 0.14, "{model} cache-write rate");
    }
    for model in ["mimo-v2.5-pro", "mimo/mimo-v2.5-pro", "xiaomi/mimo-v2.5-pro", "XiaomiMiMo/MiMo-V2.5-Pro"] {
        let rates = r(model).unwrap_or_else(|| panic!("{model} pro resolves against no pricing source"));
        assert_eq!(rates.input_per_million, 0.435, "{model} input rate");
        assert_eq!(rates.output_per_million, 0.87, "{model} output rate");
        assert_eq!(rates.cache_read_per_million, 0.0036, "{model} cache-hit rate");
        assert_eq!(rates.cache_write_per_million, 0.435, "{model} cache-write rate");
    }
    assert_eq!(input_of(pricing(), "mimo-v2.5-free"), Some(0.0));
    assert_eq!(r("mimo-v2.5-free").map(|x| x.output_per_million), Some(0.0));
    assert_eq!(input_of(pricing(), "mimo-v2.5-pro-free"), Some(0.0));
    assert_eq!(r("mimo-v2.5-pro-free").map(|x| x.output_per_million), Some(0.0));
}

#[test]
fn space_bunny_go_rates_match_official_pricing() {
    for model in ["space-bunny", "space bunny", "space-bunny-free", "space bunny free"] {
        let rates = r(model).unwrap_or_else(|| panic!("'{model}' resolves against no pricing source"));
        assert_eq!(rates.input_per_million, 0.15, "{model} input rate");
        assert_eq!(rates.output_per_million, 0.6, "{model} output rate");
        assert_eq!(rates.cache_read_per_million, 0.03, "{model} cache-hit rate");
    }
}

// MARK: - GatewaySlugRealPricingTests

const GATEWAY_PAIRS: [(&str, &str); 4] = [
    ("anthropic/openai/gpt-6-sol", "gpt-6-sol"),
    ("anthropic/openai/gpt-5.6-luna", "gpt-5.6-luna"),
    ("anthropic/openai/gpt-6-luna", "gpt-6-luna"),
    ("anthropic/openai/gpt-5.6-terra", "gpt-5.6-terra"),
];

#[test]
fn cursor_deepseek_effort_slugs_price_from_the_shipped_supplement() {
    for slug in [
        "deepseek-v41-flash-1017-high",
        "deepseek-v41-flash-1017-medium",
        "deepseek-v41-flash-1017-max",
        "deepseek-v41-flash-1017",
        "deepseek-v4.1-flash-1017",
    ] {
        assert_eq!(
            pricing().canonical_name(slug).as_deref(),
            Some("deepseek-v4.1-flash-1017"),
            "{slug} must collapse onto the dated DeepSeek route"
        );
        let t = TokenBreakdown { input: 1_000_000, output: 1_000_000, ..Default::default() };
        let c = cursor_cost(slug, &t, false)
            .unwrap_or_else(|| panic!("{slug} must price from the shipped supplement, not only the live catalogue"));
        // $0.15 input + $0.60 output per million.
        assert_close(c, 0.75, 1e-9, slug);
    }
}

#[test]
fn deepseek_effort_slugs_keep_the_dated_route_distinct_from_the_base() {
    assert_eq!(pricing().canonical_name("deepseek-v41-flash-high").as_deref(), Some("deepseek-v4.1-flash"));
    let dated = r("deepseek-v4.1-flash-1017").unwrap();
    let base = r("deepseek-v4.1-flash").unwrap();
    assert_ne!(dated.output_per_million, base.output_per_million);
}

#[test]
fn tagged_and_bare_spellings_price_identically() {
    for (tagged_slug, bare_slug) in GATEWAY_PAIRS {
        let tagged = r(tagged_slug).unwrap_or_else(|| panic!("{tagged_slug} must price"));
        let bare = r(bare_slug).unwrap_or_else(|| panic!("{bare_slug} must price"));
        assert_eq!(tagged.input_per_million, bare.input_per_million, "{tagged_slug}");
        assert_eq!(tagged.output_per_million, bare.output_per_million, "{tagged_slug}");
    }
}

#[test]
fn tagged_slug_resolves_to_the_bare_model_identity() {
    for (tagged, bare) in GATEWAY_PAIRS {
        // The candidate ladder a scanner builds: full slug, then each suffix.
        let mut candidates = vec![tagged.to_string()];
        candidates.extend(tagged.split('/').skip(1).map(str::to_string));
        let identity = pricing().canonical_key(&candidates);
        assert_eq!(identity.as_deref(), Some(bare), "{tagged} must be identified as {bare}, not as the routing path");
    }
}

#[test]
fn bare_slugs_that_borrow_rates_keep_their_own_identity() {
    for (slug, priced_as) in [("gpt-reserve", "gpt-6-luna"), ("codex-auto-review", "gpt-5.2")] {
        assert_eq!(
            gateway_identity(slug, Some(priced_as)),
            slug,
            "{slug} is its own identity even though it prices as {priced_as}"
        );
    }
    assert!(r("gpt-reserve").is_some());
    assert!(r("codex-auto-review").is_none(), "auto-review is priced by the scanner's dated fallback, not by a supplement alias");
}
