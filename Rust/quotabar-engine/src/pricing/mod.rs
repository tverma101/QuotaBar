//! Model pricing for spend imputation (Swift `Sources/QuotaBar/Pricing`, see `docs/pricing.md`).
//!
//! Prices are estimates from public catalogues plus QuotaBar's curated supplement, never provider
//! billing. Resolution order and matching rules are documented in [`resolve`].

pub mod catalog;
pub mod codecs;
mod discovery;
pub mod rates;
pub mod resolve;
pub mod store;
pub mod supplement;

pub use catalog::{normalized_key, PricingCatalog};
pub use rates::{ModelRates, PromptRateTier, TokenBreakdown, UtcPriceRateOverride};
pub use resolve::ModelPricing;
pub use store::{shared, shared_if_initialized, PricingStore, SourceId, StoreConfig};
pub use supplement::{AliasRule, PricingSupplement};

/// Swift `GatewaySlug.identity`: a slug carrying a routing path (`vendor/openai/model`) groups under
/// the model its suffix resolved to; bare slugs (including deliberately distinct identities such as
/// `gpt-reserve`) keep their own name.
pub fn gateway_identity(slug: &str, resolved_pricing_model: Option<&str>) -> String {
    if !slug.contains('/') {
        return slug.to_string();
    }
    resolved_pricing_model.unwrap_or(slug).to_string()
}

#[cfg(test)]
mod tests;
