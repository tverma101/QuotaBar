//! `RetrieveUserQuotaSummary` decoding (Swift `AntigravityQuotaSummary.swift`), both envelopes: the
//! LS wraps the payload in `{"response": {...}}`, the remote Cloud Code endpoint returns it bare.
//! Every field is optional — third-party parsers have already regressed by assuming absent fields
//! (defaulting a missing `remainingFraction` to "full"). The decoding below reproduces Swift's
//! `Decodable` leniency exactly: a malformed bucket decodes to nil fields rather than failing the
//! whole summary, while a wrongly typed `response`/`groups` rejects the document.

use super::mapper::{self, QuotaSummaryResult, SUMMARY_BUCKETS};
use super::metric;
use crate::model::MetricLine;
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

pub const ARGON_GROUP_NAME: &str = "Gemini 4 Argon";

#[derive(Clone, Debug, Default)]
pub struct SummaryBucket {
    pub bucket_id: Option<String>,
    pub remaining_fraction: Option<f64>,
    pub reset_time: Option<String>,
    pub window: Option<String>,
    pub disabled: Option<bool>,
    pub has_invalid_disabled_flag: bool,
}

#[derive(Clone, Debug, Default)]
pub struct SummaryGroup {
    pub display_name: Option<String>,
    pub buckets: Option<Vec<SummaryBucket>>,
    /// Missing and explicit-null are schema gaps; an explicit empty array is an authoritative answer.
    pub has_buckets: bool,
}

fn decode_bucket(value: &Value) -> SummaryBucket {
    let Some(object) = value.as_object() else { return SummaryBucket::default() };
    let string = |key: &str| object.get(key).and_then(Value::as_str).map(str::to_string);
    let number = |key: &str| object.get(key).and_then(Value::as_f64);
    let (disabled, invalid) = match object.get("disabled") {
        None | Some(Value::Null) => (None, false),
        Some(Value::Bool(flag)) => (Some(*flag), false),
        Some(_) => (None, true),
    };
    SummaryBucket {
        bucket_id: string("bucketId"),
        remaining_fraction: number("remainingFraction"),
        reset_time: string("resetTime"),
        window: string("window"),
        disabled,
        has_invalid_disabled_flag: invalid,
    }
}

fn decode_group(value: &Value) -> SummaryGroup {
    let Some(object) = value.as_object() else { return SummaryGroup::default() };
    let display_name = object.get("displayName").and_then(Value::as_str).map(str::to_string);
    match object.get("buckets") {
        Some(Value::Array(items)) => SummaryGroup {
            display_name,
            buckets: Some(items.iter().map(decode_bucket).collect()),
            has_buckets: true,
        },
        _ => SummaryGroup { display_name, buckets: None, has_buckets: false },
    }
}

/// `envelope.response?.groups ?? envelope.groups`; `None` when the body is not a decodable summary.
pub fn decode_groups(body: &[u8]) -> Option<Vec<SummaryGroup>> {
    let root: Value = serde_json::from_slice(body).ok()?;
    let object = root.as_object()?;
    let groups_of = |value: &Value| -> Result<Option<Vec<SummaryGroup>>, ()> {
        match value {
            Value::Null => Ok(None),
            Value::Array(items) => Ok(Some(items.iter().map(decode_group).collect())),
            _ => Err(()),
        }
    };
    let response_groups = match object.get("response") {
        None | Some(Value::Null) => None,
        Some(Value::Object(response)) => match response.get("groups") {
            None => None,
            Some(value) => groups_of(value).ok()?,
        },
        Some(_) => return None,
    };
    let bare_groups = match object.get("groups") {
        None => None,
        Some(value) => groups_of(value).ok()?,
    };
    response_groups.or(bare_groups)
}

