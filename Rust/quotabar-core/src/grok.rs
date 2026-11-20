//! Grok session parser — a line-for-line port of `GrokLogUsageScanner.parseFile(at:)` in
//! `Sources/QuotaBar/Providers/Grok/GrokLogUsageScanner.swift`, plus the whole-file FFI entry
//! point (`qb_grok_parse_file`) built on `crate::scanfile`.
//!
//! Lines come from `updates.jsonl` inside `$GROK_HOME/sessions/<id>/`. Most lines are noise; only
//! records containing the `turn_completed` marker carry usage. A completed turn yields one
//! `Entry` per key in `update.usage.modelUsage` (sorted by model name, matching Swift's
//! dictionary sort). Any `turn_completed` line that fails validation makes the whole file fail —
//! `parseFile(at:)` returns nil for it — so this module reports Failed rather than skipping.
//!
//! Fallback contract: a non-empty `timestamp` *string* that is not one of the canonical UTC
//! shapes in `crate::parse_canonical_utc` is legal Swift input (`OpenUsageISO8601` handles more
//! shapes) — the whole file falls back to the Swift parser rather than answering differently.

use serde_json::{Map, Value};

use crate::scanfile::{self, CancelCallback, QB_FILE_FAILED, QB_FILE_FALLBACK, QB_FILE_OK};
use crate::{intern, parse_canonical_utc, CanonicalTimestamp, NIL_STRING};
use std::os::raw::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;

#[repr(C)]
pub struct QbGrokEntry {
    /// Seconds since the Unix epoch.
    pub timestamp: f64,
    /// `carriedCost` in USD when `has_carried_cost != 0`, else 0.
    pub carried_cost: f64,
    pub input_tokens: u64,
    pub cache_write_5m: u64,
    pub cache_read: u64,
    pub output_tokens: u64,
    /// Offsets into the strings blob; `UINT32_MAX` when `eventID` is nil.
    pub event_id_offset: u32,
    pub event_id_length: u32,
    /// `model` is never nil in this format; a missing blob still fails bounds checks loudly.
    pub model_offset: u32,
    pub model_length: u32,
    pub has_carried_cost: u8,
    pub reserved: [u8; 7],
}

pub struct GrokFileResult {
    status: u32,
    entries: Vec<QbGrokEntry>,
    strings: Vec<u8>,
    bytes_read: u64,
    oversized_lines_skipped: u64,
}

/// Per-line result for the lenient `parseFile(_ data:)` surface, mirroring
/// `qb_claude_parse_usage_line`: `entries`/`irrelevant`/`malformed` so the Swift caller keeps
/// its own file-level rules.
pub struct GrokLineResult {
    malformed: u32,
    irrelevant: u32,
    entries: Vec<QbGrokEntry>,
    strings: Vec<u8>,
}

// ---------------------------------------------------------------------------
// Line parsing (mirror of GrokLogUsageScanner.parseLine / parseCompletedTurn)
// ---------------------------------------------------------------------------

const COMPLETED_TURN_MARKER: &[u8] = b"turn_completed";

enum GrokLine {
    Entries(Vec<EntryOut>),
    Irrelevant,
    Malformed,
    /// Legal Swift input outside the supported shapes — the file falls back to Swift.
    Fallback,
}

struct EntryOut {
    event_id: Option<String>,
    timestamp: f64,
    model: String,
    input: u64,
    cache_write_5m: u64,
    cache_read: u64,
    output: u64,
    carried_cost: Option<f64>,
}

/// Mirror of `strictCount`: a JSON number (never a bool), finite, in [0, 1e15], integral.
/// An absent key is allowed only when `required` is false and counts as zero — but a present
/// JSON null is NOT absent: `NSNull` fails Swift's `as? NSNumber`, so null is malformed for
/// required and optional fields alike.
fn strict_count(raw: Option<&Value>, required: bool) -> Option<u64> {
    let v = match raw {
        None => return if required { None } else { Some(0) },
        Some(v) => v,
    };
    let f = v.as_f64()?;
    if !f.is_finite() || f < 0.0 || f > 1e15 || f.fract() != 0.0 {
        return None;
    }
    Some(f as u64)
}

