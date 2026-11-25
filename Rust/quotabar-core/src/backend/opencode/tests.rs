//! Unit tests for the OpenCode database scan. The cross-engine parity fixture lives in Swift
//! (`OpenCodeRustParityTests`); these pin the read, anchor, and failure rules.

use std::fs::{FileTimes, OpenOptions};
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::{Duration, SystemTime};

use rusqlite::Connection;
use serde_json::json;

use super::*;
use crate::backend::sqlite::query_with_retry;

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(1);
/// The two multi-second deadline tests must not compete for CPU with each other: the per-statement
/// budget is a wall-clock test, and parallel recursive CTEs make a valid statement look slow.
static SLOW_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn fixture_path() -> String {
    let id = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir()
        .join(format!("quotabar-opencode-{}-{id}.db", std::process::id()))
        .to_string_lossy()
        .into_owned()
}

fn make_database(rows: &str) -> String {
    let path = fixture_path();
    let connection = Connection::open(&path).expect("open fixture");
    connection
        .execute_batch(&format!(
            "CREATE TABLE usage (ms INTEGER, cost REAL, tokens INTEGER, model TEXT, provider TEXT);
             {rows}"
        ))
        .expect("seed fixture");
    path
}

fn scan_request(path: &str) -> Value {
    let data_sql =
        "SELECT json_group_array(json_array(ms, cost, tokens, model, provider)) FROM usage;";
    json!({
        "databases": [{
            "path": path,
            "detectionSQL": "SELECT 'message';",
            "dataSQL": {"legacy": data_sql, "v2": data_sql, "mixed": data_sql},
            "anchorSQL": {
                "legacy": "SELECT MIN(ms) FROM usage;",
                "v2": "SELECT MIN(ms) FROM usage;",
                "mixed": "SELECT MIN(ms) FROM usage;"
            }
        }]
    })
}

fn scan_one(path: &str) -> Value {
    let result = scan(&scan_request(path)).expect("scan");
    result["databases"][0].clone()
}

fn slow_rows_sql(expression: &str) -> String {
    format!(
        "WITH RECURSIVE c(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM c WHERE x<2000000) \
         SELECT {expression} FROM c;"
    )
}

fn touch(path: &str) {
    let file = OpenOptions::new()
        .write(true)
        .open(path)
        .expect("open fixture for touch");
    file.set_times(FileTimes::new().set_modified(SystemTime::now() + Duration::from_secs(2)))
        .expect("touch fixture");
}

#[test]
fn returns_the_raw_usage_payload_and_anchor() {
    let path = make_database(
        "INSERT INTO usage VALUES
           (1000, 2.0, 1000, 'glm-5.2', 'opencode-go'),
           (2000, NULL, 500, NULL, 'opencode');",
    );

    let database = scan_one(&path);
    assert_eq!(database["schema"], "legacy");
    assert!(database.get("failure").is_none());
    let usage = database["usageJSON"].as_str().expect("usage payload");
    assert!(usage.starts_with("[[1000,2.0,1000,"));
    assert!(usage.contains("null"));
    assert_eq!(database["anchorMs"], 1000.0);

    let _ = std::fs::remove_file(&path);
}

#[test]
fn missing_database_is_a_no_result_read() {
    let database = scan_one("/tmp/quotabar-opencode-does-not-exist.db");
    assert_eq!(database["failure"], "usage query returned no result");
    assert_eq!(database["schema"], "unknown");
    assert!(database["usageJSON"].is_null());
}

#[test]
fn anchor_is_memoized_per_revision_and_moves_when_the_file_changes() {
    let path = make_database("INSERT INTO usage VALUES (1000, 1.0, 10, 'm', 'opencode');");
    assert_eq!(scan_one(&path)["anchorMs"], 1000.0);

    let connection = Connection::open(&path).expect("reopen");
    connection
        .execute_batch("INSERT INTO usage VALUES (2000, 1.0, 10, 'm', 'opencode');")
        .expect("write");
    drop(connection);
    // A newer row cannot move MIN(), so the memoized answer is still correct; the anchor moves
    // when the oldest row is deleted, which also moves the file revision.
    assert_eq!(scan_one(&path)["anchorMs"], 1000.0);

    let connection = Connection::open(&path).expect("reopen");
    connection
        .execute_batch("DELETE FROM usage WHERE ms = 1000;")
        .expect("write");
    drop(connection);
    assert_eq!(scan_one(&path)["anchorMs"], 2000.0);
    let _ = std::fs::remove_file(&path);
}

