//! Antigravity generation-blob decoder — a line-for-line port of `AntigravityProtoDecoder` in
//! `Sources/QuotaBar/Providers/Antigravity/AntigravityProtoDecoder.swift`, plus the hex decode
//! in `AntigravityDbUsageScanner.bytes(fromHex:)`.
//!
//! Generation rows arrive from SQLite as `hex(gen_metadata.data)`; the accounting fields sit in
//! an undocumented protobuf envelope (wrapped in field 1: model 19, token usage 4, embedded
//! timestamp 9). Newer databases move the wall-clock time into `steps.metadata` rows correlated
//! by explicit UUID/bot identifiers. Everything the Swift decoder reads — varints, wire types,
//! length-delimited fields, nested messages, the token-count ceiling — is mirrored exactly,
//! including every reject path.
//!
//! Fallback contract: a NULL FFI result means the caller must re-run the Swift reference
//! implementation. The decoder declines only where it cannot provably produce the same answer:
//!
//!   * generation/step hex containing a non-ASCII byte — `bytes(fromHex:)` windows the string
//!     by `Character`, not by byte, and can trap outright on crafted input, so byte-level
//!     emulation is not the same program;
//!   * identifier strings whose canonical equivalence cannot be decided without normalization —
//!     `identifiersAreCompatible` is Swift `String ==` (canonically-equal non-ASCII sequences
//!     compare equal there but differ byte-wise here), and a `StepIdentity` hashes into a Swift
//!     `Dictionary` with the same canonical semantics.
//!
//! ASCII input is handled exactly: `UInt8(_, radix: 16)` accepts a leading `+` (and `-0`), so
//! `decode_hex` reproduces those windows rather than declining them.

use crate::{intern, NIL_STRING};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;

/// `qb_antigravity_generation_status`: the row decoded into a full `QbAntigravityGenerationEvent`.
pub const QB_ANTIGRAVITY_EVENT: u32 = 0;
/// Mirrors `GenerationEventDecodeResult.ignored` — nothing to account.
pub const QB_ANTIGRAVITY_IGNORED: u32 = 1;
/// Mirrors `GenerationEventDecodeResult.undatedUsage` — usage exists but no timestamp survived.
pub const QB_ANTIGRAVITY_UNDATED_USAGE: u32 = 2;
/// Mirrors `GenerationEventDecodeResult.invalidTokenCount` — payload timestamp in
/// `qb_antigravity_generation_timestamp` when `qb_antigravity_generation_has_timestamp` is set.
pub const QB_ANTIGRAVITY_INVALID_TOKEN_COUNT: u32 = 3;
/// Mirrors `GenerationEventDecodeResult.malformedUsage` — same timestamp payload convention.
pub const QB_ANTIGRAVITY_MALFORMED_USAGE: u32 = 4;
/// The generation hex provably decodes the way Swift's `bytes(fromHex:)` returns nil — the row
/// takes the caller's unreadable/oversized path, never the decoder.
pub const QB_ANTIGRAVITY_UNREADABLE_HEX: u32 = 5;
/// Returned by `qb_antigravity_generation_status` for a NULL result — fallback, never stored.
pub const QB_ANTIGRAVITY_FALLBACK: u32 = 6;

/// `qb_antigravity_identity_status`: a `QbAntigravityStepIdentity` is present.
pub const QB_ANTIGRAVITY_IDENTITY_PRESENT: u32 = 0;
/// The Swift extraction returns nil (no usable identity / timestamp pair).
pub const QB_ANTIGRAVITY_IDENTITY_ABSENT: u32 = 1;

#[repr(C)]
pub struct QbAntigravityGenerationEvent {
    /// Whole seconds since the Unix epoch.
    pub timestamp_seconds: i64,
    /// Billable input — system-prompt + input counts, as in the Swift event.
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    /// Offsets into the strings blob; always valid — Swift substitutes its
    /// "Unknown Antigravity Model" placeholder before emitting the event.
    pub model_offset: u32,
    pub model_length: u32,
    pub reserved: [u8; 8],
}

#[repr(C)]
pub struct QbAntigravityStepIdentity {
    /// Step-metadata wall-clock seconds; valid only when `has_timestamp != 0`
    /// (`qb_antigravity_step_metadata_identity` surface).
    pub timestamp_seconds: i64,
    /// Offsets into the strings blob; `UINT32_MAX` = nil.
    pub uuid_offset: u32,
    pub uuid_length: u32,
    pub bot_id_offset: u32,
    pub bot_id_length: u32,
    pub has_timestamp: u8,
    pub reserved: [u8; 7],
}

pub struct AntigravityGenerationResult {
    status: u32,
    has_timestamp: u8,
    timestamp_seconds: i64,
    event: Option<QbAntigravityGenerationEvent>,
    strings: Vec<u8>,
}

pub struct AntigravityIdentityResult {
    status: u32,
    identity: Option<QbAntigravityStepIdentity>,
    strings: Vec<u8>,
}

// ---------------------------------------------------------------------------
// Hex decode (mirror of AntigravityDbUsageScanner.bytes(fromHex:))
// ---------------------------------------------------------------------------

enum HexDecode {
    Decoded(Vec<u8>),
    /// `bytes(fromHex:)` provably returns nil: odd UTF-8 length or a two-character window
    /// `UInt8(_, radix: 16)` cannot parse.
    Invalid,
    /// Non-ASCII input — Swift windows by `Character`, which byte-level emulation cannot
    /// reproduce (it can even trap). The caller re-runs the Swift decode.
    Fallback,
}

fn hex_digit(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

/// Mirror of `bytes(fromHex:)`: the length guard is on the UTF-8 byte count, then each
/// two-character window is parsed by `UInt8(_, radix: 16)` — which, besides hex digits,
/// accepts a leading `+` and the literal `-0` for unsigned targets.
fn decode_hex(input: &[u8]) -> HexDecode {
    if input.len() % 2 == 1 {
        return HexDecode::Invalid;
    }
    if !input.is_ascii() {
        return HexDecode::Fallback;
    }
    let mut out = Vec::with_capacity(input.len() / 2);
    for pair in input.chunks_exact(2) {
        let byte = match pair[0] {
            // "+h" parses as h for every hex digit.
            b'+' => hex_digit(pair[1]),
            // "-h" parses only as the literal 0 for unsigned targets.
            b'-' => (pair[1] == b'0').then_some(0),
            first => hex_digit(first).and_then(|hi| hex_digit(pair[1]).map(|lo| hi << 4 | lo)),
        };
        match byte {
            Some(b) => out.push(b),
            None => return HexDecode::Invalid,
        }
    }
    HexDecode::Decoded(out)
}

// ---------------------------------------------------------------------------
// Protobuf wire walk (mirror of AntigravityProtoDecoder)
// ---------------------------------------------------------------------------

enum WireValue<'a> {
    Varint(u64),
    Bytes(&'a [u8]),
    Fixed,
}

fn decode_varint(bytes: &[u8], offset: usize) -> Option<(u64, usize)> {
    if offset >= bytes.len() {
        return None;
    }
    let mut value: u64 = 0;
    for byte_index in 0..10usize {
        let position = offset + byte_index;
        if position >= bytes.len() {
            return None;
        }
        let byte = bytes[position];
        let payload = u64::from(byte & 0x7f);
        if byte_index == 9 && payload > 1 {
            return None;
        }
        value |= payload << (byte_index * 7);
        if byte & 0x80 == 0 {
            return Some((value, position + 1));
        }
    }
    None
}

/// Return the first occurrence of `requested`, validating the whole message — any malformed
/// field is nil, matching `field(_:in:)`.
fn field<'a>(requested: u32, bytes: &'a [u8]) -> Option<WireValue<'a>> {
    let mut offset = 0usize;
    while offset < bytes.len() {
        let (tag, tag_next) = decode_varint(bytes, offset)?;
        let number = u32::try_from(tag >> 3).ok().filter(|&n| n != 0)?;
        match tag & 0x7 {
            0 => {
                let (value, next) = decode_varint(bytes, tag_next)?;
                if number == requested {
                    return Some(WireValue::Varint(value));
                }
                offset = next;
            }
            2 => {
                let (length, length_next) = decode_varint(bytes, tag_next)?;
                if length > (bytes.len() - length_next) as u64 {
                    return None;
                }
                let count = usize::try_from(length).ok()?;
                let end = length_next + count;
                if number == requested {
                    return Some(WireValue::Bytes(&bytes[length_next..end]));
                }
                offset = end;
            }
            1 | 5 => {
                let width = if tag & 0x7 == 1 { 8 } else { 4 };
                if bytes.len() - tag_next < width {
                    return None;
                }
                offset = tag_next + width;
            }
            _ => return None,
        }
    }
    None
}

