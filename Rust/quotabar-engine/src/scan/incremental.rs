//! The incremental scanner shared by every JSONL-based provider.
//!
//! Per file it keeps the parsed rows, the offset just past the last complete line, the parser's
//! state at that offset and a sampled signature of the bytes before it. A refresh then costs:
//! - unchanged file (same size, mtimes, inode): nothing — the cached rows are reused;
//! - grown file whose old prefix still matches: only the appended bytes are parsed, resuming the
//!   parser from its saved state (live Claude/Codex sessions append one row per turn);
//! - anything else (rewrite, truncation, rotation): a full re-parse.
//!
//! A scan is one publication unit: if any changed file cannot be read or holds a malformed record,
//! the scan fails and the previous cache stays as it was, so a transient error never looks like
//! usage disappearing. A trailing line without a newline is provisional — its rows are returned but
//! re-read next time, so a row still being written is counted once, when complete.

use super::codec::{self, Record};
use super::discover::{DiscoveredFile, Revision};
use super::reader;
use super::store::{ScanStore, StoredFile};
use crate::context::CancelToken;
use crate::qlog;
use std::collections::HashMap;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

/// A line the parser cannot accept. For most parsers this rejects the whole file (and so the scan):
/// a record in an unknown shape must stay visible rather than silently undercount.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LineError(pub &'static str);

pub trait LineParser: Send + Sync + 'static {
    type Item: Record + Clone + Send + Sync + 'static;
    /// State carried from one line to the next (session metadata, running totals). Saved at each
    /// checkpoint so an append resumes exactly where the previous read stopped.
    type State: Record + Clone + Default + Send + Sync + 'static;
    /// Bump when parse semantics or the item encoding change; older cache rows are re-parsed.
    const LAYOUT: u32;
    /// Cheap byte-level prefilter; rejected lines never reach `parse`.
    fn wants(&self, line: &[u8]) -> bool;
    fn parse(
        &self,
        state: &mut Self::State,
        line: &[u8],
        out: &mut Vec<Self::Item>,
    ) -> Result<(), LineError>;
    /// When a row counts toward usage, its timestamp (seconds since 1970) for the future-timestamp
    /// guard; `None` for rows that do not contribute.
    fn contributing_timestamp(&self, _item: &Self::Item) -> Option<f64> {
        None
    }
}

/// Local records may run slightly ahead of wall time; anything later than this skews history into
/// future days, so the source stays incomplete (last-good history) until the clock catches up.
pub const FUTURE_TOLERANCE_SECONDS: f64 = 5.0 * 60.0;

#[derive(Debug)]
pub enum ScanError {
    Cancelled,
    Read {
        path: PathBuf,
        error: io::Error,
    },
    Malformed {
        path: PathBuf,
        reason: &'static str,
    },
    /// The file was replaced or truncated while it was read.
    Changed {
        path: PathBuf,
    },
}

impl std::fmt::Display for ScanError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ScanError::Cancelled => f.write_str("cancelled"),
            ScanError::Read { path, error } => {
                write!(f, "could not read {}: {error}", file_label(path))
            }
            ScanError::Malformed { path, reason } => {
                write!(f, "malformed record in {}: {reason}", file_label(path))
            }
            ScanError::Changed { path } => {
                write!(f, "{} changed while it was read", file_label(path))
            }
        }
    }
}

/// Log-safe file label: the file name only, never the user's directory layout.
pub fn file_label(path: &Path) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "<log>".into())
}

/// One file's rows in a scan result: committed rows then the provisional trailing-line rows.
#[derive(Clone)]
pub struct FileItems<T> {
    pub path: PathBuf,
    pub revision: Revision,
    pub items: Arc<Vec<T>>,
    pub fragment: Arc<Vec<T>>,
    /// The latest contributing row timestamp (see `LineParser::contributing_timestamp`).
    pub latest_timestamp: Option<f64>,
}

impl<T> FileItems<T> {
    pub fn iter(&self) -> impl Iterator<Item = &T> {
        self.items.iter().chain(self.fragment.iter())
    }

