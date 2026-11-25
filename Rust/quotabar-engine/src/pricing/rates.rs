//! Per-model rates and the per-request cost formula (Swift `ModelRates.swift`).

use serde::{Deserialize, Serialize};

/// A whole-request price tier selected by prompt length. The feed threshold is exclusive unless
/// `includes_threshold` ("over 100k"); unspecified lanes inherit the regular or legacy long-context
/// rate. JSON keys are snake_case, as in the compact catalogs and the supplement.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PromptRateTier {
    pub threshold_prompt_tokens: i64,
    #[serde(default)]
    pub includes_threshold: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input_per_million: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_per_million: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_write_per_million: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_read_per_million: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_write_1h_per_million: Option<f64>,
}

impl PromptRateTier {
    pub fn has_rates(&self) -> bool {
        self.input_per_million.is_some()
            || self.output_per_million.is_some()
            || self.cache_write_per_million.is_some()
            || self.cache_read_per_million.is_some()
            || self.cache_write_1h_per_million.is_some()
    }

    fn scaled(&self, factor: f64) -> PromptRateTier {
        PromptRateTier {
            threshold_prompt_tokens: self.threshold_prompt_tokens,
            includes_threshold: self.includes_threshold,
            input_per_million: self.input_per_million.map(|v| v * factor),
            output_per_million: self.output_per_million.map(|v| v * factor),
            cache_write_per_million: self.cache_write_per_million.map(|v| v * factor),
            cache_read_per_million: self.cache_read_per_million.map(|v| v * factor),
            cache_write_1h_per_million: self.cache_write_1h_per_million.map(|v| v * factor),
        }
    }
}

/// OpenRouter price lane selected by UTC weekday and minute of day. JSON keys are camelCase (the
/// Swift synthesized coding keys the compact cache already uses).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UtcPriceRateOverride {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub utc_days: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub utc_start_minute: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub utc_end_minute: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input_per_million: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_per_million: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_write_per_million: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_read_per_million: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_write_1h_per_million: Option<f64>,
}

impl UtcPriceRateOverride {
    pub fn has_rates(&self) -> bool {
        self.input_per_million.is_some()
            || self.output_per_million.is_some()
            || self.cache_write_per_million.is_some()
            || self.cache_read_per_million.is_some()
            || self.cache_write_1h_per_million.is_some()
    }

    pub fn matches(&self, weekday: &str, previous_weekday: &str, minute_of_day: i64) -> bool {
        let day_in = |day: &str| self.utc_days.as_ref().map_or(true, |days| days.iter().any(|d| d == day));
        let current = day_in(weekday);
        match (self.utc_start_minute, self.utc_end_minute) {
            (Some(start), Some(end)) if start < end => current && minute_of_day >= start && minute_of_day < end,
            (Some(start), Some(end)) if start > end => {
                (current && minute_of_day >= start) || (day_in(previous_weekday) && minute_of_day < end)
            }
            (Some(_), Some(_)) => false,
            (Some(start), None) => current && minute_of_day >= start,
            (None, Some(end)) => current && minute_of_day < end,
            (None, None) => current,
        }
    }

    fn scaled(&self, factor: f64) -> UtcPriceRateOverride {
        UtcPriceRateOverride {
            utc_days: self.utc_days.clone(),
            utc_start_minute: self.utc_start_minute,
            utc_end_minute: self.utc_end_minute,
            input_per_million: self.input_per_million.map(|v| v * factor),
            output_per_million: self.output_per_million.map(|v| v * factor),
            cache_write_per_million: self.cache_write_per_million.map(|v| v * factor),
            cache_read_per_million: self.cache_read_per_million.map(|v| v * factor),
            cache_write_1h_per_million: self.cache_write_1h_per_million.map(|v| v * factor),
        }
    }
}

pub const DEFAULT_LONG_CONTEXT_THRESHOLD: i64 = 200_000;