/// Mirror of `validTicks`: a JSON number (never a bool), finite, in [0, 1e22], integral.
/// Unlike `strict_count`, a present-but-invalid value fails the line.
fn valid_ticks(raw: &Value) -> Option<f64> {
    let f = raw.as_f64()?;
    if !f.is_finite() || f < 0.0 || f > 1e22 || f.fract() != 0.0 {
        return None;
    }
    Some(f)
}

enum Timestamp {
    Ok(f64),
    /// `params`/`_meta`/`agentTimestampMs` shape violations, or a genuinely absent timestamp —
    /// the line is malformed in Swift too.
    Malformed,
    /// A string timestamp outside the canonical UTC shapes — Swift's `OpenUsageISO8601` may
    /// still parse it, so the file falls back.
    Fallback,
}

/// Mirror of `timestamp(in:params:)`: `_meta.agentTimestampMs` (params first, then object),
/// then a numeric `timestamp` in seconds, then a string `timestamp`.
fn timestamp(object: &Map<String, Value>, params: Option<&Map<String, Value>>) -> Timestamp {
    for raw_metadata in [params.and_then(|p| p.get("_meta")), object.get("_meta")] {
        let Some(raw) = raw_metadata else { continue };
        if raw.is_null() {
            continue;
        }
        let Some(values) = raw.as_object() else {
            return Timestamp::Malformed;
        };
        if let Some(raw_ms) = values.get("agentTimestampMs") {
            return match strict_count(Some(raw_ms), true) {
                Some(ms) if ms > 0 => Timestamp::Ok(ms as f64 / 1_000.0),
                _ => Timestamp::Malformed,
            };
        }
    }

    if let Some(raw) = object.get("timestamp") {
        match raw {
            Value::Number(_) => {
                let Some(seconds) = raw.as_f64() else {
                    return Timestamp::Malformed;
                };
                if !seconds.is_finite() || seconds <= 0.0 || seconds > 1e12 {
                    return Timestamp::Malformed;
                }
                return Timestamp::Ok(seconds);
            }
            Value::String(s) => {
                return match parse_canonical_utc(s.as_bytes()) {
                    CanonicalTimestamp::Ok(t) => Timestamp::Ok(t),
                    CanonicalTimestamp::Invalid => Timestamp::Malformed,
                    CanonicalTimestamp::NotCanonical => Timestamp::Fallback,
                };
            }
            _ => {}
        }
    }
    Timestamp::Malformed
}

