//! Devin quota (daily/weekly percent + extra balance) and local CLI session/transcript spend.

pub mod auth;
pub mod client;
pub mod mapper;
pub mod sessions;
mod sessions_cache;
pub mod transcripts;

#[cfg(test)]
mod tests;
#[cfg(test)]
mod local_tests;

pub use auth::{
    clean_api_server_url, read_toml_string, CredentialsUnreadable, DevinAuth, DevinAuthStore,
    DEFAULT_API_SERVER_URL, ID,
};
pub use client::{CLOUD_COMPAT_VERSION, CLOUD_SERVICE, QUOTA_UNAVAILABLE};
pub use mapper::{
    map_user_status, map_user_status_response, MappedUsage, UsageError, MAXIMUM_RESET_HORIZON_SECS,
};

use super::{cancelled_snapshot, ProviderRuntime};
use crate::accounting::{
    append_token_usage, append_usage_trend, DayZone, TokenUsageOptions, UsageHistoryWindow,
};
use crate::context::RefreshContext;
use crate::http::{self, HttpClient};
use crate::model::{ErrorCategory, MetricLine, ProviderInfo, ProviderSnapshot, ProviderUsageHistory};
use crate::pricing;
use client::{attempt, Attempt, Failure};
use std::sync::Arc;
use std::time::Instant;
use transcripts::DevinTranscriptUsageScanner;

pub const NOT_LOGGED_IN: &str = "Run devin auth login or sign in to Devin and try again.";
pub const CREDENTIALS_UNREADABLE: &str = "QuotaBar couldn't read Devin's local credentials. Check access to credentials.toml and Devin's state database, then refresh again.";
pub const LOCAL_SOURCE_NOTE: &str = "From local Devin sessions; dollar amounts are estimates";

pub struct DevinProvider {
    info: ProviderInfo,
    pub auth: DevinAuthStore,
    http: Arc<dyn HttpClient>,
    local_scanner: DevinTranscriptUsageScanner,
}

impl DevinProvider {
    pub fn new(auth: DevinAuthStore, http: Arc<dyn HttpClient>) -> Self {
        DevinProvider {
            info: ProviderInfo { id: ID.into(), display_name: "Devin".into() },
            auth,
            http,
            local_scanner: DevinTranscriptUsageScanner::live(),
        }
    }

    pub fn with_local_scanner(mut self, scanner: DevinTranscriptUsageScanner) -> Self {
        self.local_scanner = scanner;
        self
    }

    pub fn live() -> Self {
        DevinProvider::new(DevinAuthStore::live(), http::shared())
    }

    pub fn refresh_with_api_key(
        &self,
        ctx: &RefreshContext,
        api_key: Option<&str>,
        deadline: Option<Instant>,
    ) -> ProviderSnapshot {
        if ctx.scope.suppresses_live_quota() {
            return self.local_only_snapshot(ctx);
        }

        let mut saw_api_key = false;
        let mut saw_auth_failure = false;
        let mut source_unreadable = false;
        let mut request_failure: Option<Failure> = None;
        let mut attempted: Vec<(String, String)> = Vec::new();

        let mut try_auth = |auth: DevinAuth, this: &Self| -> Option<ProviderSnapshot> {
            let fingerprint = (auth.api_key.clone(), auth.effective_api_server_url().to_string());
            if attempted.contains(&fingerprint) {
                return None;
            }
            attempted.push(fingerprint);
            saw_api_key = true;
            match attempt(this.http.as_ref(), &auth, ctx, deadline) {
                Attempt::Success(mapped) => Some(this.finish_snapshot(mapped, ctx)),
                Attempt::AuthFailure => {
                    saw_auth_failure = true;
                    None
                }
                Attempt::Failed(failure) => {
                    request_failure.get_or_insert(failure);
                    None
                }
                Attempt::Cancelled => Some(cancelled_snapshot(&this.info, ctx)),
            }
        };

        let credential = match api_key.map(str::trim).filter(|value| !value.is_empty()) {
            Some(api_key) => Ok(Some(DevinAuth { api_key: api_key.into(), api_server_url: None })),
            None => self.auth.load_credentials_file(),
        };
        match credential {
            Ok(Some(auth)) => {
                if let Some(snapshot) = try_auth(auth, self) {
                    return snapshot;
                }
            }
            Ok(None) => {}
            Err(CredentialsUnreadable) => source_unreadable = true,
        }
        for path in self.auth.state_db_paths() {
            if ctx.is_cancelled() {
                return cancelled_snapshot(&self.info, ctx);
            }
            match self.auth.load_app_auth(&path) {
                Ok(Some(auth)) => {
                    if let Some(snapshot) = try_auth(auth, self) {
                        return snapshot;
                    }
                }
                Ok(None) => {}
                Err(CredentialsUnreadable) => source_unreadable = true,
            }
        }

        let error = |message: &str, category| ProviderSnapshot::error(&self.info, message, category, ctx.now);
        if source_unreadable {
            return error(CREDENTIALS_UNREADABLE, ErrorCategory::CredentialAccess);
        }
        if saw_auth_failure {
            return error(NOT_LOGGED_IN, ErrorCategory::NotLoggedIn);
        }
        if let Some(failure) = request_failure {
            return error(&failure.message(), failure.category());
        }
        if saw_api_key {
            return error(QUOTA_UNAVAILABLE, ErrorCategory::NotAvailable);
        }
        error(NOT_LOGGED_IN, ErrorCategory::NotLoggedIn)
    }

