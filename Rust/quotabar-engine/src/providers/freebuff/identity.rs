//! Receipt provenance determines whether a Fast-tier name and price can be used
//! (`FreebuffModelIdentity.swift`). Modes can share a model row while keeping their own measured
//! tokens and public-rate estimates in its variants.

use super::catalog::{fast_base_name, group_name, pricing_routes, Entry};
use super::flash;
use crate::pricing::ModelPricing;
use std::collections::{BTreeSet, HashMap};

pub const OLDER_USAGE_NAME: &str = "Older Freebuff Usage";
const CURATED_FAST_ROUTE: &str = "deepseek-v4.1-flash-fast";

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Resolved {
    pub route: Option<String>,
    pub display_name: Option<String>,
    pub group: Option<String>,
    /// The raw text looks Fast but nothing identifies it — report unknown, not named-unpriced.
    pub has_unknown_route: bool,
}

#[derive(Clone, Default)]
pub struct FreebuffModelIdentity {
    entries: HashMap<String, Entry>,
    routes: HashMap<String, String>,
    legacy_entries: HashMap<String, Entry>,
    route_names: HashMap<String, String>,
    memo: HashMap<(String, bool), Resolved>,
}

impl FreebuffModelIdentity {
    pub fn new(entries: &HashMap<String, Entry>, pricing: &ModelPricing) -> Self {
        let routes = pricing_routes(entries, pricing);
        let mut legacy_pairs: HashMap<String, Vec<&Entry>> = HashMap::new();
        for entry in entries.values() {
            for digest in entry.legacy_digests.iter().flatten() {
                legacy_pairs.entry(digest.clone()).or_default().push(entry);
            }
        }
        // A collision must not pick an arbitrary model (or its price).
        let legacy_entries = legacy_pairs
            .into_iter()
            .filter_map(|(digest, pairs)| {
                let keys: BTreeSet<&str> = pairs.iter().map(|e| e.key.as_str()).collect();
                (keys.len() == 1).then(|| (digest, pairs[0].clone()))
            })
            .collect();
        let mut by_route: HashMap<&String, Vec<&String>> = HashMap::new();
        for (key, route) in &routes {
            by_route.entry(route).or_default().push(key);
        }
        let route_names = by_route
            .into_iter()
            .filter_map(|(route, keys)| {
                let names: BTreeSet<&str> = keys.iter().filter_map(|k| entries.get(*k)).map(|e| e.display_name.as_str()).collect();
                // Multiple opaque keys with the same display name still name one model. Distinct
                // catalogue names on one price route do not prove an identity.
                (names.len() == 1).then(|| (route.clone(), names.into_iter().next().unwrap_or_default().to_string()))
            })
            .collect();
        FreebuffModelIdentity { entries: entries.clone(), routes, legacy_entries, route_names, memo: HashMap::new() }
    }

    pub fn resolve(&mut self, model: &str, pricing: &ModelPricing, from_receipt: bool) -> Resolved {
        let key = (model.to_string(), from_receipt);
        if let Some(cached) = self.memo.get(&key) {
            return cached.clone();
        }
        let resolved = self.compute(model, pricing, from_receipt);
        if self.memo.len() < 4_096 {
            self.memo.insert(key, resolved.clone());
        }
        resolved
    }

    fn compute(&self, model: &str, pricing: &ModelPricing, from_receipt: bool) -> Resolved {
        // A display label, opaque key, or saved selection cannot prove a serving tier.
        let entry = self.entries.get(model).or_else(|| self.legacy_entries.get(&legacy_digest(model)));
        let exact = exact_route(model, pricing);
        let entry_base = if exact.is_none() || !from_receipt {
            entry.and_then(|e| fast_base_name(&e.display_name))
        } else {
            None
        };
        if let Some(base) = entry_base.or_else(|| fast_base_name(model)) {
            let (name, route) = if let (true, Some(exact), true) = (from_receipt, exact.as_ref(), fast_base_name(model).is_some()) {
                let name = if is_deepseek_flash_fast_route(model) {
                    "DeepSeek V4.1 Flash Fast (Recorded Route)".to_string()
                } else {
                    format!("{model} (Recorded Route)")
                };
                (name, Some(exact.clone()))
            } else if is_deepseek_flash_fast_route(model) || is_deepseek_flash_base_name(&base) {
                ("DeepSeek V4.1 Flash (Standard Rate Assumed)".to_string(), Some(flash::ROUTE.to_string()))
            } else {
                let model_name = if is_deepseek_flash_fast_route(model) { "DeepSeek V4.1 Flash" } else { base.as_str() };
                (format!("{model_name} (Route Unverified)"), None)
            };
            return Resolved {
                route,
                display_name: Some(name.clone()),
                group: Some(name),
                has_unknown_route: entry.is_none()
                    && exact.is_none()
                    && !is_deepseek_flash_fast_route(model)
                    && !is_deepseek_flash_base_name(&base),
            };
        }
        let route = exact.or_else(|| {
            entry.and_then(|entry| match self.routes.get(&entry.key) {
                Some(route) => Some(route.clone()),
                None => match group_name(&entry.display_name).to_lowercase().as_str() {
                    "deepseek v4.1 flash" => Some(flash::ROUTE.to_string()),
                    _ => None,
                },
            })
        });
        let display_name = entry
            .and_then(|e| fast_base_name(&e.display_name).is_none().then(|| e.display_name.clone()))
            .or_else(|| route.as_ref().and_then(|r| self.route_names.get(r).cloned()));
        let group = display_name.as_deref().map(group_name);
        Resolved { route, display_name, group, has_unknown_route: false }
    }
}

fn is_deepseek_flash_fast_route(name: &str) -> bool {
    name == CURATED_FAST_ROUTE || name == format!("deepseek/{CURATED_FAST_ROUTE}")
}

/// The one family whose Fast label QuotaBar treats as the standard tier by owner decision.
fn is_deepseek_flash_base_name(name: &str) -> bool {
    matches!(
        name.to_lowercase().as_str(),
        "deepseek v4.1 flash" | "deepseek-v4.1-flash" | "deepseek/deepseek-v4.1-flash"
    )
}

fn exact_route(model: &str, pricing: &ModelPricing) -> Option<String> {
    if pricing.open_router.entries.contains_key(model) || pricing.supplement.pricing.contains_key(model) {
        return Some(model.to_string());
    }
    if is_deepseek_flash_fast_route(model) && pricing.supplement.pricing.contains_key(CURATED_FAST_ROUTE) {
        return Some(CURATED_FAST_ROUTE.to_string());
    }
    flash::matches_route(model).then(|| model.to_string())
}

/// Matches `freebuffLegacyModelDigest` in Freebuff's common/types/freebuff-model-catalog.ts: two
/// unsigned FNV-style accumulators over JavaScript UTF-16 code units, not UTF-8 bytes.
pub fn legacy_digest(model: &str) -> String {
    let mut first: u32 = 0x811c_9dc5;
    let mut second: u32 = 0x0100_0193 ^ 0x5bd1_e995;
    for unit in format!("freebuff-legacy-model:{model}").encode_utf16() {
        first = (first ^ u32::from(unit)).wrapping_mul(0x0100_0193);
        second = (second ^ u32::from(unit)).wrapping_mul(0x5bd1_e995);
    }
    format!("{first:08x}{second:08x}")
}
