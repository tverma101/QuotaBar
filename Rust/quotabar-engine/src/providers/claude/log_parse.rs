//! Claude session-log line parsing (Swift `ClaudeLogUsageScanner.parseEntriesSwift`).
//!
//! Mirrors what ccusage's serde model accepts: `usage` with numeric `input_tokens` / `output_tokens`
//! is required, everything else optional, and a line in an unfamiliar shape is *malformed*. A
//! malformed line fails the file's parse (and so the scan): a record in an unknown shape must stay
//! visible rather than silently undercount. Lines without a `"usage"` byte marker never reach the
//! parser, and non-assistant rows that carry a usage object (attachments, tool results) are skipped.

use super::entry::ClaudeEntry;
use crate::pricing::TokenBreakdown;
use crate::scan::{LineError, LineParser};
use crate::time::parse_iso8601;
use memchr::memmem;
use serde_json::{Map, Value};
use std::sync::Arc;

/// What one line produced. `malformed` carries the first reason a line was observably wrong; entries
/// may still be present (an advisor iteration can be malformed while its parent is fine).
#[derive(Debug, Default)]
pub struct LineParse {
    pub entries: Vec<ClaudeEntry>,
    pub malformed: Option<&'static str>,
}

impl LineParse {
    fn skipped() -> Self {
        LineParse::default()
    }

    fn rejected(reason: &'static str) -> Self {
        LineParse { entries: Vec::new(), malformed: Some(reason) }
    }
}

/// The incremental-scan parser: stateless (every line stands alone).
pub struct ClaudeLineParser {
    usage_marker: memmem::Finder<'static>,
}

impl Default for ClaudeLineParser {
    fn default() -> Self {
        ClaudeLineParser { usage_marker: memmem::Finder::new(b"\"usage\"").into_owned() }
    }
}

impl ClaudeLineParser {
    pub fn new() -> Self {
        Self::default()
    }
}

impl LineParser for ClaudeLineParser {
    type Item = ClaudeEntry;
    type State = ();
    /// Bump when parse semantics or the entry encoding change.
    const LAYOUT: u32 = 1;

    fn wants(&self, line: &[u8]) -> bool {
        self.usage_marker.find(line).is_some()
    }

    fn parse(&self, _state: &mut (), line: &[u8], out: &mut Vec<ClaudeEntry>) -> Result<(), LineError> {
        let parsed = parse_line(line);
        match parsed.malformed {
            Some(reason) => Err(LineError(reason)),
            None => {
                out.extend(parsed.entries);
                Ok(())
            }
        }
    }

    fn contributing_timestamp(&self, item: &ClaudeEntry) -> Option<f64> {
        item.contributes_usage().then_some(item.timestamp)
    }
}

