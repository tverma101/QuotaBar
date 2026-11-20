//! QuotaBar core — performance-critical primitives compiled to a static library and called from
//! the Swift app over the C ABI declared in `Sources/CQuotabarCore/include/quotabar_core.h`.
//!
//! Stage 1 ports the Claude usage-line parser (`ClaudeLogUsageScanner.parseEntries` in Swift);
//! stage 2 ports the Codex rollout-line parser (`CodexLogUsageScanner.FileParser` in Swift).
//! The Swift implementations remain in the tree as the reference oracles and as the runtime
//! fallback for shapes this fast path deliberately rejects with the null-pointer `Fallback`
//! signal: usage lines whose timestamp is a string but is not one of the canonical UTC shapes
//! handled here, and lines that would exceed the fixed per-line entry cap. Every other input
//! produces byte-for-byte the same result the Swift parser produces, including the
//! `malformedTokenCounts` / `hasMalformedUsage` side channels.

use serde_json::{Map, Value};
use std::os::raw::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;

use crate::scanfile::{CancelCallback, QB_FILE_FAILED, QB_FILE_FALLBACK, QB_FILE_OK};

mod antigravity;
mod codex;
mod codex_router;
mod grok;
mod muse;
mod pi;
mod pricing;
mod scanfile;

const MAX_ENTRIES_PER_LINE: usize = 64;
pub(crate) const NIL_STRING: u32 = u32::MAX;

/// Status returned by [`qb_claude_result_status`].
pub const QB_CLAUDE_STATUS_PARSED: u32 = 0;
/// Returned via the null pointer from [`qb_claude_parse_usage_line`]: the line is legal Swift
/// input this module does not handle, so the caller must re-run its own Swift implementation.
pub const QB_CLAUDE_STATUS_FALLBACK: u32 = 1;

#[repr(C)]
pub struct QbClaudeUsageEntry {
    /// Seconds since the Unix epoch, computed with the same arithmetic the Swift canonical
    /// parser uses (`Double(wholeSeconds) + Double(millis) / 1000`).
    pub timestamp: f64,
    /// Cost in USD, valid only when `has_cost_usd != 0`.
    pub cost_usd: f64,
    pub input_tokens: u64,
    pub cache_write_5m: u64,
    pub cache_write_1h: u64,
    pub cache_read: u64,
    pub output_tokens: u64,
    /// Offsets into the string blob returned by [`qb_claude_result_strings`], or `UINT32_MAX`
    /// when the field is nil/absent.
    pub message_id_offset: u32,
    pub message_id_length: u32,
    pub request_id_offset: u32,
    pub request_id_length: u32,
    pub model_offset: u32,
    pub model_length: u32,
    pub is_sidechain: u8,
    pub has_speed: u8,
    pub is_fast: u8,
    pub has_cost_usd: u8,
    pub reserved: [u8; 4],
}

pub struct ClaudeParseResult {
    malformed: u32,
    entries: Vec<QbClaudeUsageEntry>,
    strings: Vec<u8>,
}

// ---------------------------------------------------------------------------
// Canonical UTC timestamp parsing (mirror of OpenUsageISO8601's canonical fast path)
// ---------------------------------------------------------------------------

pub(crate) enum CanonicalTimestamp {
    /// Parsed successfully: seconds + millis since the epoch.
    Ok(f64),
    /// Canonical shape, invalid calendar values — Swift's `parseCanonicalUTC` returns nil for
    /// these and never reaches the Foundation fallback, so the line is malformed.
    Invalid,
    /// Not a shape this module accepts — the caller must fall back to the Swift path.
    NotCanonical,
}

pub(crate) fn is_ascii_digit(b: u8) -> bool {
    b.is_ascii_digit()
}

fn number(bytes: &[u8], range: std::ops::Range<usize>) -> u32 {
    let mut value: u32 = 0;
    for &b in &bytes[range] {
        value = value * 10 + u32::from(b - b'0');
    }
    value
}

