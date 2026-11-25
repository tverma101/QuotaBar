//! Cursor credential resolution across Cursor's SQLite state DB and macOS Keychain (`CursorAuthStore.swift`).

use crate::context::RefreshContext;
use crate::host::{
    self, auth_tag, diagnostic_gate, SecureAccount, SecureReadOutcome, SecureReadRequest,
    SecureWriteOutcome, SecureWriteRequest,
};
use crate::parse;
use crate::{paths, qlog};
use rusqlite::{Connection, OpenFlags};
use sha2::{Digest, Sha256};
#[cfg(test)]
use std::collections::HashMap;
use std::fmt::Write as _;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
#[cfg(test)]
use std::sync::Mutex;

pub const ACCESS_TOKEN_KEY: &str = "cursorAuth/accessToken";
pub const REFRESH_TOKEN_KEY: &str = "cursorAuth/refreshToken";
pub const MEMBERSHIP_TYPE_KEY: &str = "cursorAuth/stripeMembershipType";
pub const KEYCHAIN_ACCESS_SERVICE: &str = "cursor-access-token";
pub const KEYCHAIN_REFRESH_SERVICE: &str = "cursor-refresh-token";

const STATE_DB_RELATIVE: &str = "Cursor/User/globalStorage/state.vscdb";
const REFRESH_LEEWAY_SECS: f64 = 300.0;

static UNRESOLVED_COUNTER: AtomicU64 = AtomicU64::new(1);

