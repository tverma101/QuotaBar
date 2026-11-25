//! The log-scanner result shape and the usage-history projection (Swift `LogUsageScan` and
//! `ProviderUsageHistory` in Models/DailyUsageSeries.swift).

use super::adding_saturating;
use super::day::{DayZone, UsageHistoryWindow};
use crate::model::{
    DailyModelUsageEntry, DailyUsageSeries, ModelUsageEntry, ModelUsageSeries,
    ProviderUsageHistory, Timestamp,
};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// Daily token/cost series plus the per-day models the pricing sources couldn't price — the inputs
/// `append_token_usage` needs to render the spend tiles with unknown-model warnings. Shared result
/// shape of the native log scanners (Claude, Codex, ...).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LogUsageScan {
    pub series: DailyUsageSeries,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub model_usage: Option<ModelUsageSeries>,
    /// `yyyy-MM-dd` day key to models used that day whose usage was left out because no price was
    /// available.
    #[serde(default)]
    pub unknown_models_by_day: BTreeMap<String, BTreeSet<String>>,
    /// Day key to what that day's usage would cost at public API rates (the "if it were all API"
    /// comparison); `None` when no row in the window could be estimated at all.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub api_estimate_by_day: Option<BTreeMap<String, f64>>,
    /// Full-retention marker for days where public-rate rows were unpriceable.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub api_estimate_incomplete_days: Option<BTreeSet<String>>,
    /// Day keys whose plan-priced costs contain locally imputed rows.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub estimated_cost_days: Option<BTreeSet<String>>,
    /// A valid routed request was recorded without any measured usage fields. Measured totals stay and
    /// these days are marked partial; the absent measurement is never turned into zero or an estimate.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub unmeasured_usage_days: Option<BTreeSet<String>>,
}

impl LogUsageScan {
    /// Swift `LogUsageScan.init`: the incomplete-estimate days default to the unknown-model days.
    pub fn new(
        series: DailyUsageSeries,
        unknown_models_by_day: BTreeMap<String, BTreeSet<String>>,
    ) -> Self {
        let incomplete = unknown_models_by_day.keys().cloned().collect();
        LogUsageScan {
            series,
            model_usage: None,
            unknown_models_by_day,
            api_estimate_by_day: None,
            api_estimate_incomplete_days: Some(incomplete),
            estimated_cost_days: None,
            unmeasured_usage_days: None,
        }
    }

    /// Trim an unchanged cached aggregate as its rolling lifetime window advances. This avoids
    /// repricing every retained event at midnight; the per-database cache can discard whole days.
    pub fn dropping_days(&self, before: &str) -> LogUsageScan {
        let keep_set = |set: &BTreeSet<String>| {
            set.iter()
                .filter(|d| d.as_str() >= before)
                .cloned()
                .collect()
        };
        let mut trimmed = self.clone();
        trimmed.series.daily.retain(|d| d.date.as_str() >= before);
        if let Some(models) = trimmed.model_usage.as_mut() {
            models.daily.retain(|d| d.date.as_str() >= before);
        }
        trimmed
            .unknown_models_by_day
            .retain(|day, _| day.as_str() >= before);
        if let Some(estimates) = trimmed.api_estimate_by_day.as_mut() {
            estimates.retain(|day, _| day.as_str() >= before);
        }
        trimmed.api_estimate_incomplete_days =
            self.api_estimate_incomplete_days.as_ref().map(keep_set);
        trimmed.estimated_cost_days = self.estimated_cost_days.as_ref().map(keep_set);
        trimmed.unmeasured_usage_days = self.unmeasured_usage_days.as_ref().map(keep_set);
        trimmed
    }

    pub fn marking_unmeasured_usage(&self, days: &BTreeSet<String>) -> LogUsageScan {
        if days.is_empty() {
            return self.clone();
        }
        let mut marked = self.clone();
        let existing = marked
            .unmeasured_usage_days
            .get_or_insert_with(BTreeSet::new);
        existing.extend(days.iter().cloned());
        marked
    }
}

