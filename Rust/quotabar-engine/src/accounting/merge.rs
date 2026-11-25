//! Scan merging (Swift `DailyUsageAccumulator.merged`, `mergedPreferringPrimary`,
//! `mergedPreferringPrimaryByModel`): replay already-built scans through a fresh accumulator so the
//! combined series, model usage and unknown-model set stay consistent.

use super::accumulator::{DailyUsageAccumulator, RowOptions};
use super::scan::LogUsageScan;
use crate::model::{DailyUsageEntry, ModelUsageEntry};
use crate::pricing::ModelPricing;
use std::collections::{BTreeMap, BTreeSet};

/// The model identity the by-model merge compares across sources by default.
pub fn default_model_identity(model: &str) -> String {
    model.to_lowercase()
}

/// Codex native logs and routed rows can spell one model differently: pricing aliases may rewrite
/// mode suffixes (for example `gpt-5.6-sol-ultra` to `gpt-5.6-sol`). Resolve every known pricing alias
/// before cross-source reconciliation, then fold fast tiers into the base model. Displayed model
/// spellings remain untouched.
pub fn codex_cross_source_model_identity(model: &str, pricing: &ModelPricing) -> String {
    let normalized = model.to_lowercase();
    let canonical = pricing
        .canonical_name(model)
        .map(|c| c.to_lowercase())
        .unwrap_or(normalized);
    if canonical.starts_with("gpt-") && canonical.ends_with("-fast") {
        return canonical[..canonical.len() - "-fast".len()].to_string();
    }
    canonical
}

/// Replay one model entry (and its gateway-spelling variants) into `accumulator` for `day`.
fn replay_model(accumulator: &mut DailyUsageAccumulator, day: &str, model: &ModelUsageEntry) {
    match model.variants.as_deref().filter(|v| !v.is_empty()) {
        Some(variants) => {
            for variant in variants {
                accumulator.add_with(
                    day,
                    variant.total_tokens,
                    variant.cost_usd,
                    &variant.model,
                    RowOptions {
                        canonical: Some(&model.model),
                        cost_is_complete: variant.cost_is_complete.unwrap_or(true),
                        token_count_saturated: variant.token_count_saturated == Some(true)
                            || model.token_count_saturated == Some(true),
                    },
                );
            }
        }
        None => accumulator.add_with(
            day,
            model.total_tokens,
            model.cost_usd,
            &model.model,
            RowOptions {
                canonical: None,
                cost_is_complete: model.cost_is_complete.unwrap_or(true),
                token_count_saturated: model.token_count_saturated == Some(true),
            },
        ),
    }
}

/// Carry a day entry's coverage bits into the accumulator.
fn replay_day_flags(accumulator: &mut DailyUsageAccumulator, entry: &DailyUsageEntry) {
    if !entry.cost_is_complete {
        accumulator.incomplete_cost_days.insert(entry.date.clone());
    }
    if entry.has_unexplained_incomplete_cost == Some(true) {
        accumulator
            .structural_incomplete_cost_days
            .insert(entry.date.clone());
    }
    if entry.token_count_saturated {
        accumulator
            .token_count_saturated_days
            .insert(entry.date.clone());
    }
}

fn incomplete_estimate_days(scan: &LogUsageScan) -> BTreeSet<String> {
    scan.api_estimate_incomplete_days
        .clone()
        .unwrap_or_else(|| scan.unknown_models_by_day.keys().cloned().collect())
}

impl DailyUsageAccumulator {
    /// Merge already-built scans (a provider's native log scan plus its pi slice) into one, by replaying
    /// each scan's per-model daily usage through a fresh accumulator. Every input must be
    /// accumulator-built (its `series` derived from the same per-model maps). `None` inputs are
    /// skipped; returns `None` when they are all `None` (the provider then folds in nothing).
    ///
    /// `dropping_days_before` clips the merged result to a narrower requested window without
    /// re-folding. Day keys are zero-padded `yyyy-MM-dd`, so lexicographic order is chronological.
    pub fn merged(
        scans: &[Option<LogUsageScan>],
        dropping_days_before: Option<&str>,
    ) -> Option<LogUsageScan> {
        let present: Vec<&LogUsageScan> = scans.iter().flatten().collect();
        if present.is_empty() {
            return None;
        }
        let mut accumulator = DailyUsageAccumulator::new();
        for scan in present {
            accumulator.merge(scan, dropping_days_before);
        }
        Some(accumulator.build())
    }

