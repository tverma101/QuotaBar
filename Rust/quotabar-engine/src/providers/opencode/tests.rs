use super::*;
use crate::context::{CancelToken, RefreshContext, Scope};
use crate::http::{HttpClient, HttpError, Request, Response};
use std::sync::Arc;

struct FakeHttp {
    status: u16,
    body: &'static str,
}

impl HttpClient for FakeHttp {
    fn send(&self, _: &Request, _: &CancelToken) -> Result<Response, HttpError> {
        Ok(Response {
            status: self.status,
            headers: Vec::new(),
            body: self.body.as_bytes().to_vec(),
        })
    }
}

fn create_v2_database(path: &Path) {
    let conn = rusqlite::Connection::open(path).unwrap();
    conn.execute_batch(
        "CREATE TABLE session_message (id TEXT PRIMARY KEY, type TEXT, time_created INTEGER, data TEXT);",
    )
    .unwrap();
    let now_ms = 1_780_000_000_000i64;
    for (id, cost, tokens, model) in [("m1", 2.0, 1_000, "glm-5.2"), ("m2", 1.0, 500, "gpt-5.5")] {
        let data = format!(
            r#"{{"role":"assistant","cost":{cost},"tokens":{{"total":{tokens}}},"model":{{"id":"{model}","providerID":"opencode-go"}}}}"#
        );
        conn.execute(
            "INSERT INTO session_message (id, type, time_created, data) VALUES (?1, 'assistant', ?2, ?3)",
            rusqlite::params![id, now_ms, data],
        )
        .unwrap();
    }
}

fn context(data_directory: &Path) -> RefreshContext {
    let mut ctx = RefreshContext::new(Scope::Full);
    ctx.now = 1_780_000_100.0;
    ctx.config = Some(serde_json::json!({
        "dataDirectory": data_directory,
        "gatewayClaude": false,
        "gatewayCodex": false,
        "gatewayHermes": false,
        "gatewayMuse": false
    }));
    ctx
}

#[test]
fn provider_uses_local_database_and_go_account_api() {
    let dir = tempfile::tempdir().unwrap();
    let data = dir.path().join("opencode");
    std::fs::create_dir_all(&data).unwrap();
    std::fs::write(
        data.join(auth::AUTH_FILE),
        r#"{"opencode-go":{"type":"api","key":"sk-go"}}"#,
    )
    .unwrap();
    create_v2_database(&data.join("opencode.db"));
    let http = Arc::new(FakeHttp {
        status: 200,
        body: r#"{"usage":{"rolling":{"status":"ok","percent":20},"weekly":{"status":"ok","percent":30},"monthly":{"status":"ok","percent":40}}}"#,
    });
    let provider =
        OpenCodeProvider::with_parts(dir.path().to_path_buf(), dir.path().to_path_buf(), http);
    assert!(
        provider.has_local_credentials_with_config(Some(&serde_json::json!({
            "dataDirectory": data
        })))
    );

    let snapshot = provider.refresh(&context(&data));
    assert_eq!(snapshot.error_category, None);
    assert_eq!(snapshot.plan.as_deref(), Some("Go"));
    assert!(snapshot.lines.iter().any(|line| line.label() == "Session"));
    assert!(snapshot.lines.iter().any(|line| line.label() == "Today"));
    let history = snapshot.usage_history.expect("local history");
    assert!(!history.series.daily.is_empty());
}

