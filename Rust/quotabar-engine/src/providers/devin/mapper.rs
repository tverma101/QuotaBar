//! Devin quota response normalization (`GetUserStatus`).

use crate::model::{clamp_percent, MetricKind, MetricLine, MetricValue, Timestamp};
use crate::parse;
use serde_json::Value;

pub const MAXIMUM_RESET_HORIZON_SECS: f64 = 2.0 * 365.0 * 24.0 * 60.0 * 60.0;

#[derive(Clone, Debug, PartialEq)]
pub struct MappedUsage {
    pub plan: String,
    pub lines: Vec<MetricLine>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UsageError {
    InvalidResponse,
    QuotaUnavailable,
}

pub fn map_user_status_response(body: &[u8], now: Timestamp) -> Result<MappedUsage, UsageError> {
    let root: Value = serde_json::from_slice(body).map_err(|_| UsageError::InvalidResponse)?;
    let user_status = root.get("userStatus").filter(|v| v.is_object()).ok_or(UsageError::InvalidResponse)?;
    map_user_status(user_status, now)
}

pub fn map_user_status(user_status: &Value, now: Timestamp) -> Result<MappedUsage, UsageError> {
    let empty = Value::Object(Default::default());
    let plan_status = user_status.get("planStatus").filter(|v| v.is_object()).unwrap_or(&empty);
    let plan_info = plan_status.get("planInfo").filter(|v| v.is_object()).unwrap_or(&empty);
    let plan = parse::trimmed_string(plan_info.get("planName")).unwrap_or_else(|| "Unknown".to_string());
    let hide_daily = parse::bool(plan_info.get("hideDailyQuota")) == Some(true);

    let daily_remaining = parse::number(plan_status.get("dailyQuotaRemainingPercent"));
    let weekly_remaining = parse::number(plan_status.get("weeklyQuotaRemainingPercent"));
    if plan_status.get("weeklyQuotaRemainingPercent").is_some() && weekly_remaining.is_none() {
        return Err(UsageError::InvalidResponse);
    }
    let daily_reset = if hide_daily { None } else { reset_instant(plan_status.get("dailyQuotaResetAtUnix"), now) };
    let weekly_reset = reset_instant(plan_status.get("weeklyQuotaResetAtUnix"), now);
    let extra_balance = parse::number(plan_status.get("overageBalanceMicros")).map(|micros| micros.max(0.0) / 1_000_000.0);

    let mut lines = Vec::new();
    if !hide_daily {
        if let Some(remaining) = daily_remaining {
            lines.push(quota_line("Daily quota", remaining, daily_reset, parse::DAY_MS));
        }
    }
    let weekly = weekly_remaining.or(weekly_reset.map(|_| 0.0));
    if let Some(remaining) = weekly {
        lines.push(quota_line("Weekly quota", remaining, weekly_reset, parse::WEEK_MS));
    } else if hide_daily {
        if let Some(remaining) = daily_remaining {
            lines.push(quota_line("Weekly quota", remaining, None, parse::WEEK_MS));
        }
    }
    if let Some(balance) = extra_balance {
        lines.push(MetricLine::values("Extra usage balance", vec![MetricValue::new(balance, MetricKind::Dollars)]));
    }
    if lines.is_empty() {
        return Err(UsageError::QuotaUnavailable);
    }
    Ok(MappedUsage { plan, lines })
}

fn quota_line(label: &str, remaining: f64, resets_at: Option<Timestamp>, period_ms: i64) -> MetricLine {
    MetricLine::percent_progress(label, clamp_percent(100.0 - remaining), resets_at, Some(period_ms))
}

fn reset_instant(value: Option<&Value>, now: Timestamp) -> Option<Timestamp> {
    let seconds = parse::number(value).filter(|s| *s > 0.0)?;
    (seconds > now && seconds - now <= MAXIMUM_RESET_HORIZON_SECS).then_some(seconds)
}
