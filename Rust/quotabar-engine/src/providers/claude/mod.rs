//! Claude (Swift `Providers/Claude`): OAuth/Desktop/Keychain credentials, live usage, and local
//! Claude Code session + pi spend.

mod aggregate;
pub mod auth;
pub mod client;
mod dedup;
pub mod desktop;
mod entry;
mod fold_cache;
pub mod gateway;
mod log_parse;
mod logs;
pub mod mapper;
mod owned;
mod ownership;
mod roots;
pub mod util;

pub use aggregate::aggregate;
pub use auth::{
    ClaudeAuthError, ClaudeAuthStore, ClaudeCredentialLoad, ClaudeCredentialState, ClaudeOAuth,
    ClaudeProviderConfig, ClaudeSource, LiveUsageAvailability,
};
pub use client::ClaudeClient;
pub use dedup::{dedup, should_replace, ClaudeEntryDeduplication};
pub use entry::ClaudeEntry;
pub use gateway::{is_hosted_gateway_model, is_opencode_go_gateway_model, CLAUDE_GATEWAY_PREFIXES};
pub use log_parse::{is_valid_semver, parse_line, ClaudeLineParser, LineParse};
pub use logs::{
    ClaudeIncrementalScanner, ClaudeLogConfig, ClaudeLogScanner, ClaudeScanResult, EnvLookup,
    OwnershipFn,
};
pub use mapper::{ClaudeMappedUsage, ClaudeUsageError};
pub use ownership::{read_ownership_prefix, OwnershipLookup, OwnershipPrefix};
pub use roots::{parse_source_identity, usage_files_if_complete};
pub use util::since_date;

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
use crate::pricing;
use crate::providers::pi::{PiScanResult, PiUsageScanner};
use crate::qlog;
use client::{now_for_expiry, parse_refresh_response};
use mapper::{
    format_plan, is_missing_profile_scope_failure, map_usage_response, parse_retry_after_seconds,
    rate_limited_note, rate_limited_usage, rate_limited_warning, MAXIMUM_RETRY_AFTER_SECS,
    MISSING_PROFILE_SCOPE_WARNING,
};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

pub const ID: &str = "claude";
const RATE_LIMIT_COOLDOWN_SECS: f64 = 5.0 * 60.0;
const NOT_LOGGED_IN: &str = "Not logged in. Run `claude` to authenticate.";
const CREDENTIALS_UNREADABLE: &str = "QuotaBar couldn't read Claude Code credentials at ~/.claude/.credentials.json. Check file access, then refresh again.";
const CREDENTIALS_INVALID: &str = "QuotaBar found Claude Code's credentials file, but it is malformed or has no access token. Run `claude` to sign in again, then refresh.";
const DESKTOP_UNREADABLE: &str = "QuotaBar found Claude Desktop login data but couldn't read its config or Cookies database. Check file access, then refresh again.";
const HISTORY_WARNING: &str = "Claude usage history could not be completely read. Any displayed totals are last known and may be stale.";

#[derive(Clone, Default)]
struct LiveCache {
    fingerprint: Option<[u8; 32]>,
    verified_fingerprint: Option<[u8; 32]>,
    last_good: Option<ClaudeMappedUsage>,
    rate_limited_until: Option<f64>,
}

pub struct ClaudeProvider {
    info: ProviderInfo,
    http: Arc<dyn HttpClient>,
    caches: Mutex<HashMap<String, LiveCache>>,
}

impl ClaudeProvider {
    pub fn live() -> Self {
        ClaudeProvider {
            info: ProviderInfo {
                id: ID.into(),
                display_name: "Claude".into(),
            },
            http: http::shared(),
            caches: Mutex::new(HashMap::new()),
        }
    }

    pub fn new(http: Arc<dyn HttpClient>) -> Self {
        ClaudeProvider {
            info: ProviderInfo {
                id: ID.into(),
                display_name: "Claude".into(),
            },
            http,
            caches: Mutex::new(HashMap::new()),
        }
    }

