//! Native Claude Code session log scanner (ports upstream ClaudeLogUsageScanner).

use crate::log_usage_types::{
    DailyUsageRow, LogScanStatus, ModelDayUsage, TokenBreakdown, cap_log_files_by_mtime,
    expand_tilde, host_query_response, local_day_key_from_offset, merge_daily_rows,
    since_local_midnight, warn_unreadable_usage_file,
};
use crate::model_pricing::{ModelPricing, default_pricing};
use chrono::{DateTime, NaiveDate, Utc};
use serde_json::Value;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::SystemTime;

static FILE_CACHE: Mutex<Option<HashMap<String, CachedFile>>> = Mutex::new(None);

struct CachedFile {
    size: u64,
    mtime: SystemTime,
    entries: Vec<ClaudeEntry>,
}

#[derive(Clone)]
struct ClaudeEntry {
    timestamp: DateTime<Utc>,
    tokens: TokenBreakdown,
    message_id: Option<String>,
    request_id: Option<String>,
    is_sidechain: bool,
    has_speed: bool,
    cost_usd: Option<f64>,
    model: Option<String>,
}

struct DiscoveredFile {
    path: PathBuf,
    size: u64,
    mtime: SystemTime,
}

pub fn query_daily_since(since_compact: &str, home_path: Option<&str>) -> (LogScanStatus, Vec<DailyUsageRow>) {
    let since = parse_since(since_compact);
    let pricing = default_pricing();
    let native = scan(days_back_from_since(since), home_path, pricing).unwrap_or_default();
    let pi = crate::pi_usage_scanner::query_daily_for_card("claude", since_compact);
    let rows = merge_daily_rows(native, pi);
    if rows.is_empty() {
        (LogScanStatus::NoData, vec![])
    } else {
        (LogScanStatus::Ok, rows)
    }
}

pub fn query_daily_host_json(opts_json: &str) -> String {
    let v: serde_json::Value = serde_json::from_str(opts_json).unwrap_or(serde_json::json!({}));
    let since = v.get("since").and_then(|s| s.as_str()).unwrap_or("");
    let home_path = v.get("homePath").and_then(|s| s.as_str());
    let (status, daily) = query_daily_since(since, home_path);
    host_query_response(status, daily)
}

fn parse_since(since: &str) -> DateTime<Utc> {
    let digits: String = since.chars().filter(|c| c.is_ascii_digit()).collect();
    if digits.len() >= 8 {
        if let (Ok(y), Ok(m), Ok(d)) = (
            digits[0..4].parse::<i32>(),
            digits[4..6].parse::<u32>(),
            digits[6..8].parse::<u32>(),
        ) {
            if let Some(date) = NaiveDate::from_ymd_opt(y, m, d) {
                return date.and_hms_opt(0, 0, 0).expect("midnight").and_utc();
            }
        }
    }
    since_local_midnight(30)
}

fn days_back_from_since(since: DateTime<Utc>) -> i32 {
    let now = Utc::now();
    ((now.date_naive() - since.date_naive()).num_days().max(0) + 1) as i32
}

fn scan(days_back: i32, home_path: Option<&str>, pricing: &ModelPricing) -> Option<Vec<DailyUsageRow>> {
    let roots = claude_roots(home_path);
    if roots.is_empty() {
        return None;
    }
    let files = usage_files(&roots);
    if files.is_empty() {
        return None;
    }
    let since = since_local_midnight(days_back);
    let mut entries = Vec::new();
    if let Ok(mut guard) = FILE_CACHE.lock() {
        let cache = guard.get_or_insert_with(HashMap::new);
        let mut next_cache = HashMap::new();
        for file in &files {
            if file_mtime_before(&file.mtime, since) {
                continue;
            }
            let key = file.path.to_string_lossy().to_string();
            let file_entries = if let Some(cached) = cache.get(&key) {
                if cached.size == file.size && cached.mtime == file.mtime {
                    cached.entries.clone()
                } else {
                    parse_file(&file.path)
                }
            } else {
                parse_file(&file.path)
            };
            next_cache.insert(
                key,
                CachedFile {
                    size: file.size,
                    mtime: file.mtime,
                    entries: file_entries.clone(),
                },
            );
            entries.extend(file_entries);
        }
        *cache = next_cache;
    }
    Some(aggregate(&dedup(entries), since, pricing))
}

