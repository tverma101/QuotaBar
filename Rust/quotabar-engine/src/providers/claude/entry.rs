//! One parsed Claude usage line (Swift `ClaudeLogUsageScanner.Entry`).

use crate::pricing::TokenBreakdown;
use crate::scan::{Reader, Record, Writer};
use std::sync::Arc;

/// Token buckets are pre-normalized into [`TokenBreakdown`]; the dedup fields ride along so the
/// global dedup pass can run over cached entries. Timestamps stay raw (seconds since 1970): the date
/// window is applied at aggregation so a cached parse stays valid as the window slides.
#[derive(Clone, Debug, PartialEq)]
pub struct ClaudeEntry {
    pub timestamp: f64,
    pub tokens: TokenBreakdown,
    pub message_id: Option<Arc<str>>,
    pub request_id: Option<Arc<str>>,
    pub is_sidechain: bool,
    /// The line carried a `speed` field at all (dedup tiebreaker); `tokens.is_fast` says it was "fast".
    pub has_speed: bool,
    pub cost_usd: Option<f64>,
    /// `None` when the line has no model or the placeholder `<synthetic>` (tokens count, cost is $0).
    pub model: Option<Arc<str>>,
}

impl ClaudeEntry {
    /// Swift `contributesUsage`: a row with neither tokens nor a carried cost never reaches dedup.
    pub fn contributes_usage(&self) -> bool {
        self.tokens.total_tokens() > 0 || self.cost_usd.unwrap_or(0.0) > 0.0
    }
}

impl Record for ClaudeEntry {
    fn encode(&self, w: &mut Writer) {
        w.f64(self.timestamp);
        let t = &self.tokens;
        for value in [t.input, t.cache_write_5m, t.cache_write_1h, t.cache_read, t.output] {
            w.i64(value);
        }
        w.bool(t.is_fast);
        w.opt_str(self.message_id.as_deref());
        w.opt_str(self.request_id.as_deref());
        w.bool(self.is_sidechain);
        w.bool(self.has_speed);
        w.opt_f64(self.cost_usd);
        w.opt_str(self.model.as_deref());
    }

    fn decode(r: &mut Reader<'_>) -> Option<Self> {
        let timestamp = r.f64()?;
        let tokens = TokenBreakdown {
            input: r.i64()?,
            cache_write_5m: r.i64()?,
            cache_write_1h: r.i64()?,
            cache_read: r.i64()?,
            output: r.i64()?,
            is_fast: r.bool()?,
        };
        Some(ClaudeEntry {
            timestamp,
            tokens,
            message_id: r.opt_str()?,
            request_id: r.opt_str()?,
            is_sidechain: r.bool()?,
            has_speed: r.bool()?,
            cost_usd: r.opt_f64()?,
            model: r.opt_str()?,
        })
    }
}
