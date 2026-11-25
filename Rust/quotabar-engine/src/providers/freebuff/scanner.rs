//! Freebuff local and hosted token history (`FreebuffDesktopUsageScanner`,
//! `FreebuffHostedUsageScanner`).
//!
//! Desktop project databases store only measured token counts on assistant messages and independent
//! mission-manager receipts. Hosted history contributes receipts for Cloud and On This Device runs.
//! Transcript content is never decoded or retained.

use super::auth::FreebuffAuth;
use super::client::{ClientError, FreebuffClient};
use crate::accounting::{day_key, DailyUsageAccumulator, LogUsageScan};
use crate::context::CancelToken;
use crate::host;
use crate::model::ModelUsageEntry;
use crate::pricing::{ModelPricing, TokenBreakdown};
use crate::qlog;
use crate::time::parse_iso8601;
use rusqlite::{Connection, OpenFlags};
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

#[derive(Clone)]
struct CachedTurns {
    revision: Revision,
    rows: Vec<DerivedTurn>,
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
struct DerivedTurn {
    id: String,
    timestamp_ms: f64,
    usage: Option<Usage>,
    saved_model: Option<String>,
    from_receipt: bool,
    partial: bool,
}

#[derive(Clone, Debug)]
struct Usage {
    input: Count,
    output: Count,
    cached: Count,
    reasoning: Count,
    reported_total: Count,
}

#[derive(Clone, Copy, Debug)]
enum Count {
    Absent,
    Value(i64),
    Invalid,
}

impl Count {
    fn required(self) -> Option<i64> {
        match self {
            Count::Value(value) => Some(value),
            _ => None,
        }
    }

