//! Provider-neutral SQLite value reads for providers whose SQL is built in Swift.
//!
//! Every local-usage provider (OpenCode, Antigravity, Freebuff Desktop, Hermes) sends its own
//! statements; this module owns the parts that must behave identically for all of them:
//!
//! - one in-process connection per statement, opened read-only and retried read-write only when
//!   the caller opts in (a SELECT cannot mutate the database);
//! - one wall-clock bound **per statement**, installed and removed around that statement alone, so
//!   a slow statement cannot consume a sibling's budget;
//! - `SQLiteCLIAccessor.queryValue` rendering: an empty cell is `None`, INTEGER is exact, TEXT is
//!   trimmed, and ordinary REALs match `sqlite3` (scientific REALs do not — see [`format_real`]).
//!
//! Schema knowledge, memoization, calendar bucketing, and decoding stay with the providers. Only
//! OpenCode currently memoizes anything in Rust; the Freebuff Desktop and Antigravity revisions
//! are cached in Swift, and this module stays stateless for them.

use std::time::{Duration, Instant};

use rusqlite::types::ValueRef;
use rusqlite::{Connection, OpenFlags};
use serde_json::{json, Value};

use super::{invalid_param, BackendError};

/// A failed read attempt. `Sql` may be retried without the read-only flag (matching
/// `SQLiteCLIAccessor.queryValue`); `Data` is decisive and must not be retried.
#[derive(Debug)]
pub(crate) enum AttemptError {
    Sql(String),
    Data(String),
}

impl AttemptError {
    pub(crate) fn message(self) -> String {
        match self {
            AttemptError::Sql(message) | AttemptError::Data(message) => message,
        }
    }
}

/// `sqlite.query` — one value query with `SQLiteCLIAccessor.queryValue` semantics. The SQL travels
/// in the request, so each provider keeps a single source of truth for its statements.
///
/// `readWriteFallback` defaults to `false`: a caller must opt in to the SELECT-only read-write
/// retry that `SQLiteCLIAccessor` performs for a WAL-mode database under an active writer.
pub fn query(params: &Value) -> Result<Value, BackendError> {
    query_with_default_retry(params, false)
}

/// The op body shared with the providers that keep their own operation name. `default_retry` is
/// the policy for a request that does not name `readWriteFallback`.
pub(crate) fn query_with_default_retry(
    params: &Value,
    default_retry: bool,
) -> Result<Value, BackendError> {
    let path = required_string(params, "path")?;
    let sql = required_string(params, "sql")?;
    let read_write_fallback = params
        .get("readWriteFallback")
        .and_then(Value::as_bool)
        .unwrap_or(default_retry);
    match query_value(&path, &sql, read_write_fallback) {
        Ok(value) => Ok(json!({ "value": value, "error": null })),
        Err(error) => Ok(json!({ "value": null, "error": error })),
    }
}

/// One value query. A missing file returns `Ok(None)` before a connection is opened, exactly like
/// `SQLiteCLIAccessor.queryValue`'s existence guard, so a read never creates a database.
pub(crate) fn query_value(
    path: &str,
    sql: &str,
    read_write_fallback: bool,
) -> Result<Option<String>, String> {
    if !std::path::Path::new(path).exists() {
        return Ok(None);
    }
    let result = if read_write_fallback {
        query_with_retry(path, sql)
    } else {
        with_connection(path, OpenFlags::SQLITE_OPEN_READ_ONLY, |connection| {
            query_text(connection, sql)
        })
    };
    result.map_err(AttemptError::message)
}

/// Run one read-only query, retrying read-write when a WAL writer refuses the shared lock.
pub(crate) fn query_with_retry(path: &str, sql: &str) -> Result<Option<String>, AttemptError> {
    query_with_retry_result(path, |connection| query_text(connection, sql))
}

