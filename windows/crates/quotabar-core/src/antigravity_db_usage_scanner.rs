//! Reads token accounting from Antigravity local conversation SQLite DBs
//! (`~/.gemini/antigravity*/conversations/*.db`).
//! Discovered by FelixIsaac in openusage#1058/#1120.

use crate::antigravity_proto::{self, GenerationEvent, StepIdentity};
use crate::log_usage_types::{
    DailyUsageRow, LogScanStatus, ModelDayUsage, TokenBreakdown, expand_tilde, host_query_response,
    local_day_key_from_offset, since_local_midnight, warn_unreadable_usage_file,
};
use crate::model_pricing::{ModelPricing, default_pricing};
use chrono::{DateTime, Local, NaiveDate, Utc};
use rusqlite::{Connection, OpenFlags, params};
use same_file::Handle;
use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::fs;
use std::io::{self, Read, Seek};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::SystemTime;
use sha2::{Digest, Sha256};

#[path = "antigravity_history_checkpoint.rs"]
mod checkpoint;

pub const MAXIMUM_BLOB_BYTES: i64 = 1_048_576;
const BATCH_SIZE: i64 = 8;
const CACHE_BYTES: usize = 8 * 1024 * 1024;
const CACHE_DATABASES: usize = 64;

static WARNED_OVERSIZED: Mutex<Option<HashSet<String>>> = Mutex::new(None);
static FOLDS: Mutex<FoldCache> = Mutex::new(FoldCache {
    entries: VecDeque::new(),
    bytes: 0,
});

#[derive(PartialEq, Eq)]
struct FileRevision {
    identity: Arc<Handle>,
    bytes: u64,
    modified_at: SystemTime,
}

impl FileRevision {
    fn read(path: &Path) -> io::Result<Self> {
        let identity = Arc::new(Handle::from_file(fs::File::open(path)?)?);
        let metadata = identity.as_file().metadata()?;
        Ok(Self {
            identity,
            bytes: metadata.len(),
            modified_at: metadata.modified()?,
        })
    }
}

#[derive(PartialEq, Eq)]
struct DatabaseRevision {
    main: FileRevision,
    wal: Option<FileRevision>,
}

impl DatabaseRevision {
    fn read(path: &Path) -> io::Result<Self> {
        let main = FileRevision::read(path)?;
        let mut wal_path = path.as_os_str().to_owned();
        wal_path.push("-wal");
        let wal = match FileRevision::read(Path::new(&wal_path)) {
            Ok(wal) => Some(wal),
            Err(e) if e.kind() == io::ErrorKind::NotFound => None,
            Err(e) => return Err(e),
        };
        Ok(Self { main, wal })
    }

    fn digest(&self) -> Option<Vec<u8>> {
        const MAX_SOURCE_BYTES: u64 = 8 * 1024 * 1024;
        if self.main.bytes.saturating_add(self.wal.as_ref().map_or(0, |wal| wal.bytes))
            > MAX_SOURCE_BYTES
        {
            return None;
        }
        let mut hash = Sha256::new();
        for revision in [&self.main].into_iter().chain(self.wal.iter()) {
            let mut f = revision.identity.as_file();
            f.rewind().ok()?;
            hash.update(revision.bytes.to_le_bytes());
            let mut reader = f.take(revision.bytes + 1);
            let mut buf = [0; 8192];
            let mut bytes = 0;
            loop {
                let n = reader.read(&mut buf).ok()?;
                if n == 0 {
                    break;
                }
                hash.update(&buf[..n]);
                bytes += n as u64;
            }
            if bytes != revision.bytes {
                return None;
            }
        }
        Some(hash.finalize().to_vec())
    }
}

struct CachedFold {
    revision: DatabaseRevision,
    zone: Option<String>,
    events: Arc<[GenerationEvent]>,
    bytes: usize,
}

struct FoldCache {
    entries: VecDeque<CachedFold>,
    bytes: usize,
}

impl FoldCache {
    fn get(&mut self, revision: &DatabaseRevision, zone: Option<&str>) -> Option<Arc<[GenerationEvent]>> {
        let index = self
            .entries
            .iter()
            .position(|entry| &entry.revision == revision && entry.zone.as_deref() == zone)?;
        let entry = self.entries.remove(index)?;
        let events = Arc::clone(&entry.events);
        self.entries.push_back(entry);
        Some(events)
    }

