//! Grok CLI auth store (`~/.grok/auth.json`) with conflict-safe OAuth rotation.

use crate::host::{auth_tag, diagnostic_gate};
use crate::model::ErrorCategory;
use crate::parse;
use crate::paths;
use crate::qlog;
use crate::time;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub const ID: &str = "grok";
pub const DEFAULT_CLIENT_ID: &str = "b1a00492-073a-47ea-816f-4c329264a828";
pub const REFRESH_BUFFER_SECS: f64 = 5.0 * 60.0;

pub const NOT_LOGGED_IN_MSG: &str = "Grok not logged in. Run `grok login`.";
pub const INVALID_AUTH_MSG: &str = "Grok auth invalid. Run `grok login` again.";
pub const EXPIRED_MSG: &str = "Grok auth expired. Run `grok login` again.";
pub const CREDENTIALS_UNREADABLE_MSG: &str =
    "QuotaBar couldn't read Grok CLI credentials at ~/.grok/auth.json. Check the file permissions, then refresh again.";
pub const AUTH_CONFLICT_MSG: &str =
    "Grok login changed while the token was refreshing. Refresh again to load the current account.";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct GrokAuthEntry {
    #[serde(default)]
    pub key: Option<String>,
    #[serde(default)]
    pub refresh_token: Option<String>,
    #[serde(default)]
    pub refresh: Option<String>,
    #[serde(default)]
    pub id_token: Option<String>,
    #[serde(default)]
    pub expires_at: Option<String>,
    #[serde(default)]
    pub expires: Option<String>,
    #[serde(default)]
    pub oidc_client_id: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GrokAuthState {
    pub auth: BTreeMap<String, GrokAuthEntry>,
    pub entry_key: String,
    pub entry: GrokAuthEntry,
    pub token: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GrokAuthError {
    NotLoggedIn,
    InvalidAuth,
    Expired,
    CredentialsUnreadable,
    AuthConflict,
}

impl GrokAuthError {
    pub fn message(self) -> &'static str {
        match self {
            GrokAuthError::NotLoggedIn => NOT_LOGGED_IN_MSG,
            GrokAuthError::InvalidAuth => INVALID_AUTH_MSG,
            GrokAuthError::Expired => EXPIRED_MSG,
            GrokAuthError::CredentialsUnreadable => CREDENTIALS_UNREADABLE_MSG,
            GrokAuthError::AuthConflict => AUTH_CONFLICT_MSG,
        }
    }

    pub fn category(self) -> ErrorCategory {
        match self {
            GrokAuthError::NotLoggedIn => ErrorCategory::NotLoggedIn,
            GrokAuthError::InvalidAuth => ErrorCategory::AuthInvalid,
            GrokAuthError::Expired | GrokAuthError::AuthConflict => ErrorCategory::AuthExpired,
            GrokAuthError::CredentialsUnreadable => ErrorCategory::CredentialAccess,
        }
    }
}

#[derive(Clone, Debug)]
pub struct GrokAuthStore {
    fixed_path: Option<PathBuf>,
}

impl GrokAuthStore {
    pub fn live() -> Self {
        GrokAuthStore { fixed_path: None }
    }

    pub fn at(path: PathBuf) -> Self {
        GrokAuthStore { fixed_path: Some(path) }
    }

    pub fn auth_path(&self) -> PathBuf {
        self.fixed_path.clone().unwrap_or_else(|| paths::expand_home("~/.grok/auth.json"))
    }

    pub fn load_auth_candidates(&self) -> Result<Vec<GrokAuthState>, GrokAuthError> {
        let path = self.auth_path();
        if !path.exists() {
            diagnostic_gate::clear("auth.grok.auth-file-read");
            return Err(GrokAuthError::NotLoggedIn);
        }
        let text = match std::fs::read_to_string(&path) {
            Ok(t) => {
                diagnostic_gate::clear("auth.grok.auth-file-read");
                t
            }
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                diagnostic_gate::clear("auth.grok.auth-file-read");
                return Err(GrokAuthError::NotLoggedIn);
            }
            Err(_) => {
                diagnostic_gate::log_once("auth.grok.auth-file-read", || {
                    qlog!(Error, auth_tag(ID), "Grok auth file read failed");
                });
                return Err(GrokAuthError::CredentialsUnreadable);
            }
        };
        let Some(auth) = parse_auth(&text) else {
            return Err(GrokAuthError::InvalidAuth);
        };
        let candidates: Vec<GrokAuthState> = auth
            .iter()
            .filter_map(|(k, e)| {
                let token = trimmed(e.key.as_deref())?;
                Some(GrokAuthState {
                    auth: auth.clone(),
                    entry_key: k.clone(),
                    entry: e.clone(),
                    token,
                })
            })
            .collect();
        if candidates.is_empty() {
            return Err(GrokAuthError::InvalidAuth);
        }
        Ok(candidates)
    }

    pub fn save_replacing(&self, state: &GrokAuthState, original: &GrokAuthState) -> Result<(), GrokAuthError> {
        if state.entry_key != original.entry_key {
            return Err(GrokAuthError::AuthConflict);
        }
        let Some(existing_text) = self.read_auth_text_for_save()? else {
            return Err(GrokAuthError::AuthConflict);
        };
        let Some(parsed) = parse_auth(&existing_text) else {
            return Err(GrokAuthError::AuthConflict);
        };
        if parsed.get(&original.entry_key) != Some(&original.entry) {
            return Err(GrokAuthError::AuthConflict);
        }
        self.save_with_existing(state, Some(&existing_text))
    }

    pub fn save(&self, state: &GrokAuthState) -> Result<(), GrokAuthError> {
        let existing = self.read_auth_text_for_save()?;
        self.save_with_existing(state, existing.as_deref())
    }

    fn read_auth_text_for_save(&self) -> Result<Option<String>, GrokAuthError> {
        let path = self.auth_path();
        if !path.exists() {
            diagnostic_gate::clear("auth.grok.auth-file-read");
            return Ok(None);
        }
        match std::fs::read_to_string(&path) {
            Ok(t) => {
                diagnostic_gate::clear("auth.grok.auth-file-read");
                Ok(Some(t))
            }
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(_) => {
                diagnostic_gate::log_once("auth.grok.auth-file-read", || {
                    qlog!(Error, auth_tag(ID), "Grok auth file read failed while saving");
                });
                Err(GrokAuthError::CredentialsUnreadable)
            }
        }
    }

    fn save_with_existing(&self, state: &GrokAuthState, existing_text: Option<&str>) -> Result<(), GrokAuthError> {
        let mut auth_object: Map<String, Value> = match existing_text {
            Some(text) => serde_json::from_str::<Value>(text)
                .ok()
                .and_then(|v| v.as_object().cloned())
                .ok_or(GrokAuthError::InvalidAuth)?,
            None => serde_json::to_value(&state.auth)
                .ok()
                .and_then(|v| v.as_object().cloned())
                .ok_or(GrokAuthError::InvalidAuth)?,
        };
        let mut entry_obj = auth_object
            .get(&state.entry_key)
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default();
        if let Some(ref key) = state.entry.key {
            entry_obj.insert("key".into(), Value::String(key.clone()));
        }
        if let Some(ref rt) = state.entry.refresh_token {
            entry_obj.insert("refresh_token".into(), Value::String(rt.clone()));
        }
        if let Some(ref id_tok) = state.entry.id_token {
            entry_obj.insert("id_token".into(), Value::String(id_tok.clone()));
        }
        if let Some(ref exp) = state.entry.expires_at {
            entry_obj.insert("expires_at".into(), Value::String(exp.clone()));
        }
        auth_object.insert(state.entry_key.clone(), Value::Object(entry_obj));

        let path = self.auth_path();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|_| GrokAuthError::InvalidAuth)?;
        }
        let encoded = serde_json::to_vec_pretty(&Value::Object(auth_object)).map_err(|_| GrokAuthError::InvalidAuth)?;
        write_atomic(&path, &encoded).map_err(|_| GrokAuthError::CredentialsUnreadable)
    }

    pub fn needs_refresh(&self, entry: &GrokAuthEntry, token: &str, now: f64) -> bool {
        let entry_due = entry_expires_at(entry).is_some_and(|exp| exp - now <= REFRESH_BUFFER_SECS);
        let token_due = token_expires_at(token).is_some_and(|exp| exp - now <= REFRESH_BUFFER_SECS);
        entry_due || token_due
    }

    pub fn is_expired(&self, entry: &GrokAuthEntry, token: &str, now: f64) -> bool {
        let Some(exp) = token_expires_at(token).or_else(|| entry_expires_at(entry)) else {
            return false;
        };
        now >= exp
    }

    pub fn refresh_token(&self, entry: &GrokAuthEntry) -> Option<String> {
        trimmed(entry.refresh_token.as_deref()).or_else(|| trimmed(entry.refresh.as_deref()))
    }

    pub fn client_id(&self, entry_key: &str, entry: &GrokAuthEntry) -> String {
        if let Some(cid) = trimmed(entry.oidc_client_id.as_deref()) {
            return cid;
        }
        if let Some(last) = entry_key.split("::").last() {
            let trimmed_last = last.trim();
            if !trimmed_last.is_empty() {
                return trimmed_last.to_string();
            }
        }
        DEFAULT_CLIENT_ID.to_string()
    }
}

