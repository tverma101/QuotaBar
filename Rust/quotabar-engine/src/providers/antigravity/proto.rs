//! Decodes generation-accounting fields in Antigravity's undocumented conversation protobufs.
//! Ported from OpenUsage 0.7.10 `AntigravityProtoDecoder` (FelixIsaac, openusage#1058/#1120).
//! Newer databases also record timestamps in conversation steps.

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct GenerationEvent {
    pub model: String,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub cache_read_tokens: i64,
    pub timestamp_seconds: i64,
    /// Local calendar day of `timestamp_seconds`, computed once when the event is decoded. The
    /// fold cache serves these events repeatedly, so reformatting the day on every refresh was
    /// pure allocation and timezone-conversion churn.
    #[serde(default)]
    pub day: String,
}

impl GenerationEvent {
    pub const UNKNOWN_MODEL: &'static str = "Unknown Antigravity Model";
}

enum WireValue {
    Varint(u64),
    Bytes(Vec<u8>),
}

#[derive(Debug, PartialEq, Eq, Hash)]
pub(crate) struct StepIdentity {
    pub(crate) uuid: Option<String>,
    pub(crate) bot_id: Option<String>,
}

fn unique_field(number: u32, bytes: &[u8]) -> Option<Option<WireValue>> {
    let mut offset = 0;
    let mut found = None;
    while offset < bytes.len() {
        let (field, value, end) = wire_field(bytes, offset, number)?;
        if field == number {
            if found.is_some() {
                return None;
            }
            found = Some(value?);
        }
        offset = end;
    }
    Some(found)
}

fn unique_bytes(number: u32, bytes: &[u8]) -> Option<Option<Vec<u8>>> {
    match unique_field(number, bytes)? {
        Some(WireValue::Bytes(value)) => Some(Some(value)),
        Some(WireValue::Varint(_)) => None,
        None => Some(None),
    }
}

fn identifier(number: u32, bytes: &[u8]) -> Option<Option<String>> {
    match unique_bytes(number, bytes)? {
        Some(raw) => {
            let value = String::from_utf8(raw).ok()?;
            (!value.trim().is_empty()).then_some(Some(value))
        }
        None => Some(None),
    }
}

pub(crate) fn generation_identity(blob: &[u8]) -> Option<StepIdentity> {
    let wrapped = unique_bytes(1, blob)??;
    let usage = unique_bytes(4, &wrapped)??;
    Some(StepIdentity {
        uuid: identifier(4, blob)?,
        bot_id: identifier(7, &usage)?,
    })
}

pub(crate) fn step_identity_timestamp(blob: &[u8]) -> Option<(StepIdentity, i64)> {
    let bot_id = match unique_bytes(9, blob)? {
        Some(usage) => identifier(7, &usage)?,
        None => None,
    };
    let timestamp = unique_bytes(1, blob)??;
    let Some(WireValue::Varint(timestamp)) = unique_field(1, &timestamp)? else {
        return None;
    };
    let timestamp = i64::try_from(timestamp).ok().filter(|&v| v > 0)?;
    Some((
        StepIdentity {
            uuid: identifier(12, blob)?,
            bot_id,
        },
        timestamp,
    ))
}

