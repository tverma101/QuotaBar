//! An immutable pricing snapshot with ccusage's resolution order (Swift `ModelPricing.swift`).
//!
//! Resolution for a model name:
//! 1. Supplement alias rules rewrite the slug to a canonical key (the raw name is the fallback).
//! 2. Supplement pricing (exact): curated rates, Cursor-native models, cache details.
//! 3. OpenRouter exact: live route prices and unique bare aliases.
//! 4. LiteLLM exact, then the separator-normalized retry of 2-4.
//! 5. `-fast` suffix: price the base model scaled by its fast multiplier; with no multiplier, only an
//!    exact models.dev fast entry may price it (never the standard-speed base rate).
//! 6. LiteLLM fuzzy (boundary-aware), not for `-free` siblings.
//! 7. models.dev exact only: it aggregates resellers under near-identical ids with diverging rates,
//!    so fuzzy matching against it risks wrong dollars.

use super::catalog::{normalized_key, PricingCatalog};
use super::rates::{ModelRates, TokenBreakdown};
use super::supplement::PricingSupplement;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::sync::{Arc, OnceLock, RwLock};

/// Called once per distinct name lacking a curated rate and an exact OpenRouter rate (including
/// fallback-priced names), so discovery can revalidate the public catalogue.
pub type RecheckHook = Arc<dyn Fn(&str) + Send + Sync>;

#[derive(Clone)]
enum MemoEntry {
    Rates {
        rates: Arc<ModelRates>,
        needs_recheck: bool,
        reported: bool,
    },
    Unresolved {
        reported: bool,
    },
}

impl MemoEntry {
    fn wants_report(&self) -> bool {
        matches!(
            self,
            MemoEntry::Rates {
                needs_recheck: true,
                reported: false,
                ..
            } | MemoEntry::Unresolved { reported: false }
        )
    }
}

pub struct ModelPricing {
    pub supplement: PricingSupplement,
    pub open_router: PricingCatalog,
    /// LiteLLM (bundled snapshot merged with fetched data).
    pub primary: PricingCatalog,
    /// models.dev, exact-id gap filler.
    pub secondary: PricingCatalog,
    on_recheck: Option<RecheckHook>,
    memo: RwLock<HashMap<String, MemoEntry>>,
    canonical_memo: RwLock<HashMap<String, Option<String>>>,
    cursor_canonical_memo: RwLock<HashMap<String, Option<String>>>,
    cache_token: OnceLock<String>,
}

impl Default for ModelPricing {
    fn default() -> Self {
        ModelPricing::new(
            PricingSupplement::default(),
            PricingCatalog::default(),
            PricingCatalog::default(),
            PricingCatalog::default(),
            None,
        )
    }
}

impl ModelPricing {
    pub fn new(
        supplement: PricingSupplement,
        primary: PricingCatalog,
        secondary: PricingCatalog,
        open_router: PricingCatalog,
        on_recheck: Option<RecheckHook>,
    ) -> ModelPricing {
        ModelPricing {
            supplement,
            open_router,
            primary,
            secondary,
            on_recheck,
            memo: RwLock::default(),
            canonical_memo: RwLock::default(),
            cursor_canonical_memo: RwLock::default(),
            cache_token: OnceLock::new(),
        }
    }

    /// Rates for `model`, or `None` when no source can price it (the caller flags the unknown model
    /// and counts its tokens at $0).
    pub fn resolve(&self, model: &str) -> Option<Arc<ModelRates>> {
        let entry = self.memoized_entry(model);
        if entry.wants_report() {
            self.report_recheck(model);
        }
        match entry {
            MemoEntry::Rates { rates, .. } => Some(rates),
            MemoEntry::Unresolved { .. } => None,
        }
    }

    /// `resolve` without the discovery report (identity probes walk several spellings of one slug).
    pub fn is_priced(&self, model: &str) -> bool {
        matches!(self.memoized_entry(model), MemoEntry::Rates { .. })
    }

    pub fn estimated_cost_dollars(
        &self,
        model: &str,
        tokens: &TokenBreakdown,
        timestamp: Option<f64>,
        apply_long_context_rates: bool,
    ) -> Option<f64> {
        self.resolve(model)
            .map(|r| r.cost_dollars(tokens, timestamp, apply_long_context_rates))
    }

