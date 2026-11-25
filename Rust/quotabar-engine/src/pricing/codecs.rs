//! Parsers for the three public pricing feeds plus the compact catalog format used for the bundled
//! snapshots and on-disk caches (Swift `PricingCatalogCodecs.swift`). Feeds are parsed through
//! `serde_json::Value` so one malformed entry cannot sink the whole feed.

use super::catalog::PricingCatalog;
use super::rates::{ModelRates, PromptRateTier, UtcPriceRateOverride};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::{BTreeMap, HashMap, HashSet};

#[derive(Debug, PartialEq, Eq)]
pub enum CodecError {
    NotAnObject,
    NoUsableEntries,
    IncompleteModelList,
}

impl std::fmt::Display for CodecError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            CodecError::NotAnObject => "Pricing feed is not a JSON object.",
            CodecError::NoUsableEntries => "Pricing feed contained no usable model entries.",
            CodecError::IncompleteModelList => {
                "OpenRouter returned a paginated or incomplete model list."
            }
        })
    }
}

/// No real model rate approaches this; an absurd feed value would otherwise overflow a token product.
const MAX_PER_MILLION: f64 = 1_000_000_000.0;

fn number(value: Option<&Value>) -> Option<f64> {
    match value? {
        Value::Number(n) => n.as_f64(),
        _ => None,
    }
}

fn valid_per_million(value: Option<&Value>) -> Option<f64> {
    number(value).filter(|r| r.is_finite() && *r >= 0.0 && *r <= MAX_PER_MILLION)
}

fn per_million_from_per_token(value: Option<&Value>) -> Option<f64> {
    number(value)
        .filter(|r| r.is_finite() && *r >= 0.0 && *r <= MAX_PER_MILLION / 1_000_000.0)
        .map(|r| r * 1_000_000.0)
}

/// OpenRouter writes per-token prices as decimal strings.
fn nonnegative_finite(value: Option<&Value>) -> Option<f64> {
    let parsed = match value? {
        Value::String(s) => s.parse::<f64>().ok()?,
        Value::Number(n) => n.as_f64()?,
        _ => return None,
    };
    (parsed.is_finite() && parsed >= 0.0).then_some(parsed)
}

fn open_router_rate(value: Option<&Value>) -> Option<f64> {
    nonnegative_finite(value)
        .filter(|r| *r <= f64::MAX / 1_000_000.0)
        .map(|r| r * 1_000_000.0)
}

pub(crate) fn integer(value: Option<&Value>) -> Option<i64> {
    let v = number(value)?;
    (v.is_finite() && v >= 0.0 && v.trunc() == v && v < i64::MAX as f64).then_some(v as i64)
}

/// Swift `as? [[String: Any]]`: every element must be an object or the whole cast fails.
fn object_array(value: Option<&Value>) -> Option<Vec<&Map<String, Value>>> {
    value?.as_array()?.iter().map(Value::as_object).collect()
}

// MARK: - OpenRouter

pub struct OpenRouterPage {
    pub models: Vec<Value>,
    pub total_count: i64,
    pub next_offset: Option<i64>,
}

pub fn open_router_page(data: &[u8]) -> Result<OpenRouterPage, CodecError> {
    let root: Value = serde_json::from_slice(data).map_err(|_| CodecError::IncompleteModelList)?;
    let models = root
        .get("data")
        .and_then(Value::as_array)
        .filter(|m| m.iter().all(Value::is_object));
    let total = integer(root.get("total_count"));
    let next = root
        .get("links")
        .and_then(Value::as_object)
        .and_then(|l| l.get("next"));
    let (Some(models), Some(total_count), Some(next)) = (models, total, next) else {
        return Err(CodecError::IncompleteModelList);
    };
    let next_offset = match next {
        Value::Null => None,
        Value::String(url) => Some(offset_query(url).ok_or(CodecError::IncompleteModelList)?),
        _ => return Err(CodecError::IncompleteModelList),
    };
    Ok(OpenRouterPage {
        models: models.clone(),
        total_count,
        next_offset,
    })
}

fn offset_query(url: &str) -> Option<i64> {
    let query = url.split_once('?')?.1.split('#').next()?;
    query
        .split('&')
        .filter_map(|pair| pair.split_once('='))
        .find(|(name, _)| *name == "offset")
        .and_then(|(_, value)| value.parse::<i64>().ok())
        .filter(|o| *o >= 0)
}

