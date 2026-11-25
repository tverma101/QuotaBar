//! QuotaBar's own pricing feed (Swift `PricingSupplement.swift`): curated rate and cache overrides,
//! models no public catalog carries (Cursor-native `auto`, `composer-*`), fast multipliers the
//! catalogs omit, and alias rules mapping provider log/CSV slugs to canonical pricing keys. Bundled as
//! `pricing_supplement.json` and refreshed from the feed so entries update without a release.

use super::catalog::normalized_key;
use super::rates::{ModelRates, PromptRateTier};
use crate::qlog;
use crate::time;
use fancy_regex::Regex;
use serde::Deserialize;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

/// Slug pattern -> canonical pricing key. Patterns are ICU syntax (they were written for
/// `NSRegularExpression`) and match anywhere unless anchored.
#[derive(Clone)]
pub struct AliasRule {
    pub pattern: String,
    regex: Arc<Regex>,
    pub canonical: String,
}

impl AliasRule {
    pub fn new(pattern: &str, canonical: &str) -> Result<AliasRule, String> {
        let regex = Regex::new(pattern).map_err(|e| e.to_string())?;
        Ok(AliasRule {
            pattern: pattern.to_string(),
            regex: Arc::new(regex),
            canonical: canonical.to_string(),
        })
    }

    fn matches(&self, model: &str) -> bool {
        // A pathological pattern can exceed the backtracking limit; treat that as "no match" but say so.
        self.regex.is_match(model).unwrap_or_else(|error| {
            qlog!(
                Warn,
                "pricing",
                "alias pattern '{}' failed on a model name: {error}",
                self.pattern
            );
            false
        })
    }
}

#[derive(Clone, Default)]
pub struct PricingSupplement {
    pub pricing: HashMap<String, ModelRates>,
    /// Base model -> fast-variant multiplier for `-fast` slugs whose catalogs carry no `fast` field;
    /// also stamped onto the base entry so requests flagged fast by the scanner bill at that rate.
    pub fast_multipliers: HashMap<String, f64>,
    /// `fast_multipliers` keyed by normalized base, collisions resolved to the most specific raw key
    /// (longest, then smallest). Sorted for deterministic iteration.
    normalized_fast_multipliers: Vec<(String, f64)>,
    pub alias_rules: Vec<AliasRule>,
    /// Cursor-only aliases: Cursor's CSV can share a bare slug with a first-party API that publishes
    /// different rates.
    pub cursor_alias_rules: Vec<AliasRule>,
    pub retired_pricing_keys: HashSet<String>,
    pub retired_alias_patterns: HashSet<String>,
    pub retired_alias_patterns_are_authoritative: bool,
    pub updated_at: Option<String>,
}

