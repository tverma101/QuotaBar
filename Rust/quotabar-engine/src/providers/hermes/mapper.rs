//! Hermes period, model-breakdown, and usage-trend mapping (Swift `HermesUsageMapper`).

use crate::accounting::{adding_saturating, append_usage_trend_in, DayZone};
use crate::model::{
    DailyUsageSeries, MetricKind, MetricLine, MetricValue, ModelUsageBreakdown, ModelUsageEntry,
    ModelUsageVariant, ProviderUsageHistory, Timestamp,
};
use std::collections::{BTreeMap, BTreeSet};

pub const SOURCE_NOTE: &str = "From your Hermes state database";
const NAMED_MODEL_CAP: usize = 3;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum HermesPeriod {
    Today,
    ThisWeek,
    ThisMonth,
}

impl HermesPeriod {
    pub const ALL: [HermesPeriod; 3] = [
        HermesPeriod::Today,
        HermesPeriod::ThisWeek,
        HermesPeriod::ThisMonth,
    ];

    pub fn display_name(self) -> &'static str {
        match self {
            HermesPeriod::Today => "Today",
            HermesPeriod::ThisWeek => "This Week",
            HermesPeriod::ThisMonth => "This Month",
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct HermesTokenCounts {
    pub input: i64,
    pub output: i64,
    pub cache_read: i64,
    pub cache_write: i64,
    pub reasoning: i64,
}

impl HermesTokenCounts {
    pub fn total(self) -> i64 {
        adding_saturating(
            adding_saturating(
                adding_saturating(self.input, self.output),
                adding_saturating(self.cache_read, self.cache_write),
            ),
            self.reasoning,
        )
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct HermesPeriodUsage {
    pub period: HermesPeriod,
    pub counts: HermesTokenCounts,
    pub cost_usd: Option<f64>,
    pub api_call_count: i64,
    pub is_partial: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct HermesModelUsage {
    pub model: String,
    pub tokens: i64,
    pub cost_usd: Option<f64>,
    pub is_partial: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct HermesUsageScan {
    pub periods: Vec<HermesPeriodUsage>,
    pub daily: DailyUsageSeries,
    pub model_usage_by_period: BTreeMap<HermesPeriod, Vec<HermesModelUsage>>,
    pub partial_days: BTreeSet<String>,
}

pub fn lines(scan: &HermesUsageScan, now: Timestamp, zone: DayZone) -> Vec<MetricLine> {
    let mut out = Vec::new();
    for period in HermesPeriod::ALL {
        let Some(usage) = scan
            .periods
            .iter()
            .find(|p| p.period == period && has_usage(p))
        else {
            continue;
        };
        let models = scan
            .model_usage_by_period
            .get(&period)
            .map(Vec::as_slice)
            .unwrap_or(&[]);
        out.push(MetricLine::Values {
            label: period.display_name().to_string(),
            values: period_values(usage),
            color_hex: None,
            expiries_at: Vec::new(),
            unknown_models: Vec::new(),
            model_breakdown: breakdown(models, usage.counts.total(), usage.cost_usd),
        });
    }
    if !scan.daily.daily.is_empty() {
        append_usage_trend_in(
            &scan.daily,
            &mut out,
            now,
            SOURCE_NOTE,
            &scan.partial_days,
            None,
            zone,
        );
    }
    MetricLine::append_no_data_if_needed(&mut out);
    out
}

pub fn usage_history(scan: &HermesUsageScan) -> ProviderUsageHistory {
    let incomplete_days: BTreeSet<String> = scan
        .daily
        .daily
        .iter()
        .filter(|d| d.total_tokens > 0)
        .map(|d| d.date.clone())
        .collect();
    ProviderUsageHistory {
        series: scan.daily.clone(),
        model_usage: None,
        unknown_models_by_day: BTreeMap::new(),
        api_estimate_by_day: None,
        api_estimate_incomplete_days: Some(incomplete_days),
        partial_days: (!scan.partial_days.is_empty()).then(|| scan.partial_days.clone()),
        estimated_cost_days: None,
    }
    .normalizing()
}

fn has_usage(usage: &HermesPeriodUsage) -> bool {
    usage.counts.total() > 0 || usage.cost_usd.unwrap_or(0.0) > 0.0
}

fn period_values(usage: &HermesPeriodUsage) -> Vec<MetricValue> {
    let mut values = Vec::new();
    if let Some(cost) = usage.cost_usd {
        let mut v = MetricValue::new(cost, MetricKind::Dollars).with_estimated(true);
        v.is_partial = usage.is_partial.then_some(true);
        values.push(v);
    }
    let mut tok = MetricValue::new(usage.counts.total() as f64, MetricKind::Count)
        .with_label("tokens")
        .with_estimated(usage.is_partial);
    tok.is_partial = usage.is_partial.then_some(true);
    values.push(tok);
    values
}

pub fn breakdown(
    models: &[HermesModelUsage],
    total_tokens: i64,
    total_cost_usd: Option<f64>,
) -> Option<ModelUsageBreakdown> {
    if models.is_empty() {
        return None;
    }
    let mut named: Vec<ModelUsageEntry> = Vec::new();
    let mut other_tokens: i64 = 0;
    let mut other_saturated = false;
    let mut other_cost: Option<f64> = None;
    let mut other_cost_overflowed = false;
    let mut other_variants: Vec<ModelUsageVariant> = Vec::new();
    let mut other_has_partial = false;
    let unpriced_token_floor = (models.first().map_or(0, |m| m.tokens) / 10).max(10_000_000);

    for model in models {
        let name = if model.model.trim().is_empty() {
            ModelUsageEntry::UNATTRIBUTED.to_string()
        } else {
            model.model.trim().to_string()
        };
        let is_unattributed = name.eq_ignore_ascii_case(ModelUsageEntry::UNATTRIBUTED);
        let unpriced_heavyweight = model.cost_usd.is_none() && model.tokens >= unpriced_token_floor;
        let entry = ModelUsageEntry {
            model: name.clone(),
            total_tokens: model.tokens,
            cost_usd: model.cost_usd,
            variants: None,
            cost_is_complete: model.is_partial.then_some(false),
            token_count_saturated: None,
        };
        if is_unattributed || (named.len() >= NAMED_MODEL_CAP && !unpriced_heavyweight) {
            if model.tokens > 0 && other_tokens > i64::MAX - model.tokens {
                other_saturated = true;
            }
            other_tokens = adding_saturating(other_tokens, model.tokens);
            if let Some(cost) = model.cost_usd.filter(|_| !other_cost_overflowed) {
                let sum = other_cost.unwrap_or(0.0) + cost;
                if cost.is_finite() && cost >= 0.0 && sum.is_finite() {
                    other_cost = Some(sum);
                } else {
                    other_cost_overflowed = true;
                    other_has_partial = true;
                }
            }
            other_variants.push(ModelUsageVariant {
                model: name,
                total_tokens: model.tokens,
                cost_usd: model.cost_usd,
                cost_is_complete: model.is_partial.then_some(false),
                token_count_saturated: None,
            });
            other_has_partial = other_has_partial
                || model.is_partial
                || (model.cost_usd.is_none() && model.tokens > 0);
        } else {
            named.push(entry);
        }
    }

    if other_tokens > 0 || other_cost.unwrap_or(0.0) > 0.0 {
        let other = ModelUsageEntry {
            model: ModelUsageEntry::OTHER.to_string(),
            total_tokens: other_tokens,
            cost_usd: other_cost,
            variants: Some(other_variants),
            cost_is_complete: other_has_partial.then_some(false),
            token_count_saturated: other_saturated.then_some(true),
        };
        named.extend(other.presented_rows());
    }
    (!named.is_empty()).then_some(ModelUsageBreakdown {
        total_tokens,
        token_count_saturated: None,
        total_cost_usd,
        models: named,
        source_note: Some(SOURCE_NOTE.to_string()),
    })
}
