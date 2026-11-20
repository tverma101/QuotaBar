//! Pi session parser — a line-for-line port of `PiUsageScanner.parseLineSwift` /
//! `parseFileSwift(at:)` in `Sources/QuotaBar/Providers/Pi/PiUsageScanner.swift`, plus the
//! whole-file FFI entry point (`qb_pi_parse_file`) built on `crate::scanfile`.
//!
//! Lines come from JSONL session logs under `~/.pi/agent/sessions/`. Most lines are noise; only
//! `type == "message"` records with `message.role == "assistant"` and a `message.provider` that
//! `PiProviderMapping` resolves to a QuotaBar card carry usage. Each qualifying line yields at
//! most one `Entry`. Any usage-marked line that fails validation makes the whole file fail —
//! `parseFile(at:)` returns nil for it — so this module reports Failed rather than skipping.
//!
//! Fallback contract: a `timestamp` *string* that is not one of the canonical UTC shapes in
//! `crate::parse_canonical_utc` is legal Swift input (`OpenUsageISO8601` handles more shapes) —
//! the whole file falls back to the Swift parser rather than answering differently.

use serde_json::Value;

use crate::scanfile::{self, CancelCallback, QB_FILE_FAILED, QB_FILE_FALLBACK, QB_FILE_OK};
use crate::{intern, parse_canonical_utc, CanonicalTimestamp, NIL_STRING};
use std::os::raw::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;

#[repr(C)]
pub struct QbPiEntry {
    /// Seconds since the Unix epoch.
    pub timestamp: f64,
    /// `carriedCost` in USD when `has_carried_cost != 0`, else 0.
    pub carried_cost: f64,
    pub input_tokens: u64,
    pub cache_write_5m: u64,
    pub cache_write_1h: u64,
    pub cache_read: u64,
    pub output_tokens: u64,
    /// pi's own `usage.totalTokens`, carried verbatim into `reportedTotalTokens`.
    pub reported_total_tokens: u64,
    /// Offsets into the strings blob; `UINT32_MAX` when `id` is nil.
    pub id_offset: u32,
    pub id_length: u32,
    /// `card_id` is never nil — resolved at parse time via the provider map.
    pub card_id_offset: u32,
    pub card_id_length: u32,
    /// `model` is never nil in this format; a missing blob still fails bounds checks loudly.
    pub model_offset: u32,
    pub model_length: u32,
    pub has_carried_cost: u8,
    pub reserved: [u8; 7],
}

pub struct PiFileResult {
    status: u32,
    entries: Vec<QbPiEntry>,
    strings: Vec<u8>,
    bytes_read: u64,
    oversized_lines_skipped: u64,
}

/// Per-line result for the lenient `parseFile(_ data:)` surface, mirroring
/// `qb_grok_parse_line`: `entries`/`irrelevant`/`malformed` so the Swift caller keeps
/// its own file-level rules.
pub struct PiLineResult {
    malformed: u32,
    irrelevant: u32,
    entries: Vec<QbPiEntry>,
    strings: Vec<u8>,
}

// ---------------------------------------------------------------------------
// Line parsing (mirror of PiUsageScanner.parseLineSwift)
// ---------------------------------------------------------------------------

/// Byte-level prefilter: a literal `"usage":{` must occur in the line — a `"usage" : {` with
/// whitespace does NOT match, exactly like `data.range(of:)` in Swift.
const USAGE_MARKER: &[u8] = b"\"usage\":{";

enum PiLine {
    /// At most one entry per line in this format.
    Entries(Vec<EntryOut>),
    Irrelevant,
    Malformed,
    /// Legal Swift input outside the supported shapes — the file falls back to Swift.
    Fallback,
}

struct EntryOut {
    /// `object["id"]` stored raw (untrimmed), matching Swift.
    id: Option<String>,
    timestamp: f64,
    /// Resolved QuotaBar card id — the static `PiProviderMapping` table.
    card_id: &'static str,
    model: String,
    input: u64,
    cache_write_5m: u64,
    cache_write_1h: u64,
    cache_read: u64,
    output: u64,
    reported_total: u64,
    carried_cost: Option<f64>,
}

