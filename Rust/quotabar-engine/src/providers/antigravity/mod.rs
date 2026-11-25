//! Antigravity quota and local conversation accounting (`Providers/Antigravity`).
//!
//! Probe order: Antigravity's language server, then `agy`'s, then Google Cloud Code with the
//! Keychain token. Each source prefers `RetrieveUserQuotaSummary` (merged pools + weekly windows);
//! legacy per-model endpoints only run when the summary RPC is absent.

mod auth;
mod client;
mod discovery;
mod mapper;
mod proto;
mod scanner;

use self::auth::{AntigravityAuth, AuthError};
use self::client::{AntigravityClient, CloudCodeBatch, CloudCodeOutcome, TokenRefresh};
use self::discovery::{Discovered, Options};
use self::mapper::QuotaSummary;
use self::scanner::{AntigravityScanResult, AntigravityScanner};
use super::{cancelled_snapshot, ProviderRuntime};
use crate::accounting::{
    append_token_usage, append_usage_trend, DayZone, TokenUsageOptions, UsageHistoryWindow,
};
use crate::context::RefreshContext;
use crate::host::{self, SecureAccount, SecureReadOutcome, SecureReadRequest};
use crate::model::{
    ErrorCategory, MetricLine, ProviderInfo, ProviderSnapshot, ProviderUsageHistory,
};
use crate::pricing::{self, ModelPricing};
use crate::qlog;
use std::sync::Arc;

pub const ID: &str = "antigravity";
const USAGE_SOURCE_NOTE: &str = "From your Antigravity conversations";
const SUMMARY_INCOMPLETE_WARNING: &str =
    "Some Antigravity quota limits could not be read. Missing limits may retain older values.";
const SUMMARY_UNREADABLE_WARNING: &str =
    "Antigravity quota summary could not be read. Existing limits are retained.";
const HISTORY_UNREADABLE_WARNING: &str =
    "Antigravity conversation history could not be updated. Any displayed totals are last known and may be stale.";
const HISTORY_PARTIAL_WARNING: &str =
    "Some Antigravity history could not be dated or counted. Visible totals are lower bounds.";
const HISTORY_FAILED_WARNING: &str =
    "Some Antigravity conversation stores could not be read. Visible totals are lower bounds.";
const HISTORY_PARTIAL_FAILED_WARNING: &str = "Some Antigravity conversation stores could not be read, and some history could not be dated or counted. Visible totals are lower bounds.";

const ANTIGRAVITY_SERVER: Options = Options {
    process_name: "language_server",
    markers: &["antigravity", "antigravity-ide"],
    csrf_flag: "--csrf_token",
    port_flag: Some("--extension_server_port"),
};
const AGY_SERVER: Options = Options {
    process_name: "agy",
    markers: &[],
    csrf_flag: "",
    port_flag: None,
};

struct StrategyResult {
    plan: Option<String>,
    lines: Vec<MetricLine>,
    replaces_prior_quota_progress: bool,
    warning: Option<String>,
}

impl StrategyResult {
    fn empty() -> Self {
        StrategyResult {
            plan: None,
            lines: Vec::new(),
            replaces_prior_quota_progress: false,
            warning: None,
        }
    }
}

#[derive(Clone)]
struct HistoryResult {
    history: Option<ProviderUsageHistory>,
    lines: Vec<MetricLine>,
    warning: Option<String>,
}

pub struct AntigravityProvider {
    info: ProviderInfo,
    auth: AntigravityAuth,
    client: AntigravityClient,
    scanner: AntigravityScanner,
    pricing_override: Option<Arc<ModelPricing>>,
}

impl AntigravityProvider {
    pub fn live() -> Self {
        AntigravityProvider {
            info: ProviderInfo {
                id: ID.into(),
                display_name: "Antigravity".into(),
            },
            auth: AntigravityAuth::live(),
            client: AntigravityClient::live(),
            scanner: AntigravityScanner::live(),
            pricing_override: None,
        }
    }

    pub fn with_parts(
        auth: AntigravityAuth,
        client: AntigravityClient,
        scanner: AntigravityScanner,
    ) -> Self {
        AntigravityProvider {
            info: ProviderInfo {
                id: ID.into(),
                display_name: "Antigravity".into(),
            },
            auth,
            client,
            scanner,
            pricing_override: None,
        }
    }

