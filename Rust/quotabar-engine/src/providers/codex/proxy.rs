//! FCC proxy usage ledger (Swift `CodexProxyUsageScanner`).
//!
//! Reads only metadata rows from FCC's SQLite ledger, scoped to one exact Codex account
//! fingerprint. Rows without a fingerprint are ignored: historical rows cannot be assigned after a
//! second account exists. A configured database that cannot be read makes the scan incomplete so
//! the caller can keep its last-good combined history.

use crate::accounting::{day_key, DailyUsageAccumulator, LogUsageScan, RowOptions};
use crate::context::CancelToken;
use crate::host;
use crate::model::ModelUsageEntry;
use crate::paths;
use crate::pricing::{ModelPricing, TokenBreakdown};
use crate::qlog;
use crate::sqlite;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

#[derive(Clone, Debug, PartialEq)]
pub enum CodexProxyScanResult {
    Complete(Option<LogUsageScan>),
    Incomplete,
}

#[derive(Clone)]
struct CachedFold {
    revision: Vec<(PathBuf, u64, u64, u64)>,
    window: usize,
    pricing_token: String,
    result: Option<LogUsageScan>,
}

pub struct CodexProxyScanner {
    home: PathBuf,
    database_paths: Option<Vec<PathBuf>>,
    optional_default_path: Option<PathBuf>,
    cache: Mutex<HashMap<String, CachedFold>>,
}

impl CodexProxyScanner {
    pub fn live(home: PathBuf) -> Self {
        let configured = configured_database_paths();
        let optional_default_path = if configured.is_empty() {
            Some(home.join(".fcc/usage.db"))
        } else {
            None
        };
        CodexProxyScanner {
            home,
            database_paths: if configured.is_empty() {
                None
            } else {
                Some(configured)
            },
            optional_default_path,
            cache: Mutex::new(HashMap::new()),
        }
    }

    pub fn new(home: PathBuf, database_paths: Vec<PathBuf>) -> Self {
        CodexProxyScanner {
            home,
            database_paths: Some(database_paths),
            optional_default_path: None,
            cache: Mutex::new(HashMap::new()),
        }
    }

    fn paths(&self) -> Vec<PathBuf> {
        match &self.database_paths {
            Some(paths) => unique_paths(paths),
            None => unique_paths(&[self.home.join(".fcc/usage.db")]),
        }
    }

    /// SHA-256("openai\0" + identity), first six bytes as hex, prefixed `acct_` — FCC's
    /// `account_fingerprint("openai", account_id)`.
    pub fn account_fingerprint(identity_key: Option<&str>) -> Option<String> {
        let identity = identity_key?.trim();
        if identity.is_empty() {
            return None;
        }
        let mut hasher = Sha256::new();
        hasher.update(b"openai\0");
        hasher.update(identity.as_bytes());
        let digest = hasher.finalize();
        let mut output = String::with_capacity(11);
        output.push_str("acct_");
        for byte in &digest[..6] {
            output.push_str(&format!("{byte:02x}"));
        }
        Some(output)
    }

