//! Pi coding-agent local session log scanner (Swift `PiUsageScanner`).
//!
//! Pi is a BYO-key agent that drives other providers' models, so its usage is attributed back to
//! the underlying QuotaBar provider (`claude`, `codex`, ...) rather than rendered on a card of its
//! own. Shared by Claude and Codex in Batch 3C.

use super::claude::util::{expand_home, since_date, stable_fingerprint, zone_signature};
use crate::accounting::{day_key, DailyUsageAccumulator, LogUsageScan};
use crate::context::CancelToken;
use crate::host::{self, diagnostic_gate};
use crate::model::ModelUsageEntry;
use crate::paths;
use crate::pricing::{ModelPricing, TokenBreakdown};
use crate::qlog;
use crate::scan::{
    discover, fingerprint, first_future_dated, Extensions, FileItems, IncrementalScanner,
    LineError, LineParser, Reader, Record, ScanError, ScanStore, Writer,
};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

pub fn card_id_for_pi_provider(provider: &str) -> Option<&'static str> {
    match provider {
        "anthropic" | "claude-agent-sdk" => Some("claude"),
        "openai-codex" => Some("codex"),
        "cursor" => Some("cursor"),
        "zai" | "zhipu" => Some("zai"),
        "google-antigravity" => Some("antigravity"),
        "github-copilot" => Some("copilot"),
        _ => None,
    }
}

pub fn sessions_directory(home: &Path, env: &dyn Fn(&str) -> Option<String>) -> PathBuf {
    if let Some(dir) = env("PI_CODING_AGENT_SESSION_DIR") {
        let trimmed = dir.trim();
        if !trimmed.is_empty() {
            return expand_home(home, trimmed);
        }
    }
    if let Some(cfg) = env("PI_CODING_AGENT_DIR") {
        let trimmed = cfg.trim();
        if !trimmed.is_empty() {
            return expand_home(home, trimmed).join("sessions");
        }
    }
    home.join(".pi/agent/sessions")
}

#[derive(Clone, Debug, PartialEq)]
pub struct PiEntry {
    pub id: Option<Arc<str>>,
    pub timestamp: f64,
    pub card_id: Arc<str>,
    pub model: Arc<str>,
    pub carried_cost: Option<f64>,
    pub tokens: TokenBreakdown,
    pub reported_total_tokens: i64,
}

impl Record for PiEntry {
    fn encode(&self, w: &mut Writer) {
        w.opt_str(self.id.as_deref());
        w.f64(self.timestamp);
        w.str(&self.card_id);
        w.str(&self.model);
        w.opt_f64(self.carried_cost);
        w.i64(self.tokens.input);
        w.i64(self.tokens.cache_write_5m);
        w.i64(self.tokens.cache_write_1h);
        w.i64(self.tokens.cache_read);
        w.i64(self.tokens.output);
        w.i64(self.reported_total_tokens);
    }

    fn decode(r: &mut Reader<'_>) -> Option<Self> {
        Some(PiEntry {
            id: r.opt_str()?,
            timestamp: r.f64()?,
            card_id: r.str()?,
            model: r.str()?,
            carried_cost: r.opt_f64()?,
            tokens: TokenBreakdown {
                input: r.i64()?,
                cache_write_5m: r.i64()?,
                cache_write_1h: r.i64()?,
                cache_read: r.i64()?,
                output: r.i64()?,
                is_fast: false,
            },
            reported_total_tokens: r.i64()?,
        })
    }
}

#[derive(Clone, Default)]
pub struct PiLineParser;

impl LineParser for PiLineParser {
    type Item = PiEntry;
    type State = ();
    const LAYOUT: u32 = 3;

