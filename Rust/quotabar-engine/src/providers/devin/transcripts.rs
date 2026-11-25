//! Devin local transcript (`ATIF-v1.7`) and session-DB combiner (Swift `DevinTranscriptUsageScanner`).

use super::auth::ID;
use super::sessions::{DevinSessionEntry, DevinSessionUsageReader};
use crate::accounting::{day_key, DailyUsageAccumulator, LogUsageScan, RowOptions};
use crate::context::CancelToken;
use crate::host::diagnostic_gate;
use crate::model::ModelUsageEntry;
use crate::paths;
use crate::pricing::{self, ModelPricing, TokenBreakdown};
use crate::providers::claude::util::since_date;
use crate::qlog;
use crate::scan::discover::{DiscoveredFile, Revision};
use crate::scan::incremental::FUTURE_TOLERANCE_SECONDS;
use crate::time;
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const FUTURE_TIMESTAMP_KEY: &str = "devin.transcripts.future-timestamp";
const ENUMERATION_KEY: &str = "devin.transcripts.enumeration";
const SESSION_DB_KEY: &str = "devin.sessions.read";
/// A session-database read that exceeds SQLite's safety budget is deterministic for the current
/// file and workload. Retrying it on every fold pass just stalls the pass for the full timeout;
/// log once and cool off before trying again.
const SESSION_READ_BACKOFF: Duration = Duration::from_secs(300);

pub struct DevinTranscriptUsageScanner {
    fixed: Option<(PathBuf, Option<PathBuf>)>,
    session_reader: Mutex<DevinSessionUsageReader>,
    session_retry_after: Mutex<Option<Instant>>,
    transcript_cache: Mutex<HashMap<PathBuf, (Revision, Vec<DevinSessionEntry>)>>,
}

impl DevinTranscriptUsageScanner {
    pub fn live() -> Self {
        DevinTranscriptUsageScanner {
            fixed: None,
            session_reader: Mutex::new(DevinSessionUsageReader::default()),
            session_retry_after: Mutex::new(None),
            transcript_cache: Mutex::new(HashMap::new()),
        }
    }

    pub fn new(
        transcripts_dir: PathBuf,
        session_db: Option<PathBuf>,
        cache_dir_override: Option<PathBuf>,
    ) -> Self {
        DevinTranscriptUsageScanner {
            fixed: Some((transcripts_dir, session_db)),
            session_reader: Mutex::new(DevinSessionUsageReader::new(cache_dir_override)),
            session_retry_after: Mutex::new(None),
            transcript_cache: Mutex::new(HashMap::new()),
        }
    }

    pub fn unload_caches(&self) {
        self.session_reader
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clear();
        *self
            .session_retry_after
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = None;
        self.transcript_cache
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clear();
    }

    fn locations(&self) -> (PathBuf, Option<PathBuf>) {
        match &self.fixed {
            Some((t, db)) => (t.clone(), db.clone()),
            None => {
                let cli = paths::xdg_data_home().join("devin/cli");
                (cli.join("transcripts"), Some(cli.join("sessions.db")))
            }
        }
    }