    pub fn with_pricing_override(mut self, pricing: Arc<ModelPricing>) -> Self {
        self.pricing_override = Some(pricing);
        self
    }

    fn pricing(&self, ctx: &RefreshContext) -> Arc<ModelPricing> {
        self.pricing_override.clone().unwrap_or_else(|| {
            pricing::shared()
                .current(ctx.skip_model_catalog_refresh || ctx.scope.suppresses_live_quota())
        })
    }

    fn probe(&self, ctx: &RefreshContext) -> Result<StrategyResult, (String, ErrorCategory)> {
        if ctx.is_cancelled() {
            return Err(("Refresh cancelled.".into(), ErrorCategory::Cancelled));
        }
        if let Some(snapshot) = discovery::process_snapshot() {
            if let Some(result) = self.probe_ls(&ANTIGRAVITY_SERVER, &snapshot, ctx)? {
                return Ok(result);
            }
            if let Some(result) = self.probe_ls(&AGY_SERVER, &snapshot, ctx)? {
                return Ok(result);
            }
        }
        self.probe_cloud_code(ctx)
    }

    fn probe_ls(
        &self,
        options: &Options,
        snapshot: &str,
        ctx: &RefreshContext,
    ) -> Result<Option<StrategyResult>, (String, ErrorCategory)> {
        let Some(discovered) = discovery::discover(options, snapshot) else {
            return Ok(None);
        };
        for endpoint in endpoints(&discovered) {
            if ctx.is_cancelled() {
                return Err(("Refresh cancelled.".into(), ErrorCategory::Cancelled));
            }
            if let Some(summary) = self.client.call_ls(
                &endpoint.0,
                endpoint.1,
                &discovered.csrf,
                "RetrieveUserQuotaSummary",
                &ctx.cancel,
            ) {
                if summary.is_success() {
                    if let Some(parsed) = mapper::parse_quota_summary(&summary.body) {
                        let plan = self
                            .client
                            .call_ls(
                                &endpoint.0,
                                endpoint.1,
                                &discovered.csrf,
                                "GetUserStatus",
                                &ctx.cancel,
                            )
                            .filter(|status| status.is_success())
                            .and_then(|status| mapper::parse_user_status(&status.body))
                            .and_then(|status| status.plan);
                        return Ok(Some(strategy_from_summary(parsed, plan)));
                    }
                    return Ok(Some(StrategyResult {
                        plan: None,
                        lines: Vec::new(),
                        replaces_prior_quota_progress: false,
                        warning: Some(SUMMARY_UNREADABLE_WARNING.into()),
                    }));
                }
                if summary.status != 404 {
                    qlog!(
                        Warn,
                        host::plugin_tag(ID),
                        "RetrieveUserQuotaSummary HTTP {}; falling back to legacy quota endpoints",
                        summary.status
                    );
                }
            }
            let Some(status) = self
                .client
                .call_ls(
                    &endpoint.0,
                    endpoint.1,
                    &discovered.csrf,
                    "GetUserStatus",
                    &ctx.cancel,
                )
                .filter(|status| status.is_success())
            else {
                continue;
            };
            if let Some(parsed) = mapper::parse_user_status(&status.body) {
                let lines = mapper::build_lines(&parsed.configs);
                if !lines.is_empty() {
                    return Ok(Some(StrategyResult {
                        plan: parsed.plan,
                        lines,
                        replaces_prior_quota_progress: true,
                        warning: None,
                    }));
                }
            }
            if let Some(fallback) = self
                .client
                .call_ls(
                    &endpoint.0,
                    endpoint.1,
                    &discovered.csrf,
                    "GetCommandModelConfigs",
                    &ctx.cancel,
                )
                .filter(|fallback| fallback.is_success())
            {
                if let Some(configs) = mapper::parse_command_model_configs(&fallback.body) {
                    let lines = mapper::build_lines(&configs);
                    if !lines.is_empty() {
                        return Ok(Some(StrategyResult {
                            plan: None,
                            lines,
                            replaces_prior_quota_progress: true,
                            warning: None,
                        }));
                    }
                }
            }
        }
        Ok(None)
    }