impl ProviderUsageHistory {
    /// Run the normalizing steps of Swift `ProviderUsageHistory.init`: named unknown models mark their
    /// rows' costs incomplete, legacy incomplete days get their cause classified, and the
    /// incomplete-estimate days default to the unknown-model days. Idempotent.
    pub fn normalizing(mut self) -> Self {
        self.model_usage = self
            .model_usage
            .take()
            .map(|m| marking_named_unknown_costs_incomplete(m, &self.unknown_models_by_day));
        classify_legacy_incomplete_days(
            &mut self.series,
            self.model_usage.as_ref(),
            &self.unknown_models_by_day,
        );
        if self.api_estimate_incomplete_days.is_none() {
            self.api_estimate_incomplete_days =
                Some(self.unknown_models_by_day.keys().cloned().collect());
        }
        self
    }

    /// Model rows and unknown-model names are only consumed by the 30-day spend details. Keep daily
    /// totals and API estimates for the ten-year lifetime report while dropping older array entries.
    pub fn retaining_history(&self, now: Timestamp, zone: DayZone) -> ProviderUsageHistory {
        self.retaining_history_keys(
            &UsageHistoryWindow::lifetime_day_keys(now, zone),
            &UsageHistoryWindow::day_keys(now, zone),
        )
    }

    pub fn retaining_history_keys(
        &self,
        lifetime_day_keys: &BTreeSet<String>,
        detail_day_keys: &BTreeSet<String>,
    ) -> ProviderUsageHistory {
        let model_days: Vec<DailyModelUsageEntry> = self
            .model_usage
            .as_ref()
            .map(|m| {
                m.daily
                    .iter()
                    .filter(|d| detail_day_keys.contains(&d.date))
                    .cloned()
                    .collect()
            })
            .unwrap_or_default();
        let api_estimates: Option<BTreeMap<String, f64>> =
            self.api_estimate_by_day.as_ref().map(|estimates| {
                estimates
                    .iter()
                    .filter(|(day, _)| lifetime_day_keys.contains(*day))
                    .map(|(d, v)| (d.clone(), *v))
                    .collect()
            });
        let incomplete_estimate_days: BTreeSet<String> = self
            .api_estimate_incomplete_days
            .clone()
            .unwrap_or_else(|| self.unknown_models_by_day.keys().cloned().collect());
        let keep_lifetime = |set: &BTreeSet<String>| -> BTreeSet<String> {
            set.iter()
                .filter(|d| lifetime_day_keys.contains(*d))
                .cloned()
                .collect()
        };
        ProviderUsageHistory {
            series: DailyUsageSeries {
                daily: self
                    .series
                    .daily
                    .iter()
                    .filter(|d| lifetime_day_keys.contains(&d.date))
                    .cloned()
                    .collect(),
            },
            model_usage: (!model_days.is_empty()).then_some(ModelUsageSeries { daily: model_days }),
            unknown_models_by_day: self
                .unknown_models_by_day
                .iter()
                .filter(|(day, _)| detail_day_keys.contains(*day))
                .map(|(d, v)| (d.clone(), v.clone()))
                .collect(),
            api_estimate_by_day: api_estimates.filter(|e| !e.is_empty()),
            api_estimate_incomplete_days: Some(keep_lifetime(&incomplete_estimate_days)),
            // Partial markers qualify lifetime totals too: keep them for the full lifetime window.
            partial_days: self.partial_days.as_ref().map(keep_lifetime),
            estimated_cost_days: self.estimated_cost_days.as_ref().map(keep_lifetime),
        }
        .normalizing()
    }
}

