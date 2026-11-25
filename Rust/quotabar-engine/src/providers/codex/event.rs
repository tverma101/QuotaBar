//! One priced turn parsed from a Codex rollout (Swift `CodexLogUsageScanner.Event`).

use crate::scan::{Reader, Record, Writer};
use std::sync::Arc;

/// A token-count delta for one turn. Counts are `i64` (Swift `Int`); `cached` never exceeds `input`.
#[derive(Clone, Debug, PartialEq)]
pub struct Event {
    /// Seconds since 1970.
    pub timestamp: f64,
    pub model: Arc<str>,
    /// The catalog slug to price with when `model` is a visible-only name (`codex-auto-review`).
    pub pricing_model: Option<Arc<str>>,
    pub input: i64,
    pub cached: i64,
    pub output: i64,
    pub reasoning: i64,
    pub total: i64,
    /// False when the usage breakdown does not add up, or the session's service tier is unknown:
    /// the tokens still count, but a dollar figure computed from them would be partial.
    pub has_complete_cost_breakdown: bool,
    pub is_fast: bool,
    pub service_tier: Option<Arc<str>>,
}

impl Event {
    /// Swift `hasTokenUsage`: the event counts toward usage.
    pub fn has_token_usage(&self) -> bool {
        self.total > 0 || self.input > 0 || self.cached > 0 || self.output > 0 || self.reasoning > 0
    }
}

impl Record for Event {
    fn encode(&self, w: &mut Writer) {
        w.f64(self.timestamp);
        w.str(&self.model);
        w.opt_str(self.pricing_model.as_deref());
        for value in [
            self.input,
            self.cached,
            self.output,
            self.reasoning,
            self.total,
        ] {
            w.i64(value);
        }
        w.bool(self.has_complete_cost_breakdown);
        w.bool(self.is_fast);
        w.opt_str(self.service_tier.as_deref());
    }

    fn decode(r: &mut Reader<'_>) -> Option<Self> {
        Some(Event {
            timestamp: r.f64()?,
            model: r.str()?,
            pricing_model: r.opt_str()?,
            input: r.i64()?,
            cached: r.i64()?,
            output: r.i64()?,
            reasoning: r.i64()?,
            total: r.i64()?,
            has_complete_cost_breakdown: r.bool()?,
            is_fast: r.bool()?,
            service_tier: r.opt_str()?,
        })
    }
}
