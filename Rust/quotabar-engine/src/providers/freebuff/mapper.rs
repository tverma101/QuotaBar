//! Maps Freebuff's read-only session payload to metric lines (`FreebuffUsageMapper.swift`). The
//! current meter supersedes legacy session caps; its wire values remain Freebucks but the provider
//! displays five Freebucks as one hour.

use super::error::FreebuffError;
use crate::model::{ActiveSession, MetricKind, MetricLine, MetricValue, ProgressFormat, Timestamp};
use crate::parse::{self, DAY_MS, WEEK_MS};
use crate::time;
use serde_json::{Map, Value};
use std::collections::BTreeMap;

pub const FIVE_DAY_PERIOD_MS: i64 = 5 * DAY_MS;
pub const FREEBUCKS_PER_HOUR: f64 = 5.0;

#[derive(Clone, Debug, PartialEq)]
pub struct MappedUsage {
    pub plan: Option<String>,
    pub lines: Vec<MetricLine>,
    pub warning: Option<String>,
    pub active_sessions: Vec<ActiveSession>,
}

type Object = Map<String, Value>;

/// Swift `FreebuffUsageMapper.map(response:)`. `status` is the HTTP status the host reported.
pub fn map(status_code: i64, body: &[u8]) -> Result<MappedUsage, FreebuffError> {
    let root: Object = if status_code == 404 {
        let mut none = Object::new();
        none.insert("status".into(), Value::String("none".into()));
        none
    } else if let Some(parsed) = json_object(body) {
        parsed
    } else {
        return Err(FreebuffError::InvalidResponse);
    };
    match root.get("status").and_then(Value::as_str) {
        Some(status) if !status.is_empty() => {}
        _ => return Err(FreebuffError::InvalidResponse),
    }

    let subscription = root.get("subscription").and_then(Value::as_object);
    let subscription_usage = subscription.and_then(|s| s.get("usage")).and_then(Value::as_object);
    let free_windows = root.get("freeWindows").and_then(Value::as_object);
    let freebucks = root.get("freebucks").and_then(Value::as_object);
    let mut lines: Vec<MetricLine> = Vec::new();
    let mut warning: Option<String> = None;
    if let Some(raw) = root.get("freebucks") {
        if !raw.is_null() && freebucks.is_none() {
            return Err(FreebuffError::InvalidResponse);
        }
        if raw.is_null() {
            warning = Some("Freebuff couldn't refresh its hours balances. Refresh again to get current hours.".into());
        }
    }

    if root.contains_key("freebucks") {
        // Legacy free/subscription windows are still sent for compatibility. They no longer
        // describe the available budget when the account has the current hours meter.
    } else if let Some(usage) = subscription_usage {
        let sessions = ProgressFormat::Count("sessions".into());
        append_progress(&mut lines, "Daily", usage.get("dayUsed"), usage.get("dayLimit"), &sessions,
            usage.get("dayResetAt"), Some(DAY_MS), None);
        append_progress(&mut lines, "5-Day", usage.get("fiveDayUsed"), usage.get("fiveDayLimit"), &sessions,
            None, Some(FIVE_DAY_PERIOD_MS), None);
        append_progress(&mut lines, "Monthly", usage.get("monthUsed"), usage.get("monthLimit"), &sessions,
            usage.get("periodEndsAt"), None, None);
        append_progress(&mut lines, "Premium Sessions", usage.get("dayPremiumUsed"), usage.get("dayPremiumLimit"),
            &sessions, usage.get("dayResetAt"), Some(DAY_MS), Some("Luna / DeepSeek V4 Pro"));
        append_progress(&mut lines, "Free Premium Sessions", usage.get("freeDayUsed"), usage.get("freeDayLimit"),
            &sessions, usage.get("dayResetAt"), Some(DAY_MS), None);
    } else if let Some(windows) = free_windows {
        let sessions = ProgressFormat::Count("sessions".into());
        append_progress(&mut lines, "Daily", windows.get("dayUsed"), windows.get("dayLimit"), &sessions,
            windows.get("dayResetAt"), Some(DAY_MS), None);
        append_progress(&mut lines, "Weekly", windows.get("weekUsed"), windows.get("weekLimit"), &sessions,
            None, Some(WEEK_MS), None);
        append_progress(&mut lines, "Monthly", windows.get("monthUsed"), windows.get("monthLimit"), &sessions,
            windows.get("monthResetAt"), None, None);
    } else if let Some(pool) = most_used_rate_limit(
        root.get("rateLimitsByModel").and_then(Value::as_object).unwrap_or(&Object::new()),
    ) {
        // Limited-access accounts may expose only model pools. Pools are grouped by their opaque
        // server key before choosing the most-used one, so shared per-model rows are never added
        // together and double-counted.
        let detail = pool.pool_label.as_ref().map(|label| format!("Most used pool: {label}"));
        lines.push(MetricLine::Progress {
            label: "Session Pool".into(),
            used: pool.recent_count,
            limit: pool.limit,
            format: ProgressFormat::Count("sessions".into()),
            resets_at: pool.reset_at,
            period_duration_ms: pool.period_duration_ms,
            color_hex: None,
            detail,
        });
    }

    if let Some(daily) = freebucks.and_then(|f| f.get("daily")).and_then(Value::as_object) {
        let (Some(spent), Some(limit)) = (nonnegative(daily.get("spent")), nonnegative(daily.get("limit"))) else {
            return Err(FreebuffError::InvalidResponse);
        };
        if let Some(reset) = daily.get("resetAt") {
            if date(Some(reset)).is_none() {
                return Err(FreebuffError::InvalidResponse);
            }
        }
        append_progress_numbers(
            &mut lines,
            "Daily Hours",
            spent / FREEBUCKS_PER_HOUR,
            limit / FREEBUCKS_PER_HOUR,
            &ProgressFormat::Count("hours".into()),
            daily.get("resetAt"),
            Some(DAY_MS),
            None,
        );
    } else if freebucks.is_some() {
        return Err(FreebuffError::InvalidResponse);
    }
    if let Some(freebucks) = freebucks {
        let wallet = if let Some(raw_wallet) = freebucks.get("wallet") {
            let Some(balance) = raw_wallet.as_object().and_then(|o| nonnegative(o.get("balance"))) else {
                return Err(FreebuffError::InvalidResponse);
            };
            balance
        } else {
            // Older servers only supplied the combined total. Remove the daily remainder;
            // displaying that total beside Daily Hours counted the daily pool twice.
            let daily = freebucks.get("daily").and_then(Value::as_object);
            let (Some(total), Some(daily)) = (nonnegative(freebucks.get("balance")), daily) else {
                return Err(FreebuffError::InvalidResponse);
            };
            let (Some(spent), Some(limit)) = (nonnegative(daily.get("spent")), nonnegative(daily.get("limit"))) else {
                return Err(FreebuffError::InvalidResponse);
            };
            let remaining = nonnegative(daily.get("remaining")).unwrap_or_else(|| (limit - spent).max(0.0));
            if total + 1e-9 < remaining {
                return Err(FreebuffError::InvalidResponse);
            }
            (total - remaining).max(0.0)
        };
        lines.push(MetricLine::values(
            "Hours Balance",
            vec![MetricValue::new((wallet / FREEBUCKS_PER_HOUR + 1e-9).floor(), MetricKind::Count).with_label("hours")],
        ));
    } else {
        // Explicit empty value rows replace an old balance during quota-only merges.
        lines.push(MetricLine::values("Hours Balance", Vec::new()));
    }

    append_monthly_spend(subscription_usage, freebucks, &mut lines);
    if !lines.iter().any(|line| match line {
        MetricLine::Values { values, .. } => !values.is_empty(),
        _ => true,
    }) {
        lines.push(MetricLine::no_usage_data());
    }
    if !lines.iter().any(|line| line.label() == "Monthly Spend") {
        lines.push(MetricLine::values("Monthly Spend", Vec::new()));
    }

    let sessions = active_sessions(&root)?;
    // Separate session expiry metadata from daily-budget reset times. Emit an empty row too,
    // so a successful idle poll replaces the previous active sessions.
    lines.push(MetricLine::Values {
        label: "Active Sessions".into(),
        values: Vec::new(),
        color_hex: None,
        expiries_at: sessions.iter().map(|s| s.expires_at).collect(),
        unknown_models: Vec::new(),
        model_breakdown: None,
    });

    let tier = non_empty_string(subscription.and_then(|s| s.get("tierId")));
    let access_tier = non_empty_string(root.get("accessTier"));
    Ok(MappedUsage {
        plan: tier.or_else(|| access_tier.map(|t| capitalized(&t))),
        lines,
        warning,
        active_sessions: sessions,
    })
}

