//! Codex rollout-line parser — port of `CodexLogUsageScanner.FileParser` (Swift).
//!
//! Stateful across lines of one file (carries the running model, the fast-tier flags and the
//! child-session replay gate), mirroring the Swift implementation exactly. The Swift file
//! parser remains the reference oracle and the runtime fallback: when a line carries a
//! timestamp a Foundation-backed parser could still understand but this module cannot (any
//! non-canonical-UTC string), the whole file must be re-parsed by Swift — `qb_codex_parser_feed_line`
//! reports `QB_CODEX_FEED_FALLBACK` and the caller abandons this parser for the file.

use crate::{intern, parse_canonical_utc, CanonicalTimestamp, NIL_STRING};
use serde_json::{Map, Value};
use std::ptr;

pub const QB_CODEX_FEED_OK: u32 = 0;
pub const QB_CODEX_FEED_FALLBACK: u32 = 1;

const TURN_CONTEXT_MARKER: &[u8] = br#""type":"turn_context""#;
const TOKEN_COUNT_MARKER: &[u8] = br#""type":"token_count""#;
const SESSION_META_MARKER: &[u8] = br#""type":"session_meta""#;
const TASK_STARTED_MARKER: &[u8] = br#""type":"task_started""#;
const THREAD_SETTINGS_MARKER: &[u8] = br#""type":"thread_settings_applied""#;

fn contains_marker(line: &[u8], marker: &[u8]) -> bool {
    line.windows(marker.len()).any(|window| window == marker)
}

/// Swift's `trimmingCharacters(in: .whitespaces)` trims space, tab and Unicode spaces but never
/// newline characters; `str::trim` also eats `\n`/`\r`, which could mask an embedded-newline
/// timestamp that Foundation would reject.
fn trim_ws(s: &str) -> &str {
    s.trim_matches(|c: char| c != '\n' && c != '\r' && c.is_whitespace())
}

fn saturating_add(a: i64, b: i64) -> i64 {
    a.checked_add(b).unwrap_or(i64::MAX)
}

// ---------------------------------------------------------------------------
// RawUsage (mirror of CodexLogUsageScanner.RawUsage)
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq)]
struct RawUsage {
    input: i64,
    cached: i64,
    output: i64,
    reasoning: i64,
    total: i64,
    has_reported_total: bool,
    is_valid: bool,
    has_complete_cost_breakdown: bool,
}

/// Mirror of `int(keys...)`: a JSON number (never a bool, never null), finite, in [0, 1e15],
/// integral. Returns `(value, is_present, is_valid)`.
fn int_keys(json: &Map<String, Value>, keys: &[&str]) -> (Option<i64>, bool, bool) {
    for key in keys {
        let raw = match json.get(*key) {
            Some(raw) => raw,
            None => continue,
        };
        let number = match raw {
            Value::Number(n) => n,
            _ => return (None, true, false),
        };
        let f = match number.as_f64() {
            Some(f) => f,
            None => return (None, true, false),
        };
        if !f.is_finite() || f < 0.0 || f > 1e15 || f.fract() != 0.0 {
            return (None, true, false);
        }
        return (Some(f as i64), true, true);
    }
    (None, false, true)
}

impl RawUsage {
    fn from_json(json: &Map<String, Value>) -> RawUsage {
        let parsed_input = int_keys(json, &["input_tokens", "prompt_tokens", "input"]);
        let parsed_cached =
            int_keys(json, &["cached_input_tokens", "cache_read_input_tokens", "cached_tokens"]);
        let parsed_output =
            int_keys(json, &["output_tokens", "completion_tokens", "output"]);
        let parsed_reasoning = int_keys(json, &["reasoning_output_tokens", "reasoning_tokens"]);
        let parsed_total = int_keys(json, &["total_tokens"]);

        let input = parsed_input.0.unwrap_or(0);
        // Cached input is a subset of reported input.
        let cached = parsed_cached.0.unwrap_or(0).min(input);
        let output = parsed_output.0.unwrap_or(0);
        let reasoning = parsed_reasoning.0.unwrap_or(0);

        let reported = parsed_total.0.unwrap_or(0);
        let recomputed = saturating_add(input, output);
        let has_reported_total = reported > 0;
        let total = if has_reported_total { reported } else { recomputed };
        let has_authoritative_total = has_reported_total
            || (parsed_input.1 && parsed_output.1);
        let is_valid = parsed_input.2
            && parsed_cached.2
            && parsed_output.2
            && parsed_reasoning.2
            && parsed_total.2
            && has_authoritative_total;
        let has_complete_cost_breakdown = parsed_input.1
            && parsed_output.1
            && cached <= input
            && reasoning <= output
            // A present zero total is still a report.
            && (!parsed_total.1 || reported == recomputed);

        RawUsage {
            input,
            cached,
            output,
            reasoning,
            total,
            has_reported_total,
            is_valid,
            has_complete_cost_breakdown,
        }
    }

