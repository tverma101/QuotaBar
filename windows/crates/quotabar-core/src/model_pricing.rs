//! Bundled model pricing (supplement, LiteLLM and models.dev compact snapshots).
//! Ports upstream OpenUsage v0.7.3+ aliases; v0.7.8/0.7.9 add Kimi K3, Opus 5, Grok 4.6,
//! Daybreak Blue, and Cursor Router prose labels. Upstream #909 refreshes price lists hourly
//! via gh-pages. This Windows engine currently does not fetch over the network.

use crate::log_usage_types::TokenBreakdown;
use regex_lite::{Regex, RegexBuilder};
use serde::Deserialize;
use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

const SUPPLEMENT_JSON: &str = include_str!("../data/pricing_supplement.json");
const LITELLM_JSON: &str = include_str!("../data/pricing_litellm_snapshot.json");
const CURRENT_LITELLM_JSON: &str =
    include_str!("../../../../Sources/QuotaBar/Resources/pricing_litellm_snapshot.json");
const MODELS_DEV_JSON: &str =
    include_str!("../../../../Sources/QuotaBar/Resources/pricing_models_dev_snapshot.json");
const MAX_CACHED_MODELS: usize = 1024;
const MAX_CACHED_MODEL_BYTES: usize = 256;

#[derive(Debug, Clone, Deserialize)]
struct PromptRateTier {
    threshold_prompt_tokens: i64,
    #[serde(default)]
    includes_threshold: bool,
    input_per_million: Option<f64>,
    output_per_million: Option<f64>,
    cache_write_per_million: Option<f64>,
    cache_read_per_million: Option<f64>,
    cache_write_1h_per_million: Option<f64>,
}

impl PromptRateTier {
    fn scaled(&self, factor: f64) -> Self {
        Self {
            input_per_million: self.input_per_million.map(|v| v * factor),
            output_per_million: self.output_per_million.map(|v| v * factor),
            cache_write_per_million: self.cache_write_per_million.map(|v| v * factor),
            cache_read_per_million: self.cache_read_per_million.map(|v| v * factor),
            cache_write_1h_per_million: self.cache_write_1h_per_million.map(|v| v * factor),
            ..*self
        }
    }
}

#[derive(Debug, Clone)]
pub struct ModelRates {
    pub input_per_million: f64,
    pub output_per_million: f64,
    pub cache_write_per_million: f64,
    pub cache_read_per_million: f64,
    cache_write_1h_per_million: Option<f64>,
    prompt_rate_tiers: Vec<PromptRateTier>,
    pub input_above_200k: Option<f64>,
    pub output_above_200k: Option<f64>,
    pub cache_write_above_200k: Option<f64>,
    pub cache_read_above_200k: Option<f64>,
    /// Catalog published an explicit cache-read rate (not a synthesized 10%-of-input fallback).
    pub cache_read_is_explicit: bool,
    /// Prompt-token threshold for optional long-context rates (200k default; Codex uses 272k).
    pub long_context_threshold_tokens: i32,
    pub fast_multiplier: f64,
}

impl ModelRates {
    pub fn scaled(&self, factor: f64) -> Self {
        Self {
            input_per_million: self.input_per_million * factor,
            output_per_million: self.output_per_million * factor,
            cache_write_per_million: self.cache_write_per_million * factor,
            cache_read_per_million: self.cache_read_per_million * factor,
            cache_write_1h_per_million: self.cache_write_1h_per_million.map(|v| v * factor),
            prompt_rate_tiers: self
                .prompt_rate_tiers
                .iter()
                .map(|tier| tier.scaled(factor))
                .collect(),
            input_above_200k: self.input_above_200k.map(|v| v * factor),
            output_above_200k: self.output_above_200k.map(|v| v * factor),
            cache_write_above_200k: self.cache_write_above_200k.map(|v| v * factor),
            cache_read_above_200k: self.cache_read_above_200k.map(|v| v * factor),
            cache_read_is_explicit: self.cache_read_is_explicit,
            long_context_threshold_tokens: self.long_context_threshold_tokens,
            fast_multiplier: 1.0,
        }
    }

