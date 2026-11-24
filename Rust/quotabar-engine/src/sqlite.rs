//! Native, in-process, read-only SQLite access to other apps' databases.
//!
//! Replaces the Swift backend's `/usr/bin/sqlite3` subprocess per query. Two techniques adapted from
//! rsusage (MIT, © 2026 Coobyk, <https://github.com/coobyk/rsusage>, `src/agents/sqlite.rs`):
//!
//! - open read-only without SQLite's internal mutex (each connection is used by one thread), and
//! - a cheap *source signature* over the database and its `-wal` / `-journal` siblings, so callers can
//!   skip an unchanged database entirely instead of querying it on every refresh.

use rusqlite::{Connection, ErrorCode, OpenFlags};
use std::fmt::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

#[derive(Debug)]
pub enum SqliteError {
    /// The database exists but could not be opened or queried (locked, corrupt, permission denied).
    Unreadable(String),
}

impl std::fmt::Display for SqliteError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SqliteError::Unreadable(message) => f.write_str(message),
        }
    }
}

impl std::error::Error for SqliteError {}

impl From<rusqlite::Error> for SqliteError {
    fn from(error: rusqlite::Error) -> Self {
        SqliteError::Unreadable(error.to_string())
    }
}

/// Open `path` read-only. `Ok(None)` when the file does not exist (a truly absent source).
///
pub fn open_read_only(path: &Path) -> Result<Option<Connection>, SqliteError> {
    open_for_query(path, false, Instant::now() + QUERY_TIMEOUT)
}

const QUERY_TIMEOUT: Duration = Duration::from_secs(5);

fn open_for_query(path: &Path, allow_wal_retry: bool, deadline: Instant) -> Result<Option<Connection>, SqliteError> {
    match path.metadata() {
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(SqliteError::Unreadable(error.to_string())),
    }
    let open = |access| -> rusqlite::Result<Connection> {
        let conn = Connection::open_with_flags(path, access | OpenFlags::SQLITE_OPEN_NO_MUTEX)?;
        bound_query(&conn, deadline)?;
        conn.pragma_update(None, "query_only", true)?;
        // Touch the schema now so WAL open failures surface inside the retry boundary.
        conn.query_row("SELECT count(*) FROM sqlite_master", [], |_| Ok(()))?;
        Ok(conn)
    };
    match open(OpenFlags::SQLITE_OPEN_READ_ONLY) {
        Err(ref error)
            if allow_wal_retry
                && error.sqlite_error_code() == Some(ErrorCode::CannotOpen)
                && Instant::now() < deadline =>
        {
            // The read/write handle can initialize WAL shared memory. There is no CREATE flag and
            // query_only prevents writes through this handle.
            open(OpenFlags::SQLITE_OPEN_READ_WRITE).map(Some).map_err(Into::into)
        }
        result => result.map(Some).map_err(Into::into),
    }
}

fn bound_query(conn: &Connection, deadline: Instant) -> rusqlite::Result<()> {
    conn.busy_timeout(Duration::from_secs(1).min(deadline.saturating_duration_since(Instant::now())))?;
    conn.progress_handler(1000, Some(move || Instant::now() >= deadline));
    Ok(())
}

/// The SQLite shell's plain list output. Some legacy scanner queries consume multiple rows
/// separated by newlines, with pipes between columns and empty strings for SQL NULLs.
pub fn query_text(path: &Path, sql: &str, allow_wal_retry: bool) -> Result<Option<String>, SqliteError> {
    let Some(conn) = open_for_query(path, allow_wal_retry, Instant::now() + QUERY_TIMEOUT)? else { return Ok(None) };
    let mut statement = conn.prepare(sql)?;
    if !statement.readonly() {
        return Err(SqliteError::Unreadable("Expected a read-only SQLite query.".into()));
    }
    let columns = statement.column_count();
    let mut rows = statement.query([])?;
    let mut output = String::new();
    while let Some(row) = rows.next()? {
        for index in 0..columns {
            if index > 0 {
                output.push('|');
            }
            use rusqlite::types::ValueRef;
            match row.get_ref(index)? {
                ValueRef::Null => {}
                ValueRef::Text(value) | ValueRef::Blob(value) => output.push_str(&String::from_utf8_lossy(value)),
                ValueRef::Integer(value) => { let _ = write!(output, "{value}"); }
                ValueRef::Real(value) => { let _ = write!(output, "{value}"); }
            }
        }
        output.push('\n');
    }
    let trimmed = output.trim();
    Ok((!trimmed.is_empty()).then(|| trimmed.to_owned()))
}