pub(crate) fn parse_canonical_utc(s: &[u8]) -> CanonicalTimestamp {
    let (millis,) = match s.len() {
        20 if s[19] == b'Z' => (0,),
        24 if s[19] == b'.' && s[23] == b'Z' && s[20..23].iter().all(|&b| is_ascii_digit(b)) => {
            (number(s, 20..23),)
        }
        _ => return CanonicalTimestamp::NotCanonical,
    };

    if s[4] != b'-' || s[7] != b'-' || s[10] != b'T' || s[13] != b':' || s[16] != b':' {
        return CanonicalTimestamp::NotCanonical;
    }
    for (index, &b) in s.iter().enumerate() {
        match index {
            4 | 7 | 10 | 13 | 16 | 19 | 23 => {}
            _ => {
                if !is_ascii_digit(b) {
                    return CanonicalTimestamp::NotCanonical;
                }
            }
        }
    }
    let year = number(s, 0..4) as i64;
    let month = number(s, 5..7) as i64;
    let day = number(s, 8..10) as i64;
    let hour = number(s, 11..13) as i64;
    let minute = number(s, 14..16) as i64;
    let second = number(s, 17..19) as i64;

    if year <= 0 || !(1..=12).contains(&month) || hour >= 24 || minute >= 60 || second >= 60 {
        return CanonicalTimestamp::Invalid;
    }

    let is_leap_year = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    let maximum_day: i64 = match month {
        2 => {
            if is_leap_year {
                29
            } else {
                28
            }
        }
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    };
    if day < 1 || day > maximum_day {
        return CanonicalTimestamp::Invalid;
    }

    // Proleptic Gregorian days since 1970-01-01 (Howard Hinnant's civil-date transform).
    let adjusted_year = year - if month <= 2 { 1 } else { 0 };
    let era = adjusted_year.div_euclid(400);
    let year_of_era = adjusted_year - era * 400;
    let adjusted_month = month + if month > 2 { -3 } else { 9 };
    let day_of_year = (153 * adjusted_month + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    let days_since_epoch = era * 146_097 + day_of_era - 719_468;
    let whole_seconds = days_since_epoch * 86_400 + hour * 3_600 + minute * 60 + second;

    CanonicalTimestamp::Ok(whole_seconds as f64 + f64::from(millis) / 1_000.0)
}

// ---------------------------------------------------------------------------
// SemVer validation (mirror of ClaudeLogUsageScanner.isValidSemVer)
// ---------------------------------------------------------------------------

fn is_valid_semver_identifiers(value: &str, allow_numeric_leading_zero: bool) -> bool {
    let identifiers: Vec<&str> = value.split('.').collect();
    if identifiers.is_empty() {
        return false;
    }
    identifiers.iter().all(|identifier| {
        let bytes = identifier.as_bytes();
        if bytes.is_empty() {
            return false;
        }
        if !bytes.iter().all(|&b| {
            b.is_ascii_digit() || (65..=90).contains(&b) || (97..=122).contains(&b) || b == b'-'
        }) {
            return false;
        }
        if !allow_numeric_leading_zero
            && bytes.len() > 1
            && bytes.iter().all(|&b| b.is_ascii_digit())
            && bytes[0] == b'0'
        {
            return false;
        }
        true
    })
}

fn is_valid_semver(value: &str) -> bool {
    let mut build_parts = value.split('+');
    let release = build_parts.next().unwrap_or("");
    let build = build_parts.next();
    if build_parts.next().is_some() {
        return false;
    }
    if let Some(build) = build {
        if !is_valid_semver_identifiers(build, true) {
            return false;
        }
    }

    let mut release_parts = release.splitn(2, '-');
    let core = release_parts.next().unwrap_or("");
    let prerelease = release_parts.next();

    let core_parts: Vec<&str> = core.split('.').collect();
    if core_parts.len() != 3
        || !core_parts.iter().all(|part| {
            !part.is_empty()
                && part.bytes().all(is_ascii_digit)
                && (*part == "0" || !part.starts_with('0'))
        })
    {
        return false;
    }
    if let Some(prerelease) = prerelease {
        if !is_valid_semver_identifiers(prerelease, false) {
            return false;
        }
    }
    true
}

// ---------------------------------------------------------------------------
// Line parsing
// ---------------------------------------------------------------------------

struct Breakdown {
    input: u64,
    cache_write_5m: u64,
    cache_write_1h: u64,
    cache_read: u64,
    output: u64,
    is_fast: bool,
    has_speed: bool,
}

/// Mirror of `nonnegativeTokenCount`: a JSON number (never a bool), finite, in [0, 1e15],
/// integral. u64 JSON integers land here exactly; the f64 comparison rounds identically to
/// Swift's `NSNumber.doubleValue`.
fn nonnegative_token_count(v: &Value) -> Option<u64> {
    let number = match v {
        Value::Number(n) => n,
        _ => return None,
    };
    let f = number.as_f64()?;
    if !f.is_finite() || f < 0.0 || f > 1e15 || f.fract() != 0.0 {
        return None;
    }
    Some(f as u64)
}

/// Mirror of `optionalNonnegativeTokenCount`: absent or JSON null means zero.
fn optional_nonnegative_token_count(v: Option<&Value>) -> Option<u64> {
    match v {
        None => Some(0),
        Some(Value::Null) => Some(0),
        Some(other) => nonnegative_token_count(other),
    }
}

fn token_breakdown(usage: &Map<String, Value>, malformed: &mut bool) -> Option<Breakdown> {
    let input_raw = match usage.get("input_tokens") {
        Some(v) => v,
        None => {
            *malformed = true;
            return None;
        }
    };
    let output_raw = match usage.get("output_tokens") {
        Some(v) => v,
        None => {
            *malformed = true;
            return None;
        }
    };
    let input = nonnegative_token_count(input_raw);
    let output = nonnegative_token_count(output_raw);
    let (input, output) = match (input, output) {
        (Some(i), Some(o)) => (i, o),
        _ => {
            *malformed = true;
            return None;
        }
    };

    let cache_write_5m: u64;
    let mut cache_write_1h: u64 = 0;
    match usage.get("cache_creation") {
        None | Some(Value::Null) => {
            match optional_nonnegative_token_count(usage.get("cache_creation_input_tokens")) {
                Some(v) => cache_write_5m = v,
                None => {
                    *malformed = true;
                    return None;
                }
            }
        }
        Some(Value::Object(creation)) => {
            let split = optional_nonnegative_token_count(creation.get("ephemeral_5m_input_tokens"))
                .zip(optional_nonnegative_token_count(
                    creation.get("ephemeral_1h_input_tokens"),
                ));
            match split {
                Some((five, hour)) => {
                    cache_write_5m = five;
                    cache_write_1h = hour;
                }
                None => {
                    *malformed = true;
                    return None;
                }
            }
        }
        Some(_) => {
            *malformed = true;
            return None;
        }
    }

    let cache_read = match optional_nonnegative_token_count(usage.get("cache_read_input_tokens")) {
        Some(v) => v,
        None => {
            *malformed = true;
            return None;
        }
    };

    let speed: Option<&str> = match usage.get("speed") {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) if s == "fast" || s == "standard" => Some(s.as_str()),
        Some(_) => {
            *malformed = true;
            return None;
        }
    };

    Some(Breakdown {
        input,
        cache_write_5m,
        cache_write_1h,
        cache_read,
        output,
        is_fast: speed == Some("fast"),
        has_speed: speed.is_some(),
    })
}