    fn config(&self, ctx: Option<&RefreshContext>) -> (ProviderInfo, ClaudeProviderConfig) {
        let value = ctx.and_then(|c| c.config.clone());
        let config = ClaudeProviderConfig::from_value(value.as_ref());
        let info = ProviderInfo {
            id: config
                .card_id
                .clone()
                .unwrap_or_else(|| self.info.id.clone()),
            display_name: config
                .display_name
                .clone()
                .unwrap_or_else(|| self.info.display_name.clone()),
        };
        (info, config)
    }

    fn cache(&self, info: &ProviderInfo) -> std::sync::MutexGuard<'_, HashMap<String, LiveCache>> {
        let _ = info;
        self.caches.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn auth_store(&self, config: &ClaudeProviderConfig) -> ClaudeAuthStore {
        ClaudeAuthStore::live(config)
    }

    fn scanner(&self, config: &ClaudeProviderConfig) -> ClaudeLogScanner {
        let mut log_config = ClaudeLogConfig::live();
        log_config.account_uuid = config.account_uuid.clone();
        log_config.organization_uuid = config.organization_uuid.clone();
        log_config.allows_unattributed_sessions = config.allows_unattributed_sessions;
        log_config.cache_identity_override = config.card_id.clone();
        ClaudeLogScanner::new(log_config)
    }

    fn has_credentials(&self, config: &ClaudeProviderConfig) -> bool {
        let auth = self.auth_store(config);
        let load = auth.load_credential_set(None, false);
        if load.keychain_read_cancelled {
            return true;
        }
        if load
            .candidates
            .iter()
            .any(ClaudeCredentialState::has_usable_access_token)
        {
            return true;
        }
        if load.keychain_permission_required || load.keychain_read_failed {
            return true;
        }
        if load.credentials_file_unreadable || load.credentials_file_invalid {
            return true;
        }
        if auth.has_keychain_credential_material() != Some(false) {
            return true;
        }
        matches!(
            load.desktop_status,
            crate::providers::claude::desktop::ClaudeDesktopCredentialStatus::PermissionRequired
                | crate::providers::claude::desktop::ClaudeDesktopCredentialStatus::Unreadable
                | crate::providers::claude::desktop::ClaudeDesktopCredentialStatus::Stale
        )
    }

