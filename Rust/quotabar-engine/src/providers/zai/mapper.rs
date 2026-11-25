//! Normalization of Z.ai Coding Plan quota and subscription payloads (`ZAIUsageMapper.swift`).

use super::ID;
use crate::host::{auth_tag, diagnostic_gate};
use crate::model::{clamp_percent, MetricLine, ProgressFormat};
use crate::parse::{self, DAY_MS, WEEK_MS};
use crate::qlog;
use serde_json::{Map, Value};

/// How far ahead a reported reset may sit and still be believable (2 years, matching `ZAIUsageMapper`).
pub const MAXIMUM_RESET_HORIZON_SECS: f64 = 2.0 * 365.0 * 24.0 * 3600.0;
pub const MONTHLY_PERIOD_MS: i64 = 30 * DAY_MS;

pub const INVALID_RESPONSE_ERROR: &str = super::super::error_text::INVALID_RESPONSE;
pub const NO_CODING_PLAN_ERROR: &str = "No active GLM Coding Plan. Subscribe at z.ai/subscribe to see usage.";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MapperError {
    InvalidResponse,
}

#[derive(Debug, Clone, PartialEq)]
pub struct MappedUsage {
    pub plan: Option<String>,
    pub lines: Vec<MetricLine>,
}

enum TokenWindow {
    Session(i64),
    Weekly(i64),
}

enum WindowOutcome {
    Recognized(TokenWindow),
    UnknownWindow,
    Damaged,
}

enum WebSearchOutcome {
    Yielded(MetricLine),
    NotApplicable,
    Damaged,
}

/// Detect Z.ai's `200 OK` business-level error for accounts without an active GLM Coding Plan.
pub fn is_no_coding_plan(body: &[u8]) -> bool {
    let Ok(Value::Object(root)) = serde_json::from_slice::<Value>(body) else {
        return false;
    };
    if root.get("success").and_then(Value::as_bool) != Some(false) {
        return false;
    }
    root.get("msg")
        .and_then(Value::as_str)
        .is_some_and(|msg| msg.to_ascii_lowercase().contains("coding plan"))
}

pub fn plan_name(subscription_body: &[u8]) -> Option<String> {
    let root: Value = serde_json::from_slice(subscription_body).ok()?;
    let first = root.get("data")?.as_array()?.first()?.as_object()?;
    let raw = first.get("productName")?.as_str()?;
    (!raw.is_empty()).then(|| raw.to_string())
}

pub fn map(quota_body: &[u8], subscription_body: Option<&[u8]>, now: f64) -> Result<MappedUsage, MapperError> {
    let lines = map_quota(quota_body, now)?;
    let plan = subscription_body.and_then(plan_name);
    Ok(MappedUsage { plan, lines })
}

pub fn map_quota(quota_body: &[u8], now: f64) -> Result<Vec<MetricLine>, MapperError> {
    let root: Map<String, Value> = match serde_json::from_slice(quota_body) {
        Ok(Value::Object(map)) => map,
        _ => return Err(MapperError::InvalidResponse),
    };
    let container = match root.get("data") {
        Some(Value::Object(data)) => data,
        Some(_) => return Err(MapperError::InvalidResponse),
        None => &root,
    };
    let Some(limits_raw) = container.get("limits").and_then(Value::as_array) else {
        return Err(MapperError::InvalidResponse);
    };
    let mut limits: Vec<&Map<String, Value>> = Vec::with_capacity(limits_raw.len());
    for item in limits_raw {
        let Some(obj) = item.as_object() else {
            return Err(MapperError::InvalidResponse);
        };
        limits.push(obj);
    }
    if limits.is_empty() {
        return Ok(vec![MetricLine::no_usage_data()]);
    }

    let mut lines = Vec::new();
    let mut saw_recognized_limit = false;

    for entry in &limits {
        let kind = entry
            .get("type")
            .and_then(Value::as_str)
            .or_else(|| entry.get("name").and_then(Value::as_str));
        if !matches!(kind, Some("CREDIT_LIMIT" | "TOKENS_LIMIT")) {
            continue;
        }
        match classify_token_window(entry) {
            WindowOutcome::Recognized(window) => {
                saw_recognized_limit = true;
                let (label, period_ms) = match window {
                    TokenWindow::Session(ms) => ("Session", ms),
                    TokenWindow::Weekly(ms) => ("Weekly", ms),
                };
                if let Some(line) = percent_line(entry, label, period_ms, now) {
                    lines.push(line);
                }
            }
            WindowOutcome::UnknownWindow => {}
            WindowOutcome::Damaged => {
                saw_recognized_limit = true;
            }
        }
    }

    if let Some(web) = find_limit(&limits, "TIME_LIMIT") {
        match web_search_line(web, now) {
            WebSearchOutcome::Yielded(line) => {
                saw_recognized_limit = true;
                lines.push(line);
            }
            WebSearchOutcome::NotApplicable => {}
            WebSearchOutcome::Damaged => {
                saw_recognized_limit = true;
            }
        }
    }

    if lines.is_empty() {
        if saw_recognized_limit {
            return Err(MapperError::InvalidResponse);
        }
        return Ok(vec![MetricLine::no_usage_data()]);
    }
    Ok(lines)
}

