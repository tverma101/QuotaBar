//! Pricing supplement lookups: curated rates and fast-variant multipliers.
//!
//! Mirror of `Pricing/PricingSupplement.swift`'s lookup half. Alias rules intentionally stay in
//! Swift: they are `NSRegularExpression` (ICU) patterns from a network-refreshed feed, and ICU is
//! the authority for what a rule matches. The fold passes one memoized canonical name per distinct
//! slug, so Rust never has to reinterpret a regex.

use std::collections::HashMap;

use super::super::accounting::ModelRates;
use super::catalog::normalized_key;

pub(crate) struct Supplement {
    pub pricing: HashMap<String, ModelRates>,
    fast_multipliers: HashMap<String, f64>,
    /// `fast_multipliers` keyed by `normalized_key(base)`, precomputed once at load. Collision
    /// policy: the most specific raw key (longest, then lexicographically smallest) wins.
    normalized_fast_multipliers: HashMap<String, f64>,
}

impl Supplement {
    pub fn new(
        pricing: HashMap<String, ModelRates>,
        fast_multipliers: HashMap<String, f64>,
    ) -> Self {
        let mut normalized: HashMap<String, (f64, usize, String)> = HashMap::new();
        for (base, multiplier) in &fast_multipliers {
            let key = normalized_key(base);
            let specificity = base.chars().count();
            match normalized.get(&key) {
                None => {
                    normalized.insert(key, (*multiplier, specificity, base.clone()));
                }
                Some((_, existing_specificity, existing_key))
                    if specificity > *existing_specificity
                        || (specificity == *existing_specificity && base < existing_key) =>
                {
                    normalized.insert(key, (*multiplier, specificity, base.clone()));
                }
                Some(_) => {}
            }
        }
        Self {
            pricing,
            fast_multipliers,
            normalized_fast_multipliers: normalized
                .into_iter()
                .map(|(key, (multiplier, _, _))| (key, multiplier))
                .collect(),
        }
    }

    /// Fast multiplier for a resolved base model. Exact key match first, then ccusage's
    /// normalized-suffix matching so dated keys (`gpt-5.5-2026-04-23`) still find their base entry.
    pub fn fast_multiplier(&self, model: &str) -> Option<f64> {
        if let Some(exact) = self.fast_multipliers.get(model) {
            return Some(*exact);
        }
        let normalized = normalized_key(model);
        let mut matches: Vec<(&str, f64)> = Vec::new();
        for part in normalized.split(['/', ':']).filter(|part| !part.is_empty()) {
            for (base, multiplier) in &self.normalized_fast_multipliers {
                if matches_model_suffix(part, base) {
                    matches.push((base.as_str(), *multiplier));
                }
            }
        }
        matches.sort_by(|lhs, rhs| {
            let lhs_len = lhs.0.chars().count();
            let rhs_len = rhs.0.chars().count();
            if lhs_len != rhs_len {
                return rhs_len.cmp(&lhs_len);
            }
            lhs.0.cmp(rhs.0)
        });
        matches.first().map(|(_, multiplier)| *multiplier)
    }
}

/// `base` occurs in `part` with nothing after it, or followed by a `-` separator.
fn matches_model_suffix(part: &str, base: &str) -> bool {
    if base.is_empty() {
        return false;
    }
    match part.rfind(base) {
        Some(index) => {
            let suffix = &part[index + base.len()..];
            suffix.is_empty() || suffix.starts_with('-')
        }
        None => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn supplement(multipliers: &[(&str, f64)]) -> Supplement {
        Supplement::new(
            HashMap::new(),
            multipliers
                .iter()
                .map(|(key, value)| (key.to_string(), *value))
                .collect(),
        )
    }

    #[test]
    fn exact_key_wins_then_suffix_matching_prefers_the_most_specific_base() {
        let supplement = supplement(&[("gpt-5", 2.0), ("gpt-5.5", 3.0), ("gpt-5.5-mini", 4.0)]);
        assert_eq!(supplement.fast_multiplier("gpt-5.5"), Some(3.0));
        assert_eq!(supplement.fast_multiplier("gpt-5.5-2026-04-23"), Some(3.0));
        assert_eq!(
            supplement.fast_multiplier("openai/gpt-5.5-mini-preview"),
            Some(4.0)
        );
        assert_eq!(supplement.fast_multiplier("unrelated"), None);
    }

    #[test]
    fn normalized_collisions_keep_the_most_specific_raw_key() {
        let supplement = supplement(&[("gpt-5.6", 2.0), ("gpt.5.6", 3.0)]);
        // Same normalized form; both raw keys are 7 characters, so the lexicographically
        // smaller one (`gpt-5.6`) wins, matching Swift's init.
        assert_eq!(supplement.fast_multiplier("gpt-5_6"), Some(2.0));
    }
}
