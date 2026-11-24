//! Swift `ModelPricingTests` codec cases plus the behavioral cases of `PricingCompactCatalogTests`.

use super::*;
use crate::pricing::codecs::{
    catalog_from_compact, catalog_from_litellm, catalog_from_models_dev, catalog_from_open_router, compact_data, CodecError,
};
use crate::pricing::store::{bundled_data, SourceId};
use std::collections::HashSet;

fn round_trip(catalog: &PricingCatalog) -> PricingCatalog {
    catalog_from_compact(&compact_data(catalog)).expect("compact round trip")
}

#[test]
fn catalog_codecs_preserve_synthesized_cache_read_provenance() {
    let source = br#"
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
    "#;

    let decoded = catalog_from_litellm(source).unwrap();
    let explicit_rates = &decoded.entries["explicit"];
    let missing_rates = &decoded.entries["missing"];
    assert!(explicit_rates.cache_read_is_explicit);
    assert!(!missing_rates.cache_read_is_explicit);
    assert_eq!(missing_rates.cache_read_per_million, missing_rates.input_per_million);
    assert_close(
        cost(missing_rates, &TokenBreakdown { cache_read: 1_000_000, ..Default::default() }),
        missing_rates.input_per_million,
        0.000_001,
        "a missing published cache-read rate must not invent a discount",
    );

    let restored = round_trip(&decoded);
    assert!(restored.entries["explicit"].cache_read_is_explicit);
    assert!(!restored.entries["missing"].cache_read_is_explicit);
    assert_eq!(restored.entries["missing"].cache_read_per_million, missing_rates.input_per_million);
}

#[test]
fn litellm_imports_all_published_prompt_thresholds_and_round_trips_them() {
    let source = br#"
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
    "#;

    let catalog = catalog_from_litellm(source).unwrap();
    let rates = &catalog.entries["tiered"];
    let thresholds: Vec<i64> = rates.prompt_rate_tiers.iter().map(|t| t.threshold_prompt_tokens).collect();
    assert_eq!(thresholds, vec![200_000, 272_000]);
    let last = rates.prompt_rate_tiers.last().unwrap();
    assert_close(last.input_per_million.unwrap(), 3.0, 0.000_001, "last tier input");
    assert_close(last.cache_write_per_million.unwrap(), 3.75, 0.000_001, "last tier cache write");

    let restored = round_trip(&catalog);
    assert_eq!(restored.entries["tiered"].prompt_rate_tiers, rates.prompt_rate_tiers);
}

#[test]
fn models_dev_imports_context_tiers_and_omits_conflicting_duplicate_ids() {
    let source = br#"
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
    "#;

    let catalog = catalog_from_models_dev(source).unwrap();
    let tiered = &catalog.entries["tiered"];
    let thresholds: Vec<i64> = tiered.prompt_rate_tiers.iter().map(|t| t.threshold_prompt_tokens).collect();
    assert_eq!(thresholds, vec![32_000, 128_000, 200_000]);
    assert_eq!(tiered.prompt_rate_tiers.last().unwrap().input_per_million, Some(4.0));
    assert!(tiered.prompt_rate_tiers.first().unwrap().includes_threshold);
    assert_close(cost(tiered, &input_tokens(32_000)), 0.064, 0.000_001, "models.dev context tiers begin at the stated threshold");
    assert!(catalog.entries.get("ambiguous").is_none(), "different reseller prices must not pick an arbitrary provider");
    assert_eq!(catalog.retired_keys, HashSet::from(["ambiguous".to_string()]));
    assert!(catalog.retired_keys_are_authoritative);

    let restored = round_trip(&catalog);
    assert!(restored.retired_keys_are_authoritative);
    let with_old_bundle = cat([("ambiguous", rates(7.0, 9.0))]).merging(&restored);
    assert!(
        with_old_bundle.entries.get("ambiguous").is_none(),
        "the live conflict tombstone must beat an older bundled rate"
    );
}

#[test]
fn models_dev_uses_explicit_prompt_tier_cache_read_rate_without_base_cache_rate() {
    let source = br#"{"provider":{"models":{"tiered":{"cost":{"input":1,"output":2,"tiers":[{"input":3,"output":4,"cache_read":0.5,"tier":{"type":"context","size":1000}}]}}}}}"#;

    let catalog = catalog_from_models_dev(source).unwrap();
    let rates = &catalog.entries["tiered"];

    assert!(!rates.cache_read_is_explicit);
    assert_close(
        cost(rates, &TokenBreakdown { input: 1_000, cache_read: 2_000, ..Default::default() }),
        0.004,
        0.000_001,
        "tier cache read",
    );
}

