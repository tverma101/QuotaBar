//! Bundled model pricing (supplement, LiteLLM and models.dev compact snapshots).
//! Ports upstream OpenUsage v0.7.3+ aliases; v0.7.8/0.7.9 add Kimi K3, Opus 5, Grok 4.6,
//! Daybreak Blue, and Cursor Router prose labels. Upstream #909 refreshes price lists hourly
//! via gh-pages. The desktop app also discovers exact routes from OpenRouter.

use crate::log_usage_types::TokenBreakdown;
use chrono::{DateTime, Utc};
use regex_lite::{Regex, RegexBuilder};
use serde::Deserialize;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock, RwLock};

#[path = "pricing_live.rs"]
mod live;
pub use live::enable_live_pricing;

#[path = "pricing_fallback.rs"]
mod fallback;

#[path = "pricing_rates.rs"]
mod rates;
pub use rates::ModelRates;
use rates::{PromptRateTier, UTC_DAYS, UtcRateOverride};

const SUPPLEMENT_JSON: &str = include_str!("../data/pricing_supplement.json");
const LITELLM_JSON: &str = include_str!("../data/pricing_litellm_snapshot.json");
const CURRENT_LITELLM_JSON: &str =
    include_str!("../../../../Sources/QuotaBar/Resources/pricing_litellm_snapshot.json");
const MODELS_DEV_JSON: &str =
    include_str!("../../../../Sources/QuotaBar/Resources/pricing_models_dev_snapshot.json");
const MAX_CACHED_MODELS: usize = 1024;
const MAX_CACHED_MODEL_BYTES: usize = 256;

struct AliasRule {
    pattern: Regex,
    forbidden_prefix: Option<String>,
    canonical: String,
}

struct PricingSupplement {
    pricing: HashMap<String, ModelRates>,
    fast_multipliers: HashMap<String, f64>,
    alias_rules: Vec<AliasRule>,
}

#[derive(Deserialize)]
struct SupplementFile {
    pricing: HashMap<String, SupplementRates>,
    fast_multipliers: HashMap<String, f64>,
    alias_rules: Vec<AliasRuleFile>,
    updated_at: Option<String>,
    #[serde(default)]
    retired_pricing_keys: Vec<String>,
    retired_alias_patterns: Option<Vec<String>>,
}

#[derive(Deserialize)]
struct SupplementRates {
    input_per_million: f64,
    output_per_million: f64,
    #[serde(default)]
    cache_write_per_million: Option<f64>,
    #[serde(default)]
    cache_read_per_million: Option<f64>,
}

#[derive(Deserialize)]
struct AliasRuleFile {
    pattern: String,
    canonical: String,
}

#[derive(Deserialize)]
struct CompactCatalog {
    models: HashMap<String, CompactModel>,
    #[serde(default)]
    retired: Vec<String>,
}

#[derive(Deserialize)]
struct CompactModel {
    i: f64,
    o: f64,
    cw: f64,
    cr: f64,
    cw1: Option<f64>,
    #[serde(default)]
    tiers: Vec<PromptRateTier>,
    utc: Option<Vec<UtcRateOverride>>,
    #[serde(default)]
    ia: Option<f64>,
    #[serde(default)]
    oa: Option<f64>,
    #[serde(default)]
    cwa: Option<f64>,
    #[serde(default)]
    cra: Option<f64>,
    #[serde(default)]
    fast: Option<f64>,
    /// Omitted / true = explicit cache-read; `false` = synthesized fallback.
    #[serde(default)]
    cre: Option<bool>,
}

pub struct ModelPricing {
    supplement: PricingSupplement,
    primary: HashMap<String, ModelRates>,
    secondary: HashMap<String, ModelRates>,
    open_router: RwLock<HashMap<String, ModelRates>>,
    fallback: RwLock<fallback::Fallback>,
    discovers: bool,
    generation: AtomicU64,
    resolved: Mutex<HashMap<String, Option<ModelRates>>>,
}

