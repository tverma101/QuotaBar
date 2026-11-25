//! Persistent incremental fold cache and revision helper for `DevinSessionUsageReader`.

use super::sessions::DevinSessionEntry;
use crate::host::{diagnostic_gate, plugin_tag};
use crate::paths;
use crate::pricing::TokenBreakdown;
use crate::qlog;
use crate::scan::discover::Revision;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs::OpenOptions;
use std::path::{Path, PathBuf};

pub(super) const CACHE_SCHEMA: i32 = 1;
const MAX_RECORD_BYTES: usize = 64 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StoredStamp {
    pub inode: i64,
    pub modified: f64,
    pub size: i64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StoredWinner {
    pub row_id: i64,
    pub timestamp: f64,
    pub model: String,
    pub input: i64,
    pub cache_write_5m: i64,
    pub cache_read: i64,
    pub output: i64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CacheRecord {
    pub schema: i32,
    pub revision: Vec<Option<StoredStamp>>,
    pub watermark: i64,
    pub row_count: i64,
    pub row_id_sum: i64,
    pub winners: HashMap<String, StoredWinner>,
}

pub(super) type DbRevision = [Option<StoredStamp>; 2];

pub(super) struct FoldState {
    pub watermark: i64,
    pub row_count: i64,
    pub row_id_sum: i64,
    pub winners: HashMap<String, StoredWinner>,
    pub revision: DbRevision,
}

pub(super) fn revision_for(db_path: &Path) -> Option<DbRevision> {
    let db_stamp = to_stored_stamp(Revision::read(db_path).ok()?);
    let mut wal_os = db_path.as_os_str().to_os_string();
    wal_os.push("-wal");
    let wal_stamp = Revision::read(Path::new(&wal_os)).ok().map(to_stored_stamp);
    Some([Some(db_stamp), wal_stamp])
}

fn to_stored_stamp(rev: Revision) -> StoredStamp {
    StoredStamp {
        inode: rev.ino as i64,
        modified: rev.mtime_ns as f64 / 1_000_000_000.0,
        size: rev.size as i64,
    }
}

pub(super) fn sorted_entries(winners: &HashMap<String, StoredWinner>) -> Vec<DevinSessionEntry> {
    let mut vals: Vec<&StoredWinner> = winners.values().collect();
    vals.sort_by_key(|w| w.row_id);
    vals.into_iter()
        .filter_map(|w| {
            let tokens = TokenBreakdown {
                input: w.input,
                cache_write_5m: w.cache_write_5m,
                cache_write_1h: 0,
                cache_read: w.cache_read,
                output: w.output,
                is_fast: false,
            };
            (tokens.total_tokens() > 0).then(|| DevinSessionEntry {
                timestamp: w.timestamp,
                model: w.model.clone(),
                tokens,
            })
        })
        .collect()
}

fn stable_fingerprint(s: &str) -> String {
    Sha256::digest(s.as_bytes())
        .iter()
        .take(8)
        .map(|b| format!("{b:02x}"))
        .collect()
}

fn cache_file_path(db_path: &Path, dir_override: Option<&Path>) -> PathBuf {
    let base = dir_override
        .map(PathBuf::from)
        .unwrap_or_else(|| paths::cache_dir("devin-session-usage"));
    let fp = stable_fingerprint(&db_path.to_string_lossy());
    base.join(format!("{fp}.json"))
}

pub(super) fn read_cache_record(
    db_path: &Path,
    dir_override: Option<&Path>,
) -> Option<CacheRecord> {
    let path = cache_file_path(db_path, dir_override);
    let data = std::fs::read(&path).ok()?;
    let rec: CacheRecord = serde_json::from_slice(&data).ok()?;
    (rec.schema == CACHE_SCHEMA).then_some(rec)
}

pub(super) fn write_cache_record(
    record: &CacheRecord,
    db_path: &Path,
    dir_override: Option<&Path>,
) {
    let url = cache_file_path(db_path, dir_override);
    let fp = stable_fingerprint(&db_path.to_string_lossy());
    let Ok(bytes) = serde_json::to_vec(record) else {
        return;
    };
    if bytes.len() > MAX_RECORD_BYTES {
        diagnostic_gate::log_once(
            &format!("provider.devin.session-usage-record-oversized.{fp}"),
            || {
                qlog!(
                    Warn,
                    plugin_tag("devin"),
                    "devin session usage record for {fp} is {} MB; not persisting it",
                    bytes.len() / 1_048_576
                );
            },
        );
        return;
    }
    let Some(dir) = url.parent() else { return };
    if std::fs::create_dir_all(dir).is_err() {
        return;
    }
    let lock_path = dir.join(".devin-session-usage.lock");
    let Ok(lock_file) = OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .open(&lock_path)
    else {
        return;
    };
    #[cfg(unix)]
    let _guard = FlockGuard::acquire(&lock_file);
    if let Ok(mut tmp) = tempfile::NamedTempFile::new_in(dir) {
        use std::io::Write;
        if tmp.write_all(&bytes).is_ok() && tmp.flush().is_ok() {
            if let Err(err) = tmp.persist(&url) {
                qlog!(
                    Warn,
                    plugin_tag("devin"),
                    "devin session usage cache write failed for {fp}: {}",
                    err.error
                );
            }
        }
    }
}

#[cfg(unix)]
struct FlockGuard(i32);

#[cfg(unix)]
impl FlockGuard {
    fn acquire(file: &std::fs::File) -> Option<Self> {
        use std::os::unix::io::AsRawFd;
        let fd = file.as_raw_fd();
        unsafe extern "C" {
            fn flock(fd: i32, operation: i32) -> i32;
        }
        const LOCK_EX: i32 = 2;
        if unsafe { flock(fd, LOCK_EX) } == 0 {
            Some(FlockGuard(fd))
        } else {
            None
        }
    }
}

#[cfg(unix)]
impl Drop for FlockGuard {
    fn drop(&mut self) {
        unsafe extern "C" {
            fn flock(fd: i32, operation: i32) -> i32;
        }
        const LOCK_UN: i32 = 8;
        unsafe { flock(self.0, LOCK_UN) };
    }
}
