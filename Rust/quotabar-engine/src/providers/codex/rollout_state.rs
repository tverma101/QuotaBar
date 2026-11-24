//! Parser state carried from one rollout line to the next (Swift `ParserCheckpoint` and
//! `ChildReplayGate`). It is saved at every checkpoint, so an append resumes exactly where the
//! previous read stopped.

use super::raw_usage::RawUsage;
use crate::scan::{Reader, Record, Writer};
use crate::time::parse_iso8601;
use std::sync::Arc;

/// A child session (subagent or fork) replays its parent's history before its own turns start;
/// replayed `token_count` rows only seed the delta baseline until the gate clears.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum ReplayGate {
    /// Clears at the first `task_started` whose `started_at` is at or after the child's creation
    /// second.
    UntilStartedAt(i64),
    /// The child's `session_meta` carried no usable timestamp: clears at the first `task_started`
    /// whose `started_at` is at or after that line's own wall-clock second.
    UntilSelfTimedTaskStarted,
}

impl ReplayGate {
    pub fn is_cleared(self, started_at: f64, line_timestamp: Option<&str>) -> bool {
        match self {
            ReplayGate::UntilStartedAt(gate) => started_at >= gate as f64,
            ReplayGate::UntilSelfTimedTaskStarted => line_timestamp
                .and_then(|raw| parse_iso8601(super::rollout_parse::trim_whitespace(raw)))
                .is_some_and(|line_date| started_at >= line_date.floor()),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct RolloutState {
    pub(super) previous_totals: Option<RawUsage>,
    pub(super) current_model: Option<Arc<str>>,
    pub(super) current_tier_is_fast: bool,
    pub(super) current_service_tier: Option<Arc<str>>,
    pub(super) current_service_tier_is_valid: bool,
    pub(super) saw_session_meta: bool,
    pub(super) replay_gate: Option<ReplayGate>,
}

impl Default for RolloutState {
    fn default() -> Self {
        RolloutState {
            previous_totals: None,
            current_model: None,
            current_tier_is_fast: false,
            current_service_tier: None,
            current_service_tier_is_valid: true,
            saw_session_meta: false,
            replay_gate: None,
        }
    }
}

impl Record for RolloutState {
    fn encode(&self, w: &mut Writer) {
        match &self.previous_totals {
            None => w.bool(false),
            Some(totals) => {
                w.bool(true);
                totals.encode(w);
            }
        }
        w.opt_str(self.current_model.as_deref());
        w.bool(self.current_tier_is_fast);
        w.opt_str(self.current_service_tier.as_deref());
        w.bool(self.current_service_tier_is_valid);
        w.bool(self.saw_session_meta);
        match self.replay_gate {
            None => w.varint(0),
            Some(ReplayGate::UntilStartedAt(at)) => {
                w.varint(1);
                w.i64(at);
            }
            Some(ReplayGate::UntilSelfTimedTaskStarted) => w.varint(2),
        }
    }

    fn decode(r: &mut Reader<'_>) -> Option<Self> {
        Some(RolloutState {
            previous_totals: if r.bool()? { Some(RawUsage::decode(r)?) } else { None },
            current_model: r.opt_str()?,
            current_tier_is_fast: r.bool()?,
            current_service_tier: r.opt_str()?,
            current_service_tier_is_valid: r.bool()?,
            saw_session_meta: r.bool()?,
            replay_gate: match r.varint()? {
                0 => None,
                1 => Some(ReplayGate::UntilStartedAt(r.i64()?)),
                2 => Some(ReplayGate::UntilSelfTimedTaskStarted),
                _ => return None,
            },
        })
    }
}
