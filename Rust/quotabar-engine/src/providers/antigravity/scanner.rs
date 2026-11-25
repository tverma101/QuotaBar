//! Antigravity local conversation accounting (`Providers/Antigravity/AntigravityDbUsageScanner`).
//!
//! The IDE stores each generation's opaque protobuf in `gen_metadata`. We decode only the token
//! fields (see [`super::proto`]), attribute each generation to a local day, price it through the
//! shared engine, and keep a small revision-keyed fold cache so an unchanged database is not
//! decoded again on every panel-open pass.

use super::proto::{self, GenerationEvent, StepIdentity};
use crate::accounting::{DailyUsageAccumulator, LogUsageScan};
use crate::context::CancelToken;
use crate::host;
use crate::pricing::{ModelPricing, TokenBreakdown};
use crate::qlog;
use rusqlite::{params, Connection, OpenFlags};
use std::collections::{HashMap, HashSet, VecDeque};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::UNIX_EPOCH;

pub const MAXIMUM_BLOB_BYTES: i64 = 1_048_576;
const BATCH_SIZE: i64 = 256;
const CACHE_BYTES: usize = 8 * 1024 * 1024;
/// Antigravity creates one database per conversation. Real installations routinely exceed 64,
/// so the old count cap evicted every entry before the next pass and re-decoded all of them; the
/// byte budget is the real bound. Keep a high count cap for zero-byte databases only.
const CACHE_DATABASES: usize = 1_024;

#[derive(Clone, PartialEq, Eq)]
struct FileRevision {
    length: u64,
    modified_nanos: u128,
}

impl FileRevision {
    fn read(path: &Path) -> Option<Self> {
        let metadata = fs::metadata(path).ok()?;
        let modified = metadata.modified().ok()?.duration_since(UNIX_EPOCH).ok()?;
        Some(FileRevision {
            length: metadata.len(),
            modified_nanos: modified.as_nanos(),
        })
    }
}

#[derive(Clone, PartialEq, Eq)]
struct DatabaseRevision {
    main: FileRevision,
    wal: Option<FileRevision>,
}

impl DatabaseRevision {
    fn read(path: &Path) -> Option<Self> {
        let main = FileRevision::read(path)?;
        let mut wal_path = path.as_os_str().to_owned();
        wal_path.push("-wal");
        let wal = FileRevision::read(Path::new(&wal_path));
        Some(DatabaseRevision { main, wal })
    }
}

#[derive(Clone)]
struct CachedFold {
    revision: DatabaseRevision,
    events: Arc<[GenerationEvent]>,
    bytes: usize,
}

#[derive(Default)]
struct FoldCache {
    entries: VecDeque<CachedFold>,
    bytes: usize,
}

impl FoldCache {
    fn get(&mut self, revision: &DatabaseRevision) -> Option<Arc<[GenerationEvent]>> {
        let index = self
            .entries
            .iter()
            .position(|entry| &entry.revision == revision)?;
        let entry = self.entries.remove(index)?;
        let events = Arc::clone(&entry.events);
        self.entries.push_back(entry);
        Some(events)
    }

    fn insert(&mut self, revision: DatabaseRevision, events: Arc<[GenerationEvent]>) {
        let bytes = std::mem::size_of_val(events.as_ref())
            .saturating_add(events.iter().map(|event| event.model.capacity()).sum());
        if bytes > CACHE_BYTES || self.get(&revision).is_some() {
            return;
        }
        while self.entries.len() >= CACHE_DATABASES || self.bytes + bytes > CACHE_BYTES {
            let Some(oldest) = self.entries.pop_front() else {
                break;
            };
            self.bytes = self.bytes.saturating_sub(oldest.bytes);
        }
        self.bytes = self.bytes.saturating_add(bytes);
        self.entries.push_back(CachedFold {
            revision,
            events,
            bytes,
        });
    }

    fn clear(&mut self) {
        self.entries.clear();
        self.bytes = 0;
    }
}

fn folds() -> &'static Mutex<FoldCache> {
    static FOLDS: OnceLock<Mutex<FoldCache>> = OnceLock::new();
    FOLDS.get_or_init(|| Mutex::new(FoldCache::default()))
}

/// One scan's result. `scan == None` with `has_read_failures == true` means the provider should keep
/// the last-good history and surface a lower-bound warning.
#[derive(Clone, Debug, Default)]
pub struct AntigravityScanResult {
    pub scan: Option<LogUsageScan>,
    pub has_read_failures: bool,
}

pub struct AntigravityScanner {
    home: PathBuf,
}