    fn wants(&self, line: &[u8]) -> bool {
        memchr::memmem::find(line, br#""usage""#).is_some()
    }

    fn parse(
        &self,
        _state: &mut (),
        line: &[u8],
        out: &mut Vec<Self::Item>,
    ) -> Result<(), LineError> {
        if line.iter().all(u8::is_ascii_whitespace) {
            return Ok(());
        }
        if let Some(entry) = parse_line(line)? {
            out.push(entry);
        }
        Ok(())
    }

    fn contributing_timestamp(&self, item: &Self::Item) -> Option<f64> {
        if item.reported_total_tokens == 0 && item.carried_cost.unwrap_or(0.0) <= 0.0 {
            return None;
        }
        Some(item.timestamp)
    }
}

pub fn parse_line(line: &[u8]) -> Result<Option<PiEntry>, LineError> {
    let Ok(Value::Object(obj)) = serde_json::from_slice::<Value>(line) else {
        return Ok(None);
    };
    if obj.get("type").and_then(Value::as_str) != Some("message") {
        return Ok(None);
    }
    let Some(msg) = obj.get("message").and_then(Value::as_object) else {
        return Err(LineError("missing message"));
    };
    if msg.get("role").and_then(Value::as_str) != Some("assistant") {
        return Ok(None);
    }
    let Some(provider_id) = msg.get("provider").and_then(Value::as_str) else {
        return Err(LineError("missing provider"));
    };
    let Some(card_id) = card_id_for_pi_provider(provider_id) else {
        return Ok(None);
    };
    let Some(ts_raw) = obj.get("timestamp").and_then(Value::as_str) else {
        return Err(LineError("missing timestamp"));
    };
    let Some(timestamp) = crate::time::parse_iso8601(ts_raw) else {
        return Err(LineError("invalid timestamp"));
    };
    let Some(usage) = msg.get("usage").and_then(Value::as_object) else {
        return Err(LineError("missing usage"));
    };

    let id = match obj.get("id") {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) => {
            let trimmed = s.trim();
            (!trimmed.is_empty()).then(|| Arc::from(trimmed))
        }
        Some(_) => return Err(LineError("invalid id")),
    };

    let input = strict_count(usage.get("input"), true).ok_or(LineError("invalid input"))?;
    let output = strict_count(usage.get("output"), true).ok_or(LineError("invalid output"))?;
    let cache_read =
        strict_count(usage.get("cacheRead"), false).ok_or(LineError("invalid cacheRead"))?;
    let cache_write =
        strict_count(usage.get("cacheWrite"), false).ok_or(LineError("invalid cacheWrite"))?;
    let cache_write_1h_raw =
        strict_count(usage.get("cacheWrite1h"), false).ok_or(LineError("invalid cacheWrite1h"))?;
    let reported_total =
        strict_count(usage.get("totalTokens"), true).ok_or(LineError("invalid totalTokens"))?;

    let cache_write_1h = cache_write_1h_raw.min(cache_write);
    let cache_write_5m = cache_write - cache_write_1h;

    let carried_cost = match usage.get("cost") {
        None | Some(Value::Null) => None,
        Some(Value::Object(cost)) => match cost.get("total") {
            None | Some(Value::Null) => None,
            Some(v) => {
                let Some(num) = crate::parse::number(Some(v)) else {
                    return Err(LineError("invalid carried cost"));
                };
                if !num.is_finite() || num < 0.0 || num > 1e12 {
                    return Err(LineError("out-of-range carried cost"));
                }
                Some(num)
            }
        },
        Some(_) => return Err(LineError("invalid cost object")),
    };

    let model: Arc<str> = match msg.get("model") {
        None | Some(Value::Null) => Arc::from(""),
        Some(Value::String(s)) => Arc::from(s.trim()),
        Some(_) => return Err(LineError("invalid model")),
    };

    Ok(Some(PiEntry {
        id,
        timestamp,
        card_id: Arc::from(card_id),
        model,
        carried_cost,
        tokens: TokenBreakdown {
            input,
            cache_write_5m,
            cache_write_1h,
            cache_read,
            output,
            is_fast: false,
        },
        reported_total_tokens: reported_total,
    }))
}

