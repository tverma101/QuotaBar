//! DailyUsageAccumulatorTests (and the merge cases in PiUsageScannerTests / UsageHistoryAggregatorTests):
//! the shared accumulate-then-assemble contract behind the Claude/Codex/Grok scanners.

use super::*;
use crate::accounting::{default_model_identity, DailyUsageAccumulator, LogUsageScan, RowOptions};

fn tagged<'a>(canonical: &'a str) -> RowOptions<'a> {
    RowOptions { canonical: Some(canonical), ..RowOptions::default() }
}

fn by_model(scan: &LogUsageScan, day: usize) -> BTreeMap<String, ModelUsageEntry> {
    scan.model_usage.as_ref().expect("model usage").daily[day].models.iter().map(|m| (m.model.clone(), m.clone())).collect()
}

fn near(actual: Option<f64>, expected: f64) {
    assert!((actual.expect("value") - expected).abs() < 0.0001, "{actual:?} != {expected}");
}

#[test]
fn build_sorts_days_newest_first_and_sums_per_model() {
    let mut accumulator = DailyUsageAccumulator::new();
    accumulator.add("2024-06-01", 100, Some(1.0), "sonnet");
    accumulator.add("2024-06-03", 50, Some(0.5), "sonnet");
    accumulator.add("2024-06-01", 200, Some(2.0), "sonnet");
    accumulator.add("2024-06-01", 10, Some(0.1), "opus");

    let scan = accumulator.build();
    assert_eq!(scan.series.daily.iter().map(|d| d.date.as_str()).collect::<Vec<_>>(), vec!["2024-06-03", "2024-06-01"]);
    assert_eq!(scan.series.daily.iter().map(|d| d.total_tokens).collect::<Vec<_>>(), vec![50, 310]);
    near(scan.series.daily[1].cost_usd, 3.1);

    let june1 = scan.model_usage.as_ref().and_then(|m| m.daily.iter().find(|d| d.date == "2024-06-01")).expect("june 1");
    let models: BTreeMap<_, _> = june1.models.iter().map(|m| (m.model.as_str(), m)).collect();
    assert_eq!(models["sonnet"].total_tokens, 300);
    near(models["sonnet"].cost_usd, 3.0);
    assert_eq!(models["opus"].total_tokens, 10);
}

#[test]
fn merging_incremental_scans_preserves_observed_model_variants() {
    let mut original = DailyUsageAccumulator::new();
    original.add("2026-10-02", 50, Some(0.5), "gpt-5.6-luna");
    let mut delta = DailyUsageAccumulator::new();
    delta.add_with("2026-10-02", 25, Some(0.25), "anthropic/openai/gpt-5.6-luna", tagged("gpt-5.6-luna"));

    let merged = DailyUsageAccumulator::merged(&[Some(original.build()), Some(delta.build())], None).expect("merged");
    assert_eq!(merged.series.daily[0].total_tokens, 75);
    near(merged.series.daily[0].cost_usd, 0.75);
    let model = &merged.model_usage.as_ref().expect("usage").daily[0].models[0];
    assert_eq!(model.model, "gpt-5.6-luna");
    let variants: BTreeSet<&str> = model.variants.iter().flatten().map(|v| v.model.as_str()).collect();
    assert_eq!(variants, BTreeSet::from(["gpt-5.6-luna", "anthropic/openai/gpt-5.6-luna"]));
}

#[test]
fn merge_helpers_preserve_saturated_model_and_variant_markers() {
    let mut accumulator = DailyUsageAccumulator::new();
    accumulator.add_with(
        "2026-10-02",
        i64::MAX,
        None,
        "router/model",
        RowOptions { canonical: Some("model"), token_count_saturated: true, ..RowOptions::default() },
    );
    let source = accumulator.build();
    let identity: &dyn Fn(&str) -> String = &default_model_identity;
    let merged = DailyUsageAccumulator::merged(&[Some(source.clone())], None).expect("merged");
    let preferring = DailyUsageAccumulator::merged_preferring_primary(Some(&source), &[]).0.expect("primary");
    let by_model_scan = DailyUsageAccumulator::merged_preferring_primary_by_model(Some(&source), &[], identity).0.expect("by model");

    for scan in [source, merged, preferring, by_model_scan] {
        assert!(scan.series.daily[0].token_count_saturated);
        let model = &scan.model_usage.as_ref().expect("usage").daily[0].models[0];
        assert_eq!(model.token_count_saturated, Some(true));
        assert_eq!(model.variants.as_ref().and_then(|v| v[0].token_count_saturated), Some(true));
    }
}

