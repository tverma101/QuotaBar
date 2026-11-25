//! OpenCode's local SQLite data plane.
//!
//! Port of the SQLite work in `OpenCodeUsageScanner` in
//! `Sources/QuotaBar/Providers/OpenCode/OpenCodeUsageScanner.swift`. The Swift scanner remains the
//! reference oracle. Every read that used to spawn `/usr/bin/sqlite3` now runs in process:
//!
//! - `opencode.scan` — schema probe, usage query, and monthly-cycle anchor for each message DB.
//! - `opencode.query` — one read-only value query (the Hermes gateway ledger).
//! - `opencode.probe` — schema probe plus an existence query in one round trip, retained as the
//!   direct envelope operation; the paced hosted-usage refresh uses the staged schema/query calls.
//!
//! The SQL itself is still built by Swift and travels in the request. OpenCode's layout-dependent
//! statements are large and already pinned by the Swift `OpenCodeDatabaseSQL` suite; sending them
//! keeps a single source of truth instead of a second builder that could drift. This matches how
//! alias rules stay in Swift for the pricing resolver: the hot work moves, the rules stay put.
//!
//! One memo owns the per-database cache for every operation, keyed by the file revision
//! (`path|dev:ino:size:mtime:ctime|wal-stamp`). The schema probe and the full-history anchor live in
//! the same entry, so a v1→v2 migration invalidates both together and the two engines cannot
//! disagree about which answer is current.
//!
//! Calendar policy stays at the Swift edge. Rows carry raw epoch milliseconds; Swift owns the
//! `Calendar.current` day keys and every aggregate/fold downstream.

use std::collections::HashMap;
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::sync::{Mutex, OnceLock};

use rusqlite::Connection;
use serde_json::{json, Map, Value};

#[cfg(test)]
pub(crate) use super::sqlite::QUERY_BOUND_INSTALLS;
use super::sqlite::{
    query_text, query_with_retry_result, read_cell, with_query_bound, AttemptError, CellValue,
};
use super::{invalid_param, BackendError};

/// One database to read, with the statement variants Swift generated for it.
struct DatabaseRequest {
    path: String,
    detection_sql: String,
    data_sql: HashMap<String, String>,
    anchor_sql: HashMap<String, String>,
}

/// `opencode.scan` — read every requested database and return its raw usage payload plus per-path
/// failures.
pub fn scan(params: &Value) -> Result<Value, BackendError> {
    let databases = database_requests(params)?;
    let mut results: Vec<Value> = Vec::with_capacity(databases.len());
    for database in databases {
        results.push(scan_database(&database));
    }
    Ok(json!({ "databases": results }))
}

/// `opencode.schema` — detect the layout from the shared memo, or run the detection statement
/// when the revision is cold. This is the first stage of the staged refresh; splitting it from the
/// data and anchor statements lets Swift pace each statement exactly like the CLI path.
pub fn schema(params: &Value) -> Result<Value, BackendError> {
    let path = required_string(params, "path")?;
    let detection_sql = required_string(params, "detectionSQL")?;
    if !Path::new(&path).exists() {
        return Ok(json!({ "schema": "unknown", "error": null }));
    }
    let stamp = revision_stamp(&path);
    match query_with_retry_result(&path, |connection| {
        detect_schema(connection, &path, &detection_sql, stamp.as_deref())
    }) {
        Ok(schema) => Ok(json!({ "schema": schema, "error": null })),
        Err(error) => Ok(json!({ "schema": "unknown", "error": error.message() })),
    }
}