/// Per-million-token USD rates for one model. Serialized camelCase so a fold can persist the rates
/// it priced with and compare them field for field against a later snapshot.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelRates {
    pub input_per_million: f64,
    pub output_per_million: f64,
    /// 5-minute cache writes; equals the input rate for providers without a separate price.
    pub cache_write_per_million: f64,
    pub cache_read_per_million: f64,
    /// Explicit 1-hour cache-write rate; otherwise 2x the selected input rate.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_write_1h_per_million: Option<f64>,
    #[serde(default)]
    pub prompt_rate_tiers: Vec<PromptRateTier>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub utc_price_overrides: Option<Vec<UtcPriceRateOverride>>,
    #[serde(default, rename = "inputAbove200kPerMillion", skip_serializing_if = "Option::is_none")]
    pub input_above_200k_per_million: Option<f64>,
    #[serde(default, rename = "outputAbove200kPerMillion", skip_serializing_if = "Option::is_none")]
    pub output_above_200k_per_million: Option<f64>,
    #[serde(default, rename = "cacheWriteAbove200kPerMillion", skip_serializing_if = "Option::is_none")]
    pub cache_write_above_200k_per_million: Option<f64>,
    #[serde(default, rename = "cacheReadAbove200kPerMillion", skip_serializing_if = "Option::is_none")]
    pub cache_read_above_200k_per_million: Option<f64>,
    /// Whether the source published the cache-read rate. When not, cache reads bill at the selected
    /// input rate rather than an invented discount.
    #[serde(default = "default_true")]
    pub cache_read_is_explicit: bool,
    #[serde(default = "default_threshold")]
    pub long_context_threshold_tokens: i64,
    #[serde(default = "default_multiplier")]
    pub fast_multiplier: f64,
}

fn default_true() -> bool {
    true
}
fn default_threshold() -> i64 {
    DEFAULT_LONG_CONTEXT_THRESHOLD
}
fn default_multiplier() -> f64 {
    1.0
}

impl ModelRates {
    /// Flat rates with every optional lane absent.
    pub fn new(input: f64, output: f64, cache_write: f64, cache_read: f64) -> ModelRates {
        ModelRates {
            input_per_million: input,
            output_per_million: output,
            cache_write_per_million: cache_write,
            cache_read_per_million: cache_read,
            cache_write_1h_per_million: None,
            prompt_rate_tiers: Vec::new(),
            utc_price_overrides: None,
            input_above_200k_per_million: None,
            output_above_200k_per_million: None,
            cache_write_above_200k_per_million: None,
            cache_read_above_200k_per_million: None,
            cache_read_is_explicit: true,
            long_context_threshold_tokens: DEFAULT_LONG_CONTEXT_THRESHOLD,
            fast_multiplier: 1.0,
        }
    }

    /// Every dollar figure scaled (prices `-fast` slugs off their base entry). The result carries no
    /// fast multiplier of its own.
    pub fn scaled(&self, factor: f64) -> ModelRates {
        let scale = |v: Option<f64>| v.map(|v| v * factor);
        ModelRates {
            input_per_million: self.input_per_million * factor,
            output_per_million: self.output_per_million * factor,
            cache_write_per_million: self.cache_write_per_million * factor,
            cache_read_per_million: self.cache_read_per_million * factor,
            cache_write_1h_per_million: scale(self.cache_write_1h_per_million),
            prompt_rate_tiers: self.prompt_rate_tiers.iter().map(|t| t.scaled(factor)).collect(),
            utc_price_overrides: self.utc_price_overrides.as_ref().map(|o| o.iter().map(|t| t.scaled(factor)).collect()),
            input_above_200k_per_million: scale(self.input_above_200k_per_million),
            output_above_200k_per_million: scale(self.output_above_200k_per_million),
            cache_write_above_200k_per_million: scale(self.cache_write_above_200k_per_million),
            cache_read_above_200k_per_million: scale(self.cache_read_above_200k_per_million),
            cache_read_is_explicit: self.cache_read_is_explicit,
            long_context_threshold_tokens: self.long_context_threshold_tokens,
            fast_multiplier: 1.0,
        }
    }

