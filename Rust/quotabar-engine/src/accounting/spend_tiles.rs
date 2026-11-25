//! Turns local daily token/cost data into the shared Today / Yesterday / Last 30 Days spend tiles
//! (Swift `SpendTileMapper`). Every spend-tracking provider funnels through here so the tiles render
//! identically regardless of source: Claude / Codex / Grok feed token/cost from their CLI logs, Cursor
//! from its CSV export. The data shape ([`DailyUsageSeries`]) is a provider-neutral per-day carrier.

use super::day::{day_key_from_usage_date, format_day, DayZone, UsageHistoryWindow};
use super::spend_model::{model_breakdown, BreakdownRequest};
use super::{adding_saturating, format_count_row};
use crate::model::{
    DailyUsageEntry, DailyUsageSeries, MetricChartPoint, MetricKind, MetricLine, MetricValue, ModelUsageBreakdown,
    ModelUsageSeries, Timestamp,
};
use chrono::{Datelike, Days};
use std::collections::{BTreeMap, BTreeSet};

/// Optional inputs of [`append_token_usage`] (the Swift defaulted parameters).
#[derive(Clone, Debug)]
pub struct TokenUsageOptions {
    /// Flags imputed dollars on the emitted values when `estimated_cost_days` does not say otherwise.
    pub estimated: bool,
    /// Day key to model names no pricing source can price. Their tokens still count and any known
    /// priced subtotal remains visible beside the warning. Today / Yesterday pick up their own day's
    /// set; Last 30 Days carries the union across the window.
    pub unknown_models_by_day: BTreeMap<String, BTreeSet<String>>,
    pub model_usage: Option<ModelUsageSeries>,
    pub model_source_note: Option<String>,
    /// Days whose current totals can still grow (an active session).
    pub partial_days: BTreeSet<String>,
    /// Carried for call-site parity; the tiles never render it (the Usage History screen's "At Public
    /// API Rates" total consumes it).
    pub api_estimate_by_day: Option<BTreeMap<String, f64>>,
    pub estimated_cost_days: Option<BTreeSet<String>>,
}

impl Default for TokenUsageOptions {
    fn default() -> Self {
        TokenUsageOptions {
            estimated: true,
            unknown_models_by_day: BTreeMap::new(),
            model_usage: None,
            model_source_note: None,
            partial_days: BTreeSet::new(),
            api_estimate_by_day: None,
            estimated_cost_days: None,
        }
    }
}

/// [`append_token_usage_in`] in the user's local time zone.
pub fn append_token_usage(usage: &DailyUsageSeries, lines: &mut Vec<MetricLine>, now: Timestamp, options: &TokenUsageOptions) {
    append_token_usage_in(usage, lines, now, options, DayZone::Local);
}

