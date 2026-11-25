//! Google Cloud Code quota reads through the native Antigravity app's saved Keychain sign-in
//! (`Providers/Antigravity/AntigravityCloudCode`, native source). Used only when the app's own
//! language server is not reachable; never reads `agy`, T3, or another client's credentials.
//!
//! The native source asks only for `retrieveUserQuotaSummary`, scoped to the sign-in's project
//! from `loadCodeAssist`. It never falls back to per-model endpoints, which fabricate "fully used"
//! meters from missing quota info.

use super::auth::{self, AuthError, KeychainToken};
use super::client::{self, CloudCodeBatch, CloudCodeOutcome, TokenRefresh};
use super::{mapper, strategy_from_summary, AntigravityProvider, StrategyResult, ID};
use crate::context::RefreshContext;
use crate::host;
use crate::model::ErrorCategory;
use crate::qlog;

pub(super) type ProbeError = (String, ErrorCategory);

const ACCESS_DENIED: &str =
    "Google denied access to Antigravity usage. Check that this account and project have access.";
const ENDPOINT_UNAVAILABLE: &str =
    "Antigravity did not provide a supported usage endpoint for this account or app version.";
const TEMPORARILY_UNAVAILABLE: &str =
    "Antigravity usage is temporarily unavailable. Try again shortly.";
const OAUTH_CLIENT_INVALID: &str = "Google rejected QuotaBar's Antigravity OAuth client configuration. Update QuotaBar and try again.";

enum CloudProbe {
    Success(StrategyResult),
    AuthFailed,
    Forbidden,
    NotFound,
    Unavailable,
}

enum CodeAssistLookup {
    Response {
        plan: Option<String>,
        project: Option<String>,
    },
    Failed,
}

fn failure(message: &str, category: ErrorCategory) -> ProbeError {
    (message.to_string(), category)
}

