use super::*;
use super::rates::flat_cost;

#[test]
fn pricing_memoizes_repeated_hits_and_misses_without_unbounded_growth() {
    let pricing = ModelPricing::from_bundled();
    assert!(pricing.can_price("claude-sonnet-4-20250514"));
    assert!(!pricing.can_price("unlisted-catalog-fixture"));
    for _ in 0..100 {
        assert!(pricing.can_price("claude-sonnet-4-20250514"));
        assert!(!pricing.can_price("unlisted-catalog-fixture"));
    }
    {
        let mut cache = pricing.resolved.lock().unwrap();
        assert_eq!(cache.len(), 2);
        assert!(cache["unlisted-catalog-fixture"].is_none());
        for number in 2..MAX_CACHED_MODELS {
            cache.insert(format!("test-{number}"), None);
        }
    }
    assert!(!pricing.can_price("unlisted-catalog-fixture-2"));
    assert_eq!(pricing.resolved.lock().unwrap().len(), MAX_CACHED_MODELS);
}

#[test]
fn models_dev_is_an_exact_fallback_and_honors_conflict_tombstones() {
    let mut pricing = ModelPricing::from_bundled();
    pricing.primary = load_compact_catalog(r#"{"models":{
        "priority-model":{"i":1,"o":2,"cw":1,"cr":1},
        "vendor/priority-model-v2":{"i":2,"o":2,"cw":2,"cr":2}
    }}"#);
    pricing.secondary = load_compact_catalog(r#"{"models":{
        "priority-model":{"i":3,"o":2,"cw":3,"cr":3},
        "priority-model-v2":{"i":4,"o":2,"cw":4,"cr":4},
        "secondary-only":{"i":5,"o":2,"cw":5,"cr":5},
        "conflict":{"i":6,"o":2,"cw":6,"cr":6}
    },"retired":["conflict"]}"#);

    assert_eq!(pricing.resolve("priority-model").unwrap().input_per_million, 1.0);
    assert_eq!(pricing.resolve("priority-model-v2").unwrap().input_per_million, 2.0);
    assert_eq!(pricing.resolve("secondary-only").unwrap().input_per_million, 5.0);
    assert!(!pricing.can_price("secondary-only-extra"));
    assert!(!pricing.can_price("conflict"));
    assert!(ModelPricing::from_bundled().can_price("@cf/aisingapore/gemma-sea-lion-v4-27b-it"));
}

#[test]
fn lite_llm_fuzzy_match_requires_boundaries_and_cannot_price_unverified_variants() {
    let mut pricing = ModelPricing::from_bundled();
    pricing.primary = load_compact_catalog(r#"{"models":{
        "vendor/example-4":{"i":1,"o":2,"cw":1,"cr":1},
        "space-bunny":{"i":3,"o":2,"cw":3,"cr":3}
    }}"#);
    pricing.secondary.clear();

    assert!(pricing.can_price("vendor/example-4-20250514"));
    assert!(pricing.can_price("space bunny"));
    for unknown in ["vendor/example-4.5", "notexample-4", "example-4-fast", "example-4-free"] {
        assert!(!pricing.can_price(unknown), "{unknown} was incorrectly priced");
    }
}

#[test]
fn compact_prompt_tiers_apply_to_the_entire_request_including_cache_writes() {
    let entries = load_compact_catalog(r#"{"models":{"example":{
        "i":1,"o":2,"cw":3,"cr":4,"cw1":5,"tiers":[
            {"threshold_prompt_tokens":100,"input_per_million":7},
            {"threshold_prompt_tokens":200,"includes_threshold":true,
             "output_per_million":8,"cache_write_1h_per_million":9}
        ]
    }}}"#);
    let rates = &entries["example"];
    let mut tokens = TokenBreakdown {
        input: 90,
        output: 10,
        cache_write5m: 0,
        cache_write1h: 10,
        cache_read: 0,
        is_fast: false,
    };
    let check = |actual: f64, expected: f64| assert!((actual * 1_000_000.0 - expected).abs() < 1e-9);
    check(rates.cost_dollars(&tokens), 160.0);
    tokens.input = 91;
    check(rates.cost_dollars(&tokens), 707.0);
    tokens.input = 190;
    check(rates.cost_dollars(&tokens), 360.0);
    check(rates.cost_dollars_with_options(&tokens, false), 260.0);
    check(rates.scaled(2.0).cost_dollars(&tokens), 720.0);
}

#[test]
fn bundled_pricing_resolves_claude_sonnet() {
    let p = ModelPricing::from_bundled();
    assert!(p.can_price("claude-sonnet-4-20250514"));
}

#[test]
fn opus_fast_override_from_supplement() {
    let p = ModelPricing::from_bundled();
    let rates = p.resolve("claude-opus-4-7-fast").expect("opus fast");
    assert!((rates.input_per_million - 30.0).abs() < 0.01);
}

#[test]
fn gpt_5_6_aliases_resolve() {
    let p = ModelPricing::from_bundled();
    assert!(p.can_price("gpt-5.6-sol"));
    assert!(p.can_price("gpt-5.6-terra-fast"));
    assert!(p.can_price("gpt-5.6-luna"));
}

#[test]
fn grok_4_5_and_kimi_k2_7_aliases() {
    let p = ModelPricing::from_bundled();
    let grok = p.resolve("grok-4.5-fast-high").expect("grok fast high");
    let grok_fast = p.resolve("grok-4.5-fast").expect("grok fast");
    assert!((grok.input_per_million - grok_fast.input_per_million).abs() < 0.01);
    assert!((grok_fast.output_per_million - 12.0).abs() < 0.01);
    assert!(p.can_price("cursor-grok-4.5-fast-xhigh"));
    assert!(p.can_price("kimi-k2.7-code"));
    assert!(p.can_price("kimi-k2p7"));
}