/// Swift `ProviderParse.jsonObject`: a non-empty body whose top level is an object.
pub(super) fn json_object(body: &[u8]) -> Option<Object> {
    if body.is_empty() {
        return None;
    }
    match serde_json::from_slice::<Value>(body).ok()? {
        Value::Object(object) => Some(object),
        _ => None,
    }
}

fn non_empty_string(value: Option<&Value>) -> Option<String> {
    value?.as_str().filter(|s| !s.is_empty()).map(str::to_string)
}

fn nonnegative(value: Option<&Value>) -> Option<f64> {
    parse::number(value).filter(|n| *n >= 0.0)
}

/// Swift `String.capitalized`: the first letter of each word upper-cased, the rest lower-cased.
fn capitalized(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut at_word_start = true;
    for ch in text.chars() {
        if ch.is_alphabetic() {
            if at_word_start {
                out.extend(ch.to_uppercase());
            } else {
                out.extend(ch.to_lowercase());
            }
            at_word_start = false;
        } else {
            out.push(ch);
            at_word_start = !ch.is_numeric();
        }
    }
    out
}

/// Swift `activeSessions(_:)`. Sorted by earliest expiry; equal timestamps stay distinct sessions.
pub fn active_sessions(root: &Object) -> Result<Vec<ActiveSession>, FreebuffError> {
    let mut sessions: BTreeMap<String, ActiveSession> = BTreeMap::new();
    if root.get("status").and_then(Value::as_str) == Some("active") {
        let Some(expiry) = date(root.get("expiresAt")) else { return Err(FreebuffError::InvalidResponse) };
        let id = non_empty_string(root.get("instanceId")).unwrap_or_else(|| "single".into());
        sessions.insert(id.clone(), session(id, expiry, non_empty_string(root.get("model"))));
    }
    if let Some(raw) = root.get("desktopPurchases") {
        if !raw.is_null() {
            let Some(items) = raw.as_array().filter(|a| a.iter().all(Value::is_object)) else {
                return Err(FreebuffError::InvalidResponse);
            };
            for purchase in items.iter().filter_map(Value::as_object) {
                // Unoccupied purchases are reusable hours, not running sessions.
                let Some(holder) = non_empty_string(purchase.get("holderInstanceId")) else { continue };
                let Some(expiry) = date(purchase.get("expiresAt")) else { return Err(FreebuffError::InvalidResponse) };
                let model = non_empty_string(purchase.get("model"));
                sessions.insert(holder.clone(), session(holder, expiry, model));
            }
        }
    }
    let mut ordered: Vec<ActiveSession> = sessions.into_values().collect();
    ordered.sort_by(|a, b| a.expires_at.partial_cmp(&b.expires_at).unwrap_or(std::cmp::Ordering::Equal));
    Ok(ordered)
}

