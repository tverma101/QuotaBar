//! Codex OAuth/usage/reset-credit HTTP (Swift `CodexUsageClient`).

use super::auth::CodexAuthError;
use super::mapper::CodexUsageError;
use crate::context::CancelToken;
use crate::http::{self, HttpClient, HttpError};
use crate::parse;
use serde_json::Value;
use std::sync::Arc;
use std::time::Duration;

pub const CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const REFRESH_URL: &str = "https://auth.openai.com/oauth/token";
pub const USAGE_URL: &str = "https://chatgpt.com/backend-api/wham/usage";
pub const RESET_CREDITS_URL: &str = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits";
pub const CONSUME_RESET_CREDIT_URL: &str =
    "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume";

#[derive(Clone, Debug, PartialEq)]
pub struct CodexRefreshResponse {
    pub access_token: String,
    pub refresh_token: Option<String>,
    pub id_token: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CodexRefreshError {
    Auth(CodexAuthError),
    Usage(CodexUsageError),
}

pub struct CodexClient {
    http: Arc<dyn HttpClient>,
}

impl CodexClient {
    pub fn new(http: Arc<dyn HttpClient>) -> Self {
        CodexClient { http }
    }

    pub fn shared() -> Self {
        CodexClient::new(http::shared())
    }

    pub fn refresh_token(
        &self,
        refresh_token: &str,
        cancel: &CancelToken,
    ) -> Result<CodexRefreshResponse, CodexRefreshError> {
        let body = format!(
            "grant_type=refresh_token&client_id={}&refresh_token={}",
            http::url_form_encode(CLIENT_ID),
            http::url_form_encode(refresh_token)
        );
        let request = http::Request::post_form(REFRESH_URL, body).timeout(Duration::from_secs(15));
        let response = self
            .http
            .send(&request, cancel)
            .map_err(|_| CodexRefreshError::Usage(CodexUsageError::ConnectionFailed))?;
        parse_refresh_response(response.status, &response.body)
    }

    pub fn fetch_usage(
        &self,
        access_token: &str,
        account_id: Option<&str>,
        cancel: &CancelToken,
    ) -> Result<http::Response, CodexUsageError> {
        let mut request = http::Request::get(USAGE_URL)
            .header("Authorization", format!("Bearer {access_token}"))
            .header("Accept", "application/json")
            .header("User-Agent", "QuotaBar")
            .timeout(Duration::from_secs(10));
        if let Some(account_id) = account_id.filter(|v| !v.is_empty()) {
            request = request.header("ChatGPT-Account-Id", account_id);
        }
        self.http
            .send(&request, cancel)
            .map_err(|error| match error {
                HttpError::Cancelled => CodexUsageError::ConnectionFailed,
                _ => CodexUsageError::ConnectionFailed,
            })
    }

    pub fn fetch_reset_credits(
        &self,
        access_token: &str,
        account_id: Option<&str>,
        cancel: &CancelToken,
    ) -> Result<http::Response, CodexUsageError> {
        let mut request = http::Request::get(RESET_CREDITS_URL)
            .header("Authorization", format!("Bearer {access_token}"))
            .header("Accept", "application/json")
            .header("User-Agent", "QuotaBar")
            .header("OpenAI-Beta", "codex-1")
            .header("originator", "Codex Desktop")
            .timeout(Duration::from_secs(10));
        if let Some(account_id) = account_id.filter(|v| !v.is_empty()) {
            request = request.header("ChatGPT-Account-Id", account_id);
        }
        self.http
            .send(&request, cancel)
            .map_err(|error| match error {
                HttpError::Cancelled => CodexUsageError::ConnectionFailed,
                _ => CodexUsageError::ConnectionFailed,
            })
    }