fn claude_roots(home_path: Option<&str>) -> Vec<PathBuf> {
    let mut roots = Vec::new();
    let mut seen = HashSet::new();

    fn push_root(roots: &mut Vec<PathBuf>, seen: &mut HashSet<String>, url: PathBuf) {
        if url.join("projects").is_dir() {
            let key = url.to_string_lossy().to_string();
            if seen.insert(key) {
                roots.push(url);
            }
        }
    }

    let env_or_arg = home_path
        .filter(|s| !s.trim().is_empty())
        .map(str::to_string)
        .or_else(|| std::env::var("CLAUDE_CONFIG_DIR").ok());

    if let Some(raw) = env_or_arg.filter(|s| !s.trim().is_empty()) {
        for part in raw.split(',') {
            let part = part.trim();
            if part.is_empty() {
                continue;
            }
            let mut url = expand_tilde(part);
            if url.file_name().is_some_and(|n| n == "projects") && url.is_dir() {
                if let Some(parent) = url.parent() {
                    url = parent.to_path_buf();
                }
            }
            push_root(&mut roots, &mut seen, url);
        }
    }

    if roots.is_empty() {
        if let Some(home) = dirs::home_dir() {
            let xdg = std::env::var("XDG_CONFIG_HOME")
                .ok()
                .filter(|s| !s.is_empty())
                .map(|s| expand_tilde(&s))
                .unwrap_or_else(|| home.join(".config"));
            push_root(&mut roots, &mut seen, xdg.join("claude"));
            push_root(&mut roots, &mut seen, home.join(".claude"));
            for sandbox in cowork_claude_dirs(&home) {
                push_root(&mut roots, &mut seen, sandbox);
            }
        }
    }

    roots
}

fn cowork_claude_dirs(home: &Path) -> Vec<PathBuf> {
    let base = home.join("Library/Application Support/Claude/local-agent-mode-sessions");
    if !base.is_dir() {
        return vec![];
    }
    let mut dirs = Vec::new();
    let Ok(groups) = fs::read_dir(&base) else {
        return vec![];
    };
    for group in groups.flatten() {
        let Ok(subs) = fs::read_dir(group.path()) else {
            continue;
        };
        for sub in subs.flatten() {
            let mut sessions: Vec<PathBuf> = fs::read_dir(sub.path())
                .ok()
                .map(|rd| rd.flatten().map(|e| e.path()).collect())
                .unwrap_or_default();
            for holder in sessions.clone() {
                if holder.file_name().is_some_and(|n| n == "agent") {
                    if let Ok(agent_children) = fs::read_dir(&holder) {
                        sessions.extend(agent_children.flatten().map(|e| e.path()));
                    }
                }
            }
            for session in sessions {
                dirs.push(session.join(".claude"));
            }
        }
    }
    dirs.sort();
    dirs
}

fn usage_files(roots: &[PathBuf]) -> Vec<DiscoveredFile> {
    let mut files = Vec::new();
    for root in roots {
        walk_jsonl(&root.join("projects"), &mut files);
    }
    cap_log_files_by_mtime(&mut files, |f| f.mtime, |f| f.size);
    // Stable path order for keep-first dedup after the newest-N / byte cap.
    files.sort_by(|a, b| a.path.cmp(&b.path));
    files
}

fn walk_jsonl(dir: &Path, out: &mut Vec<DiscoveredFile>) {
    let Ok(rd) = fs::read_dir(dir) else {
        return;
    };
    for entry in rd.flatten() {
        let path = entry.path();
        if path.is_dir() {
            walk_jsonl(&path, out);
        } else if path.extension().is_some_and(|e| e == "jsonl") {
            if let Ok(meta) = entry.metadata() {
                out.push(DiscoveredFile {
                    path,
                    size: meta.len(),
                    mtime: meta.modified().unwrap_or(SystemTime::UNIX_EPOCH),
                });
            }
        }
    }
}

