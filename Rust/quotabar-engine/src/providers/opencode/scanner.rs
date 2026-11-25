//! OpenCode local SQLite usage plus the hosted gateway folds
//! (`Providers/OpenCode/OpenCodeUsageScanner`).
//!
//! Costs OpenCode records for its own Go/Zen gateways are authoritative and summed directly. Turns
//! served by other local agents (Claude Code, Codex, Hermes, Muse) never land in `opencode*.db`; they
//! are folded in with measured tokens and imputed dollars so the spend tiles and Go windows describe
//! the same account usage the provider card does.

use super::mapper::{compute_windows, GoWindows};
use crate::accounting::{
    day_key, DailyUsageAccumulator, LogUsageScan, RowOptions, UsageHistoryWindow,
};
use crate::context::CancelToken;
use crate::host;
use crate::model::ModelUsageEntry;
use crate::pricing::{ModelPricing, TokenBreakdown};
use crate::qlog;
use crate::sqlite;
use chrono::TimeZone;
use serde_json::Value;
use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

pub const HOSTED_PROVIDER_IDS: [&str; 2] = ["opencode-go", "opencode"];
pub const GO_PROVIDER_ID: &str = "opencode-go";

#[derive(Clone, Debug, PartialEq)]
pub struct OpenCodeScan {
    pub log_scan: LogUsageScan,
    pub go_windows: Option<GoWindows>,
    pub includes_estimated_cost: bool,
    pub partial_days: BTreeSet<String>,
}