#[allow(dead_code)]
fn bytes_field<'a>(number: u32, bytes: &'a [u8]) -> Option<&'a [u8]> {
    match field(number, bytes) {
        Some(WireValue::Bytes(value)) => Some(value),
        _ => None,
    }
}

#[allow(dead_code)]
fn varint_field(number: u32, bytes: &[u8]) -> Option<u64> {
    match field(number, bytes) {
        Some(WireValue::Varint(value)) => Some(value),
        _ => None,
    }
}

/// Return every occurrence of a field while validating the complete containing message —
/// mirror of `matchingFields(_:in:)`; duplicates are never silently ignored by callers.
fn matching_fields<'a>(requested: u32, bytes: &'a [u8]) -> Option<Vec<WireValue<'a>>> {
    let mut values: Vec<WireValue<'a>> = Vec::new();
    let mut offset = 0usize;
    while offset < bytes.len() {
        let (tag, tag_next) = decode_varint(bytes, offset)?;
        let number = u32::try_from(tag >> 3).ok().filter(|&n| n != 0)?;
        match tag & 0x7 {
            0 => {
                let (value, next) = decode_varint(bytes, tag_next)?;
                if number == requested {
                    values.push(WireValue::Varint(value));
                }
                offset = next;
            }
            2 => {
                let (length, length_next) = decode_varint(bytes, tag_next)?;
                if length > (bytes.len() - length_next) as u64 {
                    return None;
                }
                let count = usize::try_from(length).ok()?;
                let end = length_next + count;
                if number == requested {
                    values.push(WireValue::Bytes(&bytes[length_next..end]));
                }
                offset = end;
            }
            1 | 5 => {
                let width = if tag & 0x7 == 1 { 8 } else { 4 };
                if bytes.len() - tag_next < width {
                    return None;
                }
                if number == requested {
                    values.push(WireValue::Fixed);
                }
                offset = tag_next + width;
            }
            _ => return None,
        }
    }
    Some(values)
}

/// `timestampSeconds(in:)` — a google.protobuf.Timestamp message: field 1 as a single positive
/// varint fitting Int64.
fn timestamp_seconds(message: &[u8]) -> Option<i64> {
    let fields = matching_fields(1, message)?;
    if fields.len() != 1 {
        return None;
    }
    let seconds = match fields[0] {
        WireValue::Varint(v) => v,
        _ => return None,
    };
    let seconds = i64::try_from(seconds).ok()?;
    (seconds > 0).then_some(seconds)
}

/// `timestamp(fromStepMetadata:)` — steps.metadata field 1 holds the Timestamp message.
fn timestamp_from_step_metadata(step_metadata: &[u8]) -> Option<i64> {
    let fields = matching_fields(1, step_metadata)?;
    if fields.len() != 1 {
        return None;
    }
    let timestamp = match fields[0] {
        WireValue::Bytes(b) => b,
        _ => return None,
    };
    timestamp_seconds(timestamp)
}

// ---------------------------------------------------------------------------
// Identifier extraction and correlation
// ---------------------------------------------------------------------------

enum IdentifierEvidence<'a> {
    Absent,
    Value(&'a str),
    Invalid,
}

fn identifier_evidence<'a>(number: u32, bytes: &'a [u8]) -> IdentifierEvidence<'a> {
    let Some(fields) = matching_fields(number, bytes) else {
        return IdentifierEvidence::Invalid;
    };
    if fields.is_empty() {
        return IdentifierEvidence::Absent;
    }
    if fields.len() != 1 {
        return IdentifierEvidence::Invalid;
    }
    match fields[0] {
        // `String(bytes:encoding:.utf8)` rejects invalid UTF-8; `trim()` covers the same
        // Unicode White_Space set as `.whitespacesAndNewlines`.
        WireValue::Bytes(value) => match std::str::from_utf8(value) {
            Ok(s) if !s.trim().is_empty() => IdentifierEvidence::Value(s),
            _ => IdentifierEvidence::Invalid,
        },
        _ => IdentifierEvidence::Invalid,
    }
}

fn nested_identifier_evidence<'a>(
    container_field: u32,
    identifier_field: u32,
    bytes: &'a [u8],
) -> IdentifierEvidence<'a> {
    let Some(fields) = matching_fields(container_field, bytes) else {
        return IdentifierEvidence::Invalid;
    };
    if fields.is_empty() {
        return IdentifierEvidence::Absent;
    }
    if fields.len() != 1 {
        return IdentifierEvidence::Invalid;
    }
    match fields[0] {
        WireValue::Bytes(nested) => identifier_evidence(identifier_field, nested),
        _ => IdentifierEvidence::Invalid,
    }
}

enum Compatibility {
    Compatible,
    Incompatible,
    /// Byte-different values containing non-ASCII: Swift `==` is canonical equivalence, which
    /// cannot be decided without normalization. The caller falls back to the Swift decoder.
    Unsure,
}

fn identifiers_are_compatible(
    generation: &IdentifierEvidence,
    step: &IdentifierEvidence,
) -> Compatibility {
    match (generation, step) {
        (IdentifierEvidence::Absent, IdentifierEvidence::Absent) => Compatibility::Compatible,
        (IdentifierEvidence::Value(g), IdentifierEvidence::Value(s)) => {
            if g == s {
                Compatibility::Compatible
            } else if g.is_ascii() && s.is_ascii() {
                // ASCII scalars have no canonical decompositions: byte-different means
                // canonically different.
                Compatibility::Incompatible
            } else {
                Compatibility::Unsure
            }
        }
        _ => Compatibility::Incompatible,
    }
}

struct StepIdentity<'a> {
    uuid: Option<&'a str>,
    bot_id: Option<&'a str>,
}

fn step_identity<'a>(
    uuid: IdentifierEvidence<'a>,
    bot: IdentifierEvidence<'a>,
) -> Option<StepIdentity<'a>> {
    fn value<'a>(evidence: IdentifierEvidence<'a>) -> Option<&'a str> {
        match evidence {
            IdentifierEvidence::Value(v) => Some(v),
            _ => None,
        }
    }
    if matches!(uuid, IdentifierEvidence::Invalid) || matches!(bot, IdentifierEvidence::Invalid) {
        return None;
    }
    let identity = StepIdentity {
        uuid: value(uuid),
        bot_id: value(bot),
    };
    if identity.uuid.is_none() && identity.bot_id.is_none() {
        return None;
    }
    Some(identity)
}

/// `generationStepIdentity(from:)` — generation field 4 is the step UUID; the wrapped usage
/// message's field 7 is the bot identifier.
fn generation_step_identity(generation: &[u8]) -> Option<StepIdentity<'_>> {
    let wrappers = matching_fields(1, generation)?;
    if wrappers.len() != 1 {
        return None;
    }
    let wrapped = match wrappers[0] {
        WireValue::Bytes(b) => b,
        _ => return None,
    };
    let usages = matching_fields(4, wrapped)?;
    if usages.len() != 1 {
        return None;
    }
    let usage = match usages[0] {
        WireValue::Bytes(b) => b,
        _ => return None,
    };
    step_identity(
        identifier_evidence(4, generation),
        identifier_evidence(7, usage),
    )
}