/// Mirror of `PiProviderMapping.cardID(forPiProvider:)` — an exact-match table, no trimming
/// or case folding. `nvidia-nim` and every other unmapped provider are intentionally absent.
fn card_id_for_provider(provider: &str) -> Option<&'static str> {
    Some(match provider {
        "anthropic" => "claude",
        "claude-agent-sdk" => "claude",
        "openai-codex" => "codex",
        "cursor" => "cursor",
        "zai" | "zhipu" => "zai",
        "google-antigravity" => "antigravity",
        "github-copilot" => "copilot",
        _ => return None,
    })
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

fn parse_line(line: &[u8]) -> PiLine {
    if memchr::memmem::find(line, USAGE_MARKER).is_none() {
        return PiLine::Irrelevant;
    }
    let value: Value = match serde_json::from_slice(line) {
        Ok(v) => v,
        Err(_) => return PiLine::Malformed,
    };
    let object = match value.as_object() {
        Some(o) => o,
        None => return PiLine::Malformed,
    };
    if object.get("type").and_then(Value::as_str) != Some("message") {
        return PiLine::Irrelevant;
    }
    let message = match object.get("message").and_then(Value::as_object) {
        Some(m) => m,
        None => return PiLine::Malformed,
    };
    if message.get("role").and_then(Value::as_str) != Some("assistant") {
        return PiLine::Irrelevant;
    }
    let provider = match message.get("provider").and_then(Value::as_str) {
        Some(p) => p,
        None => return PiLine::Malformed,
    };
    let card_id = match card_id_for_provider(provider) {
        Some(c) => c,
        None => return PiLine::Irrelevant,
    };

    // `timestamp` must be a string — an absent, null, or numeric timestamp is malformed in
    // Swift (`as? String` fails), not a separate path.
    let timestamp = match object.get("timestamp") {
        Some(Value::String(s)) => match parse_canonical_utc(s.as_bytes()) {
            CanonicalTimestamp::Ok(t) => t,
            CanonicalTimestamp::Invalid => return PiLine::Malformed,
            CanonicalTimestamp::NotCanonical => return PiLine::Fallback,
        },
        _ => return PiLine::Malformed,
    };
    let usage = match message.get("usage").and_then(Value::as_object) {
        Some(u) => u,
        None => return PiLine::Malformed,
    };

    // `id` is optional, but when the key is present — JSON null included — it must be a string
    // whose whitespace-trimmed form is non-empty. The stored value is the raw, untrimmed text.
    let id = match object.get("id") {
        None => None,
        Some(raw) => match raw.as_str() {
            Some(text) if !text.trim().is_empty() => Some(text.to_string()),
            _ => return PiLine::Malformed,
        },
    };

    let (input, output, reported_total) = match (
        strict_count(usage.get("input"), true),
        strict_count(usage.get("output"), true),
        strict_count(usage.get("totalTokens"), true),
    ) {
        (Some(i), Some(o), Some(t)) => (i, o, t),
        _ => return PiLine::Malformed,
    };
    let (cache_read, cache_write, cache_write_1h) = match (
        strict_count(usage.get("cacheRead"), false),
        strict_count(usage.get("cacheWrite"), false),
        strict_count(usage.get("cacheWrite1h"), false),
    ) {
        (Some(r), Some(w), Some(h)) => (r, w, h),
        _ => return PiLine::Malformed,
    };
    if cache_write_1h > cache_write {
        return PiLine::Malformed;
    }
    let cache_write_5m = cache_write - cache_write_1h;

    // `TokenBreakdown.totalTokens`: saturating sums in the same order Swift computes
    // `promptTokens` — input + (5m + 1h writes) + cacheRead, then + output. `input` is not
    // reduced by cacheRead here (unlike the Grok scanner).
    let total = input
        .saturating_add(cache_write_5m)
        .saturating_add(cache_write_1h)
        .saturating_add(cache_read)
        .saturating_add(output);
    if total != reported_total {
        return PiLine::Malformed;
    }

    // `usage.cost` is optional; a present non-object is malformed. `cost.total` likewise:
    // absent or null means no carried cost, anything else must be a non-bool finite number in
    // [0, 1e12].
    let carried_cost: Option<f64> = match usage.get("cost") {
        None | Some(Value::Null) => None,
        Some(raw) => {
            let cost = match raw.as_object() {
                Some(c) => c,
                None => return PiLine::Malformed,
            };
            match cost.get("total") {
                None | Some(Value::Null) => None,
                Some(raw_total) => match raw_total.as_f64() {
                    Some(v) if v.is_finite() && v >= 0.0 && v <= 1e12 => Some(v),
                    _ => return PiLine::Malformed,
                },
            }
        }
    };

    // `model`: absent stores ""; present — JSON null included — must be a string, and the stored
    // value is the whitespace-trimmed text.
    let model = match message.get("model") {
        None => String::new(),
        Some(Value::String(s)) => s.trim().to_string(),
        Some(_) => return PiLine::Malformed,
    };

    // This format emits a single entry per line, so the fixed per-line FFI cap cannot be hit.
    PiLine::Entries(vec![EntryOut {
        id,
        timestamp,
        card_id,
        model,
        input,
        cache_write_5m,
        cache_write_1h,
        cache_read,
        output,
        reported_total,
        carried_cost,
    }])
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
    /// usage record still fails the file, matching Swift's nil).
    fn consume(&mut self, line: &[u8]) -> bool {
        match parse_line(line) {
            PiLine::Entries(mut parsed) => {
                self.entries.append(&mut parsed);
                true
            }
            PiLine::Irrelevant => true,
            PiLine::Malformed => {
                self.malformed = true;
                true
            }
            PiLine::Fallback => {
                self.fell_back = true;
                false
            }
        }
    }
}