fn file_mtime_before(mtime: &SystemTime, since: DateTime<Utc>) -> bool {
    let Ok(duration) = mtime.duration_since(SystemTime::UNIX_EPOCH) else {
        return false;
    };
    let Some(file_dt) = DateTime::<Utc>::from_timestamp(duration.as_secs() as i64, 0) else {
        return false;
    };
    file_dt < since
}

fn parse_file(path: &Path) -> Vec<ClaudeEntry> {
    let mut reader = match fs::File::open(path) {
        Ok(file) => BufReader::new(file),
        Err(_) => {
            warn_unreadable_usage_file(path);
            return vec![];
        }
    };
    let marker = br#""usage""#;
    let mut entries = Vec::new();
    let mut line = Vec::new();
    loop {
        match reader.read_until(b'\n', &mut line) {
            Ok(0) => break,
            Ok(_) => {}
            Err(_) => {
                warn_unreadable_usage_file(path);
                return vec![];
            }
        }
        if line.windows(marker.len()).any(|w| w == marker) {
            entries.extend(parse_entries(&line));
        }
        line.clear();
    }
    entries
}

/// Parent entry from top-level usage; advisor_message iterations become extra entries.
fn parse_entries(line: &[u8]) -> Vec<ClaudeEntry> {
    let Ok(v) = serde_json::from_slice::<Value>(line) else {
        return vec![];
    };
    if v.get("type").is_some_and(|kind| kind.as_str() != Some("assistant")) {
        return vec![];
    }
    let Some(timestamp_raw) = v.get("timestamp").and_then(|t| t.as_str()) else {
        return vec![];
    };
    let Some(timestamp) = parse_iso_timestamp(timestamp_raw) else {
        return vec![];
    };
    let Some(message) = v.get("message") else {
        return vec![];
    };
    let Some(usage) = message.get("usage") else {
        return vec![];
    };
    let Some((tokens, has_speed)) = token_breakdown(usage) else {
        return vec![];
    };
    if !is_valid_entry(&v, message) {
        return vec![];
    }
    let model = message
        .get("model")
        .and_then(|m| m.as_str())
        .filter(|m| *m != "<synthetic>")
        .map(str::to_string);
    let message_id = message
        .get("id")
        .and_then(|id| id.as_str())
        .map(str::to_string);
    let request_id = v
        .get("requestId")
        .and_then(|id| id.as_str())
        .map(str::to_string);
    let is_sidechain = v
        .get("isSidechain")
        .and_then(|b| b.as_bool())
        .unwrap_or(false);
    let cost_usd = match v.get("costUSD").filter(|c| !c.is_null()) {
        Some(value) => match value.as_f64().filter(|cost| (0.0..=1e12).contains(cost)) {
            Some(cost) => Some(cost),
            None => return vec![],
        },
        None => None,
    };

    let parent = ClaudeEntry {
        timestamp,
        tokens,
        message_id: message_id.clone(),
        request_id: request_id.clone(),
        is_sidechain,
        has_speed,
        cost_usd,
        model,
    };

    let Some(iterations) = usage.get("iterations").and_then(|i| i.as_array()) else {
        return vec![parent];
    };

    let mut entries = vec![parent];
    let mut advisor_index = 0usize;
    for iteration in iterations {
        if iteration.get("type").and_then(|t| t.as_str()) != Some("advisor_message") {
            continue;
        }
        let advisor_model = iteration
            .get("model")
            .and_then(|m| m.as_str())
            .map(str::trim)
            .filter(|m| !m.is_empty())
            .map(str::to_string);
        let Some((advisor_tokens, advisor_has_speed)) = token_breakdown(iteration) else {
            continue;
        };
        entries.push(ClaudeEntry {
            timestamp,
            tokens: advisor_tokens,
            message_id: message_id
                .as_ref()
                .map(|id| format!("{id}:advisor:{advisor_index}")),
            request_id: request_id.clone(),
            is_sidechain,
            has_speed: advisor_has_speed,
            cost_usd: None,
            model: advisor_model,
        });
        advisor_index += 1;
    }
    entries
}

