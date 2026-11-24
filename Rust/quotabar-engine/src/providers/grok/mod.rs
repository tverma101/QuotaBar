//! Grok quota, OAuth refresh, and CLI session-log spend provider (`Providers/Grok`).

pub mod auth;
pub mod client;
pub mod logs;
pub mod mapper;

#[cfg(test)]
mod tests;

use super::auth_retry::{fetch_with_retry, RetryOutcome};
use super::{cancelled_snapshot, ProviderRuntime};
use crate::accounting::{
    append_token_usage, append_usage_trend, DayZone, TokenUsageOptions, UsageHistoryWindow,
};
use crate::context::RefreshContext;
use crate::host::{auth_tag, diagnostic_gate, plugin_tag};
use crate::http::{self, HttpClient, HttpError};
use crate::model::{MetricLine, ProviderInfo, ProviderSnapshot, ProviderUsageHistory};
use crate::pricing;
use crate::providers::claude::util::stable_fingerprint;
use crate::qlog;
use crate::time;
use auth::{GrokAuthError, GrokAuthState, GrokAuthStore, ID};
use logs::GrokLogUsageScanner;
use mapper::GrokUsageError;
use std::sync::{Arc, Mutex};

pub const PLAN_CACHE_INTERVAL_SECS: f64 = 3600.0;
pub const PLAN_FAILURE_DIAGNOSTIC_KEY: &str = "grok.plan.request-failed";
pub const LOCAL_SOURCE_NOTE: &str = "From your Grok logs";

struct PlanCache {
    plan: Option<String>,
    account: String,
    cached_at: f64,
}

pub struct GrokProvider {
    info: ProviderInfo,
    pub auth: Option<GrokAuthStore>,
    http: Arc<dyn HttpClient>,
    logs: Option<GrokLogUsageScanner>,
    plan_cache: Mutex<Option<PlanCache>>,
}

impl GrokProvider {
    pub fn live() -> Self {
        GrokProvider {
            info: ProviderInfo { id: ID.into(), display_name: "Grok".into() },
            auth: None,
            http: http::shared(),
            logs: None,
            plan_cache: Mutex::new(None),
        }
    }

    pub fn new(auth: GrokAuthStore, http: Arc<dyn HttpClient>, logs: GrokLogUsageScanner) -> Self {
        GrokProvider {
            info: ProviderInfo { id: ID.into(), display_name: "Grok".into() },
            auth: Some(auth),
            http,
            logs: Some(logs),
            plan_cache: Mutex::new(None),
        }
    }

    fn effective_auth(&self) -> GrokAuthStore {
        self.auth.clone().unwrap_or_else(GrokAuthStore::live)
    }

