//! Swift `ModelPricingTests`: resolution, supplement precedence, fast multipliers and cost math
//! against small fixture catalogs.

use super::*;
use std::collections::HashSet;
use std::sync::{Arc, Mutex};

fn none() -> PricingCatalog {
    PricingCatalog::default()
}

fn est(pricing: &ModelPricing, model: &str, t: &TokenBreakdown) -> Option<f64> {
    pricing.estimated_cost_dollars(model, t, None, true)
}

fn recorder() -> (Arc<Mutex<Vec<String>>>, Option<crate::pricing::resolve::RecheckHook>) {
    let seen = Arc::new(Mutex::new(Vec::<String>::new()));
    let sink = seen.clone();
    let hook: crate::pricing::resolve::RecheckHook = Arc::new(move |m: &str| sink.lock().unwrap().push(m.to_string()));
    (seen, Some(hook))
}

// MARK: - Resolution

#[test]
fn model_resolution_normalizes_dates_provider_prefixes_and_separators() {
    let scenarios = [
        ("gpt-5.5", "gpt-5.5", 5.0),
        ("claude-sonnet-4-20250514", "claude-sonnet-4", 3.0),
        ("claude-sonnet-4-5", "claude-sonnet-4-5-20250929", 3.0),
        ("xai/grok-4.3", "grok-4.3", 1.25),
        ("xai/grok-4.3", "grok-4-3", 1.25),
    ];
    for (key, model, expected) in scenarios {
        let pricing = make_pricing(None, cat([(key, rates(expected, 15.0))]), none(), none());
        assert_eq!(input_of(&pricing, model), Some(expected), "{model}");
    }
}

#[test]
fn cursor_gemini_rate_does_not_replace_public_open_router_cache_write_rate() {
    let supplement = r#"
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
    "#;
    let route = rates_with(4.0, 20.0, Some(0.1875), Some(0.2), 1.0);
    let pricing = make_pricing(
        Some(supplement),
        none(),
        none(),
        cat([("google/gemini-4-argon", route.clone()), ("gemini-4-argon", route)]),
    );
    let cache_write = TokenBreakdown { cache_write_5m: 1_000_000, ..Default::default() };

    assert_close(
        est(&pricing, "gemini-4-argon", &cache_write).unwrap(),
        0.1875,
        0.000_001,
        "the public API slug uses the OpenRouter route rate",
    );
    assert_close(
        pricing.estimated_cursor_cost_dollars("Gemini 4 Argon (Auto Balanced)", &cache_write, true).unwrap(),
        2.0,
        0.000_001,
        "Cursor's scoped alias uses its own published cache-write rate",
    );
}

#[test]
fn numeric_versions_do_not_conflate() {
    // claude-sonnet-4 must not price as claude-sonnet-4-5 (or vice versa).
    let pricing = make_pricing(None, cat([("claude-sonnet-4-5", rates(3.0, 15.0))]), none(), none());
    assert!(pricing.resolve("claude-sonnet-4").is_none());
    let reverse = make_pricing(None, cat([("claude-sonnet-4", rates(1.0, 2.0))]), none(), none());
    assert!(reverse.resolve("claude-sonnet-4-5").is_none());
}

#[test]
fn longest_key_preferred() {
    let pricing = make_pricing(
        None,
        cat([("gemini-3-pro", rates(1.0, 2.0)), ("gemini/gemini-3-pro-preview", rates(2.0, 12.0))]),
        none(),
        none(),
    );
    assert_eq!(input_of(&pricing, "gemini-3-pro-preview"), Some(2.0));
}

#[test]
fn secondary_catalog_fills_gaps() {
    let pricing = make_pricing(
        None,
        cat([("gpt-5.5", rates(5.0, 30.0))]),
        cat([("grok-build-0.1", rates(1.0, 2.0))]),
        none(),
    );
    assert_eq!(input_of(&pricing, "grok-build-0.1"), Some(1.0));
}

#[test]
fn open_router_exact_rates_beat_litellm_and_supplement_fills_missing_models() {
    let supplement = r#"{"pricing":{"gpt-5.6":{"input_per_million":1,"output_per_million":2},"auto":{"input_per_million":3,"output_per_million":4}},"alias_rules":[]}"#;
    let pricing = make_pricing(
        Some(supplement),
        cat([("gpt-5.6", rates(5.0, 10.0))]),
        none(),
        cat([("gpt-5.6", rates(7.0, 14.0)), ("new-model", rates(8.0, 16.0))]),
    );

    assert_eq!(input_of(&pricing, "new-model"), Some(8.0));
    assert_eq!(input_of(&pricing, "gpt-5.6"), Some(1.0), "curated supplement prices must remain authoritative");
    assert_eq!(input_of(&pricing, "auto"), Some(3.0));
}

