//! Normalized provider output — the wire twin of the Swift `ProviderSnapshot` / `MetricLine`
//! `Codable` types (Sources/QuotaBar/Models). Field names and optionality match the Swift synthesized
//! coding keys exactly so the macOS app decodes engine output with its existing decoders; dates
//! cross the boundary as `f64` seconds since 1970 (`JSONDecoder.DateDecodingStrategy.secondsSince1970`).
//!
//! Every `f64` that reaches JSON must be finite: Swift's decoder rejects `null` where it expects a
//! number, and serde_json writes non-finite floats as `null`.

use serde::de::Error as _;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::collections::{BTreeMap, BTreeSet};

/// Seconds since 1970-01-01T00:00:00Z.
pub type Timestamp = f64;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MetricKind {
    Percent,
    Dollars,
    Count,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum ProgressFormat {
    Percent,
    Dollars,
    Currency(String),
    Count(String),
}

#[derive(Serialize, Deserialize)]
struct ProgressFormatWire {
    kind: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    suffix: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    code: Option<String>,
}

impl Serialize for ProgressFormat {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        // Mirrors Swift: a currency format is written as kind "dollars" plus a code so older readers
        // of the shared snapshot cache still decode it.
        let wire = match self {
            ProgressFormat::Percent => ProgressFormatWire { kind: "percent".into(), suffix: None, code: None },
            ProgressFormat::Dollars => ProgressFormatWire { kind: "dollars".into(), suffix: None, code: None },
            ProgressFormat::Currency(code) => {
                ProgressFormatWire { kind: "dollars".into(), suffix: None, code: Some(code.clone()) }
            }
            ProgressFormat::Count(suffix) => {
                ProgressFormatWire { kind: "count".into(), suffix: Some(suffix.clone()), code: None }
            }
        };
        wire.serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for ProgressFormat {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let wire = ProgressFormatWire::deserialize(deserializer)?;
        match wire.kind.as_str() {
            "percent" => Ok(ProgressFormat::Percent),
            "dollars" => Ok(match wire.code {
                Some(code) => ProgressFormat::Currency(code),
                None => ProgressFormat::Dollars,
            }),
            "currency" => wire
                .code
                .map(ProgressFormat::Currency)
                .ok_or_else(|| D::Error::missing_field("code")),
            "count" => wire
                .suffix
                .map(ProgressFormat::Count)
                .ok_or_else(|| D::Error::missing_field("suffix")),
            other => Err(D::Error::unknown_variant(other, &["percent", "dollars", "currency", "count"])),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MetricValue {
    pub number: f64,
    pub kind: MetricKind,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub label: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub currency_code: Option<String>,
    pub estimated: bool,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub is_partial: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub token_count_saturated: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub is_lower_bound: Option<bool>,
}

impl MetricValue {
    pub fn new(number: f64, kind: MetricKind) -> Self {
        MetricValue {
            number: finite(number),
            kind,
            label: None,
            currency_code: None,
            estimated: false,
            is_partial: None,
            token_count_saturated: None,
            is_lower_bound: None,
        }
    }

    pub fn with_label(mut self, label: impl Into<String>) -> Self {
        self.label = Some(label.into());
        self
    }

    pub fn with_estimated(mut self, estimated: bool) -> Self {
        self.estimated = estimated;
        self
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MetricChartPoint {
    pub value: f64,
    pub label: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub value_label: Option<String>,
}

fn is_false_or_empty<T>(v: &[T]) -> bool {
    v.is_empty()
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase", rename_all_fields = "camelCase")]
pub enum MetricLine {
    Text {
        label: String,
        value: String,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        color_hex: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        subtitle: Option<String>,
    },
    Chart {
        label: String,
        points: Vec<MetricChartPoint>,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        note: Option<String>,
    },
    Values {
        label: String,
        values: Vec<MetricValue>,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        color_hex: Option<String>,
        #[serde(skip_serializing_if = "is_false_or_empty", default)]
        expiries_at: Vec<Timestamp>,
        #[serde(skip_serializing_if = "is_false_or_empty", default)]
        unknown_models: Vec<String>,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        model_breakdown: Option<ModelUsageBreakdown>,
    },
    Progress {
        label: String,
        used: f64,
        limit: f64,
        format: ProgressFormat,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        resets_at: Option<Timestamp>,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        period_duration_ms: Option<i64>,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        color_hex: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        detail: Option<String>,
    },
    Badge {
        label: String,
        text: String,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        color_hex: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        subtitle: Option<String>,
    },
}

impl MetricLine {
    pub const ERROR_BADGE_LABEL: &'static str = "Error";

    pub fn label(&self) -> &str {
        match self {
            MetricLine::Text { label, .. }
            | MetricLine::Chart { label, .. }
            | MetricLine::Values { label, .. }
            | MetricLine::Progress { label, .. }
            | MetricLine::Badge { label, .. } => label,
        }
    }

    pub fn badge(label: &str, text: &str, color_hex: Option<&str>) -> Self {
        MetricLine::Badge {
            label: label.to_string(),
            text: text.to_string(),
            color_hex: color_hex.map(str::to_string),
            subtitle: None,
        }
    }

    /// The shared "no usage data" placeholder (Swift `MetricLine.noUsageData`).
    pub fn no_usage_data() -> Self {
        MetricLine::badge("Status", "No usage data", Some("#A3A3A3"))
    }

    pub fn append_no_data_if_needed(lines: &mut Vec<MetricLine>) {
        if lines.is_empty() {
            lines.push(MetricLine::no_usage_data());
        }
    }

    pub fn values(label: &str, values: Vec<MetricValue>) -> Self {
        MetricLine::Values {
            label: label.to_string(),
            values,
            color_hex: None,
            expiries_at: Vec::new(),
            unknown_models: Vec::new(),
            model_breakdown: None,
        }
    }

    pub fn percent_progress(label: &str, used: f64, resets_at: Option<Timestamp>, period_ms: Option<i64>) -> Self {
        MetricLine::Progress {
            label: label.to_string(),
            used: finite(used),
            limit: 100.0,
            format: ProgressFormat::Percent,
            resets_at,
            period_duration_ms: period_ms,
            color_hex: None,
            detail: None,
        }
    }

    pub fn is_progress(&self) -> bool {
        matches!(self, MetricLine::Progress { .. })
    }
}

// ---------------------------------------------------------------------------------------------
// Usage history (Swift `ProviderUsageHistory` and friends in Models/DailyUsageSeries.swift).
// ---------------------------------------------------------------------------------------------

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReportedUsageCost {
    pub dollars: f64,
    pub covered_tokens: i64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", from = "DailyUsageEntryWire")]
pub struct DailyUsageEntry {
    pub date: String,
    pub total_tokens: i64,
    #[serde(rename = "costUSD", skip_serializing_if = "Option::is_none", default)]
    pub cost_usd: Option<f64>,
    pub cost_is_complete: bool,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub has_unexplained_incomplete_cost: Option<bool>,
    pub token_count_saturated: bool,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub reported_cost: Option<ReportedUsageCost>,
}

/// Decode shape of [`DailyUsageEntry`] with the Swift decoder's legacy defaults: a persisted day
/// without a coverage bit is treated as incomplete, and one without a saturation marker is saturated
/// only when its total is exactly `Int.max`.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DailyUsageEntryWire {
    date: String,
    total_tokens: i64,
    #[serde(rename = "costUSD", default)]
    cost_usd: Option<f64>,
    #[serde(default)]
    cost_is_complete: Option<bool>,
    #[serde(default)]
    has_unexplained_incomplete_cost: Option<bool>,
    #[serde(default)]
    token_count_saturated: Option<bool>,
    #[serde(default)]
    reported_cost: Option<ReportedUsageCost>,
}

impl From<DailyUsageEntryWire> for DailyUsageEntry {
    fn from(wire: DailyUsageEntryWire) -> Self {
        DailyUsageEntry {
            token_count_saturated: wire.token_count_saturated.unwrap_or(wire.total_tokens == i64::MAX),
            cost_is_complete: wire.cost_is_complete.unwrap_or(false),
            date: wire.date,
            total_tokens: wire.total_tokens,
            cost_usd: wire.cost_usd,
            has_unexplained_incomplete_cost: wire.has_unexplained_incomplete_cost,
            reported_cost: wire.reported_cost,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct DailyUsageSeries {
    pub daily: Vec<DailyUsageEntry>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelUsageVariant {
    pub model: String,
    pub total_tokens: i64,
    #[serde(rename = "costUSD", skip_serializing_if = "Option::is_none", default)]
    pub cost_usd: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub cost_is_complete: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub token_count_saturated: Option<bool>,
}

impl ModelUsageVariant {
    pub fn has_incomplete_cost(&self) -> bool {
        match self.cost_is_complete {
            Some(complete) => !complete,
            None => self.total_tokens > 0 && self.cost_usd.is_none(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelUsageEntry {
    pub model: String,
    pub total_tokens: i64,
    #[serde(rename = "costUSD", skip_serializing_if = "Option::is_none", default)]
    pub cost_usd: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub variants: Option<Vec<ModelUsageVariant>>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub cost_is_complete: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub token_count_saturated: Option<bool>,
}

impl ModelUsageEntry {
    pub const UNATTRIBUTED: &'static str = "Unattributed";
    pub const OTHER: &'static str = "Other";

    pub fn has_incomplete_cost(&self) -> bool {
        match self.cost_is_complete {
            Some(complete) => !complete,
            None => self.total_tokens > 0 && self.cost_usd.is_none(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct DailyModelUsageEntry {
    pub date: String,
    pub models: Vec<ModelUsageEntry>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct ModelUsageSeries {
    pub daily: Vec<DailyModelUsageEntry>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelUsageBreakdown {
    pub total_tokens: i64,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub token_count_saturated: Option<bool>,
    #[serde(rename = "totalCostUSD", skip_serializing_if = "Option::is_none", default)]
    pub total_cost_usd: Option<f64>,
    pub models: Vec<ModelUsageEntry>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub source_note: Option<String>,
}

/// Swift `ProviderUsageHistory`. The Swift decoder re-runs its normalizing initializer
/// (`markingNamedUnknownCostsIncomplete`, `classifyingLegacyIncompleteDays`), so the engine emits
/// the raw fold result and both platforms normalize identically.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderUsageHistory {
    pub series: DailyUsageSeries,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub model_usage: Option<ModelUsageSeries>,
    #[serde(default)]
    pub unknown_models_by_day: BTreeMap<String, BTreeSet<String>>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub api_estimate_by_day: Option<BTreeMap<String, f64>>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub api_estimate_incomplete_days: Option<BTreeSet<String>>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub partial_days: Option<BTreeSet<String>>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub estimated_cost_days: Option<BTreeSet<String>>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActiveSession {
    #[serde(rename = "instanceID")]
    pub instance_id: String,
    pub expires_at: Timestamp,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub model: Option<String>,
    #[serde(rename = "threadID", skip_serializing_if = "Option::is_none", default)]
    pub thread_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub chat_title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub project_path: Option<String>,
}

/// Stable, non-PII failure buckets (Swift `ErrorCategory` raw values).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCategory {
    NotLoggedIn,
    AuthExpired,
    AuthInvalid,
    CredentialAccess,
    Network,
    Decoding,
    #[serde(rename = "http_4xx")]
    Http4xx,
    #[serde(rename = "http_5xx")]
    Http5xx,
    RateLimited,
    NotAvailable,
    Cancelled,
    Other,
}

impl ErrorCategory {
    pub fn http(status: u16) -> Self {
        match status {
            429 => ErrorCategory::RateLimited,
            400..=499 => ErrorCategory::Http4xx,
            500..=599 => ErrorCategory::Http5xx,
            _ => ErrorCategory::Other,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderSnapshot {
    #[serde(rename = "providerID")]
    pub provider_id: String,
    pub display_name: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub plan: Option<String>,
    pub lines: Vec<MetricLine>,
    pub refreshed_at: Timestamp,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub usage_history: Option<ProviderUsageHistory>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub warning: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub history_warning: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub clears_prior_menu_bar_quota_state: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub replaces_prior_quota_progress: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub invalidates_quota_identity: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub carries_prior_history: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub quota_refreshed_at: Option<Timestamp>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub history_refreshed_at: Option<Timestamp>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub error_category: Option<ErrorCategory>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub active_sessions: Option<Vec<ActiveSession>>,
}

/// Provider identity used to stamp snapshots (Swift `Provider.id` / `displayName`).
#[derive(Clone, Debug)]
pub struct ProviderInfo {
    pub id: String,
    pub display_name: String,
}

impl ProviderSnapshot {
    /// Swift `ProviderSnapshot.init`: a provider-produced snapshot assumes its meters are live; the
    /// history stamp exists only when this refresh computed history.
    pub fn new(info: &ProviderInfo, plan: Option<String>, lines: Vec<MetricLine>, refreshed_at: Timestamp) -> Self {
        ProviderSnapshot {
            provider_id: info.id.clone(),
            display_name: info.display_name.clone(),
            plan,
            lines,
            refreshed_at,
            usage_history: None,
            warning: None,
            history_warning: None,
            clears_prior_menu_bar_quota_state: None,
            replaces_prior_quota_progress: None,
            invalidates_quota_identity: None,
            carries_prior_history: None,
            quota_refreshed_at: Some(refreshed_at),
            history_refreshed_at: None,
            error_category: None,
            active_sessions: None,
        }
    }

    pub fn with_usage_history(mut self, history: Option<ProviderUsageHistory>) -> Self {
        self.history_refreshed_at = history.as_ref().map(|_| self.refreshed_at);
        self.usage_history = history;
        self
    }

    /// Swift `ProviderSnapshot.error(provider:message:category:)`.
    pub fn error(info: &ProviderInfo, message: &str, category: ErrorCategory, now: Timestamp) -> Self {
        let mut snapshot = ProviderSnapshot::new(
            info,
            None,
            vec![MetricLine::badge(MetricLine::ERROR_BADGE_LABEL, message, Some("#EF4444"))],
            now,
        );
        snapshot.error_category = Some(category);
        snapshot
    }

    pub fn is_error(&self) -> bool {
        self.error_category.is_some()
            || self.lines.iter().any(|l| matches!(l, MetricLine::Badge { label, .. } if label == MetricLine::ERROR_BADGE_LABEL))
    }
}

/// Clamp NaN/inf to zero so the value always serializes as a JSON number.
pub fn finite(value: f64) -> f64 {
    if value.is_finite() {
        value
    } else {
        0.0
    }
}

/// Swift `ProviderParse.clampPercent`.
pub fn clamp_percent(value: f64) -> f64 {
    if !value.is_finite() {
        return 0.0;
    }
    value.clamp(0.0, 100.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn metric_line_wire_shape_matches_swift_coding_keys() {
        let line = MetricLine::Progress {
            label: "Weekly quota".into(),
            used: 12.5,
            limit: 100.0,
            format: ProgressFormat::Percent,
            resets_at: Some(1_800_000_000.0),
            period_duration_ms: Some(604_800_000),
            color_hex: None,
            detail: None,
        };
        let json = serde_json::to_value(&line).unwrap();
        assert_eq!(
            json,
            serde_json::json!({
                "type": "progress", "label": "Weekly quota", "used": 12.5, "limit": 100.0,
                "format": {"kind": "percent"}, "resetsAt": 1_800_000_000.0, "periodDurationMs": 604_800_000
            })
        );
        let values = MetricLine::values("Extra usage balance", vec![MetricValue::new(3.5, MetricKind::Dollars)]);
        assert_eq!(
            serde_json::to_value(&values).unwrap(),
            serde_json::json!({"type": "values", "label": "Extra usage balance",
                "values": [{"number": 3.5, "kind": "dollars", "estimated": false}]})
        );
        let currency = serde_json::to_value(ProgressFormat::Currency("EUR".into())).unwrap();
        assert_eq!(currency, serde_json::json!({"kind": "dollars", "code": "EUR"}));
        let round: ProgressFormat = serde_json::from_value(currency).unwrap();
        assert_eq!(round, ProgressFormat::Currency("EUR".into()));
    }

    #[test]
    fn snapshot_uses_swift_key_spellings() {
        let info = ProviderInfo { id: "devin".into(), display_name: "Devin".into() };
        let snap = ProviderSnapshot::error(&info, "boom", ErrorCategory::Http5xx, 10.0);
        let json = serde_json::to_value(&snap).unwrap();
        assert_eq!(json["providerID"], "devin");
        assert_eq!(json["displayName"], "Devin");
        assert_eq!(json["errorCategory"], "http_5xx");
        assert_eq!(json["quotaRefreshedAt"], 10.0);
        assert!(json.get("historyRefreshedAt").is_none());
        let entry = DailyUsageEntry {
            date: "2026-11-23".into(),
            total_tokens: 5,
            cost_usd: Some(1.0),
            cost_is_complete: true,
            has_unexplained_incomplete_cost: None,
            token_count_saturated: false,
            reported_cost: None,
        };
        let json = serde_json::to_value(&entry).unwrap();
        assert_eq!(json["costUSD"], 1.0);
        assert_eq!(json["totalTokens"], 5);
    }
}
