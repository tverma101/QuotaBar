//! Normalization of Codex usage responses into meters (Swift `CodexUsageMapper`).

use super::auth::CodexAuthError;
use super::client::json_object;
use crate::http::Response;
use crate::model::{MetricLine, MetricKind, MetricValue};
use crate::parse;
use crate::providers::auth_retry::is_auth_failure;
use crate::time;
use serde_json::{Map, Value};

pub const SESSION_PERIOD_MS: i64 = 5 * 60 * 60 * 1000;
pub const WEEKLY_PERIOD_MS: i64 = parse::WEEK_MS;
/// Codex flex credits are worth 4¢ each; the credits line leads with the dollar value.
pub const CREDIT_USD_RATE: f64 = 0.04;
/// The furthest future instant accepted as a reset (a sanity bound for unit mix-ups).
pub const MAXIMUM_RESET_HORIZON: f64 = 100.0 * 365.0 * 24.0 * 60.0 * 60.0;
const MAXIMUM_PERIOD_MS: f64 = 366.0 * 24.0 * 60.0 * 60.0 * 1000.0;

#[derive(Clone, Debug, PartialEq)]
pub struct CodexMappedUsage {
    pub plan: Option<String>,
    pub lines: Vec<MetricLine>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CodexUsageError {
    RequestFailed(u16),
    InvalidResponse,
    ConnectionFailed,
}

impl CodexUsageError {
    /// Swift `ProviderUsageErrorText`.
    pub fn message(self) -> String {
        match self {
            CodexUsageError::RequestFailed(status) => format!("Usage request failed (HTTP {status}). Try again later."),
            CodexUsageError::InvalidResponse => "Usage response invalid. Try again later.".into(),
            CodexUsageError::ConnectionFailed => "Usage request failed. Check your connection.".into(),
        }
    }
}

/// What `map_usage_response` can fail with (Swift threw `CodexAuthError.tokenExpired` or
/// `CodexUsageError`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MapError {
    Auth(CodexAuthError),
    Usage(CodexUsageError),
}

fn number(value: Option<&Value>) -> Option<f64> {
    parse::number(value)
}

fn header_number(response: &Response, name: &str) -> Option<f64> {
    let value = response.header(name).map(|h| Value::String(h.to_string()));
    parse::number(value.as_ref())
}