    /// Merge a previously assembled scan without losing gateway spellings preserved as variants.
    /// Nil-cost rows (unpriced/unidentified models) replay as token-only rows so the merged scan keeps
    /// counting their tokens; the unknown-model flags merge separately.
    fn merge(&mut self, scan: &LogUsageScan, min_day: Option<&str>) {
        let keep = |day: &str| min_day.is_none_or(|min| day >= min);
        for day in scan
            .unmeasured_usage_days
            .iter()
            .flatten()
            .filter(|d| keep(d))
        {
            self.unmeasured_usage_days.insert(day.clone());
        }
        for (day, models) in scan.unknown_models_by_day.iter().filter(|(d, _)| keep(d)) {
            for model in models {
                self.add_unknown_model(day, model);
            }
        }
        for day in scan
            .model_usage
            .iter()
            .flat_map(|m| m.daily.iter())
            .filter(|d| keep(&d.date))
        {
            for model in &day.models {
                replay_model(self, &day.date, model);
            }
        }
        for day in scan.series.daily.iter().filter(|d| keep(&d.date)) {
            replay_day_flags(self, day);
        }
        for day in incomplete_estimate_days(scan)
            .into_iter()
            .filter(|d| keep(d))
        {
            self.api_estimate_incomplete_days.insert(day);
        }
        for (day, estimate) in scan
            .api_estimate_by_day
            .iter()
            .flatten()
            .filter(|(d, _)| keep(d))
        {
            self.add_api_estimate(day, *estimate);
        }
    }

    /// Merge a primary scan with optional gap-fill supplements.
    ///
    /// Days already present on `primary` (any priced model row) keep only the primary numbers —
    /// supplements are skipped for those days. Supplements still contribute days the primary never saw.
    /// Use this when two ledgers can observe the same traffic (Codex session logs + FCC proxy) so tiles
    /// do not double-count overlapping days. Additive merges that are intentionally complementary
    /// (native + pi) should keep using [`merged`](Self::merged).
    ///
    /// Returns `(scan, used_supplement)` so callers can omit "FCC proxy" from the source note when every
    /// supplement day was already covered by primary logs.
    pub fn merged_preferring_primary(
        primary: Option<&LogUsageScan>,
        filling_gaps_from: &[Option<LogUsageScan>],
    ) -> (Option<LogUsageScan>, bool) {
        let primary_days: BTreeSet<String> = primary
            .and_then(|p| p.model_usage.as_ref())
            .into_iter()
            .flat_map(|usage| usage.daily.iter())
            .filter(|day| {
                day.models
                    .iter()
                    .any(|m| m.total_tokens > 0 || m.cost_usd.unwrap_or(0.0) > 0.0)
            })
            .map(|day| day.date.clone())
            .collect();

        let mut accumulator = DailyUsageAccumulator::new();
        let mut saw_any = false;
        let mut used_supplement = false;
        if let Some(primary) = primary {
            saw_any = absorb_skipping(&mut accumulator, primary, &BTreeSet::new()) || saw_any;
        }
        for supplement in filling_gaps_from.iter().flatten() {
            if absorb_skipping(&mut accumulator, supplement, &primary_days) {
                saw_any = true;
                used_supplement = true;
            }
        }
        if !saw_any {
            return (None, false);
        }
        (Some(accumulator.build()), used_supplement)
    }

