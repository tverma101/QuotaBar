//! Devin quota (daily / weekly percent + extra-usage balance) from Devin's seat-management API.
//!
//! Credential sources, in order (the union of the macOS provider and the Windows plugin):
//! 1. the Devin CLI's `credentials.toml` (`windsurf_api_key`, optional `api_server_url`);
//! 2. each Devin desktop app's `state.vscdb` (`ItemTable['windsurfAuthStatus'].apiKey`): Devin,
//!    Devin - Next, and the legacy Windsurf install. A source whose key and server were already tried
//!    is skipped.
//!
//! The state databases are read natively and cached against their revision (main file + WAL +
//! journal stamps), so an unchanged database costs a few `stat` calls per refresh.

use crate::context::RefreshContext;
use crate::host::{auth_tag, diagnostic_gate, plugin_tag};
use crate::http::{self, HttpClient, HttpError, Request};
use crate::model::{
    clamp_percent, ErrorCategory, MetricKind, MetricLine, MetricValue, ProviderInfo, ProviderSnapshot, Timestamp,
};
use crate::parse;
use crate::paths;
use crate::providers::{cancelled_snapshot, ProviderRuntime};
use crate::qlog;
use crate::sqlite::{self, SourceSignature};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Instant;

pub const ID: &str = "devin";
pub const CLOUD_SERVICE: &str = "exa.seat_management_pb.SeatManagementService";
pub const CLOUD_COMPAT_VERSION: &str = "1.108.2";
pub const DEFAULT_API_SERVER_URL: &str = "https://server.codeium.com";
/// Devin's windows are a day and a week; a reset further out than this used the wrong unit.
pub const MAXIMUM_RESET_HORIZON_SECS: f64 = 2.0 * 365.0 * 24.0 * 60.0 * 60.0;

pub const NOT_LOGGED_IN: &str = "Run devin auth login or sign in to Devin and try again.";
pub const CREDENTIALS_UNREADABLE: &str = "QuotaBar couldn't read Devin's local credentials. Check access to credentials.toml and Devin's state database, then refresh again.";
pub const QUOTA_UNAVAILABLE: &str = "Devin quota data unavailable. Try again later.";

const HTTP_FAILURE_KEY_PREFIX: &str = "devin.usage.http.";
const INVALID_RESPONSE_KEY: &str = "devin.usage.invalid-response";
const TRANSPORT_FAILURE_KEY: &str = "devin.usage.transport";

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct DevinAuth {
    pub api_key: String,
    pub api_server_url: Option<String>,
}