#[test]
fn parsed_rows_are_reused_until_the_database_changes() {
    let dir = tempfile::tempdir().unwrap();
    let data = dir.path().join("opencode");
    std::fs::create_dir_all(&data).unwrap();
    let database = data.join("opencode.db");
    create_v2_database(&database);
    let scan = || {
        scanner::scan(
            &[database.clone()],
            30,
            1_780_000_100.0,
            Arc::new(ModelPricing::default()),
            &FoldSources::default(),
            &CancelToken::new(),
        )
        .unwrap()
        .unwrap()
        .log_scan
        .series
        .daily
        .iter()
        .map(|day| day.total_tokens)
        .sum::<i64>()
    };

    assert_eq!(scan(), 1_500);
    assert_eq!(
        scan(),
        1_500,
        "an unchanged database must reuse the parsed rows"
    );

    let connection = rusqlite::Connection::open(&database).unwrap();
    connection
        .execute(
            "INSERT INTO session_message VALUES ('m3', 'assistant', 1780000000000, ?1)",
            [r#"{"role":"assistant","cost":1.0,"tokens":{"total":250},"model":{"id":"glm-5.2","providerID":"opencode-go"}}"#],
        )
        .unwrap();
    drop(connection);

    assert_eq!(
        scan(),
        1_750,
        "a database write must invalidate the row cache"
    );
}

#[test]
fn unreadable_database_fails_loudly_instead_of_rendering_zero() {
    let dir = tempfile::tempdir().unwrap();
    let data = dir.path().join("opencode");
    std::fs::create_dir_all(&data).unwrap();
    std::fs::write(
        data.join(auth::AUTH_FILE),
        r#"{"opencode-go":{"type":"api","key":"sk-go"}}"#,
    )
    .unwrap();
    std::fs::write(data.join("opencode.db"), "not a sqlite database").unwrap();
    let provider = OpenCodeProvider::with_parts(
        dir.path().to_path_buf(),
        dir.path().to_path_buf(),
        Arc::new(FakeHttp {
            status: 200,
            body: "{}",
        }),
    );
    let snapshot = provider.refresh(&context(&data));
    assert_eq!(
        snapshot.error_category,
        Some(ErrorCategory::CredentialAccess)
    );
}

#[test]
fn account_errors_surface_as_a_warning_while_history_still_publishes() {
    let dir = tempfile::tempdir().unwrap();
    let data = dir.path().join("opencode");
    std::fs::create_dir_all(&data).unwrap();
    std::fs::write(
        data.join(auth::AUTH_FILE),
        r#"{"opencode-go":{"type":"api","key":"sk-go"}}"#,
    )
    .unwrap();
    create_v2_database(&data.join("opencode.db"));
    let provider = OpenCodeProvider::with_parts(
        dir.path().to_path_buf(),
        dir.path().to_path_buf(),
        Arc::new(FakeHttp {
            status: 401,
            body: "{}",
        }),
    );
    let snapshot = provider.refresh(&context(&data));
    assert_eq!(snapshot.error_category, None);
    assert!(snapshot.warning.is_some());
    assert!(snapshot.usage_history.is_some());
    assert_eq!(snapshot.clears_prior_menu_bar_quota_state, Some(true));
}

#[test]
fn scans_v1_and_v2_rows_once_during_migration() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("opencode.db");
    let conn = rusqlite::Connection::open(&path).unwrap();
    conn.execute_batch(
        "CREATE TABLE message (id TEXT PRIMARY KEY, time_created INTEGER, data TEXT);
         CREATE TABLE session_message (id TEXT PRIMARY KEY, type TEXT, time_created INTEGER, data TEXT);",
    )
    .unwrap();
    for table in ["message", "session_message"] {
        let data = r#"{"role":"assistant","cost":1.0,"tokens":{"total":100},"modelID":"m","providerID":"opencode-go"}"#;
        if table == "message" {
            conn.execute(
                "INSERT INTO message VALUES ('same', 1780000000000, ?1)",
                [data],
            )
            .unwrap();
        } else {
            conn.execute(
                "INSERT INTO session_message VALUES ('same', 'assistant', 1780000000000, ?1)",
                [data],
            )
            .unwrap();
        }
    }
    let scan = scanner::scan(
        &[path],
        30,
        1_780_000_100.0,
        Arc::new(ModelPricing::default()),
        &FoldSources::default(),
        &CancelToken::new(),
    )
    .unwrap()
    .unwrap();
    assert_eq!(scan.log_scan.series.daily.len(), 1);
    assert_eq!(scan.log_scan.series.daily[0].total_tokens, 100);
}
