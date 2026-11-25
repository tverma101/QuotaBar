//! UsageTrendTests (the mapper-only cases) and the shared window / day-key helpers.

use super::*;
use crate::accounting::day::{day_key_from_usage_date, format_day};
use crate::accounting::spend_tiles::{append_usage_trend_in, month_day_label};
use crate::accounting::{DayZone, UsageHistoryWindow};
use crate::model::MetricChartPoint;
use chrono::NaiveDate;

fn trend(daily: Vec<DailyUsageEntry>, now: Timestamp) -> Vec<MetricLine> {
    let mut lines = Vec::new();
    append_usage_trend_in(
        &series(daily),
        &mut lines,
        now,
        "n",
        &BTreeSet::new(),
        None,
        utc(),
    );
    lines
}

fn points_of(lines: &[MetricLine]) -> Vec<MetricChartPoint> {
    match lines.first() {
        Some(MetricLine::Chart { points, .. }) => points.clone(),
        other => panic!("expected a chart line, got {other:?}"),
    }
}

fn day_label(year: i32, month: u32, day: u32) -> String {
    month_day_label(NaiveDate::from_ymd_opt(year, month, day).expect("date"))
}

#[test]
fn append_usage_trend_zero_fills_the_calendar_window() {
    let mut lines = Vec::new();
    append_usage_trend_in(
        &series(vec![
            entry("2026-06-21", 222_000_000, None),
            entry("2026-06-19", 500, None),
            entry("2026-06-20", 1_500_000, None),
        ]),
        &mut lines,
        day(2026, 6, 21),
        "Estimated from local Claude logs at API rates.",
        &BTreeSet::new(),
        None,
        utc(),
    );
    let Some(MetricLine::Chart {
        label,
        points,
        note,
    }) = lines.first()
    else {
        panic!("expected a chart line")
    };
    assert_eq!(label, "Usage Trend");
    assert_eq!(
        note.as_deref(),
        Some("Estimated from local Claude logs at API rates.")
    );
    assert_eq!(points.len(), UsageHistoryWindow::TOTAL_DAYS);
    assert_eq!(
        points.first().map(|p| p.label.clone()),
        Some(day_label(2026, 5, 23)),
        "today plus 29 back is 30 days"
    );
    assert_eq!(
        points.last().map(|p| p.label.clone()),
        Some(day_label(2026, 6, 21)),
        "window ends today"
    );
    let distinct: BTreeSet<&str> = points.iter().map(|p| p.label.as_str()).collect();
    assert_eq!(
        distinct.len(),
        UsageHistoryWindow::TOTAL_DAYS,
        "every day is a distinct bar"
    );
    let last = &points.last().expect("last").label;
    assert!(!last.contains('/'), "not the old numeric M/d format");
    assert!(
        last.chars().any(char::is_alphabetic),
        "carries a month name"
    );
    assert_eq!(points[27].value, 500.0);
    assert_eq!(points[28].value, 1_500_000.0);
    assert_eq!(points[29].value, 222_000_000.0);
    assert_eq!(points[0].value, 0.0, "an idle day is a zero bar");
    let labels: Vec<Option<&str>> = points[27..]
        .iter()
        .map(|p| p.value_label.as_deref())
        .collect();
    assert_eq!(
        labels,
        vec![Some("500 tokens"), Some("1.5M tokens"), Some("222M tokens")]
    );
    assert_eq!(points[0].value_label.as_deref(), Some("0 tokens"));
}

#[test]
fn saturated_trend_readout_uses_lower_bound_marker() {
    let saturated = DailyUsageEntry {
        token_count_saturated: true,
        ..entry("2026-06-21", i64::MAX, None)
    };
    let points = points_of(&trend(vec![saturated], day(2026, 6, 21)));
    assert!(points
        .last()
        .and_then(|p| p.value_label.as_deref())
        .is_some_and(|l| l.starts_with('≥')));
}

#[test]
fn trend_zero_fills_gaps_between_active_days() {
    let points = points_of(&trend(
        vec![
            entry("2026-06-19", 500, None),
            entry("2026-06-21", 222_000_000, None),
        ],
        day(2026, 6, 21),
    ));
    assert_eq!(points[27].label, day_label(2026, 6, 19));
    assert_eq!(points[28].label, day_label(2026, 6, 20));
    assert_eq!(
        points[28].value, 0.0,
        "the gap day is a zero bar, not removed"
    );
    assert_eq!(points[29].label, day_label(2026, 6, 21));
}

#[test]
fn trend_window_ends_at_today_even_when_usage_is_older() {
    let points = points_of(&trend(
        vec![entry("2026-06-19", 500, None)],
        day(2026, 6, 21),
    ));
    assert_eq!(
        points.last().map(|p| p.label.clone()),
        Some(day_label(2026, 6, 21))
    );
    assert_eq!(
        points[27].value, 500.0,
        "the one active day keeps its tokens"
    );
    assert_eq!(points[28].value, 0.0);
}

#[test]
fn trend_drops_days_older_than_the_window() {
    // 2026-05-10 is 30 days before 2026-06-09 and so outside the window; 2026-05-11 is the first
    // day inside it.
    let points = points_of(&trend(
        vec![
            entry("2026-05-10", 9_000, None),
            entry("2026-05-11", 1_000, None),
        ],
        day(2026, 6, 9),
    ));
    assert_eq!(points.len(), UsageHistoryWindow::TOTAL_DAYS);
    assert_eq!(
        points.first().map(|p| p.label.clone()),
        Some(day_label(2026, 5, 11))
    );
    assert_eq!(
        points.last().map(|p| p.label.clone()),
        Some(day_label(2026, 6, 9))
    );
    assert_eq!(
        points.iter().map(|p| p.value).sum::<f64>(),
        1_000.0,
        "out-of-window usage is excluded"
    );
}

