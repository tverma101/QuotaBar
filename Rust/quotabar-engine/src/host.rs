//! Services the embedding app provides to the engine.
//!
//! The engine owns all data acquisition and computation. The host keeps the few things that are
//! inherently app- or OS-UI-integrated:
//!
//! - **Logging** goes to the host's log sink so the app keeps one redacted log file
//!   (macOS: `AppLog`, `~/Library/Logs/QuotaBar/QuotaBar.log`).
//! - **Secure credential reads** (macOS Keychain, Windows Credential Manager) go through the host so
//!   per-item permission prompts, "don't ask again" memory and manual-retry gating stay in one place
//!   and are attributed to the signed app binary.

use serde::{Deserialize, Serialize};
use std::sync::{Arc, OnceLock, RwLock};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
#[repr(u32)]
pub enum LogLevel {
    Error = 0,
    Warn = 1,
    Info = 2,
    Debug = 3,
}

impl LogLevel {
    pub fn from_u32(value: u32) -> LogLevel {
        match value {
            0 => LogLevel::Error,
            1 => LogLevel::Warn,
            2 => LogLevel::Info,
            _ => LogLevel::Debug,
        }
    }
}

/// Which account a credential-store item lives under.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", content = "name", rename_all = "camelCase")]
pub enum SecureAccount {
    /// Any account (a service-only lookup; another app's item, e.g. Claude Code's).
    #[default]
    Any,
    /// The signed-in OS user (items QuotaBar writes itself).
    CurrentUser,
    /// An explicit account name another app stored the item under.
    Named(String),
}

impl SecureAccount {
    fn is_any(&self) -> bool {
        matches!(self, SecureAccount::Any)
    }
}

fn is_false(value: &bool) -> bool {
    !*value
}

/// A request to read one secret from the platform credential store.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SecureReadRequest {
    /// Keychain service / credential target name.
    pub service: String,
    #[serde(default, skip_serializing_if = "SecureAccount::is_any")]
    pub account: SecureAccount,
    /// Provider family requesting the read, for the host's permission bookkeeping and logs.
    pub provider: String,
    /// True only for user-initiated refreshes; background reads must never prompt. The host still
    /// limits a manual refresh to one dialog across every provider.
    pub allow_interaction: bool,
    /// Read even when the host is backing off after a recent failure of this item.
    #[serde(default, skip_serializing_if = "is_false")]
    pub bypass_deferred_read_failure: bool,
    /// On a manual refresh, silently recheck an item the user blocked earlier, so access granted
    /// since then recovers without a dialog. For providers with another credential source.
    #[serde(default, skip_serializing_if = "is_false")]
    pub recheck_blocked_silently: bool,
    /// The refresh this read belongs to, so the host applies that refresh's prompt budget and
    /// cancellation.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub request_id: Option<u64>,
}

impl SecureReadRequest {
    /// A read on behalf of `ctx`'s refresh: interactive only when the refresh is manual.
    pub fn for_refresh(service: &str, account: SecureAccount, provider: &str, ctx: &crate::context::RefreshContext) -> Self {
        SecureReadRequest {
            service: service.to_string(),
            account,
            provider: provider.to_string(),
            allow_interaction: ctx.is_manual,
            bypass_deferred_read_failure: false,
            recheck_blocked_silently: false,
            request_id: ctx.request_id,
        }
    }