    /// Dollar cost of one request. When `apply_long_context_rates` and prompt tokens
    /// exceed `long_context_threshold_tokens`, the whole request uses long-context rates
    /// (upstream OpenUsage 0.7.4 #885 / 0.7.6 #995).
    pub fn cost_dollars(&self, tokens: &TokenBreakdown) -> f64 {
        self.cost_dollars_with_options(tokens, true)
    }

    pub fn cost_dollars_with_options(
        &self,
        tokens: &TokenBreakdown,
        apply_long_context_rates: bool,
    ) -> f64 {
        const CACHE_WRITE_1H_MULT: f64 = 2.0;
        let mult = if tokens.is_fast { self.fast_multiplier } else { 1.0 };
        let prompt_tokens = [
            tokens.input,
            tokens.cache_write5m,
            tokens.cache_write1h,
            tokens.cache_read,
        ]
        .into_iter()
        .map(i64::from)
        .sum::<i64>();
        let use_long = apply_long_context_rates
            && prompt_tokens > i64::from(self.long_context_threshold_tokens);
        let tier = self
            .prompt_rate_tiers
            .iter()
            .filter(|tier| {
                apply_long_context_rates
                    && (prompt_tokens > tier.threshold_prompt_tokens
                        || (tier.includes_threshold && prompt_tokens == tier.threshold_prompt_tokens))
            })
            .max_by_key(|tier| tier.threshold_prompt_tokens);
        let select = |base, long, prompt: Option<f64>| {
            prompt.unwrap_or_else(|| selected_rate(base, long, use_long))
        };
        let input_rate = select(
            self.input_per_million,
            self.input_above_200k,
            tier.and_then(|t| t.input_per_million),
        );
        let output_rate = select(
            self.output_per_million,
            self.output_above_200k,
            tier.and_then(|t| t.output_per_million),
        );
        let cache_write_rate = select(
            self.cache_write_per_million,
            self.cache_write_above_200k,
            tier.and_then(|t| t.cache_write_per_million),
        );
        let cache_read_rate = if self.cache_read_is_explicit {
            select(
                self.cache_read_per_million,
                self.cache_read_above_200k,
                tier.and_then(|t| t.cache_read_per_million),
            )
        } else {
            input_rate
        };
        let cache_write_1h_rate = tier
            .and_then(|t| t.cache_write_1h_per_million)
            .or(self.cache_write_1h_per_million)
            .unwrap_or(input_rate * CACHE_WRITE_1H_MULT);

        let cost = flat_cost(tokens.input, input_rate)
            + flat_cost(tokens.output, output_rate)
            + flat_cost(tokens.cache_write5m, cache_write_rate)
            + flat_cost(tokens.cache_write1h, cache_write_1h_rate)
            + flat_cost(tokens.cache_read, cache_read_rate);
        cost * mult
    }
}

fn selected_rate(base: f64, long_context: Option<f64>, use_long: bool) -> f64 {
    if use_long {
        long_context.unwrap_or(base)
    } else {
        base
    }
}

fn flat_cost(tokens: i32, rate_per_million: f64) -> f64 {
    if tokens <= 0 {
        return 0.0;
    }
    f64::from(tokens) * rate_per_million / 1_000_000.0
}

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
    resolved: Mutex<HashMap<String, Option<ModelRates>>>,
}

static DEFAULT_PRICING: OnceLock<ModelPricing> = OnceLock::new();

