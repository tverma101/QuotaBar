//! Model-pricing resolution served from Rust.
//!
//! Mirror of the lookup half of `Pricing/ModelPricing.swift`: supplement overrides, OpenRouter /
//! LiteLLM / models.dev exact matches with separator-normalized retries, `-fast` variants priced
//! from their base entry, free-suffix handling, and LiteLLM fuzzy matching.
//!
//! A snapshot is built once per Swift `ModelPricing` (per catalogue refresh) and held behind a
//! numeric handle, so `claude.fold` / `codex.fold` take model names instead of one resolved
//! `ModelRates` per distinct slug. Alias-rule evaluation stays in Swift because the rules are ICU
//! (`NSRegularExpression`) patterns from a network-refreshed feed; the caller passes the canonical
//! name it already memoized for each slug, so the two engines cannot disagree about what a regex
//! matched. Swift keeps its own resolver as the parity oracle and the fallback when a load fails.

mod catalog;
mod supplement;

#[cfg(test)]
mod tests;

use std::collections::HashMap;
use std::sync::Mutex;

use serde_json::Value;

use super::accounting::ModelRates;
use super::{invalid_param, BackendError};
use catalog::{normalized_key, Catalog};
use supplement::Supplement;

/// Immutable catalogue snapshot plus the per-name memo shared by every fold that uses it.
pub(crate) struct Snapshot {
    supplement: Supplement,
    primary: Catalog,
    secondary: Catalog,
    open_router: Catalog,
    memo: Mutex<HashMap<String, MemoEntry>>,
}

struct MemoEntry {
    rates: Option<ModelRates>,
    needs_report: bool,
    reported: bool,
}

impl Snapshot {
    fn from_params(params: &Value) -> Result<Self, BackendError> {
        let supplement_value = params
            .get("supplement")
            .and_then(Value::as_object)
            .ok_or_else(|| invalid_param("missing `supplement` object".to_string()))?;
        let pricing = decode_rates_map(supplement_value.get("pricing"), "supplement.pricing")?;
        let fast_multipliers = match supplement_value.get("fastMultipliers") {
            None | Some(Value::Null) => HashMap::new(),
            Some(value) => serde_json::from_value(value.clone()).map_err(|error| {
                invalid_param(format!("invalid `supplement.fastMultipliers`: {error}"))
            })?,
        };
        Ok(Self {
            supplement: Supplement::new(pricing, fast_multipliers),
            primary: Catalog::new(decode_rates_map(params.get("primary"), "primary")?),
            secondary: Catalog::new(decode_rates_map(params.get("secondary"), "secondary")?),
            open_router: Catalog::new(decode_rates_map(params.get("openRouter"), "openRouter")?),
            memo: Mutex::new(HashMap::new()),
        })
    }

    /// Rates for `model`, or nil when no source can price it.
    ///
    /// `canonical` is the alias-rule result Swift already memoized for this exact name (nil when no
    /// rule matched). Names whose first `resolve` finds no curated/exact-OpenRouter rate are
    /// appended to `recheck` once per snapshot, mirroring `ModelPricing`'s discovery hook.
    fn resolve(
        &self,
        model: &str,
        canonical: Option<&str>,
        recheck: &mut Vec<String>,
    ) -> Option<ModelRates> {
        let mut memo = self.memo.lock().unwrap_or_else(|error| error.into_inner());
        if let Some(entry) = memo.get_mut(model) {
            if entry.needs_report && !entry.reported {
                entry.reported = true;
                recheck.push(model.to_string());
            }
            return entry.rates.clone();
        }

        let rates = self.resolve_uncached(model, canonical);
        let needs_report = match rates {
            Some(_) => {
                !self.has_exact_open_router_rate(model, canonical)
                    && !self.has_curated_supplement_rate(model, canonical)
            }
            None => true,
        };
        memo.insert(
            model.to_string(),
            MemoEntry {
                rates: rates.clone(),
                needs_report,
                reported: needs_report,
            },
        );
        if needs_report {
            recheck.push(model.to_string());
        }
        rates
    }

