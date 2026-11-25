//! Codex usage response mapping (Swift `CodexUsageMapper`).

use crate::http::Response;
use crate::model::{MetricKind, MetricLine, MetricValue, ProgressFormat, Timestamp};
use crate::parse;
use crate::providers::error_text;
use chrono::{DateTime, Utc};
use serde_json::Value;
use std::collections::BTreeSet;

pub const SESSION_MS: i64 = 5 * 60 * 60 * 1000;
pub const WEEK_MS: i64 = parse::WEEK_MS;
pub const CREDIT_USD_RATE: f64 = 0.04;
pub const MAXIMUM_RESET_HORIZON: f64 = 100.0 * 365.0 * 24.0 * 60.0 * 60.0;
const MAXIMUM_PERIOD_MS: f64 = 366.0 * 24.0 * 60.0 * 60.0 * 1000.0;

#[derive(Clone, Debug, Default, PartialEq)]
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
    pub fn message(self) -> String {
        match self {
            CodexUsageError::RequestFailed(status) => error_text::request_failed(status),
            CodexUsageError::InvalidResponse => error_text::INVALID_RESPONSE.to_string(),
            CodexUsageError::ConnectionFailed => error_text::CONNECTION_FAILED.to_string(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum WindowKind {
    Session,
    Weekly,
}

#[derive(Clone, Debug)]
struct WindowCandidate {
    window: serde_json::Map<String, Value>,
    used_percent: Option<f64>,
    fallback_kind: WindowKind,
}

pub fn map_usage_response(
    response: &Response,
    reset_credits: Option<&Response>,
    now: Timestamp,
) -> Result<CodexMappedUsage, CodexUsageError> {
    if response.status == 401 || response.status == 403 {
        return Err(CodexUsageError::InvalidResponse);
    }
    if !response.is_success() {
        return Err(CodexUsageError::RequestFailed(response.status));
    }
    let body: Value =
        serde_json::from_slice(&response.body).map_err(|_| CodexUsageError::InvalidResponse)?;
    let Some(body) = body.as_object() else {
        return Err(CodexUsageError::InvalidResponse);
    };
    let mut lines = Vec::new();
    if let Some(rate_limit) = body.get("rate_limit").and_then(Value::as_object) {
        lines.extend(classified_window_lines(
            rate_limit,
            ("Session", "Weekly"),
            (
                parse::number(
                    response
                        .header("x-codex-primary-used-percent")
                        .map(|v| Value::String(v.into()))
                        .as_ref(),
                ),
                parse::number(
                    response
                        .header("x-codex-secondary-used-percent")
                        .map(|v| Value::String(v.into()))
                        .as_ref(),
                ),
            ),
            now,
        ));
    }
    lines.extend(spark_lines(body, now));

    if let Some((count, expiries)) = read_reset_credits(body, reset_credits, now) {
        lines.push(MetricLine::Values {
            label: "Rate Limit Resets".into(),
            values: vec![MetricValue::new(count as f64, MetricKind::Count).with_label("available")],
            color_hex: None,
            expiries_at: expiries,
            unknown_models: Vec::new(),
            model_breakdown: None,
        });
    }

    if let Some(remaining) = read_credits_remaining(response, body) {
        lines.push(MetricLine::Values {
            label: "Credits".into(),
            values: credit_values(remaining),
            color_hex: None,
            expiries_at: Vec::new(),
            unknown_models: Vec::new(),
            model_breakdown: None,
        });
    }

    Ok(CodexMappedUsage {
        plan: format_codex_plan(body.get("plan_type")),
        lines,
    })
}

fn classified_window_lines(
    rate_limit: &serde_json::Map<String, Value>,
    labels: (&str, &str),
    header_percents: (Option<f64>, Option<f64>),
    now: Timestamp,
) -> Vec<MetricLine> {
    let candidates: Vec<WindowCandidate> = [
        window_candidate(
            rate_limit.get("primary_window"),
            header_percents.0,
            WindowKind::Session,
        ),
        window_candidate(
            rate_limit.get("secondary_window"),
            header_percents.1,
            WindowKind::Weekly,
        ),
    ]
    .into_iter()
    .flatten()
    .collect();
    [WindowKind::Session, WindowKind::Weekly]
        .into_iter()
        .filter_map(|kind| {
            let label = if kind == WindowKind::Session {
                labels.0
            } else {
                labels.1
            };
            classified_window_line(kind, label, &candidates, now)
        })
        .collect()
}

fn window_candidate(
    value: Option<&Value>,
    header_percent: Option<f64>,
    fallback_kind: WindowKind,
) -> Option<WindowCandidate> {
    let window = match value {
        Some(Value::Object(object)) => object.clone(),
        _ if header_percent.is_some() => serde_json::Map::new(),
        _ => return None,
    };
    Some(WindowCandidate {
        used_percent: parse::number(window.get("used_percent")).or(header_percent),
        window,
        fallback_kind,
    })
}

fn classified_window_line(
    kind: WindowKind,
    label: &str,
    candidates: &[WindowCandidate],
    now: Timestamp,
) -> Option<MetricLine> {
    let exact = candidates
        .iter()
        .find(|c| exact_kind(&c.window) == Some(kind));
    let fallback = candidates
        .iter()
        .find(|c| exact_kind(&c.window).is_none() && c.fallback_kind == kind);
    let candidate = exact.or(fallback)?;
    let used = candidate.used_percent?;
    let default_period = if kind == WindowKind::Session {
        SESSION_MS
    } else {
        WEEK_MS
    };
    Some(MetricLine::Progress {
        label: label.into(),
        used,
        limit: 100.0,
        format: ProgressFormat::Percent,
        resets_at: reset_date(&candidate.window, now),
        period_duration_ms: Some(read_period_ms(&candidate.window).unwrap_or(default_period)),
        color_hex: None,
        detail: None,
    })
}

fn exact_kind(window: &serde_json::Map<String, Value>) -> Option<WindowKind> {
    match read_period_ms(window) {
        Some(SESSION_MS) => Some(WindowKind::Session),
        Some(WEEK_MS) => Some(WindowKind::Weekly),
        _ => None,
    }
}

fn spark_lines(body: &serde_json::Map<String, Value>, now: Timestamp) -> Vec<MetricLine> {
    let Some(entries) = body.get("additional_rate_limits").and_then(Value::as_array) else {
        return Vec::new();
    };
    let Some(spark) = entries.iter().filter_map(Value::as_object).find(|entry| {
        ["limit_name", "metered_feature"]
            .into_iter()
            .filter_map(|key| entry.get(key).and_then(Value::as_str))
            .any(|value| value.to_lowercase().contains("spark"))
    }) else {
        return Vec::new();
    };
    let Some(rate_limit) = spark.get("rate_limit").and_then(Value::as_object) else {
        return Vec::new();
    };
    classified_window_lines(rate_limit, ("Spark", "Spark Weekly"), (None, None), now)
}

fn reset_date(window: &serde_json::Map<String, Value>, now: Timestamp) -> Option<Timestamp> {
    if let Some(reset_at) = parse::number(window.get("reset_at")) {
        if reset_at > now && reset_at - now <= MAXIMUM_RESET_HORIZON {
            return Some(reset_at);
        }
        return None;
    }
    if let Some(reset_after) = parse::number(window.get("reset_after_seconds")) {
        if reset_after > 0.0 && reset_after <= MAXIMUM_RESET_HORIZON {
            return Some(now + reset_after);
        }
    }
    None
}

fn read_period_ms(window: &serde_json::Map<String, Value>) -> Option<i64> {
    let seconds = parse::number(window.get("limit_window_seconds"))?;
    if seconds <= 0.0 {
        return None;
    }
    let milliseconds = seconds * 1000.0;
    if !milliseconds.is_finite() || milliseconds > MAXIMUM_PERIOD_MS {
        return None;
    }
    Some(milliseconds.floor() as i64)
}

pub fn credit_values(remaining: f64) -> Vec<MetricValue> {
    let credits = remaining.floor().clamp(0.0, 1_000_000_000.0) as i64;
    vec![
        MetricValue::new(credits as f64 * CREDIT_USD_RATE, MetricKind::Dollars),
        MetricValue::new(credits as f64, MetricKind::Count).with_label("credits"),
    ]
}

pub fn read_reset_credits(
    body: &serde_json::Map<String, Value>,
    reset_credits: Option<&Response>,
    now: Timestamp,
) -> Option<(i64, Vec<Timestamp>)> {
    let dedicated = reset_credits.and_then(|response| {
        if response.is_success() {
            response.json().and_then(|value| {
                let object = value.as_object()?.clone();
                parse::number(object.get("available_count"))?;
                Some(object)
            })
        } else {
            None
        }
    });
    let source = dedicated.as_ref().or_else(|| {
        body.get("rate_limit_reset_credits")
            .and_then(Value::as_object)
    })?;
    let count = parse::number(source.get("available_count"))?;
    if count < 0.0 {
        return None;
    }
    Some((
        count.floor().clamp(0.0, 1_000_000.0) as i64,
        available_expiries(source.get("credits"), now),
    ))
}

fn available_expiries(value: Option<&Value>, now: Timestamp) -> Vec<Timestamp> {
    let Some(credits) = value.and_then(Value::as_array) else {
        return Vec::new();
    };
    let mut expiries: Vec<Timestamp> = credits
        .iter()
        .filter_map(Value::as_object)
        .filter(|credit| {
            credit
                .get("status")
                .and_then(Value::as_str)
                .map_or(true, |status| status == "available")
        })
        .filter_map(|credit| parse_expiry(credit.get("expires_at"), now))
        .collect();
    expiries.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    expiries
}

fn parse_expiry(value: Option<&Value>, now: Timestamp) -> Option<Timestamp> {
    let parsed = match value? {
        Value::String(text) => parse_iso8601(text),
        other => parse::number(Some(other)),
    }?;
    (parsed > now && parsed - now <= MAXIMUM_RESET_HORIZON).then_some(parsed)
}

pub fn parse_iso8601(text: &str) -> Option<Timestamp> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return None;
    }
    DateTime::parse_from_rfc3339(trimmed)
        .ok()
        .map(|date| date.with_timezone(&Utc).timestamp_millis() as f64 / 1000.0)
        .or_else(|| {
            chrono::NaiveDateTime::parse_from_str(trimmed, "%Y-%m-%dT%H:%M:%S%.f")
                .ok()
                .map(|date| date.and_utc().timestamp_millis() as f64 / 1000.0)
        })
}

fn read_credits_remaining(
    response: &Response,
    body: &serde_json::Map<String, Value>,
) -> Option<f64> {
    if let Some(credits) = body.get("credits").and_then(Value::as_object) {
        if let Some(balance) = parse::number(credits.get("balance")) {
            return Some(balance);
        }
        if credits.get("has_credits").and_then(Value::as_bool) == Some(false) {
            return Some(0.0);
        }
    }
    parse::number(
        response
            .header("x-codex-credits-balance")
            .map(|v| Value::String(v.into()))
            .as_ref(),
    )
}

pub fn format_codex_plan(value: Option<&Value>) -> Option<String> {
    let raw = value?.as_str()?.trim();
    if raw.is_empty() {
        return None;
    }
    match raw.to_lowercase().as_str() {
        "prolite" => Some("Pro 5x".into()),
        "pro" => Some("Pro 20x".into()),
        _ => Some(
            raw.split('_')
                .map(|word| {
                    let mut chars = word.chars();
                    match chars.next() {
                        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
                        None => String::new(),
                    }
                })
                .collect::<Vec<_>>()
                .join(" "),
        ),
    }
}

/// The set of day keys covered by unmeasured router events is carried by the provider, not the
/// mapper; kept as a helper so tests can assert the row shape stays fully qualified.
pub fn _expiry_set(expiries: &[Timestamp]) -> BTreeSet<u64> {
    expiries.iter().map(|v| v.to_bits()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn response(status: u16, body: Value) -> Response {
        Response {
            status,
            headers: Vec::new(),
            body: serde_json::to_vec(&body).unwrap(),
        }
    }

    #[test]
    fn maps_windows_credits_resets_and_plan() {
        let body = json!({
            "plan_type": "pro",
            "rate_limit": {
                "primary_window": {"used_percent": 22, "limit_window_seconds": 18000, "reset_after_seconds": 60},
                "secondary_window": {"used_percent": 44, "limit_window_seconds": 604800}
            },
            "credits": {"balance": 10.9},
            "rate_limit_reset_credits": {
                "available_count": 2,
                "credits": [
                    {"status": "available", "expires_at": "2099-01-01T00:00:00Z"},
                    {"status": "consumed", "expires_at": "2099-01-02T00:00:00Z"},
                    {"expires_at": 4_000_000_000i64}
                ]
            }
        });
        let mapped = map_usage_response(&response(200, body), None, 1_800_000_000.0).unwrap();
        assert_eq!(mapped.plan.as_deref(), Some("Pro 20x"));
        let labels: Vec<&str> = mapped.lines.iter().map(MetricLine::label).collect();
        assert_eq!(
            labels,
            vec!["Session", "Weekly", "Rate Limit Resets", "Credits"]
        );
        assert!(
            matches!(&mapped.lines[2], MetricLine::Values { expiries_at, values, .. }
            if expiries_at.len() == 2 && values[0].number == 2.0)
        );
        assert!(matches!(&mapped.lines[3], MetricLine::Values { values, .. }
            if values[0].number == 0.4 && values[1].number == 10.0));
    }

    #[test]
    fn classifies_a_sole_weekly_limit_in_the_primary_slot() {
        let body = json!({
            "rate_limit": {"primary_window": {"used_percent": 70, "limit_window_seconds": 604800}}
        });
        let mapped = map_usage_response(&response(200, body), None, 1_800_000_000.0).unwrap();
        assert_eq!(mapped.lines.len(), 1);
        assert!(
            matches!(&mapped.lines[0], MetricLine::Progress { label, used, period_duration_ms, .. }
            if label == "Weekly" && *used == 70.0 && *period_duration_ms == Some(WEEK_MS))
        );
    }

    #[test]
    fn spark_limits_are_named_rows() {
        let body = json!({
            "additional_rate_limits": [{
                "limit_name": "GPT-5.3-Codex-Spark",
                "rate_limit": {
                    "primary_window": {"used_percent": 12, "limit_window_seconds": 18000},
                    "secondary_window": {"used_percent": 34, "limit_window_seconds": 604800}
                }
            }]
        });
        let mapped = map_usage_response(&response(200, body), None, 1_800_000_000.0).unwrap();
        let labels: Vec<&str> = mapped.lines.iter().map(MetricLine::label).collect();
        assert_eq!(labels, vec!["Spark", "Spark Weekly"]);
    }

    #[test]
    fn malformed_resets_and_credits_degrade_safely() {
        let body = json!({"credits": {"has_credits": false}, "rate_limit_reset_credits": {"available_count": -1}});
        let mapped = map_usage_response(&response(200, body), None, 1_800_000_000.0).unwrap();
        assert_eq!(mapped.lines.len(), 1);
        assert!(
            matches!(&mapped.lines[0], MetricLine::Values { values, .. } if values[0].number == 0.0)
        );
    }

    #[test]
    fn http_failures_map_to_usage_errors() {
        assert_eq!(
            map_usage_response(
                &Response {
                    status: 429,
                    headers: vec![],
                    body: vec![]
                },
                None,
                0.0
            ),
            Err(CodexUsageError::RequestFailed(429))
        );
    }
}
