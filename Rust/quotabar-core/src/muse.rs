//! Muse session parser — a line-for-line port of `MuseUsageScanner.parseFile(at:)` in
//! `Sources/QuotaBar/Providers/Muse/MuseUsageScanner.swift`, plus the whole-file FFI entry
//! point (`qb_muse_parse_file`) built on `crate::scanfile`.
//!
//! Lines come from `session.jsonl` under `~/.local/share/muse/sessions/**/`. Most lines are
//! noise; only `payload.event` records with `kind == "goal_usage_attribution"`, `reported ==
//! true`, and `unit == "tokens"` carry billed usage. Each such line yields one `Entry`. Any
//! malformed attribution line fails the whole file — `parseFile(at:)` returns nil for it — so
//! this module reports Failed rather than skipping.
//!
//! Fallback contract: `recorded_at` is an integer of microseconds on every line shape this
//! format accepts — there is no string timestamp variant for Foundation to rescue — so the
//! parser never declines a line for content reasons. A null FFI result means only internal
//! failure (panic, blob overflow), which the caller treats as fallback like the other bridges.

use serde_json::Value;

use crate::intern;
use crate::scanfile::{self, CancelCallback};
use std::os::raw::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;

/// `qb_muse_file_result_status`: the file parsed; entries are valid.
pub const QB_MUSE_FILE_OK: u32 = 0;
/// Internal failure the Swift caller re-runs its reference parser for — never a different
/// answer. Content-wise this module declines nothing (see the module doc).
pub const QB_MUSE_FILE_FALLBACK: u32 = 1;
/// Read error, cancellation, oversized line, or a malformed attribution record — the same
/// conditions under which the Swift `parseFile(at:)` returns nil.
pub const QB_MUSE_FILE_FAILED: u32 = 2;

#[repr(C)]
pub struct QbMuseEntry {
    /// Seconds since the Unix epoch (`recorded_at` is microseconds in the log).
    pub timestamp: f64,
    /// `input_tokens` minus the cached prefix-hit portion.
    pub input_tokens: u64,
    /// The cached (prefix-hit) portion of `input_tokens`.
    pub cache_read: u64,
    /// `output_tokens` plus `reasoning_tokens`, saturating.
    pub output_tokens: u64,
    /// Offsets into the strings blob; `model` is never nil in this format.
    pub model_offset: u32,
    pub model_length: u32,
}

pub struct MuseFileResult {
    status: u32,
    entries: Vec<QbMuseEntry>,
    strings: Vec<u8>,
    bytes_read: u64,
    oversized_lines_skipped: u64,
}

/// Per-line result for the lenient `parseFile(_ data:)` surface, mirroring
/// `qb_claude_parse_usage_line`: `entries`/`irrelevant`/`malformed` so the Swift caller keeps
/// its own file-level rules.
pub struct MuseLineResult {
    malformed: u32,
    irrelevant: u32,
    entries: Vec<QbMuseEntry>,
    strings: Vec<u8>,
}

// ---------------------------------------------------------------------------
// Line parsing (mirror of MuseUsageScanner.parseLineResult)
// ---------------------------------------------------------------------------

/// Byte prefilter — the same quoted marker `MuseUsageScanner.marker` searches for. Lines
/// without it are skipped before JSON parsing, exactly like the Swift `range(of:)`.
const ATTRIBUTION_MARKER: &[u8] = b"\"goal_usage_attribution\"";

/// Emitted when neither `record.model` nor `quantity.model` trims to a nonempty string.
const DEFAULT_MODEL: &str = "muse-spark-1.2-contributor";

enum MuseLine {
    Entry(EntryOut),
    Irrelevant,
    Malformed,
}

struct EntryOut {
    timestamp: f64,
    model: String,
    input: u64,
    cache_read: u64,
    output: u64,
}

/// Mirror of `strictBoolean`: only a real JSON bool qualifies — `1` and `"true"` fail exactly
/// like a non-CFBoolean NSNumber does in Swift.
fn strict_boolean(raw: Option<&Value>) -> Option<bool> {
    match raw {
        Some(Value::Bool(b)) => Some(*b),
        _ => None,
    }
}

/// Mirror of `exactInteger`: a JSON number (never a bool — `Value::Bool` reads no `as_f64`),
/// finite, in `[0, maximum]`, integral.
fn exact_integer(v: &Value, maximum: f64) -> Option<u64> {
    let f = v.as_f64()?;
    if !f.is_finite() || f < 0.0 || f > maximum || f.fract() != 0.0 {
        return None;
    }
    Some(f as u64)
}