#[test]
fn litellm_tier_only_cache_read_rate_survives_compaction_without_base_discount() {
    let source = br#"{"tiered":{"input_cost_per_token":0.000001,"output_cost_per_token":0.000002,"cache_read_input_token_cost_above_272k_tokens":0.0000002}}"#;

    let catalog = catalog_from_litellm(source).unwrap();
    assert!(!catalog.entries["tiered"].cache_read_is_explicit);

    let restored = round_trip(&catalog);
    let restored = &restored.entries["tiered"];
    assert!(!restored.cache_read_is_explicit);
    assert_close(
        cost(restored, &TokenBreakdown { cache_read: 272_001, ..Default::default() }),
        272_001.0 * 0.2 / 1_000_000.0,
        0.000_001,
        "tier-only cache read",
    );
}

#[test]
fn tier_cache_read_does_not_turn_fallback_into_an_incorrect_base_rate() {
    let source = br#"
    {"data":[{"id":"vendor/model","pricing":{
      "prompt":"0.000001","completion":"0.000002","overrides":[
        {"min_prompt_tokens":1000,"prompt":"0.000003"},
        {"min_prompt_tokens":2000,"prompt":"0.000004","input_cache_read":"0"},
        {"utc_days":["monday"],"prompt":"0.000005"},
        {"utc_days":["tuesday"],"prompt":"0.000005","input_cache_read":"0.0000005"}
      ]}}],"total_count":1,"links":{"next":null}}
    "#;
    let catalog = catalog_from_open_router(source).unwrap();
    let restored = round_trip(&catalog);
    let rates = &restored.entries["vendor/model"];
    let monday = epoch("2026-10-26T12:00:00Z");
    let tuesday = epoch("2026-10-27T12:00:00Z");
    assert!(!rates.cache_read_is_explicit);
    assert_close(cost(rates, &TokenBreakdown { cache_read: 1000, ..Default::default() }), 0.003, 1e-12, "1k tier fallback");
    assert_close(cost(rates, &TokenBreakdown { cache_read: 2000, ..Default::default() }), 0.0, 1e-12, "2k tier explicit 0");
    assert_close(rates.cost_dollars(&TokenBreakdown { cache_read: 100, ..Default::default() }, Some(monday), true), 0.0005, 1e-12, "monday timed fallback");
    assert_close(rates.cost_dollars(&TokenBreakdown { cache_read: 100, ..Default::default() }, Some(tuesday), true), 0.00005, 1e-12, "tuesday timed explicit");
}

#[test]
fn invalid_published_costs_are_rejected_instead_of_poisoning_spend() {
    let lite = br#"
    {
      "negative": {"input_cost_per_token": -0.000001, "output_cost_per_token": 0.000002},
      "huge": {"input_cost_per_token": 1e308, "output_cost_per_token": 0.000002},
      "bad-cache": {"input_cost_per_token": 0.000001, "output_cost_per_token": 0.000002,
                    "cache_read_input_token_cost": -0.0000005},
      "valid": {"input_cost_per_token": 0.000001, "output_cost_per_token": 0.000002}
    }
    "#;

    let catalog = catalog_from_litellm(lite).unwrap();
    assert!(catalog.entries.get("negative").is_none(), "a negative published rate must not invert spend");
    assert!(catalog.entries.get("huge").is_none(), "an unrepresentable rate must not reach a dollar total");
    let bad_cache = &catalog.entries["bad-cache"];
    assert!(!bad_cache.cache_read_is_explicit, "an invalid cache rate falls back to the input rate");
    assert_eq!(bad_cache.cache_read_per_million, bad_cache.input_per_million);
    assert!(catalog.entries.contains_key("valid"));

    let models_dev = br#"
    {"provider":{"models":{
      "negative":{"cost":{"input":-1,"output":2}},
      "huge":{"cost":{"input":1e308,"output":2}},
      "valid":{"cost":{"input":1,"output":2}}
    }}}
    "#;

    let dev = catalog_from_models_dev(models_dev).unwrap();
    assert!(dev.entries.get("negative").is_none());
    assert!(dev.entries.get("huge").is_none());
    assert!(dev.entries.contains_key("valid"));
}

