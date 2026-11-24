//! Grok CLI local session log scanner (`$GROK_HOME/sessions/**/updates.jsonl` or `~/.grok/sessions/**/updates.jsonl`).

use super::auth::ID;
use crate::accounting::{day_key, DailyUsageAccumulator, LogUsageScan};
use crate::context::CancelToken;
use crate::host::{self, diagnostic_gate};
use crate::model::ReportedUsageCost;
use crate::paths;
use crate::pricing::{ModelPricing, TokenBreakdown};
use crate::providers::claude::util::{expand_home, since_date, stable_fingerprint, zone_signature};
use crate::qlog;
use crate::scan::discover::{DiscoveredFile, Revision};
use crate::scan::{
    fingerprint, first_future_dated, FileItems, IncrementalScanner, LineError, LineParser, Reader, Record, ScanError,
    ScanStore, Writer,
};
use crate::time;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

const FUTURE_TIMESTAMP_KEY: &str = "grok.sessions.future-timestamp";
const SUMMARY_CACHE_CAP: usize = 4096;

#[derive(Clone, Debug, PartialEq)]
pub struct GrokEntry {
    pub event_id: Option<Arc<str>>,
    pub timestamp: f64,
    pub model: Arc<str>,
    pub tokens: TokenBreakdown,
    pub carried_cost: Option<f64>,
}

impl Record for GrokEntry {
    fn encode(&self, w: &mut Writer) {
        w.opt_str(self.event_id.as_deref());
        w.f64(self.timestamp);
        w.str(&self.model);
        w.i64(self.tokens.input);
        w.i64(self.tokens.cache_write_5m);
        w.i64(self.tokens.cache_read);
        w.i64(self.tokens.output);
        w.opt_f64(self.carried_cost);
    }

    fn decode(r: &mut Reader<'_>) -> Option<Self> {
        Some(GrokEntry {
            event_id: r.opt_str()?,
            timestamp: r.f64()?,
            model: r.str()?,
            tokens: TokenBreakdown {
                input: r.i64()?,
                cache_write_5m: r.i64()?,
                cache_write_1h: 0,
                cache_read: r.i64()?,
                output: r.i64()?,
                is_fast: false,
            },
            carried_cost: r.opt_f64()?,
        })
    }
}

#[derive(Clone, Default)]
pub struct GrokLineParser;

impl LineParser for GrokLineParser {
    type Item = GrokEntry;
    type State = ();
    const LAYOUT: u32 = 2;

    fn wants(&self, line: &[u8]) -> bool {
        memchr::memmem::find(line, b"turn_completed").is_some()
    }

    fn parse(&self, _state: &mut (), line: &[u8], out: &mut Vec<Self::Item>) -> Result<(), LineError> {
        if let Some(entries) = parse_line(line) {
            out.extend(entries);
        }
        Ok(())
    }

    fn contributing_timestamp(&self, item: &Self::Item) -> Option<f64> {
        Some(item.timestamp)
    }
}