    fn subtracting(&self, previous: Option<&RawUsage>) -> RawUsage {
        let Some(previous) = previous else {
            return RawUsage {
                has_reported_total: self.has_reported_total,
                ..*self
            };
        };
        let delta_or = |current: i64, prev: i64| -> i64 {
            if current >= prev {
                current - prev
            } else {
                current
            }
        };
        let input = delta_or(self.input, previous.input);
        let cached = delta_or(self.cached, previous.cached);
        let output = delta_or(self.output, previous.output);
        let reasoning = delta_or(self.reasoning, previous.reasoning);
        let component_total = saturating_add(input, output);
        let total_delta = if self.has_reported_total {
            if self.total >= previous.total {
                self.total - previous.total
            } else {
                self.total
            }
        } else {
            component_total
        };
        let complete = self.has_complete_cost_breakdown
            && previous.has_complete_cost_breakdown
            && cached <= input
            && reasoning <= output
            && total_delta == component_total;
        RawUsage {
            input,
            cached,
            output,
            reasoning,
            total: total_delta,
            has_reported_total: false,
            is_valid: self.is_valid && previous.is_valid,
            has_complete_cost_breakdown: complete,
        }
    }

    fn adding_as_baseline(&self, delta: &RawUsage) -> RawUsage {
        RawUsage {
            input: saturating_add(self.input, delta.input),
            cached: saturating_add(self.cached, delta.cached),
            output: saturating_add(self.output, delta.output),
            reasoning: saturating_add(self.reasoning, delta.reasoning),
            total: saturating_add(self.total, delta.total),
            has_reported_total: false,
            is_valid: self.is_valid && delta.is_valid,
            has_complete_cost_breakdown: self.has_complete_cost_breakdown
                && delta.has_complete_cost_breakdown,
        }
    }

    fn as_baseline(&self) -> RawUsage {
        RawUsage {
            has_reported_total: false,
            ..*self
        }
    }
}

// ---------------------------------------------------------------------------
// ChildReplayGate (mirror of Swift ChildReplayGate)
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq)]
enum ReplayGate {
    UntilStartedAt(i64),
    UntilSelfTimed,
}

