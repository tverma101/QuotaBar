//! Cursor quota, membership, Grok Bot, and CSV spend normalization (`CursorMembership.swift`, `CursorUsageMapper.swift`).

use super::csv::CursorUsageCSVRow;
use crate::accounting::{
    append_token_usage, append_usage_trend, day_key, DailyUsageAccumulator, RowOptions,
    TokenUsageOptions,
};
use crate::model::{
    clamp_percent, MetricKind, MetricLine, MetricValue, ProgressFormat, ProviderUsageHistory,
    ReportedUsageCost,
};
use crate::parse::{self, DAY_MS, WEEK_MS};
use crate::pricing::ModelPricing;
use crate::time::parse_iso8601;
use serde_json::{Map, Value};
use std::collections::{BTreeSet, HashMap};

pub const BILLING_PERIOD_MS: i64 = 30 * DAY_MS;
const MAXIMUM_BILLING_EPOCH_MS: f64 = 4_102_444_800_000.0;
const MAXIMUM_BILLING_PERIOD_MS: f64 = 366.0 * 24.0 * 60.0 * 60.0 * 1000.0;
pub const CURSOR_EXPORT_SOURCE_NOTE: &str = "From your Cursor usage export";
pub const UNKNOWN_USAGE_UNAVAILABLE: &str =
    "Cursor request-based usage data unavailable. Try again later.";

#[derive(Clone, Debug, PartialEq)]
pub struct CursorMappedUsage {
    pub plan: Option<String>,
    pub lines: Vec<MetricLine>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CursorMapperError {
    NoActiveSubscription,
    TotalUsageLimitMissing,
    RequestBasedUnavailable(String),
}

impl CursorMapperError {
    pub fn message(&self) -> &str {
        match self {
            CursorMapperError::NoActiveSubscription => "No active Cursor subscription.",
            CursorMapperError::TotalUsageLimitMissing => {
                "Total usage limit missing from API response."
            }
            CursorMapperError::RequestBasedUnavailable(msg) => msg.as_str(),
        }
    }
}

pub struct CursorPlanUsageFacts {
    pub is_enabled: bool,
    pub has_plan_usage: bool,
    pub limit: Option<f64>,
    pub total_percent_used: Option<f64>,
    pub spend_limit_type: Option<String>,
    pub pooled_limit: f64,
}

impl CursorPlanUsageFacts {
    pub fn from_usage(usage: &Map<String, Value>) -> Self {
        let is_enabled = usage.get("enabled").and_then(Value::as_bool) != Some(false);
        let plan_usage = usage.get("planUsage").and_then(Value::as_object);
        let spend_limit = usage.get("spendLimitUsage").and_then(Value::as_object);
        CursorPlanUsageFacts {
            is_enabled,
            has_plan_usage: plan_usage.is_some(),
            limit: plan_usage.and_then(|p| parse::number(p.get("limit"))),
            total_percent_used: plan_usage.and_then(|p| parse::number(p.get("totalPercentUsed"))),
            spend_limit_type: spend_limit
                .and_then(|s| parse::trimmed_string(s.get("limitType")))
                .map(|s| s.to_ascii_lowercase()),
            pooled_limit: spend_limit
                .and_then(|s| parse::number(s.get("pooledLimit")))
                .unwrap_or(0.0),
        }
    }

    pub fn plan_usage_unusable(&self) -> bool {
        !self.has_plan_usage || self.limit.is_none()
    }

