//! `LogUsageScan` trimming/marking and the `ProviderUsageHistory` projection
//! (HistoryDashboardAggregatorTests' pruning case plus direct pins for the normalizing initializer).

use super::*;
use crate::accounting::{DailyUsageAccumulator, LogUsageScan, UsageHistoryWindow};
use crate::model::ProviderUsageHistory;

fn now() -> Timestamp {
    day(2026, 7, 13)
}

fn history(series: Vec<DailyUsageEntry>) -> ProviderUsageHistory {
    ProviderUsageHistory {
        series: super::series(series),
        ..ProviderUsageHistory::default()
    }
    .normalizing()
}

fn scan_with_two_days() -> LogUsageScan {
    let mut accumulator = DailyUsageAccumulator::new();
    for day in ["2026-07-01", "2026-07-10"] {
        accumulator.add(day, 10, Some(1.0), "m");
        accumulator.add_unknown_model(day, "mystery");
        accumulator.add_api_estimate(day, 0.5);
        accumulator.mark_estimated_cost(day);
        accumulator.mark_unmeasured_usage(day);
    }
    accumulator.build()
}

#[test]
fn dropping_days_trims_every_per_day_collection() {
    let trimmed = scan_with_two_days().dropping_days("2026-07-05");
    assert_eq!(
        trimmed
            .series
            .daily
            .iter()
            .map(|d| d.date.as_str())
            .collect::<Vec<_>>(),
        vec!["2026-07-10"]
    );
    assert_eq!(trimmed.model_usage.as_ref().map(|m| m.daily.len()), Some(1));
    assert_eq!(
        trimmed
            .unknown_models_by_day
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>(),
        vec!["2026-07-10"]
    );
    assert_eq!(
        trimmed.api_estimate_by_day.as_ref().map(|e| e.len()),
        Some(1)
    );
    assert_eq!(
        trimmed.api_estimate_incomplete_days,
        Some(set(&["2026-07-10"]))
    );
    assert_eq!(trimmed.estimated_cost_days, Some(set(&["2026-07-10"])));
    assert_eq!(trimmed.unmeasured_usage_days, Some(set(&["2026-07-10"])));
    assert_eq!(
        scan_with_two_days().dropping_days("2026-07-01"),
        scan_with_two_days(),
        "the boundary day is kept"
    );
}

#[test]
fn marking_unmeasured_usage_unions_days_and_ignores_an_empty_set() {
    let scan = LogUsageScan::new(series(vec![]), BTreeMap::new());
    assert_eq!(scan.marking_unmeasured_usage(&BTreeSet::new()), scan);
    let marked = scan
        .marking_unmeasured_usage(&set(&["2026-07-02"]))
        .marking_unmeasured_usage(&set(&["2026-07-01"]));
    assert_eq!(
        marked.unmeasured_usage_days,
        Some(set(&["2026-07-01", "2026-07-02"]))
    );
}

#[test]
fn scan_defaults_incomplete_estimate_days_to_unknown_model_days() {
    let scan = LogUsageScan::new(series(vec![]), unknown_by_day(&[("2026-07-01", &["x"])]));
    assert_eq!(
        scan.api_estimate_incomplete_days,
        Some(set(&["2026-07-01"]))
    );
}

#[test]
fn scan_json_matches_the_swift_coding_keys_and_round_trips() {
    let scan = scan_with_two_days();
    let json = serde_json::to_value(&scan).expect("encode");
    for key in [
        "series",
        "modelUsage",
        "unknownModelsByDay",
        "apiEstimateByDay",
        "apiEstimateIncompleteDays",
        "estimatedCostDays",
        "unmeasuredUsageDays",
    ] {
        assert!(json.get(key).is_some(), "missing {key}");
    }
    assert_eq!(json["series"]["daily"][0]["costUSD"], 1.0);
    let back: LogUsageScan = serde_json::from_value(json).expect("decode");
    assert_eq!(back, scan);
}