    /// Merge Codex sources by day and canonical model. A router row for one model must not hide a
    /// different native model observed on that same day. When both sources contain the same model, the
    /// primary row wins because the sources do not share a request identifier for event-level
    /// deduplication. If a supplement adds a model to a day already covered by another source, the
    /// aggregate API-rate estimate becomes incomplete: those estimates are daily totals and cannot be
    /// safely split into model-level pieces here.
    pub fn merged_preferring_primary_by_model(
        primary: Option<&LogUsageScan>,
        filling_gaps_from: &[Option<&LogUsageScan>],
        model_identity: &dyn Fn(&str) -> String,
    ) -> (Option<LogUsageScan>, bool) {
        let mut accumulator = DailyUsageAccumulator::new();
        let mut seen_models: BTreeSet<(String, String)> = BTreeSet::new();
        let mut covered_days: BTreeSet<String> = BTreeSet::new();
        let mut saw_any = false;
        let mut used_supplement = false;

        if let Some(primary) = primary {
            for day in &primary.series.daily {
                if day.total_tokens > 0 || day.cost_usd.unwrap_or(0.0) > 0.0 {
                    covered_days.insert(day.date.clone());
                }
            }
            for (day, models) in &primary.unknown_models_by_day {
                for model in models {
                    accumulator.add_unknown_model(day, model);
                }
            }
            let added_days = absorb_rows(
                &mut accumulator,
                &mut seen_models,
                primary,
                false,
                model_identity,
            );
            covered_days.extend(added_days.iter().cloned());
            saw_any = !added_days.is_empty();
            saw_any = saw_any || !primary.unknown_models_by_day.is_empty();
            covered_days.extend(primary.unknown_models_by_day.keys().cloned());
            for day in incomplete_estimate_days(primary) {
                accumulator.api_estimate_incomplete_days.insert(day);
            }
            for (day, estimate) in primary.api_estimate_by_day.iter().flatten() {
                accumulator.add_api_estimate(day, *estimate);
            }
        }

        for supplement in filling_gaps_from.iter().flatten() {
            let prior_coverage = covered_days.clone();
            let mut added_unknown_days: BTreeSet<String> = BTreeSet::new();
            for (day, models) in &supplement.unknown_models_by_day {
                for model in models {
                    let known = accumulator
                        .unknown_models_by_day
                        .get(day)
                        .is_some_and(|set| set.contains(model));
                    if !known {
                        accumulator.add_unknown_model(day, model);
                        added_unknown_days.insert(day.clone());
                    }
                }
            }
            let added_days = absorb_rows(
                &mut accumulator,
                &mut seen_models,
                supplement,
                true,
                model_identity,
            );
            let incomplete_days = incomplete_estimate_days(supplement);
            if added_days.is_empty() && added_unknown_days.is_empty() {
                continue;
            }

            saw_any = true;
            used_supplement = true;
            for day in &added_days {
                if prior_coverage.contains(day) {
                    accumulator.api_estimate_incomplete_days.insert(day.clone());
                } else {
                    if incomplete_days.contains(day) {
                        accumulator.api_estimate_incomplete_days.insert(day.clone());
                    }
                    if let Some(estimate) = supplement
                        .api_estimate_by_day
                        .as_ref()
                        .and_then(|e| e.get(day))
                    {
                        accumulator.add_api_estimate(day, *estimate);
                    }
                }
                covered_days.insert(day.clone());
            }
            for day in &added_unknown_days {
                accumulator.api_estimate_incomplete_days.insert(day.clone());
            }
            covered_days.extend(added_unknown_days);
        }

        if !saw_any {
            return (None, false);
        }
        (Some(accumulator.build()), used_supplement)
    }
}

/// `absorb` of `mergedPreferringPrimary`: replay everything in `scan` except `days_to_skip`; true when
/// anything was absorbed.
fn absorb_skipping(
    accumulator: &mut DailyUsageAccumulator,
    scan: &LogUsageScan,
    days_to_skip: &BTreeSet<String>,
) -> bool {
    let mut absorbed = false;
    for (day, models) in &scan.unknown_models_by_day {
        if days_to_skip.contains(day) {
            continue;
        }
        for model in models {
            accumulator.add_unknown_model(day, model);
            absorbed = true;
        }
    }
    for day in scan.model_usage.iter().flat_map(|m| m.daily.iter()) {
        if days_to_skip.contains(&day.date) {
            continue;
        }
        for model in &day.models {
            replay_model(accumulator, &day.date, model);
            absorbed = true;
        }
    }
    for day in scan
        .series
        .daily
        .iter()
        .filter(|d| !days_to_skip.contains(&d.date))
    {
        replay_day_flags(accumulator, day);
    }
    for day in incomplete_estimate_days(scan)
        .into_iter()
        .filter(|d| !days_to_skip.contains(d))
    {
        accumulator.api_estimate_incomplete_days.insert(day);
    }
    for (day, estimate) in scan
        .api_estimate_by_day
        .iter()
        .flatten()
        .filter(|(d, _)| !days_to_skip.contains(*d))
    {
        accumulator.add_api_estimate(day, *estimate);
        absorbed = true;
    }
    absorbed
}

/// `absorbRows` of `mergedPreferringPrimaryByModel`: replay each model row with usage that the
/// day/identity set has not seen (when `skipping_seen`), and return the days that received rows.
fn absorb_rows(
    accumulator: &mut DailyUsageAccumulator,
    seen_models: &mut BTreeSet<(String, String)>,
    scan: &LogUsageScan,
    skipping_seen: bool,
    model_identity: &dyn Fn(&str) -> String,
) -> BTreeSet<String> {
    let mut added_days = BTreeSet::new();
    for day in scan.model_usage.iter().flat_map(|m| m.daily.iter()) {
        for model in &day.models {
            if !(model.total_tokens > 0 || model.cost_usd.unwrap_or(0.0) > 0.0) {
                continue;
            }
            let key = (day.date.clone(), model_identity(&model.model));
            if skipping_seen && seen_models.contains(&key) {
                continue;
            }
            seen_models.insert(key);
            added_days.insert(day.date.clone());
            replay_model(accumulator, &day.date, model);
        }
    }
    // Index the series once; the first entry for a day wins.
    let mut series_by_day: BTreeMap<&str, &DailyUsageEntry> = BTreeMap::new();
    for entry in &scan.series.daily {
        series_by_day.entry(entry.date.as_str()).or_insert(entry);
    }
    for day in &added_days {
        if let Some(entry) = series_by_day.get(day.as_str()) {
            replay_day_flags(accumulator, entry);
        }
    }
    added_days
}
