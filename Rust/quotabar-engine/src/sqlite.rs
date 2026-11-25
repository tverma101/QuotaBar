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
use std::io::{Read, Seek, SeekFrom};
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
const MAX_QUERY_TIMEOUT: Duration = Duration::from_secs(60);

/// [`open_read_only`] with a caller-chosen budget for the connection's whole query sequence. The
/// five-second default suits probes and small stores; a scanner that deliberately chunks a large
/// full-history fold can spend longer in total while keeping every individual statement bounded.
pub fn open_read_only_within(
    path: &Path,
    timeout: Duration,
) -> Result<Option<Connection>, SqliteError> {
    let timeout = timeout.clamp(Duration::from_millis(100), MAX_QUERY_TIMEOUT);
    open_for_query(path, false, Instant::now() + timeout)
}

fn open_for_query(
    path: &Path,
    allow_wal_retry: bool,
    deadline: Instant,
) -> Result<Option<Connection>, SqliteError> {
    match path.metadata() {
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(SqliteError::Unreadable(error.to_string())),
    }
    let open = |access| -> rusqlite::Result<Connection> {
        let conn = Connection::open_with_flags(path, access | OpenFlags::SQLITE_OPEN_NO_MUTEX)?;
        bound_query(&conn, deadline)?;
        conn.pragma_update(None, "query_only", true)?;
        crate::sqlite_sha3::register(&conn)?;
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
            open(OpenFlags::SQLITE_OPEN_READ_WRITE)
                .map(Some)
                .map_err(Into::into)
        }
        result => result.map(Some).map_err(Into::into),
    }
}

fn bound_query(conn: &Connection, deadline: Instant) -> rusqlite::Result<()> {
    conn.busy_timeout(
        Duration::from_secs(1).min(deadline.saturating_duration_since(Instant::now())),
    )?;
    conn.progress_handler(1000, Some(move || Instant::now() >= deadline));
    Ok(())
}

/// The SQLite shell's plain list output. Some legacy scanner queries consume multiple rows
/// separated by newlines, with pipes between columns and empty strings for SQL NULLs.
pub fn query_text(
    path: &Path,
    sql: &str,
    allow_wal_retry: bool,
) -> Result<Option<String>, SqliteError> {
    query_text_within(path, sql, allow_wal_retry, QUERY_TIMEOUT)
}

/// [`query_text`] with a caller-chosen wall-clock budget. The five-second default suits credential
/// probes and small stores; usage scanners over multi-hundred-MB databases (OpenCode, Freebuff)
/// pass a wider budget because their whole-history queries legitimately outrun five seconds on a
/// cold page cache. The budget is clamped to `[0.1s, MAX_QUERY_TIMEOUT]`.
pub fn query_text_within(
    path: &Path,
    sql: &str,
    allow_wal_retry: bool,
    timeout: Duration,
) -> Result<Option<String>, SqliteError> {
    let timeout = timeout.clamp(Duration::from_millis(100), MAX_QUERY_TIMEOUT);
    let Some(conn) = open_for_query(path, allow_wal_retry, Instant::now() + timeout)? else {
        return Ok(None);
    };
    let mut statement = conn.prepare(sql)?;
    if !statement.readonly() {
        return Err(SqliteError::Unreadable(
            "Expected a read-only SQLite query.".into(),
        ));
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
                ValueRef::Text(value) | ValueRef::Blob(value) => {
                    output.push_str(&String::from_utf8_lossy(value))
                }
                ValueRef::Integer(value) => {
                    let _ = write!(output, "{value}");
                }
                ValueRef::Real(value) => {
                    let _ = write!(output, "{value}");
                }
            }
        }
        output.push('\n');
    }
    let trimmed = output.trim();
    Ok((!trimmed.is_empty()).then(|| trimmed.to_owned()))
}