static DEFAULT_PRICING: OnceLock<ModelPricing> = OnceLock::new();

pub fn default_pricing() -> &'static ModelPricing {
    let pricing = DEFAULT_PRICING.get_or_init(|| {
        let mut pricing = ModelPricing::from_bundled();
        if let Some(path) = crate::paths::app_data_dir() {
            *pricing.open_router.get_mut().unwrap() = live::load_cache(&path);
            let cache = fallback::Fallback::load(&path, &pricing);
            *pricing.fallback.get_mut().unwrap() = cache;
        }
        pricing.discovers = true;
        pricing
    });
    pricing
}

impl ModelPricing {
    pub fn from_bundled() -> Self {
        let supplement = load_supplement(SUPPLEMENT_JSON);
        let mut primary = load_compact_catalog(LITELLM_JSON);
        primary.extend(load_compact_catalog(CURRENT_LITELLM_JSON));
        let secondary = load_compact_catalog(MODELS_DEV_JSON);
        Self {
            supplement,
            primary,
            secondary,
            open_router: RwLock::new(HashMap::new()),
            fallback: RwLock::new(fallback::Fallback::default()),
            discovers: false,
            generation: AtomicU64::new(0),
            resolved: Mutex::new(HashMap::new()),
        }
    }

    pub fn can_price(&self, model: &str) -> bool {
        self.resolve(model).is_some()
    }

    pub fn estimated_cost_dollars(&self, model: &str, tokens: &TokenBreakdown) -> Option<f64> {
        self.resolve(model).map(|r| r.cost_dollars(tokens))
    }

    pub fn estimated_cost_dollars_at(&self, model: &str, tokens: &TokenBreakdown, at: DateTime<Utc>) -> Option<f64> {
        self.resolve(model).map(|rate| rate.cost_dollars_at(tokens, Some(at), true))
    }

    /// Supplement alias canonical name when a rule matches; otherwise `None`.
    pub fn canonical_name(&self, model: &str) -> Option<String> {
        self.fallback.read().unwrap().supplement(&self.supplement).canonical_name(model)
    }

    pub fn resolve(&self, model: &str) -> Option<ModelRates> {
        if self.discovers {
            live::schedule_refresh(self, Some(model));
        }
        if model.len() > MAX_CACHED_MODEL_BYTES {
            return self.resolve_uncached(model);
        }
        if let Some(cached) = self
            .resolved
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(model)
        {
            return cached.clone();
        }
        let generation = self.generation.load(Ordering::Relaxed);
        let result = self.resolve_uncached(model);
        let mut resolved = self
            .resolved
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if generation == self.generation.load(Ordering::Relaxed) && resolved.len() < MAX_CACHED_MODELS {
            resolved.entry(model.to_owned()).or_insert_with(|| result.clone());
        }
        result
    }

    fn resolve_uncached(&self, model: &str) -> Option<ModelRates> {
        let fallback = self.fallback.read().unwrap();
        PricingLookup {
            supplement: fallback.supplement(&self.supplement),
            primary: fallback.primary(&self.primary),
            secondary: fallback.secondary(&self.secondary),
            open_router: &self.open_router.read().unwrap(),
        }.resolve(model)
    }

    fn catalog_changed(&self, apply: impl FnOnce()) {
        let mut resolved = self.resolved.lock().unwrap();
        apply();
        self.generation.fetch_add(1, Ordering::Relaxed);
        resolved.clear();
    }
}

struct PricingLookup<'a> {
    supplement: &'a PricingSupplement,
    primary: &'a HashMap<String, ModelRates>,
    secondary: &'a HashMap<String, ModelRates>,
    open_router: &'a HashMap<String, ModelRates>,
}

