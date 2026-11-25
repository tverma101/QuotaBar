//! Normalization of GitHub Copilot user usage and org billing responses.

use crate::model::{clamp_percent, ErrorCategory, MetricKind, MetricLine, MetricValue, Timestamp};
use crate::parse;
use crate::time;
use serde_json::Value;

pub const PERIOD_MS: i64 = 30 * parse::DAY_MS;

#[derive(Clone, Debug, PartialEq)]
pub struct MappedUsage {
    pub plan: Option<String>,
    pub lines: Vec<MetricLine>,
    pub is_org_managed_seat: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CopilotUsageError {
    InvalidResponse,
    ConnectionFailed,
    RequestFailed(u16),
    QuotaUnavailable,
}

impl CopilotUsageError {
    pub fn message(self) -> String {
        match self {
            CopilotUsageError::InvalidResponse => {
                "Copilot usage response invalid. Try again later.".into()
            }
            CopilotUsageError::ConnectionFailed => {
                "Couldn't reach GitHub. Check your connection.".into()
            }
            CopilotUsageError::RequestFailed(status) => {
                format!("Copilot usage request failed (HTTP {status}). Try again later.")
            }
            CopilotUsageError::QuotaUnavailable => {
                "Copilot usage data is unavailable for this account.".into()
            }
        }
    }