/// Exact-match estimate catalog from OpenRouter's model list (per-token prices -> per million).
/// Keeps cache prices, prompt-length tiers and UTC lanes. A bare alias is added only when exactly one
/// non-variant route owns it.
pub fn catalog_from_open_router(data: &[u8]) -> Result<PricingCatalog, CodecError> {
    let root: Value = serde_json::from_slice(data).map_err(|_| CodecError::NotAnObject)?;
    let models = root
        .get("data")
        .and_then(Value::as_array)
        .filter(|m| m.iter().all(Value::is_object))
        .ok_or(CodecError::NotAnObject)?;
    let complete = integer(root.get("total_count")) == Some(models.len() as i64)
        && root
            .get("links")
            .and_then(|l| l.get("next"))
            .is_some_and(Value::is_null);
    if !complete {
        return Err(CodecError::IncompleteModelList);
    }

    let mut routes: HashMap<String, ModelRates> = HashMap::with_capacity(models.len());
    let mut aliases: HashMap<String, Vec<String>> = HashMap::new();
    for model in models {
        let Some(key) = model.get("id").and_then(Value::as_str).map(str::trim) else {
            continue;
        };
        if key.is_empty() || routes.contains_key(key) {
            continue;
        }
        let Some(pricing) = model.get("pricing").and_then(Value::as_object) else {
            continue;
        };
        let limit = f64::MAX / 1_000_000.0;
        let (Some(prompt), Some(completion)) = (
            nonnegative_finite(pricing.get("prompt")),
            nonnegative_finite(pricing.get("completion")),
        ) else {
            continue;
        };
        if prompt > limit || completion > limit {
            continue;
        }
        let input = prompt * 1_000_000.0;
        let cache_read = open_router_rate(pricing.get("input_cache_read"));
        let tiers = open_router_prompt_tiers(pricing.get("overrides"), key);
        let utc = open_router_utc_overrides(pricing.get("overrides"));
        let mut rates = ModelRates::new(
            input,
            completion * 1_000_000.0,
            open_router_rate(pricing.get("input_cache_write")).unwrap_or(input),
            cache_read.unwrap_or(input),
        );
        rates.cache_write_1h_per_million = open_router_rate(pricing.get("input_cache_write_1h"));
        rates.cache_read_is_explicit = cache_read.is_some();
        rates.prompt_rate_tiers = tiers;
        rates.utc_price_overrides = (!utc.is_empty()).then_some(utc);
        routes.insert(key.to_string(), rates);

        let parts: Vec<&str> = key.split('/').collect();
        if parts.len() == 2 && !parts[1].contains(':') && !parts[1].is_empty() {
            aliases
                .entry(parts[1].to_lowercase())
                .or_default()
                .push(key.to_string());
        }
    }
    if routes.is_empty() {
        return Err(CodecError::NoUsableEntries);
    }
    let mut entries = routes.clone();
    for (alias, route_ids) in aliases {
        if route_ids.len() == 1 && !entries.contains_key(&alias) {
            if let Some(rates) = routes.get(&route_ids[0]) {
                entries.insert(alias, rates.clone());
            }
        }
    }
    Ok(PricingCatalog::from_entries(entries))
}

/// Only `min_prompt_tokens` overrides are request-size tiers (time/day lanes are handled below).
fn open_router_prompt_tiers(value: Option<&Value>, model_id: &str) -> Vec<PromptRateTier> {
    let Some(overrides) = object_array(value) else {
        return Vec::new();
    };
    let slug = model_id
        .split('/')
        .last()
        .unwrap_or("")
        .split(':')
        .next()
        .unwrap_or("")
        .to_lowercase();
    let mut tiers: Vec<PromptRateTier> = overrides
        .into_iter()
        .filter_map(|o| {
            let threshold = integer(o.get("min_prompt_tokens"))?;
            // GPT-6.1 Sol's published `>272K` boundary arrives as `min_prompt_tokens: 272000`; the exact
            // 272,000-token request stays at standard rates.
            let exclusive = slug == "gpt-6.1-sol" && threshold == 272_000;
            let tier = PromptRateTier {
                threshold_prompt_tokens: threshold,
                includes_threshold: !exclusive,
                input_per_million: open_router_rate(o.get("prompt")),
                output_per_million: open_router_rate(o.get("completion")),
                cache_write_per_million: open_router_rate(o.get("input_cache_write")),
                cache_read_per_million: open_router_rate(o.get("input_cache_read")),
                cache_write_1h_per_million: open_router_rate(o.get("input_cache_write_1h")),
            };
            tier.has_rates().then_some(tier)
        })
        .collect();
    tiers.sort_by_key(|t| t.threshold_prompt_tokens);
    tiers
}

