//! CodexRouter's append-only `usage-events.jsonl` ledger (Swift `CodexRouterUsageScanner`).
//!
//! The ledger meters routed Codex turns, including turns served through alternate providers. Rows
//! are account-scoped with CodexRouter's FCC-compatible fingerprint or a raw `accountId`; pool
//! aliases map opaque router ids onto the ChatGPT UUID QuotaBar cards use. Unscoped legacy rows are
//! absorbed only by the default (identity-less) card so multi-account installs never cross-attribute
//! history. The incremental scanner keeps an append-only parse checkpoint, and the priced fold is
//! cached by the provider when the window and pricing token are unchanged.

use super::event::Event;
use super::sessions::{codex_priority_multiplier, codex_service_tier_multiplier, cost};
use crate::accounting::{day_key, DailyUsageAccumulator, LogUsageScan, RowOptions};
use crate::context::CancelToken;
use crate::host;
use crate::model::ModelUsageEntry;
use crate::paths;
use crate::pricing::{ModelPricing, TokenBreakdown};
use crate::providers::claude::gateway::is_hosted_gateway_model;
use crate::scan::{DiscoveredFile, IncrementalScanner, LineError, LineParser, Revision, ScanStore};
use crate::time::format_iso8601;
use chrono::Utc;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

#[derive(Clone, Debug, PartialEq)]
pub enum CodexRouterScanResult {
    Complete(Option<LogUsageScan>),
    Incomplete,
}

#[derive(Clone, Debug, PartialEq)]
pub struct RouterEvent {
    pub timestamp: f64,
    pub model: Arc<str>,
    pub provider: Arc<str>,
    pub status: i64,
    pub input: i64,
    pub cached: i64,
    pub output: i64,
    pub reasoning: i64,
    pub total: Option<i64>,
    pub estimated_input: Option<i64>,
    pub account_id: Option<Arc<str>>,
    pub account_fingerprint: Option<Arc<str>>,
    pub service_tier: Option<Arc<str>>,
    pub valid_status: bool,
    pub valid_timestamp: bool,
    pub valid_model: bool,
    pub valid_numbers: bool,
    pub valid_provider: bool,
    pub valid_service_tier: bool,
    pub token_count_saturated: bool,
}

impl RouterEvent {
    fn is_malformed(&self) -> bool {
        !self.valid_status
            || !self.valid_timestamp
            || !self.valid_model
            || !self.valid_numbers
            || !self.valid_provider
    }

    fn is_success(&self) -> bool {
        self.valid_status && (200..300).contains(&self.status)
    }

    pub(crate) fn measured_total(&self) -> Option<i64> {
        let component = self.input.checked_add(self.output);
        match self.total {
            Some(total)
                if total == 0
                    && (self.input > 0
                        || self.output > 0
                        || self.cached > 0
                        || self.reasoning > 0) =>
            {
                component.filter(|value| *value > 0)
            }
            Some(total) => Some(total),
            None => component,
        }
    }

    fn has_no_measured_fields(&self) -> bool {
        self.total.is_none()
            && self.input == 0
            && self.output == 0
            && self.cached == 0
            && self.reasoning == 0
            && self.estimated_input.is_none()
    }

    pub(crate) fn complete_cost_breakdown(&self) -> bool {
        self.valid_numbers
            && self.cached <= self.input
            && self.total.map_or(true, |total| {
                total == self.input.saturating_add(self.output)
            })
            && self.estimated_input.map_or(true, |value| value <= 0)
            && self.valid_service_tier
            && !self.token_count_saturated
    }
}

impl crate::scan::Record for RouterEvent {
    fn encode(&self, w: &mut crate::scan::Writer) {
        w.f64(self.timestamp);
        w.str(&self.model);
        w.str(&self.provider);
        w.i64(self.status);
        for value in [self.input, self.cached, self.output, self.reasoning] {
            w.i64(value);
        }
        w.bool(self.valid_status);
        w.bool(self.valid_timestamp);
        w.bool(self.valid_model);
        w.bool(self.valid_numbers);
        w.bool(self.valid_provider);
        w.bool(self.valid_service_tier);
        w.bool(self.token_count_saturated);
        w.bool(self.total.is_some());
        if let Some(total) = self.total {
            w.i64(total);
        }
        w.bool(self.estimated_input.is_some());
        if let Some(value) = self.estimated_input {
            w.i64(value);
        }
        w.opt_str(self.account_id.as_deref());
        w.opt_str(self.account_fingerprint.as_deref());
        w.opt_str(self.service_tier.as_deref());
    }

