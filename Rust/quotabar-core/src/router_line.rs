//! CodexRouter event-line parser — port of `CodexRouterEventLineParser` (Swift).
//!
//! `OpenCodeRouterLedger.parseRow` folds the shared CodexRouter ledger
//! (`~/.codex/codex-router/usage-events.jsonl`, tens of thousands of flat JSON objects) on every
//! OpenCode refresh, and the per-line Foundation parse is the hot stage of that fold. This module
//! reproduces the Swift scanner's byte-level walk exactly — including its duplicate-field,
//! wrong-type and numeric-validity rules — so the fold can keep every aggregation, classification
//! and output decision in Swift while the line parse itself runs here.
//!
//! The Swift parser remains the reference oracle and the runtime fallback. `parse_router_line`
//! returns `None` when it cannot *prove* the Swift answer: non-ASCII bytes (Foundation's Unicode
//! trimming and lowercasing), escaped string keys/values, timestamps that are not the canonical
//! `…Z` shapes (a non-canonical shape may still be Foundation-parseable), and any structural
//! failure (Swift then re-checks the line with `JSONSerialization` to separate unrelated objects
//! from damaged event rows). Every accepted line produces the same result and the same
//! `CodexRouterUsageScanner.Event` field values the Swift parser produces, byte for byte.

use crate::{parse_canonical_utc, CanonicalTimestamp};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;

pub const QB_ROUTER_KIND_EVENT: u8 = 0;
pub const QB_ROUTER_KIND_MALFORMED_EVENT: u8 = 1;
pub const QB_ROUTER_KIND_IRRELEVANT: u8 = 2;

/// `Date.distantPast.timeIntervalSince1970`: the timestamp Swift attaches to an event row whose
/// `at` field could not be parsed.
pub const DISTANT_PAST_SECONDS: f64 = -62_135_769_600.0;

const NIL_I64: i64 = i64::MIN;

#[derive(Clone, Copy, Default)]
pub struct RouterFlags {
    pub has_valid_status_field: bool,
    pub has_valid_timestamp_field: bool,
    pub has_valid_model_field: bool,
    pub has_unique_status_field: bool,
    pub has_unique_provider_field: bool,
    pub has_unique_model_field: bool,
    pub has_unique_account_identity_fields: bool,
    pub has_valid_numeric_count_fields: bool,
    pub has_unique_recognized_fields: bool,
    pub has_input_tokens_field: bool,
    pub has_output_tokens_field: bool,
    pub has_valid_cached_input_tokens_field: bool,
    pub has_valid_total_tokens_field: bool,
    pub has_valid_estimated_input_tokens_field: bool,
    pub has_estimated_input_tokens: bool,
    pub has_valid_account_identity_fields: bool,
    pub has_valid_provider_field: bool,
    pub has_valid_service_tier_field: bool,
    pub token_count_saturated: bool,
}

pub struct RouterEvent {
    pub timestamp: f64,
    pub status: i64,
    pub input_tokens: i64,
    pub cached_input_tokens: i64,
    pub output_tokens: i64,
    pub reasoning_tokens: i64,
    /// `None` mirrors Swift's `totalTokens == nil`.
    pub total_tokens: Option<i64>,
    pub model: String,
    pub provider: String,
    pub account_id: Option<String>,
    pub account_fingerprint: Option<String>,
    pub service_tier: Option<String>,
    pub flags: RouterFlags,
}

pub enum RouterLineResult {
    Event(RouterEvent),
    MalformedEvent(RouterEvent),
    Irrelevant,
}

// ---------------------------------------------------------------------------
// Field identities (mirror of CodexRouterEventLineParser.Field)
// ---------------------------------------------------------------------------

const F_AT: usize = 0;
const F_MODEL: usize = 1;
const F_PROVIDER: usize = 2;
const F_STATUS: usize = 3;
const F_INPUT: usize = 4;
const F_CACHED: usize = 5;
const F_OUTPUT: usize = 6;
const F_REASONING: usize = 7;
const F_TOTAL: usize = 8;
const F_ESTIMATED: usize = 9;
const F_ACCOUNT_ID: usize = 10;
const F_ACCOUNT_FP: usize = 11;
const F_SERVICE_TIER: usize = 12;

const KNOWN_SERVICE_TIERS: [&str; 8] = [
    "auto", "default", "standard", "priority", "fast", "flex", "batch", "ultrafast",
];