/// `opencode.anchor` — read or reuse the monthly-cycle anchor for one detected layout. A failure
/// is reported to Swift as `anchorFailure`; the caller keeps the rows and falls back to the
/// calendar month, matching the CLI oracle.
pub fn anchor(params: &Value) -> Result<Value, BackendError> {
    let path = required_string(params, "path")?;
    let schema = required_string(params, "schema")?;
    let sql = required_string(params, "sql")?;
    if !Path::new(&path).exists() {
        return Ok(json!({ "anchorMs": null, "error": null }));
    }
    let effective = match schema.as_str() {
        "v2" => "v2",
        "mixed" => "mixed",
        _ => "legacy",
    };
    let stamp = revision_stamp(&path);
    if let Some(stamp) = stamp.as_deref() {
        if let Some(entry) = memo_lookup_at(&path, stamp) {
            if entry.schema == effective && entry.anchor_known {
                return Ok(json!({ "anchorMs": entry.anchor, "error": null }));
            }
        }
    }

    match query_with_retry_result(&path, |connection| {
        query_anchor(connection, &sql).map_err(AttemptError::Sql)
    }) {
        Ok(anchor) => {
            if let Some(stamp) = stamp.as_deref() {
                memo_store_anchor(&path, stamp, anchor);
            }
            Ok(json!({ "anchorMs": anchor, "error": null }))
        }
        Err(error) => Ok(json!({ "anchorMs": null, "error": error.message() })),
    }
}

/// `opencode.query` — one value query with `SQLiteCLIAccessor.queryValue` semantics. OpenCode keeps
/// the read-write retry for a contended WAL writer.
pub fn query(params: &Value) -> Result<Value, BackendError> {
    super::sqlite::query_with_default_retry(params, true)
}

/// `opencode.probe` — detect the layout (from the shared memo when fresh) and run the matching
/// existence query.
pub fn probe(params: &Value) -> Result<Value, BackendError> {
    let path = required_string(params, "path")?;
    let detection_sql = required_string(params, "detectionSQL")?;
    let sql = sql_variants(params, "sql")?;
    if !Path::new(&path).exists() {
        return Ok(json!({ "schema": "unknown", "value": null, "error": null }));
    }

    // Same connection policy as `opencode.query`: read-only first, then one read-write retry for
    // a contended database. A busy-timeout failure during detection is retried too, which the
    // previous hand-rolled open loop skipped.
    let stamp = revision_stamp(&path);
    let outcome = query_with_retry_result(&path, |connection| {
        let schema = detect_schema(connection, &path, &detection_sql, stamp.as_deref())?;
        let effective = effective_schema(schema);
        let sql = sql
            .get(effective)
            .ok_or_else(|| AttemptError::Data(format!("missing `sql.{effective}` statement")))?;
        Ok((schema, query_text(connection, sql)?))
    });
    match outcome {
        Ok((schema, value)) => Ok(json!({ "schema": schema, "value": value, "error": null })),
        Err(error) => Ok(json!({
            "schema": "unknown",
            "value": null,
            "error": error.message(),
        })),
    }
}

fn database_requests(params: &Value) -> Result<Vec<DatabaseRequest>, BackendError> {
    let databases = params
        .get("databases")
        .and_then(Value::as_array)
        .ok_or_else(|| invalid_param("missing `databases` array".to_string()))?;
    let mut requests = Vec::with_capacity(databases.len());
    for database in databases {
        let path = required_string(database, "path")?;
        let detection_sql = required_string(database, "detectionSQL")?;
        requests.push(DatabaseRequest {
            path,
            detection_sql,
            data_sql: sql_variants(database, "dataSQL")?,
            anchor_sql: sql_variants(database, "anchorSQL")?,
        });
    }
    Ok(requests)
}

fn required_string(value: &Value, key: &str) -> Result<String, BackendError> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| invalid_param(format!("missing string parameter `{key}`")))
}

fn sql_variants(value: &Value, key: &str) -> Result<HashMap<String, String>, BackendError> {
    let object = value
        .get(key)
        .and_then(Value::as_object)
        .ok_or_else(|| invalid_param(format!("missing `{key}` object")))?;
    let mut variants = HashMap::with_capacity(object.len());
    for (name, sql) in object {
        let sql = sql
            .as_str()
            .ok_or_else(|| invalid_param(format!("`{key}.{name}` must be a string")))?;
        variants.insert(name.clone(), sql.to_string());
    }
    for required in ["legacy", "v2", "mixed"] {
        if !variants.contains_key(required) {
            return Err(invalid_param(format!("missing `{key}.{required}`")));
        }
    }
    Ok(variants)
}