#[test]
fn probe_output_chooses_the_matching_sql_variant() {
    let path = make_database("INSERT INTO usage VALUES (1000, 1.0, 10, 'm', 'opencode');");
    let legacy =
        "SELECT json_group_array(json_array(ms, cost, tokens, model, provider)) FROM usage;";
    let marker =
        "SELECT json_group_array(json_array(ms, 9.0, 10, 'mixed-only', provider)) FROM usage;";
    let request = json!({
        "databases": [{
            "path": path,
            "detectionSQL": "SELECT 'message,session_message';",
            "dataSQL": {"legacy": legacy, "v2": legacy, "mixed": marker},
            "anchorSQL": {"legacy": "SELECT 1;", "v2": "SELECT 1;", "mixed": "SELECT 1;"}
        }]
    });
    let database = &scan(&request).expect("scan")["databases"][0];
    assert_eq!(database["schema"], "mixed");
    assert!(database["usageJSON"]
        .as_str()
        .expect("usage")
        .contains("mixed-only"));
    let _ = std::fs::remove_file(&path);
}

#[test]
fn a_failing_database_does_not_stop_the_others() {
    let good = make_database("INSERT INTO usage VALUES (1000, 1.0, 10, 'm', 'opencode');");
    let request = json!({
        "databases": [
            {
                "path": "/tmp/quotabar-opencode-missing.db",
                "detectionSQL": "SELECT 'message';",
                "dataSQL": {"legacy": "SELECT 1;", "v2": "SELECT 1;", "mixed": "SELECT 1;"},
                "anchorSQL": {"legacy": "SELECT 1;", "v2": "SELECT 1;", "mixed": "SELECT 1;"}
            },
            scan_request(&good)["databases"][0].clone()
        ]
    });
    let result = scan(&request).expect("scan");
    let databases = result["databases"].as_array().expect("databases");
    assert_eq!(databases.len(), 2);
    assert!(databases[0]["failure"].is_string());
    assert!(databases[1].get("failure").is_none());
    let _ = std::fs::remove_file(&good);
}

#[test]
fn query_returns_one_value_and_treats_a_missing_file_as_null() {
    let path = make_database("INSERT INTO usage VALUES (1000, 1.0, 10, 'm', 'opencode');");
    let value = query(&json!({
        "path": path,
        "sql": "SELECT json_extract('{\"input\":3}', '$.input');"
    }))
    .expect("query");
    assert_eq!(value["value"], "3");
    assert!(value["error"].is_null());

    let missing = query(&json!({
        "path": "/tmp/quotabar-opencode-missing.db",
        "sql": "SELECT 1;"
    }))
    .expect("query");
    assert!(missing["value"].is_null());
    assert!(missing["error"].is_null());
    let _ = std::fs::remove_file(&path);
}

#[test]
fn probe_picks_the_layout_once_and_reuses_the_memo() {
    let path = make_database("INSERT INTO usage VALUES (1000, 1.0, 10, 'm', 'opencode');");
    let request = json!({
        "path": path,
        "detectionSQL": "SELECT 'session_message';",
        "sql": {
            "legacy": "SELECT 'legacy';",
            "v2": "SELECT 'v2';",
            "mixed": "SELECT 'mixed';"
        }
    });
    let first = probe(&request).expect("probe");
    assert_eq!(first["schema"], "v2");
    assert_eq!(first["value"], "v2");

    // A fresh detection statement must not matter while the revision is unchanged: the memo is
    // the one owner of the schema answer.
    let mut second_request = request.clone();
    second_request["detectionSQL"] = json!("SELECT 'nothing';");
    let second = probe(&second_request).expect("probe");
    assert_eq!(second["schema"], "v2");
    assert_eq!(second["value"], "v2");
    let _ = std::fs::remove_file(&path);
}

