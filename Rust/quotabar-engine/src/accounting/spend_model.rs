//! The per-period model breakdown attached to a spend tile (Swift `SpendTileMapper.modelBreakdown` and
//! its helpers): case-folded grouping with a spelling vote, cost-then-token ordering, and folding
//! slivers into an "Other" row.

use super::day::{day_key_from_usage_date, DayZone};
use super::{adding_finite_cost, adding_saturating, cost_desc, localized_standard_compare};
use crate::model::{ModelUsageBreakdown, ModelUsageEntry, ModelUsageSeries, ModelUsageVariant};
use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet};

const NAMED_MODEL_CAP: usize = 3;

/// Tracks the casings seen for one case-folded name and elects the one that carried the most tokens
/// (ties prefer the all-lowercase spelling, then alphabetical) — so `GLM-5.2` and `glm-5.2` collapse
/// into one row titled with whichever spelling dominated the period.
#[derive(Clone, Debug, Default)]
struct SpellingVote {
    tokens_by_spelling: BTreeMap<String, i64>,
}

impl SpellingVote {
    fn note(&mut self, spelling: &str, weight: i64) {
        // Zero-token entries (cost-only lines) still get a say.
        let slot = self.tokens_by_spelling.entry(spelling.to_string()).or_insert(0);
        *slot = adding_saturating(*slot, weight.max(1));
    }

    fn best(&self) -> Option<&str> {
        self.tokens_by_spelling
            .iter()
            .min_by(|(lk, lv), (rk, rv)| {
                rv.cmp(lv)
                    .then_with(|| {
                        let l_lower = **lk == lk.to_lowercase();
                        let r_lower = **rk == rk.to_lowercase();
                        r_lower.cmp(&l_lower)
                    })
                    .then_with(|| lk.cmp(rk))
            })
            .map(|(key, _)| key.as_str())
    }
}

#[derive(Clone, Debug)]
struct VariantTotals {
    tokens: i64,
    cost_usd: Option<f64>,
    cost_is_complete: bool,
    token_count_saturated: bool,
    cost_overflowed: bool,
    vote: SpellingVote,
}

impl Default for VariantTotals {
    fn default() -> Self {
        VariantTotals {
            tokens: 0,
            cost_usd: None,
            cost_is_complete: true,
            token_count_saturated: false,
            cost_overflowed: false,
            vote: SpellingVote::default(),
        }
    }
}

#[derive(Clone, Debug)]
pub(super) struct ModelAccumulator {
    pub(super) tokens: i64,
    token_count_saturated: bool,
    pub(super) cost_usd: Option<f64>,
    cost_is_complete: bool,
    cost_overflowed: bool,
    name_vote: SpellingVote,
    /// Keyed by the case-folded slug; the vote inside restores a display spelling.
    variants: BTreeMap<String, VariantTotals>,
}

impl ModelAccumulator {
    pub(super) fn new() -> Self {
        ModelAccumulator {
            tokens: 0,
            token_count_saturated: false,
            cost_usd: None,
            cost_is_complete: true,
            cost_overflowed: false,
            name_vote: SpellingVote::default(),
            variants: BTreeMap::new(),
        }
    }

    /// The display spelling for this model, elected across every casing that merged into it.
    fn display_name(&self) -> Option<&str> {
        self.name_vote.best()
    }

    /// Merge a same-model day entry: variants (raw slugs) merge line-by-line so a multi-day period
    /// keeps one line per slug.
    fn add(&mut self, entry: &ModelUsageEntry, spelled_as: &str) {
        self.add_totals(entry);
        self.name_vote.note(spelled_as, entry.total_tokens);
        let synthesized;
        let variants: &[ModelUsageVariant] = match entry.variants.as_deref() {
            Some(variants) => variants,
            None => {
                synthesized = [ModelUsageVariant {
                    model: spelled_as.to_string(),
                    total_tokens: entry.total_tokens,
                    cost_usd: entry.cost_usd,
                    cost_is_complete: entry.cost_is_complete,
                    token_count_saturated: entry.token_count_saturated,
                }];
                &synthesized
            }
        };
        for variant in variants {
            self.merge_variant(
                &variant.model,
                variant.total_tokens,
                variant.cost_usd,
                !variant.has_incomplete_cost(),
                variant.token_count_saturated == Some(true),
            );
        }
    }

