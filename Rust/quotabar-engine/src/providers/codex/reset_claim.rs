//! Codex rate-limit reset-credit claim (Swift `CodexResetClaimService`).
//!
//! This is the app's only provider-API write. The engine owns credential selection, the credit-list
//! GET, the idempotent consume POST, server outcome parsing, and the session-lived replay ledger.
//! The Swift service keeps only the user-visible orchestration: when to refresh, auto-reset consent,
//! and the outcome the popover renders.

use super::auth::{CodexAuthError, CodexAuthState, CodexAuthStore};
use super::client::CodexClient;
use super::mapper::parse_iso8601;
use crate::context::RefreshContext;
use crate::host::plugin_tag;
use crate::http::{self, HttpClient, Response};
use crate::parse;
use crate::qlog;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

pub const ID: &str = "codex";
pub const AUTOMATIC_LEAD_SECONDS: f64 = 60.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ResetClaimOutcome {
    Success,
    NothingToReset,
    NoCredit,
    CredentialAccess,
    Cancelled,
    Failed,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResetCredit {
    pub id: String,
    pub expires_at: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResetCreditsReply {
    pub credits: Vec<ResetCredit>,
    pub auth_rejected: bool,
    pub credential_access_failed: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaimReply {
    pub outcome: ResetClaimOutcome,
    pub credit_id: Option<String>,
    pub owner_identity: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaimRequest {
    pub expiry: f64,
    pub redeem_request_id: String,
    #[serde(default)]
    pub credit_id: Option<String>,
    #[serde(default)]
    pub owner_identity: Option<String>,
    #[serde(default)]
    pub is_retry: bool,
    #[serde(default)]
    pub automatic: bool,
}

#[derive(Clone, Debug)]
pub struct ClaimConfig {
    pub provider_id: String,
    expected_identity_key: Option<String>,
    candidate_auth_homes: Vec<String>,
    additional_auth_homes: Vec<String>,
    allows_keychain_fallback: bool,
}

impl ClaimConfig {
    pub fn from_value(provider_id: &str, value: Option<&Value>) -> Self {
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
                        .map(str::trim)
                        .filter(|v| !v.is_empty())
                        .map(str::to_string)
                        .collect()
                })
                .unwrap_or_default()
        };
        ClaimConfig {
            provider_id: provider_id.to_string(),
            expected_identity_key: string("expectedIdentityKey").map(|v| v.to_lowercase()),
            candidate_auth_homes: strings("candidateAuthHomes"),
            additional_auth_homes: strings("additionalAuthHomes"),
            allows_keychain_fallback: map
                .and_then(|m| m.get("allowsKeychainFallback"))
                .and_then(Value::as_bool)
                .unwrap_or(true),
        }
    }

    fn auth_store(&self) -> CodexAuthStore {
        CodexAuthStore::live(
            self.expected_identity_key.clone(),
            self.candidate_auth_homes.clone(),
            self.additional_auth_homes.clone(),
        )
    }

    fn owner_identity(&self) -> Option<String> {
        self.expected_identity_key.clone()
    }
}

#[derive(Clone, Debug)]
struct Credential {
    access_token: String,
    account_id: Option<String>,
}

impl Credential {
    fn from_state(state: &CodexAuthState) -> Option<Self> {
        if !state.has_usable_access_token() {
            return None;
        }
        let access_token = state
            .auth
            .tokens
            .as_ref()
            .and_then(|tokens| tokens.access_token.clone())
            .filter(|token| !token.is_empty())?;
        Some(Credential {
            access_token,
            account_id: CodexAuthStore::account_identity(&state.auth),
        })
    }

    fn matches_owner(&self, owner: &Owner) -> bool {
        match (&owner.account_id, &self.account_id) {
            (Some(owner), Some(candidate)) => candidate.eq_ignore_ascii_case(owner),
            (None, None) => self.access_token == owner.access_token,
            _ => false,
        }
    }
}

#[derive(Clone, Debug)]
struct Owner {
    account_id: Option<String>,
    access_token: String,
}

impl Owner {
    fn identity(&self) -> Option<String> {
        self.account_id.clone()
    }
}

#[derive(Clone)]
struct MatchedCredit {
    credit_id: String,
    owner: Owner,
}

fn matched_credits() -> &'static Mutex<HashMap<String, MatchedCredit>> {
    static MATCHED: OnceLock<Mutex<HashMap<String, MatchedCredit>>> = OnceLock::new();
    MATCHED.get_or_init(|| Mutex::new(HashMap::new()))
}