    pub fn refresh_with_config(
        &self,
        ctx: &RefreshContext,
        config: ClaudeProviderConfig,
        info: ProviderInfo,
    ) -> ProviderSnapshot {
        if ctx.scope.suppresses_live_quota() {
            let mut mapped = ClaudeMappedUsage::default();
            return self.snapshot_with_local_usage(&info, &config, ctx, &mut mapped, None);
        }
        self.refresh_credentials(
            ctx,
            &info,
            &config,
            1,
            false,
            None,
            None,
            &self.auth_store(&config),
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn refresh_credentials(
        &self,
        ctx: &RefreshContext,
        info: &ProviderInfo,
        config: &ClaudeProviderConfig,
        credential_reloads_remaining: usize,
        force_desktop_fallback: bool,
        previous_fallback_error: Option<ClaudeAuthError>,
        previous_keychain_error: Option<ClaudeAuthError>,
        auth: &ClaudeAuthStore,
    ) -> ProviderSnapshot {
        if ctx.is_cancelled() {
            return cancelled_snapshot(info, ctx);
        }
        let load: ClaudeCredentialLoad =
            auth.load_credential_set(Some(ctx), force_desktop_fallback);
        if ctx.is_cancelled() {
            return cancelled_snapshot(info, ctx);
        }
        let keychain_access_error = if load.keychain_permission_required {
            Some(ClaudeAuthError::CredentialPermissionRequired)
        } else if load.keychain_read_failed {
            Some(ClaudeAuthError::CredentialKeychainReadFailed)
        } else {
            previous_keychain_error
        };
        let stored = &load.candidates;
        let candidates: Vec<ClaudeCredentialState> = stored
            .iter()
            .filter(|state| {
                state.has_usable_access_token()
                    && (!force_desktop_fallback || state.source == ClaudeSource::Desktop)
            })
            .cloned()
            .collect();

        if load.keychain_permission_required && candidates.is_empty() {
            return auth_error(info, ClaudeAuthError::CredentialPermissionRequired, ctx.now);
        }
        if force_desktop_fallback {
            use crate::providers::claude::desktop::ClaudeDesktopCredentialStatus as Status;
            match load.desktop_status {
                Status::PermissionRequired => {
                    return auth_error(info, ClaudeAuthError::DesktopPermissionRequired, ctx.now)
                }
                Status::Unreadable => {
                    return plain_error(
                        info,
                        DESKTOP_UNREADABLE,
                        ErrorCategory::CredentialAccess,
                        ctx.now,
                    )
                }
                Status::Stale | Status::Invalid | Status::NotFound => {
                    if load.credentials_file_unreadable {
                        return plain_error(
                            info,
                            CREDENTIALS_UNREADABLE,
                            ErrorCategory::CredentialAccess,
                            ctx.now,
                        );
                    }
                    if load.credentials_file_invalid {
                        return plain_error(
                            info,
                            CREDENTIALS_INVALID,
                            ErrorCategory::AuthInvalid,
                            ctx.now,
                        );
                    }
                    if let Some(error) = keychain_access_error {
                        return auth_error(info, error, ctx.now);
                    }
                    if let Some(error) = previous_fallback_error {
                        return auth_error(info, error, ctx.now);
                    }
                }
                Status::NotChecked | Status::Available => {}
            }
        }
        use crate::providers::claude::desktop::ClaudeDesktopCredentialStatus as Status;
        if load.desktop_status == Status::Unreadable {
            return plain_error(
                info,
                DESKTOP_UNREADABLE,
                ErrorCategory::CredentialAccess,
                ctx.now,
            );
        }
        let has_readable_stored = candidates
            .iter()
            .any(|state| state.source != ClaudeSource::Environment);
        if load.credentials_file_unreadable && !has_readable_stored {
            if load.desktop_status == Status::PermissionRequired {
                return auth_error(info, ClaudeAuthError::DesktopPermissionRequired, ctx.now);
            }
            return plain_error(
                info,
                CREDENTIALS_UNREADABLE,
                ErrorCategory::CredentialAccess,
                ctx.now,
            );
        }
        if load.credentials_file_invalid
            && candidates.is_empty()
            && load.desktop_status != Status::PermissionRequired
        {
            return plain_error(
                info,
                CREDENTIALS_INVALID,
                ErrorCategory::AuthInvalid,
                ctx.now,
            );
        }
        let has_live_candidate = candidates
            .iter()
            .any(|state| auth.live_usage_availability(state) == LiveUsageAvailability::Available);
        let desktop_fallback_warning = if !has_live_candidate {
            match load.desktop_status {
                Status::PermissionRequired => {
                    Some(ClaudeAuthError::DesktopPermissionRequired.message())
                }
                Status::Unreadable => Some(DESKTOP_UNREADABLE.to_string()),
                Status::Stale => Some(ClaudeAuthError::DesktopTokenExpired.message()),
                Status::Invalid => Some(ClaudeAuthError::DesktopCredentialsUnavailable.message()),
                Status::NotChecked | Status::NotFound | Status::Available => None,
            }
        } else {
            None
        };
        if candidates.is_empty() {
            match load.desktop_status {
                Status::PermissionRequired => {
                    return auth_error(info, ClaudeAuthError::DesktopPermissionRequired, ctx.now)
                }
                Status::Unreadable => {
                    return plain_error(
                        info,
                        DESKTOP_UNREADABLE,
                        ErrorCategory::CredentialAccess,
                        ctx.now,
                    )
                }
                Status::Stale => {
                    return auth_error(info, ClaudeAuthError::DesktopTokenExpired, ctx.now)
                }
                Status::Invalid => {
                    return auth_error(
                        info,
                        ClaudeAuthError::DesktopCredentialsUnavailable,
                        ctx.now,
                    )
                }
                Status::NotChecked | Status::NotFound | Status::Available => {}
            }
            if load.keychain_read_failed {
                return auth_error(info, ClaudeAuthError::CredentialKeychainReadFailed, ctx.now);
            }
            qlog!(Info, plugin_tag(ID), "no access token, not logged in");
            let mut mapped = ClaudeMappedUsage::default();
            let snapshot = self.snapshot_with_local_usage(
                info,
                config,
                ctx,
                &mut mapped,
                Some(NOT_LOGGED_IN.into()),
            );
            let has_usage = snapshot.usage_history.as_ref().is_some_and(|history| {
                history
                    .series
                    .daily
                    .iter()
                    .any(|day| day.total_tokens > 0 || day.cost_usd.unwrap_or(0.0) > 0.0)
            });
            if has_usage {
                return snapshot;
            }
            return plain_error(info, NOT_LOGGED_IN, ErrorCategory::NotLoggedIn, ctx.now);
        }

        let mut last_fallback_error: Option<ClaudeAuthError> = None;
        for state in &candidates {
            if ctx.is_cancelled() {
                return cancelled_snapshot(info, ctx);
            }
            if !force_desktop_fallback
                && last_fallback_error.is_some()
                && load.desktop_status == Status::NotChecked
                && auth.live_usage_availability(state) == LiveUsageAvailability::InferenceOnlyToken
            {
                return self.refresh_credentials(
                    ctx,
                    info,
                    config,
                    credential_reloads_remaining,
                    true,
                    last_fallback_error,
                    keychain_access_error,
                    auth,
                );
            }
            match self.probe(
                ctx,
                info,
                config,
                auth,
                state,
                stored,
                desktop_fallback_warning.clone(),
            ) {
                Ok(snapshot) => return snapshot,
                Err(ProbeFailure::CredentialsChanged) if credential_reloads_remaining > 0 => {
                    return self.refresh_credentials(
                        ctx,
                        info,
                        config,
                        credential_reloads_remaining - 1,
                        force_desktop_fallback,
                        previous_fallback_error,
                        keychain_access_error,
                        auth,
                    );
                }
                Err(ProbeFailure::Auth(error)) if error.allows_auth_fallback() => {
                    last_fallback_error = Some(error);
                    continue;
                }
                Err(ProbeFailure::Auth(error)) => return auth_error(info, error, ctx.now),
                Err(ProbeFailure::CredentialsChanged) => {
                    return plain_error(
                        info,
                        "Claude login changed during refresh. Refresh again.",
                        ErrorCategory::AuthExpired,
                        ctx.now,
                    )
                }
                Err(ProbeFailure::Cancelled) => return cancelled_snapshot(info, ctx),
                Err(ProbeFailure::Usage(error)) => {
                    return plain_error(info, &error.message(), ErrorCategory::Decoding, ctx.now)
                }
            }
        }
        if !force_desktop_fallback
            && last_fallback_error.is_some()
            && load.desktop_status == Status::NotChecked
        {
            qlog!(
                Info,
                plugin_tag(ID),
                "stored Claude login failed; trying Claude Desktop"
            );
            return self.refresh_credentials(
                ctx,
                info,
                config,
                credential_reloads_remaining,
                true,
                last_fallback_error,
                keychain_access_error,
                auth,
            );
        }
        if load.credentials_file_unreadable {
            return plain_error(
                info,
                CREDENTIALS_UNREADABLE,
                ErrorCategory::CredentialAccess,
                ctx.now,
            );
        }
        if load.keychain_permission_required {
            return auth_error(info, ClaudeAuthError::CredentialPermissionRequired, ctx.now);
        }
        if load.credentials_file_invalid {
            return plain_error(
                info,
                CREDENTIALS_INVALID,
                ErrorCategory::AuthInvalid,
                ctx.now,
            );
        }
        if load.keychain_read_failed {
            return auth_error(info, ClaudeAuthError::CredentialKeychainReadFailed, ctx.now);
        }
        auth_error(
            info,
            last_fallback_error.unwrap_or(ClaudeAuthError::NotLoggedIn),
            ctx.now,
        )
    }

    fn probe(
        &self,
        ctx: &RefreshContext,
        info: &ProviderInfo,
        config: &ClaudeProviderConfig,
        auth: &ClaudeAuthStore,
        state: &ClaudeCredentialState,
        expected: &[ClaudeCredentialState],
        fallback_warning: Option<String>,
    ) -> Result<ProviderSnapshot, ProbeFailure> {
        if ctx.is_cancelled() {
            return Err(ProbeFailure::Cancelled);
        }
        let mut mapped = ClaudeMappedUsage {
            plan: format_plan(
                state.oauth.subscription_type.as_deref(),
                state.oauth.rate_limit_tier.as_deref(),
            ),
            lines: Vec::new(),
            warning: None,
        };
        let mut warning = match auth.live_usage_availability(state) {
            LiveUsageAvailability::Available => {
                mapped = self.fetch_live_usage(ctx, info, auth, state, expected)?;
                mapped.warning.clone()
            }
            LiveUsageAvailability::MissingProfileScope => {
                qlog!(
                    Warn,
                    plugin_tag(ID),
                    "live usage unavailable: credential lacks the user:profile scope"
                );
                Some(MISSING_PROFILE_SCOPE_WARNING.into())
            }
            LiveUsageAvailability::InferenceOnlyToken => None,
        };
        if let Some(fallback) = fallback_warning {
            warning = Some(fallback);
        }
        Ok(self.snapshot_with_local_usage(info, config, ctx, &mut mapped, warning))
    }

    fn fetch_live_usage(
        &self,
        ctx: &RefreshContext,
        info: &ProviderInfo,
        auth: &ClaudeAuthStore,
        initial: &ClaudeCredentialState,
        expected: &[ClaudeCredentialState],
    ) -> Result<ClaudeMappedUsage, ProbeFailure> {
        let cache_key = info.id.clone();
        let mut state = initial.clone();
        let oauth_config = auth.oauth_config().map_err(ProbeFailure::Auth)?;
        let client = ClaudeClient::new(self.http.clone());
        let fingerprint = credential_fingerprint(&state.oauth);
        {
            let mut caches = self.cache(info);
            let cache = caches.entry(cache_key.clone()).or_default();
            if cache.fingerprint != Some(fingerprint) {
                cache.fingerprint = Some(fingerprint);
                cache.last_good = None;
                cache.rate_limited_until = None;
                cache.verified_fingerprint = None;
            }
            if let Some(until) = cache.rate_limited_until {
                if ctx.now < until {
                    let remaining = (until - ctx.now).max(0.0).ceil() as i64;
                    return Ok(rate_limited_snapshot(
                        cache,
                        &state.oauth,
                        Some(remaining.min(MAXIMUM_RETRY_AFTER_SECS)),
                    ));
                }
            }
        }

        if state.oauth.needs_refresh(ctx.now) {
            if let Some(refresh_token) = state.oauth.refresh_token.clone().filter(|v| !v.is_empty())
            {
                self.rotate(ctx, auth, &mut state, &refresh_token, expected)?;
            }
        }

        let mut verification =
            self.verify_if_needed(ctx, auth, &state, &oauth_config, &cache_key)?;
        let first = match verification.take() {
            Some(response) => response,
            None => client
                .fetch_usage(
                    state.oauth.access_token.as_deref().unwrap_or(""),
                    &oauth_config,
                    &ctx.cancel,
                )
                .map_err(|_| ProbeFailure::Usage(ClaudeUsageError::ConnectionFailed))?,
        };

        let response = if is_missing_profile_scope_failure(first.status, &first.body) {
            first
        } else if is_auth_failure(first.status) {
            if state.source == ClaudeSource::Desktop {
                return Err(ProbeFailure::Auth(ClaudeAuthError::DesktopTokenExpired));
            }
            let refresh_token = state
                .oauth
                .refresh_token
                .clone()
                .filter(|v| !v.is_empty())
                .ok_or(ProbeFailure::Auth(ClaudeAuthError::TokenExpired))?;
            self.rotate(ctx, auth, &mut state, &refresh_token, expected)?;
            verification = self.verify_if_needed(ctx, auth, &state, &oauth_config, &cache_key)?;
            let retried = match verification.take() {
                Some(response) => response,
                None => client
                    .fetch_usage(
                        state.oauth.access_token.as_deref().unwrap_or(""),
                        &oauth_config,
                        &ctx.cancel,
                    )
                    .map_err(|_| ProbeFailure::Usage(ClaudeUsageError::ConnectionFailed))?,
            };
            if is_missing_profile_scope_failure(retried.status, &retried.body) {
                retried
            } else if is_auth_failure(retried.status) {
                return Err(ProbeFailure::Auth(ClaudeAuthError::TokenExpired));
            } else {
                retried
            }
        } else {
            first
        };

        if is_missing_profile_scope_failure(response.status, &response.body) {
            return Ok(ClaudeMappedUsage {
                plan: format_plan(
                    state.oauth.subscription_type.as_deref(),
                    state.oauth.rate_limit_tier.as_deref(),
                ),
                lines: Vec::new(),
                warning: Some(MISSING_PROFILE_SCOPE_WARNING.into()),
            });
        }
        if response.status == 429 {
            let retry_after = parse_retry_after_seconds(response.header("retry-after"), ctx.now);
            let cooldown = retry_after
                .unwrap_or(RATE_LIMIT_COOLDOWN_SECS as i64)
                .min(MAXIMUM_RETRY_AFTER_SECS);
            let mut caches = self.cache(info);
            let cache = caches.entry(cache_key).or_default();
            cache.rate_limited_until = Some(ctx.now + cooldown as f64);
            return Ok(rate_limited_snapshot(cache, &state.oauth, retry_after));
        }
        let mapped = map_usage_response(response.status, &response.body, &state.oauth, ctx.now)
            .map_err(ProbeFailure::Usage)?;
        let mut caches = self.cache(info);
        let cache = caches.entry(cache_key).or_default();
        cache.last_good = Some(mapped.clone());
        cache.rate_limited_until = None;
        Ok(mapped)
    }

    fn verify_if_needed(
        &self,
        ctx: &RefreshContext,
        auth: &ClaudeAuthStore,
        state: &ClaudeCredentialState,
        oauth_config: &auth::ClaudeOAuthConfig,
        cache_key: &str,
    ) -> Result<Option<http::Response>, ProbeFailure> {
        let Some(identity) = auth.expected_identity_key.as_deref() else {
            return Ok(None);
        };
        if identity.split('|').count() != 2 {
            return Ok(None);
        }
        let mut hasher = Sha256::new();
        hasher.update(identity.as_bytes());
        hasher.update([0u8]);
        hasher.update(state.oauth.access_token.as_deref().unwrap_or("").as_bytes());
        let fingerprint: [u8; 32] = hasher.finalize().into();
        {
            let mut caches = self.caches.lock().unwrap_or_else(|e| e.into_inner());
            let cache = caches.entry(cache_key.to_string()).or_default();
            if cache.verified_fingerprint == Some(fingerprint) {
                return Ok(None);
            }
        }
        let response = ClaudeClient::new(self.http.clone())
            .verify_account(
                state.oauth.access_token.as_deref().unwrap_or(""),
                identity,
                oauth_config,
                &ctx.cancel,
            )
            .map_err(ProbeFailure::Auth)?;
        if response.is_none() {
            let mut caches = self.caches.lock().unwrap_or_else(|e| e.into_inner());
            caches
                .entry(cache_key.to_string())
                .or_default()
                .verified_fingerprint = Some(fingerprint);
        }
        Ok(response)
    }

    fn rotate(
        &self,
        ctx: &RefreshContext,
        auth: &ClaudeAuthStore,
        state: &mut ClaudeCredentialState,
        refresh_token: &str,
        expected: &[ClaudeCredentialState],
    ) -> Result<(), ProbeFailure> {
        let oauth_config = auth.oauth_config().map_err(ProbeFailure::Auth)?;
        let response = ClaudeClient::new(self.http.clone())
            .refresh_token(refresh_token, &oauth_config, &ctx.cancel)
            .map_err(ProbeFailure::Auth)?;
        let decoded =
            parse_refresh_response(response.status, &response.body).map_err(ProbeFailure::Auth)?;
        state.oauth.access_token = Some(decoded.access_token.clone());
        if let Some(rotate) = decoded.refresh_token {
            state.oauth.refresh_token = Some(rotate);
        }
        if let Some(expires_at) = now_for_expiry(ctx.now, decoded.expires_in) {
            state.oauth.expires_at = Some(expires_at);
        }
        match auth.save(state, expected) {
            Ok(true) => {}
            Ok(false) => return Err(ProbeFailure::CredentialsChanged),
            Err(ClaudeAuthError::CredentialsChanged) => {
                return Err(ProbeFailure::CredentialsChanged)
            }
            Err(error) => {
                qlog!(
                    Error,
                    plugin_tag(ID),
                    "failed to persist rotated Claude credentials: {error:?}"
                );
            }
        }
        Ok(())
    }

    fn snapshot_with_local_usage(
        &self,
        info: &ProviderInfo,
        config: &ClaudeProviderConfig,
        ctx: &RefreshContext,
        mapped: &mut ClaudeMappedUsage,
        warning: Option<String>,
    ) -> ProviderSnapshot {
        if ctx.scope.skips_local_accounting() {
            MetricLine::append_no_data_if_needed(&mut mapped.lines);
            return finish_snapshot(info, mapped, ctx.now, None, warning, None);
        }
        let Some(history) = self.append_local_usage(info, config, ctx, &mut mapped.lines) else {
            MetricLine::append_no_data_if_needed(&mut mapped.lines);
            return finish_snapshot(
                info,
                mapped,
                ctx.now,
                None,
                warning,
                Some(HISTORY_WARNING.into()),
            );
        };
        MetricLine::append_no_data_if_needed(&mut mapped.lines);
        finish_snapshot(info, mapped, ctx.now, Some(history), warning, None)
    }

    fn append_local_usage(
        &self,
        info: &ProviderInfo,
        config: &ClaudeProviderConfig,
        ctx: &RefreshContext,
        lines: &mut Vec<MetricLine>,
    ) -> Option<ProviderUsageHistory> {
        let _ = info;
        if ctx.is_cancelled() {
            return None;
        }
        let pricing = pricing::shared().current(ctx.skip_model_catalog_refresh);
        let days_back = UsageHistoryWindow::lifetime_days(ctx.now, DayZone::Local);
        let scanner = self.scanner(config);
        let native = match scanner.scan_result(days_back, ctx.now, &pricing, &ctx.cancel) {
            ClaudeScanResult::Complete(scan) => scan,
            ClaudeScanResult::Incomplete => return None,
        };
        if ctx.is_cancelled() {
            return None;
        }
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
        let scan = DailyUsageAccumulator::merged(&[native, pi], None)?;
        let note = if saw_pi {
            "From your Claude usage history and pi"
        } else {
            "From your Claude usage history"
        };
        let opts = TokenUsageOptions {
            estimated: true,
            unknown_models_by_day: scan.unknown_models_by_day.clone(),
            model_usage: scan.model_usage.clone(),
            model_source_note: Some(note.into()),
            partial_days: Default::default(),
            api_estimate_by_day: scan.api_estimate_by_day.clone(),
            estimated_cost_days: scan.estimated_cost_days.clone(),
        };
        append_token_usage(&scan.series, lines, ctx.now, &opts);
        append_usage_trend(
            &scan.series,
            lines,
            ctx.now,
            note,
            &Default::default(),
            None,
        );
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

fn finish_snapshot(
    info: &ProviderInfo,
    mapped: &ClaudeMappedUsage,
    now: f64,
    history: Option<ProviderUsageHistory>,
    warning: Option<String>,
    history_warning: Option<String>,
) -> ProviderSnapshot {
    let mut snapshot = ProviderSnapshot::new(info, mapped.plan.clone(), mapped.lines.clone(), now)
        .with_usage_history(history);
    snapshot.warning = warning;
    snapshot.history_warning = history_warning;
    snapshot
}

impl ProviderRuntime for ClaudeProvider {
    fn info(&self) -> &ProviderInfo {
        &self.info
    }

    fn has_local_credentials(&self) -> bool {
        let (_, config) = self.config(None);
        self.has_credentials(&config)
    }

    fn has_local_credentials_with_config(&self, config: Option<&serde_json::Value>) -> bool {
        self.has_credentials(&ClaudeProviderConfig::from_value(config))
    }

    fn refresh(&self, ctx: &RefreshContext) -> ProviderSnapshot {
        let (info, config) = self.config(Some(ctx));
        self.refresh_with_config(ctx, config, info)
    }

    fn unload_caches(&self) {
        self.caches
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clear();
    }
}

fn credential_fingerprint(oauth: &ClaudeOAuth) -> [u8; 32] {
    let mut pair = Sha256::new();
    pair.update(oauth.access_token.as_deref().unwrap_or("").as_bytes());
    let mut outer = Sha256::new();
    outer.update(pair.finalize());
    let mut refresh = Sha256::new();
    refresh.update(oauth.refresh_token.as_deref().unwrap_or("").as_bytes());
    outer.update(refresh.finalize());
    outer.finalize().into()
}

fn rate_limited_snapshot(
    cache: &LiveCache,
    oauth: &ClaudeOAuth,
    retry_after: Option<i64>,
) -> ClaudeMappedUsage {
    match &cache.last_good {
        Some(mapped) => {
            let mut mapped = mapped.clone();
            mapped.lines.push(rate_limited_note(retry_after));
            mapped.warning = Some(rate_limited_warning(retry_after));
            mapped
        }
        None => rate_limited_usage(oauth, retry_after),
    }
}

fn is_auth_failure(status: u16) -> bool {
    matches!(status, 401 | 403)
}

enum ProbeFailure {
    Auth(ClaudeAuthError),
    Usage(ClaudeUsageError),
    CredentialsChanged,
    Cancelled,
}

impl From<ClaudeUsageError> for ProbeFailure {
    fn from(value: ClaudeUsageError) -> Self {
        ProbeFailure::Usage(value)
    }
}

fn auth_error(info: &ProviderInfo, error: ClaudeAuthError, now: f64) -> ProviderSnapshot {
    let category = match error {
        ClaudeAuthError::NotLoggedIn => ErrorCategory::NotLoggedIn,
        ClaudeAuthError::CredentialPermissionRequired
        | ClaudeAuthError::CredentialKeychainReadFailed
        | ClaudeAuthError::DesktopPermissionRequired
        | ClaudeAuthError::DesktopCredentialsUnavailable => ErrorCategory::CredentialAccess,
        ClaudeAuthError::DesktopTokenExpired
        | ClaudeAuthError::SessionExpired
        | ClaudeAuthError::TokenExpired
        | ClaudeAuthError::CredentialsChanged => ErrorCategory::AuthExpired,
        ClaudeAuthError::InvalidOAuthUrl(_) => ErrorCategory::AuthInvalid,
    };
    plain_error(info, &error.message(), category, now)
}

fn plain_error(
    info: &ProviderInfo,
    message: &str,
    category: ErrorCategory,
    now: f64,
) -> ProviderSnapshot {
    ProviderSnapshot::error(info, message, category, now)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::providers::claude::auth::ClaudeOAuthConfig;
    use crate::providers::claude::desktop::ClaudeDesktopCredentialStatus;
    use crate::providers::claude::mapper::MAXIMUM_RESET_HORIZON;
    use crate::providers::claude::mapper::{SESSION_MS, WEEK_MS};
    use serde_json::json;

    #[test]
    fn provider_id_and_display_follow_config() {
        let provider = ClaudeProvider::new(http::mock::MockClient::new(Vec::new()));
        let ctx = RefreshContext {
            config: Some(json!({"cardID": "claude-work", "displayName": "Claude Work"})),
            ..RefreshContext::new(crate::context::Scope::Full)
        };
        let (info, config) = provider.config(Some(&ctx));
        assert_eq!(info.id, "claude-work");
        assert_eq!(info.display_name, "Claude Work");
        assert_eq!(config.card_id.as_deref(), Some("claude-work"));
    }

    #[test]
    fn rate_limited_last_good_is_annotated_once() {
        let oauth = ClaudeOAuth::default();
        let mapped = ClaudeMappedUsage {
            plan: Some("Max".into()),
            lines: vec![],
            warning: None,
        };
        let cache = LiveCache {
            last_good: Some(mapped),
            ..Default::default()
        };
        let result = rate_limited_snapshot(&cache, &oauth, Some(120));
        assert_eq!(result.lines.len(), 1);
        assert_eq!(result.warning.as_deref(), Some("Updates blocked by Anthropic. Be patient — manual refreshes will make it worse. Retrying in ~2m."));
    }

    #[test]
    fn constants_match_swift_periods() {
        assert_eq!(SESSION_MS, 18_000_000);
        assert_eq!(WEEK_MS, 604_800_000);
        assert!(MAXIMUM_RESET_HORIZON > 0.0);
        assert_eq!(
            ClaudeDesktopCredentialStatus::default(),
            ClaudeDesktopCredentialStatus::NotChecked
        );
        let _ = ClaudeOAuthConfig {
            usage_url: String::new(),
            refresh_url: String::new(),
            client_id: String::new(),
        };
    }
}