/// Run the Pi parser over one file. `end_offset` of `u64::MAX` reads to EOF. Returns the
/// status plus the packed entries/strings; never partially succeeds — a `Failed` status means
/// the caller returns nil for the file exactly as the Swift `parseFile(at:)` does.
fn parse_file_impl(
    path: &[u8],
    start_offset: u64,
    end_offset: Option<u64>,
    cancel_ctx: *mut c_void,
    cancel: Option<CancelCallback>,
) -> PiFileResult {
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
        return PiFileResult {
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
        return PiFileResult {
            status: QB_FILE_FAILED,
            entries: Vec::new(),
            strings: Vec::new(),
            bytes_read: stats.bytes_read,
            oversized_lines_skipped: stats.oversized_lines_skipped,
        };
    }

    let Some((entries, strings)) = pack_entries(&parser.entries) else {
        return PiFileResult {
            status: QB_FILE_FALLBACK,
            entries: Vec::new(),
            strings: Vec::new(),
            bytes_read: stats.bytes_read,
            oversized_lines_skipped: stats.oversized_lines_skipped,
        };
    };
    PiFileResult {
        status: QB_FILE_OK,
        entries,
        strings,
        bytes_read: stats.bytes_read,
        oversized_lines_skipped: stats.oversized_lines_skipped,
    }
}

/// Intern every string field of `entries` into one UTF-8 blob and produce the `#[repr(C)]`
/// array. `None` means a blob offset overflowed u32 — the caller treats it as fallback.
fn pack_entries(entries: &[EntryOut]) -> Option<(Vec<QbPiEntry>, Vec<u8>)> {
    let mut strings: Vec<u8> = Vec::new();
    let mut out: Vec<QbPiEntry> = Vec::with_capacity(entries.len());
    for entry in entries {
        let (id_offset, id_length) = match &entry.id {
            Some(s) => intern(&mut strings, s)?,
            None => (NIL_STRING, 0),
        };
        let (card_id_offset, card_id_length) = intern(&mut strings, entry.card_id)?;
        let (model_offset, model_length) = intern(&mut strings, &entry.model)?;
        out.push(QbPiEntry {
            timestamp: entry.timestamp,
            carried_cost: entry.carried_cost.unwrap_or(0.0),
            input_tokens: entry.input,
            cache_write_5m: entry.cache_write_5m,
            cache_write_1h: entry.cache_write_1h,
            cache_read: entry.cache_read,
            output_tokens: entry.output,
            reported_total_tokens: entry.reported_total,
            id_offset,
            id_length,
            card_id_offset,
            card_id_length,
            model_offset,
            model_length,
            has_carried_cost: u8::from(entry.carried_cost.is_some()),
            reserved: [0; 7],
        });
    }
    Some((out, strings))
}

