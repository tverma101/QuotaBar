//! OpenCode Go account usage API (`Providers/OpenCode/OpenCodeGoUsageClient`).
//!
//! `GET https://opencode.ai/zen/go/v1/usage` answers three account-wide consumption windows.
//! The key is only an Authorization header and never appears in errors or logs.

use crate::context::CancelToken;
use crate::http::{self, HttpClient, HttpError, Request};
use serde_json::Value;
use std::sync::Arc;
use std::time::Duration;

pub const USAGE_URL: &str = "https://opencode.ai/zen/go/v1/usage";
pub const USER_AGENT: &str = "QuotaBar/0.7.8";
const TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Clone, Debug, PartialEq)]
pub struct AccountWindow {
    pub status: String,
    pub percent: Option<i64>,
    pub resets_at: Option<f64>,
}

impl AccountWindow {
    pub fn usable(&self) -> bool {
        matches!(self.status.as_str(), "ok" | "rate-limited") && self.percent.is_some()
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct AccountUsage {
    pub rolling: AccountWindow,
    pub weekly: AccountWindow,
    pub monthly: AccountWindow,
}

impl AccountUsage {
    pub fn available(&self) -> bool {
        self.rolling.usable() && self.weekly.usable() && self.monthly.usable()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ClientError {
    Unauthorized,
    NoEntitlement,
    InvalidResponse,
    RequestFailed(u16),
    Unavailable(String),
    Cancelled,
}

impl ClientError {
    pub fn message(&self) -> &'static str {
        match self {
            ClientError::Unauthorized => "OpenCode couldn't verify this Go key. Check the key and refresh.",
            ClientError::NoEntitlement => {
                "OpenCode couldn't confirm a Go subscription for this key. Check your account or try again."
            }
            ClientError::InvalidResponse => "OpenCode returned Go usage data QuotaBar couldn't read. Try refreshing.",
            ClientError::RequestFailed(_) => "OpenCode's Go usage service returned an error.",
            ClientError::Unavailable(_) => "Couldn't reach OpenCode's Go usage service.",
            ClientError::Cancelled => "Refresh cancelled.",
        }
    }

    pub fn detail(&self) -> Option<&str> {
        match self {
            ClientError::Unavailable(detail) => Some(detail),
            _ => None,
        }
    }
}

pub struct GoClient {
    http: Arc<dyn HttpClient>,
}

impl GoClient {
    pub fn live() -> Self {
        GoClient {
            http: http::shared(),
        }
    }

    pub fn with_http(http: Arc<dyn HttpClient>) -> Self {
        GoClient { http }
    }

    pub fn fetch_usage(
        &self,
        key: &str,
        cancel: &CancelToken,
    ) -> Result<AccountUsage, ClientError> {
        let request = Request::get(USAGE_URL)
            .header("Authorization", format!("Bearer {key}"))
            .header("Accept", "application/json")
            .header("User-Agent", USER_AGENT)
            .timeout(TIMEOUT);
        let response = match self.http.send(&request, cancel) {
            Ok(response) => response,
            Err(HttpError::Cancelled) => return Err(ClientError::Cancelled),
            Err(error) => return Err(ClientError::Unavailable(error.to_string())),
        };
        if response.is_success() {
            let Some(root) = response.json() else {
                return Err(ClientError::InvalidResponse);
            };
            let Some(usage) = root.get("usage").and_then(Value::as_object) else {
                return Err(ClientError::InvalidResponse);
            };
            let parsed = parse(usage);
            return parsed
                .available()
                .then_some(parsed)
                .ok_or(ClientError::InvalidResponse);
        }
        match error_type(&response.body).as_deref() {
            Some("AuthError") => return Err(ClientError::Unauthorized),
            Some("EntitlementError") => return Err(ClientError::NoEntitlement),
            _ => {}
        }
        match response.status {
            401 => Err(ClientError::Unauthorized),
            403 => Err(ClientError::NoEntitlement),
            status => Err(ClientError::RequestFailed(status)),
        }
    }
}

fn error_type(body: &[u8]) -> Option<String> {
    let root: Value = serde_json::from_slice(body).ok()?;
    root.get("error")?.get("type")?.as_str().map(str::to_string)
}

/// Tolerant per-window parse: each field is read independently. The provider gates on `available`,
/// so a partial or unrecognized response is rejected rather than mixed with local fallback rows.
pub fn parse(usage: &serde_json::Map<String, Value>) -> AccountUsage {
    let window = |key: &str| {
        let Some(raw) = usage.get(key).and_then(Value::as_object) else {
            return AccountWindow {
                status: String::new(),
                percent: None,
                resets_at: None,
            };
        };
        let status = raw
            .get("status")
            .and_then(Value::as_str)
            .map(|s| s.trim().to_string())
            .unwrap_or_default();
        let percent = raw
            .get("percent")
            .and_then(|value| crate::parse::number(Some(value)))
            .and_then(|value| {
                (value.is_finite() && (0.0..=100.0).contains(&value)).then(|| value.round() as i64)
            });
        let resets_at = raw
            .get("resetsAt")
            .and_then(Value::as_str)
            .and_then(crate::time::parse_iso8601);
        AccountWindow {
            status,
            percent,
            resets_at,
        }
    };
    AccountUsage {
        rolling: window("rolling"),
        weekly: window("weekly"),
        monthly: window("monthly"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_all_windows_and_rejects_partial() {
        let root: Value = serde_json::from_str(
            r#"{"usage":{"rolling":{"status":"ok","percent":12.4,"resetsAt":"2026-07-12T15:00:00.000Z"},"weekly":{"status":"rate-limited","percent":100},"monthly":{"status":"ok","percent":0}}}"#,
        )
        .unwrap();
        let usage = parse(root["usage"].as_object().unwrap());
        assert!(usage.available());
        assert_eq!(usage.rolling.percent, Some(12));
        assert_eq!(usage.weekly.percent, Some(100));
        assert_eq!(usage.monthly.percent, Some(0));
        assert!(usage.rolling.resets_at.is_some());

        let partial: Value =
            serde_json::from_str(r#"{"usage":{"rolling":{"status":"ok","percent":1}}}"#).unwrap();
        assert!(!parse(partial["usage"].as_object().unwrap()).available());
    }
}