fn matched_key(provider_id: &str, redeem_request_id: &str) -> String {
    format!(
        "{}:{}:{}:{}",
        provider_id.len(),
        provider_id,
        redeem_request_id.len(),
        redeem_request_id
    )
}

struct CredentialLoad {
    credentials: Vec<Credential>,
    access_failed: bool,
    cancelled: bool,
}

fn load_file_credentials(store: &CodexAuthStore, ctx: &RefreshContext) -> CredentialLoad {
    if ctx.is_cancelled() {
        return CredentialLoad {
            credentials: Vec::new(),
            access_failed: false,
            cancelled: true,
        };
    }
    match store.load_auth_candidates() {
        Ok(candidates) => CredentialLoad {
            credentials: candidates
                .iter()
                .filter_map(Credential::from_state)
                .collect(),
            access_failed: false,
            cancelled: false,
        },
        Err(error) => {
            if ctx.is_cancelled() {
                return CredentialLoad {
                    credentials: Vec::new(),
                    access_failed: false,
                    cancelled: true,
                };
            }
            qlog!(
                Error,
                plugin_tag(ID),
                "reset claim could not read auth files: {:?}",
                error
            );
            CredentialLoad {
                credentials: Vec::new(),
                access_failed: !matches!(error, CodexAuthError::NotLoggedIn),
                cancelled: false,
            }
        }
    }
}

fn load_keychain_credentials(store: &CodexAuthStore, ctx: &RefreshContext) -> CredentialLoad {
    if ctx.is_cancelled() {
        return CredentialLoad {
            credentials: Vec::new(),
            access_failed: false,
            cancelled: true,
        };
    }
    match store.load_keychain_auth(Some(ctx)) {
        Ok(Some(state)) => CredentialLoad {
            credentials: Credential::from_state(&state).into_iter().collect(),
            access_failed: false,
            cancelled: false,
        },
        Ok(None) => CredentialLoad {
            credentials: Vec::new(),
            access_failed: false,
            cancelled: false,
        },
        Err(error) => {
            if ctx.is_cancelled() {
                return CredentialLoad {
                    credentials: Vec::new(),
                    access_failed: false,
                    cancelled: true,
                };
            }
            let access_failed = matches!(
                error,
                CodexAuthError::CredentialPermissionRequired
                    | CodexAuthError::CredentialsUnreadable
            );
            if access_failed {
                qlog!(
                    Error,
                    plugin_tag(ID),
                    "reset claim could not read Keychain credentials: {:?}",
                    error
                );
            }
            CredentialLoad {
                credentials: Vec::new(),
                access_failed,
                cancelled: false,
            }
        }
    }
}

/// Available reset credits for the live account. `None` means the lookup could not be performed at
/// all (transport failure or no usable credentials); `authRejected` asks the host to refresh once
/// and retry, matching the old Swift service's rotation retry.
pub fn available_credits(config: &ClaimConfig, ctx: &RefreshContext) -> Option<ResetCreditsReply> {
    available_credits_with_http(config, ctx, http::shared())
}

pub fn available_credits_with_http(
    config: &ClaimConfig,
    ctx: &RefreshContext,
    http: Arc<dyn HttpClient>,
) -> Option<ResetCreditsReply> {
    let file = load_file_credentials(&config.auth_store(), ctx);
    if file.cancelled || ctx.is_cancelled() {
        return None;
    }
    let mut candidates = file.credentials;
    let mut access_failed = file.access_failed;
    let mut keychain_attempted = false;
    if candidates.is_empty() && config.allows_keychain_fallback {
        keychain_attempted = true;
        let keychain = load_keychain_credentials(&config.auth_store(), ctx);
        if keychain.cancelled || ctx.is_cancelled() {
            return None;
        }
        access_failed |= keychain.access_failed;
        candidates = keychain.credentials;
    }
    if candidates.is_empty() {
        return None;
    }

    let first = fetch_available(&candidates, ctx, &http)?;
    if !first.auth_rejected {
        return Some(first);
    }
    if keychain_attempted || !config.allows_keychain_fallback {
        return Some(first);
    }
    let keychain = load_keychain_credentials(&config.auth_store(), ctx);
    if keychain.cancelled || ctx.is_cancelled() {
        return None;
    }
    access_failed |= keychain.access_failed;
    if keychain.credentials.is_empty() {
        return Some(ResetCreditsReply {
            credits: Vec::new(),
            auth_rejected: true,
            credential_access_failed: access_failed,
        });
    }
    candidates.extend(keychain.credentials);
    let second = fetch_available(&candidates, ctx, &http)?;
    Some(ResetCreditsReply {
        credential_access_failed: access_failed,
        ..second
    })
}

