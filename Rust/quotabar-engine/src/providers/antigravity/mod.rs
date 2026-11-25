//! Antigravity quota and local conversation accounting (`Providers/Antigravity`).
//!
//! Native source only: quota comes from the running Antigravity app's own language server (the
//! exact bundle executable), then from the app's saved Keychain sign-in through Google Cloud Code
//! while the app is closed. `agy`, T3 Code, and other clients' credentials are never read. Each
//! source prefers `RetrieveUserQuotaSummary` (merged pools + weekly windows).

mod auth;
mod client;
mod cloud_code;
mod discovery;
mod mapper;
mod proto;
mod scanner;

use self::auth::AntigravityAuth;
use self::client::AntigravityClient;
use self::cloud_code::ProbeError;
use self::discovery::{Discovered, Options};
use self::mapper::QuotaSummary;
use self::scanner::{AntigravityScanResult, AntigravityScanner};
use super::{cancelled_snapshot, ProviderRuntime};
use crate::accounting::{
    append_token_usage, append_usage_trend, DayZone, TokenUsageOptions, UsageHistoryWindow,
};
use crate::context::RefreshContext;
use crate::host;
use crate::model::{
    ErrorCategory, MetricLine, ProviderInfo, ProviderSnapshot, ProviderUsageHistory,
};
use crate::pricing::{self, ModelPricing};
use crate::qlog;
use std::sync::Arc;

pub const ID: &str = "antigravity";
const USAGE_SOURCE_NOTE: &str = "From your Antigravity conversations";
const SUMMARY_INCOMPLETE_WARNING: &str =
    "Some Antigravity quota limits could not be read. Missing limits may retain older values.";
const SUMMARY_UNREADABLE_WARNING: &str =
    "Antigravity quota summary could not be read. Existing limits are retained.";
const HISTORY_UNREADABLE_WARNING: &str =
    "Antigravity conversation history could not be updated. Any displayed totals are last known and may be stale.";
const HISTORY_PARTIAL_WARNING: &str =
    "Some Antigravity history could not be dated or counted. Visible totals are lower bounds.";
const HISTORY_FAILED_WARNING: &str =
    "Some Antigravity conversation stores could not be read. Visible totals are lower bounds.";
const HISTORY_PARTIAL_FAILED_WARNING: &str = "Some Antigravity conversation stores could not be read, and some history could not be dated or counted. Visible totals are lower bounds.";

struct StrategyResult {
    plan: Option<String>,
    lines: Vec<MetricLine>,
    replaces_prior_quota_progress: bool,
    warning: Option<String>,
}

impl StrategyResult {
    fn empty() -> Self {
        StrategyResult {
            plan: None,
            lines: Vec::new(),
            replaces_prior_quota_progress: false,
            warning: None,
        }
    }
}

#[derive(Clone)]
struct HistoryResult {
    history: Option<ProviderUsageHistory>,
    lines: Vec<MetricLine>,
    warning: Option<String>,
}

pub struct AntigravityProvider {
    info: ProviderInfo,
    auth: AntigravityAuth,
    client: AntigravityClient,
    scanner: AntigravityScanner,
    pricing_override: Option<Arc<ModelPricing>>,
}

impl AntigravityProvider {
    pub fn live() -> Self {
        AntigravityProvider {
            info: ProviderInfo {
                id: ID.into(),
                display_name: "Antigravity".into(),
            },
            auth: AntigravityAuth::live(),
            client: AntigravityClient::live(),
            scanner: AntigravityScanner::live(),
            pricing_override: None,
        }
    }

    pub fn with_parts(
        auth: AntigravityAuth,
        client: AntigravityClient,
        scanner: AntigravityScanner,
    ) -> Self {
        AntigravityProvider {
            info: ProviderInfo {
                id: ID.into(),
                display_name: "Antigravity".into(),
            },
            auth,
            client,
            scanner,
            pricing_override: None,
        }
    }

    pub fn with_pricing_override(mut self, pricing: Arc<ModelPricing>) -> Self {
        self.pricing_override = Some(pricing);
        self
    }

    fn pricing(&self, ctx: &RefreshContext) -> Arc<ModelPricing> {
        self.pricing_override.clone().unwrap_or_else(|| {
            pricing::shared()
                .current(ctx.skip_model_catalog_refresh || ctx.scope.suppresses_live_quota())
        })
    }

    fn probe(&self, ctx: &RefreshContext) -> Result<StrategyResult, ProbeError> {
        if ctx.is_cancelled() {
            return Err(("Refresh cancelled.".into(), ErrorCategory::Cancelled));
        }
        // A discovered native server that answers — even with a warning or an empty summary — is
        // authoritative; dropping it for a credential read would risk an unwanted Keychain prompt.
        // Only a transport-level no-result falls through to the saved sign-in.
        if let Some(snapshot) = discovery::process_snapshot() {
            let options = discovery::native_server_options(&crate::paths::home());
            if let Some(result) = self.probe_ls(&options, &snapshot, ctx)? {
                qlog!(
                    Debug,
                    host::plugin_tag(ID),
                    "quota source: native Antigravity app"
                );
                return Ok(result);
            }
        }
        let result = self.probe_cloud_code(ctx)?;
        qlog!(
            Debug,
            host::plugin_tag(ID),
            "quota source: Antigravity saved sign-in"
        );
        Ok(result)
    }

