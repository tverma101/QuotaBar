//! Local ZCode SQLite + LevelDB scanner and disk cache (`ZCodeUsageScanner.swift`, `ZCodeUsageCachePersistence.swift`).

use super::zcode_leveldb::{
    scan_leveldb_entitlement, LevelDBFile, ZCodeAllowance, ZCodeEntitlementSnapshot,
};
use crate::accounting::{DailyUsageAccumulator, LogUsageScan, RowOptions};
use crate::model::{DailyUsageEntry, DailyUsageSeries};
use crate::paths;
use crate::pricing::{shared as shared_pricing, ModelPricing, TokenBreakdown};
use crate::scan::discover::Revision;
use crate::sqlite::{query_value, SqliteError};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

pub const DEFAULT_SQLITE_PATH: &str = "~/.zcode/cli/db/db.sqlite";
pub const UNREADABLE_HISTORY_WARNING: &str = "Couldn't read ZCode token usage.";
const CACHE_SCHEMA: i32 = 1;
const MAX_CACHE_BYTES: usize = 64 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ZCodeUsageResult {
    pub total_tokens: Option<f64>,
    pub plan_name: Option<String>,
    pub log_scan: Option<LogUsageScan>,
    pub weekend_build: Option<ZCodeAllowance>,
    pub damaged_rows: usize,
    pub sqlite_read_failure: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SourceStamp {
    size: u64,
    mtime_ns: i64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DiskCacheRecord {
    schema: i32,
    sqlite_path: String,
    leveldb_path: String,
    sqlite_stamp: Option<SourceStamp>,
    leveldb_stamp: Option<SourceStamp>,
    pricing_token: String,
    scanned_at: f64,
    result: ZCodeUsageResult,
}

#[derive(Clone)]
struct SqlitePart {
    total_tokens: Option<f64>,
    plan_name: Option<String>,
    log_scan: Option<LogUsageScan>,
    damaged_rows: usize,
    sqlite_error: Option<String>,
}

#[derive(Default)]
struct ScannerCache {
    sqlite_part: Option<SqlitePart>,
    sqlite_stamp: Option<SourceStamp>,
    sqlite_pricing_token: Option<String>,
    entitlement: Option<ZCodeEntitlementSnapshot>,
    has_cached_entitlement: bool,
    leveldb_stamp: Option<SourceStamp>,
    scanned_at: Option<f64>,
}

#[derive(Clone)]
pub struct ZCodeUsageScanner {
    pub sqlite_path: PathBuf,
    pub leveldb_dir: PathBuf,
    pub cache_dir_override: Option<PathBuf>,
    cache: Arc<Mutex<ScannerCache>>,
}

impl ZCodeUsageScanner {
    pub fn live() -> Self {
        ZCodeUsageScanner {
            sqlite_path: paths::expand_home(DEFAULT_SQLITE_PATH),
            leveldb_dir: paths::platform_app_support().join("ZCode/session/Local Storage/leveldb"),
            cache_dir_override: None,
            cache: Arc::new(Mutex::new(ScannerCache::default())),
        }
    }

    pub fn new(sqlite_path: PathBuf, leveldb_dir: PathBuf) -> Self {
        ZCodeUsageScanner {
            sqlite_path,
            leveldb_dir,
            cache_dir_override: None,
            cache: Arc::new(Mutex::new(ScannerCache::default())),
        }
    }

    pub fn with_cache_dir(mut self, dir: PathBuf) -> Self {
        self.cache_dir_override = Some(dir);
        self
    }

    pub fn unload_caches(&self) {
        *self.cache.lock().unwrap_or_else(|e| e.into_inner()) = ScannerCache::default();
    }

    pub fn has_history(&self) -> bool {
        self.sqlite_path.exists() || self.leveldb_dir.exists()
    }

    pub fn usage(
        &self,
        now: Option<f64>,
        pricing_override: Option<&ModelPricing>,
    ) -> Result<Option<ZCodeUsageResult>, SqliteError> {
        let sqlite_stamp = sqlite_stamp(&self.sqlite_path);
        let leveldb_files = load_leveldb_files(&self.leveldb_dir);
        let leveldb_stamp = leveldb_stamp(leveldb_files.as_deref());

        let owned_pricing;
        let pricing = match pricing_override {
            Some(p) => p,
            None => {
                owned_pricing = shared_pricing().current(false);
                &owned_pricing
            }
        };
        let pricing_token = pricing.aggregate_cache_token();

        let effective_now = now.unwrap_or_else(current_unix_secs);
        let memory_warm = {
            let guard = self.cache.lock().unwrap_or_else(|e| e.into_inner());
            guard.sqlite_part.is_some()
                && guard.sqlite_stamp == sqlite_stamp
                && guard.sqlite_pricing_token.as_deref() == Some(pricing_token)
                && guard.has_cached_entitlement
                && guard.leveldb_stamp == leveldb_stamp
        };

        if !memory_warm {
            if let Some(persisted) = self.read_disk_cache() {
                let path_str = self.sqlite_path.to_string_lossy();
                let ldb_str = self.leveldb_dir.to_string_lossy();
                if persisted.sqlite_path == path_str
                    && persisted.leveldb_path == ldb_str
                    && persisted.sqlite_stamp == sqlite_stamp
                    && persisted.leveldb_stamp == leveldb_stamp
                    && persisted.pricing_token == pricing_token
                    && promo_still_valid(
                        persisted.result.weekend_build.as_ref(),
                        Some(persisted.scanned_at),
                        effective_now,
                    )
                {
                    let mut guard = self.cache.lock().unwrap_or_else(|e| e.into_inner());
                    guard.sqlite_part = Some(SqlitePart {
                        total_tokens: persisted.result.total_tokens,
                        plan_name: persisted.result.plan_name.clone(),
                        log_scan: persisted.result.log_scan.clone(),
                        damaged_rows: persisted.result.damaged_rows,
                        sqlite_error: None,
                    });
                    guard.sqlite_stamp = sqlite_stamp;
                    guard.sqlite_pricing_token = Some(pricing_token.to_string());
                    guard.entitlement = Some(ZCodeEntitlementSnapshot {
                        plan_name: persisted.result.plan_name.clone(),
                        weekend_build: persisted.result.weekend_build.clone(),
                    });
                    guard.has_cached_entitlement = true;
                    guard.leveldb_stamp = leveldb_stamp;
                    guard.scanned_at = Some(persisted.scanned_at);
                    return Ok(Some(persisted.result));
                }
            }
        }

        let sqlite_part = self.sqlite_usage(sqlite_stamp, pricing);
        let entitlement = self.leveldb_entitlement(leveldb_stamp, leveldb_files.as_deref(), now);

        let plan_name = sqlite_part
            .plan_name
            .clone()
            .or_else(|| entitlement.as_ref().and_then(|e| e.plan_name.clone()));

        if sqlite_part.total_tokens.is_none()
            && sqlite_part.log_scan.is_none()
            && entitlement.is_none()
        {
            if let Some(err) = sqlite_part.sqlite_error {
                return Err(SqliteError::Unreadable(err));
            }
            return Ok(None);
        }

        let result = ZCodeUsageResult {
            total_tokens: sqlite_part.total_tokens,
            plan_name,
            log_scan: sqlite_part.log_scan,
            weekend_build: entitlement.and_then(|e| e.weekend_build),
            damaged_rows: sqlite_part.damaged_rows,
            sqlite_read_failure: sqlite_part.sqlite_error.clone(),
        };

        let scanned_at = now.unwrap_or_else(current_unix_secs);
        self.cache
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .scanned_at = Some(scanned_at);
        if sqlite_part.sqlite_error.is_none() {
            self.write_disk_cache(&DiskCacheRecord {
                schema: CACHE_SCHEMA,
                sqlite_path: self.sqlite_path.to_string_lossy().into_owned(),
                leveldb_path: self.leveldb_dir.to_string_lossy().into_owned(),
                sqlite_stamp,
                leveldb_stamp,
                pricing_token: pricing_token.to_string(),
                scanned_at,
                result: result.clone(),
            });
        }
        Ok(Some(result))
    }

    fn sqlite_usage(&self, stamp: Option<SourceStamp>, pricing: &ModelPricing) -> SqlitePart {
        let pricing_token = pricing.aggregate_cache_token();
        {
            let guard = self.cache.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(cached) = &guard.sqlite_part {
                if guard.sqlite_stamp == stamp
                    && guard.sqlite_pricing_token.as_deref() == Some(pricing_token)
                {
                    return cached.clone();
                }
            }
        }

        let mut part = SqlitePart {
            total_tokens: None,
            plan_name: None,
            log_scan: None,
            damaged_rows: 0,
            sqlite_error: None,
        };

        if stamp.is_some() {
            let totals_sql = "\
                SELECT (SELECT CAST(COALESCE(SUM(CASE WHEN typeof(input_tokens) != 'integer' \
                        OR typeof(output_tokens) != 'integer' OR input_tokens < 0 OR output_tokens < 0 \
                        THEN 0 ELSE CAST(input_tokens AS REAL) + CAST(output_tokens AS REAL) END), 0) AS TEXT) \
                    FROM model_usage) || '|' || \
                    CAST((SELECT COUNT(*) FROM model_usage WHERE typeof(input_tokens) != 'integer' \
                        OR typeof(output_tokens) != 'integer' OR input_tokens < 0 OR output_tokens < 0) AS TEXT) \
                    || '|' || COALESCE((SELECT provider_id FROM model_usage WHERE provider_id LIKE 'account:zai%' ORDER BY started_at DESC LIMIT 1), '');";
            match query_value(&self.sqlite_path, totals_sql) {
                Ok(Some(raw)) => {
                    let parts: Vec<&str> = raw.split('|').collect();
                    if parts.len() < 2 {
                        part.sqlite_error = Some(UNREADABLE_HISTORY_WARNING.into());
                    } else if let Ok(total) = parts[0].parse::<f64>() {
                        if total.is_finite() && total >= 0.0 {
                            part.total_tokens = (total > 0.0).then_some(total);
                            part.damaged_rows = parts[1].parse::<usize>().unwrap_or(0);
                            if parts.len() > 2 {
                                let pid = parts[2..].join("|");
                                let pid = pid.trim();
                                if pid.contains("start-plan") {
                                    part.plan_name = Some("Start Plan".into());
                                } else if pid.contains("coding-plan") {
                                    part.plan_name = Some("Coding Plan".into());
                                }
                            }
                            part.log_scan = read_daily_series(&self.sqlite_path, pricing);
                        } else {
                            part.sqlite_error = Some(UNREADABLE_HISTORY_WARNING.into());
                        }
                    } else if !parts[0].is_empty() {
                        part.sqlite_error = Some(UNREADABLE_HISTORY_WARNING.into());
                    } else {
                        part.log_scan = read_daily_series(&self.sqlite_path, pricing);
                    }
                }
                Ok(None) => {
                    part.log_scan = read_daily_series(&self.sqlite_path, pricing);
                }
                Err(err) => {
                    part.sqlite_error = Some(err.to_string());
                }
            }
        }

        if part.sqlite_error.is_none() {
            let mut guard = self.cache.lock().unwrap_or_else(|e| e.into_inner());
            guard.sqlite_part = Some(part.clone());
            guard.sqlite_stamp = stamp;
            guard.sqlite_pricing_token = Some(pricing_token.to_string());
        }
        part
    }

    fn leveldb_entitlement(
        &self,
        stamp: Option<SourceStamp>,
        files: Option<&[LevelDBFile]>,
        now: Option<f64>,
    ) -> Option<ZCodeEntitlementSnapshot> {
        {
            let guard = self.cache.lock().unwrap_or_else(|e| e.into_inner());
            if guard.has_cached_entitlement && guard.leveldb_stamp == stamp {
                let valid = match (
                    now,
                    guard
                        .entitlement
                        .as_ref()
                        .and_then(|e| e.weekend_build.as_ref()),
                ) {
                    (Some(n), Some(promo)) => promo_still_valid(Some(promo), guard.scanned_at, n),
                    _ => true,
                };
                if valid {
                    return guard.entitlement.clone();
                }
            }
        }

        let entitlement = files.and_then(|fs| scan_leveldb_entitlement(fs, now));
        let mut guard = self.cache.lock().unwrap_or_else(|e| e.into_inner());
        guard.entitlement = entitlement.clone();
        guard.has_cached_entitlement = true;
        guard.leveldb_stamp = stamp;
        if let Some(n) = now {
            guard.scanned_at = Some(n);
        }
        entitlement
    }

    fn cache_path(&self) -> PathBuf {
        let base = self
            .cache_dir_override
            .clone()
            .unwrap_or_else(|| paths::cache_dir("zcode-usage"));
        base.join("zcode-usage.json")
    }

    fn read_disk_cache(&self) -> Option<DiskCacheRecord> {
        let bytes = std::fs::read(self.cache_path()).ok()?;
        let rec: DiskCacheRecord = serde_json::from_slice(&bytes).ok()?;
        (rec.schema == CACHE_SCHEMA).then_some(rec)
    }

    fn write_disk_cache(&self, record: &DiskCacheRecord) {
        let Ok(bytes) = serde_json::to_vec(record) else {
            return;
        };
        if bytes.len() <= MAX_CACHE_BYTES {
            let _ = paths::write_atomic(&self.cache_path(), &bytes);
        }
    }
}

fn promo_still_valid(
    allowance: Option<&ZCodeAllowance>,
    scanned_at: Option<f64>,
    now: f64,
) -> bool {
    let Some(allowance) = allowance else {
        return true;
    };
    if allowance.expires_at.is_some_and(|exp| exp <= now) {
        return false;
    }
    let is_active_unused = allowance.effective_at.is_some_and(|e| e <= now)
        && allowance.used == 0.0
        && scanned_at.is_some_and(|s| allowance.effective_at.is_some_and(|e| e > s));
    !is_active_unused
}

fn read_daily_series(sqlite_path: &Path, pricing: &ModelPricing) -> Option<LogUsageScan> {
    let daily_sql = "\
        SELECT date(started_at / 1000, 'unixepoch', 'localtime') || '|' || \
               COALESCE(model_id, '') || '|' || \
               CAST(SUM(input_tokens) AS TEXT) || '|' || \
               CAST(SUM(output_tokens) AS TEXT) || '|' || \
               CAST(SUM(cache_read_input_tokens) AS TEXT) || '|' || \
               CAST(SUM(cache_creation_input_tokens) AS TEXT) \
        FROM model_usage \
        WHERE typeof(input_tokens) = 'integer' AND typeof(output_tokens) = 'integer' \
            AND input_tokens >= 0 AND output_tokens >= 0 \
        GROUP BY date(started_at / 1000, 'unixepoch', 'localtime'), model_id \
        ORDER BY date(started_at / 1000, 'unixepoch', 'localtime') DESC;";
    if let Ok(Some(raw)) = crate::sqlite::query_text(sqlite_path, daily_sql, true) {
        let mut acc = DailyUsageAccumulator::new();
        for line in raw.lines() {
            let parts: Vec<&str> = line.split('|').collect();
            if parts.len() < 6 {
                continue;
            }
            let day = parts[0];
            let model = parts[1];
            let (Ok(input), Ok(output), Ok(cache_read), Ok(cache_creation)) = (
                parts[2].parse::<i64>(),
                parts[3].parse::<i64>(),
                parts[4].parse::<i64>(),
                parts[5].parse::<i64>(),
            ) else {
                continue;
            };
            if input < 0 || output < 0 || cache_read < 0 || cache_creation < 0 {
                continue;
            }
            let row_tokens = input.saturating_add(output);
            if row_tokens <= 0 {
                continue;
            }
            let uncached_input = input
                .saturating_sub(cache_read)
                .saturating_sub(cache_creation);
            let tokens = TokenBreakdown {
                input: uncached_input,
                cache_write_5m: cache_creation,
                cache_write_1h: 0,
                cache_read,
                output,
                is_fast: false,
            };
            let cost = pricing.estimated_cost_dollars(model, &tokens, None, true);
            let canonical = pricing
                .canonical_name(model)
                .unwrap_or_else(|| model.to_string());
            acc.add_with(
                day,
                row_tokens,
                cost,
                model,
                RowOptions {
                    canonical: Some(&canonical),
                    cost_is_complete: true,
                    token_count_saturated: false,
                },
            );
            if cost.is_some() {
                acc.mark_estimated_cost(day);
            }
            acc.record_api_estimate(day, cost, row_tokens);
        }
        let built = acc.build();
        if !built.series.daily.is_empty() {
            return Some(built);
        }
        return None;
    }

    let fallback_sql = "\
        SELECT date(started_at / 1000, 'unixepoch', 'localtime') || ':' || CAST(SUM(input_tokens + output_tokens) AS TEXT) \
        FROM model_usage \
        WHERE typeof(input_tokens) = 'integer' AND typeof(output_tokens) = 'integer' \
            AND input_tokens >= 0 AND output_tokens >= 0 \
        GROUP BY date(started_at / 1000, 'unixepoch', 'localtime') \
        ORDER BY date(started_at / 1000, 'unixepoch', 'localtime') DESC;";
    if let Ok(Some(raw)) = crate::sqlite::query_text(sqlite_path, fallback_sql, true) {
        let mut entries = Vec::new();
        for line in raw.lines() {
            let Some((day, tok_str)) = line.split_once(':') else {
                continue;
            };
            let Ok(tokens) = tok_str.parse::<i64>() else {
                continue;
            };
            if tokens > 0 {
                entries.push(DailyUsageEntry {
                    date: day.to_string(),
                    total_tokens: tokens,
                    cost_usd: None,
                    cost_is_complete: false,
                    has_unexplained_incomplete_cost: Some(true),
                    token_count_saturated: false,
                    reported_cost: None,
                });
            }
        }
        if !entries.is_empty() {
            return Some(LogUsageScan {
                series: DailyUsageSeries { daily: entries },
                model_usage: None,
                unknown_models_by_day: Default::default(),
                api_estimate_by_day: Default::default(),
                api_estimate_incomplete_days: Default::default(),
                estimated_cost_days: Default::default(),
                unmeasured_usage_days: Default::default(),
            });
        }
    }
    None
}

fn sqlite_stamp(path: &Path) -> Option<SourceStamp> {
    let rev = Revision::read(path).ok()?;
    let mut size = rev.size;
    let mut mtime_ns = rev.mtime_ns;
    let mut wal_os = path.as_os_str().to_os_string();
    wal_os.push("-wal");
    if let Ok(wal) = Revision::read(Path::new(&wal_os)) {
        size = size.saturating_add(wal.size);
        mtime_ns = mtime_ns.max(wal.mtime_ns);
    }
    Some(SourceStamp { size, mtime_ns })
}

fn load_leveldb_files(dir: &Path) -> Option<Vec<LevelDBFile>> {
    let entries = std::fs::read_dir(dir).ok()?;
    let mut files = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if !matches!(
            path.extension().and_then(|s| s.to_str()),
            Some("log" | "ldb")
        ) {
            continue;
        }
        if let Ok(rev) = Revision::read(&path) {
            files.push(LevelDBFile {
                path,
                modified_ns: rev.mtime_ns,
                size: rev.size,
            });
        }
    }
    Some(files)
}

fn leveldb_stamp(files: Option<&[LevelDBFile]>) -> Option<SourceStamp> {
    let files = files?;
    let mut total_size = 0u64;
    let mut max_mtime = 0i64;
    for f in files {
        total_size = total_size.saturating_add(f.size);
        if f.modified_ns > max_mtime {
            max_mtime = f.modified_ns;
        }
    }
    (total_size > 0).then_some(SourceStamp {
        size: total_size,
        mtime_ns: max_mtime,
    })
}

fn current_unix_secs() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}
