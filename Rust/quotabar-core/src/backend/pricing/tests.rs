//! Resolution tests for the Rust pricing mirror. The Swift side owns the cross-engine parity
//! fixture (`RustPricingParityTests`); these pin the lookup rules themselves.

use std::sync::Arc;

use super::registry::snapshot_for;
use super::*;
use serde_json::json;

fn rates(input: f64, output: f64) -> ModelRates {
    ModelRates {
        input_per_million: input,
        output_per_million: output,
        cache_write_per_million: input,
        cache_read_per_million: input / 10.0,
        ..ModelRates::default()
    }
}

fn snapshot(
    supplement: Value,
    primary: Value,
    secondary: Value,
    open_router: Value,
) -> Arc<Snapshot> {
    let params = json!({
        "supplement": supplement,
        "primary": primary,
        "secondary": secondary,
        "openRouter": open_router,
    });
    Arc::new(Snapshot::from_params(&params).expect("snapshot"))
}

#[test]
fn supplement_wins_over_public_catalogs() {
    let snapshot = snapshot(
        json!({"pricing": {"m": rates(9.0, 9.0)}, "fastMultipliers": {}}),
        json!({"m": rates(1.0, 2.0)}),
        json!({}),
        json!({"m": rates(3.0, 4.0)}),
    );
    let resolved = snapshot.resolve("m", None, &mut Vec::new()).unwrap();
    assert_eq!(resolved.input_per_million, 9.0);
}

#[test]
fn openrouter_beats_litellm_then_normalized_retry_prices_separator_variants() {
    let snapshot = snapshot(
        json!({"pricing": {}, "fastMultipliers": {}}),
        json!({"grok-4-3": rates(1.0, 2.0)}),
        json!({}),
        json!({"grok-4-3": rates(5.0, 6.0)}),
    );
    assert_eq!(
        snapshot
            .resolve("grok-4-3", None, &mut Vec::new())
            .unwrap()
            .input_per_million,
        5.0
    );
    // `grok-4.3` misses exactly, then retries the separator-normalized form.
    assert_eq!(
        snapshot
            .resolve("grok-4.3", None, &mut Vec::new())
            .unwrap()
            .input_per_million,
        5.0
    );
}

#[test]
fn alias_canonical_is_tried_before_the_raw_name() {
    let snapshot = snapshot(
        json!({"pricing": {}, "fastMultipliers": {}}),
        json!({"canonical": rates(2.0, 3.0)}),
        json!({}),
        json!({}),
    );
    let resolved = snapshot
        .resolve("cursor-alias", Some("canonical"), &mut Vec::new())
        .unwrap();
    assert_eq!(resolved.input_per_million, 2.0);
}

#[test]
fn fast_variants_scale_the_base_entry_and_reset_the_multiplier() {
    let snapshot = snapshot(
        json!({"pricing": {}, "fastMultipliers": {"base": 2.0}}),
        json!({"base": rates(10.0, 20.0)}),
        json!({}),
        json!({}),
    );
    let resolved = snapshot
        .resolve("base-fast", None, &mut Vec::new())
        .unwrap();
    assert_eq!(resolved.input_per_million, 20.0);
    assert_eq!(resolved.output_per_million, 40.0);
    assert_eq!(resolved.cache_read_per_million, 2.0);
    assert_eq!(resolved.fast_multiplier, 1.0);
}

#[test]
fn fast_variants_without_a_multiplier_stay_unpriced() {
    let snapshot = snapshot(
        json!({"pricing": {}, "fastMultipliers": {}}),
        json!({"base": rates(10.0, 20.0)}),
        json!({}),
        json!({}),
    );
    assert!(snapshot
        .resolve("base-fast", None, &mut Vec::new())
        .is_none());
}