#[test]
fn v078_v079_pricing_aliases() {
    let p = ModelPricing::from_bundled();
    let k3 = p.resolve("kimi-k3").expect("kimi k3");
    assert!((k3.input_per_million - 3.0).abs() < 0.01);
    let grok46 = p.resolve("cursor-grok-4.6-fast-high").expect("grok 4.6");
    assert!((grok46.input_per_million - 4.0).abs() < 0.01);
    let opus5 = p.resolve("claude-opus-5").expect("opus 5");
    assert!((opus5.input_per_million - 5.0).abs() < 0.01);
    assert!(p.can_price("daybreak-blue-latest"));
    let router = p.resolve("Opus 5 (Auto Balanced)").expect("cursor router");
    assert!((router.input_per_million - 5.0).abs() < 0.01);
}

#[test]
fn v0710_pricing_aliases_and_rates() {
    let p = ModelPricing::from_bundled();
    let glm = p.resolve("glm-5.3-high").expect("glm 5.3");
    assert!((glm.input_per_million - 1.4).abs() < 0.01);
    assert!((glm.output_per_million - 4.4).abs() < 0.01);
    assert!(p.can_price("gemini-3.7-flash"));
    assert!(p.can_price("gemini-3.6-flash"));
    assert_eq!(p.canonical_name("grok-proxy").as_deref(), Some("grok-build-0.1"));
    assert!(p.can_price("grok-4-6"));
    assert!(p.can_price("cursor-grok-4-6-fast"));
    let luna = p.resolve("gpt-5.6-luna").expect("luna");
    assert!((luna.input_per_million - 0.2).abs() < 0.01);
    assert!((luna.output_per_million - 1.2).abs() < 0.01);
    let luna_fast = p.resolve("gpt-5.6-luna-fast").expect("luna fast");
    assert!((luna_fast.input_per_million - 0.4).abs() < 0.01);
    assert!((luna_fast.output_per_million - 2.4).abs() < 0.01);
}

#[test]
fn v0711_v0712_pricing_aliases_and_rates() {
    let p = ModelPricing::from_bundled();
    assert!(p.can_price("muse-spark-1.3"));
    assert!(p.can_price("muse-spark-1.3-high"));
    assert!(p.can_price("gpt-6-astra"));
    assert!(p.can_price("gpt-6-astra-fast"));
    assert!(p.can_price("gemini-3.8-flash"));
    assert!(p.can_price("claude-fable-5.1"));
    let astra = p.resolve("gpt-6-astra").expect("astra");
    assert!(astra.input_per_million > 0.0);
    let spark = p.resolve("muse-spark-1.3-xhigh").expect("spark");
    assert!((spark.input_per_million - 1.25).abs() < 0.01);
}

#[test]
fn v0715_gemini_none_shorthand_aliases() {
    let p = ModelPricing::from_bundled();
    assert_eq!(p.canonical_name("gemini-2.5-flash-n").as_deref(), Some("gemini-2.5-flash"));
    assert_eq!(p.canonical_name("gemini-3-flash-n").as_deref(), Some("gemini-3-flash-preview"));
    assert_eq!(p.canonical_name("gemini-3.5-flash-n").as_deref(), Some("gemini-3.5-flash"));
    assert_eq!(p.canonical_name("gemini-3.6-flash-n").as_deref(), Some("gemini-3.6-flash"));
    assert_eq!(p.canonical_name("gemini-3.7-flash-n").as_deref(), Some("gemini-3.7-flash"));
    assert_eq!(p.canonical_name("gemini-3.8-flash-n").as_deref(), Some("gemini-3.8-flash"));
    assert_eq!(p.canonical_name("gemini-3-pro-n").as_deref(), Some("gemini-3-pro-preview"));
    assert_eq!(p.canonical_name("gemini-3-pro-none").as_deref(), Some("gemini-3-pro-preview"));
    assert_eq!(p.canonical_name("gemini-3-pro"), None);
    assert_eq!(p.canonical_name("gemini-3.1-pro-n").as_deref(), Some("gemini-3.1-pro-preview"));
}

#[test]
fn request_wide_long_context_uses_higher_tier_for_all_fields() {
    let rates = ModelRates {
        input_per_million: 1.0,
        output_per_million: 2.0,
        cache_write_per_million: 1.0,
        cache_read_per_million: 0.1,
        cache_write_1h_per_million: None,
        prompt_rate_tiers: Vec::new(),
        utc_rate_overrides: Vec::new(),
        input_above_200k: Some(10.0),
        output_above_200k: Some(20.0),
        cache_write_above_200k: Some(10.0),
        cache_read_above_200k: Some(1.0),
        cache_read_is_explicit: true,
        long_context_threshold_tokens: 200_000,
        fast_multiplier: 1.0,
    };
    let tokens = TokenBreakdown {
        input: 150_000,
        output: 1_000,
        cache_write5m: 40_000,
        cache_write1h: 0,
        cache_read: 20_000,
        is_fast: false,
    };
    // prompt = 210k → whole request at long-context rates
    let cost = rates.cost_dollars(&tokens);
    let expected = flat_cost(150_000, 10.0)
        + flat_cost(1_000, 20.0)
        + flat_cost(40_000, 10.0)
        + flat_cost(20_000, 1.0);
    assert!((cost - expected).abs() < 1e-9);
    let short = rates.cost_dollars_with_options(
        &TokenBreakdown {
            input: 1_000,
            output: 1_000,
            cache_write5m: 0,
            cache_write1h: 0,
            cache_read: 0,
            is_fast: false,
        },
        true,
    );
    assert!((short - flat_cost(1_000, 1.0) - flat_cost(1_000, 2.0)).abs() < 1e-9);
}