#[test]
fn curated_supplement_cache_rates_beat_open_router_prompt_only_rate() {
    let supplement = r#"{"pricing":{"claude-opus-5":{"input_per_million":5,"output_per_million":25,"cache_write_per_million":6.25,"cache_read_per_million":0.5}},"alias_rules":[]}"#;
    let pricing = make_pricing(
        Some(supplement),
        none(),
        none(),
        cat([("claude-opus-5", rates_with(5.0, 25.0, Some(5.0), Some(5.0), 1.0))]),
    );

    let resolved = pricing.resolve("claude-opus-5").unwrap();
    assert_eq!(resolved.input_per_million, 5.0);
    assert_eq!(resolved.cache_write_per_million, 6.25);
    assert_eq!(resolved.cache_read_per_million, 0.5);
}

#[test]
fn open_router_catalog_does_not_fuzzy_match() {
    let pricing = make_pricing(None, none(), none(), cat([("vendor/gpt-5.6", rates(7.0, 14.0))]));

    assert!(pricing.resolve("gpt-5.6-preview").is_none());
    assert_eq!(input_of(&pricing, "vendor/gpt-5.6"), Some(7.0));
}

#[test]
fn fallback_priced_model_queues_one_open_router_recheck() {
    let (seen, hook) = recorder();
    let model = "gemini-3.8-flash-n";
    let pricing = ModelPricing::new(
        PricingSupplement::default(),
        cat([("gemini-3.8-flash", rates(9.0, 27.0))]),
        none(),
        none(),
        hook,
    );

    assert!(pricing.is_priced(model), "the existing LiteLLM fallback remains usable");
    assert!(!pricing.has_exact_open_router_rate(model), "fallback pricing is not an OpenRouter match");
    for _ in 0..10 {
        assert_eq!(input_of(&pricing, model), Some(9.0));
    }
    assert_eq!(*seen.lock().unwrap(), vec![model.to_string()], "a repeated ledger row queues one catalog check");
}

#[test]
fn curated_and_exact_open_router_prices_do_not_queue_rechecks() {
    let (seen, hook) = recorder();
    let supplement = PricingSupplement::new(
        HashMap::from([("curated-model".to_string(), rates(1.0, 2.0))]),
        HashMap::new(),
        vec![],
        vec![],
        HashSet::new(),
        HashSet::new(),
        false,
        None,
    );
    let pricing = ModelPricing::new(
        supplement,
        cat([("fallback-model", rates(3.0, 4.0))]),
        none(),
        cat([("router-model", rates(5.0, 6.0))]),
        hook,
    );

    assert_eq!(input_of(&pricing, "curated-model"), Some(1.0));
    assert_eq!(input_of(&pricing, "router-model"), Some(5.0));
    assert!(seen.lock().unwrap().is_empty());
}

#[test]
fn codename_spelling_variants_resolve_to_catalog_entries() {
    // Stealth/codename models reach the logs with spellings the public catalogues never use
    // verbatim: spaces or underscores where the catalogue hyphenates.
    let pricing = make_pricing(
        None,
        none(),
        none(),
        cat([("openrouter/space-bunny", rates(7.0, 14.0)), ("space-bunny", rates(7.0, 14.0))]),
    );
    assert_eq!(input_of(&pricing, "space bunny"), Some(7.0), "spaces normalize to the catalogue's hyphens");
    assert_eq!(input_of(&pricing, "space_bunny"), Some(7.0), "underscores normalize too");
    assert_eq!(input_of(&pricing, "space-bunny"), Some(7.0), "the plain slug keeps working");

    // The hyphenated form wins via the bare OpenRouter alias, and the route-prefixed entry still
    // prices its own exact id.
    assert_eq!(input_of(&pricing, "openrouter/space-bunny"), Some(7.0));

    // Normalization must not invent matches: a distinct slug stays unpriced.
    let miss = make_pricing(None, none(), none(), cat([("space-bunny", rates(7.0, 14.0))]));
    assert!(miss.resolve("space bunny 2").is_none());
    assert!(miss.resolve("bunny").is_none());
}

#[test]
fn unknown_model_returns_nil() {
    let pricing = make_pricing(None, cat([("gpt-5.5", rates(5.0, 30.0))]), none(), none());
    assert!(pricing.resolve("made-up-model-9000").is_none());
}

// MARK: - Supplement precedence, aliases, fast multipliers

#[test]
fn supplement_pricing_beats_public_catalogs() {
    let supplement = r#"{"pricing": {"auto": {"input_per_million": 1.25, "output_per_million": 6.0, "cache_read_per_million": 0.25}}, "alias_rules": []}"#;
    let pricing = make_pricing(
        Some(supplement),
        cat([("auto", rates(99.0, 99.0))]),
        none(),
        cat([("auto", rates(88.0, 88.0))]),
    );
    assert_eq!(input_of(&pricing, "auto"), Some(1.25));
    assert_eq!(pricing.resolve("auto").map(|r| r.cache_write_per_million), Some(1.25), "cache write defaults to input");
}

