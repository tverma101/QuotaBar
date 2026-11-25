//! Turns Antigravity's quota responses into metric lines (Swift `AntigravityUsageMapper`).
//!
//! The authoritative source is the `RetrieveUserQuotaSummary` RPC ([`parse_quota_summary_result`]):
//! two pools (Gemini, shown as "Session"/"Weekly"; Claude = every non-Gemini model incl. GPT-OSS),
//! each with a rolling 5-hour and a weekly window, plus a separate Argon weekly meter for eligible
//! accounts. Builds without that RPC fall back to the legacy per-model endpoints, whose models
//! collapse into the two 5h pool meters keeping each pool's worst remaining fraction.

use super::metric::{self, SESSION_MS, WEEK_MS};
use super::summary::{self, SummaryGroup, ARGON_GROUP_NAME};
use super::ID;
use crate::host::{diagnostic_gate, plugin_tag};
use crate::model::MetricLine;
use crate::providers::claude::util::stable_fingerprint;
use crate::qlog;
use crate::time::parse_iso8601;
use serde::Deserialize;
use std::collections::BTreeMap;

/// One model's quota as returned by any source, normalized before pooling. `remaining_fraction` is
/// 0…1 (1 = full); a model with no quota info is treated as depleted (0 remaining).
#[derive(Clone, Debug, PartialEq)]
pub struct ModelConfig {
    pub label: String,
    pub model_id: Option<String>,
    pub remaining_fraction: f64,
    pub reset_time: Option<f64>,
}

#[derive(Clone, Debug)]
pub struct QuotaSummaryResult {
    pub lines: Vec<MetricLine>,
    pub is_complete: bool,
}

pub struct SummaryBucketSpec {
    pub bucket_id: &'static str,
    pub label: &'static str,
    pub period_ms: i64,
}

/// The four pool buckets, matched by **exact `bucketId` only** — a future bucket must never silently
/// join a pool, and pool identity is never inferred from `displayName`/`window`.
pub const SUMMARY_BUCKETS: [SummaryBucketSpec; 4] = [
    SummaryBucketSpec { bucket_id: "gemini-5h", label: metric::SESSION_LABEL, period_ms: SESSION_MS },
    SummaryBucketSpec { bucket_id: "gemini-weekly", label: metric::WEEKLY_LABEL, period_ms: WEEK_MS },
    SummaryBucketSpec { bucket_id: "3p-5h", label: metric::CLAUDE_LABEL, period_ms: SESSION_MS },
    SummaryBucketSpec { bucket_id: "3p-weekly", label: metric::CLAUDE_WEEKLY_LABEL, period_ms: WEEK_MS },
];

const ARGON_KEY: &str = "provider.antigravity.summary.argon";
const MALFORMED_KEY: &str = "provider.antigravity.summary.schema";
const UNKNOWN_BUCKET_KEY: &str = "provider.antigravity.summary.unknown-bucket";
const MISSING_FRACTION_KEY: &str = "provider.antigravity.summary.missing-fraction";
const MISSING_BUCKETS_KEY: &str = "provider.antigravity.summary.missing-buckets";
const DUPLICATE_BUCKET_KEY: &str = "provider.antigravity.summary.duplicate-bucket";
const ALL_SUMMARY_KEYS: [&str; 6] =
    [ARGON_KEY, MALFORMED_KEY, UNKNOWN_BUCKET_KEY, MISSING_FRACTION_KEY, MISSING_BUCKETS_KEY, DUPLICATE_BUCKET_KEY];

/// Internal/duplicate model IDs that should never surface as a meter.
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

fn diag_key(key: &str, source_id: &str) -> String {
    format!("{key}.{}", stable_fingerprint(source_id))
}

fn warn_once(key: String, message: &'static str) {
    diagnostic_gate::log_once(&key, || qlog!(Warn, plugin_tag(ID), "{message}"));
}

/// `RetrieveUserQuotaSummary` → up to five meters, ordered Session, Weekly, Argon Weekly, Claude,
/// Claude Weekly. Accepts both the LS envelope and the bare remote payload.
pub fn parse_quota_summary(data: &[u8], source_id: &str) -> Option<Vec<MetricLine>> {
    parse_quota_summary_result(data, source_id).map(|r| r.lines)
}