pub fn map_usage_response(
    response: &Response,
    reset_credits: Option<&Response>,
    now: f64,
) -> Result<CodexMappedUsage, MapError> {
    if is_auth_failure(response) {
        return Err(MapError::Auth(CodexAuthError::TokenExpired));
    }
    if !response.is_success() {
        return Err(MapError::Usage(CodexUsageError::RequestFailed(response.status)));
    }
    let Some(body) = json_object(response) else { return Err(MapError::Usage(CodexUsageError::InvalidResponse)) };

    let mut lines = Vec::new();
    let rate_limit = body.get("rate_limit").and_then(Value::as_object);
    lines.extend(classified_window_lines(
        rate_limit,
        ("Session", "Weekly"),
        (
            header_number(response, "x-codex-primary-used-percent"),
            header_number(response, "x-codex-secondary-used-percent"),
        ),
        now,
    ));
    // Model-specific limits (Spark) ride in a separate `additional_rate_limits` array.
    lines.extend(spark_lines(&body, now));
    if let Some((count, expiries)) = read_reset_credits(&body, reset_credits, now) {
        lines.push(MetricLine::Values {
            label: "Rate Limit Resets".into(),
            values: vec![MetricValue::new(count as f64, MetricKind::Count).with_label("available")],
            color_hex: None,
            expiries_at: expiries,
            unknown_models: Vec::new(),
            model_breakdown: None,
        });
    }
    if let Some(remaining) = read_credits_remaining(response, &body) {
        lines.push(MetricLine::values("Credits", credit_values(remaining)));
    }
    Ok(CodexMappedUsage { plan: format_codex_plan(body.get("plan_type")), lines })
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum WindowKind {
    Session,
    Weekly,
}

struct WindowCandidate {
    window: Map<String, Value>,
    used_percent: Option<f64>,
    fallback_kind: WindowKind,
}

fn window_candidate(value: Option<&Value>, header_percent: Option<f64>, fallback_kind: WindowKind) -> Option<WindowCandidate> {
    let window = match value.and_then(Value::as_object) {
        Some(window) => window.clone(),
        None if header_percent.is_some() => Map::new(),
        None => return None,
    };
    Some(WindowCandidate { used_percent: number(window.get("used_percent")).or(header_percent), window, fallback_kind })
}

/// Codex normally returns the five-hour window as `primary_window` and the weekly one as
/// `secondary_window`, but can move a sole weekly limit into the primary slot. Classify by the
/// explicit duration when present; keep the slot mapping only as a fallback.
fn classified_window_lines(
    rate_limit: Option<&Map<String, Value>>,
    labels: (&str, &str),
    header_percents: (Option<f64>, Option<f64>),
    now: f64,
) -> Vec<MetricLine> {
    let candidates: Vec<WindowCandidate> = [
        window_candidate(rate_limit.and_then(|r| r.get("primary_window")), header_percents.0, WindowKind::Session),
        window_candidate(rate_limit.and_then(|r| r.get("secondary_window")), header_percents.1, WindowKind::Weekly),
    ]
    .into_iter()
    .flatten()
    .collect();
    [
        classified_window_line(WindowKind::Session, labels.0, &candidates, now),
        classified_window_line(WindowKind::Weekly, labels.1, &candidates, now),
    ]
    .into_iter()
    .flatten()
    .collect()
}

fn classified_window_line(kind: WindowKind, label: &str, candidates: &[WindowCandidate], now: f64) -> Option<MetricLine> {
    let exact = candidates.iter().find(|c| exact_kind(&c.window) == Some(kind));
    let fallback = candidates.iter().find(|c| exact_kind(&c.window).is_none() && c.fallback_kind == kind);
    let candidate = exact.or(fallback)?;
    let default_period_ms = if kind == WindowKind::Session { SESSION_PERIOD_MS } else { WEEKLY_PERIOD_MS };
    let used = candidate.used_percent?;
    let period_ms = read_period_ms(Some(&candidate.window)).unwrap_or(default_period_ms);
    Some(MetricLine::percent_progress(label, used, reset_date(Some(&candidate.window), now), Some(period_ms)))
}

fn exact_kind(window: &Map<String, Value>) -> Option<WindowKind> {
    match read_period_ms(Some(window))? {
        SESSION_PERIOD_MS => Some(WindowKind::Session),
        WEEKLY_PERIOD_MS => Some(WindowKind::Weekly),
        _ => None,
    }
}

/// Spark (and any future model-specific) limits from `additional_rate_limits`; a non-dictionary
/// element is skipped rather than discarding its valid siblings.
fn spark_lines(body: &Map<String, Value>, now: f64) -> Vec<MetricLine> {
    let Some(raw_entries) = body.get("additional_rate_limits").and_then(Value::as_array) else { return Vec::new() };
    let spark = raw_entries.iter().filter_map(Value::as_object).find(|entry| is_spark_entry(entry));
    let Some(rate_limit) = spark.and_then(|s| s.get("rate_limit")).and_then(Value::as_object) else { return Vec::new() };
    classified_window_lines(Some(rate_limit), ("Spark", "Spark Weekly"), (None, None), now)
}

fn is_spark_entry(entry: &Map<String, Value>) -> bool {
    ["limit_name", "metered_feature"]
        .iter()
        .filter_map(|key| entry.get(*key).and_then(Value::as_str))
        .any(|s| s.to_lowercase().contains("spark"))
}

fn reset_date(window: Option<&Map<String, Value>>, now: f64) -> Option<f64> {
    let window = window?;
    if let Some(reset_at) = number(window.get("reset_at")) {
        return (reset_at > now && reset_at - now <= MAXIMUM_RESET_HORIZON).then_some(reset_at);
    }
    if let Some(reset_after) = number(window.get("reset_after_seconds")) {
        return (reset_after > 0.0 && reset_after <= MAXIMUM_RESET_HORIZON).then_some(now + reset_after);
    }
    None
}

fn read_period_ms(window: Option<&Map<String, Value>>) -> Option<i64> {
    let seconds = number(window?.get("limit_window_seconds")).filter(|s| *s > 0.0)?;
    let milliseconds = seconds * 1000.0;
    // An implausible window falls back to the label's known cadence.
    (milliseconds.is_finite() && milliseconds <= MAXIMUM_PERIOD_MS).then(|| milliseconds.floor() as i64)
}

/// Swift `ProviderParse.intFromClampedDouble`.
fn int_from_clamped(value: f64, lower: i64, upper: i64) -> i64 {
    if value.is_nan() || value <= lower as f64 {
        return lower;
    }
    if value >= upper as f64 {
        return upper;
    }
    value.floor() as i64
}

/// Codex flex credits as raw values: the floored credit count (clamped to `0...1e9`) and its dollar
/// value (count × 4¢), e.g. "$32.84 · 821 credits".
pub fn credit_values(remaining: f64) -> Vec<MetricValue> {
    let credits = int_from_clamped(remaining.floor(), 0, 1_000_000_000);
    let usd = credits as f64 * CREDIT_USD_RATE;
    vec![MetricValue::new(usd, MetricKind::Dollars), MetricValue::new(credits as f64, MetricKind::Count).with_label("credits")]
}

/// On-demand reset credits: the floored available count plus each still-available credit's expiry
/// (soonest first). Prefers the dedicated endpoint (the only source with per-credit expiries) and
/// falls back to the usage body's embedded count.
pub fn read_reset_credits(
    body: &Map<String, Value>,
    reset_credits: Option<&Response>,
    now: f64,
) -> Option<(i64, Vec<f64>)> {
    let source = reset_credits_source(body, reset_credits)?;
    let count = number(source.get("available_count")).filter(|c| *c >= 0.0)?;
    Some((int_from_clamped(count.floor(), 0, 1_000_000), available_expiries(source.get("credits"), now)))
}

fn reset_credits_source(body: &Map<String, Value>, reset_credits: Option<&Response>) -> Option<Map<String, Value>> {
    if let Some(response) = reset_credits.filter(|r| r.is_success()) {
        if let Some(dedicated) = json_object(response) {
            if number(dedicated.get("available_count")).is_some() {
                return Some(dedicated);
            }
        }
    }
    body.get("rate_limit_reset_credits").and_then(Value::as_object).cloned()
}

/// A credit is kept when explicitly "available" or when it carries no status at all.
fn available_expiries(value: Option<&Value>, now: f64) -> Vec<f64> {
    // Swift `as? [[String: Any]]` fails the whole cast when any element is not an object.
    let Some(array) = value.and_then(Value::as_array) else { return Vec::new() };
    let Some(credits) = array.iter().map(Value::as_object).collect::<Option<Vec<_>>>() else { return Vec::new() };
    let mut expiries: Vec<f64> = credits
        .into_iter()
        .filter(|credit| match credit.get("status").and_then(Value::as_str) {
            Some(status) => status == "available",
            None => true,
        })
        .filter_map(|credit| parse_expiry(credit.get("expires_at"), now))
        .collect();
    expiries.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    expiries
}

fn parse_expiry(value: Option<&Value>, now: f64) -> Option<f64> {
    let parsed = match value {
        Some(Value::String(s)) => time::parse_iso8601(s),
        other => number(other),
    }?;
    (parsed > now && parsed - now <= MAXIMUM_RESET_HORIZON).then_some(parsed)
}

fn read_credits_remaining(response: &Response, body: &Map<String, Value>) -> Option<f64> {
    if let Some(credits) = body.get("credits").and_then(Value::as_object) {
        if let Some(balance) = number(credits.get("balance")) {
            return Some(balance);
        }
        if credits.get("has_credits").and_then(Value::as_bool) == Some(false) {
            return Some(0.0);
        }
    }
    header_number(response, "x-codex-credits-balance")
}

pub fn format_codex_plan(value: Option<&Value>) -> Option<String> {
    let raw = value?.as_str()?.trim();
    if raw.is_empty() {
        return None;
    }
    Some(match raw.to_lowercase().as_str() {
        "prolite" => "Pro 5x".into(),
        "pro" => "Pro 20x".into(),
        _ => title_cased(raw, |c| c == '_'),
    })
}

/// Swift `String.titleCased(separator:)`: split on the separator, upper-case each word's first
/// character, keep the tail, join with single spaces.
fn title_cased(text: &str, is_separator: impl Fn(char) -> bool) -> String {
    text.split(is_separator)
        .filter(|w| !w.is_empty())
        .map(|word| {
            let mut chars = word.chars();
            let head: String = chars.next().map(|c| c.to_uppercase().collect()).unwrap_or_default();
            head + chars.as_str()
        })
        .collect::<Vec<_>>()
        .join(" ")
}