fn fetch_available(
    candidates: &[Credential],
    ctx: &RefreshContext,
    http: &Arc<dyn HttpClient>,
) -> Option<ResetCreditsReply> {
    let client = CodexClient::new(http.clone());
    let mut rejected = false;
    for credentials in candidates {
        if ctx.is_cancelled() {
            return None;
        }
        let response = match client.fetch_reset_credits(
            &credentials.access_token,
            credentials.account_id.as_deref(),
            &ctx.cancel,
        ) {
            Ok(response) => response,
            Err(_) => {
                if ctx.is_cancelled() {
                    return None;
                }
                qlog!(Warn, plugin_tag(ID), "auto reset: credit lookup failed");
                return None;
            }
        };
        if ctx.is_cancelled() {
            return None;
        }
        if response.status == 401 || response.status == 403 {
            rejected = true;
            continue;
        }
        if !(200..300).contains(&response.status) {
            qlog!(
                Warn,
                plugin_tag(ID),
                "auto reset: invalid credit list ({})",
                response.status
            );
            return None;
        }
        let Some(body) = parse_object(&response) else {
            qlog!(
                Warn,
                plugin_tag(ID),
                "auto reset: invalid credit list ({})",
                response.status
            );
            return None;
        };
        let Some(raw) = body.get("credits").and_then(Value::as_array) else {
            qlog!(
                Warn,
                plugin_tag(ID),
                "auto reset: invalid credit list ({})",
                response.status
            );
            return None;
        };
        let credits = raw
            .iter()
            .filter_map(|item| {
                let item = item.as_object()?;
                let id = item.get("id").and_then(Value::as_str)?.trim();
                if id.is_empty() {
                    return None;
                }
                if let Some(status) = item.get("status").and_then(Value::as_str) {
                    if status != "available" {
                        return None;
                    }
                }
                if let Some(reset_type) = item.get("reset_type").and_then(Value::as_str) {
                    if reset_type != "codex_rate_limits" {
                        return None;
                    }
                }
                Some(ResetCredit {
                    id: id.to_string(),
                    expires_at: item.get("expires_at").and_then(parse_expiry)?,
                })
            })
            .collect();
        return Some(ResetCreditsReply {
            credits,
            auth_rejected: false,
            credential_access_failed: false,
        });
    }
    Some(ResetCreditsReply {
        credits: Vec::new(),
        auth_rejected: rejected,
        credential_access_failed: false,
    })
}

pub fn claim(config: &ClaimConfig, request: &ClaimRequest, ctx: &RefreshContext) -> ClaimReply {
    claim_with_http(config, request, ctx, http::shared())
}

