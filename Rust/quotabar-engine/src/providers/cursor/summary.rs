//! Maps Cursor's `/api/usage-summary` + `/api/usage` enterprise/team fallback responses (`CursorUsageSummaryMapper.swift`).

use super::mapper::{
    clamped_billing_duration_ms, plan_label, CursorMappedUsage, CursorMapperError, BILLING_PERIOD_MS,
};
use crate::model::{MetricLine, ProgressFormat};
use crate::parse;
use crate::time::parse_iso8601;
use serde_json::{Map, Value};

const MAXIMUM_CYCLE_MS: f64 = 366.0 * 24.0 * 60.0 * 60.0 * 1000.0;

pub fn map(
    summary: Option<&Map<String, Value>>,
    request_usage: Option<&Map<String, Value>>,
    plan_name: Option<&str>,
    unavailable_message: &str,
) -> Result<CursorMappedUsage, CursorMapperError> {
    let summary_membership = summary.and_then(|s| parse::trimmed_string(s.get("membershipType")));
    let plan = plan_label(plan_name.or(summary_membership.as_deref()));

    let cycle = billing_cycle(summary, request_usage);
    let mut lines = Vec::new();
    let mut has_total = false;

    if let Some(line) = requests_line(request_usage, &cycle) {
        if let MetricLine::Progress { used, limit, resets_at, period_duration_ms, .. } = &line {
            lines.push(MetricLine::Progress {
                label: "Total usage".to_string(),
                used: *used,
                limit: *limit,
                format: ProgressFormat::Count("requests".to_string()),
                resets_at: *resets_at,
                period_duration_ms: *period_duration_ms,
                color_hex: None,
                detail: None,
            });
            has_total = true;
        }
        lines.push(line);
    }

    if let Some(summary) = summary {
        let ind = summary.get("individualUsage").and_then(Value::as_object);
        let team = summary.get("teamUsage").and_then(Value::as_object);
        let ind_plan = ind.and_then(|i| i.get("plan")).and_then(Value::as_object);
        let team_pooled = team.and_then(|t| t.get("pooled")).and_then(Value::as_object);

        if !has_total {
            if let Some((used, limit, is_dollars)) = pooled_or_plan_total(ind_plan, team_pooled) {
                lines.push(MetricLine::Progress {
                    label: "Total usage".to_string(),
                    used,
                    limit,
                    format: if is_dollars { ProgressFormat::Dollars } else { ProgressFormat::Percent },
                    resets_at: cycle.0,
                    period_duration_ms: Some(cycle.1),
                    color_hex: None,
                    detail: None,
                });
            }
        }

        if let Some(auto_pct) = ind_plan.and_then(|p| parse::number(p.get("autoPercentUsed"))) {
            lines.push(MetricLine::Progress {
                label: "Cursor Models".to_string(),
                used: auto_pct,
                limit: 100.0,
                format: ProgressFormat::Percent,
                resets_at: cycle.0,
                period_duration_ms: Some(cycle.1),
                color_hex: None,
                detail: None,
            });
        }
        if let Some(api_pct) = ind_plan.and_then(|p| parse::number(p.get("apiPercentUsed"))) {
            lines.push(MetricLine::Progress {
                label: "Other Models".to_string(),
                used: api_pct,
                limit: 100.0,
                format: ProgressFormat::Percent,
                resets_at: cycle.0,
                period_duration_ms: Some(cycle.1),
                color_hex: None,
                detail: None,
            });
        }

        append_missing_on_demand(summary, &mut lines, Some(cycle));
    }

    if lines.is_empty() {
        return Err(CursorMapperError::RequestBasedUnavailable(unavailable_message.to_string()));
    }

    Ok(CursorMappedUsage { plan, lines })
}