    fn probe_cloud_code(
        &self,
        ctx: &RefreshContext,
    ) -> Result<StrategyResult, (String, ErrorCategory)> {
        let token = self
            .auth
            .load_keychain_token(ctx.is_manual, ctx.request_id)
            .map_err(auth_failure)?;
        let Some(token) = token else {
            self.auth.discard_cached_token();
            return Err((
                AuthError::NotSignedIn.message().into(),
                ErrorCategory::NotLoggedIn,
            ));
        };
        if let Some(identity) = auth::cache_identity_key(&token) {
            ctx.set_observed_identity_key(identity);
        }
        let mut attempts: Vec<(String, bool)> = Vec::new();
        if let Some(access) = token
            .access_token
            .as_deref()
            .filter(|_| self.auth.is_usable(token.expiry, ctx.now))
        {
            attempts.push((access.to_string(), false));
        }
        if let Some(cached) = self.auth.load_cached_token(&token, ctx.now) {
            if !attempts.iter().any(|(value, _)| *value == cached) {
                attempts.push((cached, true));
            }
        }
        let had_attempts = !attempts.is_empty();
        let has_credentials = had_attempts
            || token
                .refresh_token
                .as_deref()
                .is_some_and(|value| !value.is_empty());
        let mut saw_auth_failure = false;
        let mut saw_forbidden = false;
        let mut saw_no_endpoint = false;
        let mut saw_transient = false;
        for (access, derived) in attempts {
            if ctx.is_cancelled() {
                return Err(("Refresh cancelled.".into(), ErrorCategory::Cancelled));
            }
            match self.fetch_cloud_code(&access, ctx) {
                CloudProbe::Success(result) => return Ok(result),
                CloudProbe::AuthFailed => {
                    saw_auth_failure = true;
                    if derived {
                        self.auth.discard_cached_token();
                    }
                }
                CloudProbe::Forbidden => saw_forbidden = true,
                CloudProbe::NotFound => saw_no_endpoint = true,
                CloudProbe::Unavailable => saw_transient = true,
            }
        }
        if (saw_auth_failure || !had_attempts) && token.refresh_token.is_some() {
            match self
                .client
                .refresh_google_token(token.refresh_token.as_deref().unwrap(), &ctx.cancel)
            {
                TokenRefresh::Refreshed {
                    access_token,
                    expires_in,
                } => {
                    if !self
                        .auth
                        .cache_token(
                            &access_token,
                            expires_in,
                            &token,
                            ctx.now,
                            ctx.is_manual,
                            ctx.request_id,
                        )
                        .map_err(auth_failure)?
                    {
                        return Err((
                            AuthError::AuthExpired.message().into(),
                            ErrorCategory::AuthExpired,
                        ));
                    }
                    return match self.fetch_cloud_code(&access_token, ctx) {
                        CloudProbe::Success(result) => Ok(result),
                        CloudProbe::AuthFailed => Err((
                            AuthError::AuthExpired.message().into(),
                            ErrorCategory::AuthExpired,
                        )),
                        CloudProbe::Forbidden => Err((
                            "Antigravity denied access to quota data.".into(),
                            ErrorCategory::AuthInvalid,
                        )),
                        CloudProbe::NotFound => Err((
                            "Antigravity's quota endpoint is unavailable for this account.".into(),
                            ErrorCategory::NotAvailable,
                        )),
                        CloudProbe::Unavailable => Err((
                            "Antigravity is temporarily unavailable. Try again later.".into(),
                            ErrorCategory::Network,
                        )),
                    };
                }
                TokenRefresh::AuthFailed => {
                    return Err((
                        AuthError::AuthExpired.message().into(),
                        ErrorCategory::AuthExpired,
                    ))
                }
                TokenRefresh::ClientConfigurationInvalid => return Err((
                    "QuotaBar's Google OAuth client was rejected. Update QuotaBar and try again."
                        .into(),
                    ErrorCategory::AuthInvalid,
                )),
                TokenRefresh::Unavailable => {
                    return Err((
                        "Antigravity is temporarily unavailable. Try again later.".into(),
                        ErrorCategory::Network,
                    ))
                }
            }
        }
        if saw_auth_failure
            || (had_attempts
                && token.access_token.is_some()
                && !self.auth.is_usable(token.expiry, ctx.now))
        {
            return Err((
                AuthError::AuthExpired.message().into(),
                ErrorCategory::AuthExpired,
            ));
        }
        if saw_forbidden {
            return Err((
                "Antigravity denied access to quota data.".into(),
                ErrorCategory::AuthInvalid,
            ));
        }
        if saw_no_endpoint && !saw_transient {
            return Err((
                "Antigravity's quota endpoint is unavailable for this account.".into(),
                ErrorCategory::NotAvailable,
            ));
        }
        if has_credentials {
            return Err((
                "Antigravity is temporarily unavailable. Try again later.".into(),
                ErrorCategory::Network,
            ));
        }
        Err((
            AuthError::NotSignedIn.message().into(),
            ErrorCategory::NotLoggedIn,
        ))
    }