pub fn claim_with_http(
    config: &ClaimConfig,
    request: &ClaimRequest,
    ctx: &RefreshContext,
    http: Arc<dyn HttpClient>,
) -> ClaimReply {
    if ctx.is_cancelled() {
        return reply(ResetClaimOutcome::Cancelled, None, None);
    }
    if request.automatic {
        if ctx.now >= request.expiry {
            return reply(ResetClaimOutcome::NoCredit, None, None);
        }
        if ctx.now < request.expiry - AUTOMATIC_LEAD_SECONDS {
            return reply(ResetClaimOutcome::Cancelled, None, None);
        }
    }

    let store = config.auth_store();
    let file = load_file_credentials(&store, ctx);
    if file.cancelled || ctx.is_cancelled() {
        return reply(ResetClaimOutcome::Cancelled, None, None);
    }
    let file_candidates = file.credentials;
    let mut candidates = file_candidates.clone();
    let mut access_failed = file.access_failed;
    let mut keychain_attempted = false;
    let mut keychain_credentials = Vec::new();
    if candidates.is_empty() && config.allows_keychain_fallback {
        keychain_attempted = true;
        let keychain = load_keychain_credentials(&store, ctx);
        if keychain.cancelled || ctx.is_cancelled() {
            return reply(ResetClaimOutcome::Cancelled, None, None);
        }
        access_failed |= keychain.access_failed;
        keychain_credentials = keychain.credentials;
        candidates.extend(keychain_credentials.clone());
    }
    if candidates.is_empty() {
        return reply(
            if access_failed {
                ResetClaimOutcome::CredentialAccess
            } else {
                ResetClaimOutcome::Failed
            },
            None,
            None,
        );
    }

    let key = matched_key(&config.provider_id, &request.redeem_request_id);
    let cached = matched_credits()
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .get(&key)
        .cloned();
    // A cached key is the in-session replay record. A persisted `isRetry` may also carry the
    // original credit id after a restart; a first automatic attempt still has to preflight the
    // live list, so a plain `creditId` is not enough to skip the GET.
    let retry_target = cached
        .as_ref()
        .map(|matched| (matched.credit_id.clone(), matched.owner.clone()))
        .or_else(|| {
            if !request.is_retry {
                return None;
            }
            request.credit_id.as_ref().map(|credit_id| {
                (
                    credit_id.clone(),
                    Owner {
                        account_id: request
                            .owner_identity
                            .clone()
                            .or_else(|| config.owner_identity()),
                        access_token: String::new(),
                    },
                )
            })
        });

    let (credit_id, owner, preferred) = if let Some((credit_id, owner)) = retry_target {
        if request.automatic && owner.account_id.is_none() {
            qlog!(
                Error,
                plugin_tag(ID),
                "auto reset: retry has no verified account identity"
            );
            return reply(ResetClaimOutcome::Failed, None, None);
        }
        let preferred: Vec<Credential> = candidates
            .iter()
            .filter(|credential| {
                if owner.account_id.is_none() && owner.access_token.is_empty() {
                    return true;
                }
                credential.matches_owner(&owner)
            })
            .cloned()
            .collect();
        if preferred.is_empty() {
            qlog!(
                Error,
                plugin_tag(ID),
                "reset claim: original account unavailable for retry"
            );
            return reply(ResetClaimOutcome::Failed, None, None);
        }
        let owner = preferred
            .first()
            .map(|credential| Owner {
                account_id: credential.account_id.clone(),
                access_token: credential.access_token.clone(),
            })
            .unwrap_or(owner);
        (credit_id, owner, preferred)
    } else {
        let match_candidates = if file_candidates.is_empty() {
            keychain_credentials.clone()
        } else {
            file_candidates.clone()
        };
        let mut matched = if request.automatic {
            match_exact(
                &request.credit_id.clone().unwrap_or_default(),
                request.expiry,
                &match_candidates,
                ctx,
                &http,
            )
        } else {
            match_credit(request.expiry, &match_candidates, ctx, &http)
        };
        if matches!(matched, MatchResult::AuthenticationRejected)
            && !keychain_attempted
            && config.allows_keychain_fallback
        {
            keychain_attempted = true;
            let keychain = load_keychain_credentials(&store, ctx);
            if keychain.cancelled || ctx.is_cancelled() {
                return reply(ResetClaimOutcome::Cancelled, None, None);
            }
            access_failed |= keychain.access_failed;
            keychain_credentials = keychain.credentials;
            candidates.extend(keychain_credentials.clone());
            matched = if request.automatic {
                match_exact(
                    &request.credit_id.clone().unwrap_or_default(),
                    request.expiry,
                    &keychain_credentials,
                    ctx,
                    &http,
                )
            } else {
                match_credit(request.expiry, &keychain_credentials, ctx, &http)
            };
        }
        match matched {
            MatchResult::Matched {
                credit_id,
                credentials,
            } => {
                let owner = Owner {
                    account_id: credentials.account_id.clone(),
                    access_token: credentials.access_token.clone(),
                };
                // An automatic write must be attributable to a verified account. The old Swift
                // path refused to POST when the preflight match had no account identity.
                if request.automatic && owner.account_id.is_none() {
                    qlog!(
                        Error,
                        plugin_tag(ID),
                        "auto reset: matched credit has no verified account identity"
                    );
                    return reply(ResetClaimOutcome::Failed, None, None);
                }
                let mut preferred = vec![credentials.clone()];
                preferred.extend(
                    candidates
                        .iter()
                        .filter(|candidate| {
                            candidate.matches_owner(&owner)
                                && (candidate.access_token != credentials.access_token
                                    || candidate.account_id != credentials.account_id)
                        })
                        .cloned(),
                );
                matched_credits()
                    .lock()
                    .unwrap_or_else(|error| error.into_inner())
                    .insert(
                        key,
                        MatchedCredit {
                            credit_id: credit_id.clone(),
                            owner: owner.clone(),
                        },
                    );
                (credit_id, owner, preferred)
            }
            MatchResult::NoCredit => {
                qlog!(
                    Warn,
                    plugin_tag(ID),
                    "reset claim: no available credit matches the picked expiry"
                );
                return reply(ResetClaimOutcome::NoCredit, None, None);
            }
            MatchResult::AuthenticationRejected => {
                return reply(
                    if access_failed {
                        ResetClaimOutcome::CredentialAccess
                    } else {
                        ResetClaimOutcome::Failed
                    },
                    None,
                    None,
                );
            }
            MatchResult::Cancelled => return reply(ResetClaimOutcome::Cancelled, None, None),
            MatchResult::Failed => return reply(ResetClaimOutcome::Failed, None, None),
        }
    };

    if ctx.is_cancelled() {
        return reply(ResetClaimOutcome::Cancelled, None, None);
    }
    let outcome = match consume(
        &credit_id,
        &request.redeem_request_id,
        &preferred,
        request.automatic,
        request.automatic.then_some(request.expiry),
        ctx,
        &http,
    ) {
        ConsumeResult::Outcome(outcome) => outcome,
        ConsumeResult::AuthenticationRejected
            if !keychain_attempted && config.allows_keychain_fallback =>
        {
            let keychain = load_keychain_credentials(&store, ctx);
            if keychain.cancelled || ctx.is_cancelled() {
                return reply(ResetClaimOutcome::Cancelled, None, None);
            }
            let fallbacks: Vec<Credential> = keychain
                .credentials
                .into_iter()
                .filter(|credential| credential.matches_owner(&owner))
                .collect();
            if fallbacks.is_empty() {
                if keychain.access_failed {
                    ResetClaimOutcome::CredentialAccess
                } else {
                    ResetClaimOutcome::Failed
                }
            } else {
                match consume(
                    &credit_id,
                    &request.redeem_request_id,
                    &fallbacks,
                    request.automatic,
                    request.automatic.then_some(request.expiry),
                    ctx,
                    &http,
                ) {
                    ConsumeResult::Outcome(outcome) => outcome,
                    ConsumeResult::AuthenticationRejected => ResetClaimOutcome::Failed,
                    ConsumeResult::Cancelled => {
                        return reply(ResetClaimOutcome::Cancelled, None, None)
                    }
                }
            }
        }
        ConsumeResult::AuthenticationRejected => ResetClaimOutcome::Failed,
        ConsumeResult::Cancelled => return reply(ResetClaimOutcome::Cancelled, None, None),
    };
    if outcome == ResetClaimOutcome::Cancelled {
        return reply(ResetClaimOutcome::Cancelled, None, None);
    }
    reply(outcome, Some(credit_id), owner.identity())
}

