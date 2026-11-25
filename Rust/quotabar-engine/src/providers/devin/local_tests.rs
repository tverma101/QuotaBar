use super::sessions::{DevinSessionEntry, DevinSessionUsageReader, FoldKind};
use super::transcripts::{aggregate, parse_bytes, DevinTranscriptUsageScanner};
use crate::context::CancelToken;
use crate::pricing::{ModelPricing, ModelRates, PricingCatalog, PricingSupplement, TokenBreakdown};
use crate::time;
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use std::path::Path;
use std::sync::Arc;

fn create_sessions_db(path: &Path, rows: &[(&str, &str, Value)]) {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).unwrap();
    }
    let conn = Connection::open(path).unwrap();
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS message_nodes (
            row_id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            chat_message TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_message_nodes_session ON message_nodes(session_id);",
    )
    .unwrap();
    append_rows(&conn, rows);
}

fn append_rows(conn: &Connection, rows: &[(&str, &str, Value)]) {
    for (sess, _role_hint, msg) in rows {
        let text = serde_json::to_string(msg).unwrap();
        conn.execute(
            "INSERT INTO message_nodes (session_id, created_at, chat_message) VALUES (?1, ?2, ?3)",
            params![sess, 1_781_000_000i64, text],
        )
        .unwrap();
    }
}

fn assistant_msg(req: Option<&str>, ts: &str, model: &str, metrics: Value) -> Value {
    let mut meta = serde_json::Map::new();
    if let Some(r) = req {
        meta.insert("request_id".into(), json!(r));
    }
    meta.insert("created_at".into(), json!(ts));
    meta.insert("generation_model".into(), json!(model));
    meta.insert("metrics".into(), metrics);
    json!({ "role": "assistant", "metadata": Value::Object(meta) })
}

#[test]
fn session_reader_verified_incremental_delete_update_and_damage() {
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("cli/sessions.db");
    let cache = dir.path().join("cache");
    let ts = "2026-06-10T10:00:00.000Z";
    create_sessions_db(
        &db,
        &[
            (
                "s1",
                "a",
                assistant_msg(
                    Some("req-a"),
                    ts,
                    "swe-2-max",
                    json!({"input_tokens": 10, "output_tokens": 1}),
                ),
            ),
            (
                "s1",
                "a",
                assistant_msg(
                    Some("req-b"),
                    ts,
                    "swe-2-max",
                    json!({"input_tokens": 20, "output_tokens": 2}),
                ),
            ),
        ],
    );

    let mut r1 = DevinSessionUsageReader::new(Some(cache.clone()));
    let entries = r1.entries(&db).unwrap();
    assert_eq!(r1.last_fold_kind, Some(FoldKind::Full));
    assert_eq!(
        entries.iter().map(|e| e.tokens.total_tokens()).sum::<i64>(),
        33
    );

    // Warm reader verifies from disk without refolding
    let mut r2 = DevinSessionUsageReader::new(Some(cache.clone()));
    let served = r2.entries(&db).unwrap();
    assert!(r2.adopted_disk_record);
    assert_eq!(r2.last_fold_kind, Some(FoldKind::Verified));
    assert_eq!(served, entries);

    // Append newer copy of req-a + req-c
    {
        let conn = Connection::open(&db).unwrap();
        append_rows(
            &conn,
            &[
                (
                    "s1",
                    "a",
                    assistant_msg(
                        Some("req-a"),
                        ts,
                        "swe-2-max",
                        json!({"input_tokens": 99, "output_tokens": 9}),
                    ),
                ),
                (
                    "s1",
                    "a",
                    assistant_msg(Some("req-c"), ts, "swe-2-max", json!({"output_tokens": 5})),
                ),
            ],
        );
    }
    let mut r3 = DevinSessionUsageReader::new(Some(cache.clone()));
    let e3 = r3.entries(&db).unwrap();
    assert_eq!(r3.last_fold_kind, Some(FoldKind::Incremental));
    assert_eq!(e3.iter().map(|e| e.tokens.total_tokens()).sum::<i64>(), 135);

    // In-place update moving request_id forces Full fold and promotes runner-up
    {
        let conn = Connection::open(&db).unwrap();
        let moved = serde_json::to_string(&assistant_msg(
            Some("req-moved"),
            ts,
            "swe-2-max",
            json!({"input_tokens": 99, "output_tokens": 9}),
        ))
        .unwrap();
        conn.execute(
            "UPDATE message_nodes SET chat_message = ?1 WHERE row_id = 3",
            params![moved],
        )
        .unwrap();
    }
    let mut r4 = DevinSessionUsageReader::new(Some(cache.clone()));
    let e4 = r4.entries(&db).unwrap();
    assert_eq!(r4.last_fold_kind, Some(FoldKind::Full));
    assert_eq!(e4.iter().map(|e| e.tokens.total_tokens()).sum::<i64>(), 146);

    // Damaged appended row fails whole read
    {
        let conn = Connection::open(&db).unwrap();
        append_rows(
            &conn,
            &[(
                "s1",
                "a",
                assistant_msg(
                    Some("req-bad"),
                    ts,
                    "swe-2-max",
                    json!({"input_tokens": "bad"}),
                ),
            )],
        );
    }
    let mut r5 = DevinSessionUsageReader::new(Some(cache));
    assert!(r5.entries(&db).is_err());
}

