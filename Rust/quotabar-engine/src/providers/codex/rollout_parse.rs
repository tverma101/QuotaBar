//! The Codex rollout line parser (Swift `CodexLogUsageScanner.FileParser`), as a [`LineParser`] for
//! the shared incremental scanner. The parser state is [`RolloutState`], so an appended rollout
//! resumes with its model, service tier, totals baseline and child-replay gate intact.
//!
//! Swift's parser took an `emitSince` window; it only ever suppressed *emitting* an event, never
//! parser state or deltas. This port keeps every event and applies the window when folding, so one
//! cached parse serves any window.
//!
//! A line that cannot be accounted for (a `token_count` that is not valid JSON, has no timestamp,
//! carries a malformed usage object, ...) fails the file with a [`LineError`], which fails the scan
//! so last-good history is kept instead of silently under-counting.

use super::event::Event;
use super::raw_usage::RawUsage;
use super::rollout_state::{ReplayGate, RolloutState};
use crate::scan::{LineError, LineParser};
use crate::time::parse_iso8601;
use memchr::memmem::Finder;
use serde_json::{Map, Value};
use std::sync::Arc;

const AUTO_REVIEW_MODEL: &str = "codex-auto-review";
/// Visible slug for Codex Luna Reserve turns; cost uses [`auto_review_fallback`] (current Luna).
pub const RESERVE_MODEL: &str = "gpt-reserve";

/// `(released on, model)`, newest first: the pricing slug an auto-review turn is billed as.
const AUTO_REVIEW_FALLBACKS: [(&str, &str); 9] = [
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

/// Swift `trimmingCharacters(in: .whitespaces)`: spaces and tabs (Unicode `Zs`), never newlines.
pub(super) fn trim_whitespace(s: &str) -> &str {
    s.trim_matches(is_horizontal_space)
}

fn is_horizontal_space(c: char) -> bool {
    c == '\t'
        || matches!(
            c,
            '\u{20}' | '\u{a0}' | '\u{1680}' | '\u{2000}'
                ..='\u{200a}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
        )
}

/// Swift `autoReviewFallback(at:)`: the dated model an auto-review/reserve turn prices as.
pub fn auto_review_fallback(timestamp: &str) -> &'static str {
    let date: String = timestamp.chars().take(10).collect();
    let bytes = date.as_bytes();
    let day_shaped = bytes.len() == 10
        && bytes.iter().enumerate().all(|(i, b)| {
            if i == 4 || i == 7 {
                *b == b'-'
            } else {
                b.is_ascii_digit()
            }
        });
    if !day_shaped {
        return "gpt-5";
    }
    AUTO_REVIEW_FALLBACKS
        .iter()
        .find(|(released_on, _)| date.as_str() >= *released_on)
        .map_or("gpt-5", |(_, model)| model)
}

/// Swift `pricingFallbackModel(for:at:)`: for an auto-review / reserve slug (or a dated alias of
/// those) the Luna-family key to price with; `None` for ordinary names.
pub fn pricing_fallback_model(model: &str, timestamp: &str) -> Option<&'static str> {
    let trimmed = model.trim();
    let bare = trimmed
        .split('/')
        .filter(|s| !s.is_empty())
        .last()
        .unwrap_or(trimmed);
    let normalized = bare.to_lowercase();
    let is_auto_review = normalized == AUTO_REVIEW_MODEL
        || normalized == RESERVE_MODEL
        || normalized.starts_with("gpt-reserve")
        || normalized.ends_with("-reserve");
    is_auto_review.then(|| auto_review_fallback(timestamp))
}

/// Swift `resolveModel(parsed:currentModel:)`: an explicit model becomes the session's current one;
/// with none anywhere the session is `gpt-5`.
pub fn resolve_model(parsed: Option<Arc<str>>, current_model: &mut Option<Arc<str>>) -> Arc<str> {
    if let Some(parsed) = parsed {
        *current_model = Some(parsed.clone());
        return parsed;
    }
    current_model
        .get_or_insert_with(|| Arc::from("gpt-5"))
        .clone()
}

enum ModelNameUpdate {
    Absent,
    Value(Arc<str>),
    Invalid,
}