    fn fetch_cloud_code(&self, token: &str, ctx: &RefreshContext) -> CloudProbe {
        let load_code_assist = self.client.cloud_code(
            client::LOAD_CODE_ASSIST_PATH,
            token,
            "agy",
            &serde_json::json!({}),
            &ctx.cancel,
        );
        let mut saw_not_found = false;
        let mut saw_transient = false;
        match self.client.cloud_code_summaries(token, &ctx.cancel) {
            CloudCodeBatch::AuthFailed => return CloudProbe::AuthFailed,
            CloudCodeBatch::Forbidden => return CloudProbe::Forbidden,
            CloudCodeBatch::NotFound => saw_not_found = true,
            CloudCodeBatch::Unavailable => saw_transient = true,
            CloudCodeBatch::Ok {
                bodies,
                all_hosts_answered,
            } => {
                let plan = match &load_code_assist {
                    CloudCodeOutcome::Ok(body) => mapper::parse_load_code_assist_plan(body),
                    _ => None,
                };
                if let Some(summary) = mapper::parse_quota_summaries(&bodies, all_hosts_answered) {
                    return CloudProbe::Success(strategy_from_summary(summary, plan));
                }
                return CloudProbe::Success(StrategyResult {
                    plan,
                    lines: Vec::new(),
                    replaces_prior_quota_progress: false,
                    warning: Some(SUMMARY_UNREADABLE_WARNING.into()),
                });
            }
        }
        let mut saw_unusable_success = false;

        match self.client.cloud_code(
            client::FETCH_MODELS_PATH,
            token,
            "antigravity",
            &serde_json::json!({}),
            &ctx.cancel,
        ) {
            CloudCodeOutcome::AuthFailed => return CloudProbe::AuthFailed,
            CloudCodeOutcome::Forbidden => return CloudProbe::Forbidden,
            CloudCodeOutcome::NotFound => saw_not_found = true,
            CloudCodeOutcome::Unavailable => saw_transient = true,
            CloudCodeOutcome::Ok(body) => {
                let lines = mapper::build_lines(&mapper::parse_cloud_code_models(&body));
                if !lines.is_empty() {
                    let plan = match &load_code_assist {
                        CloudCodeOutcome::Ok(body) => mapper::parse_load_code_assist_plan(body),
                        _ => None,
                    };
                    return CloudProbe::Success(StrategyResult {
                        plan,
                        lines,
                        replaces_prior_quota_progress: true,
                        warning: None,
                    });
                }
                saw_unusable_success = true;
            }
        }

        let mut plan = None;
        let mut project = None;
        match &load_code_assist {
            CloudCodeOutcome::AuthFailed => return CloudProbe::AuthFailed,
            CloudCodeOutcome::Forbidden => return CloudProbe::Forbidden,
            CloudCodeOutcome::NotFound => saw_not_found = true,
            CloudCodeOutcome::Unavailable => saw_transient = true,
            CloudCodeOutcome::Ok(body) => {
                plan = mapper::parse_load_code_assist_plan(body);
                project = mapper::parse_project(body);
            }
        }
        let body = project
            .as_ref()
            .map(|project| serde_json::json!({ "project": project }))
            .unwrap_or_else(|| serde_json::json!({}));
        let mut quota = self.client.cloud_code(
            client::RETRIEVE_QUOTA_PATH,
            token,
            "agy",
            &body,
            &ctx.cancel,
        );
        if project.is_some() && matches!(quota, CloudCodeOutcome::Unavailable) {
            quota = self.client.cloud_code(
                client::RETRIEVE_QUOTA_PATH,
                token,
                "agy",
                &serde_json::json!({}),
                &ctx.cancel,
            );
        }
        match quota {
            CloudCodeOutcome::AuthFailed => CloudProbe::AuthFailed,
            CloudCodeOutcome::Forbidden => CloudProbe::Forbidden,
            CloudCodeOutcome::NotFound => {
                saw_not_found = true;
                finish_cloud(saw_not_found, saw_unusable_success, saw_transient)
            }
            CloudCodeOutcome::Unavailable => {
                saw_transient = true;
                finish_cloud(saw_not_found, saw_unusable_success, saw_transient)
            }
            CloudCodeOutcome::Ok(data) => {
                let lines = mapper::build_lines(&mapper::parse_quota_buckets(&data));
                if !lines.is_empty() {
                    return CloudProbe::Success(StrategyResult {
                        plan,
                        lines,
                        replaces_prior_quota_progress: true,
                        warning: None,
                    });
                }
                saw_unusable_success = true;
                finish_cloud(saw_not_found, saw_unusable_success, saw_transient)
            }
        }
    }

