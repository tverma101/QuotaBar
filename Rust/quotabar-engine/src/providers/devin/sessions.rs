//! Devin CLI SQLite session reader & persistent incremental fold cache
//! (Swift `DevinSessionUsageReader` + `DevinSessionUsageCache`).

use super::sessions_cache::{
    read_cache_record, revision_for, sorted_entries, write_cache_record, DbRevision, FoldState,
    StoredWinner, CACHE_SCHEMA,
};
pub use super::sessions_cache::{CacheRecord, StoredStamp};
use crate::model::ModelUsageEntry;
use crate::pricing::TokenBreakdown;
use crate::sqlite;
use crate::time;
use rusqlite::{params, Connection};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;

const REVERIFY_ROW_SPAN: i64 = 4_096;
const REVERIFY_ROW_LIMIT: usize = 2_048;

#[derive(Clone, Debug, PartialEq)]
pub struct DevinSessionEntry {
    pub timestamp: f64,
    pub model: String,
    pub tokens: TokenBreakdown,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FoldKind {
    Full,
    Incremental,
    Verified,
}

pub struct DevinSessionUsageReader {
    cache_dir_override: Option<PathBuf>,
    cached: Option<(DbRevision, Arc<Vec<DevinSessionEntry>>)>,
    state: Option<FoldState>,
    persisted: Option<CacheRecord>,
    pub last_fold_kind: Option<FoldKind>,
    pub adopted_disk_record: bool,
}

impl Default for DevinSessionUsageReader {
    fn default() -> Self {
        Self::new(None)
    }
}

impl DevinSessionUsageReader {
    pub fn new(cache_dir_override: Option<PathBuf>) -> Self {
        DevinSessionUsageReader {
            cache_dir_override,
            cached: None,
            state: None,
            persisted: None,
            last_fold_kind: None,
            adopted_disk_record: false,
        }
    }

    pub fn clear(&mut self) {
        self.cached = None;
        self.state = None;
        self.persisted = None;
        self.last_fold_kind = None;
        self.adopted_disk_record = false;
    }