    fn optional(self) -> Option<i64> {
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
        for path in paths {
            if cancel.is_cancelled() {
                return None;
            }
            let Some(current) = revision(&path) else {
                continue;
            };
            let cached = self
                .turns
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .get(&path)
                .filter(|cached| cached.revision == current)
                .cloned();
            let rows = match cached {
                Some(cached) => cached.rows,
                None => {
                    let rows = read_local_turns(&path).ok()?;
                    let after = revision(&path);
                    if after.as_ref() != Some(&current) {
                        // The database changed during the read; publish nothing this pass.
                        return None;
                    }
                    self.turns.lock().unwrap_or_else(|e| e.into_inner()).insert(
                        path,
                        CachedTurns {
                            revision: current,
                            rows: rows.clone(),
                        },
                    );
                    rows
                }
            };
            turns.extend(rows);
        }
        Some(fold_turns(turns, now, pricing))
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

    pub fn unload_caches(&self) {
        self.turns.lock().unwrap_or_else(|e| e.into_inner()).clear();
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

fn read_local_turns(path: &Path) -> Result<Vec<DerivedTurn>, rusqlite::Error> {
    let connection = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    let mut include_managers = true;
    let mut include_snapshot = true;
    loop {
        let sql = rows_sql(include_managers, include_snapshot);
        match connection.query_row(&sql, [], |row| row.get::<_, Option<String>>(0)) {
            Ok(Some(text)) => {
                let rows: Vec<Value> = serde_json::from_str(&text).unwrap_or_default();
                let mut turns = Vec::with_capacity(rows.len());
                for row in rows {
                    let Some(object) = row.as_object() else {
                        continue;
                    };
                    let id = text_of(object.get("id"));
                    let timestamp = text_of(object.get("timestamp"));
                    let metrics = text_of(object.get("metrics"));
                    let selected = text_of(object.get("selectedModel"));
                    if let Some(turn) = derive_turn(&id, &timestamp, &metrics, &selected) {
                        turns.push(turn);
                    }
                }
                return Ok(turns);
            }
            Ok(None) => return Ok(Vec::new()),
            Err(error) => {
                let message = error.to_string().to_lowercase();
                if include_managers && message.contains("no such table: auto_run_decision_receipts")
                {
                    include_managers = false;
                } else if include_snapshot && message.contains("no such column: t.world_snapshot") {
                    include_snapshot = false;
                } else {
                    return Err(error);
                }
            }
        }
    }
}

fn rows_sql(include_managers: bool, include_snapshot: bool) -> String {
    let selected = if include_snapshot {
        "COALESCE(NULLIF(t.model, ''), CASE WHEN json_valid(t.world_snapshot) THEN json_extract(t.world_snapshot, '$.model') END, '')"
    } else {
        "COALESCE(t.model, '')"
    };
    let managers = if include_managers {
        format!(
            r#"
      UNION ALL
      SELECT
        COALESCE('mission-manager:' || r.thread_id || ':' || CAST(r.id AS TEXT), '') AS id,
        COALESCE(CAST(json_extract(r.manager_json, '$.startedAt') AS TEXT), CAST(r.created_at AS TEXT), '') AS timestamp,
        json_object(
          'usage', json(json_set(json_extract(r.manager_json, '$.usage'), '$.model', json_extract(r.manager_json, '$.model'))),
          'usageIncomplete', COALESCE(json_extract(r.manager_json, '$.usageIncomplete'), 0)
        ) || '' AS metrics,
        {selected} AS selectedModel
      FROM auto_run_decision_receipts r JOIN threads t ON t.id = r.thread_id
      WHERE t.harness_id = 'codebuff'
        AND json_extract(r.manager_json, '$.harnessId') = 'codebuff'
        AND json_type(r.manager_json, '$.usage') = 'object'"#
        )
    } else {
        String::new()
    };
    format!(
        r#"SELECT COALESCE(json_group_array(json_object(
          'id', id, 'timestamp', timestamp, 'metrics', metrics, 'selectedModel', selectedModel
        )), '[]') FROM (
          SELECT
            COALESCE(CASE WHEN m.request_id LIKE 'cloud:%' THEN m.request_id
              ELSE m.thread_id || ':' || m.seq END, '') AS id,
            COALESCE(CAST(m.ts AS TEXT), '') AS timestamp,
            COALESCE(NULLIF(m.metrics_json, ''), '{{}}') AS metrics,
            {selected} AS selectedModel
          FROM messages m JOIN threads t ON t.id = m.thread_id
          WHERE t.harness_id = 'codebuff' AND m.role = 'assistant'
          {managers}
        )"#
    )
}

fn derive_turn(
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

fn text_of(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(value)) => value.clone(),
        Some(Value::Null) | None => String::new(),
        Some(other) => other.to_string(),
    }
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

fn fold_turns(turns: Vec<DerivedTurn>, now: f64, pricing: &ModelPricing) -> FreebuffScan {
    let mut accumulator = DailyUsageAccumulator::new();
    let mut partial_days = std::collections::BTreeSet::new();
    let mut seen: HashSet<String> = HashSet::new();
    for turn in turns {
        if seen.contains(&turn.id) {
            continue;
        }
        let timestamp = turn.timestamp_ms / 1000.0;
        if timestamp > now {
            continue;
        }
        let day = day_key(timestamp);
        let Some(usage) = turn.usage else {
            if turn.partial {
                partial_days.insert(day);
            }
            continue;
        };
        let (Some(input), Some(output), Some(cached), Some(reasoning)) = (
            usage.input.required(),
            usage.output.required(),
            usage.cached.optional(),
            usage.reasoning.optional(),
        ) else {
            continue;
        };
        let total = input.saturating_add(output);
        if total <= 0 || cached > input || reasoning > output {
            continue;
        }
        if let Count::Value(reported) = usage.reported_total {
            if reported != total {
                continue;
            }
        } else if matches!(usage.reported_total, Count::Invalid) {
            continue;
        }
        seen.insert(turn.id);
        let saved = turn
            .saved_model
            .as_deref()
            .filter(|value| !value.is_empty());
        let legacy_without_identity = saved.is_none()
            || (!turn.from_receipt
                && saved
                    .is_some_and(|value| value.starts_with("m-") || value.starts_with("fbm1.")));
        let model = if legacy_without_identity && saved.is_none() {
            OLDER_USAGE_NAME.to_string()
        } else {
            saved.unwrap_or(ModelUsageEntry::UNATTRIBUTED).to_string()
        };
        let tokens = TokenBreakdown {
            input: input - cached,
            cache_read: cached,
            output,
            ..Default::default()
        };
        let cost = pricing.estimated_cost_dollars(&model, &tokens, Some(timestamp), false);
        accumulator.add(&day, total, cost, &model);
        match cost {
            Some(cost) => {
                accumulator.mark_estimated_cost(&day);
                accumulator.add_api_estimate(&day, cost);
            }
            None if legacy_without_identity => accumulator.add_named_unpriced_model(&day, &model),
            None => accumulator.add_unknown_model(&day, &model),
        }
        if turn.partial {
            partial_days.insert(day);
        }
    }
    let mut usage = accumulator.build();
    if !partial_days.is_empty() {
        usage = usage.marking_unmeasured_usage(&partial_days);
    }
    FreebuffScan {
        usage,
        partial_days,
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
        ModelPricing::new(
            PricingSupplement::default(),
            PricingCatalog::from_entries(entries),
            PricingCatalog::default(),
            PricingCatalog::default(),
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
            .scan(1_800_000_200.0, &pricing(), &[], &CancelToken::new())
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
            .scan(1_800_000_200.0, &pricing(), &[], &CancelToken::new())
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
            .scan(1_800_000_100.0, &pricing(), &receipts, &CancelToken::new())
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
