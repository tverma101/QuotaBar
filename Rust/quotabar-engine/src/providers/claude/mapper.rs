//! Claude usage response mapping (Swift `ClaudeUsageMapper`).

use crate::model::{MetricKind, MetricLine, MetricValue, ProgressFormat, Timestamp};
use crate::parse;
use crate::providers::claude::auth::ClaudeOAuth;
use crate::providers::error_text;
use chrono::{DateTime, Utc};
use serde_json::Value;

pub const SESSION_MS: i64 = 5 * 60 * 60 * 1000;
pub const WEEK_MS: i64 = parse::WEEK_MS;
pub const MAXIMUM_RETRY_AFTER_SECS: i64 = 24 * 60 * 60;
pub const MAXIMUM_RESET_HORIZON: f64 = 100.0 * 365.0 * 24.0 * 60.0 * 60.0;

pub const MISSING_PROFILE_SCOPE_WARNING: &str =
    "Re-login for live usage. Run `claude` and sign in again to restore session and weekly limits.";

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ClaudeMappedUsage {
    pub plan: Option<String>,
    pub lines: Vec<MetricLine>,
    pub warning: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClaudeUsageError {
    ConnectionFailed,
    InvalidResponse,
    RequestFailed(u16),
}

impl ClaudeUsageError {
    pub fn message(self) -> String {
        match self {
            ClaudeUsageError::ConnectionFailed => error_text::CONNECTION_FAILED.to_string(),
            ClaudeUsageError::InvalidResponse => error_text::INVALID_RESPONSE.to_string(),
            ClaudeUsageError::RequestFailed(status) => error_text::request_failed(status),
        }
    }
}

pub fn format_plan(
    subscription_type: Option<&str>,
    rate_limit_tier: Option<&str>,
) -> Option<String> {
    let raw = subscription_type?.trim();
    if raw.is_empty() {
        return None;
    }
    let base = raw
        .split_whitespace()
        .map(|word| {
            let mut chars = word.chars();
            match chars.next() {
                Some(first) => {
                    first.to_uppercase().collect::<String>() + &chars.as_str().to_lowercase()
                }
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ");
    let tier = rate_limit_tier?;
    let start = tier.find(|c: char| c.is_ascii_digit())?;
    let digits: String = tier[start..]
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .collect();
    if digits.is_empty() || !tier[start + digits.len()..].starts_with('x') {
        return Some(base);
    }
    Some(format!("{base} {digits}x"))
}

fn reset_date(value: Option<&Value>, now: Timestamp) -> Option<Timestamp> {
    let parsed = match value {
        Some(Value::String(text)) => parse_iso8601(text.trim()),
        Some(other) => parse::number(Some(other)).map(|number| {
            let milliseconds = if number.abs() < 1e10 {
                number * 1000.0
            } else {
                number
            };
            milliseconds / 1000.0
        }),
        None => None,
    }?;
    if parsed <= now || parsed - now > MAXIMUM_RESET_HORIZON {
        return None;
    }
    Some(parsed)
}

fn parse_iso8601(text: &str) -> Option<Timestamp> {
    if text.is_empty() {
        return None;
    }
    DateTime::parse_from_rfc3339(text)
        .ok()
        .map(|date| date.with_timezone(&Utc).timestamp_millis() as f64 / 1000.0)
        .or_else(|| {
            // Some payloads omit the timezone; treat a bare ISO timestamp as UTC.
            chrono::NaiveDateTime::parse_from_str(text, "%Y-%m-%dT%H:%M:%S%.f")
                .ok()
                .map(|date| date.and_utc().timestamp_millis() as f64 / 1000.0)
        })
}

fn append_usage_window(
    lines: &mut Vec<MetricLine>,
    value: Option<&Value>,
    label: &str,
    period_ms: i64,
    now: Timestamp,
) {
    let Some(object) = value.and_then(Value::as_object) else {
        return;
    };
    let Some(used) = parse::number(object.get("utilization")) else {
        return;
    };
    lines.push(MetricLine::Progress {
        label: label.into(),
        used,
        limit: 100.0,
        format: ProgressFormat::Percent,
        resets_at: reset_date(object.get("resets_at"), now),
        period_duration_ms: Some(period_ms),
        color_hex: None,
        detail: None,
    });
}

fn append_scoped_weekly_limit(
    lines: &mut Vec<MetricLine>,
    limits: Option<&Value>,
    model_name: &str,
    label: &str,
    now: Timestamp,
) {
    let Some(array) = limits.and_then(Value::as_array) else {
        return;
    };
    for entry in array {
        let Some(object) = entry.as_object() else {
            continue;
        };
        if object.get("kind").and_then(Value::as_str) != Some("weekly_scoped") {
            continue;
        }
        let Some(model) = object
            .get("scope")
            .and_then(Value::as_object)
            .and_then(|scope| scope.get("model"))
            .and_then(Value::as_object)
        else {
            continue;
        };
        if model.get("display_name").and_then(Value::as_str) != Some(model_name) {
            continue;
        }
        let Some(used) = parse::number(object.get("percent")) else {
            continue;
        };
        lines.push(MetricLine::Progress {
            label: label.into(),
            used,
            limit: 100.0,
            format: ProgressFormat::Percent,
            resets_at: reset_date(object.get("resets_at"), now),
            period_duration_ms: Some(WEEK_MS),
            color_hex: None,
            detail: None,
        });
        return;
    }
}

fn append_extra_usage(
    lines: &mut Vec<MetricLine>,
    value: Option<&Value>,
) -> Result<(), ClaudeUsageError> {
    let Some(object) = value.and_then(Value::as_object) else {
        return Ok(());
    };
    if object.get("is_enabled").and_then(Value::as_bool) != Some(true) {
        return Ok(());
    }
    let Some(used_minor) = parse::number(object.get("used_credits")) else {
        return Ok(());
    };
    let code = match object.get("currency") {
        None | Some(Value::Null) => "USD".to_string(),
        Some(Value::String(text)) => {
            let normalized = text.to_uppercase();
            if normalized.len() != 3 || !normalized.bytes().all(|b| b.is_ascii_uppercase()) {
                return Err(ClaudeUsageError::InvalidResponse);
            }
            normalized
        }
        _ => return Err(ClaudeUsageError::InvalidResponse),
    };
    let decimals = match object.get("decimal_places") {
        None | Some(Value::Null) => 2.0,
        Some(other) => {
            let value = parse::number(Some(other)).ok_or(ClaudeUsageError::InvalidResponse)?;
            if !(0.0..=6.0).contains(&value) || value.round() != value {
                return Err(ClaudeUsageError::InvalidResponse);
            }
            value
        }
    };
    let scale = 10f64.powf(decimals);
    let used = used_minor / scale;
    let currency_code = (code != "USD").then(|| code.clone());
    if let Some(limit_minor) = parse::number(object.get("monthly_limit")).filter(|v| *v > 0.0) {
        lines.push(MetricLine::Progress {
            label: "Extra usage spent".into(),
            used,
            limit: limit_minor / scale,
            format: match currency_code {
                Some(code) => ProgressFormat::Currency(code),
                None => ProgressFormat::Dollars,
            },
            resets_at: None,
            period_duration_ms: None,
            color_hex: None,
            detail: None,
        });
    } else if used > 0.0 {
        let mut value = MetricValue::new(used, MetricKind::Dollars);
        value.currency_code = currency_code;
        lines.push(MetricLine::Values {
            label: "Extra usage spent".into(),
            values: vec![value],
            color_hex: None,
            expiries_at: Vec::new(),
            unknown_models: Vec::new(),
            model_breakdown: None,
        });
    }
    Ok(())
}

pub fn map_usage_response(
    status: u16,
    body: &[u8],
    credentials: &ClaudeOAuth,
    now: Timestamp,
) -> Result<ClaudeMappedUsage, ClaudeUsageError> {
    if status == 401 || status == 403 {
        return Err(ClaudeUsageError::InvalidResponse);
    }
    if !(200..300).contains(&status) {
        return Err(ClaudeUsageError::RequestFailed(status));
    }
    let root: Value =
        serde_json::from_slice(body).map_err(|_| ClaudeUsageError::InvalidResponse)?;
    let Some(object) = root.as_object() else {
        return Err(ClaudeUsageError::InvalidResponse);
    };
    let mut lines = Vec::new();
    append_usage_window(
        &mut lines,
        object.get("five_hour"),
        "Session",
        SESSION_MS,
        now,
    );
    append_usage_window(&mut lines, object.get("seven_day"), "Weekly", WEEK_MS, now);
    append_usage_window(
        &mut lines,
        object.get("seven_day_sonnet"),
        "Sonnet",
        WEEK_MS,
        now,
    );
    append_scoped_weekly_limit(&mut lines, object.get("limits"), "Fable", "Fable", now);
    append_extra_usage(&mut lines, object.get("extra_usage"))?;
    Ok(ClaudeMappedUsage {
        plan: format_plan(
            credentials.subscription_type.as_deref(),
            credentials.rate_limit_tier.as_deref(),
        ),
        lines,
        warning: None,
    })
}

pub fn rate_limited_usage(
    credentials: &ClaudeOAuth,
    retry_after_seconds: Option<i64>,
) -> ClaudeMappedUsage {
    let retry_text = retry_after_seconds.map(format_rate_limit_minutes);
    let wait_text = retry_text
        .map(|text| format!("Rate limited, retry in ~{text}"))
        .unwrap_or_else(|| "Rate limited, try again later".into());
    ClaudeMappedUsage {
        plan: format_plan(
            credentials.subscription_type.as_deref(),
            credentials.rate_limit_tier.as_deref(),
        ),
        lines: vec![
            MetricLine::badge("Status", &wait_text, Some("#F59E0B")),
            rate_limited_note(retry_after_seconds),
        ],
        warning: Some(rate_limited_warning(retry_after_seconds)),
    }
}

pub fn rate_limited_warning(retry_after_seconds: Option<i64>) -> String {
    let base = "Updates blocked by Anthropic. Be patient — manual refreshes will make it worse.";
    match retry_after_seconds.map(format_rate_limit_minutes) {
        Some(text) => format!("{base} Retrying in ~{text}."),
        None => base.into(),
    }
}

pub fn rate_limited_note(retry_after_seconds: Option<i64>) -> MetricLine {
    let text = match retry_after_seconds.map(format_rate_limit_minutes) {
        Some(text) => format!("Live usage rate limited - retry in ~{text}"),
        None => "Live usage rate limited - data may be stale".into(),
    };
    MetricLine::Text {
        label: "Note".into(),
        value: text,
        color_hex: None,
        subtitle: None,
    }
}

fn format_rate_limit_minutes(seconds: i64) -> String {
    if seconds <= 0 {
        return "now".into();
    }
    format!("{}m", (seconds as f64 / 60.0).ceil() as i64)
}

pub fn parse_retry_after_seconds(value: Option<&str>, now: Timestamp) -> Option<i64> {
    let raw = value?.trim();
    if raw.is_empty() {
        return None;
    }
    if let Ok(seconds) = raw.parse::<i64>() {
        if seconds >= 0 {
            return Some(seconds.min(MAXIMUM_RETRY_AFTER_SECS));
        }
    }
    let date = DateTime::parse_from_rfc2822(raw).ok()?.with_timezone(&Utc);
    let seconds = (date.timestamp_millis() as f64 / 1000.0 - now).ceil();
    if !seconds.is_finite() || seconds <= 0.0 {
        return Some(0);
    }
    Some(seconds.min(MAXIMUM_RETRY_AFTER_SECS as f64) as i64)
}

/// Anthropic reports a missing OAuth permission as HTTP 403 with an explicit message. Only that
/// message is a scope problem; other 403s can be expired sessions or account-level denials.
pub fn is_missing_profile_scope_failure(status: u16, body: &[u8]) -> bool {
    if status != 403 {
        return false;
    }
    let body = String::from_utf8_lossy(body).to_lowercase();
    (body.contains("oauth token does not meet scope requirement") && body.contains("user:profile"))
        || body.contains("oauth token missing user:profile scope")
        || body.contains("missing user:profile scope")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn maps_windows_plan_and_extra_usage() {
        let body = serde_json::to_vec(&json!({
            "five_hour": {"utilization": 12.5, "resets_at": "2099-01-01T00:00:00Z"},
            "seven_day": {"utilization": 40},
            "seven_day_sonnet": {"utilization": 7},
            "limits": [{"kind": "weekly_scoped", "percent": 33, "scope": {"model": {"display_name": "Fable"}}}],
            "extra_usage": {"is_enabled": true, "used_credits": 1234, "monthly_limit": 5000, "currency": "eur", "decimal_places": 2}
        }))
        .unwrap();
        let oauth = ClaudeOAuth {
            subscription_type: Some("max".into()),
            rate_limit_tier: Some("20x".into()),
            ..Default::default()
        };
        let mapped = map_usage_response(200, &body, &oauth, 1_800_000_000.0).unwrap();
        assert_eq!(mapped.plan.as_deref(), Some("Max 20x"));
        let labels: Vec<&str> = mapped.lines.iter().map(MetricLine::label).collect();
        assert_eq!(
            labels,
            vec!["Session", "Weekly", "Sonnet", "Fable", "Extra usage spent"]
        );
        assert!(
            matches!(&mapped.lines[4], MetricLine::Progress { used, limit, format: ProgressFormat::Currency(code), .. }
            if (*used - 12.34).abs() < 1e-9 && (*limit - 50.0).abs() < 1e-9 && code == "EUR")
        );
    }

    #[test]
    fn extra_usage_without_cap_is_raw_dollars() {
        let body = serde_json::to_vec(&json!({
            "extra_usage": {"is_enabled": true, "used_credits": 250}
        }))
        .unwrap();
        let mapped =
            map_usage_response(200, &body, &ClaudeOAuth::default(), 1_800_000_000.0).unwrap();
        assert!(matches!(&mapped.lines[0], MetricLine::Values { values, .. }
            if values[0].number == 2.5 && values[0].currency_code.is_none()));
    }

    #[test]
    fn reset_dates_ignore_past_and_absurd_values() {
        let now = 1_800_000_000.0;
        assert_eq!(reset_date(Some(&json!("2020-01-01T00:00:00Z")), now), None);
        assert_eq!(
            reset_date(Some(&json!(4_000_000_000_000i64)), now),
            Some(4_000_000_000.0)
        );
        assert_eq!(reset_date(Some(&json!(9_999_999_999_999i64)), now), None);
    }

    #[test]
    fn retry_after_handles_seconds_date_and_garbage() {
        assert_eq!(parse_retry_after_seconds(Some("120"), 0.0), Some(120));
        assert_eq!(parse_retry_after_seconds(Some("  -5 "), 0.0), None);
        assert_eq!(
            parse_retry_after_seconds(Some("999999999"), 0.0),
            Some(MAXIMUM_RETRY_AFTER_SECS)
        );
        assert_eq!(parse_retry_after_seconds(Some("not a date"), 0.0), None);
    }

    #[test]
    fn scope_denial_requires_the_explicit_message() {
        assert!(is_missing_profile_scope_failure(
            403,
            b"OAuth token missing user:profile scope"
        ));
        assert!(!is_missing_profile_scope_failure(403, b"forbidden"));
        assert!(!is_missing_profile_scope_failure(
            401,
            b"OAuth token missing user:profile scope"
        ));
    }
}
