//! CodexRouter event-line parser — a byte-level port of `CodexRouterEventLineParser` and its
//! `JSONLineStructure` structural walker (`Sources/QuotaBar/Providers/Codex/
//! CodexRouterEventLineParser.swift`, `Sources/QuotaBar/Providers/JSONLineStructure.swift`),
//! plus a whole-file driver (`qb_codex_router_parse_file`) built on `crate::scanfile`.
//!
//! Unlike the other Rust parsers this one does not run serde_json on the fast path: the Swift
//! implementation is a hand-rolled byte-level walker (a ledger line never materializes a
//! Foundation object graph), and this module is a line-for-line port of it. serde_json-free
//! grammar only matters for the *structural-bail* verdict, where the Swift parser asks
//! `JSONSerialization` (fragmentsAllowed) whether a line it could not walk is still a valid
//! JSON object. That check is reimplemented here against the acceptance rules Foundation's
//! modern parser actually applies — probed on macOS, see `bail_verdict`:
//!
//! - one leading UTF-8 BOM at byte 0 is tolerated (and only there),
//! - a single trailing comma before `}` or `]` is accepted at any depth,
//! - integer-part digit runs must fit `Decimal`'s range (`(2^128 - 1) * 10^127`);
//!   fraction and exponent digits do not count toward it,
//! - a float-shaped number that evaluates to `+inf` is rejected, while `-inf` is accepted,
//! - strings must decode with paired `\uXXXX` surrogates,
//! - nesting is bounded at depth 512.
//!
//! Fallback contract: an `at` timestamp string that is not one of the canonical UTC shapes in
//! `crate::parse_canonical_utc` is legal Swift input (`OpenUsageISO8601` normalizes more
//! shapes), so the line reports `Fallback` — NULL on the FFI surface — and the Swift
//! reference produces the verdict. The whole-file driver likewise answers `QB_FILE_FALLBACK`
//! rather than mixing engines within one file.

use crate::scanfile::{self, CancelCallback, QB_FILE_FAILED, QB_FILE_FALLBACK, QB_FILE_OK};
use crate::{intern, parse_canonical_utc, CanonicalTimestamp, NIL_STRING};
use std::os::raw::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;

// ---------------------------------------------------------------------------
// C ABI types
// ---------------------------------------------------------------------------

/// One parsed CodexRouter `Event`. Mirrors `CodexRouterUsageScanner.Event` in Swift: string
/// offsets index into the UTF-8 blob returned by `qb_codex_router_*_result_strings`;
/// `UINT32_MAX` marks an absent optional string. `total_tokens` is valid only when
/// `has_total_tokens != 0`. The four optional-Bool flags are tri-state:
/// 0 = nil, 1 = false, 2 = true.
#[repr(C)]
pub struct QbCodexRouterEvent {
    /// Seconds since the Unix epoch; `Date.distantPast` (-62135769600) when the timestamp
    /// field is missing/unparseable (mirrors the Swift malformed-event payload).
    pub timestamp: f64,
    pub status: i64,
    pub input_tokens: i64,
    pub cached_input_tokens: i64,
    pub output_tokens: i64,
    pub reasoning_tokens: i64,
    pub total_tokens: i64,
    /// Resolved display model (never nil: "Unattributed" when the field is absent/empty).
    pub model_offset: u32,
    pub model_length: u32,
    /// Resolved provider (never nil: "unknown" when the field is absent/empty).
    pub provider_offset: u32,
    pub provider_length: u32,
    pub service_tier_offset: u32,
    pub service_tier_length: u32,
    pub account_id_offset: u32,
    pub account_id_length: u32,
    pub account_fingerprint_offset: u32,
    pub account_fingerprint_length: u32,
    pub has_valid_status_field: u8,
    pub has_valid_timestamp_field: u8,
    pub has_valid_model_field: u8,
    pub has_unique_status_field: u8,
    pub has_unique_provider_field: u8,
    pub has_unique_model_field: u8,
    pub has_unique_account_identity_fields: u8,
    pub has_valid_numeric_count_fields: u8,
    pub has_unique_recognized_fields: u8,
    pub has_total_tokens: u8,
    pub has_input_tokens_field: u8,
    pub has_output_tokens_field: u8,
    pub has_valid_cached_input_tokens_field: u8,
    pub has_valid_total_tokens_field: u8,
    pub has_valid_estimated_input_tokens_field: u8,
    pub has_valid_account_identity_fields: u8,
    /// Tri-state tags: 0 = nil, 1 = false, 2 = true.
    pub has_estimated_input_tokens: u8,
    pub has_valid_provider_field: u8,
    pub has_valid_service_tier_field: u8,
    pub token_count_saturated: u8,
    pub reserved: [u8; 4],
}

/// Per-line verdict codes returned by `qb_codex_router_line_result_verdict`.
/// Mirrors `CodexRouterEventLineParser.LineResult`.
pub const QB_ROUTER_LINE_EVENT: u32 = 0;
pub const QB_ROUTER_LINE_MALFORMED_EVENT: u32 = 1;
pub const QB_ROUTER_LINE_IRRELEVANT: u32 = 2;
pub const QB_ROUTER_LINE_MALFORMED: u32 = 3;

pub struct RouterLineResult {
    verdict: u32,
    /// 0 or 1 events. An event accompanies verdicts `EVENT` and `MALFORMED_EVENT`, and also
    /// `IRRELEVANT` when it was produced by the non-2xx short circuit — Swift's `parse`
    /// surface still returns that event even though the verdict skips it.
    entries: Vec<QbCodexRouterEvent>,
    strings: Vec<u8>,
}

pub struct RouterFileResult {
    status: u32,
    entries: Vec<QbCodexRouterEvent>,
    strings: Vec<u8>,
    /// The trailing newline-less fragment retained for append-resume — empty unless the
    /// tail was skipped for lacking a `}` (mirrors `ReadResult.finalPartial`).
    final_partial: Vec<u8>,
    is_discarding_oversized_line: bool,
    bytes_read: u64,
    oversized_lines_skipped: u64,
}

// ---------------------------------------------------------------------------
// Byte helpers (mirror of JSONLineStructure)
// ---------------------------------------------------------------------------

#[inline]
fn is_ws(byte: u8) -> bool {
    byte == b' ' || byte == 0x09 || byte == 0x0A || byte == 0x0D
}

#[inline]
fn is_hex(byte: u8) -> bool {
    byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte) || (b'A'..=b'F').contains(&byte)
}

fn skip_ws(bytes: &[u8], cursor: &mut usize, end: usize) {
    while *cursor < end && is_ws(bytes[*cursor]) {
        *cursor += 1;
    }
}

/// Port of `JSONLineStructure.validUTF8Width`: strict UTF-8 multi-byte sequence validation —
/// overlong encodings, surrogates (0xED 0xA0..0xBF), and values above U+10FFFF are rejected.
fn valid_utf8_width(bytes: &[u8], index: usize, end: usize) -> Option<usize> {
    let first = bytes[index];
    let cont = |offset: usize, range: std::ops::RangeInclusive<u8>| {
        index + offset < end && range.contains(&bytes[index + offset])
    };
    match first {
        0xC2..=0xDF => {
            if cont(1, 0x80..=0xBF) {
                Some(2)
            } else {
                None
            }
        }
        0xE0 => {
            if cont(1, 0xA0..=0xBF) && cont(2, 0x80..=0xBF) {
                Some(3)
            } else {
                None
            }
        }
        0xE1..=0xEC | 0xEE..=0xEF => {
            if cont(1, 0x80..=0xBF) && cont(2, 0x80..=0xBF) {
                Some(3)
            } else {
                None
            }
        }
        0xED => {
            if cont(1, 0x80..=0x9F) && cont(2, 0x80..=0xBF) {
                Some(3)
            } else {
                None
            }
        }
        0xF0 => {
            if cont(1, 0x90..=0xBF) && cont(2, 0x80..=0xBF) && cont(3, 0x80..=0xBF) {
                Some(4)
            } else {
                None
            }
        }
        0xF1..=0xF3 => {
            if cont(1, 0x80..=0xBF) && cont(2, 0x80..=0xBF) && cont(3, 0x80..=0xBF) {
                Some(4)
            } else {
                None
            }
        }
        0xF4 => {
            if cont(1, 0x80..=0x8F) && cont(2, 0x80..=0xBF) && cont(3, 0x80..=0xBF) {
                Some(4)
            } else {
                None
            }
        }
        _ => None,
    }
}

struct StringToken {
    /// Byte range of the string content (between the quotes).
    content: std::ops::Range<usize>,
    /// First byte after the closing quote.
    next: usize,
    has_escapes: bool,
}

/// Port of `JSONLineStructure.scanString`: validates escape shape and UTF-8 width but does
/// NOT check surrogate pairing — the caller's decode step (JSONSerialization in Swift,
/// `decode_string` here) rejects unpaired surrogates.
fn scan_string(bytes: &[u8], opening_quote: usize, end: usize) -> Option<StringToken> {
    if opening_quote >= end || bytes[opening_quote] != b'"' {
        return None;
    }
    let mut cursor = opening_quote + 1;
    let mut has_escapes = false;
    while cursor < end {
        let byte = bytes[cursor];
        if byte == b'"' {
            return Some(StringToken {
                content: (opening_quote + 1)..cursor,
                next: cursor + 1,
                has_escapes,
            });
        }
        if byte == b'\\' {
            has_escapes = true;
            cursor += 1;
            if cursor >= end {
                return None;
            }
            match bytes[cursor] {
                b'"' | b'\\' | b'/' | b'b' | b'f' | b'n' | b'r' | b't' => cursor += 1,
                b'u' => {
                    if cursor + 4 >= end {
                        return None;
                    }
                    for index in (cursor + 1)..=(cursor + 4) {
                        if !is_hex(bytes[index]) {
                            return None;
                        }
                    }
                    cursor += 5;
                }
                _ => return None,
            }
            continue;
        }
        if byte < 0x20 {
            return None;
        }
        if byte < 0x80 {
            cursor += 1;
            continue;
        }
        cursor += valid_utf8_width(bytes, cursor, end)?;
    }
    None
}

/// Strict variant of `scan_string` used only on the structural-bail path: it additionally
/// rejects unpaired `\uXXXX` surrogates, matching JSONSerialization's decode.
fn scan_string_strict(bytes: &[u8], opening_quote: usize, end: usize) -> Option<StringToken> {
    if opening_quote >= end || bytes[opening_quote] != b'"' {
        return None;
    }
    let mut cursor = opening_quote + 1;
    let mut has_escapes = false;
    while cursor < end {
        let byte = bytes[cursor];
        if byte == b'"' {
            return Some(StringToken {
                content: (opening_quote + 1)..cursor,
                next: cursor + 1,
                has_escapes,
            });
        }
        if byte == b'\\' {
            has_escapes = true;
            cursor += 1;
            if cursor >= end {
                return None;
            }
            match bytes[cursor] {
                b'"' | b'\\' | b'/' | b'b' | b'f' | b'n' | b'r' | b't' => cursor += 1,
                b'u' => {
                    if cursor + 4 >= end {
                        return None;
                    }
                    let unit = hex4(bytes, cursor + 1)?;
                    cursor += 5;
                    if (0xD800..=0xDBFF).contains(&unit) {
                        // A high surrogate must be followed by a `\uDC00`–`\uDFFF` escape.
                        if cursor + 5 >= end || bytes[cursor] != b'\\' || bytes[cursor + 1] != b'u'
                        {
                            return None;
                        }
                        let low = hex4(bytes, cursor + 2)?;
                        if !(0xDC00..=0xDFFF).contains(&low) {
                            return None;
                        }
                        cursor += 6;
                    } else if (0xDC00..=0xDFFF).contains(&unit) {
                        return None;
                    }
                }
                _ => return None,
            }
            continue;
        }
        if byte < 0x20 {
            return None;
        }
        if byte < 0x80 {
            cursor += 1;
            continue;
        }
        cursor += valid_utf8_width(bytes, cursor, end)?;
    }
    None
}

