//! Antigravity quota mapping (`Providers/Antigravity/AntigravityUsageMapper` and
//! `AntigravityQuotaSummary`): quota summary pools, legacy per-model pooling, and plan names.

use crate::host::{diagnostic_gate, plugin_tag};
use crate::model::{MetricLine, ProgressFormat};
use crate::qlog;
use crate::time::parse_iso8601;
use serde_json::Value;

pub const SESSION_LABEL: &str = "Session";
pub const WEEKLY_LABEL: &str = "Weekly";
pub const ARGON_WEEKLY_LABEL: &str = "Argon Weekly";
pub const CLAUDE_LABEL: &str = "Claude";
pub const CLAUDE_WEEKLY_LABEL: &str = "Claude Weekly";
pub const ARGON_GROUP_NAME: &str = "Gemini 4 Argon";

const UNKNOWN_BUCKET_KEY: &str = "provider.antigravity.summary.unknown-bucket";

pub const SESSION_MS: i64 = 18_000_000;
pub const WEEK_MS: i64 = 604_800_000;

const SUMMARY_BUCKETS: [(&str, &str, i64); 4] = [
    ("gemini-5h", SESSION_LABEL, SESSION_MS),
    ("gemini-weekly", WEEKLY_LABEL, WEEK_MS),
    ("3p-5h", CLAUDE_LABEL, SESSION_MS),
    ("3p-weekly", CLAUDE_WEEKLY_LABEL, WEEK_MS),
];