fn marking_named_unknown_costs_incomplete(
    series: ModelUsageSeries,
    unknown_models_by_day: &BTreeMap<String, BTreeSet<String>>,
) -> ModelUsageSeries {
    ModelUsageSeries {
        daily: series
            .daily
            .into_iter()
            .map(|mut day| {
                let unknown_names: BTreeSet<String> = unknown_models_by_day
                    .get(&day.date)
                    .map(|names| names.iter().map(|n| n.to_lowercase()).collect())
                    .unwrap_or_default();
                if unknown_names.is_empty() {
                    return day;
                }
                for model in &mut day.models {
                    if let Some(variants) = model.variants.as_mut() {
                        for variant in variants.iter_mut() {
                            if unknown_names.contains(&variant.model.to_lowercase()) {
                                variant.cost_is_complete = Some(false);
                            }
                        }
                    }
                    let variant_named = model.variants.as_ref().is_some_and(|vs| {
                        vs.iter()
                            .any(|v| unknown_names.contains(&v.model.to_lowercase()))
                    });
                    if unknown_names.contains(&model.model.to_lowercase()) || variant_named {
                        model.cost_is_complete = Some(false);
                    }
                }
                day
            })
            .collect(),
    }
}

/// Old synced documents do not carry the cause of incomplete cost. Treat named unknowns as a
/// sufficient explanation only when their model rows account for the full day and every incomplete
/// model row is named. Otherwise preserve the conservative structural-gap behavior.
fn classify_legacy_incomplete_days(
    series: &mut DailyUsageSeries,
    model_usage: Option<&ModelUsageSeries>,
    unknown_models_by_day: &BTreeMap<String, BTreeSet<String>>,
) {
    let mut models_by_day: BTreeMap<&str, Vec<&ModelUsageEntry>> = BTreeMap::new();
    for model_day in model_usage.map(|m| m.daily.as_slice()).unwrap_or_default() {
        models_by_day
            .entry(model_day.date.as_str())
            .or_default()
            .extend(model_day.models.iter());
    }
    for day in &mut series.daily {
        if day.cost_is_complete || day.has_unexplained_incomplete_cost.is_some() {
            continue;
        }
        let unknown_names = unknown_models_by_day
            .get(&day.date)
            .filter(|names| !names.is_empty());
        let model_rows = models_by_day
            .get(day.date.as_str())
            .filter(|rows| !rows.is_empty());
        let (Some(unknown_names), Some(model_rows)) = (unknown_names, model_rows) else {
            day.has_unexplained_incomplete_cost = Some(true);
            continue;
        };

        let mut model_tokens = 0i64;
        let mut model_tokens_saturated = false;
        for model in model_rows {
            if model.total_tokens > 0 && model_tokens > i64::MAX - model.total_tokens {
                model_tokens_saturated = true;
            }
            model_tokens = adding_saturating(model_tokens, model.total_tokens);
            model_tokens_saturated =
                model_tokens_saturated || model.token_count_saturated == Some(true);
        }
        let normalized_unknown: BTreeSet<String> =
            unknown_names.iter().map(|n| n.to_lowercase()).collect();
        let represented: BTreeSet<String> = model_rows
            .iter()
            .flat_map(|model| {
                std::iter::once(model.model.to_lowercase()).chain(
                    model
                        .variants
                        .iter()
                        .flatten()
                        .map(|v| v.model.to_lowercase()),
                )
            })
            .collect();
        let incomplete: Vec<&&ModelUsageEntry> = model_rows
            .iter()
            .filter(|m| m.has_incomplete_cost())
            .collect();
        let all_incomplete_named = !incomplete.is_empty()
            && incomplete.iter().all(|model| {
                normalized_unknown.contains(&model.model.to_lowercase())
                    || model
                        .variants
                        .iter()
                        .flatten()
                        .any(|v| normalized_unknown.contains(&v.model.to_lowercase()))
            });
        let names_represented = normalized_unknown.is_subset(&represented);
        day.has_unexplained_incomplete_cost = Some(
            model_tokens_saturated
                || day.token_count_saturated
                || model_tokens != day.total_tokens
                || !names_represented
                || !all_incomplete_named,
        );
    }
}
