//! Provider-level tests for Freebuff quota, auth, and the hosted+local history fold.

use super::*;
use crate::host::{Host, LogLevel, SecureReadOutcome, SecureReadRequest};
use crate::http::mock::MockClient;
use crate::http::Response;
use serde_json::json;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

struct EnvHost {
    env: Mutex<HashMap<String, String>>,
}

impl Host for EnvHost {
    fn log(&self, _: LogLevel, _: &str, _: &str) {}
    fn log_level(&self) -> LogLevel {
        LogLevel::Error
    }
    fn secure_read(&self, _: &SecureReadRequest) -> SecureReadOutcome {
        SecureReadOutcome::NotFound
    }
    fn env_var(&self, name: &str) -> Option<String> {
        self.env.lock().unwrap().get(name).cloned()
    }
}

fn with_auth_file(dir: &tempfile::TempDir) -> FreebuffAuthStore {
    let config = dir.path().join(".config/manicode");
    std::fs::create_dir_all(&config).unwrap();
    std::fs::write(
        config.join("credentials.json"),
        r#"{"default":{"authToken":"token"}}"#,
    )
    .unwrap();
    FreebuffAuthStore::with_home(dir.path().to_path_buf())
}

fn live_config(ctx: &mut RefreshContext) {
    ctx.config = Some(json!({"liveSessionEnabled": true, "hostedDetailEnabled": false}));
}