const MODEL_BLACKLIST: [&str; 9] = [
    "MODEL_CHAT_20706",
    "MODEL_CHAT_23310",
    "MODEL_GOOGLE_GEMINI_2_5_FLASH",
    "MODEL_GOOGLE_GEMINI_2_5_FLASH_THINKING",
    "MODEL_GOOGLE_GEMINI_2_5_FLASH_LITE",
    "MODEL_GOOGLE_GEMINI_2_5_PRO",
    "MODEL_PLACEHOLDER_M19",
    "MODEL_PLACEHOLDER_M9",
    "MODEL_PLACEHOLDER_M12",
];

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ModelConfig {
    pub label: String,
    pub model_id: Option<String>,
    pub remaining_fraction: f64,
    pub reset_time: Option<f64>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct QuotaSummary {
    pub lines: Vec<MetricLine>,
    pub is_complete: bool,
}

/// `RetrieveUserQuotaSummary` → up to five percent meters.
pub fn parse_quota_summary(body: &[u8]) -> Option<QuotaSummary> {
    let root: Value = serde_json::from_slice(body).ok()?;
    let groups = root
        .get("response")
        .and_then(|response| response.get("groups"))
        .or_else(|| root.get("groups"))?
        .as_array()?;

    let mut pooled: Vec<(&'static str, f64, Option<f64>)> = Vec::new();
    let mut saw_unknown = false;
    let mut saw_missing_fraction = false;
    let mut saw_missing_buckets = false;
    let mut saw_duplicate = false;
    let mut unknown_ids: Vec<String> = Vec::new();

    for group in groups {
        let display = group
            .get("displayName")
            .and_then(Value::as_str)
            .unwrap_or("");
        let buckets = match group.get("buckets") {
            None | Some(Value::Null) => {
                saw_missing_buckets = true;
                continue;
            }
            Some(Value::Array(buckets)) => buckets,
            Some(_) => {
                saw_missing_buckets = true;
                continue;
            }
        };
        if display == ARGON_GROUP_NAME {
            continue;
        }
        for bucket in buckets {
            let Some(id) = bucket.get("bucketId").and_then(Value::as_str) else {
                saw_unknown = true;
                continue;
            };
            let Some((id, label, _)) = SUMMARY_BUCKETS.iter().find(|(known, _, _)| *known == id)
            else {
                saw_unknown = true;
                unknown_ids.push(id.to_string());
                continue;
            };
            let Some(fraction) = bucket
                .get("remainingFraction")
                .and_then(Value::as_f64)
                .filter(|v| v.is_finite())
            else {
                saw_missing_fraction = true;
                continue;
            };
            let reset = bucket
                .get("resetTime")
                .and_then(Value::as_str)
                .and_then(parse_iso8601);
            if let Some(existing) = pooled.iter_mut().find(|(known, _, _)| known == id) {
                saw_duplicate = true;
                if fraction < existing.1 {
                    *existing = (*id, fraction, reset);
                }
            } else {
                pooled.push((*id, fraction, reset));
            }
            let _ = label;
        }
    }

    if unknown_ids.is_empty() {
        diagnostic_gate::clear(UNKNOWN_BUCKET_KEY);
    } else {
        // Unknown buckets never join a visible pool; say so once instead of losing a meter silently.
        unknown_ids.sort();
        unknown_ids.dedup();
        diagnostic_gate::log_once(UNKNOWN_BUCKET_KEY, || {
            qlog!(
                Warn,
                plugin_tag("antigravity"),
                "quota summary contains unrecognized bucket IDs ({}); skipping them",
                unknown_ids.join(", ")
            );
        });
    }

    let mut lines: Vec<MetricLine> = SUMMARY_BUCKETS
        .iter()
        .filter_map(|(id, label, period)| {
            pooled
                .iter()
                .find(|(known, _, _)| known == id)
                .map(|(_, fraction, reset)| line(label, *fraction, *reset, *period))
        })
        .collect();
    let (argon_line, argon_complete) = argon_weekly(groups);
    if let Some(argon) = argon_line {
        let index = lines
            .iter()
            .position(|line| matches!(line.label(), CLAUDE_LABEL | CLAUDE_WEEKLY_LABEL))
            .unwrap_or(lines.len());
        lines.insert(index, argon);
    }
    Some(QuotaSummary {
        lines,
        is_complete: argon_complete
            && !saw_unknown
            && !saw_missing_fraction
            && !saw_missing_buckets
            && !saw_duplicate,
    })
}

pub fn has_all_shared_quota_meters(body: &[u8]) -> bool {
    let Some(summary) = parse_quota_summary(body) else {
        return false;
    };
    SUMMARY_BUCKETS
        .iter()
        .all(|(_, label, _)| summary.lines.iter().any(|line| line.label() == *label))
}

/// Combine several hosts' summaries, keeping the first usable value per label. Only a fully answered
/// set of complete bodies can authoritatively clear prior meters.
pub fn parse_quota_summaries(bodies: &[Vec<u8>], all_hosts_answered: bool) -> Option<QuotaSummary> {
    let results: Vec<QuotaSummary> = bodies
        .iter()
        .filter_map(|body| parse_quota_summary(body))
        .collect();
    if results.is_empty() {
        return None;
    }
    let mut first_by_label: Vec<(String, MetricLine)> = Vec::new();
    for result in &results {
        for line in &result.lines {
            if !first_by_label
                .iter()
                .any(|(label, _)| label == line.label())
            {
                first_by_label.push((line.label().to_string(), line.clone()));
            }
        }
    }
    let ordered = [
        SESSION_LABEL,
        WEEKLY_LABEL,
        ARGON_WEEKLY_LABEL,
        CLAUDE_LABEL,
        CLAUDE_WEEKLY_LABEL,
    ];
    Some(QuotaSummary {
        lines: ordered
            .iter()
            .filter_map(|label| {
                first_by_label
                    .iter()
                    .find(|(name, _)| name == label)
                    .map(|(_, line)| line.clone())
            })
            .collect(),
        is_complete: all_hosts_answered
            && results.len() == bodies.len()
            && results.iter().all(|result| result.is_complete),
    })
}

fn argon_weekly(groups: &[Value]) -> (Option<MetricLine>, bool) {
    let argon: Vec<&Value> = groups
        .iter()
        .filter(|group| group.get("displayName").and_then(Value::as_str) == Some(ARGON_GROUP_NAME))
        .collect();
    if argon.is_empty() {
        return (None, true);
    }
    let mut complete = true;
    let mut buckets = Vec::new();
    for group in argon {
        match group.get("buckets") {
            None | Some(Value::Null) => return (None, false),
            Some(Value::Array(items)) => buckets.extend(items.iter()),
            Some(_) => return (None, false),
        }
    }
    if buckets.is_empty() {
        return (None, true);
    }
    let weekly: Vec<&&Value> = buckets
        .iter()
        .filter(|bucket| bucket.get("window").and_then(Value::as_str) == Some("weekly"))
        .collect();
    if weekly.len() != 1 {
        return (None, false);
    }
    let bucket = weekly[0];
    let Some(id) = bucket.get("bucketId").and_then(Value::as_str) else {
        return (None, false);
    };
    if SUMMARY_BUCKETS.iter().any(|(known, _, _)| *known == id) {
        return (None, false);
    }
    if let Some(disabled) = bucket.get("disabled") {
        let Some(disabled) = disabled.as_bool() else {
            return (None, false);
        };
        if disabled {
            return (None, true);
        }
    }
    let Some(fraction) = bucket
        .get("remainingFraction")
        .and_then(Value::as_f64)
        .filter(|v| v.is_finite())
    else {
        return (None, false);
    };
    if !buckets.iter().all(|bucket| {
        matches!(
            bucket.get("window").and_then(Value::as_str),
            Some("weekly" | "5h")
        )
    }) {
        complete = false;
    }
    (
        Some(line(
            ARGON_WEEKLY_LABEL,
            fraction,
            bucket
                .get("resetTime")
                .and_then(Value::as_str)
                .and_then(parse_iso8601),
            WEEK_MS,
        )),
        complete,
    )
}

/// LS `GetUserStatus` → plan + model configs.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct UserStatus {
    pub plan: Option<String>,
    pub configs: Vec<ModelConfig>,
}

pub fn parse_user_status(body: &[u8]) -> Option<UserStatus> {
    let root: Value = serde_json::from_slice(body).ok()?;
    let status = root.get("userStatus")?.as_object()?;
    let plan = status
        .get("userTier")
        .and_then(|tier| tier.get("name"))
        .and_then(Value::as_str)
        .or_else(|| {
            status
                .get("planStatus")
                .and_then(|status| status.get("planInfo"))
                .and_then(|info| info.get("planName"))
                .and_then(Value::as_str)
        });
    let configs = status
        .get("cascadeModelConfigData")
        .and_then(|data| data.get("clientModelConfigs"))
        .and_then(Value::as_array)
        .map(|items| items.iter().filter_map(config_from_ls).collect())
        .unwrap_or_default();
    Some(UserStatus {
        plan: format_plan(plan),
        configs,
    })
}

pub fn parse_command_model_configs(body: &[u8]) -> Option<Vec<ModelConfig>> {
    let root: Value = serde_json::from_slice(body).ok()?;
    let configs = root.get("clientModelConfigs")?.as_array()?;
    Some(configs.iter().filter_map(config_from_ls).collect())
}

pub fn parse_load_code_assist_plan(body: &[u8]) -> Option<String> {
    let root: Value = serde_json::from_slice(body).ok()?;
    if let Some(id) = root
        .get("paidTier")
        .and_then(|tier| tier.get("id"))
        .and_then(Value::as_str)
    {
        let known = match id {
            "g1-pro-tier" => Some("Pro"),
            "g1-ultra-tier" => Some("Ultra"),
            "g1-ultra-lite-tier" => Some("Ultra Lite"),
            _ => None,
        };
        if let Some(plan) = known {
            return Some(plan.to_string());
        }
    }
    format_plan(
        root.get("paidTier")
            .and_then(|tier| tier.get("name"))
            .and_then(Value::as_str)
            .or_else(|| {
                root.get("currentTier")
                    .and_then(|tier| tier.get("name"))
                    .and_then(Value::as_str)
            }),
    )
}

pub fn parse_project(body: &[u8]) -> Option<String> {
    let root: Value = serde_json::from_slice(body).ok()?;
    root.get("cloudaicompanionProject")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

/// Collapse legacy per-model configs into the Session / Claude 5-hour pool meters.
pub fn build_lines(configs: &[ModelConfig]) -> Vec<MetricLine> {
    let mut pooled: Vec<(&'static str, f64, Option<f64>)> = Vec::new();
    for config in configs {
        let label = config.label.trim();
        if label.is_empty()
            || config
                .model_id
                .as_deref()
                .is_some_and(|id| MODEL_BLACKLIST.contains(&id))
        {
            continue;
        }
        if is_argon_model(label, config.model_id.as_deref()) {
            continue;
        }
        let normalized = normalize_label(label);
        let pool = pool_label(&normalized);
        if let Some(existing) = pooled.iter_mut().find(|(name, _, _)| *name == pool) {
            if config.remaining_fraction < existing.1 {
                *existing = (pool, config.remaining_fraction, config.reset_time);
            }
        } else {
            pooled.push((pool, config.remaining_fraction, config.reset_time));
        }
    }
    pooled.sort_by_key(|(label, _, _)| {
        if *label == SESSION_LABEL {
            format!("0_{label}")
        } else {
            format!("1_{label}")
        }
    });
    pooled
        .into_iter()
        .map(|(label, fraction, reset)| line(label, fraction, reset, SESSION_MS))
        .collect()
}

pub fn line(label: &str, fraction: f64, reset_time: Option<f64>, period_ms: i64) -> MetricLine {
    let clamped = fraction.clamp(0.0, 1.0);
    let used = ((1.0 - clamped) * 100.0).round();
    MetricLine::Progress {
        label: label.to_string(),
        used,
        limit: 100.0,
        format: ProgressFormat::Percent,
        resets_at: reset_time,
        period_duration_ms: Some(period_ms),
        color_hex: None,
        detail: None,
    }
}

fn config_from_ls(value: &Value) -> Option<ModelConfig> {
    let label = value.get("label").and_then(Value::as_str)?;
    let id = value
        .get("modelOrAlias")
        .and_then(|alias| alias.get("model"))
        .and_then(Value::as_str);
    Some(config(label, id, value.get("quotaInfo")))
}

fn config(label: &str, model_id: Option<&str>, quota: Option<&Value>) -> ModelConfig {
    ModelConfig {
        label: label.trim().to_string(),
        model_id: model_id.map(str::to_string),
        remaining_fraction: quota
            .and_then(|quota| quota.get("remainingFraction"))
            .and_then(Value::as_f64)
            .unwrap_or(0.0),
        reset_time: quota
            .and_then(|quota| quota.get("resetTime"))
            .and_then(Value::as_str)
            .and_then(parse_iso8601),
    }
}

pub fn normalize_label(label: &str) -> String {
    let trimmed = label.trim();
    if let Some(index) = trimmed.rfind('(') {
        if trimmed[index..].ends_with(')') {
            return trimmed[..index].trim().to_string();
        }
    }
    trimmed.to_string()
}

pub fn pool_label(normalized: &str) -> &'static str {
    if normalized.to_lowercase().contains("gemini") {
        SESSION_LABEL
    } else {
        CLAUDE_LABEL
    }
}

pub fn is_argon_model(label: &str, model_id: Option<&str>) -> bool {
    if model_id == Some("MODEL_PLACEHOLDER_M421") {
        return true;
    }
    [normalize_label(label), model_id.unwrap_or("").to_string()]
        .iter()
        .any(|value| {
            let normalized = value.to_lowercase().replace(' ', "-");
            normalized == "gemini-4-argon" || normalized.starts_with("gemini-4-argon-")
        })
}

pub fn format_plan(raw: Option<&str>) -> Option<String> {
    let trimmed = raw?.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Some(rest) = trimmed.strip_prefix("Google AI ") {
        return Some(title_case(rest));
    }
    for keyword in ["Ultra", "Pro", "Free"] {
        if trimmed.to_lowercase().contains(&keyword.to_lowercase()) {
            return Some(keyword.to_string());
        }
    }
    Some(title_case(trimmed))
}

fn title_case(value: &str) -> String {
    value
        .split_whitespace()
        .map(|word| {
            let mut chars = word.chars();
            match chars.next() {
                Some(first) => format!("{}{}", first.to_uppercase(), chars.as_str().to_lowercase()),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn summary_pools_and_completeness() {
        let body = br#"{"response":{"groups":[
            {"displayName":"Gemini","buckets":[
                {"bucketId":"gemini-5h","remainingFraction":0.8,"resetTime":"2026-11-24T12:00:00Z"},
                {"bucketId":"gemini-weekly","remainingFraction":0.5}]},
            {"displayName":"Claude","buckets":[
                {"bucketId":"3p-5h","remainingFraction":0.25},
                {"bucketId":"3p-weekly","remainingFraction":0.75}]}
        ]}}"#;
        let summary = parse_quota_summary(body).unwrap();
        assert!(summary.is_complete);
        assert_eq!(summary.lines.len(), 4);
        assert_eq!(summary.lines[0].label(), SESSION_LABEL);
        assert!(
            matches!(&summary.lines[0], MetricLine::Progress { used, .. } if (*used - 20.0).abs() < 1e-6)
        );
        assert!(
            matches!(&summary.lines[2], MetricLine::Progress { used, .. } if (*used - 75.0).abs() < 1e-6)
        );

        let unknown = br#"{"groups":[{"displayName":"Gemini","buckets":[{"bucketId":"future","remainingFraction":0.1}]}]}"#;
        let summary = parse_quota_summary(unknown).unwrap();
        assert!(!summary.is_complete);
        assert!(summary.lines.is_empty());
    }

    #[test]
    fn legacy_models_pool_and_drop_blacklisted_and_argon() {
        let configs = vec![
            ModelConfig {
                label: "Gemini 3 Pro (High)".into(),
                remaining_fraction: 0.9,
                ..Default::default()
            },
            ModelConfig {
                label: "Gemini 3 Flash".into(),
                remaining_fraction: 0.7,
                ..Default::default()
            },
            ModelConfig {
                label: "Claude Sonnet".into(),
                remaining_fraction: 0.4,
                ..Default::default()
            },
            ModelConfig {
                label: "Gemini 4 Argon".into(),
                remaining_fraction: 0.1,
                ..Default::default()
            },
            ModelConfig {
                label: "Ignored".into(),
                model_id: Some("MODEL_PLACEHOLDER_M19".into()),
                remaining_fraction: 1.0,
                ..Default::default()
            },
        ];
        let lines = build_lines(&configs);
        assert_eq!(lines.len(), 2);
        assert!(
            matches!(&lines[0], MetricLine::Progress { used, .. } if (*used - 30.0).abs() < 1e-6)
        );
        assert!(
            matches!(&lines[1], MetricLine::Progress { used, .. } if (*used - 60.0).abs() < 1e-6)
        );
    }

    #[test]
    fn plan_and_project_parsing() {
        let body = br#"{"paidTier":{"id":"g1-ultra-tier","name":"Gemini Code Assist in Google One AI Ultra"},"cloudaicompanionProject":"p1"}"#;
        assert_eq!(parse_load_code_assist_plan(body).as_deref(), Some("Ultra"));
        assert_eq!(parse_project(body).as_deref(), Some("p1"));
        assert_eq!(format_plan(Some("Google AI Pro")).as_deref(), Some("Pro"));
    }
}
