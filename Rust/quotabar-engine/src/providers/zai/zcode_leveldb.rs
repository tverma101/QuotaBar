//! Reads ZCode's Chromium/Electron LevelDB entitlement snapshots (`ZCodeUsageScanner.swift`).
//!
//! Scans `.log` and `.ldb` files under `~/Library/Application Support/ZCode/session/Local Storage/leveldb`
//! for `zcode:usage-entitlement:subscription-v2:account:` JSON values and keeps the entry with the
//! highest `cachedAt` timestamp.

use super::mapper::MAXIMUM_RESET_HORIZON_SECS;
use crate::parse;
use crate::time::parse_iso8601;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::{BTreeMap, HashSet};
use std::path::PathBuf;

const ENTITLEMENT_KEY_PREFIX: &[u8] = b"zcode:usage-entitlement:subscription-v2:account:";
const ENTITLEMENT_JSON_MARKER: &[u8] = b"\"cachedAt\"";
const ENTITLEMENT_VALUE_SEARCH_WINDOW: usize = 512;
const MAX_ENTITLEMENT_JSON_BYTES: usize = 25_000;
const DEFAULT_PROMO_LIMIT: f64 = 500_000_000.0;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ZCodeAllowance {
    pub label: String,
    pub used: f64,
    pub limit: f64,
    pub remaining: f64,
    pub resets_at: Option<f64>,
    pub expires_at: Option<f64>,
    pub effective_at: Option<f64>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ZCodeEntitlementSnapshot {
    pub plan_name: Option<String>,
    pub weekend_build: Option<ZCodeAllowance>,
}

#[derive(Clone, Debug)]
pub struct LevelDBFile {
    pub path: PathBuf,
    pub modified_ns: i64,
    pub size: u64,
}

#[derive(Clone, Debug)]
struct PromoInfo {
    product_id: String,
    label: String,
    effective_at: Option<f64>,
    expires_at: Option<f64>,
}

/// Scan every `.log`/`.ldb` file in `files`, pick the entitlement snapshot with the highest
/// `cachedAt`, and select the active/scheduled promotional allowance relative to `now`.
pub fn scan_leveldb_entitlement(files: &[LevelDBFile], now: Option<f64>) -> Option<ZCodeEntitlementSnapshot> {
    let mut sorted: Vec<&LevelDBFile> = files.iter().collect();
    sorted.sort_by(|a, b| b.modified_ns.cmp(&a.modified_ns));

    let mut best_snapshot: Option<Map<String, Value>> = None;
    let mut best_cached_at: f64 = -1.0;

    for file in sorted {
        let Ok(bytes) = std::fs::read(&file.path) else { continue };
        let mut search_from = 0usize;
        while search_from < bytes.len() {
            let Some(rel) = find_subslice(&bytes[search_from..], ENTITLEMENT_KEY_PREFIX) else {
                break;
            };
            let scan_from = search_from + rel + ENTITLEMENT_KEY_PREFIX.len();
            let window_end = (scan_from + ENTITLEMENT_VALUE_SEARCH_WINDOW).min(bytes.len());
            let Some(marker_rel) = find_subslice(&bytes[scan_from..window_end], ENTITLEMENT_JSON_MARKER) else {
                search_from = scan_from;
                continue;
            };
            let marker_pos = scan_from + marker_rel;
            let mut pos = marker_pos;
            while pos > scan_from {
                pos -= 1;
                if bytes[pos] != b'{' {
                    continue;
                }
                if let Some((root, cached_at)) = parse_entitlement_snapshot(&bytes, pos) {
                    if cached_at > best_cached_at {
                        best_cached_at = cached_at;
                        best_snapshot = Some(root);
                    }
                    break;
                }
            }
            search_from = marker_pos + ENTITLEMENT_JSON_MARKER.len();
        }
    }

    let snapshot = best_snapshot?;
    entitlement_from_root(&snapshot, now)
}

fn parse_entitlement_snapshot(bytes: &[u8], brace_start: usize) -> Option<(Map<String, Value>, f64)> {
    let mut depth = 0usize;
    let mut json_end = brace_start;
    let limit = bytes.len().min(brace_start + MAX_ENTITLEMENT_JSON_BYTES);
    for (idx, &byte) in bytes.iter().enumerate().take(limit).skip(brace_start) {
        if byte == b'{' {
            depth += 1;
        } else if byte == b'}' {
            depth -= 1;
            if depth == 0 {
                json_end = idx + 1;
                break;
            }
        }
    }
    if depth != 0 || json_end <= brace_start {
        return None;
    }
    let Value::Object(root) = serde_json::from_slice::<Value>(&bytes[brace_start..json_end]).ok()? else {
        return None;
    };
    let cached_at = parse::number(root.get("cachedAt"))?;
    Some((root, cached_at))
}

fn entitlement_from_root(root: &Map<String, Value>, now: Option<f64>) -> Option<ZCodeEntitlementSnapshot> {
    let snapshot = root.get("snapshot")?.as_object()?;
    let plan_name = snapshot
        .get("quota")
        .and_then(Value::as_object)
        .and_then(|q| q.get("level"))
        .and_then(Value::as_str)
        .map(format_plan_name);

    let mut promos: BTreeMap<String, PromoInfo> = BTreeMap::new();
    let mut expiry_by_product_id: BTreeMap<String, f64> = BTreeMap::new();

    if let Some(details) = snapshot
        .get("subscription")
        .and_then(Value::as_object)
        .and_then(|s| s.get("details"))
        .and_then(Value::as_array)
    {
        for raw in details {
            let Some(detail) = raw.as_object() else { continue };
            let Some(product_id) = detail.get("productId").and_then(Value::as_str) else {
                continue;
            };
            let expire = detail.get("expireTime").and_then(Value::as_str).and_then(parse_iso8601);
            if let Some(exp) = expire {
                expiry_by_product_id.insert(product_id.to_string(), exp);
            }
            let billing_cycle = detail.get("billingCycle").and_then(Value::as_str).unwrap_or("");
            let raw_name = detail.get("productName").and_then(Value::as_str).unwrap_or("");
            let is_one_time = billing_cycle == "one_time";
            let is_build = product_id.contains("build")
                || product_id.ends_with("wk")
                || product_id.contains("-wk")
                || contains_ascii_ci(raw_name, "build");
            if !is_one_time && !is_build {
                continue;
            }
            let mut effective_at = detail
                .get("beginTime")
                .and_then(Value::as_str)
                .and_then(parse_iso8601);
            if let Some(entitlements) = detail.get("entitlements").and_then(Value::as_array) {
                for ent in entitlements.iter().filter_map(Value::as_object) {
                    if let Some(d) = ent.get("effectiveTime").and_then(Value::as_str).and_then(parse_iso8601) {
                        effective_at = Some(d);
                        break;
                    }
                }
            }
            let label = promo_label(raw_name);
            promos.insert(
                product_id.to_string(),
                PromoInfo {
                    product_id: product_id.to_string(),
                    label,
                    effective_at,
                    expires_at: expire,
                },
            );
        }
    }

    let mut allowances: Vec<ZCodeAllowance> = Vec::new();
    let mut seen_plan_ids: HashSet<String> = HashSet::new();

    if let Some(limits) = snapshot
        .get("quota")
        .and_then(Value::as_object)
        .and_then(|q| q.get("limits"))
        .and_then(Value::as_array)
    {
        for raw in limits {
            let Some(limit) = raw.as_object() else { continue };
            let plan_id = limit.get("planId").and_then(Value::as_str).unwrap_or("");
            let is_one_time = limit.get("period").and_then(Value::as_str) == Some("one_time");
            let is_weekly_plan = plan_id.ends_with("wk") || plan_id.contains("-wk");
            if !(is_weekly_plan || plan_id.contains("build") || is_one_time || promos.contains_key(plan_id)) {
                continue;
            }
            let unit = parse::number(limit.get("unit")).unwrap_or(0.0);
            if unit <= 0.0 {
                continue;
            }
            seen_plan_ids.insert(plan_id.to_string());
            let used = parse::number(limit.get("usage")).unwrap_or(0.0);
            let remaining = parse::number(limit.get("remaining")).unwrap_or(0.0);
            let mut reset_ms = parse::number(limit.get("nextResetTime"));
            let promo = promos.get(plan_id);
            let mut expires_at = promo
                .and_then(|p| p.expires_at)
                .or_else(|| expiry_by_product_id.get(plan_id).copied());
            if is_one_time {
                if expires_at.is_none() {
                    if let Some(ms) = reset_ms {
                        expires_at = plausible_reset_date(ms, now);
                    }
                }
                reset_ms = None;
            }
            allowances.push(ZCodeAllowance {
                label: promo.map(|p| p.label.clone()).unwrap_or_else(|| "Weekend Build".to_string()),
                used,
                limit: unit,
                remaining,
                resets_at: reset_ms.and_then(|ms| plausible_reset_date(ms, now)),
                expires_at,
                effective_at: promo.and_then(|p| p.effective_at),
            });
        }
    }

    let mut sorted_promos: Vec<&PromoInfo> = promos.values().collect();
    sorted_promos.sort_by(|a, b| {
        let a_eff = a.effective_at.unwrap_or(f64::INFINITY);
        let b_eff = b.effective_at.unwrap_or(f64::INFINITY);
        a_eff.total_cmp(&b_eff).then_with(|| a.product_id.cmp(&b.product_id))
    });
    for promo in sorted_promos {
        if !seen_plan_ids.contains(&promo.product_id) {
            allowances.push(ZCodeAllowance {
                label: promo.label.clone(),
                used: 0.0,
                limit: DEFAULT_PROMO_LIMIT,
                remaining: DEFAULT_PROMO_LIMIT,
                resets_at: None,
                expires_at: promo.expires_at,
                effective_at: promo.effective_at,
            });
        }
    }

    let candidates: Vec<&ZCodeAllowance> = allowances
        .iter()
        .filter(|allow| match (now, allow.expires_at) {
            (Some(n), Some(exp)) => exp > n,
            _ => true,
        })
        .collect();
    let active_with_remaining = candidates
        .iter()
        .copied()
        .find(|a| a.effective_at.is_none_or(|e| now.is_some_and(|n| e <= n) || now.is_none()) && a.remaining > 0.0);
    let active_drained = candidates
        .iter()
        .copied()
        .find(|a| a.effective_at.is_none_or(|e| now.is_some_and(|n| e <= n) || now.is_none()) && a.remaining == 0.0);
    let scheduled = candidates
        .iter()
        .copied()
        .find(|a| a.effective_at.is_some_and(|e| now.is_some_and(|n| e > n)));
    let selected = active_with_remaining
        .or(active_drained)
        .or(scheduled)
        .or_else(|| if now.is_none() { allowances.first() } else { None })
        .cloned();

    Some(ZCodeEntitlementSnapshot {
        plan_name,
        weekend_build: selected,
    })
}

fn format_plan_name(level: &str) -> String {
    match level {
        "Start" => "Start Plan".to_string(),
        "Coding" => "Coding Plan".to_string(),
        other => format!("{} Plan", capitalize_words(other)),
    }
}

fn promo_label(raw_name: &str) -> String {
    if contains_ascii_ci(raw_name, "Global Build") {
        return "Global Build".to_string();
    }
    if contains_ascii_ci(raw_name, "Weekend Build") {
        return "Weekend Build".to_string();
    }
    if !raw_name.is_empty() {
        let stripped = raw_name
            .strip_prefix("ZCODE ")
            .or_else(|| raw_name.strip_prefix("zcode "))
            .unwrap_or(raw_name);
        let titled = capitalize_words(stripped);
        if !titled.is_empty() {
            return titled;
        }
    }
    "Weekend Build".to_string()
}

fn capitalize_words(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut new_word = true;
    for ch in s.chars() {
        if !ch.is_alphanumeric() {
            new_word = true;
            out.push(ch);
        } else if new_word {
            for upper in ch.to_uppercase() {
                out.push(upper);
            }
            new_word = false;
        } else {
            for lower in ch.to_lowercase() {
                out.push(lower);
            }
        }
    }
    out
}

fn contains_ascii_ci(haystack: &str, needle: &str) -> bool {
    haystack.to_ascii_lowercase().contains(&needle.to_ascii_lowercase())
}

fn plausible_reset_date(milliseconds: f64, now: Option<f64>) -> Option<f64> {
    if milliseconds <= 0.0 || !milliseconds.is_finite() {
        return None;
    }
    let date = milliseconds / 1000.0;
    let Some(now) = now else {
        return Some(date);
    };
    if date > now && (date - now) <= MAXIMUM_RESET_HORIZON_SECS {
        Some(date)
    } else {
        None
    }
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}
