//! Normalization of OpenRouter `/api/v1/credits` and `/api/v1/key` payloads.

use super::ID;
use crate::host::{diagnostic_gate, plugin_tag};
use crate::model::{MetricKind, MetricLine, MetricValue, ProgressFormat};
use crate::{parse, qlog};
use serde_json::{Map, Value};

pub const MISSING_LIMIT_REMAINING_KEY: &str = "openrouter.key.limit-remaining-missing";

pub fn data_object(body: &[u8]) -> Option<Map<String, Value>> {
    let root: Value = serde_json::from_slice(body).ok()?;
    root.get("data")?.as_object().cloned()
}

pub fn credits_lines(data: &Map<String, Value>) -> Vec<MetricLine> {
    let Some(total_usage) = parse::number(data.get("total_usage")) else {
        return Vec::new();
    };
    let Some(reported_credits) = parse::number(data.get("total_credits")) else {
        return Vec::new();
    };

    let used = total_usage.max(0.0);
    let total_credits = reported_credits.max(0.0);
    let mut lines = Vec::new();

    if total_credits > 0.0 {
        lines.push(MetricLine::Progress {
            label: "Credits".to_string(),
            used,
            limit: total_credits,
            format: ProgressFormat::Dollars,
            resets_at: None,
            period_duration_ms: None,
            color_hex: None,
            detail: None,
        });
    }
    lines.push(MetricLine::values(
        "Balance",
        vec![MetricValue::new((total_credits - used).max(0.0), MetricKind::Dollars)],
    ));
    lines
}

pub fn key_metrics(data: &Map<String, Value>) -> (Option<String>, Vec<MetricLine>) {
    let mut lines = Vec::new();

    append_spend(data.get("usage_daily"), "Today", &mut lines);
    append_spend(data.get("usage_weekly"), "This Week", &mut lines);
    append_spend(data.get("usage_monthly"), "This Month", &mut lines);

    if let Some(limit) = parse::number(data.get("limit")).filter(|l| *l > 0.0) {
        if let Some(remaining) = parse::number(data.get("limit_remaining")) {
            let used = (limit - remaining.max(0.0)).max(0.0);
            lines.push(MetricLine::Progress {
                label: "Key Limit".to_string(),
                used,
                limit,
                format: ProgressFormat::Dollars,
                resets_at: None,
                period_duration_ms: None,
                color_hex: None,
                detail: None,
            });
        } else {
            diagnostic_gate::log_once(MISSING_LIMIT_REMAINING_KEY, || {
                qlog!(
                    Warn,
                    plugin_tag(ID),
                    "key limit reported without a remaining amount; the Key Limit meter is hidden"
                );
            });
        }
    }

    let plan = data.get("is_free_tier").and_then(Value::as_bool).map(|free| {
        if free { "Free tier" } else { "Pay as you go" }.to_string()
    });
    (plan, lines)
}

fn append_spend(value: Option<&Value>, label: &str, lines: &mut Vec<MetricLine>) {
    let Some(amount) = parse::number(value) else {
        return;
    };
    lines.push(MetricLine::values(label, vec![MetricValue::new(amount.max(0.0), MetricKind::Dollars)]));
}