fn is_valid_entry(object: &Map<String, Value>, message: &Map<String, Value>) -> bool {
    if let Some(raw_version) = object.get("version") {
        match raw_version {
            Value::String(s) if is_valid_semver(s) => {}
            _ => return false,
        }
    }
    for raw in [
        object.get("sessionId"),
        object.get("requestId"),
        message.get("id"),
    ] {
        if let Some(value) = raw {
            match value {
                Value::String(s) if !s.is_empty() => {}
                _ => return false,
            }
        }
    }
    if let Some(raw_sidechain) = object.get("isSidechain") {
        if !matches!(raw_sidechain, Value::Bool(_)) {
            return false;
        }
    }
    if let Some(raw_model) = message.get("model") {
        match raw_model {
            Value::String(s) if !s.trim().is_empty() => {}
            _ => return false,
        }
    }
    true
}

struct EntryOut {
    timestamp: f64,
    cost_usd: Option<f64>,
    breakdown: Breakdown,
    message_id: Option<String>,
    request_id: Option<String>,
    is_sidechain: bool,
    model: Option<String>,
}

enum LineOutcome {
    Parsed {
        malformed: bool,
        entries: Vec<EntryOut>,
    },
    /// Legal Swift input outside this module's supported shapes; caller re-runs the Swift path.
    Fallback,
}

fn parse_line(line: &[u8]) -> LineOutcome {
    let value: Value = match serde_json::from_slice(line) {
        Ok(v) => v,
        Err(_) => {
            return LineOutcome::Parsed {
                malformed: true,
                entries: Vec::new(),
            }
        }
    };
    let object = match &value {
        Value::Object(o) => o,
        _ => {
            return LineOutcome::Parsed {
                malformed: true,
                entries: Vec::new(),
            }
        }
    };

    // A non-assistant row is not accounting, even if it carries a usage key; it is skipped
    // without marking the line malformed (mirrors the Swift guard).
    if let Some(t) = object.get("type") {
        if t.as_str() != Some("assistant") {
            return LineOutcome::Parsed {
                malformed: false,
                entries: Vec::new(),
            };
        }
    }

    let message = match object.get("message").and_then(Value::as_object) {
        Some(m) => m,
        None => {
            // A claimed assistant accounting record in an unfamiliar shape must stay observable.
            let malformed = object.get("type").and_then(Value::as_str) == Some("assistant")
                && object.get("usage").is_some();
            return LineOutcome::Parsed {
                malformed,
                entries: Vec::new(),
            };
        }
    };
    let raw_usage = match message.get("usage") {
        Some(u) => u,
        None => {
            let malformed = object.get("type").and_then(Value::as_str) == Some("assistant")
                && object.get("usage").is_some();
            return LineOutcome::Parsed {
                malformed,
                entries: Vec::new(),
            };
        }
    };
    let usage = match raw_usage {
        Value::Object(u) => u,
        _ => {
            return LineOutcome::Parsed {
                malformed: true,
                entries: Vec::new(),
            }
        }
    };

    let mut malformed = false;

    let timestamp_string = match object.get("timestamp").and_then(Value::as_str) {
        Some(s) => s,
        None => {
            return LineOutcome::Parsed {
                malformed: true,
                entries: Vec::new(),
            }
        }
    };
    let timestamp = match parse_canonical_utc(timestamp_string.as_bytes()) {
        CanonicalTimestamp::Ok(t) => t,
        CanonicalTimestamp::Invalid => {
            return LineOutcome::Parsed {
                malformed: true,
                entries: Vec::new(),
            }
        }
        CanonicalTimestamp::NotCanonical => return LineOutcome::Fallback,
    };

    if !is_valid_entry(object, message) {
        return LineOutcome::Parsed {
            malformed: true,
            entries: Vec::new(),
        };
    }

    let Some(parsed_usage) = token_breakdown(usage, &mut malformed) else {
        return LineOutcome::Parsed {
            malformed: true,
            entries: Vec::new(),
        };
    };

    let cost_usd: Option<f64> = match object.get("costUSD") {
        None | Some(Value::Null) => None,
        Some(Value::Number(n)) => {
            let value = n.as_f64().unwrap_or(f64::NAN);
            if !value.is_finite() || value < 0.0 || value > 1e12 {
                return LineOutcome::Parsed {
                    malformed: true,
                    entries: Vec::new(),
                };
            }
            Some(value)
        }
        Some(_) => {
            return LineOutcome::Parsed {
                malformed: true,
                entries: Vec::new(),
            }
        }
    };

    let model = message
        .get("model")
        .and_then(Value::as_str)
        .and_then(|m| (m != "<synthetic>").then(|| m.to_string()));
    let parent_message_id = message
        .get("id")
        .and_then(Value::as_str)
        .map(str::to_string);
    let request_id = object
        .get("requestId")
        .and_then(Value::as_str)
        .map(str::to_string);
    let is_sidechain = matches!(object.get("isSidechain"), Some(Value::Bool(true)));

    let parent = EntryOut {
        timestamp,
        cost_usd,
        breakdown: Breakdown {
            is_fast: parsed_usage.is_fast,
            has_speed: parsed_usage.has_speed,
            input: parsed_usage.input,
            cache_write_5m: parsed_usage.cache_write_5m,
            cache_write_1h: parsed_usage.cache_write_1h,
            cache_read: parsed_usage.cache_read,
            output: parsed_usage.output,
        },
        message_id: parent_message_id.clone(),
        request_id: request_id.clone(),
        is_sidechain,
        model,
    };

    let mut entries = vec![parent];

    match usage.get("iterations") {
        None | Some(Value::Null) => {}
        Some(Value::Array(iterations)) => {
            let mut advisor_index: usize = 0;
            for iteration in iterations {
                let iteration = match iteration.as_object() {
                    Some(i) => i,
                    None => {
                        malformed = true;
                        continue;
                    }
                };
                if let Some(raw_type) = iteration.get("type") {
                    if !raw_type.is_string() {
                        malformed = true;
                        continue;
                    }
                }
                if iteration.get("type").and_then(Value::as_str) != Some("advisor_message") {
                    continue;
                }
                let Some(advisor_usage) = token_breakdown(iteration, &mut malformed) else {
                    continue;
                };
                let advisor_model = iteration
                    .get("model")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(str::to_string);

                let message_id = parent_message_id
                    .as_ref()
                    .map(|id| format!("{id}:advisor:{advisor_index}"));
                entries.push(EntryOut {
                    timestamp,
                    cost_usd: None,
                    breakdown: Breakdown {
                        input: advisor_usage.input,
                        cache_write_5m: advisor_usage.cache_write_5m,
                        cache_write_1h: advisor_usage.cache_write_1h,
                        cache_read: advisor_usage.cache_read,
                        output: advisor_usage.output,
                        is_fast: advisor_usage.is_fast,
                        has_speed: advisor_usage.has_speed,
                    },
                    message_id,
                    request_id: request_id.clone(),
                    is_sidechain,
                    model: advisor_model,
                });
                advisor_index += 1;
            }
        }
        Some(_) => {
            malformed = true;
        }
    }

    if entries.len() > MAX_ENTRIES_PER_LINE {
        return LineOutcome::Fallback;
    }

    LineOutcome::Parsed { malformed, entries }
}

