//! Provider-level tests for Freebuff quota, auth, and the hosted+local history fold.

use super::*;
use crate::host::{Host, LogLevel, SecureReadOutcome, SecureReadRequest};
use crate::http::mock::MockClient;
use crate::http::Response;
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
    let snapshot = provider.refresh(&ctx);
    assert_eq!(snapshot.error_category, Some(ErrorCategory::Http5xx));
    assert!(snapshot.usage_history.is_some());
    assert!(snapshot
        .lines
        .iter()
        .any(|line| matches!(line, MetricLine::Values { label, .. } if label == "Last 30 Days")));
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