fn strict_count(value: Option<&Value>, required: bool) -> Option<i64> {
    match value {
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

pub fn dedup(entries: impl IntoIterator<Item = PiEntry>) -> Vec<PiEntry> {
    let mut seen: HashSet<Arc<str>> = HashSet::new();
    let mut out = Vec::new();
    for entry in entries {
        if let Some(id) = &entry.id {
            if !seen.insert(id.clone()) {
                continue;
            }
        }
        out.push(entry);
    }
    out
}

pub fn aggregate(
    entries: &[PiEntry],
    card_id: &str,
    since: f64,
    pricing: &ModelPricing,
) -> LogUsageScan {
    let mut accumulator = DailyUsageAccumulator::new();
    for entry in entries {
        if entry.card_id.as_ref() != card_id || entry.timestamp < since {
            continue;
        }
        let day = day_key(entry.timestamp);
        let trimmed = (!entry.model.is_empty()).then_some(entry.model.as_ref());
        let model_name = trimmed.unwrap_or(ModelUsageEntry::UNATTRIBUTED);
        let api_estimate = trimmed.and_then(|m| {
            pricing.estimated_cost_dollars(m, &entry.tokens, Some(entry.timestamp), true)
        });
        let cost = entry.carried_cost.filter(|c| *c > 0.0).or(api_estimate);
        if cost.is_none() && entry.reported_total_tokens > 0 {
            accumulator.add_unknown_model(&day, model_name);
        }
        accumulator.record_api_estimate(&day, api_estimate, entry.reported_total_tokens);
        accumulator.add(&day, entry.reported_total_tokens, cost, model_name);
    }
    accumulator.build()
}

#[derive(Clone, Debug, PartialEq)]
pub enum PiScanResult {
    Complete(Option<LogUsageScan>),
    Incomplete,
}

pub struct PiUsageScanner {
    home: PathBuf,
    env: Arc<dyn Fn(&str) -> Option<String> + Send + Sync>,
    incremental: Option<Arc<IncrementalScanner<PiLineParser>>>,
}

impl PiUsageScanner {
    pub fn live() -> Self {
        PiUsageScanner {
            home: paths::home(),
            env: Arc::new(host::env_var),
            incremental: None,
        }
    }

    pub fn new(
        home: PathBuf,
        env: Arc<dyn Fn(&str) -> Option<String> + Send + Sync>,
        incremental: Option<Arc<IncrementalScanner<PiLineParser>>>,
    ) -> Self {
        PiUsageScanner {
            home,
            env,
            incremental,
        }
    }

    pub fn scan(
        &self,
        card_id: &str,
        days_back: usize,
        now: f64,
        pricing: &ModelPricing,
        cancel: &CancelToken,
    ) -> Option<LogUsageScan> {
        match self.scan_result(card_id, days_back, now, pricing, cancel) {
            PiScanResult::Complete(scan) => scan,
            PiScanResult::Incomplete => None,
        }
    }

    pub fn scan_result(
        &self,
        card_id: &str,
        days_back: usize,
        now: f64,
        pricing: &ModelPricing,
        cancel: &CancelToken,
    ) -> PiScanResult {
        if cancel.is_cancelled() {
            return PiScanResult::Incomplete;
        }
        let since = since_date(days_back, now);
        let dir = sessions_directory(&self.home, self.env.as_ref());
        let identity = dir.to_string_lossy().into_owned();
        let files = match discover(&dir, Extensions::Jsonl) {
            Ok(files) => files,
            Err(err) => {
                qlog!(
                    Warn,
                    host::plugin_tag("pi"),
                    "session directory could not be completely enumerated: {err}"
                );
                return PiScanResult::Incomplete;
            }
        };
        if cancel.is_cancelled() {
            return PiScanResult::Incomplete;
        }
        let scanner = self.scanner_for(&identity);
        if files.is_empty() {
            let _ = scanner.scan(&[], Some(since), cancel);
            return PiScanResult::Complete(None);
        }
        let scanned: Vec<FileItems<PiEntry>> = match scanner.scan(&files, Some(since), cancel) {
            Ok(s) => s,
            Err(ScanError::Cancelled) => return PiScanResult::Incomplete,
            Err(err) => {
                qlog!(
                    Warn,
                    host::plugin_tag("pi"),
                    "pi session scan incomplete: {err}"
                );
                return PiScanResult::Incomplete;
            }
        };
        let gate = format!(
            "pi.sessions.future-timestamp.{}",
            stable_fingerprint(&identity)
        );
        if first_future_dated(&scanned, now).is_some() {
            diagnostic_gate::log_once(&gate, || {
                qlog!(
                    Warn,
                    host::plugin_tag("pi"),
                    "session usage contains a timestamp more than five minutes ahead; preserving last-good history"
                );
            });
            return PiScanResult::Incomplete;
        }
        diagnostic_gate::clear(&gate);
        let _zone = zone_signature(since, now);
        let entries = dedup(scanned.iter().flat_map(|f| f.iter().cloned()));
        let filtered: Vec<PiEntry> = entries
            .into_iter()
            .filter(|e| {
                e.card_id.as_ref() == card_id
                    && e.timestamp >= since
                    && (e.reported_total_tokens > 0 || e.carried_cost.unwrap_or(0.0) > 0.0)
            })
            .collect();
        if filtered.is_empty() {
            return PiScanResult::Complete(None);
        }
        let _ = fingerprint(&scanned, &[card_id]);
        PiScanResult::Complete(Some(aggregate(&filtered, card_id, since, pricing)))
    }

    fn scanner_for(&self, identity: &str) -> Arc<IncrementalScanner<PiLineParser>> {
        if let Some(scanner) = &self.incremental {
            return scanner.clone();
        }
        let partition = format!("pi:{}", stable_fingerprint(identity));
        let mut reg = registry().lock().unwrap_or_else(|e| e.into_inner());
        reg.entry(partition.clone())
            .or_insert_with(|| {
                Arc::new(IncrementalScanner::new(
                    PiLineParser,
                    partition,
                    Some(ScanStore::shared()),
                ))
            })
            .clone()
    }
}

fn registry() -> &'static Mutex<HashMap<String, Arc<IncrementalScanner<PiLineParser>>>> {
    static REGISTRY: OnceLock<Mutex<HashMap<String, Arc<IncrementalScanner<PiLineParser>>>>> =
        OnceLock::new();
    REGISTRY.get_or_init(Default::default)
}

pub fn unload_caches() {
    let mut registry = registry().lock().unwrap_or_else(|e| e.into_inner());
    for scanner in registry.values() {
        scanner.clear_memory_cache();
    }
    registry.clear();
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pricing::{ModelRates, PricingCatalog, PricingSupplement};

    fn sample_line(
        id: &str,
        provider: &str,
        model: &str,
        cost: Option<&str>,
        cw: i64,
        cw1h: i64,
    ) -> Vec<u8> {
        let cost_json = cost
            .map(|c| format!(r#","cost":{{"total":{c}}}"#))
            .unwrap_or_default();
        format!(
            r#"{{"type":"message","id":"{id}","timestamp":"2026-07-12T10:00:00.000Z","message":{{"role":"assistant","provider":"{provider}","model":"{model}","usage":{{"input":100,"output":50,"cacheRead":0,"cacheWrite":{cw},"cacheWrite1h":{cw1h},"totalTokens":150{cost_json}}}}}}}"#
        )
        .into_bytes()
    }

    #[test]
    fn parses_maps_and_splits_cache_write_1h() {
        let entry = parse_line(&sample_line(
            "m1",
            "anthropic",
            "claude-opus-4-8",
            Some("0.5"),
            1000,
            400,
        ))
        .unwrap()
        .unwrap();
        assert_eq!(entry.card_id.as_ref(), "claude");
        assert_eq!(entry.carried_cost, Some(0.5));
        assert_eq!(entry.tokens.cache_write_1h, 400);
        assert_eq!(entry.tokens.cache_write_5m, 600);
        assert_eq!(entry.reported_total_tokens, 150);

        assert_eq!(
            parse_line(&sample_line("m2", "openai-codex", "gpt-5", None, 0, 0))
                .unwrap()
                .unwrap()
                .card_id
                .as_ref(),
            "codex"
        );
        assert!(
            parse_line(&sample_line("m3", "nvidia-nim", "x", None, 0, 0))
                .unwrap()
                .is_none()
        );
        let user = br#"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"user","provider":"anthropic","usage":{}}}"#;
        assert!(parse_line(user).unwrap().is_none());
    }

    #[test]
    fn provider_mapping_and_absurd_counts_safe() {
        assert_eq!(card_id_for_pi_provider("claude-agent-sdk"), Some("claude"));
        assert_eq!(card_id_for_pi_provider("zhipu"), Some("zai"));
        assert_eq!(card_id_for_pi_provider("nvidia-nim"), None);

        let hostile = br#"{"id":"m1","type":"message","timestamp":"2026-09-20T10:00:00.000Z","message":{"role":"assistant","provider":"cursor","model":"composer-2.5","usage":{"input":1e30,"output":1e30,"cacheRead":1e30,"cacheWrite":1e30,"cacheWrite1h":1e30,"totalTokens":1e30}}}"#;
        assert!(parse_line(hostile).is_err());
    }

    #[test]
    fn carried_zero_falls_through_and_dedup_works() {
        let mut entries_map = HashMap::new();
        entries_map.insert(
            "composer-2.5".to_string(),
            ModelRates::new(10.0, 20.0, 10.0, 1.0),
        );
        let pricing = ModelPricing::new(
            PricingSupplement::default(),
            PricingCatalog::from_entries(entries_map),
            PricingCatalog::default(),
            PricingCatalog::default(),
            None,
        );
        let e1 = parse_line(&sample_line(
            "dup",
            "cursor",
            "composer-2.5",
            Some("0"),
            0,
            0,
        ))
        .unwrap()
        .unwrap();
        let e2 = parse_line(&sample_line(
            "dup",
            "cursor",
            "composer-2.5",
            Some("0"),
            0,
            0,
        ))
        .unwrap()
        .unwrap();
        let scan = aggregate(&dedup([e1, e2]), "cursor", 0.0, &pricing);
        assert_eq!(scan.series.daily.len(), 1);
        assert!((scan.series.daily[0].cost_usd.unwrap() - 0.002).abs() < 1e-6);
    }

    #[test]
    fn scan_result_distinguishes_file_root_failure_from_missing_dir() {
        let dir = tempfile::tempdir().unwrap();
        let bad_home = dir.path().join("bad");
        std::fs::create_dir_all(bad_home.join(".pi/agent")).unwrap();
        std::fs::write(bad_home.join(".pi/agent/sessions"), "not a dir").unwrap();
        let scanner_bad = PiUsageScanner::new(
            bad_home,
            Arc::new(|_| None),
            Some(Arc::new(IncrementalScanner::new(
                PiLineParser,
                "test-pi-bad",
                None,
            ))),
        );
        assert_eq!(
            scanner_bad.scan_result(
                "claude",
                30,
                1_800_000_000.0,
                &ModelPricing::default(),
                &CancelToken::new()
            ),
            PiScanResult::Incomplete
        );

        let empty_home = dir.path().join("empty");
        let scanner_empty = PiUsageScanner::new(
            empty_home,
            Arc::new(|_| None),
            Some(Arc::new(IncrementalScanner::new(
                PiLineParser,
                "test-pi-empty",
                None,
            ))),
        );
        assert_eq!(
            scanner_empty.scan_result(
                "claude",
                30,
                1_800_000_000.0,
                &ModelPricing::default(),
                &CancelToken::new()
            ),
            PiScanResult::Complete(None)
        );
    }
}