fn parse_completed_turn(
    object: &Map<String, Value>,
    params: Option<&Map<String, Value>>,
    update: &Map<String, Value>,
) -> Result<Vec<EntryOut>, GrokLine> {
    let usage = match update.get("usage").and_then(Value::as_object) {
        Some(u) => u,
        None => return Err(GrokLine::Malformed),
    };
    let model_usage = match usage.get("modelUsage").and_then(Value::as_object) {
        Some(m) => m,
        None => return Err(GrokLine::Malformed),
    };
    let timestamp = match timestamp(object, params) {
        Timestamp::Ok(t) => t,
        Timestamp::Malformed => return Err(GrokLine::Malformed),
        Timestamp::Fallback => return Err(GrokLine::Fallback),
    };

    // `params?._meta ?? object._meta`: the first present raw value; anything that is neither
    // null nor an object fails the line.
    let raw_meta = params
        .and_then(|p| p.get("_meta"))
        .or_else(|| object.get("_meta"));
    if let Some(raw) = raw_meta {
        if !raw.is_null() && !raw.is_object() {
            return Err(GrokLine::Malformed);
        }
    }
    let metadata = params
        .and_then(|p| p.get("_meta"))
        .and_then(Value::as_object)
        .or_else(|| object.get("_meta").and_then(Value::as_object));

    let mut event_id: Option<String> = None;
    if let Some(raw_id) = metadata.and_then(|m| m.get("eventId")) {
        if !raw_id.is_null() {
            match raw_id.as_str().map(str::trim) {
                Some(text) if !text.is_empty() => event_id = Some(text.to_string()),
                _ => return Err(GrokLine::Malformed),
            }
        }
    }

    let top_level_ticks = match usage.get("costUsdTicks") {
        None | Some(Value::Null) => None,
        Some(raw) => match valid_ticks(raw) {
            Some(t) => Some(t),
            None => return Err(GrokLine::Malformed),
        },
    };

    // Swift sorts modelUsage by key so entry order is deterministic.
    let mut pairs: Vec<(&String, &Value)> = model_usage.iter().collect();
    pairs.sort_by(|a, b| a.0.cmp(b.0));

    let mut entries = Vec::with_capacity(pairs.len());
    for (raw_model, raw_usage) in pairs {
        let model = raw_model.trim();
        let values = raw_usage.as_object();
        let (input, output, cache_read, cache_write) = match values {
            Some(values) => (
                strict_count(values.get("inputTokens"), true),
                strict_count(values.get("outputTokens"), true),
                strict_count(values.get("cachedReadTokens"), false),
                strict_count(values.get("cacheCreationTokens"), false),
            ),
            None => (None, None, None, None),
        };
        let (Some(input), Some(output), Some(cache_read), Some(cache_write)) =
            (input, output, cache_read, cache_write)
        else {
            return Err(GrokLine::Malformed);
        };
        if model.is_empty() || cache_read > input || cache_write > input - cache_read {
            return Err(GrokLine::Malformed);
        }

        // Grok reports reasoning as a subset of outputTokens, so it must never be added again.
        let ticks = match values.and_then(|v| v.get("costUsdTicks")) {
            Some(raw) if !raw.is_null() => match valid_ticks(raw) {
                Some(t) => Some(t),
                None => return Err(GrokLine::Malformed),
            },
            _ => {
                if model_usage.len() == 1 {
                    top_level_ticks
                } else {
                    None
                }
            }
        };
        let carried_cost = ticks.map(|t| t / 10_000_000_000.0);

        entries.push(EntryOut {
            event_id: event_id.clone(),
            timestamp,
            model: model.to_string(),
            input: input - cache_read - cache_write,
            cache_write_5m: cache_write,
            cache_read,
            output,
            carried_cost,
        });
    }
    Ok(entries)
}

fn parse_line(line: &[u8]) -> GrokLine {
    if memchr::memmem::find(line, COMPLETED_TURN_MARKER).is_none() {
        return GrokLine::Irrelevant;
    }
    let value: Value = match serde_json::from_slice(line) {
        Ok(v) => v,
        Err(_) => return GrokLine::Malformed,
    };
    let object = match value.as_object() {
        Some(o) => o,
        None => return GrokLine::Malformed,
    };
    let params = object.get("params").and_then(Value::as_object);
    let update = params
        .and_then(|p| p.get("update"))
        .and_then(Value::as_object)
        .or_else(|| object.get("update").and_then(Value::as_object));
    let Some(update) = update else {
        return GrokLine::Irrelevant;
    };
    let Some(session_update) = update.get("sessionUpdate").and_then(Value::as_str) else {
        return GrokLine::Irrelevant;
    };
    if session_update != "turn_completed" {
        return GrokLine::Irrelevant;
    }
    match parse_completed_turn(object, params, update) {
        // More models per turn than fit the fixed FFI array — the Swift path has no bound.
        Ok(entries) if entries.len() > crate::MAX_ENTRIES_PER_LINE => GrokLine::Fallback,
        Ok(entries) => GrokLine::Entries(entries),
        Err(outcome) => outcome,
    }
}