    pub fn is_team_by_shape(&self) -> bool {
        self.spend_limit_type.as_deref() == Some("team") || self.pooled_limit > 0.0
    }
}

pub fn is_org_membership(raw: Option<&str>) -> bool {
    matches!(
        raw.map(|s| s.trim().to_ascii_lowercase()).as_deref(),
        Some("enterprise" | "team")
    )
}

pub fn preferred_membership(local: Option<&str>, summary: Option<&str>) -> Option<String> {
    let norm = |v: Option<&str>| {
        v.map(|s| s.trim().to_ascii_lowercase())
            .filter(|s| !s.is_empty())
    };
    let local_m = norm(local);
    let summary_m = norm(summary);
    if is_org_membership(local_m.as_deref()) {
        return local_m;
    }
    if is_org_membership(summary_m.as_deref()) {
        return summary_m;
    }
    local_m.or(summary_m)
}

pub fn routing_plan_name(
    plan_info_name: Option<&str>,
    membership_type: Option<&str>,
) -> Option<String> {
    let membership = membership_type
        .map(|s| s.trim().to_ascii_lowercase())
        .filter(|s| !s.is_empty());
    if is_org_membership(membership.as_deref()) {
        return membership;
    }
    plan_info_name
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

pub fn resolved_plan_name(
    plan_info_name: Option<&str>,
    membership_type: Option<&str>,
) -> Option<String> {
    let membership = membership_type
        .map(|s| s.trim().to_ascii_lowercase())
        .filter(|s| !s.is_empty());
    let plan_info = plan_info_name
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    if is_org_membership(membership.as_deref())
        && plan_info
            .as_deref()
            .is_none_or(|p| matches!(p.to_ascii_lowercase().as_str(), "pro" | "pro plan"))
    {
        return membership;
    }
    plan_info.or(membership)
}

pub fn resolved_plan_label(
    plan_info_name: Option<&str>,
    membership_type: Option<&str>,
) -> Option<String> {
    plan_label(resolved_plan_name(plan_info_name, membership_type).as_deref())
}

pub fn should_use_request_based_fallback(
    usage: &Map<String, Value>,
    plan_name: Option<&str>,
    plan_info_unavailable: bool,
) -> (bool, &'static str) {
    let facts = CursorPlanUsageFacts::from_usage(usage);
    if !facts.is_enabled {
        return (false, "");
    }
    let norm = plan_name
        .map(|s| s.trim().to_ascii_lowercase())
        .unwrap_or_default();
    if facts.plan_usage_unusable() && facts.total_percent_used.is_none() && norm == "enterprise" {
        return (true, "Enterprise usage data unavailable. Try again later.");
    }
    if facts.plan_usage_unusable() && facts.total_percent_used.is_none() && norm == "team" {
        return (
            true,
            "Team request-based usage data unavailable. Try again later.",
        );
    }
    if facts.plan_usage_unusable()
        && facts.total_percent_used.is_none()
        && norm.is_empty()
        && plan_info_unavailable
    {
        return (true, UNKNOWN_USAGE_UNAVAILABLE);
    }
    if facts.is_team_by_shape()
        && facts.has_plan_usage
        && facts.limit.is_none()
        && facts.total_percent_used.is_none()
    {
        return (true, UNKNOWN_USAGE_UNAVAILABLE);
    }
    (false, "")
}

pub fn map_usage(
    usage: &Map<String, Value>,
    plan_name: Option<&str>,
    credit_grants: Option<&Map<String, Value>>,
    stripe_balance_cents: f64,
) -> Result<CursorMappedUsage, CursorMapperError> {
    let facts = CursorPlanUsageFacts::from_usage(usage);
    if !facts.is_enabled {
        return Err(CursorMapperError::NoActiveSubscription);
    }
    let Some(plan_usage) = usage.get("planUsage").and_then(Value::as_object) else {
        return Err(CursorMapperError::TotalUsageLimitMissing);
    };
    if facts.limit.is_none() && facts.total_percent_used.is_none() {
        return Err(CursorMapperError::TotalUsageLimitMissing);
    }

    let normalized_plan = plan_name
        .map(|s| s.trim().to_ascii_lowercase())
        .unwrap_or_default();
    let remaining_cents = parse::number(plan_usage.get("remaining")).unwrap_or(0.0);
    let plan_used_cents = parse::number(plan_usage.get("totalSpend"))
        .unwrap_or_else(|| (facts.limit.unwrap_or(0.0) - remaining_cents).max(0.0));
    let computed_pct = facts
        .limit
        .filter(|&l| l > 0.0)
        .map(|l| plan_used_cents / l * 100.0)
        .unwrap_or(0.0);
    let total_usage_pct = facts.total_percent_used.unwrap_or(computed_pct);

    let (resets_at, period_ms) = billing_cycle(usage);
    let mut lines = Vec::new();
    append_credits(credit_grants, stripe_balance_cents, &mut lines);

    let progress =
        |label: &str, used: f64, limit: f64, format: ProgressFormat| MetricLine::Progress {
            label: label.to_string(),
            used,
            limit,
            format,
            resets_at,
            period_duration_ms: Some(period_ms),
            color_hex: None,
            detail: None,
        };

    if normalized_plan == "team" || facts.is_team_by_shape() {
        if let Some(limit_cents) = facts.limit.filter(|&l| l > 0.0) {
            lines.push(progress(
                "Total usage",
                plan_used_cents / 100.0,
                limit_cents / 100.0,
                ProgressFormat::Dollars,
            ));
        } else if let Some(pct) = facts.total_percent_used {
            lines.push(progress("Total usage", pct, 100.0, ProgressFormat::Percent));
        }
    } else {
        lines.push(progress(
            "Total usage",
            total_usage_pct,
            100.0,
            ProgressFormat::Percent,
        ));
    }

    if let Some(auto_pct) = parse::number(plan_usage.get("autoPercentUsed")) {
        lines.push(progress(
            "Cursor Models",
            auto_pct,
            100.0,
            ProgressFormat::Percent,
        ));
    }
    if let Some(api_pct) = parse::number(plan_usage.get("apiPercentUsed")) {
        lines.push(progress(
            "Other Models",
            api_pct,
            100.0,
            ProgressFormat::Percent,
        ));
    }

    if let Some(spend_limit) = usage.get("spendLimitUsage").and_then(Value::as_object) {
        let limit = parse::number(spend_limit.get("individualLimit"))
            .or_else(|| parse::number(spend_limit.get("pooledLimit")))
            .unwrap_or(0.0);
        let remaining = parse::number(spend_limit.get("individualRemaining"))
            .or_else(|| parse::number(spend_limit.get("pooledRemaining")))
            .unwrap_or(0.0);
        let spent = on_demand_spend_cents(spend_limit, limit, remaining);
        if limit > 0.0 {
            lines.push(progress(
                "On-demand",
                spent / 100.0,
                limit / 100.0,
                ProgressFormat::Dollars,
            ));
        } else if spent > 0.0 {
            lines.push(MetricLine::values(
                "On-demand",
                vec![MetricValue::new(spent / 100.0, MetricKind::Dollars)],
            ));
        }
    }

    Ok(CursorMappedUsage {
        plan: plan_label(plan_name),
        lines,
    })
}

fn on_demand_spend_cents(obj: &Map<String, Value>, limit: f64, remaining: f64) -> f64 {
    let reported: Vec<f64> = [
        parse::number(obj.get("individualUsed")),
        parse::number(obj.get("pooledUsed")),
        parse::number(obj.get("totalSpend")),
    ]
    .into_iter()
    .flatten()
    .collect();
    if let Some(&pos) = reported.iter().find(|&&v| v > 0.0) {
        return pos;
    }
    let implied = (limit - remaining).max(0.0);
    if implied > 0.0 {
        implied
    } else {
        reported.first().copied().unwrap_or(0.0)
    }
}

pub fn map_grok_bot_usage(body: &Map<String, Value>) -> Option<MetricLine> {
    if body
        .get("usesPooledEnterpriseAllowance")
        .and_then(Value::as_bool)
        == Some(true)
        || body.get("includedLimitZero").and_then(Value::as_bool) == Some(true)
        || body.get("hasNonZeroIncludedLimit").and_then(Value::as_bool) == Some(false)
    {
        return None;
    }
    let raw_pct = parse::number(body.get("usagePercent")).filter(|&v| v >= 0.0)?;
    let resets_at =
        parse::trimmed_string(body.get("nextResetTimestampUtc")).and_then(|s| parse_iso8601(&s));
    Some(MetricLine::Progress {
        label: "Grok Bot usage".to_string(),
        used: clamp_percent(raw_pct),
        limit: 100.0,
        format: ProgressFormat::Percent,
        resets_at,
        period_duration_ms: Some(WEEK_MS),
        color_hex: None,
        detail: None,
    })
}

pub fn map_request_based_usage(
    usage: &Map<String, Value>,
    plan_name: Option<&str>,
    unavailable_message: &str,
) -> Result<CursorMappedUsage, CursorMapperError> {
    super::summary::map(None, Some(usage), plan_name, unavailable_message)
}

pub fn stripe_balance_cents(body: &Map<String, Value>) -> f64 {
    match parse::number(body.get("customerBalance")) {
        Some(balance) if balance < 0.0 => balance.abs(),
        _ => 0.0,
    }
}

fn append_credits(
    credit_grants: Option<&Map<String, Value>>,
    stripe_balance_cents: f64,
    lines: &mut Vec<MetricLine>,
) {
    let has_grants = credit_grants
        .and_then(|g| g.get("hasCreditGrants"))
        .and_then(Value::as_bool)
        == Some(true);
    let grant_total = if has_grants {
        credit_grants
            .and_then(|g| parse::number(g.get("totalCents")))
            .unwrap_or(0.0)
    } else {
        0.0
    };
    let grant_used = if has_grants {
        credit_grants
            .and_then(|g| parse::number(g.get("usedCents")))
            .unwrap_or(0.0)
    } else {
        0.0
    };
    let valid_grant = has_grants && grant_total > 0.0;
    let combined = (if valid_grant { grant_total } else { 0.0 }) + stripe_balance_cents;
    let remaining = (combined - if valid_grant { grant_used } else { 0.0 }).max(0.0);
    if combined > 0.0 {
        lines.push(MetricLine::values(
            "Credits",
            vec![MetricValue::new(remaining / 100.0, MetricKind::Dollars)],
        ));
    }
}

pub fn append_spend_lines(
    rows: &[CursorUsageCSVRow],
    now: f64,
    pricing: &ModelPricing,
    lines: &mut Vec<MetricLine>,
) -> ProviderUsageHistory {
    let mut acc = DailyUsageAccumulator::new();
    let mut reported_by_day: HashMap<String, (f64, i64, bool)> = HashMap::new();

    for row in rows {
        let day = day_key(row.date);
        let total = row.tokens.total_tokens();
        let family = family_name(&row.model, pricing);
        if row.cost_is_opaque_grok_bot {
            acc.add_with(
                &day,
                total,
                None,
                &row.model,
                RowOptions {
                    canonical: Some(&family),
                    cost_is_complete: false,
                    token_count_saturated: false,
                },
            );
            acc.add_named_unpriced_model(&day, &row.model);
            acc.record_api_estimate(&day, None, total);
        } else if let Some(cost) = row.imputed_cost_dollars {
            acc.add_with(
                &day,
                total,
                Some(cost),
                &row.model,
                RowOptions {
                    canonical: Some(&family),
                    cost_is_complete: true,
                    token_count_saturated: false,
                },
            );
            acc.mark_estimated_cost(&day);
            let api_est = pricing.estimated_cost_dollars(&row.model, &row.tokens, None, false);
            acc.record_api_estimate(&day, api_est, total);
        } else {
            acc.add_with(
                &day,
                total,
                None,
                &row.model,
                RowOptions {
                    canonical: Some(&family),
                    cost_is_complete: false,
                    token_count_saturated: false,
                },
            );
            if total > 0 {
                acc.add_unknown_model(&day, &row.model);
            }
            acc.record_api_estimate(&day, None, total);
        }

        if let Some(rep) = row.reported_cost_dollars {
            let entry = reported_by_day.entry(day).or_insert((0.0, 0, false));
            let sum = entry.0 + rep;
            if !sum.is_finite() {
                entry.2 = true;
            } else {
                entry.0 = sum;
            }
            if let Some(cov) = entry.1.checked_add(total) {
                entry.1 = cov;
            } else {
                entry.2 = true;
            }
        }
    }

    let mut scan = acc.build();
    for entry in &mut scan.series.daily {
        if let Some(&(dollars, covered_tokens, overflowed)) = reported_by_day.get(&entry.date) {
            if !overflowed && covered_tokens >= 0 {
                entry.reported_cost = Some(ReportedUsageCost {
                    dollars,
                    covered_tokens,
                });
            }
        }
    }

    let opts = TokenUsageOptions {
        estimated: true,
        unknown_models_by_day: scan.unknown_models_by_day.clone(),
        model_usage: scan.model_usage.clone(),
        model_source_note: Some(CURSOR_EXPORT_SOURCE_NOTE.to_string()),
        partial_days: BTreeSet::new(),
        api_estimate_by_day: scan.api_estimate_by_day.clone(),
        estimated_cost_days: scan.estimated_cost_days.clone(),
    };
    append_token_usage(&scan.series, lines, now, &opts);
    append_usage_trend(
        &scan.series,
        lines,
        now,
        CURSOR_EXPORT_SOURCE_NOTE,
        &BTreeSet::new(),
        None,
    );

    ProviderUsageHistory {
        series: scan.series,
        model_usage: scan.model_usage,
        unknown_models_by_day: scan.unknown_models_by_day,
        api_estimate_by_day: scan.api_estimate_by_day,
        api_estimate_incomplete_days: scan.api_estimate_incomplete_days,
        partial_days: None,
        estimated_cost_days: scan.estimated_cost_days,
    }
}

fn family_name(model: &str, pricing: &ModelPricing) -> String {
    if super::csv::is_opaque_grok_bot_product_label(model) {
        return "Grok Bot".to_string();
    }
    let canonical = pricing
        .cursor_canonical_name(model)
        .or_else(|| pricing.canonical_name(model))
        .unwrap_or_else(|| model.to_string());
    if let Some(base) = canonical.strip_suffix("-fast") {
        if !base.is_empty() {
            return base.to_string();
        }
    }
    canonical
}

pub fn clamped_billing_duration_ms(duration_ms: f64, max_ms: f64) -> i64 {
    if !duration_ms.is_finite() || duration_ms <= 0.0 || duration_ms > max_ms {
        return BILLING_PERIOD_MS;
    }
    duration_ms.round() as i64
}

fn billing_cycle(usage: &Map<String, Value>) -> (Option<f64>, i64) {
    let cycle_start = parse::number(usage.get("billingCycleStart"));
    let cycle_end = parse::number(usage.get("billingCycleEnd"));
    let resets_at = cycle_end
        .filter(|&e| e > 0.0 && e <= MAXIMUM_BILLING_EPOCH_MS)
        .map(|e| e / 1000.0);
    let (Some(s), Some(e)) = (cycle_start, cycle_end) else {
        return (resets_at, BILLING_PERIOD_MS);
    };
    if s < 0.0 || e <= s {
        return (resets_at, BILLING_PERIOD_MS);
    }
    (
        resets_at,
        clamped_billing_duration_ms(e - s, MAXIMUM_BILLING_PERIOD_MS),
    )
}

pub fn plan_label(raw: Option<&str>) -> Option<String> {
    let trimmed = raw?.trim();
    if trimmed.is_empty() {
        return None;
    }
    Some(
        trimmed
            .split_whitespace()
            .map(|word| {
                let mut chars = word.chars();
                match chars.next() {
                    Some(first) => first
                        .to_uppercase()
                        .chain(chars.flat_map(char::to_lowercase))
                        .collect::<String>(),
                    None => String::new(),
                }
            })
            .collect::<Vec<_>>()
            .join(" "),
    )
}