fn token_breakdown(usage: &Value) -> Option<(TokenBreakdown, bool)> {
    let input = nonnegative_token_count(usage.get("input_tokens")?)?;
    let output = nonnegative_token_count(usage.get("output_tokens")?)?;
    let speed = match usage.get("speed").filter(|s| !s.is_null()) {
        Some(value) => Some(value.as_str().filter(|s| matches!(*s, "fast" | "standard"))?),
        None => None,
    };
    let (cache_write5m, cache_write1h) = if let Some(cache_creation) = usage.get("cache_creation").filter(|c| !c.is_null()) {
        let cache_creation = cache_creation.as_object()?;
        (
            optional_token_count(cache_creation.get("ephemeral_5m_input_tokens"))?,
            optional_token_count(cache_creation.get("ephemeral_1h_input_tokens"))?,
        )
    } else {
        (
            optional_token_count(usage.get("cache_creation_input_tokens"))?,
            0,
        )
    };
    Some((
        TokenBreakdown {
            input,
            cache_write5m,
            cache_write1h,
            cache_read: optional_token_count(usage.get("cache_read_input_tokens"))?,
            output,
            is_fast: speed == Some("fast"),
        },
        speed.is_some(),
    ))
}

fn nonnegative_token_count(value: &Value) -> Option<i32> {
    let count = value.as_f64()?;
    if !(0.0..=1e15).contains(&count) || count.fract() != 0.0 {
        return None;
    }
    Some(count as i32)
}

fn optional_token_count(value: Option<&Value>) -> Option<i32> {
    match value.filter(|v| !v.is_null()) {
        Some(value) => nonnegative_token_count(value),
        None => Some(0),
    }
}

fn is_valid_entry(object: &Value, message: &Value) -> bool {
    if let Some(version) = object.get("version") {
        if !version.as_str().is_some_and(is_semver_prefix) {
            return false;
        }
    }
    for value in [object.get("sessionId"), object.get("requestId"), message.get("id")].into_iter().flatten() {
        if !value.as_str().is_some_and(|text| !text.is_empty()) {
            return false;
        }
    }
    !object.get("isSidechain").is_some_and(|v| !v.is_boolean())
        && !message.get("model").is_some_and(|v| !v.as_str().is_some_and(|s| !s.trim().is_empty()))
}

fn is_semver_prefix(value: &str) -> bool {
    let parts: Vec<&str> = value.split('.').collect();
    parts.len() >= 3
        && parts[0].chars().all(|c| c.is_ascii_digit())
        && parts[1].chars().all(|c| c.is_ascii_digit())
        && parts[2]
            .chars()
            .next()
            .is_some_and(|c| c.is_ascii_digit())
}

pub fn parse_iso_timestamp(raw: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(raw).ok().map(|dt| dt.with_timezone(&Utc))
}

#[derive(Hash, PartialEq, Eq)]
struct ExactKey {
    message_id: String,
    request_id: Option<String>,
}

fn dedup(entries: Vec<ClaudeEntry>) -> Vec<ClaudeEntry> {
    let mut deduped = Vec::new();
    let mut exact_index: HashMap<ExactKey, usize> = HashMap::new();
    let mut message_index: HashMap<String, Vec<usize>> = HashMap::new();

    for entry in entries {
        let Some(message_id) = entry.message_id.clone() else {
            deduped.push(entry);
            continue;
        };
        let key = ExactKey {
            message_id: message_id.clone(),
            request_id: entry.request_id.clone(),
        };
        let collision = exact_index.get(&key).copied().or_else(|| {
            message_index.get(&message_id).and_then(|indices| {
                indices.iter().copied().find(|&idx| {
                    entry.is_sidechain || deduped[idx].is_sidechain
                })
            })
        });

        if let Some(index) = collision {
            if should_replace(&entry, &deduped[index]) {
                let old = &deduped[index];
                if let Some(old_id) = &old.message_id {
                    exact_index.remove(&ExactKey {
                        message_id: old_id.clone(),
                        request_id: old.request_id.clone(),
                    });
                }
                deduped[index] = entry;
                exact_index.insert(key, index);
            }
            continue;
        }

        let index = deduped.len();
        deduped.push(entry);
        exact_index.insert(key, index);
        message_index.entry(message_id).or_default().push(index);
    }
    deduped
}