/// Mirror of `tokenCount`: absent is allowed only when `required` is false (and counts as
/// zero) — but a present JSON null is NOT absent: `NSNull` fails Swift's `as? NSNumber`, so
/// null is malformed for required and optional fields alike.
fn token_count(raw: Option<&Value>, required: bool) -> Option<u64> {
    let v = match raw {
        None => return if required { None } else { Some(0) },
        Some(v) => v,
    };
    exact_integer(v, 1e15)
}

fn parse_line(line: &[u8]) -> MuseLine {
    if memchr::memmem::find(line, ATTRIBUTION_MARKER).is_none() {
        return MuseLine::Irrelevant;
    }
    let value: Value = match serde_json::from_slice(line) {
        Ok(v) => v,
        Err(_) => return MuseLine::Malformed,
    };
    let object = match value.as_object() {
        Some(o) => o,
        None => return MuseLine::Malformed,
    };
    // The marker can appear inside quoted user text. Only a decoded event with the actual
    // attribution kind is a candidate; every failure to reach it — missing or non-dict
    // `payload`/`event`, missing or non-string `kind`, a different kind — is irrelevant.
    let Some(payload) = object.get("payload").and_then(Value::as_object) else {
        return MuseLine::Irrelevant;
    };
    let Some(event) = payload.get("event").and_then(Value::as_object) else {
        return MuseLine::Irrelevant;
    };
    if event.get("kind").and_then(Value::as_str) != Some("goal_usage_attribution") {
        return MuseLine::Irrelevant;
    }

    // A claimed attribution line that cannot produce a quantity record is malformed.
    let Some(record) = event.get("record").and_then(Value::as_object) else {
        return MuseLine::Malformed;
    };
    let Some(quantity) = record.get("quantity").and_then(Value::as_object) else {
        return MuseLine::Malformed;
    };
    let Some(reported) = strict_boolean(quantity.get("reported")) else {
        return MuseLine::Malformed;
    };
    let Some(unit) = quantity.get("unit").and_then(Value::as_str) else {
        return MuseLine::Malformed;
    };
    if !reported || unit != "tokens" {
        return MuseLine::Irrelevant;
    }

    // Input is the total; cached is the prefix-hit portion inside it.
    let (Some(input), Some(output), Some(cached), Some(reasoning)) = (
        token_count(quantity.get("input_tokens"), true),
        token_count(quantity.get("output_tokens"), true),
        token_count(quantity.get("cached_tokens"), false),
        token_count(quantity.get("reasoning_tokens"), false),
    ) else {
        return MuseLine::Malformed;
    };
    if cached > input {
        return MuseLine::Malformed;
    }

    // The durable timestamp is `recorded_at` in microseconds since the epoch; a missing or
    // invalid value makes the file incomplete, so the line is malformed.
    let micros = match object
        .get("recorded_at")
        .and_then(|v| exact_integer(v, 9e15))
    {
        Some(micros) if micros > 0 => micros,
        _ => return MuseLine::Malformed,
    };

    // `model` is optional at both sites, but a present non-string (NSNull included) is
    // malformed.
    for dict in [record, quantity] {
        if let Some(raw) = dict.get("model") {
            if !raw.is_string() {
                return MuseLine::Malformed;
            }
        }
    }
    let model = [record, quantity]
        .into_iter()
        .filter_map(|dict| dict.get("model").and_then(Value::as_str))
        .map(str::trim)
        .find(|s| !s.is_empty())
        .unwrap_or(DEFAULT_MODEL);

    // Zero-token attributions are bookkeeping placeholders — skipped, not malformed.
    let total = input.saturating_add(output).saturating_add(reasoning);
    if total == 0 {
        return MuseLine::Irrelevant;
    }

    MuseLine::Entry(EntryOut {
        timestamp: micros as f64 / 1_000_000.0,
        model: model.to_string(),
        input: input - cached,
        cache_read: cached,
        output: output.saturating_add(reasoning),
    })
}

// ---------------------------------------------------------------------------
// Whole-file driver + C ABI
// ---------------------------------------------------------------------------

struct FileParser {
    entries: Vec<EntryOut>,
    malformed: bool,
}