    /// A silent read that never prompts (setup probes, background checks).
    pub fn silent(service: &str, account: SecureAccount, provider: &str) -> Self {
        SecureReadRequest {
            service: service.to_string(),
            account,
            provider: provider.to_string(),
            allow_interaction: false,
            bypass_deferred_read_failure: false,
            recheck_blocked_silently: false,
            request_id: None,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(tag = "status", rename_all = "camelCase")]
pub enum SecureReadOutcome {
    Found { value: String },
    NotFound,
    /// The item exists but reading it needs a prompt the host was not allowed to show.
    InteractionRequired,
    /// The user denied access (or previously chose not to be asked again).
    Denied,
    /// The host is backing off after a recent failure of this item; a manual refresh retries.
    Deferred,
    /// The refresh this read belonged to was cancelled.
    Cancelled,
    Failed { message: String },
}

/// A request to store one secret (a rotated OAuth token, a cached access token).
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SecureWriteRequest {
    pub service: String,
    #[serde(default, skip_serializing_if = "SecureAccount::is_any")]
    pub account: SecureAccount,
    pub provider: String,
    pub value: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(tag = "status", rename_all = "camelCase")]
pub enum SecureWriteOutcome {
    Written,
    Failed { message: String },
}

/// A request to remove a secret from the platform credential store.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SecureDeleteRequest {
    pub service: String,
    #[serde(default, skip_serializing_if = "SecureAccount::is_any")]
    pub account: SecureAccount,
    pub provider: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(tag = "status", rename_all = "camelCase")]
pub enum SecureDeleteOutcome {
    Deleted,
    NotFound,
    Failed { message: String },
}

pub trait Host: Send + Sync {
    fn log(&self, level: LogLevel, tag: &str, message: &str);
    /// The most verbose level the host will keep; lets callers skip building messages.
    fn log_level(&self) -> LogLevel;
    fn secure_read(&self, request: &SecureReadRequest) -> SecureReadOutcome;
    fn secure_write(&self, request: &SecureWriteRequest) -> SecureWriteOutcome {
        let _ = request;
        SecureWriteOutcome::Failed { message: "this host has no credential store".into() }
    }
    fn secure_delete(&self, request: &SecureDeleteRequest) -> SecureDeleteOutcome {
        let _ = request;
        SecureDeleteOutcome::Failed { message: "this host has no credential store".into() }
    }
    /// Whether an item exists, from its attributes only (never reads the secret or prompts).
    /// `None` when the store cannot tell.
    fn secure_exists(&self, service: &str) -> Option<bool> {
        let _ = service;
        None
    }
    /// An environment variable as the user's login shell exports it. A GUI app launched from the
    /// Dock does not inherit the shell environment, so the macOS host answers from the environment
    /// it captured at launch; other hosts read the process environment.
    fn env_var(&self, name: &str) -> Option<String> {
        std::env::var(name).ok().filter(|v| !v.is_empty())
    }
}

/// Default host for tests and the CLI: logs to stderr, has no credential store.
pub struct StderrHost {
    pub level: LogLevel,
}

impl Host for StderrHost {
    fn log(&self, level: LogLevel, tag: &str, message: &str) {
        let label = match level {
            LogLevel::Error => "ERROR",
            LogLevel::Warn => "WARN",
            LogLevel::Info => "INFO",
            LogLevel::Debug => "DEBUG",
        };
        eprintln!("[{label}] [{tag}] {message}");
    }

    fn log_level(&self) -> LogLevel {
        self.level
    }

    fn secure_read(&self, _request: &SecureReadRequest) -> SecureReadOutcome {
        SecureReadOutcome::NotFound
    }
}

fn host_slot() -> &'static RwLock<Arc<dyn Host>> {
    static SLOT: OnceLock<RwLock<Arc<dyn Host>>> = OnceLock::new();
    SLOT.get_or_init(|| RwLock::new(Arc::new(StderrHost { level: LogLevel::Warn })))
}

pub fn set_host(host: Arc<dyn Host>) {
    *host_slot().write().unwrap_or_else(|e| e.into_inner()) = host;
}

#[cfg(test)]
std::thread_local! {
    static TEST_HOST: std::cell::RefCell<Option<Arc<dyn Host>>> = const { std::cell::RefCell::new(None) };
}

/// Temporarily override `host()` on the current thread for unit tests.
#[cfg(test)]
pub fn with_test_host<R>(host: Arc<dyn Host>, f: impl FnOnce() -> R) -> R {
    struct Reset(Option<Arc<dyn Host>>);
    impl Drop for Reset {
        fn drop(&mut self) {
            TEST_HOST.with(|slot| *slot.borrow_mut() = self.0.take());
        }
    }
    let prev = TEST_HOST.with(|slot| slot.borrow_mut().replace(host));
    let _reset = Reset(prev);
    f()
}

pub fn host() -> Arc<dyn Host> {
    #[cfg(test)]
    if let Some(h) = TEST_HOST.with(|slot| slot.borrow().clone()) {
        return h;
    }
    host_slot().read().unwrap_or_else(|e| e.into_inner()).clone()
}

pub fn env_var(name: &str) -> Option<String> {
    host().env_var(name)
}

pub fn secure_read(request: &SecureReadRequest) -> SecureReadOutcome {
    host().secure_read(request)
}

pub fn secure_write(request: &SecureWriteRequest) -> SecureWriteOutcome {
    host().secure_write(request)
}

