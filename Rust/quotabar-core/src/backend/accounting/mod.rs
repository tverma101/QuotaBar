//! Shared priced-accounting core for local log folds.
//!
//! Ports the two pieces every log scanner runs over every retained event:
//!
//! - [`ModelRates::cost_dollars`] — the request-wide rate selection (prompt tiers, long-context
//!   lanes, cache lanes, fast multiplier) from `Pricing/ModelRates.swift`.
//! - [`accumulator::DailyUsageAccumulator`] — the per-day token/cost/model roll-up and scan
//!   assembly from `Providers/DailyUsageAccumulator.swift`.
//!
//! Pricing *resolution* (alias rules, OpenRouter/LiteLLM/models.dev lookup) stays in Swift: the
//! caller resolves each distinct model slug once per fold and passes the resulting `ModelRates`
//! table. That keeps the catalog policy and its memoization in one place while moving the
//! per-event arithmetic and dictionary churn — the part that scales with history size — here.
//!
//! Day bucketing also stays at the Swift edge: the caller passes the local-calendar day boundaries
//! for the scan window, so `Calendar.current` remains the single authority for what "today" means.

pub mod accumulator;

pub use accumulator::DailyUsageAccumulator;

use serde::Deserialize;
use serde_json::Value;

pub const UNATTRIBUTED_MODEL_NAME: &str = "Unattributed";
const CACHE_WRITE_1H_INPUT_MULTIPLIER: f64 = 2.0;

/// Swift `Int` arithmetic saturates at `Int.max`; token buckets are non-negative, so checked
/// addition in `i64` is the same function.
pub fn adding_saturating(lhs: i64, rhs: i64) -> i64 {
    lhs.saturating_add(rhs)
}

/// Mirror of `DailyUsageAccumulator.addingFiniteCost`: a non-finite or negative addition is
/// rejected, and a total that overflows to infinity is treated as no total.
pub(super) fn adding_finite_cost(current: Option<f64>, addition: f64) -> Option<f64> {
    if !addition.is_finite() || addition < 0.0 {
        return None;
    }
    let total = current.unwrap_or(0.0) + addition;
    total.is_finite().then_some(total)
}

/// `PromptRateTier` has explicit snake_case coding keys in Swift, unlike the synthesized
/// camelCase keys on `ModelRates`; match that wire shape exactly.
#[derive(Debug, Clone, Deserialize, serde::Serialize, Default, PartialEq)]
#[serde(default)]
pub struct PromptRateTier {
    pub threshold_prompt_tokens: i64,
    pub includes_threshold: bool,
    pub input_per_million: Option<f64>,
    pub output_per_million: Option<f64>,
    pub cache_write_per_million: Option<f64>,
    pub cache_read_per_million: Option<f64>,
    pub cache_write_1h_per_million: Option<f64>,
}

/// Mirror of `UTCPriceRateOverride`. Present so resolved rates can round-trip byte-for-byte;
/// the folds price aggregate log rows without an event timestamp and never consult these lanes.
#[derive(Debug, Clone, Deserialize, serde::Serialize, Default, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct UtcPriceRateOverride {
    pub utc_days: Option<Vec<String>>,
    pub utc_start_minute: Option<i64>,
    pub utc_end_minute: Option<i64>,
    pub input_per_million: Option<f64>,
    pub output_per_million: Option<f64>,
    pub cache_write_per_million: Option<f64>,
    pub cache_read_per_million: Option<f64>,
    pub cache_write_1h_per_million: Option<f64>,
}

