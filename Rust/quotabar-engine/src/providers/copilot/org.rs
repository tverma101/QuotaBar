//! Org-level Copilot billing discovery, cooldowns, and state persistence.

use super::auth::ID;
use super::client::{self, OrgsFetchResult};
use super::mapper::org_usage_lines;
use crate::context::RefreshContext;
use crate::host::{diagnostic_gate, plugin_tag};
use crate::http::{HttpClient, HttpError};
use crate::model::{MetricLine, Timestamp};
use crate::parse;
use crate::paths;
use crate::qlog;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Mutex;

pub const PROBE_BACKOFF_SECS: f64 = 5.0 * 60.0;
pub const MAX_RATE_LIMIT_COOLDOWN_SECS: f64 = 60.0 * 60.0;
const ORG_LIST_DIAG_PREFIX: &str = "copilot.org-list.";

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrgBillingState {
    pub billing_org: Option<String>,
    pub probe_retry_after: Option<f64>,
    pub rate_limit_retry_after: Option<f64>,
}

pub trait OrgStateStore: Send + Sync {
    fn load(&self) -> OrgBillingState;
    fn save(&self, state: &OrgBillingState);
    fn clear_cache(&self) {}
}

pub struct FileOrgStateStore {
    cache: Mutex<Option<(PathBuf, OrgBillingState)>>,
    fixed_path: Option<PathBuf>,
}

impl FileOrgStateStore {
    pub fn live() -> Self {
        FileOrgStateStore { cache: Mutex::new(None), fixed_path: None }
    }

    pub fn at(path: PathBuf) -> Self {
        FileOrgStateStore { cache: Mutex::new(None), fixed_path: Some(path) }
    }

    fn path(&self) -> PathBuf {
        self.fixed_path
            .clone()
            .unwrap_or_else(|| paths::cache_dir("copilot").join("org_state.json"))
    }
}

impl OrgStateStore for FileOrgStateStore {
    fn load(&self) -> OrgBillingState {
        let path = self.path();
        {
            let guard = self.cache.lock().unwrap_or_else(|e| e.into_inner());
            if let Some((cached_path, state)) = guard.as_ref() {
                if *cached_path == path {
                    return state.clone();
                }
            }
        }
        let loaded = std::fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<OrgBillingState>(&bytes).ok())
            .unwrap_or_default();
        *self.cache.lock().unwrap_or_else(|e| e.into_inner()) = Some((path, loaded.clone()));
        loaded
    }

    fn save(&self, state: &OrgBillingState) {
        let path = self.path();
        *self.cache.lock().unwrap_or_else(|e| e.into_inner()) = Some((path.clone(), state.clone()));
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(bytes) = serde_json::to_vec(state) {
            if let Some(parent) = path.parent() {
                if let Ok(mut tmp) = tempfile::NamedTempFile::new_in(parent) {
                    use std::io::Write;
                    if tmp.write_all(&bytes).is_ok() && tmp.flush().is_ok() {
                        let _ = tmp.persist(&path);
                    }
                }
            }
        }
    }

    fn clear_cache(&self) {
        *self.cache.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }
}

enum OrgSummaryError {
    Cancelled,
    RateLimit,
    Transient(String),
}