/// Append the three spend tiles (Today / Yesterday / Last 30 Days). A period with no usage is left
/// unbacked so the tile reads "No data" — a zero here is indistinguishable from "the source hasn't
/// accounted for this day yet," and a confident `$0.00 · 0 tokens` contradicts a live session meter
/// that proves otherwise. "No data" is also what a tile shows when the source couldn't be read at all,
/// where the caller appends nothing.
pub fn append_token_usage_in(
    usage: &DailyUsageSeries,
    lines: &mut Vec<MetricLine>,
    now: Timestamp,
    options: &TokenUsageOptions,
    zone: DayZone,
) {
    let unknown = &options.unknown_models_by_day;
    let partial_days = &options.partial_days;
    let has_unknown = |day: &str| unknown.get(day).is_some_and(|set| !set.is_empty());

    let today = zone.day_key(now);
    let yesterday = zone.local_date(now).and_then(|d| d.checked_sub_days(Days::new(1))).map(format_day);
    let estimated_cost = |day: Option<&str>| match &options.estimated_cost_days {
        None => options.estimated,
        Some(days) => day.is_some_and(|d| days.contains(d)),
    };
    // Normalize each row's date once; every lookup below reads the same keys.
    let keyed: Vec<(Option<String>, &DailyUsageEntry)> =
        usage.daily.iter().map(|e| (day_key_from_usage_date(&e.date, zone), e)).collect();

    let unexplained_incomplete_days: BTreeSet<String> = keyed
        .iter()
        .filter_map(|(key, entry)| {
            let day = key.as_ref()?;
            let unexplained = entry.has_unexplained_incomplete_cost == Some(true)
                || (!entry.cost_is_complete
                    && entry.has_unexplained_incomplete_cost.is_none()
                    && !has_unknown(day)
                    && !partial_days.contains(day));
            unexplained.then(|| day.clone())
        })
        .collect();

    let day_line = |label: &str, entry: &DailyUsageEntry, day: &str| -> MetricLine {
        let cost = displayable_cost(entry, day, unknown, partial_days);
        let partial = partial_days.contains(day);
        let lower_bound = partial || has_known_partial_cost(entry, day, unknown);
        let days = BTreeSet::from([day.to_string()]);
        MetricLine::Values {
            label: label.to_string(),
            values: spend_values(entry.total_tokens, cost, estimated_cost(Some(day)), partial, lower_bound, entry.token_count_saturated),
            color_hex: None,
            expiries_at: Vec::new(),
            unknown_models: unknown.get(day).map(|s| s.iter().cloned().collect()).unwrap_or_default(),
            model_breakdown: breakdown(options, zone, &BreakdownInput {
                days: &days,
                total_tokens: entry.total_tokens,
                saturated: entry.token_count_saturated,
                cost,
                unexplained: &unexplained_incomplete_days,
            }),
        }
    };

    if let Some((_, entry)) = keyed.iter().find(|(key, _)| key.as_deref() == Some(today.as_str())) {
        if has_usage(entry) {
            lines.push(day_line("Today", entry, &today));
        }
    }
    if let Some(yesterday) = &yesterday {
        if let Some((_, entry)) = keyed.iter().find(|(key, _)| key.as_deref() == Some(yesterday.as_str())) {
            if has_usage(entry) {
                lines.push(day_line("Yesterday", entry, yesterday));
            }
        }
    }

    // The tile is labelled "Last 30 Days" and summed cross-provider, so the sum must cover exactly the
    // labeled window. Filter instead of trusting the input: a source that sweeps one day extra (or a
    // persisted series that outlived a window change) would otherwise be summed under the 30-day label.
    let window_keys = UsageHistoryWindow::day_keys(now, zone);
    let windowed: Vec<(&str, &DailyUsageEntry)> = keyed
        .iter()
        .filter_map(|(key, entry)| key.as_deref().filter(|k| window_keys.contains(*k)).map(|k| (k, *entry)))
        .collect();

    let mut total_tokens = 0i64;
    let mut total_tokens_saturated = false;
    for (_, entry) in &windowed {
        total_tokens_saturated = total_tokens_saturated || entry.token_count_saturated;
        if entry.total_tokens > 0 && total_tokens > i64::MAX - entry.total_tokens {
            total_tokens_saturated = true;
        }
        total_tokens = adding_saturating(total_tokens, entry.total_tokens);
    }
    let all_unknown: BTreeSet<&String> =
        unknown.iter().filter(|(day, _)| window_keys.contains(*day)).flat_map(|(_, models)| models.iter()).collect();
    // Keep the priced subtotal when incompleteness is explained by named unknown models. Other
    // incomplete accounting (for example, a provider-reported token mismatch) remains hidden until its
    // source can produce a trustworthy subtotal and a matching warning.
    let has_unexplained_incomplete_cost = windowed.iter().any(|(day, entry)| {
        !entry.cost_is_complete
            && (entry.has_unexplained_incomplete_cost == Some(true)
                || (entry.has_unexplained_incomplete_cost.is_none() && !has_unknown(day) && !partial_days.contains(*day)))
    });
    let cost_samples: Vec<f64> =
        windowed.iter().filter_map(|(day, entry)| displayable_cost(entry, day, unknown, partial_days)).collect();
    let mut finite_cost_total = 0.0f64;
    let mut finite_cost_total_overflowed = false;
    for sample in &cost_samples {
        let next = finite_cost_total + sample;
        if !next.is_finite() {
            finite_cost_total_overflowed = true;
            break;
        }
        finite_cost_total = next;
    }
    let total_cost = (!has_unexplained_incomplete_cost && !cost_samples.is_empty()).then_some(finite_cost_total);
    if total_tokens > 0 || total_cost.unwrap_or(0.0) > 0.0 {
        // The 30-day total is incomplete whenever ANY day in the window is partial — a running session
        // keeps growing, so the sum is real but not final.
        let window_partial = windowed.iter().any(|(day, _)| partial_days.contains(*day));
        let cost_is_lower_bound = finite_cost_total_overflowed
            || window_partial
            || windowed.iter().any(|(day, entry)| {
                !entry.cost_is_complete && (entry.has_unexplained_incomplete_cost == Some(false) || has_unknown(day))
            });
        let window_estimated = match &options.estimated_cost_days {
            Some(days) => windowed.iter().any(|(day, _)| days.contains(*day)),
            None => options.estimated,
        };
        let window_days: BTreeSet<String> = windowed.iter().map(|(day, _)| day.to_string()).collect();
        lines.push(MetricLine::Values {
            label: "Last 30 Days".to_string(),
            values: spend_values(
                total_tokens,
                total_cost,
                window_estimated,
                window_partial,
                cost_is_lower_bound,
                total_tokens_saturated,
            ),
            color_hex: None,
            expiries_at: Vec::new(),
            unknown_models: all_unknown.into_iter().cloned().collect(),
            model_breakdown: breakdown(options, zone, &BreakdownInput {
                days: &window_days,
                total_tokens,
                saturated: total_tokens_saturated,
                cost: total_cost,
                unexplained: &unexplained_incomplete_days,
            }),
        });
    }
    // The All-At-API-Rates figure is intentionally NOT a dashboard row; the plan-versus-API comparison
    // lives only on the Usage History screen's total line, computed from the same `api_estimate_by_day`.
}

