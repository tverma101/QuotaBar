use crate::log_usage_types::{TokenBreakdown, expand_tilde};
use crate::model_pricing::default_pricing;
use rusqlite::{Connection, OpenFlags};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

const VALID_COUNTS: &str = "typeof(input_tokens)='integer' AND input_tokens>=0 AND typeof(output_tokens)='integer' AND output_tokens>=0";
const ENTITLEMENT_KEY: &str = "zcode:usage-entitlement:subscription-v2:account:";

pub fn scan() -> Value {
    let path = expand_tilde("~/.zcode/cli/db/db.sqlite");
    let (daily, plan, damaged) = match scan_history(&path) {
        Ok(result) => result,
        Err(error) => {
            log::warn!("ZCode history could not be read: {error}");
            (vec![], None, 0)
        }
    };
    let snapshot = dirs::data_dir()
        .map(|path| path.join("ZCode/session/Local Storage/leveldb"))
        .and_then(|path| read_entitlements(&path))
        .map(|snapshot| public_entitlement(&snapshot));
    json!({ "daily": daily, "plan": plan, "damagedRows": damaged, "entitlement": snapshot })
}

fn scan_history(path: &Path) -> rusqlite::Result<(Vec<Value>, Option<String>, i64)> {
    if !path.exists() {
        return Ok((vec![], None, 0));
    }
    let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    let columns: Vec<String> = conn.prepare("PRAGMA table_info(model_usage)")?
        .query_map([], |row| row.get(1))?.collect::<rusqlite::Result<_>>()?;
    let has = |name: &str| columns.iter().any(|col| col == name);
    let damaged = conn.query_row(
        &format!("SELECT count(*) FROM model_usage WHERE NOT ({VALID_COUNTS})"),
        [], |row| row.get(0),
    )?;
    let plan = if has("provider_id") {
        conn.query_row(
            "SELECT provider_id FROM model_usage WHERE provider_id LIKE 'account:zai%' ORDER BY started_at DESC LIMIT 1",
            [], |row| row.get::<_, String>(0),
        ).ok().and_then(|id| {
            if id.contains("start-plan") { Some("Start Plan".into()) }
            else if id.contains("coding-plan") { Some("Coding Plan".into()) }
            else { None }
        })
    } else { None };
    let model = if has("model_id") { "model_id" } else { "NULL" };
    let cache_sum = |column: &str| if has(column) { format!("SUM(MAX(0,COALESCE({column},0)))") } else { "0".into() };
    let sql = format!(
        "SELECT date(started_at / 1000, 'unixepoch', 'localtime') AS day, {model},
                SUM(input_tokens), SUM(output_tokens), {}, {}
         FROM model_usage WHERE {VALID_COUNTS} AND day IS NOT NULL
         GROUP BY day, {model} ORDER BY day",
        cache_sum("cache_read_input_tokens"), cache_sum("cache_creation_input_tokens")
    );
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map([], |row| Ok((
        row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?,
        row.get::<_, i64>(2)?, row.get::<_, i64>(3)?, row.get::<_, i64>(4)?, row.get::<_, i64>(5)?,
    )))?;
    let mut days: BTreeMap<String, (i64, Option<f64>, bool)> = BTreeMap::new();
    for row in rows {
        let (day, model, input, output, read, write) = row?;
        if input == 0 && output == 0 { continue; }
        let cost = model.and_then(|name| {
            default_pricing().estimated_cost_dollars(&name, &TokenBreakdown {
                input: i32::try_from(input.saturating_sub(read).saturating_sub(write).max(0)).ok()?,
                output: i32::try_from(output).ok()?,
                cache_read: i32::try_from(read).ok()?,
                cache_write5m: i32::try_from(write).ok()?,
                ..TokenBreakdown::default()
            })
        });
        let entry = days.entry(day).or_default();
        entry.0 = entry.0.saturating_add(input.saturating_add(output));
        if let Some(cost) = cost { *entry.1.get_or_insert(0.0) += cost; }
        else { entry.2 = true; }
    }
    Ok((days.into_iter().map(|(date, (tokens, cost, unpriced))| {
        json!({ "date": date, "totalTokens": tokens, "totalCost": if unpriced { None } else { cost } })
    }).collect(), plan, damaged))
}

