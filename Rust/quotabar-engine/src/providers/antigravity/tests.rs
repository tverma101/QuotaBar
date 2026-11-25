//! Provider-level tests: auth extraction, mapping, and the Cloud Code fallback path.

use super::*;
use crate::host::{Host, LogLevel, SecureReadOutcome, SecureReadRequest};
use crate::http::mock::{FnClient, MockClient};
use crate::http::{HttpError, Response};
use base64::Engine as _;
use std::collections::HashMap;
use std::sync::Mutex;

struct EnvHost {
    secrets: Mutex<HashMap<String, String>>,
}

impl Host for EnvHost {
    fn log(&self, _: LogLevel, _: &str, _: &str) {}
    fn log_level(&self) -> LogLevel {
        LogLevel::Error
    }
    fn secure_read(&self, request: &SecureReadRequest) -> SecureReadOutcome {
        self.secrets
            .lock()
            .unwrap()
            .get(&request.service)
            .cloned()
            .map(|value| SecureReadOutcome::Found { value })
            .unwrap_or(SecureReadOutcome::NotFound)
    }
}

fn ok(body: &str) -> Response {
    Response {
        status: 200,
        headers: Vec::new(),
        body: body.as_bytes().to_vec(),
    }
}

#[test]
fn derived_token_cache_uses_the_native_cache_file_name() {
    assert_eq!(auth::DERIVED_TOKEN_CACHE_FILE, "native-auth.json");
}