fn scan_database(database: &DatabaseRequest) -> Value {
    let mut result = Map::new();
    result.insert("path".into(), json!(database.path));

    // A missing file is a no-result read, not a spawn error: `SQLiteCLIAccessor.queryValue`
    // checks existence first so sqlite3 never gets a chance to create the database.
    if !Path::new(&database.path).exists() {
        result.insert("schema".into(), json!("unknown"));
        result.insert("usageJSON".into(), Value::Null);
        result.insert("failure".into(), json!("usage query returned no result"));
        return Value::Object(result);
    }

    let read = query_with_retry_result(&database.path, |connection| {
        read_database(database, connection)
    });
    match read {
        Ok((schema, usage_json, anchor_ms, anchor_failure)) => {
            result.insert("schema".into(), json!(schema));
            result.insert("usageJSON".into(), json!(usage_json));
            if let Some(anchor_ms) = anchor_ms {
                result.insert("anchorMs".into(), json!(anchor_ms));
            }
            if let Some(message) = anchor_failure {
                result.insert("anchorFailure".into(), json!(message));
            }
        }
        Err(error) => {
            result.insert("schema".into(), json!("unknown"));
            result.insert("usageJSON".into(), Value::Null);
            result.insert("failure".into(), json!(error.message()));
        }
    }
    Value::Object(result)
}

type DatabaseRead = (String, String, Option<f64>, Option<String>);

fn read_database(
    database: &DatabaseRequest,
    connection: &Connection,
) -> Result<DatabaseRead, AttemptError> {
    // Capture the revision before reading. If the database changes while the statements run, the
    // answer is stored under the old stamp and the next lookup misses instead of trusting it.
    let stamp = revision_stamp(&database.path);
    let cached = stamp
        .as_deref()
        .and_then(|stamp| memo_lookup_at(&database.path, stamp));

    // The shared memo is keyed by revision, so an idle database costs no probe and a migration
    // (which rewrites the file) invalidates the answer. An inconclusive probe is `unknown`, which
    // the effective layout maps to the legacy statement.
    let schema = detect_schema(
        connection,
        &database.path,
        &database.detection_sql,
        stamp.as_deref(),
    )?;
    let effective = effective_schema(schema);

    let data_sql = database
        .data_sql
        .get(effective)
        .ok_or_else(|| AttemptError::Data(format!("missing `dataSQL.{effective}` statement")))?;
    let usage_json = query_text(connection, data_sql)?
        .ok_or_else(|| AttemptError::Sql("usage query returned no result".to_string()))?;

    // The monthly-cycle anchor is a full-history MIN() that only changes when the database
    // changes, so it shares the schema's memo entry. Failures stay best-effort, exactly like the
    // Swift scanner: the window falls back to the calendar month and the scan still completes.
    if let Some(entry) = cached
        .as_ref()
        .filter(|entry| entry.anchor_known && entry.schema == schema)
    {
        return Ok((schema.to_string(), usage_json, entry.anchor, None));
    }

    let mut anchor_failure = None;
    let anchor_ms = match database.anchor_sql.get(effective) {
        Some(anchor_sql) => match query_anchor(connection, anchor_sql) {
            Ok(anchor) => {
                if let Some(stamp) = stamp.as_deref() {
                    memo_store_anchor(&database.path, stamp, anchor);
                }
                anchor
            }
            Err(error) => {
                anchor_failure = Some(error);
                None
            }
        },
        None => {
            anchor_failure = Some(format!("missing `anchorSQL.{effective}` statement"));
            None
        }
    };

    Ok((schema.to_string(), usage_json, anchor_ms, anchor_failure))
}

/// The layout probe shared by the message scan and the hosted-usage probe. The memo is consulted
/// first; only a cache miss runs the detection statement.
fn detect_schema(
    connection: &Connection,
    path: &str,
    detection_sql: &str,
    stamp: Option<&str>,
) -> Result<&'static str, AttemptError> {
    if let Some(stamp) = stamp {
        if let Some(entry) = memo_lookup_at(path, stamp) {
            return Ok(entry.schema);
        }
    }
    let probed = match query_text(connection, detection_sql)? {
        Some(output) => schema_from_probe(&output),
        None => "unknown",
    };
    if probed != "unknown" {
        if let Some(stamp) = stamp {
            memo_store_schema(path, stamp, probed);
        }
    }
    Ok(probed)
}

