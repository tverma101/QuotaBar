//! Accumulates priced per-day usage — tokens, cost and the per-model breakdown — then assembles a
//! [`LogUsageScan`] (Swift `DailyUsageAccumulator`). Shared by the log scanners (Claude, Codex, Grok)
//! so the "accumulate then assemble" tail lives in one place; each scanner keeps only its
//! format-specific parse/pricing loop.
//!
//! Days are keyed by the shared local-calendar day key. Unpriced rows are added token-only (no cost)
//! and flagged for the reveal system, so token totals stay complete while dollar subtotals retain
//! priced usage.

use super::scan::LogUsageScan;
use super::{adding_finite_cost, adding_saturating, cost_desc, localized_standard_compare};
use crate::model::{
    DailyModelUsageEntry, DailyUsageEntry, DailyUsageSeries, ModelUsageEntry, ModelUsageSeries,
    ModelUsageVariant, ReportedUsageCost,
};
use std::collections::{BTreeMap, BTreeSet};

/// Optional attributes of one [`DailyUsageAccumulator::add_with`] row.
#[derive(Clone, Copy, Debug)]
pub struct RowOptions<'a> {
    /// The model's identity when it differs from the emitted slug (a gateway-tagged spelling).
    pub canonical: Option<&'a str>,
    pub cost_is_complete: bool,
    pub token_count_saturated: bool,
}

impl Default for RowOptions<'_> {
    fn default() -> Self {
        RowOptions { canonical: None, cost_is_complete: true, token_count_saturated: false }
    }
}

#[derive(Clone, Debug, Default)]
pub struct DailyUsageAccumulator {
    pub(super) tokens_by_day: BTreeMap<String, i64>,
    pub(super) cost_by_day: BTreeMap<String, f64>,
    pub(super) estimated_cost_days: BTreeSet<String>,
    pub(super) api_estimate_by_day: BTreeMap<String, f64>,
    pub(super) api_estimate_incomplete_days: BTreeSet<String>,
    pub(super) unknown_models_by_day: BTreeMap<String, BTreeSet<String>>,
    pub(super) named_unpriced_models_by_day: BTreeMap<String, BTreeSet<String>>,
    pub(super) incomplete_cost_days: BTreeSet<String>,
    pub(super) structural_incomplete_cost_days: BTreeSet<String>,
    pub(super) incomplete_model_costs_by_day: BTreeMap<String, BTreeSet<String>>,
    pub(super) token_count_saturated_days: BTreeSet<String>,
    pub(super) models_by_day: BTreeMap<String, BTreeMap<String, ModelAccumulator>>,
    pub(super) overflowed_cost_days: BTreeSet<String>,
    pub(super) overflowed_api_estimate_days: BTreeSet<String>,
    pub(super) unmeasured_usage_days: BTreeSet<String>,
    /// Provider-reported dollars per day with the tokens they cover (Swift `ReportedUsageCostAccumulator`).
    pub(super) reported_costs: BTreeMap<String, ReportedUsageCost>,
    pub(super) overflowed_reported_days: BTreeSet<String>,
}

impl DailyUsageAccumulator {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn mark_unmeasured_usage(&mut self, day: &str) {
        self.unmeasured_usage_days.insert(day.to_string());
    }

    /// Add a row's tokens and cost, attributed to `model` on `day`, with default options.
    pub fn add(&mut self, day: &str, tokens: i64, cost: Option<f64>, model: &str) {
        self.add_with(day, tokens, cost, model, RowOptions::default());
    }

