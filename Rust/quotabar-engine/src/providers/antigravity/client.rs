//! Antigravity network I/O: local language-server RPC, Cloud Code endpoints, and Google OAuth.
//! (`Providers/Antigravity/AntigravityUsageClient`.)

use crate::context::CancelToken;
use crate::http::{self, HttpClient, HttpError, Request};
use std::sync::Arc;
use std::time::Duration;

pub const LS_SERVICE: &str = "exa.language_server_pb.LanguageServerService";
/// Daily has the active counters for the quota pools; production can return untouched Gemini
/// windows, so the summary tries daily first and falls back to production.
pub const CLOUD_CODE_URLS: [&str; 2] = [
    "https://daily-cloudcode-pa.googleapis.com",
    "https://cloudcode-pa.googleapis.com",
];
/// Plan and project lookups prefer production; daily has the active counters for quota reads.
pub const PLAN_PROJECT_URLS: [&str; 2] = [
    "https://cloudcode-pa.googleapis.com",
    "https://daily-cloudcode-pa.googleapis.com",
];
pub const LOAD_CODE_ASSIST_PATH: &str = "/v1internal:loadCodeAssist";
pub const QUOTA_SUMMARY_PATH: &str = "/v1internal:retrieveUserQuotaSummary";
/// The hub client identity exposes the Gemini pools, the separate Argon quota and the paid tier;
/// the bare IDE identity omits them, and Google marks other callers `UNSUPPORTED_CLIENT`. Every
/// Cloud Code call uses it (upstream openusage#1676).
#[cfg(target_arch = "aarch64")]
pub const CLIENT_USER_AGENT: &str =
    "antigravity/hub/2.24.0 (aidev_client; os_type=darwin; arch=arm64)";
#[cfg(not(target_arch = "aarch64"))]
pub const CLIENT_USER_AGENT: &str =
    "antigravity/hub/2.24.0 (aidev_client; os_type=darwin; arch=amd64)";
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

    /// POST one Cloud Code endpoint across `bases`. A 401 is evidence of invalid or expired
    /// authentication; a 403 is a permission denial and must not trigger an OAuth refresh. Both
    /// short-circuit because the same request would fail on the other base.
    pub fn cloud_code(
        &self,
        path: &str,
        token: &str,
        body: &serde_json::Value,
        bases: &[&str],
        cancel: &CancelToken,
    ) -> CloudCodeOutcome {
        self.cloud_code_responses(path, token, body, false, bases, cancel)
            .first()
    }

    /// A host can omit an entire quota pool. Consult the other host only when the first usable
    /// body cannot supply all shared meters; a failed supplemental host never discards measured
    /// limits. The saved sign-in's `project` scopes the summary when `loadCodeAssist` reported one.
    pub fn cloud_code_summaries(
        &self,
        token: &str,
        project: Option<&str>,
        cancel: &CancelToken,
    ) -> CloudCodeBatch {
        let body = match project {
            Some(project) => serde_json::json!({ "project": project }),
            None => serde_json::json!({}),
        };
        self.cloud_code_responses(
            QUOTA_SUMMARY_PATH,
            token,
            &body,
            true,
            &CLOUD_CODE_URLS,
            cancel,
        )
    }

    fn cloud_code_responses(
        &self,
        path: &str,
        token: &str,
        body: &serde_json::Value,
        collect_summaries: bool,
        bases: &[&str],
        cancel: &CancelToken,
    ) -> CloudCodeBatch {
        if cancel.is_cancelled() {
            return CloudCodeBatch::Unavailable;
        }
        let payload = serde_json::to_vec(body).unwrap_or_else(|_| b"{}".to_vec());
        let mut saw_not_found = false;
        let mut saw_other_failure = false;
        let mut saw_auth_failure = false;
        let mut saw_forbidden = false;
        let mut bodies = Vec::new();
        for base in bases {
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
                    ("User-Agent".into(), CLIENT_USER_AGENT.into()),
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
                if collect_summaries {
                    // A refusal on one host may not hold on the other (daily is a canary host that
                    // can 401 a token production accepts), so the summary consults both before
                    // classifying. Other paths short-circuit: the same token fails there too.
                    if response.status == 401 {
                        saw_auth_failure = true;
                    } else {
                        saw_forbidden = true;
                    }
                    continue;
                }
                return if response.status == 401 {
                    CloudCodeBatch::AuthFailed
                } else {
                    CloudCodeBatch::Forbidden
                };
            }
            if response.is_success() {
                bodies.push(response.body);
                let complete = !collect_summaries
                    || bodies.last().is_some_and(|body| {
                        crate::providers::antigravity::mapper::has_all_shared_quota_meters(body)
                    });
                if complete {
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
                all_hosts_answered: !saw_not_found
                    && !saw_other_failure
                    && !saw_auth_failure
                    && !saw_forbidden,
            };
        }
        if saw_auth_failure {
            CloudCodeBatch::AuthFailed
        } else if saw_forbidden {
            CloudCodeBatch::Forbidden
        } else if saw_not_found && !saw_other_failure {
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
