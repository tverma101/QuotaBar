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
