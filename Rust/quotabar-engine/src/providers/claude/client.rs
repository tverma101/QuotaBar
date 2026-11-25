//! Claude OAuth usage/profile/refresh HTTP (Swift `ClaudeUsageClient`).

use super::auth::{ClaudeAuthError, ClaudeOAuthConfig};
use crate::http::{self, HttpClient, HttpError};
use crate::model::Timestamp;
use crate::parse;
use serde_json::Value;
use std::sync::Arc;
use std::time::Duration;

const SCOPES: &str =
    "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload";

pub struct ClaudeClient {
    http: Arc<dyn HttpClient>,
}

impl ClaudeClient {
    pub fn new(http: Arc<dyn HttpClient>) -> Self {
        ClaudeClient { http }
    }

    pub fn shared() -> Self {
        ClaudeClient::new(http::shared())
    }

    pub fn refresh_token(
        &self,
        refresh_token: &str,
        config: &ClaudeOAuthConfig,
        cancel: &crate::context::CancelToken,
    ) -> Result<http::Response, ClaudeAuthError> {
        let body = serde_json::json!({
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
            "client_id": config.client_id,
            "scope": SCOPES,
        });
        let request =
            http::Request::post_json(&config.refresh_url, &body).timeout(Duration::from_secs(15));
        self.http
            .send(&request, cancel)
            .map_err(|error| match error {
                HttpError::Cancelled => ClaudeAuthError::SessionExpired,
                _ => ClaudeAuthError::SessionExpired,
            })
    }

    pub fn fetch_usage(
        &self,
        access_token: &str,
        config: &ClaudeOAuthConfig,
        cancel: &crate::context::CancelToken,
    ) -> Result<http::Response, HttpError> {
        let request = http::Request::get(&config.usage_url)
            .header("Authorization", format!("Bearer {}", access_token.trim()))
            .header("Accept", "application/json")
            .header("Content-Type", "application/json")
            .header("anthropic-beta", "oauth-2025-04-20")
            .header("User-Agent", "claude-code/2.1.69")
            .timeout(Duration::from_secs(10));
        self.http.send(&request, cancel)
    }

    /// `Ok(None)` means verified; `Ok(Some(response))` is a non-2xx profile response that the
    /// caller should treat as the usage response (Swift returns it unchanged).
    pub fn verify_account(
        &self,
        access_token: &str,
        expected_identity_key: &str,
        config: &ClaudeOAuthConfig,
        cancel: &crate::context::CancelToken,
    ) -> Result<Option<http::Response>, ClaudeAuthError> {
        let mut expected = expected_identity_key.split('|');
        let (Some(expected_user), Some(expected_org), None) =
            (expected.next(), expected.next(), expected.next())
        else {
            return Err(ClaudeAuthError::SessionExpired);
        };
        let profile_url = match config.usage_url.rsplit_once('/') {
            Some((base, _)) => format!("{base}/profile"),
            None => return Err(ClaudeAuthError::InvalidOAuthUrl(config.usage_url.clone())),
        };
        let request = http::Request::get(profile_url)
            .header("Authorization", format!("Bearer {}", access_token.trim()))
            .header("Accept", "application/json")
            .header("anthropic-beta", "oauth-2025-04-20")
            .timeout(Duration::from_secs(10));
        let response = self
            .http
            .send(&request, cancel)
            .map_err(|_| ClaudeAuthError::SessionExpired)?;
        if !response.is_success() {
            return Ok(Some(response));
        }
        let profile: Value =
            serde_json::from_slice(&response.body).map_err(|_| ClaudeAuthError::SessionExpired)?;
        let account = profile
            .get("account")
            .and_then(Value::as_object)
            .and_then(|a| a.get("uuid"))
            .and_then(Value::as_str);
        let organization = profile
            .get("organization")
            .and_then(Value::as_object)
            .and_then(|o| o.get("uuid"))
            .and_then(Value::as_str);
        if !account.is_some_and(|value| value.eq_ignore_ascii_case(expected_user))
            || !organization.is_some_and(|value| value.eq_ignore_ascii_case(expected_org))
        {
            return Err(ClaudeAuthError::SessionExpired);
        }
        Ok(None)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ClaudeRefreshResponse {
    pub access_token: String,
    pub refresh_token: Option<String>,
    pub expires_in: Option<f64>,
}

pub fn parse_refresh_response(
    status: u16,
    body: &[u8],
) -> Result<ClaudeRefreshResponse, ClaudeAuthError> {
    if status == 400 || status == 401 {
        let parsed: Option<Value> = serde_json::from_slice(body).ok();
        let code = parsed
            .as_ref()
            .and_then(|value| {
                value
                    .get("error")
                    .or_else(|| value.get("error_description"))
            })
            .and_then(Value::as_str);
        return Err(if code == Some("invalid_grant") {
            ClaudeAuthError::SessionExpired
        } else {
            ClaudeAuthError::TokenExpired
        });
    }
    if !(200..300).contains(&status) {
        return Err(ClaudeAuthError::TokenExpired);
    }
    let value: Value = serde_json::from_slice(body).map_err(|_| ClaudeAuthError::TokenExpired)?;
    let access_token = value
        .get("access_token")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .ok_or(ClaudeAuthError::TokenExpired)?;
    Ok(ClaudeRefreshResponse {
        access_token: access_token.to_string(),
        refresh_token: parse::trimmed_string(value.get("refresh_token")),
        expires_in: parse::number(value.get("expires_in")),
    })
}

pub fn now_for_expiry(now: Timestamp, expires_in: Option<f64>) -> Option<f64> {
    expires_in.map(|seconds| now * 1000.0 + seconds * 1000.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refresh_invalid_grant_is_session_expired() {
        assert_eq!(
            parse_refresh_response(400, br#"{"error":"invalid_grant"}"#),
            Err(ClaudeAuthError::SessionExpired)
        );
        assert_eq!(
            parse_refresh_response(401, b"<html>proxy</html>"),
            Err(ClaudeAuthError::TokenExpired)
        );
    }

    #[test]
    fn refresh_reads_rotated_tokens() {
        let parsed = parse_refresh_response(
            200,
            br#"{"access_token":"a","refresh_token":"r","expires_in":3600}"#,
        )
        .unwrap();
        assert_eq!(parsed.access_token, "a");
        assert_eq!(parsed.refresh_token.as_deref(), Some("r"));
        assert_eq!(parsed.expires_in, Some(3600.0));
    }
}