/// Visit each result row without materializing the query as one text blob. Usage scanners use
/// this for their wide history queries: it avoids SQLite's `json_group_array` encoding and the
/// second JSON decode that would otherwise allocate a `Value` tree for every row.
pub(crate) fn for_each_row_within<F>(
    path: &Path,
    sql: &str,
    allow_wal_retry: bool,
    timeout: Duration,
    mut visit: F,
) -> Result<(), SqliteError>
where
    F: FnMut(&rusqlite::Row<'_>) -> Result<(), String>,
{
    let timeout = timeout.clamp(Duration::from_millis(100), MAX_QUERY_TIMEOUT);
    let Some(conn) = open_for_query(path, allow_wal_retry, Instant::now() + timeout)? else {
        return Ok(());
    };
    let mut statement = conn.prepare(sql)?;
    if !statement.readonly() {
        return Err(SqliteError::Unreadable(
            "Expected a read-only SQLite query.".into(),
        ));
    }
    let mut rows = statement.query([])?;
    while let Some(row) = rows.next()? {
        visit(row).map_err(SqliteError::Unreadable)?;
    }
    Ok(())
}

/// Run an intentional write, such as persisting Cursor's rotated token. SQL stays inside the
/// process, and errors avoid returning SQL text that could contain a credential.
pub fn execute(path: &Path, sql: &str) -> Result<(), SqliteError> {
    let flags = OpenFlags::SQLITE_OPEN_READ_WRITE
        | OpenFlags::SQLITE_OPEN_CREATE
        | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    (|| {
        let conn = Connection::open_with_flags(path, flags)?;
        bound_query(&conn, Instant::now() + QUERY_TIMEOUT)?;
        conn.execute_batch(sql)
    })()
    .map_err(|error| {
        SqliteError::Unreadable(match error.sqlite_error_code() {
            Some(code) => format!("SQLite write failed ({code:?})."),
            None => "SQLite write failed.".into(),
        })
    })
}

/// First column of the first row as text. `Ok(None)` when the database or the row is absent.
pub fn query_value(path: &Path, sql: &str) -> Result<Option<String>, SqliteError> {
    let Some(conn) = open_read_only(path)? else {
        return Ok(None);
    };
    let mut statement = conn.prepare(sql)?;
    let mut rows = statement.query([])?;
    match rows.next()? {
        Some(row) => Ok(value_as_text(row.get_ref(0)?)),
        None => Ok(None),
    }
}

/// Like [`query_value`], but a missing table is an absent source rather than an error (an app that
/// was installed but never signed in has an empty database).
pub fn query_value_tolerating_missing_table(
    path: &Path,
    sql: &str,
) -> Result<Option<String>, SqliteError> {
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
    Some(FileStamp {
        len: meta.len(),
        mtime_ns,
    })
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
    [
        path.to_path_buf(),
        with_suffix("-wal"),
        with_suffix("-journal"),
    ]
}

fn with_suffix(path: &Path, suffix: &str) -> PathBuf {
    let mut os = path.as_os_str().to_owned();
    os.push(suffix);
    PathBuf::from(os)
}

/// Recover a sidecarless WAL-mode SQLite database by cloning it into a private temp directory,
/// switching the clone alone to `journal_mode=DELETE`, and opening the clone read-only. Never
/// touches the source file or its directory, so SQLite never leaves `-wal`/`-shm` sidecars behind.
pub fn with_recovered_sidecarless_database<T>(
    path: &Path,
    op: impl FnOnce(&Connection) -> Result<T, SqliteError>,
) -> Result<T, SqliteError> {
    if with_suffix(path, "-wal").exists()
        || with_suffix(path, "-shm").exists()
        || with_suffix(path, "-journal").exists()
    {
        return Err(SqliteError::Unreadable(
            "Database already has journal sidecars.".into(),
        ));
    }
    let mut source = open_pinned_regular_file(path)?;
    let mut header = [0u8; 20];
    source
        .read_exact(&mut header)
        .map_err(|e| SqliteError::Unreadable(e.to_string()))?;
    if &header[..16] != b"SQLite format 3\0" || header[18] != 2 || header[19] != 2 {
        return Err(SqliteError::Unreadable(
            "Database is not a sidecarless WAL SQLite file.".into(),
        ));
    }
    let dir = tempfile::tempdir().map_err(|e| SqliteError::Unreadable(e.to_string()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o700))
            .map_err(|e| SqliteError::Unreadable(e.to_string()))?;
    }
    let snapshot = dir.path().join("snapshot.db");
    clone_or_copy_pinned(&mut source, &snapshot)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&snapshot, std::fs::Permissions::from_mode(0o600))
            .map_err(|e| SqliteError::Unreadable(e.to_string()))?;
    }
    {
        let rw = Connection::open_with_flags(
            &snapshot,
            OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        bound_query(&rw, Instant::now() + QUERY_TIMEOUT)?;
        rw.execute_batch("PRAGMA journal_mode=DELETE;")?;
    }
    let ro = open_for_query(&snapshot, false, Instant::now() + QUERY_TIMEOUT)?
        .ok_or_else(|| SqliteError::Unreadable("Recovered snapshot missing.".into()))?;
    op(&ro)
}

fn open_pinned_regular_file(path: &Path) -> Result<std::fs::File, SqliteError> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        // O_NOFOLLOW + O_NONBLOCK | O_CLOEXEC on macOS/Unix (macOS flags: 0x0100 | 0x0004 | 0x1000000).
        #[cfg(target_os = "macos")]
        const FLAGS: i32 = 0x0100 | 0x0004 | 0x1000000;
        #[cfg(not(target_os = "macos"))]
        const FLAGS: i32 = 0x20000 | 0x0800 | 0x80000; // O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC on Linux
        let file = std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(FLAGS)
            .open(path)
            .map_err(|e| SqliteError::Unreadable(e.to_string()))?;
        let meta = file
            .metadata()
            .map_err(|e| SqliteError::Unreadable(e.to_string()))?;
        if !meta.is_file() {
            return Err(SqliteError::Unreadable(
                "Source database is not a regular file.".into(),
            ));
        }
        Ok(file)
    }
    #[cfg(not(unix))]
    {
        let sym =
            std::fs::symlink_metadata(path).map_err(|e| SqliteError::Unreadable(e.to_string()))?;
        if !sym.file_type().is_file() {
            return Err(SqliteError::Unreadable(
                "Source database is not a regular file.".into(),
            ));
        }
        std::fs::File::open(path).map_err(|e| SqliteError::Unreadable(e.to_string()))
    }
}