fn reply(
    outcome: ResetClaimOutcome,
    credit_id: Option<String>,
    owner_identity: Option<String>,
) -> ClaimReply {
    ClaimReply {
        outcome,
        credit_id,
        owner_identity,
    }
}

enum MatchResult {
    Matched {
        credit_id: String,
        credentials: Credential,
    },
    NoCredit,
    AuthenticationRejected,
    Cancelled,
    Failed,
}

fn match_credit(
    expiry: f64,
    candidates: &[Credential],
    ctx: &RefreshContext,
    http: &Arc<dyn HttpClient>,
) -> MatchResult {
    let client = CodexClient::new(http.clone());
    let mut rejected = false;
    for credentials in candidates {
        if ctx.is_cancelled() {
            return MatchResult::Cancelled;
        }
        let response = match client.fetch_reset_credits(
            &credentials.access_token,
            credentials.account_id.as_deref(),
            &ctx.cancel,
        ) {
            Ok(response) => response,
            Err(_) if ctx.is_cancelled() => return MatchResult::Cancelled,
            Err(_) => {
                qlog!(
                    Error,
                    plugin_tag(ID),
                    "reset claim: credit list fetch failed"
                );
                return MatchResult::Failed;
            }
        };
        if ctx.is_cancelled() {
            return MatchResult::Cancelled;
        }
        if response.status == 401 || response.status == 403 {
            rejected = true;
            continue;
        }
        let Some(body) = parse_object(&response) else {
            qlog!(
                Error,
                plugin_tag(ID),
                "reset claim: credit list fetch failed ({})",
                response.status
            );
            return MatchResult::Failed;
        };
        return match credit_id_in(&body, expiry) {
            Some(credit_id) => MatchResult::Matched {
                credit_id,
                credentials: credentials.clone(),
            },
            None => MatchResult::NoCredit,
        };
    }
    if rejected {
        qlog!(
            Error,
            plugin_tag(ID),
            "reset claim: credit list fetch rejected for every credential"
        );
        MatchResult::AuthenticationRejected
    } else {
        MatchResult::Failed
    }
}

