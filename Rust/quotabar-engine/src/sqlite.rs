//! Native, in-process, read-only SQLite access to other apps' databases.
//!
//! Replaces the Swift backend's `/usr/bin/sqlite3` subprocess per query. Two techniques adapted from
//! rsusage (MIT, © 2026 Coobyk, <https://github.com/coobyk/rsusage>, `src/agents/sqlite.rs`):
//!
//! - open read-only without SQLite's internal mutex (each connection is used by one thread), and
//! - a cheap *source signature* over the database and its `-wal` / `-journal` siblings, so callers can
//!   skip an unchanged database entirely instead of querying it on every refresh.

use rusqlite::{Connection, OpenFlags};
use std::path::{Path, PathBuf};
use std::time::Duration;

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
/// Another app may hold the database open in WAL mode. A plain read-only open works whenever SQLite
/// can use (or create) the `-shm` file; when it cannot (a read-only directory, a sandbox), fall back
/// to `immutable=1`, which reads the main file without the WAL.
pub fn open_read_only(path: &Path) -> Result<Option<Connection>, SqliteError> {
    if !path.exists() {
        return Ok(None);
    }
    let flags = OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    match Connection::open_with_flags(path, flags).and_then(|conn| probe(conn)) {
        Ok(conn) => Ok(Some(conn)),
        Err(first) => {
            let uri = immutable_uri(path);
            Connection::open_with_flags(&uri, flags | OpenFlags::SQLITE_OPEN_URI)
                .and_then(probe)
                .map(Some)
                .map_err(|_| SqliteError::Unreadable(first.to_string()))
        }
    }
}

/// Touch the schema so a database that opens lazily but cannot actually be read fails here.
fn probe(conn: Connection) -> rusqlite::Result<Connection> {
    conn.busy_timeout(Duration::from_millis(2_000))?;
    conn.query_row("SELECT count(*) FROM sqlite_master", [], |_| Ok(()))?;
    Ok(conn)
}

fn immutable_uri(path: &Path) -> String {
    let mut encoded = String::new();
    for byte in path.to_string_lossy().bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'/' | b'-' | b'_' | b'.' | b'~' | b':' | b'\\' => {
                encoded.push(byte as char)
            }
            _ => encoded.push_str(&format!("%{byte:02X}")),
        }
    }
    #[cfg(windows)]
    {
        encoded = encoded.replace('\\', "/");
        if !encoded.starts_with('/') {
            encoded.insert(0, '/');
        }
    }
    format!("file:{encoded}?immutable=1")
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
    fn immutable_uri_escapes_spaces() {
        let uri = immutable_uri(Path::new("/tmp/Application Support/x.db"));
        assert!(uri.starts_with("file:"));
        assert!(uri.contains("Application%20Support"));
        assert!(uri.ends_with("?immutable=1"));
    }
}