    fn decode(r: &mut crate::scan::Reader<'_>) -> Option<Self> {
        let timestamp = r.f64()?;
        let model = r.str()?;
        let provider = r.str()?;
        let status = r.i64()?;
        let mut values = [0i64; 4];
        for value in &mut values {
            *value = r.i64()?;
        }
        let has_total = r.bool()?;
        let total = if has_total { Some(r.i64()?) } else { None };
        let has_estimated = r.bool()?;
        let estimated_input = if has_estimated { Some(r.i64()?) } else { None };
        Some(RouterEvent {
            timestamp,
            model,
            provider,
            status,
            input: values[0],
            cached: values[1],
            output: values[2],
            reasoning: values[3],
            valid_status: r.bool()?,
            valid_timestamp: r.bool()?,
            valid_model: r.bool()?,
            valid_numbers: r.bool()?,
            valid_provider: r.bool()?,
            valid_service_tier: r.bool()?,
            token_count_saturated: r.bool()?,
            total,
            estimated_input,
            account_id: r.opt_str()?,
            account_fingerprint: r.opt_str()?,
            service_tier: r.opt_str()?,
        })
    }
}

/// Parser for one retention window. Rows older than `since` are dropped before caching so a long
/// ledger does not keep its full history resident.
#[derive(Clone)]
struct RouterParser {
    since: f64,
}

impl LineParser for RouterParser {
    type Item = RouterEvent;
    type State = ();
    const LAYOUT: u32 = 3;

    fn wants(&self, line: &[u8]) -> bool {
        line.iter()
            .position(|byte| !byte.is_ascii_whitespace())
            .is_some_and(|index| line[index] == b'{')
    }

    fn parse(
        &self,
        _state: &mut (),
        line: &[u8],
        out: &mut Vec<RouterEvent>,
    ) -> Result<(), LineError> {
        let text = std::str::from_utf8(line).map_err(|_| LineError("router line is not UTF-8"))?;
        let parsed: Value = match serde_json::from_str(text) {
            Ok(value) => value,
            Err(_) => {
                let trimmed = text.trim();
                if trimmed.is_empty() {
                    return Ok(());
                }
                return Err(LineError("malformed router event"));
            }
        };
        let Some(object) = parsed.as_object() else {
            return Ok(());
        };
        let recognized = [
            "at",
            "model",
            "provider",
            "status",
            "inputTokens",
            "cachedInputTokens",
            "outputTokens",
            "reasoningTokens",
            "totalTokens",
            "estimatedInputTokens",
            "accountId",
            "accountFingerprint",
            "serviceTier",
        ]
        .iter()
        .any(|key| object.contains_key(*key));
        if !recognized {
            return Ok(());
        }
        let event = parse_event(object)?;
        if event.is_malformed() || event.timestamp >= self.since {
            out.push(event);
        }
        Ok(())
    }

    fn contributing_timestamp(&self, item: &RouterEvent) -> Option<f64> {
        Some(item.timestamp)
    }
}

