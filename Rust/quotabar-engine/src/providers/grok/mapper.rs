//! Normalization of Grok billing (`GetGrokCreditsConfig`) and settings responses.

use crate::model::{clamp_percent, ErrorCategory, MetricLine};
use crate::parse;
use crate::time;
use serde_json::Value;

pub const WEEKLY_PERIOD_TYPE: &str = "USAGE_PERIOD_TYPE_WEEKLY";
const FALLBACK_PERIOD_MS: i64 = parse::WEEK_MS;
const MAX_PERIOD_MS: f64 = 366.0 * 24.0 * 60.0 * 60.0 * 1000.0;

#[derive(Clone, Debug, PartialEq)]
pub struct DecodedCreditsConfig {
    pub period_type: String,
    pub used_percent: f64,
    pub period_start: f64,
    pub period_end: f64,
    pub on_demand_cap: f64,
}

impl DecodedCreditsConfig {
    pub fn period_duration_ms(&self) -> i64 {
        let ms = (self.period_end - self.period_start) * 1000.0;
        if ms.is_finite() && ms > 0.0 && ms <= MAX_PERIOD_MS {
            ms.round() as i64
        } else {
            FALLBACK_PERIOD_MS
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GrokUsageError {
    ConnectionFailed,
    InvalidResponse,
    RequestFailed(u16),
}

impl GrokUsageError {
    pub fn message(self) -> String {
        match self {
            GrokUsageError::ConnectionFailed => {
                "Grok billing request failed. Check your connection.".into()
            }
            GrokUsageError::InvalidResponse => "Grok billing response changed.".into(),
            GrokUsageError::RequestFailed(status) => {
                format!("Grok billing request failed (HTTP {status}). Try again later.")
            }
        }
    }

    pub fn category(self) -> ErrorCategory {
        match self {
            GrokUsageError::ConnectionFailed => ErrorCategory::Network,
            GrokUsageError::InvalidResponse => ErrorCategory::Decoding,
            GrokUsageError::RequestFailed(status) => ErrorCategory::http(status),
        }
    }
}

pub fn decode_credits_config(body: &[u8]) -> Result<DecodedCreditsConfig, GrokUsageError> {
    let Ok(Value::Object(root)) = serde_json::from_slice::<Value>(body) else {
        return Err(GrokUsageError::InvalidResponse);
    };
    let Some(config) = root.get("config").and_then(Value::as_object) else {
        return Err(GrokUsageError::InvalidResponse);
    };
    let Some(period) = config.get("currentPeriod").and_then(Value::as_object) else {
        return Err(GrokUsageError::InvalidResponse);
    };
    let Some(period_type) = parse::trimmed_string(period.get("type")) else {
        return Err(GrokUsageError::InvalidResponse);
    };
    let Some(start) = parse_date(period.get("start")) else {
        return Err(GrokUsageError::InvalidResponse);
    };
    let Some(end) = parse_date(period.get("end")) else {
        return Err(GrokUsageError::InvalidResponse);
    };
    if end <= start {
        return Err(GrokUsageError::InvalidResponse);
    }

    let used_percent = match config.get("creditUsagePercent") {
        None | Some(Value::Null) => 0.0,
        Some(raw) => {
            let Some(num) = parse::number(Some(raw)) else {
                return Err(GrokUsageError::InvalidResponse);
            };
            num
        }
    };

    let on_demand_cap = match config.get("onDemandCap") {
        None | Some(Value::Null) => 0.0,
        Some(raw) => {
            let Some(obj) = raw.as_object() else {
                return Err(GrokUsageError::InvalidResponse);
            };
            match obj.get("val") {
                None | Some(Value::Null) => 0.0,
                Some(v) => {
                    let Some(num) = parse::number(Some(v)) else {
                        return Err(GrokUsageError::InvalidResponse);
                    };
                    num
                }
            }
        }
    };

    Ok(DecodedCreditsConfig {
        period_type,
        used_percent,
        period_start: start,
        period_end: end,
        on_demand_cap,
    })
}

pub fn map_credits_config(body: &[u8]) -> Result<Vec<MetricLine>, GrokUsageError> {
    let config = decode_credits_config(body)?;
    let mut lines = Vec::new();
    if config.period_type == WEEKLY_PERIOD_TYPE {
        lines.push(MetricLine::percent_progress(
            "Weekly limit",
            clamp_percent(config.used_percent),
            Some(config.period_end),
            Some(config.period_duration_ms()),
        ));
    }
    let text = if config.on_demand_cap > 0.0 {
        format!("{} cap", format_units(config.on_demand_cap))
    } else {
        "Disabled".to_string()
    };
    let color = if config.on_demand_cap > 0.0 {
        "#22c55e"
    } else {
        "#a3a3a3"
    };
    lines.push(MetricLine::badge("Pay as you go", &text, Some(color)));
    Ok(lines)
}

pub fn plan_name_from_settings(body: &[u8]) -> Option<String> {
    let Value::Object(root) = serde_json::from_slice::<Value>(body).ok()? else {
        return None;
    };
    parse::trimmed_string(root.get("subscription_tier_display"))
}

fn parse_date(val: Option<&Value>) -> Option<f64> {
    match val? {
        Value::String(s) => time::parse_iso8601(s.trim()),
        Value::Number(n) => n.as_f64().filter(|f| f.is_finite()),
        _ => None,
    }
}

fn format_units(value: f64) -> String {
    if !value.is_finite() {
        return "0".into();
    }
    if value.fract() == 0.0 {
        let clamped = if value >= (i64::MAX as f64) {
            i64::MAX
        } else if value <= (i64::MIN as f64) {
            i64::MIN
        } else {
            value as i64
        };
        clamped.to_string()
    } else {
        value.to_string()
    }
}