    fn scan_history(&self, ctx: &RefreshContext, pricing: &ModelPricing) -> Option<HistoryResult> {
        if ctx.is_cancelled() {
            return None;
        }
        let days = UsageHistoryWindow::lifetime_days(ctx.now, DayZone::Local);
        let AntigravityScanResult {
            scan,
            has_read_failures,
        } = self.scanner.scan(days, ctx.now, pricing, &ctx.cancel);
        if ctx.is_cancelled() {
            return None;
        }
        let Some(scan) = scan else {
            return has_read_failures.then(|| HistoryResult {
                history: None,
                lines: Vec::new(),
                warning: Some(HISTORY_UNREADABLE_WARNING.into()),
            });
        };
        let partial_days = scan.unmeasured_usage_days.clone().unwrap_or_default();
        let has_only_unmeasured = scan.series.daily.is_empty() && !partial_days.is_empty();
        let history = (!has_only_unmeasured).then(|| ProviderUsageHistory {
            series: scan.series.clone(),
            model_usage: scan.model_usage.clone(),
            unknown_models_by_day: scan.unknown_models_by_day.clone(),
            api_estimate_by_day: scan.api_estimate_by_day.clone(),
            api_estimate_incomplete_days: scan.api_estimate_incomplete_days.clone(),
            partial_days: scan.unmeasured_usage_days.clone(),
            estimated_cost_days: scan.estimated_cost_days.clone(),
        });
        let mut lines = Vec::new();
        if !has_only_unmeasured {
            let options = TokenUsageOptions {
                estimated: false,
                unknown_models_by_day: scan.unknown_models_by_day.clone(),
                model_usage: scan.model_usage.clone(),
                model_source_note: Some(USAGE_SOURCE_NOTE.into()),
                partial_days: partial_days.clone(),
                api_estimate_by_day: scan.api_estimate_by_day.clone(),
                estimated_cost_days: scan.estimated_cost_days.clone(),
            };
            append_token_usage(&scan.series, &mut lines, ctx.now, &options);
            append_usage_trend(
                &scan.series,
                &mut lines,
                ctx.now,
                USAGE_SOURCE_NOTE,
                &partial_days,
                Some("incomplete Antigravity history is shown as a lower bound"),
            );
        }
        let warning = if partial_days.is_empty() {
            has_read_failures.then(|| HISTORY_FAILED_WARNING.to_string())
        } else if has_read_failures {
            Some(HISTORY_PARTIAL_FAILED_WARNING.to_string())
        } else {
            Some(HISTORY_PARTIAL_WARNING.to_string())
        };
        Some(HistoryResult {
            history,
            lines,
            warning,
        })
    }
}

enum CloudProbe {
    Success(StrategyResult),
    AuthFailed,
    Forbidden,
    NotFound,
    Unavailable,
}

fn finish_cloud(not_found: bool, unusable_success: bool, transient: bool) -> CloudProbe {
    if (not_found || unusable_success) && !transient {
        CloudProbe::NotFound
    } else {
        CloudProbe::Unavailable
    }
}

fn endpoints(discovered: &Discovered) -> Vec<(String, u16)> {
    let mut endpoints = Vec::new();
    for port in &discovered.ports {
        endpoints.push(("https".to_string(), *port));
        endpoints.push(("http".to_string(), *port));
    }
    if let Some(port) = discovered.extension_port {
        endpoints.push(("http".to_string(), port));
    }
    endpoints
}