#[test]
fn a_schema_migration_invalidates_schema_and_anchor_together() {
    let path = make_database("INSERT INTO usage VALUES (1000, 1.0, 10, 'm', 'opencode');");
    let request = json!({
        "databases": [{
            "path": path,
            "detectionSQL": "SELECT group_concat(name) FROM (SELECT 'message' AS name);",
            "dataSQL": {
                "legacy": "SELECT json_group_array(json_array(ms, cost, tokens, model, provider)) FROM usage;",
                "v2": "SELECT 'v2';",
                "mixed": "SELECT 'mixed';"
            },
            "anchorSQL": {"legacy": "SELECT MIN(ms) FROM usage;", "v2": "SELECT 9;", "mixed": "SELECT 9;"}
        }]
    });
    let legacy = &scan(&request).expect("scan")["databases"][0];
    assert_eq!(legacy["schema"], "legacy");
    assert_eq!(legacy["anchorMs"], 1000.0);

    let connection = Connection::open(&path).expect("reopen");
    connection
        .execute_batch("CREATE TABLE session_message (id TEXT);")
        .expect("migrate");
    drop(connection);

    let mut migrated = request.clone();
    migrated["databases"][0]["detectionSQL"] = json!("SELECT 'message,session_message';");
    let mixed = &scan(&migrated).expect("scan")["databases"][0];
    assert_eq!(mixed["schema"], "mixed");
    assert_eq!(mixed["usageJSON"], "mixed");
    assert_eq!(mixed["anchorMs"], 9.0);
    let _ = std::fs::remove_file(&path);
}

#[test]
fn each_statement_installs_its_own_query_bound() {
    QUERY_BOUND_INSTALLS.with(|count| count.set(0));
    let path = make_database("INSERT INTO usage VALUES (1000, 1.0, 10, 'm', 'opencode');");
    let database = scan_one(&path);
    let installs = QUERY_BOUND_INSTALLS.with(std::cell::Cell::get);
    let _ = std::fs::remove_file(path);
    assert_eq!(
        installs, 3,
        "schema, data, and anchor each need their own bound"
    );
    assert!(database.get("failure").is_none(), "{database:?}");
    assert!(database.get("anchorFailure").is_none(), "{database:?}");
}

#[test]
fn schema_probe_does_not_cache_an_old_layout_under_a_new_revision() {
    let _guard = SLOW_TEST_LOCK.lock().unwrap();
    let path = make_database("INSERT INTO usage VALUES (1000, 1.0, 10, 'm', 'opencode');");
    let slow = json!({
        "path": path,
        "detectionSQL": slow_rows_sql("CASE WHEN count(*) > 0 THEN 'message' END")
    });

    // Change the file revision after the schema query starts but before the result is stored.
    // The old implementation stamped the cache after the query, so it would record the old
    // `message` layout under the new revision and the next probe would trust it.
    let writer_path = path.clone();
    let writer = thread::spawn(move || {
        thread::sleep(Duration::from_millis(100));
        touch(&writer_path);
    });
    let first = schema(&slow).expect("first schema probe");
    assert_eq!(first["schema"], "legacy");
    writer.join().expect("writer join");

    let second = schema(&json!({
        "path": path,
        "detectionSQL": "SELECT 'session_message';"
    }))
    .expect("second schema probe");
    assert_eq!(
        second["schema"], "v2",
        "a revision change during the probe must invalidate the memo"
    );
    let _ = std::fs::remove_file(&path);
}

#[test]
fn staged_anchor_reuses_the_memo_until_the_revision_changes() {
    let path = make_database("INSERT INTO usage VALUES (1000, 1.0, 10, 'm', 'opencode');");
    let schema_request = json!({
        "path": path,
        "detectionSQL": "SELECT 'message';"
    });
    assert_eq!(schema(&schema_request).expect("schema")["schema"], "legacy");

    let first = anchor(&json!({
        "path": path,
        "schema": "legacy",
        "sql": "SELECT MIN(ms) FROM usage;"
    }))
    .expect("anchor");
    assert_eq!(first["anchorMs"], 1000.0);

    // Same revision: the memoized anchor wins over a different statement.
    let second = anchor(&json!({
        "path": path,
        "schema": "legacy",
        "sql": "SELECT 9.0;"
    }))
    .expect("anchor memo");
    assert_eq!(second["anchorMs"], 1000.0);

    touch(&path);
    let third = anchor(&json!({
        "path": path,
        "schema": "legacy",
        "sql": "SELECT 9.0;"
    }))
    .expect("anchor after revision");
    assert_eq!(third["anchorMs"], 9.0);
    let _ = std::fs::remove_file(&path);
}

