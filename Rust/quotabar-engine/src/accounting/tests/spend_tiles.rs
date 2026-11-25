//! SpendTileMapperTests: tile presence, estimate markers, subtotals beside unknown-model warnings.

use super::*;
use crate::accounting::spend_tiles::append_token_usage_in;

fn series_of(days: &[(&str, i64)]) -> Vec<DailyUsageEntry> {
    days.iter().map(|(d, t)| entry(d, *t, None)).collect()
}

fn mapped(daily: Vec<DailyUsageEntry>) -> Vec<MetricLine> {
    mapped_lines(daily, vec![], BTreeMap::new(), None)
}

#[test]
fn idle_recent_days_left_unbacked() {
    // The source's last reported day is 3 days before today: today and yesterday are idle.
    let lines = mapped(series_of(&[("2026-06-22", 5_000), ("2026-06-23", 7_000)]));
    assert!(
        line(&lines, "Today").is_none(),
        "an idle today is left unbacked, so the tile reads No data"
    );
    assert!(
        line(&lines, "Yesterday").is_none(),
        "ditto yesterday, not a fabricated $0.00"
    );
    assert!(
        line(&lines, "Last 30 Days").is_some(),
        "the 30-day total still renders"
    );
}

#[test]
fn in_range_idle_day_also_left_unbacked() {
    let lines = mapped(series_of(&[("2026-06-24", 9_000), ("2026-06-26", 3_000)]));
    assert_eq!(values(&lines, "Today"), Some(vec![tokens(3_000.0)]));
    assert!(
        line(&lines, "Yesterday").is_none(),
        "an idle in-range day is No data, not $0.00 · 0 tokens"
    );
}

#[test]
fn empty_series_leaves_all_tiles_unbacked() {
    for daily in [vec![], vec![entry("2026-06-25", 0, None)]] {
        assert!(
            mapped(daily).is_empty(),
            "an all-zero window appends no spend tiles"
        );
    }
}

#[test]
fn used_day_renders_its_values() {
    let lines = mapped(vec![entry("2026-06-26", 12_000, Some(1.50))]);
    assert_eq!(
        values(&lines, "Today"),
        Some(vec![dollars(1.50, true, false), tokens(12_000.0)])
    );
}

#[test]
fn estimated_cost_marker_follows_the_days_in_each_period() {
    let mut lines = Vec::new();
    let options = TokenUsageOptions {
        estimated: true,
        estimated_cost_days: Some(set(&["2026-06-25"])),
        ..TokenUsageOptions::default()
    };
    append_token_usage_in(
        &series(vec![
            entry("2026-06-26", 100, Some(1.0)),
            entry("2026-06-25", 200, Some(2.0)),
        ]),
        &mut lines,
        day(2026, 6, 26),
        &options,
        utc(),
    );
    let first = |label| values(&lines, label).and_then(|v| v.first().map(|x| x.estimated));
    assert_eq!(
        first("Today"),
        Some(false),
        "an older estimate must not mark today's authoritative amount"
    );
    assert_eq!(first("Yesterday"), Some(true));
    assert_eq!(
        first("Last 30 Days"),
        Some(true),
        "the combined window is estimated when any included day is"
    );
}

#[test]
fn known_cost_subtotal_stays_visible_beside_unknown_model_warning() {
    let incomplete = |date, tokens, cost| DailyUsageEntry {
        cost_is_complete: false,
        has_unexplained_incomplete_cost: Some(false),
        ..entry(date, tokens, Some(cost))
    };
    let lines = mapped_lines(
        vec![
            incomplete("2026-06-26", 1_000, 1.25),
            incomplete("2026-06-25", 500, 0.75),
        ],
        vec![],
        unknown_by_day(&[
            ("2026-06-26", &["mystery-today"]),
            ("2026-06-25", &["mystery-yesterday"]),
        ]),
        None,
    );
    assert_eq!(
        values(&lines, "Today"),
        Some(vec![dollars(1.25, true, true), tokens(1_000.0)])
    );
    assert_eq!(
        values(&lines, "Yesterday"),
        Some(vec![dollars(0.75, true, true), tokens(500.0)])
    );
    assert_eq!(
        values(&lines, "Last 30 Days"),
        Some(vec![dollars(2.0, true, true), tokens(1_500.0)])
    );
    let Some(MetricLine::Values { unknown_models, .. }) = line(&lines, "Yesterday") else {
        panic!("expected the Yesterday spend tile")
    };
    assert_eq!(unknown_models, &vec!["mystery-yesterday".to_string()]);
}

#[test]
fn unexplained_incomplete_cost_stays_hidden() {
    let lines = mapped(vec![DailyUsageEntry {
        cost_is_complete: false,
        ..entry("2026-06-26", 1_000, Some(1.25))
    }]);
    assert_eq!(values(&lines, "Today"), Some(vec![tokens(1_000.0)]));
    assert_eq!(values(&lines, "Last 30 Days"), Some(vec![tokens(1_000.0)]));
}