pub(crate) fn query_with_retry_result<T>(
    path: &str,
    read: impl Fn(&Connection) -> Result<T, AttemptError>,
) -> Result<T, AttemptError> {
    let first = with_connection(path, OpenFlags::SQLITE_OPEN_READ_ONLY, &read);
    match first {
        Ok(value) => Ok(value),
        Err(AttemptError::Data(message)) => Err(AttemptError::Data(message)),
        Err(AttemptError::Sql(read_only_message)) => {
            match with_connection(path, OpenFlags::SQLITE_OPEN_READ_WRITE, &read) {
                Ok(value) => Ok(value),
                Err(error) => {
                    let message = error.message();
                    Err(AttemptError::Sql(if message.is_empty() {
                        read_only_message
                    } else {
                        message
                    }))
                }
            }
        }
    }
}

pub(crate) fn with_connection<T>(
    path: &str,
    flags: OpenFlags,
    read: impl Fn(&Connection) -> Result<T, AttemptError>,
) -> Result<T, AttemptError> {
    let connection = Connection::open_with_flags(path, flags)
        .map_err(|error| AttemptError::Sql(error.to_string()))?;
    connection
        .busy_timeout(Duration::from_millis(1_000))
        .map_err(|error| AttemptError::Sql(error.to_string()))?;
    // `/usr/bin/sqlite3` loads the shell's sha3 extension; the bundled library has no such
    // extension, so every connection registers the same functions. SQL text therefore stays
    // single-sourced in Swift for queries that hash inside SQLite (Antigravity's fingerprints).
    super::sqlite_sha3::register(&connection)
        .map_err(|error| AttemptError::Sql(error.to_string()))?;
    read(&connection)
}

/// Bound one SQLite statement, matching the CLI path's five-second subprocess bound. The deadline
/// is installed and removed around each statement so a caller's stages are independent: a slow
/// statement cannot consume its siblings' budget.
pub(crate) fn with_query_bound<T>(
    connection: &Connection,
    read: impl FnOnce() -> Result<T, AttemptError>,
) -> Result<T, AttemptError> {
    #[cfg(test)]
    QUERY_BOUND_INSTALLS.with(|count| count.set(count.get() + 1));
    let deadline = Instant::now() + query_bound();
    connection.progress_handler(1_000, Some(move || Instant::now() >= deadline));
    let result = read();
    connection.progress_handler(0, None::<fn() -> bool>);
    result
}

fn query_bound() -> Duration {
    Duration::from_secs(5)
}