    pub fn entries(&mut self, db_path: &Path) -> Result<Arc<Vec<DevinSessionEntry>>, String> {
        self.adopted_disk_record = false;
        let Some(before) = revision_for(db_path) else {
            self.clear();
            return Ok(Arc::new(Vec::new()));
        };
        if let Some((ref rev, ref entries)) = self.cached {
            if *rev == before {
                self.last_fold_kind = Some(FoldKind::Verified);
                return Ok(entries.clone());
            }
        }
        if self.state.is_none() {
            if let Some(record) = read_cache_record(db_path, self.cache_dir_override.as_deref()) {
                if record.revision.len() == 2
                    && record.revision[0].as_ref().map(|s| s.inode)
                        == before[0].as_ref().map(|s| s.inode)
                {
                    let rev = [record.revision[0].clone(), record.revision[1].clone()];
                    self.persisted = Some(record.clone());
                    self.state = Some(FoldState {
                        watermark: record.watermark,
                        row_count: record.row_count,
                        row_id_sum: record.row_id_sum,
                        winners: record.winners,
                        revision: rev,
                    });
                    self.adopted_disk_record = true;
                }
            }
        }

        if let Some(ref state) = self.state {
            if state.revision == before {
                let entries = Arc::new(sorted_entries(&state.winners));
                self.cached = Some((before, entries.clone()));
                self.last_fold_kind = Some(FoldKind::Verified);
                return Ok(entries);
            }
        }

        let same_file_prior = self.state.as_ref().filter(|s| {
            s.revision[0].as_ref().map(|x| x.inode) == before[0].as_ref().map(|x| x.inode)
        });

        let (new_state, entries, kind) = scan_db(db_path, same_file_prior, &before)?;
        let entries = Arc::new(entries);
        let Some(after) = revision_for(db_path) else {
            self.clear();
            return Ok(entries);
        };
        if after != before {
            self.cached = None;
            self.state = None;
            self.last_fold_kind = Some(kind);
            return Ok(entries);
        }

        let record = CacheRecord {
            schema: CACHE_SCHEMA,
            revision: vec![new_state.revision[0].clone(), new_state.revision[1].clone()],
            watermark: new_state.watermark,
            row_count: new_state.row_count,
            row_id_sum: new_state.row_id_sum,
            winners: new_state.winners.clone(),
        };
        if self.persisted.as_ref() != Some(&record) {
            write_cache_record(&record, db_path, self.cache_dir_override.as_deref());
            self.persisted = Some(record);
        }
        self.state = Some(new_state);
        self.cached = Some((before, entries.clone()));
        self.last_fold_kind = Some(kind);
        Ok(entries)
    }
}

fn scan_db(
    db_path: &Path,
    prior: Option<&FoldState>,
    stamps: &DbRevision,
) -> Result<(FoldState, Vec<DevinSessionEntry>, FoldKind), String> {
    let Some(conn) = sqlite::open_read_only(db_path).map_err(|e| e.to_string())? else {
        return Ok((
            FoldState {
                watermark: 0,
                row_count: 0,
                row_id_sum: 0,
                winners: HashMap::new(),
                revision: stamps.clone(),
            },
            Vec::new(),
            FoldKind::Full,
        ));
    };
    conn.execute_batch("BEGIN DEFERRED TRANSACTION")
        .map_err(|e| format!("Could not read Devin session usage: {e}"))?;

    let result = (|| -> Result<(FoldState, Vec<DevinSessionEntry>, FoldKind), String> {
        let watermark = prior.map_or(i64::MAX, |p| p.watermark);
        let agg = row_id_aggregate(&conn, watermark)?;
        if let Some(prior) = prior {
            if agg.prefix_count == prior.row_count && agg.prefix_sum == prior.row_id_sum {
                if let Some(winners) = incremental_winners(&conn, prior, agg.total)? {
                    let entries = sorted_entries(&winners);
                    let state = FoldState {
                        watermark: agg.maximum,
                        row_count: agg.total,
                        row_id_sum: agg.sum,
                        winners,
                        revision: stamps.clone(),
                    };
                    return Ok((state, entries, FoldKind::Incremental));
                }
            }
        }
        let mut winners = HashMap::new();
        fold_rows(&conn, &mut winners)?;
        let entries = sorted_entries(&winners);
        let state = FoldState {
            watermark: agg.maximum,
            row_count: agg.total,
            row_id_sum: agg.sum,
            winners,
            revision: stamps.clone(),
        };
        Ok((state, entries, FoldKind::Full))
    })();

    let _ = match &result {
        Ok(_) => conn.execute_batch("COMMIT"),
        Err(_) => conn.execute_batch("ROLLBACK"),
    };
    result
}

struct RowIdAgg {
    total: i64,
    sum: i64,
    prefix_sum: i64,
    prefix_count: i64,
    maximum: i64,
}

fn row_id_aggregate(conn: &Connection, watermark: i64) -> Result<RowIdAgg, String> {
    let idx = covering_index_name(conn);
    let indexed = idx.map_or_else(String::new, |name| {
        format!(" INDEXED BY \"{}\"", name.replace('"', "\"\""))
    });
    let sql = format!(
        "SELECT COUNT(*), COALESCE(SUM(row_id), 0), COALESCE(SUM(CASE WHEN row_id <= ?1 THEN row_id ELSE 0 END), 0), COALESCE(SUM(CASE WHEN row_id <= ?1 THEN 1 ELSE 0 END), 0), COALESCE(MAX(row_id), 0) FROM message_nodes{indexed}"
    );
    conn.query_row(&sql, params![watermark], |row| {
        Ok(RowIdAgg {
            total: row.get(0)?,
            sum: row.get(1)?,
            prefix_sum: row.get(2)?,
            prefix_count: row.get(3)?,
            maximum: row.get(4)?,
        })
    })
    .map_err(|_| "Could not read Devin session usage".to_string())
}

fn covering_index_name(conn: &Connection) -> Option<String> {
    let mut stmt = conn
        .prepare(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'message_nodes'",
        )
        .ok()?;
    let mut names = Vec::new();
    let rows = stmt.query_map([], |row| row.get::<_, String>(0)).ok()?;
    for name in rows.flatten() {
        names.push(name);
    }
    if names.iter().any(|n| n == "idx_message_nodes_session") {
        Some("idx_message_nodes_session".to_string())
    } else {
        names.into_iter().next()
    }
}

fn full_fold_query() -> &'static str {
    "WITH metered AS MATERIALIZED (
        SELECT row_id, created_at, json_extract(chat_message, '$.metadata.request_id') AS request_id,
               json_extract(chat_message, '$.metadata.created_at') AS generated_at,
               json_extract(chat_message, '$.metadata.generation_model') AS model,
               json_extract(chat_message, '$.metadata.metrics') AS metrics
        FROM message_nodes
        WHERE json_extract(chat_message, '$.role') = 'assistant'
          AND json_type(chat_message, '$.metadata.metrics') = 'object'
          AND (json_type(chat_message, '$.metadata.metrics.input_tokens') IS NOT NULL
            OR json_type(chat_message, '$.metadata.metrics.output_tokens') IS NOT NULL)
    ), unique_calls AS (
        SELECT *, row_number() OVER (PARTITION BY request_id,
            CASE WHEN request_id IS NULL OR request_id = '' THEN row_id ELSE 0 END ORDER BY row_id DESC) AS copy_rank
        FROM metered
    )
    SELECT row_id, request_id, created_at, generated_at, model,
           json_extract(metrics, '$.input_tokens'), json_extract(metrics, '$.output_tokens'),
           json_extract(metrics, '$.cache_read_tokens'), json_extract(metrics, '$.cache_creation_tokens'),
           json_type(metrics, '$.input_tokens'), json_type(metrics, '$.output_tokens'),
           json_type(metrics, '$.cache_read_tokens'), json_type(metrics, '$.cache_creation_tokens')
    FROM unique_calls WHERE copy_rank = 1"
}

