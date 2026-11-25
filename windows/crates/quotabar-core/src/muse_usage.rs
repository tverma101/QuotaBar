use crate::log_usage_types::TokenBreakdown;
use crate::model_pricing::default_pricing;
use serde_json::{Value, json};
use std::collections::HashSet;
use std::fs::{self, File};
use std::io::{self, BufRead, BufReader};
use std::path::Path;

pub fn scan(expired: impl Fn() -> bool) -> io::Result<Vec<Value>> {
    let Some(home) = dirs::home_dir() else { return Ok(vec![]) };
    let root = home.join(".local/share/muse/sessions");
    if !root.exists() {
        return Ok(vec![]);
    }
    let now = chrono::Utc::now().timestamp_millis();
    let cutoff = crate::log_usage_types::since_local_midnight(3653).timestamp_millis();
    let mut rows = Vec::new();
    let mut files = HashSet::new();
    let mut pending = vec![root];
    while let Some(dir) = pending.pop() {
        if expired() {
            return Err(io::Error::new(io::ErrorKind::TimedOut, "Muse history scan timed out"));
        }
        for entry in fs::read_dir(dir)? {
            let entry = entry?;
            let kind = entry.file_type()?;
            if kind.is_dir() && !is_link(&entry, &kind) {
                pending.push(entry.path());
            } else if kind.is_file() && entry.file_name() == "session.jsonl" {
                let path = entry.path();
                if !files.insert(fs::canonicalize(&path)?) {
                    continue;
                }
                fold_file(&path, cutoff, now + 300_000, &expired, &mut rows)?;
            }
        }
    }
    Ok(rows)
}

fn is_link(entry: &fs::DirEntry, file_type: &fs::FileType) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        file_type.is_symlink() || entry.metadata().map(|m| m.file_attributes() & 0x400 != 0).unwrap_or(true)
    }
    #[cfg(not(windows))]
    {
        let _ = entry;
        file_type.is_symlink()
    }
}

fn fold_file(
    path: &Path, cutoff: i64, max: i64, expired: &impl Fn() -> bool, rows: &mut Vec<Value>,
) -> io::Result<()> {
    let mut reader = BufReader::new(File::open(path)?);
    let mut line = Vec::new();
    const MARKER: &[u8] = b"\"goal_usage_attribution\"";
    while reader.read_until(b'\n', &mut line)? != 0 {
        if expired() {
            return Err(io::Error::new(io::ErrorKind::TimedOut, "Muse history scan timed out"));
        }
        if find_marker(&line, MARKER) {
            let value: Value = serde_json::from_slice(&line).map_err(invalid)?;
            if let Some(row) = projection(&value, cutoff, max)? {
                rows.push(row);
            }
        }
        line.clear();
    }
    Ok(())
}

fn find_marker(bytes: &[u8], marker: &[u8]) -> bool {
    bytes.split(|&byte| byte == b'"').any(|token| token == &marker[1..marker.len() - 1])
}

fn invalid(error: impl Into<Box<dyn std::error::Error + Send + Sync>>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, error)
}

fn projection(value: &Value, cutoff: i64, max: i64) -> io::Result<Option<Value>> {
    let event = &value["payload"]["event"];
    if event["kind"] != "goal_usage_attribution" {
        return Ok(None);
    }
    let record = &event["record"];
    let quantity = &record["quantity"];
    let reported = quantity["reported"].as_bool().ok_or_else(|| invalid("invalid Muse reported flag"))?;
    let unit = quantity["unit"].as_str().ok_or_else(|| invalid("invalid Muse usage unit"))?;
    if !reported || unit != "tokens" {
        return Ok(None);
    }
    let count = |name: &str, required: bool| {
        let value = quantity.get(name);
        if value.is_none() && !required {
            return Ok(0);
        }
        value.and_then(Value::as_i64).filter(|n| (0..=1_000_000_000_000_000).contains(n))
            .ok_or_else(|| invalid("invalid Muse token count"))
    };
    let input = count("input_tokens", true)?;
    let cached = count("cached_tokens", false)?;
    let output = count("output_tokens", true)? + count("reasoning_tokens", false)?;
    if cached > input {
        return Err(invalid("Muse cached tokens exceed input"));
    }
    let ts = value["recorded_at"].as_i64().filter(|n| *n > 0 && *n <= 9_000_000_000_000_000)
        .ok_or_else(|| invalid("invalid Muse record timestamp"))? / 1000;
    if input + output == 0 || ts < cutoff {
        return Ok(None);
    }
    if ts > max {
        return Err(invalid("Muse usage timestamp is ahead of the clock"));
    }
    let model = [record, quantity].into_iter().find_map(|source|
        source["model"].as_str().map(str::trim).filter(|name| !name.is_empty()))
        .unwrap_or("muse-spark-1.2-contributor");
    let price = i32::try_from(input - cached).ok().zip(i32::try_from(cached).ok()).zip(i32::try_from(output).ok())
        .and_then(|((input, cache_read), output)| default_pricing().estimated_cost_dollars(model, &TokenBreakdown {
            input, cache_read, output, ..TokenBreakdown::default()
        }));
    Ok(Some(json!({ "createdMs": ts, "tokens": input + output, "cost": price, "go": true })))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn projects_measured_muse_tokens_without_double_counting_cache_hits() {
        let mut record = json!({
            "recorded_at": 1770206400000000_i64,
            "payload": { "event": { "kind": "goal_usage_attribution", "record": {
                "model": "not-in-the-catalog",
                "quantity": { "reported": true, "unit": "tokens", "input_tokens": 120,
                    "cached_tokens": 90, "output_tokens": 10, "reasoning_tokens": 2 }
            } } }
        });
        let row = projection(&record, 0, i64::MAX).unwrap().unwrap();
        assert_eq!(row, json!({ "createdMs": 1770206400000_i64, "tokens": 132, "cost": null, "go": true }));
        record["payload"]["event"]["record"]["quantity"]["reported"] = json!(false);
        assert!(projection(&record, 0, i64::MAX).unwrap().is_none());
    }
}
