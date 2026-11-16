//! Compact pricing catalog codec — port of `PricingCatalogCodecs.catalogFromCompact` in Swift
//! (`Sources/QuotaBar/Pricing/PricingCatalogCodecs.swift`).
//!
//! The snapshots are produced by the bundled pricing generator and by the app itself after a
//! catalog refresh. JSON shape (snake_case for nested tiers, camelCase elsewhere):
//! `{"retrieved_at"?: "…", "models": {"<key>": {"i": 1.0, "o": 1.0, "cw": 1.0, "cr": 1.0,
//! "cw1"?: 1.0, "tiers"?: [{"threshold_prompt_tokens": 100000, "includes_threshold"?: false,
//! "input_per_million"?: …, "output_per_million"?: …, "cache_write_per_million"?: …,
//! "cache_read_per_million"?: …, "cache_write_1h_per_million"?: …}],
//! "ia"?: 1.0, "oa"?: 1.0, "cwa"?: 1.0, "cra"?: 1.0,
//! "cre"?: true, "fast"?: 1.0}} , "retired"?: ["…"]}`
//!
//! The Rust entry point returns an opaque handle; Swift walks entries through the C ABI or falls
//! back to the Swift reference implementation when the handle is NULL.

use crate::{intern, NIL_STRING};
use serde_json::Value;
use serde_json::Map;
use std::ptr;