/// `stepIdentityAndTimestamp(from:)` — step metadata field 12 is the UUID, nested field 9.7
/// the bot identifier, field 1 the Timestamp message.
fn step_identity_and_timestamp(metadata: &[u8]) -> Option<(StepIdentity<'_>, i64)> {
    let identity = step_identity(
        identifier_evidence(12, metadata),
        nested_identifier_evidence(9, 7, metadata),
    )?;
    let timestamp = timestamp_from_step_metadata(metadata)?;
    Some((identity, timestamp))
}

enum TimestampLookup {
    Found(i64),
    Miss,
    /// Identifier equivalence could not be decided — the caller falls back to Swift.
    Unsure,
}

/// `correlatedStepTimestamp(generation:wrapped:stepMetadata:)` — same-index step rows are
/// trusted only when the explicit identifiers agree (or are absent on both sides).
fn correlated_step_timestamp(
    generation: &[u8],
    wrapped: &[u8],
    step_metadata: &[u8],
) -> TimestampLookup {
    match identifiers_are_compatible(
        &identifier_evidence(4, generation),
        &identifier_evidence(12, step_metadata),
    ) {
        Compatibility::Compatible => {}
        Compatibility::Incompatible => return TimestampLookup::Miss,
        Compatibility::Unsure => return TimestampLookup::Unsure,
    }
    let Some(usage_fields) = matching_fields(4, wrapped) else {
        return TimestampLookup::Miss;
    };
    if usage_fields.len() != 1 {
        return TimestampLookup::Miss;
    }
    let usage = match usage_fields[0] {
        WireValue::Bytes(b) => b,
        _ => return TimestampLookup::Miss,
    };
    match identifiers_are_compatible(
        &identifier_evidence(7, usage),
        &nested_identifier_evidence(9, 7, step_metadata),
    ) {
        Compatibility::Compatible => {}
        Compatibility::Incompatible => return TimestampLookup::Miss,
        Compatibility::Unsure => return TimestampLookup::Unsure,
    }
    match timestamp_from_step_metadata(step_metadata) {
        Some(ts) => TimestampLookup::Found(ts),
        None => TimestampLookup::Miss,
    }
}

// ---------------------------------------------------------------------------
// Generation event decode
// ---------------------------------------------------------------------------

const MAXIMUM_TOKEN_COUNT: u64 = 1_000_000_000_000_000;
const UNKNOWN_MODEL: &str = "Unknown Antigravity Model";

struct GenerationEvent {
    model: String,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    timestamp_seconds: i64,
}

enum DecodeOutcome {
    Event(GenerationEvent),
    InvalidTokenCount {
        timestamp_seconds: Option<i64>,
    },
    MalformedUsage {
        timestamp_seconds: Option<i64>,
    },
    UndatedUsage,
    Ignored,
    /// Identifier equivalence could not be decided — the caller falls back to Swift.
    Fallback,
}

#[derive(Default)]
struct TokenCounts {
    system_prompt: u64,
    input: u64,
    output: u64,
    cache_read: u64,
}

/// `tokenCounts(in:)` — decode the whole usage message so a counter with the wrong wire type
/// or a malformed trailing field is never mistaken for an absent zero-valued counter.
fn token_counts(bytes: &[u8]) -> Option<TokenCounts> {
    let mut result = TokenCounts::default();
    let mut offset = 0usize;
    while offset < bytes.len() {
        let (tag, tag_next) = decode_varint(bytes, offset)?;
        let number = u32::try_from(tag >> 3).ok().filter(|&n| n != 0)?;
        let wire_type = tag & 0x7;
        match wire_type {
            0 => {
                let (value, next) = decode_varint(bytes, tag_next)?;
                match number {
                    1 => result.system_prompt = value,
                    2 => result.input = value,
                    3 => result.output = value,
                    5 => result.cache_read = value,
                    _ => {}
                }
                offset = next;
            }
            2 => {
                let (length, length_next) = decode_varint(bytes, tag_next)?;
                if length > (bytes.len() - length_next) as u64 {
                    return None;
                }
                let count = usize::try_from(length).ok()?;
                match number {
                    1 | 2 | 3 | 5 => return None,
                    _ => offset = length_next + count,
                }
            }
            1 | 5 => {
                let width = if wire_type == 1 { 8 } else { 4 };
                if bytes.len() - tag_next < width {
                    return None;
                }
                match number {
                    1 | 2 | 3 | 5 => return None,
                    _ => offset = tag_next + width,
                }
            }
            _ => return None,
        }
    }
    Some(result)
}

/// `decodeGenerationEvent(from:stepMetadata:matchedStepTimestamp:)` — the accounting fold's
/// five-way verdict plus the timestamp payload each reject case carries.
fn decode_generation_event(
    blob: &[u8],
    step_metadata: Option<&[u8]>,
    matched_step_timestamp: Option<i64>,
) -> DecodeOutcome {
    let Some(wrappers) = matching_fields(1, blob) else {
        return DecodeOutcome::MalformedUsage {
            timestamp_seconds: None,
        };
    };
    if wrappers.is_empty() {
        return DecodeOutcome::Ignored;
    }
    if wrappers.len() != 1 {
        return DecodeOutcome::MalformedUsage {
            timestamp_seconds: None,
        };
    }
    let wrapped = match wrappers[0] {
        WireValue::Bytes(b) => b,
        _ => {
            return DecodeOutcome::MalformedUsage {
                timestamp_seconds: None,
            }
        }
    };

    let fallback_timestamp = match matched_step_timestamp {
        Some(ts) => Some(ts),
        None => match step_metadata {
            Some(metadata) => match correlated_step_timestamp(blob, wrapped, metadata) {
                TimestampLookup::Found(ts) => Some(ts),
                TimestampLookup::Miss => None,
                TimestampLookup::Unsure => return DecodeOutcome::Fallback,
            },
            None => None,
        },
    };

    // An absent or ambiguous model stays visibly unpriced; it never borrows another rate.
    let Some(model_fields) = matching_fields(19, wrapped) else {
        return DecodeOutcome::MalformedUsage {
            timestamp_seconds: fallback_timestamp,
        };
    };
    let model_bytes: Option<&[u8]> = if model_fields.len() == 1 {
        match model_fields[0] {
            WireValue::Bytes(b) => Some(b),
            _ => None,
        }
    } else {
        None
    };
    let model = model_bytes
        .and_then(|bytes| std::str::from_utf8(bytes).ok())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or(UNKNOWN_MODEL);

    let Some(timestamp_fields) = matching_fields(9, wrapped) else {
        return DecodeOutcome::MalformedUsage {
            timestamp_seconds: fallback_timestamp,
        };
    };
    if timestamp_fields.len() > 1 {
        return DecodeOutcome::MalformedUsage {
            timestamp_seconds: fallback_timestamp,
        };
    }
    let embedded_timestamp: Option<i64> = match timestamp_fields.first() {
        Some(WireValue::Bytes(timestamp_bytes)) => {
            let Some(timestamp_messages) = matching_fields(4, timestamp_bytes) else {
                return DecodeOutcome::MalformedUsage {
                    timestamp_seconds: fallback_timestamp,
                };
            };
            if timestamp_messages.len() == 1 {
                match timestamp_messages[0] {
                    WireValue::Bytes(wall_clock) => timestamp_seconds(wall_clock),
                    _ => None,
                }
            } else {
                None
            }
        }
        Some(_) => {
            return DecodeOutcome::MalformedUsage {
                timestamp_seconds: fallback_timestamp,
            }
        }
        None => None,
    };
    let timestamp = embedded_timestamp.or(fallback_timestamp);

    let Some(usage_fields) = matching_fields(4, wrapped) else {
        return DecodeOutcome::MalformedUsage {
            timestamp_seconds: timestamp,
        };
    };
    if usage_fields.is_empty() {
        return DecodeOutcome::Ignored;
    }
    if usage_fields.len() != 1 {
        return DecodeOutcome::MalformedUsage {
            timestamp_seconds: timestamp,
        };
    }
    let usage = match usage_fields[0] {
        WireValue::Bytes(b) => b,
        _ => {
            return DecodeOutcome::MalformedUsage {
                timestamp_seconds: timestamp,
            }
        }
    };
    let Some(counts) = token_counts(usage) else {
        return DecodeOutcome::MalformedUsage {
            timestamp_seconds: timestamp,
        };
    };

    let ceiling = MAXIMUM_TOKEN_COUNT;
    if counts.system_prompt > ceiling
        || counts.input > ceiling
        || counts.output > ceiling
        || counts.cache_read > ceiling
    {
        return DecodeOutcome::InvalidTokenCount {
            timestamp_seconds: timestamp,
        };
    }

    let Some(billable_input) = counts.system_prompt.checked_add(counts.input) else {
        return DecodeOutcome::InvalidTokenCount {
            timestamp_seconds: timestamp,
        };
    };
    let Some(input_and_cache) = billable_input.checked_add(counts.cache_read) else {
        return DecodeOutcome::InvalidTokenCount {
            timestamp_seconds: timestamp,
        };
    };
    let Some(total) = input_and_cache.checked_add(counts.output) else {
        return DecodeOutcome::InvalidTokenCount {
            timestamp_seconds: timestamp,
        };
    };
    if billable_input > MAXIMUM_TOKEN_COUNT || total > MAXIMUM_TOKEN_COUNT {
        return DecodeOutcome::InvalidTokenCount {
            timestamp_seconds: timestamp,
        };
    }
    if total == 0 {
        return DecodeOutcome::Ignored;
    }

    let Some(timestamp_seconds) = timestamp else {
        return DecodeOutcome::UndatedUsage;
    };

    DecodeOutcome::Event(GenerationEvent {
        model: model.to_string(),
        input_tokens: billable_input,
        output_tokens: counts.output,
        cache_read_tokens: counts.cache_read,
        timestamp_seconds,
    })
}