/// Run an intentional write, such as persisting Cursor's rotated token. SQL stays inside the
/// process, and errors avoid returning SQL text that could contain a credential.
pub fn execute(path: &Path, sql: &str) -> Result<(), SqliteError> {
    let flags = OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_CREATE | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    (|| {
        let conn = Connection::open_with_flags(path, flags)?;
        bound_query(&conn, Instant::now() + QUERY_TIMEOUT)?;
        conn.execute_batch(sql)
    })()
    .map_err(|error| SqliteError::Unreadable(match error.sqlite_error_code() {
        Some(code) => format!("SQLite write failed ({code:?})."),
        None => "SQLite write failed.".into(),
    }))
}

/// First column of the first row as text. `Ok(None)` when the database or the row is absent.
pub fn query_value(path: &Path, sql: &str) -> Result<Option<String>, SqliteError> {
    let Some(conn) = open_read_only(path)? else { return Ok(None) };
    let mut statement = conn.prepare(sql)?;
    let mut rows = statement.query([])?;
    match rows.next()? {
        Some(row) => Ok(value_as_text(row.get_ref(0)?)),
        None => Ok(None),
    }
}

/// Like [`query_value`], but a missing table is an absent source rather than an error (an app that
/// was installed but never signed in has an empty database).
pub fn query_value_tolerating_missing_table(path: &Path, sql: &str) -> Result<Option<String>, SqliteError> {
    match query_value(path, sql) {
        Err(SqliteError::Unreadable(message)) if message.contains("no such table") => Ok(None),
        other => other,
    }
}

pub fn value_as_text(value: rusqlite::types::ValueRef<'_>) -> Option<String> {
    use rusqlite::types::ValueRef;
    match value {
        ValueRef::Null => None,
        ValueRef::Integer(i) => Some(i.to_string()),
        ValueRef::Real(f) => Some(f.to_string()),
        ValueRef::Text(t) | ValueRef::Blob(t) => Some(String::from_utf8_lossy(t).into_owned()),
    }
}

/// Size + modification time (ns) of one file, `None` when absent.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
pub struct FileStamp {
    pub len: u64,
    pub mtime_ns: i128,
}

pub fn file_stamp(path: &Path) -> Option<FileStamp> {
    let meta = std::fs::metadata(path).ok()?;
    let mtime_ns = meta
        .modified()
        .ok()
        .map(|t| match t.duration_since(std::time::UNIX_EPOCH) {
            Ok(d) => d.as_nanos() as i128,
            Err(e) => -(e.duration().as_nanos() as i128),
        })
        .unwrap_or(0);
    Some(FileStamp { len: meta.len(), mtime_ns })
}

/// The revision of a SQLite database: the stamps of the main file, its write-ahead log and its
/// rollback journal. Any of them moving means the content may have changed.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Default, serde::Serialize, serde::Deserialize)]
pub struct SourceSignature(pub Vec<Option<FileStamp>>);

pub fn source_signature(path: &Path) -> SourceSignature {
    SourceSignature(sibling_paths(path).iter().map(|p| file_stamp(p)).collect())
}

fn sibling_paths(path: &Path) -> [PathBuf; 3] {
    let with_suffix = |suffix: &str| {
        let mut os = path.as_os_str().to_owned();
        os.push(suffix);
        PathBuf::from(os)
    };
    [path.to_path_buf(), with_suffix("-wal"), with_suffix("-journal")]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_database_is_absent_not_an_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("missing.db");
        assert!(query_value(&path, "SELECT 1").unwrap().is_none());
        assert_eq!(source_signature(&path), SourceSignature(vec![None, None, None]));
    }

    #[test]
    fn reads_values_and_tracks_revisions() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.vscdb");
        {
            let conn = Connection::open(&path).unwrap();
            conn.execute_batch(
                "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB);
                 INSERT INTO ItemTable VALUES ('k', '{\"apiKey\":\"abc\"}');",
            )
            .unwrap();
        }
        let before = source_signature(&path);
        let value = query_value(&path, "SELECT value FROM ItemTable WHERE key = 'k'").unwrap();
        assert_eq!(value.as_deref(), Some("{\"apiKey\":\"abc\"}"));
        assert!(query_value(&path, "SELECT value FROM ItemTable WHERE key = 'nope'").unwrap().is_none());
        assert!(query_value(&path, "SELECT value FROM Missing").is_err());
        assert!(query_value_tolerating_missing_table(&path, "SELECT value FROM Missing").unwrap().is_none());
        std::thread::sleep(Duration::from_millis(5));
        Connection::open(&path).unwrap().execute("INSERT INTO ItemTable VALUES ('x', 'y')", []).unwrap();
        assert_ne!(before, source_signature(&path));
    }

    #[test]
    fn reads_current_wal_rows_from_a_path_with_spaces() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("database with spaces.sqlite");
        let writer = Connection::open(&path).unwrap();
        writer.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA wal_autocheckpoint = 0;
             CREATE TABLE usage (name TEXT);
             INSERT INTO usage VALUES ('in the WAL');",
        ).unwrap();
        assert_eq!(query_text(&path, "SELECT name FROM usage", false).unwrap().as_deref(), Some("in the WAL"));
    }
}
