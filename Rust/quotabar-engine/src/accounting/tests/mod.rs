//! Ports of the Swift accounting tests (SpendTileMapperTests, UsageTrendTests,
//! DailyUsageAccumulatorTests and the scan/history cases in the provider suites) on a fixed-offset
//! calendar, so day keys never depend on the machine's time zone.

mod accumulator;
mod history;
mod spend_models;
mod spend_tiles;
mod trend;

use super::spend_tiles::{append_token_usage_in, TokenUsageOptions};
use super::DayZone;
use crate::model::{
    DailyModelUsageEntry, DailyUsageEntry, DailyUsageSeries, MetricKind, MetricLine, MetricValue, ModelUsageBreakdown,
    ModelUsageEntry, ModelUsageSeries, ModelUsageVariant, Timestamp,
};
use crate::time::days_from_civil;
use std::collections::{BTreeMap, BTreeSet};

pub(super) fn utc() -> DayZone {
    DayZone::utc()
}

/// Midday on a calendar date in `zone_seconds` east of UTC (Swift `day(y, m, d)` at hour 12).
pub(super) fn day_at(zone_seconds: i32, year: i64, month: u32, day: u32) -> Timestamp {
    (days_from_civil(year, month, day) * 86_400 + 12 * 3_600 - i64::from(zone_seconds)) as f64
}

pub(super) fn day(year: i64, month: u32, day: u32) -> Timestamp {
    day_at(0, year, month, day)
}

pub(super) fn entry(date: &str, tokens: i64, cost: Option<f64>) -> DailyUsageEntry {
    DailyUsageEntry::new(date, tokens, cost)
}

pub(super) fn model(name: &str, tokens: i64, cost: Option<f64>) -> ModelUsageEntry {
    ModelUsageEntry {
        model: name.to_string(),
        total_tokens: tokens,
        cost_usd: cost,
        variants: None,
        cost_is_complete: None,
        token_count_saturated: None,
    }
}

pub(super) fn variant(name: &str, tokens: i64, cost: Option<f64>) -> ModelUsageVariant {
    ModelUsageVariant {
        model: name.to_string(),
        total_tokens: tokens,
        cost_usd: cost,
        cost_is_complete: None,
        token_count_saturated: None,
    }
}

pub(super) fn model_day(date: &str, models: Vec<ModelUsageEntry>) -> DailyModelUsageEntry {
    DailyModelUsageEntry { date: date.to_string(), models }
}

pub(super) fn series(daily: Vec<DailyUsageEntry>) -> DailyUsageSeries {
    DailyUsageSeries { daily }
}

/// Swift `MetricValue(number:kind:label:estimated:isLowerBound:)`.
pub(super) fn value(number: f64, kind: MetricKind, label: Option<&str>, estimated: bool, lower_bound: bool) -> MetricValue {
    MetricValue {
        number,
        kind,
        label: label.map(str::to_string),
        currency_code: None,
        estimated,
        is_partial: None,
        token_count_saturated: None,
        is_lower_bound: lower_bound.then_some(true),
    }
}

pub(super) fn tokens(number: f64) -> MetricValue {
    value(number, MetricKind::Count, Some("tokens"), false, false)
}

pub(super) fn dollars(number: f64, estimated: bool, lower_bound: bool) -> MetricValue {
    value(number, MetricKind::Dollars, None, estimated, lower_bound)
}

pub(super) fn set(items: &[&str]) -> BTreeSet<String> {
    items.iter().map(|s| s.to_string()).collect()
}

pub(super) fn unknown_by_day(items: &[(&str, &[&str])]) -> BTreeMap<String, BTreeSet<String>> {
    items.iter().map(|(day, models)| (day.to_string(), set(models))).collect()
}

/// Swift `mappedLines`: the tiles for `daily` / `models` at `now` (default 2026-06-26 midday UTC).
pub(super) fn mapped_lines(
    daily: Vec<DailyUsageEntry>,
    models: Vec<DailyModelUsageEntry>,
    unknown: BTreeMap<String, BTreeSet<String>>,
    now: Option<Timestamp>,
) -> Vec<MetricLine> {
    let mut lines = Vec::new();
    let options = TokenUsageOptions {
        unknown_models_by_day: unknown,
        model_usage: (!models.is_empty()).then(|| ModelUsageSeries { daily: models }),
        model_source_note: Some("From test logs".to_string()),
        ..TokenUsageOptions::default()
    };
    append_token_usage_in(&series(daily), &mut lines, now.unwrap_or_else(|| day(2026, 6, 26)), &options, utc());
    lines
}

pub(super) fn line<'a>(lines: &'a [MetricLine], label: &str) -> Option<&'a MetricLine> {
    lines.iter().find(|l| l.label() == label)
}

pub(super) fn values(lines: &[MetricLine], label: &str) -> Option<Vec<MetricValue>> {
    match line(lines, label)? {
        MetricLine::Values { values, .. } => Some(values.clone()),
        _ => None,
    }
}

pub(super) fn model_breakdown(lines: &[MetricLine], label: &str) -> Option<ModelUsageBreakdown> {
    match line(lines, label)? {
        MetricLine::Values { model_breakdown, .. } => model_breakdown.clone(),
        _ => None,
    }
}

pub(super) fn model_names(breakdown: &ModelUsageBreakdown) -> Vec<&str> {
    breakdown.models.iter().map(|m| m.model.as_str()).collect()
}

pub(super) fn find<'a>(breakdown: &'a ModelUsageBreakdown, name: &str) -> Option<&'a ModelUsageEntry> {
    breakdown.models.iter().find(|m| m.model == name)
}