    pub fn len(&self) -> usize {
        self.items.len() + self.fragment.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// The row is dated beyond the tolerance past `now`.
    pub fn is_future_dated(&self, now: f64) -> bool {
        self.latest_timestamp
            .is_some_and(|t| t > now + FUTURE_TOLERANCE_SECONDS)
    }
}

/// The first file holding a row dated in the future, if any.
pub fn first_future_dated<T>(files: &[FileItems<T>], now: f64) -> Option<&FileItems<T>> {
    files.iter().find(|f| f.is_future_dated(now))
}

struct Cached<P: LineParser> {
    revision: Revision,
    committed_end: u64,
    fragment_len: u64,
    anchor: Option<[u8; 16]>,
    state: P::State,
    items: Arc<Vec<P::Item>>,
    fragment: Arc<Vec<P::Item>>,
    /// Latest contributing timestamps of the committed and the provisional rows (kept apart so an
    /// append, which re-reads the fragment, never rescans the committed rows).
    latest_committed: Option<f64>,
    latest_fragment: Option<f64>,
}

impl<P: LineParser> Clone for Cached<P> {
    fn clone(&self) -> Self {
        Cached {
            revision: self.revision,
            committed_end: self.committed_end,
            fragment_len: self.fragment_len,
            anchor: self.anchor,
            state: self.state.clone(),
            items: self.items.clone(),
            fragment: self.fragment.clone(),
            latest_committed: self.latest_committed,
            latest_fragment: self.latest_fragment,
        }
    }
}

#[derive(Default, Clone, Copy, Debug, PartialEq, Eq)]
pub struct ScanStats {
    pub reused: usize,
    pub appended: usize,
    pub full: usize,
    pub bytes_read: u64,
}

pub struct IncrementalScanner<P: LineParser> {
    parser: P,
    partition: String,
    store: Option<&'static ScanStore>,
    state: Mutex<Partition<P>>,
}

struct Partition<P: LineParser> {
    loaded: bool,
    files: HashMap<PathBuf, Cached<P>>,
    last_stats: ScanStats,
}

enum Plan<P: LineParser> {
    Reuse(Cached<P>),
    Parse(Option<Cached<P>>),
}

impl<P: LineParser> IncrementalScanner<P> {
    /// `partition` names this parser over one set of roots (two cards over the same roots share it).
    /// `store: None` keeps the cache in memory only (tests, one-shot tools).
    pub fn new(parser: P, partition: impl Into<String>, store: Option<&'static ScanStore>) -> Self {
        IncrementalScanner {
            parser,
            partition: partition.into(),
            store,
            state: Mutex::new(Partition {
                loaded: false,
                files: HashMap::new(),
                last_stats: ScanStats::default(),
            }),
        }
    }

    pub fn parser(&self) -> &P {
        &self.parser
    }

    pub fn last_stats(&self) -> ScanStats {
        self.state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .last_stats
    }

