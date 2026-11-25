//! Cursor provider runtime (`Providers/Cursor`).

pub mod auth;
pub mod client;
pub mod csv;
pub mod mapper;
mod optional;
pub mod summary;

#[cfg(test)]
mod csv_tests;
#[cfg(test)]
mod tests;

use super::auth_retry::{fetch_with_retry, RetryOutcome};
use super::{cancelled_snapshot, ProviderRuntime};
use crate::accounting::UsageHistoryWindow;
use crate::context::RefreshContext;
use crate::host::{diagnostic_gate, plugin_tag};
use crate::http::{self, HttpClient, HttpError};
use crate::model::{ErrorCategory, ProviderInfo, ProviderSnapshot};
use crate::pricing::{self, ModelPricing};
use crate::{parse, qlog};
use chrono::{DateTime, Days, Local, TimeDelta, TimeZone};
use auth::{
    cache_identity_key, is_token_expired, new_unresolved_identity_key, token_subject, CursorAuthError,
    CursorAuthSource, CursorAuthState, CursorAuthStore,
};
use mapper::{
    append_spend_lines, map_usage, resolved_plan_label, resolved_plan_name, routing_plan_name,
    should_use_request_based_fallback, CursorMappedUsage,
};
use serde_json::{Map, Value};
use std::sync::{Arc, Mutex};

pub const ID: &str = "cursor";

#[derive(Clone, Default)]
struct SpendCache {
    usage_history: Option<crate::model::ProviderUsageHistory>,
}

pub struct CursorProvider {
    pub(super) info: ProviderInfo,
    pub auth: CursorAuthStore,
    pub(super) http: Arc<dyn HttpClient>,
    pricing_override: Option<Arc<ModelPricing>>,
    unresolved_identity_key: String,
    spend_cache: Mutex<SpendCache>,
}

impl CursorProvider {
    pub fn live() -> Self {
        CursorProvider {
            info: ProviderInfo { id: ID.into(), display_name: "Cursor".into() },
            auth: CursorAuthStore::live(),
            http: http::shared(),
            pricing_override: None,
            unresolved_identity_key: new_unresolved_identity_key(),
            spend_cache: Mutex::new(SpendCache::default()),
        }
    }

    pub fn new(auth: CursorAuthStore, http: Arc<dyn HttpClient>) -> Self {
        CursorProvider {
            info: ProviderInfo { id: ID.into(), display_name: "Cursor".into() },
            auth,
            http,
            pricing_override: None,
            unresolved_identity_key: new_unresolved_identity_key(),
            spend_cache: Mutex::new(SpendCache::default()),
        }
    }

    pub fn with_pricing_override(mut self, pricing: Arc<ModelPricing>) -> Self {
        self.pricing_override = Some(pricing);
        self
    }