#[test]
fn cloud_code_summary_maps_meters_and_plan() {
    let dir = tempfile::tempdir().unwrap();
    let token = base64::engine::general_purpose::STANDARD
        .encode(br#"{"token":{"access_token":"access","refresh_token":"refresh"}}"#);
    let mut secrets = HashMap::new();
    secrets.insert(
        auth::KEYCHAIN_SERVICE.to_string(),
        format!("go-keyring-base64:{token}"),
    );
    let host = Arc::new(EnvHost {
        secrets: Mutex::new(secrets),
    });
    let summary = r#"{"groups":[
        {"displayName":"Gemini","buckets":[
            {"bucketId":"gemini-5h","remainingFraction":0.9},
            {"bucketId":"gemini-weekly","remainingFraction":0.8}]},
        {"displayName":"Claude","buckets":[
            {"bucketId":"3p-5h","remainingFraction":0.7},
            {"bucketId":"3p-weekly","remainingFraction":0.6}]}
    ]}"#;
    let http = Arc::new(FnClient::new(move |request| {
        if request.url.contains("retrieveUserQuotaSummary") {
            return Ok(ok(summary));
        }
        if request.url.contains("loadCodeAssist") {
            return Ok(ok(r#"{"paidTier":{"id":"g1-pro-tier"}}"#));
        }
        Err(HttpError::Transport("unexpected".into()))
    }));
    host::with_test_host(host, || {
        let provider = AntigravityProvider::with_parts(
            AntigravityAuth::with_cache_path(dir.path().join("auth.json")),
            AntigravityClient::new(http),
            AntigravityScanner::with_home(dir.path().to_path_buf()),
        );
        let mut ctx = RefreshContext::new(crate::context::Scope::Full);
        ctx.now = 1_800_000_000.0;
        let snapshot = provider.refresh(&ctx);
        assert_eq!(snapshot.plan.as_deref(), Some("Pro"));
        assert_eq!(snapshot.lines.len(), 4);
        assert_eq!(snapshot.lines[0].label(), mapper::SESSION_LABEL);
        assert_eq!(snapshot.replaces_prior_quota_progress, Some(true));
    });
}

#[test]
fn cloud_code_auth_failure_and_refresh_are_typed() {
    let dir = tempfile::tempdir().unwrap();
    let token = base64::engine::general_purpose::STANDARD
        .encode(br#"{"token":{"access_token":"expired","refresh_token":"refresh"}}"#);
    let mut secrets = HashMap::new();
    secrets.insert(
        auth::KEYCHAIN_SERVICE.to_string(),
        format!("go-keyring-base64:{token}"),
    );
    let host = Arc::new(EnvHost {
        secrets: Mutex::new(secrets),
    });
    let http = Arc::new(FnClient::new(|request| {
        if request.url == client::GOOGLE_OAUTH_URL {
            return Ok(Response {
                status: 400,
                headers: Vec::new(),
                body: br#"{"error":"invalid_grant"}"#.to_vec(),
            });
        }
        Ok(Response {
            status: 401,
            headers: Vec::new(),
            body: Vec::new(),
        })
    }));
    host::with_test_host(host, || {
        let provider = AntigravityProvider::with_parts(
            AntigravityAuth::with_cache_path(dir.path().join("auth.json")),
            AntigravityClient::new(http),
            AntigravityScanner::with_home(dir.path().to_path_buf()),
        );
        let mut ctx = RefreshContext::new(crate::context::Scope::Full);
        ctx.now = 1_800_000_000.0;
        let snapshot = provider.refresh(&ctx);
        assert_eq!(snapshot.error_category, Some(ErrorCategory::AuthExpired));
        assert!(snapshot
            .lines
            .iter()
            .any(|line| line.label() == MetricLine::ERROR_BADGE_LABEL));
    });
}

#[test]
fn cloud_code_transport_failure_is_network() {
    let dir = tempfile::tempdir().unwrap();
    let token = base64::engine::general_purpose::STANDARD
        .encode(br#"{"token":{"access_token":"access","refresh_token":"refresh"}}"#);
    let mut secrets = HashMap::new();
    secrets.insert(
        auth::KEYCHAIN_SERVICE.to_string(),
        format!("go-keyring-base64:{token}"),
    );
    let host = Arc::new(EnvHost {
        secrets: Mutex::new(secrets),
    });
    let http = MockClient::new(vec![
        Err(HttpError::Transport("down".into())),
        Err(HttpError::Transport("down".into())),
        Err(HttpError::Transport("down".into())),
        Err(HttpError::Transport("down".into())),
        Err(HttpError::Transport("down".into())),
        Err(HttpError::Transport("down".into())),
    ]);
    host::with_test_host(host, || {
        let provider = AntigravityProvider::with_parts(
            AntigravityAuth::with_cache_path(dir.path().join("auth.json")),
            AntigravityClient::new(http),
            AntigravityScanner::with_home(dir.path().to_path_buf()),
        );
        let mut ctx = RefreshContext::new(crate::context::Scope::Full);
        ctx.now = 1_800_000_000.0;
        let snapshot = provider.refresh(&ctx);
        assert_eq!(snapshot.error_category, Some(ErrorCategory::Network));
    });
}

#[test]
fn fold_only_scope_skips_network_and_keeps_history() {
    let dir = tempfile::tempdir().unwrap();
    let http = MockClient::new(vec![]);
    let provider = AntigravityProvider::with_parts(
        AntigravityAuth::with_cache_path(dir.path().join("auth.json")),
        AntigravityClient::new(http.clone()),
        AntigravityScanner::with_home(dir.path().to_path_buf()),
    );
    let mut ctx = RefreshContext::new(crate::context::Scope::PanelAccounting);
    ctx.now = 1_800_000_000.0;
    let snapshot = provider.refresh(&ctx);
    assert!(http.requests.lock().unwrap().is_empty());
    assert!(snapshot
        .lines
        .iter()
        .all(|line| !matches!(line, MetricLine::Progress { .. })));
}

fn keychain_host() -> Arc<EnvHost> {
    let token = base64::engine::general_purpose::STANDARD
        .encode(br#"{"token":{"access_token":"access","refresh_token":"refresh"}}"#);
    let mut secrets = HashMap::new();
    secrets.insert(
        auth::KEYCHAIN_SERVICE.to_string(),
        format!("go-keyring-base64:{token}"),
    );
    Arc::new(EnvHost {
        secrets: Mutex::new(secrets),
    })
}

fn header<'a>(request: &'a crate::http::Request, name: &str) -> Option<&'a str> {
    request
        .headers
        .iter()
        .find(|(key, _)| key.eq_ignore_ascii_case(name))
        .map(|(_, value)| value.as_str())
}

fn body_json(request: &crate::http::Request) -> serde_json::Value {
    request
        .body
        .as_deref()
        .and_then(|body| serde_json::from_slice(body).ok())
        .unwrap_or(serde_json::Value::Null)
}

/// Regression: the Rust port asked for the summary with a bare `antigravity` user agent and no
/// project, so Google answered with only the non-Gemini pool and Session/Weekly vanished.
#[test]
fn cloud_code_summary_uses_hub_identity_and_project_scope() {
    let dir = tempfile::tempdir().unwrap();
    let seen = Arc::new(Mutex::new(Vec::<String>::new()));
    let seen_in_client = Arc::clone(&seen);
    let gemini_and_claude = r#"{"groups":[
        {"displayName":"Gemini","buckets":[
            {"bucketId":"gemini-5h","remainingFraction":0.9},
            {"bucketId":"gemini-weekly","remainingFraction":0.8}]},
        {"displayName":"Claude","buckets":[
            {"bucketId":"3p-5h","remainingFraction":0.7},
            {"bucketId":"3p-weekly","remainingFraction":0.6}]}
    ]}"#;
    let claude_only = r#"{"groups":[
        {"displayName":"Claude","buckets":[
            {"bucketId":"3p-5h","remainingFraction":0.7},
            {"bucketId":"3p-weekly","remainingFraction":0.6}]}
    ]}"#;
    let http = Arc::new(FnClient::new(move |request| {
        seen_in_client.lock().unwrap().push(request.url.clone());
        assert_eq!(
            header(request, "User-Agent"),
            Some(client::CLIENT_USER_AGENT)
        );
        if request.url.contains("loadCodeAssist") {
            assert_eq!(
                body_json(request)["metadata"]["ideType"].as_str(),
                Some("ANTIGRAVITY")
            );
            return Ok(ok(
                r#"{"cloudaicompanionProject":"proj-1","paidTier":{"id":"g1-pro-tier"}}"#,
            ));
        }
        if request.url.contains("retrieveUserQuotaSummary") {
            let scoped = body_json(request)["project"].as_str() == Some("proj-1");
            return Ok(ok(if scoped {
                gemini_and_claude
            } else {
                claude_only
            }));
        }
        Err(HttpError::Transport("unexpected".into()))
    }));
    host::with_test_host(keychain_host(), || {
        let provider = AntigravityProvider::with_parts(
            AntigravityAuth::with_cache_path(dir.path().join("auth.json")),
            AntigravityClient::new(http),
            AntigravityScanner::with_home(dir.path().to_path_buf()),
        );
        let mut ctx = RefreshContext::new(crate::context::Scope::Full);
        ctx.now = 1_800_000_000.0;
        let snapshot = provider.refresh(&ctx);
        let labels: Vec<&str> = snapshot.lines.iter().map(MetricLine::label).collect();
        assert_eq!(
            labels,
            vec![
                mapper::SESSION_LABEL,
                mapper::WEEKLY_LABEL,
                mapper::CLAUDE_LABEL,
                mapper::CLAUDE_WEEKLY_LABEL
            ]
        );
        assert_eq!(snapshot.plan.as_deref(), Some("Pro"));
        assert_eq!(snapshot.replaces_prior_quota_progress, Some(true));
    });
    let urls = seen.lock().unwrap().clone();
    // Plan and project come from production first; the summary reads daily first.
    assert!(urls[0].starts_with(client::PLAN_PROJECT_URLS[0]));
    assert!(urls[1].starts_with(client::CLOUD_CODE_URLS[0]));
    // No per-model endpoint is consulted: it would invent "fully used" meters.
    assert!(urls
        .iter()
        .all(|url| !url.contains("fetchAvailableModels") && !url.contains(":retrieveUserQuota\0")));
}