    pub fn scan(
        &self,
        days_back: usize,
        now: f64,
        pricing_provider: &dyn Fn() -> Arc<ModelPricing>,
        cancel: &CancelToken,
    ) -> Option<LogUsageScan> {
        if cancel.is_cancelled() {
            return None;
        }
        let since = since_date(days_back, now);
        let max_ts = now + FUTURE_TOLERANCE_SECONDS;
        let (transcripts_dir, session_db) = self.locations();

        if let Some(db_path) = session_db {
            if db_path.exists() {
                let cooling_down = self
                    .session_retry_after
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .is_some_and(|until| Instant::now() < until);
                if cooling_down {
                    return None;
                }
                let db_entries = match self
                    .session_reader
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .entries(&db_path)
                {
                    Ok(entries) => {
                        *self
                            .session_retry_after
                            .lock()
                            .unwrap_or_else(|e| e.into_inner()) = None;
                        diagnostic_gate::clear(SESSION_DB_KEY);
                        entries
                    }
                    Err(err) => {
                        *self
                            .session_retry_after
                            .lock()
                            .unwrap_or_else(|e| e.into_inner()) =
                            Some(Instant::now() + SESSION_READ_BACKOFF);
                        diagnostic_gate::log_once(SESSION_DB_KEY, || {
                            qlog!(Warn, crate::host::plugin_tag(ID), "session database usage could not be read; preserving last-good history and retrying after {}s: {err}", SESSION_READ_BACKOFF.as_secs());
                        });
                        return None;
                    }
                };
                if cancel.is_cancelled() {
                    return None;
                }
                if db_entries.iter().any(|e| e.timestamp > max_ts) {
                    log_future_timestamp();
                    return None;
                }
                if !db_entries.is_empty() {
                    diagnostic_gate::clear(FUTURE_TIMESTAMP_KEY);
                    let pricing = pricing_provider();
                    return Some(aggregate(&db_entries, since, &pricing));
                }
            } else {
                self.session_reader
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .clear();
                *self
                    .session_retry_after
                    .lock()
                    .unwrap_or_else(|e| e.into_inner()) = None;
            }
        }

        let files = match discover_transcripts(&transcripts_dir) {
            Ok(files) => {
                diagnostic_gate::clear(ENUMERATION_KEY);
                files
            }
            Err(err) => {
                diagnostic_gate::log_once(ENUMERATION_KEY, || {
                    qlog!(Warn, crate::host::plugin_tag(ID), "transcript files could not be completely enumerated; preserving last-good history: {err}");
                });
                return None;
            }
        };
        if files.is_empty() {
            return None;
        }

        let mut all_entries = Vec::new();
        let mut cache = self
            .transcript_cache
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        for file in files {
            if cancel.is_cancelled() {
                return None;
            }
            let entries = if let Some((rev, cached)) = cache.get(&file.path) {
                if *rev == file.revision {
                    cached.clone()
                } else {
                    let parsed = parse_file(&file.path)?;
                    cache.insert(file.path.clone(), (file.revision, parsed.clone()));
                    parsed
                }
            } else {
                let parsed = parse_file(&file.path)?;
                cache.insert(file.path.clone(), (file.revision, parsed.clone()));
                parsed
            };
            all_entries.extend(entries);
        }
        if all_entries.iter().any(|e| e.timestamp > max_ts) {
            log_future_timestamp();
            return None;
        }
        diagnostic_gate::clear(FUTURE_TIMESTAMP_KEY);
        if cancel.is_cancelled() {
            return None;
        }
        let pricing = pricing_provider();
        Some(aggregate(&all_entries, since, &pricing))
    }
}

fn log_future_timestamp() {
    diagnostic_gate::log_once(FUTURE_TIMESTAMP_KEY, || {
        qlog!(
            Warn,
            crate::host::plugin_tag(ID),
            "transcript usage contains a timestamp more than five minutes ahead; preserving last-good history"
        );
    });
}

fn discover_transcripts(dir: &Path) -> std::io::Result<Vec<DiscoveredFile>> {
    match std::fs::metadata(dir) {
        Ok(meta) => {
            if !meta.is_dir() {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    "transcripts path is not a directory",
                ));
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e),
    }
    let mut files = Vec::new();
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        let kind = entry.file_type()?;
        if kind.is_file() && path.extension().and_then(|s| s.to_str()) == Some("json") {
            let revision = Revision::read(&path)?;
            files.push(DiscoveredFile { path, revision });
        }
    }
    files.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(files)
}

pub fn parse_file(path: &Path) -> Option<Vec<DevinSessionEntry>> {
    let data = std::fs::read(path).ok()?;
    parse_bytes(&data)
}

