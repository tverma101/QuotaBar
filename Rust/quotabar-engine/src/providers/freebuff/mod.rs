//! Freebuff usage (`Providers/Freebuff`): hosted session meter, hosted receipt history, and
//! Freebuff Desktop's local measured token history.

mod auth;
mod client;
mod mapper;
mod scanner;

use self::auth::{AuthError, FreebuffAuth, FreebuffAuthStore};
use self::client::{ClientError, FreebuffClient};
use self::mapper::MappedUsage;
use self::scanner::{FreebuffScan, FreebuffScanner};
use super::{cancelled_snapshot, ProviderRuntime};
use crate::accounting::{append_token_usage, append_usage_trend, TokenUsageOptions};
use crate::context::RefreshContext;
use crate::model::{
    ErrorCategory, MetricLine, ProviderInfo, ProviderSnapshot, ProviderUsageHistory,
};
use crate::pricing::{self, ModelPricing};
use crate::qlog;
use std::collections::BTreeSet;
use std::sync::Arc;

pub const ID: &str = "freebuff";
const HISTORY_SOURCE_NOTE: &str =
    "Measured Freebuff hosted runs and legacy Desktop tokens on this Mac.";
const HOSTED_HISTORY_WARNING: &str =
    "Freebuff's hosted token history couldn't be refreshed. Totals may be incomplete.";
const HISTORY_UNREADABLE_WARNING: &str =
    "QuotaBar couldn't read Freebuff Desktop's measured token history. Refresh again after the current turn finishes.";
const MISSING_RECEIPT_WARNING: &str =
    "Some Freebuff runs have no complete token receipt. Totals include only measured usage.";

pub struct FreebuffProvider {
    info: ProviderInfo,
    store: FreebuffAuthStore,
    client: FreebuffClient,
    scanner: FreebuffScanner,
    pricing_override: Option<Arc<ModelPricing>>,
}

impl FreebuffProvider {
    pub fn live() -> Self {
        FreebuffProvider {
            info: ProviderInfo {
                id: ID.into(),
                display_name: "Freebuff".into(),
            },
            store: FreebuffAuthStore::live(),
            client: FreebuffClient::live(),
            scanner: FreebuffScanner::live(),
            pricing_override: None,
        }
    }

