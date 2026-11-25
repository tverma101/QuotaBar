//! Optional Cursor metadata, enterprise summary, request-based fallback, and Grok Bot probes (`CursorProvider.swift`).

use super::mapper::{
    is_org_membership, map_grok_bot_usage, map_request_based_usage, preferred_membership,
    resolved_plan_label, CursorMappedUsage, CursorPlanUsageFacts,
};
use super::{client, summary, CursorProvider};
use crate::context::RefreshContext;
use crate::host::{auth_tag, diagnostic_gate};
use crate::http::{HttpError, Response};
use crate::model::{ErrorCategory, MetricLine, ProviderSnapshot};
use crate::{parse, qlog};
use serde_json::{Map, Value};

pub(super) fn fetch_optional_json(
    provider: &CursorProvider,
    label: &str,
    ctx: &RefreshContext,
    call: impl FnOnce() -> Result<Option<Response>, HttpError>,
) -> Result<Option<Map<String, Value>>, ()> {
    let resp = match call() {
        Ok(Some(r)) => r,
        Ok(None) => {
            log_optional_warning(
                "optional",
                label,
                "unprepared",
                &format!("optional {label} request could not be prepared from the current session"),
            );
            return Ok(None);
        }
        Err(HttpError::Cancelled) => return Err(()),
        Err(_) => {
            log_optional_warning(
                "optional",
                label,
                "transport",
                &format!("optional {label} request failed"),
            );
            return Ok(None);
        }
    };
    if ctx.is_cancelled() {
        return Err(());
    }
    clear_optional_warnings("optional", label, &["unprepared", "transport"]);
    if !resp.is_success() {
        log_optional_warning(
            "optional",
            label,
            &format!("http.{}", resp.status),
            &format!("optional {label} request returned HTTP {}", resp.status),
        );
        return Ok(None);
    }
    let Some(obj) = super::json_object(&resp.body) else {
        log_optional_warning(
            "optional",
            label,
            "json",
            &format!("optional {label} response was invalid"),
        );
        return Ok(None);
    };
    clear_optional_warnings("optional", label, &["json"]);
    let _ = provider;
    Ok(Some(obj))
}

pub(super) fn fetch_plan_name(
    provider: &CursorProvider,
    access_token: &str,
    ctx: &RefreshContext,
) -> Result<(Option<String>, bool), ()> {
    let Some(body) = fetch_optional_json(provider, "plan", ctx, || {
        client::fetch_plan(provider.http.as_ref(), access_token, &ctx.cancel).map(Some)
    })?
    else {
        return Ok((None, true));
    };
    let Some(name) = body
        .get("planInfo")
        .and_then(Value::as_object)
        .and_then(|pi| parse::trimmed_string(pi.get("planName")))
    else {
        log_optional_warning(
            "schema",
            "plan",
            "invalid",
            "optional plan response contained invalid plan metadata",
        );
        return Ok((None, true));
    };
    clear_optional_warnings("schema", "plan", &["invalid"]);
    Ok((Some(name), false))
}

pub(super) fn fetch_credit_grants(
    provider: &CursorProvider,
    access_token: &str,
    ctx: &RefreshContext,
) -> Result<Option<Map<String, Value>>, ()> {
    let Some(body) = fetch_optional_json(provider, "credit-grants", ctx, || {
        client::fetch_credits(provider.http.as_ref(), access_token, &ctx.cancel).map(Some)
    })?
    else {
        return Ok(None);
    };
    if body.is_empty() {
        return Ok(None);
    }
    let Some(has_grants) = body.get("hasCreditGrants").and_then(Value::as_bool) else {
        if body.contains_key("hasCreditGrants") {
            log_optional_warning(
                "schema",
                "credit-grants",
                "invalid",
                "optional credit-grants response contained invalid grant metadata",
            );
        }
        return Ok(None);
    };
    if has_grants
        && !(parse::number(body.get("totalCents")).is_some_and(|t| t > 0.0)
            && parse::number(body.get("usedCents")).is_some_and(|u| u >= 0.0))
    {
        log_optional_warning(
            "schema",
            "credit-grants",
            "invalid",
            "optional credit-grants response contained invalid grant metadata",
        );
        return Ok(None);
    }
    clear_optional_warnings("schema", "credit-grants", &["invalid"]);
    Ok(Some(body))
}

pub(super) fn fetch_stripe_balance_cents(
    provider: &CursorProvider,
    access_token: &str,
    ctx: &RefreshContext,
) -> Result<f64, ()> {
    let Some(body) = fetch_optional_json(provider, "prepaid-balance", ctx, || {
        client::fetch_stripe_balance(provider.http.as_ref(), access_token, &ctx.cancel)
    })?
    else {
        return Ok(0.0);
    };
    if parse::number(body.get("customerBalance")).is_none() {
        log_optional_warning(
            "schema",
            "prepaid-balance",
            "invalid",
            "optional prepaid-balance response contained invalid balance metadata",
        );
        return Ok(0.0);
    }
    clear_optional_warnings("schema", "prepaid-balance", &["invalid"]);
    Ok(super::mapper::stripe_balance_cents(&body))
}

