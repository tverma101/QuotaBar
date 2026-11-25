//! Incremental Desktop reads against a schema shaped like Freebuff Desktop's.

use super::*;
use crate::context::CancelToken;
use crate::pricing::ModelPricing;
use crate::providers::freebuff::scanner::FreebuffScanner;
use tempfile::TempDir;

fn usage(input: i64, output: i64) -> String {
    format!(r#"{{"usage":{{"inputTokens":{input},"outputTokens":{output},"model":"model-a"}}}}"#)
}

fn database(dir: &TempDir) -> std::path::PathBuf {
    let project = dir.path().join(".config/freebuff-desktop/projects/p");
    std::fs::create_dir_all(&project).unwrap();
    let path = project.join("desktop-v2.db");
    Connection::open(&path)
        .unwrap()
        .execute_batch(
            "CREATE TABLE threads (id TEXT PRIMARY KEY, harness_id TEXT, model TEXT, world_snapshot TEXT);
             CREATE TABLE messages (seq INTEGER PRIMARY KEY AUTOINCREMENT, thread_id TEXT NOT NULL,
               request_id TEXT, role TEXT NOT NULL, parts_json TEXT NOT NULL DEFAULT '[]',
               metrics_json TEXT NOT NULL DEFAULT '{}', ts INTEGER NOT NULL);
             INSERT INTO threads VALUES ('t1', 'codebuff', 'model-a', '{}');",
        )
        .unwrap();
    path
}

fn insert(path: &Path, metrics: &str, ts: i64) {
    Connection::open(path)
        .unwrap()
        .execute(
            "INSERT INTO messages (thread_id, role, parts_json, metrics_json, ts) VALUES ('t1', 'assistant', '[\"text\"]', ?1, ?2)",
            rusqlite::params![metrics, ts],
        )
        .unwrap();
}

fn tokens(index: &MessageIndex) -> Vec<(String, f64)> {
    index
        .turns()
        .map(|turn| (turn.id.clone(), turn.timestamp_ms))
        .collect()
}

#[test]
fn only_new_or_resized_rows_are_read_again() {
    let dir = TempDir::new().unwrap();
    let path = database(&dir);
    insert(&path, &usage(10, 5), 1_000);
    insert(&path, "{}", 2_000);
    let first = read(&path, None).unwrap();
    assert_eq!(
        tokens(&first).len(),
        2,
        "a row without usage yet stays as a partial turn"
    );

    let connection = Connection::open(&path).unwrap();
    // `ts` is not in the signature: an unchanged row keeps its cached turn, proving no re-read.
    connection
        .execute("UPDATE messages SET ts = 9999 WHERE seq = 1", [])
        .unwrap();
    // The streaming row finishes: its metrics grow, so it is read again (its new `ts` shows it).
    connection
        .execute(
            "UPDATE messages SET metrics_json = ?1, ts = 2500 WHERE seq = 2",
            [usage(20, 10)],
        )
        .unwrap();
    insert(&path, &usage(1, 1), 3_000);
    let second = read(&path, Some(&first)).unwrap();
    assert_eq!(
        tokens(&second),
        vec![
            ("t1:1".to_string(), 1_000.0),
            ("t1:2".to_string(), 2_500.0),
            ("t1:3".to_string(), 3_000.0),
        ]
    );

    connection
        .execute("DELETE FROM messages WHERE seq = 2", [])
        .unwrap();
    let third = read(&path, Some(&second)).unwrap();
    assert_eq!(
        tokens(&third)
            .into_iter()
            .map(|(id, _)| id)
            .collect::<Vec<_>>(),
        vec!["t1:1", "t1:3"]
    );
}

/// Regression: every memory-pressure unload dropped the Desktop cache, so the next pass re-read
/// every transcript's overflow pages (about 830 MB for a 1.3 GB project).
#[test]
fn memory_unload_keeps_the_row_index() {
    let dir = TempDir::new().unwrap();
    let path = database(&dir);
    insert(&path, &usage(10, 5), 1_800_000_000_000);
    let scanner = FreebuffScanner::with_home(dir.path().to_path_buf());
    let pricing = ModelPricing::default();
    let now = 1_800_000_100.0;
    let first = scanner
        .scan(now, &pricing, &Default::default(), &[], &CancelToken::new())
        .unwrap();
    assert_eq!(first.usage.series.daily[0].total_tokens, 15);

    scanner.unload_caches();
    // Move the revision without touching the indexed row's header fields. A re-read would pick
    // up the new timestamp and drop the row from the window; the kept index does not.
    Connection::open(&path)
        .unwrap()
        .execute("UPDATE messages SET ts = 1 WHERE seq = 1", [])
        .unwrap();
    let second = scanner
        .scan(now, &pricing, &Default::default(), &[], &CancelToken::new())
        .unwrap();
    assert_eq!(second.usage.series, first.usage.series);
}
