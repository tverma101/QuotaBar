//! Provider-level tests: auth extraction, mapping, and the Cloud Code fallback path.

use super::*;
use crate::host::{Host, LogLevel};
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
