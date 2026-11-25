//! Freebuff model identity (`FreebuffModelIdentity` + `FreebuffModelCatalog.pricingRoutes`).
//!
//! Receipt provenance decides whether a Fast-tier name and price can be used. Pricing routes come
//! only from exact normalized names and explicit supplement aliases; every version and variant word
//! is preserved, ambiguous routes stay unpriced, and opaque keys are never guessed.

use super::catalog::{CatalogEntries, CatalogEntry};
use super::flash;
use crate::pricing::ModelPricing;
use regex_lite::Regex;
use std::collections::{HashMap, HashSet};
use std::sync::OnceLock;

const CURATED_FAST_ROUTE: &str = "deepseek-v4.1-flash-fast";
const ASSUMED_STANDARD: &str = "DeepSeek V4.1 Flash (Standard Rate Assumed)";
const MEMO_LIMIT: usize = 4_096;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Resolved {
    pub route: Option<String>,
    pub display_name: Option<String>,
    pub group: Option<String>,
    /// The raw text looks Fast but nothing identifies it: report unknown, not named-unpriced.
    pub has_unknown_route: bool,
}

pub struct ModelIdentity<'a> {
    entries: &'a CatalogEntries,
    pricing: &'a ModelPricing,
    routes: HashMap<String, String>,
    /// Legacy digest -> catalogue key, only where one key claims the digest.
    legacy_keys: HashMap<String, String>,
    route_names: HashMap<String, String>,
    memo: HashMap<(String, bool), Resolved>,
}

impl<'a> ModelIdentity<'a> {
    pub fn new(entries: &'a CatalogEntries, pricing: &'a ModelPricing) -> Self {
        let routes = pricing_routes(entries, pricing);
        let mut claims: HashMap<&str, HashSet<&str>> = HashMap::new();
        for entry in entries.values() {
            for digest in entry.legacy_digests.iter().flatten() {
                claims.entry(digest).or_default().insert(&entry.key);
            }
        }
        // A collision must not pick an arbitrary model (or its price).
        let legacy_keys = claims
            .into_iter()
            .filter(|(_, keys)| keys.len() == 1)
            .filter_map(|(digest, keys)| {
                Some((digest.to_string(), keys.into_iter().next()?.to_string()))
            })
            .collect();
        let mut names_by_route: HashMap<&str, HashSet<&str>> = HashMap::new();
        for (key, route) in &routes {
            let names = names_by_route.entry(route).or_default();
            if let Some(entry) = entries.get(key) {
                names.insert(&entry.display_name);
            }
        }
        // Several opaque keys with one display name still name one model; distinct catalogue
        // names on one price route do not prove an identity.
        let route_names = names_by_route
            .into_iter()
            .filter(|(_, names)| names.len() == 1)
            .filter_map(|(route, names)| {
                Some((route.to_string(), names.into_iter().next()?.to_string()))
            })
            .collect();
        ModelIdentity {
            entries,
            pricing,
            routes,
            legacy_keys,
            route_names,
            memo: HashMap::new(),
        }
    }

    pub fn resolve(&mut self, model: &str, from_receipt: bool) -> Resolved {
        let key = (model.to_string(), from_receipt);
        if let Some(cached) = self.memo.get(&key) {
            return cached.clone();
        }
        let resolved = self.resolve_uncached(model, from_receipt);
        if self.memo.len() < MEMO_LIMIT {
            self.memo.insert(key, resolved.clone());
        }
        resolved
    }