fn match_exact(
    credit_id: &str,
    expiry: f64,
    candidates: &[Credential],
    ctx: &RefreshContext,
    http: &Arc<dyn HttpClient>,
) -> MatchResult {
    if credit_id.is_empty() {
        return MatchResult::Failed;
    }
    let client = CodexClient::new(http.clone());
    let mut rejected = false;
    for credentials in candidates {
        if ctx.is_cancelled() {
            return MatchResult::Cancelled;
        }
        let response = match client.fetch_reset_credits(
            &credentials.access_token,
            credentials.account_id.as_deref(),
            &ctx.cancel,
        ) {
            Ok(response) => response,
            Err(_) if ctx.is_cancelled() => return MatchResult::Cancelled,
            Err(_) => {
                qlog!(Error, plugin_tag(ID), "auto reset: pre-claim lookup failed");
                return MatchResult::Failed;
            }
        };
        if ctx.is_cancelled() {
            return MatchResult::Cancelled;
        }
        if response.status == 401 || response.status == 403 {
            rejected = true;
            continue;
        }
        let Some(body) = parse_object(&response) else {
            qlog!(
                Error,
                plugin_tag(ID),
                "auto reset: pre-claim list unavailable"
            );
            return MatchResult::Failed;
        };
        let Some(credits) = body.get("credits").and_then(Value::as_array) else {
            qlog!(
                Error,
                plugin_tag(ID),
                "auto reset: pre-claim list unavailable"
            );
            return MatchResult::Failed;
        };
        let matching: Vec<&Value> = credits
            .iter()
            .filter(|item| item.get("id").and_then(Value::as_str) == Some(credit_id))
            .collect();
        if matching.len() > 1 {
            qlog!(
                Error,
                plugin_tag(ID),
                "auto reset: duplicate credit identity in preflight"
            );
            return MatchResult::Failed;
        }
        let Some(item) = matching.first() else {
            return MatchResult::NoCredit;
        };
        let Some(date) = item.get("expires_at").and_then(parse_expiry) else {
            return MatchResult::NoCredit;
        };
        if date <= ctx.now {
            return MatchResult::NoCredit;
        }
        if let Some(status) = item.get("status").and_then(Value::as_str) {
            if status != "available" {
                return MatchResult::NoCredit;
            }
        }
        if let Some(reset_type) = item.get("reset_type").and_then(Value::as_str) {
            if reset_type != "codex_rate_limits" {
                return MatchResult::NoCredit;
            }
        }
        if (date - expiry).abs() >= 1.0 {
            qlog!(
                Info,
                plugin_tag(ID),
                "auto reset: credit expiry changed during preflight; rescheduling"
            );
            return MatchResult::Cancelled;
        }
        return MatchResult::Matched {
            credit_id: credit_id.to_string(),
            credentials: credentials.clone(),
        };
    }
    if rejected {
        MatchResult::AuthenticationRejected
    } else {
        MatchResult::Failed
    }
}