/// The fields of `ModelRates` the folds read, plus the timed lanes a resolved rate can carry.
#[derive(Debug, Clone, Deserialize, serde::Serialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct ModelRates {
    pub input_per_million: f64,
    pub output_per_million: f64,
    pub cache_write_per_million: f64,
    pub cache_read_per_million: f64,
    pub cache_write_1h_per_million: Option<f64>,
    pub prompt_rate_tiers: Vec<PromptRateTier>,
    pub utc_price_overrides: Option<Vec<UtcPriceRateOverride>>,
    pub input_above_200k_per_million: Option<f64>,
    pub output_above_200k_per_million: Option<f64>,
    pub cache_write_above_200k_per_million: Option<f64>,
    pub cache_read_above_200k_per_million: Option<f64>,
    pub cache_read_is_explicit: bool,
    pub long_context_threshold_tokens: i64,
    pub fast_multiplier: f64,
}

impl Default for ModelRates {
    fn default() -> Self {
        Self {
            input_per_million: 0.0,
            output_per_million: 0.0,
            cache_write_per_million: 0.0,
            cache_read_per_million: 0.0,
            cache_write_1h_per_million: None,
            prompt_rate_tiers: Vec::new(),
            utc_price_overrides: None,
            input_above_200k_per_million: None,
            output_above_200k_per_million: None,
            cache_write_above_200k_per_million: None,
            cache_read_above_200k_per_million: None,
            cache_read_is_explicit: true,
            long_context_threshold_tokens: 200_000,
            fast_multiplier: 1.0,
        }
    }
}

impl ModelRates {
    /// Mirror of `ModelRates.scaled(by:)`: every dollar figure is scaled, and the fast multiplier
    /// is reset (the scaled copy already is the fast variant).
    pub fn scaled(&self, factor: f64) -> ModelRates {
        ModelRates {
            input_per_million: self.input_per_million * factor,
            output_per_million: self.output_per_million * factor,
            cache_write_per_million: self.cache_write_per_million * factor,
            cache_read_per_million: self.cache_read_per_million * factor,
            cache_write_1h_per_million: self.cache_write_1h_per_million.map(|value| value * factor),
            prompt_rate_tiers: self
                .prompt_rate_tiers
                .iter()
                .map(|tier| PromptRateTier {
                    threshold_prompt_tokens: tier.threshold_prompt_tokens,
                    includes_threshold: tier.includes_threshold,
                    input_per_million: tier.input_per_million.map(|value| value * factor),
                    output_per_million: tier.output_per_million.map(|value| value * factor),
                    cache_write_per_million: tier
                        .cache_write_per_million
                        .map(|value| value * factor),
                    cache_read_per_million: tier.cache_read_per_million.map(|value| value * factor),
                    cache_write_1h_per_million: tier
                        .cache_write_1h_per_million
                        .map(|value| value * factor),
                })
                .collect(),
            utc_price_overrides: self.utc_price_overrides.as_ref().map(|overrides| {
                overrides
                    .iter()
                    .map(|tier| UtcPriceRateOverride {
                        utc_days: tier.utc_days.clone(),
                        utc_start_minute: tier.utc_start_minute,
                        utc_end_minute: tier.utc_end_minute,
                        input_per_million: tier.input_per_million.map(|value| value * factor),
                        output_per_million: tier.output_per_million.map(|value| value * factor),
                        cache_write_per_million: tier
                            .cache_write_per_million
                            .map(|value| value * factor),
                        cache_read_per_million: tier
                            .cache_read_per_million
                            .map(|value| value * factor),
                        cache_write_1h_per_million: tier
                            .cache_write_1h_per_million
                            .map(|value| value * factor),
                    })
                    .collect()
            }),
            input_above_200k_per_million: self
                .input_above_200k_per_million
                .map(|value| value * factor),
            output_above_200k_per_million: self
                .output_above_200k_per_million
                .map(|value| value * factor),
            cache_write_above_200k_per_million: self
                .cache_write_above_200k_per_million
                .map(|value| value * factor),
            cache_read_above_200k_per_million: self
                .cache_read_above_200k_per_million
                .map(|value| value * factor),
            cache_read_is_explicit: self.cache_read_is_explicit,
            long_context_threshold_tokens: self.long_context_threshold_tokens,
            fast_multiplier: 1.0,
        }
    }