    /// Fold a different model into this accumulator (the Other row): one variant per folded model —
    /// its hover detail lists models, not their raw effort slugs. The Other row's own name is fixed, so
    /// folded spellings only vote inside the variant lines.
    fn fold(&mut self, entry: &ModelUsageEntry) {
        self.add_totals(entry);
        self.merge_variant(
            &entry.model,
            entry.total_tokens,
            entry.cost_usd,
            !entry.has_incomplete_cost(),
            entry.token_count_saturated == Some(true),
        );
    }

    fn add_totals(&mut self, entry: &ModelUsageEntry) {
        if entry.total_tokens > 0 && self.tokens > i64::MAX - entry.total_tokens {
            self.token_count_saturated = true;
        }
        self.tokens = adding_saturating(self.tokens, entry.total_tokens);
        self.token_count_saturated = self.token_count_saturated || entry.token_count_saturated == Some(true);
        if let Some(cost) = entry.cost_usd {
            self.accumulate_cost(cost);
        }
        if entry.has_incomplete_cost() {
            self.cost_is_complete = false;
        }
    }

    fn merge_variant(
        &mut self,
        model: &str,
        tokens: i64,
        cost_usd: Option<f64>,
        cost_is_complete: bool,
        token_count_saturated: bool,
    ) {
        let existing = self.variants.entry(model.to_lowercase()).or_default();
        if tokens > 0 && existing.tokens > i64::MAX - tokens {
            existing.token_count_saturated = true;
        }
        existing.tokens = adding_saturating(existing.tokens, tokens);
        existing.token_count_saturated = existing.token_count_saturated || token_count_saturated;
        if let Some(cost) = cost_usd {
            if !existing.cost_overflowed {
                match adding_finite_cost(existing.cost_usd, cost) {
                    Some(total) => existing.cost_usd = Some(total),
                    None => {
                        existing.cost_overflowed = true;
                        existing.cost_is_complete = false;
                    }
                }
            }
        }
        if !cost_is_complete || (tokens > 0 && cost_usd.is_none()) {
            existing.cost_is_complete = false;
        }
        existing.vote.note(model, tokens);
    }

    fn accumulate_cost(&mut self, cost: f64) {
        if self.cost_overflowed {
            return;
        }
        match adding_finite_cost(self.cost_usd, cost) {
            Some(total) => self.cost_usd = Some(total),
            None => {
                self.cost_overflowed = true;
                self.cost_is_complete = false;
            }
        }
    }

    pub(super) fn entry(&self, model: &str) -> ModelUsageEntry {
        let mut list: Vec<ModelUsageVariant> = self
            .variants
            .iter()
            .map(|(key, value)| ModelUsageVariant {
                model: value.vote.best().unwrap_or(key).to_string(),
                total_tokens: value.tokens,
                cost_usd: value.cost_usd,
                cost_is_complete: (!value.cost_is_complete).then_some(false),
                token_count_saturated: value.token_count_saturated.then_some(true),
            })
            .collect();
        list.sort_by(variant_order);
        // One variant carrying the row's own name is no breakdown.
        let is_trivial = list.len() == 1 && list[0].model.to_lowercase() == model.to_lowercase();
        ModelUsageEntry {
            model: model.to_string(),
            total_tokens: self.tokens,
            cost_usd: self.cost_usd,
            variants: if is_trivial { None } else { Some(list) },
            cost_is_complete: (!self.cost_is_complete).then_some(false),
            token_count_saturated: self.token_count_saturated.then_some(true),
        }
    }
}

/// Cost desc (priced before unpriced at equal dollars), then tokens desc, then name.
fn order_by(lhs: (Option<f64>, i64, &str), rhs: (Option<f64>, i64, &str)) -> Ordering {
    cost_desc(lhs.0.unwrap_or(0.0), rhs.0.unwrap_or(0.0))
        .then_with(|| rhs.0.is_some().cmp(&lhs.0.is_some()))
        .then_with(|| rhs.1.cmp(&lhs.1))
        .then_with(|| localized_standard_compare(lhs.2, rhs.2))
}

fn variant_order(lhs: &ModelUsageVariant, rhs: &ModelUsageVariant) -> Ordering {
    order_by((lhs.cost_usd, lhs.total_tokens, &lhs.model), (rhs.cost_usd, rhs.total_tokens, &rhs.model))
}

fn model_order(lhs: &ModelUsageEntry, rhs: &ModelUsageEntry) -> Ordering {
    order_by((lhs.cost_usd, lhs.total_tokens, &lhs.model), (rhs.cost_usd, rhs.total_tokens, &rhs.model))
}