    /// Dollar cost of one request: request-wide long-context tier, prompt-length tier, UTC timed lane
    /// (when `timestamp` is given) and fast multiplier. Aggregated sources that lose request
    /// boundaries pass `apply_long_context_rates = false`.
    pub fn cost_dollars(&self, tokens: &TokenBreakdown, timestamp: Option<f64>, apply_long_context_rates: bool) -> f64 {
        let multiplier = if tokens.is_fast { self.fast_multiplier } else { 1.0 };
        let prompt = tokens.prompt_tokens();
        let use_long = apply_long_context_rates && prompt > self.long_context_threshold_tokens;
        let tier = if apply_long_context_rates { self.selected_prompt_tier(prompt) } else { None };
        let timed = timestamp.and_then(|ts| self.utc_price_override(ts));

        let select = |base: f64, long: Option<f64>, tier_rate: Option<f64>| -> f64 {
            tier_rate.unwrap_or(if use_long { long.unwrap_or(base) } else { base })
        };
        let base_input = timed.and_then(|t| t.input_per_million).unwrap_or(self.input_per_million);
        let input_rate = select(base_input, self.input_above_200k_per_million, tier.and_then(|t| t.input_per_million));
        let output_rate = select(
            timed.and_then(|t| t.output_per_million).unwrap_or(self.output_per_million),
            self.output_above_200k_per_million,
            tier.and_then(|t| t.output_per_million),
        );
        let cache_write_rate = select(
            timed.and_then(|t| t.cache_write_per_million).unwrap_or(self.cache_write_per_million),
            self.cache_write_above_200k_per_million,
            tier.and_then(|t| t.cache_write_per_million),
        );
        let cache_read_rate = if self.cache_read_is_explicit {
            select(
                timed.and_then(|t| t.cache_read_per_million).unwrap_or(self.cache_read_per_million),
                self.cache_read_above_200k_per_million,
                tier.and_then(|t| t.cache_read_per_million),
            )
        } else {
            input_rate
        };
        let cache_write_1h_rate = tier
            .and_then(|t| t.cache_write_1h_per_million)
            .or_else(|| timed.and_then(|t| t.cache_write_1h_per_million))
            .or(self.cache_write_1h_per_million)
            .unwrap_or_else(|| input_rate * CACHE_WRITE_1H_INPUT_MULTIPLIER);

        let cost = cost(tokens.input, input_rate)
            + cost(tokens.output, output_rate)
            + cost(tokens.cache_write_5m, cache_write_rate)
            + cost(tokens.cache_write_1h, cache_write_1h_rate)
            + cost(tokens.cache_read, cache_read_rate);
        cost * multiplier
    }

    /// The highest-threshold tier the prompt crosses; the first such tier wins a tie (Swift
    /// `max(by:)` keeps the earlier element).
    fn selected_prompt_tier(&self, prompt: i64) -> Option<&PromptRateTier> {
        let mut best: Option<&PromptRateTier> = None;
        for tier in &self.prompt_rate_tiers {
            let crosses = if tier.includes_threshold {
                prompt >= tier.threshold_prompt_tokens
            } else {
                prompt > tier.threshold_prompt_tokens
            };
            if crosses && best.map_or(true, |b| b.threshold_prompt_tokens < tier.threshold_prompt_tokens) {
                best = Some(tier);
            }
        }
        best
    }

    fn utc_price_override(&self, timestamp: f64) -> Option<&UtcPriceRateOverride> {
        let overrides = self.utc_price_overrides.as_ref().filter(|o| !o.is_empty())?;
        if !timestamp.is_finite() {
            return None;
        }
        let seconds = timestamp.floor() as i64;
        let days = seconds.div_euclid(86_400);
        let minute_of_day = seconds.rem_euclid(86_400) / 60;
        // 1970-01-01 was a Thursday (index 4 counting from Sunday).
        let index = (days + 4).rem_euclid(7) as usize;
        let previous = (index + 6) % 7;
        overrides.iter().find(|o| o.matches(UTC_WEEKDAYS[index], UTC_WEEKDAYS[previous], minute_of_day))
    }
}

const CACHE_WRITE_1H_INPUT_MULTIPLIER: f64 = 2.0;
const UTC_WEEKDAYS: [&str; 7] = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];

fn cost(tokens: i64, rate_per_million: f64) -> f64 {
    tokens as f64 * rate_per_million / 1_000_000.0
}

/// Token counts split into the buckets that price differently. Every scanner normalizes into this.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenBreakdown {
    #[serde(default)]
    pub input: i64,
    #[serde(default)]
    pub cache_write_5m: i64,
    #[serde(default)]
    pub cache_write_1h: i64,
    #[serde(default)]
    pub cache_read: i64,
    #[serde(default)]
    pub output: i64,
    #[serde(default)]
    pub is_fast: bool,
}

impl TokenBreakdown {
    /// Input that selects the long-context tier (output is billed at the selected tier but does not
    /// select it).
    pub fn prompt_tokens(&self) -> i64 {
        self.input
            .saturating_add(self.cache_write_5m.saturating_add(self.cache_write_1h))
            .saturating_add(self.cache_read)
    }