    /// Parse what changed among `files` and return every in-window file's rows, in input order.
    /// Files whose content mtime predates `since_mtime` are skipped (and dropped from the cache), so
    /// years of history stay cheap to rescan.
    pub fn scan(
        &self,
        files: &[DiscoveredFile],
        since_mtime: Option<f64>,
        cancel: &CancelToken,
    ) -> Result<Vec<FileItems<P::Item>>, ScanError> {
        let mut partition = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if !partition.loaded {
            partition.files = self.load_from_store();
            partition.loaded = true;
        }
        let in_window: Vec<&DiscoveredFile> = files
            .iter()
            .filter(|f| since_mtime.map_or(true, |since| f.revision.mtime() >= since))
            .collect();

        let plans: Vec<Plan<P>> = in_window
            .iter()
            .map(|file| match partition.files.get(&file.path) {
                Some(cached) if cached.revision == file.revision => Plan::Reuse(cached.clone()),
                cached => Plan::Parse(cached.cloned()),
            })
            .collect();
        let parsed = self.parse_changed(&in_window, &plans, cancel)?;
        cancel.check().map_err(|_| ScanError::Cancelled)?;

        let mut stats = ScanStats::default();
        let mut changed = Vec::new();
        let mut results = Vec::with_capacity(in_window.len());
        for ((file, plan), outcome) in in_window.iter().zip(plans).zip(parsed) {
            let entry = match (plan, outcome) {
                (Plan::Reuse(cached), _) => {
                    stats.reused += 1;
                    cached
                }
                (
                    Plan::Parse(_),
                    Some(Parsed {
                        cached,
                        appended,
                        bytes_read,
                    }),
                ) => {
                    if appended {
                        stats.appended += 1;
                    } else {
                        stats.full += 1;
                    }
                    stats.bytes_read += bytes_read;
                    if self.store.is_some() {
                        changed.push(self.encode(&file.path, &cached));
                    }
                    partition.files.insert(file.path.clone(), cached.clone());
                    cached
                }
                (Plan::Parse(_), None) => {
                    unreachable!("every planned parse produced a result or failed the scan")
                }
            };
            results.push(FileItems {
                path: file.path.clone(),
                revision: entry.revision,
                items: entry.items,
                fragment: entry.fragment,
                latest_timestamp: max_opt(entry.latest_committed, entry.latest_fragment),
            });
        }
        let keep: std::collections::HashSet<&Path> =
            in_window.iter().map(|f| f.path.as_path()).collect();
        let removed: Vec<PathBuf> = partition
            .files
            .keys()
            .filter(|p| !keep.contains(p.as_path()))
            .cloned()
            .collect();
        for path in &removed {
            partition.files.remove(path);
        }
        if let Some(store) = self.store {
            let removed: Vec<String> = removed
                .iter()
                .map(|p| p.to_string_lossy().into_owned())
                .collect();
            store.commit(&self.partition, P::LAYOUT, &changed, &removed);
        }
        partition.last_stats = stats;
        Ok(results)
    }

    fn parse_changed(
        &self,
        files: &[&DiscoveredFile],
        plans: &[Plan<P>],
        cancel: &CancelToken,
    ) -> Result<Vec<Option<Parsed<P>>>, ScanError> {
        let jobs: Vec<usize> = plans
            .iter()
            .enumerate()
            .filter(|(_, p)| matches!(p, Plan::Parse(_)))
            .map(|(i, _)| i)
            .collect();
        let mut results: Vec<Option<Parsed<P>>> = (0..files.len()).map(|_| None).collect();
        if jobs.is_empty() {
            return Ok(results);
        }
        let workers = std::thread::available_parallelism()
            .map_or(2, |n| n.get())
            .clamp(1, 4)
            .min(jobs.len());
        let next = AtomicUsize::new(0);
        let slots: Mutex<Vec<(usize, Result<Parsed<P>, ScanError>)>> =
            Mutex::new(Vec::with_capacity(jobs.len()));
        std::thread::scope(|scope| {
            for _ in 0..workers {
                scope.spawn(|| loop {
                    let job = next.fetch_add(1, Ordering::Relaxed);
                    let Some(&index) = jobs.get(job) else { break };
                    let base = match &plans[index] {
                        Plan::Parse(base) => base.as_ref(),
                        Plan::Reuse(_) => unreachable!(),
                    };
                    let outcome = self.parse_file(files[index], base, cancel);
                    let failed = outcome.is_err();
                    slots
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .push((index, outcome));
                    if failed {
                        // Stop the other workers early; the scan fails as a whole.
                        next.store(jobs.len(), Ordering::Relaxed);
                        break;
                    }
                });
            }
        });
        let mut outcomes = slots.into_inner().unwrap_or_else(|e| e.into_inner());
        outcomes.sort_by_key(|(index, _)| *index);
        for (index, outcome) in outcomes {
            results[index] = Some(outcome?);
        }
        if results
            .iter()
            .zip(plans)
            .any(|(r, p)| matches!(p, Plan::Parse(_)) && r.is_none())
        {
            // A worker stopped early after another failed; the failure was returned above, so this is
            // only reachable through cancellation.
            return Err(ScanError::Cancelled);
        }
        Ok(results)
    }

