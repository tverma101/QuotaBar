//! Freebuff local and hosted token history (`FreebuffDesktopUsageScanner`,
//! `FreebuffHostedUsageScanner`).
//!
//! Desktop project databases store only measured token counts on assistant messages and independent
//! mission-manager receipts. Hosted history contributes receipts for Cloud and On This Device runs.
//! Transcript content is never decoded or retained.

use super::auth::FreebuffAuth;
use super::catalog::CatalogEntries;
use super::client::{ClientError, FreebuffClient};
use super::desktop::{self, MessageIndex};
use super::fold;
use crate::accounting::LogUsageScan;
use crate::context::CancelToken;
use crate::host;
use crate::pricing::ModelPricing;
use crate::qlog;
use crate::time::parse_iso8601;
use serde::Deserialize;
use serde_json::{Map, Value};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::UNIX_EPOCH;

pub const OLDER_USAGE_NAME: &str = "Older Freebuff Usage";
const MAXIMUM_RUNS: usize = 10_000;
const MAXIMUM_HOSTED_CACHE_BYTES: u64 = 8 * 1_024 * 1_024;
const HOSTED_CACHE_SECS: f64 = 300.0;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct FreebuffScan {
    pub usage: LogUsageScan,
    pub partial_days: std::collections::BTreeSet<String>,
}

#[derive(Clone, Debug)]
pub struct Receipt {
    pub id: String,
    pub timestamp_ms: f64,
    pub metrics_json: String,
    pub model: Option<String>,
}

/// One project database's last read. Reused whole while the file revision holds; otherwise the
/// next read reuses its unchanged rows (`desktop::read`).
struct CachedTurns {
    revision: Revision,
    index: MessageIndex,
}

#[derive(Clone, PartialEq, Eq)]
struct Revision {
    main: (u64, u128),
    wal: Option<(u64, u128)>,
}

fn revision(path: &Path) -> Option<Revision> {
    let main = file_revision(path)?;
    let wal = file_revision(Path::new(&format!("{}-wal", path.display())));
    Some(Revision { main, wal })
}

fn file_revision(path: &Path) -> Option<(u64, u128)> {
    let metadata = std::fs::metadata(path).ok()?;
    let modified = metadata.modified().ok()?.duration_since(UNIX_EPOCH).ok()?;
    Some((metadata.len(), modified.as_nanos()))
}

#[derive(Clone, Debug)]
pub(super) struct DerivedTurn {
    pub(super) id: String,
    pub(super) timestamp_ms: f64,
    pub(super) usage: Option<Usage>,
    pub(super) saved_model: Option<String>,
    pub(super) from_receipt: bool,
    pub(super) partial: bool,
}

#[derive(Clone, Debug)]
pub(super) struct Usage {
    pub(super) input: Count,
    pub(super) output: Count,
    pub(super) cached: Count,
    pub(super) reasoning: Count,
    reported_total: Count,
}