/// `utc_days` plus HHMM boundaries; an end of `0` after a positive start means midnight at the end
/// of that UTC day (1000-0 is 10:00-24:00).
fn open_router_utc_overrides(value: Option<&Value>) -> Vec<UtcPriceRateOverride> {
    const DAYS: [&str; 7] = [
        "monday",
        "tuesday",
        "wednesday",
        "thursday",
        "friday",
        "saturday",
        "sunday",
    ];
    let Some(overrides) = object_array(value) else {
        return Vec::new();
    };
    overrides
        .into_iter()
        .filter_map(|o| {
            if o.contains_key("min_prompt_tokens") {
                return None;
            }
            let present = |k: &str| o.get(k).filter(|v| !v.is_null());
            let days = match present("utc_days") {
                Some(v) => {
                    let raw: Vec<&str> = v
                        .as_array()?
                        .iter()
                        .map(Value::as_str)
                        .collect::<Option<_>>()?;
                    if raw.is_empty() {
                        return None;
                    }
                    let normalized: Vec<String> = raw.iter().map(|d| d.to_lowercase()).collect();
                    if !normalized.iter().all(|d| DAYS.contains(&d.as_str())) {
                        return None;
                    }
                    Some(normalized)
                }
                None => None,
            };
            let raw_start = match present("utc_start") {
                Some(v) => Some(integer(Some(v))?),
                None => None,
            };
            let raw_end = match present("utc_end") {
                Some(v) => Some(integer(Some(v))?),
                None => None,
            };
            if days.is_none() && raw_start.is_none() && raw_end.is_none() {
                return None;
            }
            let start = match raw_start {
                Some(v) => Some(utc_minute(v)?),
                None => None,
            };
            let mut end = match raw_end {
                Some(v) => Some(utc_minute(v)?),
                None => None,
            };
            if raw_end == Some(0) && start.is_some_and(|s| s > 0) {
                end = Some(1_440);
            }
            let tier = UtcPriceRateOverride {
                utc_days: days,
                utc_start_minute: start,
                utc_end_minute: end,
                input_per_million: open_router_rate(o.get("prompt")),
                output_per_million: open_router_rate(o.get("completion")),
                cache_write_per_million: open_router_rate(o.get("input_cache_write")),
                cache_read_per_million: open_router_rate(o.get("input_cache_read")),
                cache_write_1h_per_million: open_router_rate(o.get("input_cache_write_1h")),
            };
            tier.has_rates().then_some(tier)
        })
        .collect()
}

fn utc_minute(hhmm: i64) -> Option<i64> {
    if !(0..=2_400).contains(&hhmm) {
        return None;
    }
    let (hour, minute) = (hhmm / 100, hhmm % 100);
    (hour <= 24 && minute < 60 && (hour < 24 || minute == 0)).then_some(hour * 60 + minute)
}

// MARK: - LiteLLM

const LITELLM_TIER_THRESHOLDS: [i64; 5] = [100_000, 128_000, 200_000, 272_000, 512_000];