pub(super) fn enrich_primary_usage_from_summary_if_needed(
    provider: &CursorProvider,
    access_token: &str,
    usage: &Map<String, Value>,
    plan_info_name: Option<&str>,
    membership_type: Option<&str>,
    mapped: &mut CursorMappedUsage,
    ctx: &RefreshContext,
) -> Result<(), ()> {
    let facts = CursorPlanUsageFacts::from_usage(usage);
    let org_seat = is_org_membership(membership_type)
        || is_org_membership(plan_info_name)
        || facts.is_team_by_shape();
    if !org_seat {
        return Ok(());
    }
    let Some(summary) = fetch_optional_json(provider, "usage-summary", ctx, || {
        client::fetch_usage_summary(provider.http.as_ref(), access_token, &ctx.cancel)
    })?
    else {
        return Ok(());
    };
    summary::append_missing_on_demand(&summary, &mut mapped.lines, None);
    let summary_membership =
        parse::trimmed_string(summary.get("membershipType")).map(|s| s.to_ascii_lowercase());
    if let Some(updated_plan) = resolved_plan_label(
        plan_info_name,
        preferred_membership(membership_type, summary_membership.as_deref()).as_deref(),
    ) {
        mapped.plan = Some(updated_plan);
    }
    Ok(())
}

pub(super) fn fetch_fallback_usage(
    provider: &CursorProvider,
    access_token: &str,
    plan_name: Option<&str>,
    unavailable_message: &str,
    ctx: &RefreshContext,
) -> Result<CursorMappedUsage, ProviderSnapshot> {
    let info = &provider.info;
    let summary = fetch_optional_json(provider, "usage-summary", ctx, || {
        client::fetch_usage_summary(provider.http.as_ref(), access_token, &ctx.cancel)
    })
    .map_err(|()| super::cancelled_snapshot(info, ctx))?;

    let rest_usage =
        match client::fetch_rest_usage(provider.http.as_ref(), access_token, &ctx.cancel) {
            Ok(Some(resp)) if resp.is_success() => super::json_object(&resp.body),
            Err(HttpError::Cancelled) => return Err(super::cancelled_snapshot(info, ctx)),
            Ok(Some(_)) | Ok(None) | Err(_) => {
                log_optional_warning(
                    "optional",
                    "request-based-usage",
                    "failed",
                    "optional request-based usage fallback failed",
                );
                None
            }
        };
    if ctx.is_cancelled() {
        return Err(super::cancelled_snapshot(info, ctx));
    }
    if let Some(ref s) = summary {
        if !s.contains_key("individualUsage") && !s.contains_key("teamUsage") {
            log_optional_warning(
                "schema",
                "usage-summary",
                "no-usable-fields",
                "optional usage-summary response contained no usable usage fields",
            );
        }
    }
    if let Some(ref r) = rest_usage {
        if !r.contains_key("gpt-4") {
            log_optional_warning(
                "schema",
                "request-based-usage",
                "no-usable-fields",
                "optional request-based usage response contained no usable usage fields",
            );
        }
    }
    if summary.is_none() && rest_usage.is_none() {
        return Err(ProviderSnapshot::error(
            info,
            unavailable_message,
            ErrorCategory::Decoding,
            ctx.now,
        ));
    }

    summary::map(
        summary.as_ref(),
        rest_usage.as_ref(),
        plan_name,
        unavailable_message,
    )
    .map_err(|_| {
        let fallback_err = map_request_based_usage(
            rest_usage.as_ref().unwrap_or(&Map::new()),
            plan_name,
            unavailable_message,
        );
        let msg = fallback_err
            .err()
            .map(|e| e.message().to_string())
            .unwrap_or_else(|| unavailable_message.to_string());
        ProviderSnapshot::error(info, &msg, ErrorCategory::Decoding, ctx.now)
    })
}

pub(super) fn append_grok_bot_usage(
    provider: &CursorProvider,
    access_token: &str,
    lines: &mut Vec<MetricLine>,
    ctx: &RefreshContext,
) -> Result<(), ()> {
    let Some(body) = fetch_optional_json(provider, "Grok Bot usage", ctx, || {
        client::fetch_grok_bot_usage(provider.http.as_ref(), access_token, &ctx.cancel).map(Some)
    })?
    else {
        return Ok(());
    };
    if body
        .get("usesPooledEnterpriseAllowance")
        .and_then(Value::as_bool)
        == Some(true)
        || body.get("includedLimitZero").and_then(Value::as_bool) == Some(true)
        || body.get("hasNonZeroIncludedLimit").and_then(Value::as_bool) == Some(false)
    {
        return Ok(());
    }
    if let Some(line) = map_grok_bot_usage(&body) {
        clear_optional_warnings("schema", "grok-bot", &["invalid"]);
        lines.push(line);
    } else {
        log_optional_warning(
            "schema",
            "grok-bot",
            "invalid",
            "optional Grok Bot usage response contained invalid usage metadata",
        );
    }
    Ok(())
}

pub(super) fn log_optional_warning(kind: &str, label: &str, reason: &str, message: &str) {
    let key = format!("auth.cursor.{kind}.{label}.{reason}");
    diagnostic_gate::log_once(&key, || {
        qlog!(Warn, auth_tag(super::ID), "{message}");
    });
}

pub(super) fn clear_optional_warnings(kind: &str, label: &str, reasons: &[&str]) {
    for reason in reasons {
        diagnostic_gate::clear(&format!("auth.cursor.{kind}.{label}.{reason}"));
    }
}
