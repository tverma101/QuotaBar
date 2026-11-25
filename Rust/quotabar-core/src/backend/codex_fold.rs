//! Codex rollout fold.
//!
//! Port of `CodexLogUsageScanner.accumulate` + `aggregate` (the per-file fold the scanner stores in
//! its inode aggregate cache). Events arrive from Swift in a fixed-stride binary payload; pricing
//! identity and rates come either from a Rust snapshot handle (resolved here per distinct
//! `pricingModel`) or, on the fallback path, from the pre-resolved table Swift still builds.
//!
//! The Codex-specific pricing policy is carried over verbatim: dated-suffix model identity,
//! long-context lanes for the GPT-5.x/6 families, priority and service-tier multipliers, and the
//! no-cache-discount models.

use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};

use super::accounting::{
    DailyUsageAccumulator, DayBoundaries, ModelRates, TokenBreakdown, UNATTRIBUTED_MODEL_NAME,
};
use super::codex_pricing::{codex_cost, codex_priority_multiplier, codex_service_tier_multiplier};
use super::pricing::FoldPricing;
use super::{invalid_param, BackendError};

/// Fixed byte stride of one Codex event in the payload.
pub const CODEX_EVENT_STRIDE: usize = 64;

/// `OpenCodeUsageScanner.claudeGatewayPrefixes`.
const CLAUDE_GATEWAY_PREFIXES: [&str; 2] = ["anthropic/opencode_go/", "anthropic/opencode/"];

#[derive(Debug, Clone)]
struct CodexEvent {
    timestamp: f64,
    input: i64,
    cached: i64,
    output: i64,
    reasoning: i64,
    total: i64,
    model: u32,
    pricing_model: Option<u32>,
    service_tier: Option<u32>,
    has_complete_cost_breakdown: bool,
    is_fast: bool,
}

