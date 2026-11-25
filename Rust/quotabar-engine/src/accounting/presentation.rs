//! Presentation rules for model rows (Swift `ModelUsageEntry` extension in ModelUsagePresentation.swift):
//! an "Other" group that restates one model's price is shown as that model, so the hover never prints
//! the same tokens and dollars twice.

use super::adding_saturating;
use crate::model::{ModelUsageEntry, ModelUsageVariant};

fn is_named(name: &str, expected: &str) -> bool {
    name.to_lowercase() == expected.to_lowercase()
}

impl ModelUsageEntry {
    fn restates_cost(&self, other: Option<f64>) -> bool {
        match (self.cost_usd, other) {
            (None, None) => true,
            (Some(row), Some(part)) => {
                row.is_finite() && part.is_finite() && (row - part).abs() < 0.005
            }
            _ => false,
        }
    }

    /// Other is a group of models. One model inside it is not a group: the row and that model would
    /// show the same tokens and cost. A lone named model becomes its own row. A lone unattributed
    /// bucket stays Other, without a second line that repeats it.
    pub fn collapsing_restated_other(&self) -> ModelUsageEntry {
        let Some(only) = self
            .variants
            .as_deref()
            .filter(|v| v.len() == 1)
            .map(|v| &v[0])
        else {
            return self.clone();
        };
        if !is_named(&self.model, Self::OTHER)
            || only.total_tokens != self.total_tokens
            || !self.restates_cost(only.cost_usd)
        {
            return self.clone();
        }
        if is_named(&only.model, Self::UNATTRIBUTED) {
            let mut row = self.clone();
            row.variants = None;
            return row;
        }
        ModelUsageEntry {
            model: only.model.clone(),
            total_tokens: self.total_tokens,
            cost_usd: self.cost_usd,
            variants: None,
            cost_is_complete: self.cost_is_complete,
            token_count_saturated: self.token_count_saturated,
        }
    }

    /// Hover rows for this entry. One model that carries an Other row's entire price is listed on its
    /// own, and so is each leftover model.
    pub fn presented_rows(&self) -> Vec<ModelUsageEntry> {
        let collapsed = self.collapsing_restated_other();
        let multi = collapsed.variants.as_deref().filter(|v| v.len() > 1);
        let (Some(variants), Some(cost)) = (multi, collapsed.cost_usd.filter(|c| *c > 0.0)) else {
            return vec![collapsed.dropping_restated_variant()];
        };
        if !is_named(&collapsed.model, Self::OTHER) {
            return vec![collapsed.dropping_restated_variant()];
        }

        let echo_indexes: Vec<usize> = (0..variants.len())
            .filter(|&i| {
                variants[i]
                    .cost_usd
                    .is_some_and(|part| part > 0.0 && (part - cost).abs() < 0.005)
            })
            .collect();
        let contributor_tokens = variants
            .iter()
            .try_fold(0i64, |acc, v| acc.checked_add(v.total_tokens));
        let [echo_index] = echo_indexes[..] else {
            return vec![collapsed.clone()];
        };
        if contributor_tokens != Some(collapsed.total_tokens)
            || collapsed.token_count_saturated == Some(true)
        {
            return vec![collapsed.clone()];
        }
        let rest: Vec<ModelUsageVariant> = variants
            .iter()
            .enumerate()
            .filter(|(i, _)| *i != echo_index)
            .map(|(_, v)| v.clone())
            .collect();
        if !rest.iter().all(|v| v.cost_usd.unwrap_or(0.0) == 0.0) {
            return vec![collapsed.clone()];
        }
        let mut rows = vec![row_for(&variants[echo_index])];
        rows.extend(rows_for_remaining(&rest));
        rows
    }

    /// A single raw slug that repeats this row's own tokens and cost is not a breakdown.
    pub fn dropping_restated_variant(&self) -> ModelUsageEntry {
        match self.variants.as_deref() {
            Some([only])
                if only.total_tokens == self.total_tokens && self.restates_cost(only.cost_usd) =>
            {
                let mut row = self.clone();
                row.variants = None;
                row
            }
            _ => self.clone(),
        }
    }
}

fn row_for(variant: &ModelUsageVariant) -> ModelUsageEntry {
    ModelUsageEntry {
        model: variant.model.clone(),
        total_tokens: variant.total_tokens,
        cost_usd: variant.cost_usd,
        variants: None,
        cost_is_complete: variant.cost_is_complete,
        token_count_saturated: variant.token_count_saturated,
    }
}

fn rows_for_remaining(variants: &[ModelUsageVariant]) -> Vec<ModelUsageEntry> {
    match variants {
        [] => Vec::new(),
        [only] if is_named(&only.model, ModelUsageEntry::UNATTRIBUTED) => vec![ModelUsageEntry {
            model: ModelUsageEntry::OTHER.to_string(),
            variants: None,
            ..row_for(only)
        }],
        [only] => vec![row_for(only)],
        _ => {
            let tokens = variants
                .iter()
                .fold(0, |acc, v| adding_saturating(acc, v.total_tokens));
            let mut cost: Option<f64> = None;
            let mut incomplete = false;
            let mut saturated = false;
            for variant in variants {
                if let Some(part) = variant.cost_usd {
                    cost = Some(cost.unwrap_or(0.0) + part);
                }
                incomplete = incomplete || variant.has_incomplete_cost();
                saturated = saturated || variant.token_count_saturated == Some(true);
            }
            vec![ModelUsageEntry {
                model: ModelUsageEntry::OTHER.to_string(),
                total_tokens: tokens,
                cost_usd: cost,
                variants: Some(variants.to_vec()),
                cost_is_complete: (incomplete || cost.is_none()).then_some(false),
                token_count_saturated: saturated.then_some(true),
            }]
        }
    }
}