    fn finish_snapshot(&self, mapped: MappedUsage, ctx: &RefreshContext) -> ProviderSnapshot {
        let mut lines = mapped.lines;
        let history = if !ctx.scope.skips_local_accounting() {
            self.append_local_usage(&mut lines, ctx)
        } else {
            None
        };
        ProviderSnapshot::new(&self.info, Some(mapped.plan), lines, ctx.now).with_usage_history(history)
    }

    fn local_only_snapshot(&self, ctx: &RefreshContext) -> ProviderSnapshot {
        let mut lines = Vec::new();
        let history = self.append_local_usage(&mut lines, ctx);
        MetricLine::append_no_data_if_needed(&mut lines);
        ProviderSnapshot::new(&self.info, None, lines, ctx.now).with_usage_history(history)
    }

    fn append_local_usage(&self, lines: &mut Vec<MetricLine>, ctx: &RefreshContext) -> Option<ProviderUsageHistory> {
        if ctx.is_cancelled() {
            return None;
        }
        let days_back = UsageHistoryWindow::lifetime_days(ctx.now, DayZone::Local);
        let skip = ctx.skip_model_catalog_refresh;
        let pricing_fn = || pricing::shared().current(skip);
        let scan = self.local_scanner.scan(days_back, ctx.now, &pricing_fn, &ctx.cancel)?;
        let opts = TokenUsageOptions {
            estimated: true,
            unknown_models_by_day: scan.unknown_models_by_day.clone(),
            model_usage: scan.model_usage.clone(),
            model_source_note: Some(LOCAL_SOURCE_NOTE.to_string()),
            partial_days: Default::default(),
            api_estimate_by_day: scan.api_estimate_by_day.clone(),
            estimated_cost_days: scan.estimated_cost_days.clone(),
        };
        append_token_usage(&scan.series, lines, ctx.now, &opts);
        append_usage_trend(&scan.series, lines, ctx.now, LOCAL_SOURCE_NOTE, &Default::default(), None);
        Some(ProviderUsageHistory {
            series: scan.series,
            model_usage: scan.model_usage,
            unknown_models_by_day: scan.unknown_models_by_day,
            api_estimate_by_day: scan.api_estimate_by_day,
            api_estimate_incomplete_days: scan.api_estimate_incomplete_days,
            partial_days: None,
            estimated_cost_days: scan.estimated_cost_days,
        })
    }
}

impl ProviderRuntime for DevinProvider {
    fn info(&self) -> &ProviderInfo {
        &self.info
    }

    fn has_local_credentials(&self) -> bool {
        match self.auth.load_credentials_file() {
            Ok(Some(_)) | Err(CredentialsUnreadable) => return true,
            Ok(None) => {}
        }
        self.auth.state_db_paths().iter().any(|path| !matches!(self.auth.load_app_auth(path), Ok(None)))
    }

    fn refresh(&self, ctx: &RefreshContext) -> ProviderSnapshot {
        self.refresh_with_api_key(ctx, None, None)
    }

    fn unload_caches(&self) {
        self.auth.unload_caches();
        self.local_scanner.unload_caches();
    }
}
