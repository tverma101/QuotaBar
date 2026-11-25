//! Antigravity network I/O: local language-server RPC, Cloud Code endpoints, and Google OAuth.
//! (`Providers/Antigravity/AntigravityUsageClient`.)

use crate::context::CancelToken;
use crate::http::{self, HttpClient, HttpError, Request};
use std::sync::Arc;
use std::time::Duration;

pub const LS_SERVICE: &str = "exa.language_server_pb.LanguageServerService";
pub const CLOUD_CODE_URLS: [&str; 2] = [
    "https://daily-cloudcode-pa.googleapis.com",
    "https://cloudcode-pa.googleapis.com",
];
pub const FETCH_MODELS_PATH: &str = "/v1internal:fetchAvailableModels";
pub const LOAD_CODE_ASSIST_PATH: &str = "/v1internal:loadCodeAssist";
pub const RETRIEVE_QUOTA_PATH: &str = "/v1internal:retrieveUserQuota";
pub const QUOTA_SUMMARY_PATH: &str = "/v1internal:retrieveUserQuotaSummary";
pub const GOOGLE_OAUTH_URL: &str = "https://oauth2.googleapis.com/token";
pub const GOOGLE_CLIENT_ID: &str =
    "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com";
pub const GOOGLE_CLIENT_SECRET: &str = "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";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Clone, Debug, PartialEq)]
pub enum CloudCodeOutcome {
    Ok(Vec<u8>),
    NotFound,
    AuthFailed,
    Forbidden,
    Unavailable,
}

#[derive(Clone, Debug, PartialEq)]
pub enum CloudCodeBatch {
    Ok {
        bodies: Vec<Vec<u8>>,
        all_hosts_answered: bool,
    },
    AuthFailed,
    Forbidden,
    NotFound,
    Unavailable,
}