    /// Add a row's tokens + cost, attributed to `model` on `day`.
    ///
    /// `options.canonical` is the model's *identity*; `model` is the slug the provider actually
    /// emitted. They differ when a gateway tags its slugs: one model then arrives as both
    /// `gpt-5.6-luna` and `anthropic/openai/gpt-5.6-luna`. Scanners that resolve pricing pass the
    /// catalog key as `canonical`, so anything priced alike collapses into one row while the observed
    /// spellings survive as tooltip variants.
    ///
    /// `cost` is `None` for a row no pricing source can price. Those rows count their tokens and leave
    /// their own model cost blank; priced models on the same day retain their subtotal with an
    /// incomplete-cost marker.
    pub fn add_with(&mut self, day: &str, tokens: i64, cost: Option<f64>, model: &str, options: RowOptions<'_>) {
        let prior_tokens = self.tokens_by_day.get(day).copied().unwrap_or(0);
        if tokens > 0 && prior_tokens > i64::MAX - tokens {
            self.token_count_saturated_days.insert(day.to_string());
        }
        if options.token_count_saturated {
            self.token_count_saturated_days.insert(day.to_string());
        }
        self.tokens_by_day.insert(day.to_string(), adding_saturating(prior_tokens, tokens));
        if let Some(cost) = cost {
            if self.overflowed_cost_days.contains(day) {
                self.incomplete_cost_days.insert(day.to_string());
            } else if let Some(total) = adding_finite_cost(self.cost_by_day.get(day).copied(), cost) {
                self.cost_by_day.insert(day.to_string(), total);
            } else {
                self.overflowed_cost_days.insert(day.to_string());
                self.incomplete_cost_days.insert(day.to_string());
            }
        } else if tokens > 0 {
            self.incomplete_cost_days.insert(day.to_string());
            self.incomplete_model_costs_by_day.entry(day.to_string()).or_default().insert(model.to_string());
        }
        if !options.cost_is_complete {
            self.incomplete_cost_days.insert(day.to_string());
            self.incomplete_model_costs_by_day.entry(day.to_string()).or_default().insert(model.to_string());
        }
        let identity = options.canonical.unwrap_or(model);
        self.models_by_day
            .entry(day.to_string())
            .or_default()
            .entry(identity.to_string())
            .or_default()
            .add(tokens, cost, model, options.cost_is_complete, options.token_count_saturated);
    }

    /// Swift `ReportedUsageCostAccumulator.add`: sum the provider-reported dollars of a day with the
    /// tokens they cover. A negative, non-finite or overflowing amount is dropped (an overflowing day
    /// loses its reported cost for good).
    pub fn add_reported_cost(&mut self, day: &str, dollars: Option<f64>, tokens: i64) {
        let Some(dollars) = dollars.filter(|d| d.is_finite() && *d >= 0.0) else { return };
        if tokens < 0 || self.overflowed_reported_days.contains(day) {
            return;
        }
        let prior = self.reported_costs.get(day).cloned().unwrap_or(ReportedUsageCost { dollars: 0.0, covered_tokens: 0 });
        let total = prior.dollars + dollars;
        if !total.is_finite() {
            self.reported_costs.remove(day);
            self.overflowed_reported_days.insert(day.to_string());
            return;
        }
        self.reported_costs.insert(
            day.to_string(),
            ReportedUsageCost { dollars: total, covered_tokens: adding_saturating(prior.covered_tokens, tokens) },
        );
    }

    /// Keep a known component subtotal available internally while preventing it from being presented
    /// as the complete cost for this day or model. Used when a source reports measured tokens but its
    /// billing breakdown does not cover the reported total.
    pub fn mark_cost_incomplete(&mut self, day: &str, model: &str, canonical: Option<&str>) {
        self.incomplete_cost_days.insert(day.to_string());
        self.structural_incomplete_cost_days.insert(day.to_string());
        self.mark_model_cost_incomplete(day, model, canonical);
    }

    /// Mark one model's subtotal as unsettled without making the whole day's known subtotal
    /// unpresentable (an active session while sibling models on the same day are complete).
    pub fn mark_model_cost_incomplete(&mut self, day: &str, model: &str, canonical: Option<&str>) {
        let identity = canonical.unwrap_or(model);
        if let Some(accumulator) = self.models_by_day.get_mut(day).and_then(|models| models.get_mut(identity)) {
            accumulator.mark_cost_incomplete(model);
        }
    }

    /// Add the public-API-rate estimate for one row. Sums per day; rows without any resolvable rate
    /// contribute nothing, so the estimate is honest about coverage.
    pub fn add_api_estimate(&mut self, day: &str, cost: f64) {
        if self.overflowed_api_estimate_days.contains(day) {
            self.api_estimate_incomplete_days.insert(day.to_string());
            return;
        }
        match adding_finite_cost(self.api_estimate_by_day.get(day).copied(), cost) {
            Some(total) => {
                self.api_estimate_by_day.insert(day.to_string(), total);
            }
            None => {
                self.api_estimate_by_day.remove(day);
                self.overflowed_api_estimate_days.insert(day.to_string());
                self.api_estimate_incomplete_days.insert(day.to_string());
            }
        }
    }

    /// Mark a day's plan-priced dollars as imputed rather than provider-recorded.
    pub fn mark_estimated_cost(&mut self, day: &str) {
        self.estimated_cost_days.insert(day.to_string());
    }