#[test]
fn unknown_models_stay_out_of_the_series() {
    let mut accumulator = DailyUsageAccumulator::new();
    accumulator.add_unknown_model("2024-06-02", "mystery-model");
    let scan = accumulator.build();
    // A day with only unpriceable usage never enters the series or the model breakdown.
    assert!(scan.series.daily.is_empty());
    assert_eq!(scan.model_usage.as_ref().map(|m| m.daily.is_empty()), Some(true));
    assert_eq!(scan.unknown_models_by_day, unknown_by_day(&[("2024-06-02", &["mystery-model"])]));
}

#[test]
fn daily_cost_coverage_and_model_costs_become_incomplete_for_mixed_usage() {
    let mut accumulator = DailyUsageAccumulator::new();
    accumulator.add("2026-10-14", 100, Some(1.0), "known");
    accumulator.add("2026-10-14", 25, None, "unknown");
    accumulator.add_unknown_model("2026-10-14", "unknown");

    let scan = accumulator.build();
    let day = &scan.series.daily[0];
    assert_eq!(day.total_tokens, 125);
    assert_eq!(day.cost_usd, Some(1.0), "the known priced subtotal remains available");
    assert!(!day.cost_is_complete);
    assert_eq!(day.has_unexplained_incomplete_cost, Some(false), "the named unknown explains the gap");
    let models = by_model(&scan, 0);
    assert_eq!(models["known"].cost_usd, Some(1.0));
    assert_eq!(models["unknown"].cost_usd, None);
}

#[test]
fn unnamed_incomplete_models_make_the_gap_unexplained() {
    let mut accumulator = DailyUsageAccumulator::new();
    accumulator.add("2026-10-14", 100, Some(1.0), "known");
    accumulator.add("2026-10-14", 25, None, "mystery");
    let day = accumulator.build().series.daily.remove(0);
    assert_eq!(day.has_unexplained_incomplete_cost, Some(true));

    let mut named = DailyUsageAccumulator::new();
    named.add("2026-10-14", 25, None, "mystery");
    named.add_named_unpriced_model("2026-10-14", "mystery");
    let day = named.build().series.daily.remove(0);
    assert_eq!(day.has_unexplained_incomplete_cost, Some(false));
    assert!(!day.cost_is_complete);
}

#[test]
fn public_api_estimate_is_marked_incomplete_when_provider_only_rate_exists() {
    let mut accumulator = DailyUsageAccumulator::new();
    accumulator.add("2026-10-14", 100, Some(0.25), "cursor-native-model");
    accumulator.record_api_estimate("2026-10-14", None, 100);
    accumulator.add("2026-10-14", 200, Some(0.10), "public-model");
    accumulator.record_api_estimate("2026-10-14", Some(0.08), 200);

    let scan = accumulator.build();
    assert_eq!(scan.api_estimate_by_day.as_ref().and_then(|e| e.get("2026-10-14")), Some(&0.08));
    assert_eq!(scan.api_estimate_incomplete_days, Some(set(&["2026-10-14"])));
}

#[test]
fn cost_overflow_keeps_a_finite_lower_bound() {
    let mut accumulator = DailyUsageAccumulator::new();
    accumulator.add("2026-10-14", 1, Some(1e308), "m");
    accumulator.add("2026-10-14", 1, Some(1e308), "m");
    accumulator.add("2026-10-14", 1, Some(f64::NAN), "m");
    let scan = accumulator.build();
    let day = &scan.series.daily[0];
    assert_eq!(day.cost_usd, Some(1e308));
    assert!(!day.cost_is_complete);
    assert_eq!(day.has_unexplained_incomplete_cost, Some(false), "a finite lower bound is safe to show");
    assert_eq!(by_model(&scan, 0)["m"].cost_is_complete, Some(false));
}

#[test]
fn token_totals_saturate_instead_of_wrapping() {
    let mut accumulator = DailyUsageAccumulator::new();
    accumulator.add("2026-10-14", i64::MAX, Some(1.0), "m");
    accumulator.add("2026-10-14", 5, Some(1.0), "m");
    let scan = accumulator.build();
    assert_eq!(scan.series.daily[0].total_tokens, i64::MAX);
    assert!(scan.series.daily[0].token_count_saturated);
    assert_eq!(by_model(&scan, 0)["m"].token_count_saturated, Some(true));
}