#[cfg(test)]
thread_local! {
    /// Tests count statement bounds directly, independent of wall-clock scheduling.
    pub(crate) static QUERY_BOUND_INSTALLS: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

/// One cell read from SQLite. `query_text` mirrors `SQLiteCLIAccessor.queryValue` for the
/// INTEGER/TEXT values current provider statements select: an empty cell or whitespace-only text
/// is `None`, INTEGER rendering is exact, and TEXT is trimmed. REAL rendering matches sqlite3 for
/// ordinary values such as `2.0`, but not for scientific values such as `1e300`; no current
/// provider query selects a REAL that reaches this boundary. See [`format_real`].
pub(crate) enum CellValue {
    Null,
    Integer(i64),
    Real(f64),
    Text(String),
}

pub(crate) fn read_cell(row: &rusqlite::Row<'_>) -> rusqlite::Result<CellValue> {
    Ok(match row.get_ref(0)? {
        ValueRef::Null => CellValue::Null,
        ValueRef::Integer(number) => CellValue::Integer(number),
        ValueRef::Real(number) => CellValue::Real(number),
        ValueRef::Text(bytes) => CellValue::Text(String::from_utf8_lossy(bytes).into_owned()),
        ValueRef::Blob(_) => CellValue::Null,
    })
}

pub(crate) fn query_text(
    connection: &Connection,
    sql: &str,
) -> Result<Option<String>, AttemptError> {
    with_query_bound(connection, || {
        match connection.query_row(sql, [], read_cell) {
            Ok(value) => {
                let text = match value {
                    CellValue::Null => return Ok(None),
                    CellValue::Integer(number) => number.to_string(),
                    CellValue::Real(number) => format_real(number),
                    CellValue::Text(text) => text,
                };
                let trimmed = text.trim();
                Ok((!trimmed.is_empty()).then(|| trimmed.to_string()))
            }
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(error) => Err(AttemptError::Sql(error.to_string())),
        }
    })
}

pub(crate) fn format_real(number: f64) -> String {
    // Rust's Display is shortest-round-trip for ordinary reals and matches sqlite3 for values like
    // 2.0, but it uses a full decimal expansion where sqlite3 switches to scientific notation
    // (1e300 is `1.0e+300` in sqlite3, not a 300-digit integer plus `.0`). No current provider
    // statement selects a REAL; a future one needs a CLI-parity formatter before relying on this.
    let mut text = format!("{number}");
    let has_marker = text.contains('.')
        || text.contains('e')
        || text.contains('E')
        || text.contains('n')
        || text.contains('N');
    if !has_marker {
        text.push_str(".0");
    }
    text
}

fn required_string(value: &Value, key: &str) -> Result<String, BackendError> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| invalid_param(format!("missing string parameter `{key}`")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    fn fixture_path() -> String {
        static SEQUENCE: AtomicU64 = AtomicU64::new(0);
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or(Duration::ZERO)
            .as_nanos();
        let sequence = SEQUENCE.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir()
            .join(format!(
                "quotabar-sqlite-primitive-{}-{nonce}-{sequence}.db",
                std::process::id()
            ))
            .to_string_lossy()
            .into_owned()
    }

    fn seeded(sql: &str) -> String {
        let path = fixture_path();
        let connection = rusqlite::Connection::open(&path).expect("open fixture");
        connection.execute_batch(sql).expect("seed fixture");
        drop(connection);
        path
    }

    fn call(path: &str, sql: &str) -> Value {
        query(&json!({ "path": path, "sql": sql })).expect("query")
    }

    #[test]
    fn missing_file_is_a_null_read_and_never_creates_the_database() {
        let path = fixture_path();
        let value = call(&path, "SELECT 1;");
        assert!(value["value"].is_null());
        assert!(value["error"].is_null());
        assert!(!std::path::Path::new(&path).exists());
    }

    /// A `json_group_array` over an empty result is a real payload (`"[]"`), not a missing read.
    /// Freebuff Desktop's scanner treats a nil payload as an unreadable database, so this shape
    /// has to survive the primitive exactly as `sqlite3` prints it.
    #[test]
    fn empty_json_aggregate_is_a_value() {
        let path = seeded("CREATE TABLE messages(role TEXT);");
        assert_eq!(
            call(
                &path,
                "SELECT COALESCE(json_group_array(json_object('role', role)), '[]') FROM messages;"
            )["value"],
            "[]"
        );
        let _ = std::fs::remove_file(path);
    }

    /// Freebuff Desktop's projection COALESCEs every column so one NULL cell cannot take the whole
    /// array down. Pin the JSON rendering of NULL, an empty blob, an empty string, and bounded
    /// integers, which is the shape the scanner then decodes.
    #[test]
    fn json_projection_keeps_null_and_empty_cells_distinguishable() {
        let path = seeded(
            "CREATE TABLE rows(id TEXT, ts INTEGER, metrics TEXT, blob BLOB);\n             INSERT INTO rows VALUES ('a', 1793440800000, NULL, NULL);\n             INSERT INTO rows VALUES ('b', 0, '', x'');\n             INSERT INTO rows VALUES (NULL, -1, '{}', x'00');",
        );
        let value = call(
            &path,
            "SELECT COALESCE(json_group_array(json_object(\n               'id', COALESCE(id, ''),\n               'ts', COALESCE(CAST(ts AS TEXT), ''),\n               'metrics', COALESCE(NULLIF(metrics, ''), '{}')\n             )), '[]') FROM rows;",
        );
        assert_eq!(
            value["value"],
            json!(
                r#"[{"id":"a","ts":"1793440800000","metrics":"{}"},{"id":"b","ts":"0","metrics":"{}"},{"id":"","ts":"-1","metrics":"{}"}]"#
            )
        );
        assert!(value["error"].is_null());
        let _ = std::fs::remove_file(path);
    }

    /// Epoch-millisecond stamps and 64-bit counters must arrive as exact decimal text. Anything
    /// that round-trips through `f64` would silently move a future-dated row or a large total.
    #[test]
    fn large_integers_render_without_precision_loss() {
        let path = seeded("CREATE TABLE t(v);");
        assert_eq!(
            call(&path, "SELECT 9007199254740993;")["value"],
            "9007199254740993"
        );
        assert_eq!(
            call(&path, "SELECT 9223372036854775807;")["value"],
            "9223372036854775807"
        );
        assert_eq!(call(&path, "SELECT -1;")["value"], "-1");
        assert_eq!(call(&path, "SELECT 4102444800;")["value"], "4102444800");
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn empty_cells_are_null_and_text_is_trimmed() {
        let path = seeded("CREATE TABLE t(v);");
        for sql in [
            "SELECT '';",
            "SELECT NULL;",
            "SELECT char(9, 10, 13, 32);",
            "SELECT 1 WHERE 0;",
        ] {
            let value = call(&path, sql);
            assert!(value["value"].is_null(), "{sql} should be null");
            assert!(value["error"].is_null(), "{sql} should not fail");
        }
        assert_eq!(call(&path, "SELECT '  x  ';")["value"], "x");
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn sql_failures_are_reported_in_the_response_not_the_envelope() {
        let path = seeded("CREATE TABLE t(v);");
        let value = call(&path, "SELECT * FROM missing_table;");
        assert!(value["value"].is_null());
        assert!(value["error"]
            .as_str()
            .expect("error string")
            .contains("no such table"));
        let _ = std::fs::remove_file(path);
    }

    /// The generation query selects `hex(data)`, `length(data)`, and NULL for an oversized blob.
    /// Those columns are the only rows Antigravity's scanner can legitimately see, so pin their
    /// exact JSON shape: the uppercase hex sqlite prints, an empty blob as `""` rather than null, a
    /// NULL `data` row excluded, and an oversized blob's `hex` as null while its byte count
    /// survives.
    #[test]
    fn antigravity_generation_payload_keeps_exact_hex_and_null_columns() {
        let path = seeded(
            "CREATE TABLE gen_metadata(idx INTEGER PRIMARY KEY, data BLOB);\n             INSERT INTO gen_metadata VALUES (0, x'00ff7f');\n             INSERT INTO gen_metadata VALUES (1, x'');\n             INSERT INTO gen_metadata VALUES (2, NULL);\n             INSERT INTO gen_metadata VALUES (3, zeroblob(1048577));",
        );
        let sql = "SELECT json_group_array(json_object('index', idx, 'bytes', length(data), \
             'hex', CASE WHEN length(data) <= 1048576 THEN hex(data) ELSE NULL END, \
             'step_hex', NULL)) \
             FROM gen_metadata WHERE data IS NOT NULL ORDER BY idx";

        assert_eq!(
            call(&path, sql)["value"],
            json!(
                "[{\"index\":0,\"bytes\":3,\"hex\":\"00FF7F\",\"step_hex\":null},\
                 {\"index\":1,\"bytes\":0,\"hex\":\"\",\"step_hex\":null},\
                 {\"index\":3,\"bytes\":1048577,\"hex\":null,\"step_hex\":null}]"
                    .replace('\n', "")
                    .replace("                 ", "")
            )
        );
        let _ = std::fs::remove_file(path);
    }

    /// Ordinary REALs match `sqlite3` (`2.0`), which is the only REAL any provider statement can
    /// reach today; scientific values do not, and that limitation is documented on [`format_real`].
    #[test]
    fn integer_text_and_simple_real_values_match_sqlite_cli_rendering() {
        let path = seeded("CREATE TABLE t(v);");

        assert_eq!(call(&path, "SELECT 2.0;")["value"], "2.0");
        assert_eq!(call(&path, "SELECT 1;")["value"], "1");
        assert_eq!(call(&path, "SELECT '  x  ';")["value"], "x");
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn read_write_retry_is_opt_in() {
        let path = seeded("CREATE TABLE t(v); INSERT INTO t VALUES (1);");
        let read_only = query(&json!({ "path": path, "sql": "SELECT v FROM t;" })).expect("query");
        assert_eq!(read_only["value"], "1");
        let with_retry = query(&json!({
            "path": path,
            "sql": "SELECT v FROM t;",
            "readWriteFallback": true
        }))
        .expect("query");
        assert_eq!(with_retry["value"], "1");
        let _ = std::fs::remove_file(path);
    }
}