impl Usage {
    /// An absent reported total is fine; an unreadable or mismatched one rejects the turn.
    pub(super) fn total_matches(&self, total: i64) -> bool {
        match self.reported_total {
            Count::Absent => true,
            Count::Value(reported) => reported == total,
            Count::Invalid => false,
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub(super) enum Count {
    Absent,
    Value(i64),
    Invalid,
}

impl Count {
    pub(super) fn required(self) -> Option<i64> {
        match self {
            Count::Value(value) => Some(value),
            _ => None,
        }
    }

    pub(super) fn optional(self) -> Option<i64> {
        match self {
            Count::Absent => Some(0),
            Count::Value(value) => Some(value),
            Count::Invalid => None,
        }
    }
}

pub struct FreebuffScanner {
    home: PathBuf,
    turns: Mutex<HashMap<PathBuf, CachedTurns>>,
    hosted: Mutex<Option<HostedCache>>,
}

struct HostedCache {
    account: String,
    fetched_at: f64,
    receipts: Vec<Receipt>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PersistedHostedCache {
    account_key: String,
    #[serde(default)]
    runs: HashMap<String, PersistedCachedRun>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PersistedCachedRun {
    receipt: Option<PersistedReceipt>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PersistedReceipt {
    id: String,
    timestamp_ms: f64,
    #[serde(rename = "metricsJSON")]
    metrics_json: String,
    model: Option<String>,
}

impl From<PersistedReceipt> for Receipt {
    fn from(receipt: PersistedReceipt) -> Self {
        Receipt {
            id: receipt.id,
            timestamp_ms: receipt.timestamp_ms,
            metrics_json: receipt.metrics_json,
            model: receipt.model,
        }
    }
}

impl FreebuffScanner {
    pub fn live() -> Self {
        FreebuffScanner::with_home(crate::paths::home())
    }

    pub fn with_home(home: PathBuf) -> Self {
        FreebuffScanner {
            home,
            turns: Mutex::new(HashMap::new()),
            hosted: Mutex::new(None),
        }
    }

    pub fn home(&self) -> &Path {
        &self.home
    }

    pub fn database_paths(&self) -> Vec<PathBuf> {
        let root = self.home.join(".config/freebuff-desktop/projects");
        let Ok(entries) = std::fs::read_dir(root) else {
            return Vec::new();
        };
        let mut paths: Vec<PathBuf> = entries
            .flatten()
            .map(|entry| entry.path().join("desktop-v2.db"))
            .filter(|path| path.is_file())
            .collect();
        paths.sort();
        paths
    }

    pub fn has_history(&self) -> bool {
        !self.database_paths().is_empty()
    }

    pub fn scan(
        &self,
        now: f64,
        pricing: &ModelPricing,
        catalog: &CatalogEntries,
        hosted_receipts: &[Receipt],
        cancel: &CancelToken,
    ) -> Option<FreebuffScan> {
        if cancel.is_cancelled() {
            return None;
        }
        let paths = self.database_paths();
        if paths.is_empty() && hosted_receipts.is_empty() {
            return None;
        }
        let mut turns: Vec<DerivedTurn> = hosted_receipts
            .iter()
            .filter_map(|receipt| {
                derive_turn(
                    &receipt.id,
                    &receipt.timestamp_ms.to_string(),
                    &receipt.metrics_json,
                    receipt.model.as_deref().unwrap_or(""),
                )
            })
            .collect();
        self.turns
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .retain(|path, _| paths.contains(path));
        for path in paths {
            if cancel.is_cancelled() {
                return None;
            }
            let Some(current) = revision(&path) else {
                continue;
            };
            let prior = self
                .turns
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .remove(&path);
            let index = match prior {
                Some(cached) if cached.revision == current => cached.index,
                prior => {
                    // The read is one SQLite snapshot. It is stored under the revision seen before
                    // it, so a write that lands during the read moves the revision and the next
                    // pass re-lists the rows.
                    match desktop::read(&path, prior.as_ref().map(|cached| &cached.index)) {
                        Ok(index) => index,
                        Err(error) => {
                            qlog!(
                                Warn,
                                host::plugin_tag("freebuff"),
                                "Desktop project history unreadable: {error}"
                            );
                            if let Some(prior) = prior {
                                self.turns
                                    .lock()
                                    .unwrap_or_else(|e| e.into_inner())
                                    .insert(path, prior);
                            }
                            return None;
                        }
                    }
                }
            };
            turns.extend(index.turns().cloned());
            self.turns.lock().unwrap_or_else(|e| e.into_inner()).insert(
                path,
                CachedTurns {
                    revision: current,
                    index,
                },
            );
        }
        Some(fold::fold_turns(turns, now, pricing, catalog))
    }

    /// Fetch hosted usage with a short in-memory cache. A fold-only panel pass reuses the receipts
    /// from the meter pass; a manual refresh, or a cache older than five minutes, re-reads.
    pub fn hosted_receipts(
        &self,
        auth: &FreebuffAuth,
        client: &FreebuffClient,
        now: f64,
        is_manual: bool,
        cancel: &CancelToken,
    ) -> Result<Vec<Receipt>, ClientError> {
        let account = account_key(&auth.token);
        if !is_manual {
            let guard = self.hosted.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(cache) = guard.as_ref() {
                if cache.account == account && now - cache.fetched_at < HOSTED_CACHE_SECS {
                    return Ok(cache.receipts.clone());
                }
            }
        }
        let receipts = fetch_hosted(auth, client, now, cancel)?;
        *self.hosted.lock().unwrap_or_else(|e| e.into_inner()) = Some(HostedCache {
            account,
            fetched_at: now,
            receipts: receipts.clone(),
        });
        Ok(receipts)
    }

    /// Saved hosted receipts are accounting evidence, not a network entitlement. Read the shared
    /// persisted cache on every offline fold so receipts appended by another app/CLI process are
    /// picked up, while any fresher in-memory fetch for the same account wins by receipt id.
    pub fn cached_receipts(&self, auth: &FreebuffAuth) -> Vec<Receipt> {
        let account = account_key(&auth.token);
        let mut receipts: HashMap<String, Receipt> = self
            .persisted_receipts(&account)
            .into_iter()
            .map(|receipt| (receipt.id.clone(), receipt))
            .collect();
        if let Some(cache) = self
            .hosted
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
            .filter(|cache| cache.account == account)
        {
            for receipt in &cache.receipts {
                receipts.insert(receipt.id.clone(), receipt.clone());
            }
        }
        let mut receipts: Vec<Receipt> = receipts.into_values().collect();
        receipts.sort_by(|left, right| left.id.cmp(&right.id));
        receipts
    }

    fn persisted_receipts(&self, account: &str) -> Vec<Receipt> {
        let path = self
            .home
            .join("Library/Application Support/QuotaBar/freebuff-hosted-usage-v1.json");
        let Ok(metadata) = std::fs::metadata(&path) else {
            return Vec::new();
        };
        if metadata.len() > MAXIMUM_HOSTED_CACHE_BYTES {
            qlog!(
                Warn,
                host::auth_tag("freebuff"),
                "saved hosted token receipts exceeded the cache byte budget"
            );
            return Vec::new();
        }
        let Ok(bytes) = std::fs::read(&path) else {
            return Vec::new();
        };
        match serde_json::from_slice::<PersistedHostedCache>(&bytes) {
            Ok(cache) if cache.account_key == account => cache
                .runs
                .into_values()
                .filter_map(|cached| cached.receipt.map(Receipt::from))
                .collect(),
            Ok(_) => Vec::new(),
            Err(_) => {
                qlog!(
                    Warn,
                    host::auth_tag("freebuff"),
                    "saved hosted token receipts could not be read; local Desktop history remains available"
                );
                Vec::new()
            }
        }
    }

    /// Drops the hosted-receipt cache. The Desktop row index stays: it holds only derived counts
    /// (about 200 bytes per turn), and rebuilding it re-reads every transcript's overflow pages,
    /// hundreds of MB for a large project.
    pub fn unload_caches(&self) {
        *self.hosted.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }
}

fn account_key(token: &str) -> String {
    use sha2::{Digest, Sha256};
    Sha256::digest(token.as_bytes())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

pub(super) fn derive_turn(
    id: &str,
    timestamp: &str,
    metrics_json: &str,
    selected: &str,
) -> Option<DerivedTurn> {
    if id.is_empty() {
        return None;
    }
    let timestamp_ms: f64 = timestamp.trim().parse().ok()?;
    if !timestamp_ms.is_finite() {
        return None;
    }
    let metrics: Map<String, Value> = serde_json::from_str(metrics_json).ok()?;
    let usage = metrics.get("usage").and_then(Value::as_object);
    let recorded_model = usage
        .and_then(|usage| usage.get("model"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    let saved_model = recorded_model.clone().or_else(|| {
        let selected = selected.trim();
        (!selected.is_empty()).then(|| selected.to_string())
    });
    let partial =
        usage.is_none() || metrics.get("usageIncomplete").and_then(Value::as_bool) == Some(true);
    let usage = usage.map(|usage| Usage {
        input: count(usage.get("inputTokens")),
        output: count(usage.get("outputTokens")),
        cached: count(usage.get("cachedInputTokens")),
        reasoning: count(usage.get("reasoningOutputTokens")),
        reported_total: count(usage.get("totalTokens")),
    });
    Some(DerivedTurn {
        id: id.to_string(),
        timestamp_ms,
        usage,
        saved_model,
        from_receipt: recorded_model.is_some(),
        partial,
    })
}

fn count(value: Option<&Value>) -> Count {
    match value {
        None | Some(Value::Null) => Count::Absent,
        Some(Value::Bool(_)) => Count::Invalid,
        Some(Value::Number(number)) => match number.as_i64() {
            Some(value) if value >= 0 => Count::Value(value),
            _ => Count::Invalid,
        },
        Some(_) => Count::Invalid,
    }
}

fn parse_page(body: &[u8]) -> Option<(Vec<Value>, Option<String>, Option<String>)> {
    let root: Value = serde_json::from_slice(body).ok()?;
    let object = root.as_object()?;
    let items = object.get("items")?.as_array()?.clone();
    let next = object
        .get("nextCursor")
        .and_then(Value::as_str)
        .map(str::to_string);
    let end = object
        .get("endCursor")
        .and_then(Value::as_str)
        .map(str::to_string);
    Some((items, next, end))
}

fn fetch_hosted(
    auth: &FreebuffAuth,
    client: &FreebuffClient,
    now: f64,
    cancel: &CancelToken,
) -> Result<Vec<Receipt>, ClientError> {
    let cutoff = now - 30.0 * 86_400.0;
    let chats = fetch_pages(client, "chats", None, auth, cancel)?;
    let mut receipts: HashMap<String, Receipt> = HashMap::new();
    for chat in chats.iter().filter_map(Value::as_object) {
        if cancel.is_cancelled() {
            return Ok(Vec::new());
        }
        let Some(chat_id) = chat.get("id").and_then(Value::as_str) else {
            continue;
        };
        let runs = fetch_pages(
            client,
            &format!("chats/{}/runs", crate::http::url_form_encode(chat_id)),
            None,
            auth,
            cancel,
        )?;
        for run in runs.iter().filter_map(Value::as_object) {
            let Some(id) = run.get("id").and_then(Value::as_str) else {
                continue;
            };
            let status = run.get("status").and_then(Value::as_str).unwrap_or("");
            let active = matches!(status, "queued" | "running");
            let agent = run.get("agent").and_then(Value::as_str);
            let model = run.get("model").and_then(Value::as_str);
            let is_freebuff = (agent.is_none() || agent == Some("codebuff"))
                && model.is_none_or(|model| !model.starts_with("byok:"));
            let stamp = run
                .get("finishedAt")
                .and_then(Value::as_str)
                .or_else(|| run.get("createdAt").and_then(Value::as_str))
                .and_then(parse_iso8601);
            let Some(stamp) = stamp else { continue };
            if !is_freebuff || (!active && stamp < cutoff) {
                continue;
            }
            let events = fetch_pages(
                client,
                &format!("runs/{}/events", crate::http::url_form_encode(id)),
                None,
                auth,
                cancel,
            )?;
            let mut metrics: Option<Map<String, Value>> = None;
            for event in events.iter().filter_map(Value::as_object) {
                if event.get("kind").and_then(Value::as_str) != Some("metrics") {
                    continue;
                }
                let Some(payload) = event.get("payload").and_then(Value::as_object) else {
                    continue;
                };
                let usage = payload.get("usage").and_then(Value::as_object);
                if let Some(usage) = usage {
                    let input = usage.get("inputTokens").and_then(Value::as_i64);
                    let output = usage.get("outputTokens").and_then(Value::as_i64);
                    let total_ok = match (
                        input,
                        output,
                        usage.get("totalTokens").and_then(Value::as_i64),
                    ) {
                        (Some(input), Some(output), Some(total)) => {
                            input.saturating_add(output) == total
                        }
                        _ => true,
                    };
                    if input.is_none() || output.is_none() || !total_ok {
                        return Err(ClientError::InvalidResponse);
                    }
                }
                let mut merged = metrics.take().unwrap_or_default();
                if let Some(usage) = usage {
                    merged.insert("usage".into(), Value::Object(usage.clone()));
                }
                if let Some(incomplete) = payload.get("usageIncomplete") {
                    merged.insert("usageIncomplete".into(), incomplete.clone());
                }
                metrics = Some(merged);
            }
            let metrics_json = metrics
                .map(Value::Object)
                .map(|value| value.to_string())
                .unwrap_or_else(|| "{}".to_string());
            let receipt = Receipt {
                id: format!("cloud:{id}"),
                timestamp_ms: stamp * 1000.0,
                metrics_json,
                model: model.map(str::to_string),
            };
            receipts.insert(receipt.id.clone(), receipt);
            if receipts.len() > MAXIMUM_RUNS {
                return Err(ClientError::InvalidResponse);
            }
        }
    }
    let mut receipts: Vec<Receipt> = receipts.into_values().collect();
    receipts.sort_by(|left, right| left.id.cmp(&right.id));
    Ok(receipts)
}

fn fetch_pages(
    client: &FreebuffClient,
    path: &str,
    mut cursor: Option<String>,
    auth: &FreebuffAuth,
    cancel: &CancelToken,
) -> Result<Vec<Value>, ClientError> {
    let mut items = Vec::new();
    let mut seen = HashSet::new();
    for _ in 0..100 {
        let response = client.fetch_history(path, cursor.as_deref(), auth, cancel)?;
        if response.status == 401 {
            return Err(ClientError::TokenInvalid);
        }
        if !(200..300).contains(&response.status) {
            return Err(ClientError::RequestFailed(response.status));
        }
        let (page, next, _) = parse_page(&response.body).ok_or(ClientError::InvalidResponse)?;
        items.extend(page);
        let Some(next) = next else { return Ok(items) };
        if !seen.insert(next.clone()) {
            return Err(ClientError::InvalidResponse);
        }
        cursor = Some(next);
    }
    Err(ClientError::InvalidResponse)
}

pub fn warn(error: &ClientError) {
    qlog!(
        Warn,
        host::plugin_tag("freebuff"),
        "hosted history read failed: {error:?}"
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pricing::{ModelRates, PricingCatalog, PricingSupplement};
    use rusqlite::params;
    use rusqlite::Connection;
    use tempfile::TempDir;

    fn pricing() -> ModelPricing {
        let mut entries = HashMap::new();
        entries.insert("model-a".to_string(), ModelRates::new(1.0, 2.0, 1.0, 0.1));
        // Freebuff prices only exact public routes, never LiteLLM fuzzy matches.
        ModelPricing::new(
            PricingSupplement::default(),
            PricingCatalog::default(),
            PricingCatalog::default(),
            PricingCatalog::from_entries(entries),
            None,
        )
    }

    fn seed(path: &Path, rows: &[(&str, i64, &str, &str)]) {
        let connection = Connection::open(path).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE threads (id TEXT PRIMARY KEY, harness_id TEXT, model TEXT, world_snapshot TEXT);
                 CREATE TABLE messages (thread_id TEXT, seq INTEGER, role TEXT, ts INTEGER, metrics_json TEXT, request_id TEXT);
                 CREATE TABLE auto_run_decision_receipts (id INTEGER, thread_id TEXT, created_at INTEGER, manager_json TEXT);",
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO threads VALUES ('t1','codebuff','selected-model','{}')",
                [],
            )
            .unwrap();
        for (index, (id, ts, metrics, request)) in rows.iter().enumerate() {
            connection
                .execute(
                    "INSERT INTO messages VALUES ('t1', ?1, 'assistant', ?2, ?3, ?4)",
                    params![index as i64, ts, metrics, request],
                )
                .unwrap();
            let _ = id;
        }
    }

    #[test]
    fn local_turns_fold_prices_and_marks_partial_days() {
        let dir = TempDir::new().unwrap();
        let project = dir.path().join(".config/freebuff-desktop/projects/p1");
        std::fs::create_dir_all(&project).unwrap();
        let db = project.join("desktop-v2.db");
        seed(
            &db,
            &[
                (
                    "1",
                    1_800_000_000,
                    r#"{"usage":{"inputTokens":100,"outputTokens":50,"cachedInputTokens":20,"totalTokens":150,"model":"model-a"}}"#,
                    "",
                ),
                ("2", 1_800_000_100, r#"{"usageIncomplete":true}"#, ""),
            ],
        );
        let scanner = FreebuffScanner::with_home(dir.path().to_path_buf());
        assert!(scanner.has_history());
        let scan = scanner
            .scan(
                1_800_000_200.0,
                &pricing(),
                &CatalogEntries::new(),
                &[],
                &CancelToken::new(),
            )
            .expect("scan");
        assert_eq!(scan.usage.series.daily[0].total_tokens, 150);
        assert!(scan.usage.series.daily[0].cost_usd.unwrap() > 0.0);
        assert_eq!(scan.partial_days.len(), 1);
        assert!(!scan
            .usage
            .estimated_cost_days
            .clone()
            .unwrap_or_default()
            .is_empty());

        let again = scanner
            .scan(
                1_800_000_200.0,
                &pricing(),
                &CatalogEntries::new(),
                &[],
                &CancelToken::new(),
            )
            .expect("cached scan");
        assert_eq!(again.usage.series, scan.usage.series);
    }

    #[test]
    fn hosted_receipts_merge_patches_and_survive_local_db_missing_columns() {
        let dir = TempDir::new().unwrap();
        let project = dir.path().join(".config/freebuff-desktop/projects/old");
        std::fs::create_dir_all(&project).unwrap();
        let db = project.join("desktop-v2.db");
        let connection = Connection::open(&db).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE threads (id TEXT PRIMARY KEY, harness_id TEXT, model TEXT);
                 CREATE TABLE messages (thread_id TEXT, seq INTEGER, role TEXT, ts INTEGER, metrics_json TEXT, request_id TEXT);
                 INSERT INTO threads VALUES ('t','codebuff','m');",
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO messages VALUES ('t',0,'assistant',1800000000,'{\"usage\":{\"inputTokens\":10,\"outputTokens\":5,\"model\":\"model-a\"}}','')",
                [],
            )
            .unwrap();
        drop(connection);
        let receipts = vec![Receipt {
            id: "cloud:r1".into(),
            timestamp_ms: 1_800_000_000_000.0,
            metrics_json: r#"{"usage":{"inputTokens":20,"outputTokens":10,"model":"model-a"}}"#
                .into(),
            model: Some("model-a".into()),
        }];
        let scan = FreebuffScanner::with_home(dir.path().to_path_buf())
            .scan(
                1_800_000_100.0,
                &pricing(),
                &CatalogEntries::new(),
                &receipts,
                &CancelToken::new(),
            )
            .unwrap();
        assert_eq!(
            scan.usage
                .series
                .daily
                .iter()
                .map(|day| day.total_tokens)
                .sum::<i64>(),
            45
        );
    }
}