fn metered_rows_query(predicate: &str) -> String {
    format!(
        "SELECT row_id, json_extract(chat_message, '$.metadata.request_id'),
                created_at, json_extract(chat_message, '$.metadata.created_at'),
                json_extract(chat_message, '$.metadata.generation_model'),
                json_extract(chat_message, '$.metadata.metrics.input_tokens'),
                json_extract(chat_message, '$.metadata.metrics.output_tokens'),
                json_extract(chat_message, '$.metadata.metrics.cache_read_tokens'),
                json_extract(chat_message, '$.metadata.metrics.cache_creation_tokens'),
                json_type(chat_message, '$.metadata.metrics.input_tokens'),
                json_type(chat_message, '$.metadata.metrics.output_tokens'),
                json_type(chat_message, '$.metadata.metrics.cache_read_tokens'),
                json_type(chat_message, '$.metadata.metrics.cache_creation_tokens')
         FROM message_nodes
         WHERE {predicate}
           AND json_extract(chat_message, '$.role') = 'assistant'
           AND json_type(chat_message, '$.metadata.metrics') = 'object'
           AND (json_type(chat_message, '$.metadata.metrics.input_tokens') IS NOT NULL
             OR json_type(chat_message, '$.metadata.metrics.output_tokens') IS NOT NULL)
         ORDER BY row_id"
    )
}

fn fold_rows(conn: &Connection, winners: &mut HashMap<String, StoredWinner>) -> Result<(), String> {
    let mut stmt = conn
        .prepare(full_fold_query())
        .map_err(|_| "Could not read Devin session usage".to_string())?;
    let mut rows = stmt
        .query([])
        .map_err(|_| "Could not read Devin session usage".to_string())?;
    while let Some(row) = rows
        .next()
        .map_err(|_| "Could not read Devin session usage".to_string())?
    {
        let (key, winner) = read_candidate(row)?;
        winners.insert(key, winner);
    }
    Ok(())
}

fn each_candidate(
    conn: &Connection,
    predicate: &str,
    mut body: impl FnMut(String, StoredWinner) -> Result<(), String>,
) -> Result<(), String> {
    let sql = metered_rows_query(predicate);
    let mut stmt = conn
        .prepare(&sql)
        .map_err(|_| "Could not read Devin session usage".to_string())?;
    let mut rows = stmt
        .query([])
        .map_err(|_| "Could not read Devin session usage".to_string())?;
    while let Some(row) = rows
        .next()
        .map_err(|_| "Could not read Devin session usage".to_string())?
    {
        let (key, winner) = read_candidate(row)?;
        body(key, winner)?;
    }
    Ok(())
}

