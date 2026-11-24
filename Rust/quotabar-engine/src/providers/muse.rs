//! Muse local session log scanner (Swift `MuseUsageScanner`).
//!
//! Muse's runtime emits `goal_usage_attribution` with per-step token counts inside `session.jsonl`
//! files under `~/.local/share/muse/sessions`. Produces entries normalized for OpenCode gateway
//! attribution (used by OpenCode in Batch 3C).

use super::claude::util::since_date;
use super::claude::ClaudeEntry;
use crate::accounting::{adding_saturating, day_key};
use crate::context::CancelToken;
use crate::host::{self, diagnostic_gate};
use crate::paths;
use crate::pricing::TokenBreakdown;
use crate::qlog;
use crate::scan::discover::{DiscoveredFile, Revision};
use crate::scan::{first_future_dated, IncrementalScanner, LineError, LineParser, Reader, Record, ScanError, ScanStore, Writer};
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

#[derive(Clone, Debug, PartialEq)]
pub struct MuseEntry {
    pub timestamp: f64,
    pub tokens: TokenBreakdown,
    pub model: Option<Arc<str>>,
}

impl Record for MuseEntry {
    fn encode(&self, w: &mut Writer) {
        w.f64(self.timestamp);
        w.i64(self.tokens.input);
        w.i64(self.tokens.output);
        w.i64(self.tokens.cache_read);
        w.opt_str(self.model.as_deref());
    }

    fn decode(r: &mut Reader<'_>) -> Option<Self> {
        let timestamp = r.f64()?;
        let input = r.i64()?;
        let output = r.i64()?;
        let cache_read = r.i64()?;
        let model = r.opt_str()?;
        Some(MuseEntry {
            timestamp,
            tokens: TokenBreakdown {
                input,
                cache_write_5m: 0,
                cache_write_1h: 0,
                cache_read,
                output,
                is_fast: false,
            },
            model,
        })
    }
}

#[derive(Clone, Default)]
pub struct MuseLineParser;

impl LineParser for MuseLineParser {
    type Item = MuseEntry;
    type State = ();
    const LAYOUT: u32 = 4;