fn parse_event(object: &serde_json::Map<String, Value>) -> Result<RouterEvent, LineError> {
    let string = |key: &str| object.get(key).and_then(Value::as_str).map(str::to_string);
    let number = |key: &str| object.get(key).and_then(Value::as_f64);
    let integer = |key: &str| {
        number(key)
            .filter(|value| {
                value.is_finite()
                    && value.fract() == 0.0
                    && *value >= 0.0
                    && *value <= i64::MAX as f64
            })
            .map(|value| value as i64)
    };

    let timestamp_text = string("at").unwrap_or_default();
    let timestamp = parse_iso(&timestamp_text);
    let model_raw = string("model");
    let provider_raw = string("provider");
    let status = integer("status");
    let input = integer("inputTokens");
    let cached = integer("cachedInputTokens");
    let output = integer("outputTokens");
    let reasoning = integer("reasoningTokens");
    let total = integer("totalTokens");
    let estimated_input = integer("estimatedInputTokens");
    let mut valid_numbers = true;
    for key in [
        "inputTokens",
        "cachedInputTokens",
        "outputTokens",
        "reasoningTokens",
        "totalTokens",
        "estimatedInputTokens",
    ] {
        if object.get(key).is_some_and(|value| !value.is_null()) && integer(key).is_none() {
            valid_numbers = false;
        }
    }
    let mut valid_status = status.is_some();
    if let Some(status) = status {
        valid_status = status == 0 || (100..600).contains(&status);
    }
    let service_tier = string("serviceTier")
        .map(|value| value.trim().to_lowercase())
        .filter(|value| !value.is_empty());
    let known_tiers = [
        "auto",
        "default",
        "standard",
        "priority",
        "fast",
        "flex",
        "batch",
        "ultrafast",
    ];
    let valid_service_tier = service_tier
        .as_ref()
        .map_or(true, |value| known_tiers.contains(&value.as_str()));
    let model = model_raw
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(ModelUsageEntry::UNATTRIBUTED)
        .to_string();
    let provider = provider_raw
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or("unknown")
        .to_string();
    let provider_valid = object.get("provider").map_or(true, Value::is_string)
        && provider_raw
            .as_ref()
            .map_or(true, |value| !value.trim().is_empty());
    Ok(RouterEvent {
        timestamp: timestamp.unwrap_or(0.0),
        model: Arc::from(model),
        provider: Arc::from(provider),
        status: status.unwrap_or(0),
        input: input.unwrap_or(0).max(0),
        cached: cached.unwrap_or(0).max(0),
        output: output.unwrap_or(0).max(0),
        reasoning: reasoning.unwrap_or(0).max(0),
        total,
        estimated_input,
        account_id: string("accountId")
            .map(|value| Arc::<str>::from(value.trim()))
            .filter(|value| !value.is_empty()),
        account_fingerprint: string("accountFingerprint")
            .map(|value| Arc::<str>::from(value.trim()))
            .filter(|value| !value.is_empty()),
        service_tier: service_tier.map(Arc::from),
        valid_status,
        valid_timestamp: timestamp.is_some(),
        valid_model: object.get("model").map_or(true, Value::is_string),
        valid_numbers,
        valid_provider: provider_valid,
        valid_service_tier,
        token_count_saturated: false,
    })
}

fn parse_iso(value: &str) -> Option<f64> {
    let text = value.trim();
    if text.is_empty() {
        return None;
    }
    chrono::DateTime::parse_from_rfc3339(text)
        .ok()
        .map(|date| date.timestamp_millis() as f64 / 1000.0)
        .or_else(|| {
            chrono::NaiveDateTime::parse_from_str(text, "%Y-%m-%dT%H:%M:%S%.f")
                .ok()
                .map(|date| date.and_utc().timestamp_millis() as f64 / 1000.0)
        })
}

#[derive(Clone, Debug)]
struct CachedFold {
    window: usize,
    pricing_token: String,
    result: Option<LogUsageScan>,
}

pub struct CodexRouterScanner {
    home: PathBuf,
    ledger_paths: Option<Vec<PathBuf>>,
    pool_paths: Option<Vec<PathBuf>>,
    optional_default_ledger: Option<PathBuf>,
    cache: Mutex<HashMap<String, CachedFold>>,
}

impl CodexRouterScanner {
    pub fn live(home: PathBuf) -> Self {
        let configured = configured_ledger_paths();
        CodexRouterScanner {
            home: home.clone(),
            ledger_paths: if configured.is_empty() {
                None
            } else {
                Some(configured)
            },
            pool_paths: None,
            optional_default_ledger: Some(home.join(".codex/codex-router/usage-events.jsonl")),
            cache: Mutex::new(HashMap::new()),
        }
    }

    pub fn new(home: PathBuf, ledger_paths: Vec<PathBuf>, pool_paths: Vec<PathBuf>) -> Self {
        CodexRouterScanner {
            home,
            ledger_paths: Some(ledger_paths),
            pool_paths: Some(pool_paths),
            optional_default_ledger: None,
            cache: Mutex::new(HashMap::new()),
        }
    }

    fn ledgers(&self) -> Vec<PathBuf> {
        match &self.ledger_paths {
            Some(paths) => paths.clone(),
            None => vec![self.home.join(".codex/codex-router/usage-events.jsonl")],
        }
    }

    fn pools(&self) -> Vec<PathBuf> {
        match &self.pool_paths {
            Some(paths) => paths.clone(),
            None => configured_pool_paths(&self.home),
        }
    }