#[test]
fn model_rows_sort_by_cost_then_tokens_then_name() {
    let mut accumulator = DailyUsageAccumulator::new();
    for (model, tokens, cost) in [("b", 10, 1.0), ("a", 10, 1.0), ("z", 99, 1.0), ("free", 500, 0.0), ("hi", 1, 5.0)] {
        accumulator.add("2026-10-14", tokens, Some(cost), model);
    }
    let scan = accumulator.build();
    let names: Vec<&str> = scan.model_usage.as_ref().expect("usage").daily[0].models.iter().map(|m| m.model.as_str()).collect();
    assert_eq!(names, vec!["hi", "z", "a", "b", "free"]);
}

#[test]
fn marking_cost_incomplete_is_structural_for_the_day_and_scoped_for_one_model() {
    let mut accumulator = DailyUsageAccumulator::new();
    accumulator.add("2026-10-14", 10, Some(1.0), "a");
    accumulator.add("2026-10-14", 10, Some(1.0), "b");
    accumulator.mark_model_cost_incomplete("2026-10-14", "a", None);
    let scan = accumulator.build();
    assert!(scan.series.daily[0].cost_is_complete, "a per-model mark leaves the day complete");
    assert_eq!(by_model(&scan, 0)["a"].cost_is_complete, Some(false));
    assert_eq!(by_model(&scan, 0)["b"].cost_is_complete, None);

    accumulator.mark_cost_incomplete("2026-10-14", "b", None);
    let day = accumulator.build().series.daily.remove(0);
    assert!(!day.cost_is_complete);
    assert_eq!(day.has_unexplained_incomplete_cost, Some(true));
}