/// Parse one Pi usage line, mirroring `qb_grok_parse_line`.
///
/// Returns a heap-allocated result the caller must pass to [`qb_pi_line_result_destroy`], or a
/// null pointer when the line is legal input this module does not support (a non-canonical
/// string timestamp) — the caller falls back to the Swift reference.
#[no_mangle]
pub extern "C" fn qb_pi_parse_line(line: *const u8, line_len: usize) -> *mut PiLineResult {
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
            PiLine::Entries(e) => (e, 0u32, 0u32),
            PiLine::Irrelevant => (Vec::new(), 1u32, 0u32),
            PiLine::Malformed => (Vec::new(), 0u32, 1u32),
            PiLine::Fallback => return ptr::null_mut(),
        };
        match pack_entries(&entries) {
            Some((entries, strings)) => Box::into_raw(Box::new(PiLineResult {
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

/// Nonzero when the line carried a `usage` marker but failed validation.
#[no_mangle]
pub extern "C" fn qb_pi_line_result_malformed(result: *const PiLineResult) -> u32 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.malformed
}

/// Nonzero when the line was skipped without parsing (no marker, not a mapped assistant row).
#[no_mangle]
pub extern "C" fn qb_pi_line_result_irrelevant(result: *const PiLineResult) -> u32 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.irrelevant
}

#[no_mangle]
pub extern "C" fn qb_pi_line_result_entry_count(result: *const PiLineResult) -> u32 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.entries.len() as u32
}

/// Pointer to the entry array; valid until [`qb_pi_line_result_destroy`].
#[no_mangle]
pub extern "C" fn qb_pi_line_result_entries(result: *const PiLineResult) -> *const QbPiEntry {
    if result.is_null() {
        return ptr::null();
    }
    unsafe { &*result }.entries.as_ptr()
}

/// Pointer to the UTF-8 string blob the entry offsets index into, plus its byte length.
#[no_mangle]
pub extern "C" fn qb_pi_line_result_strings(
    result: *const PiLineResult,
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
/// `result` must be a pointer returned by [`qb_pi_parse_line`], destroyed at most once.
#[no_mangle]
pub unsafe extern "C" fn qb_pi_line_result_destroy(result: *mut PiLineResult) {
    if result.is_null() {
        return;
    }
    unsafe { drop(Box::from_raw(result)) };
}

/// Parse one Pi session `.jsonl` file end to end.
///
/// `path` is a NUL-terminated UTF-8 path. `end_offset` of `UINT64_MAX` reads to EOF. `cancel` is
/// invoked once per 64 KiB chunk. Returns a heap-allocated result (never NULL for a completed
/// call) or NULL only on internal failure — a NULL must be treated like `FALLBACK`.
#[no_mangle]
pub extern "C" fn qb_pi_parse_file(
    path: *const u8,
    path_len: usize,
    start_offset: u64,
    end_offset: u64,
    cancel: Option<extern "C" fn(*mut c_void) -> u8>,
    cancel_ctx: *mut c_void,
) -> *mut PiFileResult {
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
pub extern "C" fn qb_pi_file_result_status(result: *const PiFileResult) -> u32 {
    if result.is_null() {
        return QB_FILE_FALLBACK;
    }
    unsafe { &*result }.status
}

#[no_mangle]
pub extern "C" fn qb_pi_file_result_entry_count(result: *const PiFileResult) -> u32 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.entries.len() as u32
}

/// Pointer to the entry array; valid until [`qb_pi_file_result_destroy`].
#[no_mangle]
pub extern "C" fn qb_pi_file_result_entries(result: *const PiFileResult) -> *const QbPiEntry {
    if result.is_null() {
        return ptr::null();
    }
    unsafe { &*result }.entries.as_ptr()
}

/// Pointer to the UTF-8 string blob the entry offsets index into, plus its byte length.
#[no_mangle]
pub extern "C" fn qb_pi_file_result_strings(
    result: *const PiFileResult,
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
pub extern "C" fn qb_pi_file_result_bytes_read(result: *const PiFileResult) -> u64 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.bytes_read
}

#[no_mangle]
pub extern "C" fn qb_pi_file_result_oversized_lines(result: *const PiFileResult) -> u64 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.oversized_lines_skipped
}

/// # Safety
/// `result` must be a pointer returned by [`qb_pi_parse_file`], destroyed at most once.
#[no_mangle]
pub unsafe extern "C" fn qb_pi_file_result_destroy(result: *mut PiFileResult) {
    if result.is_null() {
        return;
    }
    unsafe { drop(Box::from_raw(result)) };
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(line: &str) -> PiLine {
        parse_line(line.as_bytes())
    }

    /// A canonical mapped line; `usage` is the raw `message.usage` object body.
    fn line(usage: &str) -> String {
        format!(
            r#"{{"type":"message","id":"m1","timestamp":"2026-07-12T10:00:00.000Z","message":{{"role":"assistant","provider":"anthropic","model":"claude-opus-4-8","usage":{usage}}}}}"#
        )
    }

    /// input 100 + output 50 + cacheRead 30 + cacheWrite 20 = 200.
    const FULL_USAGE: &str = r#"{"input":100,"output":50,"cacheRead":30,"cacheWrite":20,"cacheWrite1h":8,"totalTokens":200,"cost":{"total":0.5}}"#;

    #[test]
    fn marker_gate() {
        // No `"usage":{` bytes → irrelevant, even for valid JSON.
        assert!(matches!(parse("{}"), PiLine::Irrelevant));
        assert!(matches!(parse("not json at all"), PiLine::Irrelevant));
        // `"usage" : {` with whitespace does NOT trip the byte prefilter → irrelevant.
        assert!(matches!(
            parse(
                r#"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","usage" : {"input":1,"output":1,"totalTokens":2}}}"#
            ),
            PiLine::Irrelevant
        ));
        // Marker inside a string value still trips the prefilter; validation then decides.
        assert!(matches!(
            parse(r#"{"note":"contains \"usage\":{\" text"}"#),
            PiLine::Irrelevant
        ));
    }

    #[test]
    fn valid_line_yields_one_entry() {
        match parse(&line(FULL_USAGE)) {
            PiLine::Entries(entries) => {
                assert_eq!(entries.len(), 1);
                let e = &entries[0];
                assert_eq!(e.id.as_deref(), Some("m1"));
                assert_eq!(e.card_id, "claude");
                assert_eq!(e.model, "claude-opus-4-8");
                assert_eq!(e.input, 100);
                assert_eq!(e.cache_read, 30);
                assert_eq!(e.cache_write_5m, 12);
                assert_eq!(e.cache_write_1h, 8);
                assert_eq!(e.output, 50);
                assert_eq!(e.reported_total, 200);
                assert_eq!(e.carried_cost, Some(0.5));
            }
            _ => panic!("expected entry"),
        }
    }

    #[test]
    fn provider_mapping_table() {
        for (provider, card) in [
            ("anthropic", "claude"),
            ("claude-agent-sdk", "claude"),
            ("openai-codex", "codex"),
            ("cursor", "cursor"),
            ("zai", "zai"),
            ("zhipu", "zai"),
            ("google-antigravity", "antigravity"),
            ("github-copilot", "copilot"),
        ] {
            let l = line(r#"{"input":1,"output":1,"totalTokens":2}"#).replace(
                r#""provider":"anthropic""#,
                &format!(r#""provider":"{provider}""#),
            );
            match parse(&l) {
                PiLine::Entries(entries) => assert_eq!(entries[0].card_id, card, "{provider}"),
                _ => panic!("expected entry for {provider}"),
            }
        }
        // Unmapped → irrelevant; missing/non-string provider → malformed.
        let unmapped = line(r#"{"input":1,"output":1,"totalTokens":2}"#)
            .replace(r#""provider":"anthropic""#, r#""provider":"nvidia-nim""#);
        assert!(matches!(parse(&unmapped), PiLine::Irrelevant));
        let missing = line(r#"{"input":1,"output":1,"totalTokens":2}"#)
            .replace(r#""provider":"anthropic","#, "");
        assert!(matches!(parse(&missing), PiLine::Malformed));
        let numeric = line(r#"{"input":1,"output":1,"totalTokens":2}"#)
            .replace(r#""provider":"anthropic""#, r#""provider":7"#);
        assert!(matches!(parse(&numeric), PiLine::Malformed));
    }

    #[test]
    fn type_and_role_filters() {
        // Non-"message" type or non-assistant role is dropped silently.
        let user_type = line(r#"{"input":1,"output":1,"totalTokens":2}"#)
            .replace(r#""type":"message""#, r#""type":"user""#);
        assert!(matches!(parse(&user_type), PiLine::Irrelevant));
        let no_type =
            line(r#"{"input":1,"output":1,"totalTokens":2}"#).replace(r#""type":"message","#, "");
        assert!(matches!(parse(&no_type), PiLine::Irrelevant));
        let user_role = line(r#"{"input":1,"output":1,"totalTokens":2}"#)
            .replace(r#""role":"assistant""#, r#""role":"user""#);
        assert!(matches!(parse(&user_role), PiLine::Irrelevant));
        let no_role =
            line(r#"{"input":1,"output":1,"totalTokens":2}"#).replace(r#""role":"assistant","#, "");
        assert!(matches!(parse(&no_role), PiLine::Irrelevant));
        // `message` itself missing or non-object is malformed (a top-level `usage` keeps the
        // byte marker alive so the line reaches JSON validation).
        assert!(matches!(
            parse(
                r#"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","usage":{"a":1},"id":"m"}"#
            ),
            PiLine::Malformed
        ));
        assert!(matches!(
            parse(
                r#"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","usage":{"a":1},"message":"scalar"}"#
            ),
            PiLine::Malformed
        ));
    }

    #[test]
    fn timestamp_shapes() {
        // Canonical with and without millis (2026-07-12T10:00:00Z = 1783850400 seconds).
        match parse(&line(r#"{"input":1,"output":1,"totalTokens":2}"#)) {
            PiLine::Entries(entries) => assert_eq!(entries[0].timestamp, 1_783_850_400.0),
            _ => panic!("expected entry"),
        }
        let nonfractional = line(r#"{"input":1,"output":1,"totalTokens":2}"#)
            .replace("2026-07-12T10:00:00.000Z", "2026-07-12T10:00:00Z");
        assert!(matches!(parse(&nonfractional), PiLine::Entries(_)));

        // Non-canonical strings are legal Swift input → fallback.
        for ts in [
            "2026-07-12 10:00:00",
            "2026-07-12T10:00:00.123456Z",
            "2026-07-12T10:00:00+00:00",
        ] {
            let l = line(r#"{"input":1,"output":1,"totalTokens":2}"#)
                .replace("2026-07-12T10:00:00.000Z", ts);
            assert!(matches!(parse(&l), PiLine::Fallback), "{ts}");
        }

        // Missing, null, numeric, or canonical-but-invalid timestamps are malformed.
        for fragment in [
            r#""timestamp":1771588800,"#,
            r#""timestamp":null,"#,
            "",
            r#""timestamp":"2026-13-12T10:00:00.000Z","#,
        ] {
            let l = line(r#"{"input":1,"output":1,"totalTokens":2}"#)
                .replace(r#""timestamp":"2026-07-12T10:00:00.000Z","#, fragment);
            assert!(matches!(parse(&l), PiLine::Malformed), "{fragment}");
        }
    }

    #[test]
    fn id_rules() {
        // Absent → nil.
        let no_id = line(r#"{"input":1,"output":1,"totalTokens":2}"#).replace(r#""id":"m1","#, "");
        match parse(&no_id) {
            PiLine::Entries(entries) => assert_eq!(entries[0].id, None),
            _ => panic!("expected entry"),
        }
        // Whitespace-padded id is stored RAW (untrimmed).
        let padded = line(r#"{"input":1,"output":1,"totalTokens":2}"#)
            .replace(r#""id":"m1""#, r#""id":"  m-9  ""#);
        match parse(&padded) {
            PiLine::Entries(entries) => assert_eq!(entries[0].id.as_deref(), Some("  m-9  ")),
            _ => panic!("expected entry"),
        }
        // Present-but-empty-after-trim, null, and non-string ids are malformed.
        for raw in [r#""id":"   ""#, r#""id":"""#, r#""id":null"#, r#""id":123"#] {
            let l = line(r#"{"input":1,"output":1,"totalTokens":2}"#).replace(r#""id":"m1""#, raw);
            assert!(matches!(parse(&l), PiLine::Malformed), "{raw}");
        }
    }

    #[test]
    fn strict_count_rules() {
        // Required fields missing → malformed.
        for usage in [
            r#"{"output":1,"totalTokens":2}"#,
            r#"{"input":1,"totalTokens":2}"#,
            r#"{"input":1,"output":1}"#,
        ] {
            assert!(matches!(parse(&line(usage)), PiLine::Malformed), "{usage}");
        }
        // Present null counts as malformed for required AND optional fields.
        for usage in [
            r#"{"input":null,"output":1,"totalTokens":2}"#,
            r#"{"input":1,"output":1,"cacheRead":null,"totalTokens":2}"#,
            r#"{"input":1,"output":1,"cacheWrite1h":null,"totalTokens":2}"#,
        ] {
            assert!(matches!(parse(&line(usage)), PiLine::Malformed), "{usage}");
        }
        // bool, fractional, negative, over-cap, and numeric strings are malformed.
        for usage in [
            r#"{"input":true,"output":1,"totalTokens":2}"#,
            r#"{"input":1.5,"output":1,"totalTokens":2}"#,
            r#"{"input":-1,"output":1,"totalTokens":2}"#,
            r#"{"input":1e16,"output":1,"totalTokens":2}"#,
            r#"{"input":"5","output":1,"totalTokens":2}"#,
        ] {
            assert!(matches!(parse(&line(usage)), PiLine::Malformed), "{usage}");
        }
        // `message.usage` itself missing/null/non-object is malformed (a top-level `usage`
        // keeps the byte marker alive so the line reaches JSON validation).
        for usage in ["", r#""usage":null,"#, r#""usage":7,"#] {
            let l = format!(
                r#"{{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","usage":{{"a":1}},"message":{{"role":"assistant","provider":"anthropic",{usage}"model":"m"}}}}"#
            );
            assert!(matches!(parse(&l), PiLine::Malformed), "{usage}");
        }
    }

    #[test]
    fn cache_write_split_and_total_tokens() {
        // cacheWrite1h <= cacheWrite splits; total = input + cacheWrite + cacheRead + output.
        match parse(&line(
            r#"{"input":10,"output":5,"cacheWrite":100,"cacheWrite1h":40,"totalTokens":115}"#,
        )) {
            PiLine::Entries(entries) => {
                assert_eq!(entries[0].cache_write_1h, 40);
                assert_eq!(entries[0].cache_write_5m, 60);
            }
            _ => panic!("expected entry"),
        }
        // cacheWrite1h > cacheWrite → malformed.
        assert!(matches!(
            parse(&line(
                r#"{"input":10,"output":5,"cacheWrite":40,"cacheWrite1h":41,"totalTokens":55}"#
            )),
            PiLine::Malformed
        ));
        // totalTokens must equal the bucket sum — input is NOT reduced by cacheRead.
        assert!(matches!(
            parse(&line(
                r#"{"input":10,"output":5,"cacheRead":3,"totalTokens":15}"#
            )),
            PiLine::Malformed
        ));
        match parse(&line(
            r#"{"input":10,"output":5,"cacheRead":3,"totalTokens":18}"#,
        )) {
            PiLine::Entries(entries) => {
                assert_eq!(entries[0].input, 10);
                assert_eq!(entries[0].cache_read, 3);
            }
            _ => panic!("expected entry"),
        }
    }

    #[test]
    fn cost_rules() {
        // Absent, null, empty object, and null total → no carried cost.
        for usage in [
            r#"{"input":1,"output":1,"totalTokens":2}"#,
            r#"{"input":1,"output":1,"totalTokens":2,"cost":null}"#,
            r#"{"input":1,"output":1,"totalTokens":2,"cost":{}}"#,
            r#"{"input":1,"output":1,"totalTokens":2,"cost":{"total":null}}"#,
        ] {
            match parse(&line(usage)) {
                PiLine::Entries(entries) => assert_eq!(entries[0].carried_cost, None, "{usage}"),
                _ => panic!("expected entry: {usage}"),
            }
        }
        // Bounds: 0 and 1e12 accepted.
        for (total, expected) in [("0", Some(0.0)), ("1e12", Some(1e12))] {
            let usage =
                format!(r#"{{"input":1,"output":1,"totalTokens":2,"cost":{{"total":{total}}}}}"#);
            match parse(&line(&usage)) {
                PiLine::Entries(entries) => assert_eq!(entries[0].carried_cost, expected),
                _ => panic!("expected entry: {usage}"),
            }
        }
        // Non-object cost, or an invalid total, is malformed.
        for usage in [
            r#"{"input":1,"output":1,"totalTokens":2,"cost":5}"#,
            r#"{"input":1,"output":1,"totalTokens":2,"cost":{"total":"x"}}"#,
            r#"{"input":1,"output":1,"totalTokens":2,"cost":{"total":true}}"#,
            r#"{"input":1,"output":1,"totalTokens":2,"cost":{"total":-1}}"#,
            r#"{"input":1,"output":1,"totalTokens":2,"cost":{"total":1e13}}"#,
        ] {
            assert!(matches!(parse(&line(usage)), PiLine::Malformed), "{usage}");
        }
    }

    #[test]
    fn model_rules() {
        // Absent → "".
        let absent = line(r#"{"input":1,"output":1,"totalTokens":2}"#)
            .replace(r#""model":"claude-opus-4-8","#, "");
        match parse(&absent) {
            PiLine::Entries(entries) => assert_eq!(entries[0].model, ""),
            _ => panic!("expected entry"),
        }
        // Stored trimmed.
        let padded = line(r#"{"input":1,"output":1,"totalTokens":2}"#).replace(
            r#""model":"claude-opus-4-8""#,
            r#""model":"  claude-sonnet  ""#,
        );
        match parse(&padded) {
            PiLine::Entries(entries) => assert_eq!(entries[0].model, "claude-sonnet"),
            _ => panic!("expected entry"),
        }
        // Present non-string — null included — is malformed.
        for raw in [r#""model":null"#, r#""model":123"#, r#""model":{}"#] {
            let l = line(r#"{"input":1,"output":1,"totalTokens":2}"#)
                .replace(r#""model":"claude-opus-4-8""#, raw);
            assert!(matches!(parse(&l), PiLine::Malformed), "{raw}");
        }
    }

    #[test]
    fn invalid_json_and_non_object_are_malformed() {
        assert!(matches!(
            parse(r#"{"usage":{ but broken"#),
            PiLine::Malformed
        ));
        assert!(matches!(parse(r#"[{"usage":{"a":1}}]"#), PiLine::Malformed));
    }
}