    fn refresh_access_token(
        &self,
        store: &GrokAuthStore,
        state: &mut GrokAuthState,
        ctx: &RefreshContext,
    ) -> Result<Option<String>, GrokProviderError> {
        let original = state.clone();
        let Some(rt) = store.refresh_token(&state.entry) else {
            return Ok(None);
        };
        let client_id = store.client_id(&state.entry_key, &state.entry);
        let resp = match client::refresh_token(self.http.as_ref(), &rt, &client_id, &ctx.cancel) {
            Ok(r) => r,
            Err(HttpError::Cancelled) => return Err(GrokProviderError::Cancelled),
            Err(_) => {
                diagnostic_gate::log_once(&refresh_failure_key(store, &original, "transport"), || {
                    qlog!(Warn, auth_tag(ID), "token refresh request failed (transport)");
                });
                return Err(GrokProviderError::Usage(GrokUsageError::ConnectionFailed));
            }
        };
        if ctx.is_cancelled() {
            return Err(GrokProviderError::Cancelled);
        }
        if !resp.is_success() {
            let status = resp.status;
            diagnostic_gate::log_once(&refresh_failure_key(store, &original, &format!("http.{status}")), || {
                qlog!(Warn, auth_tag(ID), "token refresh failed (HTTP {status})");
            });
            if status == 400 || status == 401 {
                return Ok(None);
            }
            return Err(GrokProviderError::Usage(GrokUsageError::RequestFailed(status)));
        }
        let Some(decoded) = client::decode_refresh_response(&resp) else {
            diagnostic_gate::log_once(&refresh_failure_key(store, &original, "invalid-response"), || {
                qlog!(Warn, auth_tag(ID), "token refresh returned an undecodable or empty access token");
            });
            return Ok(None);
        };
        let access_token = decoded.access_token.trim().to_string();
        if access_token.is_empty() {
            diagnostic_gate::log_once(&refresh_failure_key(store, &original, "invalid-response"), || {
                qlog!(Warn, auth_tag(ID), "token refresh returned an undecodable or empty access token");
            });
            return Ok(None);
        }

        diagnostic_gate::clear_prefix(&refresh_diag_prefix(&original.entry_key));
        state.token = access_token.clone();
        state.entry.key = Some(access_token.clone());
        if let Some(new_rt) = decoded.refresh_token.map(|s| s.trim().to_string()).filter(|s| !s.is_empty()) {
            state.entry.refresh_token = Some(new_rt);
        }
        if let Some(new_id) = decoded.id_token.map(|s| s.trim().to_string()).filter(|s| !s.is_empty()) {
            state.entry.id_token = Some(new_id);
        }
        let expires_at = decoded
            .expires_in
            .filter(|e| e.is_finite() && *e > 0.0)
            .map(|e| ctx.now + e)
            .or_else(|| auth::token_expires_at(&access_token))
            .unwrap_or(ctx.now + 3600.0);
        state.entry.expires_at = Some(time::format_iso8601(expires_at));

        match store.save_replacing(state, &original) {
            Ok(()) => diagnostic_gate::clear_prefix(&refresh_diag_prefix(&original.entry_key)),
            Err(err @ (GrokAuthError::AuthConflict | GrokAuthError::CredentialsUnreadable | GrokAuthError::InvalidAuth)) => {
                return Err(GrokProviderError::Auth(err));
            }
            Err(_) => {
                diagnostic_gate::log_once(&refresh_failure_key(store, &original, "persist"), || {
                    qlog!(Error, auth_tag(ID), "failed to persist rotated credentials; using the refreshed token for this session only");
                });
            }
        }
        if ctx.is_cancelled() {
            return Err(GrokProviderError::Cancelled);
        }
        Ok(Some(access_token))
    }

    fn fetch_plan_name(&self, access_token: &str, account: &str, ctx: &RefreshContext) -> Result<Option<String>, ()> {
        if ctx.is_cancelled() {
            return Err(());
        }
        if !ctx.is_manual {
            let guard = self.plan_cache.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(c) = guard.as_ref() {
                if c.account == account && (ctx.now - c.cached_at) < PLAN_CACHE_INTERVAL_SECS {
                    return Ok(c.plan.clone());
                }
            }
        }
        match client::fetch_settings(self.http.as_ref(), access_token, &ctx.cancel) {
            Ok(resp) if resp.is_success() => {
                let plan = mapper::plan_name_from_settings(&resp.body);
                diagnostic_gate::clear(PLAN_FAILURE_DIAGNOSTIC_KEY);
                *self.plan_cache.lock().unwrap_or_else(|e| e.into_inner()) = Some(PlanCache {
                    plan: plan.clone(),
                    account: account.to_string(),
                    cached_at: ctx.now,
                });
                Ok(plan)
            }
            Ok(resp) => {
                let code = resp.status;
                diagnostic_gate::log_once(PLAN_FAILURE_DIAGNOSTIC_KEY, || {
                    qlog!(Warn, plugin_tag(ID), "plan label request failed (HTTP {code})");
                });
                Ok(self.cached_plan_for(account))
            }
            Err(HttpError::Cancelled) => Err(()),
            Err(err) => {
                diagnostic_gate::log_once(PLAN_FAILURE_DIAGNOSTIC_KEY, || {
                    qlog!(Warn, plugin_tag(ID), "plan label request failed (transport): {err}");
                });
                Ok(self.cached_plan_for(account))
            }
        }
    }

    fn cached_plan_for(&self, account: &str) -> Option<String> {
        self.plan_cache
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
            .filter(|c| c.account == account)
            .and_then(|c| c.plan.clone())
    }

