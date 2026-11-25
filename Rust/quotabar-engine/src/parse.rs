//! Lenient readers for untrusted provider payloads (Swift `ProviderParse`).

use serde_json::Value;

/// A finite number from a JSON number or a numeric string; booleans are not numbers.
pub fn number(value: Option<&Value>) -> Option<f64> {
    match value? {
        Value::Number(n) => n.as_f64().filter(|v| v.is_finite()),
        Value::String(s) => s.trim().parse::<f64>().ok().filter(|v| v.is_finite()),
        _ => None,
    }
}

pub fn bool(value: Option<&Value>) -> Option<bool> {
    match value? {
        Value::Bool(b) => Some(*b),
        Value::Number(n) => n.as_f64().map(|v| v != 0.0),
        Value::String(s) => match s.trim().to_ascii_lowercase().as_str() {
            "true" | "1" => Some(true),
            "false" | "0" => Some(false),
            _ => None,
        },
        _ => None,
    }
}

/// A non-empty, whitespace-trimmed string.
pub fn trimmed_string(value: Option<&Value>) -> Option<String> {
    let trimmed = value?.as_str()?.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

pub fn object(value: Option<&Value>) -> Option<&serde_json::Map<String, Value>> {
    value?.as_object()
}

pub const DAY_MS: i64 = 24 * 60 * 60 * 1000;
pub const WEEK_MS: i64 = 7 * DAY_MS;

/// Decode standard or URL-safe Base64 (with or without `=` padding).
pub fn decode_base64(input: &str) -> Option<Vec<u8>> {
    let clean: String = input.chars().filter(|c| !c.is_ascii_whitespace()).collect();
    if clean.is_empty() {
        return Some(Vec::new());
    }
    let mut out = Vec::with_capacity(clean.len() * 3 / 4);
    let mut buf = 0u32;
    let mut bits = 0u8;
    let mut ended = false;
    for byte in clean.bytes() {
        if byte == b'=' {
            ended = true;
            continue;
        }
        if ended {
            return None;
        }
        let val = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'+' | b'-' => 62,
            b'/' | b'_' => 63,
            _ => return None,
        };
        buf = (buf << 6) | u32::from(val);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buf >> bits) as u8);
            buf &= (1 << bits) - 1;
        }
    }
    Some(out)
}

/// Decode the middle payload segment of a JWT (`header.payload.signature`) into a JSON object.
pub fn jwt_payload(token: &str) -> Option<serde_json::Map<String, Value>> {
    let mut parts = token.trim().split('.');
    let _header = parts.next()?;
    let payload = parts.next()?;
    let _sig = parts.next()?;
    let bytes = decode_base64(payload)?;
    match serde_json::from_slice::<Value>(&bytes).ok()? {
        Value::Object(map) => Some(map),
        _ => None,
    }
}

/// Bounded integer token count (`0..=1e15`), rejecting booleans, floats with fractional parts, and out-of-range numbers.
pub fn non_negative_count(value: Option<&Value>) -> Option<i64> {
    let raw = number(value)?;
    if raw < 0.0 || raw > 1e15 || raw.trunc() != raw {
        return None;
    }
    Some(raw as i64)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn numbers_accept_strings_and_reject_booleans() {
        assert_eq!(number(Some(&json!(42))), Some(42.0));
        assert_eq!(number(Some(&json!(" 7.5 "))), Some(7.5));
        assert_eq!(number(Some(&json!(true))), None);
        assert_eq!(number(Some(&json!("inf"))), None);
        assert_eq!(number(None), None);
    }

    #[test]
    fn bools_accept_numbers_and_strings() {
        assert_eq!(bool(Some(&json!(true))), Some(true));
        assert_eq!(bool(Some(&json!(0))), Some(false));
        assert_eq!(bool(Some(&json!(" TRUE "))), Some(true));
        assert_eq!(bool(Some(&json!("maybe"))), None);
    }
}