    fn entry(&self, model: &str) -> Option<&'a CatalogEntry> {
        let entries = self.entries;
        entries.get(model).or_else(|| {
            self.legacy_keys
                .get(&legacy_digest(model))
                .and_then(|key| entries.get(key))
        })
    }

    fn resolve_uncached(&self, model: &str, from_receipt: bool) -> Resolved {
        // A display label, opaque key, or saved selection cannot prove a serving tier.
        let entry = self.entry(model);
        let exact = exact_route(model, self.pricing);
        let entry_base = if exact.is_none() || !from_receipt {
            entry.and_then(|entry| fast_base_name(&entry.display_name))
        } else {
            None
        };
        if let Some(base) = entry_base.or_else(|| fast_base_name(model)) {
            let flash_fast = is_flash_fast_route(model);
            let (name, route) =
                if from_receipt && exact.is_some() && fast_base_name(model).is_some() {
                    let name = if flash_fast {
                        "DeepSeek V4.1 Flash Fast (Recorded Route)".to_string()
                    } else {
                        format!("{model} (Recorded Route)")
                    };
                    (name, exact.clone())
                } else if flash_fast || is_flash_base_name(&base) {
                    (ASSUMED_STANDARD.to_string(), Some(flash::ROUTE.to_string()))
                } else {
                    (format!("{base} (Route Unverified)"), None)
                };
            return Resolved {
                route,
                display_name: Some(name.clone()),
                group: Some(name),
                has_unknown_route: entry.is_none()
                    && exact.is_none()
                    && !flash_fast
                    && !is_flash_base_name(&base),
            };
        }
        let route = exact.or_else(|| {
            let entry = entry?;
            self.routes.get(&entry.key).cloned().or_else(|| {
                (group_name(&entry.display_name).to_lowercase() == "deepseek v4.1 flash")
                    .then(|| flash::ROUTE.to_string())
            })
        });
        let display_name = entry
            .filter(|entry| fast_base_name(&entry.display_name).is_none())
            .map(|entry| entry.display_name.clone())
            .or_else(|| {
                route
                    .as_ref()
                    .and_then(|route| self.route_names.get(route).cloned())
            });
        Resolved {
            route,
            group: display_name.as_deref().map(group_name),
            display_name,
            has_unknown_route: false,
        }
    }
}

fn is_flash_fast_route(name: &str) -> bool {
    name == CURATED_FAST_ROUTE || name.strip_prefix("deepseek/") == Some(CURATED_FAST_ROUTE)
}

/// The one family whose Fast label QuotaBar treats as the standard tier, by owner decision.
fn is_flash_base_name(name: &str) -> bool {
    matches!(
        name.to_lowercase().as_str(),
        "deepseek v4.1 flash" | "deepseek-v4.1-flash" | "deepseek/deepseek-v4.1-flash"
    )
}

fn exact_route(model: &str, pricing: &ModelPricing) -> Option<String> {
    if pricing.open_router.entries.contains_key(model)
        || pricing.supplement.pricing.contains_key(model)
    {
        return Some(model.to_string());
    }
    if is_flash_fast_route(model) && pricing.supplement.pricing.contains_key(CURATED_FAST_ROUTE) {
        return Some(CURATED_FAST_ROUTE.to_string());
    }
    flash::matches_route(model).then(|| model.to_string())
}

/// Catalogue key -> pricing route.
fn pricing_routes(entries: &CatalogEntries, pricing: &ModelPricing) -> HashMap<String, String> {
    let mut index: HashMap<String, Vec<&str>> = HashMap::new();
    for route in pricing.open_router.entries.keys() {
        if !route.contains('/') {
            continue;
        }
        let last = route
            .split('/')
            .rfind(|part| !part.is_empty())
            .unwrap_or(route);
        index.entry(normalized(last)).or_default().push(route);
    }
    let mut routes: HashMap<String, String> = HashMap::new();
    for (key, entry) in entries {
        if fast_base_name(&entry.display_name).is_some() {
            continue;
        }
        if let Some([only]) = index
            .get(&normalized(&entry.display_name))
            .map(Vec::as_slice)
        {
            if fast_base_name(only).is_none() {
                routes.insert(key.clone(), only.to_string());
            }
        }
    }
    // Curated fallback aliases do not prove a Fast serving route either.
    for (key, entry) in entries {
        if routes.contains_key(key) || fast_base_name(&entry.display_name).is_some() {
            continue;
        }
        let Some(canonical) = pricing.supplement.canonical_name(&entry.display_name) else {
            continue;
        };
        if fast_base_name(&canonical).is_none()
            && pricing.supplement.pricing.contains_key(&canonical)
        {
            routes.insert(key.clone(), canonical);
        }
    }
    routes
}