// ---------------------------------------------------------------------------
// Whole-file driver + C ABI
// ---------------------------------------------------------------------------

struct FileParser {
    entries: Vec<EntryOut>,
    malformed: bool,
    fell_back: bool,
}

impl FileParser {
    /// `deliver` callback for `scan_file_lines`. Returning false aborts the scan early — used
    /// only for the whole-file fallback signal, never for ordinary malformed rows (a malformed
    /// `turn_completed` still fails the file, matching Swift's nil).
    fn consume(&mut self, line: &[u8]) -> bool {
        match parse_line(line) {
            GrokLine::Entries(mut parsed) => {
                self.entries.append(&mut parsed);
                true
            }
            GrokLine::Irrelevant => true,
            GrokLine::Malformed => {
                self.malformed = true;
                true
            }
            GrokLine::Fallback => {
                self.fell_back = true;
                false
            }
        }
    }
}

/// Run the Grok parser over one file. `end_offset` of `u64::MAX` reads to EOF. Returns the
/// status plus the packed entries/strings; never partially succeeds — a `Failed` status means
/// the caller returns nil for the file exactly as the Swift `parseFile(at:)` does.
fn parse_file_impl(
    path: &[u8],
    start_offset: u64,
    end_offset: Option<u64>,
    cancel_ctx: *mut c_void,
    cancel: Option<CancelCallback>,
) -> GrokFileResult {
    let mut parser = FileParser {
        entries: Vec::new(),
        malformed: false,
        fell_back: false,
    };
    let stats = scanfile::scan_file_lines(
        path,
        start_offset,
        end_offset,
        true,
        false,
        cancel_ctx,
        cancel,
        scanfile::MAX_LINE_BYTES,
        &mut |line, _is_final_partial| parser.consume(line),
    );

    if parser.fell_back {
        return GrokFileResult {
            status: QB_FILE_FALLBACK,
            entries: Vec::new(),
            strings: Vec::new(),
            bytes_read: stats.bytes_read,
            oversized_lines_skipped: stats.oversized_lines_skipped,
        };
    }
    // Mirror `forEachLine(...)` = `readLines(...).isComplete`: read success, no oversized lines,
    // not left discarding — then the file's own malformed rule applies.
    let complete = stats.succeeded
        && stats.oversized_lines_skipped == 0
        && !stats.is_discarding_oversized_line;
    if !complete || parser.malformed {
        return GrokFileResult {
            status: QB_FILE_FAILED,
            entries: Vec::new(),
            strings: Vec::new(),
            bytes_read: stats.bytes_read,
            oversized_lines_skipped: stats.oversized_lines_skipped,
        };
    }

    let Some((entries, strings)) = pack_entries(&parser.entries) else {
        return GrokFileResult {
            status: QB_FILE_FALLBACK,
            entries: Vec::new(),
            strings: Vec::new(),
            bytes_read: stats.bytes_read,
            oversized_lines_skipped: stats.oversized_lines_skipped,
        };
    };
    GrokFileResult {
        status: QB_FILE_OK,
        entries,
        strings,
        bytes_read: stats.bytes_read,
        oversized_lines_skipped: stats.oversized_lines_skipped,
    }
}

/// Intern every string field of `entries` into one UTF-8 blob and produce the `#[repr(C)]`
/// array. `None` means a blob offset overflowed u32 — the caller treats it as fallback.
fn pack_entries(entries: &[EntryOut]) -> Option<(Vec<QbGrokEntry>, Vec<u8>)> {
    let mut strings: Vec<u8> = Vec::new();
    let mut out: Vec<QbGrokEntry> = Vec::with_capacity(entries.len());
    for entry in entries {
        let (event_id_offset, event_id_length) = match &entry.event_id {
            Some(s) => intern(&mut strings, s)?,
            None => (NIL_STRING, 0),
        };
        let (model_offset, model_length) = intern(&mut strings, &entry.model)?;
        out.push(QbGrokEntry {
            timestamp: entry.timestamp,
            carried_cost: entry.carried_cost.unwrap_or(0.0),
            input_tokens: entry.input,
            cache_write_5m: entry.cache_write_5m,
            cache_read: entry.cache_read,
            output_tokens: entry.output,
            event_id_offset,
            event_id_length,
            model_offset,
            model_length,
            has_carried_cost: u8::from(entry.carried_cost.is_some()),
            reserved: [0; 7],
        });
    }
    Some((out, strings))
}