fn classify_token_window(entry: &Map<String, Value>) -> WindowOutcome {
    let Some(unit) = parse::number(entry.get("unit")) else {
        return damaged_window_entry(entry, "missing or non-positive unit/number");
    };
    let Some(number) = parse::number(entry.get("number")).filter(|&n| n > 0.0) else {
        return damaged_window_entry(entry, "missing or non-positive unit/number");
    };
    let unit_ms = if unit == 3.0 {
        3_600_000.0
    } else if unit == 4.0 {
        DAY_MS as f64
    } else if unit == 6.0 {
        WEEK_MS as f64
    } else if unit == 5.0 {
        MONTHLY_PERIOD_MS as f64
    } else {
        return WindowOutcome::UnknownWindow;
    };
    let duration = unit_ms * number;
    if !duration.is_finite() || duration < 1.0 || duration >= i64::MAX as f64 {
        return damaged_window_entry(entry, "unbelievable window duration");
    }
    let period_ms = duration as i64;
    if period_ms < DAY_MS {
        WindowOutcome::Recognized(TokenWindow::Session(period_ms))
    } else {
        WindowOutcome::Recognized(TokenWindow::Weekly(period_ms))
    }
}

fn damaged_window_entry(entry: &Map<String, Value>, reason: &str) -> WindowOutcome {
    diagnostic_gate::log_once("zai.quota.damaged-window-entry", || {
        qlog!(Warn, auth_tag(ID), "skipped unreadable quota window entry ({reason}): {:?}", entry);
    });
    WindowOutcome::Damaged
}

fn percent_line(entry: &Map<String, Value>, label: &str, period_ms: i64, now: f64) -> Option<MetricLine> {
    let Some(raw_pct) = parse::number(entry.get("percentage")) else {
        diagnostic_gate::log_once("zai.quota.damaged-percentage-entry", || {
            qlog!(Warn, auth_tag(ID), "skipped {label} quota entry with unreadable percentage: {:?}", entry);
        });
        return None;
    };
    let used = clamp_percent(raw_pct);
    let resets_at = reset_date(entry.get("nextResetTime"), now);
    Some(MetricLine::Progress {
        label: label.to_string(),
        used,
        limit: 100.0,
        format: ProgressFormat::Percent,
        resets_at,
        period_duration_ms: Some(period_ms),
        color_hex: None,
        detail: None,
    })
}

fn web_search_line(entry: &Map<String, Value>, now: f64) -> WebSearchOutcome {
    let Some(used) = parse::number(entry.get("currentValue")).filter(|&u| u >= 0.0) else {
        return damaged_time_limit(entry);
    };
    let Some(limit) = parse::number(entry.get("usage")).filter(|&l| l >= 0.0) else {
        return damaged_time_limit(entry);
    };
    if limit <= 0.0 {
        return WebSearchOutcome::NotApplicable;
    }
    let resets_at = reset_date(entry.get("nextResetTime"), now);
    WebSearchOutcome::Yielded(MetricLine::Progress {
        label: "Web Searches".to_string(),
        used,
        limit,
        format: ProgressFormat::Count("searches".to_string()),
        resets_at,
        period_duration_ms: Some(MONTHLY_PERIOD_MS),
        color_hex: None,
        detail: None,
    })
}

fn damaged_time_limit(entry: &Map<String, Value>) -> WebSearchOutcome {
    diagnostic_gate::log_once("zai.quota.damaged-time-limit", || {
        qlog!(Warn, auth_tag(ID), "skipped unreadable TIME_LIMIT entry: {:?}", entry);
    });
    WebSearchOutcome::Damaged
}

pub(super) fn reset_date(value: Option<&Value>, now: f64) -> Option<f64> {
    let milliseconds = parse::number(value).filter(|&ms| ms > 0.0)?;
    let date = milliseconds / 1000.0;
    if date > now && (date - now) <= MAXIMUM_RESET_HORIZON_SECS {
        Some(date)
    } else {
        None
    }
}

fn find_limit<'a>(limits: &[&'a Map<String, Value>], target: &str) -> Option<&'a Map<String, Value>> {
    limits.iter().copied().find(|entry| {
        entry.get("type").and_then(Value::as_str) == Some(target)
            || entry.get("name").and_then(Value::as_str) == Some(target)
    })
}