#[test]
fn trend_aggregates_duplicate_days_and_parses_compact_dates() {
    let points = points_of(&trend(
        vec![
            entry("20260620", 1000, None),
            entry("2026-06-20", 500, None),
        ],
        day(2026, 6, 20),
    ));
    assert_eq!(
        points.last().map(|p| p.label.clone()),
        Some(day_label(2026, 6, 20))
    );
    assert_eq!(
        points.last().map(|p| p.value),
        Some(1500.0),
        "the day's tokens are summed, not split across bars"
    );
}

#[test]
fn append_usage_trend_skipped_when_window_has_no_usage() {
    assert!(
        trend(vec![], day(2026, 6, 21)).is_empty(),
        "no rows means no chart"
    );
    assert!(
        trend(vec![entry("2026-06-20", 0, None)], day(2026, 6, 21)).is_empty(),
        "a fully idle window has no trend"
    );
}

#[test]
fn partial_days_extend_the_trend_note() {
    let mut lines = Vec::new();
    let partial = set(&["2026-06-21"]);
    append_usage_trend_in(
        &series(vec![entry("2026-06-21", 5, None)]),
        &mut lines,
        day(2026, 6, 21),
        "src",
        &partial,
        None,
        utc(),
    );
    append_usage_trend_in(
        &series(vec![entry("2026-06-21", 5, None)]),
        &mut lines,
        day(2026, 6, 21),
        "src",
        &partial,
        Some("custom"),
        utc(),
    );
    let notes: Vec<Option<String>> = lines
        .iter()
        .map(|l| match l {
            MetricLine::Chart { note, .. } => note.clone(),
            _ => None,
        })
        .collect();
    assert_eq!(
        notes[0].as_deref(),
        Some("src · days with an active Hermes session are partial until it ends")
    );
    assert_eq!(notes[1].as_deref(), Some("src · custom"));
}

#[test]
fn window_is_exactly_thirty_calendar_days() {
    assert_eq!(UsageHistoryWindow::TOTAL_DAYS, 30);
    assert_eq!(
        UsageHistoryWindow::PREVIOUS_DAYS,
        UsageHistoryWindow::TOTAL_DAYS - 1
    );
    let keys = UsageHistoryWindow::day_keys(day(2026, 7, 13), utc());
    assert_eq!(keys.len(), 30);
    assert_eq!(keys.iter().next().map(String::as_str), Some("2026-06-14"));
    assert_eq!(
        keys.iter().next_back().map(String::as_str),
        Some("2026-07-13")
    );
}

#[test]
fn lifetime_window_spans_ten_calendar_years_including_leap_days() {
    // 2016-06-26 ..= 2026-06-26 spans ten years: 3650 days plus the 2020 and 2024 leap days, plus today.
    assert_eq!(
        UsageHistoryWindow::lifetime_days(day(2026, 6, 26), utc()),
        3_653
    );
    let keys = UsageHistoryWindow::lifetime_day_keys(day(2026, 6, 26), utc());
    assert!(keys.contains("2016-06-26"));
    assert!(!keys.contains("2016-06-25"));
    // A Feb 29 "today" clamps its ten-years-ago cutoff to Feb 28.
    let leap = UsageHistoryWindow::lifetime_day_keys(day(2028, 2, 29), utc());
    assert!(leap.contains("2018-02-28") && !leap.contains("2018-02-27"));
}

#[test]
fn day_key_uses_injected_zone_and_zero_pads() {
    // 2024-03-07 23:30 UTC pads month and day; the key is local-calendar so Tokyo reads the 8th.
    let instant = (days_from_civil(2024, 3, 7) * 86_400 + 23 * 3_600 + 30 * 60) as f64;
    assert_eq!(DayZone::utc().day_key(instant), "2024-03-07");
    assert_eq!(
        DayZone::fixed_east(9 * 3600)
            .expect("zone")
            .day_key(instant),
        "2024-03-08"
    );
    assert_eq!(
        crate::accounting::day_key_in(instant, DayZone::utc()),
        "2024-03-07"
    );
    assert_eq!(DayZone::utc().day_key(f64::NAN), "0000-00-00");
    // The system-local variant returns a well-formed key near the same date.
    let local = crate::accounting::day_key(instant);
    assert_eq!(local.len(), 10);
    assert!(["2024-03-07", "2024-03-08"].contains(&local.as_str()));
}

#[test]
fn usage_dates_normalize_to_day_keys() {
    let zone = utc();
    let key = |raw: &str| day_key_from_usage_date(raw, zone);
    assert_eq!(key(" 2026-06-20 ").as_deref(), Some("2026-06-20"));
    assert_eq!(key("20260620").as_deref(), Some("2026-06-20"));
    assert_eq!(key("2026-06-20T23:30:00Z").as_deref(), Some("2026-06-20"));
    assert_eq!(
        key("2026-06-20T23:30:00-05:00").as_deref(),
        Some("2026-06-21")
    );
    assert_eq!(
        key("2026-06-20T25:00:00Z").as_deref(),
        Some("2026-06-20"),
        "invalid time falls back to the day prefix"
    );
    assert_eq!(key("Jun 20, 2026").as_deref(), Some("2026-06-20"));
    assert_eq!(key("Jun 31, 2026"), None);
    assert_eq!(key(""), None);
    assert_eq!(key("yesterday"), None);
    let plus_two = DayZone::fixed_east(2 * 3600).expect("zone");
    assert_eq!(
        day_key_from_usage_date("2026-06-25T22:00:00Z", plus_two).as_deref(),
        Some("2026-06-26")
    );
    assert_eq!(
        format_day(NaiveDate::from_ymd_opt(7, 3, 9).expect("date")),
        "0007-03-09"
    );
}