#[derive(Clone, Default)]
pub struct FoldSources {
    pub claude_roots: Vec<PathBuf>,
    pub codex_homes: Vec<PathBuf>,
    pub hermes_state_db: Option<PathBuf>,
    pub muse_roots: Vec<PathBuf>,
    pub router_ledger_paths: Vec<PathBuf>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ScanError {
    DatabaseUnreadable,
    Incomplete(String),
    Cancelled,
}

#[derive(Clone, Debug, PartialEq)]
struct Row {
    ms: f64,
    /// Local calendar day of `ms`; computed once when the row is parsed so an unchanged cached
    /// database does not reformat a day key for every row on every refresh.
    day: String,
    cost: Option<f64>,
    tokens: i64,
    saturated: bool,
    model: String,
    provider: String,
}

struct FoldState {
    since: f64,
    max_timestamp: f64,
    pricing: std::sync::Arc<ModelPricing>,
    rates: HashMap<(String, String), f64>,
    accumulator: DailyUsageAccumulator,
    go_costs: Vec<(f64, f64)>,
    estimated: bool,
    partial_days: BTreeSet<String>,
}

impl FoldState {
    fn add_gateway(
        &mut self,
        timestamp: f64,
        model: &str,
        provider: &str,
        tokens: TokenBreakdown,
        recorded_cost: Option<f64>,
        is_aggregated: bool,
        token_count_saturated: bool,
        in_progress: bool,
        incomplete_accounting: bool,
    ) {
        if timestamp < self.since || timestamp > self.max_timestamp {
            return;
        }
        let total = tokens.input
            + tokens.cache_write_5m
            + tokens.cache_write_1h
            + tokens.cache_read
            + tokens.output;
        if total <= 0 && recorded_cost.unwrap_or(0.0) <= 0.0 {
            return;
        }
        let day = day_key(timestamp);
        if in_progress {
            self.partial_days.insert(day.clone());
        }
        let api_estimate =
            self.pricing
                .estimated_cost_dollars(model, &tokens, Some(timestamp), !is_aggregated);
        let rate = self
            .rates
            .get(&(model.to_string(), provider.to_string()))
            .copied();
        let cost = recorded_cost
            .filter(|cost| cost.is_finite() && *cost >= 0.0)
            .or_else(|| rate.map(|rate| rate * total as f64))
            .or(api_estimate);
        if incomplete_accounting || token_count_saturated {
            self.accumulator.record_api_estimate(&day, None, total);
        } else {
            self.accumulator
                .record_api_estimate(&day, api_estimate, total);
        }
        match cost {
            Some(cost) => {
                self.accumulator.add_with(
                    &day,
                    total,
                    Some(cost),
                    model,
                    RowOptions {
                        token_count_saturated,
                        ..RowOptions::default()
                    },
                );
                self.accumulator.mark_estimated_cost(&day);
                if incomplete_accounting || token_count_saturated {
                    self.accumulator.mark_cost_incomplete(&day, model, None);
                } else if provider == GO_PROVIDER_ID {
                    self.go_costs.push((timestamp * 1000.0, cost));
                }
                self.estimated = true;
            }
            None => {
                if !incomplete_accounting && !token_count_saturated {
                    self.accumulator.add_unknown_model(&day, model);
                }
                self.accumulator.add_with(
                    &day,
                    total,
                    None,
                    model,
                    RowOptions {
                        token_count_saturated,
                        ..RowOptions::default()
                    },
                );
            }
        }
        if in_progress {
            self.accumulator
                .mark_model_cost_incomplete(&day, model, None);
        }
    }
}

const MAX_FUTURE_SECS: f64 = 5.0 * 60.0;

pub fn scan(
    database_paths: &[PathBuf],
    days_back: usize,
    now: f64,
    pricing: std::sync::Arc<ModelPricing>,
    sources: &FoldSources,
    cancel: &CancelToken,
) -> Result<Option<OpenCodeScan>, ScanError> {
    if cancel.is_cancelled() {
        return Err(ScanError::Cancelled);
    }
    let since = since_date(days_back, now);
    let cutoff_ms = (since * 1000.0).floor() as i64;
    let maximum_timestamp = now + MAX_FUTURE_SECS;
    let mut row_sets: Vec<Arc<Vec<Row>>> = Vec::new();
    let mut anchor_ms: Option<f64> = None;
    let mut failures = Vec::new();
    for path in database_paths {
        if cancel.is_cancelled() {
            return Err(ScanError::Cancelled);
        }
        let signature = crate::sqlite::source_signature(path);
        let cached = database_cache()
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .get(path)
            .filter(|entry| entry.cutoff_ms == cutoff_ms && entry.signature == signature)
            .map(|entry| (entry.rows.clone(), entry.anchor_ms));
        if let Some((rows, cached_anchor)) = cached {
            if let Some(value) = cached_anchor.filter(|value| value.is_finite()) {
                anchor_ms = Some(anchor_ms.map_or(value, |existing| existing.min(value)));
            }
            row_sets.push(rows);
            continue;
        }
        let schema = match detect_schema(path) {
            Ok(schema) => schema,
            Err(error) => {
                failures.push(format!("{}: {error}", path.display()));
                continue;
            }
        };
        let parsed = match query_rows(path, schema, since) {
            Ok(parsed) => parsed,
            Err(error) => {
                failures.push(format!("{}: {error}", path.display()));
                continue;
            }
        };
        if cancel.is_cancelled() {
            return Err(ScanError::Cancelled);
        }
        let anchor = query_anchor(path, schema);
        let cacheable = anchor.is_ok();
        let anchor = anchor.unwrap_or_else(|error| {
            let gate = format!("opencode.anchor.{}", path.display());
            host::diagnostic_gate::log_once(&gate, || {
                qlog!(
                    Warn,
                    host::plugin_tag("opencode"),
                    "anchor query failed for {}: {error} — monthly window falls back to calendar month",
                    path.display()
                );
            });
            None
        });
        if let Some(value) = anchor.filter(|value| value.is_finite()) {
            anchor_ms = Some(anchor_ms.map_or(value, |existing| existing.min(value)));
        }
        let rows = Arc::new(parsed);
        if cacheable {
            let mut cache = database_cache()
                .lock()
                .unwrap_or_else(|error| error.into_inner());
            if cache.len() >= 8 && !cache.contains_key(path) {
                cache.clear();
            }
            cache.insert(
                path.clone(),
                CachedDatabase {
                    signature,
                    cutoff_ms,
                    rows: rows.clone(),
                    anchor_ms: anchor,
                },
            );
        }
        row_sets.push(rows);
    }
    if !failures.is_empty() {
        for failure in &failures {
            qlog!(
                Warn,
                host::plugin_tag("opencode"),
                "usage query failed: {failure}"
            );
        }
        return Err(ScanError::DatabaseUnreadable);
    }
    if cancel.is_cancelled() {
        return Err(ScanError::Cancelled);
    }
    let tile_since = since_date(UsageHistoryWindow::PREVIOUS_DAYS, now);
    let rates = effective_rates(row_sets.iter().flat_map(|rows| rows.iter()), tile_since);
    let mut accumulator = DailyUsageAccumulator::new();
    let row_count: usize = row_sets.iter().map(|rows| rows.len()).sum();
    let mut go_costs: Vec<(f64, f64)> = Vec::with_capacity(row_count);
    for row in row_sets.iter().flat_map(|rows| rows.iter()) {
        if row.ms / 1000.0 < since {
            continue;
        }
        accumulator.add_with(
            &row.day,
            row.tokens,
            row.cost,
            &row.model,
            RowOptions {
                token_count_saturated: row.saturated,
                ..RowOptions::default()
            },
        );
        if row.provider == GO_PROVIDER_ID {
            if let Some(cost) = row.cost {
                go_costs.push((row.ms, cost));
            }
        }
    }
    let mut state = FoldState {
        since,
        max_timestamp: maximum_timestamp,
        pricing: pricing.clone(),
        rates,
        accumulator,
        go_costs,
        estimated: false,
        partial_days: BTreeSet::new(),
    };
    fold_claude(&mut state, &sources.claude_roots, now, cancel)?;
    fold_codex(&mut state, &sources.codex_homes, now, cancel)?;
    fold_router(&mut state, &sources.router_ledger_paths, now, cancel)?;
    fold_hermes(&mut state, sources.hermes_state_db.as_deref(), cancel)?;
    fold_muse(&mut state, &sources.muse_roots, now, cancel)?;
    if cancel.is_cancelled() {
        return Err(ScanError::Cancelled);
    }
    let go_windows = (!state.go_costs.is_empty()).then(|| {
        let now_dt = chrono::Utc
            .timestamp_opt(now as i64, 0)
            .single()
            .unwrap_or_else(chrono::Utc::now);
        compute_windows(&state.go_costs, anchor_ms, now_dt)
    });
    Ok(Some(OpenCodeScan {
        log_scan: state.accumulator.build(),
        go_windows,
        includes_estimated_cost: state.estimated,
        partial_days: state.partial_days,
    }))
}

fn since_date(days_back: usize, now: f64) -> f64 {
    let days = days_back.max(1);
    let now_date = crate::accounting::DayZone::Local.local_date(now);
    let Some(now_date) = now_date else {
        return now - days as f64 * 86_400.0;
    };
    let start = now_date - chrono::Duration::days((days - 1) as i64);
    use chrono::Datelike;
    chrono::Local
        .with_ymd_and_hms(start.year(), start.month(), start.day(), 0, 0, 0)
        .single()
        .map(|date| date.timestamp() as f64)
        .unwrap_or(now - days as f64 * 86_400.0)
}

fn effective_rates<'a>(
    rows: impl Iterator<Item = &'a Row>,
    tile_since: f64,
) -> HashMap<(String, String), f64> {
    // Borrow each row's model/provider while totalling: the common case is thousands of rows for a
    // handful of routes, so cloning the pair per row was pure allocation churn.
    let mut totals: HashMap<(&'a str, &'a str), (f64, f64)> = HashMap::new();
    for row in rows {
        if row.ms / 1000.0 < tile_since
            || row.tokens <= 0
            || row.saturated
            || row.cost.is_none()
            || row
                .model
                .eq_ignore_ascii_case(ModelUsageEntry::UNATTRIBUTED)
        {
            continue;
        }
        if row.model.starts_with("muse-")
            || row.model == "deepseek-v4-pro"
            || row.model == "deepseek/deepseek-v4-pro"
            || row.model == "space-bunny-free"
        {
            continue;
        }
        let entry = totals
            .entry((row.model.as_str(), row.provider.as_str()))
            .or_insert((0.0, 0.0));
        entry.0 += row.cost.unwrap_or(0.0);
        entry.1 += row.tokens as f64;
    }
    totals
        .into_iter()
        .filter_map(|((model, provider), (cost, tokens))| {
            (tokens > 0.0 && cost.is_finite()).then(|| {
                (
                    (model.to_string(), provider.to_string()),
                    (cost / tokens).clamp(0.0, 1e-3),
                )
            })
        })
        .collect()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Schema {
    Legacy,
    V2,
    Mixed,
    Unknown,
}

impl Schema {
    fn reads_v2(self) -> bool {
        matches!(self, Schema::V2 | Schema::Mixed)
    }

    fn reads_legacy(self) -> bool {
        matches!(self, Schema::Legacy | Schema::Mixed | Schema::Unknown)
    }

    fn effective(self) -> Schema {
        if self == Schema::Unknown {
            Schema::Legacy
        } else {
            self
        }
    }
}

fn detect_schema(path: &Path) -> Result<Schema, String> {
    let sql = "SELECT group_concat(name) FROM sqlite_master WHERE type='table' AND name IN ('message','session_message');";
    let output = sqlite::query_value(path, sql).map_err(|error| error.to_string())?;
    let names: BTreeSet<&str> = output
        .as_deref()
        .unwrap_or("")
        .split(',')
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .collect();
    Ok(
        match (names.contains("message"), names.contains("session_message")) {
            (true, true) => Schema::Mixed,
            (true, false) => Schema::Legacy,
            (false, true) => Schema::V2,
            (false, false) => Schema::Unknown,
        },
    )
}

struct CachedDatabase {
    signature: crate::sqlite::SourceSignature,
    cutoff_ms: i64,
    rows: Arc<Vec<Row>>,
    anchor_ms: Option<f64>,
}

fn database_cache() -> &'static Mutex<HashMap<PathBuf, CachedDatabase>> {
    static CACHE: OnceLock<Mutex<HashMap<PathBuf, CachedDatabase>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Release the parsed-row cache for account switches and memory-pressure unloads.
pub fn clear_database_cache() {
    database_cache()
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .clear();
}

fn query_rows(path: &Path, schema: Schema, since: f64) -> Result<Vec<Row>, String> {
    let cutoff_ms = (since * 1000.0).floor() as i64;
    let sql = data_sql(schema.effective(), cutoff_ms);
    let mut rows = Vec::new();
    sqlite::for_each_row_within(
        path,
        &sql,
        true,
        std::time::Duration::from_secs(30),
        |row| parse_row(row, &mut rows),
    )
    .map_err(|error| error.to_string())?;
    Ok(rows)
}

fn parse_row(row: &rusqlite::Row<'_>, rows: &mut Vec<Row>) -> Result<(), String> {
    use rusqlite::types::ValueRef;
    let ms = match row.get_ref(0).map_err(|error| error.to_string())? {
        ValueRef::Integer(value) => value as f64,
        ValueRef::Real(value) => value,
        _ => return Err("usage row has an invalid timestamp".into()),
    };
    if !ms.is_finite() || ms < 0.0 {
        return Err("usage row has an invalid timestamp".into());
    }
    let cost = match row.get_ref(1).map_err(|error| error.to_string())? {
        ValueRef::Integer(value) => Some(value as f64).filter(|value| *value >= 0.0),
        ValueRef::Real(value) => Some(value).filter(|value| value.is_finite() && *value >= 0.0),
        _ => None,
    };
    let raw_tokens = match row.get_ref(2).map_err(|error| error.to_string())? {
        ValueRef::Integer(value) => value as f64,
        ValueRef::Real(value) => value,
        _ => return Err("usage row has an invalid token total".into()),
    };
    if !raw_tokens.is_finite() || raw_tokens < 0.0 || raw_tokens.trunc() != raw_tokens {
        return Err("usage row has an invalid token total".into());
    }
    let saturated = raw_tokens > 1e15;
    let tokens = raw_tokens.min(1e15) as i64;
    if tokens == 0 && cost.unwrap_or(0.0) == 0.0 {
        return Ok(());
    }
    let model = match row.get_ref(3).map_err(|error| error.to_string())? {
        ValueRef::Null => ModelUsageEntry::UNATTRIBUTED.to_string(),
        ValueRef::Text(value) => {
            let value = String::from_utf8_lossy(value);
            let trimmed = value.trim();
            if trimmed.is_empty() {
                ModelUsageEntry::UNATTRIBUTED.to_string()
            } else {
                trimmed.to_string()
            }
        }
        _ => return Err("usage row has an invalid model".into()),
    };
    let provider = match row.get_ref(4).map_err(|error| error.to_string())? {
        ValueRef::Text(value) => String::from_utf8_lossy(value).into_owned(),
        _ => return Err("usage row has an invalid provider".into()),
    };
    rows.push(Row {
        ms,
        day: day_key(ms / 1000.0),
        cost,
        tokens,
        saturated,
        model,
        provider,
    });
    Ok(())
}

#[cfg(test)]
fn parse_rows(text: &str) -> Result<Vec<Row>, String> {
    let Value::Array(entries) = serde_json::from_str::<serde_json::Value>(text)
        .map_err(|error| format!("usage rows are not JSON: {error}"))?
    else {
        return Err("usage rows are not an array".into());
    };
    let mut rows = Vec::with_capacity(entries.len());
    for entry in entries {
        let Value::Array(fields) = entry else {
            return Err("usage row is not an array".into());
        };
        if fields.len() < 5 {
            return Err("usage row has fewer than five fields".into());
        }
        let Some(ms) = fields[0].as_f64().filter(|value| *value >= 0.0) else {
            return Err("usage row has an invalid timestamp".into());
        };
        let Some(raw_tokens) = fields[2]
            .as_f64()
            .filter(|value| *value >= 0.0 && value.trunc() == *value)
        else {
            return Err("usage row has an invalid token total".into());
        };
        let Some(provider) = fields[4].as_str() else {
            return Err("usage row has an invalid provider".into());
        };
        let saturated = raw_tokens > 1e15;
        let tokens = raw_tokens.min(1e15) as i64;
        let cost = fields[1].as_f64().filter(|value| *value >= 0.0);
        if tokens == 0 && cost.unwrap_or(0.0) == 0.0 {
            continue;
        }
        let model = match &fields[3] {
            serde_json::Value::Null => ModelUsageEntry::UNATTRIBUTED.to_string(),
            serde_json::Value::String(value) => {
                let trimmed = value.trim();
                if trimmed.is_empty() {
                    ModelUsageEntry::UNATTRIBUTED.to_string()
                } else {
                    trimmed.to_string()
                }
            }
            _ => return Err("usage row has an invalid model".into()),
        };
        rows.push(Row {
            ms,
            day: day_key(ms / 1000.0),
            cost,
            tokens,
            saturated,
            model,
            provider: provider.to_string(),
        });
    }
    Ok(rows)
}

fn query_anchor(path: &Path, schema: Schema) -> Result<Option<f64>, String> {
    let branches = {
        let mut parts = Vec::new();
        if schema.effective().reads_v2() {
            parts.push(
                "SELECT time_created FROM session_message WHERE type = 'assistant' AND json_valid(data) \
                 AND COALESCE(json_extract(data,'$.model.providerID'), json_extract(data,'$.providerID')) = 'opencode-go' \
                 AND json_type(data,'$.cost') IN ('integer','real')",
            );
        }
        if schema.effective().reads_legacy() {
            parts.push(
                "SELECT time_created FROM message WHERE json_extract(data,'$.role') = 'assistant' AND json_valid(data) \
                 AND COALESCE(json_extract(data,'$.providerID'), json_extract(data,'$.model.providerID')) = 'opencode-go' \
                 AND json_type(data,'$.cost') IN ('integer','real')",
            );
        }
        parts.join(" UNION ALL ")
    };
    let sql = format!("SELECT MIN(time_created) FROM ({branches});");
    let value = sqlite::query_value(path, &sql).map_err(|error| error.to_string())?;
    Ok(value.and_then(|text| text.trim().parse::<f64>().ok()))
}

fn data_sql(schema: Schema, cutoff_ms: i64) -> String {
    let providers = "('opencode-go','opencode')";
    let token_total = r#"
        CASE
            WHEN total_type IN ('integer','real') AND total > 0 THEN total
            WHEN tokens_type = 'object'
              AND (total_type IS NULL OR total_type = 'null' OR (total_type IN ('integer','real') AND total = 0))
              AND input_type IN ('integer','real') AND input_tokens >= 0
              AND output_type IN ('integer','real') AND output_tokens >= 0
              AND (reasoning_type IS NULL OR reasoning_type = 'null' OR (reasoning_type IN ('integer','real') AND reasoning_tokens >= 0))
              AND (cache_type IS NULL OR cache_type IN ('null','object'))
              AND (cache_read_type IS NULL OR cache_read_type = 'null' OR (cache_read_type IN ('integer','real') AND cache_read_tokens >= 0))
              AND (cache_write_type IS NULL OR cache_write_type = 'null' OR (cache_write_type IN ('integer','real') AND cache_write_tokens >= 0))
            THEN COALESCE(input_tokens,0) + COALESCE(output_tokens,0) + COALESCE(reasoning_tokens,0)
               + COALESCE(cache_read_tokens,0) + COALESCE(cache_write_tokens,0)
            WHEN tokens_absent_is_zero = 1 AND (tokens_type IS NULL OR tokens_type = 'null')
              AND (cost_type IS NULL OR cost_type = 'null' OR (cost_type IN ('integer','real') AND cost = 0)) THEN 0
            ELSE -1
        END
    "#;
    let mut branches = Vec::new();
    if schema.reads_v2() {
        branches.push(format!(
            r#"
            SELECT time_created,
                   json_type(data,'$.cost') AS cost_type,
                   json_extract(data,'$.cost') AS cost,
                   json_type(data,'$.tokens') AS tokens_type,
                   json_type(data,'$.tokens.total') AS total_type,
                   json_extract(data,'$.tokens.total') AS total,
                   json_type(data,'$.tokens.input') AS input_type,
                   json_extract(data,'$.tokens.input') AS input_tokens,
                   json_type(data,'$.tokens.output') AS output_type,
                   json_extract(data,'$.tokens.output') AS output_tokens,
                   json_type(data,'$.tokens.reasoning') AS reasoning_type,
                   json_extract(data,'$.tokens.reasoning') AS reasoning_tokens,
                   json_type(data,'$.tokens.cache') AS cache_type,
                   json_type(data,'$.tokens.cache.read') AS cache_read_type,
                   json_extract(data,'$.tokens.cache.read') AS cache_read_tokens,
                   json_type(data,'$.tokens.cache.write') AS cache_write_type,
                   json_extract(data,'$.tokens.cache.write') AS cache_write_tokens,
                   COALESCE(json_extract(data,'$.model.id'), json_extract(data,'$.modelID')) AS model_id,
                   COALESCE(json_extract(data,'$.model.providerID'), json_extract(data,'$.providerID')) AS provider_id,
                   1 AS tokens_absent_is_zero
            FROM session_message
            WHERE type = 'assistant' AND time_created >= {cutoff_ms} AND json_valid(data)
              AND COALESCE(json_extract(data,'$.model.providerID'), json_extract(data,'$.providerID')) IN {providers}
            "#
        ));
    }
    if schema.reads_legacy() {
        let dedupe = if schema == Schema::Mixed {
            "AND NOT EXISTS (SELECT 1 FROM session_message AS migrated WHERE migrated.id = message.id)"
        } else {
            ""
        };
        branches.push(format!(
            r#"
            SELECT time_created,
                   json_type(data,'$.cost') AS cost_type,
                   json_extract(data,'$.cost') AS cost,
                   json_type(data,'$.tokens') AS tokens_type,
                   json_type(data,'$.tokens.total') AS total_type,
                   json_extract(data,'$.tokens.total') AS total,
                   json_type(data,'$.tokens.input') AS input_type,
                   json_extract(data,'$.tokens.input') AS input_tokens,
                   json_type(data,'$.tokens.output') AS output_type,
                   json_extract(data,'$.tokens.output') AS output_tokens,
                   json_type(data,'$.tokens.reasoning') AS reasoning_type,
                   json_extract(data,'$.tokens.reasoning') AS reasoning_tokens,
                   json_type(data,'$.tokens.cache') AS cache_type,
                   json_type(data,'$.tokens.cache.read') AS cache_read_type,
                   json_extract(data,'$.tokens.cache.read') AS cache_read_tokens,
                   json_type(data,'$.tokens.cache.write') AS cache_write_type,
                   json_extract(data,'$.tokens.cache.write') AS cache_write_tokens,
                   COALESCE(json_extract(data,'$.modelID'), json_extract(data,'$.model.id')) AS model_id,
                   COALESCE(json_extract(data,'$.providerID'), json_extract(data,'$.model.providerID')) AS provider_id,
                   0 AS tokens_absent_is_zero
            FROM message
            WHERE json_extract(data,'$.role') = 'assistant' AND time_created >= {cutoff_ms} AND json_valid(data)
              AND COALESCE(json_extract(data,'$.providerID'), json_extract(data,'$.model.providerID')) IN {providers}
              {dedupe}
            "#
        ));
    }
    format!(
        "WITH source AS ({} ) SELECT time_created, \
         CASE WHEN tokens_absent_is_zero = 1 AND (tokens_type IS NULL OR tokens_type = 'null') \
                   AND (cost_type IS NULL OR cost_type = 'null') THEN 0 \
              WHEN cost_type IS NULL OR cost_type = 'null' THEN NULL \
              WHEN cost_type IN ('integer','real') AND cost >= 0 THEN cost ELSE -1 END, \
         {token_total}, model_id, provider_id FROM source;",
        branches.join(" UNION ALL ")
    )
}

fn fold_claude(
    state: &mut FoldState,
    roots: &[PathBuf],
    now: f64,
    cancel: &CancelToken,
) -> Result<(), ScanError> {
    if roots.is_empty() {
        return Ok(());
    }
    let config = crate::providers::claude::ClaudeLogConfig::live();
    let scanner = crate::providers::claude::ClaudeLogScanner::new(config);
    let days = UsageHistoryWindow::lifetime_days(now, crate::accounting::DayZone::Local);
    let Some(entries) = scanner.gateway_entries(days, now, Some(roots.to_vec()), cancel) else {
        return Err(ScanError::Incomplete("Claude sessions".into()));
    };
    for entry in entries {
        let Some(model) = entry.model.as_deref() else {
            continue;
        };
        let provider = if crate::providers::claude::is_opencode_go_gateway_model(model) {
            GO_PROVIDER_ID
        } else {
            HOSTED_PROVIDER_IDS[1]
        };
        state.add_gateway(
            entry.timestamp,
            model,
            provider,
            entry.tokens.clone(),
            entry.cost_usd,
            false,
            false,
            false,
            false,
        );
    }
    Ok(())
}

fn fold_codex(
    state: &mut FoldState,
    homes: &[PathBuf],
    now: f64,
    cancel: &CancelToken,
) -> Result<(), ScanError> {
    if homes.is_empty() {
        return Ok(());
    }
    let days = UsageHistoryWindow::lifetime_days(now, crate::accounting::DayZone::Local);
    let scanner = crate::providers::codex::CodexSessionScanner::new(
        crate::paths::home(),
        homes.to_vec(),
        Vec::new(),
        None,
    );
    let Some(events) = scanner.hosted_gateway_events(days, now, cancel) else {
        return Err(ScanError::Incomplete("Codex sessions".into()));
    };
    for event in events {
        let model = event.model.trim();
        if model.is_empty() {
            continue;
        }
        let tokens = TokenBreakdown {
            input: (event.input - event.cached).max(0),
            cache_write_5m: 0,
            cache_write_1h: 0,
            cache_read: event.cached.max(0),
            output: event.output,
            is_fast: event.is_fast,
        };
        let provider = if crate::providers::claude::is_opencode_go_gateway_model(model) {
            GO_PROVIDER_ID
        } else {
            HOSTED_PROVIDER_IDS[1]
        };
        state.add_gateway(
            event.timestamp,
            model,
            provider,
            tokens,
            None,
            false,
            false,
            false,
            !event.has_complete_cost_breakdown,
        );
    }
    Ok(())
}

fn fold_router(
    state: &mut FoldState,
    paths: &[PathBuf],
    now: f64,
    cancel: &CancelToken,
) -> Result<(), ScanError> {
    if paths.is_empty() {
        return Ok(());
    }
    let scanner = crate::providers::codex::router::CodexRouterScanner::new(
        crate::paths::home(),
        paths.to_vec(),
        Vec::new(),
    );
    let days = UsageHistoryWindow::lifetime_days(now, crate::accounting::DayZone::Local);
    let Some(events) = scanner.opencode_events(days, now, cancel) else {
        return Err(ScanError::Incomplete("Router ledger".into()));
    };
    for event in events {
        let raw_model = event.model.trim();
        let (model, burns_go) = crate::providers::claude::CLAUDE_GATEWAY_PREFIXES
            .iter()
            .find_map(|prefix| {
                raw_model.strip_prefix(prefix).map(|rest| {
                    (
                        rest.trim(),
                        *prefix == crate::providers::claude::CLAUDE_GATEWAY_PREFIXES[0],
                    )
                })
            })
            .unwrap_or_else(|| {
                (
                    raw_model,
                    event.provider.to_ascii_lowercase().contains("opencode-go"),
                )
            });
        if model.is_empty() {
            continue;
        }
        let input = event.input.max(0);
        let cached = event.cached.clamp(0, input);
        let tokens = TokenBreakdown {
            input: input - cached,
            cache_write_5m: 0,
            cache_write_1h: 0,
            cache_read: cached,
            output: event.output.max(0),
            is_fast: false,
        };
        let provider = if burns_go {
            GO_PROVIDER_ID
        } else {
            HOSTED_PROVIDER_IDS[1]
        };
        state.add_gateway(
            event.timestamp,
            model,
            provider,
            tokens,
            None,
            false,
            event.token_count_saturated,
            false,
            !event.valid_numbers || event.estimated_input.unwrap_or(0) > 0,
        );
    }
    Ok(())
}

fn fold_hermes(
    state: &mut FoldState,
    path: Option<&Path>,
    cancel: &CancelToken,
) -> Result<(), ScanError> {
    let Some(path) = path else { return Ok(()) };
    if !path.exists() {
        return Err(ScanError::Incomplete("Hermes database".into()));
    }
    let cutoff = state.since;
    let sql = format!(
        "SELECT json_group_array(json_array(started_at, input_tokens, output_tokens, cache_read_tokens, \
         cache_write_tokens, reasoning_tokens, estimated_cost_usd, model, billing_provider, ended_at)) \
         FROM sessions WHERE started_at >= {cutoff:.3} AND \
         (COALESCE(LOWER(billing_provider), '') LIKE 'opencode%' OR COALESCE(LOWER(billing_base_url), '') LIKE '%opencode%');"
    );
    let Some(text) =
        sqlite::query_text_within(path, &sql, true, std::time::Duration::from_secs(30))
            .map_err(|_| ScanError::Incomplete("Hermes query".into()))?
    else {
        return Ok(());
    };
    let Value::Array(entries) = serde_json::from_str::<serde_json::Value>(&text)
        .map_err(|_| ScanError::Incomplete("Hermes rows".into()))?
    else {
        return Err(ScanError::Incomplete("Hermes rows".into()));
    };
    for entry in entries {
        if cancel.is_cancelled() {
            return Err(ScanError::Cancelled);
        }
        let Value::Array(fields) = entry else {
            return Err(ScanError::Incomplete("Hermes row".into()));
        };
        if fields.len() < 10 {
            return Err(ScanError::Incomplete("Hermes row".into()));
        }
        let Some(timestamp) = fields[0].as_f64() else {
            continue;
        };
        let count = |index: usize| fields[index].as_f64().unwrap_or(0.0).max(0.0) as i64;
        let tokens = TokenBreakdown {
            input: count(1),
            output: count(2),
            cache_read: count(3),
            cache_write_5m: count(4),
            cache_write_1h: 0,
            is_fast: false,
        };
        let model = fields[7]
            .as_str()
            .map(str::trim)
            .filter(|m| !m.is_empty())
            .unwrap_or(ModelUsageEntry::UNATTRIBUTED);
        let billing = fields[8].as_str().unwrap_or("").to_ascii_lowercase();
        let provider = if billing.starts_with("opencode") && !billing.contains("go") {
            HOSTED_PROVIDER_IDS[1]
        } else {
            GO_PROVIDER_ID
        };
        let ended = fields[9].as_f64().unwrap_or(0.0);
        let cost = fields[6].as_f64().filter(|value| *value > 0.0);
        state.add_gateway(
            timestamp,
            model,
            provider,
            tokens,
            cost,
            true,
            false,
            ended <= 0.0,
            false,
        );
    }
    Ok(())
}

fn fold_muse(
    state: &mut FoldState,
    roots: &[PathBuf],
    now: f64,
    cancel: &CancelToken,
) -> Result<(), ScanError> {
    if roots.is_empty() {
        return Ok(());
    }
    let scanner = crate::providers::muse::MuseUsageScanner::new(roots.to_vec(), None);
    let days = UsageHistoryWindow::lifetime_days(now, crate::accounting::DayZone::Local);
    let Some(entries) = scanner.parsed_entries_if_complete(days, now, cancel) else {
        return Err(ScanError::Incomplete("Muse sessions".into()));
    };
    for entry in entries {
        let model = entry
            .model
            .as_deref()
            .unwrap_or("muse-spark-1.2-contributor");
        state.add_gateway(
            entry.timestamp,
            model,
            GO_PROVIDER_ID,
            entry.tokens.clone(),
            None,
            false,
            false,
            false,
            false,
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_rows_and_rejects_malformed_accounting() {
        let text = r#"[[1780000000000,1.5,500,"gpt-5.5","opencode"],[1780000001000,null,0,"x","opencode-go"]]"#;
        let rows = parse_rows(text).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].tokens, 500);
        assert_eq!(rows[0].cost, Some(1.5));

        assert!(parse_rows(r#"[[1,1.5,-1,"x","opencode"]]"#).is_err());
    }
}