impl DevinAuth {
    pub fn effective_api_server_url(&self) -> &str {
        self.api_server_url.as_deref().unwrap_or(DEFAULT_API_SERVER_URL)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CredentialsUnreadable;

// ---------------------------------------------------------------------------------------------
// Auth store
// ---------------------------------------------------------------------------------------------

pub struct DevinAuthStore {
    /// `None` resolves the platform locations on every read, so a host that reconfigures the home
    /// directory (tests, the CLI's `--home`) is honored without rebuilding the engine.
    fixed: Option<(Vec<PathBuf>, Vec<PathBuf>)>,
    app_auth_cache: Mutex<HashMap<PathBuf, (SourceSignature, Option<DevinAuth>)>>,
}

impl DevinAuthStore {
    pub fn new(credentials_paths: Vec<PathBuf>, state_db_paths: Vec<PathBuf>) -> Self {
        DevinAuthStore { fixed: Some((credentials_paths, state_db_paths)), app_auth_cache: Mutex::new(HashMap::new()) }
    }

    /// Standard locations for this platform, resolved against the configured home on every read.
    pub fn live() -> Self {
        DevinAuthStore { fixed: None, app_auth_cache: Mutex::new(HashMap::new()) }
    }

    pub fn credentials_paths(&self) -> Vec<PathBuf> {
        match &self.fixed {
            Some((credentials, _)) => credentials.clone(),
            None => live_locations().0,
        }
    }

    pub fn state_db_paths(&self) -> Vec<PathBuf> {
        match &self.fixed {
            Some((_, state)) => state.clone(),
            None => live_locations().1,
        }
    }

    /// The first credentials file that exists. `Ok(None)` when none exists or it has no API key; a
    /// present file that cannot be read stays distinguishable so detection never hides a login.
    pub fn load_credentials_file(&self) -> Result<Option<DevinAuth>, CredentialsUnreadable> {
        let Some(path) = self.credentials_paths().into_iter().find(|p| p.exists()) else {
            diagnostic_gate::clear("auth.devin.credentials-file-read");
            return Ok(None);
        };
        let text = match std::fs::read_to_string(&path) {
            Ok(text) => text,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(_) => {
                diagnostic_gate::log_once("auth.devin.credentials-file-read", || {
                    qlog!(Error, auth_tag(ID), "CLI credentials file read failed");
                });
                return Err(CredentialsUnreadable);
            }
        };
        diagnostic_gate::clear("auth.devin.credentials-file-read");
        let Some(api_key) = read_toml_string(&text, "windsurf_api_key") else { return Ok(None) };
        Ok(Some(DevinAuth {
            api_key,
            api_server_url: clean_api_server_url(read_toml_string(&text, "api_server_url").as_deref()),
        }))
    }

    /// The credential stored by one Devin app, re-read only when its database's revision moved. A
    /// failed read is not cached, so a transient failure retries on the next refresh.
    pub fn load_app_auth(&self, path: &Path) -> Result<Option<DevinAuth>, CredentialsUnreadable> {
        let signature = sqlite::source_signature(path);
        if let Some((cached_signature, auth)) = self.app_auth_cache.lock().unwrap_or_else(|e| e.into_inner()).get(path) {
            if *cached_signature == signature {
                return Ok(auth.clone());
            }
        }
        let auth = read_app_auth(path)?;
        self.app_auth_cache
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(path.to_path_buf(), (signature, auth.clone()));
        Ok(auth)
    }
}

fn live_locations() -> (Vec<PathBuf>, Vec<PathBuf>) {
    let xdg = paths::xdg_data_home();
    let mut credentials = vec![xdg.join("devin/credentials.toml")];
    #[cfg(windows)]
    {
        let local = std::env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(|| paths::home().join("AppData/Local"));
        credentials.push(local.join("devin/credentials.toml"));
    }
    // Legacy CLI directory kept during Devin's migration.
    credentials.push(xdg.join("cognition/credentials.toml"));
    let support = paths::platform_app_support();
    let state = ["Devin", "Devin - Next", "Windsurf"]
        .iter()
        .map(|app| support.join(app).join("User/globalStorage/state.vscdb"))
        .collect();
    (credentials, state)
}

fn read_app_auth(path: &Path) -> Result<Option<DevinAuth>, CredentialsUnreadable> {
    let sql = "SELECT value FROM ItemTable WHERE key = 'windsurfAuthStatus' LIMIT 1";
    let value = match sqlite::query_value_tolerating_missing_table(path, sql) {
        Ok(value) => value,
        Err(_) => {
            diagnostic_gate::log_once("auth.devin.state-db-read", || {
                qlog!(Error, auth_tag(ID), "app state database credential read failed");
            });
            return Err(CredentialsUnreadable);
        }
    };
    diagnostic_gate::clear("auth.devin.state-db-read");
    let Some(value) = value else {
        diagnostic_gate::clear("auth.devin.state-db-decode");
        return Ok(None);
    };
    let Some(object) = serde_json::from_str::<Value>(&value).ok().filter(Value::is_object) else {
        diagnostic_gate::log_once("auth.devin.state-db-decode", || {
            qlog!(Error, auth_tag(ID), "app state database credential data could not be decoded");
        });
        return Err(CredentialsUnreadable);
    };
    diagnostic_gate::clear("auth.devin.state-db-decode");
    Ok(parse::trimmed_string(object.get("apiKey")).map(|api_key| DevinAuth { api_key, api_server_url: None }))
}

/// `https://` only, trailing slashes removed.
pub fn clean_api_server_url(value: Option<&str>) -> Option<String> {
    let trimmed = value?.trim();
    if !trimmed.starts_with("https://") {
        return None;
    }
    let cleaned = trimmed.trim_end_matches('/');
    (!cleaned.is_empty()).then(|| cleaned.to_string())
}

/// The minimal TOML reader the Swift provider used: `key = value`, quoted or bare, `#` comments on
/// bare values, first matching line wins (an empty value stops the search).
pub fn read_toml_string(text: &str, key: &str) -> Option<String> {
    for line in text.split(['\n', '\r']).filter(|l| !l.is_empty()) {
        let Some((name, value)) = line.split_once('=') else { continue };
        if name.trim() != key {
            continue;
        }
        let value = value.trim();
        if value.is_empty() {
            return None;
        }
        if value.starts_with('"') || value.starts_with('\'') {
            return read_quoted(value);
        }
        let value = value.split('#').next().unwrap_or("").trim();
        return (!value.is_empty()).then(|| value.to_string());
    }
    None
}

fn read_quoted(value: &str) -> Option<String> {
    let mut chars = value.chars();
    let quote = chars.next()?;
    let mut output = String::new();
    let mut previous: Option<char> = None;
    for ch in chars {
        if ch == quote && previous != Some('\\') {
            let trimmed = output.trim();
            return (!trimmed.is_empty()).then(|| trimmed.to_string());
        }
        output.push(ch);
        previous = Some(ch);
    }
    None
}

// ---------------------------------------------------------------------------------------------
// Mapper
// ---------------------------------------------------------------------------------------------

#[derive(Clone, Debug, PartialEq)]
pub struct MappedUsage {
    pub plan: String,
    pub lines: Vec<MetricLine>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UsageError {
    InvalidResponse,
    QuotaUnavailable,
}

pub fn map_user_status_response(body: &[u8], now: Timestamp) -> Result<MappedUsage, UsageError> {
    let root: Value = serde_json::from_slice(body).map_err(|_| UsageError::InvalidResponse)?;
    let user_status = root.get("userStatus").filter(|v| v.is_object()).ok_or(UsageError::InvalidResponse)?;
    map_user_status(user_status, now)
}

pub fn map_user_status(user_status: &Value, now: Timestamp) -> Result<MappedUsage, UsageError> {
    let empty = Value::Object(Default::default());
    let plan_status = user_status.get("planStatus").filter(|v| v.is_object()).unwrap_or(&empty);
    let plan_info = plan_status.get("planInfo").filter(|v| v.is_object()).unwrap_or(&empty);
    let plan = parse::trimmed_string(plan_info.get("planName")).unwrap_or_else(|| "Unknown".to_string());
    let hide_daily = parse::bool(plan_info.get("hideDailyQuota")) == Some(true);

    let daily_remaining = parse::number(plan_status.get("dailyQuotaRemainingPercent"));
    let weekly_remaining = parse::number(plan_status.get("weeklyQuotaRemainingPercent"));
    // A weekly field that is present but unreadable is a schema change, not "no weekly quota".
    if plan_status.get("weeklyQuotaRemainingPercent").is_some() && weekly_remaining.is_none() {
        return Err(UsageError::InvalidResponse);
    }
    let daily_reset = if hide_daily { None } else { reset_instant(plan_status.get("dailyQuotaResetAtUnix"), now) };
    let weekly_reset = reset_instant(plan_status.get("weeklyQuotaResetAtUnix"), now);
    let extra_balance = parse::number(plan_status.get("overageBalanceMicros")).map(|micros| micros.max(0.0) / 1_000_000.0);

    let mut lines = Vec::new();
    if !hide_daily {
        if let Some(remaining) = daily_remaining {
            lines.push(quota_line("Daily quota", remaining, daily_reset, parse::DAY_MS));
        }
    }
    // Proto3 JSON omits zero values: a valid weekly reset with no percentage is an exhausted window.
    let weekly = weekly_remaining.or(weekly_reset.map(|_| 0.0));
    if let Some(remaining) = weekly {
        lines.push(quota_line("Weekly quota", remaining, weekly_reset, parse::WEEK_MS));
    } else if hide_daily {
        if let Some(remaining) = daily_remaining {
            // No weekly percentage or reset: surface the hidden daily quota in the Weekly row.
            lines.push(quota_line("Weekly quota", remaining, None, parse::WEEK_MS));
        }
    }
    if let Some(balance) = extra_balance {
        lines.push(MetricLine::values("Extra usage balance", vec![MetricValue::new(balance, MetricKind::Dollars)]));
    }
    if lines.is_empty() {
        return Err(UsageError::QuotaUnavailable);
    }
    Ok(MappedUsage { plan, lines })
}

/// Devin reports percent *remaining*; the tile shows percent *used*.
fn quota_line(label: &str, remaining: f64, resets_at: Option<Timestamp>, period_ms: i64) -> MetricLine {
    MetricLine::percent_progress(label, clamp_percent(100.0 - remaining), resets_at, Some(period_ms))
}

/// A reset instant only when it is ahead of `now` and inside a believable horizon; a zero or a stale
/// value would otherwise render "Resets soon" forever.
fn reset_instant(value: Option<&Value>, now: Timestamp) -> Option<Timestamp> {
    let seconds = parse::number(value).filter(|s| *s > 0.0)?;
    (seconds > now && seconds - now <= MAXIMUM_RESET_HORIZON_SECS).then_some(seconds)
}

// ---------------------------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------------------------

enum Attempt {
    Success(MappedUsage),
    AuthFailure,
    Failed(Failure),
    Cancelled,
}

#[derive(Clone, Copy)]
enum Failure {
    RequestFailed(u16),
    InvalidResponse,
    ConnectionFailed,
    QuotaUnavailable,
}

impl Failure {
    fn message(self) -> String {
        match self {
            Failure::RequestFailed(status) => {
                format!("Devin's service returned an error (HTTP {status}). Try again later.")
            }
            Failure::InvalidResponse => "Devin returned quota data QuotaBar couldn't read. Try again later.".into(),
            Failure::ConnectionFailed => "QuotaBar couldn't reach Devin. Check your connection and try again.".into(),
            Failure::QuotaUnavailable => QUOTA_UNAVAILABLE.into(),
        }
    }

    fn category(self) -> ErrorCategory {
        match self {
            Failure::RequestFailed(status) => ErrorCategory::http(status),
            Failure::InvalidResponse => ErrorCategory::Decoding,
            Failure::ConnectionFailed => ErrorCategory::Network,
            Failure::QuotaUnavailable => ErrorCategory::NotAvailable,
        }
    }
}

pub struct DevinProvider {
    info: ProviderInfo,
    pub auth: DevinAuthStore,
    http: Arc<dyn HttpClient>,
}

impl DevinProvider {
    pub fn new(auth: DevinAuthStore, http: Arc<dyn HttpClient>) -> Self {
        DevinProvider { info: ProviderInfo { id: ID.into(), display_name: "Devin".into() }, auth, http }
    }

    pub fn live() -> Self {
        DevinProvider::new(DevinAuthStore::live(), http::shared())
    }

    fn attempt(&self, auth: &DevinAuth, ctx: &RefreshContext, deadline: Option<Instant>) -> Attempt {
        if ctx.is_cancelled() {
            return Attempt::Cancelled;
        }
        let timeout = deadline.map_or(http::DEFAULT_TIMEOUT, |deadline| {
            http::DEFAULT_TIMEOUT.min(deadline.saturating_duration_since(Instant::now()))
        });
        if timeout.is_zero() {
            return Attempt::Failed(Failure::ConnectionFailed);
        }
        let url = format!("{}/{}/GetUserStatus", auth.effective_api_server_url(), CLOUD_SERVICE);
        let body = json!({
            "metadata": {
                "apiKey": auth.api_key,
                "ideName": "devin",
                "ideVersion": CLOUD_COMPAT_VERSION,
                "extensionName": "devin",
                "extensionVersion": CLOUD_COMPAT_VERSION,
                "locale": "en"
            }
        });
        let request = Request::post_json(url, &body)
            .header("Connect-Protocol-Version", "1")
            .timeout(timeout);
        let response = match self.http.send(&request, &ctx.cancel) {
            Ok(response) => response,
            Err(HttpError::Cancelled) => return Attempt::Cancelled,
            Err(error) => {
                diagnostic_gate::log_once(TRANSPORT_FAILURE_KEY, || {
                    qlog!(Warn, plugin_tag(ID), "quota request failed (transport): {error}");
                });
                return Attempt::Failed(Failure::ConnectionFailed);
            }
        };
        if ctx.is_cancelled() {
            return Attempt::Cancelled;
        }
        if response.status == 401 || response.status == 403 {
            return Attempt::AuthFailure;
        }
        if !response.is_success() {
            let status = response.status;
            diagnostic_gate::log_once(&format!("{HTTP_FAILURE_KEY_PREFIX}{status}"), || {
                qlog!(Warn, plugin_tag(ID), "quota request failed (HTTP {status})");
            });
            return Attempt::Failed(Failure::RequestFailed(status));
        }
        match map_user_status_response(&response.body, ctx.now) {
            Ok(mapped) => {
                diagnostic_gate::clear_prefix("devin.usage.");
                Attempt::Success(mapped)
            }
            Err(UsageError::QuotaUnavailable) => Attempt::Failed(Failure::QuotaUnavailable),
            Err(UsageError::InvalidResponse) => {
                diagnostic_gate::log_once(INVALID_RESPONSE_KEY, || {
                    qlog!(Warn, plugin_tag(ID), "quota response could not be read");
                });
                Attempt::Failed(Failure::InvalidResponse)
            }
        }
    }

    fn snapshot(&self, mapped: MappedUsage, ctx: &RefreshContext) -> ProviderSnapshot {
        ProviderSnapshot::new(&self.info, Some(mapped.plan), mapped.lines, ctx.now)
    }
}

impl DevinProvider {
    /// A saved per-account API key takes the place of the default CLI credential. The desktop
    /// auth fallback is shared with the ordinary provider refresh.
    pub fn refresh_with_api_key(
        &self, ctx: &RefreshContext, api_key: Option<&str>, deadline: Option<Instant>,
    ) -> ProviderSnapshot {
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
            match this.attempt(&auth, ctx, deadline) {
                Attempt::Success(mapped) => Some(this.snapshot(mapped, ctx)),
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
        // A failed request keeps its own message and bucket: an outage, a schema change and a broken
        // network are different problems with different fixes.
        if let Some(failure) = request_failure {
            return error(&failure.message(), failure.category());
        }
        if saw_api_key {
            return error(QUOTA_UNAVAILABLE, ErrorCategory::NotAvailable);
        }
        error(NOT_LOGGED_IN, ErrorCategory::NotLoggedIn)
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
        // An indeterminate but present source stays detected so refresh can show its repair path.
        self.auth.state_db_paths().iter().any(|path| !matches!(self.auth.load_app_auth(path), Ok(None)))
    }

    fn refresh(&self, ctx: &RefreshContext) -> ProviderSnapshot {
        self.refresh_with_api_key(ctx, None, None)
    }
}

#[cfg(test)]
mod tests;