fn session(instance_id: String, expires_at: Timestamp, model: Option<String>) -> ActiveSession {
    ActiveSession { instance_id, expires_at, model, thread_id: None, chat_title: None, project_path: None }
}

struct RateLimitPool {
    key: String,
    pool_label: Option<String>,
    limit: f64,
    recent_count: f64,
    reset_at: Option<Timestamp>,
    period_duration_ms: Option<i64>,
}

fn most_used_rate_limit(models: &Object) -> Option<RateLimitPool> {
    let mut pools: BTreeMap<String, RateLimitPool> = BTreeMap::new();
    for (model, raw) in models {
        let Some(value) = raw.as_object() else { continue };
        let Some(limit) = parse::number(value.get("limit")).filter(|l| *l > 0.0) else { continue };
        let Some(recent_count) = parse::number(value.get("recentCount")).filter(|c| *c >= 0.0) else { continue };
        let key = non_empty_string(value.get("pool")).unwrap_or_else(|| format!("model:{model}"));
        let candidate = RateLimitPool {
            key: key.clone(),
            pool_label: non_empty_string(value.get("poolLabel")),
            limit,
            recent_count,
            reset_at: date(value.get("resetAt")),
            period_duration_ms: period_duration(value.get("period").and_then(Value::as_str)),
        };
        match pools.get(&key) {
            Some(existing) if candidate.recent_count / candidate.limit <= existing.recent_count / existing.limit => {}
            _ => {
                pools.insert(key, candidate);
            }
        }
    }
    let mut ordered: Vec<RateLimitPool> = pools.into_values().collect();
    ordered.sort_by(|a, b| {
        let left = a.recent_count / a.limit;
        let right = b.recent_count / b.limit;
        if left != right {
            return right.partial_cmp(&left).unwrap_or(std::cmp::Ordering::Equal);
        }
        a.key.cmp(&b.key)
    });
    ordered.into_iter().next()
}