    fn parse_file(
        &self,
        file: &DiscoveredFile,
        base: Option<&Cached<P>>,
        cancel: &CancelToken,
    ) -> Result<Parsed<P>, ScanError> {
        cancel.check().map_err(|_| ScanError::Cancelled)?;
        let read_err = |error| ScanError::Read {
            path: file.path.clone(),
            error,
        };
        if file.is_zstd() {
            return self.parse_zstd(file, cancel);
        }
        let resume = match base {
            Some(base) if self.can_append(file, base) => Some(base),
            _ => None,
        };
        let (start, mut state) = match resume {
            Some(base) => (base.committed_end, base.state.clone()),
            None => (0, P::State::default()),
        };
        let mut items = Vec::new();
        let mut failure: Option<ScanError> = None;
        let summary = reader::read_lines(&file.path, start, file.revision.size, |line| {
            if cancel.is_cancelled() {
                failure = Some(ScanError::Cancelled);
                return false;
            }
            if !self.parser.wants(line) {
                return true;
            }
            match self.parser.parse(&mut state, line, &mut items) {
                Ok(()) => true,
                Err(LineError(reason)) => {
                    failure = Some(ScanError::Malformed {
                        path: file.path.clone(),
                        reason,
                    });
                    false
                }
            }
        })
        .map_err(read_err)?;
        if let Some(failure) = failure {
            return Err(failure);
        }
        // The trailing unterminated line: its rows are provisional and its state is discarded. If it
        // does not parse yet, a writer is mid-line; it is re-read once the newline lands.
        let mut fragment = Vec::new();
        if !summary.fragment.is_empty() && self.parser.wants(&summary.fragment) {
            let mut scratch = state.clone();
            if self
                .parser
                .parse(&mut scratch, &summary.fragment, &mut fragment)
                .is_err()
            {
                fragment.clear();
                qlog!(
                    Debug,
                    "scan",
                    "{}: trailing line is incomplete; it is re-read on the next scan",
                    file_label(&file.path)
                );
            }
        }
        // Only append-only growth may follow the read: the bytes we parsed must still be the file's.
        let after = Revision::read(&file.path).map_err(read_err)?;
        if !after.same_file(&file.revision) || after.size < file.revision.size {
            return Err(ScanError::Changed {
                path: file.path.clone(),
            });
        }
        let anchor = reader::prefix_anchor(&file.path, summary.committed_end).map_err(read_err)?;
        let latest_committed = max_opt(
            resume.and_then(|b| b.latest_committed),
            self.latest_of(&items),
        );
        let latest_fragment = self.latest_of(&fragment);
        let items = match resume {
            Some(base) if !items.is_empty() => {
                let mut merged = Vec::with_capacity(base.items.len() + items.len());
                merged.extend(base.items.iter().cloned());
                merged.extend(items);
                Arc::new(merged)
            }
            Some(base) => base.items.clone(),
            None => Arc::new(items),
        };
        Ok(Parsed {
            cached: Cached {
                revision: file.revision,
                committed_end: summary.committed_end,
                fragment_len: summary.fragment.len() as u64,
                anchor: Some(anchor),
                state,
                items,
                fragment: Arc::new(fragment),
                latest_committed,
                latest_fragment,
            },
            appended: resume.is_some(),
            bytes_read: summary.bytes_read,
        })
    }

    /// The cached prefix still describes the file: same inode, grown (never shrunk or same-size
    /// rewritten), and the sampled signature of the parsed bytes is unchanged.
    fn can_append(&self, file: &DiscoveredFile, base: &Cached<P>) -> bool {
        let Some(anchor) = base.anchor else {
            return false;
        };
        base.revision.same_file(&file.revision)
            && file.revision.size > base.revision.size
            && base.committed_end <= file.revision.size
            && reader::prefix_anchor(&file.path, base.committed_end).is_ok_and(|now| now == anchor)
    }