pub fn parse_line(line: &[u8]) -> Option<Vec<GrokEntry>> {
    let Value::Object(obj) = serde_json::from_slice::<Value>(line).ok()? else {
        return None;
    };
    let params = obj.get("params").and_then(Value::as_object);
    let update = params
        .and_then(|p| p.get("update"))
        .or_else(|| obj.get("update"))
        .and_then(Value::as_object)?;
    if update.get("sessionUpdate").and_then(Value::as_str) != Some("turn_completed") {
        return None;
    }
    let usage = update.get("usage").and_then(Value::as_object)?;
    let model_usage = usage.get("modelUsage").and_then(Value::as_object)?;
    if model_usage.is_empty() {
        return None;
    }

    let raw_meta = params.and_then(|p| p.get("_meta")).or_else(|| obj.get("_meta"));
    let metadata = match raw_meta {
        None | Some(Value::Null) => None,
        Some(Value::Object(m)) => Some(m),
        Some(_) => return None,
    };
    let event_id: Option<Arc<str>> = match metadata.and_then(|m| m.get("eventId")) {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) => {
            let trimmed = s.trim();
            if trimmed.is_empty() { None } else { Some(Arc::from(trimmed)) }
        }
        Some(_) => return None,
    };

    let timestamp = extract_timestamp(metadata, &obj)?;
    let top_ticks = match usage.get("costUsdTicks") {
        None | Some(Value::Null) => None,
        Some(raw) => Some(valid_ticks(raw)?),
    };

    let mut out = Vec::with_capacity(model_usage.len());
    for (raw_model, raw_values) in model_usage {
        let model_name = raw_model.trim();
        let values = raw_values.as_object()?;
        if model_name.is_empty() {
            return None;
        }
        let input = strict_count(values.get("inputTokens"), true)?;
        let output = strict_count(values.get("outputTokens"), true)?;
        let cache_read = strict_count(values.get("cachedReadTokens"), false)?;
        let cache_write = strict_count(values.get("cacheCreationTokens"), false)?;
        if cache_read > input || cache_write > input - cache_read {
            return None;
        }
        let ticks = match values.get("costUsdTicks") {
            None | Some(Value::Null) => if model_usage.len() == 1 { top_ticks } else { None },
            Some(raw) => Some(valid_ticks(raw)?),
        };
        let carried_cost = ticks.map(|t| t / 10_000_000_000.0);
        out.push(GrokEntry {
            event_id: event_id.clone(),
            timestamp,
            model: Arc::from(model_name),
            tokens: TokenBreakdown {
                input: input - cache_read - cache_write,
                cache_write_5m: cache_write,
                cache_write_1h: 0,
                cache_read,
                output,
                is_fast: false,
            },
            carried_cost,
        });
    }
    Some(out)
}

fn extract_timestamp(meta: Option<&serde_json::Map<String, Value>>, obj: &serde_json::Map<String, Value>) -> Option<f64> {
    if let Some(m) = meta {
        if let Some(raw_ms) = m.get("agentTimestampMs") {
            if !raw_ms.is_null() {
                let ms = crate::parse::number(Some(raw_ms)).filter(|v| v.is_finite() && *v > 0.0)?;
                return Some(ms / 1000.0);
            }
        }
    }
    match obj.get("timestamp")? {
        Value::Number(n) => n.as_f64().filter(|v| v.is_finite() && *v > 0.0),
        Value::String(s) => time::parse_iso8601(s.trim()),
        _ => None,
    }
}

fn valid_ticks(val: &Value) -> Option<f64> {
    if val.is_boolean() {
        return None;
    }
    let num = crate::parse::number(Some(val))?;
    (num.is_finite() && num >= 0.0 && num <= 1e15).then_some(num)
}

fn strict_count(val: Option<&Value>, required: bool) -> Option<i64> {
    match val {
        None | Some(Value::Null) => (!required).then_some(0),
        Some(Value::Bool(_)) => None,
        Some(Value::Number(n)) => {
            if let Some(i) = n.as_i64() {
                (0..=1_000_000_000_000_000).contains(&i).then_some(i)
            } else {
                let f = n.as_f64()?;
                (f.is_finite() && f >= 0.0 && f <= 1e15 && f.trunc() == f).then_some(f as i64)
            }
        }
        _ => None,
    }
}

pub fn dedup(entries: impl IntoIterator<Item = GrokEntry>) -> Vec<GrokEntry> {
    let mut seen: HashSet<String> = HashSet::new();
    let mut out = Vec::new();
    for entry in entries {
        if let Some(id) = &entry.event_id {
            let key = format!("{}\0{}", id, entry.model);
            if !seen.insert(key) {
                continue;
            }
        }
        out.push(entry);
    }
    out
}