pub fn credit_id_in(body: &serde_json::Map<String, Value>, expiry: f64) -> Option<String> {
    let credits = body.get("credits").and_then(Value::as_array)?;
    credits.iter().find_map(|credit| {
        if let Some(status) = credit.get("status").and_then(Value::as_str) {
            if status != "available" {
                return None;
            }
        }
        let date = credit.get("expires_at").and_then(parse_expiry)?;
        if (date - expiry).abs() >= 1.0 {
            return None;
        }
        credit
            .get("id")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
            .map(str::to_string)
    })
}

enum ConsumeResult {
    Outcome(ResetClaimOutcome),
    AuthenticationRejected,
    Cancelled,
}

fn consume(
    credit_id: &str,
    redeem_request_id: &str,
    candidates: &[Credential],
    automatic: bool,
    automatic_expiry: Option<f64>,
    ctx: &RefreshContext,
    http: &Arc<dyn HttpClient>,
) -> ConsumeResult {
    let client = CodexClient::new(http.clone());
    let mut last_rejection = None;
    let mut consume_was_sent = false;
    for credentials in candidates {
        if ctx.is_cancelled() {
            return if consume_was_sent && automatic {
                ConsumeResult::Outcome(ResetClaimOutcome::Failed)
            } else {
                ConsumeResult::Cancelled
            };
        }
        if let Some(expiry) = automatic_expiry {
            if ctx.now >= expiry {
                return ConsumeResult::Outcome(ResetClaimOutcome::NoCredit);
            }
            if ctx.now < expiry - AUTOMATIC_LEAD_SECONDS {
                return if consume_was_sent {
                    ConsumeResult::Outcome(ResetClaimOutcome::Failed)
                } else {
                    ConsumeResult::Cancelled
                };
            }
        }
        consume_was_sent = true;
        let response = match client.consume_reset_credit(
            &credentials.access_token,
            credentials.account_id.as_deref(),
            credit_id,
            redeem_request_id,
            &ctx.cancel,
        ) {
            Ok(response) => response,
            Err(_) => {
                if ctx.is_cancelled() {
                    return if automatic {
                        ConsumeResult::Outcome(ResetClaimOutcome::Failed)
                    } else {
                        ConsumeResult::Cancelled
                    };
                }
                qlog!(Error, plugin_tag(ID), "reset claim: consume request failed");
                return ConsumeResult::Outcome(ResetClaimOutcome::Failed);
            }
        };
        if ctx.is_cancelled() && !automatic {
            return ConsumeResult::Cancelled;
        }
        if response.status == 401 || response.status == 403 {
            last_rejection = Some(response.status);
            continue;
        }
        let outcome = outcome_from_consume(&response);
        if outcome == ResetClaimOutcome::Failed {
            qlog!(
                Error,
                plugin_tag(ID),
                "reset claim: consume failed ({}): {}",
                response.status,
                crate::redact::body_preview(&String::from_utf8_lossy(&response.body), 300)
            );
        }
        return ConsumeResult::Outcome(outcome);
    }
    qlog!(
        Error,
        plugin_tag(ID),
        "reset claim: consume rejected for every credential (last: {:?})",
        last_rejection
    );
    ConsumeResult::AuthenticationRejected
}

pub fn outcome_from_consume(response: &Response) -> ResetClaimOutcome {
    if !(200..300).contains(&response.status) {
        return ResetClaimOutcome::Failed;
    }
    let Some(body) = parse_object(response) else {
        return ResetClaimOutcome::Failed;
    };
    match body.get("code").and_then(Value::as_str) {
        Some("reset" | "already_redeemed") => ResetClaimOutcome::Success,
        Some("nothing_to_reset") => ResetClaimOutcome::NothingToReset,
        Some("no_credit") => ResetClaimOutcome::NoCredit,
        _ => ResetClaimOutcome::Failed,
    }
}

fn parse_object(response: &Response) -> Option<serde_json::Map<String, Value>> {
    serde_json::from_slice::<Value>(&response.body)
        .ok()?
        .as_object()
        .cloned()
}

fn parse_expiry(value: &Value) -> Option<f64> {
    match value {
        Value::String(text) => parse_iso8601(text),
        other => parse::number(Some(other)),
    }
}

#[cfg(test)]
mod tests;