    /// Record public-rate coverage for a row. Provider-specific or carried dollars can exist even when
    /// the shared public catalog cannot price that model; those rows make the day's API comparison
    /// explicitly incomplete instead of leaving a misleading partial total.
    pub fn record_api_estimate(&mut self, day: &str, cost: Option<f64>, tokens: i64) {
        if tokens <= 0 {
            return;
        }
        match cost {
            Some(cost) => self.add_api_estimate(day, cost),
            None => {
                self.api_estimate_incomplete_days.insert(day.to_string());
            }
        }
    }

    /// Note a model that couldn't be priced but still carried tokens — surfaced as the tile's warning
    /// triangle. Its cost is excluded, while known priced usage remains in the displayed subtotal.
    pub fn add_unknown_model(&mut self, day: &str, model: &str) {
        self.unknown_models_by_day.entry(day.to_string()).or_default().insert(model.to_string());
        self.incomplete_cost_days.insert(day.to_string());
        self.api_estimate_incomplete_days.insert(day.to_string());
    }

    /// Note a model the source identified by name but no pricing source can price. Unlike
    /// [`add_unknown_model`](Self::add_unknown_model) this is an *explained* cost gap: the day's known
    /// priced subtotal stays displayed with a lower-bound marker and no unknown-model warning fires.
    pub fn add_named_unpriced_model(&mut self, day: &str, model: &str) {
        self.named_unpriced_models_by_day.entry(day.to_string()).or_default().insert(model.to_string());
        self.incomplete_cost_days.insert(day.to_string());
        self.api_estimate_incomplete_days.insert(day.to_string());
    }

    /// Assemble the scan: per-day tokens/cost (days sorted newest-first), the per-day model breakdown
    /// and the unknown-model set. Days with unpriced rows carry all tokens and any known priced
    /// subtotal; `api_estimate_by_day` carries the public-API-rate comparison when any row could be
    /// priced.
    pub fn build(&self) -> LogUsageScan {
        let empty = BTreeSet::new();
        let days: Vec<DailyUsageEntry> = self
            .tokens_by_day
            .iter()
            .rev()
            .map(|(day, &tokens)| {
                let unknown = self.unknown_models_by_day.get(day).unwrap_or(&empty);
                let named = self.named_unpriced_models_by_day.get(day).unwrap_or(&empty);
                let has_unnamed_incomplete_model = self
                    .incomplete_model_costs_by_day
                    .get(day)
                    .is_some_and(|models| models.iter().any(|m| !unknown.contains(m) && !named.contains(m)));
                let has_structural_gap = self.structural_incomplete_cost_days.contains(day) || has_unnamed_incomplete_model;
                let has_known_cost_gap =
                    self.overflowed_cost_days.contains(day) || !unknown.is_empty() || !named.is_empty();
                DailyUsageEntry {
                    date: day.clone(),
                    total_tokens: tokens,
                    cost_usd: self.cost_by_day.get(day).copied(),
                    cost_is_complete: !self.incomplete_cost_days.contains(day),
                    has_unexplained_incomplete_cost: if has_structural_gap {
                        Some(true)
                    } else if has_known_cost_gap {
                        Some(false)
                    } else {
                        None
                    },
                    token_count_saturated: self.token_count_saturated_days.contains(day),
                    reported_cost: self.reported_costs.get(day).cloned(),
                }
            })
            .collect();
        let model_usage = ModelUsageSeries {
            daily: self
                .models_by_day
                .iter()
                .rev()
                .map(|(day, models)| {
                    let mut entries: Vec<ModelUsageEntry> =
                        models.iter().map(|(model, accumulator)| accumulator.entry(model)).collect();
                    // Deterministic order: cost desc with nil as $0, then tokens desc, then name — the
                    // same total order the spend-tile breakdown uses, so scans and history agree.
                    entries.sort_by(|l, r| {
                        cost_desc(l.cost_usd.unwrap_or(0.0), r.cost_usd.unwrap_or(0.0))
                            .then_with(|| r.total_tokens.cmp(&l.total_tokens))
                            .then_with(|| localized_standard_compare(&l.model, &r.model))
                    });
                    DailyModelUsageEntry { date: day.clone(), models: entries }
                })
                .collect(),
        };
        LogUsageScan {
            series: DailyUsageSeries { daily: days },
            model_usage: Some(model_usage),
            unknown_models_by_day: self.unknown_models_by_day.clone(),
            api_estimate_by_day: (!self.api_estimate_by_day.is_empty()).then(|| self.api_estimate_by_day.clone()),
            api_estimate_incomplete_days: Some(self.api_estimate_incomplete_days.clone()),
            estimated_cost_days: (!self.estimated_cost_days.is_empty()).then(|| self.estimated_cost_days.clone()),
            unmeasured_usage_days: (!self.unmeasured_usage_days.is_empty()).then(|| self.unmeasured_usage_days.clone()),
        }
    }
}