    fn clear_memo(&self) {
        let mut memo = self.memo.lock().unwrap_or_else(|error| error.into_inner());
        memo.clear();
    }

    fn resolve_uncached(&self, model: &str, canonical: Option<&str>) -> Option<ModelRates> {
        if let Some(canonical) = canonical {
            if canonical != model {
                return self.lookup(canonical).or_else(|| self.lookup(model));
            }
        }
        self.lookup(model)
    }

    /// The secondary catalogue is consulted only after the whole primary lookup misses, like
    /// ccusage. models.dev answers exact ids only.
    fn lookup(&self, name: &str) -> Option<ModelRates> {
        if let Some(entry) = self.supplement.pricing.get(name) {
            return Some(entry.clone());
        }
        if let Some(exact) = self.open_router.find_exact(name) {
            return Some(self.with_supplement_fast_multiplier(name, exact));
        }
        if let Some(exact) = self.primary.find_exact(name) {
            return Some(self.with_supplement_fast_multiplier(name, exact));
        }
        let normalized = normalized_key(name);
        if normalized != name {
            if let Some(entry) = self.supplement.pricing.get(&normalized) {
                return Some(entry.clone());
            }
            if let Some(exact) = self.open_router.find_exact(&normalized) {
                return Some(self.with_supplement_fast_multiplier(name, exact));
            }
            if let Some(exact) = self.primary.find_exact(&normalized) {
                return Some(self.with_supplement_fast_multiplier(name, exact));
            }
        }
        if let Some(fast) = self.fast_variant(name) {
            return Some(fast);
        }
        // An exact models.dev card is the only remaining source for a `-fast` slug; the
        // standard-speed base rate is never fuzzy-matched.
        if name.ends_with("-fast") {
            return self.secondary.find_exact(name).cloned();
        }
        // A free-looking sibling must not inherit a paid catalogue entry through fuzzy matching.
        if has_free_suffix(name) {
            return self.secondary.find_exact(name).cloned();
        }
        if let Some((_, fuzzy)) = self.primary.find_fuzzy(name) {
            return Some(self.with_supplement_fast_multiplier(name, fuzzy));
        }
        if let Some(exact) = self.secondary.find_exact(name) {
            return Some(self.with_supplement_fast_multiplier(name, exact));
        }
        None
    }

    /// Feeds can drop the fast multiplier (LiteLLM removed Anthropic's `fast` fields), so fall back
    /// to the supplement's curated multiplier. Never touches dedicated `-fast` cards or entries
    /// whose multiplier the feed does supply.
    fn with_supplement_fast_multiplier(&self, name: &str, rates: &ModelRates) -> ModelRates {
        let mut stamped = rates.clone();
        if !name.ends_with("-fast") && stamped.fast_multiplier == 1.0 {
            if let Some(multiplier) = self.supplement.fast_multiplier(name) {
                stamped.fast_multiplier = multiplier;
            }
        }
        stamped
    }

    /// Prices `<base>-fast` slugs from their base entry when a fast multiplier is known. Returns
    /// nil when the multiplier is unknown; an exact models.dev fast entry is still accepted above.
    fn fast_variant(&self, name: &str) -> Option<ModelRates> {
        let base = name.strip_suffix("-fast")?;
        if base.is_empty() {
            return None;
        }
        let (key, rates) = self.base_entry(base)?;
        let multiplier = if rates.fast_multiplier != 1.0 {
            rates.fast_multiplier
        } else if let Some(multiplier) = self
            .supplement
            .fast_multiplier(&key)
            .or_else(|| self.supplement.fast_multiplier(base))
        {
            multiplier
        } else {
            return None;
        };
        Some(rates.scaled(multiplier))
    }

    fn base_entry(&self, base: &str) -> Option<(String, ModelRates)> {
        if let Some(entry) = self.supplement.pricing.get(base) {
            return Some((base.to_string(), entry.clone()));
        }
        if let Some(entry) = self.open_router.find_exact(base) {
            return Some((base.to_string(), entry.clone()));
        }
        if let Some(entry) = self.primary.find_exact(base) {
            return Some((base.to_string(), entry.clone()));
        }
        if let Some(dated) = self.dated_primary_entry(base) {
            return Some(dated);
        }
        self.secondary
            .find_exact(base)
            .map(|entry| (base.to_string(), entry.clone()))
    }

