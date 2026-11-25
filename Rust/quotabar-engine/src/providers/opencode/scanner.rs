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
use std::collections::{BTreeSet, HashMap, HashSet};
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
    /// Presence mirrors the Swift oracle: account cards mean positively attributed rows for disabled
    /// identities are excluded; no cards keeps legacy unscoped rows additive.
    pub enabled_codex_identity_keys: Option<BTreeSet<String>>,
    pub codex_home_identity_keys: HashMap<String, String>,
    /// Every router/account identifier alias for every registered Codex card, used to classify rows
    /// before the enabled-account filter.
    pub codex_account_identity_keys: HashMap<String, String>,
    /// Alias map restricted to enabled cards, used for router/native source reconciliation.
    pub router_account_identity_keys: HashMap<String, String>,
    pub claude_account_configs: Vec<crate::providers::claude::ClaudeProviderConfig>,
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
    day: Arc<str>,
    cost: Option<f64>,
    tokens: i64,
    saturated: bool,
    model: Arc<str>,
    provider: Arc<str>,
}

/// The database repeats a small set of dates, model names, and provider IDs across many rows.
/// Only the rows retain these strings after the query finishes.
#[derive(Default)]
struct RowStrings {
    dates: HashMap<Option<chrono::NaiveDate>, Arc<str>>,
    names: HashSet<Arc<str>>,
}

impl RowStrings {
    fn day(&mut self, timestamp: f64) -> Arc<str> {
        let date = crate::accounting::DayZone::Local.local_date(timestamp);
        self.dates
            .entry(date)
            .or_insert_with(|| {
                date.map_or_else(
                    || Arc::from("0000-00-00"),
                    |date| Arc::from(crate::accounting::day::format_day(date)),
                )
            })
            .clone()
    }