    pub fn category(self) -> ErrorCategory {
        match self {
            CopilotUsageError::InvalidResponse => ErrorCategory::Decoding,
            CopilotUsageError::ConnectionFailed => ErrorCategory::Network,
            CopilotUsageError::RequestFailed(status) => ErrorCategory::http(status),
            CopilotUsageError::QuotaUnavailable => ErrorCategory::NotAvailable,
        }
    }
}

pub fn map_user_response(body: &[u8]) -> Result<MappedUsage, CopilotUsageError> {
    let Ok(Value::Object(root)) = serde_json::from_slice::<Value>(body) else {
        return Err(CopilotUsageError::InvalidResponse);
    };
    map_user_object(&root)
}

pub fn map_user_object(
    body: &serde_json::Map<String, Value>,
) -> Result<MappedUsage, CopilotUsageError> {
    let plan = plan_label(body.get("copilot_plan"));
    let resets_at = parse_reset_date(body.get("quota_reset_date"))
        .or_else(|| parse_reset_date(body.get("limited_user_reset_date")));

    let mut lines = Vec::new();
    let snapshots = body.get("quota_snapshots").and_then(Value::as_object);
    let premium = snapshots.and_then(|s| s.get("premium_interactions"));

    if let Some(credits) = snapshot_line("Credits", premium, resets_at) {
        lines.push(credits);
        if let Some(overage) = overage_line(premium) {
            lines.push(overage);
        }
    }
    if let Some(chat) = snapshot_line("Chat", snapshots.and_then(|s| s.get("chat")), resets_at) {
        lines.push(chat);
    }
    if let Some(comp) = snapshot_line(
        "Completions",
        snapshots.and_then(|s| s.get("completions")),
        resets_at,
    ) {
        lines.push(comp);
    }

    if lines.is_empty() {
        let limited = body.get("limited_user_quotas").and_then(Value::as_object);
        let monthly = body.get("monthly_quotas").and_then(Value::as_object);
        if let Some(chat) = limited_line(
            "Chat",
            limited.and_then(|l| l.get("chat")),
            monthly.and_then(|m| m.get("chat")),
            resets_at,
        ) {
            lines.push(chat);
        }
        if let Some(comp) = limited_line(
            "Completions",
            limited.and_then(|l| l.get("completions")),
            monthly.and_then(|m| m.get("completions")),
            resets_at,
        ) {
            lines.push(comp);
        }
    }

    if lines.is_empty() {
        if parse::bool(body.get("token_based_billing")) == Some(true) {
            return Ok(MappedUsage {
                plan,
                lines: personal_credits_lines(premium),
                is_org_managed_seat: true,
            });
        }
        return Err(CopilotUsageError::QuotaUnavailable);
    }

    Ok(MappedUsage {
        plan,
        lines,
        is_org_managed_seat: false,
    })
}

pub fn org_usage_lines(body: &[u8]) -> Option<Vec<MetricLine>> {
    let root: Value = serde_json::from_slice(body).ok()?;
    let items = root.get("usageItems")?.as_array()?;
    let credit_items: Vec<&serde_json::Map<String, Value>> = items
        .iter()
        .filter_map(Value::as_object)
        .filter(|item| is_copilot(item.get("product")) && is_credit_unit(item.get("unitType")))
        .collect();
    if credit_items.is_empty() {
        return None;
    }
    let credits: f64 = credit_items
        .iter()
        .map(|i| {
            parse::number(i.get("grossQuantity"))
                .unwrap_or(0.0)
                .max(0.0)
        })
        .sum();
    let spend: f64 = credit_items
        .iter()
        .map(|i| parse::number(i.get("netAmount")).unwrap_or(0.0).max(0.0))
        .sum();
    Some(vec![
        MetricLine::values(
            "Org Credits",
            vec![MetricValue::new(credits, MetricKind::Count).with_label("credits")],
        ),
        MetricLine::values(
            "Org Spend",
            vec![MetricValue::new(spend, MetricKind::Dollars)],
        ),
    ])
}

fn is_copilot(val: Option<&Value>) -> bool {
    val.and_then(Value::as_str)
        .is_some_and(|s| s.trim().eq_ignore_ascii_case("copilot"))
}

fn is_credit_unit(val: Option<&Value>) -> bool {
    val.and_then(Value::as_str).is_some_and(|s| {
        let lower = s.trim().to_ascii_lowercase();
        lower == "ai-units" || lower == "ai-credits"
    })
}

fn snapshot_line(
    label: &str,
    raw: Option<&Value>,
    resets_at: Option<Timestamp>,
) -> Option<MetricLine> {
    let snapshot = raw?.as_object()?;
    let entitlement = parse::number(snapshot.get("entitlement"));
    let remaining = parse::number(snapshot.get("remaining"));

    if parse::bool(snapshot.get("unlimited")) == Some(true)
        || entitlement == Some(-1.0)
        || remaining == Some(-1.0)
    {
        return None;
    }
    if entitlement == Some(0.0) {
        return None;
    }

    let used_percent =
        if let Some(percent_remaining) = parse::number(snapshot.get("percent_remaining")) {
            clamp_percent(100.0 - percent_remaining)
        } else if let (Some(ent), Some(rem)) = (entitlement.filter(|e| *e > 0.0), remaining) {
            clamp_percent(100.0 - (rem / ent) * 100.0)
        } else {
            return None;
        };

    Some(MetricLine::percent_progress(
        label,
        used_percent,
        resets_at,
        Some(PERIOD_MS),
    ))
}

fn personal_credits_lines(raw: Option<&Value>) -> Vec<MetricLine> {
    let Some(snapshot) = raw.and_then(Value::as_object) else {
        return Vec::new();
    };
    let Some(used) = parse::number(snapshot.get("credits_used")).filter(|v| *v > 0.0) else {
        return Vec::new();
    };
    vec![MetricLine::values(
        "Credits",
        vec![MetricValue::new(used, MetricKind::Count)],
    )]
}

fn overage_line(raw: Option<&Value>) -> Option<MetricLine> {
    let snapshot = raw?.as_object()?;
    if parse::bool(snapshot.get("overage_permitted")) != Some(true) {
        return None;
    }
    let overage = parse::number(snapshot.get("overage_count"))
        .unwrap_or(0.0)
        .max(0.0);
    Some(MetricLine::values(
        "Extra Usage",
        vec![MetricValue::new(overage, MetricKind::Count)],
    ))
}

fn limited_line(
    label: &str,
    remaining: Option<&Value>,
    total: Option<&Value>,
    resets_at: Option<Timestamp>,
) -> Option<MetricLine> {
    let total = parse::number(total).filter(|t| *t > 0.0)?;
    let remaining = parse::number(remaining)?;
    let used = (total - remaining).max(0.0);
    Some(MetricLine::percent_progress(
        label,
        clamp_percent((used / total) * 100.0),
        resets_at,
        Some(PERIOD_MS),
    ))
}

fn plan_label(value: Option<&Value>) -> Option<String> {
    let raw = parse::trimmed_string(value)?;
    let mut words = Vec::new();
    for part in raw.split(|c: char| c == '_' || c == ' ' || c == '-') {
        if part.is_empty() {
            continue;
        }
        let mut chars = part.chars();
        if let Some(first) = chars.next() {
            let mut word = first.to_uppercase().to_string();
            word.push_str(&chars.as_str().to_ascii_lowercase());
            words.push(word);
        }
    }
    (!words.is_empty()).then(|| words.join(" "))
}

pub fn parse_reset_date(value: Option<&Value>) -> Option<Timestamp> {
    let raw = parse::trimmed_string(value)?;
    if let Some(ts) = time::parse_iso8601(&raw) {
        return Some(ts);
    }
    let date = chrono::NaiveDate::parse_from_str(&raw, "%Y-%m-%d").ok()?;
    let dt = date.and_hms_opt(0, 0, 0)?;
    Some(dt.and_utc().timestamp() as f64)
}