pub fn has_all_shared_quota_meters(body: &[u8], source_id: &str) -> bool {
    let Some(result) = mapper::parse_quota_summary_result(body, source_id) else { return false };
    let labels: BTreeSet<&str> = result.lines.iter().map(MetricLine::label).collect();
    SUMMARY_BUCKETS.iter().all(|spec| labels.contains(spec.label))
}

/// Keep the first usable value for a meter across hosts. Duplicates within one body still use the
/// conservative parser policy. Only wholly readable responses can clear old omitted limits.
pub fn parse_quota_summaries_result(bodies: &[Vec<u8>], all_hosts_answered: bool) -> Option<QuotaSummaryResult> {
    let results: Vec<QuotaSummaryResult> = bodies
        .iter()
        .enumerate()
        .filter_map(|(index, body)| mapper::parse_quota_summary_result(body, &format!("cloud-code-{index}")))
        .collect();
    if results.is_empty() {
        return None;
    }
    let mut first_by_label: BTreeMap<String, MetricLine> = BTreeMap::new();
    for result in &results {
        for line in &result.lines {
            first_by_label.entry(line.label().to_string()).or_insert_with(|| line.clone());
        }
    }
    let ordered = [
        metric::SESSION_LABEL,
        metric::WEEKLY_LABEL,
        metric::ARGON_WEEKLY_LABEL,
        metric::CLAUDE_LABEL,
        metric::CLAUDE_WEEKLY_LABEL,
    ];
    Some(QuotaSummaryResult {
        lines: ordered.iter().filter_map(|label| first_by_label.get(*label).cloned()).collect(),
        is_complete: all_hosts_answered && results.len() == bodies.len() && results.iter().all(|r| r.is_complete),
    })
}

/// An absent or explicitly disabled quota is authoritative. Ambiguous shapes retain last-good
/// meters through the summary's existing completeness policy, rather than inventing a quota.
pub fn argon_weekly_result(groups: &[SummaryGroup]) -> (Option<MetricLine>, bool) {
    let argon: Vec<&SummaryGroup> = groups.iter().filter(|g| g.display_name.as_deref() == Some(ARGON_GROUP_NAME)).collect();
    if argon.is_empty() {
        return (None, true);
    }
    if !argon.iter().all(|g| g.has_buckets) {
        return (None, false);
    }
    let buckets: Vec<&SummaryBucket> = argon.iter().flat_map(|g| g.buckets.iter().flatten()).collect();
    if buckets.is_empty() {
        return (None, true);
    }
    let weekly: Vec<&&SummaryBucket> = buckets.iter().filter(|b| b.window.as_deref() == Some("weekly")).collect();
    if weekly.len() != 1 {
        return (None, false);
    }
    let bucket = weekly[0];
    let Some(id) = bucket.bucket_id.as_deref().filter(|id| !id.is_empty()) else { return (None, false) };
    if SUMMARY_BUCKETS.iter().any(|spec| spec.bucket_id == id) || bucket.has_invalid_disabled_flag {
        return (None, false);
    }
    if bucket.disabled == Some(true) {
        return (None, true);
    }
    let Some(fraction) = bucket.remaining_fraction.filter(|f| f.is_finite()) else { return (None, false) };
    let reset = bucket.reset_time.as_deref().and_then(crate::time::parse_iso8601);
    (
        Some(mapper::line(metric::ARGON_WEEKLY_LABEL, fraction, reset, metric::WEEK_MS)),
        buckets.iter().all(|b| matches!(b.window.as_deref(), Some("weekly") | Some("5h"))),
    )
}

pub fn is_argon_model(label: &str, model_id: Option<&str>) -> bool {
    if model_id == Some("MODEL_PLACEHOLDER_M421") {
        return true;
    }
    [mapper::normalize_label(label), model_id.unwrap_or("").to_string()].iter().any(|value| {
        let normalized = value.to_lowercase().replace(' ', "-");
        normalized == "gemini-4-argon" || normalized.starts_with("gemini-4-argon-")
    })
}