    /// Cursor's usage CSV: scoped aliases may select Cursor-specific rates (`cursor-<canonical>`);
    /// every other model goes through the shared lookup.
    pub fn estimated_cursor_cost_dollars(
        &self,
        model: &str,
        tokens: &TokenBreakdown,
        apply_long_context_rates: bool,
    ) -> Option<f64> {
        let rates = match self.cursor_canonical_name(model) {
            Some(canonical) => self
                .lookup(&format!("cursor-{canonical}"))
                .or_else(|| self.lookup(&canonical))
                .map(Arc::new)
                .or_else(|| self.resolve(model)),
            None => self.resolve(model),
        }?;
        Some(rates.cost_dollars(tokens, None, apply_long_context_rates))
    }

    /// The catalog key a slug should be identified by: the shortest candidate with an exact entry
    /// (the bare model id), else the first candidate that prices at all. Gateway-tagged slugs
    /// (`anthropic/openai/gpt-5.6-luna`) price fuzzily, but must group under their bare id.
    pub fn canonical_key(&self, candidates: &[String]) -> Option<String> {
        let mut ordered: Vec<&String> = candidates.iter().collect();
        ordered.sort_by_key(|c| c.chars().count());
        for candidate in ordered {
            if let Some(key) = self.exact_key(candidate) {
                return Some(key);
            }
        }
        candidates.iter().find(|c| self.is_priced(c)).cloned()
    }

    fn exact_key(&self, candidate: &str) -> Option<String> {
        if let Some(hit) = self.canonical_name(candidate) {
            return Some(hit);
        }
        let known = self.supplement.pricing.contains_key(candidate)
            || self.open_router.entries.contains_key(candidate)
            || self.primary.entries.contains_key(candidate)
            || self.secondary.entries.contains_key(candidate);
        known.then(|| candidate.to_string())
    }

    pub fn canonical_name(&self, model: &str) -> Option<String> {
        memoized(&self.canonical_memo, model, || {
            self.supplement.canonical_name(model)
        })
    }

    pub fn cursor_canonical_name(&self, model: &str) -> Option<String> {
        memoized(&self.cursor_canonical_memo, model, || {
            self.supplement.cursor_canonical_name(model)
        })
    }

    /// Whether OpenRouter itself has an exact rate (never a fallback estimate).
    pub fn has_exact_open_router_rate(&self, model: &str) -> bool {
        if self.open_router.entries.contains_key(model) {
            return true;
        }
        if let Some(canonical) = self.canonical_name(model) {
            if self.open_router.entries.contains_key(&canonical) {
                return true;
            }
        }
        let normalized = normalized_key(model);
        normalized != model && self.open_router.entries.contains_key(normalized.as_ref())
    }

    fn has_curated_supplement_rate(&self, model: &str) -> bool {
        let pricing = &self.supplement.pricing;
        pricing.contains_key(model)
            || pricing.contains_key(normalized_key(model).as_ref())
            || self
                .canonical_name(model)
                .is_some_and(|c| pricing.contains_key(&c))
    }

    /// A stable fingerprint of every rate and rule; equal catalogues give equal tokens across launches
    /// (retrieval dates are excluded, so revalidating an unchanged feed does not invalidate folds).
    pub fn aggregate_cache_token(&self) -> &str {
        self.cache_token.get_or_init(|| {
            let mut hasher = Sha256::new();
            hasher.update(b"engine-pricing-v1\n");
            for (name, entries) in [
                ("primary", &self.primary.entries),
                ("secondary", &self.secondary.entries),
                ("openRouter", &self.open_router.entries),
                ("supplement", &self.supplement.pricing),
            ] {
                hasher.update(name.as_bytes());
                let mut keys: Vec<&String> = entries.keys().collect();
                keys.sort();
                for key in keys {
                    hasher.update(key.as_bytes());
                    hasher.update(serde_json::to_vec(&entries[key]).unwrap_or_default());
                    hasher.update(b"\n");
                }
            }
            for rule in &self.supplement.alias_rules {
                hasher.update(format!("alias:{}:{}\n", rule.pattern, rule.canonical).as_bytes());
            }
            for rule in &self.supplement.cursor_alias_rules {
                hasher.update(
                    format!("cursor-alias:{}:{}\n", rule.pattern, rule.canonical).as_bytes(),
                );
            }
            let mut retired: Vec<&String> = self.supplement.retired_pricing_keys.iter().collect();
            retired.sort();
            for key in retired {
                hasher.update(format!("retired-pricing:{key}\n").as_bytes());
            }
            let mut fast: Vec<(&String, &f64)> = self.supplement.fast_multipliers.iter().collect();
            fast.sort_by(|a, b| a.0.cmp(b.0));
            for (key, multiplier) in fast {
                hasher.update(format!("fast:{key}:{multiplier:?}\n").as_bytes());
            }
            hasher
                .finalize()
                .iter()
                .take(16)
                .map(|b| format!("{b:02x}"))
                .collect()
        })
    }

