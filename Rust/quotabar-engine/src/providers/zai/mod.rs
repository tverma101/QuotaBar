//! Z.ai Coding Plan quota + local ZCode token usage provider (`Providers/ZAI`).

pub mod auth;
pub mod mapper;
pub mod zcode;
pub mod zcode_leveldb;

#[cfg(test)]
mod tests;

use super::api_key::{ApiKeySpec, ApiKeyStatus};
use super::{cancelled_snapshot, ProviderRuntime};
use crate::accounting::{append_token_usage, TokenUsageOptions};
use crate::context::RefreshContext;
use crate::host::{auth_tag, diagnostic_gate};
use crate::http::{self, HttpClient, HttpError, Request};
use crate::model::{
    ErrorCategory, MetricLine, ProgressFormat, ProviderInfo, ProviderSnapshot, ProviderUsageHistory,
};
use crate::pricing::ModelPricing;
use crate::{qlog, time};
use mapper::{
    is_no_coding_plan, map, plan_name as parse_plan_name, INVALID_RESPONSE_ERROR,
    NO_CODING_PLAN_ERROR,
};
use std::collections::BTreeSet;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use zcode::{ZCodeUsageScanner, UNREADABLE_HISTORY_WARNING};
use zcode_leveldb::ZCodeAllowance;

pub const ID: &str = "zai";
pub const QUOTA_URL: &str = "https://api.z.ai/api/monitor/usage/quota/limit";
pub const SUBSCRIPTION_URL: &str = "https://api.z.ai/api/biz/subscription/list";
pub const PLAN_CACHE_INTERVAL_SECS: f64 = 3600.0;

const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
const LOCAL_SOURCE_NOTE: &str = "From your ZCode usage history";
const ZCODE_FAILURE_GATE_KEY: &str = "auth.zai.quota-with-zcode.failure";

#[derive(Clone, Default)]
struct CachedSubscription {
    body: Vec<u8>,
    api_key: String,
    fetched_at: f64,
}

pub struct ZAIProvider {
    info: ProviderInfo,
    spec: Option<ApiKeySpec>,
    http: Arc<dyn HttpClient>,
    scanner: ZCodeUsageScanner,
    sub_cache: Mutex<Option<CachedSubscription>>,
    pricing_override: Option<Arc<ModelPricing>>,
}

impl ZAIProvider {
    pub fn live() -> Self {
        ZAIProvider {
            info: ProviderInfo {
                id: ID.into(),
                display_name: "Z.ai".into(),
            },
            spec: None,
            http: http::shared(),
            scanner: ZCodeUsageScanner::live(),
            sub_cache: Mutex::new(None),
            pricing_override: None,
        }
    }

    pub fn new(spec: ApiKeySpec, http: Arc<dyn HttpClient>, scanner: ZCodeUsageScanner) -> Self {
        ZAIProvider {
            info: ProviderInfo {
                id: ID.into(),
                display_name: "Z.ai".into(),
            },
            spec: Some(spec),
            http,
            scanner,
            sub_cache: Mutex::new(None),
            pricing_override: None,
        }
    }

    pub fn with_pricing_override(mut self, pricing: Arc<ModelPricing>) -> Self {
        self.pricing_override = Some(pricing);
        self
    }

    fn effective_spec(&self) -> ApiKeySpec {
        self.spec.clone().unwrap_or_else(auth::live_spec)
    }

    fn refresh_quota(&self, ctx: &RefreshContext) -> ProviderSnapshot {
        let spec = self.effective_spec();
        let api_key = match auth::load_for_refresh(&spec) {
            Ok(Some(key)) => key,
            Ok(None) => {
                return ProviderSnapshot::error(
                    &self.info,
                    auth::MISSING_KEY_ERROR,
                    ErrorCategory::NotLoggedIn,
                    ctx.now,
                )
            }
            Err((message, category)) => {
                return ProviderSnapshot::error(&self.info, message, category, ctx.now)
            }
        };

        let quota_req = Request::get(QUOTA_URL)
            .header("Authorization", format!("Bearer {api_key}"))
            .header("Accept", "application/json")
            .timeout(REQUEST_TIMEOUT);
        let quota_resp = match self.http.send(&quota_req, &ctx.cancel) {
            Ok(resp) => resp,
            Err(HttpError::Cancelled) => return cancelled_snapshot(&self.info, ctx),
            Err(_) => {
                return ProviderSnapshot::error(
                    &self.info,
                    "Couldn't reach Z.ai. Check your connection.",
                    ErrorCategory::Network,
                    ctx.now,
                )
            }
        };
        if ctx.is_cancelled() {
            return cancelled_snapshot(&self.info, ctx);
        }

        let sub_body = match self.subscription_body(&api_key, ctx) {
            Ok(body) => body,
            Err(()) => return cancelled_snapshot(&self.info, ctx),
        };

        if quota_resp.status == 401 || quota_resp.status == 403 {
            return ProviderSnapshot::error(
                &self.info,
                auth::INVALID_KEY_ERROR,
                ErrorCategory::AuthInvalid,
                ctx.now,
            );
        }
        if !quota_resp.is_success() {
            return ProviderSnapshot::error(
                &self.info,
                &format!("Z.ai request failed (HTTP {}).", quota_resp.status),
                ErrorCategory::http(quota_resp.status),
                ctx.now,
            );
        }
        if is_no_coding_plan(&quota_resp.body) {
            let mut snap = ProviderSnapshot::error(
                &self.info,
                NO_CODING_PLAN_ERROR,
                ErrorCategory::NotAvailable,
                ctx.now,
            );
            snap.clears_prior_menu_bar_quota_state = Some(true);
            return snap;
        }
        match map(&quota_resp.body, sub_body.as_deref(), ctx.now) {
            Ok(mapped) => ProviderSnapshot::new(&self.info, mapped.plan, mapped.lines, ctx.now),
            Err(_) => ProviderSnapshot::error(
                &self.info,
                INVALID_RESPONSE_ERROR,
                ErrorCategory::Decoding,
                ctx.now,
            ),
        }
    }