fn field_named(key: &[u8]) -> Option<usize> {
    match key {
        b"at" => Some(F_AT),
        b"model" => Some(F_MODEL),
        b"provider" => Some(F_PROVIDER),
        b"status" => Some(F_STATUS),
        b"inputTokens" => Some(F_INPUT),
        b"cachedInputTokens" => Some(F_CACHED),
        b"outputTokens" => Some(F_OUTPUT),
        b"reasoningTokens" => Some(F_REASONING),
        b"totalTokens" => Some(F_TOTAL),
        b"estimatedInputTokens" => Some(F_ESTIMATED),
        b"accountId" => Some(F_ACCOUNT_ID),
        b"accountFingerprint" => Some(F_ACCOUNT_FP),
        b"serviceTier" => Some(F_SERVICE_TIER),
        _ => None,
    }
}

fn is_string_field(field: usize) -> bool {
    matches!(
        field,
        F_AT | F_MODEL | F_PROVIDER | F_ACCOUNT_ID | F_ACCOUNT_FP | F_SERVICE_TIER
    )
}

fn is_numeric_count_field(field: usize) -> bool {
    matches!(
        field,
        F_INPUT | F_CACHED | F_OUTPUT | F_REASONING | F_TOTAL | F_ESTIMATED
    )
}

fn is_measured_count_field(field: usize) -> bool {
    matches!(field, F_INPUT | F_CACHED | F_OUTPUT | F_REASONING | F_TOTAL)
}

fn is_successful_status(status: i64) -> bool {
    (200..300).contains(&status)
}

// ---------------------------------------------------------------------------
// Field accumulator (mirror of CodexRouterEventLineParser.Fields)
// ---------------------------------------------------------------------------

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
    seen_fields: u32,
    duplicate_fields: u32,
    recognized_fields_unique: bool,
    /// Indexed by [`F_INPUT`]..=[`F_ESTIMATED`]; `None` mirrors Swift's absent dictionary entry.
    numeric_validity: [Option<bool>; 6],
}

impl Fields {
    fn new() -> Fields {
        Fields {
            at: None,
            model: None,
            model_valid: true,
            provider: None,
            provider_valid: true,
            status: None,
            status_seen: false,
            status_valid: false,
            input_tokens: None,
            cached_input_tokens: None,
            output_tokens: None,
            reasoning_tokens: None,
            total_tokens: None,
            estimated_input_tokens: None,
            token_count_saturated: false,
            cached_input_tokens_seen: false,
            cached_input_tokens_valid: false,
            total_tokens_seen: false,
            total_tokens_valid: false,
            estimated_input_tokens_seen: false,
            estimated_input_tokens_valid: false,
            account_id: None,
            account_fingerprint: None,
            account_id_valid: true,
            account_fingerprint_valid: true,
            service_tier: None,
            service_tier_valid: true,
            seen_fields: 0,
            duplicate_fields: 0,
            recognized_fields_unique: true,
            numeric_validity: [None; 6],
        }
    }

    /// Swift's `seenFields.insert(field).inserted`: false on the second occurrence.
    fn observe(&mut self, field: usize) -> bool {
        let bit = 1u32 << field;
        if self.seen_fields & bit != 0 {
            self.recognized_fields_unique = false;
            self.duplicate_fields |= bit;
            false
        } else {
            self.seen_fields |= bit;
            true
        }
    }

    fn numeric_slot(field: usize) -> Option<usize> {
        match field {
            F_INPUT => Some(0),
            F_CACHED => Some(1),
            F_OUTPUT => Some(2),
            F_REASONING => Some(3),
            F_TOTAL => Some(4),
            F_ESTIMATED => Some(5),
            _ => None,
        }
    }

    fn set_numeric_validity(&mut self, field: usize, valid: bool) {
        if let Some(slot) = Self::numeric_slot(field) {
            self.numeric_validity[slot] = Some(valid);
        }
    }

    fn set_string(&mut self, field: usize, value: &str) {
        match field {
            F_AT => self.at = Some(value.to_owned()),
            F_MODEL => {
                self.model = Some(value.to_owned());
                self.model_valid = true;
            }
            F_PROVIDER => {
                let trimmed = value.trim();
                self.provider = nil_if_empty(trimmed);
                self.provider_valid = self.provider.is_some();
            }
            F_ACCOUNT_ID => {
                self.account_id = Some(value.to_owned());
                self.account_id_valid = true;
            }
            F_ACCOUNT_FP => {
                self.account_fingerprint = Some(value.to_owned());
                self.account_fingerprint_valid = true;
            }
            F_SERVICE_TIER => {
                let tier = value.trim().to_ascii_lowercase();
                self.service_tier_valid = KNOWN_SERVICE_TIERS.contains(&tier.as_str());
                self.service_tier = nil_if_empty(&tier);
            }
            _ => {}
        }
    }