fn should_replace(candidate: &ClaudeEntry, existing: &ClaudeEntry) -> bool {
    if candidate.is_sidechain != existing.is_sidechain {
        return existing.is_sidechain;
    }
    let ct = total_tokens(&candidate.tokens);
    let et = total_tokens(&existing.tokens);
    if ct != et {
        return ct > et;
    }
    candidate.has_speed && !existing.has_speed
}

fn total_tokens(tokens: &TokenBreakdown) -> i32 {
    [tokens.input, tokens.cache_write5m, tokens.cache_write1h, tokens.cache_read, tokens.output]
        .into_iter()
        .fold(0, i32::saturating_add)
}

fn aggregate(entries: &[ClaudeEntry], since: DateTime<Utc>, pricing: &ModelPricing) -> Vec<DailyUsageRow> {
    let mut by_day: BTreeMap<String, DailyUsageRow> = BTreeMap::new();

    for entry in entries {
        if entry.timestamp < since {
            continue;
        }
        let day = local_day_key_from_offset(&entry.timestamp);
        let model = entry
            .model
            .as_deref()
            .map(str::trim)
            .filter(|m| !m.is_empty());
        let cost = entry.cost_usd.or_else(|| {
            model.and_then(|m| pricing.estimated_cost_dollars(m, &entry.tokens))
        });

        let row = by_day.entry(day).or_insert_with_key(|date| DailyUsageRow {
            date: date.clone(),
            input_tokens: 0,
            output_tokens: 0,
            cache_creation_tokens: 0,
            cache_read_tokens: 0,
            total_tokens: 0,
            total_cost: None,
            cost_usd: None,
            models: BTreeMap::new(),
        });
        let tokens = &entry.tokens;
        let total = total_tokens(tokens);
        row.input_tokens = row.input_tokens.saturating_add(tokens.input);
        row.output_tokens = row.output_tokens.saturating_add(tokens.output);
        row.cache_creation_tokens = row.cache_creation_tokens
            .saturating_add(tokens.cache_write5m)
            .saturating_add(tokens.cache_write1h);
        row.cache_read_tokens = row.cache_read_tokens.saturating_add(tokens.cache_read);
        row.total_tokens = row.total_tokens.saturating_add(total);

        let model = row.models.entry(model.unwrap_or("Unattributed").to_string()).or_insert(ModelDayUsage {
            input_tokens: 0,
            output_tokens: 0,
            cache_creation_tokens: 0,
            cache_read_tokens: 0,
            total_tokens: 0,
            total_cost: None,
        });
        model.total_tokens = model.total_tokens.saturating_add(total);
        model.output_tokens = model.total_tokens;
        if let Some(cost) = cost {
            let daily_cost = row.total_cost.unwrap_or_default() + cost;
            row.total_cost = Some(daily_cost);
            row.cost_usd = Some(daily_cost);
            model.total_cost = Some(model.total_cost.unwrap_or_default() + cost);
        }
    }

    by_day.into_values().rev().collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::TempDir;

    #[test]
    fn parses_usage_line_and_aggregates() {
        let tmp = TempDir::new().unwrap();
        let projects = tmp.path().join("projects").join("demo");
        fs::create_dir_all(&projects).unwrap();
        let log = projects.join("sess.jsonl");
        let line = format!(
            r#"{{"timestamp":"{}","message":{{"id":"m1","model":"claude-sonnet-4-20250514","usage":{{"input_tokens":100,"output_tokens":50}}}},"requestId":"r1","version":"1.0.0"}}"#,
            Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
        );
        let mut f = fs::File::create(&log).unwrap();
        writeln!(f, "{line}").unwrap();

        let rows = scan(1, Some(&tmp.path().to_string_lossy()), default_pricing()).unwrap();
        assert!(!rows.is_empty());
        assert!(rows[0].total_tokens >= 150);
    }

    #[test]
    fn parse_entries_emits_advisor_iterations() {
        let line = br#"{"timestamp":"2026-07-12T10:00:00.000Z","message":{"id":"m1","model":"claude-sonnet-4-20250514","usage":{"input_tokens":100,"output_tokens":50,"iterations":[{"type":"advisor_message","model":"claude-opus-4-20250514","input_tokens":10,"output_tokens":5},{"type":"other","model":"x","input_tokens":1,"output_tokens":1}]}},"requestId":"r1","version":"1.0.0"}"#;
        let entries = parse_entries(line);
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].message_id.as_deref(), Some("m1"));
        assert_eq!(entries[0].tokens.input, 100);
        assert_eq!(entries[1].message_id.as_deref(), Some("m1:advisor:0"));
        assert_eq!(entries[1].model.as_deref(), Some("claude-opus-4-20250514"));
        assert_eq!(entries[1].tokens.input, 10);
        assert_eq!(entries[1].tokens.output, 5);
        assert!(entries[1].cost_usd.is_none());
    }

    #[test]
    fn nested_iteration_null_model_counts_unattributed_tokens_without_cost() {
        let line = br#"{"timestamp":"2026-07-12T10:00:00.000Z","message":{"id":"m1","model":"claude-sonnet-4-20250514","usage":{"input_tokens":100,"output_tokens":50,"iterations":[{"type":"advisor_message","model":null,"input_tokens":10,"output_tokens":5}]}},"requestId":"r1","version":"1.0.0"}"#;
        let entries = parse_entries(line);
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].tokens.input, 100);
        assert_eq!(entries[0].model.as_deref(), Some("claude-sonnet-4-20250514"));
        assert_eq!(entries[1].model, None);
        let rows = aggregate(&entries, entries[0].timestamp, default_pricing());
        assert_eq!(rows[0].total_tokens, 165);
        assert_eq!(rows[0].models["Unattributed"].total_tokens, 15);
        assert_eq!(rows[0].models["Unattributed"].total_cost, None);
    }

    #[test]
    fn top_level_null_model_is_still_rejected() {
        let line = br#"{"timestamp":"2026-07-12T10:00:00.000Z","message":{"id":"m1","model":null,"usage":{"input_tokens":100,"output_tokens":50}},"requestId":"r1","version":"1.0.0"}"#;
        assert!(parse_entries(line).is_empty());
    }

    #[test]
    fn folds_nullable_assistant_rows_without_counting_tool_results_or_invalid_counts() {
        let tmp = TempDir::new().unwrap();
        let log = tmp.path().join("session.jsonl");
        let usage = r#"{"type":"assistant","timestamp":"2026-02-20T12:00:00Z","costUSD":null,"message":{"usage" : {"input_tokens":10,"output_tokens":2,"cache_creation":null,"cache_creation_input_tokens":3,"cache_read_input_tokens":null,"speed":null}}}"#;
        let tool_result = r#"{"type":"user","timestamp":"2026-02-20T12:00:00Z","message":{"usage":{"input_tokens":999,"output_tokens":999}}}"#;
        let invalid = r#"{"type":"assistant","timestamp":"2026-02-20T12:00:00Z","message":{"usage":{"input_tokens":-1,"output_tokens":2}}}"#;
        fs::write(&log, [usage, tool_result, invalid].join("\n")).unwrap();

        let entries = parse_file(&log);
        assert_eq!(entries.len(), 1);
        let rows = aggregate(&entries, entries[0].timestamp, default_pricing());
        assert_eq!(rows[0].total_tokens, 15);
        assert_eq!(rows[0].cache_creation_tokens, 3);
        assert_eq!(rows[0].total_cost, None);
    }
}