#[test]
fn lifetime_coverage_survives_pruning_of_thirty_day_model_details() {
    let old_day = "2026-06-12"; // 31 days before 2026-07-13
    let source = ProviderUsageHistory {
        series: series(vec![
            entry("2026-07-13", 100, Some(1.0)),
            DailyUsageEntry {
                cost_is_complete: false,
                ..entry(old_day, 200, Some(2.0))
            },
        ]),
        model_usage: Some(ModelUsageSeries {
            daily: vec![model_day(
                old_day,
                vec![
                    model("known-model", 100, Some(2.0)),
                    model("mystery-model", 100, None),
                ],
            )],
        }),
        unknown_models_by_day: unknown_by_day(&[(old_day, &["mystery-model"])]),
        partial_days: Some(set(&[old_day])),
        estimated_cost_days: Some(set(&[old_day])),
        ..ProviderUsageHistory::default()
    }
    .normalizing();

    let retained = source.retaining_history(now(), utc());
    assert!(
        retained.model_usage.is_none(),
        "the old day's model rows leave the 30-day detail window"
    );
    assert!(retained.unknown_models_by_day.get(old_day).is_none());
    assert_eq!(
        retained.partial_days,
        Some(set(&[old_day])),
        "lifetime partial status survives"
    );
    assert_eq!(
        retained.estimated_cost_days,
        Some(set(&[old_day])),
        "estimate provenance survives"
    );
    let old = retained
        .series
        .daily
        .iter()
        .find(|d| d.date == old_day)
        .expect("old day");
    assert_eq!(old.has_unexplained_incomplete_cost, Some(false));
    assert_eq!(retained.series.daily.len(), 2);
}

#[test]
fn retaining_history_drops_days_outside_the_lifetime_window() {
    let lifetime = UsageHistoryWindow::lifetime_day_keys(now(), utc());
    assert!(!lifetime.contains("2016-07-12"));
    let source = ProviderUsageHistory {
        series: series(vec![
            entry("2016-07-12", 1, Some(1.0)),
            entry("2016-07-13", 2, Some(1.0)),
        ]),
        api_estimate_by_day: Some(BTreeMap::from([("2016-07-12".to_string(), 1.0)])),
        api_estimate_incomplete_days: Some(set(&["2016-07-12"])),
        ..ProviderUsageHistory::default()
    };
    let retained = source.retaining_history(now(), utc());
    assert_eq!(
        retained
            .series
            .daily
            .iter()
            .map(|d| d.date.as_str())
            .collect::<Vec<_>>(),
        vec!["2016-07-13"]
    );
    assert_eq!(
        retained.api_estimate_by_day, None,
        "an emptied estimate map is dropped"
    );
    assert_eq!(retained.api_estimate_incomplete_days, Some(BTreeSet::new()));
}

#[test]
fn named_unknown_models_mark_their_rows_incomplete_and_classify_legacy_days() {
    let named_gap = DailyUsageEntry {
        cost_is_complete: false,
        ..entry("2026-07-13", 125, Some(1.0))
    };
    let source = ProviderUsageHistory {
        series: series(vec![named_gap]),
        model_usage: Some(ModelUsageSeries {
            daily: vec![model_day(
                "2026-07-13",
                vec![model("known", 100, Some(1.0)), model("Mystery", 25, None)],
            )],
        }),
        unknown_models_by_day: unknown_by_day(&[("2026-07-13", &["mystery"])]),
        ..ProviderUsageHistory::default()
    }
    .normalizing();
    let rows = &source.model_usage.as_ref().expect("usage").daily[0].models;
    assert_eq!(rows[1].cost_is_complete, Some(false));
    assert_eq!(rows[0].cost_is_complete, None);
    // Tokens add up, the unknown name is represented, and every incomplete row is named.
    assert_eq!(
        source.series.daily[0].has_unexplained_incomplete_cost,
        Some(false)
    );
    assert_eq!(
        source.api_estimate_incomplete_days,
        Some(set(&["2026-07-13"]))
    );

    // The same day with model rows that do not cover the total stays a structural gap.
    let short = ProviderUsageHistory {
        series: series(vec![DailyUsageEntry {
            cost_is_complete: false,
            ..entry("2026-07-13", 500, Some(1.0))
        }]),
        model_usage: source.model_usage.clone(),
        unknown_models_by_day: source.unknown_models_by_day.clone(),
        ..ProviderUsageHistory::default()
    }
    .normalizing();
    assert_eq!(
        short.series.daily[0].has_unexplained_incomplete_cost,
        Some(true)
    );

    // No named unknowns at all: always structural.
    let bare = history(vec![DailyUsageEntry {
        cost_is_complete: false,
        ..entry("2026-07-13", 5, Some(1.0))
    }]);
    assert_eq!(
        bare.series.daily[0].has_unexplained_incomplete_cost,
        Some(true)
    );
    assert_eq!(
        bare.clone().normalizing(),
        bare,
        "normalizing is idempotent"
    );
}
