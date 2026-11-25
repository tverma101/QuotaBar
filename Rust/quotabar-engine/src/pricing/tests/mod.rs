//! Pricing tests ported from the Swift suites (`ModelPricingTests`, `PricingBundledResourceTests`,
//! `GatewaySlugRealPricingTests`, and the behavioral cases of `PricingCompactCatalogTests`).

mod bundled;
mod codecs;
mod resolution;

use super::catalog::PricingCatalog;
use super::rates::{ModelRates, TokenBreakdown};
use super::resolve::ModelPricing;
use super::supplement::PricingSupplement;
use std::collections::HashMap;

/// Swift `XCTAssertEqual(_, _, accuracy:)`.
pub(super) fn assert_close(actual: f64, expected: f64, accuracy: f64, what: &str) {
    assert!(
        (actual - expected).abs() <= accuracy,
        "{what}: expected {expected} +/- {accuracy}, got {actual}"
    );
}

/// `rates(input, output)` with cache lanes defaulting to the input rate, like the Swift helper.
pub(super) fn rates(input: f64, output: f64) -> ModelRates {
    ModelRates::new(input, output, input, input)
}

pub(super) fn rates_with(
    input: f64,
    output: f64,
    cache_write: Option<f64>,
    cache_read: Option<f64>,
    fast: f64,
) -> ModelRates {
    let mut r = ModelRates::new(
        input,
        output,
        cache_write.unwrap_or(input),
        cache_read.unwrap_or(input),
    );
    r.fast_multiplier = fast;
    r
}

pub(super) fn cat<const N: usize>(entries: [(&str, ModelRates); N]) -> PricingCatalog {
    PricingCatalog::from_entries(
        entries
            .into_iter()
            .map(|(k, v)| (k.to_string(), v))
            .collect::<HashMap<_, _>>(),
    )
}

/// Swift `makePricing`: any catalog may be empty; `supplement_json` is decoded when given.
pub(super) fn make_pricing(
    supplement_json: Option<&str>,
    primary: PricingCatalog,
    secondary: PricingCatalog,
    open_router: PricingCatalog,
) -> ModelPricing {
    let supplement = match supplement_json {
        Some(json) => {
            PricingSupplement::decode(json.as_bytes()).expect("supplement fixture decodes")
        }
        None => PricingSupplement::default(),
    };
    ModelPricing::new(supplement, primary, secondary, open_router, None)
}

pub(super) fn tokens(
    input: i64,
    cache_write_5m: i64,
    cache_write_1h: i64,
    cache_read: i64,
    output: i64,
) -> TokenBreakdown {
    TokenBreakdown {
        input,
        cache_write_5m,
        cache_write_1h,
        cache_read,
        output,
        is_fast: false,
    }
}

pub(super) fn input_tokens(input: i64) -> TokenBreakdown {
    TokenBreakdown {
        input,
        ..Default::default()
    }
}

/// `rates.costDollars(for:)` with the Swift defaults (no timestamp, long-context rates on).
pub(super) fn cost(rates: &ModelRates, tokens: &TokenBreakdown) -> f64 {
    rates.cost_dollars(tokens, None, true)
}

pub(super) fn input_of(pricing: &ModelPricing, model: &str) -> Option<f64> {
    pricing.resolve(model).map(|r| r.input_per_million)
}

/// Seconds since 1970 for an RFC 3339 timestamp (Swift `ISO8601DateFormatter().date(from:)`).
pub(super) fn epoch(rfc3339: &str) -> f64 {
    chrono::DateTime::parse_from_rfc3339(rfc3339)
        .expect("valid timestamp")
        .timestamp() as f64
}