#[test]
fn dated_primary_entries_supply_fast_base_rates() {
    let snapshot = snapshot(
        json!({"pricing": {}, "fastMultipliers": {"gpt-5.5": 3.0}}),
        json!({
            "gpt-5.5-20260101": rates(1.0, 2.0),
            "gpt-5.5-20260301": rates(4.0, 5.0)
        }),
        json!({}),
        json!({}),
    );
    let resolved = snapshot
        .resolve("gpt-5.5-fast", None, &mut Vec::new())
        .unwrap();
    assert_eq!(resolved.input_per_million, 12.0);
}

#[test]
fn free_suffix_models_never_inherit_fuzzy_paid_rates() {
    let snapshot = snapshot(
        json!({"pricing": {}, "fastMultipliers": {}}),
        json!({"some-model": rates(10.0, 20.0)}),
        json!({}),
        json!({}),
    );
    assert!(snapshot
        .resolve("some-model-free", None, &mut Vec::new())
        .is_none());
}

#[test]
fn catalog_entries_carry_the_supplement_fast_multiplier() {
    let snapshot = snapshot(
        json!({"pricing": {}, "fastMultipliers": {"speedy": 4.0}}),
        json!({"speedy": rates(1.0, 2.0)}),
        json!({}),
        json!({}),
    );
    let resolved = snapshot.resolve("speedy", None, &mut Vec::new()).unwrap();
    assert_eq!(resolved.fast_multiplier, 4.0);
}

#[test]
fn recheck_lists_unpriced_and_fallback_priced_names_once() {
    let snapshot = snapshot(
        json!({"pricing": {}, "fastMultipliers": {}}),
        json!({"known": rates(1.0, 2.0)}),
        json!({}),
        json!({}),
    );
    let mut recheck = Vec::new();
    snapshot.resolve("known", None, &mut recheck);
    snapshot.resolve("mystery", None, &mut recheck);
    snapshot.resolve("known", None, &mut recheck);
    snapshot.resolve("mystery", None, &mut recheck);
    assert_eq!(recheck, vec!["known".to_string(), "mystery".to_string()]);
}

#[test]
fn preserves_exact_rate_bits_through_the_wire() {
    let params: Value = serde_json::from_str(
        r#"{
            "supplement": {"pricing": {}, "fastMultipliers": {}},
            "primary": {},
            "secondary": {"m": {
                "inputPerMillion": 11.0,
                "outputPerMillion": 9.600000000000001,
                "cacheWritePerMillion": 11.0,
                "cacheReadPerMillion": 1.1,
                "promptRateTiers": [],
                "cacheReadIsExplicit": true,
                "longContextThresholdTokens": 200000,
                "fastMultiplier": 1.0
            }},
            "openRouter": {}
        }"#,
    )
    .expect("params");
    let snapshot = Snapshot::from_params(&params).expect("snapshot");
    let resolved = snapshot.resolve("m", None, &mut Vec::new()).expect("rates");
    assert_eq!(resolved.output_per_million, 9.600000000000001);
}

#[test]
fn load_release_and_resolve_handles() {
    let loaded = load(&json!({
        "supplement": {"pricing": {}, "fastMultipliers": {}},
        "primary": {"m": rates(1.0, 2.0)},
        "secondary": {},
        "openRouter": {},
    }))
    .expect("load");
    let handle = loaded["handle"].as_u64().expect("handle");

    let resolved = resolve_op(&json!({
        "handle": handle,
        "models": ["m", "other"],
        "canonicalNames": {},
    }))
    .expect("resolve");
    assert_eq!(resolved["rates"]["m"]["inputPerMillion"], 1.0);
    assert_eq!(resolved["rates"]["other"], Value::Null);
    assert_eq!(resolved["recheckModels"], json!(["m", "other"]));

    assert_eq!(
        release(&json!({"handle": handle})).unwrap()["released"],
        true
    );
    let error = match snapshot_for(handle) {
        Ok(_) => panic!("released handle must not resolve"),
        Err(error) => error,
    };
    assert_eq!(error.kind, "invalid_request");
}