/// A canary host refusing the token must not hide the other host's complete answer.
#[test]
fn summary_refusal_on_one_host_consults_the_other() {
    let dir = tempfile::tempdir().unwrap();
    let summary = r#"{"groups":[
        {"displayName":"Gemini","buckets":[
            {"bucketId":"gemini-5h","remainingFraction":0.5},
            {"bucketId":"gemini-weekly","remainingFraction":0.4}]},
        {"displayName":"Claude","buckets":[
            {"bucketId":"3p-5h","remainingFraction":0.3},
            {"bucketId":"3p-weekly","remainingFraction":0.2}]}
    ]}"#;
    let http = Arc::new(FnClient::new(move |request| {
        if request.url.contains("loadCodeAssist") {
            return Ok(ok("{}"));
        }
        if request.url.starts_with(client::CLOUD_CODE_URLS[0]) {
            return Ok(Response {
                status: 401,
                headers: Vec::new(),
                body: Vec::new(),
            });
        }
        Ok(ok(summary))
    }));
    host::with_test_host(keychain_host(), || {
        let provider = AntigravityProvider::with_parts(
            AntigravityAuth::with_cache_path(dir.path().join("auth.json")),
            AntigravityClient::new(http),
            AntigravityScanner::with_home(dir.path().to_path_buf()),
        );
        let mut ctx = RefreshContext::new(crate::context::Scope::Full);
        ctx.now = 1_800_000_000.0;
        let snapshot = provider.refresh(&ctx);
        assert_eq!(snapshot.error_category, None);
        assert_eq!(
            snapshot.lines.first().map(MetricLine::label),
            Some(mapper::SESSION_LABEL)
        );
        // A complete body proves the pools even though the canary host refused.
        assert_eq!(snapshot.replaces_prior_quota_progress, Some(true));
    });
}

/// A summary with no usable meter is an absent endpoint, never an invented quota.
#[test]
fn empty_summary_reports_missing_endpoint_without_legacy_fallback() {
    let dir = tempfile::tempdir().unwrap();
    let http = Arc::new(FnClient::new(move |request| {
        assert!(!request.url.contains("fetchAvailableModels"));
        if request.url.contains("loadCodeAssist") {
            return Ok(ok("{}"));
        }
        Ok(ok(r#"{"groups":[]}"#))
    }));
    host::with_test_host(keychain_host(), || {
        let provider = AntigravityProvider::with_parts(
            AntigravityAuth::with_cache_path(dir.path().join("auth.json")),
            AntigravityClient::new(http),
            AntigravityScanner::with_home(dir.path().to_path_buf()),
        );
        let mut ctx = RefreshContext::new(crate::context::Scope::Full);
        ctx.now = 1_800_000_000.0;
        let snapshot = provider.refresh(&ctx);
        assert_eq!(snapshot.error_category, Some(ErrorCategory::NotAvailable));
    });
}