#[test]
fn alias_rule_rewrites_slug() {
    let supplement = r#"{"pricing": {}, "alias_rules": [
        {"pattern": "^claude-4\\.5-sonnet(?:-thinking)?$", "canonical": "claude-sonnet-4-5"}
    ]}"#;
    let pricing = make_pricing(Some(supplement), cat([("claude-sonnet-4-5", rates(3.0, 15.0))]), none(), none());
    assert_eq!(input_of(&pricing, "claude-4.5-sonnet-thinking"), Some(3.0));
}

#[test]
fn alias_miss_falls_back_to_raw_name() {
    let supplement = r#"{"pricing": {}, "alias_rules": [{"pattern": "^gpt-x$", "canonical": "key-not-anywhere"}]}"#;
    let pricing = make_pricing(Some(supplement), cat([("gpt-x", rates(1.0, 2.0))]), none(), none());
    assert_eq!(input_of(&pricing, "gpt-x"), Some(1.0));
}

#[test]
fn fast_suffix_uses_supplement_multiplier() {
    let supplement = r#"{"pricing": {}, "fast_multipliers": {"gpt-5.5": 2.5}, "alias_rules": []}"#;
    let pricing = make_pricing(
        Some(supplement),
        cat([("gpt-5.5", rates_with(5.0, 30.0, None, Some(0.5), 1.0))]),
        none(),
        none(),
    );
    let fast = pricing.resolve("gpt-5.5-fast").unwrap();
    assert_eq!(fast.input_per_million, 12.5);
    assert_eq!(fast.output_per_million, 75.0);
    assert_eq!(fast.cache_read_per_million, 1.25);
}

#[test]
fn fast_suffix_uses_entry_multiplier() {
    let pricing = make_pricing(None, cat([("claude-opus-4-6", rates_with(5.0, 25.0, None, None, 6.0))]), none(), none());
    let fast = pricing.resolve("claude-opus-4-6-fast").unwrap();
    assert_eq!(fast.input_per_million, 30.0);
    assert_eq!(fast.fast_multiplier, 1.0, "multiplier folded into the scaled rates");
}

#[test]
fn fast_suffix_without_multiplier_returns_nil() {
    let pricing = make_pricing(None, cat([("gpt-9", rates(1.0, 2.0))]), none(), none());
    assert!(pricing.resolve("gpt-9-fast").is_none());
}

#[test]
fn fast_suffix_without_multiplier_uses_secondary_exact_entry() {
    let pricing = make_pricing(
        None,
        cat([("gpt-9", rates(1.0, 2.0))]),
        cat([("gpt-9-fast", rates(2.5, 5.0))]),
        none(),
    );
    assert_eq!(input_of(&pricing, "gpt-9-fast"), Some(2.5));
}

#[test]
fn dated_base_key_still_finds_fast_multiplier() {
    let supplement = r#"{"pricing": {}, "fast_multipliers": {"gpt-5.5": 2.5}, "alias_rules": []}"#;
    let pricing = make_pricing(Some(supplement), cat([("gpt-5.5-20260423", rates(5.0, 30.0))]), none(), none());
    assert_eq!(input_of(&pricing, "gpt-5.5-fast"), Some(12.5));
}

#[test]
fn dated_fast_base_prefers_newest_catalog_date() {
    let supplement = r#"{"pricing": {}, "fast_multipliers": {"gpt-5.5": 2.5}, "alias_rules": []}"#;
    let pricing = make_pricing(
        Some(supplement),
        cat([("gpt-5.5-20250423", rates(2.0, 8.0)), ("gpt-5.5-20260423", rates(5.0, 30.0))]),
        none(),
        none(),
    );
    assert_eq!(input_of(&pricing, "gpt-5.5-fast"), Some(12.5));
    assert_eq!(pricing.resolve("gpt-5.5-fast").map(|r| r.output_per_million), Some(75.0));
}

#[test]
fn dated_fast_multiplier_chooses_most_specific_base() {
    let supplement = r#"{"pricing": {}, "fast_multipliers": {"gpt-5": 2, "gpt-5.5": 2.5}, "alias_rules": []}"#;
    let pricing = make_pricing(Some(supplement), none(), none(), none());

    assert_eq!(pricing.supplement.fast_multiplier("gpt-5.5-2026-04-23"), Some(2.5));
}

#[test]
fn fast_variant_does_not_borrow_fuzzy_sibling_rates() {
    let supplement = r#"{"pricing": {}, "fast_multipliers": {"gpt-9": 2}, "alias_rules": []}"#;
    let pricing = make_pricing(Some(supplement), cat([("gpt-9-pro", rates(5.0, 30.0))]), none(), none());

    assert!(pricing.resolve("gpt-9-fast").is_none());
}