    /// Successful routed turns served by an OpenCode-hosted provider. The native Codex card skips
    /// these; the OpenCode card folds them so they are counted exactly once. `None` means a ledger
    /// was incomplete or a row was implausibly future-dated.
    pub fn opencode_events(
        &self,
        days_back: usize,
        now: f64,
        cancel: &CancelToken,
    ) -> Option<Vec<RouterEvent>> {
        let Some(files) =
            discover_ledgers(&self.ledgers(), self.optional_default_ledger.as_deref())
        else {
            return None;
        };
        let days = days_back.max(1);
        let retention_days = days.max(35);
        let scanner = shared_scanner(&self.ledgers(), retention_days);
        let parsed = scanner.scan(&files, None, cancel).ok()?;
        if cancel.is_cancelled() {
            return None;
        }
        let since = now - (days.saturating_sub(1)) as f64 * 86_400.0;
        let mut events = Vec::new();
        for file in &parsed {
            for event in file.iter() {
                if event.is_malformed() {
                    return None;
                }
                if !event.is_success() || event.timestamp > now + 300.0 {
                    continue;
                }
                if event.timestamp < since || !is_opencode_served(event) {
                    continue;
                }
                if event.measured_total().unwrap_or(0) <= 0
                    && event.estimated_input.unwrap_or(0) <= 0
                {
                    continue;
                }
                events.push(event.clone());
            }
        }
        Some(events)
    }

    pub fn scan_result(
        &self,
        account_identity_key: Option<&str>,
        allows_unscoped_events: bool,
        days_back: usize,
        now: f64,
        pricing: &ModelPricing,
        cancel: &CancelToken,
    ) -> CodexRouterScanResult {
        let days = days_back.max(1);
        let pricing_token = pricing.aggregate_cache_token().to_string();
        let identity = account_identity_key
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_lowercase);
        let cache_key = format!(
            "{}|{}|{}|{}",
            identity.as_deref().unwrap_or("-"),
            allows_unscoped_events,
            days,
            self.ledgers()
                .iter()
                .map(|p| p.display().to_string())
                .collect::<Vec<_>>()
                .join(",")
        );
        {
            let cache = self.cache.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(cached) = cache.get(&cache_key) {
                if cached.window == days && cached.pricing_token == pricing_token {
                    return CodexRouterScanResult::Complete(cached.result.clone());
                }
            }
        }