    fn wants(&self, line: &[u8]) -> bool {
        memchr::memmem::find(line, br#""goal_usage_attribution""#).is_some()
    }

    fn parse(&self, _state: &mut (), line: &[u8], out: &mut Vec<Self::Item>) -> Result<(), LineError> {
        if line.iter().all(u8::is_ascii_whitespace) {
            return Ok(());
        }
        if let Some(entry) = parse_line(line)? {
            out.push(entry);
        }
        Ok(())
    }

    fn contributing_timestamp(&self, item: &Self::Item) -> Option<f64> {
        Some(item.timestamp)
    }
}

pub fn parse_line(line: &[u8]) -> Result<Option<MuseEntry>, LineError> {
    let Ok(Value::Object(obj)) = serde_json::from_slice::<Value>(line) else {
        return Ok(None);
    };
    let Some(event) = obj
        .get("payload")
        .and_then(Value::as_object)
        .and_then(|p| p.get("event"))
        .and_then(Value::as_object)
    else {
        return Ok(None);
    };
    if event.get("kind").and_then(Value::as_str) != Some("goal_usage_attribution") {
        return Ok(None);
    }
    let Some(record) = event.get("record").and_then(Value::as_object) else {
        return Err(LineError("missing record"));
    };
    let Some(quantity) = record.get("quantity").and_then(Value::as_object) else {
        return Err(LineError("missing quantity"));
    };
    let Some(reported) = quantity.get("reported").and_then(Value::as_bool) else {
        return Err(LineError("invalid reported flag"));
    };
    let Some(unit) = quantity.get("unit").and_then(Value::as_str) else {
        return Err(LineError("missing unit"));
    };
    if !reported || unit != "tokens" {
        return Ok(None);
    }

    let input = strict_count(quantity.get("input_tokens"), true).ok_or(LineError("invalid input_tokens"))?;
    let output = strict_count(quantity.get("output_tokens"), true).ok_or(LineError("invalid output_tokens"))?;
    let cached = strict_count(quantity.get("cached_tokens"), false).ok_or(LineError("invalid cached_tokens"))?;
    let reasoning = strict_count(quantity.get("reasoning_tokens"), false).ok_or(LineError("invalid reasoning_tokens"))?;
    if cached > input {
        return Err(LineError("cached_tokens exceeds input_tokens"));
    }
    let uncached_input = input - cached;

    let micros = obj
        .get("recorded_at")
        .and_then(|v| match v {
            Value::Number(n) => n.as_i64().or_else(|| {
                n.as_f64()
                    .filter(|f| f.is_finite() && *f >= 0.0 && *f <= 9e15 && f.trunc() == *f)
                    .map(|f| f as i64)
            }),
            _ => None,
        })
        .filter(|m| *m > 0 && *m <= 9_000_000_000_000_000)
        .ok_or(LineError("invalid recorded_at"))?;
    let timestamp = micros as f64 / 1_000_000.0;

    let model = non_empty_trimmed(record.get("model"))
        .or_else(|| non_empty_trimmed(quantity.get("model")))
        .or_else(|| Some("muse-spark-1.2-contributor".into()));

    Ok(Some(MuseEntry {
        timestamp,
        tokens: TokenBreakdown {
            input: uncached_input,
            cache_write_5m: 0,
            cache_write_1h: 0,
            cache_read: cached,
            output: adding_saturating(output, reasoning),
            is_fast: false,
        },
        model,
    }))
}

fn non_empty_trimmed(value: Option<&Value>) -> Option<Arc<str>> {
    value
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(Arc::from)
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

pub fn sessions_directory(home: &Path) -> PathBuf {
    home.join(".local/share/muse/sessions")
}

/// Discover `session.jsonl` files recursively under `roots`, ignoring `approval-review/` and
/// `process-owners/`. Failing to read a present directory fails completeness (`Err`).
pub fn discover_session_files(roots: &[PathBuf]) -> std::io::Result<Vec<DiscoveredFile>> {
    let mut files = Vec::new();
    for root in roots {
        let canon = match std::fs::canonicalize(root) {
            Ok(p) => p,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(e) => return Err(e),
        };
        if !std::fs::metadata(&canon)?.is_dir() {
            return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "muse root is not a directory"));
        }
        let mut stack = vec![canon];
        while let Some(dir) = stack.pop() {
            for entry in std::fs::read_dir(&dir)? {
                let entry = entry?;
                let name = entry.file_name();
                let Some(name_str) = name.to_str() else { continue };
                let kind = entry.file_type()?;
                if kind.is_dir() {
                    if name_str == "approval-review" || name_str == "process-owners" {
                        continue;
                    }
                    stack.push(entry.path());
                } else if kind.is_file() && name_str == "session.jsonl" {
                    let path = entry.path();
                    let revision = Revision::read(&path)?;
                    files.push(DiscoveredFile { path, revision });
                }
            }
        }
    }
    files.sort_by(|a, b| a.path.cmp(&b.path));
    files.dedup_by(|a, b| a.path == b.path);
    Ok(files)
}

pub struct MuseUsageScanner {
    roots: Vec<PathBuf>,
    incremental: Option<Arc<IncrementalScanner<MuseLineParser>>>,
}

impl MuseUsageScanner {
    pub fn live() -> Self {
        Self::new(vec![sessions_directory(&paths::home())], None)
    }

    pub fn new(roots: Vec<PathBuf>, incremental: Option<Arc<IncrementalScanner<MuseLineParser>>>) -> Self {
        MuseUsageScanner { roots, incremental }
    }

    pub fn parsed_entries_if_complete(
        &self,
        days_back: usize,
        now: f64,
        cancel: &CancelToken,
    ) -> Option<Vec<MuseEntry>> {
        if cancel.is_cancelled() {
            return None;
        }
        let since = since_date(days_back, now);
        let files = match discover_session_files(&self.roots) {
            Ok(files) => files,
            Err(err) => {
                qlog!(Warn, host::plugin_tag("muse"), "muse session directory unreadable: {err}");
                return None;
            }
        };
        let identity = if self.roots.is_empty() {
            "no-muse-root".to_string()
        } else {
            let mut sorted: Vec<String> = self.roots.iter().map(|p| p.to_string_lossy().into_owned()).collect();
            sorted.sort();
            sorted.join("\n")
        };
        let scanner = self.scanner_for(&identity);
        let scanned = match scanner.scan(&files, Some(since), cancel) {
            Ok(s) => s,
            Err(ScanError::Cancelled) => return None,
            Err(err) => {
                qlog!(Warn, host::plugin_tag("muse"), "muse session scan incomplete: {err}");
                return None;
            }
        };
        let gate = "muse.sessions.future-timestamp";
        if first_future_dated(&scanned, now).is_some() {
            diagnostic_gate::log_once(gate, || {
                qlog!(
                    Warn,
                    host::plugin_tag("muse"),
                    "session usage contains a timestamp more than five minutes ahead; preserving last-good history"
                );
            });
            return None;
        }
        diagnostic_gate::clear(gate);
        let mut out = Vec::new();
        for file in &scanned {
            for entry in file.iter() {
                if entry.timestamp >= since {
                    let _ = day_key(entry.timestamp);
                    out.push(entry.clone());
                }
            }
        }
        Some(out)
    }