/// Decode one JSONL line. The top-level usage is the main-model entry; only advisor-message
/// iterations become additional entries (under their own model), matching ccusage without recounting
/// the ordinary message iterations that feed the parent total.
pub fn parse_line(line: &[u8]) -> LineParse {
    let Ok(Value::Object(object)) = serde_json::from_slice::<Value>(line) else {
        return LineParse::rejected("line is not a JSON object");
    };
    // Attachments and tool results can contain unrelated usage objects. Only the assistant
    // message's accounting belongs to this source; a byte marker alone cannot classify it.
    if let Some(kind) = object.get("type") {
        if kind.as_str() != Some("assistant") {
            return LineParse::skipped();
        }
    }
    let message_usage = object.get("message").and_then(Value::as_object).and_then(|m| m.get("usage").map(|u| (m, u)));
    let Some((message, raw_usage)) = message_usage else {
        // A claimed assistant accounting record in an unfamiliar shape must stay observable. Other
        // rows may legitimately carry a usage key inside unrelated payloads.
        let claimed = object.get("type").and_then(Value::as_str) == Some("assistant") && object.contains_key("usage");
        return if claimed { LineParse::rejected("assistant usage record in an unfamiliar shape") } else { LineParse::skipped() };
    };
    let Value::Object(usage) = raw_usage else {
        return LineParse::rejected("usage is not an object");
    };
    let Some(timestamp) = object.get("timestamp").and_then(Value::as_str).and_then(parse_iso8601) else {
        return LineParse::rejected("missing or invalid timestamp");
    };
    if !is_valid_entry(&object, message) {
        return LineParse::rejected("invalid version, id, sidechain or model field");
    }
    let mut malformed: Option<&'static str> = None;
    let Some(parsed_usage) = token_breakdown(usage, &mut malformed) else {
        return LineParse { entries: Vec::new(), malformed };
    };
    let cost_usd = match object.get("costUSD") {
        None | Some(Value::Null) => None,
        Some(Value::Number(n)) => match n.as_f64() {
            Some(value) if value.is_finite() && (0.0..=1e12).contains(&value) => Some(value),
            _ => return LineParse::rejected("costUSD out of range"),
        },
        Some(_) => return LineParse::rejected("costUSD is not a number"),
    };

    let model: Option<Arc<str>> =
        message.get("model").and_then(Value::as_str).filter(|m| *m != "<synthetic>").map(Arc::from);
    let message_id: Option<Arc<str>> = message.get("id").and_then(Value::as_str).map(Arc::from);
    let request_id: Option<Arc<str>> = object.get("requestId").and_then(Value::as_str).map(Arc::from);
    let is_sidechain = object.get("isSidechain").and_then(Value::as_bool).unwrap_or(false);

    let mut entries = vec![ClaudeEntry {
        timestamp,
        tokens: parsed_usage.0,
        message_id: message_id.clone(),
        request_id: request_id.clone(),
        is_sidechain,
        has_speed: parsed_usage.1,
        cost_usd,
        model,
    }];

    match usage.get("iterations") {
        None | Some(Value::Null) => {}
        Some(Value::Array(iterations)) => {
            let mut advisor_index = 0usize;
            for iteration in iterations {
                let Some(iteration) = iteration.as_object() else {
                    malformed.get_or_insert("iteration is not an object");
                    continue;
                };
                if iteration.get("type").is_some_and(|t| !t.is_string()) {
                    malformed.get_or_insert("iteration type is not a string");
                    continue;
                }
                if iteration.get("type").and_then(Value::as_str) != Some("advisor_message") {
                    continue;
                }
                let Some((tokens, has_speed)) = token_breakdown(iteration, &mut malformed) else { continue };
                // Missing or malformed model attribution must not discard measured advisor tokens.
                // Keep them under the shared Unattributed label so their cost remains visibly unknown.
                let advisor_model = iteration
                    .get("model")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|m| !m.is_empty())
                    .map(Arc::<str>::from);
                entries.push(ClaudeEntry {
                    timestamp,
                    tokens,
                    message_id: message_id.as_ref().map(|id| Arc::from(format!("{id}:advisor:{advisor_index}"))),
                    request_id: request_id.clone(),
                    is_sidechain,
                    has_speed,
                    cost_usd: None,
                    model: advisor_model,
                });
                advisor_index += 1;
            }
        }
        Some(_) => {
            malformed.get_or_insert("iterations is not an array");
        }
    }
    LineParse { entries, malformed }
}

/// Swift `nonnegativeTokenCount`: a JSON number (never a bool), finite, in [0, 1e15] and integral.
fn nonnegative_token_count(raw: &Value) -> Option<i64> {
    let value = raw.as_f64()?;
    (value.is_finite() && (0.0..=1e15).contains(&value) && value.fract() == 0.0).then_some(value as i64)
}

/// Swift `optionalNonnegativeTokenCount`: absent or `null` means zero.
fn optional_token_count(raw: Option<&Value>) -> Option<i64> {
    match raw {
        None | Some(Value::Null) => Some(0),
        Some(value) => nonnegative_token_count(value),
    }
}