impl ReplayGate {
    /// `line_timestamp` is the raw (trimmed) timestamp string of the task_started line, if any.
    /// `Ok(None)` means "timestamp present but not canonical"; the caller must fall back for the
    /// file because Swift's Foundation-backed parser could still understand it.
    fn is_cleared(
        &self,
        started_at: f64,
        line_timestamp: Option<&str>,
    ) -> Result<bool, ()> {
        match self {
            ReplayGate::UntilStartedAt(gate) => Ok(started_at >= *gate as f64),
            ReplayGate::UntilSelfTimed => {
                let Some(raw) = line_timestamp else {
                    return Ok(false);
                };
                match parse_canonical_utc(raw.as_bytes()) {
                    CanonicalTimestamp::Ok(seconds) => {
                        Ok(started_at >= seconds.floor())
                    }
                    CanonicalTimestamp::Invalid => Ok(false),
                    CanonicalTimestamp::NotCanonical => Err(()),
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Small payload walkers (mirror the Swift helpers)
// ---------------------------------------------------------------------------

enum ModelNameUpdate {
    Absent,
    Value(String),
    Invalid,
}

fn model_name_update(json: &Map<String, Value>) -> ModelNameUpdate {
    let values: [Option<&Value>; 3] = [
        json.get("model"),
        json.get("model_name"),
        json.get("metadata")
            .and_then(Value::as_object)
            .and_then(|m| m.get("model")),
    ];
    for value in values {
        let Some(value) = value else {
            continue;
        };
        let Some(text) = value.as_str() else {
            return ModelNameUpdate::Invalid;
        };
        let trimmed = text.trim();
        if trimmed.is_empty() {
            continue;
        }
        return ModelNameUpdate::Value(trimmed.to_string());
    }
    ModelNameUpdate::Absent
}

struct ServiceTierUpdate {
    tier: Option<String>,
    is_valid: bool,
}

fn parsed_service_tier(raw: &Value) -> ServiceTierUpdate {
    let Some(text) = raw.as_str() else {
        return ServiceTierUpdate {
            tier: None,
            is_valid: false,
        };
    };
    let tier = text.trim().to_lowercase();
    const KNOWN: &[&str] = &[
        "auto", "default", "standard", "priority", "fast", "flex", "batch", "ultrafast",
    ];
    if tier.is_empty() || !KNOWN.contains(&tier.as_str()) {
        return ServiceTierUpdate {
            tier: if tier.is_empty() { None } else { Some(tier) },
            is_valid: false,
        };
    }
    ServiceTierUpdate {
        tier: Some(tier),
        is_valid: true,
    }
}

fn service_tier_update(payload: &Map<String, Value>) -> Option<ServiceTierUpdate> {
    if let Some(raw_settings) = payload.get("thread_settings") {
        match raw_settings.as_object() {
            Some(settings) => {
                if let Some(raw_tier) = settings.get("service_tier") {
                    return Some(parsed_service_tier(raw_tier));
                }
            }
            None => {
                return Some(ServiceTierUpdate {
                    tier: None,
                    is_valid: false,
                })
            }
        }
    }
    if let Some(raw_tier) = payload.get("service_tier") {
        return Some(parsed_service_tier(raw_tier));
    }
    None
}

fn has_non_null_value(value: Option<&Value>) -> bool {
    match value {
        None | Some(Value::Null) => false,
        Some(Value::String(s)) => !s.trim().is_empty(),
        _ => true,
    }
}

fn is_child_session_meta(payload: &Map<String, Value>) -> bool {
    if has_non_null_value(payload.get("forked_from_id")) {
        return true;
    }
    if has_non_null_value(payload.get("parent_thread_id")) {
        return true;
    }
    if payload.get("thread_source").and_then(Value::as_str) == Some("subagent") {
        return true;
    }
    if let Some(source) = payload.get("source").and_then(Value::as_object) {
        if has_non_null_value(source.get("subagent")) {
            return true;
        }
    }
    false
}

const AUTO_REVIEW_MODEL: &str = "codex-auto-review";
const RESERVE_MODEL: &str = "gpt-reserve";

const AUTO_REVIEW_FALLBACKS: &[(&str, &str)] = &[
    ("2026-09-22", "gpt-6-luna"),
    ("2026-07-09", "gpt-5.6-luna"),
    ("2026-04-23", "gpt-5.5"),
    ("2026-03-05", "gpt-5.4"),
    ("2026-02-05", "gpt-5.3-codex"),
    ("2025-12-11", "gpt-5.2-codex"),
    ("2025-11-13", "gpt-5.1-codex"),
    ("2025-09-15", "gpt-5-codex"),
    ("2025-08-07", "gpt-5"),
];

fn auto_review_fallback(timestamp: &str) -> &'static str {
    let bytes = timestamp.as_bytes();
    if bytes.len() < 10 {
        return "gpt-5";
    }
    let date = &timestamp[..10];
    let valid = date.len() == 10
        && date.as_bytes()[4] == b'-'
        && date.as_bytes()[7] == b'-'
        && date
            .as_bytes()
            .iter()
            .enumerate()
            .all(|(i, &b)| i == 4 || i == 7 || b.is_ascii_digit());
    if !valid {
        return "gpt-5";
    }
    AUTO_REVIEW_FALLBACKS
        .iter()
        .find(|(released, _)| date >= *released)
        .map(|(_, model)| *model)
        .unwrap_or("gpt-5")
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

struct CodexEventOut {
    timestamp: f64,
    model: String,
    pricing_model: Option<String>,
    input: i64,
    cached: i64,
    output: i64,
    reasoning: i64,
    total: i64,
    has_complete_cost_breakdown: bool,
    is_fast: bool,
    service_tier: Option<String>,
}

pub struct CodexParser {
    emit_since: Option<f64>,
    previous_totals: Option<RawUsage>,
    current_model: Option<String>,
    current_tier_is_fast: bool,
    current_service_tier: Option<String>,
    current_service_tier_is_valid: bool,
    saw_session_meta: bool,
    replay_gate: Option<ReplayGate>,
    damaged_line_count: u64,
    events: Vec<CodexEventOut>,
}

impl CodexParser {
    fn new(emit_since: Option<f64>) -> Self {
        CodexParser {
            emit_since,
            previous_totals: None,
            current_model: None,
            current_tier_is_fast: false,
            current_service_tier: None,
            current_service_tier_is_valid: true,
            saw_session_meta: false,
            replay_gate: None,
            damaged_line_count: 0,
            events: Vec::new(),
        }
    }

    fn resolve_model(&mut self, parsed: Option<String>) -> String {
        if let Some(model) = parsed {
            self.current_model = Some(model);
        }
        if let Some(current) = &self.current_model {
            return current.clone();
        }
        self.current_model = Some("gpt-5".to_string());
        "gpt-5".to_string()
    }

    /// Feed one line. `Ok(())` means consumed (whatever the outcome); `Err(())` means the caller
    /// must re-parse the whole file with the Swift implementation.
    fn consume(&mut self, line: &[u8]) -> Result<(), ()> {
        let is_turn_context = contains_marker(line, TURN_CONTEXT_MARKER);
        let is_session_meta = !self.saw_session_meta && contains_marker(line, SESSION_META_MARKER);
        let is_task_started = self.replay_gate.is_some() && contains_marker(line, TASK_STARTED_MARKER);
        let is_thread_settings = contains_marker(line, THREAD_SETTINGS_MARKER);
        let is_token_count = contains_marker(line, TOKEN_COUNT_MARKER);
        if !is_turn_context && !is_session_meta && !is_task_started && !is_thread_settings && !is_token_count {
            return Ok(());
        }

        let value: Value = match serde_json::from_slice(line) {
            Ok(v) => v,
            Err(_) => {
                if is_token_count {
                    self.damaged_line_count += 1;
                }
                return Ok(());
            }
        };
        let object = match &value {
            Value::Object(o) => o,
            _ => {
                if is_token_count {
                    self.damaged_line_count += 1;
                }
                return Ok(());
            }
        };
        let line_type = object.get("type").and_then(Value::as_str);
        let payload = object.get("payload").and_then(Value::as_object);

        if line_type == Some("turn_context") {
            let Some(payload) = payload else {
                self.damaged_line_count += 1;
                self.current_model = None;
                return Ok(());
            };
            match model_name_update(payload) {
                ModelNameUpdate::Absent => {}
                ModelNameUpdate::Value(model) => self.current_model = Some(model),
                ModelNameUpdate::Invalid => {
                    self.damaged_line_count += 1;
                    self.current_model = None;
                }
            }
            return Ok(());
        }

        if line_type == Some("session_meta") && !self.saw_session_meta {
            self.saw_session_meta = true;
            if let Some(payload) = payload {
                if is_child_session_meta(payload) {
                    let timestamp_raw = object
                        .get("timestamp")
                        .and_then(Value::as_str)
                        .map(trim_ws);
                    match timestamp_raw {
                        Some(raw) => match parse_canonical_utc(raw.as_bytes()) {
                            CanonicalTimestamp::Ok(seconds) => {
                                self.replay_gate =
                                    Some(ReplayGate::UntilStartedAt(seconds.floor() as i64));
                            }
                            CanonicalTimestamp::Invalid => {
                                self.replay_gate = Some(ReplayGate::UntilSelfTimed);
                            }
                            CanonicalTimestamp::NotCanonical => return Err(()),
                        },
                        None => {
                            // Missing or non-string timestamp: Foundation cannot parse it either.
                            self.replay_gate = Some(ReplayGate::UntilSelfTimed);
                        }
                    }
                }
            }
            return Ok(());
        }

        if is_thread_settings
            && line_type == Some("event_msg")
            && payload.and_then(|p| p.get("type")).and_then(Value::as_str)
                == Some("thread_settings_applied")
        {
            if let Some(payload) = payload {
                if let Some(update) = service_tier_update(payload) {
                    self.current_service_tier_is_valid = update.is_valid;
                    self.current_service_tier =
                        if update.is_valid { update.tier } else { None };
                    self.current_tier_is_fast = update.is_valid
                        && matches!(
                            self.current_service_tier.as_deref(),
                            Some("fast") | Some("priority")
                        );
                }
            }
            return Ok(());
        }

        if line_type != Some("event_msg") || payload.is_none() {
            if is_token_count {
                self.damaged_line_count += 1;
            }
            return Ok(());
        }
        let payload = payload.expect("payload presence checked above");

        if payload.get("type").and_then(Value::as_str) == Some("task_started") {
            if let Some(gate) = self.replay_gate {
                if let Some(started_at) = payload.get("started_at").and_then(Value::as_f64) {
                    let line_timestamp = object
                        .get("timestamp")
                        .and_then(Value::as_str)
                        .map(trim_ws);
                    match gate.is_cleared(started_at, line_timestamp) {
                        Ok(true) => self.replay_gate = None,
                        Ok(false) => {}
                        Err(()) => return Err(()),
                    }
                }
            }
            return Ok(());
        }

        if payload.get("type").and_then(Value::as_str) != Some("token_count") {
            if is_token_count {
                self.damaged_line_count += 1;
            }
            return Ok(());
        }

        // token_count body.
        let timestamp_raw = match object.get("timestamp").and_then(Value::as_str).map(trim_ws) {
            Some(raw) => raw,
            None => {
                self.damaged_line_count += 1;
                return Ok(());
            }
        };
        let timestamp = match parse_canonical_utc(timestamp_raw.as_bytes()) {
            CanonicalTimestamp::Ok(seconds) => seconds,
            CanonicalTimestamp::Invalid => {
                self.damaged_line_count += 1;
                return Ok(());
            }
            CanonicalTimestamp::NotCanonical => return Err(()),
        };

        let info = match payload.get("info").and_then(Value::as_object) {
            Some(info) => info,
            None => {
                self.damaged_line_count += 1;
                return Ok(());
            }
        };

        let totals: Option<RawUsage> = match info.get("total_token_usage") {
            Some(Value::Null) | None => None,
            Some(Value::Object(totals_object)) => {
                let parsed = RawUsage::from_json(totals_object);
                if !parsed.is_valid {
                    self.damaged_line_count += 1;
                    return Ok(());
                }
                Some(parsed)
            }
            Some(_) => {
                self.damaged_line_count += 1;
                return Ok(());
            }
        };

        if self.replay_gate.is_some() {
            if let Some(totals) = totals {
                self.previous_totals = Some(totals);
            } else if let Some(raw_last) = info.get("last_token_usage") {
                if !raw_last.is_null() {
                    match raw_last.as_object() {
                        Some(last_object) => {
                            let last = RawUsage::from_json(last_object);
                            if !last.is_valid {
                                self.damaged_line_count += 1;
                                return Ok(());
                            }
                            self.previous_totals = Some(match self.previous_totals {
                                Some(previous) => previous.adding_as_baseline(&last),
                                None => last.as_baseline(),
                            });
                        }
                        None => {
                            self.damaged_line_count += 1;
                            return Ok(());
                        }
                    }
                }
            }
            return Ok(());
        }

        if let Some(totals) = totals {
            if let Some(previous) = self.previous_totals {
                if totals == previous {
                    return Ok(());
                }
            }
        }

        let usage: RawUsage = match info.get("last_token_usage") {
            Some(raw_last) if !raw_last.is_null() => {
                match raw_last.as_object() {
                    Some(last_object) => {
                        let last = RawUsage::from_json(last_object);
                        if !last.is_valid {
                            self.damaged_line_count += 1;
                            return Ok(());
                        }
                        if totals.is_none() {
                            self.previous_totals = Some(match self.previous_totals {
                                Some(previous) => previous.adding_as_baseline(&last),
                                None => last.as_baseline(),
                            });
                        }
                        last
                    }
                    None => {
                        self.damaged_line_count += 1;
                        return Ok(());
                    }
                }
            }
            _ => match totals {
                Some(totals) => totals.subtracting(self.previous_totals.as_ref()),
                None => {
                    self.damaged_line_count += 1;
                    return Ok(());
                }
            },
        };

        if !usage.is_valid {
            self.damaged_line_count += 1;
            return Ok(());
        }
        if totals.is_some() {
            self.previous_totals = totals;
        }
        if usage.input == 0
            && usage.cached == 0
            && usage.output == 0
            && usage.reasoning == 0
            && usage.total == 0
        {
            return Ok(());
        }

        let parsed_model = match model_name_update(payload) {
            ModelNameUpdate::Value(model) => Some(model),
            ModelNameUpdate::Invalid => {
                self.damaged_line_count += 1;
                return Ok(());
            }
            ModelNameUpdate::Absent => match model_name_update(info) {
                ModelNameUpdate::Value(model) => Some(model),
                ModelNameUpdate::Invalid => {
                    self.damaged_line_count += 1;
                    return Ok(());
                }
                ModelNameUpdate::Absent => None,
            },
        };
        let model = self.resolve_model(parsed_model);
        let pricing_model = if model == AUTO_REVIEW_MODEL || model == RESERVE_MODEL {
            Some(auto_review_fallback(timestamp_raw).to_string())
        } else {
            None
        };

        let event = CodexEventOut {
            timestamp,
            model,
            pricing_model,
            input: usage.input,
            cached: usage.cached,
            output: usage.output,
            reasoning: usage.reasoning,
            total: usage.total,
            has_complete_cost_breakdown: usage.has_complete_cost_breakdown
                && self.current_service_tier_is_valid,
            is_fast: self.current_tier_is_fast,
            service_tier: self.current_service_tier.clone(),
        };
        if self.emit_since.is_none() || timestamp >= self.emit_since.unwrap_or(0.0) {
            self.events.push(event);
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// C ABI
// ---------------------------------------------------------------------------

/// One emitted Codex event. String offsets index into the blob returned by
/// [`qb_codex_take_events_strings`]; `UINT32_MAX` marks absent optional fields.
#[repr(C)]
pub struct QbCodexEvent {
    pub timestamp: f64,
    pub input_tokens: i64,
    pub cached_tokens: i64,
    pub output_tokens: i64,
    pub reasoning_tokens: i64,
    pub total_tokens: i64,
    pub model_offset: u32,
    pub model_length: u32,
    pub pricing_model_offset: u32,
    pub pricing_model_length: u32,
    pub service_tier_offset: u32,
    pub service_tier_length: u32,
    pub has_complete_cost_breakdown: u8,
    pub is_fast: u8,
    pub reserved: [u8; 6],
}

pub struct CodexEventResult {
    entries: Vec<QbCodexEvent>,
    strings: Vec<u8>,
}

pub struct CodexCheckpointResult {
    has_previous_totals: u8,
    previous_input: i64,
    previous_cached: i64,
    previous_output: i64,
    previous_reasoning: i64,
    previous_total: i64,
    previous_has_reported_total: u8,
    previous_is_valid: u8,
    previous_has_complete_cost_breakdown: u8,
    saw_session_meta: u8,
    current_tier_is_fast: u8,
    current_service_tier_is_valid: u8,
    replay_gate_kind: u8, // 0 none, 1 until_started_at, 2 until_self_timed
    replay_gate_started_at: f64,
    current_model_offset: u32,
    current_model_length: u32,
    service_tier_offset: u32,
    service_tier_length: u32,
    strings: Vec<u8>,
}

fn push_optional(blob: &mut Vec<u8>, value: &Option<String>) -> Option<(u32, u32)> {
    match value {
        Some(s) => intern(blob, s),
        None => Some((NIL_STRING, 0)),
    }
}

/// Create a parser for one file. `has_emit_since`/`emit_since_seconds` mirror Swift's `Date?`;
/// when `has_emit_since == 0` every parsed event is emitted.
#[no_mangle]
pub extern "C" fn qb_codex_parser_create(has_emit_since: u8, emit_since_seconds: f64) -> *mut CodexParser {
    let emit_since = (has_emit_since != 0).then_some(emit_since_seconds);
    Box::into_raw(Box::new(CodexParser::new(emit_since)))
}

/// Feed one line. Returns `QB_CODEX_FEED_FALLBACK` when the line carries a timestamp this
/// module cannot emulate (Foundation could); the caller must abandon this parser and re-parse
/// the file with the Swift implementation.
///
/// # Safety
/// `parser` must come from [`qb_codex_parser_create`] and not be destroyed yet.
#[no_mangle]
pub unsafe extern "C" fn qb_codex_parser_feed_line(
    parser: *mut CodexParser,
    line: *const u8,
    line_len: usize,
) -> u32 {
    if parser.is_null() {
        return QB_CODEX_FEED_OK;
    }
    if line.is_null() && line_len > 0 {
        return QB_CODEX_FEED_FALLBACK;
    }
    let bytes = if line.is_null() {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(line, line_len) }
    };
    let parser = unsafe { &mut *parser };
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| parser.consume(bytes))) {
        Ok(Ok(())) => QB_CODEX_FEED_OK,
        Ok(Err(())) => QB_CODEX_FEED_FALLBACK,
        Err(_) => QB_CODEX_FEED_FALLBACK,
    }
}

/// Number of lines the parser skipped as damaged (Swift's `damagedLineCount` accounting).
///
/// # Safety
/// `parser` must be a live pointer from [`qb_codex_parser_create`].
#[no_mangle]
pub unsafe extern "C" fn qb_codex_parser_damaged_count(parser: *const CodexParser) -> u64 {
    if parser.is_null() {
        return 0;
    }
    unsafe { &*parser }.damaged_line_count
}

/// Move out the events emitted so far (the parser keeps its file state). Call once at the end
/// of a file. The result must be passed to [`qb_codex_take_events_destroy`].
///
/// # Safety
/// `parser` must be a live pointer from [`qb_codex_parser_create`].
#[no_mangle]
pub unsafe extern "C" fn qb_codex_parser_take_events(parser: *mut CodexParser) -> *mut CodexEventResult {
    if parser.is_null() {
        return ptr::null_mut();
    }
    let parser = unsafe { &mut *parser };
    let events = std::mem::take(&mut parser.events);
    let mut strings: Vec<u8> = Vec::new();
    let mut entries: Vec<QbCodexEvent> = Vec::with_capacity(events.len());
    for event in &events {
        let (model_offset, model_length) = match intern(&mut strings, &event.model) {
            Some(v) => v,
            None => return ptr::null_mut(),
        };
        let (pricing_model_offset, pricing_model_length) =
            match push_optional(&mut strings, &event.pricing_model) {
                Some(v) => v,
                None => return ptr::null_mut(),
            };
        let (service_tier_offset, service_tier_length) =
            match push_optional(&mut strings, &event.service_tier) {
                Some(v) => v,
                None => return ptr::null_mut(),
            };
        entries.push(QbCodexEvent {
            timestamp: event.timestamp,
            input_tokens: event.input,
            cached_tokens: event.cached,
            output_tokens: event.output,
            reasoning_tokens: event.reasoning,
            total_tokens: event.total,
            model_offset,
            model_length,
            pricing_model_offset,
            pricing_model_length,
            service_tier_offset,
            service_tier_length,
            has_complete_cost_breakdown: u8::from(event.has_complete_cost_breakdown),
            is_fast: u8::from(event.is_fast),
            reserved: [0; 6],
        });
    }
    Box::into_raw(Box::new(CodexEventResult { entries, strings }))
}

#[no_mangle]
pub extern "C" fn qb_codex_take_events_count(result: *const CodexEventResult) -> u32 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.entries.len() as u32
}

#[no_mangle]
pub extern "C" fn qb_codex_take_events_entries(
    result: *const CodexEventResult,
) -> *const QbCodexEvent {
    if result.is_null() {
        return ptr::null();
    }
    unsafe { &*result }.entries.as_ptr()
}

#[no_mangle]
pub extern "C" fn qb_codex_take_events_strings(
    result: *const CodexEventResult,
    length: *mut u32,
) -> *const u8 {
    if result.is_null() {
        if !length.is_null() {
            unsafe { *length = 0 };
        }
        return ptr::null();
    }
    let result = unsafe { &*result };
    if !length.is_null() {
        unsafe { *length = result.strings.len() as u32 };
    }
    result.strings.as_ptr()
}

/// # Safety
/// `result` must be a pointer returned by [`qb_codex_parser_take_events`], destroyed at most once.
#[no_mangle]
pub unsafe extern "C" fn qb_codex_take_events_destroy(result: *mut CodexEventResult) {
    if result.is_null() {
        return;
    }
    unsafe { drop(Box::from_raw(result)) };
}

/// Export the parser checkpoint (one-way read; the parser keeps its state). The result must be
/// passed to [`qb_codex_checkpoint_destroy`].
///
/// # Safety
/// `parser` must be a live pointer from [`qb_codex_parser_create`].
#[no_mangle]
pub unsafe extern "C" fn qb_codex_parser_checkpoint(parser: *const CodexParser) -> *mut CodexCheckpointResult {
    if parser.is_null() {
        return ptr::null_mut();
    }
    let parser = unsafe { &*parser };
    let mut strings: Vec<u8> = Vec::new();
    let (current_model_offset, current_model_length) = match &parser.current_model {
        Some(s) => match intern(&mut strings, s) {
            Some(v) => v,
            None => return ptr::null_mut(),
        },
        None => (NIL_STRING, 0),
    };
    let (service_tier_offset, service_tier_length) = match &parser.current_service_tier {
        Some(s) => match intern(&mut strings, s) {
            Some(v) => v,
            None => return ptr::null_mut(),
        },
        None => (NIL_STRING, 0),
    };
    let (has_previous_totals, previous_input, previous_cached, previous_output, previous_reasoning, previous_total,
         previous_has_reported_total, previous_is_valid, previous_has_complete_cost_breakdown) =
        match parser.previous_totals {
            Some(u) => (
                1u8,
                u.input,
                u.cached,
                u.output,
                u.reasoning,
                u.total,
                u8::from(u.has_reported_total),
                u8::from(u.is_valid),
                u8::from(u.has_complete_cost_breakdown),
            ),
            None => (0u8, 0, 0, 0, 0, 0, 0, 0, 0),
        };
    let (replay_gate_kind, replay_gate_started_at) = match parser.replay_gate {
        Some(ReplayGate::UntilStartedAt(t)) => (1u8, t as f64),
        Some(ReplayGate::UntilSelfTimed) => (2u8, 0.0),
        None => (0u8, 0.0),
    };
    Box::into_raw(Box::new(CodexCheckpointResult {
        has_previous_totals,
        previous_input,
        previous_cached,
        previous_output,
        previous_reasoning,
        previous_total,
        previous_has_reported_total,
        previous_is_valid,
        previous_has_complete_cost_breakdown,
        saw_session_meta: u8::from(parser.saw_session_meta),
        current_tier_is_fast: u8::from(parser.current_tier_is_fast),
        current_service_tier_is_valid: u8::from(parser.current_service_tier_is_valid),
        replay_gate_kind,
        replay_gate_started_at,
        current_model_offset,
        current_model_length,
        service_tier_offset,
        service_tier_length,
        strings,
    }))
}

#[no_mangle]
pub extern "C" fn qb_codex_checkpoint_has_previous_totals(result: *const CodexCheckpointResult) -> u8 {
    unsafe { result.as_ref().map(|r| r.has_previous_totals).unwrap_or(0) }
}

macro_rules! codex_checkpoint_i64 {
    ($name:ident, $field:ident) => {
        #[no_mangle]
        pub extern "C" fn $name(result: *const CodexCheckpointResult) -> i64 {
            unsafe { result.as_ref().map(|r| r.$field).unwrap_or(0) }
        }
    };
}

codex_checkpoint_i64!(qb_codex_checkpoint_previous_input, previous_input);
codex_checkpoint_i64!(qb_codex_checkpoint_previous_cached, previous_cached);
codex_checkpoint_i64!(qb_codex_checkpoint_previous_output, previous_output);
codex_checkpoint_i64!(qb_codex_checkpoint_previous_reasoning, previous_reasoning);
codex_checkpoint_i64!(qb_codex_checkpoint_previous_total, previous_total);

#[no_mangle]
pub extern "C" fn qb_codex_checkpoint_previous_has_reported_total(result: *const CodexCheckpointResult) -> u8 {
    unsafe { result.as_ref().map(|r| r.previous_has_reported_total).unwrap_or(0) }
}

#[no_mangle]
pub extern "C" fn qb_codex_checkpoint_previous_is_valid(result: *const CodexCheckpointResult) -> u8 {
    unsafe { result.as_ref().map(|r| r.previous_is_valid).unwrap_or(0) }
}

#[no_mangle]
pub extern "C" fn qb_codex_checkpoint_previous_has_complete_cost_breakdown(
    result: *const CodexCheckpointResult,
) -> u8 {
    unsafe { result.as_ref().map(|r| r.previous_has_complete_cost_breakdown).unwrap_or(0) }
}

#[no_mangle]
pub extern "C" fn qb_codex_checkpoint_saw_session_meta(result: *const CodexCheckpointResult) -> u8 {
    unsafe { result.as_ref().map(|r| r.saw_session_meta).unwrap_or(0) }
}

#[no_mangle]
pub extern "C" fn qb_codex_checkpoint_current_tier_is_fast(result: *const CodexCheckpointResult) -> u8 {
    unsafe { result.as_ref().map(|r| r.current_tier_is_fast).unwrap_or(0) }
}

#[no_mangle]
pub extern "C" fn qb_codex_checkpoint_current_service_tier_is_valid(
    result: *const CodexCheckpointResult,
) -> u8 {
    unsafe { result.as_ref().map(|r| r.current_service_tier_is_valid).unwrap_or(0) }
}

/// 0 none, 1 until_started_at, 2 until_self_timed.
#[no_mangle]
pub extern "C" fn qb_codex_checkpoint_replay_gate_kind(result: *const CodexCheckpointResult) -> u8 {
    unsafe { result.as_ref().map(|r| r.replay_gate_kind).unwrap_or(0) }
}

#[no_mangle]
pub extern "C" fn qb_codex_checkpoint_replay_gate_started_at(result: *const CodexCheckpointResult) -> f64 {
    unsafe { result.as_ref().map(|r| r.replay_gate_started_at).unwrap_or(0.0) }
}

#[no_mangle]
pub extern "C" fn qb_codex_checkpoint_current_model_offset(result: *const CodexCheckpointResult) -> u32 {
    unsafe { result.as_ref().map(|r| r.current_model_offset).unwrap_or(NIL_STRING) }
}

#[no_mangle]
pub extern "C" fn qb_codex_checkpoint_current_model_length(result: *const CodexCheckpointResult) -> u32 {
    unsafe { result.as_ref().map(|r| r.current_model_length).unwrap_or(0) }
}

#[no_mangle]
pub extern "C" fn qb_codex_checkpoint_service_tier_offset(result: *const CodexCheckpointResult) -> u32 {
    unsafe { result.as_ref().map(|r| r.service_tier_offset).unwrap_or(NIL_STRING) }
}

#[no_mangle]
pub extern "C" fn qb_codex_checkpoint_service_tier_length(result: *const CodexCheckpointResult) -> u32 {
    unsafe { result.as_ref().map(|r| r.service_tier_length).unwrap_or(0) }
}

#[no_mangle]
pub extern "C" fn qb_codex_checkpoint_strings(
    result: *const CodexCheckpointResult,
    length: *mut u32,
) -> *const u8 {
    if result.is_null() {
        if !length.is_null() {
            unsafe { *length = 0 };
        }
        return ptr::null();
    }
    let result = unsafe { &*result };
    if !length.is_null() {
        unsafe { *length = result.strings.len() as u32 };
    }
    result.strings.as_ptr()
}

/// # Safety
/// `result` must be a pointer returned by [`qb_codex_parser_checkpoint`], destroyed at most once.
#[no_mangle]
pub unsafe extern "C" fn qb_codex_checkpoint_destroy(result: *mut CodexCheckpointResult) {
    if result.is_null() {
        return;
    }
    unsafe { drop(Box::from_raw(result)) };
}

/// Destroy a parser. # Safety
/// `parser` must be a pointer returned by [`qb_codex_parser_create`], destroyed at most once.
#[no_mangle]
pub unsafe extern "C" fn qb_codex_parser_destroy(parser: *mut CodexParser) {
    if parser.is_null() {
        return;
    }
    unsafe { drop(Box::from_raw(parser)) };
}