struct BreakdownInput<'a> {
    days: &'a BTreeSet<String>,
    total_tokens: i64,
    saturated: bool,
    cost: Option<f64>,
    unexplained: &'a BTreeSet<String>,
}

fn breakdown(options: &TokenUsageOptions, zone: DayZone, input: &BreakdownInput<'_>) -> Option<ModelUsageBreakdown> {
    model_breakdown(
        options.model_usage.as_ref(),
        &BreakdownRequest {
            days: input.days,
            total_tokens: input.total_tokens,
            token_count_saturated: input.saturated,
            total_cost_usd: input.cost,
            source_note: options.model_source_note.as_deref(),
            unexplained_incomplete_days: input.unexplained,
            zone,
        },
    )
}

/// A period with any real usage: tokens used, dollars priced, or both. A zero-token, zero-cost day is
/// idle and gets no tile ("No data"), not a fabricated `$0.00 · 0 tokens`.
fn has_usage(entry: &DailyUsageEntry) -> bool {
    entry.total_tokens > 0 || entry.cost_usd.unwrap_or(0.0) > 0.0
}

/// [`append_usage_trend_in`] in the user's local time zone.
pub fn append_usage_trend(
    usage: &DailyUsageSeries,
    lines: &mut Vec<MetricLine>,
    now: Timestamp,
    note: &str,
    partial_days: &BTreeSet<String>,
    partial_note: Option<&str>,
) {
    append_usage_trend_in(usage, lines, now, note, partial_days, partial_note, DayZone::Local);
}

/// Append the Usage Trend chart line: one bar per calendar day over the window, value = tokens used
/// that day. Tokens are always measured (no estimate flag). Appends nothing when the whole window is
/// idle, so a source with no usage leaves "No data" rather than a flat row of zero bars.
pub fn append_usage_trend_in(
    usage: &DailyUsageSeries,
    lines: &mut Vec<MetricLine>,
    now: Timestamp,
    note: &str,
    partial_days: &BTreeSet<String>,
    partial_note: Option<&str>,
    zone: DayZone,
) {
    let points = trend_points(usage, now, zone);
    if points.is_empty() {
        return;
    }
    let mut trend_note = note.to_string();
    if !partial_days.is_empty() {
        // Some providers have an explicit partial-day cause such as an active session or a skipped
        // oversized source record; retain the established Hermes copy by default.
        trend_note.push_str(" · ");
        trend_note.push_str(partial_note.unwrap_or("days with an active Hermes session are partial until it ends"));
    }
    lines.push(MetricLine::Chart { label: "Usage Trend".to_string(), points, note: Some(trend_note) });
}

const MONTH_ABBREVIATIONS: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/// The compact month/day axis label, e.g. "Jun 21" (en-US).
pub fn month_day_label(date: chrono::NaiveDate) -> String {
    format!("{} {}", MONTH_ABBREVIATIONS[date.month0() as usize], date.day())
}

