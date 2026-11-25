//! Provider runtimes (Swift `ProviderRuntime`): an auth store reads credentials already on the
//! machine, a usage client calls the provider's API, a mapper normalizes into `MetricLine`s.

use crate::context::RefreshContext;
use crate::model::{ErrorCategory, ProviderInfo, ProviderSnapshot};
use std::sync::Arc;

pub mod antigravity;
pub mod api_key;
pub mod auth_retry;
pub mod claude;
pub mod codex;
pub mod copilot;
pub mod cursor;
pub mod devin;
pub mod error_text;
pub mod freebuff;
pub mod grok;
pub mod hermes;
pub mod muse;
pub mod opencode;
pub mod openrouter;
pub mod pi;
pub mod private_file;
pub mod zai;

pub trait ProviderRuntime: Send + Sync {
    fn info(&self) -> &ProviderInfo;

    /// Silent, local-only setup probe (no network, no prompts, never changes enablement). Mirrors
    /// the credential sources and usability filters `refresh` starts with.
    fn has_local_credentials(&self) -> bool;

    /// Configuration-aware variant of `has_local_credentials` (e.g. account-scoped paths).
    fn has_local_credentials_with_config(&self, _config: Option<&serde_json::Value>) -> bool {
        self.has_local_credentials()
    }

    fn refresh(&self, ctx: &RefreshContext) -> ProviderSnapshot;

    /// Release any recomputable in-memory provider caches when the OS reports memory pressure.
    fn unload_caches(&self) {}
}

/// Swift `cancelledRefreshSnapshot(provider:)`.
pub fn cancelled_snapshot(info: &ProviderInfo, ctx: &RefreshContext) -> ProviderSnapshot {
    ProviderSnapshot::error(
        info,
        "Refresh cancelled.",
        ErrorCategory::Cancelled,
        ctx.now,
    )
}

/// Every provider the engine implements, in no particular order (the host owns display order).
pub fn all() -> Vec<Arc<dyn ProviderRuntime>> {
    vec![
        Arc::new(antigravity::AntigravityProvider::live()),
        Arc::new(claude::ClaudeProvider::live()),
        Arc::new(codex::CodexProvider::live()),
        Arc::new(copilot::CopilotProvider::live()),
        Arc::new(cursor::CursorProvider::live()),
        Arc::new(devin::DevinProvider::live()),
        Arc::new(freebuff::FreebuffProvider::live()),
        Arc::new(grok::GrokProvider::live()),
        Arc::new(hermes::HermesProvider::live()),
        Arc::new(opencode::OpenCodeProvider::live()),
        Arc::new(openrouter::OpenRouterProvider::live()),
        Arc::new(zai::ZAIProvider::live()),
    ]
}