fn clone_or_copy_pinned(source: &mut std::fs::File, dst: &Path) -> Result<(), SqliteError> {
    #[cfg(target_os = "macos")]
    {
        use std::ffi::CString;
        use std::os::unix::ffi::OsStrExt;
        use std::os::unix::io::AsRawFd;
        extern "C" {
            fn fclonefileat(
                srcfd: std::os::raw::c_int,
                dst_dirfd: std::os::raw::c_int,
                dst: *const std::os::raw::c_char,
                flags: u32,
            ) -> std::os::raw::c_int;
        }
        const AT_FDCWD: std::os::raw::c_int = -2;
        if let Ok(c_dst) = CString::new(dst.as_os_str().as_bytes()) {
            let rc = unsafe { fclonefileat(source.as_raw_fd(), AT_FDCWD, c_dst.as_ptr(), 0) };
            if rc == 0 {
                return Ok(());
            }
        }
    }
    source
        .seek(SeekFrom::Start(0))
        .map_err(|e| SqliteError::Unreadable(e.to_string()))?;
    let mut out = std::fs::File::create(dst).map_err(|e| SqliteError::Unreadable(e.to_string()))?;
    std::io::copy(source, &mut out).map_err(|e| SqliteError::Unreadable(e.to_string()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_database_is_absent_not_an_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("missing.db");
        assert!(query_value(&path, "SELECT 1").unwrap().is_none());
        assert_eq!(
            source_signature(&path),
            SourceSignature(vec![None, None, None])
        );
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
        assert!(
            query_value(&path, "SELECT value FROM ItemTable WHERE key = 'nope'")
                .unwrap()
                .is_none()
        );
        assert!(query_value(&path, "SELECT value FROM Missing").is_err());
        assert!(
            query_value_tolerating_missing_table(&path, "SELECT value FROM Missing")
                .unwrap()
                .is_none()
        );
        std::thread::sleep(Duration::from_millis(5));
        Connection::open(&path)
            .unwrap()
            .execute("INSERT INTO ItemTable VALUES ('x', 'y')", [])
            .unwrap();
        assert_ne!(before, source_signature(&path));
    }

    #[test]
    fn a_caller_budget_bounds_long_queries_and_is_clamped() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("big.sqlite");
        Connection::open(&path)
            .unwrap()
            .execute_batch("CREATE TABLE t (v INTEGER);")
            .unwrap();
        // A zero budget clamps to the floor instead of failing every query outright.
        assert_eq!(
            query_text_within(&path, "SELECT 42", false, Duration::ZERO)
                .unwrap()
                .as_deref(),
            Some("42")
        );
        // A runaway query stops at its budget rather than running unbounded.
        let started = Instant::now();
        let runaway = "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n) SELECT count(*) FROM n";
        assert!(query_text_within(&path, runaway, false, Duration::from_millis(300)).is_err());
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "budget ignored: {:?}",
            started.elapsed()
        );
    }

    #[test]
    fn reads_current_wal_rows_from_a_path_with_spaces() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("database with spaces.sqlite");
        let writer = Connection::open(&path).unwrap();
        writer
            .execute_batch(
                "PRAGMA journal_mode = WAL;
             PRAGMA wal_autocheckpoint = 0;
             CREATE TABLE usage (name TEXT);
             INSERT INTO usage VALUES ('in the WAL');",
            )
            .unwrap();
        assert_eq!(
            query_text(&path, "SELECT name FROM usage", false)
                .unwrap()
                .as_deref(),
            Some("in the WAL")
        );
    }

    #[test]
    fn recovers_sidecarless_wal_database_without_touching_source_directory() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sidecarless.db");
        {
            let conn = Connection::open(&path).unwrap();
            conn.execute_batch(
                "PRAGMA journal_mode = WAL;
                 CREATE TABLE items (name TEXT);
                 INSERT INTO items VALUES ('ok');
                 PRAGMA wal_checkpoint(TRUNCATE);",
            )
            .unwrap();
        }
        // Simulate an unlinked -wal/-shm pair on a WAL-mode database.
        let _ = std::fs::remove_file(with_suffix(&path, "-wal"));
        let _ = std::fs::remove_file(with_suffix(&path, "-shm"));
        assert!(!with_suffix(&path, "-wal").exists());

        let count: i64 = with_recovered_sidecarless_database(&path, |conn| {
            Ok(conn.query_row("SELECT count(*) FROM items", [], |r| r.get(0))?)
        })
        .unwrap();
        assert_eq!(count, 1);
        assert!(
            !with_suffix(&path, "-wal").exists(),
            "recovery must never create sidecars"
        );
        assert!(
            !with_suffix(&path, "-shm").exists(),
            "recovery must never create sidecars"
        );
    }
}