#[test]
fn unknown_model_does_not_explain_separate_structural_cost_gap() {
    let lines = mapped_lines(
        vec![DailyUsageEntry {
            cost_is_complete: false,
            has_unexplained_incomplete_cost: Some(true),
            ..entry("2026-06-26", 1_000, Some(1.25))
        }],
        vec![model_day(
            "2026-06-26",
            vec![
                model("known-model", 900, Some(1.25)),
                model("mystery-model", 100, None),
            ],
        )],
        unknown_by_day(&[("2026-06-26", &["mystery-model"])]),
        None,
    );
    assert_eq!(values(&lines, "Today"), Some(vec![tokens(1_000.0)]));
    assert_eq!(values(&lines, "Last 30 Days"), Some(vec![tokens(1_000.0)]));
    let breakdown = model_breakdown(&lines, "Today").expect("breakdown");
    assert!(breakdown.models.iter().all(|m| m.cost_usd.is_none()));
}

#[test]
fn saturated_token_counts_stay_lower_bounds_across_thirty_day_breakdown() {
    let lines = mapped_lines(
        vec![
            DailyUsageEntry {
                token_count_saturated: true,
                ..entry("2026-06-26", i64::MAX, Some(1.0))
            },
            entry("2026-06-25", 1, Some(0.1)),
        ],
        vec![
            model_day(
                "2026-06-26",
                vec![ModelUsageEntry {
                    token_count_saturated: Some(true),
                    ..model("large-model", i64::MAX, Some(1.0))
                }],
            ),
            model_day("2026-06-25", vec![model("large-model", 1, Some(0.1))]),
        ],
        BTreeMap::new(),
        None,
    );
    let Some(MetricLine::Values {
        values,
        model_breakdown,
        ..
    }) = line(&lines, "Last 30 Days")
    else {
        panic!("the 30-day spend row must survive saturated token values")
    };
    assert_eq!(values.first().map(|v| v.number), Some(1.1));
    assert_eq!(values.last().map(|v| v.number), Some(i64::MAX as f64));
    assert_eq!(
        values.last().and_then(|v| v.token_count_saturated),
        Some(true)
    );
    let first_model = model_breakdown
        .as_ref()
        .and_then(|b| b.models.first())
        .expect("model");
    assert_eq!(first_model.cost_usd, Some(1.1));
    assert_eq!(first_model.token_count_saturated, Some(true));
}

#[test]
fn single_model_period_still_gets_model_breakdown() {
    let single = model("gpt-5.5", 300, Some(3.0));
    let lines = mapped_lines(
        vec![entry("2026-06-26", 300, Some(3.0))],
        vec![model_day("2026-06-26", vec![single.clone()])],
        BTreeMap::new(),
        None,
    );
    let breakdown = model_breakdown(&lines, "Today").expect("breakdown");
    assert_eq!(breakdown.total_tokens, 300);
    assert_eq!(breakdown.total_cost_usd, Some(3.0));
    assert_eq!(breakdown.models, vec![single]);
}

#[test]
fn model_breakdown_iso_date_matches_local_period_day() {
    // A +02:00 calendar: local midnight on 2026-06-26 is 2026-06-25T22:00:00Z, so a UTC ISO string
    // must still land in the local "Today".
    let zone = DayZone::fixed_east(2 * 3600).expect("zone");
    let now = day_at(2 * 3600, 2026, 6, 26);
    let mut lines = Vec::new();
    let options = TokenUsageOptions {
        model_usage: Some(ModelUsageSeries {
            daily: vec![model_day(
                "2026-06-25T22:00:00Z",
                vec![model("gpt-5.5", 300, Some(3.0))],
            )],
        }),
        ..TokenUsageOptions::default()
    };
    append_token_usage_in(
        &series(vec![entry("2026-06-26", 300, Some(3.0))]),
        &mut lines,
        now,
        &options,
        zone,
    );
    let breakdown = model_breakdown(&lines, "Today").expect("breakdown");
    assert_eq!(model_names(&breakdown), vec!["gpt-5.5"]);
}

#[test]
fn day_rows_with_other_date_shapes_resolve_to_the_same_day() {
    let lines = mapped(vec![
        entry("20260626", 10, None),
        entry("Jun 25, 2026", 5, None),
    ]);
    assert_eq!(values(&lines, "Today"), Some(vec![tokens(10.0)]));
    assert_eq!(values(&lines, "Yesterday"), Some(vec![tokens(5.0)]));
}

#[test]
fn partial_days_mark_values_and_keep_cost_as_lower_bound() {
    let mut lines = Vec::new();
    let options = TokenUsageOptions {
        partial_days: set(&["2026-06-26"]),
        ..TokenUsageOptions::default()
    };
    let incomplete = DailyUsageEntry {
        cost_is_complete: false,
        ..entry("2026-06-26", 100, Some(1.0))
    };
    append_token_usage_in(
        &series(vec![incomplete]),
        &mut lines,
        day(2026, 6, 26),
        &options,
        utc(),
    );
    let today = values(&lines, "Today").expect("today");
    assert_eq!(today[0].number, 1.0);
    assert_eq!(today[0].is_partial, Some(true));
    assert_eq!(today[0].is_lower_bound, Some(true));
    assert!(
        today[0].estimated,
        "a partial day marks its dollars estimated"
    );
    assert_eq!(today[1].is_partial, Some(true));
    assert!(today[1].estimated);
}