impl AntigravityScanner {
    pub fn live() -> Self {
        AntigravityScanner {
            home: crate::paths::home(),
        }
    }

    pub fn with_home(home: PathBuf) -> Self {
        AntigravityScanner { home }
    }

    pub fn scan(
        &self,
        days_back: usize,
        now: f64,
        pricing: &ModelPricing,
        cancel: &CancelToken,
    ) -> AntigravityScanResult {
        if cancel.is_cancelled() {
            return AntigravityScanResult::default();
        }
        let since = now - (days_back as f64 * 86_400.0);
        let mut read_failures = false;
        let gemini = self.home.join(".gemini");
        let mut dirs = match fs::read_dir(&gemini) {
            Ok(entries) => entries
                .flatten()
                .filter(|entry| {
                    entry
                        .file_name()
                        .to_string_lossy()
                        .starts_with("antigravity")
                })
                .map(|entry| entry.path().join("conversations"))
                .filter(|path| path.is_dir())
                .collect::<Vec<_>>(),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(error) => {
                qlog!(
                    Warn,
                    host::plugin_tag("antigravity"),
                    "conversation roots could not be listed: {error}"
                );
                read_failures = true;
                Vec::new()
            }
        };
        dirs.sort();
        let mut paths = Vec::new();
        for dir in &dirs {
            match database_files(dir) {
                Ok(files) => paths.extend(files),
                Err(error) => {
                    qlog!(
                        Warn,
                        host::plugin_tag("antigravity"),
                        "conversation directory could not be read: {error}"
                    );
                    read_failures = true;
                }
            }
        }
        paths.sort();
        paths.dedup();

        let mut accumulator = DailyUsageAccumulator::new();
        let mut seen = HashSet::new();
        for path in paths {
            if cancel.is_cancelled() {
                return AntigravityScanResult::default();
            }
            let Some(identity) = database_identity(&path) else {
                continue;
            };
            if !seen.insert(identity) {
                continue;
            }
            match self.read_fold(&path, cancel) {
                Some(events) => {
                    for event in events.iter() {
                        accumulate(event, since, pricing, &mut accumulator);
                    }
                }
                None if cancel.is_cancelled() => return AntigravityScanResult::default(),
                None => read_failures = true,
            }
        }
        let scan = accumulator.build();
        AntigravityScanResult {
            scan: (!scan.series.daily.is_empty()).then_some(scan),
            has_read_failures: read_failures,
        }
    }

    fn read_fold(&self, path: &Path, cancel: &CancelToken) -> Option<Arc<[GenerationEvent]>> {
        let revision = DatabaseRevision::read(path)?;
        if let Ok(mut cache) = folds().lock() {
            if let Some(events) = cache.get(&revision) {
                return Some(events);
            }
        }
        if cancel.is_cancelled() {
            return None;
        }
        let (events, oversized) = match read_database(path) {
            Ok(result) => result,
            Err(error) => {
                qlog!(
                    Warn,
                    host::plugin_tag("antigravity"),
                    "conversation database read failed: {error}"
                );
                return None;
            }
        };
        if oversized {
            qlog!(
                Warn,
                host::plugin_tag("antigravity"),
                "generation records larger than {MAXIMUM_BLOB_BYTES} bytes were skipped"
            );
        }
        // Do not cache a fold whose database changed while it was being read; the next pass retries.
        if DatabaseRevision::read(path).as_ref() != Some(&revision) {
            return None;
        }
        let events: Arc<[GenerationEvent]> = events.into();
        if let Ok(mut cache) = folds().lock() {
            cache.insert(revision, Arc::clone(&events));
        }
        Some(events)
    }

    pub fn unload_caches() {
        folds().lock().unwrap_or_else(|e| e.into_inner()).clear();
    }
}

#[derive(Hash, PartialEq, Eq)]
enum DatabaseIdentity {
    #[cfg(unix)]
    Inode(u64, u64),
    #[cfg(not(unix))]
    Path(PathBuf),
}

fn database_identity(path: &Path) -> Option<DatabaseIdentity> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let metadata = fs::metadata(path).ok()?;
        Some(DatabaseIdentity::Inode(metadata.dev(), metadata.ino()))
    }
    #[cfg(not(unix))]
    {
        Some(DatabaseIdentity::Path(
            fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf()),
        ))
    }
}

fn database_files(dir: &Path) -> std::io::Result<Vec<PathBuf>> {
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error),
    };
    let mut paths: Vec<PathBuf> = entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.extension().is_some_and(|extension| extension == "db") && path.is_file()
        })
        .collect();
    paths.sort();
    Ok(paths)
}