fn hex4(bytes: &[u8], start: usize) -> Option<u32> {
    let mut value: u32 = 0;
    for index in start..(start + 4) {
        let b = *bytes.get(index)?;
        value = (value << 4) | u32::from(char::from(b).to_digit(16)?);
    }
    Some(value)
}

/// Port of `CodexRouterEventLineParser.decodeString`: without escapes the content is
/// already UTF-8-validated; with escapes it decodes exactly like the wrapped-
/// `["..."]` JSONSerialization call, including surrogate-pair requirements.
fn decode_string(bytes: &[u8], token: &StringToken) -> Option<String> {
    if !token.has_escapes {
        return std::str::from_utf8(&bytes[token.content.clone()])
            .ok()
            .map(String::from);
    }
    let content = &bytes[token.content.clone()];
    let mut out: Vec<u8> = Vec::with_capacity(content.len());
    let mut i = 0;
    while i < content.len() {
        let b = content[i];
        if b == b'\\' {
            i += 1; // scanString guarantees a following byte
            match content[i] {
                // One-byte escapes: `i` is at the escape letter — step past it.
                b'"' => {
                    out.push(b'"');
                    i += 1;
                }
                b'\\' => {
                    out.push(b'\\');
                    i += 1;
                }
                b'/' => {
                    out.push(b'/');
                    i += 1;
                }
                b'b' => {
                    out.push(0x08);
                    i += 1;
                }
                b'f' => {
                    out.push(0x0C);
                    i += 1;
                }
                b'n' => {
                    out.push(b'\n');
                    i += 1;
                }
                b'r' => {
                    out.push(b'\r');
                    i += 1;
                }
                b't' => {
                    out.push(b'\t');
                    i += 1;
                }
                b'u' => {
                    let unit = hex4(content, i + 1)?;
                    let scalar = if (0xD800..=0xDBFF).contains(&unit) {
                        // Pair required: `\u` + low surrogate directly after this escape.
                        if i + 10 < content.len()
                            && content[i + 5] == b'\\'
                            && content[i + 6] == b'u'
                        {
                            let low = hex4(content, i + 7)?;
                            if (0xDC00..=0xDFFF).contains(&low) {
                                i += 11; // `uXXXX` + `\uYYYY`
                                0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                            } else {
                                return None;
                            }
                        } else {
                            return None;
                        }
                    } else if (0xDC00..=0xDFFF).contains(&unit) {
                        return None;
                    } else {
                        i += 5; // `uXXXX`
                        unit
                    };
                    let mut buf = [0u8; 4];
                    out.extend_from_slice(char::from_u32(scalar)?.encode_utf8(&mut buf).as_bytes());
                }
                _ => return None,
            }
        } else {
            out.push(b);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

// ---------------------------------------------------------------------------
// Structural skip (port of JSONLineStructure.skipValue / parseValue, depth ≤ 128)
// ---------------------------------------------------------------------------

const SKIP_DEPTH_LIMIT: usize = 128;

fn skip_value(bytes: &[u8], start: usize, end: usize) -> Option<usize> {
    let mut cursor = start;
    skip_ws(bytes, &mut cursor, end);
    if !parse_value(bytes, &mut cursor, end, 0) {
        return None;
    }
    Some(cursor)
}

fn parse_value(bytes: &[u8], cursor: &mut usize, end: usize, depth: usize) -> bool {
    if *cursor >= end || depth > SKIP_DEPTH_LIMIT {
        return false;
    }
    match bytes[*cursor] {
        b'"' => match scan_string(bytes, *cursor, end) {
            Some(token) => {
                *cursor = token.next;
                true
            }
            None => false,
        },
        b'{' => {
            *cursor += 1;
            skip_ws(bytes, cursor, end);
            if *cursor < end && bytes[*cursor] == b'}' {
                *cursor += 1;
                return true;
            }
            while *cursor < end {
                if bytes[*cursor] != b'"' {
                    return false;
                }
                let Some(key) = scan_string(bytes, *cursor, end) else {
                    return false;
                };
                *cursor = key.next;
                skip_ws(bytes, cursor, end);
                if *cursor >= end || bytes[*cursor] != b':' {
                    return false;
                }
                *cursor += 1;
                skip_ws(bytes, cursor, end);
                if !parse_value(bytes, cursor, end, depth + 1) {
                    return false;
                }
                skip_ws(bytes, cursor, end);
                if *cursor >= end {
                    return false;
                }
                if bytes[*cursor] == b'}' {
                    *cursor += 1;
                    return true;
                }
                if bytes[*cursor] != b',' {
                    return false;
                }
                *cursor += 1;
                skip_ws(bytes, cursor, end);
                if *cursor >= end || bytes[*cursor] == b'}' {
                    return false;
                }
            }
            false
        }
        b'[' => {
            *cursor += 1;
            skip_ws(bytes, cursor, end);
            if *cursor < end && bytes[*cursor] == b']' {
                *cursor += 1;
                return true;
            }
            while *cursor < end {
                if !parse_value(bytes, cursor, end, depth + 1) {
                    return false;
                }
                skip_ws(bytes, cursor, end);
                if *cursor >= end {
                    return false;
                }
                if bytes[*cursor] == b']' {
                    *cursor += 1;
                    return true;
                }
                if bytes[*cursor] != b',' {
                    return false;
                }
                *cursor += 1;
                skip_ws(bytes, cursor, end);
                if *cursor >= end || bytes[*cursor] == b']' {
                    return false;
                }
            }
            false
        }
        b't' => consume_literal(bytes, cursor, end, b"true"),
        b'f' => consume_literal(bytes, cursor, end, b"false"),
        b'n' => consume_literal(bytes, cursor, end, b"null"),
        _ => skip_number(bytes, cursor, end),
    }
}

fn consume_literal(bytes: &[u8], cursor: &mut usize, end: usize, literal: &[u8]) -> bool {
    if *cursor + literal.len() > end {
        return false;
    }
    for (offset, &expected) in literal.iter().enumerate() {
        if bytes[*cursor + offset] != expected {
            return false;
        }
    }
    *cursor += literal.len();
    true
}

fn skip_number(bytes: &[u8], cursor: &mut usize, end: usize) -> bool {
    let start = *cursor;
    if *cursor < end && bytes[*cursor] == b'-' {
        *cursor += 1;
    }
    if *cursor >= end {
        return false;
    }
    if bytes[*cursor] == b'0' {
        *cursor += 1;
        if *cursor < end && bytes[*cursor].is_ascii_digit() {
            return false;
        }
    } else {
        if !(b'1'..=b'9').contains(&bytes[*cursor]) {
            return false;
        }
        while *cursor < end && bytes[*cursor].is_ascii_digit() {
            *cursor += 1;
        }
    }
    if *cursor < end && bytes[*cursor] == b'.' {
        *cursor += 1;
        let fraction_start = *cursor;
        while *cursor < end && bytes[*cursor].is_ascii_digit() {
            *cursor += 1;
        }
        if *cursor == fraction_start {
            return false;
        }
    }
    if *cursor < end && (bytes[*cursor] == b'e' || bytes[*cursor] == b'E') {
        *cursor += 1;
        if *cursor < end && (bytes[*cursor] == b'+' || bytes[*cursor] == b'-') {
            *cursor += 1;
        }
        let exponent_start = *cursor;
        while *cursor < end && bytes[*cursor].is_ascii_digit() {
            *cursor += 1;
        }
        if *cursor == exponent_start {
            return false;
        }
    }
    *cursor > start
}

// ---------------------------------------------------------------------------
// Fields (port of CodexRouterEventLineParser.Field + Fields)
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq)]
enum Field {
    At,
    Model,
    Provider,
    Status,
    InputTokens,
    CachedInputTokens,
    OutputTokens,
    ReasoningTokens,
    TotalTokens,
    EstimatedInputTokens,
    AccountId,
    AccountFingerprint,
    ServiceTier,
}

const KNOWN_SERVICE_TIERS: [&str; 8] = [
    "auto",
    "default",
    "standard",
    "priority",
    "fast",
    "flex",
    "batch",
    "ultrafast",
];

fn is_string_field(field: Field) -> bool {
    matches!(
        field,
        Field::At
            | Field::Model
            | Field::Provider
            | Field::AccountId
            | Field::AccountFingerprint
            | Field::ServiceTier
    )
}

fn is_token_count_field(field: Field) -> bool {
    matches!(
        field,
        Field::InputTokens
            | Field::CachedInputTokens
            | Field::OutputTokens
            | Field::ReasoningTokens
            | Field::TotalTokens
            | Field::EstimatedInputTokens
    )
}

fn is_measured_token_count_field(field: Field) -> bool {
    matches!(
        field,
        Field::InputTokens
            | Field::CachedInputTokens
            | Field::OutputTokens
            | Field::ReasoningTokens
            | Field::TotalTokens
    )
}

fn is_number_start(byte: u8) -> bool {
    byte == b'-' || byte.is_ascii_digit()
}

/// `Swift trimmingCharacters(in: .whitespacesAndNewlines)` — the union of `whitespaces`
/// (Unicode Zs) and `newlines`, which is exactly the Unicode `White_Space` property.
fn trim_ws(s: &str) -> &str {
    s.trim_matches(|c: char| c.is_whitespace())
}

/// `field(for:key:)` — raw-byte match for escape-free keys (length-dispatched).
fn field_for_key(key: &[u8]) -> Option<Field> {
    match key {
        b"at" => Some(Field::At),
        b"model" => Some(Field::Model),
        b"provider" => Some(Field::Provider),
        b"status" => Some(Field::Status),
        b"accountId" => Some(Field::AccountId),
        b"inputTokens" | b"totalTokens" | b"serviceTier" => match key {
            b"inputTokens" => Some(Field::InputTokens),
            b"totalTokens" => Some(Field::TotalTokens),
            _ => Some(Field::ServiceTier),
        },
        b"outputTokens" => Some(Field::OutputTokens),
        b"reasoningTokens" => Some(Field::ReasoningTokens),
        b"cachedInputTokens" => Some(Field::CachedInputTokens),
        b"accountFingerprint" => Some(Field::AccountFingerprint),
        b"estimatedInputTokens" => Some(Field::EstimatedInputTokens),
        _ => None,
    }
}

/// `field(named:)` — exact name match for decoded keys.
fn field_named(key: &str) -> Option<Field> {
    match key {
        "at" => Some(Field::At),
        "model" => Some(Field::Model),
        "provider" => Some(Field::Provider),
        "status" => Some(Field::Status),
        "inputTokens" => Some(Field::InputTokens),
        "cachedInputTokens" => Some(Field::CachedInputTokens),
        "outputTokens" => Some(Field::OutputTokens),
        "reasoningTokens" => Some(Field::ReasoningTokens),
        "totalTokens" => Some(Field::TotalTokens),
        "accountId" => Some(Field::AccountId),
        "accountFingerprint" => Some(Field::AccountFingerprint),
        "serviceTier" => Some(Field::ServiceTier),
        "estimatedInputTokens" => Some(Field::EstimatedInputTokens),
        _ => None,
    }
}

/// `field(for:token:)` — escape-free keys match on raw bytes; escaped keys decode first.
/// A key that fails decoding is treated as unrecognized, exactly like the Swift `field?`
/// (it skips the value rather than bailing the line).
fn field_for_token(bytes: &[u8], token: &StringToken) -> Option<Field> {
    if token.has_escapes {
        decode_string(bytes, token).and_then(|name| field_named(&name))
    } else {
        field_for_key(&bytes[token.content.clone()])
    }
}

/// Port of the private `Fields` accumulator. `seen`/`duplicates` track recognized-field
/// occurrences; `numeric_invalid` is the last-write-wins mirror of
/// `numericCountFieldValidity` for the six token-count fields.
#[derive(Default)]
struct Fields {
    at: Option<String>,
    model: Option<String>,
    model_valid: bool,
    provider: Option<String>,
    provider_valid: bool,
    status: Option<i64>,
    status_seen: bool,
    status_valid: bool,
    input_tokens: Option<i64>,
    cached_input_tokens: Option<i64>,
    output_tokens: Option<i64>,
    reasoning_tokens: Option<i64>,
    total_tokens: Option<i64>,
    estimated_input_tokens: Option<i64>,
    token_count_saturated: bool,
    cached_input_tokens_seen: bool,
    cached_input_tokens_valid: bool,
    total_tokens_seen: bool,
    total_tokens_valid: bool,
    estimated_input_tokens_seen: bool,
    estimated_input_tokens_valid: bool,
    account_id: Option<String>,
    account_fingerprint: Option<String>,
    account_id_valid: bool,
    account_fingerprint_valid: bool,
    service_tier: Option<String>,
    service_tier_valid: bool,
    /// Bit set on every recognized-field occurrence (bit = `field_index`).
    seen: u16,
    /// Bit set once a field is seen twice — poisons uniqueness permanently.
    duplicates: u16,
    recognized_fields_unique: bool,
    /// Last-write-wins per numeric field: bit set ⇔ last write was "invalid"
    /// (`numericCountFieldValidity[field] == false` in the Swift dict).
    numeric_invalid: u8,
}

impl Fields {
    fn new() -> Fields {
        let mut fields = Fields::default();
        fields.model_valid = true;
        fields.provider_valid = true;
        fields.account_id_valid = true;
        fields.account_fingerprint_valid = true;
        fields.service_tier_valid = true;
        fields.recognized_fields_unique = true;
        fields
    }

    fn field_index(field: Field) -> u16 {
        field as u16
    }

    fn field_bit(field: Field) -> u16 {
        1 << Self::field_index(field)
    }

    /// Bit inside `numeric_invalid` for the six token-count fields.
    fn numeric_bit(field: Field) -> u8 {
        match field {
            Field::InputTokens => 1,
            Field::CachedInputTokens => 2,
            Field::OutputTokens => 4,
            Field::ReasoningTokens => 8,
            Field::TotalTokens => 16,
            Field::EstimatedInputTokens => 32,
            _ => 0,
        }
    }

    fn account_identity_fields_valid(&self) -> bool {
        self.account_id_valid && self.account_fingerprint_valid
    }

    fn numeric_count_fields_valid(&self) -> bool {
        self.numeric_invalid == 0
    }

    fn status_field_unique(&self) -> bool {
        self.duplicates & Self::field_bit(Field::Status) == 0
    }

    fn provider_field_unique(&self) -> bool {
        self.duplicates & Self::field_bit(Field::Provider) == 0
    }

    fn model_field_unique(&self) -> bool {
        self.duplicates & Self::field_bit(Field::Model) == 0
    }

    fn account_identity_fields_unique(&self) -> bool {
        self.duplicates
            & (Self::field_bit(Field::AccountId) | Self::field_bit(Field::AccountFingerprint))
            == 0
    }

    /// Record one occurrence of `field` — port of the `seenFields.insert` + `clear` prefix
    /// that runs before the value dispatch for every recognized key.
    fn note_occurrence(&mut self, field: Field) {
        let bit = Self::field_bit(field);
        if self.seen & bit != 0 {
            self.recognized_fields_unique = false;
            self.duplicates |= bit;
        }
        self.seen |= bit;
        self.clear(field);
    }

    fn set_string(&mut self, field: Field, value: String) {
        match field {
            Field::At => self.at = Some(value),
            Field::Model => {
                self.model = Some(value);
                self.model_valid = true;
            }
            Field::Provider => {
                let trimmed = trim_ws(&value);
                self.provider = if trimmed.is_empty() {
                    None
                } else {
                    Some(trimmed.to_string())
                };
                self.provider_valid = self.provider.is_some();
            }
            Field::AccountId => {
                self.account_id = Some(value);
                self.account_id_valid = true;
            }
            Field::AccountFingerprint => {
                self.account_fingerprint = Some(value);
                self.account_fingerprint_valid = true;
            }
            Field::ServiceTier => {
                let tier = trim_ws(&value).to_lowercase();
                self.service_tier = if tier.is_empty() {
                    None
                } else {
                    Some(tier.clone())
                };
                self.service_tier_valid = KNOWN_SERVICE_TIERS.contains(&tier.as_str());
            }
            _ => {}
        }
    }

    fn set_integer(&mut self, field: Field, value: i64) {
        match field {
            Field::Status => {
                self.status = Some(value);
                self.status_seen = true;
                // The router emits an explicit zero for a canceled/failed transport attempt;
                // it is a valid unsuccessful record, not a malformed measurement.
                self.status_valid = value == 0 || (100..600).contains(&value);
            }
            Field::InputTokens => {
                self.input_tokens = Some(value);
                self.write_numeric(field, value >= 0);
            }
            Field::CachedInputTokens => {
                self.cached_input_tokens = Some(value);
                self.cached_input_tokens_valid = value >= 0;
                self.write_numeric(field, value >= 0);
            }
            Field::OutputTokens => {
                self.output_tokens = Some(value);
                self.write_numeric(field, value >= 0);
            }
            Field::ReasoningTokens => {
                self.reasoning_tokens = Some(value);
                self.write_numeric(field, value >= 0);
            }
            Field::TotalTokens => {
                self.total_tokens = Some(value);
                self.total_tokens_valid = value >= 0;
                self.write_numeric(field, value >= 0);
            }
            Field::EstimatedInputTokens => {
                self.estimated_input_tokens = Some(value);
                self.estimated_input_tokens_valid = value >= 0;
                self.write_numeric(field, value >= 0);
            }
            _ => {}
        }
    }

    fn write_numeric(&mut self, field: Field, valid: bool) {
        let bit = Self::numeric_bit(field);
        if valid {
            self.numeric_invalid &= !bit;
        } else {
            self.numeric_invalid |= bit;
        }
    }

    fn clear(&mut self, field: Field) {
        match field {
            Field::At => self.at = None,
            Field::Model => {
                self.model = None;
                self.model_valid = false;
            }
            Field::Provider => {
                self.provider = None;
                self.provider_valid = false;
            }
            Field::Status => {
                self.status = None;
                self.status_seen = true;
                self.status_valid = false;
            }
            Field::InputTokens => {
                self.input_tokens = None;
                self.numeric_invalid |= Self::numeric_bit(field);
            }
            Field::CachedInputTokens => {
                self.cached_input_tokens = None;
                self.cached_input_tokens_seen = true;
                self.cached_input_tokens_valid = false;
                self.numeric_invalid |= Self::numeric_bit(field);
            }
            Field::OutputTokens => {
                self.output_tokens = None;
                self.numeric_invalid |= Self::numeric_bit(field);
            }
            Field::ReasoningTokens => {
                self.reasoning_tokens = None;
                self.numeric_invalid |= Self::numeric_bit(field);
            }
            Field::TotalTokens => {
                self.total_tokens = None;
                self.total_tokens_seen = true;
                self.total_tokens_valid = false;
                self.numeric_invalid |= Self::numeric_bit(field);
            }
            Field::EstimatedInputTokens => {
                self.estimated_input_tokens = None;
                self.estimated_input_tokens_seen = true;
                self.estimated_input_tokens_valid = false;
                self.numeric_invalid |= Self::numeric_bit(field);
            }
            Field::AccountId => {
                self.account_id = None;
                self.account_id_valid = false;
            }
            Field::AccountFingerprint => {
                self.account_fingerprint = None;
                self.account_fingerprint_valid = false;
            }
            Field::ServiceTier => {
                self.service_tier = None;
                self.service_tier_valid = false;
            }
        }
    }

    fn set_null(&mut self, field: Field) {
        match field {
            Field::AccountId => self.account_id_valid = true,
            Field::AccountFingerprint => self.account_fingerprint_valid = true,
            Field::ServiceTier => self.service_tier_valid = false,
            Field::Provider => self.provider_valid = false,
            Field::Model => self.model_valid = false,
            _ => {}
        }
    }
}

// ---------------------------------------------------------------------------
// Integer parsing (port of CodexRouterEventLineParser.parseInteger)
// ---------------------------------------------------------------------------

const TOKEN_CEILING: i64 = 1_000_000_000_000_000;

struct ParsedInteger {
    value: i64,
    next: usize,
    is_exact_integer: bool,
    is_within_bounds: bool,
    is_saturated: bool,
}

/// Strict JSON number grammar plus the Swift trailing-delimiter rule (the byte after the
/// number, past whitespace, must be `,` or the object end). Integer literals saturate to
/// ±1e15 digit by digit; float forms parse via f64 with floor-clamped storage.
fn parse_integer(bytes: &[u8], start: usize, end: usize) -> Option<ParsedInteger> {
    let mut cursor = start;
    let mut negative = false;
    if cursor < end && bytes[cursor] == b'-' {
        negative = true;
        cursor += 1;
    }
    if cursor >= end {
        return None;
    }
    if bytes[cursor] == b'0' {
        cursor += 1;
    } else {
        if !(b'1'..=b'9').contains(&bytes[cursor]) {
            return None;
        }
        while cursor < end && bytes[cursor].is_ascii_digit() {
            cursor += 1;
        }
    }

    let mut needs_float = false;
    if cursor < end && bytes[cursor] == b'.' {
        needs_float = true;
        cursor += 1;
        let fraction_start = cursor;
        while cursor < end && bytes[cursor].is_ascii_digit() {
            cursor += 1;
        }
        if cursor == fraction_start {
            return None;
        }
    }
    if cursor < end && (bytes[cursor] == b'e' || bytes[cursor] == b'E') {
        needs_float = true;
        cursor += 1;
        if cursor < end && (bytes[cursor] == b'+' || bytes[cursor] == b'-') {
            cursor += 1;
        }
        let exponent_start = cursor;
        while cursor < end && bytes[cursor].is_ascii_digit() {
            cursor += 1;
        }
        if cursor == exponent_start {
            return None;
        }
    }

    let number_end = cursor;
    let mut next = cursor;
    skip_ws(bytes, &mut next, end);
    if !(next == end || bytes[next] == b',') {
        return None;
    }

    let ceiling = TOKEN_CEILING;
    let value: i64;
    let is_exact_integer: bool;
    let is_within_bounds: bool;
    let is_saturated: bool;
    if needs_float {
        let text = std::str::from_utf8(&bytes[start..number_end]).ok()?;
        let number: f64 = text.parse().ok()?;
        if number.is_nan() {
            return None;
        }
        is_exact_integer = number.is_finite() && number.trunc() == number;
        is_within_bounds = number.is_finite() && number.abs() <= ceiling as f64;
        is_saturated = !is_within_bounds;
        if number.is_infinite() {
            value = if negative { -ceiling } else { ceiling };
        } else {
            // `Int(max(-ceiling, min(ceiling, number.rounded(.down))))` — floor clamp.
            value = number.floor().max(-(ceiling as f64)).min(ceiling as f64) as i64;
        }
    } else {
        is_exact_integer = true;
        let digits_start = start + usize::from(negative);
        let mut magnitude: i64 = 0;
        let mut saturated = false;
        for &b in &bytes[digits_start..number_end] {
            let digit = i64::from(b - b'0');
            if magnitude > (ceiling - digit) / 10 {
                magnitude = ceiling;
                saturated = true;
            } else if !saturated {
                magnitude = magnitude * 10 + digit;
            }
        }
        value = if negative { -magnitude } else { magnitude };
        is_within_bounds = !saturated;
        is_saturated = saturated;
    }

    Some(ParsedInteger {
        value,
        next: number_end,
        is_exact_integer,
        is_within_bounds,
        is_saturated,
    })
}

// ---------------------------------------------------------------------------
// Main object walk (port of CodexRouterEventLineParser.parse)
// ---------------------------------------------------------------------------

/// `Date.distantPast` in seconds since the Unix epoch — the Swift malformed-event payload.
const DISTANT_PAST: f64 = -62_135_769_600.0;

enum Walk {
    /// The line failed the structural walk — hand to `bail_verdict`.
    Bail,
    /// An `at` string outside the canonical shapes — the Swift engine owns the verdict.
    Fallback,
    /// Walk finished; `Some(ts)` = timestamp parsed, `None` = malformed-event timestamp.
    Done(Fields, Option<f64>),
}

fn walk(bytes: &[u8]) -> Walk {
    let mut object_start = 0;
    while object_start < bytes.len() && is_ws(bytes[object_start]) {
        object_start += 1;
    }
    if !(object_start + 1 < bytes.len() && bytes[object_start] == b'{') {
        return Walk::Bail;
    }
    let mut object_end = bytes.len();
    while object_end > 1 && is_ws(bytes[object_end - 1]) {
        object_end -= 1;
    }
    if !(object_end > 1 && bytes[object_end - 1] == b'}') {
        return Walk::Bail;
    }
    object_end -= 1;

    let mut fields = Fields::new();
    let mut cursor = object_start + 1;
    while cursor < object_end {
        skip_ws(bytes, &mut cursor, object_end);
        if cursor == object_end {
            break;
        }
        if bytes[cursor] != b'"' {
            return Walk::Bail;
        }
        let Some(key_token) = scan_string(bytes, cursor, object_end) else {
            return Walk::Bail;
        };
        let field = field_for_token(bytes, &key_token);
        cursor = key_token.next;
        skip_ws(bytes, &mut cursor, object_end);
        if !(cursor < object_end && bytes[cursor] == b':') {
            return Walk::Bail;
        }
        cursor += 1;
        skip_ws(bytes, &mut cursor, object_end);
        if cursor >= object_end {
            return Walk::Bail;
        }

        let value_start = cursor;
        if let Some(field) = field {
            fields.note_occurrence(field);
            if is_string_field(field) && bytes[cursor] == b'"' {
                let Some(token) = scan_string(bytes, cursor, object_end) else {
                    return Walk::Bail;
                };
                let Some(value) = decode_string(bytes, &token) else {
                    return Walk::Bail;
                };
                fields.set_string(field, value);
                cursor = token.next;
            } else if is_number_start(bytes[cursor]) {
                let Some(parsed) = parse_integer(bytes, cursor, object_end) else {
                    return Walk::Bail;
                };
                fields.set_integer(field, parsed.value);
                if field == Field::Status && !parsed.is_exact_integer {
                    fields.status_valid = false;
                }
                if is_token_count_field(field) {
                    if parsed.is_saturated && parsed.value >= 0 {
                        // A clamped *measured* count lowers the bound; the estimated input
                        // is router-side bookkeeping and can never saturate measured usage.
                        if is_measured_token_count_field(field) {
                            fields.token_count_saturated = true;
                        }
                    } else if !parsed.is_exact_integer || !parsed.is_within_bounds {
                        fields.numeric_invalid |= Fields::numeric_bit(field);
                    }
                }
                cursor = parsed.next;
            } else {
                let Some(next) = skip_value(bytes, cursor, object_end) else {
                    return Walk::Bail;
                };
                if &bytes[value_start..next] == b"null" {
                    fields.set_null(field);
                }
                cursor = next;
            }
        } else {
            let Some(next) = skip_value(bytes, cursor, object_end) else {
                return Walk::Bail;
            };
            cursor = next;
        }

        skip_ws(bytes, &mut cursor, object_end);
        if cursor == object_end {
            break;
        }
        if cursor >= object_end {
            return Walk::Bail;
        }
        if bytes[cursor] == b',' {
            cursor += 1;
            skip_ws(bytes, &mut cursor, object_end);
            if cursor >= object_end {
                return Walk::Bail;
            }
        } else {
            return Walk::Bail;
        }
    }

    if cursor != object_end {
        return Walk::Bail;
    }

    // `at` is trimmed before parsing; a string outside the canonical shapes may still be
    // legal for OpenUsageISO8601, so the line declines to the Swift engine.
    match fields.at.as_deref().map(trim_ws) {
        Some(timestamp) => match parse_canonical_utc(timestamp.as_bytes()) {
            CanonicalTimestamp::Ok(ts) => Walk::Done(fields, Some(ts)),
            CanonicalTimestamp::Invalid => Walk::Done(fields, None),
            CanonicalTimestamp::NotCanonical => Walk::Fallback,
        },
        None => Walk::Done(fields, None),
    }
}

// ---------------------------------------------------------------------------
// Structural-bail classification — the JSONSerialization verdict
// ---------------------------------------------------------------------------

/// `Decimal.greatestFiniteMagnitude` mantissa ((2^128 - 1), 39 digits) — Foundation's JSON
/// parser accumulates integer-part digits as a `Decimal` and rejects magnitudes above it.
/// The limit in full is this mantissa followed by 127 zeros (166 digits total).
const DECIMAL_MAX_MANTISSA: &[u8] = b"340282366920938463463374607431768211455";

/// Whether a digit run (no leading zeros, sign stripped) fits `Decimal`'s range:
/// shorter than 166 digits always, longer never, exactly 166 only at or below the limit.
fn within_decimal_limit(digits: &[u8]) -> bool {
    match digits.len().cmp(&166) {
        std::cmp::Ordering::Less => true,
        std::cmp::Ordering::Greater => false,
        std::cmp::Ordering::Equal => {
            let (head, tail) = digits.split_at(DECIMAL_MAX_MANTISSA.len());
            head < DECIMAL_MAX_MANTISSA
                || (head == DECIMAL_MAX_MANTISSA && tail.iter().all(|&d| d == b'0'))
        }
    }
}

/// Foundation-grammar number check for the bail path: strict JSON grammar, plus the
/// `Decimal`-range limit on the integer-part digit run, plus the asymmetric float rule
/// (positive `+inf` is rejected, `-inf` is accepted).
fn foundation_number(bytes: &[u8], cursor: &mut usize, end: usize) -> bool {
    let start = *cursor;
    if bytes[*cursor] == b'-' {
        *cursor += 1;
    }
    if *cursor >= end {
        return false;
    }
    if bytes[*cursor] == b'0' {
        *cursor += 1;
        if *cursor < end && bytes[*cursor].is_ascii_digit() {
            return false;
        }
    } else {
        if !(b'1'..=b'9').contains(&bytes[*cursor]) {
            return false;
        }
        while *cursor < end && bytes[*cursor].is_ascii_digit() {
            *cursor += 1;
        }
    }
    let int_digits = &bytes[start + usize::from(bytes[start] == b'-')..*cursor];
    if !within_decimal_limit(int_digits) {
        return false;
    }

    let mut float_shape = false;
    if *cursor < end && bytes[*cursor] == b'.' {
        float_shape = true;
        *cursor += 1;
        let fraction_start = *cursor;
        while *cursor < end && bytes[*cursor].is_ascii_digit() {
            *cursor += 1;
        }
        if *cursor == fraction_start {
            return false;
        }
    }
    if *cursor < end && (bytes[*cursor] == b'e' || bytes[*cursor] == b'E') {
        float_shape = true;
        *cursor += 1;
        if *cursor < end && (bytes[*cursor] == b'+' || bytes[*cursor] == b'-') {
            *cursor += 1;
        }
        let exponent_start = *cursor;
        while *cursor < end && bytes[*cursor].is_ascii_digit() {
            *cursor += 1;
        }
        if *cursor == exponent_start {
            return false;
        }
    }

    if float_shape {
        let Ok(text) = std::str::from_utf8(&bytes[start..*cursor]) else {
            return false;
        };
        let Ok(number) = text.parse::<f64>() else {
            return false;
        };
        // `1e309` is rejected, `-1e309` decodes to -inf and is accepted.
        if number == f64::INFINITY {
            return false;
        }
    }
    true
}

/// Foundation's nesting bound — probed at 512 for both objects and arrays.
const FOUNDATION_DEPTH_LIMIT: usize = 512;

/// JSON value walk under Foundation's acceptance rules (see module doc). `collect_keys`
/// decodes member keys — set only for the outermost object, whose keys decide
/// relevant-vs-malformed.
fn foundation_value(
    bytes: &[u8],
    cursor: &mut usize,
    end: usize,
    depth: usize,
    recognized: &mut bool,
    collect_keys: bool,
) -> bool {
    if *cursor >= end || depth > FOUNDATION_DEPTH_LIMIT {
        return false;
    }
    match bytes[*cursor] {
        b'"' => match scan_string_strict(bytes, *cursor, end) {
            Some(token) => {
                *cursor = token.next;
                true
            }
            None => false,
        },
        b'{' => {
            *cursor += 1;
            skip_ws(bytes, cursor, end);
            if *cursor < end && bytes[*cursor] == b'}' {
                *cursor += 1;
                return true;
            }
            loop {
                if *cursor >= end {
                    return false;
                }
                let Some(key) = scan_string_strict(bytes, *cursor, end) else {
                    return false;
                };
                if collect_keys {
                    if let Some(name) = decode_string(bytes, &key) {
                        if field_named(&name).is_some() {
                            *recognized = true;
                        }
                    }
                }
                *cursor = key.next;
                skip_ws(bytes, cursor, end);
                if *cursor >= end || bytes[*cursor] != b':' {
                    return false;
                }
                *cursor += 1;
                skip_ws(bytes, cursor, end);
                if !foundation_value(bytes, cursor, end, depth + 1, recognized, false) {
                    return false;
                }
                skip_ws(bytes, cursor, end);
                if *cursor >= end {
                    return false;
                }
                if bytes[*cursor] == b'}' {
                    *cursor += 1;
                    return true;
                }
                if bytes[*cursor] != b',' {
                    return false;
                }
                *cursor += 1;
                skip_ws(bytes, cursor, end);
                // One trailing comma before the brace is accepted.
                if *cursor < end && bytes[*cursor] == b'}' {
                    *cursor += 1;
                    return true;
                }
            }
        }
        b'[' => {
            *cursor += 1;
            skip_ws(bytes, cursor, end);
            if *cursor < end && bytes[*cursor] == b']' {
                *cursor += 1;
                return true;
            }
            loop {
                if !foundation_value(bytes, cursor, end, depth + 1, recognized, false) {
                    return false;
                }
                skip_ws(bytes, cursor, end);
                if *cursor >= end {
                    return false;
                }
                if bytes[*cursor] == b']' {
                    *cursor += 1;
                    return true;
                }
                if bytes[*cursor] != b',' {
                    return false;
                }
                *cursor += 1;
                skip_ws(bytes, cursor, end);
                if *cursor < end && bytes[*cursor] == b']' {
                    *cursor += 1;
                    return true;
                }
            }
        }
        b't' => consume_literal(bytes, cursor, end, b"true"),
        b'f' => consume_literal(bytes, cursor, end, b"false"),
        b'n' => consume_literal(bytes, cursor, end, b"null"),
        _ => foundation_number(bytes, cursor, end),
    }
}

/// The verdict the Swift `parseResult` derives for lines its walker rejected: whitespace
/// and empty lines are irrelevant; a valid non-object is malformed; a valid object is
/// irrelevant unless a top-level key names a recognized field — then it is malformed.
fn bail_verdict(bytes: &[u8]) -> ParsedLine {
    if bytes.is_empty() || bytes.iter().all(|&b| is_ws(b)) {
        return ParsedLine::Irrelevant(None);
    }
    let mut start = 0;
    // JSONSerialization tolerates exactly one UTF-8 BOM at byte 0.
    if bytes.starts_with(&[0xEF, 0xBB, 0xBF]) {
        start = 3;
    }
    skip_ws(bytes, &mut start, bytes.len());
    // Any non-object verdict is `.malformed` regardless of validity.
    if start >= bytes.len() || bytes[start] != b'{' {
        return ParsedLine::Malformed;
    }
    let mut cursor = start;
    let mut recognized = false;
    // The outermost token is depth 1 — Foundation counts the root container itself, so a
    // `{"pad":<512-deep>}` line hits 513 and is invalid.
    if !foundation_value(bytes, &mut cursor, bytes.len(), 1, &mut recognized, true) {
        return ParsedLine::Malformed;
    }
    skip_ws(bytes, &mut cursor, bytes.len());
    if cursor != bytes.len() {
        return ParsedLine::Malformed;
    }
    if recognized {
        ParsedLine::Malformed
    } else {
        ParsedLine::Irrelevant(None)
    }
}

// ---------------------------------------------------------------------------
// Event construction (port of makeEvent) and the line verdict
// ---------------------------------------------------------------------------

const UNATTRIBUTED_MODEL: &str = "Unattributed";

struct EventOut {
    timestamp: f64,
    model: String,
    provider: String,
    status: i64,
    has_valid_status_field: bool,
    has_valid_timestamp_field: bool,
    has_valid_model_field: bool,
    has_unique_status_field: bool,
    has_unique_provider_field: bool,
    has_unique_model_field: bool,
    has_unique_account_identity_fields: bool,
    has_valid_numeric_count_fields: bool,
    has_unique_recognized_fields: bool,
    input_tokens: i64,
    cached_input_tokens: i64,
    output_tokens: i64,
    reasoning_tokens: i64,
    total_tokens: Option<i64>,
    has_input_tokens_field: bool,
    has_output_tokens_field: bool,
    has_valid_cached_input_tokens_field: bool,
    has_valid_total_tokens_field: bool,
    has_valid_estimated_input_tokens_field: bool,
    has_estimated_input_tokens: Option<bool>,
    has_valid_account_identity_fields: bool,
    has_valid_provider_field: Option<bool>,
    has_valid_service_tier_field: Option<bool>,
    account_id: Option<String>,
    account_fingerprint: Option<String>,
    service_tier: Option<String>,
    token_count_saturated: Option<bool>,
}

fn make_event(fields: &Fields, timestamp: f64, has_valid_timestamp_field: bool) -> EventOut {
    let model = fields
        .model
        .as_deref()
        .map(trim_ws)
        .filter(|s| !s.is_empty())
        .unwrap_or(UNATTRIBUTED_MODEL)
        .to_string();
    let provider = fields
        .provider
        .as_deref()
        .map(trim_ws)
        .filter(|s| !s.is_empty())
        .unwrap_or("unknown")
        .to_string();
    let total_tokens = fields.total_tokens.filter(|&v| v >= 0);
    let account_id = fields
        .account_id
        .as_deref()
        .map(trim_ws)
        .filter(|s| !s.is_empty())
        .map(String::from);
    let account_fingerprint = fields
        .account_fingerprint
        .as_deref()
        .map(trim_ws)
        .filter(|s| !s.is_empty())
        .map(String::from);
    EventOut {
        timestamp,
        model,
        provider,
        status: fields.status.unwrap_or(0),
        has_valid_status_field: fields.status_seen && fields.status_valid,
        has_valid_timestamp_field,
        has_valid_model_field: fields.model_valid,
        has_unique_status_field: fields.status_field_unique(),
        has_unique_provider_field: fields.provider_field_unique(),
        has_unique_model_field: fields.model_field_unique(),
        has_unique_account_identity_fields: fields.account_identity_fields_unique(),
        has_valid_numeric_count_fields: fields.numeric_count_fields_valid(),
        has_unique_recognized_fields: fields.recognized_fields_unique,
        input_tokens: fields.input_tokens.unwrap_or(0).max(0),
        cached_input_tokens: fields.cached_input_tokens.unwrap_or(0).max(0),
        output_tokens: fields.output_tokens.unwrap_or(0).max(0),
        reasoning_tokens: fields.reasoning_tokens.unwrap_or(0).max(0),
        total_tokens,
        has_input_tokens_field: fields.input_tokens.map(|v| v >= 0).unwrap_or(false),
        has_output_tokens_field: fields.output_tokens.map(|v| v >= 0).unwrap_or(false),
        has_valid_cached_input_tokens_field: !fields.cached_input_tokens_seen
            || fields.cached_input_tokens_valid,
        has_valid_total_tokens_field: !fields.total_tokens_seen || fields.total_tokens_valid,
        has_valid_estimated_input_tokens_field: !fields.estimated_input_tokens_seen
            || fields.estimated_input_tokens_valid,
        has_estimated_input_tokens: Some(
            fields
                .estimated_input_tokens
                .map(|v| v > 0)
                .unwrap_or(false),
        ),
        has_valid_account_identity_fields: fields.account_identity_fields_valid(),
        has_valid_provider_field: Some(fields.provider_valid),
        has_valid_service_tier_field: Some(fields.service_tier_valid),
        account_id,
        account_fingerprint,
        service_tier: fields.service_tier.clone(),
        token_count_saturated: fields.token_count_saturated.then_some(true),
    }
}

fn is_successful_status(status: i64) -> bool {
    (200..300).contains(&status)
}

enum ParsedLine {
    Event(EventOut),
    MalformedEvent(EventOut),
    /// `Some` when a non-2xx short circuit produced an event (Swift's `parse` still
    /// returns it); `None` for structural-bail irrelevants.
    Irrelevant(Option<EventOut>),
    Malformed,
    /// A non-canonical `at` string — legal input the Swift engine must answer for.
    Fallback,
}

fn parse_line(bytes: &[u8]) -> ParsedLine {
    match walk(bytes) {
        Walk::Bail => bail_verdict(bytes),
        Walk::Fallback => ParsedLine::Fallback,
        Walk::Done(fields, timestamp) => {
            let timestamp_valid = timestamp.is_some();
            let event = make_event(&fields, timestamp.unwrap_or(DISTANT_PAST), timestamp_valid);
            // A unique, valid non-2xx status short-circuits before the other validity
            // checks — the row belongs to a failed response and is ignored. The event is
            // carried only when `parse` would surface it: with an invalid timestamp the
            // Swift `parse` reports nil and the payload is unobservable.
            if event.has_valid_status_field
                && event.has_unique_status_field
                && !is_successful_status(event.status)
            {
                return ParsedLine::Irrelevant(if event.has_valid_timestamp_field {
                    Some(event)
                } else {
                    None
                });
            }
            if !timestamp_valid {
                return ParsedLine::MalformedEvent(event);
            }
            if event.has_valid_status_field
                && event.has_valid_account_identity_fields
                && event.has_valid_model_field
                && event.has_valid_numeric_count_fields
                && event.has_unique_recognized_fields
                && event.has_valid_provider_field != Some(false)
            {
                ParsedLine::Event(event)
            } else {
                ParsedLine::MalformedEvent(event)
            }
        }
    }
}

/// Port of `looksLikeCompleteObject`: a final file fragment is a record only when its
/// closing object delimiter arrived — otherwise it may still be mid-append.
fn looks_like_complete_object(line: &[u8]) -> bool {
    let mut end = line.len();
    while end > 0 {
        if !is_ws(line[end - 1]) {
            return line[end - 1] == b'}';
        }
        end -= 1;
    }
    false
}

// ---------------------------------------------------------------------------
// Whole-file driver
// ---------------------------------------------------------------------------

struct FileParser {
    entries: Vec<EventOut>,
    malformed: bool,
    fell_back: bool,
    /// The skipped trailing fragment — `ReadResult.finalPartial` for the tail-cache
    /// checkpoint (a `}`-terminated tail is consumed instead and stays empty).
    pending_partial: Vec<u8>,
}

impl FileParser {
    /// `deliver` callback for `scan_file_lines`. A trailing unterminated fragment without a
    /// closing `}` stays buffered for the next append exactly like the Swift readers —
    /// it is neither parsed nor counted as malformed, but it is retained as the
    /// append-resume carry.
    fn consume(&mut self, line: &[u8], is_final_partial: bool) -> bool {
        if is_final_partial && !looks_like_complete_object(line) {
            self.pending_partial = line.to_vec();
            return true;
        }
        match parse_line(line) {
            ParsedLine::Event(event) | ParsedLine::MalformedEvent(event) => {
                self.entries.push(event);
                true
            }
            ParsedLine::Irrelevant(_) => true,
            ParsedLine::Malformed => {
                self.malformed = true;
                true
            }
            ParsedLine::Fallback => {
                self.fell_back = true;
                false
            }
        }
    }
}

fn parse_file_impl(
    path: &[u8],
    start_offset: u64,
    end_offset: Option<u64>,
    cancel_ctx: *mut c_void,
    cancel: Option<CancelCallback>,
) -> RouterFileResult {
    let mut parser = FileParser {
        entries: Vec::new(),
        malformed: false,
        fell_back: false,
        pending_partial: Vec::new(),
    };
    // `deliver_final_partial` is required here: the Swift readers hand a trailing
    // `}`-terminated object to the line parser manually, so the Rust driver must see it.
    let stats = scanfile::scan_file_lines(
        path,
        start_offset,
        end_offset,
        true,
        false,
        cancel_ctx,
        cancel,
        scanfile::MAX_LINE_BYTES,
        &mut |line, is_final_partial| parser.consume(line, is_final_partial),
    );

    let complete = stats.succeeded
        && stats.oversized_lines_skipped == 0
        && !stats.is_discarding_oversized_line;
    // A malformed row earlier in the file wins over a later fallback — the Swift guard
    // (`read.isComplete && !malformedLine`) yields nil for the file either way.
    let status = if parser.fell_back && !parser.malformed {
        QB_FILE_FALLBACK
    } else if parser.malformed || !complete {
        QB_FILE_FAILED
    } else {
        QB_FILE_OK
    };
    if status != QB_FILE_OK {
        return RouterFileResult {
            status,
            entries: Vec::new(),
            strings: Vec::new(),
            final_partial: Vec::new(),
            is_discarding_oversized_line: stats.is_discarding_oversized_line,
            bytes_read: stats.bytes_read,
            oversized_lines_skipped: stats.oversized_lines_skipped,
        };
    }
    let Some((entries, strings)) = pack_entries(&parser.entries) else {
        return RouterFileResult {
            status: QB_FILE_FALLBACK,
            entries: Vec::new(),
            strings: Vec::new(),
            final_partial: Vec::new(),
            is_discarding_oversized_line: stats.is_discarding_oversized_line,
            bytes_read: stats.bytes_read,
            oversized_lines_skipped: stats.oversized_lines_skipped,
        };
    };
    RouterFileResult {
        status,
        entries,
        strings,
        final_partial: parser.pending_partial,
        is_discarding_oversized_line: stats.is_discarding_oversized_line,
        bytes_read: stats.bytes_read,
        oversized_lines_skipped: stats.oversized_lines_skipped,
    }
}

// ---------------------------------------------------------------------------
// Packing + C ABI
// ---------------------------------------------------------------------------

fn tri(value: Option<bool>) -> u8 {
    match value {
        None => 0,
        Some(false) => 1,
        Some(true) => 2,
    }
}

/// Intern every string field of `events` into one UTF-8 blob and produce the `#[repr(C)]`
/// array. `None` means a blob offset overflowed u32 — the caller treats it as fallback.
fn pack_entries(events: &[EventOut]) -> Option<(Vec<QbCodexRouterEvent>, Vec<u8>)> {
    let mut strings: Vec<u8> = Vec::new();
    let mut out: Vec<QbCodexRouterEvent> = Vec::with_capacity(events.len());
    for event in events {
        let (model_offset, model_length) = intern(&mut strings, &event.model)?;
        let (provider_offset, provider_length) = intern(&mut strings, &event.provider)?;
        let (service_tier_offset, service_tier_length) = match &event.service_tier {
            Some(s) => intern(&mut strings, s)?,
            None => (NIL_STRING, 0),
        };
        let (account_id_offset, account_id_length) = match &event.account_id {
            Some(s) => intern(&mut strings, s)?,
            None => (NIL_STRING, 0),
        };
        let (account_fingerprint_offset, account_fingerprint_length) =
            match &event.account_fingerprint {
                Some(s) => intern(&mut strings, s)?,
                None => (NIL_STRING, 0),
            };
        out.push(QbCodexRouterEvent {
            timestamp: event.timestamp,
            status: event.status,
            input_tokens: event.input_tokens,
            cached_input_tokens: event.cached_input_tokens,
            output_tokens: event.output_tokens,
            reasoning_tokens: event.reasoning_tokens,
            total_tokens: event.total_tokens.unwrap_or(0),
            model_offset,
            model_length,
            provider_offset,
            provider_length,
            service_tier_offset,
            service_tier_length,
            account_id_offset,
            account_id_length,
            account_fingerprint_offset,
            account_fingerprint_length,
            has_valid_status_field: u8::from(event.has_valid_status_field),
            has_valid_timestamp_field: u8::from(event.has_valid_timestamp_field),
            has_valid_model_field: u8::from(event.has_valid_model_field),
            has_unique_status_field: u8::from(event.has_unique_status_field),
            has_unique_provider_field: u8::from(event.has_unique_provider_field),
            has_unique_model_field: u8::from(event.has_unique_model_field),
            has_unique_account_identity_fields: u8::from(event.has_unique_account_identity_fields),
            has_valid_numeric_count_fields: u8::from(event.has_valid_numeric_count_fields),
            has_unique_recognized_fields: u8::from(event.has_unique_recognized_fields),
            has_total_tokens: u8::from(event.total_tokens.is_some()),
            has_input_tokens_field: u8::from(event.has_input_tokens_field),
            has_output_tokens_field: u8::from(event.has_output_tokens_field),
            has_valid_cached_input_tokens_field: u8::from(
                event.has_valid_cached_input_tokens_field,
            ),
            has_valid_total_tokens_field: u8::from(event.has_valid_total_tokens_field),
            has_valid_estimated_input_tokens_field: u8::from(
                event.has_valid_estimated_input_tokens_field,
            ),
            has_valid_account_identity_fields: u8::from(event.has_valid_account_identity_fields),
            has_estimated_input_tokens: tri(event.has_estimated_input_tokens),
            has_valid_provider_field: tri(event.has_valid_provider_field),
            has_valid_service_tier_field: tri(event.has_valid_service_tier_field),
            token_count_saturated: tri(event.token_count_saturated),
            reserved: [0; 4],
        });
    }
    Some((out, strings))
}

/// Parse one CodexRouter ledger line.
///
/// Returns a heap-allocated result the caller must pass to
/// [`qb_codex_router_line_result_destroy`], or NULL when the line is legal Swift input this
/// module declines (a non-canonical `at` string) — the caller re-runs its own parser.
/// A null pointer is never an error.
#[no_mangle]
pub extern "C" fn qb_codex_router_parse_line(
    line: *const u8,
    line_len: usize,
) -> *mut RouterLineResult {
    if line.is_null() && line_len > 0 {
        return ptr::null_mut();
    }
    let bytes = if line.is_null() {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(line, line_len) }
    };
    match catch_unwind(AssertUnwindSafe(|| {
        let (verdict, event) = match parse_line(bytes) {
            ParsedLine::Event(e) => (QB_ROUTER_LINE_EVENT, Some(e)),
            ParsedLine::MalformedEvent(e) => (QB_ROUTER_LINE_MALFORMED_EVENT, Some(e)),
            ParsedLine::Irrelevant(e) => (QB_ROUTER_LINE_IRRELEVANT, e),
            ParsedLine::Malformed => (QB_ROUTER_LINE_MALFORMED, None),
            ParsedLine::Fallback => return ptr::null_mut(),
        };
        let mut events = Vec::new();
        if let Some(event) = event {
            events.push(event);
        }
        match pack_entries(&events) {
            Some((entries, strings)) => Box::into_raw(Box::new(RouterLineResult {
                verdict,
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

/// One of `QB_ROUTER_LINE_*`; the `IRRELEVANT` verdict may still carry one entry — the
/// produced event for a non-2xx short circuit (Swift's `parse` returns it).
#[no_mangle]
pub extern "C" fn qb_codex_router_line_result_verdict(result: *const RouterLineResult) -> u32 {
    if result.is_null() {
        return QB_ROUTER_LINE_MALFORMED;
    }
    unsafe { &*result }.verdict
}

#[no_mangle]
pub extern "C" fn qb_codex_router_line_result_entry_count(result: *const RouterLineResult) -> u32 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.entries.len() as u32
}

/// Pointer to the entry array; valid until [`qb_codex_router_line_result_destroy`].
#[no_mangle]
pub extern "C" fn qb_codex_router_line_result_entries(
    result: *const RouterLineResult,
) -> *const QbCodexRouterEvent {
    if result.is_null() {
        return ptr::null();
    }
    unsafe { &*result }.entries.as_ptr()
}

/// Pointer to the UTF-8 string blob the entry offsets index into, plus its byte length.
#[no_mangle]
pub extern "C" fn qb_codex_router_line_result_strings(
    result: *const RouterLineResult,
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
/// `result` must be a pointer returned by [`qb_codex_router_parse_line`], destroyed at
/// most once.
#[no_mangle]
pub unsafe extern "C" fn qb_codex_router_line_result_destroy(result: *mut RouterLineResult) {
    if result.is_null() {
        return;
    }
    unsafe { drop(Box::from_raw(result)) };
}

/// Parse one CodexRouter ledger file end to end: the Rust side streams, splits, and parses
/// every line — including a trailing `}`-terminated object without a newline — without
/// materializing Foundation objects.
///
/// `path` is a UTF-8 path (not NUL-terminated). `end_offset` of `UINT64_MAX` reads to EOF.
/// `cancel` is invoked once per 64 KiB chunk. NULL result is treated like
/// `QB_FILE_FALLBACK`. Status is one of `QB_FILE_OK` / `QB_FILE_FALLBACK` / `QB_FILE_FAILED`;
/// a `FALLBACK` or `FAILED` result carries no entries — the caller never mixes engines.
#[no_mangle]
pub extern "C" fn qb_codex_router_parse_file(
    path: *const u8,
    path_len: usize,
    start_offset: u64,
    end_offset: u64,
    cancel: Option<extern "C" fn(*mut c_void) -> u8>,
    cancel_ctx: *mut c_void,
) -> *mut RouterFileResult {
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
pub extern "C" fn qb_codex_router_file_result_status(result: *const RouterFileResult) -> u32 {
    if result.is_null() {
        return QB_FILE_FALLBACK;
    }
    unsafe { &*result }.status
}

#[no_mangle]
pub extern "C" fn qb_codex_router_file_result_entry_count(result: *const RouterFileResult) -> u32 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.entries.len() as u32
}

#[no_mangle]
pub extern "C" fn qb_codex_router_file_result_entries(
    result: *const RouterFileResult,
) -> *const QbCodexRouterEvent {
    if result.is_null() {
        return ptr::null();
    }
    unsafe { &*result }.entries.as_ptr()
}

#[no_mangle]
pub extern "C" fn qb_codex_router_file_result_strings(
    result: *const RouterFileResult,
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
pub extern "C" fn qb_codex_router_file_result_bytes_read(result: *const RouterFileResult) -> u64 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.bytes_read
}

#[no_mangle]
pub extern "C" fn qb_codex_router_file_result_oversized_lines(
    result: *const RouterFileResult,
) -> u64 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.oversized_lines_skipped
}

/// The trailing newline-less fragment retained for the append-resume checkpoint — empty
/// unless a `.success` read ended in a non-`}` tail the driver skipped.
#[no_mangle]
pub extern "C" fn qb_codex_router_file_result_partial_line(
    result: *const RouterFileResult,
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
        unsafe { *length = result.final_partial.len() as u32 };
    }
    if result.final_partial.is_empty() {
        return ptr::null();
    }
    result.final_partial.as_ptr()
}

#[no_mangle]
pub extern "C" fn qb_codex_router_file_result_is_discarding_oversized_line(
    result: *const RouterFileResult,
) -> u8 {
    if result.is_null() {
        return 0;
    }
    unsafe { u8::from((*result).is_discarding_oversized_line) }
}

/// # Safety
/// `result` must be a pointer returned by [`qb_codex_router_parse_file`], destroyed at
/// most once.
#[no_mangle]
pub unsafe extern "C" fn qb_codex_router_file_result_destroy(result: *mut RouterFileResult) {
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

    fn verdict(line: &str) -> &'static str {
        match parse_line(line.as_bytes()) {
            ParsedLine::Event(_) => "event",
            ParsedLine::MalformedEvent(_) => "malformedEvent",
            ParsedLine::Irrelevant(_) => "irrelevant",
            ParsedLine::Malformed => "malformed",
            ParsedLine::Fallback => "fallback",
        }
    }

    fn event(line: &str) -> EventOut {
        match parse_line(line.as_bytes()) {
            ParsedLine::Event(e) | ParsedLine::MalformedEvent(e) => e,
            ParsedLine::Irrelevant(Some(e)) => e,
            _ => panic!("expected an event, got {}", verdict(line)),
        }
    }

    const TS: &str = "2026-10-02T12:00:00Z";

    #[test]
    fn struct_layout() {
        assert_eq!(std::mem::size_of::<QbCodexRouterEvent>(), 120);
        assert_eq!(std::mem::align_of::<QbCodexRouterEvent>(), 8);
    }

    #[test]
    fn basic_event_all_fields() {
        let line = format!(
            r#"{{"padding":"ignore, \"keys\"","serviceTier":"PRIORITY","totalTokens":17,"outputTokens":5,"reasoningTokens":2,"cachedInputTokens":3,"inputTokens":10,"status":200,"provider":"openai","model":"gpt-6-luna","at":"{TS}","accountId":"acct_A","accountFingerprint":"acct_deadbeef"}}"#
        );
        let e = event(&line);
        assert_eq!(verdict(&line), "event");
        assert_eq!(e.model, "gpt-6-luna");
        assert_eq!(e.provider, "openai");
        assert_eq!(e.status, 200);
        assert_eq!(e.input_tokens, 10);
        assert_eq!(e.cached_input_tokens, 3);
        assert_eq!(e.output_tokens, 5);
        assert_eq!(e.reasoning_tokens, 2);
        assert_eq!(e.total_tokens, Some(17));
        assert_eq!(e.account_id.as_deref(), Some("acct_A"));
        assert_eq!(e.account_fingerprint.as_deref(), Some("acct_deadbeef"));
        assert_eq!(e.service_tier.as_deref(), Some("priority"));
        assert!(e.has_valid_status_field);
        assert!(e.has_valid_timestamp_field);
    }

    #[test]
    fn escaped_key_names_match() {
        let e = event(&format!(
            r#"{{"at":"{TS}","status":200,"m\u006fdel":"gpt-6","input\u0054okens":42}}"#
        ));
        assert_eq!(e.model, "gpt-6");
        assert_eq!(e.input_tokens, 42);
    }

    #[test]
    fn escaped_timestamp_decodes() {
        let e = event(&format!(
            r#"{{"at":"2026-10-02T12:00:00\u005a","status":200}}"#
        ));
        assert_eq!(e.timestamp, 1790942400.0);
    }

    #[test]
    fn float_status_edges() {
        // Exact-integer floats are valid statuses.
        let e = event(&format!(r#"{{"at":"{TS}","status":2e2}}"#));
        assert_eq!(e.status, 200);
        assert!(e.has_valid_status_field);
        assert_eq!(
            verdict(&format!(r#"{{"at":"{TS}","status":2.0e2}}"#)),
            "event"
        );
        // Non-integral floats poison the status field.
        let e = event(&format!(r#"{{"at":"{TS}","status":2.5}}"#));
        assert_eq!(
            verdict(&format!(r#"{{"at":"{TS}","status":2.5}}"#)),
            "malformedEvent"
        );
        assert!(!e.has_valid_status_field);
        // Float token counts floor toward -inf (not toward zero).
        let e = event(&format!(
            r#"{{"at":"{TS}","status":200,"inputTokens":2.9}}"#
        ));
        assert_eq!(e.input_tokens, 2);
        assert!(!e.has_valid_numeric_count_fields);
        let e = event(&format!(
            r#"{{"at":"{TS}","status":200,"inputTokens":-2.9}}"#
        ));
        assert_eq!(e.input_tokens, 0); // stored -3, clamped nonnegative
    }

    #[test]
    fn status_range_rules() {
        assert_eq!(
            verdict(&format!(r#"{{"at":"{TS}","status":199}}"#)),
            "irrelevant"
        );
        assert_eq!(
            verdict(&format!(r#"{{"at":"{TS}","status":299}}"#)),
            "event"
        );
        assert_eq!(
            verdict(&format!(r#"{{"at":"{TS}","status":0}}"#)),
            "irrelevant"
        );
        assert_eq!(
            verdict(&format!(r#"{{"at":"{TS}","status":404}}"#)),
            "irrelevant"
        );
        assert_eq!(
            verdict(&format!(r#"{{"at":"{TS}","status":600}}"#)),
            "malformedEvent"
        );
        assert_eq!(
            verdict(&format!(r#"{{"at":"{TS}","status":99}}"#)),
            "malformedEvent"
        );
        assert_eq!(
            verdict(&format!(r#"{{"at":"{TS}","status":-5}}"#)),
            "malformedEvent"
        );
        // Missing/typed-wrong status is a malformed event.
        assert_eq!(
            verdict(&format!(r#"{{"at":"{TS}","model":"m"}}"#)),
            "malformedEvent"
        );
        assert_eq!(
            verdict(&format!(r#"{{"at":"{TS}","status":null}}"#)),
            "malformedEvent"
        );
        assert_eq!(
            verdict(&format!(r#"{{"at":"{TS}","status":"200"}}"#)),
            "malformedEvent"
        );
        assert_eq!(
            verdict(&format!(r#"{{"at":"{TS}","status":true}}"#)),
            "malformedEvent"
        );
        // Non-2xx short circuit requires a UNIQUE valid status.
        assert_eq!(
            verdict(&format!(r#"{{"at":"{TS}","status":404,"status":404}}"#)),
            "malformedEvent"
        );
        // Non-2xx + invalid timestamp is still irrelevant — the check runs first.
        assert_eq!(verdict(&format!(r#"{{"status":404}}"#)), "irrelevant");
    }

    #[test]
    fn duplicates_poison_uniqueness_last_value_wins() {
        let e = event(&format!(
            r#"{{"at":"{TS}","status":200,"status":500,"model":"first","model":"last"}}"#
        ));
        assert_eq!(
            verdict(&format!(
                r#"{{"at":"{TS}","status":200,"status":500,"model":"first","model":"last"}}"#
            )),
            "malformedEvent"
        );
        assert_eq!(e.status, 500);
        assert_eq!(e.model, "last");
        assert!(!e.has_unique_status_field);
        assert!(!e.has_unique_model_field);
        // `at` duplicates poison too.
        assert_eq!(
            verdict(&format!(r#"{{"at":"{TS}","at":"{TS}","status":200}}"#)),
            "malformedEvent"
        );
        // A duplicate whose last occurrence is invalid poisons both stored value and flag.
        let e = event(&format!(r#"{{"at":"{TS}","status":200,"status":"x"}}"#));
        assert_eq!(e.status, 0);
        assert!(!e.has_valid_status_field);
    }

    #[test]
    fn null_vs_absent_asymmetries() {
        // accountId / accountFingerprint nulls are valid.
        let e = event(&format!(
            r#"{{"at":"{TS}","status":200,"accountId":null,"accountFingerprint":null}}"#
        ));
        assert_eq!(
            verdict(&format!(
                r#"{{"at":"{TS}","status":200,"accountId":null,"accountFingerprint":null}}"#
            )),
            "event"
        );
        assert_eq!(e.account_id, None);
        assert!(e.has_valid_account_identity_fields);
        // provider / model / serviceTier nulls are invalid.
        assert_eq!(
            verdict(&format!(r#"{{"at":"{TS}","status":200,"provider":null}}"#)),
            "malformedEvent"
        );
        assert_eq!(
            verdict(&format!(r#"{{"at":"{TS}","status":200,"model":null}}"#)),
            "malformedEvent"
        );
        // A null tier flips `serviceTierValid` — a flag outside the `.event` verdict check.
        let e = event(&format!(
            r#"{{"at":"{TS}","status":200,"serviceTier":null}}"#
        ));
        assert_eq!(e.service_tier, None);
        assert_eq!(e.has_valid_service_tier_field, Some(false));
        // Non-string identity is invalid.
        assert_eq!(
            verdict(&format!(r#"{{"at":"{TS}","status":200,"accountId":5}}"#)),
            "malformedEvent"
        );
    }

    #[test]
    fn provider_empty_invalid_absent_valid() {
        assert_eq!(
            verdict(&format!(r#"{{"at":"{TS}","status":200,"provider":"  "}}"#)),
            "malformedEvent"
        );
        let e = event(&format!(r#"{{"at":"{TS}","status":200}}"#));
        assert_eq!(e.provider, "unknown");
        assert_eq!(e.has_valid_provider_field, Some(true));
    }

    #[test]
    fn model_empty_is_unattributed_but_valid() {
        let e = event(&format!(r#"{{"at":"{TS}","status":200,"model":"  "}}"#));
        assert_eq!(e.model, UNATTRIBUTED_MODEL);
        assert!(e.has_valid_model_field);
        assert_eq!(e.has_valid_model_field, true);
    }

    #[test]
    fn service_tier_values() {
        for (tier, valid) in [
            ("auto", true),
            ("default", true),
            ("standard", true),
            ("priority", true),
            ("fast", true),
            ("flex", true),
            ("batch", true),
            ("ultrafast", true),
            ("PRIORITY", true), // case-insensitive
            ("weird", false),
        ] {
            let line = format!(r#"{{"at":"{TS}","status":200,"serviceTier":"{tier}"}}"#);
            let e = event(&line);
            // An unknown tier is still a valid `.event` — its flag marks the
            // incomplete cost breakdown downstream.
            assert_eq!(verdict(&line), "event", "tier {tier}");
            assert_eq!(e.has_valid_service_tier_field, Some(valid), "tier {tier}");
            let expected_tier = if tier.is_empty() {
                None
            } else {
                Some(tier.to_lowercase())
            };
            assert_eq!(e.service_tier, expected_tier);
        }
        // A blank tier stores nil and flips the flag — still a valid `.event`, because
        // `hasValidServiceTierField` is not part of the `.event` verdict check.
        let e = event(&format!(
            r#"{{"at":"{TS}","status":200,"serviceTier":" "}}"#
        ));
        assert_eq!(e.service_tier, None);
        assert_eq!(e.has_valid_service_tier_field, Some(false));
    }

    #[test]
    fn token_saturation_vs_negative() {
        // Saturated positive measured counts are valid and flagged.
        let e = event(&format!(
            r#"{{"at":"{TS}","status":200,"inputTokens":1000000000000001}}"#
        ));
        assert_eq!(
            verdict(&format!(
                r#"{{"at":"{TS}","status":200,"inputTokens":1000000000000001}}"#
            )),
            "event"
        );
        assert_eq!(e.input_tokens, 1_000_000_000_000_000);
        assert_eq!(e.token_count_saturated, Some(true));
        // Negative counts are invalid, stored, and clamped to 0 in the event.
        let e = event(&format!(r#"{{"at":"{TS}","status":200,"inputTokens":-5}}"#));
        assert_eq!(
            verdict(&format!(r#"{{"at":"{TS}","status":200,"inputTokens":-5}}"#)),
            "malformedEvent"
        );
        assert_eq!(e.input_tokens, 0);
        assert!(!e.has_input_tokens_field);
        assert!(!e.has_valid_numeric_count_fields);
        // Negative saturation is invalid too (saturated && value < 0 → invalid write).
        assert_eq!(
            verdict(&format!(
                r#"{{"at":"{TS}","status":200,"inputTokens":-2000000000000001}}"#
            )),
            "malformedEvent"
        );
        // 1e15 itself is in range.
        let e = event(&format!(
            r#"{{"at":"{TS}","status":200,"inputTokens":1000000000000000}}"#
        ));
        assert_eq!(e.input_tokens, 1_000_000_000_000_000);
        assert_eq!(e.token_count_saturated, None);
        // Float overflow saturates positively.
        let e = event(&format!(
            r#"{{"at":"{TS}","status":200,"inputTokens":1e309}}"#
        ));
        assert_eq!(e.input_tokens, 1_000_000_000_000_000);
        assert_eq!(e.token_count_saturated, Some(true));
        // The estimated input is never measured — it cannot set the saturated flag.
        let e = event(&format!(
            r#"{{"at":"{TS}","status":200,"inputTokens":10,"outputTokens":20,"totalTokens":30,"estimatedInputTokens":1000000000000001}}"#
        ));
        assert_eq!(e.token_count_saturated, None);
        assert_eq!(e.has_estimated_input_tokens, Some(true));
    }

    #[test]
    fn timestamp_edges() {
        // Missing → malformed event (distant past).
        let e = event(&format!(r#"{{"status":200,"model":"m"}}"#));
        assert_eq!(
            verdict(&format!(r#"{{"status":200,"model":"m"}}"#)),
            "malformedEvent"
        );
        assert_eq!(e.timestamp, DISTANT_PAST);
        assert!(!e.has_valid_timestamp_field);
        // Non-string / null / invalid-shape → malformed event.
        assert_eq!(
            verdict(&format!(r#"{{"status":200,"at":123}}"#)),
            "malformedEvent"
        );
        assert_eq!(
            verdict(&format!(r#"{{"status":200,"at":null}}"#)),
            "malformedEvent"
        );
        assert_eq!(
            verdict(&format!(r#"{{"status":200,"at":"2026-13-02T12:00:00Z"}}"#)),
            "malformedEvent"
        );
        // Canonical-shape but impossible date → malformed event (never falls to Foundation).
        assert_eq!(
            verdict(&format!(r#"{{"status":200,"at":"2026-02-29T12:00:00Z"}}"#)),
            "malformedEvent"
        );
        // Non-canonical strings are legal for OpenUsageISO8601 → Rust declines.
        for ts in [
            "2026-10-02 12:00:00",
            "2026-10-02T12:00:00+00:00",
            "2026-10-02T12:00:00.1234Z",
            "2026-10-02T12:00:00.123456Z",
            "2026-10-02T12:00:00 UTC",
        ] {
            assert_eq!(
                verdict(&format!(r#"{{"status":200,"at":"{ts}"}}"#)),
                "fallback",
                "timestamp {ts}"
            );
        }
    }

    #[test]
    fn structural_bail_classification() {
        // Non-object JSON → malformed; the empty line is irrelevant
        // (`guard !line.isEmpty else { return .irrelevant }`).
        for line in ["[1,2]", "\"x\"", "123", "null", "true"] {
            assert_eq!(verdict(line), "malformed", "{line:?}");
        }
        assert_eq!(verdict(""), "irrelevant");
        // Whitespace-only → irrelevant.
        assert_eq!(verdict("   \t\r\n  "), "irrelevant");
        // A walkable object with only unrecognized keys still resolves `at` — missing
        // here — so it is a malformed event, not an irrelevant bail.
        assert_eq!(verdict(r#"{"foo":1,"bar":[true,null]}"#), "malformedEvent");
        // Field names are case-sensitive: `STATUS` is unrecognized, the object still
        // walks, and `at` is missing → malformed event (not a bail at all).
        assert_eq!(verdict(r#"{"STATUS":200}"#), "malformedEvent");
        // Recognized-key-bearing object that cannot be walked → malformed.
        assert_eq!(verdict(r#"{"status":}"#), "malformed");
        assert_eq!(verdict(r#"{"status":200"#), "malformed");
        // A lone surrogate in an UNRECOGNIZED field never decodes — the lenient scan
        // accepts its shape — so the line walks and lands on the missing `at`.
        assert_eq!(verdict(r#"{"pad":"\ud800"}"#), "malformedEvent");
        // A recognized field whose value fails to decode bails the walk.
        assert_eq!(verdict(r#"{"model":"\ud800"}"#), "malformed");
        assert_eq!(verdict(r#"{"model":"\ud800\u0041"}"#), "malformed");
        assert_eq!(verdict(r#"{"model":"\udc00"}"#), "malformed");
        // Surrogate pairs decode.
        assert_eq!(
            verdict(&format!(
                r#"{{"at":"{TS}","status":200,"model":"\ud83d\ude00m"}}"#
            )),
            "event"
        );
    }

    #[test]
    fn trailing_comma_foundation_acceptance() {
        // The walker rejects a trailing comma, but Foundation accepts the object — the
        // verdict then depends on key presence, not syntax.
        assert_eq!(verdict(r#"{"pad":1,}"#), "irrelevant");
        assert_eq!(verdict(r#"{"status":200,}"#), "malformed");
        assert_eq!(verdict(r#"{"pad":[1,]}"#), "irrelevant");
        assert_eq!(verdict(r#"{"status":[1,]}"#), "malformed");
        assert_eq!(verdict(r#"{"pad":{"x":1,}}"#), "irrelevant");
        // Double trailing commas are still invalid everywhere.
        assert_eq!(verdict(r#"{"pad":1,,}"#), "malformed");
    }

    #[test]
    fn foundation_number_edges_on_bail_path() {
        // Integer parts must fit Decimal's range — only reachable through the bail path
        // (the main walker's skipNumber accepts any magnitude).
        let huge = "9".repeat(166);
        assert_eq!(verdict(&format!(r#"{{"pad":{huge},}}"#)), "malformed");
        let limit = "1".to_string() + &"0".repeat(165);
        assert_eq!(verdict(&format!(r#"{{"pad":{limit},}}"#)), "irrelevant");
        // Float +inf is rejected, -inf accepted — via a bail-triggering shape.
        assert_eq!(verdict(r#"{"pad":1e999,}"#), "malformed");
        assert_eq!(verdict(r#"{"pad":-1e999,}"#), "irrelevant");
    }

    #[test]
    fn depth_over_128_bails_to_foundation() {
        let deep = "[".repeat(130) + &"]".repeat(130);
        assert_eq!(verdict(&format!(r#"{{"pad":{deep}}}"#)), "irrelevant");
        assert_eq!(
            verdict(&format!(r#"{{"status":200,"pad":{deep}}}"#)),
            "malformed"
        );
        // Beyond Foundation's own 512 bound the object is invalid → malformed.
        let deeper = "[".repeat(520) + &"]".repeat(520);
        assert_eq!(verdict(&format!(r#"{{"pad":{deeper}}}"#)), "malformed");
        // 129-deep still walks: the outermost `[` is depth 0, so `[`#129 lands at
        // depth 128 — the inclusive bound. The walk completes and `at` is missing.
        let ok = "[".repeat(129) + &"]".repeat(129);
        assert_eq!(verdict(&format!(r#"{{"pad":{ok}}}"#)), "malformedEvent");
        // `[`#130 hits depth 129 → bail → Foundation (under its 512 bound) → irrelevant.
        let bail = "[".repeat(130) + &"]".repeat(130);
        assert_eq!(verdict(&format!(r#"{{"pad":{bail}}}"#)), "irrelevant");
    }

    #[test]
    fn leading_bom_is_tolerated() {
        assert_eq!(verdict("\u{feff}{\"pad\":1,}"), "irrelevant");
        assert_eq!(verdict("\u{feff}{\"status\":1,}"), "malformed");
    }

    #[test]
    fn torn_and_unwalkable_members() {
        // Torn nested object in an unknown field → malformed.
        assert_eq!(
            verdict(&format!(r#"{{"at":"{TS}","pad":{{"x" 1}}}}"#)),
            "malformed"
        );
        // A *valid* nested value in an unknown field does not touch the event.
        assert_eq!(
            verdict(&format!(
                r#"{{"at":"{TS}","status":200,"pad":{{"x":[1,2,{{"y":"z"}}]}}}}"#
            )),
            "event"
        );
        // Missing comma.
        assert_eq!(
            verdict(&format!(r#"{{"at":"{TS}","status":200 "x":1}}"#)),
            "malformed"
        );
        // Torn string.
        assert_eq!(
            verdict(&format!(r#"{{"at":"{TS}","model":"unfinished}}"#)),
            "malformed"
        );
        // A raw control character inside a string bails the whole line.
        assert_eq!(
            verdict(&format!("{{\"at\":\"{TS}\",\"pad\":\"a\nb\"}}")),
            "malformed"
        );
    }

    #[test]
    fn estimated_input_is_not_measured() {
        let e = event(&format!(
            r#"{{"at":"{TS}","status":200,"estimatedInputTokens":-5}}"#
        ));
        assert_eq!(e.has_estimated_input_tokens, Some(false));
        assert!(!e.has_valid_numeric_count_fields);
        assert!(!e.has_valid_estimated_input_tokens_field);
    }

    #[test]
    fn looks_like_complete_object_check() {
        assert!(looks_like_complete_object(b"{}"));
        assert!(looks_like_complete_object(b" {\"a\":1} \t\n"));
        assert!(!looks_like_complete_object(b"{\"a\":1"));
        assert!(!looks_like_complete_object(b""));
        assert!(!looks_like_complete_object(b"   "));
    }

    #[test]
    fn invalid_utf8_in_strings() {
        let mut line = br#"{"at":"2026-10-02T12:00:00Z","model":""#.to_vec();
        line.push(0xFF);
        line.extend_from_slice(b"\"}");
        assert!(matches!(parse_line(&line), ParsedLine::Malformed));
        let mut pad = br#"{"at":"2026-10-02T12:00:00Z","pad":""#.to_vec();
        pad.push(0xFF);
        pad.extend_from_slice(b"\"}");
        assert!(matches!(parse_line(&pad), ParsedLine::Malformed));
    }

    #[test]
    fn whitespace_and_framing() {
        assert_eq!(
            verdict(&format!(" {{\"at\":\"{TS}\",\"status\":200}} \t\r\n")),
            "event"
        );
        assert_eq!(
            verdict(&format!("{{\"at\":\"{TS}\",\"status\":200}}x")),
            "malformed"
        );
        assert_eq!(
            verdict(&format!("{{\"at\":\"{TS}\",\"status\":200}} {{}}")),
            "malformed"
        );
    }
}