    pub fn with_parts(
        store: FreebuffAuthStore,
        client: FreebuffClient,
        scanner: FreebuffScanner,
    ) -> Self {
        FreebuffProvider {
            info: ProviderInfo {
                id: ID.into(),
                display_name: "Freebuff".into(),
            },
            store,
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

    fn refresh_quota(&self, auth: &FreebuffAuth, ctx: &RefreshContext) -> ProviderSnapshot {
        let response = match self.client.fetch_session(auth, &ctx.cancel) {
            Ok(response) => response,
            Err(ClientError::ConnectionFailed) => {
                return ProviderSnapshot::error(
                    &self.info,
                    client::map_error(ClientError::ConnectionFailed),
                    ErrorCategory::Network,
                    ctx.now,
                )
            }
            Err(error) => {
                return ProviderSnapshot::error(
                    &self.info,
                    client::map_error(error),
                    ErrorCategory::Network,
                    ctx.now,
                )
            }
        };
        if ctx.is_cancelled() {
            return cancelled_snapshot(&self.info, ctx);
        }
        if response.status == 401 {
            return ProviderSnapshot::error(
                &self.info,
                AuthError::TokenInvalid.message(),
                ErrorCategory::AuthExpired,
                ctx.now,
            );
        }
        if !response.is_success() && response.status != 404 {
            return ProviderSnapshot::error(
                &self.info,
                &format!("Freebuff usage request failed (HTTP {}).", response.status),
                ErrorCategory::http(response.status),
                ctx.now,
            );
        }
        let mapped = match mapper::map(&response.body, response.status) {
            Ok(mapped) => mapped,
            Err(_) => {
                return ProviderSnapshot::error(
                    &self.info,
                    "Freebuff returned unreadable usage data. Try again later.",
                    ErrorCategory::Decoding,
                    ctx.now,
                )
            }
        };
        snapshot_from_mapped(&self.info, mapped, ctx.now)
    }
}

fn snapshot_from_mapped(info: &ProviderInfo, mapped: MappedUsage, now: f64) -> ProviderSnapshot {
    let mut snapshot = ProviderSnapshot::new(info, mapped.plan, mapped.lines, now);
    snapshot.warning = mapped.warning;
    snapshot.clears_prior_menu_bar_quota_state = Some(true);
    snapshot.active_sessions =
        (!mapped.active_sessions.is_empty()).then_some(mapped.active_sessions);
    snapshot
}

fn append_history(result: &mut ProviderSnapshot, scan: &FreebuffScan, now: f64) {
    let usage = &scan.usage;
    let options = TokenUsageOptions {
        estimated: true,
        unknown_models_by_day: usage.unknown_models_by_day.clone(),
        model_usage: usage.model_usage.clone(),
        model_source_note: Some(HISTORY_SOURCE_NOTE.into()),
        partial_days: scan.partial_days.clone(),
        api_estimate_by_day: usage.api_estimate_by_day.clone(),
        estimated_cost_days: usage.estimated_cost_days.clone(),
    };
    append_token_usage(&usage.series, &mut result.lines, now, &options);
    append_usage_trend(
        &usage.series,
        &mut result.lines,
        now,
        HISTORY_SOURCE_NOTE,
        &scan.partial_days,
        Some("incomplete Freebuff history is shown as a lower bound"),
    );
    result.usage_history = Some(ProviderUsageHistory {
        series: usage.series.clone(),
        model_usage: usage.model_usage.clone(),
        unknown_models_by_day: usage.unknown_models_by_day.clone(),
        api_estimate_by_day: usage.api_estimate_by_day.clone(),
        api_estimate_incomplete_days: usage.api_estimate_incomplete_days.clone(),
        partial_days: Some(scan.partial_days.clone()),
        estimated_cost_days: usage.estimated_cost_days.clone(),
    });
    result.history_refreshed_at = Some(now);
}

impl ProviderRuntime for FreebuffProvider {
    fn info(&self) -> &ProviderInfo {
        &self.info
    }

    fn has_local_credentials(&self) -> bool {
        self.store.has_local_credentials() || self.scanner.has_history()
    }

    fn unload_caches(&self) {
        self.scanner.unload_caches();
    }

    fn refresh(&self, ctx: &RefreshContext) -> ProviderSnapshot {
        if ctx.is_cancelled() {
            return cancelled_snapshot(&self.info, ctx);
        }
        let scope = ctx.scope;
        let auth = match self.store.load_auth(ctx.is_manual, ctx.request_id) {
            Ok(auth) => auth,
            Err(AuthError::CredentialsUnreadable) => {
                return ProviderSnapshot::error(
                    &self.info,
                    AuthError::CredentialsUnreadable.message(),
                    ErrorCategory::CredentialAccess,
                    ctx.now,
                )
            }
            Err(error) => {
                return ProviderSnapshot::error(
                    &self.info,
                    error.message(),
                    auth_category(&error),
                    ctx.now,
                )
            }
        };
        let mut snapshot = if scope.suppresses_live_quota() {
            ProviderSnapshot::new(&self.info, None, Vec::new(), ctx.now)
        } else if let Some(auth) = &auth {
            self.refresh_quota(auth, ctx)
        } else {
            ProviderSnapshot::error(
                &self.info,
                AuthError::NotLoggedIn.message(),
                ErrorCategory::NotLoggedIn,
                ctx.now,
            )
        };
        if scope.skips_local_accounting() || ctx.is_cancelled() {
            return snapshot;
        }
        let scan_now = ctx.now;
        let mut incomplete_history = auth.is_none();
        if auth.is_none() {
            snapshot.history_warning = Some(AuthError::NotLoggedIn.message().to_string());
        }
        let pricing = self.pricing(ctx);
        let hosted = if let Some(auth) = &auth {
            if scope == crate::context::Scope::LocalAccounting {
                self.scanner.cached_receipts(auth)
            } else {
                match self.scanner.hosted_receipts(
                    auth,
                    &self.client,
                    scan_now,
                    ctx.is_manual,
                    &ctx.cancel,
                ) {
                    Ok(receipts) => receipts,
                    Err(ClientError::TokenInvalid) => {
                        let mut result = snapshot;
                        result.lines = vec![MetricLine::badge(
                            MetricLine::ERROR_BADGE_LABEL,
                            AuthError::TokenInvalid.message(),
                            Some("#EF4444"),
                        )];
                        result.error_category = Some(ErrorCategory::AuthExpired);
                        return result;
                    }
                    Err(error) => {
                        scanner::warn(&error);
                        incomplete_history = true;
                        snapshot.history_warning = Some(HOSTED_HISTORY_WARNING.into());
                        self.scanner.cached_receipts(auth)
                    }
                }
            }
        } else {
            Vec::new()
        };
        let has_history = !hosted.is_empty()
            || (scope != crate::context::Scope::LocalAccounting && self.scanner.has_history());
        let scan = if has_history {
            self.scanner.scan(scan_now, &pricing, &hosted, &ctx.cancel)
        } else {
            None
        };
        if ctx.is_cancelled() {
            return cancelled_snapshot(&self.info, ctx);
        }
        let Some(mut scan) = scan else {
            if snapshot.error_category.is_none() && !has_history {
                return snapshot;
            }
            if snapshot.history_warning.is_none() {
                snapshot.history_warning = Some(HISTORY_UNREADABLE_WARNING.into());
            }
            return snapshot;
        };
        if incomplete_history {
            let days = scan
                .usage
                .series
                .daily
                .iter()
                .map(|entry| entry.date.clone())
                .collect::<BTreeSet<_>>();
            scan.partial_days.extend(days);
            scan.usage = scan.usage.marking_unmeasured_usage(&scan.partial_days);
        }
        let now = scan_now;
        let first_day = crate::accounting::DayZone::Local.day_key(now - 29.0 * 86_400.0);
        let today = crate::accounting::DayZone::Local.day_key(now);
        if scan
            .partial_days
            .iter()
            .any(|day| *day >= first_day && *day <= today)
        {
            qlog!(
                Warn,
                crate::host::auth_tag(ID),
                "token history contains incomplete or missing usage receipts"
            );
            if snapshot.history_warning.is_none() {
                snapshot.history_warning = Some(MISSING_RECEIPT_WARNING.into());
            }
        }
        append_history(&mut snapshot, &scan, now);
        snapshot
    }
}

fn auth_category(error: &AuthError) -> ErrorCategory {
    match error {
        AuthError::NotLoggedIn => ErrorCategory::NotLoggedIn,
        AuthError::CredentialPermissionRequired => ErrorCategory::CredentialAccess,
        AuthError::TokenInvalid => ErrorCategory::AuthExpired,
        AuthError::CredentialsUnreadable => ErrorCategory::CredentialAccess,
        AuthError::InvalidConfigDirectory
        | AuthError::InvalidCredentials
        | AuthError::MissingDefaultProfile => ErrorCategory::AuthInvalid,
    }
}

#[cfg(test)]
mod tests;