    /// Release memoized lookups and the lazy fuzzy indexes.
    pub fn clear_caches(&self) {
        self.memo.write().unwrap_or_else(|e| e.into_inner()).clear();
        self.canonical_memo
            .write()
            .unwrap_or_else(|e| e.into_inner())
            .clear();
        self.cursor_canonical_memo
            .write()
            .unwrap_or_else(|e| e.into_inner())
            .clear();
        self.primary.clear_fuzzy_index();
        self.secondary.clear_fuzzy_index();
        self.open_router.clear_fuzzy_index();
    }

    // MARK: resolution

    fn memoized_entry(&self, model: &str) -> MemoEntry {
        if let Some(entry) = self
            .memo
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .get(model)
        {
            return entry.clone();
        }
        let candidate = match self.resolve_uncached(model) {
            Some(rates) => MemoEntry::Rates {
                rates: Arc::new(rates),
                needs_recheck: !self.has_exact_open_router_rate(model)
                    && !self.has_curated_supplement_rate(model),
                reported: false,
            },
            None => MemoEntry::Unresolved { reported: false },
        };
        // Concurrent scans may resolve the same name at once; the first memoized result wins.
        self.memo
            .write()
            .unwrap_or_else(|e| e.into_inner())
            .entry(model.to_string())
            .or_insert(candidate)
            .clone()
    }

    /// Flip the entry to reported under the lock, then call the hook outside it, so a name is handed
    /// to discovery at most once per snapshot.
    fn report_recheck(&self, model: &str) {
        let Some(hook) = &self.on_recheck else { return };
        let report = {
            let mut memo = self.memo.write().unwrap_or_else(|e| e.into_inner());
            match memo.get_mut(model) {
                Some(MemoEntry::Rates {
                    needs_recheck: true,
                    reported,
                    ..
                })
                | Some(MemoEntry::Unresolved { reported })
                    if !*reported =>
                {
                    *reported = true;
                    true
                }
                _ => false,
            }
        };
        if report {
            hook(model);
        }
    }

    fn resolve_uncached(&self, model: &str) -> Option<ModelRates> {
        match self.canonical_name(model) {
            Some(canonical) if canonical != model => {
                self.lookup(&canonical).or_else(|| self.lookup(model))
            }
            _ => self.lookup(model),
        }
    }

    fn lookup(&self, name: &str) -> Option<ModelRates> {
        if let Some(entry) = self.supplement.pricing.get(name) {
            return Some(entry.clone());
        }
        if let Some((_, rates)) = self.open_router.find_exact(name) {
            return Some(self.with_supplement_fast_multiplier(name, rates));
        }
        if let Some((_, rates)) = self.primary.find_exact(name) {
            return Some(self.with_supplement_fast_multiplier(name, rates));
        }
        // Separator-normalized exact retry ("space bunny" vs "space-bunny"); exact-only, so it cannot
        // widen what a miss matches.
        let normalized = normalized_key(name);
        if normalized != name {
            if let Some(entry) = self.supplement.pricing.get(normalized.as_ref()) {
                return Some(entry.clone());
            }
            if let Some((_, rates)) = self.open_router.find_exact(&normalized) {
                return Some(self.with_supplement_fast_multiplier(name, rates));
            }
            if let Some((_, rates)) = self.primary.find_exact(&normalized) {
                return Some(self.with_supplement_fast_multiplier(name, rates));
            }
        }
        if let Some(fast) = self.fast_variant(name) {
            return Some(fast);
        }
        if name.ends_with("-fast") || has_free_suffix(name) {
            // A free-looking sibling must not inherit a paid entry through the fuzzy matcher.
            return self.secondary.find_exact(name).map(|(_, r)| r.clone());
        }
        if let Some((_, rates)) = self.primary.find_fuzzy(name) {
            return Some(self.with_supplement_fast_multiplier(name, rates));
        }
        self.secondary
            .find_exact(name)
            .map(|(_, rates)| self.with_supplement_fast_multiplier(name, rates))
    }