        let Some(files) =
            discover_ledgers(&self.ledgers(), self.optional_default_ledger.as_deref())
        else {
            return CodexRouterScanResult::Incomplete;
        };
        let retention_days = days.max(35);
        let since = now - (retention_days.saturating_sub(1)) as f64 * 86_400.0;
        let scanner = shared_scanner(&self.ledgers(), retention_days);
        let parsed = match scanner.scan(&files, None, cancel) {
            Ok(parsed) => parsed,
            Err(_) => return CodexRouterScanResult::Incomplete,
        };
        if cancel.is_cancelled() {
            return CodexRouterScanResult::Incomplete;
        }
        let aliases = load_pool_aliases(&self.pools());
        let expected_fingerprint =
            super::proxy::CodexProxyScanner::account_fingerprint(identity.as_deref());
        let expected_account_id = identity.as_deref();
        let window_since = now - (days.saturating_sub(1)) as f64 * 86_400.0;
        let mut accumulator = DailyUsageAccumulator::new();
        let mut saw_rows = false;
        for file in &parsed {
            for event in file.iter() {
                if cancel.is_cancelled() {
                    return CodexRouterScanResult::Incomplete;
                }
                if event.is_malformed() {
                    if !belongs_to_account(
                        event,
                        expected_fingerprint.as_deref(),
                        expected_account_id,
                        &aliases,
                        allows_unscoped_events,
                    ) {
                        continue;
                    }
                    return CodexRouterScanResult::Incomplete;
                }
                if !event.is_success() {
                    continue;
                }
                if !belongs_to_account(
                    event,
                    expected_fingerprint.as_deref(),
                    expected_account_id,
                    &aliases,
                    allows_unscoped_events,
                ) {
                    continue;
                }
                if event.timestamp < window_since {
                    continue;
                }
                if event.timestamp > now {
                    continue;
                }
                if is_opencode_served(event) {
                    continue;
                }
                if is_hosted_gateway_model(&event.model) {
                    continue;
                }
                let Some(total) = event.measured_total() else {
                    if event.has_no_measured_fields() {
                        saw_rows = true;
                        accumulator.mark_unmeasured_usage(&day_key(event.timestamp));
                        continue;
                    }
                    return CodexRouterScanResult::Incomplete;
                };
                if total <= 0 {
                    continue;
                }
                saw_rows = true;
                let day = day_key(event.timestamp);
                let model = event.model.trim();
                let model = if model.is_empty() {
                    ModelUsageEntry::UNATTRIBUTED
                } else {
                    model
                };
                let resolved = resolve_router_pricing(model, event.timestamp, pricing);
                let Some(resolution) = resolved else {
                    if total > 0 {
                        accumulator.add_unknown_model(&day, model);
                    }
                    accumulator.add_with(
                        &day,
                        total,
                        None,
                        model,
                        RowOptions {
                            canonical: Some(model),
                            cost_is_complete: false,
                            token_count_saturated: event.token_count_saturated,
                        },
                    );
                    continue;
                };
                let input = event.input.max(0);
                let cached = event.cached.min(input);
                let breakdown = TokenBreakdown {
                    input: (input - cached).max(0),
                    cache_write_5m: 0,
                    cache_write_1h: 0,
                    cache_read: cached,
                    output: event.output.max(0),
                    is_fast: false,
                };
                let api_estimate = event
                    .complete_cost_breakdown()
                    .then(|| resolution.rates.cost_dollars(&breakdown, None, true));
                accumulator.record_api_estimate(&day, api_estimate, total);
                let is_priority =
                    matches!(event.service_tier.as_deref(), Some("fast" | "priority"));
                let service_multiplier = codex_service_tier_multiplier(
                    &resolution.pricing_model,
                    event.service_tier.as_deref(),
                );
                let log_event = Event {
                    timestamp: event.timestamp,
                    model: Arc::from(model),
                    pricing_model: Some(Arc::from(resolution.pricing_model.as_str())),
                    input,
                    cached,
                    output: event.output.max(0),
                    reasoning: event.reasoning.max(0),
                    total,
                    has_complete_cost_breakdown: event.complete_cost_breakdown(),
                    is_fast: is_priority || service_multiplier.is_some(),
                    service_tier: event.service_tier.clone(),
                };
                let dollars = cost(
                    &resolution.rates,
                    &log_event,
                    &resolution.pricing_model,
                    is_priority || service_multiplier.is_some(),
                    service_multiplier.unwrap_or(resolution.priority_multiplier),
                );
                accumulator.add_with(
                    &day,
                    total,
                    event.complete_cost_breakdown().then_some(dollars),
                    model,
                    RowOptions {
                        canonical: Some(&resolution.canonical_model),
                        cost_is_complete: event.complete_cost_breakdown(),
                        token_count_saturated: event.token_count_saturated,
                    },
                );
                if !event.complete_cost_breakdown() {
                    accumulator.mark_cost_incomplete(
                        &day,
                        model,
                        Some(&resolution.canonical_model),
                    );
                }
            }
        }
        if cancel.is_cancelled() {
            return CodexRouterScanResult::Incomplete;
        }
        let result = if saw_rows {
            let scan = accumulator.build();
            (!scan.series.daily.is_empty()
                || !scan.unknown_models_by_day.is_empty()
                || scan.unmeasured_usage_days.is_some())
            .then_some(scan)
        } else {
            None
        };
        self.cache.lock().unwrap_or_else(|e| e.into_inner()).insert(
            cache_key,
            CachedFold {
                window: days,
                pricing_token,
                result: result.clone(),
            },
        );
        let _ = since;
        CodexRouterScanResult::Complete(result)
    }
}

#[derive(Clone)]
struct PricingResolution {
    pricing_model: String,
    canonical_model: String,
    rates: Arc<crate::pricing::ModelRates>,
    priority_multiplier: f64,
}