pub fn default_pricing() -> &'static ModelPricing {
    DEFAULT_PRICING.get_or_init(ModelPricing::from_bundled)
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
            resolved: Mutex::new(HashMap::new()),
        }
    }

    pub fn can_price(&self, model: &str) -> bool {
        self.resolve(model).is_some()
    }

    pub fn estimated_cost_dollars(&self, model: &str, tokens: &TokenBreakdown) -> Option<f64> {
        self.resolve(model).map(|r| r.cost_dollars(tokens))
    }

    /// Supplement alias canonical name when a rule matches; otherwise `None`.
    pub fn canonical_name(&self, model: &str) -> Option<String> {
        self.supplement.canonical_name(model)
    }

    pub fn resolve(&self, model: &str) -> Option<ModelRates> {
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
        let result = self.resolve_uncached(model);
        let mut resolved = self
            .resolved
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if resolved.len() < MAX_CACHED_MODELS {
            resolved.entry(model.to_owned()).or_insert_with(|| result.clone());
        }
        result
    }

    fn resolve_uncached(&self, model: &str) -> Option<ModelRates> {
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
        if let Some(r) = self.primary.get(name) {
            return Some(self.with_supplement_fast_multiplier(name, r));
        }
        let normalized = normalized_key(name);
        if normalized != name {
            if let Some(r) = self.supplement.pricing.get(&normalized) {
                return Some(r.clone());
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
        for (key, rates) in &self.primary {
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
    });
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
mod tests {
    use super::*;

    #[test]
    fn pricing_memoizes_repeated_hits_and_misses_without_unbounded_growth() {
        let pricing = ModelPricing::from_bundled();
        assert!(pricing.can_price("claude-sonnet-4-20250514"));
        assert!(!pricing.can_price("unlisted-catalog-fixture"));
        for _ in 0..100 {
            assert!(pricing.can_price("claude-sonnet-4-20250514"));
            assert!(!pricing.can_price("unlisted-catalog-fixture"));
        }
        {
            let mut cache = pricing.resolved.lock().unwrap();
            assert_eq!(cache.len(), 2);
            assert!(cache["unlisted-catalog-fixture"].is_none());
            for number in 2..MAX_CACHED_MODELS {
                cache.insert(format!("test-{number}"), None);
            }
        }
        assert!(!pricing.can_price("unlisted-catalog-fixture-2"));
        assert_eq!(pricing.resolved.lock().unwrap().len(), MAX_CACHED_MODELS);
    }

    #[test]
    fn models_dev_is_an_exact_fallback_and_honors_conflict_tombstones() {
        let mut pricing = ModelPricing::from_bundled();
        pricing.primary = load_compact_catalog(r#"{"models":{
            "priority-model":{"i":1,"o":2,"cw":1,"cr":1},
            "vendor/priority-model-v2":{"i":2,"o":2,"cw":2,"cr":2}
        }}"#);
        pricing.secondary = load_compact_catalog(r#"{"models":{
            "priority-model":{"i":3,"o":2,"cw":3,"cr":3},
            "priority-model-v2":{"i":4,"o":2,"cw":4,"cr":4},
            "secondary-only":{"i":5,"o":2,"cw":5,"cr":5},
            "conflict":{"i":6,"o":2,"cw":6,"cr":6}
        },"retired":["conflict"]}"#);

        assert_eq!(pricing.resolve("priority-model").unwrap().input_per_million, 1.0);
        assert_eq!(pricing.resolve("priority-model-v2").unwrap().input_per_million, 2.0);
        assert_eq!(pricing.resolve("secondary-only").unwrap().input_per_million, 5.0);
        assert!(!pricing.can_price("secondary-only-extra"));
        assert!(!pricing.can_price("conflict"));
        assert!(ModelPricing::from_bundled().can_price("@cf/aisingapore/gemma-sea-lion-v4-27b-it"));
    }

    #[test]
    fn lite_llm_fuzzy_match_requires_boundaries_and_cannot_price_unverified_variants() {
        let mut pricing = ModelPricing::from_bundled();
        pricing.primary = load_compact_catalog(r#"{"models":{
            "vendor/example-4":{"i":1,"o":2,"cw":1,"cr":1},
            "space-bunny":{"i":3,"o":2,"cw":3,"cr":3}
        }}"#);
        pricing.secondary.clear();

        assert!(pricing.can_price("vendor/example-4-20250514"));
        assert!(pricing.can_price("space bunny"));
        for unknown in ["vendor/example-4.5", "notexample-4", "example-4-fast", "example-4-free"] {
            assert!(!pricing.can_price(unknown), "{unknown} was incorrectly priced");
        }
    }

    #[test]
    fn compact_prompt_tiers_apply_to_the_entire_request_including_cache_writes() {
        let entries = load_compact_catalog(r#"{"models":{"example":{
            "i":1,"o":2,"cw":3,"cr":4,"cw1":5,"tiers":[
                {"threshold_prompt_tokens":100,"input_per_million":7},
                {"threshold_prompt_tokens":200,"includes_threshold":true,
                 "output_per_million":8,"cache_write_1h_per_million":9}
            ]
        }}}"#);
        let rates = &entries["example"];
        let mut tokens = TokenBreakdown {
            input: 90,
            output: 10,
            cache_write5m: 0,
            cache_write1h: 10,
            cache_read: 0,
            is_fast: false,
        };
        let check = |actual: f64, expected: f64| assert!((actual * 1_000_000.0 - expected).abs() < 1e-9);
        check(rates.cost_dollars(&tokens), 160.0);
        tokens.input = 91;
        check(rates.cost_dollars(&tokens), 707.0);
        tokens.input = 190;
        check(rates.cost_dollars(&tokens), 360.0);
        check(rates.cost_dollars_with_options(&tokens, false), 260.0);
        check(rates.scaled(2.0).cost_dollars(&tokens), 720.0);
    }

    #[test]
    fn bundled_pricing_resolves_claude_sonnet() {
        let p = ModelPricing::from_bundled();
        assert!(p.can_price("claude-sonnet-4-20250514"));
    }

    #[test]
    fn opus_fast_override_from_supplement() {
        let p = ModelPricing::from_bundled();
        let rates = p.resolve("claude-opus-4-7-fast").expect("opus fast");
        assert!((rates.input_per_million - 30.0).abs() < 0.01);
    }

    #[test]
    fn gpt_5_6_aliases_resolve() {
        let p = ModelPricing::from_bundled();
        assert!(p.can_price("gpt-5.6-sol"));
        assert!(p.can_price("gpt-5.6-terra-fast"));
        assert!(p.can_price("gpt-5.6-luna"));
    }

    #[test]
    fn grok_4_5_and_kimi_k2_7_aliases() {
        let p = ModelPricing::from_bundled();
        let grok = p.resolve("grok-4.5-fast-high").expect("grok fast high");
        let grok_fast = p.resolve("grok-4.5-fast").expect("grok fast");
        assert!((grok.input_per_million - grok_fast.input_per_million).abs() < 0.01);
        assert!((grok_fast.output_per_million - 12.0).abs() < 0.01);
        assert!(p.can_price("cursor-grok-4.5-fast-xhigh"));
        assert!(p.can_price("kimi-k2.7-code"));
        assert!(p.can_price("kimi-k2p7"));
    }

    #[test]
    fn v078_v079_pricing_aliases() {
        let p = ModelPricing::from_bundled();
        let k3 = p.resolve("kimi-k3").expect("kimi k3");
        assert!((k3.input_per_million - 3.0).abs() < 0.01);
        let grok46 = p.resolve("cursor-grok-4.6-fast-high").expect("grok 4.6");
        assert!((grok46.input_per_million - 4.0).abs() < 0.01);
        let opus5 = p.resolve("claude-opus-5").expect("opus 5");
        assert!((opus5.input_per_million - 5.0).abs() < 0.01);
        assert!(p.can_price("daybreak-blue-latest"));
        let router = p.resolve("Opus 5 (Auto Balanced)").expect("cursor router");
        assert!((router.input_per_million - 5.0).abs() < 0.01);
    }

    #[test]
    fn v0710_pricing_aliases_and_rates() {
        let p = ModelPricing::from_bundled();
        let glm = p.resolve("glm-5.3-high").expect("glm 5.3");
        assert!((glm.input_per_million - 1.4).abs() < 0.01);
        assert!((glm.output_per_million - 4.4).abs() < 0.01);
        assert!(p.can_price("gemini-3.7-flash"));
        assert!(p.can_price("gemini-3.6-flash"));
        assert_eq!(p.canonical_name("grok-proxy").as_deref(), Some("grok-build-0.1"));
        assert!(p.can_price("grok-4-6"));
        assert!(p.can_price("cursor-grok-4-6-fast"));
        let luna = p.resolve("gpt-5.6-luna").expect("luna");
        assert!((luna.input_per_million - 0.2).abs() < 0.01);
        assert!((luna.output_per_million - 1.2).abs() < 0.01);
        let luna_fast = p.resolve("gpt-5.6-luna-fast").expect("luna fast");
        assert!((luna_fast.input_per_million - 0.4).abs() < 0.01);
        assert!((luna_fast.output_per_million - 2.4).abs() < 0.01);
    }

    #[test]
    fn v0711_v0712_pricing_aliases_and_rates() {
        let p = ModelPricing::from_bundled();
        assert!(p.can_price("muse-spark-1.3"));
        assert!(p.can_price("muse-spark-1.3-high"));
        assert!(p.can_price("gpt-6-astra"));
        assert!(p.can_price("gpt-6-astra-fast"));
        assert!(p.can_price("gemini-3.8-flash"));
        assert!(p.can_price("claude-fable-5.1"));
        let astra = p.resolve("gpt-6-astra").expect("astra");
        assert!(astra.input_per_million > 0.0);
        let spark = p.resolve("muse-spark-1.3-xhigh").expect("spark");
        assert!((spark.input_per_million - 1.25).abs() < 0.01);
    }

    #[test]
    fn v0715_gemini_none_shorthand_aliases() {
        let p = ModelPricing::from_bundled();
        assert_eq!(p.canonical_name("gemini-2.5-flash-n").as_deref(), Some("gemini-2.5-flash"));
        assert_eq!(p.canonical_name("gemini-3-flash-n").as_deref(), Some("gemini-3-flash-preview"));
        assert_eq!(p.canonical_name("gemini-3.5-flash-n").as_deref(), Some("gemini-3.5-flash"));
        assert_eq!(p.canonical_name("gemini-3.6-flash-n").as_deref(), Some("gemini-3.6-flash"));
        assert_eq!(p.canonical_name("gemini-3.7-flash-n").as_deref(), Some("gemini-3.7-flash"));
        assert_eq!(p.canonical_name("gemini-3.8-flash-n").as_deref(), Some("gemini-3.8-flash"));
        assert_eq!(p.canonical_name("gemini-3-pro-n").as_deref(), Some("gemini-3-pro-preview"));
        assert_eq!(p.canonical_name("gemini-3-pro-none").as_deref(), Some("gemini-3-pro-preview"));
        assert_eq!(p.canonical_name("gemini-3-pro"), None);
        assert_eq!(p.canonical_name("gemini-3.1-pro-n").as_deref(), Some("gemini-3.1-pro-preview"));
    }

    #[test]
    fn request_wide_long_context_uses_higher_tier_for_all_fields() {
        let rates = ModelRates {
            input_per_million: 1.0,
            output_per_million: 2.0,
            cache_write_per_million: 1.0,
            cache_read_per_million: 0.1,
            cache_write_1h_per_million: None,
            prompt_rate_tiers: Vec::new(),
            input_above_200k: Some(10.0),
            output_above_200k: Some(20.0),
            cache_write_above_200k: Some(10.0),
            cache_read_above_200k: Some(1.0),
            cache_read_is_explicit: true,
            long_context_threshold_tokens: 200_000,
            fast_multiplier: 1.0,
        };
        let tokens = TokenBreakdown {
            input: 150_000,
            output: 1_000,
            cache_write5m: 40_000,
            cache_write1h: 0,
            cache_read: 20_000,
            is_fast: false,
        };
        // prompt = 210k → whole request at long-context rates
        let cost = rates.cost_dollars(&tokens);
        let expected = flat_cost(150_000, 10.0)
            + flat_cost(1_000, 20.0)
            + flat_cost(40_000, 10.0)
            + flat_cost(20_000, 1.0);
        assert!((cost - expected).abs() < 1e-9);
        let short = rates.cost_dollars_with_options(
            &TokenBreakdown {
                input: 1_000,
                output: 1_000,
                cache_write5m: 0,
                cache_write1h: 0,
                cache_read: 0,
                is_fast: false,
            },
            true,
        );
        assert!((short - flat_cost(1_000, 1.0) - flat_cost(1_000, 2.0)).abs() < 1e-9);
    }
}