#[test]
fn free_suffix_does_not_borrow_paid_fuzzy_sibling_rates() {
    let pricing = make_pricing(None, cat([("gpt-5.5", rates(5.0, 30.0))]), none(), none());
    assert!(pricing.resolve("gpt-5.5-free").is_none());
}

// MARK: - Cost math

#[test]
fn cost_uses_all_token_buckets() {
    let entry = ModelRates::new(3.0, 15.0, 3.75, 0.3);
    let pricing = make_pricing(None, cat([("claude-sonnet-4-5", entry)]), none(), none());
    let t = tokens(1_000_000, 1_000_000, 1_000_000, 1_000_000, 1_000_000);
    // input 3 + cacheWrite5m 3.75 + cacheWrite1h (3x2=6) + cacheRead 0.3 + output 15 = 28.05
    assert_close(est(&pricing, "claude-sonnet-4-5", &t).unwrap(), 28.05, 0.0001, "all buckets");
}

#[test]
fn long_context_rates_apply_only_when_prompt_exceeds_the_threshold() {
    let mut entry = ModelRates::new(3.0, 15.0, 3.75, 0.3);
    entry.input_above_200k_per_million = Some(6.0);
    entry.output_above_200k_per_million = Some(22.5);
    let pricing = make_pricing(None, cat([("claude-sonnet-4-5", entry)]), none(), none());
    let scenarios = [
        ("above threshold", input_tokens(300_000), 1.8),
        ("exactly at threshold", TokenBreakdown { input: 200_000, output: 10_000, ..Default::default() }, 0.75),
        ("large output alone", TokenBreakdown { input: 10_000, output: 300_000, ..Default::default() }, 4.53),
    ];
    for (name, t, expected) in scenarios {
        let actual = est(&pricing, "claude-sonnet-4-5", &t).unwrap();
        assert_close(actual, expected, 0.0001, name);
    }
}

#[test]
fn combined_prompt_buckets_select_long_context_rates_for_every_bucket() {
    let mut entry = ModelRates::new(3.0, 15.0, 3.75, 0.3);
    entry.input_above_200k_per_million = Some(6.0);
    entry.output_above_200k_per_million = Some(22.5);
    entry.cache_write_above_200k_per_million = Some(7.5);
    entry.cache_read_above_200k_per_million = Some(0.6);
    let pricing = make_pricing(None, cat([("claude-sonnet-4-5", entry)]), none(), none());
    let t = tokens(100_000, 60_000, 0, 50_000, 20_000);

    // The 210k prompt selects the higher tier for input, cache, and output alike.
    let expected = 0.6 + 0.45 + 0.03 + 0.45;
    assert_close(est(&pricing, "claude-sonnet-4-5", &t).unwrap(), expected, 0.0001, "combined prompt");
}

#[test]
fn custom_long_context_threshold_uses_whole_request_rates() {
    let mut entry = ModelRates::new(5.0, 30.0, 5.0, 0.5);
    entry.input_above_200k_per_million = Some(10.0);
    entry.output_above_200k_per_million = Some(45.0);
    entry.cache_read_above_200k_per_million = Some(1.0);
    entry.long_context_threshold_tokens = 272_000;

    let at_threshold = tokens(200_000, 0, 0, 72_000, 1_000);
    let over_threshold = tokens(200_001, 0, 0, 72_000, 1_000);

    assert_close(cost(&entry, &at_threshold), 1.066, 0.000_001, "at threshold");
    assert_close(cost(&entry, &over_threshold), 2.117_01, 0.000_001, "over threshold");
}

#[test]
fn cost_without_tier_rates_uses_base_rate_throughout() {
    let pricing = make_pricing(None, cat([("gpt-5.5", rates(5.0, 30.0))]), none(), none());
    assert_close(est(&pricing, "gpt-5.5", &input_tokens(300_000)).unwrap(), 1.5, 0.0001, "base rate");
}

#[test]
fn fast_speed_applies_entry_multiplier() {
    let pricing = make_pricing(None, cat([("claude-opus-4-6", rates_with(5.0, 25.0, None, None, 6.0))]), none(), none());
    let mut t = input_tokens(1_000_000);
    assert_close(est(&pricing, "claude-opus-4-6", &t).unwrap(), 5.0, 0.0001, "standard");
    t.is_fast = true;
    assert_close(est(&pricing, "claude-opus-4-6", &t).unwrap(), 30.0, 0.0001, "fast");
}

#[test]
fn unknown_model_cost_is_nil() {
    let pricing = make_pricing(None, none(), none(), none());
    assert!(est(&pricing, "mystery", &input_tokens(100)).is_none());
}