#[test]
fn open_router_codec_adds_only_unique_base_aliases_and_keeps_variant_pricing_exact() {
    let source = br#"
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
    "#;

    let catalog = catalog_from_open_router(source).unwrap();

    assert_eq!(catalog.find_exact("vendor/model-a").map(|(_, r)| r.input_per_million), Some(3.0));
    assert_eq!(catalog.find_exact("model-a").map(|(_, r)| r.input_per_million), Some(3.0));
    assert_eq!(catalog.find_exact("vendor/model-a:free").map(|(_, r)| r.input_per_million), Some(0.0));
    assert!(catalog.find_exact("ambiguous").is_none(), "ambiguous bare ids must not pick a route price");
    assert!(catalog.find_exact("bad").is_none(), "invalid rates must be skipped");
    let rates = catalog.find_exact("model-a").unwrap().1;
    assert_eq!(rates.cache_read_per_million, 3.0, "unknown caching must not assume a discount");
    assert!(!rates.cache_read_is_explicit);
}

const QWEN_FEED: &[u8] = br#"
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
"#;

#[test]
fn open_router_cache_prices_and_multiple_prompt_tiers_survive_compact_caching() {
    let fetched = catalog_from_open_router(QWEN_FEED).unwrap();
    let original = fetched.find_exact("qwen/qwen3.7-flash").unwrap().1.clone();
    assert_close(original.cache_write_per_million, 0.038, 0.000_001, "cache write");
    assert_close(original.cache_read_per_million, 0.006, 0.000_001, "cache read");
    assert_close(original.cache_write_1h_per_million.unwrap(), 0.06, 0.000_001, "cache write 1h");
    assert!(original.cache_read_is_explicit);
    assert_eq!(original.prompt_rate_tiers.len(), 2, "time-of-day overrides are not prompt-length tiers");
    assert_eq!(original.utc_price_overrides.as_ref().map(|o| o.len()), Some(1), "UTC-day rates are retained separately from prompt tiers");
    assert!(original.prompt_rate_tiers[0].includes_threshold);

    let cached = round_trip(&fetched);
    let restored = cached.find_exact("qwen/qwen3.7-flash").unwrap().1;
    assert_eq!(*restored, original);

    assert_close(cost(&original, &input_tokens(31_999)), 31_999.0 * 0.03 / 1_000_000.0, 0.000_000_001, "below first tier");
    assert_close(
        cost(&original, &input_tokens(32_000)),
        32_000.0 * 0.1 / 1_000_000.0,
        0.000_000_001,
        "OpenRouter's min_prompt_tokens threshold is inclusive",
    );
    assert_close(cost(&original, &input_tokens(256_000)), 256_000.0 * 0.2 / 1_000_000.0, 0.000_000_001, "second tier");

    let mut all_buckets = tokens(1_000_000, 1_000_000, 1_000_000, 1_000_000, 1_000_000);
    assert_close(cost(&original, &all_buckets), 1.79, 0.000_001, "all buckets");
    all_buckets.is_fast = true;
    assert_close(cost(&original, &all_buckets), 1.79, 0.000_001, "all buckets, fast flag has no multiplier");
}

#[test]
fn open_router_utc_price_windows_apply_by_event_timestamp_and_survive_cache() {
    let source = br#"
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
    "#;

    let catalog = catalog_from_open_router(source).unwrap();
    let cached = round_trip(&catalog);
    let rates = cached.find_exact("deepseek/deepseek-v4.1-flash-1017").unwrap().1;
    let t = tokens(1_000_000, 0, 0, 1_000_000, 1_000_000);
    let peak = epoch("2026-10-26T02:00:00Z");
    let off_peak = epoch("2026-10-26T04:00:00Z");
    let weekend = epoch("2026-10-25T02:00:00Z");

    assert_close(rates.cost_dollars(&t, Some(peak), true), 1.506, 0.000_001, "peak");
    assert_close(rates.cost_dollars(&t, Some(off_peak), true), 0.753, 0.000_001, "off peak");
    assert_close(rates.cost_dollars(&t, Some(weekend), true), 0.753, 0.000_001, "weekend");
    assert_eq!(
        rates.utc_price_overrides.as_ref().and_then(|o| o.last()).and_then(|o| o.utc_end_minute),
        Some(1_440),
        "an end of 00:00 after a daytime start denotes midnight at the end of that day"
    );
}