    pub fn total_tokens(&self) -> i64 {
        self.prompt_tokens().saturating_add(self.output)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tokens(input: i64, output: i64) -> TokenBreakdown {
        TokenBreakdown { input, output, ..Default::default() }
    }

    #[test]
    fn flat_cost_and_fast_multiplier() {
        let mut rates = ModelRates::new(3.0, 15.0, 3.75, 0.3);
        rates.fast_multiplier = 6.0;
        let t = TokenBreakdown { input: 1_000_000, output: 100_000, cache_read: 2_000_000, cache_write_5m: 10, ..Default::default() };
        let expected = 3.0 + 1.5 + 0.6 + 10.0 * 3.75 / 1e6;
        assert!((rates.cost_dollars(&t, None, true) - expected).abs() < 1e-12);
        let fast = TokenBreakdown { is_fast: true, ..t };
        assert!((rates.cost_dollars(&fast, None, true) - expected * 6.0).abs() < 1e-9);
    }

    #[test]
    fn long_context_and_prompt_tiers() {
        let mut rates = ModelRates::new(3.0, 15.0, 3.75, 0.3);
        rates.input_above_200k_per_million = Some(6.0);
        rates.output_above_200k_per_million = Some(22.5);
        // Exactly 200k stays standard; above it the whole request bills long-context.
        assert_eq!(rates.cost_dollars(&tokens(200_000, 0), None, true), 0.6);
        assert_eq!(rates.cost_dollars(&tokens(200_001, 1_000_000), None, true), 200_001.0 * 6.0 / 1e6 + 22.5);
        assert_eq!(rates.cost_dollars(&tokens(200_001, 0), None, false), 200_001.0 * 3.0 / 1e6);

        rates.prompt_rate_tiers = vec![
            PromptRateTier { threshold_prompt_tokens: 100_000, includes_threshold: true, input_per_million: Some(4.0), ..tier0() },
            PromptRateTier { threshold_prompt_tokens: 300_000, includes_threshold: false, input_per_million: Some(8.0), ..tier0() },
        ];
        assert_eq!(rates.cost_dollars(&tokens(100_000, 0), None, true), 0.4);
        assert_eq!(rates.cost_dollars(&tokens(300_000, 0), None, true), 300_000.0 * 4.0 / 1e6);
        assert_eq!(rates.cost_dollars(&tokens(300_001, 0), None, true), 300_001.0 * 8.0 / 1e6);
    }

    fn tier0() -> PromptRateTier {
        PromptRateTier {
            threshold_prompt_tokens: 0,
            includes_threshold: false,
            input_per_million: None,
            output_per_million: None,
            cache_write_per_million: None,
            cache_read_per_million: None,
            cache_write_1h_per_million: None,
        }
    }

    #[test]
    fn implicit_cache_read_bills_at_input_and_1h_writes_double_input() {
        let mut rates = ModelRates::new(2.0, 8.0, 2.0, 2.0);
        rates.cache_read_is_explicit = false;
        rates.cache_read_per_million = 0.2;
        let t = TokenBreakdown { cache_read: 1_000_000, cache_write_1h: 1_000_000, ..Default::default() };
        assert_eq!(rates.cost_dollars(&t, None, true), 2.0 + 4.0);
    }

    #[test]
    fn utc_override_selects_by_weekday_and_minute() {
        let mut rates = ModelRates::new(1.0, 1.0, 1.0, 1.0);
        rates.utc_price_overrides = Some(vec![UtcPriceRateOverride {
            utc_days: Some(vec!["monday".into()]),
            utc_start_minute: Some(22 * 60),
            utc_end_minute: Some(2 * 60),
            input_per_million: Some(0.5),
            output_per_million: None,
            cache_write_per_million: None,
            cache_read_per_million: None,
            cache_write_1h_per_million: None,
        }]);
        // 2026-11-23 is a Monday. 23:00 Monday matches; 01:00 Tuesday matches via previous day.
        let monday_2300 = 1_795_474_800.0 - 3600.0 * 0.0; // 2026-11-23T23:00:00Z
        assert_eq!(rates.cost_dollars(&tokens(1_000_000, 0), Some(monday_2300), true), 0.5);
        assert_eq!(rates.cost_dollars(&tokens(1_000_000, 0), Some(monday_2300 + 7200.0), true), 0.5);
        assert_eq!(rates.cost_dollars(&tokens(1_000_000, 0), Some(monday_2300 - 7200.0), true), 1.0);
        assert_eq!(rates.cost_dollars(&tokens(1_000_000, 0), None, true), 1.0);
    }

    #[test]
    fn saturating_prompt_tokens() {
        let t = TokenBreakdown { input: i64::MAX, cache_read: 5, output: 1, ..Default::default() };
        assert_eq!(t.prompt_tokens(), i64::MAX);
        assert_eq!(t.total_tokens(), i64::MAX);
    }
}