#[test]
fn legacy_daily_entry_without_coverage_bit_is_treated_as_incomplete() {
    let legacy: DailyUsageEntry = serde_json::from_str(r#"{"date":"2026-10-14","totalTokens":100,"costUSD":1}"#).expect("decode");
    assert!(!legacy.cost_is_complete);
    assert!(!legacy.token_count_saturated);
    let max: DailyUsageEntry = serde_json::from_str(&format!(r#"{{"date":"d","totalTokens":{}}}"#, i64::MAX)).expect("decode");
    assert!(max.token_count_saturated);

    let current = entry("2026-10-14", 100, Some(1.0));
    let round_trip: DailyUsageEntry = serde_json::from_str(&serde_json::to_string(&current).expect("encode")).expect("decode");
    assert!(round_trip.cost_is_complete);
}

#[test]
fn merged_preferring_primary_keeps_primary_days_and_fills_gaps_only() {
    let mut primary = DailyUsageAccumulator::new();
    primary.add("2024-06-01", 100, Some(1.0), "gpt-5");
    primary.add("2024-06-02", 50, Some(0.5), "gpt-5");
    let mut proxy = DailyUsageAccumulator::new();
    // Overlaps 2024-06-01 — must NOT add on top of primary.
    proxy.add("2024-06-01", 999, Some(9.0), "gpt-5.6-luna");
    // Gap day only primary never saw.
    proxy.add("2024-06-03", 20, Some(0.2), "gpt-5.6-luna");

    let (scan, used) = DailyUsageAccumulator::merged_preferring_primary(Some(&primary.build()), &[Some(proxy.build())]);
    assert!(used);
    let scan = scan.expect("scan");
    let by_day: BTreeMap<_, _> = scan.series.daily.iter().map(|d| (d.date.as_str(), d)).collect();
    assert_eq!(by_day["2024-06-01"].total_tokens, 100);
    near(by_day["2024-06-01"].cost_usd, 1.0);
    assert_eq!(by_day["2024-06-02"].total_tokens, 50);
    assert_eq!(by_day["2024-06-03"].total_tokens, 20);
    near(by_day["2024-06-03"].cost_usd, 0.2);
}

#[test]
fn merged_preferring_primary_reports_no_supplement_when_fully_overlapped() {
    let mut primary = DailyUsageAccumulator::new();
    primary.add("2024-06-01", 100, Some(1.0), "gpt-5");
    let mut proxy = DailyUsageAccumulator::new();
    proxy.add("2024-06-01", 999, Some(9.0), "gpt-5.6-luna");

    let (scan, used) = DailyUsageAccumulator::merged_preferring_primary(Some(&primary.build()), &[Some(proxy.build())]);
    assert!(!used);
    assert_eq!(scan.expect("scan").series.daily.iter().map(|d| d.total_tokens).collect::<Vec<_>>(), vec![100]);
    assert!(DailyUsageAccumulator::merged_preferring_primary(None, &[None]).0.is_none());
}

#[test]
fn codex_merge_fills_distinct_models_within_covered_days_and_keeps_primary_overlap() {
    let mut router = DailyUsageAccumulator::new();
    router.add("2026-10-16", 100, Some(1.0), "gpt-5");
    router.record_api_estimate("2026-10-16", Some(0.8), 100);
    let mut native = DailyUsageAccumulator::new();
    native.add("2026-10-16", 900, Some(9.0), "gpt-5");
    native.add("2026-10-16", 40, Some(0.4), "gpt-5-codex-mini");
    native.record_api_estimate("2026-10-16", Some(7.2), 940);

    let identity: &dyn Fn(&str) -> String = &default_model_identity;
    let (scan, used) =
        DailyUsageAccumulator::merged_preferring_primary_by_model(Some(&router.build()), &[Some(native.build())], identity);
    assert!(used);
    let scan = scan.expect("scan");
    let day = &scan.series.daily[0];
    assert_eq!(day.total_tokens, 140);
    near(day.cost_usd, 1.4);
    let models = by_model(&scan, 0);
    assert_eq!(models["gpt-5"].total_tokens, 100, "the primary same-model row wins");
    assert_eq!(models["gpt-5-codex-mini"].total_tokens, 40, "a second model on the same day is retained");
    assert_eq!(scan.api_estimate_by_day.as_ref().and_then(|e| e.get("2026-10-16")), Some(&0.8), "estimates are not double-added");
    assert_eq!(scan.api_estimate_incomplete_days, Some(set(&["2026-10-16"])), "a mixed-source day cannot be complete");
}

#[test]
fn merged_sums_native_and_pi_on_the_same_day_and_is_none_when_all_none() {
    let mut native = DailyUsageAccumulator::new();
    native.add("2026-10-16", 200, Some(1.0), "claude-sonnet");
    let mut pi = DailyUsageAccumulator::new();
    pi.add("2026-10-16", 100, Some(0.5), "claude-sonnet");
    let merged = DailyUsageAccumulator::merged(&[Some(native.build()), Some(pi.build())], None).expect("merged");
    near(merged.series.daily[0].cost_usd, 1.5);
    assert_eq!(merged.series.daily[0].total_tokens, 300);
    assert!(DailyUsageAccumulator::merged(&[None, None], None).is_none());
}

#[test]
fn merged_preferring_primary_keeps_gateway_variants_on_a_single_row() {
    let primary = LogUsageScan {
        model_usage: Some(ModelUsageSeries {
            daily: vec![model_day(
                "2026-07-13",
                vec![ModelUsageEntry {
                    variants: Some(vec![variant("anthropic/openai/gpt-5.4", 100, Some(0.1))]),
                    ..model("gpt-5.4", 100, Some(0.1))
                }],
            )],
        }),
        ..LogUsageScan::new(series(vec![entry("2026-07-13", 100, Some(0.1))]), BTreeMap::new())
    };
    let merged = DailyUsageAccumulator::merged_preferring_primary(Some(&primary), &[]).0.expect("merged");
    let model = &merged.model_usage.as_ref().expect("usage").daily[0].models[0];
    assert_eq!(model.total_tokens, 100);
    let names: Vec<&str> = model.variants.iter().flatten().map(|v| v.model.as_str()).collect();
    assert_eq!(names, vec!["anthropic/openai/gpt-5.4"]);
}

#[test]
fn merge_can_drop_days_before_a_cutoff() {
    let mut accumulator = DailyUsageAccumulator::new();
    accumulator.add("2026-10-01", 1, Some(1.0), "m");
    accumulator.add("2026-10-05", 2, Some(1.0), "m");
    accumulator.add_unknown_model("2026-10-01", "old");
    accumulator.mark_unmeasured_usage("2026-10-01");
    accumulator.add_api_estimate("2026-10-01", 1.0);
    accumulator.add_api_estimate("2026-10-05", 2.0);
    let merged = DailyUsageAccumulator::merged(&[Some(accumulator.build())], Some("2026-10-03")).expect("merged");
    assert_eq!(merged.series.daily.iter().map(|d| d.date.as_str()).collect::<Vec<_>>(), vec!["2026-10-05"]);
    assert!(merged.unknown_models_by_day.is_empty());
    assert_eq!(merged.unmeasured_usage_days, None);
    assert_eq!(merged.api_estimate_by_day.map(|e| e.len()), Some(1));
}