pub fn parse_quota_summary_result(data: &[u8], source_id: &str) -> Option<QuotaSummaryResult> {
    let malformed = diag_key(MALFORMED_KEY, source_id);
    let unknown_key = diag_key(UNKNOWN_BUCKET_KEY, source_id);
    let fraction_key = diag_key(MISSING_FRACTION_KEY, source_id);
    let duplicate_key = diag_key(DUPLICATE_BUCKET_KEY, source_id);
    let Some(groups) = summary::decode_groups(data) else {
        // Callers only parse 2xx bodies, so an undecodable one is schema drift — say so loudly.
        warn_once(malformed, "quota summary response has no decodable groups; treating as not-a-summary");
        return None;
    };
    diagnostic_gate::clear(&malformed);

    let mut pooled: BTreeMap<&'static str, (f64, Option<f64>)> = BTreeMap::new();
    let (mut saw_unknown, mut saw_missing_fraction, mut saw_duplicate) = (false, false, false);
    let saw_missing_buckets = groups.iter().any(|g| !g.has_buckets);
    let non_argon: Vec<&SummaryGroup> =
        groups.iter().filter(|g| g.display_name.as_deref() != Some(ARGON_GROUP_NAME)).collect();
    for bucket in non_argon.iter().flat_map(|g| g.buckets.iter().flatten()) {
        let Some(spec) = bucket.bucket_id.as_deref().and_then(|id| SUMMARY_BUCKETS.iter().find(|s| s.bucket_id == id)) else {
            saw_unknown = true;
            continue;
        };
        let Some(fraction) = bucket.remaining_fraction.filter(|f| f.is_finite()) else {
            saw_missing_fraction = true;
            continue;
        };
        let reset = bucket.reset_time.as_deref().and_then(parse_iso8601);
        match pooled.get(spec.bucket_id) {
            Some((existing, _)) => {
                saw_duplicate = true;
                if fraction < *existing {
                    pooled.insert(spec.bucket_id, (fraction, reset));
                }
            }
            None => {
                pooled.insert(spec.bucket_id, (fraction, reset));
            }
        }
    }

    gate(saw_unknown, unknown_key, "quota summary contains unrecognized bucket IDs; skipping them");
    gate(saw_missing_fraction, fraction_key, "quota summary bucket has no usable remainingFraction; dropping its line");
    gate(
        saw_missing_buckets,
        diag_key(MISSING_BUCKETS_KEY, source_id),
        "quota summary group has no buckets array; retaining omitted meters until a complete response arrives",
    );
    gate(saw_duplicate, duplicate_key, "quota summary contains duplicate bucket IDs; keeping the most depleted value");

    let mut lines: Vec<MetricLine> = SUMMARY_BUCKETS
        .iter()
        .filter_map(|spec| pooled.get(spec.bucket_id).map(|(fraction, reset)| line(spec.label, *fraction, *reset, spec.period_ms)))
        .collect();
    let (argon_line, argon_complete) = summary::argon_weekly_result(&groups);
    let argon_key = diag_key(ARGON_KEY, source_id);
    if argon_complete {
        diagnostic_gate::clear(&argon_key);
    } else {
        warn_once(argon_key, "Argon quota has an ambiguous or unusable weekly bucket; retaining omitted meters");
    }
    if let Some(argon) = argon_line {
        let index = lines
            .iter()
            .position(|l| l.label() == metric::CLAUDE_LABEL || l.label() == metric::CLAUDE_WEEKLY_LABEL)
            .unwrap_or(lines.len());
        lines.insert(index, argon);
    }
    Some(QuotaSummaryResult {
        lines,
        is_complete: argon_complete && !saw_unknown && !saw_missing_fraction && !saw_missing_buckets && !saw_duplicate,
    })
}

fn gate(condition: bool, key: String, message: &'static str) {
    if condition {
        warn_once(key, message);
    } else {
        diagnostic_gate::clear(&key);
    }
}

pub fn clear_quota_summary_diagnostics(source_id: &str) {
    for key in ALL_SUMMARY_KEYS {
        diagnostic_gate::clear(&diag_key(key, source_id));
    }
}