    pub fn scan_result(
        &self,
        account_identity_key: Option<&str>,
        days_back: usize,
        now: f64,
        pricing: &ModelPricing,
        cancel: &CancelToken,
    ) -> CodexProxyScanResult {
        let Some(fingerprint) = Self::account_fingerprint(account_identity_key) else {
            return CodexProxyScanResult::Complete(None);
        };
        let paths = self.paths();
        let days = days_back.max(1);
        let since = day_key(now - (days.saturating_sub(1)) as f64 * 86_400.0);
        let through = day_key(now);
        let revision = revision(&paths);
        let pricing_token = pricing.aggregate_cache_token().to_string();
        {
            let cache = self.cache.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(cached) = cache.get(&fingerprint) {
                if cached.revision == revision
                    && cached.window == days
                    && cached.pricing_token == pricing_token
                {
                    return CodexProxyScanResult::Complete(cached.result.clone());
                }
            }
        }

        let mut accumulator = DailyUsageAccumulator::new();
        let mut saw_source = false;
        let mut saw_rows = false;
        for path in &paths {
            if cancel.is_cancelled() {
                return CodexProxyScanResult::Incomplete;
            }
            if self.optional_default_path.as_deref() == Some(path.as_path()) && !path.exists() {
                continue;
            }
            saw_source = true;
            let schema = match sqlite::query_value(
                path,
                "SELECT COALESCE(json_group_array(name), '[]') FROM pragma_table_info('usage_events');",
            ) {
                Ok(Some(value)) => value,
                Ok(None) => continue,
                Err(_) => {
                    qlog!(Warn, "codex", "FCC usage database could not be read; preserving last-good history");
                    return CodexProxyScanResult::Incomplete;
                }
            };
            if !has_required_schema(&schema) {
                qlog!(
                    Warn,
                    "codex",
                    "FCC usage database schema is incomplete; preserving last-good history"
                );
                return CodexProxyScanResult::Incomplete;
            }
            let sql = events_sql(&fingerprint, &since, &through);
            let payload = match sqlite::query_value(path, &sql) {
                Ok(Some(value)) => value,
                Ok(None) => continue,
                Err(_) => {
                    qlog!(
                        Warn,
                        "codex",
                        "FCC usage query failed; preserving last-good history"
                    );
                    return CodexProxyScanResult::Incomplete;
                }
            };
            let rows: Vec<serde_json::Map<String, serde_json::Value>> =
                match serde_json::from_str(&payload) {
                    Ok(rows) => rows,
                    Err(_) => {
                        qlog!(
                            Warn,
                            "codex",
                            "FCC usage rows could not be decoded; preserving last-good history"
                        );
                        return CodexProxyScanResult::Incomplete;
                    }
                };
            for row in rows {
                if cancel.is_cancelled() {
                    return CodexProxyScanResult::Incomplete;
                }
                let Some(day) = row
                    .get("local_day")
                    .and_then(serde_json::Value::as_str)
                    .map(str::trim)
                    .filter(|value| is_iso_day(value))
                else {
                    qlog!(
                        Warn,
                        "codex",
                        "FCC usage database contains malformed rows; preserving last-good history"
                    );
                    return CodexProxyScanResult::Incomplete;
                };
                let model = row
                    .get("model")
                    .and_then(serde_json::Value::as_str)
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .unwrap_or(ModelUsageEntry::UNATTRIBUTED);
                let Some(input) = count(row.get("input_tokens")) else {
                    qlog!(
                        Warn,
                        "codex",
                        "FCC usage database contains malformed rows; preserving last-good history"
                    );
                    return CodexProxyScanResult::Incomplete;
                };
                let Some(output) = count(row.get("output_tokens")) else {
                    qlog!(
                        Warn,
                        "codex",
                        "FCC usage database contains malformed rows; preserving last-good history"
                    );
                    return CodexProxyScanResult::Incomplete;
                };
                let Some(cache_read) = count(row.get("cache_read_input_tokens")) else {
                    qlog!(
                        Warn,
                        "codex",
                        "FCC usage database contains malformed rows; preserving last-good history"
                    );
                    return CodexProxyScanResult::Incomplete;
                };
                let Some(cache_write) = count(row.get("cache_creation_input_tokens")) else {
                    qlog!(
                        Warn,
                        "codex",
                        "FCC usage database contains malformed rows; preserving last-good history"
                    );
                    return CodexProxyScanResult::Incomplete;
                };
                let Some(total) = input
                    .checked_add(cache_read)
                    .and_then(|v| v.checked_add(cache_write))
                    .and_then(|v| v.checked_add(output))
                else {
                    qlog!(
                        Warn,
                        "codex",
                        "FCC usage database contains malformed rows; preserving last-good history"
                    );
                    return CodexProxyScanResult::Incomplete;
                };
                if total <= 0 {
                    continue;
                }
                saw_rows = true;
                let tokens = TokenBreakdown {
                    input,
                    cache_write_5m: cache_write,
                    cache_write_1h: 0,
                    cache_read,
                    output,
                    is_fast: false,
                };
                let candidates = pricing_model_candidates(model);
                let resolved = pricing.canonical_key(&candidates).or_else(|| {
                    candidates
                        .iter()
                        .find(|candidate| pricing.is_priced(candidate))
                        .cloned()
                });
                let Some(pricing_model) = resolved else {
                    accumulator.add_unknown_model(day, model);
                    accumulator.add_with(
                        day,
                        total,
                        None,
                        model,
                        RowOptions {
                            canonical: Some(model),
                            cost_is_complete: false,
                            token_count_saturated: false,
                        },
                    );
                    continue;
                };
                let Some(rates) = pricing.resolve(&pricing_model) else {
                    accumulator.add_unknown_model(day, model);
                    accumulator.add_with(
                        day,
                        total,
                        None,
                        model,
                        RowOptions {
                            canonical: Some(model),
                            cost_is_complete: false,
                            token_count_saturated: false,
                        },
                    );
                    continue;
                };
                let cost = rates.cost_dollars(&tokens, None, true);
                accumulator.record_api_estimate(day, Some(cost), total);
                let canonical =
                    crate::pricing::gateway_identity(model, Some(pricing_model.as_str()));
                accumulator.add_with(
                    day,
                    total,
                    Some(cost),
                    model,
                    RowOptions {
                        canonical: Some(&canonical),
                        cost_is_complete: true,
                        token_count_saturated: false,
                    },
                );
            }
        }
        if cancel.is_cancelled() {
            return CodexProxyScanResult::Incomplete;
        }
        let result = if !saw_source || !saw_rows {
            None
        } else {
            let scan = accumulator.build();
            (!scan.series.daily.is_empty() || !scan.unknown_models_by_day.is_empty())
                .then_some(scan)
        };
        self.cache.lock().unwrap_or_else(|e| e.into_inner()).insert(
            fingerprint,
            CachedFold {
                revision,
                window: days,
                pricing_token,
                result: result.clone(),
            },
        );
        CodexProxyScanResult::Complete(result)
    }
}