pub fn org_billing_lines(
    http: &dyn HttpClient,
    store: &dyn OrgStateStore,
    token: &str,
    ctx: &RefreshContext,
) -> Result<Vec<MetricLine>, ()> {
    if ctx.is_cancelled() {
        return Err(());
    }
    let mut state = store.load();
    if let Some(retry_after) = state.rate_limit_retry_after {
        if retry_after > ctx.now {
            return Ok(Vec::new());
        }
        state.rate_limit_retry_after = None;
        store.save(&state);
    }
    if ctx.is_manual {
        if state.probe_retry_after.is_some() {
            state.probe_retry_after = None;
            store.save(&state);
        }
    } else if let Some(retry_after) = state.probe_retry_after {
        if retry_after > ctx.now {
            return Ok(Vec::new());
        }
    }

    let mut attempted = HashSet::new();
    if let Some(cached_org) = state.billing_org.clone() {
        attempted.insert(cached_org.to_ascii_lowercase());
        match fetch_org_lines(http, store, &mut state, &cached_org, token, ctx) {
            Ok(Some(lines)) => {
                diagnostic_gate::clear_prefix(&org_diag_prefix(&cached_org));
                state.probe_retry_after = None;
                store.save(&state);
                return Ok(lines);
            }
            Ok(None) => {
                diagnostic_gate::clear_prefix(&org_diag_prefix(&cached_org));
                state.billing_org = None;
                store.save(&state);
            }
            Err(OrgSummaryError::Cancelled) => return Err(()),
            Err(OrgSummaryError::RateLimit) => {
                qlog!(Info, plugin_tag(ID), "org billing rate limited; pausing org discovery");
                return Ok(Vec::new());
            }
            Err(OrgSummaryError::Transient(desc)) => {
                diagnostic_gate::log_once(&format!("{}transient", org_diag_prefix(&cached_org)), || {
                    qlog!(Warn, plugin_tag(ID), "org billing lookup failed for the remembered org: {desc}");
                });
                return Ok(Vec::new());
            }
        }
    }

    let OrgsFetchResult { response, partial_status, partial_rate_limited } =
        match client::fetch_user_orgs(http, token, &ctx.cancel) {
            Ok(res) => res,
            Err(HttpError::Cancelled) => return Err(()),
            Err(err) => {
                diagnostic_gate::log_once(&format!("{ORG_LIST_DIAG_PREFIX}fetch"), || {
                    qlog!(Warn, plugin_tag(ID), "org list fetch failed: {err}");
                });
                return Ok(Vec::new());
            }
        };
    if ctx.is_cancelled() {
        return Err(());
    }
    if let Some(ref partial) = partial_status {
        if let Ok(code) = partial.parse::<u16>() {
            let rl = partial_rate_limited || client::is_rate_limit_response(&response);
            if rl {
                record_rate_limit(store, &mut state, response.header("retry-after"), response.header("x-ratelimit-reset"), ctx.now);
                qlog!(Info, plugin_tag(ID), "org list rate limited; pausing org discovery");
                return Ok(Vec::new());
            }
            diagnostic_gate::log_once(&format!("{ORG_LIST_DIAG_PREFIX}partial.{code}"), || {
                qlog!(Warn, plugin_tag(ID), "org list pagination stopped at HTTP {code}; using completed pages");
            });
        } else {
            diagnostic_gate::log_once(&format!("{ORG_LIST_DIAG_PREFIX}partial.{}", fingerprint_str(partial)), || {
                qlog!(Warn, plugin_tag(ID), "org list pagination stopped after {partial}; using completed pages");
            });
        }
    }
    if client::is_rate_limit_response(&response) {
        record_rate_limit(store, &mut state, response.header("retry-after"), response.header("x-ratelimit-reset"), ctx.now);
        qlog!(Info, plugin_tag(ID), "org list rate limited; pausing org discovery");
        return Ok(Vec::new());
    }
    if response.status != 200 {
        if response.status == 403 {
            state.probe_retry_after = Some(ctx.now + PROBE_BACKOFF_SECS);
            store.save(&state);
        }
        let code = response.status;
        diagnostic_gate::log_once(&format!("{ORG_LIST_DIAG_PREFIX}http.{code}"), || {
            qlog!(Info, plugin_tag(ID), "org list HTTP {code}; skipping org billing lookup");
        });
        return Ok(Vec::new());
    }
    if partial_status.is_none() {
        diagnostic_gate::clear_prefix(ORG_LIST_DIAG_PREFIX);
    }

    let orgs = org_logins(&response.body);
    let mut saw_transient_failure = partial_status.is_some();
    for org in orgs {
        if !attempted.insert(org.to_ascii_lowercase()) {
            continue;
        }
        if ctx.is_cancelled() {
            return Err(());
        }
        match fetch_org_lines(http, store, &mut state, &org, token, ctx) {
            Ok(Some(lines)) => {
                diagnostic_gate::clear_prefix(&org_diag_prefix(&org));
                state.billing_org = Some(org);
                state.probe_retry_after = None;
                store.save(&state);
                return Ok(lines);
            }
            Ok(None) => {
                diagnostic_gate::clear_prefix(&org_diag_prefix(&org));
            }
            Err(OrgSummaryError::Cancelled) => return Err(()),
            Err(OrgSummaryError::RateLimit) => {
                qlog!(Info, plugin_tag(ID), "org billing rate limited; pausing org discovery");
                return Ok(Vec::new());
            }
            Err(OrgSummaryError::Transient(desc)) => {
                saw_transient_failure = true;
                diagnostic_gate::log_once(&format!("{}transient", org_diag_prefix(&org)), || {
                    qlog!(Warn, plugin_tag(ID), "org billing summary failed for one org; trying the next: {desc}");
                });
            }
        }
    }
    if !saw_transient_failure {
        state.probe_retry_after = Some(ctx.now + PROBE_BACKOFF_SECS);
        store.save(&state);
    }
    Ok(Vec::new())
}

