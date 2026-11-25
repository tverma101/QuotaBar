//! Copilot HTTP requests for personal seat usage and org billing.

use crate::context::CancelToken;
use crate::http::{HttpClient, HttpError, Request, Response};
use serde_json::Value;
use std::collections::HashSet;
use std::time::Duration;

pub const USAGE_URL: &str = "https://api.github.com/copilot_internal/user";
pub const USER_ORGS_URL: &str = "https://api.github.com/user/orgs?per_page=100";

const USAGE_TIMEOUT: Duration = Duration::from_secs(10);
const ORG_TIMEOUT: Duration = Duration::from_secs(15);

pub fn fetch_usage(
    http: &dyn HttpClient,
    token: &str,
    cancel: &CancelToken,
) -> Result<Response, HttpError> {
    let req = Request::get(USAGE_URL)
        .header("Authorization", format!("token {token}"))
        .header("Accept", "application/json")
        .header("Editor-Version", "vscode/1.96.2")
        .header("Editor-Plugin-Version", "copilot-chat/0.26.7")
        .header("User-Agent", "GitHubCopilotChat/0.26.7")
        .header("X-Github-Api-Version", "2025-04-01")
        .timeout(USAGE_TIMEOUT);
    http.send(&req, cancel)
}

pub fn usage_summary_url(org: &str) -> String {
    let encoded: String = org
        .bytes()
        .flat_map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => vec![b as char],
            other => format!("%{other:02X}").chars().collect(),
        })
        .collect();
    format!("https://api.github.com/orgs/{encoded}/settings/billing/usage/summary")
}

pub fn fetch_usage_summary(
    http: &dyn HttpClient,
    org: &str,
    token: &str,
    cancel: &CancelToken,
) -> Result<Response, HttpError> {
    send_org_get(http, &usage_summary_url(org), token, cancel)
}

pub fn send_org_get(
    http: &dyn HttpClient,
    url: &str,
    token: &str,
    cancel: &CancelToken,
) -> Result<Response, HttpError> {
    let req = Request::get(url)
        .header("Authorization", format!("token {token}"))
        .header("Accept", "application/vnd.github+json")
        .header("User-Agent", "QuotaBar")
        .header("X-GitHub-Api-Version", "2022-11-28")
        .timeout(ORG_TIMEOUT);
    http.send(&req, cancel)
}

pub struct OrgsFetchResult {
    pub response: Response,
    pub partial_status: Option<String>,
    pub partial_rate_limited: bool,
}

pub fn fetch_user_orgs(
    http: &dyn HttpClient,
    token: &str,
    cancel: &CancelToken,
) -> Result<OrgsFetchResult, HttpError> {
    let mut next_url = Some(USER_ORGS_URL.to_string());
    let mut visited = HashSet::new();
    let mut orgs: Vec<Value> = Vec::new();
    let mut final_response: Option<Response> = None;

    for _ in 0..100 {
        let Some(url) = next_url.take() else { break };
        if !visited.insert(url.clone()) {
            return Err(HttpError::Transport(
                "repeated GitHub pagination URL".into(),
            ));
        }
        if cancel.is_cancelled() {
            return Err(HttpError::Cancelled);
        }
        let resp = match send_org_get(http, &url, token, cancel) {
            Ok(resp) => resp,
            Err(HttpError::Cancelled) => return Err(HttpError::Cancelled),
            Err(err) => {
                if !orgs.is_empty() {
                    if let Some(mut prev) = final_response {
                        prev.body = serde_json::to_vec(&orgs).unwrap_or(prev.body);
                        return Ok(OrgsFetchResult {
                            response: prev,
                            partial_status: Some("transport".into()),
                            partial_rate_limited: false,
                        });
                    }
                }
                return Err(err);
            }
        };
        if resp.status != 200 {
            if !orgs.is_empty() {
                let mut merged = resp.clone();
                merged.status = 200;
                merged.body = serde_json::to_vec(&orgs).unwrap_or(merged.body);
                return Ok(OrgsFetchResult {
                    response: merged,
                    partial_status: Some(resp.status.to_string()),
                    partial_rate_limited: is_rate_limit_response(&resp),
                });
            }
            return Ok(OrgsFetchResult {
                response: resp,
                partial_status: None,
                partial_rate_limited: false,
            });
        }
        let Ok(Value::Array(items)) = serde_json::from_slice::<Value>(&resp.body) else {
            if !orgs.is_empty() {
                if let Some(mut prev) = final_response {
                    prev.body = serde_json::to_vec(&orgs).unwrap_or(prev.body);
                    return Ok(OrgsFetchResult {
                        response: prev,
                        partial_status: Some("invalid-body".into()),
                        partial_rate_limited: false,
                    });
                }
            }
            return Ok(OrgsFetchResult {
                response: resp,
                partial_status: None,
                partial_rate_limited: false,
            });
        };
        orgs.extend(items);
        next_url = next_link_url(resp.header("link"));
        final_response = Some(resp);
        if next_url.is_none() {
            break;
        }
    }

    let mut resp = final_response.unwrap_or_default();
    resp.status = 200;
    resp.body = serde_json::to_vec(&orgs).unwrap_or_default();
    let partial_status = next_url.map(|_| "page-limit".to_string());
    Ok(OrgsFetchResult {
        response: resp,
        partial_status,
        partial_rate_limited: false,
    })
}

pub fn is_rate_limit_response(resp: &Response) -> bool {
    let remaining = resp.header("x-ratelimit-remaining").map(str::trim);
    if resp.status == 429 || (resp.status == 200 && remaining == Some("0")) {
        return true;
    }
    if resp.status != 403 {
        return false;
    }
    if resp.header("retry-after").is_some() || remaining == Some("0") {
        return true;
    }
    contains_secondary_rate_limit_message(&resp.body)
}

fn contains_secondary_rate_limit_message(body: &[u8]) -> bool {
    let msg = serde_json::from_slice::<Value>(body)
        .ok()
        .and_then(|v| {
            v.get("message")
                .and_then(Value::as_str)
                .map(ToString::to_string)
        })
        .unwrap_or_else(|| String::from_utf8_lossy(body).into_owned());
    let lower = msg.to_ascii_lowercase();
    lower.contains("secondary rate limit")
        || lower.contains("rate limit exceeded")
        || lower.contains("rate-limit exceeded")
        || lower.contains("abuse detection")
}

pub fn next_link_url(link_header: Option<&str>) -> Option<String> {
    let header = link_header?;
    for part in header.split(',') {
        let mut segments = part.split(';');
        let Some(url_seg) = segments.next() else {
            continue;
        };
        let is_next = segments.any(|seg| {
            let trimmed = seg.trim();
            trimmed == r#"rel="next""# || trimmed == "rel='next'" || trimmed == "rel=next"
        });
        if is_next {
            let trimmed = url_seg.trim();
            if let Some(inner) = trimmed.strip_prefix('<').and_then(|s| s.strip_suffix('>')) {
                if !inner.is_empty() {
                    return Some(inner.to_string());
                }
            }
        }
    }
    None
}