    /// Historical dated-slug compatibility for fast variants. Only a `-YYYYMMDD` (or
    /// `-YYYY-MM-DD`) suffix of the base slug qualifies, never a nearby sibling.
    fn dated_primary_entry(&self, base: &str) -> Option<(String, ModelRates)> {
        let normalized_base = normalized_key(base);
        let base_has_provider_prefix = normalized_base.contains('/');
        let base_slug = normalized_base
            .rsplit('/')
            .next()
            .unwrap_or(&normalized_base)
            .to_string();
        let mut candidates: Vec<(String, String, ModelRates)> = Vec::new();
        for (key, rates) in self.primary.entries() {
            let normalized = normalized_key(key);
            let candidate_slug = normalized
                .rsplit('/')
                .next()
                .unwrap_or(&normalized)
                .to_string();
            let comparable_base = if base_has_provider_prefix {
                &normalized_base
            } else {
                &base_slug
            };
            let comparable_key = if base_has_provider_prefix {
                &normalized
            } else {
                &candidate_slug
            };
            let dated_prefix = format!("{comparable_base}-");
            let Some(suffix) = comparable_key.strip_prefix(&dated_prefix) else {
                continue;
            };
            if suffix.len() < 8 {
                continue;
            }
            let date = &suffix[..8];
            if !date.bytes().all(|byte| byte.is_ascii_digit()) {
                continue;
            }
            if suffix.len() != 8 && suffix.as_bytes().get(8) != Some(&b'-') {
                continue;
            }
            candidates.push((key.clone(), date.to_string(), rates.clone()));
        }
        candidates.sort_by(|lhs, rhs| {
            if lhs.1 != rhs.1 {
                return rhs.1.cmp(&lhs.1);
            }
            if lhs.0.len() == rhs.0.len() {
                lhs.0.cmp(&rhs.0)
            } else {
                rhs.0.len().cmp(&lhs.0.len())
            }
        });
        candidates
            .into_iter()
            .next()
            .map(|(key, _, rates)| (key, rates))
    }

    /// Whether OpenRouter itself has an exact rate for this name. Deliberately ignores LiteLLM
    /// fuzzy matches and models.dev.
    fn has_exact_open_router_rate(&self, model: &str, canonical: Option<&str>) -> bool {
        if self.open_router.find_exact(model).is_some() {
            return true;
        }
        if let Some(canonical) = canonical {
            if self.open_router.find_exact(canonical).is_some() {
                return true;
            }
        }
        let normalized = normalized_key(model);
        normalized != model && self.open_router.find_exact(&normalized).is_some()
    }

    fn has_curated_supplement_rate(&self, model: &str, canonical: Option<&str>) -> bool {
        if self.supplement.pricing.contains_key(model) {
            return true;
        }
        let normalized = normalized_key(model);
        if self.supplement.pricing.contains_key(&normalized) {
            return true;
        }
        canonical.is_some_and(|canonical| self.supplement.pricing.contains_key(canonical))
    }
}

fn decode_rates_map(
    value: Option<&Value>,
    label: &str,
) -> Result<HashMap<String, ModelRates>, BackendError> {
    let Some(value) = value else {
        return Err(invalid_param(format!("missing `{label}` rates object")));
    };
    if value.is_null() {
        return Ok(HashMap::new());
    }
    serde_json::from_value(value.clone())
        .map_err(|error| invalid_param(format!("invalid `{label}` rates: {error}")))
}

fn has_free_suffix(name: &str) -> bool {
    let normalized = normalized_key(name).to_lowercase();
    let last_segment = normalized.rsplit('/').next().unwrap_or(&normalized);
    last_segment.ends_with("-free")
}

mod registry;

pub(crate) use registry::{clear, load, release, resolve_op, FoldPricing};
