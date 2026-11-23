//! Estimate daily Cursor activity from local agent transcript JSONL files (~/.cursor/projects).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use chrono::{DateTime, NaiveDate, Utc};
use serde::Serialize;

const CHARS_PER_TOKEN: u64 = 4;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CursorDailyUsage {
    pub date: String,
    pub total_tokens: u64,
    #[serde(rename = "estimated")]
    pub is_estimated: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CursorLogsStatus {
    Ok,
    NoData,
}

pub fn cursor_agent_home() -> PathBuf {
    if let Ok(v) = std::env::var("CURSOR_AGENT_HOME") {
        return expand_tilde(&v);
    }
    dirs::home_dir()
        .map(|h| h.join(".cursor"))
        .unwrap_or_else(|| PathBuf::from(".cursor"))
}

fn expand_tilde(path: &str) -> PathBuf {
    let trimmed = path.trim();
    if trimmed == "~" {
        return dirs::home_dir().unwrap_or_else(|| PathBuf::from("."));
    }
    if let Some(rest) = trimmed.strip_prefix("~/") {
        if let Some(home) = dirs::home_dir() {
            return home.join(rest);
        }
    }
    PathBuf::from(trimmed)
}

fn parse_since_day(since: &str) -> Option<NaiveDate> {
    let digits: String = since.chars().filter(|c| c.is_ascii_digit()).collect();
    if digits.len() >= 8 {
        let y: i32 = digits[0..4].parse().ok()?;
        let m: u32 = digits[4..6].parse().ok()?;
        let d: u32 = digits[6..8].parse().ok()?;
        return NaiveDate::from_ymd_opt(y, m, d);
    }
    NaiveDate::parse_from_str(since, "%Y-%m-%d").ok()
}

fn day_key_from_mtime(path: &Path) -> Option<String> {
    let meta = std::fs::metadata(path).ok()?;
    let modified = meta.modified().ok()?;
    let dt: DateTime<Utc> = modified.into();
    Some(dt.format("%Y-%m-%d").to_string())
}

fn date_from_day_key(key: &str) -> Option<NaiveDate> {
    if key.len() < 10 {
        return None;
    }
    let y: i32 = key.get(0..4)?.parse().ok()?;
    let m: u32 = key.get(5..7)?.parse().ok()?;
    let d: u32 = key.get(8..10)?.parse().ok()?;
    NaiveDate::from_ymd_opt(y, m, d)
}

#[cfg(test)]
fn yyyymmdd(date: NaiveDate) -> String {
    date.format("%Y%m%d").to_string()
}

fn estimate_tokens_in_jsonl(path: &Path) -> u64 {
    let Ok(content) = std::fs::read_to_string(path) else {
        return 0;
    };
    let mut chars = 0u64;
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let Ok(v) = serde_json::from_str::<serde_json::Value>(trimmed) else {
            continue;
        };
        chars += extract_message_chars(&v);
    }
    chars / CHARS_PER_TOKEN
}

fn extract_message_chars(v: &serde_json::Value) -> u64 {
    let mut chars = 0u64;
    if let Some(content) = v.pointer("/message/content").and_then(|c| c.as_array()) {
        for item in content {
            if let Some(text) = item.get("text").and_then(|t| t.as_str()) {
                chars += text.chars().count() as u64;
            }
        }
    }
    chars
}

fn collect_transcript_jsonl(projects_dir: &Path, out: &mut Vec<PathBuf>) {
    if !projects_dir.is_dir() {
        return;
    }
    let Ok(entries) = std::fs::read_dir(projects_dir) else {
        return;
    };
    for entry in entries.flatten() {
        let transcripts = entry.path().join("agent-transcripts");
        if transcripts.is_dir() {
            walk_transcripts_dir(&transcripts, out);
        }
    }
}

fn walk_transcripts_dir(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            walk_transcripts_dir(&path, out);
        } else if path.extension().is_some_and(|e| e == "jsonl") {
            out.push(path);
        }
    }
}

/// Aggregate estimated tokens per calendar day from transcript files modified on/after `since` (YYYYMMDD or YYYY-MM-DD).
pub fn query_daily_since(since: &str) -> (CursorLogsStatus, Vec<CursorDailyUsage>) {
    let since_date = parse_since_day(since)
        .unwrap_or_else(|| Utc::now().date_naive() - chrono::Duration::days(30));

    let projects = cursor_agent_home().join("projects");
    let mut files = Vec::new();
    collect_transcript_jsonl(&projects, &mut files);

    let mut by_day: BTreeMap<String, u64> = BTreeMap::new();
    for path in files {
        let Some(day_key) = day_key_from_mtime(&path) else {
            continue;
        };
        let Some(file_day) = date_from_day_key(&day_key) else {
            continue;
        };
        if file_day < since_date {
            continue;
        }
        let tokens = estimate_tokens_in_jsonl(&path);
        if tokens == 0 {
            continue;
        }
        *by_day.entry(day_key).or_insert(0) += tokens;
    }

    if by_day.is_empty() {
        return (CursorLogsStatus::NoData, vec![]);
    }

    let daily = by_day
        .into_iter()
        .map(|(date, total_tokens)| CursorDailyUsage {
            date,
            total_tokens,
            is_estimated: true,
        })
        .collect();

    (CursorLogsStatus::Ok, daily)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn estimates_tokens_from_transcript_jsonl() {
        let dir = tempfile::tempdir().expect("tempdir");
        let projects = dir.path().join("projects").join("demo").join("agent-transcripts");
        std::fs::create_dir_all(&projects).expect("mkdir");
        let jsonl = projects.join("sess.jsonl");
        let mut f = std::fs::File::create(&jsonl).expect("create");
        writeln!(
            f,
            r#"{{"role":"user","message":{{"content":[{{"type":"text","text":"{:040}"}}]}}}}"#,
            "a".repeat(40)
        )
        .expect("write");
        drop(f);

        let prev = std::env::var("CURSOR_AGENT_HOME").ok();
        // SAFETY: test-only env override; single-threaded test.
        unsafe {
            std::env::set_var("CURSOR_AGENT_HOME", dir.path());
        }

        let since = yyyymmdd(Utc::now().date_naive() - chrono::Duration::days(1));
        let (status, daily) = query_daily_since(&since);
        assert_eq!(status, CursorLogsStatus::Ok);
        assert_eq!(daily.len(), 1);
        assert_eq!(daily[0].total_tokens, 10);

        // SAFETY: test-only env restore; single-threaded test.
        unsafe {
            if let Some(p) = prev {
                std::env::set_var("CURSOR_AGENT_HOME", p);
            } else {
                std::env::remove_var("CURSOR_AGENT_HOME");
            }
        }
    }
}
