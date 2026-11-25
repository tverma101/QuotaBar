//! Claude local-usage fold.
//!
//! Port of `ClaudeLogUsageScanner.dedup` + `aggregate` + `DailyUsageAccumulator.build`. The Swift
//! methods stay in place as the parity oracle and as the runtime fallback when the backend reports
//! an internal failure.
//!
//! Entries arrive from Swift in a fixed-stride binary payload (the scanner already holds them as
//! decoded `Entry` values, so this avoids re-parsing JSONL and avoids a JSON re-encode of the whole
//! history). Pricing arrives either as a Rust snapshot handle (model names are resolved here) or,
//! on the fallback path, as the pre-resolved `ModelRates` table Swift still builds.

use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};

use super::accounting::{
    DailyUsageAccumulator, DayBoundaries, TokenBreakdown, UNATTRIBUTED_MODEL_NAME,
};
use super::pricing::FoldPricing;
use super::{invalid_param, BackendError};

/// Fixed byte stride of one Claude entry in the payload.
pub const CLAUDE_ENTRY_STRIDE: usize = 72;

/// Mirrors `OpenCodeUsageScanner.claudeGatewayPrefixes`.
const CLAUDE_GATEWAY_PREFIXES: [&str; 2] = ["anthropic/opencode_go/", "anthropic/opencode/"];

#[derive(Debug, Clone)]
struct ClaudeEntry {
    timestamp: f64,
    tokens: TokenBreakdown,
    cost_usd: Option<f64>,
    message_id: Option<u32>,
    request_id: Option<u32>,
    model: Option<u32>,
    is_sidechain: bool,
    has_speed: bool,
}

pub fn fold(params: &Value, payload: &[u8]) -> Result<Value, BackendError> {
    let since = required_number(params, "since")?;
    let boundaries = DayBoundaries::from_value(
        params
            .get("dayBoundaries")
            .ok_or_else(|| invalid_param("missing `dayBoundaries`".to_string()))?,
    )
    .map_err(invalid_param)?;
    let models = string_pool(params, "models")?;
    let message_ids = string_pool(params, "messageIds")?;
    let request_ids = string_pool(params, "requestIds")?;
    let mut pricing = FoldPricing::from_params(params)?;

    let entries = decode_entries(payload, &models, &message_ids, &request_ids)?;
    // The Swift wrapper resolved every distinct slug in the payload, including entries the window
    // later drops, so discovery saw the same set. Resolve them up front in backend mode too; the
    // memo makes the in-fold lookups free.
    if pricing.has_backend() {
        let mut seen: HashSet<&str> = HashSet::new();
        for entry in &entries {
            if let Some(index) = entry.model {
                let trimmed = models[index as usize].trim();
                if !trimmed.is_empty() && seen.insert(trimmed) {
                    let _ = pricing.resolve(trimmed);
                }
            }
        }
    }
    let deduped = dedup(entries);

    let mut accumulator = DailyUsageAccumulator::default();
    for entry in &deduped {
        if entry.timestamp < since {
            continue;
        }
        let day = boundaries.key_for(entry.timestamp);
        let trimmed_model = entry
            .model
            .map(|index| models[index as usize].trim())
            .filter(|model| !model.is_empty());
        let model_name = trimmed_model.unwrap_or(UNATTRIBUTED_MODEL_NAME);
        if trimmed_model.is_some_and(is_hosted_gateway_model) {
            continue;
        }

        let estimated = trimmed_model
            .and_then(|model| pricing.resolve(model))
            .map(|rates| rates.cost_dollars(&entry.tokens));
        let cost = entry.cost_usd.or(estimated);
        if cost.is_none() && entry.tokens.total_tokens() > 0 {
            accumulator.add_unknown_model(day, model_name);
        }
        accumulator.record_api_estimate(day, estimated, entry.tokens.total_tokens());
        accumulator.add(
            day,
            entry.tokens.total_tokens(),
            cost,
            model_name,
            None,
            true,
            false,
        );
    }

    Ok(json!({
        "scan": accumulator.build(),
        "recheckModels": pricing.take_recheck(),
    }))
}

fn required_number(params: &Value, key: &str) -> Result<f64, BackendError> {
    params
        .get(key)
        .and_then(Value::as_f64)
        .filter(|value| value.is_finite())
        .ok_or_else(|| invalid_param(format!("missing finite number parameter `{key}`")))
}