    fn probe(&self, initial_state: &CursorAuthState, ctx: &RefreshContext) -> ProviderSnapshot {
        let mut auth_state = initial_state.clone();
        if auth_state.access_token.is_empty() || is_token_expired(&auth_state.access_token, ctx.now) {
            match self.rotate_token(&mut auth_state, ctx, false) {
                Ok(()) => {}
                Err(snap) => return snap,
            }
            if ctx.is_cancelled() {
                return cancelled_snapshot(&self.info, ctx);
            }
        }

        if ctx.scope.suppresses_live_quota() {
            return self.finish_with_optional_spend(
                CursorMappedUsage { plan: None, lines: Vec::new() },
                &auth_state.access_token,
                ctx,
            );
        }

        let current_token = auth_state.access_token.clone();
        let diag_source = retry_source_id(&auth_state);
        let outcome = fetch_with_retry(
            ID,
            &diag_source,
            &current_token,
            ctx,
            |tok| client::fetch_usage(self.http.as_ref(), tok, &ctx.cancel),
            || self.rotate_token(&mut auth_state, ctx, true).map(|()| auth_state.access_token.clone()),
        );

        let usage_resp = match outcome {
            RetryOutcome::Response(resp) => resp,
            RetryOutcome::Cancelled => return cancelled_snapshot(&self.info, ctx),
            RetryOutcome::ConnectionFailed | RetryOutcome::RetriedConnectionFailed => {
                return ProviderSnapshot::error(&self.info, "Couldn't reach Cursor. Check your connection.", ErrorCategory::Network, ctx.now);
            }
            RetryOutcome::AuthExpired => {
                return ProviderSnapshot::error(&self.info, CursorAuthError::TokenExpired.message(), ErrorCategory::AuthExpired, ctx.now);
            }
            RetryOutcome::RefreshError(snap) => return snap,
        };
        if ctx.is_cancelled() {
            return cancelled_snapshot(&self.info, ctx);
        }
        if !usage_resp.is_success() {
            return ProviderSnapshot::error(&self.info, &format!("Cursor request failed (HTTP {}).", usage_resp.status), ErrorCategory::http(usage_resp.status), ctx.now);
        }
        let Some(usage) = json_object(&usage_resp.body) else {
            return ProviderSnapshot::error(&self.info, "Cursor returned an unexpected response.", ErrorCategory::Decoding, ctx.now);
        };

        let current_token = auth_state.access_token.clone();
        let (plan_info_name, plan_info_unavailable) = match optional::fetch_plan_name(self, &current_token, ctx) {
            Ok(v) => v,
            Err(()) => return cancelled_snapshot(&self.info, ctx),
        };
        if ctx.is_cancelled() {
            return cancelled_snapshot(&self.info, ctx);
        }

        let routing_plan = routing_plan_name(plan_info_name.as_deref(), auth_state.membership_type.as_deref());
        let display_plan = resolved_plan_name(plan_info_name.as_deref(), auth_state.membership_type.as_deref());
        let (use_fallback, fallback_msg) = should_use_request_based_fallback(&usage, routing_plan.as_deref(), plan_info_unavailable);

        let mut mapped = if use_fallback {
            match optional::fetch_fallback_usage(self, &current_token, display_plan.as_deref().or(routing_plan.as_deref()), fallback_msg, ctx) {
                Ok(m) => m,
                Err(snap) => return snap,
            }
        } else {
            let credit_grants = match optional::fetch_credit_grants(self, &current_token, ctx) {
                Ok(v) => v,
                Err(()) => return cancelled_snapshot(&self.info, ctx),
            };
            let stripe_balance = match optional::fetch_stripe_balance_cents(self, &current_token, ctx) {
                Ok(v) => v,
                Err(()) => return cancelled_snapshot(&self.info, ctx),
            };
            let mut m = match map_usage(&usage, plan_info_name.as_deref(), credit_grants.as_ref(), stripe_balance) {
                Ok(m) => m,
                Err(err) => return ProviderSnapshot::error(&self.info, err.message(), ErrorCategory::Decoding, ctx.now),
            };
            if let Some(lbl) = resolved_plan_label(plan_info_name.as_deref(), auth_state.membership_type.as_deref()) {
                m.plan = Some(lbl);
            }
            if optional::enrich_primary_usage_from_summary_if_needed(self, &current_token, &usage, plan_info_name.as_deref(), auth_state.membership_type.as_deref(), &mut m, ctx).is_err() {
                return cancelled_snapshot(&self.info, ctx);
            }
            m
        };

        if optional::append_grok_bot_usage(self, &current_token, &mut mapped.lines, ctx).is_err() {
            return cancelled_snapshot(&self.info, ctx);
        }
        self.finish_with_optional_spend(mapped, &current_token, ctx)
    }

