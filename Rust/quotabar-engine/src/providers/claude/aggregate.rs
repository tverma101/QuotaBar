//! Day aggregation (Swift `ClaudeLogUsageScanner.aggregate`).

use super::entry::ClaudeEntry;
use super::gateway::is_hosted_gateway_model;
use crate::accounting::{day_key, DailyUsageAccumulator, LogUsageScan};
use crate::model::ModelUsageEntry;
use crate::pricing::ModelPricing;

/// Bucket deduplicated entries into local calendar days. Cost mode "auto": a line's `costUSD` when
/// present, else tokens priced through `pricing`.
///
/// Rows no pricing source can price still count their tokens (cost dashes, per the owner's "count
/// tokens, dash cost" policy) and land in `unknown_models_by_day` for the warning triangle and the
/// reveal system. Every row with a resolvable rate also contributes its tokens' public-API-rate value
/// to `api_estimate_by_day` (the "if it were all API" comparison), including rows whose displayed cost
/// is provider-reported.
pub fn aggregate(entries: &[ClaudeEntry], since: f64, pricing: &ModelPricing) -> LogUsageScan {
    let mut accumulator = DailyUsageAccumulator::new();
    for entry in entries {
        if entry.timestamp < since {
            continue;
        }
        let day = day_key(entry.timestamp);
        // One trimmed slug for pricing, the unknown-model warning and the breakdown key alike:
        // diverging spellings would let the warning triangle and the hover panel disagree.
        let trimmed_model = entry.model.as_deref().map(str::trim).filter(|m| !m.is_empty());
        let model_name = trimmed_model.unwrap_or(ModelUsageEntry::UNATTRIBUTED);
        // OpenCode Go/Zen gateway turns are folded into the OpenCode card; counting them here would
        // double-count the same dollars/tokens in Total Spend.
        if trimmed_model.is_some_and(is_hosted_gateway_model) {
            continue;
        }
        let estimate = trimmed_model
            .and_then(|model| pricing.estimated_cost_dollars(model, &entry.tokens, Some(entry.timestamp), true));
        let cost = entry.cost_usd.or(estimate);
        let tokens = entry.tokens.total_tokens();
        if cost.is_none() && tokens > 0 {
            accumulator.add_unknown_model(&day, model_name);
        }
        accumulator.record_api_estimate(&day, estimate, tokens);
        accumulator.add(&day, tokens, cost, model_name);
    }
    accumulator.build()
}