#[derive(Debug, Clone)]
struct CodexPricing {
    canonical: String,
    rate_model: String,
    base_rates: Option<ModelRates>,
    resolved_rates: Option<ModelRates>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct EventKey {
    timestamp_bits: u64,
    model: u32,
    pricing_model: Option<u32>,
    input: i64,
    cached: i64,
    output: i64,
    reasoning: i64,
    total: i64,
    has_complete_cost_breakdown: bool,
    is_fast: bool,
    service_tier: Option<u32>,
}

pub fn fold(params: &Value, payload: &[u8]) -> Result<Value, BackendError> {
    let since = required_number(params, "since")?;
    let boundaries = DayBoundaries::from_value(
        params
            .get("dayBoundaries")
            .ok_or_else(|| invalid_param("missing `dayBoundaries`".to_string()))?,
    )
    .map_err(invalid_param)?;
    let models = string_pool(params, "models")?;
    let service_tiers = string_pool(params, "serviceTiers")?;
    let mut backend_pricing = if FoldPricing::handle_present(params) {
        Some(FoldPricing::from_params(params)?)
    } else {
        None
    };
    let inline_pricing = if backend_pricing.is_none() {
        Some(pricing_table(params)?)
    } else {
        None
    };
    let events = decode_events(payload, &models, &service_tiers)?;
    // Build the per-model pricing entries for every event in the buffer, including events the
    // window later drops, mirroring the Swift wrapper's pre-pass and its discovery candidates.
    let mut pricing_cache: HashMap<String, CodexPricing> = HashMap::new();
    for event in &events {
        let raw_model = models[event.model as usize].as_str();
        let trimmed = raw_model.trim();
        let model = if trimmed.is_empty() {
            UNATTRIBUTED_MODEL_NAME
        } else {
            trimmed
        };
        let pricing_model = match event.pricing_model {
            Some(index) => models[index as usize].as_str(),
            None => model,
        };
        if pricing_cache.contains_key(pricing_model) {
            continue;
        }
        let entry = if let Some(pricing) = backend_pricing.as_mut() {
            backend_codex_pricing(pricing, pricing_model)
        } else {
            inline_pricing
                .as_ref()
                .and_then(|table| table.get(pricing_model))
                .cloned()
                .ok_or_else(|| {
                    invalid_param(format!("missing pricing entry for `{pricing_model}`"))
                })?
        };
        pricing_cache.insert(pricing_model.to_string(), entry);
    }

    let mut seen: HashSet<EventKey> = HashSet::new();
    let mut accumulator = DailyUsageAccumulator::default();

    for event in &events {
        if event.timestamp < since {
            continue;
        }
        let key = EventKey {
            timestamp_bits: normalize_bits(event.timestamp),
            model: event.model,
            pricing_model: event.pricing_model,
            input: event.input,
            cached: event.cached,
            output: event.output,
            reasoning: event.reasoning,
            total: event.total,
            has_complete_cost_breakdown: event.has_complete_cost_breakdown,
            is_fast: event.is_fast,
            service_tier: event.service_tier,
        };
        if !seen.insert(key) {
            continue;
        }

        let day = boundaries.key_for(event.timestamp);
        let raw_model = models[event.model as usize].as_str();
        let trimmed = raw_model.trim();
        let model = if trimmed.is_empty() {
            UNATTRIBUTED_MODEL_NAME
        } else {
            trimmed
        };
        if is_hosted_gateway_model(model) {
            continue;
        }

        // When the event carries no explicit pricing model, Swift resolves the *trimmed* emitted
        // name (or "Unattributed" for an empty one), so mirror that instead of the raw pool entry.
        let pricing_model = match event.pricing_model {
            Some(index) => models[index as usize].as_str(),
            None => model,
        };
        let pricing_entry = pricing_cache
            .get(pricing_model)
            .cloned()
            .ok_or_else(|| invalid_param(format!("missing pricing entry for `{pricing_model}`")))?;

        let api_estimate = if event.has_complete_cost_breakdown {
            pricing_entry.resolved_rates.as_ref().map(|rates| {
                rates.cost_dollars(&TokenBreakdown {
                    input: (event.input - event.cached).max(0),
                    cache_read: event.cached,
                    output: event.output,
                    ..TokenBreakdown::default()
                })
            })
        } else {
            None
        };
        accumulator.record_api_estimate(day, api_estimate, event.total);

        let identity = gateway_identity(model, &pricing_entry.rate_model);
        let Some(rates) = pricing_entry.resolved_rates.as_ref() else {
            if event.total > 0 {
                accumulator.add_unknown_model(day, model);
            }
            accumulator.add(day, event.total, None, model, Some(identity), true, false);
            if !event.has_complete_cost_breakdown {
                accumulator.mark_cost_incomplete(day, model, Some(identity));
            }
            continue;
        };

        let is_fast_alias = pricing_entry.canonical.ends_with("-fast");
        let applies_fast_tier = if is_fast_alias {
            pricing_entry.base_rates.is_some()
        } else {
            event.is_fast
        };
        let service_tier = event
            .service_tier
            .map(|index| service_tiers[index as usize].as_str());
        let service_tier_multiplier =
            codex_service_tier_multiplier(&pricing_entry.rate_model, service_tier);
        let fast_tier = service_tier_multiplier.is_some() || applies_fast_tier;
        let fast_multiplier = service_tier_multiplier
            .unwrap_or_else(|| codex_priority_multiplier(&pricing_entry.rate_model, rates));
        let event_cost = event.has_complete_cost_breakdown.then(|| {
            codex_cost(
                rates,
                event.input,
                event.cached,
                event.output,
                &pricing_entry.rate_model,
                fast_tier,
                fast_multiplier,
            )
        });

        accumulator.add(
            day,
            event.total,
            event_cost,
            model,
            Some(identity),
            true,
            false,
        );
        if !event.has_complete_cost_breakdown {
            accumulator.mark_cost_incomplete(day, model, Some(identity));
        }
    }

    Ok(json!({
        "scan": accumulator.build(),
        "recheckModels": backend_pricing
            .map(|mut pricing| pricing.take_recheck())
            .unwrap_or_default(),
    }))
}

/// Resolve one `pricingModel` the way `CodexRustFold.FoldContext.pricingEntry` does: alias to the
/// canonical identity, split a `-fast` alias, then resolve the rate model (falling back to the
/// emitted name).
fn backend_codex_pricing(pricing: &mut FoldPricing, pricing_model: &str) -> CodexPricing {
    let canonical = pricing
        .canonical(pricing_model)
        .map(str::to_string)
        .unwrap_or_else(|| pricing_model.to_string());
    let rate_model = canonical
        .strip_suffix("-fast")
        .map(str::to_string)
        .unwrap_or_else(|| canonical.clone());
    let base_rates = pricing.resolve(&rate_model);
    let resolved_rates = match &base_rates {
        Some(rates) => Some(rates.clone()),
        None => pricing.resolve(pricing_model),
    };
    CodexPricing {
        canonical,
        rate_model,
        base_rates,
        resolved_rates,
    }
}

fn required_number(params: &Value, key: &str) -> Result<f64, BackendError> {
    params
        .get(key)
        .and_then(Value::as_f64)
        .filter(|value| value.is_finite())
        .ok_or_else(|| invalid_param(format!("missing finite number parameter `{key}`")))
}

fn string_pool(params: &Value, key: &str) -> Result<Vec<String>, BackendError> {
    params
        .get(key)
        .and_then(Value::as_array)
        .ok_or_else(|| invalid_param(format!("missing `{key}` string array")))?
        .iter()
        .map(|value| {
            value
                .as_str()
                .map(str::to_string)
                .ok_or_else(|| invalid_param(format!("`{key}` must contain only strings")))
        })
        .collect()
}

fn pricing_table(params: &Value) -> Result<HashMap<String, CodexPricing>, BackendError> {
    let object = params
        .get("pricing")
        .and_then(Value::as_object)
        .ok_or_else(|| invalid_param("missing `pricing` object".to_string()))?;
    let mut table = HashMap::with_capacity(object.len());
    for (model, value) in object {
        let canonical = value
            .get("canonical")
            .and_then(Value::as_str)
            .ok_or_else(|| invalid_param(format!("missing `canonical` for `{model}`")))?
            .to_string();
        let rate_model = value
            .get("rateModel")
            .and_then(Value::as_str)
            .ok_or_else(|| invalid_param(format!("missing `rateModel` for `{model}`")))?
            .to_string();
        let base_rates = decode_rates(value.get("baseRates"))?;
        let resolved_rates = decode_rates(value.get("resolvedRates"))?;
        table.insert(
            model.clone(),
            CodexPricing {
                canonical,
                rate_model,
                base_rates,
                resolved_rates,
            },
        );
    }
    Ok(table)
}

fn decode_rates(value: Option<&Value>) -> Result<Option<ModelRates>, BackendError> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(value) => serde_json::from_value(value.clone())
            .map(Some)
            .map_err(|error| invalid_param(format!("invalid pricing rates: {error}"))),
    }
}