fn open_readonly(path: &Path) -> Result<(Connection, bool), rusqlite::Error> {
    match Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY) {
        Ok(connection) => Ok((connection, false)),
        Err(error) => {
            let encoded = path
                .to_string_lossy()
                .replace('%', "%25")
                .replace(' ', "%20");
            let uri = format!("file:{encoded}?immutable=1");
            Connection::open_with_flags(
                &uri,
                OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
            )
            .map(|connection| (connection, true))
            .map_err(|_| error)
        }
    }
}

fn page_sql() -> String {
    format!(
        "SELECT idx, CASE WHEN length(data) <= {MAXIMUM_BLOB_BYTES} THEN data ELSE NULL END AS data \
         FROM gen_metadata WHERE idx > ?1 AND data IS NOT NULL ORDER BY idx LIMIT {BATCH_SIZE}"
    )
}

struct StepIndex {
    by_identity: HashMap<StepIdentity, Option<i64>>,
    legacy_by_index: HashMap<i64, i64>,
}

impl StepIndex {
    fn read(connection: &Connection) -> Result<Option<Self>, rusqlite::Error> {
        let has_steps = connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM pragma_table_info('steps') WHERE name = 'metadata') \
             AND EXISTS(SELECT 1 FROM pragma_table_info('steps') WHERE name = 'idx' AND pk = 1) \
             AND (SELECT COUNT(*) FROM pragma_table_info('steps') WHERE pk > 0) = 1",
            [],
            |row| row.get::<_, bool>(0),
        )?;
        if !has_steps {
            return Ok(None);
        }
        let mut index = StepIndex {
            by_identity: HashMap::new(),
            legacy_by_index: HashMap::new(),
        };
        let sql = format!(
            "SELECT idx, metadata FROM steps WHERE length(metadata) BETWEEN 1 AND {MAXIMUM_BLOB_BYTES} ORDER BY idx"
        );
        let mut statement = connection.prepare(&sql)?;
        let mut rows = statement.query([])?;
        while let Some(row) = rows.next()? {
            let idx: i64 = row.get(0)?;
            let blob = row
                .get_ref(1)?
                .as_blob()
                .map_err(|_| rusqlite::Error::InvalidQuery)?;
            let Some((identity, timestamp)) = proto::step_identity_timestamp(blob) else {
                continue;
            };
            if identity.uuid.is_none() && identity.bot_id.is_none() {
                index.legacy_by_index.insert(idx, timestamp);
            } else {
                index
                    .by_identity
                    .entry(identity)
                    .and_modify(|slot| {
                        *slot = match *slot {
                            Some(previous) => Some(previous.min(timestamp)),
                            None => None,
                        };
                    })
                    .or_insert(Some(timestamp));
            }
        }
        Ok(Some(index))
    }

    fn timestamp(&self, idx: i64, blob: &[u8]) -> Option<i64> {
        let identity = proto::generation_identity(blob)?;
        if identity.uuid.is_none() && identity.bot_id.is_none() {
            self.legacy_by_index.get(&idx).copied()
        } else {
            self.by_identity.get(&identity).copied().flatten()
        }
    }
}

fn read_database(path: &Path) -> Result<(Vec<GenerationEvent>, bool), rusqlite::Error> {
    let (connection, _immutable) = open_readonly(path)?;
    let transaction = connection.unchecked_transaction()?;
    let steps = StepIndex::read(&transaction)?;
    let sql = page_sql();
    let mut statement = transaction.prepare(&sql)?;
    let mut last_index: i64 = -1;
    let mut events = Vec::new();
    let mut oversized = false;
    loop {
        let rows = statement.query_map(params![last_index], |row| {
            let idx: i64 = row.get(0)?;
            let data: Option<Vec<u8>> = row.get(1)?;
            Ok((idx, data))
        })?;
        let batch: Vec<(i64, Option<Vec<u8>>)> = rows.collect::<Result<_, _>>()?;
        if batch.is_empty() {
            break;
        }
        let count = batch.len();
        let mut stalled = false;
        for (idx, data) in batch {
            if idx <= last_index {
                stalled = true;
                break;
            }
            last_index = idx;
            let Some(blob) = data else {
                oversized = true;
                continue;
            };
            if let Some(event) = proto::generation_event_with_timestamp(&blob, || {
                steps.as_ref()?.timestamp(idx, &blob)
            }) {
                events.push(event);
            }
        }
        if stalled || count < BATCH_SIZE as usize {
            break;
        }
    }
    Ok((events, oversized))
}