// ---------------------------------------------------------------------------
// FFI packing
// ---------------------------------------------------------------------------

enum GenerationInput<'a> {
    Hex(&'a [u8]),
    Bytes(&'a [u8]),
}

fn pack_decode_outcome(outcome: DecodeOutcome) -> *mut AntigravityGenerationResult {
    let mut strings: Vec<u8> = Vec::new();
    let (status, has_timestamp, timestamp_seconds, event) = match outcome {
        DecodeOutcome::Event(event) => {
            let (model_offset, model_length) = match intern(&mut strings, &event.model) {
                Some(v) => v,
                None => return ptr::null_mut(),
            };
            (
                QB_ANTIGRAVITY_EVENT,
                0u8,
                0i64,
                Some(QbAntigravityGenerationEvent {
                    timestamp_seconds: event.timestamp_seconds,
                    input_tokens: event.input_tokens,
                    output_tokens: event.output_tokens,
                    cache_read_tokens: event.cache_read_tokens,
                    model_offset,
                    model_length,
                    reserved: [0; 8],
                }),
            )
        }
        DecodeOutcome::InvalidTokenCount { timestamp_seconds } => (
            QB_ANTIGRAVITY_INVALID_TOKEN_COUNT,
            u8::from(timestamp_seconds.is_some()),
            timestamp_seconds.unwrap_or(0),
            None,
        ),
        DecodeOutcome::MalformedUsage { timestamp_seconds } => (
            QB_ANTIGRAVITY_MALFORMED_USAGE,
            u8::from(timestamp_seconds.is_some()),
            timestamp_seconds.unwrap_or(0),
            None,
        ),
        DecodeOutcome::UndatedUsage => (QB_ANTIGRAVITY_UNDATED_USAGE, 0, 0, None),
        DecodeOutcome::Ignored => (QB_ANTIGRAVITY_IGNORED, 0, 0, None),
        DecodeOutcome::Fallback => return ptr::null_mut(),
    };
    Box::into_raw(Box::new(AntigravityGenerationResult {
        status,
        has_timestamp,
        timestamp_seconds,
        event,
        strings,
    }))
}

/// `pack_decode_outcome` for a generation that could not even be hex-decoded: the same result
/// Swift produces when `bytes(fromHex:)` returns nil (the caller's oversized path).
fn unreadable_hex_result() -> *mut AntigravityGenerationResult {
    Box::into_raw(Box::new(AntigravityGenerationResult {
        status: QB_ANTIGRAVITY_UNREADABLE_HEX,
        has_timestamp: 0,
        timestamp_seconds: 0,
        event: None,
        strings: Vec::new(),
    }))
}

fn decode_generation_impl(
    generation: GenerationInput<'_>,
    step_hex: Option<&[u8]>,
    matched_step_timestamp: Option<i64>,
) -> *mut AntigravityGenerationResult {
    let owned_generation;
    let blob: &[u8] = match generation {
        GenerationInput::Hex(hex) => match decode_hex(hex) {
            HexDecode::Decoded(b) => {
                owned_generation = b;
                &owned_generation
            }
            HexDecode::Invalid => return unreadable_hex_result(),
            HexDecode::Fallback => return ptr::null_mut(),
        },
        GenerationInput::Bytes(b) => b,
    };
    let owned_step;
    let step_metadata: Option<&[u8]> = match step_hex {
        None => None,
        Some(hex) => match decode_hex(hex) {
            HexDecode::Decoded(b) => {
                owned_step = b;
                Some(&owned_step)
            }
            // `row.stepHex.flatMap(Self.bytes(fromHex:))` — an undecodable step row is nil
            // metadata, not a failed row.
            HexDecode::Invalid => None,
            HexDecode::Fallback => return ptr::null_mut(),
        },
    };
    let outcome = decode_generation_event(blob, step_metadata, matched_step_timestamp);
    pack_decode_outcome(outcome)
}

fn pack_identity(
    identity: Option<StepIdentity<'_>>,
    timestamp_seconds: Option<i64>,
) -> *mut AntigravityIdentityResult {
    let Some(identity) = identity else {
        return Box::into_raw(Box::new(AntigravityIdentityResult {
            status: QB_ANTIGRAVITY_IDENTITY_ABSENT,
            identity: None,
            strings: Vec::new(),
        }));
    };
    // A non-ASCII identifier could compare/hash differently under Swift's canonical String
    // equality (the step index keys on these strings) — the caller re-runs the Swift
    // extraction rather than risk a different answer.
    if identity.uuid.is_some_and(|s| !s.is_ascii())
        || identity.bot_id.is_some_and(|s| !s.is_ascii())
    {
        return ptr::null_mut();
    }
    let mut strings: Vec<u8> = Vec::new();
    let (uuid_offset, uuid_length) = match identity.uuid {
        Some(s) => match intern(&mut strings, s) {
            Some(v) => v,
            None => return ptr::null_mut(),
        },
        None => (NIL_STRING, 0),
    };
    let (bot_id_offset, bot_id_length) = match identity.bot_id {
        Some(s) => match intern(&mut strings, s) {
            Some(v) => v,
            None => return ptr::null_mut(),
        },
        None => (NIL_STRING, 0),
    };
    Box::into_raw(Box::new(AntigravityIdentityResult {
        status: QB_ANTIGRAVITY_IDENTITY_PRESENT,
        identity: Some(QbAntigravityStepIdentity {
            timestamp_seconds: timestamp_seconds.unwrap_or(0),
            uuid_offset,
            uuid_length,
            bot_id_offset,
            bot_id_length,
            has_timestamp: u8::from(timestamp_seconds.is_some()),
            reserved: [0; 7],
        }),
        strings,
    }))
}

fn generation_step_identity_impl(input: GenerationInput<'_>) -> *mut AntigravityIdentityResult {
    let owned;
    let bytes: &[u8] = match input {
        GenerationInput::Hex(hex) => match decode_hex(hex) {
            HexDecode::Decoded(b) => {
                owned = b;
                &owned
            }
            // An undecodable generation carries no identity — the caller's decode reports
            // the row unreadable on its own, so Absent is the definitive answer here.
            HexDecode::Invalid => {
                return pack_identity(None, None);
            }
            HexDecode::Fallback => return ptr::null_mut(),
        },
        GenerationInput::Bytes(b) => b,
    };
    pack_identity(generation_step_identity(bytes), None)
}

fn step_metadata_identity_impl(metadata_hex: &[u8]) -> *mut AntigravityIdentityResult {
    let metadata = match decode_hex(metadata_hex) {
        HexDecode::Decoded(b) => b,
        // `if let hex = row.hex, let bytes = bytes(fromHex: hex)` — undecodable step hex is
        // skipped silently, so Absent is definitive.
        HexDecode::Invalid => {
            return pack_identity(None, None);
        }
        HexDecode::Fallback => return ptr::null_mut(),
    };
    match step_identity_and_timestamp(&metadata) {
        Some((identity, ts)) => pack_identity(Some(identity), Some(ts)),
        None => pack_identity(None, None),
    }
}

// ---------------------------------------------------------------------------
// C ABI
// ---------------------------------------------------------------------------

unsafe fn raw_slice<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if ptr.is_null() {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(ptr, len) }
    }
}

