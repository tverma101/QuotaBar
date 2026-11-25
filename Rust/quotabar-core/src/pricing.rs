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
//! "cre"?: true, "crb"?: false, "fast"?: 1.0}} , "retired"?: ["…"]}`
//!
//! The Rust entry point returns an opaque handle; Swift reassembles `ModelRates` through the C ABI.
//! This is the *fallback*: Swift's `catalogFromCompact` runs Foundation's `JSONDecoder` first
//! (byte-exact with the snapshots that Foundation itself wrote — serde_json rounds exact-half
//! decimals to even, Foundation toward zero). This module only runs when Foundation cannot handle
//! an input at all; `catalogFromCompact` throws `PricingCodecError.notAnObject` if both fail.

use crate::{intern, NIL_STRING};
use serde_json::Map;
use serde_json::Value;
use std::ptr;

// The C header (Sources/CQuotabarCore/include/quotabar_core.h) must agree on layout. If these
// asserts fire, do not change a field — fix the header to match or revert.
const _: () = assert!(std::mem::size_of::<QbCompactTier>() == 56);
const _: () = assert!(std::mem::size_of::<QbCompactEntry>() == 104);
const _: () = assert!(std::mem::align_of::<QbCompactTier>() == 8);
const _: () = assert!(std::mem::align_of::<QbCompactEntry>() == 8);

pub const QB_PRICING_MAX_TIERS_PER_ENTRY: usize = 4;
pub const QB_PRICING_MAX_RETIRED_KEYS: usize = 4096;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct QbCompactTier {
    pub threshold_prompt_tokens: u64,
    pub includes_threshold: u8,
    pub input_per_million: f64, // NaN = absent
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
    pub tier_offset: u32, // index into the shared QbCompactTier array
}

pub struct PricingCompactResult {
    pub retrieved_at_offset: u32,
    pub retrieved_at_length: u32,
    pub entries: Vec<QbCompactEntry>,
    pub tiers: Vec<QbCompactTier>,
    pub retired_count: u32,
    pub retired_offset: u32, // first retired key in blob (count entries, contiguous)
    /// Whether the catalog contained a "retired" key at all (even an empty array). Swift treats
    /// presence, not non-emptiness, as authoritative (`file.retiredKeys != nil`).
    pub retired_present: u8,
    pub strings: Vec<u8>,
}

/// Optional cost field: None when absent, Some(None→NaN sentinel handled by caller), wrong-type → reject.
fn opt_f64(member: &Map<String, Value>, name: &str) -> Option<Option<f64>> {
    match member.get(name) {
        None => Some(None),
        Some(v) => v.as_f64().filter(|d| d.is_finite()).map(Some),
    }
}

fn parse_double(member: &Map<String, Value>, name: &str) -> Option<f64> {
    member
        .get(name)
        .and_then(|v| v.as_f64())
        .filter(|d| d.is_finite())
}