pub fn aggregate(entries: &[GrokEntry], since: f64, pricing: &ModelPricing) -> LogUsageScan {
    let mut accumulator = DailyUsageAccumulator::new();
    for entry in entries {
        if entry.timestamp < since {
            continue;
        }
        let day = day_key(entry.timestamp);
        let tokens = entry.tokens.total_tokens();
        let estimate = pricing.estimated_cost_dollars(&entry.model, &entry.tokens, Some(entry.timestamp), true);
        let cost = entry.carried_cost.or(estimate);
        accumulator.record_api_estimate(&day, estimate, tokens);
        if cost.is_none() && tokens > 0 {
            accumulator.add_unknown_model(&day, &entry.model);
        }
        accumulator.add(&day, tokens, cost, &entry.model);
    }
    let mut scan = accumulator.build();
    // Preserve provider-reported cost per day alongside imputed cost.
    let mut reported_by_day: HashMap<String, (f64, i64, bool)> = HashMap::new();
    for entry in entries {
        if entry.timestamp < since {
            continue;
        }
        let Some(dollars) = entry.carried_cost.filter(|d| d.is_finite() && *d >= 0.0) else {
            continue;
        };
        let day = day_key(entry.timestamp);
        let slot = reported_by_day.entry(day).or_insert((0.0, 0, false));
        if slot.2 {
            continue;
        }
        let next = slot.0 + dollars;
        if !next.is_finite() {
            slot.2 = true;
            continue;
        }
        slot.0 = next;
        slot.1 = crate::accounting::adding_saturating(slot.1, entry.tokens.total_tokens());
    }
    for day_entry in &mut scan.series.daily {
        if let Some(&(dollars, covered_tokens, overflowed)) = reported_by_day.get(&day_entry.date) {
            if !overflowed && covered_tokens >= 0 {
                day_entry.reported_cost = Some(ReportedUsageCost { dollars, covered_tokens });
            }
        }
    }
    scan
}

pub struct GrokLogUsageScanner {
    home_override: Option<PathBuf>,
    env: Arc<dyn Fn(&str) -> Option<String> + Send + Sync>,
    incremental: Option<Arc<IncrementalScanner<GrokLineParser>>>,
    summary_cache: Mutex<HashMap<PathBuf, (Revision, bool)>>,
}

impl GrokLogUsageScanner {
    pub fn live() -> Self {
        GrokLogUsageScanner {
            home_override: None,
            env: Arc::new(host::env_var),
            incremental: None,
            summary_cache: Mutex::new(HashMap::new()),
        }
    }

    pub fn new(
        home: PathBuf,
        env: Arc<dyn Fn(&str) -> Option<String> + Send + Sync>,
        incremental: Option<Arc<IncrementalScanner<GrokLineParser>>>,
    ) -> Self {
        GrokLogUsageScanner {
            home_override: Some(home),
            env,
            incremental,
            summary_cache: Mutex::new(HashMap::new()),
        }
    }

    pub fn unload_caches(&self) {
        self.summary_cache.lock().unwrap_or_else(|e| e.into_inner()).clear();
    }

    fn grok_home(&self) -> PathBuf {
        if let Some(raw) = (self.env)("GROK_HOME") {
            let trimmed = raw.trim();
            if !trimmed.is_empty() {
                let base = self.home_override.clone().unwrap_or_else(paths::home);
                return expand_home(&base, trimmed);
            }
        }
        self.home_override.clone().unwrap_or_else(paths::home).join(".grok")
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
        let sessions_dir = self.grok_home().join("sessions");
        let files = match self.discover_updates(&sessions_dir) {
            Ok(files) => files,
            Err(err) => {
                qlog!(Warn, host::plugin_tag(ID), "session files could not be completely enumerated; preserving last-good history: {err}");
                return None;
            }
        };
        if cancel.is_cancelled() {
            return None;
        }
        let identity = sessions_dir.to_string_lossy().into_owned();
        let scanner = self.scanner_for(&identity);
        if files.is_empty() {
            let _ = scanner.scan(&[], Some(since), cancel);
            return None;
        }
        let scanned: Vec<FileItems<GrokEntry>> = match scanner.scan(&files, Some(since), cancel) {
            Ok(s) => s,
            Err(ScanError::Cancelled) => return None,
            Err(err) => {
                qlog!(Warn, host::plugin_tag(ID), "grok session scan incomplete: {err}");
                return None;
            }
        };
        if first_future_dated(&scanned, now).is_some() {
            diagnostic_gate::log_once(FUTURE_TIMESTAMP_KEY, || {
                qlog!(Warn, host::plugin_tag(ID), "session usage contains a timestamp more than five minutes ahead; preserving last-good history");
            });
            return None;
        }
        diagnostic_gate::clear(FUTURE_TIMESTAMP_KEY);
        let _zone = zone_signature(since, now);
        let entries = dedup(scanned.iter().flat_map(|f| f.iter().cloned()));
        let _ = fingerprint(&scanned, &[]);
        let pricing = pricing_provider();
        Some(aggregate(&entries, since, &pricing))
    }