impl FileParser {
    /// `deliver` callback for `scan_file_lines`. Never aborts early — irrelevant lines are
    /// skipped and a malformed attribution still fails the file, matching Swift's nil.
    fn consume(&mut self, line: &[u8]) -> bool {
        match parse_line(line) {
            MuseLine::Entry(entry) => {
                self.entries.push(entry);
                true
            }
            MuseLine::Irrelevant => true,
            MuseLine::Malformed => {
                self.malformed = true;
                true
            }
        }
    }
}

/// Run the Muse parser over one file. `end_offset` of `u64::MAX` reads to EOF. Returns the
/// status plus the packed entries/strings; never partially succeeds — a `Failed` status means
/// the caller returns nil for the file exactly as the Swift `parseFile(at:)` does.
fn parse_file_impl(
    path: &[u8],
    start_offset: u64,
    end_offset: Option<u64>,
    cancel_ctx: *mut c_void,
    cancel: Option<CancelCallback>,
) -> MuseFileResult {
    let mut parser = FileParser {
        entries: Vec::new(),
        malformed: false,
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

    // Mirror `forEachLine(...)` = `readLines(...).isComplete`: read success, no oversized
    // lines, not left discarding — then the file's own malformed rule applies.
    let complete = stats.succeeded
        && stats.oversized_lines_skipped == 0
        && !stats.is_discarding_oversized_line;
    if !complete || parser.malformed {
        return MuseFileResult {
            status: QB_MUSE_FILE_FAILED,
            entries: Vec::new(),
            strings: Vec::new(),
            bytes_read: stats.bytes_read,
            oversized_lines_skipped: stats.oversized_lines_skipped,
        };
    }

    let Some((entries, strings)) = pack_entries(&parser.entries) else {
        return MuseFileResult {
            status: QB_MUSE_FILE_FALLBACK,
            entries: Vec::new(),
            strings: Vec::new(),
            bytes_read: stats.bytes_read,
            oversized_lines_skipped: stats.oversized_lines_skipped,
        };
    };
    MuseFileResult {
        status: QB_MUSE_FILE_OK,
        entries,
        strings,
        bytes_read: stats.bytes_read,
        oversized_lines_skipped: stats.oversized_lines_skipped,
    }
}

/// Intern every string field of `entries` into one UTF-8 blob and produce the `#[repr(C)]`
/// array. `None` means a blob offset overflowed u32 — the caller treats it as fallback.
fn pack_entries(entries: &[EntryOut]) -> Option<(Vec<QbMuseEntry>, Vec<u8>)> {
    let mut strings: Vec<u8> = Vec::new();
    let mut out: Vec<QbMuseEntry> = Vec::with_capacity(entries.len());
    for entry in entries {
        let (model_offset, model_length) = intern(&mut strings, &entry.model)?;
        out.push(QbMuseEntry {
            timestamp: entry.timestamp,
            input_tokens: entry.input,
            cache_read: entry.cache_read,
            output_tokens: entry.output,
            model_offset,
            model_length,
        });
    }
    Some((out, strings))
}

/// Parse one Muse usage line, mirroring `qb_claude_parse_usage_line`.
///
/// Returns a heap-allocated result the caller must pass to [`qb_muse_line_result_destroy`], or
/// a null pointer on internal failure — the caller falls back to the Swift reference.
#[no_mangle]
pub extern "C" fn qb_muse_parse_line(line: *const u8, line_len: usize) -> *mut MuseLineResult {
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
            MuseLine::Entry(e) => (vec![e], 0u32, 0u32),
            MuseLine::Irrelevant => (Vec::new(), 1u32, 0u32),
            MuseLine::Malformed => (Vec::new(), 0u32, 1u32),
        };
        match pack_entries(&entries) {
            Some((entries, strings)) => Box::into_raw(Box::new(MuseLineResult {
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

/// Nonzero when the line carried the attribution marker but failed validation.
#[no_mangle]
pub extern "C" fn qb_muse_line_result_malformed(result: *const MuseLineResult) -> u32 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.malformed
}

/// Nonzero when the line was skipped without parsing (no marker, not a reported token
/// attribution, or a zero-token placeholder).
#[no_mangle]
pub extern "C" fn qb_muse_line_result_irrelevant(result: *const MuseLineResult) -> u32 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.irrelevant
}

#[no_mangle]
pub extern "C" fn qb_muse_line_result_entry_count(result: *const MuseLineResult) -> u32 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.entries.len() as u32
}

/// Pointer to the entry array; valid until [`qb_muse_line_result_destroy`].
#[no_mangle]
pub extern "C" fn qb_muse_line_result_entries(result: *const MuseLineResult) -> *const QbMuseEntry {
    if result.is_null() {
        return ptr::null();
    }
    unsafe { &*result }.entries.as_ptr()
}

/// Pointer to the UTF-8 string blob the entry offsets index into, plus its byte length.
#[no_mangle]
pub extern "C" fn qb_muse_line_result_strings(
    result: *const MuseLineResult,
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
/// `result` must be a pointer returned by [`qb_muse_parse_line`], destroyed at most once.
#[no_mangle]
pub unsafe extern "C" fn qb_muse_line_result_destroy(result: *mut MuseLineResult) {
    if result.is_null() {
        return;
    }
    unsafe { drop(Box::from_raw(result)) };
}

/// Parse one Muse `session.jsonl` file end to end.
///
/// `path` is a NUL-terminated UTF-8 path. `end_offset` of `UINT64_MAX` reads to EOF. `cancel`
/// is invoked once per 64 KiB chunk. Returns a heap-allocated result (never NULL for a
/// completed call) or NULL only on internal failure — a NULL must be treated like `FALLBACK`.
#[no_mangle]
pub extern "C" fn qb_muse_parse_file(
    path: *const u8,
    path_len: usize,
    start_offset: u64,
    end_offset: u64,
    cancel: Option<extern "C" fn(*mut c_void) -> u8>,
    cancel_ctx: *mut c_void,
) -> *mut MuseFileResult {
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
pub extern "C" fn qb_muse_file_result_status(result: *const MuseFileResult) -> u32 {
    if result.is_null() {
        return QB_MUSE_FILE_FALLBACK;
    }
    unsafe { &*result }.status
}

#[no_mangle]
pub extern "C" fn qb_muse_file_result_entry_count(result: *const MuseFileResult) -> u32 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.entries.len() as u32
}

/// Pointer to the entry array; valid until [`qb_muse_file_result_destroy`].
#[no_mangle]
pub extern "C" fn qb_muse_file_result_entries(result: *const MuseFileResult) -> *const QbMuseEntry {
    if result.is_null() {
        return ptr::null();
    }
    unsafe { &*result }.entries.as_ptr()
}

/// Pointer to the UTF-8 string blob the entry offsets index into, plus its byte length.
#[no_mangle]
pub extern "C" fn qb_muse_file_result_strings(
    result: *const MuseFileResult,
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
pub extern "C" fn qb_muse_file_result_bytes_read(result: *const MuseFileResult) -> u64 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.bytes_read
}

#[no_mangle]
pub extern "C" fn qb_muse_file_result_oversized_lines(result: *const MuseFileResult) -> u64 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.oversized_lines_skipped
}

/// # Safety
/// `result` must be a pointer returned by [`qb_muse_parse_file`], destroyed at most once.
#[no_mangle]
pub unsafe extern "C" fn qb_muse_file_result_destroy(result: *mut MuseFileResult) {
    if result.is_null() {
        return;
    }
    unsafe { drop(Box::from_raw(result)) };
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(line: &str) -> MuseLine {
        parse_line(line.as_bytes())
    }

    /// A well-formed attribution envelope; `record` supplies the record's inner fields.
    fn attributed(record: &str) -> String {
        format!(
            r#"{{"recorded_at":1771588800123456,"payload":{{"event":{{"kind":"goal_usage_attribution","record":{{{record}}}}}}}}}"#
        )
    }

    /// The usual shape: `quantity` plus any extra record fields.
    fn usage(quantity: &str) -> String {
        attributed(&format!(r#""quantity":{quantity}"#))
    }

    #[test]
    fn marker_gate_short_circuits_non_attribution_lines() {
        assert!(matches!(parse("{}"), MuseLine::Irrelevant));
        assert!(matches!(parse("not json at all"), MuseLine::Irrelevant));
        // Valid JSON without the marker text is irrelevant without parsing.
        assert!(matches!(
            parse(r#"{"payload":{"event":{"kind":"other"}}}"#),
            MuseLine::Irrelevant
        ));
    }

    #[test]
    fn kind_mismatch_with_marker_present_is_irrelevant() {
        // Marker bytes arrive via an unrelated field while the decoded kind differs.
        let line = r#"{"recorded_at":1771588800123456,"payload":{"event":{"kind":"goal_progress","note":"goal_usage_attribution"}}}"#;
        assert!(matches!(parse(line), MuseLine::Irrelevant));
        // The whole payload/event/kind chain failing is also irrelevant, not malformed.
        for line in [
            r#"{"payload":"goal_usage_attribution"}"#,
            r#"{"payload":{"event":"goal_usage_attribution"}}"#,
            r#"{"payload":{"event":{"kind_x":"goal_usage_attribution"}}}"#,
            r#"{"payload":{"event":{"kind":7,"note":"goal_usage_attribution"}}}"#,
        ] {
            assert!(matches!(parse(line), MuseLine::Irrelevant), "{line}");
        }
    }

    #[test]
    fn reported_and_unit_filter_irrelevant_rows() {
        assert!(matches!(
            parse(&usage(
                r#"{"reported":false,"unit":"tokens","input_tokens":1,"output_tokens":1}"#
            )),
            MuseLine::Irrelevant
        ));
        assert!(matches!(
            parse(&usage(
                r#"{"reported":true,"unit":"requests","input_tokens":1,"output_tokens":1}"#
            )),
            MuseLine::Irrelevant
        ));
        // Zero-token reported rows are bookkeeping placeholders — skipped.
        assert!(matches!(
            parse(&usage(
                r#"{"reported":true,"unit":"tokens","input_tokens":0,"output_tokens":0}"#
            )),
            MuseLine::Irrelevant
        ));
    }

    #[test]
    fn valid_attribution_yields_one_entry() {
        match parse(&usage(
            r#"{"reported":true,"unit":"tokens","input_tokens":100,"output_tokens":50,"cached_tokens":30,"reasoning_tokens":10}"#,
        )) {
            MuseLine::Entry(e) => {
                assert_eq!(e.timestamp, 1_771_588_800.123_456);
                assert_eq!(e.input, 70);
                assert_eq!(e.cache_read, 30);
                assert_eq!(e.output, 60);
                assert_eq!(e.model, DEFAULT_MODEL);
            }
            _ => panic!("expected entry"),
        }
    }

    #[test]
    fn model_precedence_record_then_quantity_then_default() {
        let line = attributed(
            r#""model":"  record-model  ","quantity":{"reported":true,"unit":"tokens","input_tokens":1,"output_tokens":1,"model":"quantity-model"}"#,
        );
        match parse(&line) {
            MuseLine::Entry(e) => assert_eq!(e.model, "record-model"),
            _ => panic!("expected entry"),
        }
        // A blank record.model falls through to quantity.model.
        let line = attributed(
            r#""model":"   ","quantity":{"reported":true,"unit":"tokens","input_tokens":1,"output_tokens":1,"model":"quantity-model"}"#,
        );
        match parse(&line) {
            MuseLine::Entry(e) => assert_eq!(e.model, "quantity-model"),
            _ => panic!("expected entry"),
        }
        match parse(&usage(
            r#"{"reported":true,"unit":"tokens","input_tokens":1,"output_tokens":1,"model":"   "}"#,
        )) {
            MuseLine::Entry(e) => assert_eq!(e.model, DEFAULT_MODEL),
            _ => panic!("expected entry"),
        }
    }

    #[test]
    fn non_string_models_are_malformed() {
        for line in [
            attributed(
                r#""model":5,"quantity":{"reported":true,"unit":"tokens","input_tokens":1,"output_tokens":1}"#,
            ),
            attributed(
                r#""model":null,"quantity":{"reported":true,"unit":"tokens","input_tokens":1,"output_tokens":1}"#,
            ),
            usage(
                r#"{"reported":true,"unit":"tokens","input_tokens":1,"output_tokens":1,"model":{}}"#,
            ),
        ] {
            assert!(matches!(parse(&line), MuseLine::Malformed), "{line}");
        }
    }

    #[test]
    fn reported_must_be_a_real_boolean() {
        for reported in ["1", "\"true\"", "null"] {
            let line = usage(&format!(
                r#"{{"reported":{reported},"unit":"tokens","input_tokens":1,"output_tokens":1}}"#
            ));
            assert!(matches!(parse(&line), MuseLine::Malformed), "{reported}");
        }
        // Missing unit fails the same quartet guard.
        assert!(matches!(
            parse(&usage(
                r#"{"reported":true,"input_tokens":1,"output_tokens":1}"#
            )),
            MuseLine::Malformed
        ));
    }

    #[test]
    fn missing_record_or_quantity_is_malformed() {
        assert!(matches!(parse(&attributed("")), MuseLine::Malformed));
        assert!(matches!(
            parse(&attributed(r#""quantity":7"#)),
            MuseLine::Malformed
        ));
        // `record` missing or non-dict.
        let line = r#"{"recorded_at":1771588800123456,"payload":{"event":{"kind":"goal_usage_attribution"}}}"#;
        assert!(matches!(parse(line), MuseLine::Malformed));
        let line = r#"{"recorded_at":1771588800123456,"payload":{"event":{"kind":"goal_usage_attribution","record":[]}}}"#;
        assert!(matches!(parse(line), MuseLine::Malformed));
    }

    #[test]
    fn token_count_rules() {
        // Missing required counts.
        for quantity in [
            r#"{"reported":true,"unit":"tokens","output_tokens":1}"#,
            r#"{"reported":true,"unit":"tokens","input_tokens":1}"#,
            // Present-but-null counts are malformed even for the optional fields.
            r#"{"reported":true,"unit":"tokens","input_tokens":1,"output_tokens":1,"cached_tokens":null}"#,
            r#"{"reported":true,"unit":"tokens","input_tokens":1,"output_tokens":1,"reasoning_tokens":null}"#,
            // Bool, fractional, negative, over the cap, string — all malformed.
            r#"{"reported":true,"unit":"tokens","input_tokens":true,"output_tokens":1}"#,
            r#"{"reported":true,"unit":"tokens","input_tokens":1.5,"output_tokens":1}"#,
            r#"{"reported":true,"unit":"tokens","input_tokens":-1,"output_tokens":1}"#,
            r#"{"reported":true,"unit":"tokens","input_tokens":1000000000000001,"output_tokens":1}"#,
            r#"{"reported":true,"unit":"tokens","input_tokens":"5","output_tokens":1}"#,
        ] {
            assert!(
                matches!(parse(&usage(quantity)), MuseLine::Malformed),
                "{quantity}"
            );
        }
        // cached > input is malformed; cached == input is fine.
        assert!(matches!(
            parse(&usage(
                r#"{"reported":true,"unit":"tokens","input_tokens":10,"output_tokens":1,"cached_tokens":11}"#
            )),
            MuseLine::Malformed
        ));
        assert!(matches!(
            parse(&usage(
                r#"{"reported":true,"unit":"tokens","input_tokens":10,"output_tokens":1,"cached_tokens":10}"#
            )),
            MuseLine::Entry(_)
        ));
    }

    #[test]
    fn recorded_at_must_be_a_positive_microsecond_integer() {
        for (recorded_at, expected_ok) in [
            ("1771588800123456", true),
            ("1", true),
            ("0", false),
            ("-5", false),
            ("1771588800.5", false),
            ("\"1771588800123456\"", false),
            ("true", false),
            ("null", false),
            ("9000000000000001", false),
        ] {
            let line = format!(
                r#"{{"recorded_at":{recorded_at},"payload":{{"event":{{"kind":"goal_usage_attribution","record":{{"quantity":{{"reported":true,"unit":"tokens","input_tokens":1,"output_tokens":1}}}}}}}}}}"#
            );
            let ok = matches!(parse(&line), MuseLine::Entry(_));
            assert_eq!(ok, expected_ok, "recorded_at {recorded_at}");
        }
        // Missing entirely is malformed too.
        let line = r#"{"payload":{"event":{"kind":"goal_usage_attribution","record":{"quantity":{"reported":true,"unit":"tokens","input_tokens":1,"output_tokens":1}}}}}"#;
        assert!(matches!(parse(line), MuseLine::Malformed));
    }

    #[test]
    fn invalid_json_and_non_object_with_marker_are_malformed() {
        assert!(matches!(
            parse(r#"{"goal_usage_attribution" broken"#),
            MuseLine::Malformed
        ));
        assert!(matches!(
            parse(r#"["goal_usage_attribution"]"#),
            MuseLine::Malformed
        ));
    }

    #[test]
    fn cache_read_does_not_change_total_gate() {
        // input == cached still counts toward the zero-token gate.
        assert!(matches!(
            parse(&usage(
                r#"{"reported":true,"unit":"tokens","input_tokens":5,"output_tokens":0,"cached_tokens":5}"#
            )),
            MuseLine::Entry(_)
        ));
    }
}