impl PricingLookup<'_> {
    fn resolve(&self, model: &str) -> Option<ModelRates> {
        if let Some(canonical) = self.supplement.canonical_name(model) {
            if canonical != model {
                if let Some(r) = self.lookup(&canonical) {
                    return Some(r);
                }
            }
        }
        self.lookup(model)
    }

    fn lookup(&self, name: &str) -> Option<ModelRates> {
        if let Some(r) = self.supplement.pricing.get(name) {
            return Some(r.clone());
        }
        if let Some(r) = self.open_router.get(name) {
            return Some(self.with_supplement_fast_multiplier(name, r));
        }
        if let Some(r) = self.primary.get(name) {
            return Some(self.with_supplement_fast_multiplier(name, r));
        }
        let normalized = normalized_key(name);
        if normalized != name {
            if let Some(r) = self.supplement.pricing.get(&normalized) {
                return Some(r.clone());
            }
            if let Some(r) = self.open_router.get(&normalized) {
                return Some(self.with_supplement_fast_multiplier(name, r));
            }
            if let Some(r) = self.primary.get(&normalized) {
                return Some(self.with_supplement_fast_multiplier(name, r));
            }
        }
        if let Some(r) = self.fast_variant(name) {
            return Some(r);
        }
        if !name.ends_with("-fast")
            && !normalized.rsplit('/').next().unwrap_or_default().to_ascii_lowercase().ends_with("-free")
        {
            if let Some(r) = self.fuzzy_primary(name) {
                return Some(self.with_supplement_fast_multiplier(name, r));
            }
        }
        self.secondary.get(name).map(|r| self.with_supplement_fast_multiplier(name, r))
    }

    fn with_supplement_fast_multiplier(&self, name: &str, rates: &ModelRates) -> ModelRates {
        let mut rates = rates.clone();
        if rates.fast_multiplier == 1.0 && !name.ends_with("-fast") {
            if let Some(multiplier) = self.supplement.fast_multiplier(name) {
                rates.fast_multiplier = multiplier;
            }
        }
        rates
    }

    fn fast_variant(&self, name: &str) -> Option<ModelRates> {
        const SUFFIX: &str = "-fast";
        if !name.ends_with(SUFFIX) {
            return None;
        }
        let base = &name[..name.len() - SUFFIX.len()];
        if base.is_empty() {
            return None;
        }
        let (key, rates) = self.base_entry(base)?;
        let multiplier = if rates.fast_multiplier != 1.0 {
            rates.fast_multiplier
        } else {
            self.supplement
                .fast_multiplier(&key)
                .or_else(|| self.supplement.fast_multiplier(base))?
        };
        Some(rates.scaled(multiplier))
    }

    fn base_entry(&self, base: &str) -> Option<(String, ModelRates)> {
        if let Some(r) = self.supplement.pricing.get(base) {
            return Some((base.to_string(), r.clone()));
        }
        if let Some(r) = self.open_router.get(base) {
            return Some((base.to_string(), r.clone()));
        }
        self.primary
            .get(base)
            .map(|r| (base.to_string(), r.clone()))
            .or_else(|| self.dated_primary_entry(base))
            .or_else(|| self.secondary.get(base).map(|r| (base.to_string(), r.clone())))
    }

    fn dated_primary_entry(&self, base: &str) -> Option<(String, ModelRates)> {
        let base = normalized_key(base);
        self.primary
            .iter()
            .filter_map(|(key, rates)| {
                let candidate = normalized_key(key);
                let candidate = if base.contains('/') {
                    &candidate
                } else {
                    candidate.rsplit('/').next().unwrap_or_default()
                };
                let suffix = candidate.strip_prefix(&base)?.strip_prefix('-')?;
                let (date, tail) = suffix.split_at_checked(8)?;
                (date.bytes().all(|b| b.is_ascii_digit())
                    && (tail.is_empty() || tail.starts_with('-')))
                    .then(|| (date.to_owned(), key, rates))
            })
            .max_by(|a, b| {
                a.0.cmp(&b.0)
                    .then_with(|| a.1.len().cmp(&b.1.len()))
                    .then_with(|| b.1.cmp(a.1))
            })
            .map(|(_, key, rates)| (key.clone(), rates.clone()))
    }

    fn fuzzy_primary(&self, model: &str) -> Option<&ModelRates> {
        let normalized = normalized_key(model);
        let mut best: Option<(&str, &ModelRates)> = None;
        for (key, rates) in self.primary {
            if key_matches(key, model, &normalized) {
                best = match best {
                    Some((bk, _)) if key.len() > bk.len() || (key.len() == bk.len() && key.as_str() < bk) => {
                        Some((key.as_str(), rates))
                    }
                    Some(current) => Some(current),
                    None => Some((key.as_str(), rates)),
                };
            }
        }
        best.map(|(_, r)| r)
    }
}