    fn set_integer(&mut self, field: usize, value: i64) {
        match field {
            F_STATUS => {
                self.status = Some(value);
                self.status_seen = true;
                // The router emits an explicit zero for a canceled/failed transport attempt.
                self.status_valid = value == 0 || (100..600).contains(&value);
            }
            F_INPUT => {
                self.input_tokens = Some(value);
                self.set_numeric_validity(field, value >= 0);
            }
            F_CACHED => {
                self.cached_input_tokens = Some(value);
                self.cached_input_tokens_valid = value >= 0;
                self.set_numeric_validity(field, value >= 0);
            }
            F_OUTPUT => {
                self.output_tokens = Some(value);
                self.set_numeric_validity(field, value >= 0);
            }
            F_REASONING => {
                self.reasoning_tokens = Some(value);
                self.set_numeric_validity(field, value >= 0);
            }
            F_TOTAL => {
                self.total_tokens = Some(value);
                self.total_tokens_valid = value >= 0;
                self.set_numeric_validity(field, value >= 0);
            }
            F_ESTIMATED => {
                self.estimated_input_tokens = Some(value);
                self.estimated_input_tokens_valid = value >= 0;
                self.set_numeric_validity(field, value >= 0);
            }
            _ => {}
        }
    }

    fn clear(&mut self, field: usize) {
        match field {
            F_AT => self.at = None,
            F_MODEL => {
                self.model = None;
                self.model_valid = false;
            }
            F_PROVIDER => {
                self.provider = None;
                self.provider_valid = false;
            }
            F_STATUS => {
                self.status = None;
                self.status_seen = true;
                self.status_valid = false;
            }
            F_INPUT => {
                self.input_tokens = None;
                self.set_numeric_validity(field, false);
            }
            F_CACHED => {
                self.cached_input_tokens = None;
                self.cached_input_tokens_seen = true;
                self.cached_input_tokens_valid = false;
                self.set_numeric_validity(field, false);
            }
            F_OUTPUT => {
                self.output_tokens = None;
                self.set_numeric_validity(field, false);
            }
            F_REASONING => {
                self.reasoning_tokens = None;
                self.set_numeric_validity(field, false);
            }
            F_TOTAL => {
                self.total_tokens = None;
                self.total_tokens_seen = true;
                self.total_tokens_valid = false;
                self.set_numeric_validity(field, false);
            }
            F_ESTIMATED => {
                self.estimated_input_tokens = None;
                self.estimated_input_tokens_seen = true;
                self.estimated_input_tokens_valid = false;
                self.set_numeric_validity(field, false);
            }
            F_ACCOUNT_ID => {
                self.account_id = None;
                self.account_id_valid = false;
            }
            F_ACCOUNT_FP => {
                self.account_fingerprint = None;
                self.account_fingerprint_valid = false;
            }
            F_SERVICE_TIER => {
                self.service_tier = None;
                self.service_tier_valid = false;
            }
            _ => {}
        }
    }

    fn set_null(&mut self, field: usize) {
        match field {
            // Optional identity fields may be explicitly null in legacy router rows.
            F_ACCOUNT_ID => self.account_id_valid = true,
            F_ACCOUNT_FP => self.account_fingerprint_valid = true,
            F_SERVICE_TIER => self.service_tier_valid = false,
            F_PROVIDER => self.provider_valid = false,
            F_MODEL => self.model_valid = false,
            _ => {}
        }
    }

    fn account_identity_fields_valid(&self) -> bool {
        self.account_id_valid && self.account_fingerprint_valid
    }

    fn numeric_count_fields_valid(&self) -> bool {
        self.numeric_validity.iter().all(|slot| *slot != Some(false))
    }

    fn field_unique(&self, field: usize) -> bool {
        self.duplicate_fields & (1u32 << field) == 0
    }
}

fn nil_if_empty(value: &str) -> Option<String> {
    if value.is_empty() {
        None
    } else {
        Some(value.to_owned())
    }
}

// ---------------------------------------------------------------------------
// Byte scanning (mirror of JSONLineStructure)
// ---------------------------------------------------------------------------

fn is_whitespace(byte: u8) -> bool {
    byte == b' ' || byte == b'\t' || byte == b'\n' || byte == b'\r'
}