#[test]
fn large_session_database_folds_across_row_chunks_without_losing_or_duplicating_usage() {
    const ROWS: usize = 10_000;
    const DUPLICATES: usize = 10;
    const LATEST_DUPLICATE_INPUT: i64 = 7;

    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("sessions.db");
    let cache = dir.path().join("cache");
    create_sessions_db(&db, &[]);
    let ts = "2026-06-10T10:00:00.000Z";
    {
        let conn = Connection::open(&db).unwrap();
        let transaction = conn.unchecked_transaction().unwrap();
        for index in 0..ROWS {
            // Every tenth row shares one request id, so the winner spans many chunk boundaries.
            let duplicate = index % (ROWS / DUPLICATES) == 0;
            let request = if duplicate {
                "shared-request".to_string()
            } else {
                format!("request-{index}")
            };
            let input = if duplicate && index + (ROWS / DUPLICATES) >= ROWS {
                LATEST_DUPLICATE_INPUT
            } else {
                1
            };
            let message = assistant_msg(
                Some(&request),
                ts,
                "swe-2-max",
                json!({ "input_tokens": input }),
            );
            transaction
                .execute(
                    "INSERT INTO message_nodes (session_id, created_at, chat_message) VALUES (?1, ?2, ?3)",
                    params![
                        "large-session",
                        1_781_000_000i64,
                        serde_json::to_string(&message).unwrap()
                    ],
                )
                .unwrap();
        }
        transaction.commit().unwrap();
    }

    let mut reader = DevinSessionUsageReader::new(Some(cache.clone()));
    let entries = reader.entries(&db).unwrap();
    assert_eq!(reader.last_fold_kind, Some(FoldKind::Full));
    let expected_unique_rows = ROWS - DUPLICATES + 1;
    assert_eq!(entries.len(), expected_unique_rows);
    let expected_tokens = ((ROWS - DUPLICATES) as i64 * 1) + LATEST_DUPLICATE_INPUT;
    assert_eq!(
        entries
            .iter()
            .map(|entry| entry.tokens.total_tokens())
            .sum::<i64>(),
        expected_tokens
    );

    // The persisted record must make the next reader verify instead of refolding.
    let mut warm = DevinSessionUsageReader::new(Some(cache));
    let served = warm.entries(&db).unwrap();
    assert!(warm.adopted_disk_record);
    assert_eq!(warm.last_fold_kind, Some(FoldKind::Verified));
    assert_eq!(served, entries);
}

#[test]
fn transcript_parser_and_neon_routing_and_db_precedence() {
    let ts = "2026-06-10T10:00:00.000Z";
    let t_json = serde_json::to_vec(&json!({
        "schema_version": "ATIF-v1.7",
        "agent": { "model_name": "SWE-2 Max" },
        "steps": [
            { "source": "user", "timestamp": ts },
            { "source": "agent", "timestamp": ts, "model_name": "swe-2-max", "metrics": { "prompt_tokens": 15836, "completion_tokens": 1813, "cached_tokens": 11776 } }
        ],
        "final_metrics": { "total_prompt_tokens": 99999 }
    })).unwrap();
    let parsed = parse_bytes(&t_json).unwrap();
    assert_eq!(parsed.len(), 1);
    assert_eq!(parsed[0].tokens.input, 4060);
    assert_eq!(parsed[0].tokens.cache_read, 11776);
    assert_eq!(parsed[0].tokens.output, 1813);

    // cached > prompt damages whole file
    let bad = serde_json::to_vec(&json!({ "steps": [{ "timestamp": ts, "metrics": { "prompt_tokens": 100, "cached_tokens": 200 } }] })).unwrap();
    assert!(parse_bytes(&bad).is_none());

    // Foreign JSON fails closed
    assert!(parse_bytes(br#"{"theme":"dark"}"#).is_none());

    // gemini-4-neon-xhigh uses exact OpenRouter route google/gemini-4-neon
    let mut openrouter_entries = std::collections::HashMap::new();
    openrouter_entries.insert(
        "google/gemini-4-neon".to_string(),
        ModelRates::new(3.0, 15.0, 3.0, 0.15),
    );
    let pricing = ModelPricing::new(
        PricingSupplement::default(),
        PricingCatalog::default(),
        PricingCatalog::default(),
        PricingCatalog::from_entries(openrouter_entries),
        None,
    );
    let now = time::parse_iso8601("2026-11-21T12:00:00Z").unwrap();
    let neon = DevinSessionEntry {
        timestamp: now,
        model: "gemini-4-neon-xhigh".into(),
        tokens: TokenBreakdown {
            input: 1_000_000,
            cache_read: 1_000_000,
            output: 1_000_000,
            ..Default::default()
        },
    };
    let scan = aggregate(&[neon], 0.0, &pricing);
    let day = &scan.series.daily[0];
    assert!((scan.api_estimate_by_day.unwrap()[&day.date] - 18.15).abs() < 1e-6);
    assert_eq!(day.total_tokens, 3_000_000);
    assert!(day.reported_cost.is_none());

    // Database beats transcripts export without adding them together
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("sessions.db");
    let tr = dir.path().join("transcripts");
    std::fs::create_dir_all(&tr).unwrap();
    std::fs::write(tr.join("exported.json"), &t_json).unwrap();
    create_sessions_db(
        &db,
        &[(
            "s1",
            "a",
            assistant_msg(
                Some("r1"),
                ts,
                "swe-2-max",
                json!({"input_tokens": 10, "output_tokens": 5}),
            ),
        )],
    );
    let scanner = DevinTranscriptUsageScanner::new(tr, Some(db), Some(dir.path().join("c")));
    let now_june = time::parse_iso8601("2026-06-18T12:00:00Z").unwrap();
    let res = scanner
        .scan(
            30,
            now_june,
            &|| Arc::new(ModelPricing::default()),
            &CancelToken::new(),
        )
        .unwrap();
    assert_eq!(res.series.daily[0].total_tokens, 15);
}