fn strategy_from_summary(summary: QuotaSummary, plan: Option<String>) -> StrategyResult {
    StrategyResult {
        plan,
        lines: summary.lines,
        replaces_prior_quota_progress: summary.is_complete,
        warning: (!summary.is_complete).then(|| SUMMARY_INCOMPLETE_WARNING.to_string()),
    }
}

fn auth_failure(error: AuthError) -> (String, ErrorCategory) {
    let category = match error {
        AuthError::NotSignedIn => ErrorCategory::NotLoggedIn,
        AuthError::CredentialPermissionRequired => ErrorCategory::CredentialAccess,
        AuthError::InvalidCredentialData | AuthError::CredentialStoreUnreadable => {
            ErrorCategory::AuthInvalid
        }
        AuthError::AuthExpired => ErrorCategory::AuthExpired,
    };
    (error.message().to_string(), category)
}

impl ProviderRuntime for AntigravityProvider {
    fn info(&self) -> &ProviderInfo {
        &self.info
    }

    fn has_local_credentials(&self) -> bool {
        if let Some(snapshot) = discovery::process_snapshot() {
            if discovery::discover(&ANTIGRAVITY_SERVER, &snapshot).is_some()
                || discovery::discover(&AGY_SERVER, &snapshot).is_some()
            {
                return true;
            }
        }
        let request = SecureReadRequest::silent(
            auth::KEYCHAIN_SERVICE,
            SecureAccount::Named(auth::KEYCHAIN_ACCOUNT.into()),
            ID,
        );
        match host::secure_read(&request) {
            SecureReadOutcome::Found { .. } | SecureReadOutcome::InteractionRequired => true,
            // Indeterminate store failures keep the card enabled so refresh can show the repair.
            SecureReadOutcome::Failed { .. } => true,
            _ => false,
        }
    }

    fn unload_caches(&self) {
        AntigravityScanner::unload_caches();
    }

    fn refresh(&self, ctx: &RefreshContext) -> ProviderSnapshot {
        if ctx.is_cancelled() {
            return cancelled_snapshot(&self.info, ctx);
        }
        let may_replace = ctx.scope.refreshes_quota_domain();
        let history = if ctx.scope.skips_local_accounting() {
            None
        } else {
            let pricing = self.pricing(ctx);
            self.scan_history(ctx, &pricing)
        };
        let quota = if ctx.scope.suppresses_live_quota() {
            Ok(StrategyResult::empty())
        } else {
            self.probe(ctx)
        };
        if ctx.is_cancelled() {
            return cancelled_snapshot(&self.info, ctx);
        }
        match quota {
            Ok(result) => {
                if ctx.scope.skips_local_accounting() {
                    let mut snapshot =
                        ProviderSnapshot::new(&self.info, result.plan, result.lines, ctx.now);
                    snapshot.warning = result.warning;
                    snapshot.replaces_prior_quota_progress =
                        may_replace.then_some(result.replaces_prior_quota_progress);
                    return snapshot;
                }
                let mut lines = result.lines;
                if let Some(history) = &history {
                    lines.extend(history.lines.iter().cloned());
                }
                let mut snapshot = ProviderSnapshot::new(&self.info, result.plan, lines, ctx.now);
                snapshot.usage_history =
                    history.as_ref().and_then(|history| history.history.clone());
                snapshot.history_refreshed_at = snapshot.usage_history.as_ref().map(|_| ctx.now);
                snapshot.warning = result.warning;
                snapshot.history_warning =
                    history.as_ref().and_then(|history| history.warning.clone());
                snapshot.replaces_prior_quota_progress =
                    may_replace.then_some(result.replaces_prior_quota_progress);
                snapshot
            }
            Err((message, category)) => {
                let mut snapshot = ProviderSnapshot::error(&self.info, &message, category, ctx.now);
                if let Some(history) = history {
                    snapshot.usage_history = history.history;
                    snapshot.history_refreshed_at =
                        snapshot.usage_history.as_ref().map(|_| ctx.now);
                    snapshot.history_warning = history.warning;
                }
                snapshot
            }
        }
    }
}

#[cfg(test)]
mod tests;
