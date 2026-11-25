//! Machine-readable limits export (`quotabar.limits.v1`).
//! Maps probe/cache progress lines into a stable JSON envelope for CLI + local HTTP.

use crate::plugin_engine::runtime::{MetricLine, PluginOutput, ProgressFormat};
use crate::usage_snapshot::CachedPluginSnapshot;
use chrono::{DateTime, Utc};
use serde::Serialize;
use std::collections::BTreeMap;

pub const LIMITS_SCHEMA: &str = "quotabar.limits.v1";

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LimitsDocument {
    pub schema: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub generated_at: Option<String>,
    pub providers: BTreeMap<String, ProviderLimits>,
    pub errors: Vec<LimitsError>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderLimits {
    pub display_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plan: Option<String>,
    pub resources: BTreeMap<String, ResourceLimit>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fetched_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stale: Option<bool>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResourceLimit {
    pub used: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub limit: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remaining: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub utilization: Option<f64>,
    pub unit: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resets_at: Option<String>,
    pub label: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LimitsError {
    pub provider_id: String,
    pub message: String,
}

/// Stable slug for a resource key from a progress line label.
pub fn resource_slug(label: &str) -> String {
    let mut out = String::new();
    let mut prev_dash = false;
    for ch in label.chars() {
        let c = ch.to_ascii_lowercase();
        if c.is_ascii_alphanumeric() {
            out.push(c);
            prev_dash = false;
        } else if !prev_dash && !out.is_empty() {
            out.push('-');
            prev_dash = true;
        }
    }
    while out.ends_with('-') {
        out.pop();
    }
    if out.is_empty() {
        "resource".to_string()
    } else {
        out
    }
}

fn unit_for_format(format: &ProgressFormat) -> String {
    match format {
        ProgressFormat::Percent => "percent".to_string(),
        ProgressFormat::Dollars => "dollars".to_string(),
        ProgressFormat::Count { suffix } => {
            if suffix.trim().is_empty() {
                "count".to_string()
            } else {
                format!("count:{suffix}")
            }
        }
    }
}

fn resource_from_progress(
    label: &str,
    used: f64,
    limit: f64,
    format: &ProgressFormat,
    resets_at: Option<&str>,
) -> ResourceLimit {
    let has_cap = limit.is_finite() && limit > 0.0;
    let utilization = if has_cap {
        Some((used / limit).clamp(0.0, 10.0))
    } else {
        None
    };
    let remaining = if has_cap {
        Some((limit - used).max(0.0))
    } else {
        None
    };
    ResourceLimit {
        used,
        limit: if has_cap { Some(limit) } else { None },
        remaining,
        utilization,
        unit: unit_for_format(format),
        resets_at: resets_at.map(str::to_string),
        label: label.to_string(),
    }
}

pub fn provider_limits_from_lines(
    display_name: &str,
    plan: Option<&str>,
    lines: &[MetricLine],
    fetched_at: Option<&str>,
    stale: Option<bool>,
) -> ProviderLimits {
    let mut resources = BTreeMap::new();
    for line in lines {
        if let MetricLine::Progress {
            label,
            used,
            limit,
            format,
            resets_at,
            ..
        } = line
        {
            let mut key = resource_slug(label);
            let mut n = 2;
            while resources.contains_key(&key) {
                key = format!("{}-{}", resource_slug(label), n);
                n += 1;
            }
            resources.insert(
                key,
                resource_from_progress(label, *used, *limit, format, resets_at.as_deref()),
            );
        }
    }
    ProviderLimits {
        display_name: display_name.to_string(),
        plan: plan.map(str::to_string),
        resources,
        fetched_at: fetched_at.map(str::to_string),
        expires_at: None,
        stale,
    }
}

pub fn limits_from_snapshots<'a>(
    snapshots: impl IntoIterator<Item = &'a CachedPluginSnapshot>,
    errors: Vec<LimitsError>,
    now: DateTime<Utc>,
) -> LimitsDocument {
    let providers = snapshots
        .into_iter()
        .map(|snapshot| {
            let mut provider = provider_limits_from_lines(
                &snapshot.display_name,
                snapshot.plan.as_deref(),
                &snapshot.lines,
                Some(&snapshot.fetched_at),
                Some(snapshot.is_stale(now)),
            );
            provider.expires_at = snapshot.expires_at()
                .map(|date| date.to_rfc3339_opts(chrono::SecondsFormat::Secs, true));
            (snapshot.provider_id.clone(), provider)
        })
        .collect();
    LimitsDocument {
        schema: LIMITS_SCHEMA.to_string(),
        generated_at: Some(now.to_rfc3339()),
        providers,
        errors,
    }
}

pub fn probe_error_message(output: &PluginOutput) -> Option<&str> {
    output.lines.iter().find_map(|line| match line {
        MetricLine::Badge { label, text, .. } if label == "Error" => Some(text.as_str()),
        MetricLine::Text { label, value, .. } if label == "Error" => Some(value.as_str()),
        _ => None,
    })
}

/// A warning-only probe cannot replace a previously measured quota snapshot.
pub fn probe_limits_error(output: &PluginOutput) -> Option<&str> {
    probe_error_message(output).or_else(|| {
        if output.lines.iter().any(|line| matches!(line, MetricLine::Progress { .. })) {
            None
        } else {
            output.warning.as_deref()
        }
    })
}

pub fn limits_from_plugin_outputs(outputs: &[PluginOutput]) -> LimitsDocument {
    let mut providers = BTreeMap::new();
    let mut errors = Vec::new();
    for out in outputs {
        for line in &out.lines {
            if let MetricLine::Badge { label, text, .. } = line {
                if label == "Error" {
                    errors.push(LimitsError {
                        provider_id: out.provider_id.clone(),
                        message: text.clone(),
                    });
                }
            }
        }
        providers.insert(
            out.provider_id.clone(),
            provider_limits_from_lines(
                &out.display_name,
                out.plan.as_deref(),
                &out.lines,
                None,
                None,
            ),
        );
    }
    LimitsDocument {
        schema: LIMITS_SCHEMA.to_string(),
        generated_at: None,
        providers,
        errors,
    }
}

pub fn empty_limits_document() -> LimitsDocument {
    LimitsDocument {
        schema: LIMITS_SCHEMA.to_string(),
        generated_at: None,
        providers: BTreeMap::new(),
        errors: Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resource_slug_normalizes_labels() {
        assert_eq!(resource_slug("Session"), "session");
        assert_eq!(resource_slug("Total usage"), "total-usage");
        assert_eq!(resource_slug("  "), "resource");
    }

    #[test]
    fn warning_only_probe_is_a_limits_error() {
        let mut output = PluginOutput {
            provider_id: "claude".into(),
            display_name: "Claude".into(),
            plan: None,
            warning: Some("Updates blocked by Anthropic rate limit".into()),
            lines: vec![],
            icon_url: String::new(),
        };
        assert_eq!(probe_limits_error(&output), output.warning.as_deref());
        output.lines.push(MetricLine::Progress {
            label: "Session".into(),
            used: 10.0,
            limit: 100.0,
            format: ProgressFormat::Percent,
            resets_at: None,
            period_duration_ms: None,
            color: None,
            session_start_signal: None,
        });
        assert_eq!(probe_limits_error(&output), None);
    }

    #[test]
    fn maps_progress_lines_to_resources() {
        let lines = vec![MetricLine::Progress {
            label: "Session".to_string(),
            used: 40.0,
            limit: 100.0,
            format: ProgressFormat::Percent,
            resets_at: Some("2026-08-10T00:00:00Z".to_string()),
            period_duration_ms: None,
            color: None,
            session_start_signal: None,        }];
        let provider = provider_limits_from_lines("Claude", Some("Pro"), &lines, None, None);
        let session = provider.resources.get("session").expect("session");
        assert_eq!(session.used, 40.0);
        assert_eq!(session.limit, Some(100.0));
        assert_eq!(session.remaining, Some(60.0));
        assert_eq!(session.utilization, Some(0.4));
        assert_eq!(session.unit, "percent");
    }

    #[test]
    fn uncapped_progress_omits_limit_fields() {
        let lines = vec![MetricLine::Progress {
            label: "Credits".to_string(),
            used: 12.5,
            limit: 0.0,
            format: ProgressFormat::Dollars,
            resets_at: None,
            period_duration_ms: None,
            color: None,
            session_start_signal: None,        }];
        let provider = provider_limits_from_lines("Cursor", None, &lines, None, None);
        let credits = provider.resources.get("credits").expect("credits");
        assert_eq!(credits.used, 12.5);
        assert!(credits.limit.is_none());
        assert!(credits.remaining.is_none());
        assert!(credits.utilization.is_none());
        assert_eq!(credits.unit, "dollars");
    }

    #[test]
    fn maps_probe_errors_to_limits_errors() {
        use crate::plugin_engine::runtime::PluginOutput;

        let outputs = vec![PluginOutput {
            provider_id: "claude".to_string(),
            display_name: "Claude".to_string(),
            plan: None,
            warning: None,
            lines: vec![MetricLine::Badge {
                label: "Error".to_string(),
                text: "timeout".to_string(),
                color: Some("#ef4444".to_string()),
                subtitle: None,
            }],
            icon_url: String::new(),
        }];
        let doc = limits_from_plugin_outputs(&outputs);
        assert_eq!(doc.errors.len(), 1);
        assert_eq!(doc.errors[0].provider_id, "claude");
        assert_eq!(doc.errors[0].message, "timeout");
        assert!(doc.providers.get("claude").unwrap().resources.is_empty());
    }
}