fn configured_database_paths() -> Vec<PathBuf> {
    ["OPENUSAGE_CODEX_PROXY_USAGE_DB", "FCC_USAGE_DB"]
        .into_iter()
        .filter_map(host::env_var)
        .flat_map(|value| split_paths(&value))
        .map(|value| paths::expand_home(&value))
        .collect()
}

fn split_paths(raw: &str) -> Vec<String> {
    raw.split([',', '\n', '\r'])
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .collect()
}

fn unique_paths(paths: &[PathBuf]) -> Vec<PathBuf> {
    let mut seen = HashSet::new();
    paths
        .iter()
        .filter(|path| {
            let canonical = std::fs::canonicalize(path).unwrap_or_else(|_| (*path).clone());
            let identity = std::fs::metadata(&canonical)
                .map(|meta| format!("inode:{:?}:{:?}", meta.dev(), meta.ino()))
                .unwrap_or_else(|_| format!("path:{}", canonical.display()));
            seen.insert(identity)
        })
        .cloned()
        .collect()
}

fn revision(paths: &[PathBuf]) -> Vec<(PathBuf, u64, u64, u64)> {
    let mut result = Vec::new();
    for path in paths {
        for candidate in [
            path.clone(),
            with_suffix(path, "-wal"),
            with_suffix(path, "-shm"),
        ] {
            let meta = std::fs::metadata(&candidate).ok();
            result.push((
                candidate,
                meta.as_ref().map(|m| m.len()).unwrap_or(0),
                meta.as_ref()
                    .and_then(|m| m.modified().ok())
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_nanos() as u64)
                    .unwrap_or(0),
                meta.as_ref().map(|m| m.ino()).unwrap_or(0),
            ));
        }
    }
    result
}

fn with_suffix(path: &Path, suffix: &str) -> PathBuf {
    PathBuf::from(format!("{}{suffix}", path.display()))
}

fn has_required_schema(payload: &str) -> bool {
    let Ok(Value::Array(values)) = serde_json::from_str::<Value>(payload) else {
        return false;
    };
    let columns: HashSet<&str> = values.iter().filter_map(Value::as_str).collect();
    [
        "provider_id",
        "local_day",
        "model",
        "input_tokens",
        "output_tokens",
        "cache_read_input_tokens",
        "cache_creation_input_tokens",
        "source",
        "account_fingerprint",
    ]
    .iter()
    .all(|required| columns.contains(required))
}

fn events_sql(fingerprint: &str, since_day: &str, through_day: &str) -> String {
    let escape = |value: &str| value.replace('\'', "''");
    format!(
        "SELECT json_group_array(json_object(\
            'local_day', local_day, 'model', model, 'input_tokens', input_tokens, \
            'output_tokens', output_tokens, 'cache_read_input_tokens', cache_read_input_tokens, \
            'cache_creation_input_tokens', cache_creation_input_tokens)) \
         FROM usage_events WHERE provider_id = 'openai' AND source = 'fcc_proxy' \
         AND account_fingerprint = '{}' AND local_day BETWEEN '{}' AND '{}';",
        escape(fingerprint),
        escape(since_day),
        escape(through_day)
    )
}

fn count(value: Option<&serde_json::Value>) -> Option<i64> {
    let number = value?.as_f64()?;
    (number.is_finite() && number >= 0.0 && number <= 1e15 && number.fract() == 0.0)
        .then_some(number as i64)
}

fn is_iso_day(value: &str) -> bool {
    value.len() == 10
        && value.as_bytes()[4] == b'-'
        && value.as_bytes()[7] == b'-'
        && value
            .as_bytes()
            .iter()
            .enumerate()
            .all(|(index, byte)| matches!(index, 4 | 7) || byte.is_ascii_digit())
}

fn pricing_model_candidates(model: &str) -> Vec<String> {
    let mut candidates = vec![model.to_string()];
    let mut remainder = model;
    while let Some((_, rest)) = remainder.split_once('/') {
        if rest.is_empty() {
            break;
        }
        candidates.push(rest.to_string());
        remainder = rest;
    }
    candidates.dedup();
    candidates
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn account_fingerprint_matches_fcc() {
        assert_eq!(
            CodexProxyScanner::account_fingerprint(Some("1118f6f1-8697-4e7b-9112-1771b3e36099"))
                .as_deref(),
            Some("acct_1257f3fe5af1")
        );
        assert_eq!(CodexProxyScanner::account_fingerprint(Some("  ")), None);
    }

    #[test]
    fn schema_requires_every_column() {
        let payload = r#"["provider_id","local_day","model","input_tokens","output_tokens","cache_read_input_tokens","cache_creation_input_tokens","source","account_fingerprint"]"#;
        assert!(has_required_schema(payload));
        assert!(!has_required_schema(r#"["provider_id"]"#));
        assert!(!has_required_schema("not json"));
    }

    #[test]
    fn pricing_candidates_walk_every_suffix() {
        assert_eq!(
            pricing_model_candidates("anthropic/openai/gpt-6-luna"),
            vec![
                "anthropic/openai/gpt-6-luna",
                "openai/gpt-6-luna",
                "gpt-6-luna"
            ]
        );
    }
}
