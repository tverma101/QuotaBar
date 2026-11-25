//! The in-memory fold-result cache (Swift `ClaudeUsageFoldCache`).
//!
//! Keeps only a completed result, never the full native transcript. Callers still enumerate sources,
//! check account ownership and run the incremental scan before lookup, so additions, removals,
//! rewrites and read failures take their normal path: the fingerprint covers every in-window file's
//! path and revision plus the window start, pricing token, account scope and time zone. A backwards
//! clock refuses the entry (the caller's future-timestamp check runs on every call regardless).

/// Fingerprint of everything a fold result depends on (see [`crate::scan::fingerprint`]).
pub type FoldKey = [u8; 16];

pub struct FoldCache<T> {
    key: FoldKey,
    observed_at: f64,
    value: T,
}

impl<T: Clone> FoldCache<T> {
    pub fn new(key: FoldKey, observed_at: f64, value: T) -> Self {
        FoldCache { key, observed_at, value }
    }

    pub fn lookup(&self, key: &FoldKey, now: f64) -> Option<T> {
        (self.key == *key && now >= self.observed_at).then(|| self.value.clone())
    }
}
