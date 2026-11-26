//! Pi coding-agent session log scanner (ports upstream PiUsageScanner).
//! Folds pi assistant usage into Claude/Codex cards via provider mapping.

use crate::claude_usage_scanner::parse_iso_timestamp;
use crate::log_usage_types::{
    DailyUsageRow, ModelDayUsage, TokenBreakdown, cap_log_files_by_mtime, expand_tilde,
    local_day_key_from_offset, since_local_midnight, warn_unreadable_usage_file, UsageFileCache,
    USAGE_FILE_CACHE_MAX_FILES,
};
use crate::model_pricing::{ModelPricing, default_pricing};
use chrono::{DateTime, NaiveDate, Utc};
use serde_json::Value;
use std::collections::{BTreeMap, HashSet};
use std::fs::{self, File};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::SystemTime;


static FILE_CACHE: Mutex<Option<UsageFileCache<Entry>>> = Mutex::new(None);

#[derive(Clone)]
struct Entry {
    id: Option<String>,
    timestamp: DateTime<Utc>,
    card_id: String,
    model: String,
    carried_cost: Option<f64>,
    tokens: TokenBreakdown,
    reported_total_tokens: i32,
}

struct DiscoveredFile {
    path: PathBuf,
    size: u64,
    mtime: SystemTime,
}

/// pi `provider` → OpenUsage card id.
fn card_id_for_pi_provider(provider: &str) -> Option<&'static str> {
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

fn sessions_directory() -> PathBuf {
    if let Ok(v) = std::env::var("PI_CODING_AGENT_SESSION_DIR") {
        let t = v.trim();
        if !t.is_empty() {
            return expand_tilde(t);
        }
    }
    if let Ok(v) = std::env::var("PI_CODING_AGENT_DIR") {
        let t = v.trim();
        if !t.is_empty() {
            return expand_tilde(t).join("sessions");
        }
    }
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".pi/agent/sessions")
}