    fn insert(&mut self, revision: DatabaseRevision, zone: Option<String>, events: Arc<[GenerationEvent]>) {
        let bytes = std::mem::size_of_val(events.as_ref())
            .saturating_add(events.iter().map(|event| event.model.capacity()).sum());
        if bytes > CACHE_BYTES || self.get(&revision, zone.as_deref()).is_some() {
            return;
        }
        if let Some(index) = self
            .entries
            .iter()
            .position(|entry| entry.revision.main.identity == revision.main.identity)
        {
            self.bytes -= self.entries.remove(index).expect("located cached fold").bytes;
        }
        while self.entries.len() >= CACHE_DATABASES || self.bytes + bytes > CACHE_BYTES {
            self.bytes -= self.entries.pop_front().expect("cache is over budget").bytes;
        }
        self.bytes += bytes;
        self.entries.push_back(CachedFold {
            revision,
            zone,
            events,
            bytes,
        });
    }
}

pub fn query_daily_since(
    since_compact: &str,
    home_path: Option<&str>,
) -> (LogScanStatus, Vec<DailyUsageRow>) {
    query_daily(since_compact, home_path, None)
}

fn query_daily(
    since_compact: &str,
    home_path: Option<&str>,
    checkpoint: Option<&Path>,
) -> (LogScanStatus, Vec<DailyUsageRow>) {
    let since = parse_since(since_compact);
    let pricing = default_pricing();
    let rows = scan(days_back_from_since(since), home_path, pricing, checkpoint).unwrap_or_default();
    if rows.is_empty() {
        (LogScanStatus::NoData, vec![])
    } else {
        (LogScanStatus::Ok, rows)
    }
}

pub fn query_daily_host_json(opts_json: &str, checkpoint: &Path) -> String {
    let v: serde_json::Value = serde_json::from_str(opts_json).unwrap_or(serde_json::json!({}));
    let since = v.get("since").and_then(|s| s.as_str()).unwrap_or("");
    let home_path = v.get("homePath").and_then(|s| s.as_str());
    let (status, daily) = query_daily(since, home_path, Some(checkpoint));
    host_query_response(status, daily)
}

fn parse_since(since: &str) -> DateTime<Utc> {
    let digits: String = since.chars().filter(|c| c.is_ascii_digit()).collect();
    if digits.len() >= 8 {
        if let (Ok(y), Ok(m), Ok(d)) = (
            digits[0..4].parse::<i32>(),
            digits[4..6].parse::<u32>(),
            digits[6..8].parse::<u32>(),
        ) {
            if let Some(date) = NaiveDate::from_ymd_opt(y, m, d) {
                return date.and_hms_opt(0, 0, 0).expect("midnight").and_utc();
            }
        }
    }
    since_local_midnight(30)
}

fn days_back_from_since(since: DateTime<Utc>) -> i32 {
    let now = Utc::now();
    ((now.date_naive() - since.date_naive()).num_days().max(0) + 1) as i32
}

fn conversations_dirs(home_path: Option<&str>) -> Vec<PathBuf> {
    let home = match home_path {
        Some(p) => expand_tilde(p),
        None => dirs::home_dir().unwrap_or_else(|| PathBuf::from(".")),
    };
    let mut dirs: Vec<PathBuf> = Vec::new();
    if let Ok(entries) = fs::read_dir(home.join(".gemini")) {
        dirs.extend(
            entries
                .flatten()
                .filter(|e| {
                    e.file_name()
                        .to_string_lossy()
                        .starts_with("antigravity")
                        && e.path().is_dir()
                })
                .map(|e| e.path().join("conversations")),
        );
    }
    // The XDG location some Antigravity clients use.
    let xdg = home.join(".config").join("antigravity").join("conversations");
    if xdg.is_dir() {
        dirs.push(xdg);
    }
    // T3 Code runs Antigravity through its ACP adapter with a private home per instance, so that
    // usage never appears under ~/.gemini. Listing these directories reads no credentials.
    if let Ok(entries) = fs::read_dir(home.join(".t3").join("userdata").join("providers").join("antigravity")) {
        dirs.extend(
            entries
                .flatten()
                .map(|e| e.path().join("antigravity-acp").join("conversations"))
                .filter(|path| path.is_dir()),
        );
    }
    dirs.sort();
    dirs.dedup();
    dirs
}