    pub fn consume_reset_credit(
        &self,
        access_token: &str,
        account_id: Option<&str>,
        credit_id: &str,
        redeem_request_id: &str,
        cancel: &CancelToken,
    ) -> Result<http::Response, CodexUsageError> {
        let mut request = http::Request::post_json(
            CONSUME_RESET_CREDIT_URL,
            &serde_json::json!({"redeem_request_id": redeem_request_id, "credit_id": credit_id}),
        )
        .header("Authorization", format!("Bearer {access_token}"))
        .header("Accept", "application/json")
        .header("Content-Type", "application/json")
        .header("User-Agent", "QuotaBar")
        .header("OpenAI-Beta", "codex-1")
        .header("originator", "Codex Desktop")
        .timeout(Duration::from_secs(15));
        if let Some(account_id) = account_id.filter(|v| !v.is_empty()) {
            request = request.header("ChatGPT-Account-Id", account_id);
        }
        self.http
            .send(&request, cancel)
            .map_err(|_| CodexUsageError::ConnectionFailed)
    }
}

fn parse_refresh_response(
    status: u16,
    body: &[u8],
) -> Result<CodexRefreshResponse, CodexRefreshError> {
    if status == 400 || status == 401 {
        let parsed: Option<Value> = serde_json::from_slice(body).ok();
        let code = parsed.as_ref().and_then(|value| {
            value.get("error").and_then(|error| {
                error
                    .as_object()
                    .and_then(|object| object.get("code").or_else(|| object.get("error")))
                    .or(Some(error))
                    .and_then(Value::as_str)
            })
        });
        return Err(match code {
            Some("refresh_token_expired") => {
                CodexRefreshError::Auth(CodexAuthError::SessionExpired)
            }
            Some("refresh_token_reused") => CodexRefreshError::Auth(CodexAuthError::TokenConflict),
            Some("refresh_token_invalidated") => {
                CodexRefreshError::Auth(CodexAuthError::TokenRevoked)
            }
            _ => CodexRefreshError::Usage(CodexUsageError::RequestFailed(status)),
        });
    }
    if !(200..300).contains(&status) {
        return Err(CodexRefreshError::Usage(CodexUsageError::RequestFailed(
            status,
        )));
    }
    let parsed: Value = serde_json::from_slice(body)
        .map_err(|_| CodexRefreshError::Auth(CodexAuthError::TokenExpired))?;
    let access_token = parsed
        .get("access_token")
        .and_then(Value::as_str)
        .filter(|v| !v.is_empty())
        .ok_or(CodexRefreshError::Auth(CodexAuthError::TokenExpired))?;
    Ok(CodexRefreshResponse {
        access_token: access_token.to_string(),
        refresh_token: parse::trimmed_string(parsed.get("refresh_token")),
        id_token: parse::trimmed_string(parsed.get("id_token")),
    })
}

/// Maps a token-endpoint rejection onto the credential error the provider falls back on.
pub fn auth_error_for_refresh(error: &CodexRefreshError) -> Option<CodexAuthError> {
    match error {
        CodexRefreshError::Auth(error) => Some(*error),
        CodexRefreshError::Usage(CodexUsageError::RequestFailed(400 | 401)) => {
            Some(CodexAuthError::TokenExpired)
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognized_oauth_codes_become_dead_credential_statuses() {
        assert_eq!(
            parse_refresh_response(400, br#"{"error":{"code":"refresh_token_expired"}}"#),
            Err(CodexRefreshError::Auth(CodexAuthError::SessionExpired))
        );
        assert_eq!(
            parse_refresh_response(400, br#"{"error":"refresh_token_reused"}"#),
            Err(CodexRefreshError::Auth(CodexAuthError::TokenConflict))
        );
        assert_eq!(
            auth_error_for_refresh(&CodexRefreshError::Usage(CodexUsageError::RequestFailed(
                400
            ))),
            Some(CodexAuthError::TokenExpired)
        );
        assert_eq!(
            auth_error_for_refresh(&CodexRefreshError::Usage(CodexUsageError::RequestFailed(
                500
            ))),
            None
        );
    }

    #[test]
    fn successful_refresh_reads_rotated_tokens() {
        let parsed = parse_refresh_response(
            200,
            br#"{"access_token":"a","refresh_token":"r","id_token":"i"}"#,
        )
        .unwrap();
        assert_eq!(parsed.access_token, "a");
        assert_eq!(parsed.refresh_token.as_deref(), Some("r"));
        assert_eq!(parsed.id_token.as_deref(), Some("i"));
    }
}