impl CloudCodeBatch {
    pub fn first(&self) -> CloudCodeOutcome {
        match self {
            CloudCodeBatch::Ok { bodies, .. } => CloudCodeOutcome::Ok(bodies[0].clone()),
            CloudCodeBatch::AuthFailed => CloudCodeOutcome::AuthFailed,
            CloudCodeBatch::Forbidden => CloudCodeOutcome::Forbidden,
            CloudCodeBatch::NotFound => CloudCodeOutcome::NotFound,
            CloudCodeBatch::Unavailable => CloudCodeOutcome::Unavailable,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum TokenRefresh {
    Refreshed {
        access_token: String,
        expires_in: f64,
    },
    ClientConfigurationInvalid,
    AuthFailed,
    Unavailable,
}

pub struct AntigravityClient {
    http: Arc<dyn HttpClient>,
}

impl AntigravityClient {
    pub fn live() -> Self {
        AntigravityClient {
            http: http::shared(),
        }
    }

    pub fn new(http: Arc<dyn HttpClient>) -> Self {
        AntigravityClient { http }
    }

    /// Call one language-server RPC. `None` means this port is not the live one.
    pub fn call_ls(
        &self,
        scheme: &str,
        port: u16,
        csrf: &str,
        method: &str,
        cancel: &CancelToken,
    ) -> Option<http::Response> {
        if cancel.is_cancelled() {
            return None;
        }
        let body = serde_json::json!({
            "metadata": {
                "ideName": "antigravity",
                "extensionName": "antigravity",
                "ideVersion": "unknown",
                "locale": "en"
            }
        });
        let request = Request::post_json(
            format!("{scheme}://127.0.0.1:{port}/{LS_SERVICE}/{method}"),
            &body,
        )
        .header("Connect-Protocol-Version", "1")
        .header("x-codeium-csrf-token", csrf)
        .timeout(Duration::from_secs(10))
        .insecure_loopback_tls();
        match self.http.send(&request, cancel) {
            Ok(response) => Some(response),
            Err(HttpError::Cancelled) | Err(_) => None,
        }
    }

    pub fn cloud_code(
        &self,
        path: &str,
        token: &str,
        user_agent: &str,
        body: &serde_json::Value,
        cancel: &CancelToken,
    ) -> CloudCodeOutcome {
        self.cloud_code_responses(path, token, user_agent, body, false, cancel)
            .first()
    }

    pub fn cloud_code_summaries(&self, token: &str, cancel: &CancelToken) -> CloudCodeBatch {
        self.cloud_code_responses(
            QUOTA_SUMMARY_PATH,
            token,
            "antigravity",
            &serde_json::json!({}),
            true,
            cancel,
        )
    }

    fn cloud_code_responses(
        &self,
        path: &str,
        token: &str,
        user_agent: &str,
        body: &serde_json::Value,
        collect_summaries: bool,
        cancel: &CancelToken,
    ) -> CloudCodeBatch {
        if cancel.is_cancelled() {
            return CloudCodeBatch::Unavailable;
        }
        let payload = serde_json::to_vec(body).unwrap_or_else(|_| b"{}".to_vec());
        let mut saw_not_found = false;
        let mut saw_other_failure = false;
        let mut bodies = Vec::new();
        for base in CLOUD_CODE_URLS {
            if cancel.is_cancelled() {
                return CloudCodeBatch::Unavailable;
            }
            let request = Request {
                method: "POST",
                url: format!("{base}{path}"),
                headers: vec![
                    ("Accept".into(), "application/json".into()),
                    ("Content-Type".into(), "application/json".into()),
                    ("Authorization".into(), format!("Bearer {token}")),
                    ("User-Agent".into(), user_agent.into()),
                ],
                body: Some(payload.clone()),
                timeout: REQUEST_TIMEOUT,
                allow_insecure_loopback: false,
            };
            let response = match self.http.send(&request, cancel) {
                Ok(response) => response,
                Err(HttpError::Cancelled) => return CloudCodeBatch::Unavailable,
                Err(_) => {
                    saw_other_failure = true;
                    continue;
                }
            };
            if response.status == 401 || response.status == 403 {
                if !bodies.is_empty() {
                    return CloudCodeBatch::Ok {
                        bodies,
                        all_hosts_answered: false,
                    };
                }
                return if response.status == 401 {
                    CloudCodeBatch::AuthFailed
                } else {
                    CloudCodeBatch::Forbidden
                };
            }
            if response.is_success() {
                bodies.push(response.body.clone());
                if !collect_summaries
                    || crate::providers::antigravity::mapper::has_all_shared_quota_meters(
                        &response.body,
                    )
                {
                    return CloudCodeBatch::Ok {
                        bodies,
                        all_hosts_answered: true,
                    };
                }
                continue;
            }
            if response.status == 404 {
                saw_not_found = true;
            } else {
                saw_other_failure = true;
            }
        }
        if !bodies.is_empty() {
            return CloudCodeBatch::Ok {
                bodies,
                all_hosts_answered: !saw_not_found && !saw_other_failure,
            };
        }
        if saw_not_found && !saw_other_failure {
            CloudCodeBatch::NotFound
        } else {
            CloudCodeBatch::Unavailable
        }
    }

    pub fn refresh_google_token(&self, refresh_token: &str, cancel: &CancelToken) -> TokenRefresh {
        if cancel.is_cancelled() {
            return TokenRefresh::Unavailable;
        }
        let form = [
            format!("client_id={}", http::url_form_encode(GOOGLE_CLIENT_ID)),
            format!(
                "client_secret={}",
                http::url_form_encode(GOOGLE_CLIENT_SECRET)
            ),
            format!("refresh_token={}", http::url_form_encode(refresh_token)),
            "grant_type=refresh_token".to_string(),
        ]
        .join("&");
        let request = Request::post_form(GOOGLE_OAUTH_URL, form).timeout(REQUEST_TIMEOUT);
        let response = match self.http.send(&request, cancel) {
            Ok(response) => response,
            Err(_) => return TokenRefresh::Unavailable,
        };
        match response.status {
            200..=299 => {
                let Ok(root) = serde_json::from_slice::<serde_json::Value>(&response.body) else {
                    return TokenRefresh::Unavailable;
                };
                let access = root
                    .get("access_token")
                    .and_then(|value| value.as_str())
                    .map(str::trim)
                    .filter(|value| !value.is_empty());
                let Some(access) = access else {
                    return TokenRefresh::Unavailable;
                };
                TokenRefresh::Refreshed {
                    access_token: access.to_string(),
                    expires_in: root
                        .get("expires_in")
                        .and_then(|value| value.as_f64())
                        .unwrap_or(3600.0),
                }
            }
            408 | 429 => TokenRefresh::Unavailable,
            400..=499 => {
                let error = serde_json::from_slice::<serde_json::Value>(&response.body)
                    .ok()
                    .and_then(|root| {
                        root.get("error")
                            .and_then(|value| value.as_str())
                            .map(str::to_string)
                    });
                match error.as_deref() {
                    Some(
                        "invalid_client"
                        | "deleted_client"
                        | "invalid_request"
                        | "unauthorized_client"
                        | "unsupported_grant_type"
                        | "invalid_scope",
                    ) => TokenRefresh::ClientConfigurationInvalid,
                    Some("invalid_grant") => TokenRefresh::AuthFailed,
                    _ => TokenRefresh::AuthFailed,
                }
            }
            _ => TokenRefresh::Unavailable,
        }
    }
}
