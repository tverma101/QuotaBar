//! Persistent per-file scan cache: one SQLite database for every scanner, so a cold start reads
//! compact blobs instead of re-parsing gigabytes of logs.
//!
//! Rows are keyed by `(partition, path)`; a partition is one parser over one set of roots. WAL mode
//! and a busy timeout let the dev and release builds share the file. A corrupt or foreign row is a
//! cache miss (the file is re-parsed), never an error the user sees.

use super::discover::Revision;
use crate::qlog;
use rusqlite::{params, Connection, OptionalExtension};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

/// One persisted file checkpoint, still encoded.
#[derive(Clone, Debug, PartialEq)]
pub struct StoredFile {
    pub path: String,
    pub revision: Revision,
    pub committed_end: u64,
    pub fragment_len: u64,
    pub anchor: Option<[u8; 16]>,
    pub state: Vec<u8>,
    pub items: Vec<u8>,
    pub fragment_items: Vec<u8>,
}

pub struct ScanStore {
    path: PathBuf,
    conn: Mutex<Option<Connection>>,
}

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS scan_files (
    partition TEXT NOT NULL,
    path TEXT NOT NULL,
    layout INTEGER NOT NULL,
    size INTEGER NOT NULL,
    mtime_ns INTEGER NOT NULL,
    ctime_ns INTEGER NOT NULL,
    dev INTEGER NOT NULL,
    ino INTEGER NOT NULL,
    committed_end INTEGER NOT NULL,
    fragment_len INTEGER NOT NULL,
    anchor BLOB,
    state BLOB NOT NULL,
    items BLOB NOT NULL,
    fragment_items BLOB NOT NULL,
    PRIMARY KEY (partition, path)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS scan_results (
    key TEXT PRIMARY KEY NOT NULL,
    fingerprint BLOB NOT NULL,
    value BLOB NOT NULL
) WITHOUT ROWID;
";

impl ScanStore {
    /// The engine-wide store under the app data directory.
    pub fn shared() -> &'static ScanStore {
        static STORE: OnceLock<ScanStore> = OnceLock::new();
        STORE.get_or_init(|| ScanStore::at(crate::paths::cache_dir("scan").join("scan-cache.sqlite3")))
    }

    pub fn at(path: PathBuf) -> ScanStore {
        ScanStore { path, conn: Mutex::new(None) }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    fn open(path: &Path) -> rusqlite::Result<Connection> {
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let conn = Connection::open(path)?;
        conn.busy_timeout(std::time::Duration::from_secs(5))?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        conn.execute_batch(SCHEMA)?;
        Ok(conn)
    }

    /// Run `f` on the open connection, reopening once after a failure (a deleted cache directory).
    fn with<T>(&self, what: &str, f: impl Fn(&mut Connection) -> rusqlite::Result<T>) -> Option<T> {
        let mut slot = self.conn.lock().unwrap_or_else(|e| e.into_inner());
        for attempt in 0..2 {
            if slot.is_none() {
                match Self::open(&self.path) {
                    Ok(conn) => *slot = Some(conn),
                    Err(e) => {
                        qlog!(Error, "scan-cache", "open failed ({what}): {e}");
                        return None;
                    }
                }
            }
            match f(slot.as_mut().expect("connection opened above")) {
                Ok(value) => return Some(value),
                Err(e) => {
                    qlog!(Warn, "scan-cache", "{what} failed (attempt {}): {e}", attempt + 1);
                    *slot = None;
                }
            }
        }
        None
    }

    /// Every row of a partition written with `layout`. Rows of another layout are stale.
    pub fn load_partition(&self, partition: &str, layout: u32) -> Vec<StoredFile> {
        self.with("load", |conn| {
            let mut stmt = conn.prepare_cached(
                "SELECT path, size, mtime_ns, ctime_ns, dev, ino, committed_end, fragment_len, anchor,
                        state, items, fragment_items
                 FROM scan_files WHERE partition = ?1 AND layout = ?2",
            )?;
            let rows = stmt.query_map(params![partition, layout], |row| {
                let anchor: Option<Vec<u8>> = row.get(8)?;
                Ok(StoredFile {
                    path: row.get(0)?,
                    revision: Revision {
                        size: row.get::<_, i64>(1)? as u64,
                        mtime_ns: row.get(2)?,
                        ctime_ns: row.get(3)?,
                        dev: row.get::<_, i64>(4)? as u64,
                        ino: row.get::<_, i64>(5)? as u64,
                    },
                    committed_end: row.get::<_, i64>(6)? as u64,
                    fragment_len: row.get::<_, i64>(7)? as u64,
                    anchor: anchor.and_then(|a| a.try_into().ok()),
                    state: row.get(9)?,
                    items: row.get(10)?,
                    fragment_items: row.get(11)?,
                })
            })?;
            rows.collect()
        })
        .unwrap_or_default()
    }

    /// Upsert `changed`, delete `removed`, and drop rows of other layouts, in one transaction.
    pub fn commit(&self, partition: &str, layout: u32, changed: &[StoredFile], removed: &[String]) {
        if changed.is_empty() && removed.is_empty() {
            return;
        }
        self.with("commit", |conn| {
            let tx = conn.transaction()?;
            {
                let mut upsert = tx.prepare_cached(
                    "INSERT OR REPLACE INTO scan_files
                     (partition, path, layout, size, mtime_ns, ctime_ns, dev, ino, committed_end,
                      fragment_len, anchor, state, items, fragment_items)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)",
                )?;
                for file in changed {
                    upsert.execute(params![
                        partition,
                        file.path,
                        layout,
                        file.revision.size as i64,
                        file.revision.mtime_ns,
                        file.revision.ctime_ns,
                        file.revision.dev as i64,
                        file.revision.ino as i64,
                        file.committed_end as i64,
                        file.fragment_len as i64,
                        file.anchor.as_ref().map(|a| a.as_slice()),
                        file.state,
                        file.items,
                        file.fragment_items,
                    ])?;
                }
                let mut delete = tx.prepare_cached("DELETE FROM scan_files WHERE partition = ?1 AND path = ?2")?;
                for path in removed {
                    delete.execute(params![partition, path])?;
                }
                tx.execute("DELETE FROM scan_files WHERE partition = ?1 AND layout != ?2", params![partition, layout])?;
            }
            tx.commit()
        });
    }

    /// A folded result cached under `key`, valid only while `fingerprint` matches.
    pub fn load_result(&self, key: &str, fingerprint: &[u8]) -> Option<Vec<u8>> {
        self.with("load result", |conn| {
            conn.query_row(
                "SELECT value FROM scan_results WHERE key = ?1 AND fingerprint = ?2",
                params![key, fingerprint],
                |row| row.get(0),
            )
            .optional()
        })
        .flatten()
    }

    pub fn store_result(&self, key: &str, fingerprint: &[u8], value: &[u8]) {
        self.with("store result", |conn| {
            conn.execute(
                "INSERT OR REPLACE INTO scan_results (key, fingerprint, value) VALUES (?1, ?2, ?3)",
                params![key, fingerprint, value],
            )
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(path: &str, size: u64) -> StoredFile {
        StoredFile {
            path: path.into(),
            revision: Revision { size, mtime_ns: 7, ctime_ns: 8, dev: u64::MAX, ino: 3 },
            committed_end: size,
            fragment_len: 0,
            anchor: Some([9; 16]),
            state: vec![],
            items: vec![1, 2, 3],
            fragment_items: vec![0],
        }
    }

    #[test]
    fn partitions_layouts_and_removals() {
        let dir = tempfile::tempdir().unwrap();
        let store = ScanStore::at(dir.path().join("nested/scan.sqlite3"));
        store.commit("claude:a", 1, &[row("/x", 10), row("/y", 20)], &[]);
        store.commit("claude:b", 1, &[row("/x", 30)], &[]);
        let a = store.load_partition("claude:a", 1);
        assert_eq!(a.len(), 2);
        assert_eq!(a.iter().find(|f| f.path == "/x").unwrap(), &row("/x", 10));
        assert!(store.load_partition("claude:a", 2).is_empty());

        store.commit("claude:a", 1, &[], &["/y".to_string()]);
        assert_eq!(store.load_partition("claude:a", 1).len(), 1);
        // A new layout replaces the old rows wholesale.
        store.commit("claude:a", 2, &[row("/z", 1)], &[]);
        assert!(store.load_partition("claude:a", 1).is_empty());
        assert_eq!(store.load_partition("claude:b", 1).len(), 1);

        store.store_result("k", b"fp1", b"value");
        assert_eq!(store.load_result("k", b"fp1").as_deref(), Some(&b"value"[..]));
        assert_eq!(store.load_result("k", b"fp2"), None);
    }

    #[test]
    fn a_deleted_cache_directory_is_recreated() {
        let dir = tempfile::tempdir().unwrap();
        let store = ScanStore::at(dir.path().join("cache/scan.sqlite3"));
        store.commit("p", 1, &[row("/x", 1)], &[]);
        std::fs::remove_dir_all(dir.path().join("cache")).unwrap();
        store.commit("p", 1, &[row("/x", 2)], &[]);
        // The open handle may still point at the unlinked file; a fresh store must see a usable DB.
        let fresh = ScanStore::at(dir.path().join("cache/scan.sqlite3"));
        fresh.commit("p", 1, &[row("/y", 3)], &[]);
        assert!(fresh.load_partition("p", 1).iter().any(|f| f.path == "/y"));
    }
}