/// Decode one generation row: the `hex(gen_metadata.data)` text plus the same-index
/// `hex(steps.metadata)` text (NULL when absent) and the step-index-matched timestamp.
///
/// Returns a heap-allocated result the caller must pass to
/// [`qb_antigravity_generation_destroy`], or NULL when the input is legal this module cannot
/// answer identically — the caller falls back to the Swift decoder. A
/// `QB_ANTIGRAVITY_UNREADABLE_HEX` status means the generation hex is undecodable, matching
/// `bytes(fromHex:)` returning nil.
#[no_mangle]
pub extern "C" fn qb_antigravity_decode_generation(
    generation_hex: *const u8,
    generation_hex_len: usize,
    step_hex: *const u8,
    step_hex_len: usize,
    matched_step_timestamp: i64,
    has_matched_step_timestamp: u8,
) -> *mut AntigravityGenerationResult {
    if (generation_hex.is_null() && generation_hex_len > 0)
        || (step_hex.is_null() && step_hex_len > 0)
    {
        return ptr::null_mut();
    }
    let generation = unsafe { raw_slice(generation_hex, generation_hex_len) };
    let step = if step_hex.is_null() {
        None
    } else {
        Some(unsafe { raw_slice(step_hex, step_hex_len) })
    };
    let matched = (has_matched_step_timestamp != 0).then_some(matched_step_timestamp);
    match catch_unwind(AssertUnwindSafe(|| {
        decode_generation_impl(GenerationInput::Hex(generation), step, matched)
    })) {
        Ok(p) => p,
        Err(_) => ptr::null_mut(),
    }
}

/// Same contract as [`qb_antigravity_decode_generation`] but the generation arrives as raw
/// protobuf bytes — the bounded accounting projection used for oversized blobs. Step metadata
/// still arrives hex-encoded.
#[no_mangle]
pub extern "C" fn qb_antigravity_decode_generation_blob(
    generation: *const u8,
    generation_len: usize,
    step_hex: *const u8,
    step_hex_len: usize,
    matched_step_timestamp: i64,
    has_matched_step_timestamp: u8,
) -> *mut AntigravityGenerationResult {
    if (generation.is_null() && generation_len > 0) || (step_hex.is_null() && step_hex_len > 0) {
        return ptr::null_mut();
    }
    let generation = unsafe { raw_slice(generation, generation_len) };
    let step = if step_hex.is_null() {
        None
    } else {
        Some(unsafe { raw_slice(step_hex, step_hex_len) })
    };
    let matched = (has_matched_step_timestamp != 0).then_some(matched_step_timestamp);
    match catch_unwind(AssertUnwindSafe(|| {
        decode_generation_impl(GenerationInput::Bytes(generation), step, matched)
    })) {
        Ok(p) => p,
        Err(_) => ptr::null_mut(),
    }
}

/// `qb_antigravity_generation_status`: the `GenerationEventDecodeResult` case, or
/// [`QB_ANTIGRAVITY_FALLBACK`] for NULL (the fallback signal itself).
#[no_mangle]
pub extern "C" fn qb_antigravity_generation_status(
    result: *const AntigravityGenerationResult,
) -> u32 {
    if result.is_null() {
        return QB_ANTIGRAVITY_FALLBACK;
    }
    unsafe { &*result }.status
}

/// Nonzero when `qb_antigravity_generation_timestamp` carries the case's `timestampSeconds`
/// payload (invalid-token-count and malformed-usage cases only).
#[no_mangle]
pub extern "C" fn qb_antigravity_generation_has_timestamp(
    result: *const AntigravityGenerationResult,
) -> u8 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.has_timestamp
}

#[no_mangle]
pub extern "C" fn qb_antigravity_generation_timestamp(
    result: *const AntigravityGenerationResult,
) -> i64 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.timestamp_seconds
}

/// Pointer to the decoded event; NULL unless the status is [`QB_ANTIGRAVITY_EVENT`]. Valid
/// until [`qb_antigravity_generation_destroy`].
#[no_mangle]
pub extern "C" fn qb_antigravity_generation_event(
    result: *const AntigravityGenerationResult,
) -> *const QbAntigravityGenerationEvent {
    if result.is_null() {
        return ptr::null();
    }
    match &unsafe { &*result }.event {
        Some(event) => event as *const QbAntigravityGenerationEvent,
        None => ptr::null(),
    }
}