// ---------------------------------------------------------------------------
// C ABI
// ---------------------------------------------------------------------------

pub(crate) fn intern(blob: &mut Vec<u8>, s: &str) -> Option<(u32, u32)> {
    let offset: u32 = blob.len().try_into().ok()?;
    let length: u32 = s.len().try_into().ok()?;
    if u64::from(offset) + u64::from(length) > u64::from(u32::MAX) {
        return None;
    }
    blob.extend_from_slice(s.as_bytes());
    Some((offset, length))
}

/// Intern every string field of `entries` into one UTF-8 blob and produce the `#[repr(C)]`
/// array. `None` means a blob offset overflowed u32 — the caller treats it as fallback.
fn pack_entries(entries: &[EntryOut]) -> Option<(Vec<QbClaudeUsageEntry>, Vec<u8>)> {
    let mut strings: Vec<u8> = Vec::new();
    let mut ffi_entries: Vec<QbClaudeUsageEntry> = Vec::with_capacity(entries.len());
    for entry in entries {
        let (message_id_offset, message_id_length) = match &entry.message_id {
            Some(s) => intern(&mut strings, s)?,
            None => (NIL_STRING, 0),
        };
        let (request_id_offset, request_id_length) = match &entry.request_id {
            Some(s) => intern(&mut strings, s)?,
            None => (NIL_STRING, 0),
        };
        let (model_offset, model_length) = match &entry.model {
            Some(s) => intern(&mut strings, s)?,
            None => (NIL_STRING, 0),
        };
        ffi_entries.push(QbClaudeUsageEntry {
            timestamp: entry.timestamp,
            cost_usd: entry.cost_usd.unwrap_or(0.0),
            input_tokens: entry.breakdown.input,
            cache_write_5m: entry.breakdown.cache_write_5m,
            cache_write_1h: entry.breakdown.cache_write_1h,
            cache_read: entry.breakdown.cache_read,
            output_tokens: entry.breakdown.output,
            message_id_offset,
            message_id_length,
            request_id_offset,
            request_id_length,
            model_offset,
            model_length,
            is_sidechain: u8::from(entry.is_sidechain),
            has_speed: u8::from(entry.breakdown.has_speed),
            is_fast: u8::from(entry.breakdown.is_fast),
            has_cost_usd: u8::from(entry.cost_usd.is_some()),
            reserved: [0; 4],
        });
    }
    Some((ffi_entries, strings))
}

fn build_result(outcome: LineOutcome) -> *mut ClaudeParseResult {
    let LineOutcome::Parsed { malformed, entries } = outcome else {
        return ptr::null_mut();
    };
    match pack_entries(&entries) {
        Some((ffi_entries, strings)) => Box::into_raw(Box::new(ClaudeParseResult {
            malformed: u32::from(malformed),
            entries: ffi_entries,
            strings,
        })),
        None => ptr::null_mut(),
    }
}

/// ABI version of this library. Bump when the entry layout changes.
///
/// v3 adds whole-file parsing (`qb_*_parse_file` + `qb_cancel_callback` + `QB_FILE_*`) and the
/// Grok/Pi/Muse/CodexRouter event + Antigravity generation-entry surfaces.
#[no_mangle]
pub extern "C" fn qb_core_version() -> u32 {
    3
}

/// Parse one Claude usage line.
///
/// Returns a heap-allocated result the caller must pass to [`qb_claude_result_destroy`], or a
/// null pointer when the line is legal input this module does not support — the caller is
/// expected to fall back to its own implementation. A null pointer is never an error.
#[no_mangle]
pub extern "C" fn qb_claude_parse_usage_line(
    line: *const u8,
    line_len: usize,
) -> *mut ClaudeParseResult {
    if line.is_null() && line_len > 0 {
        return ptr::null_mut();
    }
    let bytes = if line.is_null() {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(line, line_len) }
    };
    match catch_unwind(AssertUnwindSafe(|| build_result(parse_line(bytes)))) {
        Ok(ptr) => ptr,
        Err(_) => ptr::null_mut(),
    }
}

/// Always [`QB_CLAUDE_STATUS_PARSED`] for a non-null result; null results signal fallback.
#[no_mangle]
pub extern "C" fn qb_claude_result_status(result: *const ClaudeParseResult) -> u32 {
    if result.is_null() {
        return QB_CLAUDE_STATUS_FALLBACK;
    }
    QB_CLAUDE_STATUS_PARSED
}

/// Nonzero when any part of the line failed Swift's `malformedTokenCounts` accounting — the
/// caller must treat the file as containing an unresolved row (same semantics as Swift).
#[no_mangle]
pub extern "C" fn qb_claude_result_malformed(result: *const ClaudeParseResult) -> u32 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.malformed
}