pub fn parse_bytes(data: &[u8]) -> Option<Vec<DevinSessionEntry>> {
    let Value::Object(root) = serde_json::from_slice::<Value>(data).ok()? else {
        return None;
    };
    let steps = root.get("steps")?.as_array()?;
    let session_model = root
        .get("agent")
        .and_then(Value::as_object)
        .and_then(|a| a.get("model_name"))
        .and_then(Value::as_str)
        .map(str::trim)
        .unwrap_or("")
        .to_string();

    let mut out = Vec::new();
    for step in steps {
        let obj = step.as_object()?;
        let Some(metrics) = obj.get("metrics").and_then(Value::as_object) else {
            if obj.contains_key("metrics") && !obj["metrics"].is_null() {
                return None;
            }
            continue;
        };
        let prompt = optional_count(metrics.get("prompt_tokens"))?;
        let completion = optional_count(metrics.get("completion_tokens"))?;
        let cached = optional_count(metrics.get("cached_tokens"))?;
        let (Some(prompt_val), completion_val, cached_val) =
            (prompt, completion.unwrap_or(0), cached.unwrap_or(0))
        else {
            if completion.is_none() && cached.is_none() {
                continue;
            }
            if cached.unwrap_or(0) > 0 {
                return None;
            }
            // completion present without prompt
            let timestamp = parse_step_timestamp(obj.get("timestamp"))?;
            let model = step_model_name(obj.get("model_name"), &session_model);
            let tokens = TokenBreakdown {
                input: 0,
                cache_write_5m: 0,
                cache_write_1h: 0,
                cache_read: 0,
                output: completion.unwrap_or(0),
                is_fast: false,
            };
            if tokens.total_tokens() > 0 {
                out.push(DevinSessionEntry {
                    timestamp,
                    model,
                    tokens,
                });
            }
            continue;
        };
        if cached_val > prompt_val {
            return None;
        }
        let timestamp = parse_step_timestamp(obj.get("timestamp"))?;
        let model = step_model_name(obj.get("model_name"), &session_model);
        let tokens = TokenBreakdown {
            input: prompt_val - cached_val,
            cache_write_5m: 0,
            cache_write_1h: 0,
            cache_read: cached_val,
            output: completion_val,
            is_fast: false,
        };
        if tokens.total_tokens() > 0 {
            out.push(DevinSessionEntry {
                timestamp,
                model,
                tokens,
            });
        }
    }
    Some(out)
}

fn optional_count(val: Option<&Value>) -> Option<Option<i64>> {
    match val {
        None | Some(Value::Null) => Some(None),
        Some(Value::Bool(_)) => None,
        Some(Value::Number(n)) => {
            if let Some(i) = n.as_i64() {
                (0..=1_000_000_000_000_000).contains(&i).then_some(Some(i))
            } else {
                let f = n.as_f64()?;
                (f.is_finite() && f >= 0.0 && f <= 1e15 && f.trunc() == f).then_some(Some(f as i64))
            }
        }
        _ => None,
    }
}

fn parse_step_timestamp(val: Option<&Value>) -> Option<f64> {
    let raw = val.and_then(Value::as_str)?;
    time::parse_iso8601(raw)
}

fn step_model_name(val: Option<&Value>, fallback: &str) -> String {
    let raw = val
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let chosen = raw.unwrap_or(fallback).trim();
    if chosen.is_empty() {
        ModelUsageEntry::UNATTRIBUTED.to_string()
    } else {
        chosen.to_string()
    }
}

pub fn aggregate(
    entries: &[DevinSessionEntry],
    since: f64,
    pricing: &ModelPricing,
) -> LogUsageScan {
    let mut accumulator = DailyUsageAccumulator::new();
    for entry in entries {
        if entry.timestamp < since {
            continue;
        }
        let day = day_key(entry.timestamp);
        let estimate = match entry.model.to_ascii_lowercase().as_str() {
            "gemini-4-neon" | "gemini-4-neon-xhigh" => {
                let route = "google/gemini-4-neon";
                let rates = pricing.open_router.find_exact(route).map(|(_, r)| r);
                if rates.is_none() {
                    let _ = pricing.resolve(route);
                }
                rates.map(|r| r.cost_dollars(&entry.tokens, Some(entry.timestamp), false))
            }
            _ => pricing.estimated_cost_dollars(
                &entry.model,
                &entry.tokens,
                Some(entry.timestamp),
                false,
            ),
        };
        if estimate.is_none() {
            if entry.model == ModelUsageEntry::UNATTRIBUTED {
                accumulator.add_unknown_model(&day, &entry.model);
            } else {
                accumulator.add_named_unpriced_model(&day, &entry.model);
            }
        }
        let canonical = pricing
            .canonical_name(&entry.model)
            .unwrap_or_else(|| pricing::catalog::normalized_key(&entry.model).to_ascii_lowercase());
        accumulator.add_with(
            &day,
            entry.tokens.total_tokens(),
            estimate,
            &entry.model,
            RowOptions {
                canonical: Some(&canonical),
                cost_is_complete: estimate.is_some(),
                token_count_saturated: false,
            },
        );
        accumulator.record_api_estimate(&day, estimate, entry.tokens.total_tokens());
        if estimate.is_some() {
            accumulator.mark_estimated_cost(&day);
        }
    }
    accumulator.build()
}