impl PricingSupplement {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        pricing: HashMap<String, ModelRates>,
        fast_multipliers: HashMap<String, f64>,
        alias_rules: Vec<AliasRule>,
        cursor_alias_rules: Vec<AliasRule>,
        retired_pricing_keys: HashSet<String>,
        retired_alias_patterns: HashSet<String>,
        retired_alias_patterns_are_authoritative: bool,
        updated_at: Option<String>,
    ) -> PricingSupplement {
        let mut normalized: HashMap<String, (f64, usize, String)> = HashMap::new();
        for (base, multiplier) in &fast_multipliers {
            let key = normalized_key(base).into_owned();
            let specificity = base.chars().count();
            let replace = match normalized.get(&key) {
                None => true,
                Some((_, existing, raw)) => {
                    specificity > *existing || (specificity == *existing && base < raw)
                }
            };
            if replace {
                normalized.insert(key, (*multiplier, specificity, base.clone()));
            }
        }
        let mut normalized_fast_multipliers: Vec<(String, f64)> = normalized
            .into_iter()
            .map(|(k, (m, _, _))| (k, m))
            .collect();
        normalized_fast_multipliers.sort_by(|a, b| a.0.cmp(&b.0));
        PricingSupplement {
            pricing,
            fast_multipliers,
            normalized_fast_multipliers,
            alias_rules,
            cursor_alias_rules,
            retired_pricing_keys,
            retired_alias_patterns,
            retired_alias_patterns_are_authoritative,
            updated_at,
        }
    }

    pub fn canonical_name(&self, model: &str) -> Option<String> {
        self.alias_rules
            .iter()
            .find(|r| r.matches(model))
            .map(|r| r.canonical.clone())
    }

    pub fn cursor_canonical_name(&self, model: &str) -> Option<String> {
        self.cursor_alias_rules
            .iter()
            .find(|r| r.matches(model))
            .map(|r| r.canonical.clone())
    }

    /// Fast multiplier for a resolved base model: exact key, then ccusage's normalized-suffix match so
    /// dated keys (`gpt-5.5-2026-04-23`) find their base. The most specific base wins.
    pub fn fast_multiplier(&self, model: &str) -> Option<f64> {
        if let Some(exact) = self.fast_multipliers.get(model) {
            return Some(*exact);
        }
        let normalized = normalized_key(model);
        let mut best: Option<(&str, f64)> = None;
        for part in normalized.split(['/', ':']).filter(|p| !p.is_empty()) {
            for (base, multiplier) in &self.normalized_fast_multipliers {
                if !matches_model_suffix(part, base) {
                    continue;
                }
                let better = match best {
                    None => true,
                    Some((current, _)) => {
                        let (a, b) = (base.chars().count(), current.chars().count());
                        a > b || (a == b && base.as_str() < current)
                    }
                };
                if better {
                    best = Some((base, *multiplier));
                }
            }
        }
        best.map(|(_, m)| m)
    }

    /// Merge `other` on top: `other` wins per key, base-only keys survive, alias rules are unioned
    /// (other's first). A cached feed never erases a newly bundled pin.
    pub fn merging(&self, other: &PricingSupplement) -> PricingSupplement {
        let mut pricing = self.pricing.clone();
        pricing.extend(other.pricing.iter().map(|(k, v)| (k.clone(), v.clone())));
        let mut retired_keys: HashSet<String> = self
            .retired_pricing_keys
            .union(&other.retired_pricing_keys)
            .cloned()
            .collect();
        for key in other.pricing.keys() {
            if !other.retired_pricing_keys.contains(key) {
                retired_keys.remove(key);
            }
        }
        for key in &retired_keys {
            pricing.remove(key);
        }
        let mut multipliers = self.fast_multipliers.clone();
        multipliers.extend(other.fast_multipliers.iter().map(|(k, v)| (k.clone(), *v)));
        let mut rules = union_rules(&other.alias_rules, &self.alias_rules);
        let cursor_rules = union_rules(&other.cursor_alias_rules, &self.cursor_alias_rules);
        let mut retired_patterns: HashSet<String> = self
            .retired_alias_patterns
            .union(&other.retired_alias_patterns)
            .cloned()
            .collect();
        if other.retired_alias_patterns_are_authoritative {
            for rule in &other.alias_rules {
                if !other.retired_alias_patterns.contains(&rule.pattern) {
                    retired_patterns.remove(&rule.pattern);
                }
            }
        }
        rules.retain(|r| !retired_patterns.contains(&r.pattern));
        let updated_at = match (&self.updated_at, &other.updated_at) {
            (None, o) => o.clone(),
            (b, None) => b.clone(),
            (Some(b), Some(o)) => match (time::parse_feed_date(b), time::parse_feed_date(o)) {
                (Some(bd), Some(od)) => Some(if od > bd { o.clone() } else { b.clone() }),
                _ => Some(if o > b { o.clone() } else { b.clone() }),
            },
        };
        PricingSupplement::new(
            pricing,
            multipliers,
            rules,
            cursor_rules,
            retired_keys,
            retired_patterns,
            self.retired_alias_patterns_are_authoritative
                || other.retired_alias_patterns_are_authoritative,
            updated_at,
        )
    }

    /// Keep an authority snapshot's explicit removals when an older or independently refreshed overlay
    /// still carries those entries.
    pub fn preserving_retirements(
        &self,
        authority: &PricingSupplement,
        preserve_alias_patterns: bool,
    ) -> PricingSupplement {
        let retired_keys: HashSet<String> = self
            .retired_pricing_keys
            .union(&authority.retired_pricing_keys)
            .cloned()
            .collect();
        let retired_patterns: HashSet<String> = if preserve_alias_patterns {
            self.retired_alias_patterns
                .union(&authority.retired_alias_patterns)
                .cloned()
                .collect()
        } else {
            self.retired_alias_patterns.clone()
        };
        let mut pricing = self.pricing.clone();
        for key in &retired_keys {
            pricing.remove(key);
        }
        PricingSupplement::new(
            pricing,
            self.fast_multipliers.clone(),
            self.alias_rules
                .iter()
                .filter(|r| !retired_patterns.contains(&r.pattern))
                .cloned()
                .collect(),
            self.cursor_alias_rules.clone(),
            retired_keys,
            retired_patterns,
            self.retired_alias_patterns_are_authoritative
                || authority.retired_alias_patterns_are_authoritative,
            self.updated_at.clone(),
        )
    }

    /// Decode the supplement JSON (bundled or feed). Malformed JSON is an error; an individually
    /// invalid alias pattern is skipped and logged.
    pub fn decode(data: &[u8]) -> Result<PricingSupplement, String> {
        let file: SupplementFile =
            serde_json::from_slice(data).map_err(|e| format!("supplement JSON: {e}"))?;
        let fast = file.fast_multipliers.unwrap_or_default();
        let pricing = file
            .pricing
            .into_iter()
            .map(|(model, e)| {
                let tiers = e.prompt_rate_tiers.unwrap_or_default();
                let explicit = e.cache_read_per_million.is_some();
                let mut rates = ModelRates::new(
                    e.input_per_million,
                    e.output_per_million,
                    e.cache_write_per_million.unwrap_or(e.input_per_million),
                    e.cache_read_per_million.unwrap_or(e.input_per_million),
                );
                rates.cache_write_1h_per_million = e.cache_write_1h_per_million;
                rates.prompt_rate_tiers = tiers;
                rates.cache_read_is_explicit = explicit;
                // Scanners that flag fast mode on the request price the base slug, never `-fast`.
                rates.fast_multiplier = fast.get(&model).copied().unwrap_or(1.0);
                (model, rates)
            })
            .collect();
        let compile = |rules: Vec<RuleFile>, label: &str| -> Vec<AliasRule> {
            rules
                .into_iter()
                .filter_map(|r| match AliasRule::new(&r.pattern, &r.canonical) {
                    Ok(rule) => Some(rule),
                    Err(error) => {
                        qlog!(Warn, "pricing", "pricing supplement: invalid {label}alias pattern '{}' skipped: {error}", r.pattern);
                        None
                    }
                })
                .collect()
        };
        let authoritative = file.retired_alias_patterns.is_some();
        Ok(PricingSupplement::new(
            pricing,
            fast,
            compile(file.alias_rules, ""),
            compile(file.cursor_alias_rules.unwrap_or_default(), "Cursor "),
            file.retired_pricing_keys
                .unwrap_or_default()
                .into_iter()
                .collect(),
            file.retired_alias_patterns
                .unwrap_or_default()
                .into_iter()
                .collect(),
            authoritative,
            file.updated_at,
        ))
    }
}