fn resolve_router_pricing(
    model: &str,
    timestamp: f64,
    pricing: &ModelPricing,
) -> Option<PricingResolution> {
    let candidates = pricing_candidates(model);
    if let Some(pricing_model) = pricing.canonical_key(&candidates).or_else(|| {
        candidates
            .iter()
            .find(|candidate| pricing.is_priced(candidate))
            .cloned()
    }) {
        if let Some(rates) = pricing.resolve(&pricing_model) {
            let canonical = crate::pricing::gateway_identity(model, Some(pricing_model.as_str()));
            return Some(PricingResolution {
                priority_multiplier: codex_priority_multiplier(&pricing_model, &rates),
                canonical_model: canonical,
                pricing_model,
                rates,
            });
        }
    }
    let fallback = pricing_fallback_model(model, timestamp)?;
    let rates = pricing.resolve(&fallback)?;
    Some(PricingResolution {
        priority_multiplier: codex_priority_multiplier(&fallback, &rates),
        canonical_model: model.to_string(),
        pricing_model: fallback,
        rates,
    })
}

fn pricing_candidates(model: &str) -> Vec<String> {
    let mut candidates = vec![model.to_string()];
    let mut remainder = model;
    while let Some((_, rest)) = remainder.split_once('/') {
        if rest.is_empty() {
            break;
        }
        candidates.push(rest.to_string());
        remainder = rest;
    }
    candidates
}

fn pricing_fallback_model(model: &str, timestamp: f64) -> Option<String> {
    let trimmed = model.trim();
    let bare = trimmed
        .split('/')
        .filter(|part| !part.is_empty())
        .next_back()?;
    let normalized = bare.to_lowercase();
    if !(normalized == "codex-auto-review"
        || normalized == "gpt-reserve"
        || normalized.starts_with("gpt-reserve")
        || normalized.ends_with("-reserve"))
    {
        return None;
    }
    let date = format_iso8601(timestamp);
    Some(auto_review_fallback(&date))
}

fn auto_review_fallback(timestamp: &str) -> String {
    let day = timestamp.get(..10).unwrap_or("");
    let fallbacks = [
        ("2026-09-22", "gpt-6-luna"),
        ("2026-07-09", "gpt-5.6-luna"),
        ("2026-04-23", "gpt-5.5"),
        ("2026-03-05", "gpt-5.4"),
        ("2026-02-05", "gpt-5.3-codex"),
        ("2025-12-11", "gpt-5.2-codex"),
        ("2025-11-13", "gpt-5.1-codex"),
        ("2025-09-15", "gpt-5-codex"),
        ("2025-08-07", "gpt-5"),
    ];
    if !is_iso_day(day) {
        return "gpt-5".into();
    }
    fallbacks
        .iter()
        .find(|(released, _)| day >= *released)
        .map(|(_, model)| (*model).to_string())
        .unwrap_or_else(|| "gpt-5".into())
}

fn is_iso_day(value: &str) -> bool {
    value.len() == 10
        && value.as_bytes()[4] == b'-'
        && value.as_bytes()[7] == b'-'
        && value
            .as_bytes()
            .iter()
            .enumerate()
            .all(|(index, byte)| matches!(index, 4 | 7) || byte.is_ascii_digit())
}

fn is_opencode_served(event: &RouterEvent) -> bool {
    event.provider.trim().to_lowercase().starts_with("opencode")
        || is_hosted_gateway_model(&event.model)
}

fn belongs_to_account(
    event: &RouterEvent,
    expected_fingerprint: Option<&str>,
    expected_account_id: Option<&str>,
    aliases: &HashMap<String, String>,
    allows_unscoped_events: bool,
) -> bool {
    let has_identity = event.account_fingerprint.is_some() || event.account_id.is_some();
    if !has_identity {
        return allows_unscoped_events;
    }
    let fingerprint_matches = event
        .account_fingerprint
        .as_deref()
        .and_then(|fingerprint| {
            expected_fingerprint.map(|expected| fingerprint.eq_ignore_ascii_case(expected))
        });
    let account_matches = event.account_id.as_deref().and_then(|account_id| {
        let alias = aliases.get(&account_id.to_lowercase()).cloned();
        if let Some(expected) = expected_account_id {
            return Some(
                account_id.eq_ignore_ascii_case(expected)
                    || alias.is_some_and(|value| value.eq_ignore_ascii_case(expected)),
            );
        }
        alias.is_some().then_some(true)
    });
    if let (Some(fingerprint), Some(account)) = (fingerprint_matches, account_matches) {
        if fingerprint != account {
            return false;
        }
    }
    if fingerprint_matches == Some(true) || account_matches == Some(true) {
        return true;
    }
    if expected_fingerprint.is_some() || expected_account_id.is_some() {
        return false;
    }
    allows_unscoped_events
}