/// `model`, then `model_name`, then `metadata.model`: the first present key must be a string; an
/// empty (whitespace-only) value is skipped.
fn model_name_update(json: &Map<String, Value>) -> ModelNameUpdate {
    let metadata_model = json
        .get("metadata")
        .and_then(Value::as_object)
        .and_then(|m| m.get("model"));
    for value in [json.get("model"), json.get("model_name"), metadata_model]
        .into_iter()
        .flatten()
    {
        let Some(text) = value.as_str() else {
            return ModelNameUpdate::Invalid;
        };
        let trimmed = text.trim();
        if !trimmed.is_empty() {
            return ModelNameUpdate::Value(Arc::from(trimmed));
        }
    }
    ModelNameUpdate::Absent
}

struct ServiceTierUpdate {
    tier: Option<Arc<str>>,
    is_valid: bool,
}

const KNOWN_TIERS: [&str; 8] = [
    "auto",
    "default",
    "standard",
    "priority",
    "fast",
    "flex",
    "batch",
    "ultrafast",
];

fn parsed_service_tier(raw: &Value) -> ServiceTierUpdate {
    let Some(text) = raw.as_str() else {
        return ServiceTierUpdate {
            tier: None,
            is_valid: false,
        };
    };
    let tier = text.trim().to_lowercase();
    let is_valid = KNOWN_TIERS.contains(&tier.as_str());
    ServiceTierUpdate {
        tier: (!tier.is_empty()).then(|| Arc::from(tier)),
        is_valid,
    }
}

fn service_tier_update(payload: &Map<String, Value>) -> Option<ServiceTierUpdate> {
    if let Some(raw_settings) = payload.get("thread_settings") {
        let Some(settings) = raw_settings.as_object() else {
            return Some(ServiceTierUpdate {
                tier: None,
                is_valid: false,
            });
        };
        if let Some(raw_tier) = settings.get("service_tier") {
            return Some(parsed_service_tier(raw_tier));
        }
    }
    payload.get("service_tier").map(parsed_service_tier)
}

fn has_non_null_value(value: Option<&Value>) -> bool {
    match value {
        None | Some(Value::Null) => false,
        Some(Value::String(text)) => !text.trim().is_empty(),
        Some(_) => true,
    }
}

/// A `session_meta` payload that marks a forked or subagent session (its file starts with replayed
/// parent history).
pub fn is_child_session_meta(payload: &Map<String, Value>) -> bool {
    has_non_null_value(payload.get("forked_from_id"))
        || has_non_null_value(payload.get("parent_thread_id"))
        || payload.get("thread_source").and_then(Value::as_str) == Some("subagent")
        || payload
            .get("source")
            .and_then(Value::as_object)
            .is_some_and(|source| has_non_null_value(source.get("subagent")))
}

/// `NSNumber` also bridges JSON booleans (`true` is 1), so Swift accepted them as `started_at`.
fn number_as_f64(value: &Value) -> Option<f64> {
    match value {
        Value::Number(n) => n.as_f64(),
        Value::Bool(b) => Some(f64::from(u8::from(*b))),
        _ => None,
    }
}

fn str_field<'a>(object: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    object.get(key).and_then(Value::as_str)
}

pub struct CodexLineParser {
    turn_context: Finder<'static>,
    token_count: Finder<'static>,
    session_meta: Finder<'static>,
    task_started: Finder<'static>,
    thread_settings: Finder<'static>,
}