    fn finish_with_optional_spend(&self, mut mapped: CursorMappedUsage, access_token: &str, ctx: &RefreshContext) -> ProviderSnapshot {
        if ctx.scope.skips_local_accounting() {
            return ProviderSnapshot::new(&self.info, mapped.plan, mapped.lines, ctx.now);
        }
        if ctx.is_cancelled() {
            return cancelled_snapshot(&self.info, ctx);
        }
        let end = ctx.now;
        let Some(start) = usage_export_start(end, &Local) else {
            optional::log_optional_warning("csv", "usage-csv", "window", "usage CSV calendar window could not be determined");
            return ProviderSnapshot::new(&self.info, mapped.plan, mapped.lines, ctx.now);
        };
        let resp = match client::fetch_usage_csv(self.http.as_ref(), access_token, start, end, &ctx.cancel) {
            Ok(Some(r)) if r.is_success() => r,
            Err(HttpError::Cancelled) => return cancelled_snapshot(&self.info, ctx),
            Ok(Some(r)) => {
                optional::log_optional_warning("csv", "usage-csv", &format!("http.{}", r.status), &format!("optional usage CSV request returned HTTP {}", r.status));
                return ProviderSnapshot::new(&self.info, mapped.plan, mapped.lines, ctx.now);
            }
            Ok(None) | Err(_) => return ProviderSnapshot::new(&self.info, mapped.plan, mapped.lines, ctx.now),
        };
        if ctx.is_cancelled() {
            return cancelled_snapshot(&self.info, ctx);
        }
        let Ok(csv_text) = std::str::from_utf8(&resp.body) else {
            optional::log_optional_warning("csv", "usage-csv", "utf8", "usage CSV response was not valid UTF-8");
            return ProviderSnapshot::new(&self.info, mapped.plan, mapped.lines, ctx.now);
        };
        let owned_pricing;
        let pricing = match self.pricing_override.as_deref() {
            Some(p) => p,
            None => {
                owned_pricing = pricing::shared().current(ctx.skip_model_catalog_refresh);
                &owned_pricing
            }
        };
        let parsed = match csv::parse_usage_csv(csv_text, pricing, end + csv::FUTURE_TOLERANCE_SECONDS, &ctx.cancel) {
            Ok(p) => p,
            Err(_) => {
                optional::log_optional_warning("csv", "usage-csv", "malformed", "optional usage CSV response could not be parsed");
                return ProviderSnapshot::new(&self.info, mapped.plan, mapped.lines, ctx.now);
            }
        };
        if ctx.is_cancelled() {
            return cancelled_snapshot(&self.info, ctx);
        }
        if parsed.rejected_row_count > 0 {
            optional::log_optional_warning("csv", "usage-csv", "partial", "withheld partial usage CSV with invalid rows");
            return ProviderSnapshot::new(&self.info, mapped.plan, mapped.lines, ctx.now);
        }
        if parsed.unpriced_grok_bot_row_count > 0 {
            let n = parsed.unpriced_grok_bot_row_count;
            let plural = if n == 1 { "" } else { "s" };
            diagnostic_gate::log_once("auth.cursor.csv.unpriced-grok-bot", || {
                qlog!(Info, plugin_tag(ID), "usage CSV kept {n} Grok Bot row{plural} with measured tokens but no serving-model price");
            });
        } else {
            diagnostic_gate::clear("auth.cursor.csv.unpriced-grok-bot");
        }
        optional::clear_optional_warnings("csv", "usage-csv", &["malformed", "partial", "utf8", "window"]);
        let history = append_spend_lines(&parsed.rows, end, pricing, &mut mapped.lines);
        self.spend_cache.lock().unwrap_or_else(|e| e.into_inner()).usage_history = Some(history.clone());
        ProviderSnapshot::new(&self.info, mapped.plan, mapped.lines, ctx.now).with_usage_history(Some(history))
    }

    fn rotate_token(&self, auth_state: &mut CursorAuthState, ctx: &RefreshContext, force_keychain_refresh: bool) -> Result<(), ProviderSnapshot> {
        if auth_state.source == CursorAuthSource::Keychain && (force_keychain_refresh || auth_state.refresh_token.is_none()) {
            match self.auth.load_auth_state(Some(ctx), ctx.now, true) {
                Ok(Some(reloaded)) if reloaded.source == auth_state.source
                    && reloaded.access_token == auth_state.access_token
                    && (auth_state.refresh_token.is_none() || reloaded.refresh_token == auth_state.refresh_token) => *auth_state = reloaded,
                Ok(_) => return Err(ProviderSnapshot::error(&self.info, CursorAuthError::SessionExpired.message(), ErrorCategory::AuthExpired, ctx.now)),
                Err(CursorAuthError::Cancelled) => return Err(cancelled_snapshot(&self.info, ctx)),
                Err(err) => return Err(ProviderSnapshot::error(&self.info, err.message(), map_auth_err(&err), ctx.now)),
            }
        }
        let Some(ref refresh_tok) = auth_state.refresh_token else {
            return Err(ProviderSnapshot::error(&self.info, CursorAuthError::TokenExpired.message(), ErrorCategory::AuthExpired, ctx.now));
        };
        let resp = match client::refresh_token(self.http.as_ref(), refresh_tok, &ctx.cancel) {
            Ok(r) => r,
            Err(HttpError::Cancelled) => return Err(cancelled_snapshot(&self.info, ctx)),
            Err(_) => return Err(ProviderSnapshot::error(&self.info, "Couldn't reach Cursor. Check your connection.", ErrorCategory::Network, ctx.now)),
        };
        if !resp.is_success() {
            if matches!(resp.status, 400 | 401 | 403) {
                return Err(ProviderSnapshot::error(&self.info, CursorAuthError::SessionExpired.message(), ErrorCategory::AuthExpired, ctx.now));
            }
            return Err(ProviderSnapshot::error(&self.info, &format!("Cursor request failed (HTTP {}).", resp.status), ErrorCategory::http(resp.status), ctx.now));
        }
        let Some(new_access) = json_object(&resp.body).and_then(|o| parse::trimmed_string(o.get("access_token"))) else {
            return Err(ProviderSnapshot::error(&self.info, "Cursor returned an unexpected response.", ErrorCategory::Decoding, ctx.now));
        };
        match self.auth.save_access_token(&new_access, auth_state, ctx.now) {
            Ok(()) => {
                auth_state.access_token = new_access;
                if let Some(id) = cache_identity_key(auth_state) {
                    ctx.set_observed_identity_key(id);
                }
                if ctx.is_cancelled() {
                    return Err(cancelled_snapshot(&self.info, ctx));
                }
                Ok(())
            }
            Err(CursorAuthError::Cancelled) => Err(cancelled_snapshot(&self.info, ctx)),
            Err(err) => Err(ProviderSnapshot::error(&self.info, err.message(), map_auth_err(&err), ctx.now)),
        }
    }
}

