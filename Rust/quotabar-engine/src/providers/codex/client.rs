//! Codex HTTP client (Swift `CodexUsageClient`): the OAuth token refresh, the usage endpoint, the
//! reset-credit list and the reset-credit consume call.

use super::auth::CodexAuthError;
use super::mapper::CodexUsageError;
use crate::context::CancelToken;
use crate::http::{url_form_encode, HttpClient, HttpError, Request, Response};
use serde_json::Value;
use std::time::Duration;

pub const CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const REFRESH_URL: &str = "https://auth.openai.com/oauth/token";
pub const USAGE_URL: &str = "https://chatgpt.com/backend-api/wham/usage";
pub const RESET_CREDITS_URL: &str = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits";
pub const CONSUME_RESET_CREDIT_URL: &str = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CodexRefreshResponse {
    pub access_token: String,
    pub refresh_token: Option<String>,
    pub id_token: Option<String>,
}

/// What a client call can fail with: a transport error, or the typed Codex auth/usage errors Swift
/// threw from the same call sites.
#[derive(Clone, Debug, PartialEq)]
pub enum CodexClientError {
    Transport(HttpError),
    Auth(CodexAuthError),
    Usage(CodexUsageError),
}

impl From<HttpError> for CodexClientError {
    fn from(error: HttpError) -> Self {
        CodexClientError::Transport(error)
    }
}

pub struct CodexUsageClient<'a> {
    pub http: &'a dyn HttpClient,
}

fn is_present(account_id: Option<&str>) -> Option<&str> {
    account_id.filter(|a| !a.is_empty())
}

impl CodexUsageClient<'_> {
    pub fn refresh_token(&self, refresh_token: &str, cancel: &CancelToken) -> Result<CodexRefreshResponse, CodexClientError> {
        let body = format!(
            "grant_type=refresh_token&client_id={}&refresh_token={}",
            url_form_encode(CLIENT_ID),
            url_form_encode(refresh_token)
        );
        let response = self.http.send(&Request::post_form(REFRESH_URL, body).timeout(Duration::from_secs(15)), cancel)?;

        if response.status == 400 || response.status == 401 {
            let error_body = json_object(&response);
            let code = error_body
                .as_ref()
                .and_then(|b| b.get("error"))
                .and_then(|error| match error {
                    Value::Object(error) => error
                        .get("code")
                        .and_then(Value::as_str)
                        .or_else(|| error.get("error").and_then(Value::as_str))
                        .map(str::to_string),
                    other => other.as_str().map(str::to_string),
                })
                .or_else(|| error_body.as_ref().and_then(|b| b.get("code")).and_then(Value::as_str).map(str::to_string));
            return Err(match code.as_deref() {
                Some("refresh_token_expired") => CodexClientError::Auth(CodexAuthError::SessionExpired),
                Some("refresh_token_reused") => CodexClientError::Auth(CodexAuthError::TokenConflict),
                Some("refresh_token_invalidated") => CodexClientError::Auth(CodexAuthError::TokenRevoked),
                // No recognized OAuth error code (often a non-JSON proxy/WAF page): report the HTTP
                // status rather than asserting token expiry the user can't fix by re-logging in.
                _ => CodexClientError::Usage(CodexUsageError::RequestFailed(response.status)),
            });
        }
        if !response.is_success() {
            return Err(CodexClientError::Usage(CodexUsageError::RequestFailed(response.status)));
        }
        let access_token = json_object(&response)
            .and_then(|b| b.get("access_token").and_then(Value::as_str).map(str::to_string))
            .filter(|t| !t.is_empty());
        let Some(access_token) = access_token else { return Err(CodexClientError::Auth(CodexAuthError::TokenExpired)) };
        let body = json_object(&response).unwrap_or_default();
        Ok(CodexRefreshResponse {
            access_token,
            refresh_token: body.get("refresh_token").and_then(Value::as_str).map(str::to_string),
            id_token: body.get("id_token").and_then(Value::as_str).map(str::to_string),
        })
    }

    pub fn fetch_usage(&self, access_token: &str, account_id: Option<&str>, cancel: &CancelToken) -> Result<Response, HttpError> {
        let mut request = Request::get(USAGE_URL)
            .header("Authorization", format!("Bearer {access_token}"))
            .header("Accept", "application/json")
            .header("User-Agent", "QuotaBar")
            .timeout(Duration::from_secs(10));
        if let Some(account) = is_present(account_id) {
            request = request.header("ChatGPT-Account-Id", account);
        }
        self.http.send(&request, cancel)
    }

    /// On-demand rate-limit reset credits including each credit's expiry (a separate endpoint from
    /// `usage`). The extra headers mirror the Codex desktop client. Best-effort for the caller.
    pub fn fetch_reset_credits(
        &self,
        access_token: &str,
        account_id: Option<&str>,
        cancel: &CancelToken,
    ) -> Result<Response, HttpError> {
        let mut request = Request::get(RESET_CREDITS_URL)
            .header("Authorization", format!("Bearer {access_token}"))
            .header("Accept", "application/json")
            .header("User-Agent", "QuotaBar")
            .header("OpenAI-Beta", "codex-1")
            .header("originator", "Codex Desktop")
            .timeout(Duration::from_secs(10));
        if let Some(account) = is_present(account_id) {
            request = request.header("ChatGPT-Account-Id", account);
        }
        self.http.send(&request, cancel)
    }

    /// Consumes (claims) one rate-limit reset credit. `redeem_request_id` is the caller's idempotency
    /// key (reused on retry so a retried claim can never burn a second credit); `credit_id` targets
    /// exactly one credit. The outcome rides in the 200 body's `code`.
    pub fn consume_reset_credit(
        &self,
        access_token: &str,
        account_id: Option<&str>,
        credit_id: &str,
        redeem_request_id: &str,
        cancel: &CancelToken,
    ) -> Result<Response, HttpError> {
        // `JSONSerialization` with `.sortedKeys`: credit_id, then redeem_request_id.
        let body = serde_json::json!({ "redeem_request_id": redeem_request_id, "credit_id": credit_id });
        let mut request = Request::post_json(CONSUME_RESET_CREDIT_URL, &body)
            .header("Authorization", format!("Bearer {access_token}"))
            .header("Accept", "application/json")
            .header("User-Agent", "QuotaBar")
            .header("OpenAI-Beta", "codex-1")
            .header("originator", "Codex Desktop")
            .timeout(Duration::from_secs(15));
        if let Some(account) = is_present(account_id) {
            request = request.header("ChatGPT-Account-Id", account);
        }
        self.http.send(&request, cancel)
    }
}

/// Swift `ProviderParse.jsonObject`: a non-empty body that parses to a JSON object.
pub fn json_object(response: &Response) -> Option<serde_json::Map<String, Value>> {
    if response.body.is_empty() {
        return None;
    }
    match serde_json::from_slice::<Value>(&response.body).ok()? {
        Value::Object(map) => Some(map),
        _ => None,
    }
}