fn period_duration(value: Option<&str>) -> Option<i64> {
    match value {
        Some("pacific_day") => Some(DAY_MS),
        Some("pacific_week") => Some(WEEK_MS),
        Some("pacific_month") => Some(30 * DAY_MS),
        _ => None,
    }
}

fn append_monthly_spend(subscription_usage: Option<&Object>, freebucks: Option<&Object>, lines: &mut Vec<MetricLine>) {
    let monthly = freebucks.and_then(|f| f.get("monthly")).and_then(Value::as_object);
    let pick = |monthly_key: &str, usage_key: &str| -> Option<&Value> {
        monthly.and_then(|m| m.get(monthly_key)).or_else(|| subscription_usage.and_then(|u| u.get(usage_key)))
    };
    let spent = parse::number(pick("spentUsd", "monthSpendUsd"));
    let limit = parse::number(pick("limitUsd", "monthSpendLimitUsd"));
    let Some(spent) = spent.filter(|s| *s >= 0.0) else { return };
    let reset = date(pick("resetAt", "periodEndsAt"));
    match limit.filter(|l| *l > 0.0) {
        Some(limit) => lines.push(MetricLine::Progress {
            label: "Monthly Spend".into(),
            used: spent,
            limit,
            format: ProgressFormat::Dollars,
            resets_at: reset,
            period_duration_ms: None,
            color_hex: None,
            detail: None,
        }),
        None => lines.push(MetricLine::values("Monthly Spend", vec![MetricValue::new(spent, MetricKind::Dollars)])),
    }
}

#[allow(clippy::too_many_arguments)]
fn append_progress(
    lines: &mut Vec<MetricLine>,
    label: &str,
    raw_used: Option<&Value>,
    raw_limit: Option<&Value>,
    format: &ProgressFormat,
    raw_reset: Option<&Value>,
    period_duration_ms: Option<i64>,
    detail: Option<&str>,
) {
    let (Some(used), Some(limit)) = (
        parse::number(raw_used).filter(|u| *u >= 0.0),
        parse::number(raw_limit).filter(|l| *l >= 0.0),
    ) else {
        return;
    };
    append_progress_numbers(lines, label, used, limit, format, raw_reset, period_duration_ms, detail);
}

#[allow(clippy::too_many_arguments)]
fn append_progress_numbers(
    lines: &mut Vec<MetricLine>,
    label: &str,
    used: f64,
    limit: f64,
    format: &ProgressFormat,
    raw_reset: Option<&Value>,
    period_duration_ms: Option<i64>,
    detail: Option<&str>,
) {
    lines.push(MetricLine::Progress {
        label: label.into(),
        used,
        limit,
        format: format.clone(),
        resets_at: date(raw_reset),
        period_duration_ms,
        color_hex: None,
        detail: detail.map(str::to_string),
    });
}

/// A reset timestamp from the payload (Swift `date(_:)`): a non-empty ISO-8601 string.
fn date(value: Option<&Value>) -> Option<Timestamp> {
    let text = value?.as_str().filter(|s| !s.is_empty())?;
    time::parse_iso8601(text)
}