    fn probe_ls(
        &self,
        options: &Options,
        snapshot: &str,
        ctx: &RefreshContext,
    ) -> Result<Option<StrategyResult>, ProbeError> {
        let Some(discovered) = discovery::discover(options, snapshot) else {
            return Ok(None);
        };
        for endpoint in endpoints(&discovered) {
            if ctx.is_cancelled() {
                return Err(("Refresh cancelled.".into(), ErrorCategory::Cancelled));
            }
            if let Some(summary) = self.client.call_ls(
                &endpoint.0,
                endpoint.1,
                &discovered.csrf,
                "RetrieveUserQuotaSummary",
                &ctx.cancel,
            ) {
                if summary.is_success() {
                    if let Some(parsed) = mapper::parse_quota_summary(&summary.body) {
                        let plan = self
                            .client
                            .call_ls(
                                &endpoint.0,
                                endpoint.1,
                                &discovered.csrf,
                                "GetUserStatus",
                                &ctx.cancel,
                            )
                            .filter(|status| status.is_success())
                            .and_then(|status| mapper::parse_user_status(&status.body))
                            .and_then(|status| status.plan);
                        return Ok(Some(strategy_from_summary(parsed, plan)));
                    }
                    return Ok(Some(StrategyResult {
                        plan: None,
                        lines: Vec::new(),
                        replaces_prior_quota_progress: false,
                        warning: Some(SUMMARY_UNREADABLE_WARNING.into()),
                    }));
                }
                if summary.status != 404 {
                    qlog!(
                        Warn,
                        host::plugin_tag(ID),
                        "RetrieveUserQuotaSummary HTTP {}; falling back to legacy quota endpoints",
                        summary.status
                    );
                }
            }
            let Some(status) = self
                .client
                .call_ls(
                    &endpoint.0,
                    endpoint.1,
                    &discovered.csrf,
                    "GetUserStatus",
                    &ctx.cancel,
                )
                .filter(|status| status.is_success())
            else {
                continue;
            };
            if let Some(parsed) = mapper::parse_user_status(&status.body) {
                let lines = mapper::build_lines(&parsed.configs);
                if !lines.is_empty() {
                    return Ok(Some(StrategyResult {
                        plan: parsed.plan,
                        lines,
                        replaces_prior_quota_progress: true,
                        warning: None,
                    }));
                }
            }
            if let Some(fallback) = self
                .client
                .call_ls(
                    &endpoint.0,
                    endpoint.1,
                    &discovered.csrf,
                    "GetCommandModelConfigs",
                    &ctx.cancel,
                )
                .filter(|fallback| fallback.is_success())
            {
                if let Some(configs) = mapper::parse_command_model_configs(&fallback.body) {
                    let lines = mapper::build_lines(&configs);
                    if !lines.is_empty() {
                        return Ok(Some(StrategyResult {
                            plan: None,
                            lines,
                            replaces_prior_quota_progress: true,
                            warning: None,
                        }));
                    }
                }
            }
        }
        Ok(None)
    }

    fn scan_history(&self, ctx: &RefreshContext, pricing: &ModelPricing) -> Option<HistoryResult> {
        if ctx.is_cancelled() {
            return None;
        }
        let days = UsageHistoryWindow::lifetime_days(ctx.now, DayZone::Local);
        let AntigravityScanResult {
            scan,
            has_read_failures,
        } = self.scanner.scan(days, ctx.now, pricing, &ctx.cancel);
        if ctx.is_cancelled() {
            return None;
        }
        let Some(scan) = scan else {
            return has_read_failures.then(|| HistoryResult {
                history: None,
                lines: Vec::new(),
                warning: Some(HISTORY_UNREADABLE_WARNING.into()),
            });
        };
        let partial_days = scan.unmeasured_usage_days.clone().unwrap_or_default();
        let has_only_unmeasured = scan.series.daily.is_empty() && !partial_days.is_empty();
        let history = (!has_only_unmeasured).then(|| ProviderUsageHistory {
            series: scan.series.clone(),
            model_usage: scan.model_usage.clone(),
            unknown_models_by_day: scan.unknown_models_by_day.clone(),
            api_estimate_by_day: scan.api_estimate_by_day.clone(),
            api_estimate_incomplete_days: scan.api_estimate_incomplete_days.clone(),
            partial_days: scan.unmeasured_usage_days.clone(),
            estimated_cost_days: scan.estimated_cost_days.clone(),
        });
        let mut lines = Vec::new();
        if !has_only_unmeasured {
            let options = TokenUsageOptions {
                estimated: false,
                unknown_models_by_day: scan.unknown_models_by_day.clone(),
                model_usage: scan.model_usage.clone(),
                model_source_note: Some(USAGE_SOURCE_NOTE.into()),
                partial_days: partial_days.clone(),
                api_estimate_by_day: scan.api_estimate_by_day.clone(),
                estimated_cost_days: scan.estimated_cost_days.clone(),
            };
            append_token_usage(&scan.series, &mut lines, ctx.now, &options);
            append_usage_trend(
                &scan.series,
                &mut lines,
                ctx.now,
                USAGE_SOURCE_NOTE,
                &partial_days,
                Some("incomplete Antigravity history is shown as a lower bound"),
            );
        }
        let warning = if partial_days.is_empty() {
            has_read_failures.then(|| HISTORY_FAILED_WARNING.to_string())
        } else if has_read_failures {
            Some(HISTORY_PARTIAL_FAILED_WARNING.to_string())
        } else {
            Some(HISTORY_PARTIAL_WARNING.to_string())
        };
        Some(HistoryResult {
            history,
            lines,
            warning,
        })
    }
}