    fn probe(&self, store: &GrokAuthStore, state: &mut GrokAuthState, ctx: &RefreshContext) -> Result<ProviderSnapshot, GrokProviderError> {
        if ctx.is_cancelled() {
            return Err(GrokProviderError::Cancelled);
        }
        let mut lines = Vec::new();
        let mut plan = None;
        if !ctx.scope.suppresses_live_quota() {
            let sub = state
                .entry
                .id_token
                .as_deref()
                .or(Some(&state.token))
                .and_then(crate::parse::jwt_payload)
                .and_then(|m| crate::parse::trimmed_string(m.get("sub")))
                .unwrap_or_default();
            let diag_source = format!("{}\n{sub}", state.entry_key);
            let mut working = state.clone();
            let outcome = fetch_with_retry(
                ID,
                &diag_source,
                &working.token.clone(),
                ctx,
                |tok| client::fetch_credits_config(self.http.as_ref(), tok, &ctx.cancel),
                || match self.refresh_access_token(store, &mut working, ctx)? {
                    Some(tok) => Ok(tok),
                    None => Err(GrokProviderError::Auth(GrokAuthError::Expired)),
                },
            );
            *state = working;
            let resp = match outcome {
                RetryOutcome::Response(r) => r,
                RetryOutcome::Cancelled => return Err(GrokProviderError::Cancelled),
                RetryOutcome::ConnectionFailed | RetryOutcome::RetriedConnectionFailed => {
                    return Err(GrokProviderError::Usage(GrokUsageError::ConnectionFailed));
                }
                RetryOutcome::AuthExpired => return Err(GrokProviderError::Auth(GrokAuthError::Expired)),
                RetryOutcome::RefreshError(e) => return Err(e),
            };
            if !resp.is_success() {
                return Err(GrokProviderError::Usage(GrokUsageError::RequestFailed(resp.status)));
            }
            lines = mapper::map_credits_config(&resp.body).map_err(GrokProviderError::Usage)?;
            plan = self.fetch_plan_name(&state.token, &state.entry_key, ctx).map_err(|()| GrokProviderError::Cancelled)?;
        }

        if ctx.scope.skips_local_accounting() {
            return Ok(ProviderSnapshot::new(&self.info, plan, lines, ctx.now));
        }

        let history = self.append_local_usage(&mut lines, ctx);
        Ok(ProviderSnapshot::new(&self.info, plan, lines, ctx.now).with_usage_history(history))
    }

    fn append_local_usage(&self, lines: &mut Vec<MetricLine>, ctx: &RefreshContext) -> Option<ProviderUsageHistory> {
        let days_back = UsageHistoryWindow::lifetime_days(ctx.now, DayZone::Local);
        let skip = ctx.skip_model_catalog_refresh;
        let pricing_fn = || pricing::shared().current(skip);
        let live_scanner;
        let scanner = match &self.logs {
            Some(s) => s,
            None => {
                live_scanner = GrokLogUsageScanner::live();
                &live_scanner
            }
        };
        let scan = scanner.scan(days_back, ctx.now, &pricing_fn, &ctx.cancel)?;
        let opts = TokenUsageOptions {
            estimated: true,
            unknown_models_by_day: scan.unknown_models_by_day.clone(),
            model_usage: scan.model_usage.clone(),
            model_source_note: Some(LOCAL_SOURCE_NOTE.to_string()),
            partial_days: Default::default(),
            api_estimate_by_day: scan.api_estimate_by_day.clone(),
            estimated_cost_days: scan.estimated_cost_days.clone(),
        };
        append_token_usage(&scan.series, lines, ctx.now, &opts);
        append_usage_trend(&scan.series, lines, ctx.now, LOCAL_SOURCE_NOTE, &Default::default(), None);
        Some(ProviderUsageHistory {
            series: scan.series,
            model_usage: scan.model_usage,
            unknown_models_by_day: scan.unknown_models_by_day,
            api_estimate_by_day: scan.api_estimate_by_day,
            api_estimate_incomplete_days: scan.api_estimate_incomplete_days,
            partial_days: None,
            estimated_cost_days: scan.estimated_cost_days,
        })
    }
}

