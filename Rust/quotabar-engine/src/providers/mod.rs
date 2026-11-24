//! Provider runtimes (Swift `ProviderRuntime`): an auth store reads credentials already on the
//! machine, a usage client calls the provider's API, a mapper normalizes into `MetricLine`s.

use crate::context::RefreshContext;
use crate::model::{ErrorCategory, ProviderInfo, ProviderSnapshot};
use std::sync::Arc;

pub mod claude;
pub mod codex;
pub mod devin;

pub trait ProviderRuntime: Send + Sync {
    fn info(&self) -> &ProviderInfo;

    /// Silent, local-only setup probe (no network, no prompts, never changes enablement). Mirrors
    /// the credential sources and usability filters `refresh` starts with.
    fn has_local_credentials(&self) -> bool;

    fn refresh(&self, ctx: &RefreshContext) -> ProviderSnapshot;
}

/// Swift `cancelledRefreshSnapshot(provider:)`.
pub fn cancelled_snapshot(info: &ProviderInfo, ctx: &RefreshContext) -> ProviderSnapshot {
    ProviderSnapshot::error(info, "Refresh cancelled.", ErrorCategory::Cancelled, ctx.now)
}

/// Every provider the engine implements, in no particular order (the host owns display order).
pub fn all() -> Vec<Arc<dyn ProviderRuntime>> {
    vec![Arc::new(devin::DevinProvider::live())]
}