    fn subscription_body(
        &self,
        api_key: &str,
        ctx: &RefreshContext,
    ) -> Result<Option<Vec<u8>>, ()> {
        if !ctx.is_manual {
            let guard = self.sub_cache.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(cached) = guard.as_ref() {
                if cached.api_key == api_key
                    && (ctx.now - cached.fetched_at) < PLAN_CACHE_INTERVAL_SECS
                {
                    return Ok(Some(cached.body.clone()));
                }
            }
        }
        if ctx.is_cancelled() {
            return Err(());
        }
        let req = Request::get(SUBSCRIPTION_URL)
            .header("Authorization", format!("Bearer {api_key}"))
            .header("Accept", "application/json")
            .timeout(REQUEST_TIMEOUT);
        let fetched = match self.http.send(&req, &ctx.cancel) {
            Ok(resp) if resp.is_success() => {
                if ctx.is_cancelled() {
                    return Err(());
                }
                let _ = parse_plan_name(&resp.body);
                Some(resp.body)
            }
            Err(HttpError::Cancelled) => return Err(()),
            _ => None,
        };
        let mut guard = self.sub_cache.lock().unwrap_or_else(|e| e.into_inner());
        let Some(body) = fetched else {
            return Ok(guard
                .as_ref()
                .filter(|c| c.api_key == api_key)
                .map(|c| c.body.clone()));
        };
        *guard = Some(CachedSubscription {
            body: body.clone(),
            api_key: api_key.to_string(),
            fetched_at: ctx.now,
        });
        Ok(Some(body))
    }
}

impl ProviderRuntime for ZAIProvider {
    fn info(&self) -> &ProviderInfo {
        &self.info
    }

    fn has_local_credentials(&self) -> bool {
        self.effective_spec().has_key_or_unreadable_config() || self.scanner.has_history()
    }

    fn unload_caches(&self) {
        self.scanner.unload_caches();
        *self.sub_cache.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }

    fn refresh(&self, ctx: &RefreshContext) -> ProviderSnapshot {
        let folds_history_only = ctx.scope.suppresses_live_quota();
        let quota = if folds_history_only {
            ProviderSnapshot::new(&self.info, None, Vec::new(), ctx.now)
        } else {
            self.refresh_quota(ctx)
        };
        if quota.error_category == Some(ErrorCategory::Cancelled) || ctx.is_cancelled() {
            return quota;
        }
        if ctx.scope.skips_local_accounting() {
            return quota;
        }

        let usage = match self
            .scanner
            .usage(Some(ctx.now), self.pricing_override.as_deref())
        {
            Ok(Some(usage)) => usage,
            Ok(None) => return quota,
            Err(err) => {
                qlog!(Warn, auth_tag(ID), "ZCode token history read failed: {err}");
                let mut result = quota;
                result.history_warning = Some(UNREADABLE_HISTORY_WARNING.into());
                return result;
            }
        };

        let has_content = usage.total_tokens.unwrap_or(0.0) > 0.0
            || usage.weekend_build.is_some()
            || usage.log_scan.is_some()
            || usage.damaged_rows > 0
            || usage.plan_name.is_some();
        if !has_content {
            return quota;
        }

        let mut result = quota.clone();
        let mut quota_failed = false;
        if let Some(MetricLine::Badge { label, text, .. }) = quota.lines.iter().find(|l| {
            matches!(l, MetricLine::Badge { label, .. } if label == MetricLine::ERROR_BADGE_LABEL)
        }) {
            let _ = label;
            quota_failed = true;
            let key_status = self.effective_spec().key_status();
            let is_pure_local = key_status == ApiKeyStatus::NotSet && quota.error_category == Some(ErrorCategory::NotLoggedIn);
            let warning = (!is_pure_local).then(|| text.clone());
            if let Some(ref msg) = warning {
                diagnostic_gate::log_once(ZCODE_FAILURE_GATE_KEY, || {
                    qlog!(Warn, auth_tag(ID), "quota refresh failed: {msg}");
                });
            }
            result = ProviderSnapshot::new(&self.info, quota.plan.or(usage.plan_name), Vec::new(), ctx.now);
            result.warning = warning;
            result.quota_refreshed_at = Some(time::DISTANT_PAST);
            result.clears_prior_menu_bar_quota_state = quota.clears_prior_menu_bar_quota_state;
        } else if result.plan.is_none() {
            result.plan = usage.plan_name;
        }

        if !folds_history_only && quota.lines.iter().all(|l| !matches!(l, MetricLine::Badge { label, .. } if label == MetricLine::ERROR_BADGE_LABEL)) {
            diagnostic_gate::clear(ZCODE_FAILURE_GATE_KEY);
        }

        if !folds_history_only {
            if let Some(weekend) = &usage.weekend_build {
                if weekend.expires_at.is_none_or(|exp| exp > ctx.now) {
                    result.lines.push(promo_line(weekend, ctx.now));
                    if !quota_failed {
                        result.quota_refreshed_at = Some(ctx.now);
                    }
                }
            }
        }

        if let Some(scan) = &usage.log_scan {
            let opts = TokenUsageOptions {
                estimated: true,
                unknown_models_by_day: scan.unknown_models_by_day.clone(),
                model_usage: scan.model_usage.clone(),
                model_source_note: Some(LOCAL_SOURCE_NOTE.to_string()),
                partial_days: BTreeSet::new(),
                api_estimate_by_day: scan.api_estimate_by_day.clone(),
                estimated_cost_days: scan.estimated_cost_days.clone(),
            };
            append_token_usage(&scan.series, &mut result.lines, ctx.now, &opts);
            result.usage_history = Some(ProviderUsageHistory {
                series: scan.series.clone(),
                model_usage: scan.model_usage.clone(),
                unknown_models_by_day: scan.unknown_models_by_day.clone(),
                api_estimate_by_day: scan.api_estimate_by_day.clone(),
                api_estimate_incomplete_days: scan.api_estimate_incomplete_days.clone(),
                partial_days: None,
                estimated_cost_days: scan.estimated_cost_days.clone(),
            });
            result.history_refreshed_at = Some(ctx.now);
        }

        let mut warnings = Vec::new();
        if let Some(failure) = &usage.sqlite_read_failure {
            qlog!(
                Warn,
                auth_tag(ID),
                "ZCode token history read failed: {failure}"
            );
            warnings.push(UNREADABLE_HISTORY_WARNING.to_string());
        }
        if usage.damaged_rows > 0 {
            diagnostic_gate::log_once("zcode.damaged-usage-rows", || {
                qlog!(
                    Warn,
                    auth_tag(ID),
                    "ZCode history had {} invalid rows; totals exclude them",
                    usage.damaged_rows
                );
            });
            let plural = if usage.damaged_rows == 1 { "" } else { "s" };
            warnings.push(format!(
                "Skipped {} invalid ZCode usage row{plural}; recent totals may be slightly low.",
                usage.damaged_rows
            ));
        }
        if !warnings.is_empty() {
            result.history_warning = Some(warnings.join(" · "));
        }

        result
    }
}

fn promo_line(promo: &ZCodeAllowance, now: f64) -> MetricLine {
    let (detail, resets_at) = if let Some(eff) = promo.effective_at.filter(|&e| e > now) {
        (
            Some(deadline_label("Starts", eff, now)),
            promo.expires_at.or(Some(eff)),
        )
    } else if let Some(exp) = promo.expires_at {
        (Some(deadline_label("Expires", exp, now)), Some(exp))
    } else {
        (None, promo.resets_at)
    };
    MetricLine::Progress {
        label: promo.label.clone(),
        used: promo.used,
        limit: promo.limit,
        format: ProgressFormat::Count("tokens".to_string()),
        resets_at,
        period_duration_ms: None,
        color_hex: None,
        detail,
    }
}

/// Format `"Starts in ..."` / `"Expires soon"` matching `Formatters.deadlineLabel(..., mode: .relative)`.
pub fn deadline_label(verb: &str, date: f64, now: f64) -> String {
    let seconds = date - now;
    if seconds <= 5.0 * 60.0 {
        return format!("{verb} soon");
    }
    let total_minutes = (seconds / 60.0).ceil().max(1.0) as i64;
    let total_hours = total_minutes / 60;
    let minutes = total_minutes % 60;
    let days = total_hours / 24;
    let hours = total_hours % 24;
    let span = if days > 0 {
        if hours > 0 {
            format!("{days}d {hours}h")
        } else {
            format!("{days}d")
        }
    } else if total_hours > 0 {
        if minutes > 0 {
            format!("{total_hours}h {minutes}m")
        } else {
            format!("{total_hours}h")
        }
    } else {
        format!("{total_minutes}m")
    };
    format!("{verb} in {span}")
}