fn intern_entry(
    blob: &mut Vec<u8>,
    tiers_blob: &mut Vec<QbCompactTier>,
    key: &str,
    model: &Map<String, Value>,
) -> Option<QbCompactEntry> {
    let input = parse_double(model, "i")?;
    let output = parse_double(model, "o")?;
    let cw = parse_double(model, "cw")?;
    let cr = parse_double(model, "cr")?;
    // Foundation throws on a wrong-typed required or optional Double; so does this path.
    // In-range numbers pass through unchecked (the compact path never range-checks, like the
    // Swift reference decode).
    let cw1 = opt_f64(model, "cw1")?;
    let input_200k = opt_f64(model, "ia")?;
    let output_200k = opt_f64(model, "oa")?;
    let cw_200k = opt_f64(model, "cwa")?;
    let cr_200k = opt_f64(model, "cra")?;

    let legacy_cache_read_is_explicit = match model.get("cre") {
        None => 1,
        Some(v) => match v.as_bool() {
            Some(b) => u8::from(b),
            None => return None, // Foundation throws on a wrong-typed cre
        },
    };
    let cache_read_is_explicit = match model.get("crb") {
        None | Some(Value::Null) => legacy_cache_read_is_explicit,
        Some(v) => u8::from(v.as_bool()?),
    };
    let fast_multiplier = match model.get("fast") {
        None => 1.0,
        Some(v) => match v.as_f64().filter(|d| d.is_finite()) {
            Some(d) => d,
            None => return None, // Foundation throws on a wrong-typed fast
        },
    };

    let tiers_json = match model.get("tiers") {
        None => Vec::new(),
        Some(v) => match v.as_array() {
            Some(arr) => arr.clone(),
            None => return None, // Foundation throws on a non-array tiers
        },
    };
    if tiers_json.len() > QB_PRICING_MAX_TIERS_PER_ENTRY {
        return None;
    }

    let tier_offset = tiers_blob.len() as u32;
    for tier in &tiers_json {
        let Some(t) = tier.as_object() else {
            return None;
        };
        let threshold = match t.get("threshold_prompt_tokens").and_then(|v| v.as_u64()) {
            Some(v) => v,
            None => return None, // required (Swift's PromptRateTier throws on missing/wrong type)
        };
        let includes = match t.get("includes_threshold") {
            None => false,
            Some(v) => match v.as_bool() {
                Some(b) => b,
                None => return None, // Foundation throws on a wrong-typed includes_threshold
            },
        };
        let tier_opt = |name: &str| -> Option<Option<f64>> {
            match t.get(name) {
                None => Some(None),
                Some(v) => v.as_f64().filter(|d| d.is_finite()).map(Some),
            }
        };
        let input_t = tier_opt("input_per_million")?;
        let output_t = tier_opt("output_per_million")?;
        let cw_t = tier_opt("cache_write_per_million")?;
        let cr_t = tier_opt("cache_read_per_million")?;
        let cw1_t = tier_opt("cache_write_1h_per_million")?;
        tiers_blob.push(QbCompactTier {
            threshold_prompt_tokens: threshold,
            includes_threshold: u8::from(includes),
            input_per_million: input_t.unwrap_or(f64::NAN),
            output_per_million: output_t.unwrap_or(f64::NAN),
            cache_write_per_million: cw_t.unwrap_or(f64::NAN),
            cache_read_per_million: cr_t.unwrap_or(f64::NAN),
            cache_write_1h_per_million: cw1_t.unwrap_or(f64::NAN),
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
        input_above_200k_per_million: input_200k.unwrap_or(f64::NAN),
        output_above_200k_per_million: output_200k.unwrap_or(f64::NAN),
        cache_write_above_200k_per_million: cw_200k.unwrap_or(f64::NAN),
        cache_read_above_200k_per_million: cr_200k.unwrap_or(f64::NAN),
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

    let models = root.get("models").and_then(|v| v.as_object())?.clone();

    for (key, model) in &models {
        let Some(model) = model.as_object() else {
            return None;
        };
        entries.push(intern_entry(&mut strings, &mut tiers, key, model)?);
    }

    let (retrieved_at_offset, retrieved_at_length) = match root.get("retrieved_at") {
        None => (NIL_STRING, 0),
        Some(Value::String(s)) => {
            if s.is_empty() {
                (NIL_STRING, 0)
            } else if let Some(v) = intern(&mut strings, s) {
                v
            } else {
                return None;
            }
        }
        Some(_) => return None, // Foundation throws on a wrong-typed retrieved_at
    };

    let (retired_count, retired_offset, retired_present) = match root.get("retired") {
        None => (0, 0, 0),
        Some(Value::Array(arr)) => {
            // Strings are u32-addressed by the C ABI; a >4 GiB blob cannot arise here
            // (snapshots are ~1 MB, the disk cache ~8 MB), so the cast is unrepresentable input,
            // never a silent truncation.
            if strings.len() as u64 > u64::from(u32::MAX) {
                return None;
            }
            if arr.len() > QB_PRICING_MAX_RETIRED_KEYS {
                return None;
            }
            if arr.is_empty() {
                (0, 0, 1)
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
                (arr.len() as u32, off, 1)
            }
        }
        Some(_) => return None, // Foundation throws on a wrong-typed retired
    };

    Some(PricingCompactResult {
        retrieved_at_offset,
        retrieved_at_length,
        entries,
        tiers,
        retired_count,
        retired_offset,
        retired_present,
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
    parse_compact_catalog(bytes)
        .map(|r| Box::into_raw(Box::new(r)))
        .unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn qb_pricing_compact_catalog_entry_count(
    result: *const PricingCompactResult,
) -> u32 {
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
pub extern "C" fn qb_pricing_compact_catalog_tier_count(
    result: *const PricingCompactResult,
) -> u32 {
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
pub extern "C" fn qb_pricing_compact_catalog_retrieved_at_offset(
    result: *const PricingCompactResult,
) -> u32 {
    unsafe {
        result
            .as_ref()
            .map(|r| r.retrieved_at_offset)
            .unwrap_or(NIL_STRING)
    }
}

#[no_mangle]
pub extern "C" fn qb_pricing_compact_catalog_retrieved_at_length(
    result: *const PricingCompactResult,
) -> u32 {
    unsafe { result.as_ref().map(|r| r.retrieved_at_length).unwrap_or(0) }
}

#[no_mangle]
pub extern "C" fn qb_pricing_compact_catalog_retired_count(
    result: *const PricingCompactResult,
) -> u32 {
    unsafe { result.as_ref().map(|r| r.retired_count).unwrap_or(0) }
}

/// 1 when the catalog contained a "retired" key at all (even an empty array); 0 otherwise.
/// Swift treats presence as authoritative, matching the Swift decode path (`retiredKeys != nil`).
#[no_mangle]
pub extern "C" fn qb_pricing_compact_catalog_retired_present(
    result: *const PricingCompactResult,
) -> u8 {
    unsafe { result.as_ref().map(|r| r.retired_present).unwrap_or(0) }
}

/// Offset of the first retired-key record in the string blob ([u32le length][bytes]*, count
/// from qb_pricing_compact_catalog_retired_count). Keys are stored in catalog order, not sorted.
#[no_mangle]
pub extern "C" fn qb_pricing_compact_catalog_retired_offset(
    result: *const PricingCompactResult,
) -> u32 {
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
        for name in [
            "pricing_litellm_snapshot.json",
            "pricing_models_dev_snapshot.json",
        ] {
            let path = format!(
                "{}/../../Sources/QuotaBar/Resources/{name}",
                env!("CARGO_MANIFEST_DIR")
            );
            let bytes = std::fs::read(path).unwrap();
            let parsed = parse_compact_catalog(&bytes).unwrap();
            assert!(!parsed.entries.is_empty());
            assert!(parsed
                .entries
                .iter()
                .all(|e| e.input_per_million.is_finite() && e.output_per_million.is_finite()));
        }
    }
}