fn hosted_cache_key(token: &str) -> String {
    use sha2::{Digest, Sha256};
    Sha256::digest(token.as_bytes())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn write_saved_receipt(dir: &tempfile::TempDir, token: &str, timestamp_ms: f64) {
    let cache_dir = dir.path().join("Library/Application Support/QuotaBar");
    std::fs::create_dir_all(&cache_dir).unwrap();
    let cache = json!({
        "accountKey": hosted_cache_key(token),
        "windowVersion": 1,
        "chats": {},
        "runs": {
            "saved-run": {
                "receipt": {
                    "id": "cloud:saved-run",
                    "timestampMs": timestamp_ms,
                    "metricsJSON": "{\"usage\":{\"model\":\"model-a\",\"inputTokens\":100,\"outputTokens\":50,\"cachedInputTokens\":20,\"totalTokens\":150}}",
                    "model": "model-a"
                }
            }
        }
    });
    std::fs::write(
        cache_dir.join("freebuff-hosted-usage-v1.json"),
        serde_json::to_vec(&cache).unwrap(),
    )
    .unwrap();
}

fn ok(body: &str) -> Response {
    Response {
        status: 200,
        headers: Vec::new(),
        body: body.as_bytes().to_vec(),
    }
}

#[test]
fn quota_refresh_maps_meters_and_401_is_expired() {
    let dir = tempfile::tempdir().unwrap();
    let session = r#"{"status":"active","expiresAt":"2026-11-24T12:00:00Z","subscription":{"tierId":"pro","usage":{"dayUsed":4,"dayLimit":10}}}"#;
    let http = MockClient::new(vec![Ok(ok(session))]);
    let provider = FreebuffProvider::with_parts(
        with_auth_file(&dir),
        FreebuffClient::new(http),
        FreebuffScanner::with_home(dir.path().to_path_buf()),
    );
    let mut ctx = RefreshContext::new(crate::context::Scope::Full);
    ctx.now = 1_800_000_000.0;
    live_config(&mut ctx);
    let snapshot = provider.refresh(&ctx);
    assert_eq!(snapshot.plan.as_deref(), Some("pro"));
    assert!(snapshot.lines.iter().any(|line| line.label() == "Daily"));
    assert!(snapshot.active_sessions.is_some());

    let http = MockClient::new(vec![Ok(Response {
        status: 401,
        headers: Vec::new(),
        body: Vec::new(),
    })]);
    let provider = FreebuffProvider::with_parts(
        with_auth_file(&dir),
        FreebuffClient::new(http),
        FreebuffScanner::with_home(dir.path().to_path_buf()),
    );
    let snapshot = provider.refresh(&ctx);
    assert_eq!(snapshot.error_category, Some(ErrorCategory::AuthExpired));
}

#[test]
fn local_database_history_appends_tiles_and_survives_quota_failure() {
    let dir = tempfile::tempdir().unwrap();
    let project = dir.path().join(".config/freebuff-desktop/projects/p");
    std::fs::create_dir_all(&project).unwrap();
    let db = rusqlite::Connection::open(project.join("desktop-v2.db")).unwrap();
    db.execute_batch(
        "CREATE TABLE threads (id TEXT PRIMARY KEY, harness_id TEXT, model TEXT, world_snapshot TEXT);
         CREATE TABLE messages (thread_id TEXT, seq INTEGER, role TEXT, ts INTEGER, metrics_json TEXT, request_id TEXT);
         INSERT INTO threads VALUES ('t','codebuff','m','{}');
         INSERT INTO messages VALUES ('t',0,'assistant',1800000000000,'{\"usage\":{\"inputTokens\":100,\"outputTokens\":50}}','');",
    )
    .unwrap();
    drop(db);
    let http = MockClient::new(vec![Ok(Response {
        status: 500,
        headers: Vec::new(),
        body: Vec::new(),
    })]);
    let provider = FreebuffProvider::with_parts(
        with_auth_file(&dir),
        FreebuffClient::new(http),
        FreebuffScanner::with_home(dir.path().to_path_buf()),
    );
    let mut ctx = RefreshContext::new(crate::context::Scope::Full);
    ctx.now = 1_800_000_100.0;
    live_config(&mut ctx);
    let snapshot = provider.refresh(&ctx);
    assert_eq!(snapshot.error_category, Some(ErrorCategory::Http5xx));
    assert!(snapshot.usage_history.is_some());
    assert!(snapshot
        .lines
        .iter()
        .any(|line| matches!(line, MetricLine::Values { label, .. } if label == "Last 30 Days")));
}

#[test]
fn offline_default_never_requests_network_but_uses_saved_hosted_receipts() {
    let dir = tempfile::tempdir().unwrap();
    write_saved_receipt(&dir, "token", 1_800_000_000_000.0);
    let http = MockClient::new(vec![]);
    let provider = FreebuffProvider::with_parts(
        with_auth_file(&dir),
        FreebuffClient::new(http.clone()),
        FreebuffScanner::with_home(dir.path().to_path_buf()),
    );
    let mut ctx = RefreshContext::new(crate::context::Scope::Full);
    ctx.now = 1_800_000_100.0;

    let snapshot = provider.refresh(&ctx);

    assert!(
        http.requests.lock().unwrap().is_empty(),
        "offline public builds must not request session, hosted history, or catalogue APIs"
    );
    assert_eq!(
        snapshot.warning.as_deref(),
        Some("Live Freebuff quotas and session timers are unavailable. QuotaBar shows saved measurements only.")
    );
    assert_eq!(snapshot.clears_prior_menu_bar_quota_state, Some(true));
    assert!(snapshot.lines.iter().any(|line| matches!(
        line,
        MetricLine::Values { label, values, .. } if label == "Hours Balance" && values.is_empty()
    )));
    let history = snapshot
        .usage_history
        .expect("saved hosted receipt history");
    assert!(history.series.daily.iter().any(|day| day.total_tokens > 0));
}

#[test]
fn session_only_config_does_not_request_hosted_history() {
    let dir = tempfile::tempdir().unwrap();
    let session = r#"{"status":"active","expiresAt":"2026-11-24T12:00:00Z","subscription":{"tierId":"pro","usage":{"dayUsed":4,"dayLimit":10}}}"#;
    let http = MockClient::new(vec![Ok(ok(session))]);
    let provider = FreebuffProvider::with_parts(
        with_auth_file(&dir),
        FreebuffClient::new(http.clone()),
        FreebuffScanner::with_home(dir.path().to_path_buf()),
    );
    let mut ctx = RefreshContext::new(crate::context::Scope::Full);
    ctx.now = 1_800_000_000.0;
    live_config(&mut ctx);

    let snapshot = provider.refresh(&ctx);

    assert_eq!(snapshot.plan.as_deref(), Some("pro"));
    let requests = http.requests.lock().unwrap();
    assert_eq!(
        requests.len(),
        1,
        "hosted history/model catalogue stay disabled in the private local build"
    );
    assert!(requests[0].url.contains("/api/v1/freebuff/session"));
}

#[test]
fn hosted_history_is_used_when_present_and_has_no_auth_still_folds_local() {
    let dir = tempfile::tempdir().unwrap();
    let http = MockClient::new(vec![]);
    let host = EnvHost {
        env: Mutex::new(HashMap::new()),
    };
    crate::host::with_test_host(Arc::new(host), || {
        let provider = FreebuffProvider::with_parts(
            FreebuffAuthStore::with_home(dir.path().join("missing")),
            FreebuffClient::new(http.clone()),
            FreebuffScanner::with_home(dir.path().to_path_buf()),
        );
        let mut ctx = RefreshContext::new(crate::context::Scope::PanelAccounting);
        ctx.now = 1_800_000_000.0;
        let snapshot = provider.refresh(&ctx);
        assert!(http.requests.lock().unwrap().is_empty());
        assert_eq!(snapshot.error_category, None);
    });
}