#[test]
fn a_read_only_failure_retries_the_query_with_write_access() {
    use std::cell::Cell;

    let path = make_database("INSERT INTO usage VALUES (1000, 1.0, 10, 'm', 'opencode');");
    let attempts = Cell::new(0);
    let value = query_with_retry_result(&path, |connection| {
        attempts.set(attempts.get() + 1);
        if attempts.get() == 1 {
            return Err(AttemptError::Sql(
                "attempt to write a readonly database".to_string(),
            ));
        }
        Ok(query_text(connection, "SELECT 7;")?)
    })
    .expect("retry");
    assert_eq!(value, Some("7".to_string()));
    assert_eq!(attempts.get(), 2);
    let _ = std::fs::remove_file(&path);
}

#[test]
fn query_reports_sql_failures_as_data_not_a_panic() {
    let path = make_database("INSERT INTO usage VALUES (1000, 1.0, 10, 'm', 'opencode');");
    let result =
        query(&json!({ "path": path, "sql": "SELECT missing_column FROM usage;" })).expect("query");
    assert!(result["value"].is_null());
    assert!(result["error"].is_string());
    let _ = std::fs::remove_file(&path);
}

/// Hold an EXCLUSIVE rollback-mode lock for `hold`, long enough for a read-only attempt to hit its
/// one-second busy timeout and for the read-write retry to wait out the remainder.
fn hold_exclusive_lock(path: &str, hold: std::time::Duration) -> std::thread::JoinHandle<()> {
    use std::sync::mpsc;
    use std::thread;

    let (locked_tx, locked_rx) = mpsc::channel();
    let writer_path = path.to_string();
    let writer = thread::spawn(move || {
        let connection = Connection::open(&writer_path).expect("writer open");
        connection
            .busy_timeout(std::time::Duration::from_secs(5))
            .expect("writer timeout");
        connection
            .execute_batch("BEGIN EXCLUSIVE;")
            .expect("writer lock");
        locked_tx.send(()).expect("signal lock");
        thread::sleep(hold);
        connection.execute_batch("COMMIT;").expect("writer commit");
    });
    locked_rx.recv().expect("writer locked");
    writer
}

#[test]
fn retry_recovers_when_a_contended_writer_releases_its_lock() {
    let path = make_database("INSERT INTO usage VALUES (1000, 1.0, 10, 'm', 'opencode');");
    let writer = hold_exclusive_lock(&path, std::time::Duration::from_millis(1_200));

    let value = query_with_retry(&path, "SELECT COUNT(*) FROM usage;")
        .expect("the read-write retry must succeed after the writer releases");
    assert_eq!(value.as_deref(), Some("1"));
    writer.join().expect("writer join");
    let _ = std::fs::remove_file(&path);
}

#[test]
fn probe_retries_after_a_contended_writer_releases_its_lock() {
    let path = make_database("INSERT INTO usage VALUES (1000, 1.0, 10, 'm', 'opencode');");
    let writer = hold_exclusive_lock(&path, std::time::Duration::from_millis(1_200));

    let result = probe(&json!({
        "path": path,
        "detectionSQL": "SELECT 'message' FROM usage LIMIT 1;",
        "sql": {
            "legacy": "SELECT 1 FROM usage LIMIT 1;",
            "v2": "SELECT 2 FROM usage LIMIT 1;",
            "mixed": "SELECT 3 FROM usage LIMIT 1;"
        }
    }))
    .expect("probe");
    assert_eq!(result["schema"], "legacy");
    assert_eq!(result["value"], "1");
    writer.join().expect("writer join");
    let _ = std::fs::remove_file(&path);
}
