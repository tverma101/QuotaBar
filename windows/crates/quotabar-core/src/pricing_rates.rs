use crate::log_usage_types::TokenBreakdown;
use chrono::{DateTime, Datelike, Timelike, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub(super) struct PromptRateTier {
    pub(super) threshold_prompt_tokens: i64,
    #[serde(default)]
    pub(super) includes_threshold: bool,
    pub(super) input_per_million: Option<f64>,
    pub(super) output_per_million: Option<f64>,
    pub(super) cache_write_per_million: Option<f64>,
    pub(super) cache_read_per_million: Option<f64>,
    pub(super) cache_write_1h_per_million: Option<f64>,
}

impl PromptRateTier {
    fn scaled(&self, factor: f64) -> Self {
        Self {
            input_per_million: self.input_per_million.map(|v| v * factor),
            output_per_million: self.output_per_million.map(|v| v * factor),
            cache_write_per_million: self.cache_write_per_million.map(|v| v * factor),
            cache_read_per_million: self.cache_read_per_million.map(|v| v * factor),
            cache_write_1h_per_million: self.cache_write_1h_per_million.map(|v| v * factor),
            ..*self
        }
    }
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub(super) struct UtcRateOverride {
    #[serde(alias = "utcDays")]
    pub(super) utc_days: Option<Vec<String>>,
    #[serde(alias = "utcStartMinute")]
    pub(super) utc_start_minute: Option<u32>,
    #[serde(alias = "utcEndMinute")]
    pub(super) utc_end_minute: Option<u32>,
    #[serde(alias = "inputPerMillion")]
    pub(super) input_per_million: Option<f64>,
    #[serde(alias = "outputPerMillion")]
    pub(super) output_per_million: Option<f64>,
    #[serde(alias = "cacheWritePerMillion")]
    pub(super) cache_write_per_million: Option<f64>,
    #[serde(alias = "cacheReadPerMillion")]
    pub(super) cache_read_per_million: Option<f64>,
    #[serde(alias = "cacheWrite1hPerMillion")]
    pub(super) cache_write_1h_per_million: Option<f64>,
}

pub(super) const UTC_DAYS: [&str; 7] = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"];

impl UtcRateOverride {
    fn matches(&self, day: usize, minute: u32) -> bool {
        let matches_day = |day| self.utc_days.as_ref()
            .is_none_or(|days| days.iter().any(|value| value == UTC_DAYS[day]));
        match (self.utc_start_minute, self.utc_end_minute) {
            (Some(start), Some(end)) if start < end => matches_day(day) && (start..end).contains(&minute),
            (Some(start), Some(end)) if start > end => {
                (minute >= start && matches_day(day)) || (minute < end && matches_day((day + 6) % 7))
            }
            (Some(_), Some(_)) => false,
            (Some(start), None) => matches_day(day) && minute >= start,
            (None, Some(end)) => matches_day(day) && minute < end,
            (None, None) => matches_day(day),
        }
    }

    fn scaled(&self, factor: f64) -> Self {
        Self {
            input_per_million: self.input_per_million.map(|v| v * factor),
            output_per_million: self.output_per_million.map(|v| v * factor),
            cache_write_per_million: self.cache_write_per_million.map(|v| v * factor),
            cache_read_per_million: self.cache_read_per_million.map(|v| v * factor),
            cache_write_1h_per_million: self.cache_write_1h_per_million.map(|v| v * factor),
            ..self.clone()
        }
    }
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct ModelRates {
    pub input_per_million: f64,
    pub output_per_million: f64,
    pub cache_write_per_million: f64,
    pub cache_read_per_million: f64,
    pub(super) cache_write_1h_per_million: Option<f64>,
    pub(super) prompt_rate_tiers: Vec<PromptRateTier>,
    pub(super) utc_rate_overrides: Vec<UtcRateOverride>,
    pub input_above_200k: Option<f64>,
    pub output_above_200k: Option<f64>,
    pub cache_write_above_200k: Option<f64>,
    pub cache_read_above_200k: Option<f64>,
    /// Catalog published an explicit cache-read rate (not a synthesized 10%-of-input fallback).
    pub cache_read_is_explicit: bool,
    /// Prompt-token threshold for optional long-context rates (200k default; Codex uses 272k).
    pub long_context_threshold_tokens: i32,
    pub fast_multiplier: f64,
}

impl ModelRates {
    pub fn scaled(&self, factor: f64) -> Self {
        Self {
            input_per_million: self.input_per_million * factor,
            output_per_million: self.output_per_million * factor,
            cache_write_per_million: self.cache_write_per_million * factor,
            cache_read_per_million: self.cache_read_per_million * factor,
            cache_write_1h_per_million: self.cache_write_1h_per_million.map(|v| v * factor),
            prompt_rate_tiers: self
                .prompt_rate_tiers
                .iter()
                .map(|tier| tier.scaled(factor))
                .collect(),
            utc_rate_overrides: self.utc_rate_overrides.iter().map(|rate| rate.scaled(factor)).collect(),
            input_above_200k: self.input_above_200k.map(|v| v * factor),
            output_above_200k: self.output_above_200k.map(|v| v * factor),
            cache_write_above_200k: self.cache_write_above_200k.map(|v| v * factor),
            cache_read_above_200k: self.cache_read_above_200k.map(|v| v * factor),
            cache_read_is_explicit: self.cache_read_is_explicit,
            long_context_threshold_tokens: self.long_context_threshold_tokens,
            fast_multiplier: 1.0,
        }
    }

    /// Dollar cost of one request. When `apply_long_context_rates` and prompt tokens
    /// exceed `long_context_threshold_tokens`, the whole request uses long-context rates
    /// (upstream OpenUsage 0.7.4 #885 / 0.7.6 #995).
    pub fn cost_dollars(&self, tokens: &TokenBreakdown) -> f64 {
        self.cost_dollars_with_options(tokens, true)
    }

    pub fn cost_dollars_with_options(
        &self,
        tokens: &TokenBreakdown,
        apply_long_context_rates: bool,
    ) -> f64 {
        self.cost_dollars_at(tokens, None, apply_long_context_rates)
    }

    pub fn cost_dollars_at(
        &self,
        tokens: &TokenBreakdown,
        timestamp: Option<DateTime<Utc>>,
        apply_long_context_rates: bool,
    ) -> f64 {
        const CACHE_WRITE_1H_MULT: f64 = 2.0;
        let mult = if tokens.is_fast { self.fast_multiplier } else { 1.0 };
        let prompt_tokens = [
            tokens.input,
            tokens.cache_write5m,
            tokens.cache_write1h,
            tokens.cache_read,
        ]
        .into_iter()
        .map(i64::from)
        .sum::<i64>();
        let use_long = apply_long_context_rates
            && prompt_tokens > i64::from(self.long_context_threshold_tokens);
        let tier = self
            .prompt_rate_tiers
            .iter()
            .filter(|tier| {
                apply_long_context_rates
                    && (prompt_tokens > tier.threshold_prompt_tokens
                        || (tier.includes_threshold && prompt_tokens == tier.threshold_prompt_tokens))
            })
            .max_by_key(|tier| tier.threshold_prompt_tokens);
        let select = |base, long, prompt: Option<f64>| {
            prompt.unwrap_or_else(|| selected_rate(base, long, use_long))
        };
        let timed = timestamp.filter(|_| !self.utc_rate_overrides.is_empty()).and_then(|ts| {
            let day = ts.weekday().num_days_from_monday() as usize;
            let minute = ts.hour() * 60 + ts.minute();
            self.utc_rate_overrides.iter().find(|rate| rate.matches(day, minute))
        });
        let input_rate = select(
            timed.and_then(|t| t.input_per_million).unwrap_or(self.input_per_million),
            self.input_above_200k,
            tier.and_then(|t| t.input_per_million),
        );
        let output_rate = select(
            timed.and_then(|t| t.output_per_million).unwrap_or(self.output_per_million),
            self.output_above_200k,
            tier.and_then(|t| t.output_per_million),
        );
        let cache_write_rate = select(
            timed.and_then(|t| t.cache_write_per_million).unwrap_or(self.cache_write_per_million),
            self.cache_write_above_200k,
            tier.and_then(|t| t.cache_write_per_million),
        );
        let cache_read_rate = if self.cache_read_is_explicit {
            select(
                timed.and_then(|t| t.cache_read_per_million).unwrap_or(self.cache_read_per_million),
                self.cache_read_above_200k,
                tier.and_then(|t| t.cache_read_per_million),
            )
        } else {
            input_rate
        };
        let cache_write_1h_rate = tier
            .and_then(|t| t.cache_write_1h_per_million)
            .or_else(|| timed.and_then(|t| t.cache_write_1h_per_million))
            .or(self.cache_write_1h_per_million)
            .unwrap_or(input_rate * CACHE_WRITE_1H_MULT);

        let cost = flat_cost(tokens.input, input_rate)
            + flat_cost(tokens.output, output_rate)
            + flat_cost(tokens.cache_write5m, cache_write_rate)
            + flat_cost(tokens.cache_write1h, cache_write_1h_rate)
            + flat_cost(tokens.cache_read, cache_read_rate);
        cost * mult
    }
}

fn selected_rate(base: f64, long_context: Option<f64>, use_long: bool) -> f64 {
    if use_long {
        long_context.unwrap_or(base)
    } else {
        base
    }
}

pub(super) fn flat_cost(tokens: i32, rate_per_million: f64) -> f64 {
    if tokens <= 0 {
        return 0.0;
    }
    f64::from(tokens) * rate_per_million / 1_000_000.0
}