fn accumulate(
    event: &GenerationEvent,
    since: f64,
    pricing: &ModelPricing,
    accumulator: &mut DailyUsageAccumulator,
) {
    if (event.timestamp_seconds as f64) < since {
        return;
    }
    let input_and_cached = event.input_tokens.checked_add(event.cache_read_tokens);
    let total = input_and_cached.and_then(|value| value.checked_add(event.output_tokens));
    let Some(total) = total.filter(|&value| value > 0) else {
        return;
    };
    let day = &event.day;
    let tokens = TokenBreakdown {
        input: event.input_tokens,
        cache_read: event.cache_read_tokens,
        output: event.output_tokens,
        ..Default::default()
    };
    let estimate = pricing.estimated_cost_dollars(
        &event.model,
        &tokens,
        Some(event.timestamp_seconds as f64),
        true,
    );
    accumulator.record_api_estimate(day, estimate, total);
    match estimate {
        Some(cost) => accumulator.add(day, total, Some(cost), &event.model),
        None => {
            accumulator.add_unknown_model(day, &event.model);
            accumulator.add(day, total, None, &event.model);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pricing::{ModelRates, PricingCatalog, PricingSupplement};
    use tempfile::TempDir;

    fn pricing() -> ModelPricing {
        let mut entries = HashMap::new();
        entries.insert(
            "gemini-2.5-flash".to_string(),
            ModelRates::new(1.0, 2.0, 1.0, 0.1),
        );
        ModelPricing::new(
            PricingSupplement::default(),
            PricingCatalog::from_entries(entries),
            PricingCatalog::default(),
            PricingCatalog::default(),
            None,
        )
    }

    fn seed(path: &Path, rows: &[(i64, Option<Vec<u8>>)]) {
        let connection = Connection::open(path).unwrap();
        connection
            .execute(
                "CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB)",
                [],
            )
            .unwrap();
        for (idx, data) in rows {
            connection
                .execute(
                    "INSERT INTO gen_metadata (idx, data) VALUES (?1, ?2)",
                    params![idx, data],
                )
                .unwrap();
        }
    }

    #[test]
    fn scans_generation_blobs_with_pricing_and_unknown_models() {
        let dir = TempDir::new().unwrap();
        let conversations = dir.path().join(".gemini/antigravity/conversations");
        fs::create_dir_all(&conversations).unwrap();
        let database = conversations.join("session.db");
        let timestamp = 1_800_000_000u64;
        seed(
            &database,
            &[
                (
                    1,
                    Some(proto::encode_generation_blob(
                        "gemini-2.5-flash",
                        10,
                        20,
                        7,
                        3,
                        timestamp,
                    )),
                ),
                (
                    2,
                    Some(proto::encode_generation_blob(
                        "mystery-model",
                        0,
                        5,
                        1,
                        0,
                        timestamp,
                    )),
                ),
                (3, None),
            ],
        );
        let scanner = AntigravityScanner::with_home(dir.path().to_path_buf());
        let result = scanner.scan(30, timestamp as f64 + 60.0, &pricing(), &CancelToken::new());
        assert!(!result.has_read_failures);
        let scan = result.scan.expect("scan");
        assert_eq!(scan.series.daily.len(), 1);
        assert_eq!(scan.series.daily[0].total_tokens, 46);
        assert!(scan.series.daily[0].cost_usd.unwrap() > 0.0);
        assert_eq!(
            scan.unknown_models_by_day
                .values()
                .flatten()
                .next()
                .map(String::as_str),
            Some("mystery-model")
        );

        // A second scan reuses the fold cache; the result stays identical.
        let again = scanner.scan(30, timestamp as f64 + 60.0, &pricing(), &CancelToken::new());
        assert_eq!(again.scan.unwrap().series, scan.series);
        AntigravityScanner::unload_caches();
    }

    #[test]
    fn missing_roots_are_empty_not_failures_and_broken_database_is_a_failure() {
        let dir = TempDir::new().unwrap();
        let scanner = AntigravityScanner::with_home(dir.path().to_path_buf());
        let empty = scanner.scan(
            30,
            1_800_000_000.0,
            &ModelPricing::default(),
            &CancelToken::new(),
        );
        assert!(empty.scan.is_none());
        assert!(!empty.has_read_failures);

        let conversations = dir.path().join(".gemini/antigravity/conversations");
        fs::create_dir_all(&conversations).unwrap();
        fs::write(conversations.join("broken.db"), b"not sqlite").unwrap();
        let broken = scanner.scan(
            30,
            1_800_000_000.0,
            &ModelPricing::default(),
            &CancelToken::new(),
        );
        assert!(broken.scan.is_none());
        assert!(broken.has_read_failures);
    }
}
