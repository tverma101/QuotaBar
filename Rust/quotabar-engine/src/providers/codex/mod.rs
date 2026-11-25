//! Codex (Swift `Providers/Codex`): CLI/Keychain auth, live rate-limit meters, reset credits, and
//! native rollout + pi spend.

pub mod auth;
pub mod client;
pub mod event;
pub mod mapper;
pub mod proxy;
pub mod raw_usage;
pub mod reset_claim;
pub mod rollout_parse;
pub mod rollout_state;
pub mod router;
pub mod sessions;

pub use auth::{CodexAuth, CodexAuthError, CodexAuthState, CodexAuthStore, CodexTokens};
pub use client::{CodexClient, CodexRefreshError, CodexRefreshResponse};
pub use mapper::{CodexMappedUsage, CodexUsageError};
pub use proxy::{CodexProxyScanResult, CodexProxyScanner};
pub use reset_claim::{ClaimReply, ResetClaimOutcome, ResetCreditsReply};
pub use router::{CodexRouterScanResult, CodexRouterScanner};
pub use sessions::{CodexScanResult, CodexSessionScanner, SharedAttribution};

use super::{cancelled_snapshot, ProviderRuntime};
use crate::accounting::{
    append_token_usage, append_usage_trend, DailyUsageAccumulator, DayZone, TokenUsageOptions,
    UsageHistoryWindow,
};
use crate::context::RefreshContext;
use crate::host::plugin_tag;
use crate::http::{self, HttpClient};
use crate::model::{
    ErrorCategory, MetricLine, ProviderInfo, ProviderSnapshot, ProviderUsageHistory,
};
use crate::paths;
use crate::pricing;
use crate::providers::pi::{PiScanResult, PiUsageScanner};
use crate::qlog;
use crate::time::format_iso8601;
use auth::CodexAuthSource;
use client::auth_error_for_refresh;
use mapper::map_usage_response;
use serde_json::Value;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

pub const ID: &str = "codex";

#[derive(Clone, Debug)]
struct CodexConfig {
    card_id: Option<String>,
    display_name: Option<String>,
    expected_identity_key: Option<String>,
    initial_account_identity_key: Option<String>,
    candidate_auth_homes: Vec<String>,
    additional_auth_homes: Vec<String>,
    log_homes: Vec<String>,
    peer_homes: Vec<String>,
    allows_keychain_fallback: bool,
    allows_unattributed_pi_usage: bool,
    shared_attribution: Option<SharedAttribution>,
}

impl CodexConfig {
    fn from_value(value: Option<&Value>) -> Self {
        let map = value.and_then(Value::as_object);
        let string = |key: &str| {
            map.and_then(|m| m.get(key))
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|v| !v.is_empty())
                .map(str::to_string)
        };
        let strings = |key: &str| {
            map.and_then(|m| m.get(key))
                .and_then(Value::as_array)
                .map(|values| {
                    values
                        .iter()
                        .filter_map(Value::as_str)
                        .map(str::to_string)
                        .collect()
                })
                .unwrap_or_default()
        };
        let flag = |key: &str, default: bool| {
            map.and_then(|m| m.get(key))
                .and_then(Value::as_bool)
                .unwrap_or(default)
        };
        CodexConfig {
            card_id: string("cardID").or_else(|| string("providerID")),
            display_name: string("displayName"),
            expected_identity_key: string("expectedIdentityKey"),
            initial_account_identity_key: string("initialAccountIdentityKey"),
            candidate_auth_homes: strings("candidateAuthHomes"),
            additional_auth_homes: strings("additionalAuthHomes"),
            log_homes: strings("logHomes"),
            peer_homes: strings("peerHomes"),
            allows_keychain_fallback: flag("allowsKeychainFallback", true),
            allows_unattributed_pi_usage: flag("allowsUnattributedPiUsage", true),
            shared_attribution: shared_attribution(map),
        }
    }

    fn expected_identity(&self) -> Option<String> {
        self.expected_identity_key
            .as_deref()
            .map(str::trim)
            .filter(|v| !v.is_empty())
            .map(str::to_lowercase)
    }
}