/// Parse one Grok usage line, mirroring `qb_claude_parse_usage_line`.
///
/// Returns a heap-allocated result the caller must pass to [`qb_grok_line_result_destroy`], or a
/// null pointer when the line is legal input this module does not support (non-canonical string
/// timestamp, oversized entry fan-out) — the caller falls back to the Swift reference.
#[no_mangle]
pub extern "C" fn qb_grok_parse_line(line: *const u8, line_len: usize) -> *mut GrokLineResult {
    if line.is_null() && line_len > 0 {
        return ptr::null_mut();
    }
    let bytes = if line.is_null() {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(line, line_len) }
    };
    match catch_unwind(AssertUnwindSafe(|| {
        let (entries, irrelevant, malformed) = match parse_line(bytes) {
            GrokLine::Entries(e) => (e, 0u32, 0u32),
            GrokLine::Irrelevant => (Vec::new(), 1u32, 0u32),
            GrokLine::Malformed => (Vec::new(), 0u32, 1u32),
            GrokLine::Fallback => return ptr::null_mut(),
        };
        match pack_entries(&entries) {
            Some((entries, strings)) => Box::into_raw(Box::new(GrokLineResult {
                malformed,
                irrelevant,
                entries,
                strings,
            })),
            None => ptr::null_mut(),
        }
    })) {
        Ok(ptr) => ptr,
        Err(_) => ptr::null_mut(),
    }
}

/// Nonzero when the line carried a `turn_completed` marker but failed validation.
#[no_mangle]
pub extern "C" fn qb_grok_line_result_malformed(result: *const GrokLineResult) -> u32 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.malformed
}

/// Nonzero when the line was skipped without parsing (no marker, not a completed turn).
#[no_mangle]
pub extern "C" fn qb_grok_line_result_irrelevant(result: *const GrokLineResult) -> u32 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.irrelevant
}

#[no_mangle]
pub extern "C" fn qb_grok_line_result_entry_count(result: *const GrokLineResult) -> u32 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.entries.len() as u32
}

/// Pointer to the entry array; valid until [`qb_grok_line_result_destroy`].
#[no_mangle]
pub extern "C" fn qb_grok_line_result_entries(result: *const GrokLineResult) -> *const QbGrokEntry {
    if result.is_null() {
        return ptr::null();
    }
    unsafe { &*result }.entries.as_ptr()
}