impl ProviderRuntime for CursorProvider {
    fn info(&self) -> &ProviderInfo {
        &self.info
    }

    fn has_local_credentials(&self) -> bool {
        self.auth.has_local_credentials()
    }

    fn unload_caches(&self) {
        self.spend_cache.lock().unwrap_or_else(|e| e.into_inner()).usage_history = None;
    }

    fn refresh(&self, ctx: &RefreshContext) -> ProviderSnapshot {
        if ctx.is_cancelled() {
            return cancelled_snapshot(&self.info, ctx);
        }
        let state = match self.auth.load_auth_state(Some(ctx), ctx.now, false) {
            Ok(Some(state)) => {
                ctx.set_observed_identity_key(cache_identity_key(&state).unwrap_or_else(|| self.unresolved_identity_key.clone()));
                state
            }
            Ok(None) => {
                ctx.set_observed_identity_key(self.unresolved_identity_key.clone());
                return ProviderSnapshot::error(&self.info, CursorAuthError::NotLoggedIn.message(), ErrorCategory::NotLoggedIn, ctx.now);
            }
            Err(CursorAuthError::Cancelled) => return cancelled_snapshot(&self.info, ctx),
            Err(err) => return ProviderSnapshot::error(&self.info, err.message(), map_auth_err(&err), ctx.now),
        };
        if ctx.is_cancelled() {
            return cancelled_snapshot(&self.info, ctx);
        }
        self.probe(&state, ctx)
    }
}

fn usage_export_start(now: f64, zone: &impl TimeZone) -> Option<f64> {
    if !now.is_finite() {
        return None;
    }
    let date = DateTime::from_timestamp(now.floor() as i64, 0)?
        .with_timezone(zone)
        .date_naive()
        .checked_sub_days(Days::new(UsageHistoryWindow::PREVIOUS_DAYS as u64))?;
    let midnight = date.and_hms_opt(0, 0, 0)?;
    // Some local zones skip midnight on a clock transition.
    (0..=24 * 60)
        .find_map(|minutes| {
            zone.from_local_datetime(&midnight.checked_add_signed(TimeDelta::minutes(minutes))?)
                .earliest()
        })
        .map(|start| start.timestamp() as f64)
}

pub(super) fn json_object(bytes: &[u8]) -> Option<Map<String, Value>> {
    serde_json::from_slice::<Value>(bytes).ok()?.as_object().cloned()
}

fn retry_source_id(state: &CursorAuthState) -> String {
    let src = match state.source {
        CursorAuthSource::Sqlite => "sqlite",
        CursorAuthSource::Keychain => "keychain",
    };
    let sub = token_subject(&state.access_token).unwrap_or_default();
    format!("{src}\n{sub}")
}

fn map_auth_err(err: &CursorAuthError) -> ErrorCategory {
    match err {
        CursorAuthError::NotLoggedIn => ErrorCategory::NotLoggedIn,
        CursorAuthError::CredentialPermissionRequired | CursorAuthError::CredentialsUnreadable => {
            ErrorCategory::CredentialAccess
        }
        CursorAuthError::SessionExpired | CursorAuthError::TokenExpired => ErrorCategory::AuthExpired,
        CursorAuthError::Cancelled => ErrorCategory::Cancelled,
    }
}