fn decode_events(
    payload: &[u8],
    models: &[String],
    service_tiers: &[String],
) -> Result<Vec<CodexEvent>, BackendError> {
    if payload.len() % CODEX_EVENT_STRIDE != 0 {
        return Err(invalid_param(format!(
            "payload length {} is not a multiple of {CODEX_EVENT_STRIDE}",
            payload.len()
        )));
    }
    let mut events = Vec::with_capacity(payload.len() / CODEX_EVENT_STRIDE);
    for chunk in payload.chunks_exact(CODEX_EVENT_STRIDE) {
        let timestamp = f64::from_le_bytes(chunk[0..8].try_into().expect("8 bytes"));
        if !timestamp.is_finite() {
            return Err(invalid_param("event timestamp is not finite".to_string()));
        }
        let input = u64::from_le_bytes(chunk[8..16].try_into().expect("8 bytes"));
        let cached = u64::from_le_bytes(chunk[16..24].try_into().expect("8 bytes"));
        let output = u64::from_le_bytes(chunk[24..32].try_into().expect("8 bytes"));
        let reasoning = u64::from_le_bytes(chunk[32..40].try_into().expect("8 bytes"));
        let total = u64::from_le_bytes(chunk[40..48].try_into().expect("8 bytes"));
        let model = i32::from_le_bytes(chunk[48..52].try_into().expect("4 bytes"));
        let pricing_model = i32::from_le_bytes(chunk[52..56].try_into().expect("4 bytes"));
        let service_tier = i32::from_le_bytes(chunk[56..60].try_into().expect("4 bytes"));
        let flags = chunk[60];

        let model = pool_index(model)
            .ok_or_else(|| invalid_param("event model index is missing".to_string()))?;
        let pricing_model = pool_index(pricing_model);
        let service_tier = pool_index(service_tier);
        if model as usize >= models.len() {
            return Err(invalid_param("event model index out of range".to_string()));
        }
        if let Some(index) = pricing_model {
            if index as usize >= models.len() {
                return Err(invalid_param(
                    "event pricing model index out of range".to_string(),
                ));
            }
        }
        if let Some(index) = service_tier {
            if index as usize >= service_tiers.len() {
                return Err(invalid_param(
                    "event service tier index out of range".to_string(),
                ));
            }
        }

        events.push(CodexEvent {
            timestamp,
            input: to_i64(input),
            cached: to_i64(cached),
            output: to_i64(output),
            reasoning: to_i64(reasoning),
            total: to_i64(total),
            model,
            pricing_model,
            service_tier,
            has_complete_cost_breakdown: flags & 0b1 != 0,
            is_fast: flags & 0b10 != 0,
        });
    }
    Ok(events)
}