fn scan(
    days_back: i32,
    home_path: Option<&str>,
    pricing: &ModelPricing,
    checkpoint: Option<&Path>,
) -> Option<Vec<DailyUsageRow>> {
    let dirs = conversations_dirs(home_path);
    let mut paths = Vec::new();
    for dir in &dirs {
        match database_files(dir) {
            Ok(p) => paths.extend(p),
            Err(_) => warn_unreadable_usage_file(dir),
        }
    }
    if paths.is_empty() {
        return None;
    }
    let since = since_local_midnight(days_back);
    let mut folds = Vec::new();
    let mut identities = HashSet::new();
    let zone = iana_time_zone::get_timezone().ok();
    let checkpoint = checkpoint.and_then(checkpoint::open);
    for path in &paths {
        if let Some(events) = read_fold(path, &mut identities, zone.as_deref(), checkpoint.as_ref()) {
            folds.push(events);
        }
    }
    let rows = aggregate(folds.iter().flat_map(|fold| fold.iter()), since, pricing);
    if rows.is_empty() { None } else { Some(rows) }
}

fn read_fold(
    path: &Path,
    identities: &mut HashSet<Arc<Handle>>,
    zone: Option<&str>,
    checkpoint: Option<&Connection>,
) -> Option<Arc<[GenerationEvent]>> {
    let before = DatabaseRevision::read(path).ok();
    if let Some(revision) = &before {
        if identities.contains(&revision.main.identity) {
            return None;
        }
        if let Some(events) = FOLDS.lock().ok().and_then(|mut cache| cache.get(revision, zone)) {
            identities.insert(Arc::clone(&revision.main.identity));
            return Some(events);
        }
    }
    let disk = (|| {
        let conn = checkpoint?;
        let zone = zone?;
        let path_key = path.canonicalize().ok()?.into_os_string().into_string().ok()?;
        Some((conn, zone, path_key, before.as_ref()?.digest()?))
    })();
    if let (Some((conn, zone, key, digest)), Some(revision)) = (&disk, &before) {
        if let Some(events) = checkpoint::load(conn, key, zone, digest) {
            if DatabaseRevision::read(path).ok().as_ref() == Some(revision) {
                identities.insert(Arc::clone(&revision.main.identity));
                let events = Arc::from(events);
                if let (Ok(mut cache), Some(revision)) = (FOLDS.lock(), before) {
                    cache.insert(revision, Some(zone.to_string()), Arc::clone(&events));
                }
                return Some(events);
            }
            return None;
        }
    }
    let (events, oversized, immutable) = match read_database(path) {
        Ok(result) => result,
        Err(_) => {
            warn_unreadable_usage_file(path);
            return None;
        }
    };
    if oversized {
        warn_oversized(path);
    }
    let events: Arc<[GenerationEvent]> = events.into();
    if let Some(before) = before {
        let Ok(after) = DatabaseRevision::read(path) else {
            return None;
        };
        if before.main.identity != after.main.identity {
            return None;
        }
        identities.insert(Arc::clone(&before.main.identity));
        if !oversized && !immutable && before == after {
            if let Some((conn, zone, key, digest)) = disk {
                if after.digest().as_ref() == Some(&digest) {
                    checkpoint::save(conn, &key, zone, &digest, &events);
                }
            }
            if let Ok(mut cache) = FOLDS.lock() {
                cache.insert(before, zone.map(str::to_owned), Arc::clone(&events));
            }
        }
    }
    Some(events)
}

fn database_files(dir: &Path) -> Result<Vec<PathBuf>, std::io::Error> {
    let entries = match fs::read_dir(dir) {
        Ok(e) => e,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(vec![]),
        Err(e) => return Err(e),
    };
    let mut paths: Vec<PathBuf> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|ext| ext == "db") && p.is_file())
        .collect();
    paths.sort();
    Ok(paths)
}