// MARK: - Wire types (the documented response shapes; validated only at this boundary)

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct QuotaInfo {
    remaining_fraction: Option<f64>,
    reset_time: Option<String>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct ModelOrAlias {
    model: Option<String>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct LsModelConfig {
    label: Option<String>,
    model_or_alias: Option<ModelOrAlias>,
    quota_info: Option<QuotaInfo>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct Tier {
    id: Option<String>,
    name: Option<String>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct PlanInfo {
    plan_name: Option<String>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct PlanStatus {
    plan_info: Option<PlanInfo>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct CascadeData {
    client_model_configs: Option<Vec<LsModelConfig>>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct UserStatus {
    user_tier: Option<Tier>,
    plan_status: Option<PlanStatus>,
    cascade_model_config_data: Option<CascadeData>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct UserStatusEnvelope {
    user_status: Option<UserStatus>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct CommandConfigsEnvelope {
    client_model_configs: Option<Vec<LsModelConfig>>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct CcModel {
    model: Option<String>,
    display_name: Option<String>,
    label: Option<String>,
    is_internal: Option<bool>,
    quota_info: Option<QuotaInfo>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct CcModelsEnvelope {
    models: Option<BTreeMap<String, CcModel>>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct CcLoadEnvelope {
    cloudaicompanion_project: Option<String>,
    current_tier: Option<Tier>,
    paid_tier: Option<Tier>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct CcBucket {
    model_id: Option<String>,
    remaining_fraction: Option<f64>,
    reset_time: Option<String>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct CcQuotaEnvelope {
    buckets: Option<Vec<CcBucket>>,
}

fn non_empty(value: Option<String>) -> Option<String> {
    value.filter(|v| !v.is_empty())
}

// MARK: - Response parsing (legacy per-model endpoints)

/// LS `GetUserStatus` → plan name + model configs. `None` when the body has no `userStatus`.
pub fn parse_user_status(data: &[u8]) -> Option<(Option<String>, Vec<ModelConfig>)> {
    let envelope: UserStatusEnvelope = serde_json::from_slice(data).ok()?;
    let status = envelope.user_status?;
    // Prefer Google's own `userTier` over the Windsurf-inherited `planInfo.planName` (which reads
    // "Pro" for every paid tier).
    let raw_plan = status
        .user_tier
        .and_then(|t| t.name)
        .or(status.plan_status.and_then(|p| p.plan_info).and_then(|i| i.plan_name));
    let plan = format_plan(raw_plan.as_deref());
    let configs = status
        .cascade_model_config_data
        .and_then(|c| c.client_model_configs)
        .unwrap_or_default()
        .into_iter()
        .filter_map(config_from_ls)
        .collect();
    Some((plan, configs))
}

/// LS `GetCommandModelConfigs` fallback → model configs only (no plan). `None` when absent.
pub fn parse_command_model_configs(data: &[u8]) -> Option<Vec<ModelConfig>> {
    let envelope: CommandConfigsEnvelope = serde_json::from_slice(data).ok()?;
    Some(envelope.client_model_configs?.into_iter().filter_map(config_from_ls).collect())
}

/// Cloud Code `fetchAvailableModels` → model configs (drops `isInternal`, empty-label models).
pub fn parse_cloud_code_models(data: &[u8]) -> Vec<ModelConfig> {
    let Ok(envelope) = serde_json::from_slice::<CcModelsEnvelope>(data) else { return Vec::new() };
    let Some(models) = envelope.models else { return Vec::new() };
    models
        .into_iter()
        .filter_map(|(key, model)| {
            if model.is_internal == Some(true) {
                return None;
            }
            let label = non_empty(model.display_name).or(non_empty(model.label))?;
            config(Some(label), non_empty(model.model).or(Some(key)), model.quota_info)
        })
        .collect()
}

/// Cloud Code `retrieveUserQuota` → buckets keyed by raw model id.
pub fn parse_quota_buckets(data: &[u8]) -> Vec<ModelConfig> {
    let Ok(envelope) = serde_json::from_slice::<CcQuotaEnvelope>(data) else { return Vec::new() };
    envelope
        .buckets
        .unwrap_or_default()
        .into_iter()
        .filter_map(|bucket| {
            let id = non_empty(bucket.model_id)?;
            Some(ModelConfig {
                label: id.clone(),
                model_id: Some(id),
                remaining_fraction: bucket.remaining_fraction.unwrap_or(0.0),
                reset_time: bucket.reset_time.as_deref().and_then(parse_iso8601),
            })
        })
        .collect()
}

/// Cloud Code `loadCodeAssist` → plan name (paid tier preferred over current tier).
pub fn parse_load_code_assist_plan(data: &[u8]) -> Option<String> {
    let envelope: CcLoadEnvelope = serde_json::from_slice(data).ok()?;
    if let Some(plan) = envelope.paid_tier.as_ref().and_then(|t| t.id.as_deref()).and_then(|id| match id {
        "g1-pro-tier" => Some("Pro"),
        "g1-ultra-tier" => Some("Ultra"),
        "g1-ultra-lite-tier" => Some("Ultra Lite"),
        _ => None,
    }) {
        return Some(plan.to_string());
    }
    let raw = envelope.paid_tier.and_then(|t| t.name).or(envelope.current_tier.and_then(|t| t.name));
    format_plan(raw.as_deref())
}

pub fn parse_project(data: &[u8]) -> Option<String> {
    serde_json::from_slice::<CcLoadEnvelope>(data).ok()?.cloudaicompanion_project.filter(|p| !p.is_empty())
}

// MARK: - Line building (legacy pooling)

/// Collapse model configs into the two quota-pool meters, keeping the worst fraction per pool and
/// ordering the Gemini pool ("Session") before Claude. Blacklisted, empty-label and Argon models
/// are dropped.
pub fn build_lines(configs: &[ModelConfig]) -> Vec<MetricLine> {
    let mut pooled: BTreeMap<String, (f64, Option<f64>)> = BTreeMap::new();
    for config in configs {
        let label = config.label.trim_matches([' ', '\t']).to_string();
        if label.is_empty() {
            continue;
        }
        if config.model_id.as_deref().is_some_and(|id| MODEL_BLACKLIST.contains(&id)) {
            continue;
        }
        if summary::is_argon_model(&label, config.model_id.as_deref()) {
            continue;
        }
        let pool = pool_label(&normalize_label(&label));
        match pooled.get(&pool) {
            // Worst-case wins; ties keep the first seen.
            Some((existing, _)) if config.remaining_fraction >= *existing => {}
            _ => {
                pooled.insert(pool, (config.remaining_fraction, config.reset_time));
            }
        }
    }
    let mut entries: Vec<(String, (f64, Option<f64>))> = pooled.into_iter().collect();
    entries.sort_by_key(|(pool, _)| sort_key(pool));
    entries.into_iter().map(|(pool, (fraction, reset))| line(&pool, fraction, reset, SESSION_MS)).collect()
}

pub fn line(pool: &str, fraction: f64, reset_time: Option<f64>, period_ms: i64) -> MetricLine {
    let clamped = fraction.clamp(0.0, 1.0);
    // Raw percent, not rounded: the headline rounds at display time, and `isFreshSessionWindow`
    // keys its "Not started" claim off `used == 0` exactly.
    MetricLine::percent_progress(pool, (1.0 - clamped) * 100.0, reset_time, Some(period_ms))
}

// MARK: - Pooling helpers (pure)

/// "Gemini 3 Pro (High)" → "Gemini 3 Pro" — strip a trailing parenthetical variant
/// (`\s*\([^)]*\)\s*$`), then trim surrounding blanks.
pub fn normalize_label(label: &str) -> String {
    let trimmed_end = label.trim_end();
    if let Some(body) = trimmed_end.strip_suffix(')') {
        // Leftmost '(' with no ')' after it: the regex's leftmost match start.
        let start = body.rfind(')').map_or(0, |close| close + 1);
        if let Some(open) = body[start..].find('(') {
            return body[..start + open].trim_matches([' ', '\t']).to_string();
        }
    }
    label.trim_matches([' ', '\t']).to_string()
}

pub fn pool_label(normalized_label: &str) -> String {
    // Pro and Flash draw from one shared pool since Antigravity's 2026-05-19 quota merge, so every
    // Gemini model maps to the single "Session" meter; everything else shares the other pool.
    if normalized_label.to_lowercase().contains("gemini") {
        metric::SESSION_LABEL.to_string()
    } else {
        metric::CLAUDE_LABEL.to_string()
    }
}

pub fn sort_key(pool_label: &str) -> String {
    if pool_label == metric::SESSION_LABEL {
        format!("0_{pool_label}")
    } else {
        format!("1_{pool_label}")
    }
}

/// Normalize a raw plan/tier string to a short label. LS returns "Google AI Pro" (strip the prefix,
/// keep the tail); Cloud Code returns "Gemini Code Assist in Google One AI Pro" (pull the tier word).
pub fn format_plan(raw: Option<&str>) -> Option<String> {
    let trimmed = raw?.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Some(rest) = trimmed.strip_prefix("Google AI ") {
        return Some(title_cased(rest));
    }
    let lower = trimmed.to_lowercase();
    for keyword in ["Ultra", "Pro", "Free"] {
        if lower.contains(&keyword.to_lowercase()) {
            return Some(keyword.to_string());
        }
    }
    Some(title_cased(trimmed))
}

/// Swift `titleCased(separator: \.isWhitespace)`: uppercase each word's first character, keep the
/// rest, re-join with single spaces.
fn title_cased(text: &str) -> String {
    text.split(char::is_whitespace)
        .filter(|word| !word.is_empty())
        .map(|word| {
            let mut chars = word.chars();
            let head: String = chars.next().map(|c| c.to_uppercase().collect()).unwrap_or_default();
            format!("{head}{}", chars.as_str())
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn config_from_ls(model: LsModelConfig) -> Option<ModelConfig> {
    config(model.label, model.model_or_alias.and_then(|m| m.model), model.quota_info)
}

fn config(label: Option<String>, model_id: Option<String>, quota: Option<QuotaInfo>) -> Option<ModelConfig> {
    let label = label.map(|l| l.trim_matches([' ', '\t']).to_string()).filter(|l| !l.is_empty())?;
    let quota = quota.unwrap_or_default();
    Some(ModelConfig {
        label,
        model_id,
        remaining_fraction: quota.remaining_fraction.unwrap_or(0.0),
        reset_time: quota.reset_time.as_deref().and_then(parse_iso8601),
    })
}