/// Everything `modelBreakdown` needs besides the model usage itself.
pub(super) struct BreakdownRequest<'a> {
    pub days: &'a BTreeSet<String>,
    pub total_tokens: i64,
    pub token_count_saturated: bool,
    pub total_cost_usd: Option<f64>,
    pub source_note: Option<&'a str>,
    pub unexplained_incomplete_days: &'a BTreeSet<String>,
    pub zone: DayZone,
}

pub(super) fn model_breakdown(usage: Option<&ModelUsageSeries>, request: &BreakdownRequest<'_>) -> Option<ModelUsageBreakdown> {
    let usage = usage?;
    if request.days.is_empty() {
        return None;
    }

    // Keyed by the case-folded name so `GLM-5.2` and `glm-5.2` land in one row; the accumulator's
    // spelling vote decides which casing titles it.
    let mut by_model: BTreeMap<String, ModelAccumulator> = BTreeMap::new();
    for day in &usage.daily {
        let Some(key) = day_key_from_usage_date(&day.date, request.zone).filter(|k| request.days.contains(k)) else {
            continue;
        };
        for model in day.models.iter().filter(|m| m.total_tokens > 0 || m.cost_usd.unwrap_or(0.0) > 0.0) {
            let name = normalized_model_name(&model.model);
            let hidden;
            let adjusted = if request.unexplained_incomplete_days.contains(&key) {
                hidden = hiding_cost(model);
                &hidden
            } else {
                model
            };
            by_model.entry(name.to_lowercase()).or_insert_with(ModelAccumulator::new).add(adjusted, &name);
        }
    }

    if by_model.is_empty() {
        return None;
    }
    let modeled_tokens = by_model.values().fold(0i64, |acc, v| adding_saturating(acc, v.tokens));
    if request.total_tokens > modeled_tokens {
        let name = ModelUsageEntry::UNATTRIBUTED;
        let entry = ModelUsageEntry {
            model: name.to_string(),
            total_tokens: request.total_tokens - modeled_tokens,
            cost_usd: None,
            variants: None,
            cost_is_complete: None,
            token_count_saturated: None,
        };
        by_model.entry(name.to_lowercase()).or_insert_with(ModelAccumulator::new).add(&entry, name);
    }

    let mut sorted: Vec<ModelUsageEntry> =
        by_model.iter().map(|(key, accumulator)| accumulator.entry(accumulator.display_name().unwrap_or(key))).collect();
    sorted.sort_by(model_order);
    let folded = fold_model_list(&sorted);
    if folded.is_empty() {
        return None;
    }
    Some(ModelUsageBreakdown {
        total_tokens: request.total_tokens,
        token_count_saturated: request.token_count_saturated.then_some(true),
        total_cost_usd: request.total_cost_usd,
        models: folded,
        source_note: request.source_note.map(str::to_string),
    })
}

fn hiding_cost(model: &ModelUsageEntry) -> ModelUsageEntry {
    let mut adjusted = model.clone();
    adjusted.cost_usd = None;
    adjusted.cost_is_complete = Some(false);
    if let Some(variants) = adjusted.variants.as_mut() {
        for variant in variants {
            variant.cost_usd = None;
            variant.cost_is_complete = Some(false);
        }
    }
    adjusted
}

fn normalized_model_name(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() { ModelUsageEntry::UNATTRIBUTED.to_string() } else { trimmed.to_string() }
}

fn fold_model_list(entries: &[ModelUsageEntry]) -> Vec<ModelUsageEntry> {
    let mut visible: Vec<ModelUsageEntry> = Vec::new();
    let mut other = ModelAccumulator::new();
    let unpriced_token_floor = (entries.first().map_or(0, |e| e.total_tokens) / 10).max(10_000_000);

    for entry in entries {
        let is_unattributed = entry.model.to_lowercase() == ModelUsageEntry::UNATTRIBUTED.to_lowercase();
        let unpriced_heavyweight = entry.cost_usd.is_none() && entry.total_tokens >= unpriced_token_floor;
        if is_unattributed || (visible.len() >= NAMED_MODEL_CAP && !unpriced_heavyweight) {
            other.fold(entry);
        } else {
            visible.push(entry.clone());
        }
    }

    if other.tokens > 0 || other.cost_usd.unwrap_or(0.0) > 0.0 {
        // A single folded model is not a tail: leaving it under Other made the hover print that
        // model's tokens and cost twice.
        visible.extend(other.entry(ModelUsageEntry::OTHER).presented_rows());
    }
    visible.sort_by(model_order);
    visible
}