fn discover_ledgers(
    paths: &[PathBuf],
    optional_default: Option<&Path>,
) -> Option<Vec<DiscoveredFile>> {
    let mut files = Vec::new();
    let mut seen = HashSet::new();
    for path in paths {
        let canonical = std::fs::canonicalize(path).unwrap_or_else(|_| path.clone());
        if !seen.insert(canonical.clone()) {
            continue;
        }
        match std::fs::metadata(&canonical) {
            Ok(meta) if meta.is_file() => {
                let revision = Revision::read(&canonical).ok()?;
                files.push(DiscoveredFile {
                    path: canonical,
                    revision,
                });
            }
            Ok(_) => return None,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                if optional_default.is_some_and(|optional| canonical == optional) {
                    continue;
                }
                return None;
            }
            Err(_) => return None,
        }
    }
    files.sort_by(|a, b| a.path.cmp(&b.path));
    Some(files)
}

fn scanner_registry() -> &'static Mutex<HashMap<String, Arc<IncrementalScanner<RouterParser>>>> {
    static REGISTRY: OnceLock<Mutex<HashMap<String, Arc<IncrementalScanner<RouterParser>>>>> =
        OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

fn shared_scanner(
    paths: &[PathBuf],
    retention_days: usize,
) -> Arc<IncrementalScanner<RouterParser>> {
    let mut hasher = Sha256::new();
    for path in paths {
        hasher.update(path.display().to_string().as_bytes());
        hasher.update([0]);
    }
    let digest = hasher.finalize();
    let key = format!(
        "codex-router:{}:{}",
        digest
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>(),
        retention_days
    );
    let mut registry = scanner_registry()
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    registry
        .entry(key.clone())
        .or_insert_with(|| {
            let since = Utc::now().timestamp() as f64 - retention_days as f64 * 86_400.0;
            Arc::new(IncrementalScanner::new(
                RouterParser { since },
                key,
                Some(ScanStore::shared()),
            ))
        })
        .clone()
}

/// Release parsed router events retained by shared scanners. Compact checkpoints remain in the
/// scan store; the next ledger pass rehydrates them rather than reparsing the JSONL ledgers.
pub(super) fn unload_shared_caches() {
    let mut registry = scanner_registry()
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    for scanner in registry.values() {
        scanner.clear_memory_cache();
    }
    registry.clear();
}

fn configured_ledger_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if let Some(value) = host::env_var("OPENUSAGE_CODEX_ROUTER_USAGE_EVENTS") {
        paths.extend(
            split_paths(&value)
                .into_iter()
                .map(|p| paths::expand_home(&p)),
        );
    }
    for key in ["CODEX_ROUTER_STATE_DIR", "MODEL_ROUTER_STATE_DIR"] {
        if let Some(value) = host::env_var(key) {
            for state in split_paths(&value) {
                paths.push(paths::expand_home(&state).join("usage-events.jsonl"));
            }
        }
    }
    paths
}

fn configured_pool_paths(home: &Path) -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if let Some(value) = host::env_var("MODEL_ROUTER_CHATGPT_ACCOUNT_POOL") {
        paths.extend(
            split_paths(&value)
                .into_iter()
                .map(|p| paths::expand_home(&p)),
        );
    }
    for key in ["CODEX_ROUTER_STATE_DIR", "MODEL_ROUTER_STATE_DIR"] {
        if let Some(value) = host::env_var(key) {
            for state in split_paths(&value) {
                paths.push(paths::expand_home(&state).join("chatgpt-account-pool.json"));
            }
        }
    }
    paths.push(home.join(".codex/codex-router/chatgpt-account-pool.json"));
    paths
}

fn split_paths(raw: &str) -> Vec<String> {
    raw.split([',', '\n', '\r'])
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .collect()
}