fn union_rules(first: &[AliasRule], then: &[AliasRule]) -> Vec<AliasRule> {
    let seen: HashSet<&str> = first.iter().map(|r| r.pattern.as_str()).collect();
    first
        .iter()
        .cloned()
        .chain(
            then.iter()
                .filter(|r| !seen.contains(r.pattern.as_str()))
                .cloned(),
        )
        .collect()
}

/// `base` occurs in `part` (last occurrence) with nothing after it, or followed by `-`.
fn matches_model_suffix(part: &str, base: &str) -> bool {
    if base.is_empty() {
        return false;
    }
    match part.rfind(base) {
        Some(start) => {
            let suffix = &part[start + base.len()..];
            suffix.is_empty() || suffix.starts_with('-')
        }
        None => false,
    }
}

#[derive(Deserialize)]
struct SupplementFile {
    updated_at: Option<String>,
    pricing: HashMap<String, EntryFile>,
    fast_multipliers: Option<HashMap<String, f64>>,
    alias_rules: Vec<RuleFile>,
    cursor_alias_rules: Option<Vec<RuleFile>>,
    retired_pricing_keys: Option<Vec<String>>,
    retired_alias_patterns: Option<Vec<String>>,
}

#[derive(Deserialize)]
struct EntryFile {
    input_per_million: f64,
    output_per_million: f64,
    cache_write_per_million: Option<f64>,
    cache_read_per_million: Option<f64>,
    cache_write_1h_per_million: Option<f64>,
    prompt_rate_tiers: Option<Vec<PromptRateTier>>,
}

#[derive(Deserialize)]
struct RuleFile {
    pattern: String,
    canonical: String,
}