/// LiteLLM's `model_prices_and_context_window.json`: entries without both input and output costs
/// (stubs, non-chat modes) are skipped.
pub fn catalog_from_litellm(data: &[u8]) -> Result<PricingCatalog, CodecError> {
    let root: Value = serde_json::from_slice(data).map_err(|_| CodecError::NotAnObject)?;
    let root = root.as_object().ok_or(CodecError::NotAnObject)?;
    let mut entries = HashMap::with_capacity(root.len());
    for (key, value) in root {
        let Some(entry) = value.as_object() else {
            continue;
        };
        let (Some(input), Some(output)) = (
            per_million_from_per_token(entry.get("input_cost_per_token")),
            per_million_from_per_token(entry.get("output_cost_per_token")),
        ) else {
            continue;
        };
        let cache_read = per_million_from_per_token(entry.get("cache_read_input_token_cost"));
        let tiers: Vec<PromptRateTier> = LITELLM_TIER_THRESHOLDS
            .iter()
            .filter_map(|threshold| {
                let suffix = format!("above_{}k_tokens", threshold / 1_000);
                let field = |prefix: &str| {
                    per_million_from_per_token(entry.get(&format!("{prefix}_{suffix}")))
                };
                let tier = PromptRateTier {
                    threshold_prompt_tokens: *threshold,
                    includes_threshold: false,
                    input_per_million: field("input_cost_per_token"),
                    output_per_million: field("output_cost_per_token"),
                    cache_write_per_million: field("cache_creation_input_token_cost"),
                    cache_read_per_million: field("cache_read_input_token_cost"),
                    cache_write_1h_per_million: None,
                };
                tier.has_rates().then_some(tier)
            })
            .collect();
        let mut rates = ModelRates::new(
            input,
            output,
            per_million_from_per_token(entry.get("cache_creation_input_token_cost"))
                .unwrap_or(input),
            cache_read.unwrap_or(input),
        );
        rates.cache_read_is_explicit = cache_read.is_some();
        rates.prompt_rate_tiers = tiers;
        rates.input_above_200k_per_million =
            per_million_from_per_token(entry.get("input_cost_per_token_above_200k_tokens"));
        rates.output_above_200k_per_million =
            per_million_from_per_token(entry.get("output_cost_per_token_above_200k_tokens"));
        rates.cache_write_above_200k_per_million = per_million_from_per_token(
            entry.get("cache_creation_input_token_cost_above_200k_tokens"),
        );
        rates.cache_read_above_200k_per_million =
            per_million_from_per_token(entry.get("cache_read_input_token_cost_above_200k_tokens"));
        if let Some(fast) = entry
            .get("provider_specific_entry")
            .and_then(|p| number(p.get("fast")))
        {
            if fast.is_finite() && fast > 0.0 {
                rates.fast_multiplier = fast;
            }
        }
        entries.insert(key.clone(), rates);
    }
    if entries.is_empty() {
        return Err(CodecError::NoUsableEntries);
    }
    Ok(PricingCatalog::from_entries(entries))
}

// MARK: - models.dev

/// models.dev `api.json` (`{provider: {models: {id: {cost}}}}`, already per million). Duplicate ids
/// survive only when every provider publishes identical rates; conflicting ids become tombstones.
pub fn catalog_from_models_dev(data: &[u8]) -> Result<PricingCatalog, CodecError> {
    let root: Value = serde_json::from_slice(data).map_err(|_| CodecError::NotAnObject)?;
    let root = root.as_object().ok_or(CodecError::NotAnObject)?;
    let mut providers: Vec<&String> = root.keys().collect();
    providers.sort();
    let mut candidates: HashMap<String, Vec<ModelRates>> = HashMap::new();
    for name in providers {
        let Some(models) = root[name].get("models").and_then(Value::as_object) else {
            continue;
        };
        for (model_id, model) in models {
            let Some(cost) = model.get("cost").and_then(Value::as_object) else {
                continue;
            };
            let (Some(input), Some(output)) = (
                valid_per_million(cost.get("input")),
                valid_per_million(cost.get("output")),
            ) else {
                continue;
            };
            let mut tiers: Vec<PromptRateTier> = object_array(cost.get("tiers"))
                .unwrap_or_default()
                .into_iter()
                .filter_map(|tier| {
                    let context = tier.get("tier")?.as_object()?;
                    if context.get("type").and_then(Value::as_str) != Some("context") {
                        return None;
                    }
                    models_dev_tier(tier, integer(context.get("size"))?)
                })
                .collect();
            if !tiers.iter().any(|t| t.threshold_prompt_tokens == 200_000) {
                if let Some(tier) = cost
                    .get("context_over_200k")
                    .and_then(Value::as_object)
                    .and_then(|c| models_dev_tier(c, 200_000))
                {
                    tiers.push(tier);
                }
            }
            tiers.sort_by_key(|t| t.threshold_prompt_tokens);
            let cache_read = valid_per_million(cost.get("cache_read"));
            let mut rates = ModelRates::new(
                input,
                output,
                valid_per_million(cost.get("cache_write")).unwrap_or(input),
                cache_read.unwrap_or(input),
            );
            rates.cache_read_is_explicit = cache_read.is_some();
            rates.prompt_rate_tiers = tiers;
            candidates.entry(model_id.clone()).or_default().push(rates);
        }
    }
    let mut entries = HashMap::new();
    let mut retired = HashSet::new();
    for (id, rates) in candidates {
        if rates.iter().skip(1).all(|r| *r == rates[0]) {
            entries.insert(id, rates.into_iter().next().expect("non-empty"));
        } else {
            retired.insert(id);
        }
    }
    if entries.is_empty() {
        return Err(CodecError::NoUsableEntries);
    }
    Ok(PricingCatalog::new(entries, None, retired, true))
}