pub fn token_expires_at(token: &str) -> Option<f64> {
    let payload = parse::jwt_payload(token)?;
    parse::number(payload.get("exp"))
}

fn entry_expires_at(entry: &GrokAuthEntry) -> Option<f64> {
    if let Some(s) = trimmed(entry.expires_at.as_deref()) {
        if let Some(ts) = time::parse_iso8601(&s) {
            return Some(ts);
        }
    }
    if let Some(s) = trimmed(entry.expires.as_deref()) {
        if let Some(ts) = time::parse_iso8601(&s) {
            return Some(ts);
        }
    }
    None
}

pub fn parse_auth(text: &str) -> Option<BTreeMap<String, GrokAuthEntry>> {
    serde_json::from_str::<BTreeMap<String, GrokAuthEntry>>(text).ok()
}

fn trimmed(value: Option<&str>) -> Option<String> {
    let t = value?.trim();
    (!t.is_empty()).then(|| t.to_string())
}

fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let dir = path.parent().unwrap_or_else(|| Path::new("."));
    let mut tmp = tempfile::NamedTempFile::new_in(dir)?;
    use std::io::Write;
    tmp.write_all(bytes)?;
    tmp.flush()?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = tmp.as_file().set_permissions(std::fs::Permissions::from_mode(0o600));
    }
    tmp.persist(path).map_err(|e| e.error)?;
    Ok(())
}