/// Pointer to the UTF-8 string blob the model offsets index into, plus its byte length.
#[no_mangle]
pub extern "C" fn qb_antigravity_generation_strings(
    result: *const AntigravityGenerationResult,
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
/// `result` must be a pointer returned by a `qb_antigravity_decode_generation*` call,
/// destroyed at most once.
#[no_mangle]
pub unsafe extern "C" fn qb_antigravity_generation_destroy(
    result: *mut AntigravityGenerationResult,
) {
    if result.is_null() {
        return;
    }
    unsafe { drop(Box::from_raw(result)) };
}

/// Extract the generation's step identity (uuid + bot identifier) — the lookup key the step
/// timestamp index uses. NULL = fall back to the Swift extraction.
#[no_mangle]
pub extern "C" fn qb_antigravity_generation_step_identity(
    generation_hex: *const u8,
    generation_hex_len: usize,
) -> *mut AntigravityIdentityResult {
    if generation_hex.is_null() && generation_hex_len > 0 {
        return ptr::null_mut();
    }
    let generation = unsafe { raw_slice(generation_hex, generation_hex_len) };
    match catch_unwind(AssertUnwindSafe(|| {
        generation_step_identity_impl(GenerationInput::Hex(generation))
    })) {
        Ok(p) => p,
        Err(_) => ptr::null_mut(),
    }
}

/// Raw-bytes variant of [`qb_antigravity_generation_step_identity`] for the projection path.
#[no_mangle]
pub extern "C" fn qb_antigravity_generation_step_identity_blob(
    generation: *const u8,
    generation_len: usize,
) -> *mut AntigravityIdentityResult {
    if generation.is_null() && generation_len > 0 {
        return ptr::null_mut();
    }
    let generation = unsafe { raw_slice(generation, generation_len) };
    match catch_unwind(AssertUnwindSafe(|| {
        generation_step_identity_impl(GenerationInput::Bytes(generation))
    })) {
        Ok(p) => p,
        Err(_) => ptr::null_mut(),
    }
}

/// Extract a `steps.metadata` row's identity plus wall-clock timestamp — the pair
/// `stepIdentityAndTimestamp(from:)` produces for the step timestamp index. NULL = fall back
/// to the Swift extraction.
#[no_mangle]
pub extern "C" fn qb_antigravity_step_metadata_identity(
    metadata_hex: *const u8,
    metadata_hex_len: usize,
) -> *mut AntigravityIdentityResult {
    if metadata_hex.is_null() && metadata_hex_len > 0 {
        return ptr::null_mut();
    }
    let metadata = unsafe { raw_slice(metadata_hex, metadata_hex_len) };
    match catch_unwind(AssertUnwindSafe(|| step_metadata_identity_impl(metadata))) {
        Ok(p) => p,
        Err(_) => ptr::null_mut(),
    }
}

/// `QB_ANTIGRAVITY_IDENTITY_PRESENT` when `qb_antigravity_identity` is non-NULL.
#[no_mangle]
pub extern "C" fn qb_antigravity_identity_status(result: *const AntigravityIdentityResult) -> u32 {
    if result.is_null() {
        return QB_ANTIGRAVITY_IDENTITY_ABSENT;
    }
    unsafe { &*result }.status
}

/// Pointer to the identity; NULL when the status is not `QB_ANTIGRAVITY_IDENTITY_PRESENT`.
/// Valid until [`qb_antigravity_identity_destroy`].
#[no_mangle]
pub extern "C" fn qb_antigravity_identity(
    result: *const AntigravityIdentityResult,
) -> *const QbAntigravityStepIdentity {
    if result.is_null() {
        return ptr::null();
    }
    match &unsafe { &*result }.identity {
        Some(identity) => identity as *const QbAntigravityStepIdentity,
        None => ptr::null(),
    }
}

/// Pointer to the UTF-8 string blob the identity offsets index into, plus its byte length.
#[no_mangle]
pub extern "C" fn qb_antigravity_identity_strings(
    result: *const AntigravityIdentityResult,
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
/// `result` must be a pointer returned by a `qb_antigravity_*identity` call, destroyed at
/// most once.
#[no_mangle]
pub unsafe extern "C" fn qb_antigravity_identity_destroy(result: *mut AntigravityIdentityResult) {
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

    fn varint(mut value: u64) -> Vec<u8> {
        let mut encoded = Vec::new();
        loop {
            let mut byte = (value & 0x7f) as u8;
            value >>= 7;
            if value != 0 {
                byte |= 0x80;
            }
            encoded.push(byte);
            if value == 0 {
                break;
            }
        }
        encoded
    }

    fn varint_field_bytes(number: u32, value: u64) -> Vec<u8> {
        let mut out = varint(u64::from(number) << 3);
        out.extend(varint(value));
        out
    }

    fn bytes_field_bytes(number: u32, bytes: &[u8]) -> Vec<u8> {
        let mut out = varint(u64::from(number) << 3 | 2);
        out.extend(varint(bytes.len() as u64));
        out.extend_from_slice(bytes);
        out
    }

    fn fixed64_field_bytes(number: u32, value: u64) -> Vec<u8> {
        let mut out = varint(u64::from(number) << 3 | 1);
        out.extend_from_slice(&value.to_le_bytes());
        out
    }

    fn generation_blob(
        model: Option<&str>,
        input: u64,
        output: u64,
        cache_read: u64,
        system_prompt: u64,
        timestamp: Option<u64>,
        step_uuid: Option<&str>,
        bot_id: Option<&str>,
    ) -> Vec<u8> {
        let mut usage = varint_field_bytes(1, system_prompt);
        usage.extend(varint_field_bytes(2, input));
        usage.extend(varint_field_bytes(3, output));
        usage.extend(varint_field_bytes(5, cache_read));
        if let Some(bot) = bot_id {
            usage.extend(bytes_field_bytes(7, bot.as_bytes()));
        }

        let mut event = Vec::new();
        if let Some(model) = model {
            event.extend(bytes_field_bytes(19, model.as_bytes()));
        }
        event.extend(bytes_field_bytes(4, &usage));
        if let Some(ts) = timestamp {
            let wall_clock = varint_field_bytes(1, ts);
            event.extend(bytes_field_bytes(9, &bytes_field_bytes(4, &wall_clock)));
        }
        let mut generation = bytes_field_bytes(1, &event);
        if let Some(uuid) = step_uuid {
            generation.extend(bytes_field_bytes(4, uuid.as_bytes()));
        }
        generation
    }

    fn step_metadata_bytes(
        timestamp: u64,
        step_uuid: Option<&str>,
        bot_id: Option<&str>,
    ) -> Vec<u8> {
        let mut metadata = bytes_field_bytes(1, &varint_field_bytes(1, timestamp));
        if let Some(bot) = bot_id {
            metadata.extend(bytes_field_bytes(9, &bytes_field_bytes(7, bot.as_bytes())));
        }
        if let Some(uuid) = step_uuid {
            metadata.extend(bytes_field_bytes(12, uuid.as_bytes()));
        }
        metadata
    }

    fn hex_encode(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    // -- decode_hex ---------------------------------------------------------

    #[test]
    fn hex_decode_round_trips_and_mirrors_swift() {
        assert!(matches!(decode_hex(b""), HexDecode::Decoded(ref b) if b.is_empty()));
        assert!(
            matches!(decode_hex(b"00ffA5"), HexDecode::Decoded(ref b) if b == &[0x00, 0xff, 0xa5])
        );
        assert!(matches!(decode_hex(b"0"), HexDecode::Invalid));
        assert!(matches!(decode_hex(b"zz"), HexDecode::Invalid));
        assert!(matches!(decode_hex(b"0x"), HexDecode::Invalid));
        // `UInt8(_, radix: 16)` sign quirks — mirrored, not declined.
        assert!(matches!(decode_hex(b"+f"), HexDecode::Decoded(ref b) if b == &[0x0f]));
        assert!(matches!(decode_hex(b"+F"), HexDecode::Decoded(ref b) if b == &[0x0f]));
        assert!(matches!(decode_hex(b"-0"), HexDecode::Decoded(ref b) if b == &[0x00]));
        assert!(matches!(decode_hex(b"-1"), HexDecode::Invalid));
        assert!(matches!(decode_hex(b"++"), HexDecode::Invalid));
        assert!(matches!(decode_hex(b"f+"), HexDecode::Invalid));
        assert!(matches!(decode_hex(b"f-"), HexDecode::Invalid));
        // Non-ASCII input declines: Swift windows by Character.
        assert!(matches!(decode_hex("éé".as_bytes()), HexDecode::Fallback));
    }

    // -- decode_varint ------------------------------------------------------

    #[test]
    fn varint_edges_match_swift() {
        assert_eq!(decode_varint(&[0x05], 0), Some((5, 1)));
        assert_eq!(decode_varint(&[0xac, 0x02], 0), Some((300, 2)));
        assert_eq!(decode_varint(&[0x80], 0), None);
        assert_eq!(decode_varint(&[0xff; 11], 0), None);
        let mut too_large = vec![0xff; 9];
        too_large.push(0x02);
        assert_eq!(decode_varint(&too_large, 0), None);
        // Ten-byte maximum with payload <= 1 on the last byte still decodes.
        let mut max = vec![0xff; 9];
        max.push(0x01);
        assert_eq!(decode_varint(&max, 0), Some((u64::MAX, 10)));
        // Ten continuation bytes never terminate — the loop stops at ten.
        assert_eq!(decode_varint(&[0x80; 10], 0), None);
        assert_eq!(decode_varint(&[0x05], 1), None);
        assert_eq!(decode_varint(&[0x00, 0x05], 1), Some((5, 2)));
    }

    // -- field / matching_fields --------------------------------------------

    #[test]
    fn oversized_length_cannot_overflow() {
        let mut fields = varint_field_bytes(1, 42);
        fields.extend(varint(2 << 3 | 2));
        fields.extend(varint(u64::MAX));
        assert_eq!(varint_field(1, &fields), Some(42));
        assert!(bytes_field(2, &fields).is_none());
        assert!(matching_fields(1, &fields).is_none());
    }

    #[test]
    fn fixed_and_unknown_wire_types() {
        // Fixed64 field 2 skipped; field 0 rejected; wire type 3 rejected.
        let mut msg = fixed64_field_bytes(2, 7);
        msg.extend(varint_field_bytes(1, 9));
        assert_eq!(varint_field(1, &msg), Some(9));
        let zero_field = varint(0);
        assert!(matching_fields(1, &zero_field).is_none());
        let group = varint(1 << 3 | 3);
        assert!(matching_fields(1, &group).is_none());
    }

    // -- token_counts -------------------------------------------------------

    #[test]
    fn token_counts_counter_wire_types_reject() {
        // A counter carrying a bytes field is malformed, not zero.
        let usage = bytes_field_bytes(2, b"not-a-varint");
        assert!(token_counts(&usage).is_none());
        // Fixed-width counters are malformed too.
        let usage = fixed64_field_bytes(3, 9);
        assert!(token_counts(&usage).is_none());
        // Unknown fields of every supported wire type are skipped.
        let mut usage = varint_field_bytes(9, 1);
        usage.extend(bytes_field_bytes(9, b"x"));
        usage.extend(fixed64_field_bytes(9, 0));
        usage.extend(varint_field_bytes(2, 7));
        let counts = token_counts(&usage).unwrap();
        assert_eq!(counts.input, 7);
        // Trailing garbage fails the message even when counters are complete.
        usage.extend([0xff]);
        assert!(token_counts(&usage).is_none());
    }

    // -- decode_generation_event --------------------------------------------

    fn event(blob: &[u8], step: Option<&[u8]>, matched: Option<i64>) -> DecodeOutcome {
        decode_generation_event(blob, step, matched)
    }

    #[test]
    fn complete_generation_record() {
        let blob = generation_blob(
            Some("gemini-3.1-pro-low"),
            1_000,
            200,
            50,
            1_132,
            Some(1_800_000_000),
            Some("turn-1"),
            Some("bot-1"),
        );
        match event(&blob, None, None) {
            DecodeOutcome::Event(e) => {
                assert_eq!(e.model, "gemini-3.1-pro-low");
                assert_eq!(e.input_tokens, 2_132);
                assert_eq!(e.output_tokens, 200);
                assert_eq!(e.cache_read_tokens, 50);
                assert_eq!(e.timestamp_seconds, 1_800_000_000);
            }
            _ => panic!("expected event"),
        }
    }

    #[test]
    fn correlated_step_timestamp_only_when_identifiers_match() {
        let blob = generation_blob(
            Some("gemini-3.6-flash"),
            1_000,
            200,
            0,
            0,
            None,
            Some("turn-1"),
            Some("bot-1"),
        );
        let good = step_metadata_bytes(1_800_000_000, Some("turn-1"), Some("bot-1"));
        match event(&blob, Some(&good), None) {
            DecodeOutcome::Event(e) => assert_eq!(e.timestamp_seconds, 1_800_000_000),
            _ => panic!("expected event"),
        }
        let wrong_uuid = step_metadata_bytes(1_800_000_000, Some("other-turn"), Some("bot-1"));
        assert!(matches!(
            event(&blob, Some(&wrong_uuid), None),
            DecodeOutcome::UndatedUsage
        ));
        let wrong_bot = step_metadata_bytes(1_800_000_000, Some("turn-1"), Some("other-bot"));
        assert!(matches!(
            event(&blob, Some(&wrong_bot), None),
            DecodeOutcome::UndatedUsage
        ));
        let missing_ids = bytes_field_bytes(1, &varint_field_bytes(1, 1_800_000_000));
        assert!(matches!(
            event(&blob, Some(&missing_ids), None),
            DecodeOutcome::UndatedUsage
        ));
        // Both sides silent on identifiers: legacy correlation keeps working.
        let blob = generation_blob(Some("m"), 1, 1, 0, 0, None, None, None);
        let no_ids = step_metadata_bytes(1_800_000_000, None, None);
        match event(&blob, Some(&no_ids), None) {
            DecodeOutcome::Event(e) => assert_eq!(e.timestamp_seconds, 1_800_000_000),
            _ => panic!("expected event"),
        }
    }

    #[test]
    fn matched_step_timestamp_beats_step_metadata_but_not_embedded() {
        let blob = generation_blob(
            Some("m"),
            10,
            5,
            0,
            0,
            Some(1_800_000_000),
            Some("t"),
            Some("b"),
        );
        // Embedded timestamp wins over the matched/indexed one.
        match event(&blob, None, Some(1_700_000_000)) {
            DecodeOutcome::Event(e) => assert_eq!(e.timestamp_seconds, 1_800_000_000),
            _ => panic!("expected event"),
        }
        let blob = generation_blob(Some("m"), 10, 5, 0, 0, None, Some("t"), Some("b"));
        let step = step_metadata_bytes(1_600_000_000, Some("t"), Some("b"));
        match event(&blob, Some(&step), Some(1_700_000_000)) {
            DecodeOutcome::Event(e) => assert_eq!(e.timestamp_seconds, 1_700_000_000),
            _ => panic!("expected event"),
        }
    }

    #[test]
    fn reject_paths_carry_the_right_timestamp() {
        // No timestamp anywhere → undated.
        let blob = generation_blob(Some("m"), 1, 1, 0, 0, None, Some("t"), Some("b"));
        assert!(matches!(
            event(&blob, None, None),
            DecodeOutcome::UndatedUsage
        ));
        // Zero total usage → ignored even with a timestamp.
        let blob = generation_blob(
            Some("m"),
            0,
            0,
            0,
            0,
            Some(1_800_000_000),
            Some("t"),
            Some("b"),
        );
        assert!(matches!(event(&blob, None, None), DecodeOutcome::Ignored));
        // Individual counters above the ceiling → invalidTokenCount with the embedded ts.
        let blob = generation_blob(
            Some("m"),
            u64::MAX,
            0,
            0,
            0,
            Some(1_800_000_000),
            Some("t"),
            Some("b"),
        );
        assert!(matches!(
            event(&blob, None, None),
            DecodeOutcome::InvalidTokenCount {
                timestamp_seconds: Some(1_800_000_000)
            }
        ));
        // systemPrompt + input above the ceiling → invalid.
        let blob = generation_blob(
            Some("m"),
            MAXIMUM_TOKEN_COUNT,
            0,
            0,
            1,
            Some(1_800_000_000),
            Some("t"),
            Some("b"),
        );
        assert!(matches!(
            event(&blob, None, None),
            DecodeOutcome::InvalidTokenCount {
                timestamp_seconds: Some(1_800_000_000)
            }
        ));
        // Garbage → malformed with no timestamp.
        assert!(matches!(
            event(&[0xff, 0xff, 0xff], None, None),
            DecodeOutcome::MalformedUsage {
                timestamp_seconds: None
            }
        ));
        // No field-1 wrapper at all → ignored.
        assert!(matches!(
            event(&varint_field_bytes(3, 9), None, None),
            DecodeOutcome::Ignored
        ));
        // Two wrappers → malformed.
        let inner = bytes_field_bytes(4, &varint_field_bytes(2, 5));
        let mut blob = bytes_field_bytes(1, &inner);
        blob.extend(bytes_field_bytes(1, &inner));
        assert!(matches!(
            event(&blob, None, None),
            DecodeOutcome::MalformedUsage {
                timestamp_seconds: None
            }
        ));
    }

    #[test]
    fn model_ambiguity_stays_unpriced() {
        // Two model fields → unknown model, never a guessed rate.
        let usage = [varint_field_bytes(2, 10), varint_field_bytes(3, 5)].concat();
        let mut event_bytes = bytes_field_bytes(19, b"model-a");
        event_bytes.extend(varint_field_bytes(19, 7)); // wrong wire type, still ambiguous
        event_bytes.extend(bytes_field_bytes(4, &usage));
        event_bytes.extend(bytes_field_bytes(
            9,
            &bytes_field_bytes(4, &varint_field_bytes(1, 1_800_000_000)),
        ));
        let blob = bytes_field_bytes(1, &event_bytes);
        match event(&blob, None, None) {
            DecodeOutcome::Event(e) => assert_eq!(e.model, UNKNOWN_MODEL),
            _ => panic!("expected event"),
        }
        // Whitespace-only model → unknown.
        let usage = [varint_field_bytes(2, 10), varint_field_bytes(3, 5)].concat();
        let mut event_bytes = bytes_field_bytes(19, "  \u{00a0} ".as_bytes());
        event_bytes.extend(bytes_field_bytes(4, &usage));
        event_bytes.extend(bytes_field_bytes(
            9,
            &bytes_field_bytes(4, &varint_field_bytes(1, 1_800_000_000)),
        ));
        let blob = bytes_field_bytes(1, &event_bytes);
        match event(&blob, None, None) {
            DecodeOutcome::Event(e) => assert_eq!(e.model, UNKNOWN_MODEL),
            _ => panic!("expected event"),
        }
        // Invalid UTF-8 model → unknown; valid model trimmed.
        let usage = [varint_field_bytes(2, 10), varint_field_bytes(3, 5)].concat();
        let mut event_bytes = bytes_field_bytes(19, &[0xff, 0xfe]);
        event_bytes.extend(bytes_field_bytes(4, &usage));
        event_bytes.extend(bytes_field_bytes(
            9,
            &bytes_field_bytes(4, &varint_field_bytes(1, 1_800_000_000)),
        ));
        let blob = bytes_field_bytes(1, &event_bytes);
        match event(&blob, None, None) {
            DecodeOutcome::Event(e) => assert_eq!(e.model, UNKNOWN_MODEL),
            _ => panic!("expected event"),
        }
    }

    #[test]
    fn non_ascii_identifier_mismatch_declines() {
        // "é" vs "e + combining acute" — canonically equal under Swift ==, byte-different here.
        let blob = generation_blob(Some("m"), 1, 1, 0, 0, None, Some("caf\u{e9}"), Some("b"));
        let step = step_metadata_bytes(1_800_000_000, Some("cafe\u{301}"), Some("b"));
        assert!(matches!(
            event(&blob, Some(&step), None),
            DecodeOutcome::Fallback
        ));
        // One side non-ASCII and byte-different cannot be decided without normalization —
        // decline rather than risk a canonical-equivalence miss.
        let step = step_metadata_bytes(1_800_000_000, Some("cafe2"), Some("b"));
        assert!(matches!(
            event(&blob, Some(&step), None),
            DecodeOutcome::Fallback
        ));
        // All-ASCII mismatch is definitively incompatible — never a decline.
        let blob = generation_blob(Some("m"), 1, 1, 0, 0, None, Some("turn-1"), Some("b"));
        let step = step_metadata_bytes(1_800_000_000, Some("turn-2"), Some("b"));
        assert!(matches!(
            event(&blob, Some(&step), None),
            DecodeOutcome::UndatedUsage
        ));
    }

    // -- identities -----------------------------------------------------------

    #[test]
    fn generation_step_identity_extracts_and_rejects() {
        let blob = generation_blob(Some("m"), 1, 1, 0, 0, None, Some("turn-9"), Some("bot-9"));
        let identity = generation_step_identity(&blob).unwrap();
        assert_eq!(identity.uuid, Some("turn-9"));
        assert_eq!(identity.bot_id, Some("bot-9"));
        // UUID only / bot only / neither.
        let blob = generation_blob(Some("m"), 1, 1, 0, 0, None, Some("u"), None);
        let identity = generation_step_identity(&blob).unwrap();
        assert_eq!(identity.uuid, Some("u"));
        assert_eq!(identity.bot_id, None);
        let blob = generation_blob(Some("m"), 1, 1, 0, 0, None, None, None);
        assert!(generation_step_identity(&blob).is_none());
        // Whitespace-only identifier → invalid → whole identity nil.
        let blob = generation_blob(Some("m"), 1, 1, 0, 0, None, Some("  "), Some("b"));
        assert!(generation_step_identity(&blob).is_none());
        // Truncated wrapper → nil rather than a partial identity.
        assert!(generation_step_identity(&[0x0a, 0x05, 0x22]).is_none());
    }

    #[test]
    fn step_metadata_identity_and_timestamp() {
        let metadata = step_metadata_bytes(1_800_000_000, Some("turn-1"), Some("bot-1"));
        let (identity, ts) = step_identity_and_timestamp(&metadata).unwrap();
        assert_eq!(identity.uuid, Some("turn-1"));
        assert_eq!(identity.bot_id, Some("bot-1"));
        assert_eq!(ts, 1_800_000_000);
        // No identifiers → nil even with a timestamp.
        let metadata = step_metadata_bytes(1_800_000_000, None, None);
        assert!(step_identity_and_timestamp(&metadata).is_none());
        // No timestamp → nil even with identifiers.
        let metadata = bytes_field_bytes(12, b"turn-1");
        assert!(step_identity_and_timestamp(&metadata).is_none());
    }

    // -- FFI round-trips ------------------------------------------------------

    unsafe fn decode_ffi(hex_str: &str, step: Option<&str>, matched: Option<i64>) -> u32 {
        let step_bytes = step.map(|s| s.as_bytes());
        let raw = qb_antigravity_decode_generation(
            hex_str.as_ptr(),
            hex_str.len(),
            step_bytes.map_or(ptr::null(), |s| s.as_ptr()),
            step_bytes.map_or(0, |s| s.len()),
            matched.unwrap_or(0),
            u8::from(matched.is_some()),
        );
        assert!(!raw.is_null());
        let status = qb_antigravity_generation_status(raw);
        unsafe { qb_antigravity_generation_destroy(raw) };
        status
    }

    #[test]
    fn ffi_decode_round_trip() {
        let blob = generation_blob(
            Some("gemini-3.6-flash"),
            10,
            5,
            2,
            0,
            Some(1_800_000_000),
            Some("t"),
            Some("b"),
        );
        let hex = hex_encode(&blob);
        assert_eq!(
            unsafe { decode_ffi(&hex, None, None) },
            QB_ANTIGRAVITY_EVENT
        );
        // Odd-length and invalid hex → the unreadable status.
        assert_eq!(
            unsafe { decode_ffi("0", None, None) },
            QB_ANTIGRAVITY_UNREADABLE_HEX
        );
        assert_eq!(
            unsafe { decode_ffi("zz", None, None) },
            QB_ANTIGRAVITY_UNREADABLE_HEX
        );
        // Non-ASCII hex declines entirely.
        let raw = qb_antigravity_decode_generation("éé".as_ptr(), 4, ptr::null(), 0, 0, 0);
        assert!(raw.is_null());
        // Step hex odd → treated as absent metadata (still decodes via embedded ts).
        assert_eq!(
            unsafe { decode_ffi(&hex, Some("0"), None) },
            QB_ANTIGRAVITY_EVENT
        );
    }

    #[test]
    fn ffi_identity_round_trip() {
        let blob = generation_blob(Some("m"), 1, 1, 0, 0, None, Some("turn-1"), Some("bot-1"));
        let hex = hex_encode(&blob);
        let raw = qb_antigravity_generation_step_identity(hex.as_ptr(), hex.len());
        assert!(!raw.is_null());
        assert_eq!(
            qb_antigravity_identity_status(raw),
            QB_ANTIGRAVITY_IDENTITY_PRESENT
        );
        let ffi = unsafe { &*qb_antigravity_identity(raw) };
        let mut len = 0u32;
        let base = qb_antigravity_identity_strings(raw, &mut len);
        let strings = unsafe { std::slice::from_raw_parts(base, len as usize) };
        let uuid = &strings[ffi.uuid_offset as usize..(ffi.uuid_offset + ffi.uuid_length) as usize];
        assert_eq!(uuid, b"turn-1");
        assert_eq!(ffi.has_timestamp, 0);
        unsafe { qb_antigravity_identity_destroy(raw) };

        // Step-metadata surface returns identity + timestamp together.
        let metadata = step_metadata_bytes(1_800_000_000, Some("turn-1"), Some("bot-1"));
        let metadata_hex = hex_encode(&metadata);
        let raw = qb_antigravity_step_metadata_identity(metadata_hex.as_ptr(), metadata_hex.len());
        assert!(!raw.is_null());
        let ffi = unsafe { &*qb_antigravity_identity(raw) };
        assert_eq!(ffi.has_timestamp, 1);
        assert_eq!(ffi.timestamp_seconds, 1_800_000_000);
        unsafe { qb_antigravity_identity_destroy(raw) };

        // Non-ASCII identity declines.
        let blob = generation_blob(Some("m"), 1, 1, 0, 0, None, Some("caf\u{e9}"), None);
        let blob_hex = hex_encode(&blob);
        let raw = qb_antigravity_generation_step_identity(blob_hex.as_ptr(), blob_hex.len());
        assert!(raw.is_null());
    }
}