fn load_pool_aliases(paths: &[PathBuf]) -> HashMap<String, String> {
    let mut aliases: HashMap<String, String> = HashMap::new();
    let mut conflicts: HashSet<String> = HashSet::new();
    fn merge(
        aliases: &mut HashMap<String, String>,
        conflicts: &mut HashSet<String>,
        alias: &str,
        account: &str,
    ) {
        let key = alias.to_lowercase();
        if key.is_empty() || conflicts.contains(&key) {
            return;
        }
        match aliases.get(&key) {
            Some(existing) if existing != account => {
                aliases.remove(&key);
                conflicts.insert(key);
            }
            _ => {
                aliases.insert(key, account.to_lowercase());
            }
        }
    }
    for path in paths {
        let Ok(text) = std::fs::read_to_string(path) else {
            continue;
        };
        let Ok(Value::Object(root)) = serde_json::from_str::<Value>(&text) else {
            continue;
        };
        let Some(Value::Object(accounts)) = root.get("accounts") else {
            continue;
        };
        for (pool_id, value) in accounts {
            let Value::Object(account) = value else {
                continue;
            };
            let identity = account.get("identity").and_then(Value::as_object);
            let id = identity
                .and_then(|identity| identity.get("accountId"))
                .or_else(|| account.get("accountId"))
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty());
            let Some(id) = id else { continue };
            merge(&mut aliases, &mut conflicts, pool_id, id);
            if let Some(fingerprint) =
                super::proxy::CodexProxyScanner::account_fingerprint(Some(id))
            {
                merge(&mut aliases, &mut conflicts, &fingerprint, id);
            }
        }
    }
    aliases
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn parse_line(value: Value) -> RouterEvent {
        let line = serde_json::to_vec(&value).unwrap();
        let parser = RouterParser { since: 0.0 };
        let mut out = Vec::new();
        parser.parse(&mut (), &line, &mut out).unwrap();
        out.pop().expect("event")
    }

    #[test]
    fn parses_router_event_fields() {
        let event = parse_line(json!({
            "at": "2026-11-24T10:00:00Z",
            "model": "gpt-6-luna",
            "provider": "openai",
            "status": 200,
            "inputTokens": 100,
            "cachedInputTokens": 20,
            "outputTokens": 30,
            "reasoningTokens": 5,
            "totalTokens": 130,
            "accountFingerprint": "acct_abc"
        }));
        assert_eq!(event.measured_total(), Some(130));
        assert!(event.complete_cost_breakdown());
        assert!(event.is_success());
        assert_eq!(event.account_fingerprint.as_deref(), Some("acct_abc"));
    }

    #[test]
    fn account_attribution_never_crosses_scoped_cards() {
        let unscoped = parse_line(json!({
            "at": "2026-11-24T10:00:00Z", "model": "gpt-6-luna", "status": 200,
            "inputTokens": 1, "outputTokens": 1
        }));
        let scoped = parse_line(json!({
            "at": "2026-11-24T10:00:00Z", "model": "gpt-6-luna", "status": 200,
            "inputTokens": 1, "outputTokens": 1, "accountId": "account-b"
        }));
        assert!(!belongs_to_account(
            &unscoped,
            None,
            None,
            &HashMap::new(),
            false
        ));
        assert!(belongs_to_account(
            &unscoped,
            None,
            None,
            &HashMap::new(),
            true
        ));
        // The default card still owns stamped Codex traffic when it allows unscoped rows.
        assert!(belongs_to_account(
            &scoped,
            None,
            None,
            &HashMap::new(),
            true
        ));
        // A scoped card never absorbs another card's stamped rows, even with unscoped access.
        assert!(!belongs_to_account(
            &scoped,
            None,
            Some("account-a"),
            &HashMap::new(),
            true
        ));
        assert!(belongs_to_account(
            &scoped,
            None,
            Some("account-b"),
            &HashMap::new(),
            false
        ));
    }

    #[test]
    fn only_2xx_events_are_successful() {
        let event = parse_line(json!({
            "at": "2026-11-24T10:00:00Z", "model": "gpt-6-luna", "status": 500,
            "inputTokens": 1, "outputTokens": 1
        }));
        assert!(!event.is_success());
    }

    #[test]
    fn dated_reserve_aliases_price_with_the_release_day_model() {
        assert_eq!(auto_review_fallback("2026-11-24T00:00:00Z"), "gpt-6-luna");
        assert_eq!(auto_review_fallback("2025-01-01T00:00:00Z"), "gpt-5");
        assert_eq!(
            pricing_fallback_model("anthropic/openai/gpt-reserve", 1_800_000_000.0),
            Some("gpt-6-luna".into())
        );
        assert_eq!(pricing_fallback_model("gpt-6-luna", 1_800_000_000.0), None);
    }
}