    fn name(&mut self, value: &str) -> Arc<str> {
        if let Some(shared) = self.names.get(value) {
            return shared.clone();
        }
        let shared: Arc<str> = Arc::from(value);
        self.names.insert(shared.clone());
        shared
    }
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
    let mut go_costs = Vec::new();
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
        if row.provider.as_ref() == GO_PROVIDER_ID {
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
    // Read the router ledger before native Codex folds. Complete, identity-resolved router rows own
    // their matching native day/model/account pair; incomplete rows remain only as fallback evidence
    // when that native pair is unavailable. This is the multi-account version of the Swift oracle's
    // exactly-once reconciliation.
    let router_events = collect_router_events(sources, now, cancel)?;
    let router_coverage = complete_router_coverage(&router_events, sources, &state.pricing);
    fold_claude(&mut state, sources, now, cancel)?;
    let native_coverage = fold_codex(&mut state, sources, now, cancel, &router_coverage)?;
    fold_router_events(
        &mut state,
        sources,
        router_events,
        &router_coverage,
        &native_coverage,
    );
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
        let model = row.model.as_ref();
        if model.starts_with("muse-")
            || matches!(
                model,
                "deepseek-v4-pro" | "deepseek/deepseek-v4-pro" | "space-bunny-free"
            )
        {
            continue;
        }
        let entry = totals
            .entry((model, row.provider.as_ref()))
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
    let mut strings = RowStrings::default();
    sqlite::for_each_row_within(
        path,
        &sql,
        true,
        std::time::Duration::from_secs(30),
        |row| parse_row(row, &mut rows, &mut strings),
    )
    .map_err(|error| error.to_string())?;
    rows.shrink_to_fit();
    Ok(rows)
}

fn parse_row(
    row: &rusqlite::Row<'_>,
    rows: &mut Vec<Row>,
    strings: &mut RowStrings,
) -> Result<(), String> {
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
        ValueRef::Null => strings.name(ModelUsageEntry::UNATTRIBUTED),
        ValueRef::Text(value) => {
            let value = String::from_utf8_lossy(value);
            let trimmed = value.trim();
            if trimmed.is_empty() {
                strings.name(ModelUsageEntry::UNATTRIBUTED)
            } else {
                strings.name(trimmed)
            }
        }
        _ => return Err("usage row has an invalid model".into()),
    };
    let provider = match row.get_ref(4).map_err(|error| error.to_string())? {
        ValueRef::Text(value) => strings.name(&String::from_utf8_lossy(value)),
        _ => return Err("usage row has an invalid provider".into()),
    };
    rows.push(Row {
        ms,
        day: strings.day(ms / 1000.0),
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
    let mut strings = RowStrings::default();
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
            serde_json::Value::Null => ModelUsageEntry::UNATTRIBUTED,
            serde_json::Value::String(value) => {
                let trimmed = value.trim();
                if trimmed.is_empty() {
                    ModelUsageEntry::UNATTRIBUTED
                } else {
                    trimmed
                }
            }
            _ => return Err("usage row has an invalid model".into()),
        };
        rows.push(Row {
            ms,
            day: strings.day(ms / 1000.0),
            cost,
            tokens,
            saturated,
            model: strings.name(model),
            provider: strings.name(provider),
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
    sources: &FoldSources,
    now: f64,
    cancel: &CancelToken,
) -> Result<(), ScanError> {
    if sources.claude_roots.is_empty() {
        return Ok(());
    }
    // Account-scoped Claude cards carry their ownership filters into OpenCode's supplementary fold.
    // Without them a multi-account installation would fold one card's hosted Claude sessions into
    // every enabled card's OpenCode source set. The legacy unconfigured path keeps the default scan.
    let configs = if sources.claude_account_configs.is_empty() {
        vec![crate::providers::claude::ClaudeProviderConfig::from_value(
            None,
        )]
    } else {
        sources.claude_account_configs.clone()
    };
    let days = UsageHistoryWindow::lifetime_days(now, crate::accounting::DayZone::Local);
    for provider_config in configs {
        let mut log_config = crate::providers::claude::ClaudeLogConfig::live();
        log_config.account_uuid = provider_config.account_uuid.clone();
        log_config.organization_uuid = provider_config.organization_uuid.clone();
        log_config.allows_unattributed_sessions = provider_config.allows_unattributed_sessions;
        log_config.cache_identity_override = provider_config.card_id.clone();
        let scanner = crate::providers::claude::ClaudeLogScanner::new(log_config);
        let Some(entries) =
            scanner.gateway_entries(days, now, Some(sources.claude_roots.clone()), cancel)
        else {
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
    }
    Ok(())
}

fn canonical_path(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

fn canonical_key(path: &Path) -> String {
    canonical_path(path).to_string_lossy().into_owned()
}

fn unique_homes(homes: &[PathBuf]) -> Vec<PathBuf> {
    let mut seen = HashSet::new();
    homes
        .iter()
        .filter_map(|home| {
            let canonical = canonical_path(home);
            seen.insert(canonical_key(&canonical)).then_some(canonical)
        })
        .collect()
}

fn event_key(event: &crate::providers::codex::event::Event) -> String {
    format!(
        "{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}",
        event.timestamp.to_bits(),
        event.model,
        event.pricing_model.as_deref().unwrap_or(""),
        event.input,
        event.cached,
        event.output,
        event.reasoning,
        event.total,
        event.has_complete_cost_breakdown,
        event.is_fast,
        event.service_tier.as_deref().unwrap_or("")
    )
}

fn home_identity(home: &Path, sources: &FoldSources) -> Option<String> {
    sources
        .codex_home_identity_keys
        .get(&canonical_key(home))
        .cloned()
}

fn day_model_account_key(
    timestamp: f64,
    model: &str,
    identity: &str,
    pricing: &ModelPricing,
) -> String {
    format!(
        "{}\u{1f}{}\u{1f}{}",
        day_key(timestamp),
        crate::accounting::codex_cross_source_model_identity(model, pricing),
        identity.to_lowercase()
    )
}

fn fold_codex(
    state: &mut FoldState,
    sources: &FoldSources,
    now: f64,
    cancel: &CancelToken,
    router_coverage: &HashSet<String>,
) -> Result<HashSet<String>, ScanError> {
    let homes = unique_homes(&sources.codex_homes);
    if homes.is_empty() {
        return Ok(HashSet::new());
    }
    let default_home = canonical_path(&crate::paths::home().join(".codex"));
    let mut default_homes = Vec::new();
    let mut managed_homes = Vec::new();
    for home in homes {
        if canonical_key(&home) == canonical_key(&default_home) {
            default_homes.push(home);
        } else {
            managed_homes.push(home);
        }
    }
    let days = UsageHistoryWindow::lifetime_days(now, crate::accounting::DayZone::Local);
    let mut native_coverage = HashSet::new();
    let mut seen_events = HashSet::new();
    for (home, is_managed) in default_homes
        .iter()
        .map(|home| (home, false))
        .chain(managed_homes.iter().map(|home| (home, true)))
    {
        if cancel.is_cancelled() {
            return Err(ScanError::Cancelled);
        }
        let scanner = crate::providers::codex::CodexSessionScanner::new(
            crate::paths::home(),
            vec![home.clone()],
            if is_managed {
                default_homes.clone()
            } else {
                Vec::new()
            },
            None,
        );
        let Some(events) = scanner.hosted_gateway_events(days, now, cancel) else {
            return Err(ScanError::Incomplete("Codex sessions".into()));
        };
        let account_identity = home_identity(home, sources);
        for event in events {
            if !seen_events.insert(event_key(&event)) {
                continue;
            }
            let (model, burns_go) = gateway_model(event.model.trim());
            if model.is_empty() {
                continue;
            }
            if let Some(identity) = account_identity.as_deref() {
                let key = day_model_account_key(event.timestamp, &model, identity, &state.pricing);
                native_coverage.insert(key.clone());
                if router_coverage.contains(&key) {
                    continue;
                }
            }
            let tokens = TokenBreakdown {
                input: (event.input - event.cached).max(0),
                cache_write_5m: 0,
                cache_write_1h: 0,
                cache_read: event.cached.max(0),
                output: event.output,
                is_fast: event.is_fast,
            };
            let provider = if burns_go {
                GO_PROVIDER_ID
            } else {
                HOSTED_PROVIDER_IDS[1]
            };
            state.add_gateway(
                event.timestamp,
                &model,
                provider,
                tokens,
                None,
                false,
                false,
                false,
                !event.has_complete_cost_breakdown,
            );
        }
    }
    Ok(native_coverage)
}

fn gateway_model(raw_model: &str) -> (String, bool) {
    crate::providers::claude::CLAUDE_GATEWAY_PREFIXES
        .iter()
        .find_map(|prefix| {
            raw_model.strip_prefix(prefix).map(|rest| {
                (
                    rest.trim().to_string(),
                    *prefix == crate::providers::claude::CLAUDE_GATEWAY_PREFIXES[0],
                )
            })
        })
        .unwrap_or_else(|| (raw_model.to_string(), false))
}

fn router_identity(
    event: &crate::providers::codex::router::RouterEvent,
    identifiers_to_identity_keys: &HashMap<String, String>,
) -> Option<String> {
    let identifiers = [
        event.account_id.as_deref(),
        event.account_fingerprint.as_deref(),
    ]
    .into_iter()
    .flatten()
    .map(|value| value.trim().to_lowercase())
    .filter(|value| !value.is_empty())
    .collect::<Vec<_>>();
    if identifiers.is_empty() {
        return None;
    }
    let mut resolved = Vec::with_capacity(identifiers.len());
    for identifier in &identifiers {
        resolved.push(identifiers_to_identity_keys.get(identifier)?);
    }
    let first = resolved.first()?;
    resolved
        .iter()
        .all(|value| *value == *first)
        .then(|| first.to_lowercase())
}

fn collect_router_events(
    sources: &FoldSources,
    now: f64,
    cancel: &CancelToken,
) -> Result<Vec<crate::providers::codex::router::RouterEvent>, ScanError> {
    if sources.router_ledger_paths.is_empty() {
        return Ok(Vec::new());
    }
    let scanner = crate::providers::codex::router::CodexRouterScanner::new(
        crate::paths::home(),
        sources.router_ledger_paths.clone(),
        Vec::new(),
    );
    let days = UsageHistoryWindow::lifetime_days(now, crate::accounting::DayZone::Local);
    let Some(events) = scanner.opencode_events(days, now, cancel) else {
        return Err(ScanError::Incomplete("Router ledger".into()));
    };
    Ok(events
        .into_iter()
        .filter(|event| {
            let Some(enabled) = &sources.enabled_codex_identity_keys else {
                return true;
            };
            router_identity(event, &sources.codex_account_identity_keys)
                .map(|identity| enabled.contains(&identity))
                .unwrap_or(true)
        })
        .collect())
}

fn complete_router_coverage(
    events: &[crate::providers::codex::router::RouterEvent],
    sources: &FoldSources,
    pricing: &ModelPricing,
) -> HashSet<String> {
    let mut completeness: HashMap<String, bool> = HashMap::new();
    for event in events {
        if event.measured_total().unwrap_or(0) <= 0 && event.estimated_input.unwrap_or(0) <= 0 {
            continue;
        }
        let Some(identity) = router_identity(event, &sources.router_account_identity_keys) else {
            continue;
        };
        let (model, _) = gateway_model(event.model.trim());
        if model.is_empty() {
            continue;
        }
        let key = day_model_account_key(event.timestamp, &model, &identity, pricing);
        let complete = event.complete_cost_breakdown();
        completeness
            .entry(key)
            .and_modify(|existing| *existing &= complete)
            .or_insert(complete);
    }
    completeness
        .into_iter()
        .filter_map(|(key, complete)| complete.then_some(key))
        .collect()
}

fn fold_router_events(
    state: &mut FoldState,
    sources: &FoldSources,
    events: Vec<crate::providers::codex::router::RouterEvent>,
    router_coverage: &HashSet<String>,
    native_coverage: &HashSet<String>,
) {
    for event in events {
        let (model, burns_go) = gateway_model(event.model.trim());
        if model.is_empty() {
            continue;
        }
        if let Some(identity) = router_identity(&event, &sources.router_account_identity_keys) {
            let key = day_model_account_key(event.timestamp, &model, &identity, &state.pricing);
            if !router_coverage.contains(&key) && native_coverage.contains(&key) {
                continue;
            }
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
            &model,
            provider,
            tokens,
            None,
            false,
            event.token_count_saturated,
            false,
            !event.valid_numbers || event.estimated_input.unwrap_or(0) > 0,
        );
    }
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
    use crate::providers::codex::router::RouterEvent;

    fn router_event(
        account_id: Option<&str>,
        fingerprint: Option<&str>,
        total: Option<i64>,
        estimated_input: Option<i64>,
    ) -> RouterEvent {
        RouterEvent {
            timestamp: 1_780_000_000.0,
            model: Arc::from("anthropic/opencode_go/gpt-5.5"),
            provider: Arc::from("opencode-go"),
            status: 200,
            input: 100,
            cached: 20,
            output: 50,
            reasoning: 0,
            total,
            estimated_input,
            account_id: account_id.map(Arc::from),
            account_fingerprint: fingerprint.map(Arc::from),
            service_tier: None,
            valid_status: true,
            valid_timestamp: true,
            valid_model: true,
            valid_numbers: true,
            valid_provider: true,
            valid_service_tier: true,
            token_count_saturated: false,
        }
    }

    fn fold_state(pricing: Arc<ModelPricing>) -> FoldState {
        FoldState {
            since: 0.0,
            max_timestamp: f64::MAX,
            pricing,
            rates: HashMap::new(),
            accumulator: DailyUsageAccumulator::new(),
            go_costs: Vec::new(),
            estimated: false,
            partial_days: BTreeSet::new(),
        }
    }

    #[test]
    fn router_identity_requires_every_identifier_to_resolve_to_one_account() {
        let event = router_event(Some("acct-a"), Some("fp-a"), Some(150), None);
        let aliases = HashMap::from([
            ("acct-a".to_string(), "acct-a".to_string()),
            ("fp-a".to_string(), "acct-a".to_string()),
        ]);
        assert_eq!(router_identity(&event, &aliases).as_deref(), Some("acct-a"));

        let conflicting = HashMap::from([
            ("acct-a".to_string(), "acct-a".to_string()),
            ("fp-a".to_string(), "acct-b".to_string()),
        ]);
        assert_eq!(router_identity(&event, &conflicting), None);
        assert_eq!(router_identity(&event, &HashMap::new()), None);
    }

    #[test]
    fn incomplete_router_rows_do_not_suppress_measured_native_rows() {
        let pricing = Arc::new(ModelPricing::default());
        let mut sources = FoldSources::default();
        sources.router_account_identity_keys = HashMap::from([
            ("acct-a".to_string(), "acct-a".to_string()),
            ("fp-a".to_string(), "acct-a".to_string()),
        ]);
        let complete = router_event(Some("acct-a"), Some("fp-a"), Some(150), None);
        let coverage = complete_router_coverage(&[complete.clone()], &sources, &pricing);
        let (model, _) = gateway_model(complete.model.trim());
        let key = day_model_account_key(complete.timestamp, &model, "acct-a", &pricing);
        assert!(coverage.contains(&key));

        // A mismatched/estimated router breakdown cannot own the pair. When native measured rows are
        // available for the same day/model/account, the incomplete router row is fallback evidence
        // and is skipped instead of double-counted.
        let incomplete = router_event(Some("acct-a"), Some("fp-a"), Some(151), Some(1));
        let incomplete_coverage =
            complete_router_coverage(&[incomplete.clone()], &sources, &pricing);
        assert!(!incomplete_coverage.contains(&key));
        let native_coverage = HashSet::from([key]);
        let mut state = fold_state(pricing);
        fold_router_events(
            &mut state,
            &sources,
            vec![incomplete],
            &incomplete_coverage,
            &native_coverage,
        );
        assert!(state.accumulator.build().series.daily.is_empty());
    }

    #[test]
    fn incomplete_router_rows_remain_fallback_when_native_rows_are_missing() {
        let pricing = Arc::new(ModelPricing::default());
        let mut sources = FoldSources::default();
        sources.router_account_identity_keys = HashMap::from([
            ("acct-a".to_string(), "acct-a".to_string()),
            ("fp-a".to_string(), "acct-a".to_string()),
        ]);
        let incomplete = router_event(Some("acct-a"), Some("fp-a"), Some(151), Some(1));
        let coverage = complete_router_coverage(&[incomplete.clone()], &sources, &pricing);
        assert!(coverage.is_empty());

        let mut state = fold_state(pricing);
        fold_router_events(
            &mut state,
            &sources,
            vec![incomplete],
            &coverage,
            &HashSet::new(),
        );
        let daily = state.accumulator.build().series.daily;
        assert_eq!(daily.len(), 1);
        assert_eq!(daily[0].total_tokens, 150);
    }

    #[test]
    fn unresolved_router_rows_remain_additive_instead_of_suppressing_native_rows() {
        let pricing = Arc::new(ModelPricing::default());
        let sources = FoldSources::default();
        let unresolved = router_event(Some("unknown-account"), None, Some(150), None);
        let coverage = complete_router_coverage(&[unresolved.clone()], &sources, &pricing);
        assert!(coverage.is_empty());

        // Even if a native row happens to cover the same day/model pair for a known account, an
        // unresolved router row is not positive evidence about that account and must stay additive.
        let (model, _) = gateway_model(unresolved.model.trim());
        let native_coverage = HashSet::from([day_model_account_key(
            unresolved.timestamp,
            &model,
            "acct-a",
            &pricing,
        )]);
        let mut state = fold_state(pricing);
        fold_router_events(
            &mut state,
            &sources,
            vec![unresolved],
            &coverage,
            &native_coverage,
        );
        let daily = state.accumulator.build().series.daily;
        assert_eq!(daily.len(), 1);
        assert_eq!(daily[0].total_tokens, 150);
    }

    #[test]
    fn parses_rows_and_rejects_malformed_accounting() {
        let text = r#"[[1780000000000,1.5,500,"gpt-5.5","opencode"],[1780000001000,null,0,"x","opencode-go"]]"#;
        let rows = parse_rows(text).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].tokens, 500);
        assert_eq!(rows[0].cost, Some(1.5));

        assert!(parse_rows(r#"[[1,1.5,-1,"x","opencode"]]"#).is_err());
    }

    #[test]
    fn repeated_rows_share_cached_names_and_dates() {
        let rows = parse_rows(
            r#"[[1780000000000,1.5,500,"gpt-5.5","opencode"],[1780000001000,2.5,750,"gpt-5.5","opencode"],[1780172800000,3,900,"gpt-5.5","opencode-go"]]"#,
        )
        .unwrap();

        assert!(Arc::ptr_eq(&rows[0].day, &rows[1].day));
        assert!(Arc::ptr_eq(&rows[0].model, &rows[1].model));
        assert!(Arc::ptr_eq(&rows[0].provider, &rows[1].provider));
        assert_ne!(rows[0].day, rows[2].day);
        assert_ne!(rows[0].provider, rows[2].provider);
    }
}