/// Running totals shared by a model row and each raw spelling inside it.
#[derive(Clone, Debug)]
struct Totals {
    tokens: i64,
    token_count_saturated: bool,
    cost_usd: Option<f64>,
    cost_is_complete: bool,
    cost_overflowed: bool,
}

impl Default for Totals {
    fn default() -> Self {
        Totals { tokens: 0, token_count_saturated: false, cost_usd: None, cost_is_complete: true, cost_overflowed: false }
    }
}

impl Totals {
    fn absorb(&mut self, tokens: i64, cost: Option<f64>, cost_is_complete: bool, source_saturated: bool) {
        if tokens > 0 && self.tokens > i64::MAX - tokens {
            self.token_count_saturated = true;
        }
        self.tokens = adding_saturating(self.tokens, tokens);
        self.token_count_saturated = self.token_count_saturated || source_saturated;
        if let Some(cost) = cost {
            if !self.cost_overflowed {
                match adding_finite_cost(self.cost_usd, cost) {
                    Some(total) => self.cost_usd = Some(total),
                    None => {
                        self.cost_overflowed = true;
                        self.cost_is_complete = false;
                    }
                }
            }
        } else if tokens > 0 {
            self.cost_is_complete = false;
        }
        if !cost_is_complete {
            self.cost_is_complete = false;
        }
    }
}

#[derive(Clone, Debug)]
struct Spelling {
    totals: Totals,
    /// The first spelling seen for this case-folded key.
    spelling: String,
}

/// One model row for one day, plus the exact slugs it absorbed (keyed case-folded) — what the hover
/// panel lists, so a gateway-tagged spelling stays visible without being a row of its own.
#[derive(Clone, Debug, Default)]
pub(super) struct ModelAccumulator {
    totals: Totals,
    spellings: BTreeMap<String, Spelling>,
}

impl ModelAccumulator {
    fn add(&mut self, tokens: i64, cost: Option<f64>, spelling: &str, cost_is_complete: bool, source_saturated: bool) {
        self.totals.absorb(tokens, cost, cost_is_complete, source_saturated);
        let existing = self
            .spellings
            .entry(spelling.to_lowercase())
            .or_insert_with(|| Spelling { totals: Totals::default(), spelling: spelling.to_string() });
        existing.totals.absorb(tokens, cost, cost_is_complete, source_saturated);
    }

    fn mark_cost_incomplete(&mut self, spelling: &str) {
        self.totals.cost_is_complete = false;
        if let Some(existing) = self.spellings.get_mut(&spelling.to_lowercase()) {
            existing.totals.cost_is_complete = false;
        }
    }

    fn entry(&self, model: &str) -> ModelUsageEntry {
        let mut variants: Vec<ModelUsageVariant> = self
            .spellings
            .values()
            .map(|value| ModelUsageVariant {
                model: value.spelling.clone(),
                total_tokens: value.totals.tokens,
                cost_usd: value.totals.cost_usd,
                cost_is_complete: (!value.totals.cost_is_complete).then_some(false),
                token_count_saturated: value.totals.token_count_saturated.then_some(true),
            })
            .collect();
        // Stable sort over the case-folded key order: ties are deterministic.
        variants.sort_by_key(|v| std::cmp::Reverse(v.total_tokens));
        // A single spelling that is just the row's own name is no breakdown.
        let is_trivial = variants.len() == 1 && variants[0].model.to_lowercase() == model.to_lowercase();
        ModelUsageEntry {
            model: model.to_string(),
            total_tokens: self.totals.tokens,
            cost_usd: self.totals.cost_usd,
            variants: if is_trivial || variants.is_empty() { None } else { Some(variants) },
            cost_is_complete: (!self.totals.cost_is_complete).then_some(false),
            token_count_saturated: self.totals.token_count_saturated.then_some(true),
        }
    }
}