/// Protobuf unsigned varint. At most 10 bytes; the 10th payload nibble must be 0 or 1.
pub fn decode_varint(bytes: &[u8], offset: usize) -> Option<(u64, usize)> {
    if offset >= bytes.len() {
        return None;
    }
    let mut value: u64 = 0;
    for byte_index in 0..10 {
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

fn field(requested: u32, bytes: &[u8]) -> Option<WireValue> {
    let mut offset = 0;
    while offset < bytes.len() {
        let (number, value, end) = wire_field(bytes, offset, requested)?;
        if number == requested {
            return value;
        }
        offset = end;
    }
    None
}

fn wire_field(
    bytes: &[u8],
    offset: usize,
    requested: u32,
) -> Option<(u32, Option<WireValue>, usize)> {
    let (tag, next) = decode_varint(bytes, offset)?;
    let number = u32::try_from(tag >> 3).ok()?;
    if number == 0 {
        return None;
    }
    let (value, end) = match tag & 0x7 {
        0 => {
            let (value, after) = decode_varint(bytes, next)?;
            (
                (number == requested).then_some(WireValue::Varint(value)),
                after,
            )
        }
        2 => {
            let (len, start) = decode_varint(bytes, next)?;
            let remaining = bytes.len().saturating_sub(start);
            if len > remaining as u64 {
                return None;
            }
            let count = usize::try_from(len).ok()?;
            let end = start + count;
            (
                (number == requested).then(|| WireValue::Bytes(bytes[start..end].to_vec())),
                end,
            )
        }
        1 | 5 => {
            let width = if tag & 0x7 == 1 { 8 } else { 4 };
            if bytes.len().saturating_sub(next) < width {
                return None;
            }
            (None, next + width)
        }
        _ => return None,
    };
    Some((number, value, end))
}

fn bytes_field(number: u32, bytes: &[u8]) -> Option<Vec<u8>> {
    match field(number, bytes)? {
        WireValue::Bytes(value) => Some(value),
        WireValue::Varint(_) => None,
    }
}

fn varint_field(number: u32, bytes: &[u8]) -> Option<u64> {
    match field(number, bytes)? {
        WireValue::Varint(value) => Some(value),
        WireValue::Bytes(_) => None,
    }
}

/// `gen_metadata.data` wraps its event in field 1: model 19, token counts 4, timestamp 9.
/// An absent model stays visibly unpriced instead of silently borrowing another Gemini rate.
pub fn generation_event(blob: &[u8]) -> Option<GenerationEvent> {
    generation_event_with_timestamp(blob, || None)
}

pub(crate) fn generation_event_with_timestamp(
    blob: &[u8],
    fallback: impl FnOnce() -> Option<i64>,
) -> Option<GenerationEvent> {
    let wrapped = bytes_field(1, blob)?;
    let decoded_model = bytes_field(19, &wrapped).and_then(|raw| String::from_utf8(raw).ok());
    let model = decoded_model
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| GenerationEvent::UNKNOWN_MODEL.to_string());

    let usage = bytes_field(4, &wrapped)?;
    let system_prompt = i64::try_from(varint_field(1, &usage).unwrap_or(0)).ok()?;
    let input = i64::try_from(varint_field(2, &usage).unwrap_or(0)).ok()?;
    let output = i64::try_from(varint_field(3, &usage).unwrap_or(0)).ok()?;
    let cache_read = i64::try_from(varint_field(5, &usage).unwrap_or(0)).ok()?;
    let billable_input = system_prompt.checked_add(input)?;
    if billable_input == 0 && output == 0 && cache_read == 0 {
        return None;
    }

    let timestamp_seconds = embedded_timestamp(&wrapped).or_else(fallback)?;

    Some(GenerationEvent {
        model,
        input_tokens: billable_input,
        output_tokens: output,
        cache_read_tokens: cache_read,
        timestamp_seconds,
        day: crate::accounting::day_key(timestamp_seconds as f64),
    })
}

fn embedded_timestamp(wrapped: &[u8]) -> Option<i64> {
    let timing = bytes_field(9, wrapped)?;
    let wall = bytes_field(4, &timing)?;
    i64::try_from(varint_field(1, &wall)?)
        .ok()
        .filter(|&v| v > 0)
}

#[cfg(test)]
pub(crate) fn encode_varint(mut value: u64) -> Vec<u8> {
    let mut out = Vec::new();
    loop {
        let mut byte = (value & 0x7f) as u8;
        value >>= 7;
        if value != 0 {
            byte |= 0x80;
        }
        out.push(byte);
        if value == 0 {
            break;
        }
    }
    out
}

#[cfg(test)]
fn encode_key(field: u32, wire: u8) -> Vec<u8> {
    encode_varint(u64::from(field) << 3 | u64::from(wire))
}

#[cfg(test)]
pub(crate) fn encode_bytes_field(field: u32, data: &[u8]) -> Vec<u8> {
    let mut out = encode_key(field, 2);
    out.extend(encode_varint(data.len() as u64));
    out.extend_from_slice(data);
    out
}

#[cfg(test)]
pub(crate) fn encode_varint_field(field: u32, value: u64) -> Vec<u8> {
    let mut out = encode_key(field, 0);
    out.extend(encode_varint(value));
    out
}

#[cfg(test)]
pub(crate) fn encode_generation_blob(
    model: &str,
    system_prompt: u64,
    input: u64,
    output: u64,
    cache_read: u64,
    timestamp_seconds: u64,
) -> Vec<u8> {
    let mut usage = Vec::new();
    usage.extend(encode_varint_field(1, system_prompt));
    usage.extend(encode_varint_field(2, input));
    usage.extend(encode_varint_field(3, output));
    usage.extend(encode_varint_field(5, cache_read));
    let wall = encode_varint_field(1, timestamp_seconds);
    let timing = encode_bytes_field(4, &wall);
    let mut wrapped = Vec::new();
    wrapped.extend(encode_bytes_field(19, model.as_bytes()));
    wrapped.extend(encode_bytes_field(4, &usage));
    wrapped.extend(encode_bytes_field(9, &timing));
    encode_bytes_field(1, &wrapped)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_varint_single_and_multi_byte() {
        assert_eq!(decode_varint(&[0], 0), Some((0, 1)));
        assert_eq!(decode_varint(&[1], 0), Some((1, 1)));
        assert_eq!(decode_varint(&[127], 0), Some((127, 1)));
        assert_eq!(decode_varint(&[0x80, 0x01], 0), Some((128, 2)));
        assert_eq!(decode_varint(&[0xff, 0x01], 0), Some((255, 2)));
        assert_eq!(decode_varint(&[0xac, 0x02], 0), Some((300, 2)));
    }

    #[test]
    fn decode_varint_rejects_truncated_and_overlong() {
        assert_eq!(decode_varint(&[], 0), None);
        assert_eq!(decode_varint(&[0x80], 0), None);
        assert_eq!(
            decode_varint(
                &[0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02],
                0
            ),
            None
        );
        let max_ok = [0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01];
        assert_eq!(decode_varint(&max_ok, 0), Some((1u64 << 63, 10)));
    }

    #[test]
    fn generation_event_reads_model_billable_input_and_timestamp() {
        let blob = encode_generation_blob("gemini-2.5-flash", 10, 20, 7, 3, 1_700_000_000);
        let event = generation_event(&blob).expect("decode");
        assert_eq!(event.model, "gemini-2.5-flash");
        assert_eq!(event.input_tokens, 30);
        assert_eq!(event.output_tokens, 7);
        assert_eq!(event.cache_read_tokens, 3);
        assert_eq!(event.timestamp_seconds, 1_700_000_000);
    }

    #[test]
    fn generation_event_unknown_model_when_field_19_missing() {
        let usage = {
            let mut u = Vec::new();
            u.extend(encode_varint_field(2, 5));
            u.extend(encode_varint_field(3, 1));
            u
        };
        let wall = encode_varint_field(1, 1_700_000_001);
        let timing = encode_bytes_field(4, &wall);
        let mut wrapped = Vec::new();
        wrapped.extend(encode_bytes_field(4, &usage));
        wrapped.extend(encode_bytes_field(9, &timing));
        let blob = encode_bytes_field(1, &wrapped);
        let event = generation_event(&blob).expect("decode");
        assert_eq!(event.model, GenerationEvent::UNKNOWN_MODEL);
        assert_eq!(event.input_tokens, 5);
    }

    #[test]
    fn generation_event_skips_zero_token_and_malformed() {
        let zero = encode_generation_blob("gemini-2.5-flash", 0, 0, 0, 0, 1_700_000_000);
        assert!(generation_event(&zero).is_none());
        assert!(generation_event(&[0xff]).is_none());
        assert!(generation_event(&[]).is_none());
    }
}
