//! Per-refresh request context (Swift `ProviderRefreshContext` task-locals, made explicit).

use crate::model::Timestamp;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

/// Which domains a refresh pass covers (Swift `ProviderRefreshContext.Scope`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Scope {
    MenuBar,
    PanelMeters,
    LocalAccounting,
    PanelAccounting,
    Full,
}

impl Scope {
    pub fn skips_local_accounting(self) -> bool {
        matches!(self, Scope::MenuBar | Scope::PanelMeters)
    }

    pub fn suppresses_live_quota(self) -> bool {
        matches!(self, Scope::LocalAccounting | Scope::PanelAccounting)
    }

    pub fn refreshes_quota_domain(self) -> bool {
        matches!(self, Scope::MenuBar | Scope::PanelMeters | Scope::Full)
    }

    pub fn refreshes_history_domain(self, panel_meters_includes_history: bool) -> bool {
        match self {
            Scope::LocalAccounting | Scope::PanelAccounting | Scope::Full => true,
            Scope::MenuBar | Scope::PanelMeters => panel_meters_includes_history,
        }
    }
}

/// Cooperative cancellation shared between the caller and long-running scans.
#[derive(Clone, Default, Debug)]
pub struct CancelToken {
    cancelled: Arc<AtomicBool>,
    pub(crate) serial_scan: bool,
}

impl CancelToken {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Relaxed)
    }

    pub fn check(&self) -> Result<(), Cancelled> {
        if self.is_cancelled() {
            Err(Cancelled)
        } else {
            Ok(())
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Cancelled;

impl std::fmt::Display for Cancelled {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("cancelled")
    }
}

impl std::error::Error for Cancelled {}

#[derive(Clone, Debug)]
pub struct RefreshContext {
    pub scope: Scope,
    /// User-initiated refresh: credential prompts are allowed and backoffs are bypassed.
    pub is_manual: bool,
    pub now: Timestamp,
    pub cancel: CancelToken,
    /// Skip network pricing-catalog refreshes (the host already refreshed recently).
    pub skip_model_catalog_refresh: bool,
    /// Background folds limit scan concurrency to reduce CPU and memory spikes.
    pub paced: bool,
    /// The host's id for this refresh; forwarded with host callbacks (Keychain prompt budgets).
    pub request_id: Option<u64>,
    /// Optional per-call provider configuration (multi-account paths, preferences, overrides).
    pub config: Option<Value>,
    /// Observed account/cache identity produced by the provider during this refresh.
    pub observed_identity_key: Arc<Mutex<Option<String>>>,
}

impl RefreshContext {
    pub fn new(scope: Scope) -> Self {
        RefreshContext {
            scope,
            is_manual: false,
            now: now_timestamp(),
            cancel: CancelToken::new(),
            skip_model_catalog_refresh: false,
            paced: false,
            request_id: None,
            config: None,
            observed_identity_key: Arc::new(Mutex::new(None)),
        }
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancel.is_cancelled()
    }

    pub fn set_observed_identity_key(&self, key: impl Into<String>) {
        *self
            .observed_identity_key
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = Some(key.into());
    }

    pub fn observed_identity_key(&self) -> Option<String> {
        self.observed_identity_key
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }
}

pub fn now_timestamp() -> Timestamp {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

pub fn system_time_to_timestamp(time: SystemTime) -> Timestamp {
    match time.duration_since(UNIX_EPOCH) {
        Ok(d) => d.as_secs_f64(),
        Err(e) => -e.duration().as_secs_f64(),
    }
}
