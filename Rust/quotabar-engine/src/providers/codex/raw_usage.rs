//! Token fields of a `token_count` usage object (Swift `CodexLogUsageScanner.RawUsage`), tolerating
//! the older field spellings ccusage accepts (`prompt_tokens`, `completion_tokens`, ...).

use crate::scan::{Reader, Record, Writer};
use serde_json::{Map, Value};

/// Swift `ProviderParse.addingSaturating`: overflow in either direction yields `Int.max`.
pub(super) fn saturating_add(a: i64, b: i64) -> i64 {
    a.checked_add(b).unwrap_or(i64::MAX)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct RawUsage {
    pub input: i64,
    pub cached: i64,
    pub output: i64,
    pub reasoning: i64,
    pub total: i64,
    /// `total` is component-derived when absent or zero; only a positive reported value is a
    /// cumulative total counter that can authoritatively produce a later delta.
    pub has_reported_total: bool,
    pub has_complete_cost_breakdown: bool,
    pub is_valid: bool,
}

/// What one counter lookup found: its value, whether any alias key was present, and whether the
/// present value is a valid count.
struct Field {
    value: Option<i64>,
    is_present: bool,
    is_valid: bool,
}

/// The first present alias wins: a JSON number (never a bool or null), finite, integral, in
/// `[0, 1e15]`; anything else present is an invalid field.
fn field(json: &Map<String, Value>, keys: &[&str]) -> Field {
    for key in keys {
        let Some(raw) = json.get(*key) else { continue };
        return match raw.as_f64() {
            Some(v) if v.is_finite() && (0.0..=1e15).contains(&v) && v.fract() == 0.0 => Field {
                value: Some(v as i64),
                is_present: true,
                is_valid: true,
            },
            _ => Field {
                value: None,
                is_present: true,
                is_valid: false,
            },
        };
    }
    Field {
        value: None,
        is_present: false,
        is_valid: true,
    }
}

impl RawUsage {
    pub fn from_json(json: &Map<String, Value>) -> RawUsage {
        let parsed_input = field(json, &["input_tokens", "prompt_tokens", "input"]);
        let parsed_cached = field(
            json,
            &[
                "cached_input_tokens",
                "cache_read_input_tokens",
                "cached_tokens",
            ],
        );
        let parsed_output = field(json, &["output_tokens", "completion_tokens", "output"]);
        let parsed_reasoning = field(json, &["reasoning_output_tokens", "reasoning_tokens"]);
        let parsed_total = field(json, &["total_tokens"]);
        let input = parsed_input.value.unwrap_or(0);
        // Cached input is a subset of reported input. Some Codex snapshots briefly disagree while
        // counters settle; count no more cached tokens than the measured input bucket.
        let cached = parsed_cached.value.unwrap_or(0).min(input);
        let output = parsed_output.value.unwrap_or(0);
        let reasoning = parsed_reasoning.value.unwrap_or(0);
        let reported = parsed_total.value.unwrap_or(0);
        // Reasoning tokens are a subset of output on OpenAI/Codex usage; do not add them again.
        let recomputed = saturating_add(input, output);
        let has_reported_total = reported > 0;
        let has_authoritative_total =
            has_reported_total || (parsed_input.is_present && parsed_output.is_present);
        RawUsage {
            input,
            cached,
            output,
            reasoning,
            total: if has_reported_total {
                reported
            } else {
                recomputed
            },
            has_reported_total,
            is_valid: parsed_input.is_valid
                && parsed_cached.is_valid
                && parsed_output.is_valid
                && parsed_reasoning.is_valid
                && parsed_total.is_valid
                && has_authoritative_total,
            has_complete_cost_breakdown: parsed_input.is_present
                && parsed_output.is_present
                && cached <= input
                && reasoning <= output
                // A present zero total is still a report. If it contradicts positive components,
                // keep the component-derived token count but never present its partial price as whole.
                && (!parsed_total.is_present || reported == recomputed),
        }
    }

    /// Swift `subtracting`: the per-turn delta of a cumulative counter. Components reset
    /// independently, so a counter that went backwards counts as a fresh start.
    pub fn subtracting(&self, previous: Option<&RawUsage>) -> RawUsage {
        let Some(previous) = previous else {
            return *self;
        };
        let delta = |now: i64, before: i64| if now >= before { now - before } else { now };
        let input = delta(self.input, previous.input);
        let cached = delta(self.cached, previous.cached);
        let output = delta(self.output, previous.output);
        let reasoning = delta(self.reasoning, previous.reasoning);
        let component_total = saturating_add(input, output);
        // A reported total stays authoritative against a prior reported total or a baseline
        // accumulated from last-only events; a mismatch with the component deltas only makes the
        // cost incomplete.
        let total = if self.has_reported_total {
            delta(self.total, previous.total)
        } else {
            component_total
        };
        RawUsage {
            input,
            cached,
            output,
            reasoning,
            total,
            has_reported_total: false,
            is_valid: self.is_valid && previous.is_valid,
            has_complete_cost_breakdown: self.has_complete_cost_breakdown
                && previous.has_complete_cost_breakdown
                && cached <= input
                && reasoning <= output
                && total == component_total,
        }
    }

    /// Swift `addingAsBaseline`: extend a last-only running baseline by one more turn.
    pub fn adding_as_baseline(&self, delta: &RawUsage) -> RawUsage {
        RawUsage {
            input: saturating_add(self.input, delta.input),
            cached: saturating_add(self.cached, delta.cached),
            output: saturating_add(self.output, delta.output),
            reasoning: saturating_add(self.reasoning, delta.reasoning),
            total: saturating_add(self.total, delta.total),
            has_reported_total: false,
            is_valid: self.is_valid && delta.is_valid,
            has_complete_cost_breakdown: self.has_complete_cost_breakdown
                && delta.has_complete_cost_breakdown,
        }
    }

    pub fn as_baseline(&self) -> RawUsage {
        RawUsage {
            has_reported_total: false,
            ..*self
        }
    }
}

impl Record for RawUsage {
    fn encode(&self, w: &mut Writer) {
        for value in [
            self.input,
            self.cached,
            self.output,
            self.reasoning,
            self.total,
        ] {
            w.i64(value);
        }
        w.bool(self.has_reported_total);
        w.bool(self.has_complete_cost_breakdown);
        w.bool(self.is_valid);
    }

    fn decode(r: &mut Reader<'_>) -> Option<Self> {
        Some(RawUsage {
            input: r.i64()?,
            cached: r.i64()?,
            output: r.i64()?,
            reasoning: r.i64()?,
            total: r.i64()?,
            has_reported_total: r.bool()?,
            has_complete_cost_breakdown: r.bool()?,
            is_valid: r.bool()?,
        })
    }
}