/// Per-day token points across the queried window (today + the previous 29 days), oldest first.
/// Tokens are summed per calendar day, so two source rows that normalize to the same date become one
/// bar carrying their total. Idle days are zero-filled, not dropped, so the sparkline stays
/// calendar-true. Returns empty when nothing was used in the window — there's no trend to draw. Each
/// point carries a "Jun 21" axis label and a pre-formatted "222M tokens" readout.
fn trend_points(usage: &DailyUsageSeries, now: Timestamp, zone: DayZone) -> Vec<MetricChartPoint> {
    let mut tokens_by_day: BTreeMap<String, i64> = BTreeMap::new();
    let mut saturated_days: BTreeSet<String> = BTreeSet::new();
    for day in &usage.daily {
        let Some(key) = (day.total_tokens >= 0).then(|| day_key_from_usage_date(&day.date, zone)).flatten() else {
            continue;
        };
        let previous = tokens_by_day.get(&key).copied().unwrap_or(0);
        if day.total_tokens > 0 && previous > i64::MAX - day.total_tokens {
            saturated_days.insert(key.clone());
        }
        tokens_by_day.insert(key.clone(), adding_saturating(previous, day.total_tokens));
        if day.token_count_saturated {
            saturated_days.insert(key);
        }
    }
    if !tokens_by_day.values().any(|&t| t > 0) {
        return Vec::new();
    }

    let Some(today) = zone.local_date(now) else { return Vec::new() };
    (0..UsageHistoryWindow::TOTAL_DAYS as u64)
        .rev()
        .filter_map(|offset| today.checked_sub_days(Days::new(offset)))
        .map(|date| {
            let key = format_day(date);
            let tokens = tokens_by_day.get(&key).copied().unwrap_or(0);
            let lower_bound = saturated_days.contains(&key);
            let text = format_count_row(tokens as f64);
            MetricChartPoint {
                value: tokens as f64,
                label: month_day_label(date),
                value_label: Some(format!("{}{text} tokens", if lower_bound { "≥" } else { "" })),
            }
        })
        .collect()
}

fn displayable_cost(
    entry: &DailyUsageEntry,
    day: &str,
    unknown: &BTreeMap<String, BTreeSet<String>>,
    partial_days: &BTreeSet<String>,
) -> Option<f64> {
    let cost = entry.cost_usd.filter(|c| c.is_finite() && *c >= 0.0)?;
    let has_unknown = unknown.get(day).is_some_and(|set| !set.is_empty());
    (entry.cost_is_complete
        || entry.has_unexplained_incomplete_cost == Some(false)
        || partial_days.contains(day)
        || (entry.has_unexplained_incomplete_cost != Some(true) && has_unknown))
        .then_some(cost)
}

fn has_known_partial_cost(entry: &DailyUsageEntry, day: &str, unknown: &BTreeMap<String, BTreeSet<String>>) -> bool {
    if entry.cost_is_complete || entry.has_unexplained_incomplete_cost == Some(true) {
        return false;
    }
    entry.has_unexplained_incomplete_cost == Some(false) || unknown.get(day).is_some_and(|set| !set.is_empty())
}

/// One period's spend as raw values: the estimated dollars followed by the measured token count,
/// rendered combined as "$4.08 · 1.2M tokens". The token value carries the "tokens" unit.
///
/// Only called for a period with real usage. `estimated` flags locally calculated dollars on the value
/// itself; token counts are always measured. `tokens_estimated` marks the period PARTIAL (a session is
/// still running, so the recorded total is real but not final).
fn spend_values(
    tokens: i64,
    cost_usd: Option<f64>,
    estimated: bool,
    tokens_estimated: bool,
    cost_is_lower_bound: bool,
    token_count_saturated: bool,
) -> Vec<MetricValue> {
    let mut values = Vec::with_capacity(2);
    if let Some(cost) = cost_usd {
        values.push(MetricValue {
            number: cost,
            kind: MetricKind::Dollars,
            label: None,
            currency_code: None,
            estimated: estimated || tokens_estimated,
            is_partial: tokens_estimated.then_some(true),
            token_count_saturated: None,
            is_lower_bound: cost_is_lower_bound.then_some(true),
        });
    }
    values.push(MetricValue {
        number: tokens as f64,
        kind: MetricKind::Count,
        label: Some("tokens".to_string()),
        currency_code: None,
        estimated: tokens_estimated,
        is_partial: tokens_estimated.then_some(true),
        token_count_saturated: token_count_saturated.then_some(true),
        is_lower_bound: None,
    });
    values
}