    /// Feeds can drop their own fast multiplier (LiteLLM removed Anthropic's in October 2026); fall
    /// back to the supplement's so a request flagged fast on the base slug still bills fast.
    fn with_supplement_fast_multiplier(&self, name: &str, rates: &ModelRates) -> ModelRates {
        if name.ends_with("-fast") || rates.fast_multiplier != 1.0 {
            return rates.clone();
        }
        match self.supplement.fast_multiplier(name) {
            Some(multiplier) => ModelRates {
                fast_multiplier: multiplier,
                ..rates.clone()
            },
            None => rates.clone(),
        }
    }

    fn fast_variant(&self, name: &str) -> Option<ModelRates> {
        let base = name.strip_suffix("-fast").filter(|b| !b.is_empty())?;
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

    fn base_entry(&self, base: &str) -> Option<(String, &ModelRates)> {
        if let Some(entry) = self.supplement.pricing.get(base) {
            return Some((base.to_string(), entry));
        }
        if let Some((key, rates)) = self
            .open_router
            .find_exact(base)
            .or_else(|| self.primary.find_exact(base))
        {
            return Some((key.to_string(), rates));
        }
        self.dated_primary_entry(base).or_else(|| {
            self.secondary
                .find_exact(base)
                .map(|(k, r)| (k.to_string(), r))
        })
    }

    /// Dated-slug compatibility for fast variants (`gpt-9` -> `gpt-9-20260101`) without letting a
    /// sibling such as `gpt-9-pro` supply the base rates. Newest date wins, then the longer key.
    fn dated_primary_entry(&self, base: &str) -> Option<(String, &ModelRates)> {
        let normalized_base = normalized_key(base);
        let has_prefix = normalized_base.contains('/');
        let comparable_base = if has_prefix {
            normalized_base.as_ref()
        } else {
            last_segment(&normalized_base)
        };
        let dated_prefix = format!("{comparable_base}-");
        let mut best: Option<([u8; 8], &str, &ModelRates)> = None; // (date, key, rates)
        for (key, rates) in &self.primary.entries {
            let normalized = normalized_key(key);
            let comparable = if has_prefix {
                normalized.as_ref()
            } else {
                last_segment(&normalized)
            };
            let Some(suffix) = comparable.strip_prefix(dated_prefix.as_str()) else {
                continue;
            };
            let bytes = suffix.as_bytes();
            if bytes.len() < 8
                || !bytes[..8].iter().all(u8::is_ascii_digit)
                || !(bytes.len() == 8 || bytes[8] == b'-')
            {
                continue;
            }
            let mut date = [0u8; 8];
            date.copy_from_slice(&bytes[..8]);
            let better = match best {
                None => true,
                Some((best_date, best_key, _)) => {
                    if date != best_date {
                        date > best_date
                    } else {
                        let (a, b) = (key.chars().count(), best_key.chars().count());
                        if a == b {
                            key.as_str() < best_key
                        } else {
                            a > b
                        }
                    }
                }
            };
            if better {
                best = Some((date, key, rates));
            }
        }
        best.map(|(_, key, rates)| (key.to_string(), rates))
    }
}

/// Swift `split(separator: "/").last ?? value` (empty components omitted).
fn last_segment(value: &str) -> &str {
    value
        .split('/')
        .filter(|s| !s.is_empty())
        .last()
        .unwrap_or(value)
}

fn has_free_suffix(name: &str) -> bool {
    let normalized = normalized_key(name).to_lowercase();
    last_segment(&normalized).ends_with("-free")
}

fn memoized(
    memo: &RwLock<HashMap<String, Option<String>>>,
    key: &str,
    compute: impl FnOnce() -> Option<String>,
) -> Option<String> {
    if let Some(hit) = memo.read().unwrap_or_else(|e| e.into_inner()).get(key) {
        return hit.clone();
    }
    let value = compute();
    memo.write()
        .unwrap_or_else(|e| e.into_inner())
        .insert(key.to_string(), value.clone());
    value
}