fn string_pool(params: &Value, key: &str) -> Result<Vec<String>, BackendError> {
    params
        .get(key)
        .and_then(Value::as_array)
        .ok_or_else(|| invalid_param(format!("missing `{key}` string array")))?
        .iter()
        .map(|value| {
            value
                .as_str()
                .map(str::to_string)
                .ok_or_else(|| invalid_param(format!("`{key}` must contain only strings")))
        })
        .collect()
}

fn decode_entries(
    payload: &[u8],
    models: &[String],
    message_ids: &[String],
    request_ids: &[String],
) -> Result<Vec<ClaudeEntry>, BackendError> {
    if payload.len() % CLAUDE_ENTRY_STRIDE != 0 {
        return Err(invalid_param(format!(
            "payload length {} is not a multiple of {CLAUDE_ENTRY_STRIDE}",
            payload.len()
        )));
    }
    let mut entries = Vec::with_capacity(payload.len() / CLAUDE_ENTRY_STRIDE);
    for chunk in payload.chunks_exact(CLAUDE_ENTRY_STRIDE) {
        let timestamp = f64::from_le_bytes(chunk[0..8].try_into().expect("8 bytes"));
        let input = u64::from_le_bytes(chunk[8..16].try_into().expect("8 bytes"));
        let cache_write_5m = u64::from_le_bytes(chunk[16..24].try_into().expect("8 bytes"));
        let cache_write_1h = u64::from_le_bytes(chunk[24..32].try_into().expect("8 bytes"));
        let cache_read = u64::from_le_bytes(chunk[32..40].try_into().expect("8 bytes"));
        let output = u64::from_le_bytes(chunk[40..48].try_into().expect("8 bytes"));
        let cost_usd = f64::from_le_bytes(chunk[48..56].try_into().expect("8 bytes"));
        let message_id = i32::from_le_bytes(chunk[56..60].try_into().expect("4 bytes"));
        let request_id = i32::from_le_bytes(chunk[60..64].try_into().expect("4 bytes"));
        let model = i32::from_le_bytes(chunk[64..68].try_into().expect("4 bytes"));
        let flags = chunk[68];

        if !timestamp.is_finite() {
            return Err(invalid_param("entry timestamp is not finite".to_string()));
        }
        entries.push(ClaudeEntry {
            timestamp,
            tokens: TokenBreakdown {
                input: to_i64(input),
                cache_write_5m: to_i64(cache_write_5m),
                cache_write_1h: to_i64(cache_write_1h),
                cache_read: to_i64(cache_read),
                output: to_i64(output),
                is_fast: flags & 0b100 != 0,
            },
            cost_usd: if cost_usd.is_nan() {
                None
            } else {
                Some(cost_usd).filter(|value| value.is_finite() && *value >= 0.0)
            },
            message_id: pool_index(message_id),
            request_id: pool_index(request_id),
            model: pool_index(model),
            is_sidechain: flags & 0b1 != 0,
            has_speed: flags & 0b10 != 0,
        });
    }
    // Validate every index against its pool, so a writer/reader disagreement is a typed error
    // instead of a panic or a silently dropped row.
    for entry in &entries {
        if let Some(index) = entry.message_id {
            if index as usize >= message_ids.len() {
                return Err(invalid_param("message id index out of range".to_string()));
            }
        }
        if let Some(index) = entry.request_id {
            if index as usize >= request_ids.len() {
                return Err(invalid_param("request id index out of range".to_string()));
            }
        }
        if let Some(index) = entry.model {
            if index as usize >= models.len() {
                return Err(invalid_param("model index out of range".to_string()));
            }
        }
    }
    Ok(entries)
}

fn to_i64(value: u64) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}

fn pool_index(value: i32) -> Option<u32> {
    (value >= 0).then_some(value as u32)
}

fn is_hosted_gateway_model(model: &str) -> bool {
    CLAUDE_GATEWAY_PREFIXES
        .iter()
        .any(|prefix| model.starts_with(prefix))
}

// ---------------------------------------------------------------------------
// Deduplication (mirror of `ClaudeLogUsageScanner.dedup`)
// ---------------------------------------------------------------------------

