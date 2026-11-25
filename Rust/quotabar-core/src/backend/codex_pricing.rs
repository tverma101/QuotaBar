//! Codex rollout pricing policy.
//!
//! Mirror of the static helpers in `CodexLogUsageScanner`: dated-suffix model identity, the
//! long-context lanes for the GPT-5.x/6 families, priority and service-tier multipliers, and the
//! no-cache-discount models. Kept beside the fold so the policy that scales per event is one module
//! and the event decoding stays in [`super::codex_fold`].

use super::accounting::{ModelRates, TokenBreakdown};

pub(super) fn codex_cost(
    rates: &ModelRates,
    input: i64,
    cached: i64,
    output: i64,
    model: &str,
    fast_tier: bool,
    fast_multiplier: f64,
) -> f64 {
    let mut effective = rates.clone();
    if let Some(long_context) = codex_long_context_rates(model) {
        effective.input_above_200k_per_million = Some(long_context.input);
        effective.output_above_200k_per_million = Some(long_context.output);
        effective.cache_read_above_200k_per_million = Some(long_context.cache_read);
        effective.long_context_threshold_tokens = 272_000;
    }
    if codex_model_has_no_cache_discount(model) {
        effective.cache_read_per_million = effective.input_per_million;
        effective.cache_read_above_200k_per_million = effective.input_above_200k_per_million;
    } else if !rates.cache_read_is_explicit {
        effective.cache_read_per_million = effective.input_per_million;
        effective.cache_read_above_200k_per_million = effective.input_above_200k_per_million;
    }
    effective.fast_multiplier = fast_multiplier;

    let non_cached = (input - cached).max(0);
    effective.cost_dollars(&TokenBreakdown {
        input: non_cached,
        cache_read: cached,
        output,
        is_fast: fast_tier,
        ..TokenBreakdown::default()
    })
}

pub(super) fn codex_priority_multiplier(model: &str, rates: &ModelRates) -> f64 {
    match dated_base_model(model).as_str() {
        "gpt-5.5" | "gpt-5.5-pro" => 2.5,
        "gpt-5.4" | "gpt-5.4-pro" | "gpt-5.6-sol" | "gpt-5.6-terra" | "gpt-5.6-luna"
        | "gpt-6-sol" | "gpt-6-terra" | "gpt-6-luna" | "gpt-6-astra" => 2.0,
        _ => {
            if rates.fast_multiplier == 1.0 {
                2.0
            } else {
                rates.fast_multiplier
            }
        }
    }
}

pub(super) fn codex_service_tier_multiplier(
    model: &str,
    service_tier: Option<&str>,
) -> Option<f64> {
    let base = dated_base_model(model);
    let slug = base.split('/').last().unwrap_or(&base);
    if slug != "gpt-6.1-sol" {
        return None;
    }
    match service_tier?.to_lowercase().as_str() {
        "fast" | "priority" => Some(2.0),
        "flex" | "batch" => Some(0.5),
        "ultrafast" => Some(6.0),
        _ => None,
    }
}

fn codex_model_has_no_cache_discount(model: &str) -> bool {
    matches!(
        dated_base_model(model).as_str(),
        "gpt-5.4-pro" | "gpt-5.5-pro"
    )
}

fn codex_long_context_rates(model: &str) -> Option<LongContextRates> {
    match dated_base_model(model).as_str() {
        "gpt-5.4" => Some(LongContextRates::new(5.0, 22.5, 0.5)),
        "gpt-5.4-pro" => Some(LongContextRates::new(60.0, 270.0, 60.0)),
        "gpt-5.5" => Some(LongContextRates::new(10.0, 45.0, 1.0)),
        "gpt-5.5-pro" => Some(LongContextRates::new(60.0, 270.0, 60.0)),
        "gpt-5.6-sol" => Some(LongContextRates::new(8.0, 30.0, 0.8)),
        "gpt-5.6-terra" | "gpt-6-terra" => Some(LongContextRates::new(4.0, 18.0, 0.4)),
        "gpt-5.6-luna" => Some(LongContextRates::new(0.4, 1.8, 0.04)),
        "gpt-6-sol" => Some(LongContextRates::new(4.0, 15.0, 0.4)),
        "gpt-6-astra" => Some(LongContextRates::new(20.0, 75.0, 2.0)),
        "gpt-6-luna" => Some(LongContextRates::new(0.2, 0.75, 0.02)),
        _ => None,
    }
}

struct LongContextRates {
    input: f64,
    output: f64,
    cache_read: f64,
}

impl LongContextRates {
    fn new(input: f64, output: f64, cache_read: f64) -> Self {
        Self {
            input,
            output,
            cache_read,
        }
    }
}

fn dated_base_model(model: &str) -> String {
    strip_dated_suffix(model, true)
        .or_else(|| strip_dated_suffix(model, false))
        .unwrap_or_else(|| model.to_string())
}

/// Mirror of `stripDatedSuffix`: `-YYYY-MM-DD` (11 bytes) or `-YYYYMMDD` (9 bytes).
fn strip_dated_suffix(model: &str, separated: bool) -> Option<String> {
    let bytes = model.as_bytes();
    let suffix_length = if separated { 11 } else { 9 };
    if bytes.len() < suffix_length {
        return None;
    }
    let start = bytes.len() - suffix_length;
    if bytes[start] != b'-' {
        return None;
    }
    if separated {
        for offset in 1..=10 {
            let byte = bytes[start + offset];
            if offset == 5 || offset == 8 {
                if byte != b'-' {
                    return None;
                }
            } else if !byte.is_ascii_digit() {
                return None;
            }
        }
    } else {
        for offset in 1..=8 {
            if !bytes[start + offset].is_ascii_digit() {
                return None;
            }
        }
    }
    Some(model[..start].to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_dated_suffixes() {
        assert_eq!(dated_base_model("gpt-5.2-2026-05-12"), "gpt-5.2");
        assert_eq!(dated_base_model("gpt-5.2-20260512"), "gpt-5.2");
        assert_eq!(dated_base_model("gpt-5.2"), "gpt-5.2");
    }
}