impl Default for CodexLineParser {
    fn default() -> Self {
        CodexLineParser {
            turn_context: Finder::new(br#""type":"turn_context""#),
            token_count: Finder::new(br#""type":"token_count""#),
            session_meta: Finder::new(br#""type":"session_meta""#),
            task_started: Finder::new(br#""type":"task_started""#),
            thread_settings: Finder::new(br#""type":"thread_settings_applied""#),
        }
    }
}

const MALFORMED_JSON: LineError = LineError("token_count line is not a JSON object");
const MALFORMED_CONTEXT: LineError =
    LineError("turn_context has no payload object or an invalid model");
const MALFORMED_TOKEN_COUNT: LineError =
    LineError("token_count line is not an event_msg with a payload object");
const MALFORMED_TYPE: LineError =
    LineError("line mentions token_count but is not a token_count event");
const MALFORMED_TIMESTAMP: LineError = LineError("token_count has no parseable timestamp");
const MALFORMED_INFO: LineError = LineError("token_count info is missing or not an object");
const MALFORMED_USAGE: LineError = LineError("token_count usage object is invalid");
const MALFORMED_MODEL: LineError = LineError("token_count model is not a string");

impl LineParser for CodexLineParser {
    type Item = Event;
    type State = RolloutState;
    /// Bump when parse semantics or the event encoding change.
    const LAYOUT: u32 = 1;

    /// The state-independent superset of the lines `parse` acts on (it re-applies the
    /// `saw_session_meta` and replay-gate conditions).
    fn wants(&self, line: &[u8]) -> bool {
        self.turn_context.find(line).is_some()
            || self.token_count.find(line).is_some()
            || self.session_meta.find(line).is_some()
            || self.task_started.find(line).is_some()
            || self.thread_settings.find(line).is_some()
    }

    fn contributing_timestamp(&self, event: &Event) -> Option<f64> {
        event.has_token_usage().then_some(event.timestamp)
    }

    fn parse(
        &self,
        state: &mut RolloutState,
        line: &[u8],
        out: &mut Vec<Event>,
    ) -> Result<(), LineError> {
        let is_turn_context = self.turn_context.find(line).is_some();
        let is_session_meta = !state.saw_session_meta && self.session_meta.find(line).is_some();
        let is_task_started = state.replay_gate.is_some() && self.task_started.find(line).is_some();
        let is_thread_settings = self.thread_settings.find(line).is_some();
        let has_token_count_marker = self.token_count.find(line).is_some();
        if !(is_turn_context
            || is_session_meta
            || is_task_started
            || is_thread_settings
            || has_token_count_marker)
        {
            return Ok(());
        }
        let malformed_if_token_count = |error: LineError| {
            if has_token_count_marker {
                Err(error)
            } else {
                Ok(())
            }
        };

        let Ok(Value::Object(object)) = serde_json::from_slice::<Value>(line) else {
            return malformed_if_token_count(MALFORMED_JSON);
        };
        let line_type = str_field(&object, "type");
        let payload = object.get("payload").and_then(Value::as_object);

        if line_type == Some("turn_context") {
            let Some(payload) = payload else {
                state.current_model = None;
                return Err(MALFORMED_CONTEXT);
            };
            match model_name_update(payload) {
                ModelNameUpdate::Invalid => {
                    state.current_model = None;
                    return Err(MALFORMED_CONTEXT);
                }
                ModelNameUpdate::Value(model) => state.current_model = Some(model),
                ModelNameUpdate::Absent => {}
            }
            return Ok(());
        }
        if line_type == Some("session_meta") && !state.saw_session_meta {
            state.saw_session_meta = true;
            if payload.is_some_and(is_child_session_meta) {
                // A creation time gates replay by second; without one the gate times itself off the
                // first task_started line.
                state.replay_gate = Some(
                    str_field(&object, "timestamp")
                        .and_then(|raw| parse_iso8601(trim_whitespace(raw)))
                        .map_or(ReplayGate::UntilSelfTimedTaskStarted, |created| {
                            ReplayGate::UntilStartedAt(created.floor() as i64)
                        }),
                );
            }
            return Ok(());
        }
        if is_thread_settings
            && line_type == Some("event_msg")
            && payload.and_then(|p| str_field(p, "type")) == Some("thread_settings_applied")
        {
            if let Some(update) = payload.and_then(service_tier_update) {
                state.current_service_tier_is_valid = update.is_valid;
                state.current_service_tier = if update.is_valid { update.tier } else { None };
                state.current_tier_is_fast = update.is_valid
                    && matches!(
                        state.current_service_tier.as_deref(),
                        Some("fast") | Some("priority")
                    );
            }
            return Ok(());
        }
        let (Some("event_msg"), Some(payload)) = (line_type, payload) else {
            return malformed_if_token_count(MALFORMED_TOKEN_COUNT);
        };

        let payload_type = str_field(payload, "type");
        if payload_type == Some("task_started") {
            if let (Some(gate), Some(started_at)) = (
                state.replay_gate,
                payload.get("started_at").and_then(number_as_f64),
            ) {
                if gate.is_cleared(
                    started_at,
                    str_field(&object, "timestamp").map(trim_whitespace),
                ) {
                    state.replay_gate = None;
                }
            }
            return Ok(());
        }
        if payload_type != Some("token_count") {
            return malformed_if_token_count(MALFORMED_TYPE);
        }
        let Some(timestamp_raw) = str_field(&object, "timestamp").map(trim_whitespace) else {
            return Err(MALFORMED_TIMESTAMP);
        };
        let Some(timestamp) = parse_iso8601(timestamp_raw) else {
            return Err(MALFORMED_TIMESTAMP);
        };

        // A rate-limit-only ping: `info` is explicitly null (OpenAI emits these while a turn is in
        // flight with no usage to report). Nothing to count, and not a reason to fail the file.
        let info = match payload.get("info") {
            Some(Value::Null) => return Ok(()),
            Some(Value::Object(info)) => info,
            _ => return Err(MALFORMED_INFO),
        };
        let totals = match info.get("total_token_usage") {
            None | Some(Value::Null) => None,
            Some(Value::Object(object)) => Some(
                Some(RawUsage::from_json(object))
                    .filter(|u| u.is_valid)
                    .ok_or(MALFORMED_USAGE)?,
            ),
            Some(_) => return Err(MALFORMED_USAGE),
        };
        let last = match info.get("last_token_usage") {
            None | Some(Value::Null) => None,
            Some(Value::Object(object)) => Some(
                Some(RawUsage::from_json(object))
                    .filter(|u| u.is_valid)
                    .ok_or(MALFORMED_USAGE)?,
            ),
            Some(_) => return Err(MALFORMED_USAGE),
        };
        let extend_baseline = |previous: Option<RawUsage>, last: &RawUsage| match previous {
            Some(previous) => previous.adding_as_baseline(last),
            None => last.as_baseline(),
        };

        if state.replay_gate.is_some() {
            // Replayed parent history: it only seeds the baseline later deltas are measured from.
            if let Some(totals) = totals {
                state.previous_totals = Some(totals);
            } else if let Some(last) = last {
                state.previous_totals = Some(extend_baseline(state.previous_totals, &last));
            }
            return Ok(());
        }
        if let (Some(totals), Some(previous)) = (&totals, &state.previous_totals) {
            if totals == previous {
                return Ok(());
            }
        }
        let usage = match (last, totals) {
            (Some(last), totals) => {
                if totals.is_none() {
                    state.previous_totals = Some(extend_baseline(state.previous_totals, &last));
                }
                last
            }
            (None, Some(totals)) => totals.subtracting(state.previous_totals.as_ref()),
            (None, None) => return Err(MALFORMED_USAGE),
        };
        if !usage.is_valid {
            return Err(MALFORMED_USAGE);
        }
        if totals.is_some() {
            state.previous_totals = totals;
        }
        if usage.input <= 0
            && usage.cached <= 0
            && usage.output <= 0
            && usage.reasoning <= 0
            && usage.total <= 0
        {
            return Ok(());
        }

        let parsed_model = match model_name_update(payload) {
            ModelNameUpdate::Value(model) => Some(model),
            ModelNameUpdate::Invalid => return Err(MALFORMED_MODEL),
            ModelNameUpdate::Absent => match model_name_update(info) {
                ModelNameUpdate::Value(model) => Some(model),
                ModelNameUpdate::Invalid => return Err(MALFORMED_MODEL),
                ModelNameUpdate::Absent => None,
            },
        };
        let model = resolve_model(parsed_model, &mut state.current_model);
        let pricing_model = (&*model == AUTO_REVIEW_MODEL || &*model == RESERVE_MODEL)
            .then(|| Arc::from(auto_review_fallback(timestamp_raw)));
        out.push(Event {
            timestamp,
            model,
            pricing_model,
            input: usage.input,
            cached: usage.cached,
            output: usage.output,
            reasoning: usage.reasoning,
            total: usage.total,
            has_complete_cost_breakdown: usage.has_complete_cost_breakdown
                && state.current_service_tier_is_valid,
            is_fast: state.current_tier_is_fast,
            service_tier: state.current_service_tier.clone(),
        });
        Ok(())
    }
}

/// Parse a whole rollout from memory, like Swift's `parseFile(_ data:)`: the events, or the first
/// line the file cannot be accounted for.
pub fn parse_rollout(data: &[u8]) -> Result<Vec<Event>, LineError> {
    let parser = CodexLineParser::default();
    let (mut state, mut events) = (RolloutState::default(), Vec::new());
    for line in data.split(|b| *b == b'\n').filter(|l| !l.is_empty()) {
        if parser.wants(line) {
            parser.parse(&mut state, line, &mut events)?;
        }
    }
    Ok(events)
}
