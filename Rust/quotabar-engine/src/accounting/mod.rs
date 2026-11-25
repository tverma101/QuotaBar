//! Shared usage accounting (Swift `DailyUsageAccumulator`, `LogUsageScan`, `SpendTileMapper`): the
//! "accumulate priced per-day usage, then render spend tiles" pipeline every log-scanning provider
//! funnels through. Day keys are the local-calendar `yyyy-MM-dd` contract in [`day`].

pub mod accumulator;
mod collate;
pub mod day;
mod format;
mod merge;
pub mod presentation;
pub mod scan;
mod spend_model;
pub mod spend_tiles;

pub use accumulator::{DailyUsageAccumulator, RowOptions};
pub use collate::localized_standard_compare;
pub use day::{day_key, day_key_from_usage_date, day_key_in, DayZone, UsageHistoryWindow};
pub use format::format_count_row;
pub use merge::{codex_cross_source_model_identity, default_model_identity};
pub use scan::LogUsageScan;
pub use spend_tiles::{
    append_token_usage, append_token_usage_in, append_usage_trend, append_usage_trend_in,
    TokenUsageOptions,
};

use crate::model::DailyUsageEntry;

/// Swift `ProviderParse.addingSaturating`: any overflow, in either direction, yields `Int.max`.
pub(crate) fn adding_saturating(lhs: i64, rhs: i64) -> i64 {
    lhs.checked_add(rhs).unwrap_or(i64::MAX)
}

/// Add one finite, non-negative dollar amount to a running total; `None` when the addition is
/// rejected or the total would overflow to infinity.
pub(crate) fn adding_finite_cost(current: Option<f64>, addition: f64) -> Option<f64> {
    if !addition.is_finite() || addition < 0.0 {
        return None;
    }
    let total = current.unwrap_or(0.0) + addition;
    total.is_finite().then_some(total)
}

/// Descending order for finite costs (non-finite values compare equal rather than panicking a sort).
pub(crate) fn cost_desc(lhs: f64, rhs: f64) -> std::cmp::Ordering {
    rhs.partial_cmp(&lhs).unwrap_or(std::cmp::Ordering::Equal)
}

impl DailyUsageEntry {
    /// Swift `DailyUsageEntry.init`: complete cost, no cause tracking, and a saturation marker
    /// derived from the total unless given.
    pub fn new(date: &str, total_tokens: i64, cost_usd: Option<f64>) -> Self {
        DailyUsageEntry {
            date: date.to_string(),
            total_tokens,
            cost_usd,
            cost_is_complete: true,
            has_unexplained_incomplete_cost: None,
            token_count_saturated: total_tokens == i64::MAX,
            reported_cost: None,
        }
    }
}

#[cfg(test)]
mod tests;