pub fn secure_delete(request: &SecureDeleteRequest) -> SecureDeleteOutcome {
    host().secure_delete(request)
}

pub fn secure_exists(service: &str) -> Option<bool> {
    host().secure_exists(service)
}

pub fn log_enabled(level: LogLevel) -> bool {
    level <= host().log_level()
}

/// Log through the host. Every message is redacted here, so a host without its own redaction
/// (the Windows app, the CLI) never writes a secret or a home-directory path.
pub fn log(level: LogLevel, tag: &str, message: &str) {
    let host = host();
    if level <= host.log_level() {
        host.log(level, tag, &crate::redact::redact_log_message(message));
    }
}

/// `qlog!(Info, "refresh", "devin ok ({}ms)", ms)` — formats only when the level is enabled.
#[macro_export]
macro_rules! qlog {
    ($level:ident, $tag:expr, $($arg:tt)+) => {{
        if $crate::host::log_enabled($crate::host::LogLevel::$level) {
            $crate::host::log($crate::host::LogLevel::$level, &$tag, &format!($($arg)+));
        }
    }};
}

/// Per-provider tag helpers matching Swift `LogTag.plugin` / `LogTag.auth`.
pub fn plugin_tag(id: &str) -> String {
    format!("plugin:{id}")
}

pub fn auth_tag(id: &str) -> String {
    format!("auth:{id}")
}

/// Swift `DiagnosticGate`: log a failure once until it clears, so a persistent problem writes one
/// line instead of one per refresh.
pub mod diagnostic_gate {
    use std::collections::HashSet;
    use std::sync::{Mutex, OnceLock};

    fn keys() -> &'static Mutex<HashSet<String>> {
        static KEYS: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
        KEYS.get_or_init(|| Mutex::new(HashSet::new()))
    }

    pub fn log_once(key: &str, emit: impl FnOnce()) {
        let first = keys().lock().unwrap_or_else(|e| e.into_inner()).insert(key.to_string());
        if first {
            emit();
        }
    }

    pub fn clear(key: &str) {
        keys().lock().unwrap_or_else(|e| e.into_inner()).remove(key);
    }

    pub fn clear_prefix(prefix: &str) {
        keys().lock().unwrap_or_else(|e| e.into_inner()).retain(|k| !k.starts_with(prefix));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn secure_requests_use_the_host_wire_format() {
        let mut request = SecureReadRequest::silent("Claude Code-credentials", SecureAccount::Any, "claude");
        assert_eq!(
            serde_json::to_value(&request).unwrap(),
            serde_json::json!({"service": "Claude Code-credentials", "provider": "claude", "allowInteraction": false})
        );
        request.account = SecureAccount::Named("antigravity".into());
        request.recheck_blocked_silently = true;
        request.request_id = Some(4);
        let value = serde_json::to_value(&request).unwrap();
        assert_eq!(value["account"], serde_json::json!({"kind": "named", "name": "antigravity"}));
        assert_eq!(value["recheckBlockedSilently"], true);
        assert_eq!(serde_json::from_value::<SecureReadRequest>(value).unwrap(), request);

        let write = SecureWriteRequest {
            service: "s".into(),
            account: SecureAccount::CurrentUser,
            provider: "cursor".into(),
            value: "v".into(),
        };
        assert_eq!(serde_json::to_value(&write).unwrap()["account"], serde_json::json!({"kind": "currentUser"}));
        let outcome: SecureReadOutcome = serde_json::from_str(r#"{"status":"found","value":"x"}"#).unwrap();
        assert_eq!(outcome, SecureReadOutcome::Found { value: "x".into() });
        let outcome: SecureReadOutcome = serde_json::from_str(r#"{"status":"deferred"}"#).unwrap();
        assert_eq!(outcome, SecureReadOutcome::Deferred);
        let delete = SecureDeleteRequest {
            service: "s".into(),
            account: SecureAccount::Named("acct".into()),
            provider: "openrouter".into(),
        };
        assert_eq!(serde_json::to_value(&delete).unwrap()["account"], serde_json::json!({"kind": "named", "name": "acct"}));
        let deleted: SecureDeleteOutcome = serde_json::from_str(r#"{"status":"deleted"}"#).unwrap();
        assert_eq!(deleted, SecureDeleteOutcome::Deleted);
    }
}