/// Pointer to the UTF-8 string blob the entry offsets index into, plus its byte length.
#[no_mangle]
pub extern "C" fn qb_grok_line_result_strings(
    result: *const GrokLineResult,
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
/// `result` must be a pointer returned by [`qb_grok_parse_line`], destroyed at most once.
#[no_mangle]
pub unsafe extern "C" fn qb_grok_line_result_destroy(result: *mut GrokLineResult) {
    if result.is_null() {
        return;
    }
    unsafe { drop(Box::from_raw(result)) };
}

/// Parse one Grok `updates.jsonl` file end to end.
///
/// `path` is a NUL-terminated UTF-8 path. `end_offset` of `UINT64_MAX` reads to EOF. `cancel` is
/// invoked once per 64 KiB chunk. Returns a heap-allocated result (never NULL for a completed
/// call) or NULL only on internal failure — a NULL must be treated like `FALLBACK`.
#[no_mangle]
pub extern "C" fn qb_grok_parse_file(
    path: *const u8,
    path_len: usize,
    start_offset: u64,
    end_offset: u64,
    cancel: Option<extern "C" fn(*mut c_void) -> u8>,
    cancel_ctx: *mut c_void,
) -> *mut GrokFileResult {
    if path.is_null() {
        return ptr::null_mut();
    }
    let path = unsafe { std::slice::from_raw_parts(path, path_len) };
    let end = if end_offset == u64::MAX {
        None
    } else {
        Some(end_offset)
    };
    match catch_unwind(AssertUnwindSafe(|| {
        Box::into_raw(Box::new(parse_file_impl(
            path,
            start_offset,
            end,
            cancel_ctx,
            cancel,
        )))
    })) {
        Ok(ptr) => ptr,
        Err(_) => ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn qb_grok_file_result_status(result: *const GrokFileResult) -> u32 {
    if result.is_null() {
        return QB_FILE_FALLBACK;
    }
    unsafe { &*result }.status
}

#[no_mangle]
pub extern "C" fn qb_grok_file_result_entry_count(result: *const GrokFileResult) -> u32 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.entries.len() as u32
}

/// Pointer to the entry array; valid until [`qb_grok_file_result_destroy`].
#[no_mangle]
pub extern "C" fn qb_grok_file_result_entries(result: *const GrokFileResult) -> *const QbGrokEntry {
    if result.is_null() {
        return ptr::null();
    }
    unsafe { &*result }.entries.as_ptr()
}

/// Pointer to the UTF-8 string blob the entry offsets index into, plus its byte length.
#[no_mangle]
pub extern "C" fn qb_grok_file_result_strings(
    result: *const GrokFileResult,
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

#[no_mangle]
pub extern "C" fn qb_grok_file_result_bytes_read(result: *const GrokFileResult) -> u64 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.bytes_read
}

#[no_mangle]
pub extern "C" fn qb_grok_file_result_oversized_lines(result: *const GrokFileResult) -> u64 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.oversized_lines_skipped
}

/// # Safety
/// `result` must be a pointer returned by [`qb_grok_parse_file`], destroyed at most once.
#[no_mangle]
pub unsafe extern "C" fn qb_grok_file_result_destroy(result: *mut GrokFileResult) {
    if result.is_null() {
        return;
    }
    unsafe { drop(Box::from_raw(result)) };
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(line: &str) -> GrokLine {
        parse_line(line.as_bytes())
    }

    fn completed(usage: &str) -> String {
        // Numeric `timestamp` is seconds per the Swift contract; milliseconds travel in
        // `_meta.agentTimestampMs` instead.
        format!(
            r#"{{"timestamp":1771588800,"params":{{"update":{{"sessionUpdate":"turn_completed","usage":{usage}}}}}}}"#
        )
    }

    #[test]
    fn irrelevant_lines_skip_without_marker() {
        assert!(matches!(parse("{}"), GrokLine::Irrelevant));
        // Marker text present, valid object, but no `update` → irrelevant (not malformed).
        assert!(matches!(
            parse(r#"{"sessionUpdate":"turn_completed"}"#),
            GrokLine::Irrelevant
        ));
    }

    #[test]
    fn marker_gate_short_circuits_non_completed_lines() {
        // No "turn_completed" anywhere → irrelevant even though it is valid JSON.
        assert!(matches!(
            parse(r#"{"params":{"update":{"sessionUpdate":"user_message"}}}"#),
            GrokLine::Irrelevant
        ));
    }

    #[test]
    fn marker_present_but_other_update_is_irrelevant() {
        let line = r#"{"timestamp":1771588800000,"params":{"update":{"sessionUpdate":"turn_completed_x"}}}"#;
        assert!(matches!(parse(line), GrokLine::Irrelevant));
    }

    #[test]
    fn completed_turn_yields_sorted_model_entries() {
        let line = completed(
            r#"{"modelUsage":{"grok-b":{"inputTokens":10,"outputTokens":5},"grok-a":{"inputTokens":100,"outputTokens":50,"cachedReadTokens":30,"cacheCreationTokens":20,"costUsdTicks":25000000000}}}"#,
        );
        match parse(&line) {
            GrokLine::Entries(entries) => {
                assert_eq!(entries.len(), 2);
                assert_eq!(entries[0].model, "grok-a");
                assert_eq!(entries[0].input, 100 - 30 - 20);
                assert_eq!(entries[0].cache_read, 30);
                assert_eq!(entries[0].cache_write_5m, 20);
                assert_eq!(entries[0].carried_cost, Some(2.5));
                assert_eq!(entries[1].model, "grok-b");
                assert_eq!(entries[1].carried_cost, None);
            }
            other => panic!(
                "expected entries, got {:?}",
                matches!(other, GrokLine::Malformed)
            ),
        }
    }

    #[test]
    fn single_model_inherits_top_level_ticks() {
        let line = completed(
            r#"{"costUsdTicks":40000000000,"modelUsage":{"grok":{"inputTokens":10,"outputTokens":5}}}"#,
        );
        match parse(&line) {
            GrokLine::Entries(entries) => {
                assert_eq!(entries[0].carried_cost, Some(4.0));
            }
            _ => panic!("expected entries"),
        }
    }

    #[test]
    fn multi_model_does_not_inherit_top_level_ticks() {
        let line = completed(
            r#"{"costUsdTicks":40000000000,"modelUsage":{"a":{"inputTokens":1,"outputTokens":1},"b":{"inputTokens":1,"outputTokens":1}}}"#,
        );
        match parse(&line) {
            GrokLine::Entries(entries) => {
                assert!(entries.iter().all(|e| e.carried_cost.is_none()));
            }
            _ => panic!("expected entries"),
        }
    }

    #[test]
    fn cache_invariants_enforced() {
        // cacheRead > input → malformed
        let line = completed(
            r#"{"modelUsage":{"m":{"inputTokens":10,"outputTokens":5,"cachedReadTokens":11}}}"#,
        );
        assert!(matches!(parse(&line), GrokLine::Malformed));
        // cacheWrite > input - cacheRead → malformed
        let line = completed(
            r#"{"modelUsage":{"m":{"inputTokens":10,"outputTokens":5,"cachedReadTokens":6,"cacheCreationTokens":5}}}"#,
        );
        assert!(matches!(parse(&line), GrokLine::Malformed));
        // cacheWrite == input - cacheRead → ok
        let line = completed(
            r#"{"modelUsage":{"m":{"inputTokens":10,"outputTokens":5,"cachedReadTokens":6,"cacheCreationTokens":4}}}"#,
        );
        assert!(matches!(parse(&line), GrokLine::Entries(_)));
    }

    #[test]
    fn event_id_must_be_nonempty_trimmed_string() {
        let base = r#"{"timestamp":1771588800,"params":{"_meta":{"eventId":"  e-1  "},"update":{"sessionUpdate":"turn_completed","usage":{"modelUsage":{"m":{"inputTokens":1,"outputTokens":1}}}}}}"#;
        match parse(base) {
            GrokLine::Entries(entries) => assert_eq!(entries[0].event_id.as_deref(), Some("e-1")),
            _ => panic!("expected entries"),
        }
        let blank = r#"{"timestamp":1771588800,"params":{"_meta":{"eventId":"   "},"update":{"sessionUpdate":"turn_completed","usage":{"modelUsage":{"m":{"inputTokens":1,"outputTokens":1}}}}}}"#;
        assert!(matches!(parse(blank), GrokLine::Malformed));
        let numeric = r#"{"timestamp":1771588800,"params":{"_meta":{"eventId":5},"update":{"sessionUpdate":"turn_completed","usage":{"modelUsage":{"m":{"inputTokens":1,"outputTokens":1}}}}}}"#;
        assert!(matches!(parse(numeric), GrokLine::Malformed));
        let scalar_meta = r#"{"timestamp":1771588800,"params":{"_meta":7,"update":{"sessionUpdate":"turn_completed","usage":{"modelUsage":{"m":{"inputTokens":1,"outputTokens":1}}}}}}"#;
        assert!(matches!(parse(scalar_meta), GrokLine::Malformed));
    }

    #[test]
    fn timestamp_precedence_and_shapes() {
        // agentTimestampMs wins over numeric timestamp (params _meta before object _meta).
        let line = r#"{"timestamp":111,"params":{"_meta":{"agentTimestampMs":1771588800123},"update":{"sessionUpdate":"turn_completed","usage":{"modelUsage":{"m":{"inputTokens":1,"outputTokens":1}}}}}}"#;
        match parse(line) {
            GrokLine::Entries(entries) => assert_eq!(entries[0].timestamp, 1_771_588_800.123),
            _ => panic!("expected entries"),
        }
        // Numeric seconds.
        match parse(&completed(
            r#"{"modelUsage":{"m":{"inputTokens":1,"outputTokens":1}}}"#,
        )) {
            GrokLine::Entries(entries) => assert_eq!(entries[0].timestamp, 1_771_588_800.0),
            _ => panic!("expected entries"),
        }
        // Canonical string.
        let line = r#"{"timestamp":"2026-02-20T12:00:00.000Z","params":{"update":{"sessionUpdate":"turn_completed","usage":{"modelUsage":{"m":{"inputTokens":1,"outputTokens":1}}}}}}"#;
        match parse(line) {
            GrokLine::Entries(entries) => assert_eq!(entries[0].timestamp, 1_771_588_800.0),
            _ => panic!("expected entries"),
        }
        // Non-canonical string → fallback.
        let line = r#"{"timestamp":"2026-02-20 12:00:00","params":{"update":{"sessionUpdate":"turn_completed","usage":{"modelUsage":{"m":{"inputTokens":1,"outputTokens":1}}}}}}"#;
        assert!(matches!(parse(line), GrokLine::Fallback));
        // Missing everything → malformed.
        let line = r#"{"params":{"update":{"sessionUpdate":"turn_completed","usage":{"modelUsage":{"m":{"inputTokens":1,"outputTokens":1}}}}}}"#;
        assert!(matches!(parse(line), GrokLine::Malformed));
        // Bool timestamp is not a number.
        let line = r#"{"timestamp":true,"params":{"update":{"sessionUpdate":"turn_completed","usage":{"modelUsage":{"m":{"inputTokens":1,"outputTokens":1}}}}}}"#;
        assert!(matches!(parse(line), GrokLine::Malformed));
    }

    #[test]
    fn strict_count_rules() {
        // fractional, bool, negative, >1e15, string → malformed.
        for raw in [
            r#"{"inputTokens":1.5,"outputTokens":1}"#,
            r#"{"inputTokens":true,"outputTokens":1}"#,
            r#"{"inputTokens":-1,"outputTokens":1}"#,
            r#"{"inputTokens":1e16,"outputTokens":1}"#,
            r#"{"inputTokens":"5","outputTokens":1}"#,
        ] {
            let line = completed(&format!(r#"{{"modelUsage":{{"m":{raw}}}}}"#));
            assert!(matches!(parse(&line), GrokLine::Malformed), "{raw}");
        }
    }

    #[test]
    fn missing_usage_or_model_usage_is_malformed() {
        // `update.usage` absent.
        assert!(matches!(parse(&completed("{}")), GrokLine::Malformed));
        // `update.usage.modelUsage` absent.
        assert!(matches!(
            parse(&completed(r#"{"usage":{}}"#)),
            GrokLine::Malformed
        ));
        // `usage` non-object.
        assert!(matches!(
            parse(&completed(r#"{"usage":7}"#)),
            GrokLine::Malformed
        ));
    }
}