fn open_readonly(path: &Path) -> Result<(Connection, bool), rusqlite::Error> {
    match Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY) {
        Ok(c) => Ok((c, false)),
        Err(e) => {
            let encoded = path
                .to_string_lossy()
                .replace('%', "%25")
                .replace(' ', "%20");
            let uri = format!("file:{encoded}?immutable=1");
            Connection::open_with_flags(
                &uri,
                OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
            )
            .map(|c| (c, true))
            .map_err(|_| e)
        }
    }
}

/// `CASE` skips blobs larger than 1 MiB before SQLite materializes them into the row.
fn page_sql() -> String {
    format!(
        "SELECT idx, CASE WHEN length(data) <= {MAXIMUM_BLOB_BYTES} THEN data ELSE NULL END AS data \
         FROM gen_metadata WHERE idx > ?1 AND data IS NOT NULL ORDER BY idx LIMIT {BATCH_SIZE}"
    )
}

struct StepIndex {
    by_identity: HashMap<StepIdentity, Option<(NaiveDate, i64)>>,
    legacy_by_index: HashMap<i64, i64>,
}

impl StepIndex {
    fn read(conn: &Connection) -> Result<Option<Self>, rusqlite::Error> {
        let has_steps = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM pragma_table_info('steps') WHERE name = 'metadata')
                AND EXISTS(SELECT 1 FROM pragma_table_info('steps') WHERE name = 'idx' AND pk = 1)
                AND (SELECT COUNT(*) FROM pragma_table_info('steps') WHERE pk > 0) = 1",
            [],
            |row| row.get::<_, bool>(0),
        )?;
        if !has_steps {
            return Ok(None);
        }
        let mut result = Self { by_identity: HashMap::new(), legacy_by_index: HashMap::new() };
        let sql = format!(
            "SELECT idx, metadata FROM steps
             WHERE length(metadata) BETWEEN 1 AND {MAXIMUM_BLOB_BYTES} ORDER BY idx"
        );
        let mut stmt = conn.prepare(&sql)?;
        let mut rows = stmt.query([])?;
        let mut estimated = 0;
        while let Some(row) = rows.next()? {
            let idx = row.get(0)?;
            let blob = row.get_ref(1)?.as_blob().map_err(|_| rusqlite::Error::InvalidQuery)?;
            let Some((identity, timestamp)) = antigravity_proto::step_identity_timestamp(blob) else {
                continue;
            };
            let Some(date) = DateTime::from_timestamp(timestamp, 0) else {
                continue;
            };
            if identity.uuid.is_none() && identity.bot_id.is_none() {
                estimated += 64;
                result.legacy_by_index.insert(idx, timestamp);
            } else {
                let day = date.with_timezone(&Local).date_naive();
                match result.by_identity.entry(identity) {
                    std::collections::hash_map::Entry::Vacant(slot) => {
                        estimated += 256
                            + slot.key().uuid.as_ref().map_or(0, String::capacity)
                            + slot.key().bot_id.as_ref().map_or(0, String::capacity);
                        slot.insert(Some((day, timestamp)));
                    }
                    std::collections::hash_map::Entry::Occupied(mut slot) => {
                        if let Some((previous_day, previous_stamp)) = *slot.get() {
                            slot.insert((day == previous_day).then_some((day, timestamp.min(previous_stamp))));
                        }
                    }
                }
            }
            if estimated > CACHE_BYTES {
                log::warn!("[antigravity] Step timestamp index exceeded its history memory budget");
                return Ok(None);
            }
        }
        Ok(Some(result))
    }

    fn timestamp(&self, idx: i64, blob: &[u8]) -> Option<i64> {
        let identity = antigravity_proto::generation_identity(blob)?;
        if identity.uuid.is_none() && identity.bot_id.is_none() {
            self.legacy_by_index.get(&idx).copied()
        } else {
            self.by_identity.get(&identity).copied().flatten().map(|(_, stamp)| stamp)
        }
    }
}