impl PricingSupplement {
    fn canonical_name(&self, model: &str) -> Option<String> {
        for rule in &self.alias_rules {
            if let Some(ref forbidden) = rule.forbidden_prefix {
                if model == forbidden {
                    continue;
                }
            }
            if rule.pattern.is_match(model) {
                return Some(rule.canonical.clone());
            }
        }
        None
    }

    fn fast_multiplier(&self, model: &str) -> Option<f64> {
        if let Some(v) = self.fast_multipliers.get(model) {
            return Some(*v);
        }
        let normalized = normalized_key(model);
        for part in normalized.split(['/', ':']) {
            for (base, mult) in &self.fast_multipliers {
                if matches_model_suffix(part, &normalized_key(base)) {
                    return Some(*mult);
                }
            }
        }
        None
    }
}

fn load_supplement(json: &str) -> PricingSupplement {
    let file: SupplementFile = serde_json::from_str(json).unwrap_or(SupplementFile {
        pricing: HashMap::new(),
        fast_multipliers: HashMap::new(),
        alias_rules: vec![],
        updated_at: None,
        retired_pricing_keys: Vec::new(),
        retired_alias_patterns: None,
    });
    build_supplement(file)
}

fn build_supplement(mut file: SupplementFile) -> PricingSupplement {
    for key in file.retired_pricing_keys {
        file.pricing.remove(&key);
    }
    if let Some(retired) = file.retired_alias_patterns {
        file.alias_rules.retain(|rule| !retired.contains(&rule.pattern));
    }
    let mut pricing = HashMap::new();
    for (model, entry) in file.pricing {
        let cache_read_is_explicit = entry.cache_read_per_million.is_some();
        let fast_multiplier = file.fast_multipliers.get(&model).copied().unwrap_or(1.0);
        pricing.insert(
            model,
            ModelRates {
                input_per_million: entry.input_per_million,
                output_per_million: entry.output_per_million,
                cache_write_per_million: entry
                    .cache_write_per_million
                    .unwrap_or(entry.input_per_million),
                cache_read_per_million: entry
                    .cache_read_per_million
                    .unwrap_or(entry.input_per_million * 0.1),
                cache_write_1h_per_million: None,
                prompt_rate_tiers: Vec::new(),
                utc_rate_overrides: Vec::new(),
                input_above_200k: None,
                output_above_200k: None,
                cache_write_above_200k: None,
                cache_read_above_200k: None,
                cache_read_is_explicit,
                long_context_threshold_tokens: 200_000,
                fast_multiplier,
            },
        );
    }
    let alias_rules = file
        .alias_rules
        .into_iter()
        .filter_map(|rule| {
            compile_alias_pattern(&rule.pattern).map(|(pattern, forbidden_prefix)| AliasRule {
                pattern,
                forbidden_prefix,
                canonical: rule.canonical,
            })
        })
        .collect();
    PricingSupplement {
        pricing,
        fast_multipliers: file.fast_multipliers,
        alias_rules,
    }
}