fn fetch_org_lines(
    http: &dyn HttpClient,
    store: &dyn OrgStateStore,
    state: &mut OrgBillingState,
    org: &str,
    token: &str,
    ctx: &RefreshContext,
) -> Result<Option<Vec<MetricLine>>, OrgSummaryError> {
    if ctx.is_cancelled() {
        return Err(OrgSummaryError::Cancelled);
    }
    let resp = match client::fetch_usage_summary(http, org, token, &ctx.cancel) {
        Ok(resp) => resp,
        Err(HttpError::Cancelled) => return Err(OrgSummaryError::Cancelled),
        Err(err) => return Err(OrgSummaryError::Transient(err.to_string())),
    };
    if ctx.is_cancelled() {
        return Err(OrgSummaryError::Cancelled);
    }
    if client::is_rate_limit_response(&resp) {
        let retry_after = resp.header("retry-after").map(ToString::to_string);
        let rate_limit_reset = resp.header("x-ratelimit-reset").map(ToString::to_string);
        record_rate_limit(store, state, retry_after.as_deref(), rate_limit_reset.as_deref(), ctx.now);
        if resp.status == 200 {
            if let Some(lines) = org_usage_lines(&resp.body) {
                return Ok(Some(lines));
            }
        }
        return Err(OrgSummaryError::RateLimit);
    }
    if resp.status != 200 {
        qlog!(Debug, plugin_tag(ID), "org billing summary for one org: HTTP {}", resp.status);
        if resp.status >= 500 {
            return Err(OrgSummaryError::Transient(format!("HTTP {}", resp.status)));
        }
        return Ok(None);
    }
    Ok(org_usage_lines(&resp.body))
}

pub fn org_logins(body: &[u8]) -> Vec<String> {
    let Ok(Value::Array(items)) = serde_json::from_slice::<Value>(body) else {
        return Vec::new();
    };
    items
        .iter()
        .filter_map(|item| parse::trimmed_string(item.get("login")))
        .collect()
}

fn record_rate_limit(
    store: &dyn OrgStateStore,
    state: &mut OrgBillingState,
    retry_after: Option<&str>,
    rate_limit_reset: Option<&str>,
    now: Timestamp,
) {
    let mut retry_date: Option<f64> = None;
    if let Some(raw) = retry_after {
        if let Ok(seconds) = raw.trim().parse::<f64>() {
            if seconds.is_finite() && seconds >= 0.0 {
                retry_date = Some(now + seconds.min(MAX_RATE_LIMIT_COOLDOWN_SECS));
            }
        } else if let Ok(dt) = chrono::DateTime::parse_from_rfc2822(raw.trim()) {
            retry_date = Some(dt.timestamp() as f64);
        }
    }
    if let Some(raw) = rate_limit_reset {
        if let Ok(epoch) = raw.trim().parse::<f64>() {
            if epoch > now && epoch - now <= MAX_RATE_LIMIT_COOLDOWN_SECS {
                retry_date = Some(retry_date.map_or(epoch, |prev| prev.max(epoch)));
            }
        }
    }
    let clamped = retry_date
        .map(|d| d.min(now + MAX_RATE_LIMIT_COOLDOWN_SECS))
        .unwrap_or(now + PROBE_BACKOFF_SECS);
    state.rate_limit_retry_after = Some(clamped);
    store.save(state);
}

fn org_diag_prefix(org: &str) -> String {
    format!("copilot.org-billing.{}.", fingerprint_str(&org.to_ascii_lowercase()))
}

fn fingerprint_str(s: &str) -> String {
    use sha2::{Digest, Sha256};
    Sha256::digest(s.as_bytes()).iter().take(8).map(|b| format!("{b:02x}")).collect()
}