/// Normalize one usage object (the parent's, or an advisor iteration's) into token buckets plus
/// whether the log carried a `speed` field. `None` marks `malformed` and drops the object.
fn token_breakdown(usage: &Map<String, Value>, malformed: &mut Option<&'static str>) -> Option<(TokenBreakdown, bool)> {
    let mut fail = |reason: &'static str| {
        malformed.get_or_insert(reason);
        None
    };
    let (Some(input_raw), Some(output_raw)) = (usage.get("input_tokens"), usage.get("output_tokens")) else {
        return fail("input_tokens or output_tokens is missing");
    };
    let (Some(input), Some(output)) = (nonnegative_token_count(input_raw), nonnegative_token_count(output_raw)) else {
        return fail("input_tokens or output_tokens is not a token count");
    };

    // Cache writes: the 5m/1h split when present (1h bills at 2x input), else the legacy aggregate
    // `cache_creation_input_tokens` treated as all-5m.
    let (cache_write_5m, cache_write_1h) = match usage.get("cache_creation") {
        None | Some(Value::Null) => match optional_token_count(usage.get("cache_creation_input_tokens")) {
            Some(aggregate) => (aggregate, 0),
            None => return fail("cache_creation_input_tokens is not a token count"),
        },
        Some(Value::Object(creation)) => match (
            optional_token_count(creation.get("ephemeral_5m_input_tokens")),
            optional_token_count(creation.get("ephemeral_1h_input_tokens")),
        ) {
            (Some(five), Some(hour)) => (five, hour),
            _ => return fail("cache_creation split is not a token count"),
        },
        Some(_) => return fail("cache_creation is not an object"),
    };
    let Some(cache_read) = optional_token_count(usage.get("cache_read_input_tokens")) else {
        return fail("cache_read_input_tokens is not a token count");
    };
    // Claude tags fast-mode requests with `speed`; any value outside the known set marks a log shape
    // we don't understand, so the line is skipped (ccusage's enum parse does the same).
    let speed = match usage.get("speed") {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) if s == "fast" || s == "standard" => Some(s.as_str()),
        Some(_) => return fail("speed is not fast or standard"),
    };
    let tokens = TokenBreakdown {
        input,
        cache_write_5m,
        cache_write_1h,
        cache_read,
        output,
        is_fast: speed == Some("fast"),
    };
    Some((tokens, speed.is_some()))
}

/// ccusage's validity rules: a `version` that isn't SemVer marks a foreign log format, and ids / model
/// that are present but empty mark a malformed line.
fn is_valid_entry(object: &Map<String, Value>, message: &Map<String, Value>) -> bool {
    if let Some(version) = object.get("version") {
        if !version.as_str().is_some_and(is_valid_semver) {
            return false;
        }
    }
    for value in [object.get("sessionId"), object.get("requestId"), message.get("id")].into_iter().flatten() {
        if !value.as_str().is_some_and(|text| !text.is_empty()) {
            return false;
        }
    }
    if object.get("isSidechain").is_some_and(|v| !v.is_boolean()) {
        return false;
    }
    if let Some(model) = message.get("model") {
        if !model.as_str().is_some_and(|m| !m.trim().is_empty()) {
            return false;
        }
    }
    true
}

/// Accepts a complete SemVer value, including valid prerelease and build identifiers.
pub fn is_valid_semver(value: &str) -> bool {
    let mut build_parts = value.split('+');
    let release = build_parts.next().unwrap_or("");
    let build = build_parts.next();
    if build_parts.next().is_some() {
        return false;
    }
    if build.is_some_and(|build| !is_valid_identifiers(build, true)) {
        return false;
    }
    let mut release_parts = release.splitn(2, '-');
    let core = release_parts.next().unwrap_or("");
    let core_parts: Vec<&str> = core.split('.').collect();
    let core_ok = core_parts.len() == 3
        && core_parts
            .iter()
            .all(|part| !part.is_empty() && part.bytes().all(|b| b.is_ascii_digit()) && (*part == "0" || !part.starts_with('0')));
    if !core_ok {
        return false;
    }
    release_parts.next().is_none_or(|prerelease| is_valid_identifiers(prerelease, false))
}

fn is_valid_identifiers(value: &str, allow_numeric_leading_zero: bool) -> bool {
    value.split('.').all(|identifier| {
        let bytes = identifier.as_bytes();
        if bytes.is_empty() || !bytes.iter().all(|b| b.is_ascii_alphanumeric() || *b == b'-') {
            return false;
        }
        allow_numeric_leading_zero || bytes.len() == 1 || !(bytes.iter().all(u8::is_ascii_digit) && bytes[0] == b'0')
    })
}