    /// Mirror of `ModelRates.costDollars(for:)` with no timestamp and long-context tiers enabled.
    pub fn cost_dollars(&self, tokens: &TokenBreakdown) -> f64 {
        let prompt_tokens = tokens.prompt_tokens();
        let multiplier = if tokens.is_fast {
            self.fast_multiplier
        } else {
            1.0
        };
        let use_long_context = prompt_tokens > self.long_context_threshold_tokens;
        let selected_tier = self
            .prompt_rate_tiers
            .iter()
            .filter(|tier| {
                if tier.includes_threshold {
                    prompt_tokens >= tier.threshold_prompt_tokens
                } else {
                    prompt_tokens > tier.threshold_prompt_tokens
                }
            })
            .max_by(|lhs, rhs| {
                lhs.threshold_prompt_tokens
                    .cmp(&rhs.threshold_prompt_tokens)
            });

        let input_base = self.input_per_million;
        let input_rate = selected_rate(
            input_base,
            self.input_above_200k_per_million,
            selected_tier.and_then(|tier| tier.input_per_million),
            use_long_context,
        );
        let output_rate = selected_rate(
            self.output_per_million,
            self.output_above_200k_per_million,
            selected_tier.and_then(|tier| tier.output_per_million),
            use_long_context,
        );
        let cache_write_rate = selected_rate(
            self.cache_write_per_million,
            self.cache_write_above_200k_per_million,
            selected_tier.and_then(|tier| tier.cache_write_per_million),
            use_long_context,
        );
        let cache_read_rate = if self.cache_read_is_explicit {
            selected_rate(
                self.cache_read_per_million,
                self.cache_read_above_200k_per_million,
                selected_tier.and_then(|tier| tier.cache_read_per_million),
                use_long_context,
            )
        } else {
            input_rate
        };
        let cache_write_1h_rate = selected_tier
            .and_then(|tier| tier.cache_write_1h_per_million)
            .or(self.cache_write_1h_per_million)
            .unwrap_or_else(|| input_rate * CACHE_WRITE_1H_INPUT_MULTIPLIER);

        let cost = per_million(tokens.input, input_rate)
            + per_million(tokens.output, output_rate)
            + per_million(tokens.cache_write_5m, cache_write_rate)
            + per_million(tokens.cache_write_1h, cache_write_1h_rate)
            + per_million(tokens.cache_read, cache_read_rate);
        cost * multiplier
    }
}

fn selected_rate(
    base: f64,
    long_context: Option<f64>,
    prompt_tier: Option<f64>,
    use_long_context: bool,
) -> f64 {
    prompt_tier.unwrap_or_else(|| {
        if use_long_context {
            long_context.unwrap_or(base)
        } else {
            base
        }
    })
}

fn per_million(tokens: i64, rate_per_million: f64) -> f64 {
    tokens as f64 * rate_per_million / 1_000_000.0
}

/// Mirror of `TokenBreakdown`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct TokenBreakdown {
    pub input: i64,
    pub cache_write_5m: i64,
    pub cache_write_1h: i64,
    pub cache_read: i64,
    pub output: i64,
    pub is_fast: bool,
}

impl TokenBreakdown {
    pub fn prompt_tokens(&self) -> i64 {
        let writes = adding_saturating(self.cache_write_5m, self.cache_write_1h);
        adding_saturating(adding_saturating(self.input, writes), self.cache_read)
    }

    pub fn total_tokens(&self) -> i64 {
        adding_saturating(self.prompt_tokens(), self.output)
    }
}

/// Local-calendar day starts for one scan window, ascending. Built by Swift from
/// `Calendar.current`; the fold only chooses the last boundary at or before a timestamp.
pub struct DayBoundaries {
    entries: Vec<(f64, String)>,
}