fn endpoints(discovered: &Discovered) -> Vec<(String, u16)> {
    let mut endpoints = Vec::new();
    for port in &discovered.ports {
        endpoints.push(("https".to_string(), *port));
        endpoints.push(("http".to_string(), *port));
    }
    if let Some(port) = discovered.extension_port {
        endpoints.push(("http".to_string(), port));
    }
    endpoints
}

fn strategy_from_summary(summary: QuotaSummary, plan: Option<String>) -> StrategyResult {
    StrategyResult {
        plan,
        lines: summary.lines,
        replaces_prior_quota_progress: summary.is_complete,
        warning: (!summary.is_complete).then(|| SUMMARY_INCOMPLETE_WARNING.to_string()),
    }
}

impl ProviderRuntime for AntigravityProvider {
    fn info(&self) -> &ProviderInfo {
        &self.info
    }

    /// Silent, local-only: the native app's language server in the process table, or the app's
    /// saved Keychain sign-in readable without a prompt. Never T3, `agy`, or other clients.
    fn has_local_credentials(&self) -> bool {
        if let Some(snapshot) = discovery::process_snapshot() {
            let options = discovery::native_server_options(&crate::paths::home());
            if discovery::discover(&options, &snapshot).is_some() {
                return true;
            }
        }
        self.auth.cache_identity_key_for_launch() != auth::UNRESOLVED_CACHE_IDENTITY
    }

    fn unload_caches(&self) {
        AntigravityScanner::unload_caches();
    }

    fn refresh(&self, ctx: &RefreshContext) -> ProviderSnapshot {
        if ctx.is_cancelled() {
            return cancelled_snapshot(&self.info, ctx);
        }
        let may_replace = ctx.scope.refreshes_quota_domain();
        let history = if ctx.scope.skips_local_accounting() {
            None
        } else {
            let pricing = self.pricing(ctx);
            self.scan_history(ctx, &pricing)
        };
        let quota = if ctx.scope.suppresses_live_quota() {
            Ok(StrategyResult::empty())
        } else {
            self.probe(ctx)
        };
        if ctx.is_cancelled() {
            return cancelled_snapshot(&self.info, ctx);
        }
        match quota {
            Ok(result) => {
                if ctx.scope.skips_local_accounting() {
                    let mut snapshot =
                        ProviderSnapshot::new(&self.info, result.plan, result.lines, ctx.now);
                    snapshot.warning = result.warning;
                    snapshot.replaces_prior_quota_progress =
                        may_replace.then_some(result.replaces_prior_quota_progress);
                    return snapshot;
                }
                let mut lines = result.lines;
                if let Some(history) = &history {
                    lines.extend(history.lines.iter().cloned());
                }
                let mut snapshot = ProviderSnapshot::new(&self.info, result.plan, lines, ctx.now);
                snapshot.usage_history =
                    history.as_ref().and_then(|history| history.history.clone());
                snapshot.history_refreshed_at = snapshot.usage_history.as_ref().map(|_| ctx.now);
                snapshot.warning = result.warning;
                snapshot.history_warning =
                    history.as_ref().and_then(|history| history.warning.clone());
                snapshot.replaces_prior_quota_progress =
                    may_replace.then_some(result.replaces_prior_quota_progress);
                snapshot
            }
            Err((message, category)) => {
                let mut snapshot = ProviderSnapshot::error(&self.info, &message, category, ctx.now);
                if let Some(history) = history {
                    snapshot.usage_history = history.history;
                    snapshot.history_refreshed_at =
                        snapshot.usage_history.as_ref().map(|_| ctx.now);
                    snapshot.history_warning = history.warning;
                }
                snapshot
            }
        }
    }
}

#[cfg(test)]
mod tests;