fn to_i64(value: u64) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}

fn pool_index(value: i32) -> Option<u32> {
    (value >= 0).then_some(value as u32)
}

fn normalize_bits(value: f64) -> u64 {
    if value == 0.0 {
        0.0f64.to_bits()
    } else {
        value.to_bits()
    }
}

fn is_hosted_gateway_model(model: &str) -> bool {
    CLAUDE_GATEWAY_PREFIXES
        .iter()
        .any(|prefix| model.starts_with(prefix))
}

/// Mirror of `GatewaySlug.identity(of:resolvedPricingModel:)`.
fn gateway_identity<'a>(model: &'a str, rate_model: &'a str) -> &'a str {
    if model.contains('/') {
        rate_model
    } else {
        model
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    struct EventSpec {
        timestamp: f64,
        input: u64,
        cached: u64,
        output: u64,
        reasoning: u64,
        total: u64,
        model: u32,
        pricing_model: Option<u32>,
        service_tier: Option<u32>,
        has_complete_cost_breakdown: bool,
        is_fast: bool,
    }

    impl Default for EventSpec {
        fn default() -> Self {
            Self {
                timestamp: 1_000.0,
                input: 0,
                cached: 0,
                output: 0,
                reasoning: 0,
                total: 0,
                model: 0,
                pricing_model: None,
                service_tier: None,
                has_complete_cost_breakdown: true,
                is_fast: false,
            }
        }
    }

    fn encode(events: &[EventSpec]) -> Vec<u8> {
        let mut payload = vec![0u8; events.len() * CODEX_EVENT_STRIDE];
        for (index, event) in events.iter().enumerate() {
            let start = index * CODEX_EVENT_STRIDE;
            let chunk = &mut payload[start..start + CODEX_EVENT_STRIDE];
            chunk[0..8].copy_from_slice(&event.timestamp.to_le_bytes());
            chunk[8..16].copy_from_slice(&event.input.to_le_bytes());
            chunk[16..24].copy_from_slice(&event.cached.to_le_bytes());
            chunk[24..32].copy_from_slice(&event.output.to_le_bytes());
            chunk[32..40].copy_from_slice(&event.reasoning.to_le_bytes());
            chunk[40..48].copy_from_slice(&event.total.to_le_bytes());
            chunk[48..52].copy_from_slice(&(event.model as i32).to_le_bytes());
            chunk[52..56]
                .copy_from_slice(&event.pricing_model.map_or(-1, |v| v as i32).to_le_bytes());
            chunk[56..60]
                .copy_from_slice(&event.service_tier.map_or(-1, |v| v as i32).to_le_bytes());
            let mut flags = 0u8;
            if event.has_complete_cost_breakdown {
                flags |= 0b1;
            }
            if event.is_fast {
                flags |= 0b10;
            }
            chunk[60] = flags;
        }
        payload
    }

    fn pricing_entry(canonical: &str, rate_model: &str, rates: Value) -> Value {
        json!({
            "canonical": canonical,
            "rateModel": rate_model,
            "baseRates": rates,
            "resolvedRates": rates,
        })
    }

    fn rates(input: f64, output: f64) -> Value {
        json!({
            "inputPerMillion": input,
            "outputPerMillion": output,
            "cacheWritePerMillion": input,
            "cacheReadPerMillion": input / 10.0,
            "cacheReadIsExplicit": true,
            "longContextThresholdTokens": 200000,
            "fastMultiplier": 1.0,
        })
    }

    #[test]
    fn folds_events_with_cache_and_dedup() {
        let payload = encode(&[
            EventSpec {
                input: 1_000,
                cached: 100,
                output: 200,
                total: 1_200,
                ..EventSpec::default()
            },
            EventSpec {
                input: 1_000,
                cached: 100,
                output: 200,
                total: 1_200,
                ..EventSpec::default()
            },
        ]);
        let params = json!({
            "since": 1_000.0,
            "dayBoundaries": [[1_000.0, "2026-01-01"]],
            "models": ["gpt-5.2"],
            "serviceTiers": [],
            "pricing": { "gpt-5.2": pricing_entry("gpt-5.2", "gpt-5.2", rates(10.0, 20.0)) },
        });
        let result = fold(&params, &payload).unwrap();
        assert_eq!(result["scan"]["series"]["daily"][0]["totalTokens"], 1_200);
        // (900 * 10 + 200 * 20 + 100 * 1) / 1e6
        let cost = result["scan"]["series"]["daily"][0]["costUSD"]
            .as_f64()
            .unwrap();
        assert!((cost - 0.0131).abs() < 1e-12);
    }

    #[test]
    fn applies_priority_multiplier_to_fast_events() {
        let payload = encode(&[EventSpec {
            input: 1_000_000,
            total: 1_000_000,
            is_fast: true,
            ..EventSpec::default()
        }]);
        let params = json!({
            "since": 1_000.0,
            "dayBoundaries": [[1_000.0, "2026-01-01"]],
            "models": ["gpt-5.5"],
            "serviceTiers": [],
            "pricing": { "gpt-5.5": pricing_entry("gpt-5.5", "gpt-5.5", rates(10.0, 20.0)) },
        });
        let result = fold(&params, &payload).unwrap();
        let cost = result["scan"]["series"]["daily"][0]["costUSD"]
            .as_f64()
            .unwrap();
        assert!((cost - 25.0).abs() < 1e-9);
    }

    #[test]
    fn missing_pricing_entry_is_an_invalid_request() {
        let payload = encode(&[EventSpec {
            input: 10,
            total: 10,
            ..EventSpec::default()
        }]);
        let params = json!({
            "since": 1_000.0,
            "dayBoundaries": [[1_000.0, "2026-01-01"]],
            "models": ["gpt-5.2"],
            "serviceTiers": [],
            "pricing": {},
        });
        assert_eq!(fold(&params, &payload).unwrap_err().kind, "invalid_request");
    }
}