fn effective_schema(schema: &'static str) -> &'static str {
    if schema == "unknown" {
        "legacy"
    } else {
        schema
    }
}

fn schema_from_probe(output: &str) -> &'static str {
    let names: Vec<&str> = output
        .split(',')
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .collect();
    let has_legacy = names.contains(&"message");
    let has_v2 = names.contains(&"session_message");
    match (has_legacy, has_v2) {
        (true, true) => "mixed",
        (true, false) => "legacy",
        (false, true) => "v2",
        (false, false) => "unknown",
    }
}

fn query_anchor(connection: &Connection, sql: &str) -> Result<Option<f64>, String> {
    with_query_bound(connection, || {
        match connection.query_row(sql, [], read_cell) {
            Ok(value) => Ok(match value {
                CellValue::Null => None,
                CellValue::Integer(number) => Some(number as f64),
                CellValue::Real(number) => Some(number),
                CellValue::Text(text) => text
                    .trim()
                    .parse::<f64>()
                    .ok()
                    .filter(|value| value.is_finite()),
            }),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(error) => Err(AttemptError::Sql(error.to_string())),
        }
    })
    .map_err(AttemptError::message)
}

// ---------------------------------------------------------------------------
// Per-database memo (schema + anchor, one key)
// ---------------------------------------------------------------------------

#[derive(Clone)]
struct MemoEntry {
    /// The revision this answer was computed from. A write or migration moves it, so the entry is
    /// replaced instead of trusted.
    stamp: String,
    schema: &'static str,
    anchor: Option<f64>,
    anchor_known: bool,
}

/// `dev:ino:size:mtime:ctime|wal-stamp`. Both the main file and its `-wal` companion move on a
/// write, including a v1→v2 migration, so one revision invalidates schema and anchor together.
fn revision_stamp(path: &str) -> Option<String> {
    fn stamp(path: &str, missing_allowed: bool) -> Option<String> {
        match std::fs::symlink_metadata(path) {
            Ok(metadata) => Some(format!(
                "{}:{}:{}:{}.{:09}:{}.{:09}",
                metadata.dev(),
                metadata.ino(),
                metadata.len(),
                metadata.mtime(),
                metadata.mtime_nsec(),
                metadata.ctime(),
                metadata.ctime_nsec()
            )),
            Err(error) if missing_allowed && error.kind() == std::io::ErrorKind::NotFound => {
                Some("missing".to_string())
            }
            Err(_) => None,
        }
    }
    Some(format!(
        "{}|{}",
        stamp(path, false)?,
        stamp(&format!("{path}-wal"), true)?
    ))
}

/// One entry per database path (not per revision), so a long-lived app does not accumulate an
/// entry for every write. The entry carries the revision it was computed at.
fn memo() -> &'static Mutex<HashMap<String, MemoEntry>> {
    static MEMO: OnceLock<Mutex<HashMap<String, MemoEntry>>> = OnceLock::new();
    MEMO.get_or_init(|| Mutex::new(HashMap::new()))
}

fn memo_lookup_at(path: &str, stamp: &str) -> Option<MemoEntry> {
    let memo = memo().lock().unwrap_or_else(|error| error.into_inner());
    memo.get(path).filter(|entry| entry.stamp == stamp).cloned()
}

fn memo_store_schema(path: &str, stamp: &str, schema: &'static str) {
    let mut memo = memo().lock().unwrap_or_else(|error| error.into_inner());
    memo.insert(
        path.to_string(),
        MemoEntry {
            stamp: stamp.to_string(),
            schema,
            anchor: None,
            anchor_known: false,
        },
    );
}

fn memo_store_anchor(path: &str, stamp: &str, anchor: Option<f64>) {
    let mut memo = memo().lock().unwrap_or_else(|error| error.into_inner());
    if let Some(entry) = memo.get_mut(path) {
        if entry.stamp == stamp {
            entry.anchor = anchor;
            entry.anchor_known = true;
        }
    }
}

#[cfg(test)]
mod tests;