fn shared_attribution(map: Option<&serde_json::Map<String, Value>>) -> Option<SharedAttribution> {
    let home = map
        .and_then(|m| m.get("sharedAttributionHome"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())?;
    let identity = map
        .and_then(|m| m.get("sharedAttributionIdentity"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())?;
    let keeps_unattributed = map
        .and_then(|m| m.get("sharedAttributionKeepsUnattributed"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    Some(SharedAttribution {
        home: paths::expand_home(home),
        identity: identity.to_string(),
        keeps_unattributed,
    })
}

pub struct CodexProvider {
    info: ProviderInfo,
    http: Arc<dyn HttpClient>,
    home: PathBuf,
    proxy: CodexProxyScanner,
    router: CodexRouterScanner,
    resolved_identity: Mutex<std::collections::HashMap<String, String>>,
}

impl CodexProvider {
    pub fn live() -> Self {
        CodexProvider {
            info: ProviderInfo {
                id: ID.into(),
                display_name: "Codex".into(),
            },
            http: http::shared(),
            home: paths::home(),
            proxy: CodexProxyScanner::live(paths::home()),
            router: CodexRouterScanner::live(paths::home()),
            resolved_identity: Mutex::new(std::collections::HashMap::new()),
        }
    }

    pub fn new(http: Arc<dyn HttpClient>, home: PathBuf) -> Self {
        CodexProvider {
            info: ProviderInfo {
                id: ID.into(),
                display_name: "Codex".into(),
            },
            proxy: CodexProxyScanner::live(home.clone()),
            router: CodexRouterScanner::live(home.clone()),
            http,
            home,
            resolved_identity: Mutex::new(std::collections::HashMap::new()),
        }
    }

    fn info_for(&self, config: &CodexConfig) -> ProviderInfo {
        ProviderInfo {
            id: config
                .card_id
                .clone()
                .unwrap_or_else(|| self.info.id.clone()),
            display_name: config
                .display_name
                .clone()
                .unwrap_or_else(|| self.info.display_name.clone()),
        }
    }

    fn auth_store(&self, config: &CodexConfig) -> CodexAuthStore {
        CodexAuthStore::live(
            config.expected_identity(),
            config.candidate_auth_homes.clone(),
            config.additional_auth_homes.clone(),
        )
    }

    fn log_homes(&self, config: &CodexConfig) -> Vec<PathBuf> {
        let homes: Vec<PathBuf> = if !config.log_homes.is_empty() {
            config
                .log_homes
                .iter()
                .map(|h| paths::expand_home(h))
                .collect()
        } else {
            match std::env::var("CODEX_HOME")
                .ok()
                .filter(|v| !v.trim().is_empty())
            {
                Some(value) => value
                    .split(',')
                    .map(str::trim)
                    .filter(|v| !v.is_empty())
                    .map(paths::expand_home)
                    .collect(),
                None => vec![self.home.join(".codex")],
            }
        };
        if homes.is_empty() {
            vec![self.home.join(".codex")]
        } else {
            homes
        }
    }

    fn scanner(&self, config: &CodexConfig) -> CodexSessionScanner {
        let peers = config
            .peer_homes
            .iter()
            .map(|h| paths::expand_home(h))
            .collect();
        CodexSessionScanner::new(
            self.home.clone(),
            self.log_homes(config),
            peers,
            config.shared_attribution.clone(),
        )
    }

    fn resolved_identity(&self, info: &ProviderInfo, config: &CodexConfig) -> Option<String> {
        config
            .expected_identity()
            .or_else(|| {
                self.resolved_identity
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .get(&info.id)
                    .cloned()
            })
            .or_else(|| {
                config
                    .initial_account_identity_key
                    .as_deref()
                    .map(|v| v.trim().to_lowercase())
            })
    }

    fn remember_identity(&self, info: &ProviderInfo, auth: &CodexAuthState) {
        if let Some(identity) = CodexAuthStore::account_identity(&auth.auth) {
            self.resolved_identity
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .insert(info.id.clone(), identity);
        }
    }

    fn has_credentials(&self, config: &CodexConfig) -> bool {
        let auth = self.auth_store(config);
        let file_candidates = match auth.load_auth_candidates() {
            Ok(candidates) => candidates,
            Err(CodexAuthError::CredentialsUnreadable | CodexAuthError::InvalidAuthPayload) => {
                return true
            }
            Err(_) => return false,
        };
        if file_candidates
            .iter()
            .any(CodexAuthState::has_usable_access_token)
        {
            return true;
        }
        if !config.allows_keychain_fallback {
            return false;
        }
        match auth.load_keychain_auth(None) {
            Ok(Some(state)) => state.has_usable_access_token(),
            Ok(None) => false,
            Err(
                CodexAuthError::CredentialPermissionRequired
                | CodexAuthError::CredentialsUnreadable,
            ) => true,
            Err(_) => false,
        }
    }

    fn refresh_with_config(&self, ctx: &RefreshContext, config: CodexConfig) -> ProviderSnapshot {
        let info = self.info_for(&config);
        if ctx.scope.suppresses_live_quota() {
            let mut lines = Vec::new();
            let history = if let Some(identity) = self.resolved_identity(&info, &config) {
                self.append_local_usage(&info, &config, ctx, &mut lines, Some(&identity))
            } else {
                None
            };
            MetricLine::append_no_data_if_needed(&mut lines);
            return ProviderSnapshot::new(&info, None, lines, ctx.now).with_usage_history(history);
        }

        let auth = self.auth_store(&config);
        let file_candidates = match auth.load_auth_candidates() {
            Ok(candidates) => candidates,
            Err(CodexAuthError::CredentialsUnreadable | CodexAuthError::InvalidAuthPayload) => {
                return self.local_only_snapshot(
                    &info,
                    &config,
                    ctx,
                    CodexAuthError::CredentialsUnreadable,
                )
            }
            Err(error) => return self.local_only_snapshot(&info, &config, ctx, error),
        };
        let mut last_fallback: Option<CodexAuthError> = None;
        for candidate in file_candidates {
            if ctx.is_cancelled() {
                return cancelled_snapshot(&info, ctx);
            }
            match self.probe(ctx, &info, &config, &auth, candidate) {
                Ok(snapshot) => return snapshot,
                Err(ProbeFailure::Auth(error)) if error.allows_auth_fallback() => {
                    last_fallback = Some(error);
                    continue;
                }
                Err(ProbeFailure::Auth(error)) => {
                    return self.local_only_snapshot(&info, &config, ctx, error)
                }
                Err(ProbeFailure::Cancelled) => return cancelled_snapshot(&info, ctx),
                Err(ProbeFailure::Usage(error)) => {
                    if matches!(error, CodexUsageError::ConnectionFailed) {
                        return self.local_only_snapshot(
                            &info,
                            &config,
                            ctx,
                            CodexAuthError::NotLoggedIn,
                        );
                    }
                    return self.local_only_snapshot(
                        &info,
                        &config,
                        ctx,
                        CodexAuthError::CredentialsUnreadable,
                    );
                }
            }
        }

        if config.allows_keychain_fallback {
            match auth.load_keychain_auth(Some(ctx)) {
                Ok(Some(candidate)) if auth.matches_expected_account(&candidate.auth) => {
                    match self.probe(ctx, &info, &config, &auth, candidate) {
                        Ok(snapshot) => return snapshot,
                        Err(ProbeFailure::Cancelled) => return cancelled_snapshot(&info, ctx),
                        Err(ProbeFailure::Auth(error)) => last_fallback = Some(error),
                        Err(ProbeFailure::Usage(_)) => {}
                    }
                }
                Ok(_) => {}
                Err(CodexAuthError::CredentialPermissionRequired) => {
                    return ProviderSnapshot::error(
                        &info,
                        CodexAuthError::CredentialPermissionRequired.message(),
                        ErrorCategory::CredentialAccess,
                        ctx.now,
                    )
                }
                Err(error) => last_fallback = Some(error),
            }
        }
        self.local_only_snapshot(
            &info,
            &config,
            ctx,
            last_fallback.unwrap_or(CodexAuthError::NotLoggedIn),
        )
    }

    fn probe(
        &self,
        ctx: &RefreshContext,
        info: &ProviderInfo,
        config: &CodexConfig,
        auth: &CodexAuthStore,
        initial: CodexAuthState,
    ) -> Result<ProviderSnapshot, ProbeFailure> {
        if ctx.is_cancelled() {
            return Err(ProbeFailure::Cancelled);
        }
        let mut state = initial;
        if !auth.matches_expected_account(&state.auth) {
            return Err(ProbeFailure::Auth(CodexAuthError::TokenConflict));
        }
        self.remember_identity(info, &state);
        let Some(mut access_token) = state
            .auth
            .tokens
            .as_ref()
            .and_then(|t| t.access_token.clone())
            .filter(|v| !v.is_empty())
        else {
            if state.auth.api_key.as_deref().is_some_and(|v| !v.is_empty()) {
                return Err(ProbeFailure::Auth(CodexAuthError::UsageApiKey));
            }
            return Err(ProbeFailure::Auth(CodexAuthError::NotLoggedIn));
        };

        if auth.needs_refresh(&state.auth) {
            if let Ok(Some(live)) = self.reload_live_auth(&state, auth) {
                if let Some(token) = live
                    .auth
                    .tokens
                    .as_ref()
                    .and_then(|t| t.access_token.clone())
                    .filter(|v| !v.is_empty())
                {
                    state = live;
                    access_token = token;
                }
            }
        }
        if auth.needs_refresh(&state.auth) {
            if let Some(refresh_token) = state
                .auth
                .tokens
                .as_ref()
                .and_then(|t| t.refresh_token.clone())
                .filter(|v| !v.is_empty())
            {
                access_token = self.rotate(ctx, &state, &refresh_token, auth)?;
            }
        }
        if !auth.matches_expected_account(&state.auth) {
            return Err(ProbeFailure::Auth(CodexAuthError::TokenConflict));
        }
        self.remember_identity(info, &state);

        let response = self.fetch_usage_with_retry(ctx, &mut state, &access_token, auth)?;
        let current_token = state
            .auth
            .tokens
            .as_ref()
            .and_then(|t| t.access_token.clone())
            .unwrap_or(access_token);
        let account_id = state
            .auth
            .tokens
            .as_ref()
            .and_then(|t| t.account_id.clone());
        let reset_credits = CodexClient::new(self.http.clone())
            .fetch_reset_credits(&current_token, account_id.as_deref(), &ctx.cancel)
            .ok();
        let mut mapped = map_usage_response(&response, reset_credits.as_ref(), ctx.now)
            .map_err(ProbeFailure::Usage)?;

        let history = if ctx.scope.skips_local_accounting() {
            None
        } else {
            let identity = self.resolved_identity(info, config);
            self.append_local_usage(info, config, ctx, &mut mapped.lines, identity.as_deref())
        };
        MetricLine::append_no_data_if_needed(&mut mapped.lines);
        Ok(
            ProviderSnapshot::new(info, mapped.plan, mapped.lines, ctx.now)
                .with_usage_history(history),
        )
    }

    fn fetch_usage_with_retry(
        &self,
        ctx: &RefreshContext,
        state: &mut CodexAuthState,
        access_token: &str,
        auth: &CodexAuthStore,
    ) -> Result<http::Response, ProbeFailure> {
        let client = CodexClient::new(self.http.clone());
        let account_id = state
            .auth
            .tokens
            .as_ref()
            .and_then(|t| t.account_id.clone());
        let first = client
            .fetch_usage(access_token, account_id.as_deref(), &ctx.cancel)
            .map_err(ProbeFailure::Usage)?;
        if first.status != 401 && first.status != 403 {
            return Ok(first);
        }
        if let Ok(Some(live)) = self.reload_live_auth(state, auth) {
            if let Some(token) = live
                .auth
                .tokens
                .as_ref()
                .and_then(|t| t.access_token.clone())
            {
                if token != *access_token && live.auth.tokens == state.auth.tokens {
                    *state = live;
                    let response = client
                        .fetch_usage(&token, account_id.as_deref(), &ctx.cancel)
                        .map_err(ProbeFailure::Usage)?;
                    if response.status != 401 && response.status != 403 {
                        return Ok(response);
                    }
                }
            }
        }
        let refresh_token = state
            .auth
            .tokens
            .as_ref()
            .and_then(|t| t.refresh_token.clone())
            .filter(|v| !v.is_empty())
            .ok_or(ProbeFailure::Auth(CodexAuthError::TokenExpired))?;
        let token = self.rotate(ctx, state, &refresh_token, auth)?;
        let response = client
            .fetch_usage(&token, account_id.as_deref(), &ctx.cancel)
            .map_err(ProbeFailure::Usage)?;
        if response.status == 401 || response.status == 403 {
            return Err(ProbeFailure::Auth(CodexAuthError::TokenExpired));
        }
        Ok(response)
    }

    fn reload_live_auth(
        &self,
        state: &CodexAuthState,
        auth: &CodexAuthStore,
    ) -> Result<Option<CodexAuthState>, CodexAuthError> {
        let candidate = match &state.source {
            CodexAuthSource::File(path) => auth.load_auth(path)?,
            CodexAuthSource::Keychain(account) => auth.load_keychain_account(account, None)?,
        };
        Ok(candidate.filter(|candidate| auth.matches_expected_account(&candidate.auth)))
    }

    fn rotate(
        &self,
        ctx: &RefreshContext,
        state: &CodexAuthState,
        refresh_token: &str,
        auth: &CodexAuthStore,
    ) -> Result<String, ProbeFailure> {
        let original = state.clone();
        let response = CodexClient::new(self.http.clone())
            .refresh_token(refresh_token, &ctx.cancel)
            .map_err(|error| match auth_error_for_refresh(&error) {
                Some(error) => ProbeFailure::Auth(error),
                None => match error {
                    CodexRefreshError::Usage(error) => ProbeFailure::Usage(error),
                    CodexRefreshError::Auth(error) => ProbeFailure::Auth(error),
                },
            })?;
        let mut refreshed = state.clone();
        let tokens = refreshed.auth.tokens.get_or_insert_with(Default::default);
        tokens.access_token = Some(response.access_token.clone());
        if let Some(rotate) = response.refresh_token {
            tokens.refresh_token = Some(rotate);
        }
        if let Some(id_token) = response.id_token {
            tokens.id_token = Some(id_token);
        }
        refreshed.auth.last_refresh = Some(format_iso8601(ctx.now));
        if !auth.matches_expected_account(&refreshed.auth) {
            return Err(ProbeFailure::Auth(CodexAuthError::TokenConflict));
        }
        match auth.save(&refreshed, &original) {
            Ok(()) => {}
            Err(
                CodexAuthError::TokenConflict
                | CodexAuthError::CredentialPermissionRequired
                | CodexAuthError::CredentialsUnreadable
                | CodexAuthError::InvalidAuthPayload,
            ) => return Err(ProbeFailure::Auth(auth_error_for_save(&refreshed, auth))),
            Err(error) => {
                qlog!(
                    Error,
                    plugin_tag(ID),
                    "failed to persist rotated Codex credentials: {error:?}"
                );
            }
        }
        Ok(response.access_token)
    }

    fn append_local_usage(
        &self,
        info: &ProviderInfo,
        config: &CodexConfig,
        ctx: &RefreshContext,
        lines: &mut Vec<MetricLine>,
        account_identity: Option<&str>,
    ) -> Option<ProviderUsageHistory> {
        let _ = account_identity;
        if ctx.is_cancelled() {
            return None;
        }
        let pricing = pricing::shared().current(ctx.skip_model_catalog_refresh);
        let days_back = UsageHistoryWindow::lifetime_days(ctx.now, DayZone::Local);
        let native =
            match self
                .scanner(config)
                .scan_result(days_back, ctx.now, &pricing, &ctx.cancel)
            {
                CodexScanResult::Complete(scan) => scan,
                CodexScanResult::Incomplete => return None,
            };
        if ctx.is_cancelled() {
            return None;
        }
        let proxy = match self.proxy.scan_result(
            account_identity,
            days_back,
            ctx.now,
            &pricing,
            &ctx.cancel,
        ) {
            CodexProxyScanResult::Complete(scan) => scan,
            CodexProxyScanResult::Incomplete => return None,
        };
        if ctx.is_cancelled() {
            return None;
        }
        // Multi-account cards prefer CodexRouter's stamped metering, because a shared `~/.codex`
        // tree mixes accounts. Single/default cards keep logs -> FCC -> router, so native rollouts
        // still win when the router ledger is absent.
        let router_scan = match self.router.scan_result(
            account_identity,
            account_identity.is_none(),
            days_back,
            ctx.now,
            &pricing,
            &ctx.cancel,
        ) {
            CodexRouterScanResult::Complete(scan) => scan,
            CodexRouterScanResult::Incomplete => return None,
        };
        if ctx.is_cancelled() {
            return None;
        }
        let partial_days = router_scan
            .as_ref()
            .and_then(|scan| scan.unmeasured_usage_days.clone())
            .unwrap_or_default();
        let model_identity =
            |model: &str| crate::accounting::codex_cross_source_model_identity(model, &pricing);
        let (core_scan, used_logs, used_proxy, used_router) = if account_identity.is_some() {
            let (router_then_logs, used_logs) =
                DailyUsageAccumulator::merged_preferring_primary_by_model(
                    router_scan.as_ref(),
                    &[native.as_ref()],
                    &model_identity,
                );
            let (with_proxy, used_proxy) =
                DailyUsageAccumulator::merged_preferring_primary_by_model(
                    router_then_logs.as_ref(),
                    &[proxy.as_ref()],
                    &model_identity,
                );
            (with_proxy, used_logs, used_proxy, router_scan.is_some())
        } else {
            let (logs_and_proxy, used_proxy) =
                DailyUsageAccumulator::merged_preferring_primary_by_model(
                    native.as_ref(),
                    &[proxy.as_ref()],
                    &model_identity,
                );
            let (all, used_router) = DailyUsageAccumulator::merged_preferring_primary_by_model(
                logs_and_proxy.as_ref(),
                &[router_scan.as_ref()],
                &model_identity,
            );
            (all, native.is_some(), used_proxy, used_router)
        };
        let pi = if config.allows_unattributed_pi_usage {
            match PiUsageScanner::live().scan_result(
                &info.id,
                days_back,
                ctx.now,
                &pricing,
                &ctx.cancel,
            ) {
                PiScanResult::Complete(scan) => scan,
                PiScanResult::Incomplete => return None,
            }
        } else {
            None
        };
        let saw_pi = pi.is_some();
        let scan = DailyUsageAccumulator::merged(&[core_scan, pi], None)?;
        let source_names = [
            used_logs.then_some("Codex logs"),
            used_proxy.then_some("FCC proxy"),
            used_router.then_some("Codex Router"),
            saw_pi.then_some("pi"),
        ]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>();
        let note = if partial_days.is_empty() {
            format!("From your {}", source_names.join(", "))
        } else {
            qlog!(
                Warn,
                plugin_tag(ID),
                "Some Router requests have no token measurements; affected daily totals are partial"
            );
            format!(
                "From your {}. Some routed requests have no token measurements; totals include measured requests only.",
                source_names.join(", ")
            )
        };
        let opts = TokenUsageOptions {
            estimated: true,
            unknown_models_by_day: scan.unknown_models_by_day.clone(),
            model_usage: scan.model_usage.clone(),
            model_source_note: Some(note.clone()),
            partial_days: partial_days.clone(),
            api_estimate_by_day: scan.api_estimate_by_day.clone(),
            estimated_cost_days: scan.estimated_cost_days.clone(),
        };
        append_token_usage(&scan.series, lines, ctx.now, &opts);
        append_usage_trend(&scan.series, lines, ctx.now, &note, &partial_days, None);
        Some(ProviderUsageHistory {
            series: scan.series,
            model_usage: scan.model_usage,
            unknown_models_by_day: scan.unknown_models_by_day,
            api_estimate_by_day: scan.api_estimate_by_day,
            api_estimate_incomplete_days: scan.api_estimate_incomplete_days,
            partial_days: (!partial_days.is_empty()).then_some(partial_days),
            estimated_cost_days: scan.estimated_cost_days,
        })
    }

    fn local_only_snapshot(
        &self,
        info: &ProviderInfo,
        config: &CodexConfig,
        ctx: &RefreshContext,
        error: CodexAuthError,
    ) -> ProviderSnapshot {
        let mut lines = Vec::new();
        let history = if ctx.scope.skips_local_accounting() {
            None
        } else {
            let identity = self.resolved_identity(info, config);
            self.append_local_usage(info, config, ctx, &mut lines, identity.as_deref())
        };
        MetricLine::append_no_data_if_needed(&mut lines);
        let mut snapshot =
            ProviderSnapshot::new(info, None, lines, ctx.now).with_usage_history(history);
        snapshot.warning = Some(format!(
            "Live Codex limits unavailable: {}",
            error.message()
        ));
        snapshot
    }
}

impl ProviderRuntime for CodexProvider {
    fn info(&self) -> &ProviderInfo {
        &self.info
    }

    fn has_local_credentials(&self) -> bool {
        self.has_credentials(&CodexConfig::from_value(None))
    }

    fn has_local_credentials_with_config(&self, config: Option<&Value>) -> bool {
        self.has_credentials(&CodexConfig::from_value(config))
    }

    fn refresh(&self, ctx: &RefreshContext) -> ProviderSnapshot {
        self.refresh_with_config(ctx, CodexConfig::from_value(ctx.config.as_ref()))
    }

    fn unload_caches(&self) {
        self.resolved_identity
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clear();
        sessions::unload_shared_caches();
        router::unload_shared_caches();
    }
}

fn auth_error_for_save(state: &CodexAuthState, _auth: &CodexAuthStore) -> CodexAuthError {
    if state.has_usable_access_token() {
        CodexAuthError::TokenConflict
    } else {
        CodexAuthError::CredentialsUnreadable
    }
}

enum ProbeFailure {
    Auth(CodexAuthError),
    Usage(CodexUsageError),
    Cancelled,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn config_reads_account_card_fields() {
        let config = CodexConfig::from_value(Some(&json!({
            "cardID": "codex-work",
            "displayName": "Codex Work",
            "expectedIdentityKey": "ACCT",
            "candidateAuthHomes": ["/tmp/a"],
            "logHomes": ["/tmp/a"],
            "allowsKeychainFallback": false
        })));
        assert_eq!(config.card_id.as_deref(), Some("codex-work"));
        assert_eq!(config.expected_identity().as_deref(), Some("acct"));
        assert_eq!(config.candidate_auth_homes, vec!["/tmp/a"]);
        assert!(!config.allows_keychain_fallback);
    }

    #[test]
    fn identity_falls_back_to_the_initial_default() {
        let provider = CodexProvider::new(
            http::mock::MockClient::new(Vec::new()),
            PathBuf::from("/tmp/x"),
        );
        let config = CodexConfig::from_value(Some(&json!({"initialAccountIdentityKey": "Acct"})));
        let info = provider.info_for(&config);
        assert_eq!(
            provider.resolved_identity(&info, &config).as_deref(),
            Some("acct")
        );
    }

    #[test]
    fn local_usage_folds_fcc_proxy_and_router_through_the_provider() {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs_f64();
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let home = std::env::temp_dir().join(format!(
            "quotabar-codex-port-{}-{stamp}",
            std::process::id()
        ));
        std::fs::create_dir_all(home.join(".codex/codex-router")).unwrap();
        let identity = "1118f6f1-8697-4e7b-9112-1771b3e36099";
        let fingerprint = CodexProxyScanner::account_fingerprint(Some(identity)).unwrap();
        let day = crate::accounting::day_key(now - 60.0);

        let database = home.join("usage.db");
        crate::sqlite::execute(
            &database,
            &format!(
                "CREATE TABLE usage_events (provider_id TEXT, local_day TEXT, model TEXT, \
                 input_tokens INTEGER, output_tokens INTEGER, cache_read_input_tokens INTEGER, \
                 cache_creation_input_tokens INTEGER, source TEXT, account_fingerprint TEXT);\
                 INSERT INTO usage_events VALUES ('openai', '{day}', 'gpt-5', 100, 0, 0, 0, 'fcc_proxy', '{fingerprint}');"
            ),
        )
        .unwrap();
        let ledger = home.join(".codex/codex-router/usage-events.jsonl");
        std::fs::write(
            &ledger,
            format!(
                "{}\n",
                json!({
                    "at": crate::time::format_iso8601(now - 60.0),
                    "model": "gpt-5-mini",
                    "provider": "openai",
                    "status": 200,
                    "inputTokens": 25,
                    "outputTokens": 5,
                    "totalTokens": 30,
                    "accountFingerprint": fingerprint,
                })
            ),
        )
        .unwrap();

        let mut provider =
            CodexProvider::new(http::mock::MockClient::new(Vec::new()), home.clone());
        provider.proxy = CodexProxyScanner::new(home.clone(), vec![database]);
        provider.router = CodexRouterScanner::new(home.clone(), vec![ledger], vec![]);
        let config = CodexConfig {
            card_id: Some("codex".into()),
            display_name: None,
            expected_identity_key: Some(identity.into()),
            initial_account_identity_key: None,
            candidate_auth_homes: vec![home.display().to_string()],
            additional_auth_homes: vec![],
            log_homes: vec![home.display().to_string()],
            peer_homes: vec![],
            allows_keychain_fallback: false,
            allows_unattributed_pi_usage: false,
            shared_attribution: None,
        };
        let info = provider.info_for(&config);
        let mut ctx = RefreshContext::new(crate::context::Scope::Full);
        ctx.now = now;
        ctx.skip_model_catalog_refresh = true;
        let mut lines = Vec::new();
        let history = provider
            .append_local_usage(&info, &config, &ctx, &mut lines, Some(identity))
            .expect("history");

        assert_eq!(
            history
                .series
                .daily
                .iter()
                .map(|day| day.total_tokens)
                .sum::<i64>(),
            130
        );
        let models: std::collections::BTreeSet<_> = history
            .model_usage
            .as_ref()
            .expect("model usage")
            .daily
            .iter()
            .flat_map(|day| day.models.iter().map(|model| model.model.clone()))
            .collect();
        assert!(models.contains("gpt-5"), "native proxy rows: {models:?}");
        assert!(models.contains("gpt-5-mini"), "router rows: {models:?}");
        let note = lines
            .iter()
            .find_map(|line| match line {
                MetricLine::Chart { note, .. } => note.clone(),
                _ => None,
            })
            .unwrap_or_default();
        assert!(
            note.contains("FCC proxy") && note.contains("Codex Router"),
            "{note}"
        );
        std::fs::remove_dir_all(&home).ok();
    }
}