#[test]
fn open_router_gpt_6_1_sol_272k_boundary_is_exclusive_for_standard_and_batch() {
    let source = br#"
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
    "#;

    let catalog = catalog_from_open_router(source).unwrap();
    let standard = catalog.find_exact("openai/gpt-6.1-sol").unwrap().1;
    let batch = catalog.find_exact("openai/gpt-6.1-sol:batch").unwrap().1;
    let ordinary = catalog.find_exact("vendor/other-model").unwrap().1;

    assert!(!standard.prompt_rate_tiers.first().unwrap().includes_threshold);
    assert!(!batch.prompt_rate_tiers.first().unwrap().includes_threshold);
    assert_close(cost(standard, &input_tokens(272_000)), 0.544, 0.000_001, "standard at boundary");
    assert_close(cost(standard, &input_tokens(272_001)), 1.088004, 0.000_001, "standard above boundary");
    assert_close(cost(batch, &input_tokens(272_000)), 0.272, 0.000_001, "batch at boundary");
    assert_close(cost(batch, &input_tokens(272_001)), 0.544002, 0.000_001, "batch above boundary");
    assert!(
        ordinary.prompt_rate_tiers.first().unwrap().includes_threshold,
        "other OpenRouter min_prompt_tokens tiers remain inclusive"
    );
    assert_close(cost(ordinary, &input_tokens(32_000)), 0.096, 0.000_001, "ordinary tier");
}

#[test]
fn open_router_codec_rejects_incomplete_paginated_feed() {
    let source = br#"{"data":[{"id":"vendor/model","pricing":{"prompt":"0.000001","completion":"0.000002"}}],"total_count":2,"links":{"next":"/api/v1/models?offset=1"}}"#;

    assert_eq!(catalog_from_open_router(source).err(), Some(CodecError::IncompleteModelList));
}

#[test]
fn legacy_compact_catalog_treats_unmarked_cache_read_as_explicit() {
    // Snapshots created before `cre` existed cannot distinguish source and synthesized rates.
    let legacy = br#"{"models":{"gpt-test":{"i":5,"o":30,"cw":5,"cr":0.5}}}"#;

    let decoded = catalog_from_compact(legacy).unwrap();

    assert!(decoded.entries["gpt-test"].cache_read_is_explicit);
}

// MARK: - PricingCompactCatalogTests (behavioral cases)

#[test]
fn bundled_snapshots_decode_through_the_compact_codec() {
    for source in [SourceId::Litellm, SourceId::ModelsDev] {
        let data = bundled_data(source).expect("bundled snapshot present");
        let catalog = catalog_from_compact(data).unwrap_or_else(|e| panic!("{source:?} snapshot failed to decode: {e}"));
        assert!(!catalog.entries.is_empty(), "{source:?} snapshot is empty");
        // The compact codec must round-trip its own snapshots without losing a key or a rate.
        let restored = round_trip(&catalog);
        assert_eq!(restored.entries, catalog.entries, "{source:?} compact round trip changed entries");
        assert_eq!(restored.retired_keys, catalog.retired_keys, "{source:?} retired keys");
        assert_eq!(restored.retired_keys_are_authoritative, catalog.retired_keys_are_authoritative, "{source:?} authority");
    }
}

#[test]
fn huge_tier_threshold_does_not_trap_the_decoder() {
    // threshold_prompt_tokens past Int64.max must be rejected cleanly.
    let json = br#"
    {"models":{"cheap":{"i":0.1,"o":0.2,"cw":0.1,"cr":0.01,
    "tiers":[{"threshold_prompt_tokens":17000000000000000000,"input_per_million":1}]}}}
    "#;
    assert!(catalog_from_compact(json).is_err());
}

#[test]
fn wrong_typed_tiers_are_rejected() {
    let json = br#"{"models":{"cheap":{"i":0.1,"o":0.2,"cw":0.1,"cr":0.01,"tiers":"not-an-array"}}}"#;
    assert!(catalog_from_compact(json).is_err());
}

#[test]
fn wrong_typed_retired_key_is_rejected() {
    let json = br#"{"models":{},"retired":"not-an-array"}"#;
    assert!(catalog_from_compact(json).is_err());
}

#[test]
fn wrong_typed_optional_fields_are_rejected() {
    let json = br#"{"models":{"cheap":{"i":0.1,"o":0.2,"cw":0.1,"cr":0.01,"ia":"not-a-number"}}}"#;
    assert!(catalog_from_compact(json).is_err());
}

#[test]
fn empty_retired_array_is_present_as_authoritative() {
    let json = br#"{"models":{"cheap":{"i":0.1,"o":0.2,"cw":0.1,"cr":0.01}},"retired":[]}"#;
    let catalog = catalog_from_compact(json).unwrap();
    assert!(catalog.retired_keys.is_empty());
    assert!(catalog.retired_keys_are_authoritative);
}