fn regex(slot: &'static OnceLock<Regex>, pattern: &str) -> &'static Regex {
    slot.get_or_init(|| Regex::new(pattern).expect("static Freebuff pattern"))
}

/// Recognizes a tier suffix, not words like Flash or FastAPI. Some labels end in a build date.
pub fn fast_base_name(name: &str) -> Option<String> {
    static FAST: OnceLock<Regex> = OnceLock::new();
    let trimmed = name.trim();
    let found = regex(
        &FAST,
        r"(?i)[\s_-]+fast(?:[\s_-]+(?:\d{1,2}/\d{1,2}|\d{4}))?$",
    )
    .find(trimmed)?;
    Some(trimmed[..found.start()].to_string())
}

/// Freebuff labels one Haiku route with an extra "100k context" descriptor. That is a context
/// annotation, not a distinct route; aggregated turn receipts cannot apply per-request context
/// tiers, so it routes to the exact base entry.
fn normalized(name: &str) -> String {
    static CONTEXT: OnceLock<Regex> = OnceLock::new();
    let route_name = regex(&CONTEXT, r"(?i)\s*(?:[·•]\s*)?100k\s+context$").replace_all(name, "");
    let lower: Vec<char> = route_name.to_lowercase().chars().collect();
    let mut out = String::with_capacity(lower.len());
    for (index, &character) in lower.iter().enumerate() {
        // `\bv(?=\d)`: a version prefix, as in "v4.1".
        let at_boundary = index == 0 || {
            let prior = lower[index - 1];
            !(prior.is_alphanumeric() || prior == '_')
        };
        if character == 'v' && at_boundary && lower.get(index + 1).is_some_and(char::is_ascii_digit)
        {
            continue;
        }
        if character.is_alphanumeric() {
            out.push(character);
        }
    }
    out
}

/// Catalogue labels keep real model versions, but mode, build, and context annotations need not
/// repeat a model in the compact breakdown. Full source labels survive as accounting variants.
pub fn group_name(name: &str) -> String {
    static CONTEXT: OnceLock<Regex> = OnceLock::new();
    static BUILD: OnceLock<Regex> = OnceLock::new();
    static MODE: OnceLock<Regex> = OnceLock::new();
    let name = regex(&CONTEXT, r"(?i)\s*(?:[·•]\s*)?\d+k\s+context$").replace_all(name, "");
    let name = regex(&BUILD, r"\s+\d{1,2}/\d{1,2}$").replace_all(&name, "");
    let name = regex(&MODE, r"(?i)\s+(?:Fast|Slow)$").replace_all(&name, "");
    name.trim().to_string()
}

/// Matches `freebuffLegacyModelDigest` in Freebuff's common/types/freebuff-model-catalog.ts: two
/// unsigned FNV-style accumulators over JavaScript UTF-16 code units, not UTF-8 bytes.
pub fn legacy_digest(model: &str) -> String {
    let mut first: u32 = 0x811c_9dc5;
    let mut second: u32 = 0x0100_0193 ^ 0x5bd1_e995;
    for unit in "freebuff-legacy-model:"
        .encode_utf16()
        .chain(model.encode_utf16())
    {
        first = (first ^ u32::from(unit)).wrapping_mul(0x0100_0193);
        second = (second ^ u32::from(unit)).wrapping_mul(0x5bd1_e995);
    }
    format!("{first:08x}{second:08x}")
}

#[cfg(test)]
#[path = "identity_tests.rs"]
mod tests;