    /// Normalize Muse entries into `ClaudeEntry` gateway rows for OpenCode's combined fold.
    pub fn to_claude_gateway_entries(entries: &[MuseEntry]) -> Vec<ClaudeEntry> {
        entries
            .iter()
            .map(|e| ClaudeEntry {
                timestamp: e.timestamp,
                tokens: e.tokens.clone(),
                message_id: None,
                request_id: None,
                is_sidechain: false,
                has_speed: false,
                cost_usd: None,
                model: Some(e.model.clone().unwrap_or_else(|| Arc::from("muse-spark-1.2-contributor"))),
            })
            .collect()
    }

    fn scanner_for(&self, identity: &str) -> Arc<IncrementalScanner<MuseLineParser>> {
        if let Some(scanner) = &self.incremental {
            return scanner.clone();
        }
        let partition = format!("muse:{}", super::claude::util::stable_fingerprint(identity));
        let mut reg = registry().lock().unwrap_or_else(|e| e.into_inner());
        reg.entry(partition.clone())
            .or_insert_with(|| Arc::new(IncrementalScanner::new(MuseLineParser, partition, Some(ScanStore::shared()))))
            .clone()
    }
}

fn registry() -> &'static Mutex<HashMap<String, Arc<IncrementalScanner<MuseLineParser>>>> {
    static REGISTRY: OnceLock<Mutex<HashMap<String, Arc<IncrementalScanner<MuseLineParser>>>>> = OnceLock::new();
    REGISTRY.get_or_init(Default::default)
}

pub fn unload_caches() {
    registry().lock().unwrap_or_else(|e| e.into_inner()).clear();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_goal_usage_attribution_and_skips_irrelevant() {
        let line = br#"{"recorded_at":1780000000000000,"payload":{"event":{"kind":"goal_usage_attribution","record":{"model":"muse-spark-1.2-contributor","quantity":{"reported":true,"unit":"tokens","input_tokens":1000,"output_tokens":200,"cached_tokens":700,"reasoning_tokens":50}}}}}"#;
        let entry = parse_line(line).unwrap().unwrap();
        assert_eq!(entry.tokens.input, 300);
        assert_eq!(entry.tokens.cache_read, 700);
        assert_eq!(entry.tokens.output, 250);
        assert_eq!(entry.model.as_deref(), Some("muse-spark-1.2-contributor"));

        let unreported = br#"{"recorded_at":1780000000000000,"payload":{"event":{"kind":"goal_usage_attribution","record":{"quantity":{"reported":false,"unit":"tokens"}}}}}"#;
        assert!(parse_line(unreported).unwrap().is_none());
    }

    #[test]
    fn discovers_only_session_jsonl_outside_excluded_dirs() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join(".local/share/muse/sessions");
        std::fs::create_dir_all(root.join("s1")).unwrap();
        std::fs::create_dir_all(root.join("approval-review")).unwrap();
        std::fs::create_dir_all(root.join("process-owners")).unwrap();
        std::fs::write(root.join("s1/session.jsonl"), "{}\n").unwrap();
        std::fs::write(root.join("s1/other.jsonl"), "{}\n").unwrap();
        std::fs::write(root.join("approval-review/session.jsonl"), "{}\n").unwrap();
        std::fs::write(root.join("process-owners/session.jsonl"), "{}\n").unwrap();
        let found = discover_session_files(&[root]).unwrap();
        assert_eq!(found.len(), 1);
        assert!(found[0].path.ends_with("s1/session.jsonl"));
    }
}