fn incremental_winners(
    conn: &Connection,
    prior: &FoldState,
    total_rows: i64,
) -> Result<Option<HashMap<String, StoredWinner>>, String> {
    let mut winners = prior.winners.clone();
    if total_rows > prior.row_count {
        let pred = format!("row_id > {}", prior.watermark);
        each_candidate(conn, &pred, |key, winner| {
            if let Some(existing) = winners.get(&key) {
                if existing.row_id > winner.row_id {
                    return Ok(());
                }
            }
            winners.insert(key, winner);
            Ok(())
        })?;
    }

    let band_floor = prior.watermark - REVERIFY_ROW_SPAN;
    let mut band: Vec<i64> = prior
        .winners
        .values()
        .filter(|w| w.row_id > band_floor)
        .map(|w| w.row_id)
        .collect();
    band.sort_unstable();
    if band.is_empty() {
        return Ok(Some(winners));
    }
    if band.len() > REVERIFY_ROW_LIMIT {
        let start = band.len() - REVERIFY_ROW_LIMIT;
        band = band[start..].to_vec();
    }
    let mut key_by_row: HashMap<i64, &str> = HashMap::with_capacity(band.len());
    for (k, w) in &prior.winners {
        if w.row_id > band_floor {
            key_by_row.insert(w.row_id, k.as_str());
        }
    }
    let mut seen: HashSet<i64> = HashSet::with_capacity(band.len());
    let in_list = band
        .iter()
        .map(i64::to_string)
        .collect::<Vec<_>>()
        .join(",");
    let pred = format!("row_id IN ({in_list})");
    let mut consistent = true;
    each_candidate(conn, &pred, |key, winner| {
        if key_by_row.get(&winner.row_id).copied() != Some(key.as_str()) {
            consistent = false;
            return Ok(());
        }
        if winners.get(&key).map(|w| w.row_id) == Some(winner.row_id) {
            winners.insert(key, winner.clone());
        }
        seen.insert(winner.row_id);
        Ok(())
    })?;
    if !consistent || seen.len() != band.len() {
        return Ok(None);
    }
    Ok(Some(winners))
}

fn read_candidate(row: &rusqlite::Row<'_>) -> Result<(String, StoredWinner), String> {
    let row_id: i64 = row
        .get(0)
        .map_err(|_| "Could not read Devin session usage".to_string())?;
    let key = partition_key(row, row_id);
    let created_at_secs: i64 = row.get(2).unwrap_or(0);
    let generated_at = strict_text(row, 3).and_then(|s| time::parse_iso8601(&s));
    let timestamp = generated_at.unwrap_or(created_at_secs as f64);
    let raw_model = strict_text(row, 4)
        .map(|s| s.trim().to_string())
        .unwrap_or_default();
    let model = if raw_model.is_empty() {
        ModelUsageEntry::UNATTRIBUTED.to_string()
    } else {
        raw_model
    };
    let input = strict_count(row, 5)?;
    let output = strict_count(row, 6)?;
    let cache_read = strict_count(row, 7)?;
    let cache_write_5m = strict_count(row, 8)?;
    Ok((
        key,
        StoredWinner {
            row_id,
            timestamp,
            model,
            input,
            cache_write_5m,
            cache_read,
            output,
        },
    ))
}

fn partition_key(row: &rusqlite::Row<'_>, row_id: i64) -> String {
    match row.get_ref(1).ok() {
        Some(rusqlite::types::ValueRef::Text(bytes)) => {
            let s = String::from_utf8_lossy(bytes);
            if s.is_empty() {
                format!("u:{row_id}")
            } else {
                format!("r:{s}")
            }
        }
        Some(rusqlite::types::ValueRef::Null) | None => format!("u:{row_id}"),
        Some(rusqlite::types::ValueRef::Integer(i)) => format!("n:1:{i}"),
        Some(rusqlite::types::ValueRef::Real(f)) => format!("n:2:{f}"),
        Some(rusqlite::types::ValueRef::Blob(b)) => format!("n:4:{}", b.len()),
    }
}

fn strict_text(row: &rusqlite::Row<'_>, idx: usize) -> Option<String> {
    match row.get_ref(idx).ok()? {
        rusqlite::types::ValueRef::Text(bytes) => {
            std::str::from_utf8(bytes).ok().map(ToString::to_string)
        }
        _ => None,
    }
}

fn strict_count(row: &rusqlite::Row<'_>, col: usize) -> Result<i64, String> {
    let Some(ty) = strict_text(row, col + 4) else {
        return Ok(0);
    };
    if ty == "null" {
        return Ok(0);
    }
    if ty != "integer" {
        return Err("Could not read Devin session usage".to_string());
    }
    let val: i64 = row
        .get(col)
        .map_err(|_| "Could not read Devin session usage".to_string())?;
    if !(0..=1_000_000_000_000_000).contains(&val) {
        return Err("Could not read Devin session usage".to_string());
    }
    Ok(val)
}