fn read_database(path: &Path) -> Result<(Vec<GenerationEvent>, bool, bool), rusqlite::Error> {
    let (conn, immutable) = open_readonly(path)?;
    let tx = conn.unchecked_transaction()?;
    let steps = StepIndex::read(&tx)?;
    let sql = page_sql();
    let mut stmt = tx.prepare(&sql)?;
    let mut last_index: i64 = -1;
    let mut events = Vec::new();
    let mut oversized = false;
    loop {
        let rows = stmt.query_map(params![last_index], |row| {
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
            if let Some(event) = antigravity_proto::generation_event_with_timestamp(&blob, || {
                steps.as_ref()?.timestamp(idx, &blob)
            }) {
                events.push(event);
            }
        }
        if stalled || count < BATCH_SIZE as usize {
            break;
        }
    }
    Ok((events, oversized, immutable))
}

fn warn_oversized(path: &Path) {
    let key = path.to_string_lossy().to_string();
    let Ok(mut guard) = WARNED_OVERSIZED.lock() else {
        return;
    };
    let set = guard.get_or_insert_with(HashSet::new);
    if set.insert(key.clone()) {
        log::warn!("generation records larger than {MAXIMUM_BLOB_BYTES} bytes skipped in {key}");
    }
}

fn i32_tokens(n: i64) -> Option<i32> {
    i32::try_from(n).ok().filter(|&v| v >= 0)
}

fn aggregate<'a>(
    events: impl IntoIterator<Item = &'a GenerationEvent>,
    since: DateTime<Utc>,
    pricing: &ModelPricing,
) -> Vec<DailyUsageRow> {
    let mut tokens_by_day: BTreeMap<String, i32> = BTreeMap::new();
    let mut cost_by_day: BTreeMap<String, f64> = BTreeMap::new();
    let mut models_by_day: BTreeMap<String, BTreeMap<String, (i32, f64)>> = BTreeMap::new();
    let mut input_by_day: BTreeMap<String, i32> = BTreeMap::new();
    let mut output_by_day: BTreeMap<String, i32> = BTreeMap::new();
    let mut cache_read_by_day: BTreeMap<String, i32> = BTreeMap::new();

    for event in events {
        let Some(ts) = DateTime::<Utc>::from_timestamp(event.timestamp_seconds, 0) else {
            continue;
        };
        if ts < since {
            continue;
        }
        let Some(input) = i32_tokens(event.input_tokens) else {
            continue;
        };
        let Some(output) = i32_tokens(event.output_tokens) else {
            continue;
        };
        let Some(cache_read) = i32_tokens(event.cache_read_tokens) else {
            continue;
        };
        let Some(total) = input
            .checked_add(cache_read)
            .and_then(|v| v.checked_add(output))
        else {
            continue;
        };
        if total <= 0 {
            continue;
        }
        let tokens = TokenBreakdown {
            input,
            cache_write5m: 0,
            cache_write1h: 0,
            cache_read,
            output,
            is_fast: false,
        };
        let Some(cost) = pricing.estimated_cost_dollars_at(&event.model, &tokens, ts.with_timezone(&Utc)) else {
            continue;
        };
        let day = local_day_key_from_offset(&ts);
        *tokens_by_day.entry(day.clone()).or_default() += total;
        *cost_by_day.entry(day.clone()).or_default() += cost;
        *input_by_day.entry(day.clone()).or_default() += input;
        *output_by_day.entry(day.clone()).or_default() += output;
        *cache_read_by_day.entry(day.clone()).or_default() += cache_read;
        let slot = models_by_day.entry(day).or_default();
        let e = slot.entry(event.model.clone()).or_insert((0, 0.0));
        e.0 += total;
        e.1 += cost;
    }

    tokens_by_day
        .keys()
        .rev()
        .cloned()
        .map(|day| {
            let total_cost = cost_by_day.get(&day).copied();
            let models: BTreeMap<String, ModelDayUsage> = models_by_day
                .get(&day)
                .map(|m| {
                    m.iter()
                        .map(|(name, (tokens, cost))| {
                            (
                                name.clone(),
                                ModelDayUsage {
                                    input_tokens: 0,
                                    output_tokens: *tokens,
                                    cache_creation_tokens: 0,
                                    cache_read_tokens: 0,
                                    total_tokens: *tokens,
                                    total_cost: Some(*cost),
                                },
                            )
                        })
                        .collect()
                })
                .unwrap_or_default();
            DailyUsageRow {
                date: day.clone(),
                input_tokens: *input_by_day.get(&day).unwrap_or(&0),
                output_tokens: *output_by_day.get(&day).unwrap_or(&0),
                cache_creation_tokens: 0,
                cache_read_tokens: *cache_read_by_day.get(&day).unwrap_or(&0),
                total_tokens: *tokens_by_day.get(&day).unwrap_or(&0),
                total_cost,
                cost_usd: total_cost,
                models,
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::antigravity_proto::encode_generation_blob;
    use rusqlite::Connection;
    use tempfile::TempDir;

    fn seed_db(path: &Path, rows: &[(i64, Option<Vec<u8>>)]) {
        let conn = Connection::open(path).unwrap();
        conn.execute(
            "CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB)",
            [],
        )
        .unwrap();
        for (idx, data) in rows {
            conn.execute(
                "INSERT INTO gen_metadata (idx, data) VALUES (?1, ?2)",
                params![idx, data],
            )
            .unwrap();
        }
    }

    #[test]
    fn page_sql_skips_oversized_blobs_in_sql() {
        let sql = page_sql();
        assert!(sql.contains("length(data) <= 1048576"));
        assert!(sql.contains("ELSE NULL"));
        assert!(sql.contains("LIMIT 8"));
    }

    #[test]
    fn scan_tempfile_sqlite_skips_oversized_and_unpriced() {
        let tmp = TempDir::new().unwrap();
        let conv = tmp.path().join(".gemini/antigravity-cli/conversations");
        fs::create_dir_all(&conv).unwrap();
        let db = conv.join("sess.db");
        let now = Utc::now().timestamp() as u64;
        let priced = encode_generation_blob("gemini-3.6-flash", 10, 90, 40, 5, now);
        let unknown = encode_generation_blob("___unset_antigravity_model___", 1, 1, 1, 0, now);
        assert!(default_pricing().can_price("gemini-3.6-flash"));
        assert!(!default_pricing().can_price("___unset_antigravity_model___"));
        let oversized = vec![0u8; (MAXIMUM_BLOB_BYTES as usize) + 1];
        seed_db(
            &db,
            &[(1, Some(priced)), (2, Some(unknown)), (3, Some(oversized))],
        );

        let home = tmp.path().to_str().unwrap();
        let (status, rows) = query_daily_since("", Some(home));
        assert_eq!(status, LogScanStatus::Ok);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].input_tokens, 100);
        assert_eq!(rows[0].output_tokens, 40);
        assert_eq!(rows[0].cache_read_tokens, 5);
        assert_eq!(rows[0].total_tokens, 145);
        assert!(rows[0].total_cost.is_some());
        assert!(rows[0].models.contains_key("gemini-3.6-flash"));
        assert!(!rows[0].models.contains_key("___unset_antigravity_model___"));
    }

    #[test]
    fn scan_includes_t3_code_and_xdg_conversation_stores() {
        let tmp = TempDir::new().unwrap();
        let t3 = tmp
            .path()
            .join(".t3/userdata/providers/antigravity/abc123/antigravity-acp/conversations");
        let xdg = tmp.path().join(".config/antigravity/conversations");
        fs::create_dir_all(&t3).unwrap();
        fs::create_dir_all(&xdg).unwrap();
        fs::create_dir_all(tmp.path().join(".t3/userdata/providers/antigravity/empty")).unwrap();
        let now = Utc::now().timestamp() as u64;
        seed_db(
            &t3.join("t3.db"),
            &[(1, Some(encode_generation_blob("gemini-3.6-flash", 10, 90, 40, 5, now)))],
        );
        seed_db(
            &xdg.join("xdg.db"),
            &[(1, Some(encode_generation_blob("gemini-3.6-flash", 20, 80, 10, 0, now)))],
        );

        let dirs = conversations_dirs(Some(tmp.path().to_str().unwrap()));
        assert_eq!(dirs.len(), 2, "{dirs:?}");
        let (status, rows) = query_daily_since("", Some(tmp.path().to_str().unwrap()));
        assert_eq!(status, LogScanStatus::Ok);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].total_tokens, 255);
    }

    #[test]
    fn scan_includes_sibling_antigravity_conversation_stores() {
        let tmp = TempDir::new().unwrap();
        let cli = tmp.path().join(".gemini/antigravity-cli/conversations");
        let ide = tmp.path().join(".gemini/antigravity/conversations");
        fs::create_dir_all(&cli).unwrap();
        fs::create_dir_all(&ide).unwrap();
        let now = Utc::now().timestamp() as u64;
        seed_db(
            &cli.join("cli.db"),
            &[(1, Some(encode_generation_blob("gemini-3.6-flash", 10, 90, 40, 5, now)))],
        );
        seed_db(
            &ide.join("ide.db"),
            &[(1, Some(encode_generation_blob("gemini-3.6-flash", 20, 80, 10, 0, now)))],
        );

        let (status, rows) = query_daily_since("", Some(tmp.path().to_str().unwrap()));
        assert_eq!(status, LogScanStatus::Ok);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].input_tokens, 200);
        assert_eq!(rows[0].output_tokens, 50);
        assert_eq!(rows[0].total_tokens, 255);
    }

    #[test]
    fn missing_conversations_dir_is_no_data() {
        let tmp = TempDir::new().unwrap();
        let (status, rows) = query_daily_since("", Some(tmp.path().to_str().unwrap()));
        assert_eq!(status, LogScanStatus::NoData);
        assert!(rows.is_empty());
    }

    #[test]
    fn unchanged_database_reuses_fold_but_replaced_database_does_not() {
        let tmp = TempDir::new().unwrap();
        let db = tmp.path().join("conversation.db");
        let now = Utc::now().timestamp() as u64;
        let seed = |path: &Path, output| {
            seed_db(path, &[(1, Some(encode_generation_blob(
                "gemini-3.6-flash", 10, 90, output, 5, now,
            )))]);
        };
        seed(&db, 40);
        let original = read_fold(&db, &mut HashSet::new(), None, None).unwrap();
        let unchanged = read_fold(&db, &mut HashSet::new(), None, None).unwrap();
        assert!(Arc::ptr_eq(&original, &unchanged));

        let old = tmp.path().join("old.db");
        fs::rename(&db, old).unwrap();
        seed(&db, 20);
        let replacement = read_fold(&db, &mut HashSet::new(), None, None).unwrap();
        assert_eq!(replacement[0].output_tokens, 20);
        assert!(!Arc::ptr_eq(&original, &replacement));
    }

    #[test]
    fn duplicate_database_file_is_counted_once() {
        let tmp = TempDir::new().unwrap();
        let db = tmp.path().join("conversation.db");
        let alias = tmp.path().join("alias.db");
        seed_db(&db, &[]);
        fs::hard_link(&db, &alias).unwrap();
        let mut identities = HashSet::new();
        assert!(read_fold(&db, &mut identities, None, None).is_some());
        assert!(read_fold(&alias, &mut identities, None, None).is_none());
    }

    #[test]
    fn joins_steps_by_identity_and_rejects_cross_day_duplicates() {
        use antigravity_proto::{encode_bytes_field, encode_varint_field};

        let tmp = TempDir::new().unwrap();
        let db = tmp.path().join("steps.db");
        let generation = |id: &str| {
            let mut blob = encode_generation_blob("gemini-3.6-flash", 10, 90, 40, 5, 0);
            blob.extend(encode_bytes_field(4, id.as_bytes()));
            blob
        };
        seed_db(&db, &[(1, Some(generation("match"))), (2, Some(generation("conflict"))),
            (3, Some(generation("no-match")))]);
        let conn = Connection::open(&db).unwrap();
        conn.execute("CREATE TABLE steps (idx INTEGER PRIMARY KEY, metadata BLOB)", []).unwrap();
        let timestamp = Utc::now().timestamp() as u64;
        for (idx, id, time) in [
            (1, "other", timestamp), (11, "match", timestamp),
            (12, "conflict", timestamp), (13, "conflict", timestamp - 172_800),
        ] {
            let mut metadata = encode_bytes_field(1, &encode_varint_field(1, time));
            metadata.extend(encode_bytes_field(12, id.as_bytes()));
            conn.execute("INSERT INTO steps VALUES (?1, ?2)", params![idx, metadata]).unwrap();
        }
        let (events, _, _) = read_database(&db).unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].timestamp_seconds, timestamp as i64);
    }
}