pub(super) fn auth_failure(error: AuthError) -> ProbeError {
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

fn expired() -> ProbeError {
    auth_failure(AuthError::AuthExpired)
}

impl AntigravityProvider {
    pub(super) fn probe_cloud_code(
        &self,
        ctx: &RefreshContext,
    ) -> Result<StrategyResult, ProbeError> {
        let Some(token) = self
            .auth
            .load_keychain_token(ctx.is_manual, ctx.request_id)
            .map_err(auth_failure)?
        else {
            // Proven logout invalidates the derived cache. A Keychain read failure (above) leaves
            // the cache untouched for recovery.
            self.auth.discard_cached_token();
            return Err(auth_failure(AuthError::NotSignedIn));
        };
        if let Some(identity) = auth::cache_identity_key(&token) {
            ctx.set_observed_identity_key(identity);
        }

        let mut attempts: Vec<(String, bool)> = Vec::new();
        let mut has_known_expired_access = false;
        if let Some(access) = token.access_token.as_deref() {
            if self.auth.is_usable(token.expiry, ctx.now) {
                attempts.push((access.to_string(), false));
            } else {
                has_known_expired_access = true;
            }
        }
        if let Some(cached) = self.auth.load_cached_token(&token, ctx.now) {
            if !attempts.iter().any(|(value, _)| *value == cached) {
                attempts.push((cached, true));
            }
        }
        let refresh_token = token
            .refresh_token
            .as_deref()
            .filter(|value| !value.is_empty());
        // Something to authenticate with tells a transient outage apart from "not signed in".
        let has_credentials = !attempts.is_empty() || refresh_token.is_some();

        let mut saw_auth_failure = false;
        let mut saw_forbidden = false;
        let mut saw_no_endpoint = false;
        let mut saw_transient = false;
        for (access, derived) in &attempts {
            if ctx.is_cancelled() {
                return Err(failure("Refresh cancelled.", ErrorCategory::Cancelled));
            }
            match self.fetch_cloud_code(access, ctx) {
                CloudProbe::Success(result) => return Ok(result),
                CloudProbe::AuthFailed => {
                    saw_auth_failure = true;
                    if *derived {
                        self.auth.discard_cached_token();
                    }
                }
                CloudProbe::Forbidden => saw_forbidden = true,
                CloudProbe::NotFound => saw_no_endpoint = true,
                CloudProbe::Unavailable => saw_transient = true,
            }
        }

        // Refresh only on evidence of dead auth: a rejection, no usable token, or a known-expired
        // access token. A transient outage on a live token must not trigger an OAuth refresh.
        if saw_auth_failure || attempts.is_empty() || has_known_expired_access {
            if let Some(refresh_token) = refresh_token {
                return self.refresh_and_fetch(refresh_token, &token, ctx);
            }
        }

        // Reached only without a usable refresh credential.
        if saw_auth_failure {
            return Err(expired());
        }
        if has_known_expired_access && !saw_forbidden && !saw_no_endpoint && !saw_transient {
            return Err(expired());
        }
        if saw_forbidden {
            return Err(failure(ACCESS_DENIED, ErrorCategory::AuthInvalid));
        }
        if saw_no_endpoint && !saw_transient {
            return Err(failure(ENDPOINT_UNAVAILABLE, ErrorCategory::NotAvailable));
        }
        if has_credentials {
            return Err(failure(TEMPORARILY_UNAVAILABLE, ErrorCategory::Network));
        }
        Err(auth_failure(AuthError::NotSignedIn))
    }

    fn refresh_and_fetch(
        &self,
        refresh_token: &str,
        source: &KeychainToken,
        ctx: &RefreshContext,
    ) -> Result<StrategyResult, ProbeError> {
        match self.client.refresh_google_token(refresh_token, &ctx.cancel) {
            TokenRefresh::Refreshed {
                access_token,
                expires_in,
            } => {
                match self.auth.cache_token(
                    &access_token,
                    expires_in,
                    source,
                    ctx.now,
                    ctx.is_manual,
                    ctx.request_id,
                ) {
                    Ok(true) => {}
                    Ok(false) => return Err(expired()),
                    // A one-time Keychain grant authorizes this refresh, but not a second read or
                    // durable caching. The renewed token still serves this refresh; nothing is
                    // written to the derived cache.
                    Err(AuthError::CredentialPermissionRequired) if ctx.is_manual => {
                        qlog!(
                            Debug,
                            host::auth_tag(ID),
                            "using renewed Antigravity sign-in for this refresh only"
                        );
                    }
                    Err(error) => return Err(auth_failure(error)),
                }
                if ctx.is_cancelled() {
                    return Err(failure("Refresh cancelled.", ErrorCategory::Cancelled));
                }
                match self.fetch_cloud_code(&access_token, ctx) {
                    CloudProbe::Success(result) => Ok(result),
                    CloudProbe::AuthFailed => Err(expired()),
                    CloudProbe::Forbidden => {
                        Err(failure(ACCESS_DENIED, ErrorCategory::AuthInvalid))
                    }
                    CloudProbe::NotFound => {
                        Err(failure(ENDPOINT_UNAVAILABLE, ErrorCategory::NotAvailable))
                    }
                    // The refreshed token is valid, so a non-2xx here is a transient outage.
                    CloudProbe::Unavailable => {
                        Err(failure(TEMPORARILY_UNAVAILABLE, ErrorCategory::Network))
                    }
                }
            }
            // The refresh token itself is dead (revoked or expired).
            TokenRefresh::AuthFailed => Err(expired()),
            TokenRefresh::ClientConfigurationInvalid => {
                Err(failure(OAUTH_CLIENT_INVALID, ErrorCategory::AuthInvalid))
            }
            TokenRefresh::Unavailable => {
                Err(failure(TEMPORARILY_UNAVAILABLE, ErrorCategory::Network))
            }
        }
    }

    /// The summary is scoped to the sign-in's project when `loadCodeAssist` reports one; a scoped
    /// request the API refuses is retried unscoped. A parsed summary with no usable meter is an
    /// absent endpoint, never an invented quota.
    fn fetch_cloud_code(&self, token: &str, ctx: &RefreshContext) -> CloudProbe {
        let account = self.load_code_assist(token, ctx);
        let project = match &account {
            CodeAssistLookup::Response { project, .. } => project.clone(),
            CodeAssistLookup::Failed => None,
        };
        let mut outcome = self
            .client
            .cloud_code_summaries(token, project.as_deref(), &ctx.cancel);
        if project.is_some()
            && matches!(
                outcome,
                CloudCodeBatch::AuthFailed | CloudCodeBatch::Forbidden | CloudCodeBatch::NotFound
            )
        {
            outcome = self.client.cloud_code_summaries(token, None, &ctx.cancel);
        }
        match outcome {
            CloudCodeBatch::AuthFailed => CloudProbe::AuthFailed,
            CloudCodeBatch::Forbidden => CloudProbe::Forbidden,
            CloudCodeBatch::NotFound => CloudProbe::NotFound,
            CloudCodeBatch::Unavailable => CloudProbe::Unavailable,
            CloudCodeBatch::Ok {
                bodies,
                all_hosts_answered,
            } => {
                let Some(summary) = mapper::parse_quota_summaries(&bodies, all_hosts_answered)
                else {
                    return CloudProbe::Unavailable;
                };
                if summary.lines.is_empty() {
                    return CloudProbe::NotFound;
                }
                let plan = match account {
                    CodeAssistLookup::Response { plan, .. } => plan,
                    CodeAssistLookup::Failed => None,
                };
                CloudProbe::Success(strategy_from_summary(summary, plan))
            }
        }
    }

    /// Plan and project lookup. The nested metadata identifies this client as the Antigravity IDE.
    fn load_code_assist(&self, token: &str, ctx: &RefreshContext) -> CodeAssistLookup {
        let body = serde_json::json!({
            "metadata": {
                "ideType": "ANTIGRAVITY",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI"
            }
        });
        match self.client.cloud_code(
            client::LOAD_CODE_ASSIST_PATH,
            token,
            &body,
            &client::PLAN_PROJECT_URLS,
            &ctx.cancel,
        ) {
            CloudCodeOutcome::Ok(data) => CodeAssistLookup::Response {
                plan: mapper::parse_load_code_assist_plan(&data),
                project: mapper::parse_project(&data),
            },
            _ => CodeAssistLookup::Failed,
        }
    }
}