pub const QB_PRICING_MAX_TIERS_PER_ENTRY: usize = 4;
pub const QB_PRICING_MAX_RETIRED_KEYS: usize = 4096;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct QbCompactTier {
    pub threshold_prompt_tokens: u64,
    pub includes_threshold: u8,
    pub input_per_million: f64,     // NaN = absent
    pub output_per_million: f64,
    pub cache_write_per_million: f64,
    pub cache_read_per_million: f64,
    pub cache_write_1h_per_million: f64,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct QbCompactEntry {
    pub key_offset: u32,
    pub key_length: u32,
    pub input_per_million: f64,
    pub output_per_million: f64,
    pub cache_write_per_million: f64,
    pub cache_read_per_million: f64,
    pub cache_write_1h_per_million: f64, // NaN = absent
    pub input_above_200k_per_million: f64,
    pub output_above_200k_per_million: f64,
    pub cache_write_above_200k_per_million: f64,
    pub cache_read_above_200k_per_million: f64,
    pub cache_read_is_explicit: u8,
    pub fast_multiplier: f64,
    pub tier_count: u8,
    pub tier_offset: u32,       // index into the shared QbCompactTier array
}

pub struct PricingCompactResult {
    pub retrieved_at_offset: u32,
    pub retrieved_at_length: u32,
    pub entries: Vec<QbCompactEntry>,
    pub tiers: Vec<QbCompactTier>,
    pub retired_count: u32,
    pub retired_offset: u32,           // first retired key in blob (count entries, contiguous)
    pub strings: Vec<u8>,
}

fn parse_f64_optional(v: Option<&Value>) -> Option<f64> {
    v.and_then(|x| x.as_f64())
}

fn parse_double(member: &Map<String, Value>, name: &str) -> Option<f64> {
    member.get(name).and_then(|v| v.as_f64())
}

fn nonnegative_finite(value: f64) -> Option<f64> {
    if value.is_finite() && value >= 0.0 && value <= 1e18 {
        Some(value)
    } else {
        None
    }
}

fn intern_entry(
    blob: &mut Vec<u8>,
    tiers_blob: &mut Vec<QbCompactTier>,
    key: &str,
    model: &Map<String, Value>,
) -> Option<QbCompactEntry> {
    let input = nonnegative_finite(parse_double(model, "i")?)?;
    let output = nonnegative_finite(parse_double(model, "o")?)?;
    let cw = nonnegative_finite(parse_double(model, "cw")?)?;
    let cr = nonnegative_finite(parse_double(model, "cr")?)?;
    let cw1 = parse_f64_optional(model.get("cw1")).and_then(nonnegative_finite);

    let input_200k = parse_f64_optional(model.get("ia")).and_then(nonnegative_finite).unwrap_or(f64::NAN);
    let output_200k = parse_f64_optional(model.get("oa")).and_then(nonnegative_finite).unwrap_or(f64::NAN);
    let cw_200k = parse_f64_optional(model.get("cwa")).and_then(nonnegative_finite).unwrap_or(f64::NAN);
    let cr_200k = parse_f64_optional(model.get("cra")).and_then(nonnegative_finite).unwrap_or(f64::NAN);

    let cache_read_is_explicit = model
        .get("cre")
        .and_then(|v| v.as_bool())
        .map(|b| u8::from(b))
        .unwrap_or(1);
    let fast_multiplier = parse_f64_optional(model.get("fast"))
        .and_then(nonnegative_finite)
        .filter(|v| *v > 0.0)
        .unwrap_or(1.0);

    let tiers_json = model
        .get("tiers")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    if tiers_json.len() > QB_PRICING_MAX_TIERS_PER_ENTRY {
        return None;
    }

    let tier_offset = tiers_blob.len() as u32;
    for tier in &tiers_json {
        let Some(t) = tier.as_object() else { return None };
        let threshold = t
            .get("threshold_prompt_tokens")
            .and_then(|v| v.as_u64())
            .unwrap_or(0);
        let includes = t.get("includes_threshold").and_then(|v| v.as_bool()).unwrap_or(false);
        tiers_blob.push(QbCompactTier {
            threshold_prompt_tokens: threshold,
            includes_threshold: u8::from(includes),
            input_per_million: parse_f64_optional(t.get("input_per_million")).unwrap_or(f64::NAN),
            output_per_million: parse_f64_optional(t.get("output_per_million")).unwrap_or(f64::NAN),
            cache_write_per_million: parse_f64_optional(t.get("cache_write_per_million")).unwrap_or(f64::NAN),
            cache_read_per_million: parse_f64_optional(t.get("cache_read_per_million")).unwrap_or(f64::NAN),
            cache_write_1h_per_million: parse_f64_optional(t.get("cache_write_1h_per_million")).unwrap_or(f64::NAN),
        });
    }

    let (key_offset, key_length) = intern(blob, key)?;
    Some(QbCompactEntry {
        key_offset,
        key_length,
        input_per_million: input,
        output_per_million: output,
        cache_write_per_million: cw,
        cache_read_per_million: cr,
        cache_write_1h_per_million: cw1.unwrap_or(f64::NAN),
        input_above_200k_per_million: input_200k,
        output_above_200k_per_million: output_200k,
        cache_write_above_200k_per_million: cw_200k,
        cache_read_above_200k_per_million: cr_200k,
        cache_read_is_explicit,
        fast_multiplier,
        tier_count: tiers_json.len() as u8,
        tier_offset,
    })
}

pub fn parse_compact_catalog(data: &[u8]) -> Option<PricingCompactResult> {
    let value: Value = serde_json::from_slice(data).ok()?;
    let root = value.as_object()?;

    let mut strings: Vec<u8> = Vec::new();
    let mut tiers: Vec<QbCompactTier> = Vec::new();
    let mut entries: Vec<QbCompactEntry> = Vec::new();

    let models = root
        .get("models")
        .and_then(|v| v.as_object())?
        .clone();

    for (key, model) in &models {
        let Some(model) = model.as_object() else { return None };
        entries.push(intern_entry(&mut strings, &mut tiers, key, model)?);
    }
    // Preserve deterministic order for parity tests (Swift iterates sorted JSON keys).
    entries.sort_by_key(|e| {
        let s = std::str::from_utf8(&strings[e.key_offset as usize..(e.key_offset + e.key_length) as usize]).unwrap_or("");
        s.to_string()
    });

    let (retrieved_at_offset, retrieved_at_length) = match root.get("retrieved_at") {
        Some(Value::String(s)) => {
            if s.is_empty() {
                (NIL_STRING, 0)
            } else if let Some(v) = intern(&mut strings, s) {
                v
            } else {
                return None;
            }
        }
        _ => (NIL_STRING, 0),
    };

    let (retired_count, retired_offset) = match root.get("retired") {
        Some(Value::Array(arr)) => {
            if arr.len() > QB_PRICING_MAX_RETIRED_KEYS { return None }
            if arr.is_empty() {
                (0, 0)
            } else {
                let off = strings.len() as u32;
                for item in arr {
                    let Some(s) = item.as_str() else { return None };
                    let bytes = s.as_bytes();
                    if bytes.len() > u32::MAX as usize {
                        return None;
                    }
                    strings.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
                    strings.extend_from_slice(bytes);
                }
                (arr.len() as u32, off)
            }
        }
        _ => (0, 0),
    };

    Some(PricingCompactResult {
        retrieved_at_offset,
        retrieved_at_length,
        entries,
        tiers,
        retired_count,
        retired_offset,
        strings,
    })
}

// ---------------------------------------------------------------------------
// C ABI
// ---------------------------------------------------------------------------

#[no_mangle]
pub extern "C" fn qb_pricing_compact_catalog_parse(
    data: *const u8,
    length: usize,
) -> *mut PricingCompactResult {
    if data.is_null() && length > 0 {
        return ptr::null_mut();
    }
    let bytes = if data.is_null() {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(data, length) }
    };
    parse_compact_catalog(bytes).map(|r| Box::into_raw(Box::new(r))).unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn qb_pricing_compact_catalog_entry_count(result: *const PricingCompactResult) -> u32 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.entries.len() as u32
}