    fn parse_zstd(
        &self,
        file: &DiscoveredFile,
        cancel: &CancelToken,
    ) -> Result<Parsed<P>, ScanError> {
        let mut state = P::State::default();
        let mut items = Vec::new();
        let mut failure = None;
        let bytes_read = reader::read_zstd_lines(&file.path, |line| {
            if cancel.is_cancelled() {
                failure = Some(ScanError::Cancelled);
                return false;
            }
            if !self.parser.wants(line) {
                return true;
            }
            match self.parser.parse(&mut state, line, &mut items) {
                Ok(()) => true,
                Err(LineError(reason)) => {
                    failure = Some(ScanError::Malformed {
                        path: file.path.clone(),
                        reason,
                    });
                    false
                }
            }
        })
        .map_err(|error| ScanError::Read {
            path: file.path.clone(),
            error,
        })?;
        if let Some(failure) = failure {
            return Err(failure);
        }
        Ok(Parsed {
            cached: Cached {
                revision: file.revision,
                committed_end: file.revision.size,
                fragment_len: 0,
                anchor: None,
                latest_committed: self.latest_of(&items),
                latest_fragment: None,
                state,
                items: Arc::new(items),
                fragment: Arc::new(Vec::new()),
            },
            appended: false,
            bytes_read,
        })
    }

    fn encode(&self, path: &Path, cached: &Cached<P>) -> StoredFile {
        StoredFile {
            path: path.to_string_lossy().into_owned(),
            revision: cached.revision,
            committed_end: cached.committed_end,
            fragment_len: cached.fragment_len,
            anchor: cached.anchor,
            state: codec::to_bytes(&cached.state),
            items: codec::seq_to_bytes(&cached.items),
            fragment_items: codec::seq_to_bytes(&cached.fragment),
        }
    }

    fn load_from_store(&self) -> HashMap<PathBuf, Cached<P>> {
        let Some(store) = self.store else {
            return HashMap::new();
        };
        let rows = store.load_partition(&self.partition, P::LAYOUT);
        let mut files = HashMap::with_capacity(rows.len());
        let mut corrupt = 0usize;
        for row in rows {
            let decoded = (|| {
                let items: Vec<P::Item> = codec::seq_from_bytes(&row.items)?;
                let fragment: Vec<P::Item> = codec::seq_from_bytes(&row.fragment_items)?;
                Some(Cached::<P> {
                    revision: row.revision,
                    committed_end: row.committed_end,
                    fragment_len: row.fragment_len,
                    anchor: row.anchor,
                    state: codec::from_bytes(&row.state)?,
                    latest_committed: self.latest_of(&items),
                    latest_fragment: self.latest_of(&fragment),
                    items: Arc::new(items),
                    fragment: Arc::new(fragment),
                })
            })();
            match decoded {
                Some(cached) => {
                    files.insert(PathBuf::from(row.path), cached);
                }
                None => corrupt += 1,
            }
        }
        if corrupt > 0 {
            qlog!(
                Warn,
                "scan-cache",
                "{}: {corrupt} cached file record(s) were unreadable and will be re-parsed",
                self.partition
            );
        }
        files
    }
}

impl<P: LineParser> IncrementalScanner<P> {
    fn latest_of(&self, items: &[P::Item]) -> Option<f64> {
        items
            .iter()
            .filter_map(|i| self.parser.contributing_timestamp(i))
            .reduce(f64::max)
    }
}

fn max_opt(a: Option<f64>, b: Option<f64>) -> Option<f64> {
    match (a, b) {
        (Some(a), Some(b)) => Some(a.max(b)),
        (a, None) => a,
        (None, b) => b,
    }
}

struct Parsed<P: LineParser> {
    cached: Cached<P>,
    appended: bool,
    bytes_read: u64,
}

#[cfg(test)]
#[path = "incremental_tests.rs"]
mod tests;