struct StringToken {
    content: (usize, usize),
    next: usize,
    has_escapes: bool,
}

fn is_hex_digit(byte: u8) -> bool {
    byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte) || (b'A'..=b'F').contains(&byte)
}

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
                content: (opening_quote + 1, cursor),
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
                        if !is_hex_digit(bytes[index]) {
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

fn valid_utf8_width(bytes: &[u8], index: usize, end: usize) -> Option<usize> {
    let first = bytes[index];
    let continuation = |offset: usize, range: (u8, u8)| -> bool {
        index + offset < end && bytes[index + offset] >= range.0 && bytes[index + offset] <= range.1
    };
    let default_range = (0x80, 0xBF);
    match first {
        0xC2..=0xDF => (continuation(1, default_range)).then_some(2),
        0xE0 => (continuation(1, (0xA0, 0xBF)) && continuation(2, default_range)).then_some(3),
        0xE1..=0xEC | 0xEE..=0xEF => {
            (continuation(1, default_range) && continuation(2, default_range)).then_some(3)
        }
        0xED => (continuation(1, (0x80, 0x9F)) && continuation(2, default_range)).then_some(3),
        0xF0 => {
            (continuation(1, (0x90, 0xBF))
                && continuation(2, default_range)
                && continuation(3, default_range))
            .then_some(4)
        }
        0xF1..=0xF3 => {
            (continuation(1, default_range)
                && continuation(2, default_range)
                && continuation(3, default_range))
            .then_some(4)
        }
        0xF4 => {
            (continuation(1, (0x80, 0x8F))
                && continuation(2, default_range)
                && continuation(3, default_range))
            .then_some(4)
        }
        _ => None,
    }
}

fn skip_whitespace(bytes: &[u8], cursor: &mut usize, end: usize) {
    while *cursor < end && is_whitespace(bytes[*cursor]) {
        *cursor += 1;
    }
}

fn skip_value(bytes: &[u8], start: usize, end: usize) -> Option<usize> {
    let mut cursor = start;
    skip_whitespace(bytes, &mut cursor, end);
    if parse_value(bytes, &mut cursor, end, 0) {
        Some(cursor)
    } else {
        None
    }
}

fn consume_literal(bytes: &[u8], cursor: &mut usize, end: usize, literal: &[u8]) -> bool {
    if *cursor + literal.len() > end {
        return false;
    }
    for offset in 0..literal.len() {
        if bytes[*cursor + offset] != literal[offset] {
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

fn parse_value(bytes: &[u8], cursor: &mut usize, end: usize, depth: u32) -> bool {
    if *cursor >= end || depth > 128 {
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
            skip_whitespace(bytes, cursor, end);
            if *cursor < end && bytes[*cursor] == b'}' {
                *cursor += 1;
                return true;
            }
            while *cursor < end {
                if bytes[*cursor] != b'"' {
                    return false;
                }
                let key = match scan_string(bytes, *cursor, end) {
                    Some(token) => token,
                    None => return false,
                };
                *cursor = key.next;
                skip_whitespace(bytes, cursor, end);
                if *cursor >= end || bytes[*cursor] != b':' {
                    return false;
                }
                *cursor += 1;
                skip_whitespace(bytes, cursor, end);
                if !parse_value(bytes, cursor, end, depth + 1) {
                    return false;
                }
                skip_whitespace(bytes, cursor, end);
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
                skip_whitespace(bytes, cursor, end);
                if *cursor >= end || bytes[*cursor] == b'}' {
                    return false;
                }
            }
            false
        }
        b'[' => {
            *cursor += 1;
            skip_whitespace(bytes, cursor, end);
            if *cursor < end && bytes[*cursor] == b']' {
                *cursor += 1;
                return true;
            }
            while *cursor < end {
                if !parse_value(bytes, cursor, end, depth + 1) {
                    return false;
                }
                skip_whitespace(bytes, cursor, end);
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
                skip_whitespace(bytes, cursor, end);
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

// ---------------------------------------------------------------------------
// Whole-line parse (mirror of CodexRouterEventLineParser.parse)
// ---------------------------------------------------------------------------

struct ParsedInteger {
    value: i64,
    next: usize,
    is_exact_integer: bool,
    is_within_bounds: bool,
    is_saturated: bool,
}

const CEILING: f64 = 1_000_000_000_000_000.0;

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

    let mut needs_floating_point_conversion = false;
    if cursor < end && bytes[cursor] == b'.' {
        needs_floating_point_conversion = true;
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
        needs_floating_point_conversion = true;
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
    skip_whitespace(bytes, &mut next, end);
    if next != end && bytes[next] != b',' {
        return None;
    }

    let value: i64;
    let is_exact_integer: bool;
    let is_within_bounds: bool;
    let is_saturated: bool;
    if needs_floating_point_conversion {
        let text = std::str::from_utf8(&bytes[start..number_end]).ok()?;
        let number: f64 = text.parse().ok()?;
        // Swift's `Double(String)` rejects a few spellings Rust accepts (e.g. a trailing `.`), but
        // that shape never reaches here: the scanner above requires at least one fraction digit.
        if number.is_nan() {
            return None;
        }
        is_exact_integer = number.is_finite() && number.trunc() == number;
        is_within_bounds = number.is_finite() && number.abs() <= CEILING;
        is_saturated = !is_within_bounds;
        if number.is_infinite() {
            value = if negative {
                -(CEILING as i64)
            } else {
                CEILING as i64
            };
        } else {
            let clamped = number.floor().max(-CEILING).min(CEILING);
            value = clamped as i64;
        }
    } else {
        is_exact_integer = true;
        let digits_start = if negative { start + 1 } else { start };
        let mut magnitude: i64 = 0;
        let mut saturated = false;
        for &byte in &bytes[digits_start..number_end] {
            let digit = i64::from(byte - b'0');
            if magnitude > (CEILING as i64 - digit) / 10 {
                magnitude = CEILING as i64;
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

fn is_number_start(byte: u8) -> bool {
    byte == b'-' || byte.is_ascii_digit()
}

/// `None` means "let the Swift parser decide": the line is not pure ASCII, a string key or value
/// is escaped, the timestamp is not canonical, or the structure did not parse.
fn parse_object(line: &[u8]) -> Option<(Fields, Option<f64>)> {
    let mut object_start = 0;
    while object_start < line.len() && is_whitespace(line[object_start]) {
        object_start += 1;
    }
    if object_start + 1 >= line.len() || line[object_start] != b'{' {
        return None;
    }
    let mut object_end = line.len();
    while object_end > 1 && is_whitespace(line[object_end - 1]) {
        object_end -= 1;
    }
    if object_end <= 1 || line[object_end - 1] != b'}' {
        return None;
    }
    object_end -= 1;

    let mut fields = Fields::new();
    let mut cursor = object_start + 1;
    while cursor < object_end {
        skip_whitespace(line, &mut cursor, object_end);
        if cursor == object_end {
            break;
        }
        if line[cursor] != b'"' {
            return None;
        }
        let key = scan_string(line, cursor, object_end)?;
        if key.has_escapes {
            return None;
        }
        let field = field_named(&line[key.content.0..key.content.1]);
        cursor = key.next;
        skip_whitespace(line, &mut cursor, object_end);
        if cursor >= object_end || line[cursor] != b':' {
            return None;
        }
        cursor += 1;
        skip_whitespace(line, &mut cursor, object_end);
        if cursor >= object_end {
            return None;
        }

        let value_start = cursor;
        if let Some(field) = field {
            fields.observe(field);
            fields.clear(field);
        }
        if let Some(field) = field.filter(|&f| is_string_field(f)) {
            if line[cursor] == b'"' {
                let token = scan_string(line, cursor, object_end)?;
                if token.has_escapes {
                    return None;
                }
                let value = std::str::from_utf8(&line[token.content.0..token.content.1]).ok()?;
                fields.set_string(field, value);
                cursor = token.next;
            } else {
                let next = skip_value(line, value_start, object_end)?;
                if next - value_start == 4 && &line[value_start..next] == b"null" {
                    fields.set_null(field);
                }
                cursor = next;
            }
        } else if let Some(field) = field {
            if is_number_start(line[cursor]) {
                let parsed = parse_integer(line, cursor, object_end)?;
                fields.set_integer(field, parsed.value);
                if field == F_STATUS && !parsed.is_exact_integer {
                    fields.status_valid = false;
                }
                if is_numeric_count_field(field) {
                    if parsed.is_saturated && parsed.value >= 0 {
                        // estimatedInputTokens only describes router-side cost coverage; a clamped
                        // estimate cannot make an exact measured count look like a lower bound.
                        if is_measured_count_field(field) {
                            fields.token_count_saturated = true;
                        }
                    } else if !parsed.is_exact_integer || !parsed.is_within_bounds {
                        fields.set_numeric_validity(field, false);
                    }
                }
                cursor = parsed.next;
            } else {
                let next = skip_value(line, value_start, object_end)?;
                if next - value_start == 4 && &line[value_start..next] == b"null" {
                    fields.set_null(field);
                }
                cursor = next;
            }
        } else {
            cursor = skip_value(line, value_start, object_end)?;
        }

        skip_whitespace(line, &mut cursor, object_end);
        if cursor == object_end {
            break;
        }
        if line[cursor] == b',' {
            cursor += 1;
            skip_whitespace(line, &mut cursor, object_end);
            if cursor >= object_end {
                return None;
            }
        } else {
            return None;
        }
    }

    if cursor != object_end {
        return None;
    }

    let timestamp = match fields.at.as_deref().map(str::trim) {
        Some(value) if !value.is_empty() => match parse_canonical_utc(value.as_bytes()) {
            CanonicalTimestamp::Ok(seconds) => Some(seconds),
            CanonicalTimestamp::Invalid => None,
            // A non-canonical shape may still be Foundation-parseable; only Swift can decide.
            CanonicalTimestamp::NotCanonical => return None,
        },
        _ => None,
    };
    Some((fields, timestamp))
}

fn make_event(fields: &mut Fields, timestamp: Option<f64>) -> RouterEvent {
    let model = fields
        .model
        .as_deref()
        .map(str::trim)
        .and_then(nil_if_empty)
        .unwrap_or_else(|| "Unattributed".to_owned());
    let provider = fields
        .provider
        .as_deref()
        .map(str::trim)
        .and_then(nil_if_empty)
        .unwrap_or_else(|| "unknown".to_owned());
    let account_id = fields
        .account_id
        .as_deref()
        .map(str::trim)
        .and_then(nil_if_empty);
    let account_fingerprint = fields
        .account_fingerprint
        .as_deref()
        .map(str::trim)
        .and_then(nil_if_empty);
    let service_tier = fields
        .service_tier
        .as_deref()
        .map(str::trim)
        .and_then(nil_if_empty)
        .map(|value| value.to_ascii_lowercase());

    let input_tokens = fields.input_tokens.unwrap_or(0).max(0);
    let cached_input_tokens = fields.cached_input_tokens.unwrap_or(0).max(0);
    let output_tokens = fields.output_tokens.unwrap_or(0).max(0);
    let reasoning_tokens = fields.reasoning_tokens.unwrap_or(0).max(0);
    let total_tokens = fields.total_tokens.filter(|value| *value >= 0);
    let has_input_tokens_field = fields.input_tokens.map(|value| value >= 0).unwrap_or(false);
    let has_output_tokens_field = fields.output_tokens.map(|value| value >= 0).unwrap_or(false);
    let has_estimated_input_tokens = fields
        .estimated_input_tokens
        .map(|value| value > 0)
        .unwrap_or(false);

    RouterEvent {
        timestamp: timestamp.unwrap_or(DISTANT_PAST_SECONDS),
        status: fields.status.unwrap_or(0),
        input_tokens,
        cached_input_tokens,
        output_tokens,
        reasoning_tokens,
        total_tokens,
        model,
        provider,
        account_id,
        account_fingerprint,
        service_tier,
        flags: RouterFlags {
            has_valid_status_field: fields.status_seen && fields.status_valid,
            has_valid_timestamp_field: timestamp.is_some(),
            has_valid_model_field: fields.model_valid,
            has_unique_status_field: fields.field_unique(F_STATUS),
            has_unique_provider_field: fields.field_unique(F_PROVIDER),
            has_unique_model_field: fields.field_unique(F_MODEL),
            has_unique_account_identity_fields: !(fields.duplicate_fields
                & ((1u32 << F_ACCOUNT_ID) | (1u32 << F_ACCOUNT_FP))
                != 0),
            has_valid_numeric_count_fields: fields.numeric_count_fields_valid(),
            has_unique_recognized_fields: fields.recognized_fields_unique,
            has_input_tokens_field,
            has_output_tokens_field,
            has_valid_cached_input_tokens_field: !fields.cached_input_tokens_seen
                || fields.cached_input_tokens_valid,
            has_valid_total_tokens_field: !fields.total_tokens_seen || fields.total_tokens_valid,
            has_valid_estimated_input_tokens_field: !fields.estimated_input_tokens_seen
                || fields.estimated_input_tokens_valid,
            has_estimated_input_tokens,
            has_valid_account_identity_fields: fields.account_identity_fields_valid(),
            has_valid_provider_field: fields.provider_valid,
            has_valid_service_tier_field: fields.service_tier_valid,
            token_count_saturated: fields.token_count_saturated,
        },
    }
}

fn is_reportable(event: &RouterEvent) -> bool {
    event.flags.has_valid_status_field
        && event.flags.has_valid_account_identity_fields
        && event.flags.has_valid_model_field
        && event.flags.has_valid_numeric_count_fields
        && event.flags.has_unique_recognized_fields
        && event.flags.has_valid_provider_field
}

fn is_irrelevant(event: &RouterEvent) -> bool {
    event.flags.has_valid_status_field
        && event.flags.has_unique_status_field
        && !is_successful_status(event.status)
}

pub fn parse_router_line(line: &[u8]) -> Option<RouterLineResult> {
    if line.iter().any(|byte| *byte >= 0x80) {
        return None;
    }
    match parse_object(line) {
        Some((mut fields, timestamp)) => {
            let event = make_event(&mut fields, timestamp);
            if is_irrelevant(&event) {
                return Some(RouterLineResult::Irrelevant);
            }
            Some(if timestamp.is_some() && is_reportable(&event) {
                RouterLineResult::Event(event)
            } else {
                RouterLineResult::MalformedEvent(event)
            })
        }
        // Structural failures fall back: only Swift's `JSONSerialization` re-check can separate an
        // unrelated object from a damaged event row.
        None => None,
    }
}

// ---------------------------------------------------------------------------
// C ABI (declared in Sources/CQuotabarCore/include/quotabar_core.h)
// ---------------------------------------------------------------------------

#[repr(C)]
pub struct QbRouterLine {
    pub timestamp: f64,
    pub status: i64,
    pub input_tokens: i64,
    pub cached_input_tokens: i64,
    pub output_tokens: i64,
    pub reasoning_tokens: i64,
    /// `NIL_I64` when `totalTokens` is nil.
    pub total_tokens: i64,
    pub model_offset: u32,
    pub model_length: u32,
    pub provider_offset: u32,
    pub provider_length: u32,
    pub account_id_offset: u32,
    pub account_id_length: u32,
    pub account_fingerprint_offset: u32,
    pub account_fingerprint_length: u32,
    pub service_tier_offset: u32,
    pub service_tier_length: u32,
    pub kind: u8,
    pub has_valid_status_field: u8,
    pub has_valid_timestamp_field: u8,
    pub has_valid_model_field: u8,
    pub has_unique_status_field: u8,
    pub has_unique_provider_field: u8,
    pub has_unique_model_field: u8,
    pub has_unique_account_identity_fields: u8,
    pub has_valid_numeric_count_fields: u8,
    pub has_unique_recognized_fields: u8,
    pub has_input_tokens_field: u8,
    pub has_output_tokens_field: u8,
    pub has_valid_cached_input_tokens_field: u8,
    pub has_valid_total_tokens_field: u8,
    pub has_valid_estimated_input_tokens_field: u8,
    pub has_estimated_input_tokens: u8,
    pub has_valid_account_identity_fields: u8,
    pub has_valid_provider_field: u8,
    pub has_valid_service_tier_field: u8,
    pub token_count_saturated: u8,
    pub reserved: [u8; 4],
}

pub struct RouterLineBox {
    kind: u8,
    entry: Option<QbRouterLine>,
    strings: Vec<u8>,
}

fn flag(value: bool) -> u8 {
    u8::from(value)
}

fn intern_optional(blob: &mut Vec<u8>, value: &Option<String>) -> (u32, u32) {
    match value.as_deref().and_then(|s| crate::intern(blob, s)) {
        Some((offset, length)) => (offset, length),
        None => (crate::NIL_STRING, 0),
    }
}

fn build_box(result: RouterLineResult) -> *mut RouterLineBox {
    let (kind, event) = match result {
        RouterLineResult::Event(event) => (QB_ROUTER_KIND_EVENT, Some(event)),
        RouterLineResult::MalformedEvent(event) => (QB_ROUTER_KIND_MALFORMED_EVENT, Some(event)),
        RouterLineResult::Irrelevant => (QB_ROUTER_KIND_IRRELEVANT, None),
    };
    let mut strings: Vec<u8> = Vec::new();
    let entry = event.map(|event| {
        let (model_offset, model_length) = crate::intern(&mut strings, &event.model)
            .unwrap_or((crate::NIL_STRING, 0));
        let (provider_offset, provider_length) = crate::intern(&mut strings, &event.provider)
            .unwrap_or((crate::NIL_STRING, 0));
        let (account_id_offset, account_id_length) =
            intern_optional(&mut strings, &event.account_id);
        let (account_fingerprint_offset, account_fingerprint_length) =
            intern_optional(&mut strings, &event.account_fingerprint);
        let (service_tier_offset, service_tier_length) =
            intern_optional(&mut strings, &event.service_tier);
        let flags = event.flags;
        QbRouterLine {
            timestamp: event.timestamp,
            status: event.status,
            input_tokens: event.input_tokens,
            cached_input_tokens: event.cached_input_tokens,
            output_tokens: event.output_tokens,
            reasoning_tokens: event.reasoning_tokens,
            total_tokens: event.total_tokens.unwrap_or(NIL_I64),
            model_offset,
            model_length,
            provider_offset,
            provider_length,
            account_id_offset,
            account_id_length,
            account_fingerprint_offset,
            account_fingerprint_length,
            service_tier_offset,
            service_tier_length,
            kind,
            has_valid_status_field: flag(flags.has_valid_status_field),
            has_valid_timestamp_field: flag(flags.has_valid_timestamp_field),
            has_valid_model_field: flag(flags.has_valid_model_field),
            has_unique_status_field: flag(flags.has_unique_status_field),
            has_unique_provider_field: flag(flags.has_unique_provider_field),
            has_unique_model_field: flag(flags.has_unique_model_field),
            has_unique_account_identity_fields: flag(flags.has_unique_account_identity_fields),
            has_valid_numeric_count_fields: flag(flags.has_valid_numeric_count_fields),
            has_unique_recognized_fields: flag(flags.has_unique_recognized_fields),
            has_input_tokens_field: flag(flags.has_input_tokens_field),
            has_output_tokens_field: flag(flags.has_output_tokens_field),
            has_valid_cached_input_tokens_field: flag(flags.has_valid_cached_input_tokens_field),
            has_valid_total_tokens_field: flag(flags.has_valid_total_tokens_field),
            has_valid_estimated_input_tokens_field: flag(
                flags.has_valid_estimated_input_tokens_field,
            ),
            has_estimated_input_tokens: flag(flags.has_estimated_input_tokens),
            has_valid_account_identity_fields: flag(flags.has_valid_account_identity_fields),
            has_valid_provider_field: flag(flags.has_valid_provider_field),
            has_valid_service_tier_field: flag(flags.has_valid_service_tier_field),
            token_count_saturated: flag(flags.token_count_saturated),
            reserved: [0; 4],
        }
    });
    Box::into_raw(Box::new(RouterLineBox {
        kind,
        entry,
        strings,
    }))
}

/// Parse one CodexRouter ledger line. Returns NULL when the Swift parser must decide.
#[no_mangle]
pub extern "C" fn qb_router_parse_line(line: *const u8, line_len: usize) -> *mut RouterLineBox {
    if line.is_null() && line_len > 0 {
        return ptr::null_mut();
    }
    let bytes = if line.is_null() {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(line, line_len) }
    };
    match catch_unwind(AssertUnwindSafe(|| parse_router_line(bytes))) {
        Ok(Some(result)) => build_box(result),
        _ => ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn qb_router_line_kind(result: *const RouterLineBox) -> u8 {
    match unsafe { result.as_ref() } {
        Some(result) => result.kind,
        None => QB_ROUTER_KIND_IRRELEVANT,
    }
}

#[no_mangle]
pub extern "C" fn qb_router_line_entry(result: *const RouterLineBox) -> *const QbRouterLine {
    match unsafe { result.as_ref() } {
        Some(boxed) => match boxed.entry.as_ref() {
            Some(entry) => entry as *const QbRouterLine,
            None => ptr::null(),
        },
        None => ptr::null(),
    }
}

#[no_mangle]
pub extern "C" fn qb_router_line_strings(
    result: *const RouterLineBox,
    length: *mut u32,
) -> *const u8 {
    match unsafe { result.as_ref() } {
        Some(boxed) => {
            if !length.is_null() {
                unsafe { *length = boxed.strings.len() as u32 };
            }
            boxed.strings.as_ptr()
        }
        None => {
            if !length.is_null() {
                unsafe { *length = 0 };
            }
            ptr::null()
        }
    }
}

#[no_mangle]
pub extern "C" fn qb_router_line_destroy(result: *mut RouterLineBox) {
    if result.is_null() {
        return;
    }
    unsafe {
        drop(Box::from_raw(result));
    }
}