fn models_dev_tier(rates: &Map<String, Value>, threshold: i64) -> Option<PromptRateTier> {
    let tier = PromptRateTier {
        threshold_prompt_tokens: threshold,
        includes_threshold: true,
        input_per_million: valid_per_million(rates.get("input")),
        output_per_million: valid_per_million(rates.get("output")),
        cache_write_per_million: valid_per_million(rates.get("cache_write")),
        cache_read_per_million: valid_per_million(rates.get("cache_read")),
        cache_write_1h_per_million: None,
    };
    tier.has_rates().then_some(tier)
}

// MARK: - Compact format (bundled snapshots + disk cache)

/// Per-million rates under short keys: `i`nput, `o`utput, cache lanes, `a`bove-200k variants,
/// optional prompt tiers and UTC lanes, `cre` (omitted = explicit) and `fast`.
#[derive(Serialize, Deserialize)]
struct CompactFile {
    #[serde(
        rename = "retrieved_at",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    retrieved_at: Option<String>,
    models: BTreeMap<String, CompactModel>,
    /// Presence marks a complete tombstone snapshot; older writers omit it.
    #[serde(rename = "retired", default, skip_serializing_if = "Option::is_none")]
    retired: Option<Vec<String>>,
}

#[derive(Serialize, Deserialize)]
struct CompactModel {
    i: f64,
    o: f64,
    cw: f64,
    cr: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    cw1: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    tiers: Option<Vec<PromptRateTier>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    utc: Option<Vec<UtcPriceRateOverride>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    ia: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    oa: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    cwa: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    cra: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    cre: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    crb: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    fast: Option<f64>,
}

pub fn catalog_from_compact(data: &[u8]) -> Result<PricingCatalog, String> {
    let file: CompactFile = serde_json::from_slice(data).map_err(|e| e.to_string())?;
    let entries = file
        .models
        .into_iter()
        .map(|(key, m)| {
            let mut rates = ModelRates::new(m.i, m.o, m.cw, m.cr);
            rates.cache_write_1h_per_million = m.cw1;
            rates.prompt_rate_tiers = m.tiers.unwrap_or_default();
            rates.utc_price_overrides = m.utc;
            rates.input_above_200k_per_million = m.ia;
            rates.output_above_200k_per_million = m.oa;
            rates.cache_write_above_200k_per_million = m.cwa;
            rates.cache_read_above_200k_per_million = m.cra;
            rates.cache_read_is_explicit = m.crb.or(m.cre).unwrap_or(true);
            rates.fast_multiplier = m.fast.unwrap_or(1.0);
            (key, rates)
        })
        .collect();
    let authoritative = file.retired.is_some();
    Ok(PricingCatalog::new(
        entries,
        file.retrieved_at,
        file.retired.unwrap_or_default().into_iter().collect(),
        authoritative,
    ))
}

pub fn compact_data(catalog: &PricingCatalog) -> Vec<u8> {
    let models = catalog
        .entries
        .iter()
        .map(|(key, r)| {
            let has_cache_read_override = r.cache_read_above_200k_per_million.is_some()
                || r.prompt_rate_tiers
                    .iter()
                    .any(|t| t.cache_read_per_million.is_some())
                || r.utc_price_overrides
                    .as_ref()
                    .is_some_and(|o| o.iter().any(|u| u.cache_read_per_million.is_some()));
            let model = CompactModel {
                i: r.input_per_million,
                o: r.output_per_million,
                cw: r.cache_write_per_million,
                cr: r.cache_read_per_million,
                cw1: r.cache_write_1h_per_million,
                tiers: (!r.prompt_rate_tiers.is_empty()).then(|| r.prompt_rate_tiers.clone()),
                utc: r.utc_price_overrides.clone().filter(|o| !o.is_empty()),
                ia: r.input_above_200k_per_million,
                oa: r.output_above_200k_per_million,
                cwa: r.cache_write_above_200k_per_million,
                cra: r.cache_read_above_200k_per_million,
                cre: (!r.cache_read_is_explicit && !has_cache_read_override).then_some(false),
                crb: (!r.cache_read_is_explicit && has_cache_read_override).then_some(false),
                fast: (r.fast_multiplier != 1.0).then_some(r.fast_multiplier),
            };
            (key.clone(), model)
        })
        .collect();
    let retired = catalog.retired_keys_are_authoritative.then(|| {
        let mut keys: Vec<String> = catalog.retired_keys.iter().cloned().collect();
        keys.sort();
        keys
    });
    serde_json::to_vec(&CompactFile {
        retrieved_at: catalog.retrieved_at.clone(),
        models,
        retired,
    })
    .expect("compact catalog serializes")
}