impl DayBoundaries {
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let array = value
            .as_array()
            .filter(|array| !array.is_empty())
            .ok_or_else(|| "`dayBoundaries` must be a non-empty array".to_string())?;
        let mut entries: Vec<(f64, String)> = Vec::with_capacity(array.len());
        let mut previous: Option<f64> = None;
        for element in array {
            let pair = element
                .as_array()
                .filter(|pair| pair.len() == 2)
                .ok_or_else(|| {
                    "each `dayBoundaries` entry must be [start, \"yyyy-MM-dd\"]".to_string()
                })?;
            let start = pair[0]
                .as_f64()
                .filter(|value| value.is_finite())
                .ok_or_else(|| "day boundary start must be a finite number".to_string())?;
            let key = pair[1]
                .as_str()
                .filter(|key| key.len() == 10)
                .ok_or_else(|| "day boundary key must be a `yyyy-MM-dd` string".to_string())?
                .to_string();
            if previous.is_some_and(|previous| start < previous) {
                return Err("day boundaries must be ascending".to_string());
            }
            previous = Some(start);
            entries.push((start, key));
        }
        Ok(Self { entries })
    }

    /// The day key for a timestamp: the last boundary whose start is at or before it. Timestamps
    /// before the first boundary (or after the last) clamp to the edge day, matching what
    /// `Calendar.current` produced for the same window.
    pub fn key_for(&self, timestamp: f64) -> &str {
        let index = self
            .entries
            .partition_point(|(start, _)| *start <= timestamp);
        if index == 0 {
            &self.entries[0].1
        } else {
            &self.entries[index - 1].1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn rates() -> ModelRates {
        ModelRates {
            input_per_million: 10.0,
            output_per_million: 20.0,
            cache_write_per_million: 12.5,
            cache_read_per_million: 1.0,
            ..ModelRates::default()
        }
    }

    #[test]
    fn prices_each_token_lane() {
        let tokens = TokenBreakdown {
            input: 1_000_000,
            cache_write_5m: 1_000_000,
            cache_write_1h: 1_000_000,
            cache_read: 1_000_000,
            output: 1_000_000,
            is_fast: false,
        };
        // 10 + 20 + 12.5 + (10 * 2) + 1
        assert!((rates().cost_dollars(&tokens) - 63.5).abs() < 1e-9);
    }

    #[test]
    fn applies_long_context_lanes_above_the_threshold() {
        let mut rates = rates();
        rates.input_above_200k_per_million = Some(30.0);
        rates.long_context_threshold_tokens = 200_000;
        let tokens = TokenBreakdown {
            input: 200_001,
            output: 1_000_000,
            ..TokenBreakdown::default()
        };
        assert!((rates.cost_dollars(&tokens) - (200_001.0 * 30.0 / 1e6 + 20.0)).abs() < 1e-9);
    }

    #[test]
    fn prompt_tier_overrides_the_long_context_lane() {
        let mut rates = rates();
        rates.input_above_200k_per_million = Some(30.0);
        rates.prompt_rate_tiers = vec![PromptRateTier {
            threshold_prompt_tokens: 100_000,
            includes_threshold: false,
            input_per_million: Some(15.0),
            ..PromptRateTier::default()
        }];
        let tokens = TokenBreakdown {
            input: 150_000,
            ..TokenBreakdown::default()
        };
        assert!((rates.cost_dollars(&tokens) - 150_000.0 * 15.0 / 1e6).abs() < 1e-9);
    }

    #[test]
    fn boundaries_choose_the_last_start_at_or_before_the_timestamp() {
        let boundaries = DayBoundaries::from_value(&json!([
            [100.0, "2026-01-01"],
            [200.0, "2026-01-02"],
            [300.0, "2026-01-03"]
        ]))
        .unwrap();
        assert_eq!(boundaries.key_for(99.0), "2026-01-01");
        assert_eq!(boundaries.key_for(200.0), "2026-01-02");
        assert_eq!(boundaries.key_for(299.9), "2026-01-02");
        assert_eq!(boundaries.key_for(10_000.0), "2026-01-03");
    }
}