enum GrokProviderError {
    Auth(GrokAuthError),
    Usage(GrokUsageError),
    Cancelled,
}

impl GrokProviderError {
    fn into_snapshot(self, info: &ProviderInfo, ctx: &RefreshContext) -> ProviderSnapshot {
        match self {
            GrokProviderError::Auth(e) => ProviderSnapshot::error(info, e.message(), e.category(), ctx.now),
            GrokProviderError::Usage(e) => ProviderSnapshot::error(info, &e.message(), e.category(), ctx.now),
            GrokProviderError::Cancelled => cancelled_snapshot(info, ctx),
        }
    }
}

impl ProviderRuntime for GrokProvider {
    fn info(&self) -> &ProviderInfo {
        &self.info
    }

    fn has_local_credentials(&self) -> bool {
        match self.effective_auth().load_auth_candidates() {
            Ok(candidates) => !candidates.is_empty(),
            Err(GrokAuthError::CredentialsUnreadable | GrokAuthError::InvalidAuth) => true,
            Err(_) => false,
        }
    }

    fn refresh(&self, ctx: &RefreshContext) -> ProviderSnapshot {
        if ctx.scope.suppresses_live_quota() {
            let mut lines = Vec::new();
            let history = self.append_local_usage(&mut lines, ctx);
            MetricLine::append_no_data_if_needed(&mut lines);
            return ProviderSnapshot::new(&self.info, None, lines, ctx.now).with_usage_history(history);
        }

        let store = self.effective_auth();
        let candidates = match store.load_auth_candidates() {
            Ok(c) => c,
            Err(e) => return GrokProviderError::Auth(e).into_snapshot(&self.info, ctx),
        };
        let mut saw_expired = false;
        let mut refresh_failure: Option<GrokProviderError> = None;

        for mut state in candidates {
            if store.needs_refresh(&state.entry, &state.token, ctx.now) {
                match self.refresh_access_token(&store, &mut state, ctx) {
                    Ok(Some(_)) => {
                        return match self.probe(&store, &mut state, ctx) {
                            Ok(snap) => snap,
                            Err(err) => err.into_snapshot(&self.info, ctx),
                        };
                    }
                    Ok(None) => {}
                    Err(err @ (GrokProviderError::Cancelled | GrokProviderError::Auth(_))) => {
                        return err.into_snapshot(&self.info, ctx);
                    }
                    Err(err @ GrokProviderError::Usage(_)) => {
                        if store.is_expired(&state.entry, &state.token, ctx.now) {
                            if refresh_failure.is_none() {
                                refresh_failure = Some(err);
                            }
                            continue;
                        }
                    }
                }
                if store.is_expired(&state.entry, &state.token, ctx.now) {
                    saw_expired = true;
                    continue;
                }
            }
            return match self.probe(&store, &mut state, ctx) {
                Ok(snap) => snap,
                Err(err) => err.into_snapshot(&self.info, ctx),
            };
        }

        if let Some(err) = refresh_failure {
            return err.into_snapshot(&self.info, ctx);
        }
        if saw_expired {
            return GrokProviderError::Auth(GrokAuthError::Expired).into_snapshot(&self.info, ctx);
        }
        GrokProviderError::Auth(GrokAuthError::InvalidAuth).into_snapshot(&self.info, ctx)
    }

    fn unload_caches(&self) {
        *self.plan_cache.lock().unwrap_or_else(|e| e.into_inner()) = None;
        if let Some(ref scanner) = self.logs {
            scanner.unload_caches();
        }
        logs::unload_global_caches();
    }
}

fn refresh_diag_prefix(entry_key: &str) -> String {
    format!("auth.grok.refresh.{}.", stable_fingerprint(entry_key))
}

fn refresh_failure_key(store: &GrokAuthStore, state: &GrokAuthState, kind: &str) -> String {
    let rt = store.refresh_token(&state.entry).unwrap_or_default();
    format!("{}{}.{kind}", refresh_diag_prefix(&state.entry_key), stable_fingerprint(&rt))
}