fn latest_snapshot(bytes: &[u8]) -> Option<Value> {
    let mut best: Option<Value> = None;
    let key = ENTITLEMENT_KEY.as_bytes();
    let marker = b"{\"cachedAt\"";
    let mut start = 0;
    while let Some(offset) = bytes[start..].windows(key.len()).position(|bytes| bytes == key) {
        start += offset + key.len();
        let end = (start + 512).min(bytes.len());
        if let Some(offset) = bytes[start..end].windows(marker.len()).position(|bytes| bytes == marker) {
            let from = start + offset;
            let mut candidates = serde_json::Deserializer::from_slice(&bytes[from..(from + 25_000).min(bytes.len())])
                .into_iter::<Value>();
            if let Some(Ok(candidate)) = candidates.next() {
                if candidate["snapshot"].is_object() && cached_at(&candidate) > best.as_ref().and_then(cached_at) {
                    best = Some(candidate);
                }
            }
        }
    }
    best
}

fn cached_at(value: &Value) -> Option<i64> {
    value["cachedAt"].as_i64().filter(|n| *n >= 0)
}

fn public_entitlement(snapshot: &Value) -> Value {
    let pick = |value: &Value, fields: &[&str]| -> Value {
        Value::Object(fields.iter().filter_map(|field| {
            value.get(field).filter(|value| value.is_string() || value.is_number())
                .map(|value| ((*field).to_string(), value.clone()))
        }).collect())
    };
    let rows = |value: &Value| value.as_array().cloned().unwrap_or_default();
    let quota = &snapshot["quota"];
    let limits: Vec<_> = rows(&quota["limits"]).iter().map(|limit|
        pick(limit, &["planId", "period", "unit", "usage", "remaining", "nextResetTime"])).collect();
    let details: Vec<_> = rows(&snapshot["subscription"]["details"]).iter().map(|detail| {
        let mut output = pick(detail, &["productId", "productName", "billingCycle", "expireTime", "beginTime"]);
        output["entitlements"] = Value::Array(rows(&detail["entitlements"]).iter()
            .map(|entry| pick(entry, &["effectiveTime"])).collect());
        output
    }).collect();
    json!({ "quota": { "level": quota["level"].as_str(), "limits": limits }, "subscription": { "details": details } })
}

fn read_entitlements(path: &Path) -> Option<Value> {
    fs::read_dir(path).ok()?.filter_map(Result::ok)
        .filter(|entry| matches!(entry.path().extension().and_then(|ext| ext.to_str()), Some("ldb" | "log")))
        .filter_map(|entry| fs::read(entry.path()).ok().and_then(|bytes| latest_snapshot(&bytes)))
        .max_by_key(cached_at).and_then(|value| value.get("snapshot").cloned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scans_minimal_history_without_counting_invalid_rows() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("db.sqlite");
        let db = Connection::open(&path).unwrap();
        db.execute_batch("CREATE TABLE model_usage(started_at, input_tokens, output_tokens, provider_id);
            INSERT INTO model_usage VALUES
                (1770206400000, 12, 4, 'account:zai:coding-plan'),
                (1770206400000, 'invalid', 5, NULL);").unwrap();
        let (rows, plan, damaged) = scan_history(&path).unwrap();
        assert_eq!(damaged, 1);
        assert_eq!(plan.as_deref(), Some("Coding Plan"));
        assert_eq!(rows[0]["totalTokens"], 16);
        assert!(rows[0]["totalCost"].is_null());
    }

    #[test]
    fn selects_latest_entitlement_across_compacted_records() {
        let dir = tempfile::tempdir().unwrap();
        for (name, revision) in [("001.log", 11), ("002.ldb", 7)] {
            fs::write(dir.path().join(name), format!(
                "binary\0{ENTITLEMENT_KEY}example\0{{\"cachedAt\":{revision},\"snapshot\":{{\"revision\":{revision}}}}}tail"
            )).unwrap();
        }
        assert_eq!(read_entitlements(dir.path()).unwrap()["revision"], 11);
    }
}