/// Upstream Swift NSRegularExpression accepts `(?i)` inline flags and `(?=-)` lookaheads.
/// `regex-lite` supports neither, so strip a leading `(?i)` and translate `(?=-)` into a
/// forbidden bare-prefix check (`gemini-3-pro(?=-)` matches `gemini-3-pro-*` but not `gemini-3-pro`).
fn compile_alias_pattern(pattern: &str) -> Option<(Regex, Option<String>)> {
    let (body, case_insensitive) = match pattern.strip_prefix("(?i)") {
        Some(rest) => (rest, true),
        None => (pattern, false),
    };
    let (body_owned, forbidden_prefix) = if let Some(idx) = body.find("(?=-)") {
        let prefix = body[..idx].trim_start_matches('^').to_string();
        let replaced = format!("{}{}", &body[..idx], &body[idx + "(?=-)".len()..]);
        (replaced, Some(prefix))
    } else {
        (body.to_string(), None)
    };
    let regex = if case_insensitive {
        RegexBuilder::new(&body_owned).case_insensitive(true).build().ok()?
    } else {
        Regex::new(&body_owned).ok()?
    };
    Some((regex, forbidden_prefix))
}

fn load_compact_catalog(json: &str) -> HashMap<String, ModelRates> {
    let mut file: CompactCatalog = match serde_json::from_str(json) {
        Ok(file) => file,
        Err(err) => {
            log::warn!("failed to parse bundled compact pricing: {err}");
            return HashMap::new();
        }
    };
    for key in file.retired {
        file.models.remove(&key);
    }
    file.models
        .into_iter()
        .map(|(key, m)| {
            (
                key,
                ModelRates {
                    input_per_million: m.i,
                    output_per_million: m.o,
                    cache_write_per_million: m.cw,
                    cache_read_per_million: m.cr,
                    cache_write_1h_per_million: m.cw1,
                    prompt_rate_tiers: m.tiers,
                    utc_rate_overrides: m.utc.unwrap_or_default(),
                    input_above_200k: m.ia,
                    output_above_200k: m.oa,
                    cache_write_above_200k: m.cwa,
                    cache_read_above_200k: m.cra,
                    cache_read_is_explicit: m.cre.unwrap_or(true),
                    long_context_threshold_tokens: 200_000,
                    fast_multiplier: m.fast.unwrap_or(1.0),
                },
            )
        })
        .collect()
}

fn normalized_key(model: &str) -> String {
    model.replace(['.', '@', ' ', '_'], "-")
}

fn key_matches(candidate: &str, model: &str, normalized_model: &str) -> bool {
    let nc = normalized_key(candidate);
    contains_key(model, candidate) || contains_key(candidate, model)
        || contains_key(normalized_model, &nc) || contains_key(&nc, normalized_model)
}

fn contains_key(value: &str, key: &str) -> bool {
    if key.is_empty() {
        return false;
    }
    value.match_indices(key).any(|(start, _)| {
        let bytes = value.as_bytes();
        if start > 0 && bytes[start - 1].is_ascii_alphanumeric() {
            return false;
        }
        let suffix = &bytes[start + key.len()..];
        match suffix {
            [separator, rest @ ..] if matches!(separator, b'-' | b'.')
                && key.as_bytes().last().is_some_and(u8::is_ascii_digit) => {
                let digits = rest.iter().take_while(|b| b.is_ascii_digit()).count();
                digits == 0 || (digits == 8 && !rest.get(digits).is_some_and(u8::is_ascii_alphanumeric))
            }
            [first, ..] => !first.is_ascii_alphanumeric(),
            [] => true,
        }
    })
}

fn matches_model_suffix(part: &str, base: &str) -> bool {
    part.rfind(base)
        .map(|idx| {
            let suffix = &part[idx + base.len()..];
            suffix.is_empty() || suffix.starts_with('-')
        })
        .unwrap_or(false)
}

#[cfg(test)]
#[path = "pricing_tests.rs"]
mod tests;