#[no_mangle]
pub extern "C" fn qb_pricing_compact_catalog_entries(
    result: *const PricingCompactResult,
) -> *const QbCompactEntry {
    if result.is_null() {
        return ptr::null();
    }
    unsafe { &*result }.entries.as_ptr()
}

#[no_mangle]
pub extern "C" fn qb_pricing_compact_catalog_tier_count(result: *const PricingCompactResult) -> u32 {
    if result.is_null() {
        return 0;
    }
    unsafe { &*result }.tiers.len() as u32
}

#[no_mangle]
pub extern "C" fn qb_pricing_compact_catalog_tiers(
    result: *const PricingCompactResult,
) -> *const QbCompactTier {
    if result.is_null() {
        return ptr::null();
    }
    unsafe { &*result }.tiers.as_ptr()
}

#[no_mangle]
pub extern "C" fn qb_pricing_compact_catalog_retrieved_at_offset(result: *const PricingCompactResult) -> u32 {
    unsafe { result.as_ref().map(|r| r.retrieved_at_offset).unwrap_or(NIL_STRING) }
}

#[no_mangle]
pub extern "C" fn qb_pricing_compact_catalog_retrieved_at_length(result: *const PricingCompactResult) -> u32 {
    unsafe { result.as_ref().map(|r| r.retrieved_at_length).unwrap_or(0) }
}

#[no_mangle]
pub extern "C" fn qb_pricing_compact_catalog_retired_count(result: *const PricingCompactResult) -> u32 {
    unsafe { result.as_ref().map(|r| r.retired_count).unwrap_or(0) }
}

/// Offset of the first retired-key record in the string blob ([u32le length][bytes]*, count
/// from qb_pricing_compact_catalog_retired_count). Keys are stored in catalog order, not sorted.
#[no_mangle]
pub extern "C" fn qb_pricing_compact_catalog_retired_offset(result: *const PricingCompactResult) -> u32 {
    unsafe { result.as_ref().map(|r| r.retired_offset).unwrap_or(0) }
}

#[no_mangle]
pub extern "C" fn qb_pricing_compact_catalog_strings(
    result: *const PricingCompactResult,
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
pub unsafe extern "C" fn qb_pricing_compact_catalog_destroy(result: *mut PricingCompactResult) {
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

    #[test]
    fn parses_minimal_snapshot() {
        let raw = r#"{"models":{"cheap":{"i":0.1,"o":0.2,"cw":0.1,"cr":0.01}}}"#;
        let parsed = parse_compact_catalog(raw.as_bytes()).unwrap();
        assert_eq!(parsed.entries.len(), 1);
        assert_eq!(parsed.entries[0].input_per_million, 0.1);
        assert_eq!(parsed.entries[0].tier_count, 0);
    }

    #[test]
    fn cached_crate_snapshots_roundtrip() {
        for name in ["pricing_litellm_snapshot.json", "pricing_models_dev_snapshot.json"] {
            let path = format!("../../Sources/QuotaBar/Resources/{name}");
            let bytes = std::fs::read(path).unwrap();
            let parsed = parse_compact_catalog(&bytes).unwrap();
            assert!(!parsed.entries.is_empty());
            assert!(parsed.entries.iter().all(|e| e.input_per_million.is_finite() && e.output_per_million.is_finite()));
        }
    }
}