    fn discover_updates(&self, root: &Path) -> std::io::Result<Vec<DiscoveredFile>> {
        let canon = match std::fs::canonicalize(root) {
            Ok(p) => p,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(e),
        };
        if !std::fs::metadata(&canon)?.is_dir() {
            return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "grok sessions root is not a directory"));
        }
        let mut files = Vec::new();
        let mut stack = vec![canon];
        while let Some(dir) = stack.pop() {
            for entry in std::fs::read_dir(&dir)? {
                let entry = entry?;
                let kind = entry.file_type()?;
                if kind.is_dir() {
                    stack.push(entry.path());
                } else if kind.is_file() && entry.file_name().to_str() == Some("updates.jsonl") {
                    let updates_path = entry.path();
                    if self.include_session_for_updates(&updates_path)? {
                        let revision = Revision::read(&updates_path)?;
                        files.push(DiscoveredFile { path: updates_path, revision });
                    }
                }
            }
        }
        files.sort_by(|a, b| a.path.cmp(&b.path));
        Ok(files)
    }

    fn include_session_for_updates(&self, updates_path: &Path) -> std::io::Result<bool> {
        let Some(parent) = updates_path.parent() else {
            return Ok(true);
        };
        let summary_path = parent.join("summary.json");
        let rev = match Revision::read(&summary_path) {
            Ok(rev) => rev,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(true),
            Err(e) => return Err(e),
        };
        {
            let cache = self.summary_cache.lock().unwrap_or_else(|e| e.into_inner());
            if let Some((cached_rev, include)) = cache.get(&summary_path) {
                if *cached_rev == rev {
                    return Ok(*include);
                }
            }
        }
        let text = std::fs::read_to_string(&summary_path)?;
        let obj: serde_json::Map<String, Value> = serde_json::from_str::<Value>(&text)
            .ok()
            .and_then(|v| v.as_object().cloned())
            .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::InvalidData, "malformed summary.json"))?;
        let include = match obj.get("session_kind") {
            None | Some(Value::Null) => true,
            Some(Value::String(kind)) => !kind.trim().to_ascii_lowercase().starts_with("subagent"),
            Some(_) => return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "invalid session_kind")),
        };
        let mut cache = self.summary_cache.lock().unwrap_or_else(|e| e.into_inner());
        if cache.len() >= SUMMARY_CACHE_CAP {
            cache.clear();
        }
        cache.insert(summary_path, (rev, include));
        Ok(include)
    }

    fn scanner_for(&self, identity: &str) -> Arc<IncrementalScanner<GrokLineParser>> {
        if let Some(scanner) = &self.incremental {
            return scanner.clone();
        }
        let partition = format!("grok:{}", stable_fingerprint(identity));
        let mut reg = registry().lock().unwrap_or_else(|e| e.into_inner());
        reg.entry(partition.clone())
            .or_insert_with(|| Arc::new(IncrementalScanner::new(GrokLineParser, partition, Some(ScanStore::shared()))))
            .clone()
    }
}

fn registry() -> &'static Mutex<HashMap<String, Arc<IncrementalScanner<GrokLineParser>>>> {
    static REGISTRY: OnceLock<Mutex<HashMap<String, Arc<IncrementalScanner<GrokLineParser>>>>> = OnceLock::new();
    REGISTRY.get_or_init(Default::default)
}

pub fn unload_global_caches() {
    registry().lock().unwrap_or_else(|e| e.into_inner()).clear();
}