#[derive(Debug)]
struct Deduplication {
    entries: Vec<ClaudeEntry>,
    exact_index: HashMap<(u32, Option<u32>), usize>,
    message_index: HashMap<u32, Vec<usize>>,
}

impl Deduplication {
    fn new() -> Self {
        Self {
            entries: Vec::new(),
            exact_index: HashMap::new(),
            message_index: HashMap::new(),
        }
    }

    fn append(&mut self, entry: ClaudeEntry) {
        let Some(message_id) = entry.message_id else {
            self.entries.push(entry);
            return;
        };
        let key = (message_id, entry.request_id);
        let collision = self.exact_index.get(&key).copied().or_else(|| {
            self.message_index.get(&message_id).and_then(|indices| {
                indices
                    .iter()
                    .copied()
                    .find(|index| entry.is_sidechain || self.entries[*index].is_sidechain)
            })
        });

        if let Some(index) = collision {
            if should_replace(&entry, &self.entries[index]) {
                let old = &self.entries[index];
                if let Some(old_id) = old.message_id {
                    self.exact_index.remove(&(old_id, old.request_id));
                }
                self.entries[index] = entry;
                self.exact_index.insert(key, index);
            }
            return;
        }

        let index = self.entries.len();
        self.entries.push(entry);
        self.exact_index.insert(key, index);
        self.message_index
            .entry(message_id)
            .or_default()
            .push(index);
    }
}

fn should_replace(candidate: &ClaudeEntry, existing: &ClaudeEntry) -> bool {
    if candidate.is_sidechain != existing.is_sidechain {
        return existing.is_sidechain;
    }
    let candidate_total = candidate.tokens.total_tokens();
    let existing_total = existing.tokens.total_tokens();
    if candidate_total != existing_total {
        return candidate_total > existing_total;
    }
    candidate.has_speed && !existing.has_speed
}