pub fn append_missing_on_demand(
    summary: &Map<String, Value>,
    lines: &mut Vec<MetricLine>,
    cycle: Option<(Option<f64>, i64)>,
) {
    if lines.iter().any(|l| l.label() == "On-demand") {
        return;
    }
    let ind_od = summary
        .get("individualUsage")
        .and_then(Value::as_object)
        .and_then(|i| i.get("onDemand"))
        .and_then(Value::as_object);
    let team_od = summary
        .get("teamUsage")
        .and_then(Value::as_object)
        .and_then(|t| t.get("onDemand"))
        .and_then(Value::as_object);

    let pick = |obj: Option<&Map<String, Value>>| -> Option<(f64, f64)> {
        let obj = obj?;
        if obj.get("enabled").and_then(Value::as_bool) == Some(false) {
            return None;
        }
        let limit = parse::number(obj.get("limit")).filter(|&l| l > 0.0)?;
        let used = parse::number(obj.get("used")).unwrap_or(0.0).max(0.0);
        let remaining = parse::number(obj.get("remaining"));
        let implied = remaining.map(|r| (limit - r).max(0.0)).unwrap_or(0.0);
        Some((used.max(implied), limit))
    };

    let Some((used_cents, limit_cents)) = pick(ind_od).or_else(|| pick(team_od)) else {
        return;
    };
    let (resets_at, period_ms) = match cycle {
        Some((r, p)) => (r, Some(p)),
        None => (None, None),
    };
    lines.push(MetricLine::Progress {
        label: "On-demand".to_string(),
        used: used_cents / 100.0,
        limit: limit_cents / 100.0,
        format: ProgressFormat::Dollars,
        resets_at,
        period_duration_ms: period_ms,
        color_hex: None,
        detail: None,
    });
}

fn pooled_or_plan_total(
    ind_plan: Option<&Map<String, Value>>,
    team_pooled: Option<&Map<String, Value>>,
) -> Option<(f64, f64, bool)> {
    if let Some(pooled) = team_pooled {
        if pooled.get("enabled").and_then(Value::as_bool) != Some(false) {
            if let Some(limit_cents) = parse::number(pooled.get("limit")).filter(|&l| l > 0.0) {
                let remaining = parse::number(pooled.get("remaining"));
                let used_cents = parse::number(pooled.get("used"))
                    .unwrap_or_else(|| remaining.map(|r| (limit_cents - r).max(0.0)).unwrap_or(0.0));
                return Some((used_cents / 100.0, limit_cents / 100.0, true));
            }
        }
    }
    if let Some(plan) = ind_plan {
        if let Some(limit_cents) = parse::number(plan.get("limit")).filter(|&l| l > 0.0) {
            let used_cents = parse::number(plan.get("used")).unwrap_or(0.0).max(0.0);
            return Some((used_cents / 100.0, limit_cents / 100.0, true));
        }
        if plan.get("autoPercentUsed").is_none() && plan.get("apiPercentUsed").is_none() {
            if let Some(pct) = parse::number(plan.get("totalPercentUsed")) {
                return Some((pct, 100.0, false));
            }
        }
    }
    None
}

fn requests_line(request_usage: Option<&Map<String, Value>>, cycle: &(Option<f64>, i64)) -> Option<MetricLine> {
    let usage = request_usage?;
    let gpt4 = usage.get("gpt-4")?.as_object()?;
    let limit = parse::number(gpt4.get("maxRequestUsage")).filter(|&l| l > 0.0)?;
    let used = parse::number(gpt4.get("numRequests"))
        .or_else(|| parse::number(gpt4.get("numRequestsTotal")))
        .unwrap_or(0.0)
        .max(0.0);
    Some(MetricLine::Progress {
        label: "Requests".to_string(),
        used,
        limit,
        format: ProgressFormat::Count("requests".to_string()),
        resets_at: cycle.0,
        period_duration_ms: Some(cycle.1),
        color_hex: None,
        detail: None,
    })
}

fn billing_cycle(summary: Option<&Map<String, Value>>, request_usage: Option<&Map<String, Value>>) -> (Option<f64>, i64) {
    let start = summary
        .and_then(|s| s.get("billingCycleStart"))
        .and_then(Value::as_str)
        .and_then(parse_iso8601);
    let end = summary
        .and_then(|s| s.get("billingCycleEnd"))
        .and_then(Value::as_str)
        .and_then(parse_iso8601);
    if let (Some(s), Some(e)) = (start, end) {
        if e > s {
            let ms = (e - s) * 1000.0;
            return (Some(e), clamped_billing_duration_ms(ms, MAXIMUM_CYCLE_MS));
        }
    }
    let req_start = request_usage
        .and_then(|u| u.get("startOfMonth"))
        .and_then(Value::as_str)
        .and_then(parse_iso8601);
    (
        req_start.map(|s| s + (BILLING_PERIOD_MS as f64) / 1000.0),
        BILLING_PERIOD_MS,
    )
}