pub fn new_unresolved_identity_key() -> String {
    let seq = UNRESOLVED_COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("cursor-unresolved-{seq}")
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CursorAuthSource {
    Sqlite,
    Keychain,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CursorAuthState {
    pub access_token: String,
    pub refresh_token: Option<String>,
    pub membership_type: Option<String>,
    pub source: CursorAuthSource,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CursorAuthError {
    NotLoggedIn,
    CredentialPermissionRequired,
    CredentialsUnreadable,
    SessionExpired,
    TokenExpired,
    Cancelled,
}

impl CursorAuthError {
    pub fn message(&self) -> &'static str {
        match self {
            CursorAuthError::NotLoggedIn => "Not logged in. Sign in via Cursor app or run `agent login`.",
            CursorAuthError::CredentialPermissionRequired => {
                "macOS needs permission to read your Cursor Keychain item. Refresh to be asked once, then choose Always Allow."
            }
            CursorAuthError::CredentialsUnreadable => {
                "QuotaBar couldn't read Cursor's local credential data. Check access to Cursor's state database and login Keychain, then refresh again."
            }
            CursorAuthError::SessionExpired => "Session expired. Sign in via Cursor app or run `agent login`.",
            CursorAuthError::TokenExpired => "Token expired. Sign in via Cursor app or run `agent login`.",
            CursorAuthError::Cancelled => "Cancelled.",
        }
    }
}

pub trait SqlBackend: Send + Sync {
    fn query_item(&self, key: &str) -> Result<Option<String>, String>;
    fn write_access_token(&self, value: &str) -> Result<(), String>;
}

pub trait KeychainBackend: Send + Sync {
    fn read_item(
        &self,
        service: &str,
        account: SecureAccount,
        ctx: Option<&RefreshContext>,
    ) -> Result<Option<String>, CursorAuthError>;
    fn write_current_user(&self, service: &str, value: &str) -> Result<(), String>;
    fn item_exists(&self, service: &str) -> Option<bool>;
}

struct LiveSqlBackend {
    path: PathBuf,
}

impl SqlBackend for LiveSqlBackend {
    fn query_item(&self, key: &str) -> Result<Option<String>, String> {
        let escaped = key.replace('\'', "''");
        let sql = format!("SELECT value FROM ItemTable WHERE key = '{escaped}' LIMIT 1;");
        crate::sqlite::query_value_tolerating_missing_table(&self.path, &sql)
            .map_err(|e| e.to_string())
    }

    fn write_access_token(&self, value: &str) -> Result<(), String> {
        let flags = OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX;
        let conn = Connection::open_with_flags(&self.path, flags).map_err(|e| e.to_string())?;
        conn.execute(
            "INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?1, ?2)",
            [ACCESS_TOKEN_KEY, value],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }
}

struct HostKeychainBackend;

impl KeychainBackend for HostKeychainBackend {
    fn read_item(
        &self,
        service: &str,
        account: SecureAccount,
        ctx: Option<&RefreshContext>,
    ) -> Result<Option<String>, CursorAuthError> {
        let req = match ctx {
            Some(c) => SecureReadRequest::for_refresh(service, account, "cursor", c),
            None => SecureReadRequest::silent(service, account, "cursor"),
        };
        match host::secure_read(&req) {
            SecureReadOutcome::Found { value } => {
                let trimmed = value.trim();
                Ok((!trimmed.is_empty()).then(|| trimmed.to_string()))
            }
            SecureReadOutcome::NotFound => Ok(None),
            SecureReadOutcome::InteractionRequired
            | SecureReadOutcome::Denied
            | SecureReadOutcome::Deferred => Err(CursorAuthError::CredentialPermissionRequired),
            SecureReadOutcome::Cancelled => Err(CursorAuthError::Cancelled),
            SecureReadOutcome::Failed { .. } => Err(CursorAuthError::CredentialsUnreadable),
        }
    }

    fn write_current_user(&self, service: &str, value: &str) -> Result<(), String> {
        let req = SecureWriteRequest {
            service: service.to_string(),
            account: SecureAccount::CurrentUser,
            value: value.to_string(),
            provider: "cursor".to_string(),
        };
        match host::secure_write(&req) {
            SecureWriteOutcome::Written => Ok(()),
            SecureWriteOutcome::Failed { message } => Err(message),
        }
    }

    fn item_exists(&self, service: &str) -> Option<bool> {
        host::secure_exists(service)
    }
}

#[derive(Clone)]
pub struct CursorAuthStore {
    sql: Arc<dyn SqlBackend>,
    keychain: Arc<dyn KeychainBackend>,
}

impl CursorAuthStore {
    pub fn live() -> Self {
        Self::at_path(paths::platform_app_support().join(STATE_DB_RELATIVE))
    }

    pub fn at_path(db_path: PathBuf) -> Self {
        CursorAuthStore {
            sql: Arc::new(LiveSqlBackend { path: db_path }),
            keychain: Arc::new(HostKeychainBackend),
        }
    }

    pub fn with_backends(sql: Arc<dyn SqlBackend>, keychain: Arc<dyn KeychainBackend>) -> Self {
        CursorAuthStore { sql, keychain }
    }

    pub fn has_local_credentials(&self) -> bool {
        match self.read_sqlite_snapshot() {
            Ok(Some(_)) | Err(()) => return true,
            Ok(None) => {}
        }
        match self.read_keychain_item(KEYCHAIN_ACCESS_SERVICE, None) {
            Ok(Some(_))
            | Err(CursorAuthError::CredentialPermissionRequired | CursorAuthError::Cancelled) => {
                return true
            }
            Ok(None) | Err(_) => {}
        }
        self.keychain.item_exists(KEYCHAIN_ACCESS_SERVICE) == Some(true)
    }

    pub fn load_auth_state(
        &self,
        ctx: Option<&RefreshContext>,
        now: f64,
        force_keychain_refresh_read: bool,
    ) -> Result<Option<CursorAuthState>, CursorAuthError> {
        let sqlite_result = self.read_sqlite_snapshot();
        let sqlite_unreadable = sqlite_result.is_err();
        let sqlite_state = sqlite_result.ok().flatten();

        let membership = self.read_membership_type();
        let sqlite_can_auth = sqlite_state
            .as_ref()
            .is_some_and(|s| !is_token_expired(&s.access_token, now) || s.refresh_token.is_some());
        let sqlite_looks_free = membership.as_deref() == Some("free");

        if sqlite_can_auth && !sqlite_looks_free {
            return Ok(sqlite_state.map(|mut s| {
                s.membership_type = membership;
                s
            }));
        }

        let kc_ctx = if sqlite_state.is_some() { None } else { ctx };
        let kc_access = match self.read_keychain_item(KEYCHAIN_ACCESS_SERVICE, kc_ctx) {
            Ok(tok) => tok,
            Err(CursorAuthError::Cancelled) => return Err(CursorAuthError::Cancelled),
            Err(CursorAuthError::CredentialPermissionRequired) => {
                if sqlite_can_auth {
                    return Ok(sqlite_state.map(|mut s| {
                        s.membership_type = membership;
                        s
                    }));
                }
                return Err(CursorAuthError::CredentialPermissionRequired);
            }
            Err(_) => None,
        };

        let sqlite_subject = sqlite_state
            .as_ref()
            .and_then(|s| token_subject(&s.access_token));
        let kc_subject = kc_access.as_deref().and_then(token_subject);
        let subjects_differ = sqlite_looks_free
            && kc_access.is_some()
            && kc_subject.is_some()
            && sqlite_subject != kc_subject;

        if !sqlite_can_auth || subjects_differ {
            if let Some(kc_tok) = kc_access {
                let rotation_needed = force_keychain_refresh_read || needs_refresh(&kc_tok, now);
                let kc_refresh = if rotation_needed {
                    match self.read_keychain_item(KEYCHAIN_REFRESH_SERVICE, kc_ctx) {
                        Ok(r) => r,
                        Err(CursorAuthError::Cancelled) => return Err(CursorAuthError::Cancelled),
                        Err(err) => {
                            if force_keychain_refresh_read || is_token_expired(&kc_tok, now) {
                                return Err(err);
                            }
                            None
                        }
                    }
                } else {
                    None
                };
                return Ok(Some(CursorAuthState {
                    access_token: kc_tok,
                    refresh_token: kc_refresh,
                    membership_type: membership,
                    source: CursorAuthSource::Keychain,
                }));
            }
        }

        if let Some(mut s) = sqlite_state {
            s.membership_type = membership;
            return Ok(Some(s));
        }
        if sqlite_unreadable {
            return Err(CursorAuthError::CredentialsUnreadable);
        }
        Ok(None)
    }

    pub fn save_access_token(
        &self,
        new_access: &str,
        replacing: &CursorAuthState,
        now: f64,
    ) -> Result<(), CursorAuthError> {
        let current = match self.load_auth_state(None, now, false) {
            Ok(Some(c)) => c,
            Ok(None) => return Err(CursorAuthError::SessionExpired),
            Err(CursorAuthError::Cancelled) => return Err(CursorAuthError::Cancelled),
            Err(_) => return Err(CursorAuthError::SessionExpired),
        };
        if current.source != replacing.source || !same_account(&current, replacing) {
            return Err(CursorAuthError::SessionExpired);
        }
        match replacing.source {
            CursorAuthSource::Sqlite => {
                if let Err(err) = self.sql.write_access_token(new_access) {
                    diagnostic_gate::log_once("auth.cursor.persist.sqlite", || {
                        qlog!(
                            Warn,
                            auth_tag("cursor"),
                            "failed to persist Cursor SQLite token: {err}"
                        );
                    });
                    return Err(CursorAuthError::CredentialsUnreadable);
                }
            }
            CursorAuthSource::Keychain => {
                if let Err(err) = self
                    .keychain
                    .write_current_user(KEYCHAIN_ACCESS_SERVICE, new_access)
                {
                    diagnostic_gate::log_once("auth.cursor.persist.keychain", || {
                        qlog!(
                            Warn,
                            auth_tag("cursor"),
                            "failed to persist Cursor Keychain token: {err}"
                        );
                    });
                    return Err(CursorAuthError::CredentialsUnreadable);
                }
            }
        }
        Ok(())
    }

    pub fn cache_identity_key_for_launch(&self) -> String {
        let Ok(Some(mut state)) = self.read_sqlite_snapshot() else {
            return new_unresolved_identity_key();
        };
        let membership = self.read_membership_type();
        if membership.as_deref() == Some("free") {
            return new_unresolved_identity_key();
        }
        state.membership_type = membership;
        cache_identity_key(&state).unwrap_or_else(new_unresolved_identity_key)
    }

    fn read_sqlite_snapshot(&self) -> Result<Option<CursorAuthState>, ()> {
        let access = self
            .sql
            .query_item(ACCESS_TOKEN_KEY)
            .map_err(|_| ())?
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        let Some(access_token) = access else {
            return Ok(None);
        };
        let refresh_token = self
            .sql
            .query_item(REFRESH_TOKEN_KEY)
            .ok()
            .flatten()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        Ok(Some(CursorAuthState {
            access_token,
            refresh_token,
            membership_type: None,
            source: CursorAuthSource::Sqlite,
        }))
    }

    fn read_membership_type(&self) -> Option<String> {
        self.sql
            .query_item(MEMBERSHIP_TYPE_KEY)
            .ok()
            .flatten()
            .map(|s| s.trim().to_ascii_lowercase())
            .filter(|s| !s.is_empty())
    }

    fn read_keychain_item(
        &self,
        service: &str,
        ctx: Option<&RefreshContext>,
    ) -> Result<Option<String>, CursorAuthError> {
        match self
            .keychain
            .read_item(service, SecureAccount::CurrentUser, ctx)
        {
            Ok(Some(val)) => return Ok(Some(val)),
            Ok(None) => {}
            Err(CursorAuthError::Cancelled) => return Err(CursorAuthError::Cancelled),
            Err(err @ CursorAuthError::CredentialPermissionRequired) => return Err(err),
            Err(_) => {}
        }
        self.keychain.read_item(service, SecureAccount::Any, ctx)
    }
}

pub fn token_subject(token: &str) -> Option<String> {
    let payload = parse::jwt_payload(token)?;
    parse::trimmed_string(payload.get("sub"))
}

pub fn token_expiry(token: &str) -> Option<f64> {
    let payload = parse::jwt_payload(token)?;
    parse::number(payload.get("exp"))
}

pub fn is_token_expired(token: &str, now: f64) -> bool {
    token_expiry(token).is_some_and(|exp| exp <= now)
}

pub fn needs_refresh(token: &str, now: f64) -> bool {
    token_expiry(token).is_some_and(|exp| exp <= now + REFRESH_LEEWAY_SECS)
}

pub fn cache_identity_key(state: &CursorAuthState) -> Option<String> {
    if let Some(sub) = token_subject(&state.access_token) {
        return Some(format!("cursor-{}", sha256_hex(sub.as_bytes())));
    }
    let cred = state
        .refresh_token
        .as_deref()
        .unwrap_or(&state.access_token);
    (!cred.is_empty()).then(|| format!("cursor-credential-{}", sha256_hex(cred.as_bytes())))
}

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut out = String::with_capacity(digest.len() * 2);
    for b in digest {
        let _ = write!(out, "{b:02x}");
    }
    out
}

fn same_account(a: &CursorAuthState, b: &CursorAuthState) -> bool {
    match (
        token_subject(&a.access_token),
        token_subject(&b.access_token),
    ) {
        (Some(sa), Some(sb)) => sa == sb,
        (None, None) => a.access_token == b.access_token,
        _ => false,
    }
}

/// In-memory SQLite stub for unit tests (shared with `tests.rs`).
#[cfg(test)]
pub struct MemorySqlite {
    pub values: Mutex<HashMap<String, String>>,
    pub written_values: Mutex<HashMap<String, String>>,
    pub fail_reads: bool,
}

#[cfg(test)]
impl MemorySqlite {
    pub fn new(initial: HashMap<String, String>) -> Self {
        MemorySqlite {
            values: Mutex::new(initial),
            written_values: Mutex::new(HashMap::new()),
            fail_reads: false,
        }
    }
}

#[cfg(test)]
impl SqlBackend for MemorySqlite {
    fn query_item(&self, key: &str) -> Result<Option<String>, String> {
        if self.fail_reads {
            return Err("injected state database read failure".into());
        }
        Ok(self
            .values
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(key)
            .cloned())
    }

    fn write_access_token(&self, value: &str) -> Result<(), String> {
        self.values
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(ACCESS_TOKEN_KEY.into(), value.into());
        self.written_values
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(ACCESS_TOKEN_KEY.into(), value.into());
        Ok(())
    }
}