fn dedup(entries: Vec<ClaudeEntry>) -> Vec<ClaudeEntry> {
    let mut deduplication = Deduplication::new();
    for entry in entries {
        deduplication.append(entry);
    }
    deduplication.entries
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use serde_json::json;

    pub(crate) struct EntrySpec {
        pub timestamp: f64,
        pub input: u64,
        pub cache_write_5m: u64,
        pub cache_write_1h: u64,
        pub cache_read: u64,
        pub output: u64,
        pub cost_usd: Option<f64>,
        pub message_id: Option<u32>,
        pub request_id: Option<u32>,
        pub model: Option<u32>,
        pub is_sidechain: bool,
        pub has_speed: bool,
        pub is_fast: bool,
    }

    impl Default for EntrySpec {
        fn default() -> Self {
            Self {
                timestamp: 1_000.0,
                input: 0,
                cache_write_5m: 0,
                cache_write_1h: 0,
                cache_read: 0,
                output: 0,
                cost_usd: None,
                message_id: None,
                request_id: None,
                model: None,
                is_sidechain: false,
                has_speed: false,
                is_fast: false,
            }
        }
    }

    pub(crate) fn encode(entries: &[EntrySpec]) -> Vec<u8> {
        let mut payload = vec![0u8; entries.len() * CLAUDE_ENTRY_STRIDE];
        for (index, entry) in entries.iter().enumerate() {
            let start = index * CLAUDE_ENTRY_STRIDE;
            let chunk = &mut payload[start..start + CLAUDE_ENTRY_STRIDE];
            chunk[0..8].copy_from_slice(&entry.timestamp.to_le_bytes());
            chunk[8..16].copy_from_slice(&entry.input.to_le_bytes());
            chunk[16..24].copy_from_slice(&entry.cache_write_5m.to_le_bytes());
            chunk[24..32].copy_from_slice(&entry.cache_write_1h.to_le_bytes());
            chunk[32..40].copy_from_slice(&entry.cache_read.to_le_bytes());
            chunk[40..48].copy_from_slice(&entry.output.to_le_bytes());
            chunk[48..56].copy_from_slice(&entry.cost_usd.unwrap_or(f64::NAN).to_le_bytes());
            chunk[56..60].copy_from_slice(&entry.message_id.map_or(-1, |v| v as i32).to_le_bytes());
            chunk[60..64].copy_from_slice(&entry.request_id.map_or(-1, |v| v as i32).to_le_bytes());
            chunk[64..68].copy_from_slice(&entry.model.map_or(-1, |v| v as i32).to_le_bytes());
            let mut flags = 0u8;
            if entry.is_sidechain {
                flags |= 0b1;
            }
            if entry.has_speed {
                flags |= 0b10;
            }
            if entry.is_fast {
                flags |= 0b100;
            }
            chunk[68] = flags;
        }
        payload
    }

    fn params(models: &[&str], pricing: Value) -> Value {
        json!({
            "since": 1_000.0,
            "dayBoundaries": [[1_000.0, "2026-01-01"], [2_000.0, "2026-01-02"]],
            "models": models,
            "messageIds": ["msg_1", "msg_2"],
            "requestIds": ["req_1", "req_2"],
            "pricing": pricing,
        })
    }

    fn rates(input: f64, output: f64) -> Value {
        json!({
            "inputPerMillion": input,
            "outputPerMillion": output,
            "cacheWritePerMillion": input,
            "cacheReadPerMillion": input / 10.0,
            "cacheReadIsExplicit": true,
            "longContextThresholdTokens": 200000,
            "fastMultiplier": 1.0,
        })
    }

    #[test]
    fn folds_tokens_cost_and_models_by_day() {
        let models = ["claude-model"];
        let payload = encode(&[
            EntrySpec {
                input: 1_000_000,
                output: 0,
                model: Some(0),
                message_id: Some(0),
                request_id: Some(0),
                ..EntrySpec::default()
            },
            EntrySpec {
                timestamp: 2_500.0,
                input: 0,
                output: 1_000_000,
                cost_usd: Some(0.25),
                model: Some(0),
                message_id: Some(1),
                request_id: Some(1),
                ..EntrySpec::default()
            },
        ]);
        let result = fold(
            &params(&models, json!({"claude-model": rates(10.0, 20.0)})),
            &payload,
        )
        .expect("fold");
        let days = result["scan"]["series"]["daily"].as_array().unwrap();
        assert_eq!(days.len(), 2);
        assert_eq!(days[0]["date"], "2026-01-02");
        assert_eq!(days[0]["totalTokens"], 1_000_000);
        assert_eq!(days[0]["costUSD"], 0.25);
        assert_eq!(days[1]["costUSD"], 10.0);
        assert_eq!(
            result["scan"]["modelUsage"]["daily"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
    }

    #[test]
    fn deduplicates_exact_and_sidechain_replays() {
        let models = ["m"];
        let payload = encode(&[
            EntrySpec {
                input: 10,
                message_id: Some(0),
                request_id: Some(0),
                model: Some(0),
                ..EntrySpec::default()
            },
            EntrySpec {
                input: 10,
                message_id: Some(0),
                request_id: Some(0),
                model: Some(0),
                ..EntrySpec::default()
            },
            EntrySpec {
                input: 5,
                message_id: Some(0),
                request_id: Some(1),
                model: Some(0),
                is_sidechain: true,
                ..EntrySpec::default()
            },
        ]);
        let result = fold(&params(&models, json!({"m": rates(1.0, 1.0)})), &payload).unwrap();
        assert_eq!(result["scan"]["series"]["daily"][0]["totalTokens"], 10);
    }

    #[test]
    fn gateway_models_and_unpriced_rows_keep_tokens() {
        let models = ["anthropic/opencode_go/deepseek", "mystery"];
        let payload = encode(&[
            EntrySpec {
                input: 100,
                model: Some(0),
                ..EntrySpec::default()
            },
            EntrySpec {
                input: 50,
                output: 25,
                model: Some(1),
                ..EntrySpec::default()
            },
        ]);
        let result = fold(&params(&models, json!({})), &payload).unwrap();
        assert_eq!(result["scan"]["series"]["daily"][0]["totalTokens"], 75);
        assert_eq!(
            result["scan"]["unknownModelsByDay"]["2026-01-01"][0],
            "mystery"
        );
        assert_eq!(
            result["scan"]["series"]["daily"][0]["costIsComplete"],
            false
        );
    }

    #[test]
    fn rejects_malformed_payloads() {
        let error = fold(&params(&["m"], json!({})), &[0u8; 10]).unwrap_err();
        assert_eq!(error.kind, "invalid_request");
    }
}