#[no_mangle]
pub extern "C" fn qb_claude_result_entry_count(result: *const ClaudeParseResult) -> u32 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.entries.len() as u32
}

/// Pointer to the entry array; valid until [`qb_claude_result_destroy`].
#[no_mangle]
pub extern "C" fn qb_claude_result_entries(
    result: *const ClaudeParseResult,
) -> *const QbClaudeUsageEntry {
    if result.is_null() {
        return ptr::null();
    }
    unsafe { &*result }.entries.as_ptr()
}

/// Pointer to the UTF-8 string blob the entry offsets index into, plus its byte length.
#[no_mangle]
pub extern "C" fn qb_claude_result_strings(
    result: *const ClaudeParseResult,
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
/// `result` must be a pointer returned by [`qb_claude_parse_usage_line`], destroyed at most once.
#[no_mangle]
pub unsafe extern "C" fn qb_claude_result_destroy(result: *mut ClaudeParseResult) {
    if result.is_null() {
        return;
    }
    unsafe { drop(Box::from_raw(result)) };
}

// ---------------------------------------------------------------------------
// Whole-file driver (qb_claude_parse_file)
// ---------------------------------------------------------------------------

/// Byte gate mirroring `ClaudeLogUsageScanner.usageMarker` (`Data(#""usage""#.utf8)`): only lines
/// carrying the literal `"usage"` reach the JSON parser; every other line is skipped.
const USAGE_MARKER: &[u8] = b"\"usage\"";

/// Whole-file result for `qb_claude_parse_file`. `status` is one of the shared `QB_FILE_*`
/// codes; `malformed` is the OR of every line's `malformedTokenCounts` signal.
pub struct ClaudeFileResult {
    status: u32,
    malformed: u32,
    entries: Vec<QbClaudeUsageEntry>,
    strings: Vec<u8>,
    bytes_read: u64,
    oversized_lines_skipped: u64,
}

struct ClaudeFileParser {
    entries: Vec<EntryOut>,
    malformed: bool,
    fell_back: bool,
}

impl ClaudeFileParser {
    /// `deliver` callback for `scan_file_lines`. Fallback aborts the scan immediately (the file
    /// is re-parsed in Swift); a malformed line only sets the flag — the read continues to EOF so
    /// its completeness is judged exactly the way `read.isComplete` is in Swift.
    fn consume(&mut self, line: &[u8]) -> bool {
        if memchr::memmem::find(line, USAGE_MARKER).is_none() {
            return true;
        }
        match parse_line(line) {
            LineOutcome::Parsed { malformed, entries } => {
                if malformed {
                    // The Swift per-line callback returns nil for a malformed line — its entries
                    // are discarded, and the flag makes the whole file unusable.
                    self.malformed = true;
                } else {
                    self.entries.extend(entries);
                }
                true
            }
            LineOutcome::Fallback => {
                self.fell_back = true;
                false
            }
        }
    }
}

/// Parse one Claude session file end to end, mirroring `ClaudeLogUsageScanner.parseFile(at:)` via
/// `ClaudeSessionAppendCache`: complete lines plus the trailing unterminated fragment all run the
/// same marker gate + line parser; any malformed usage row, a read failure, an oversized line, or
/// cancellation fails the file the way the Swift path returns nil.
fn claude_parse_file_impl(
    path: &[u8],
    start_offset: u64,
    end_offset: Option<u64>,
    cancel_ctx: *mut c_void,
    cancel: Option<CancelCallback>,
) -> ClaudeFileResult {
    let mut parser = ClaudeFileParser {
        entries: Vec::new(),
        malformed: false,
        fell_back: false,
    };
    // The Swift path hands the trailing newline-less fragment to the same per-line parser
    // (`parseFragment` → `parseLine`), so the final partial is delivered like any other line.
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

    let bare = |status: u32, malformed: bool| ClaudeFileResult {
        status,
        malformed: u32::from(malformed),
        entries: Vec::new(),
        strings: Vec::new(),
        bytes_read: stats.bytes_read,
        oversized_lines_skipped: stats.oversized_lines_skipped,
    };

    if parser.fell_back {
        return bare(QB_FILE_FALLBACK, false);
    }
    // Mirror `read.isComplete, !malformed`: read success, no oversized lines, not left
    // discarding — then the file-level malformed flag applies.
    let complete = stats.succeeded
        && stats.oversized_lines_skipped == 0
        && !stats.is_discarding_oversized_line;
    if !complete || parser.malformed {
        return bare(QB_FILE_FAILED, parser.malformed);
    }
    match pack_entries(&parser.entries) {
        Some((entries, strings)) => ClaudeFileResult {
            status: QB_FILE_OK,
            malformed: 0,
            entries,
            strings,
            bytes_read: stats.bytes_read,
            oversized_lines_skipped: stats.oversized_lines_skipped,
        },
        None => bare(QB_FILE_FALLBACK, false),
    }
}

/// Parse one Claude session `.jsonl` file end to end: the Rust side streams, splits, and parses
/// every line without materializing Foundation objects. `end_offset` of UINT64_MAX reads to EOF.
/// `cancel` is invoked once per 64 KiB chunk. Returns a heap-allocated result (never NULL for a
/// completed call); NULL itself is treated like `QB_FILE_FALLBACK`.
#[no_mangle]
pub extern "C" fn qb_claude_parse_file(
    path: *const u8,
    path_len: usize,
    start_offset: u64,
    end_offset: u64,
    cancel: Option<CancelCallback>,
    cancel_ctx: *mut c_void,
) -> *mut ClaudeFileResult {
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
        Box::into_raw(Box::new(claude_parse_file_impl(
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

/// One of the shared `QB_FILE_*` codes; NULL reads as `QB_FILE_FALLBACK`.
#[no_mangle]
pub extern "C" fn qb_claude_file_result_status(result: *const ClaudeFileResult) -> u32 {
    if result.is_null() {
        return QB_FILE_FALLBACK;
    }
    unsafe { &*result }.status
}

/// Nonzero when any line in the file carried malformed usage data — the same flag that makes the
/// Swift `parseFile(at:)` return nil (surfaced on `QB_FILE_FAILED` results for diagnostics).
#[no_mangle]
pub extern "C" fn qb_claude_file_result_malformed(result: *const ClaudeFileResult) -> u32 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.malformed
}

#[no_mangle]
pub extern "C" fn qb_claude_file_result_entry_count(result: *const ClaudeFileResult) -> u32 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.entries.len() as u32
}

/// Pointer to the entry array; valid until [`qb_claude_file_result_destroy`].
#[no_mangle]
pub extern "C" fn qb_claude_file_result_entries(
    result: *const ClaudeFileResult,
) -> *const QbClaudeUsageEntry {
    if result.is_null() {
        return ptr::null();
    }
    unsafe { &*result }.entries.as_ptr()
}

/// Pointer to the UTF-8 string blob the entry offsets index into, plus its byte length.
#[no_mangle]
pub extern "C" fn qb_claude_file_result_strings(
    result: *const ClaudeFileResult,
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
pub extern "C" fn qb_claude_file_result_bytes_read(result: *const ClaudeFileResult) -> u64 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.bytes_read
}

#[no_mangle]
pub extern "C" fn qb_claude_file_result_oversized_lines(result: *const ClaudeFileResult) -> u64 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.oversized_lines_skipped
}

/// # Safety
/// `result` must be a pointer returned by [`qb_claude_parse_file`], destroyed at most once.
#[no_mangle]
pub unsafe extern "C" fn qb_claude_file_result_destroy(result: *mut ClaudeFileResult) {
    if result.is_null() {
        return;
    }
    unsafe { drop(Box::from_raw(result)) };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(line: &str) -> (bool, Vec<EntryOut>) {
        match parse_line(line.as_bytes()) {
            LineOutcome::Parsed { malformed, entries } => (malformed, entries),
            LineOutcome::Fallback => panic!("expected parsed outcome, got fallback"),
        }
    }

    #[test]
    fn modern_line_with_cache_split_and_fast_speed() {
        let line = r#"{"timestamp":"2026-02-20T12:00:00.000Z","sessionId":"s","requestId":"req_1","version":"1.0.24","isSidechain":true,"costUSD":0.5,"message":{"id":"msg_1","model":"claude-test-model","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":30,"cache_creation":{"ephemeral_5m_input_tokens":20,"ephemeral_1h_input_tokens":10},"speed":"fast"}}}"#;
        let (malformed, entries) = parse(line);
        assert!(!malformed);
        assert_eq!(entries.len(), 1);
        let e = &entries[0];
        assert_eq!(e.breakdown.input, 100);
        assert_eq!(e.breakdown.cache_write_5m, 20);
        assert_eq!(e.breakdown.cache_write_1h, 10);
        assert_eq!(e.breakdown.cache_read, 30);
        assert_eq!(e.breakdown.output, 50);
        assert!(e.breakdown.is_fast);
        assert!(e.breakdown.has_speed);
        assert_eq!(e.cost_usd, Some(0.5));
        assert_eq!(e.message_id.as_deref(), Some("msg_1"));
        assert_eq!(e.request_id.as_deref(), Some("req_1"));
        assert_eq!(e.model.as_deref(), Some("claude-test-model"));
        assert!(e.is_sidechain);
        assert_eq!(e.timestamp, 1_771_588_800.0);
    }

    #[test]
    fn legacy_cache_creation_counts_as_five_minute_writes() {
        let line = r#"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"m","model":"x","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":40,"cache_read_input_tokens":7}}}"#;
        let (malformed, entries) = parse(line);
        assert!(!malformed);
        assert_eq!(entries[0].breakdown.cache_write_5m, 40);
        assert_eq!(entries[0].breakdown.cache_write_1h, 0);
        assert_eq!(entries[0].breakdown.cache_read, 7);
        assert!(!entries[0].breakdown.has_speed);
        assert_eq!(entries[0].cost_usd, None);
    }

    #[test]
    fn advisor_iterations_become_extra_entries() {
        let line = r#"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"msg_9","model":"opus","usage":{"input_tokens":10,"output_tokens":5,"iterations":[{"type":"message"},{"type":"advisor_message","model":" advisor-model ","input_tokens":70,"output_tokens":30,"speed":"standard"},{"type":"advisor_message","input_tokens":1,"output_tokens":2}]}}}"#;
        let (malformed, entries) = parse(line);
        assert!(!malformed);
        assert_eq!(entries.len(), 3);
        assert_eq!(entries[1].message_id.as_deref(), Some("msg_9:advisor:0"));
        assert_eq!(entries[1].model.as_deref(), Some("advisor-model"));
        assert_eq!(entries[1].breakdown.input, 70);
        assert!(entries[1].breakdown.has_speed);
        assert!(!entries[1].breakdown.is_fast);
        assert_eq!(entries[2].message_id.as_deref(), Some("msg_9:advisor:1"));
        assert_eq!(entries[2].model, None);
    }

    #[test]
    fn non_advisor_iterations_do_not_add_entries() {
        let line = r#"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"m","usage":{"input_tokens":10,"output_tokens":5,"iterations":[{"type":"message"},{"type":"tool_use"}]}}}"#;
        let (malformed, entries) = parse(line);
        assert!(!malformed);
        assert_eq!(entries.len(), 1);
    }

    #[test]
    fn advisor_iteration_non_string_type_marks_malformed() {
        let line = r#"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"m","usage":{"input_tokens":10,"output_tokens":5,"iterations":[{"type":7}]}}}"#;
        let (malformed, entries) = parse(line);
        assert!(malformed);
        assert_eq!(entries.len(), 1);
    }

    #[test]
    fn advisor_iterations_non_array_marks_malformed() {
        let line = r#"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"m","usage":{"input_tokens":10,"output_tokens":5,"iterations":{"type":"advisor_message"}}}}"#;
        let (malformed, entries) = parse(line);
        assert!(malformed);
        assert_eq!(entries.len(), 1);
    }

    #[test]
    fn invalid_speed_marks_line_malformed() {
        let line = r#"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"m","usage":{"input_tokens":10,"output_tokens":5,"speed":"turbo"}}}"#;
        let (malformed, entries) = parse(line);
        assert!(malformed);
        assert!(entries.is_empty());
    }

    #[test]
    fn cost_usd_must_be_a_nonnegative_finite_number() {
        for (raw, expected) in [
            ("\"costUSD\":true", true),
            ("\"costUSD\":-1", true),
            ("\"costUSD\":1e13", true),
            ("\"costUSD\":null", false),
            ("\"costUSD\":0", false),
            ("\"costUSD\":1234.5", false),
        ] {
            let line = format!(
                r#"{{"timestamp":"2026-02-20T12:00:00.000Z",{raw},"message":{{"id":"m","usage":{{"input_tokens":1,"output_tokens":2}}}}}}"#
            );
            let (malformed, _) = parse(&line);
            assert_eq!(malformed, expected, "cost case: {raw}");
        }
    }

    #[test]
    fn invalid_version_rejects_line() {
        let line = r#"{"timestamp":"2026-02-20T12:00:00.000Z","version":"1.0","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#;
        let (malformed, entries) = parse(line);
        assert!(malformed);
        assert!(entries.is_empty());
    }

    #[test]
    fn semver_rules() {
        assert!(is_valid_semver("1.0.24"));
        assert!(is_valid_semver("0.0.0"));
        assert!(is_valid_semver("1.2.3-rc.1"));
        assert!(is_valid_semver("1.2.3+build.5"));
        assert!(is_valid_semver("1.2.3-rc.1+build.5"));
        assert!(!is_valid_semver("1.2"));
        assert!(!is_valid_semver("1.2.3.4"));
        assert!(!is_valid_semver("01.2.3"));
        assert!(!is_valid_semver("1.2.3-01"));
        // Numeric prerelease identifiers with leading zero are invalid SemVer.
        assert!(!is_valid_semver("1.2.3-rc.01"));
        assert!(is_valid_semver("1.2.3-rc.1"));
        assert!(!is_valid_semver("1.2.3+"));
        assert!(!is_valid_semver("1.2.3+build..5"));
        assert!(!is_valid_semver("1.2.3-"));
    }

    #[test]
    fn token_counts_reject_non_numbers_bools_and_fractional() {
        for raw in [
            "\"input_tokens\":\"5\"",
            "\"input_tokens\":true",
            "\"input_tokens\":1.5",
            "\"input_tokens\":1000000000000001",
        ] {
            let line = format!(
                r#"{{"timestamp":"2026-02-20T12:00:00.000Z","message":{{"id":"m","usage":{{{raw},"output_tokens":2}}}}}}"#
            );
            let (malformed, entries) = parse(&line);
            assert!(malformed, "token case: {raw}");
            assert!(entries.is_empty());
        }
    }

    #[test]
    fn non_assistant_rows_are_skipped_silently() {
        for t in [r#""type":"user""#, r#""type":7"#] {
            let line = format!(
                r#"{{"timestamp":"2026-02-20T12:00:00.000Z",{t},"message":{{"id":"m","usage":{{"input_tokens":1,"output_tokens":2}}}}}}"#
            );
            let (malformed, entries) = parse(&line);
            assert!(!malformed);
            assert!(entries.is_empty());
        }
    }

    #[test]
    fn assistant_with_unfamiliar_shape_is_observable() {
        let line = r#"{"type":"assistant","usage":{"input_tokens":1},"timestamp":"2026-02-20T12:00:00.000Z"}"#;
        let (malformed, entries) = parse(line);
        assert!(malformed);
        assert!(entries.is_empty());
    }

    #[test]
    fn timestamp_shapes() {
        // Canonical non-fractional UTC.
        let (m, entries) = parse(
            r#"{"timestamp":"2026-02-20T12:00:00Z","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        );
        assert!(!m);
        assert_eq!(entries.len(), 1);

        // Canonical datetime with invalid month is malformed in Swift too (Foundation is never
        // consulted for canonical shapes).
        let (m, entries) = parse(
            r#"{"timestamp":"2026-13-20T12:00:00Z","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        );
        assert!(m);
        assert!(entries.is_empty());

        // Non-canonical shapes fall back to the Swift path.
        for ts in [
            "2026-02-20 12:00:00",
            "2026-02-20T12:00:00.39Z",
            "2026-02-20T12:00:00.1234Z",
            "2026-02-20T12:00:00+00:00",
            "2026-02-20T12:00:00.123456Z",
        ] {
            let line = format!(
                r#"{{"timestamp":"{ts}","message":{{"id":"m","usage":{{"input_tokens":1,"output_tokens":2}}}}}}"#
            );
            assert!(
                matches!(parse_line(line.as_bytes()), LineOutcome::Fallback),
                "expected fallback for {ts}"
            );
        }
    }

    #[test]
    fn leap_day_handling() {
        let ok = r#"{"timestamp":"2024-02-29T00:00:00.000Z","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#;
        assert!(!parse(ok).0);
        let bad = r#"{"timestamp":"2026-02-29T00:00:00.000Z","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":2}}}"#;
        assert!(parse(bad).0);
    }

    #[test]
    fn synthetic_model_becomes_nil() {
        let line = r#"{"timestamp":"2026-02-20T12:00:00.000Z","message":{"id":"m","model":"<synthetic>","usage":{"input_tokens":1,"output_tokens":2}}}"#;
        let (malformed, entries) = parse(line);
        assert!(!malformed);
        assert_eq!(entries[0].model, None);
    }

    #[test]
    fn invalid_json_and_non_object_are_malformed() {
        assert!(parse("not json").0);
        assert!(parse("").0);
        assert!(parse("123").0);
        assert!(parse("[1,2]").0);
    }

    #[test]
    fn entry_cap_forces_fallback() {
        let mut advisor_iters = String::new();
        for _ in 0..100 {
            advisor_iters
                .push_str(r#"{"type":"advisor_message","input_tokens":1,"output_tokens":1},"#);
        }
        let advisor_iters = advisor_iters.trim_end_matches(',');
        let line = format!(
            r#"{{"timestamp":"2026-02-20T12:00:00.000Z","message":{{"id":"m","usage":{{"input_tokens":1,"output_tokens":2,"iterations":[{advisor_iters}]}}}}}}"#
        );
        assert!(matches!(parse_line(line.as_bytes()), LineOutcome::Fallback));
    }

    // -------------------------------------------------------------------
    // Whole-file driver (qb_claude_parse_file / claude_parse_file_impl)
    // -------------------------------------------------------------------

    fn write_temp_file(bytes: &[u8]) -> String {
        use std::io::Write;
        use std::sync::atomic::{AtomicU64, Ordering};
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "quotabar-claude-file-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let mut file = std::fs::File::create(&path).expect("create temp");
        file.write_all(bytes).expect("write temp");
        path.to_str().expect("utf8 temp path").to_string()
    }

    fn usage_line(id: &str, input: u64) -> String {
        format!(
            r#"{{"timestamp":"2026-02-20T12:00:00Z","requestId":"r{id}","message":{{"id":"{id}","model":"claude-test-model","usage":{{"input_tokens":{input},"output_tokens":5}}}}}}"#
        )
    }

    fn parse_file(path: &str) -> ClaudeFileResult {
        claude_parse_file_impl(path.as_bytes(), 0, None, std::ptr::null_mut(), None)
    }

    #[test]
    fn file_parses_multiline_file_and_noise() {
        let contents = format!(
            "{{\"noise\":true}}\n{}\n{{\"usage\":\"not an object\"}}\n{}\n",
            usage_line("m1", 10),
            usage_line("m2", 20)
        );
        // `"usage":"not an object"` carries the marker so it reaches the parser — the JSON is
        // valid but has no message.usage, a skipped non-malformed row.
        let path = write_temp_file(contents.as_bytes());
        let result = parse_file(&path);
        std::fs::remove_file(&path).ok();
        assert_eq!(result.status, QB_FILE_OK);
        assert_eq!(result.malformed, 0);
        assert_eq!(result.entries.len(), 2);
        assert_eq!(result.entries[0].input_tokens, 10);
        assert_eq!(result.entries[1].input_tokens, 20);
        assert_eq!(result.bytes_read, contents.len() as u64);
    }

    #[test]
    fn file_trailing_unterminated_line_is_parsed() {
        let contents = format!("{}\n{}", usage_line("m1", 10), usage_line("m2", 20));
        let path = write_temp_file(contents.as_bytes());
        let result = parse_file(&path);
        std::fs::remove_file(&path).ok();
        assert_eq!(result.status, QB_FILE_OK);
        assert_eq!(result.entries.len(), 2);
    }

    #[test]
    fn file_empty_is_ok_with_no_entries() {
        let path = write_temp_file(b"");
        let result = parse_file(&path);
        std::fs::remove_file(&path).ok();
        assert_eq!(result.status, QB_FILE_OK);
        assert_eq!(result.entries.len(), 0);
    }

    #[test]
    fn file_missing_fails() {
        let result = parse_file("/nonexistent/quotabar-claude-test");
        assert_eq!(result.status, QB_FILE_FAILED);
        assert_eq!(result.malformed, 0);
    }

    #[test]
    fn file_malformed_usage_row_fails_with_flag() {
        // The marker gate admits the line (`"usage"` is present); the invalid JSON body is
        // malformed in Swift too, so the whole file answers nil.
        let contents = format!(
            "{}\n{{\"usage\": not-json\n{}\n",
            usage_line("m1", 10),
            usage_line("m2", 20)
        );
        let path = write_temp_file(contents.as_bytes());
        let result = parse_file(&path);
        std::fs::remove_file(&path).ok();
        assert_eq!(result.status, QB_FILE_FAILED);
        assert_eq!(result.malformed, 1);
        assert!(result.entries.is_empty());
    }

    #[test]
    fn file_non_canonical_timestamp_falls_back() {
        let contents = format!(
            "{}\n{}\n",
            usage_line("m1", 10),
            r#"{"timestamp":"2026-02-20T12:00:00+00:00","message":{"id":"m2","usage":{"input_tokens":1,"output_tokens":2}}}"#
        );
        let path = write_temp_file(contents.as_bytes());
        let result = parse_file(&path);
        std::fs::remove_file(&path).ok();
        assert_eq!(result.status, QB_FILE_FALLBACK);
        assert!(result.entries.is_empty());
    }

    #[test]
    fn file_cancelled_read_fails() {
        extern "C" fn always_cancel(_ctx: *mut c_void) -> u8 {
            1
        }
        let path = write_temp_file(format!("{}\n", usage_line("m1", 10)).as_bytes());
        let result = claude_parse_file_impl(
            path.as_bytes(),
            0,
            None,
            std::ptr::null_mut(),
            Some(always_cancel),
        );
        std::fs::remove_file(&path).ok();
        assert_eq!(result.status, QB_FILE_FAILED);
        assert_eq!(result.malformed, 0);
    }
}