/// Daily rows for one card (`claude` / `codex`) from pi session logs since `since_compact`.
pub fn query_daily_for_card(card_id: &str, since_compact: &str) -> Vec<DailyUsageRow> {
    let since = parse_since(since_compact);
    scan(card_id, days_back_from_since(since), default_pricing()).unwrap_or_default()
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

fn scan(card_id: &str, days_back: i32, pricing: &ModelPricing) -> Option<Vec<DailyUsageRow>> {
    let files = jsonl_files(&sessions_directory());
    if files.is_empty() {
        return None;
    }
    let since = since_local_midnight(days_back);
    let mut entries = Vec::new();
    if let Ok(mut guard) = FILE_CACHE.lock() {
        let cache = guard.get_or_insert_with(UsageFileCache::default);
        let mut scanned_paths = HashSet::new();
        for file in &files {
            if file_mtime_before(&file.mtime, since) {
                continue;
            }
            scanned_paths.insert(file.path.to_string_lossy().to_string());
            let file_entries = cache.get_or_parse(&file.path, file.size, file.mtime, || {
                parse_file(&file.path)
            });
            entries.extend(
                file_entries
                    .iter()
                    .filter(|entry| entry.timestamp >= since && entry.card_id == card_id)
                    .cloned(),
            );
        }
        cache.finish_scan(
            &scanned_paths,
            |mtime| !file_mtime_before(mtime, since),
            USAGE_FILE_CACHE_MAX_FILES,
        );
    }
    Some(aggregate(&dedup(entries), card_id, since, pricing))
}

fn jsonl_files(dir: &Path) -> Vec<DiscoveredFile> {
    let mut files = Vec::new();
    walk_jsonl(dir, &mut files);
    cap_log_files_by_mtime(&mut files, |f| f.mtime, |f| f.size);
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

fn parse_file(path: &Path) -> Vec<Entry> {
    let mut reader = match File::open(path) {
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
            if let Some(entry) = parse_line(&line) {
                entries.push(entry);
            }
        }
        line.clear();
    }
    entries
}

fn parse_line(line: &[u8]) -> Option<Entry> {
    let v: Value = serde_json::from_slice(line).ok()?;
    if v.get("type").and_then(|t| t.as_str()) != Some("message") {
        return None;
    }
    let timestamp = parse_iso_timestamp(v.get("timestamp")?.as_str()?)?;
    let message = v.get("message")?;
    if message.get("role").and_then(|r| r.as_str()) != Some("assistant") {
        return None;
    }
    let card_id = card_id_for_pi_provider(message.get("provider")?.as_str()?)?.to_string();
    let usage = message.get("usage")?;
    let input = token_count(usage.get("input"), true)?;
    let output = token_count(usage.get("output"), true)?;
    let cache_read = token_count(usage.get("cacheRead"), false)?;
    let cache_write = token_count(usage.get("cacheWrite"), false)?;
    let cache_write_1h = token_count(usage.get("cacheWrite1h"), false)?;
    let reported_total_tokens = token_count(usage.get("totalTokens"), true)?;
    if cache_write_1h > cache_write
        || i64::from(input) + i64::from(output) + i64::from(cache_read) + i64::from(cache_write)
            != i64::from(reported_total_tokens)
    {
        return None;
    }
    let id = match v.get("id") {
        None => None,
        Some(value) => {
            let id = value.as_str()?;
            if id.trim().is_empty() {
                return None;
            }
            Some(id.to_string())
        }
    };
    let model = match message.get("model") {
        None => "",
        Some(value) => value.as_str()?.trim(),
    };
    let carried_cost = match usage.get("cost").filter(|cost| !cost.is_null()) {
        None => None,
        Some(cost) => match cost.as_object()?.get("total").filter(|total| !total.is_null()) {
            None => None,
            Some(total) => Some(total.as_f64().filter(|n| (0.0..=1e12).contains(n))?),
        },
    };
    Some(Entry {
        id,
        timestamp,
        card_id,
        model: model.to_string(),
        carried_cost,
        tokens: TokenBreakdown {
            input,
            cache_write5m: cache_write - cache_write_1h,
            cache_write1h: cache_write_1h,
            cache_read,
            output,
            is_fast: false,
        },
        reported_total_tokens,
    })
}

fn token_count(value: Option<&Value>, required: bool) -> Option<i32> {
    let Some(value) = value else { return (!required).then_some(0) };
    let count = value.as_f64()?;
    (count.fract() == 0.0 && (0.0..=f64::from(i32::MAX)).contains(&count))
        .then_some(count as i32)
}

fn dedup(mut entries: Vec<Entry>) -> Vec<Entry> {
    let mut seen = HashSet::new();
    entries.retain(|entry| entry.id.as_ref().is_none_or(|id| seen.insert(id.clone())));
    entries
}

fn aggregate(
    entries: &[Entry],
    card_id: &str,
    since: DateTime<Utc>,
    pricing: &ModelPricing,
) -> Vec<DailyUsageRow> {
    let mut tokens_by_day: BTreeMap<String, i32> = BTreeMap::new();
    let mut cost_by_day: BTreeMap<String, f64> = BTreeMap::new();
    let mut models_by_day: BTreeMap<String, BTreeMap<String, (i32, Option<f64>)>> = BTreeMap::new();
    let mut input_by_day: BTreeMap<String, i32> = BTreeMap::new();
    let mut output_by_day: BTreeMap<String, i32> = BTreeMap::new();
    let mut cache_create_by_day: BTreeMap<String, i32> = BTreeMap::new();
    let mut cache_read_by_day: BTreeMap<String, i32> = BTreeMap::new();

    for entry in entries {
        if entry.card_id != card_id || entry.timestamp < since {
            continue;
        }
        let day = local_day_key_from_offset(&entry.timestamp);
        let trimmed = entry.model.trim();
        let model_name = if trimmed.is_empty() {
            "unattributed"
        } else {
            trimmed
        };
        let cost = if card_id == "codex" && trimmed == crate::codex_usage_scanner::AUTO_REVIEW_MODEL {
            if entry.timestamp.timestamp() >= crate::codex_usage_scanner::AUTO_REVIEW_FREE_SINCE_UNIX {
                Some(0.0)
            } else if let Some(carried) = entry.carried_cost.filter(|c| *c > 0.0) {
                Some(carried)
            } else {
                let fallback = crate::codex_usage_scanner::auto_review_fallback(
                    &crate::codex_usage_scanner::event_day_key(&entry.timestamp),
                );
                let total_input = entry.tokens.input + entry.tokens.cache_read;
                crate::codex_pricing::estimated_cost_dollars_at(
                    pricing,
                    &crate::codex_pricing::CodexCostInput {
                        model: &fallback,
                        input: total_input,
                        cached: entry.tokens.cache_read.min(total_input),
                        output: entry.tokens.output,
                        reasoning: 0,
                        is_fast: entry.tokens.is_fast,
                        is_ultrafast: false,
                    },
                    Some(entry.timestamp),
                )
            }
        } else if let Some(carried) = entry.carried_cost.filter(|c| *c > 0.0) {
            Some(carried)
        } else if !trimmed.is_empty() {
            pricing.estimated_cost_dollars_at(trimmed, &entry.tokens, entry.timestamp)
        } else {
            None
        };

        let total = entry.reported_total_tokens;
        let add_tokens = |tokens: &mut i32, count| *tokens = tokens.saturating_add(count);
        add_tokens(tokens_by_day.entry(day.clone()).or_default(), total);
        if let Some(cost) = cost {
            *cost_by_day.entry(day.clone()).or_default() += cost;
        }
        add_tokens(input_by_day.entry(day.clone()).or_default(), entry.tokens.input);
        add_tokens(output_by_day.entry(day.clone()).or_default(), entry.tokens.output);
        add_tokens(
            cache_create_by_day.entry(day.clone()).or_default(),
            entry.tokens.cache_write5m + entry.tokens.cache_write1h,
        );
        add_tokens(cache_read_by_day.entry(day.clone()).or_default(), entry.tokens.cache_read);
        let e = models_by_day
            .entry(day)
            .or_default()
            .entry(model_name.to_string())
            .or_default();
        add_tokens(&mut e.0, total);
        if let Some(cost) = cost {
            *e.1.get_or_insert(0.0) += cost;
        }
    }

    tokens_by_day
        .keys()
        .rev()
        .cloned()
        .map(|day| {
            let total_cost = cost_by_day.get(&day).copied();
            let models = models_by_day
                .get(&day)
                .map(|m| {
                    m.iter()
                        .map(|(name, (tokens, cost))| {
                            (
                                name.clone(),
                                ModelDayUsage {
                                    input_tokens: 0,
                                    output_tokens: *tokens,
                                    cache_creation_tokens: 0,
                                    cache_read_tokens: 0,
                                    total_tokens: *tokens,
                                    total_cost: *cost,
                                },
                            )
                        })
                        .collect()
                })
                .unwrap_or_default();
            DailyUsageRow {
                date: day.clone(),
                input_tokens: *input_by_day.get(&day).unwrap_or(&0),
                output_tokens: *output_by_day.get(&day).unwrap_or(&0),
                cache_creation_tokens: *cache_create_by_day.get(&day).unwrap_or(&0),
                cache_read_tokens: *cache_read_by_day.get(&day).unwrap_or(&0),
                total_tokens: *tokens_by_day.get(&day).unwrap_or(&0),
                total_cost,
                cost_usd: total_cost,
                models,
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(provider: &str, cache_write: i32, cache_write_1h: i32, cost: Option<f64>) -> Vec<u8> {
        let mut usage = serde_json::json!({
            "input": 100,
            "output": 50,
            "cacheRead": 0,
            "cacheWrite": cache_write,
            "cacheWrite1h": cache_write_1h,
            "totalTokens": 150 + cache_write,
        });
        if let Some(c) = cost {
            usage["cost"] = serde_json::json!({ "total": c });
        }
        serde_json::json!({
            "type": "message",
            "id": "m1",
            "timestamp": "2026-07-12T10:00:00.000Z",
            "message": {
                "role": "assistant",
                "provider": provider,
                "model": "claude-opus-4-8",
                "usage": usage,
            }
        })
        .to_string()
        .into_bytes()
    }

    #[test]
    fn maps_providers() {
        assert_eq!(card_id_for_pi_provider("anthropic"), Some("claude"));
        assert_eq!(card_id_for_pi_provider("claude-agent-sdk"), Some("claude"));
        assert_eq!(card_id_for_pi_provider("openai-codex"), Some("codex"));
        assert_eq!(card_id_for_pi_provider("nvidia-nim"), None);
    }

    #[test]
    fn parses_mapped_anthropic_line() {
        let entry = parse_line(&line("anthropic", 0, 0, Some(0.5))).unwrap();
        assert_eq!(entry.card_id, "claude");
        assert_eq!(entry.model, "claude-opus-4-8");
        assert_eq!(entry.carried_cost, Some(0.5));
        assert_eq!(entry.reported_total_tokens, 150);
        assert_eq!(entry.tokens.input, 100);
        assert_eq!(entry.tokens.output, 50);
    }

    #[test]
    fn splits_cache_write_buckets_by_1h() {
        let entry = parse_line(&line("anthropic", 1000, 400, Some(0.5))).unwrap();
        assert_eq!(entry.tokens.cache_write1h, 400);
        assert_eq!(entry.tokens.cache_write5m, 600);
    }

    #[test]
    fn maps_codex_and_skips_unmapped_and_non_assistant() {
        assert_eq!(
            parse_line(&line("openai-codex", 0, 0, Some(0.5)))
                .unwrap()
                .card_id,
            "codex"
        );
        assert!(parse_line(&line("nvidia-nim", 0, 0, Some(0.5))).is_none());
        let user = br#"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"user","provider":"anthropic","usage":{}}}"#;
        assert!(parse_line(user).is_none());
    }

    #[test]
    fn keeps_unpriced_tokens_and_deduplicates_replayed_ids() {
        let mut entry = parse_line(&line("anthropic", 0, 0, None)).unwrap();
        entry.model = "not-in-the-catalog".into();
        let entries = dedup(vec![entry.clone(), entry]);
        let days = aggregate(&entries, "claude", DateTime::<Utc>::UNIX_EPOCH, default_pricing());
        assert_eq!(days.len(), 1);
        assert_eq!(days[0].total_tokens, 150);
        assert_eq!(days[0].total_cost, None);
    }

    #[test]
    fn rejects_inconsistent_cache_buckets() {
        assert!(parse_line(&line("anthropic", 100, 101, None)).is_none());
    }

    #[test]
    fn saturates_daily_tokens_across_individually_valid_entries() {
        let large = parse_line(br#"{"type":"message","timestamp":"2026-07-12T10:00:00Z","message":{"role":"assistant","provider":"anthropic","usage":{"input":2147483647,"output":0,"totalTokens":2147483647}}}"#).unwrap();
        let small = parse_line(&line("anthropic", 0, 0, None)).unwrap();
        let days = aggregate(&[large, small], "claude", DateTime::<Utc>::UNIX_EPOCH, default_pricing());
        assert_eq!(days[0].total_tokens, i32::MAX);
        assert_eq!(days[0].input_tokens, i32::MAX);
    }
}
