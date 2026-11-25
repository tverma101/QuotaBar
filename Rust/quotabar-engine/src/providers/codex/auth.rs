//! Codex CLI credentials (Swift `CodexAuthStore`): `auth.json` homes and the `Codex Auth` Keychain
//! item, account-identity verification, and rotation-safe persistence.

use crate::host::{
    self, SecureAccount, SecureReadOutcome, SecureReadRequest, SecureWriteOutcome,
    SecureWriteRequest,
};
use crate::paths;
use crate::providers::private_file;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine as _;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

pub const ID: &str = "codex";
pub const KEYCHAIN_SERVICE: &str = "Codex Auth";
pub const ACCESS_TOKEN_REFRESH_WINDOW: f64 = 5.0 * 60.0;

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CodexTokens {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub access_token: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refresh_token: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id_token: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account_id: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CodexAuth {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tokens: Option<CodexTokens>,
    #[serde(
        default,
        rename = "last_refresh",
        skip_serializing_if = "Option::is_none"
    )]
    pub last_refresh: Option<String>,
    #[serde(
        default,
        rename = "OPENAI_API_KEY",
        skip_serializing_if = "Option::is_none"
    )]
    pub api_key: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum CodexAuthSource {
    File(PathBuf),
    Keychain(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CodexAuthState {
    pub auth: CodexAuth,
    pub source: CodexAuthSource,
}

impl CodexAuthState {
    pub fn has_usable_access_token(&self) -> bool {
        self.auth
            .tokens
            .as_ref()
            .and_then(|t| t.access_token.as_deref())
            .is_some_and(|v| !v.is_empty())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CodexAuthError {
    NotLoggedIn,
    CredentialPermissionRequired,
    CredentialsUnreadable,
    SessionExpired,
    TokenConflict,
    TokenRevoked,
    TokenExpired,
    UsageApiKey,
    InvalidAuthPayload,
}

impl CodexAuthError {
    pub fn message(self) -> &'static str {
        match self {
            CodexAuthError::NotLoggedIn => "Not logged in. Run `codex` to authenticate.",
            CodexAuthError::CredentialPermissionRequired => {
                "macOS needs permission to read your Codex Keychain item. Refresh to be asked once, then choose Always Allow."
            }
            CodexAuthError::CredentialsUnreadable => {
                "QuotaBar found Codex credential data but couldn't read it. Check file permissions and that your login Keychain is unlocked, then refresh again."
            }
            CodexAuthError::SessionExpired => "Session expired. Run `codex` to log in again.",
            CodexAuthError::TokenConflict => "Token conflict. Run `codex` to log in again.",
            CodexAuthError::TokenRevoked => "Token revoked. Run `codex` to log in again.",
            CodexAuthError::TokenExpired => "Token expired. Run `codex` to log in again.",
            CodexAuthError::UsageApiKey => "Usage not available for API key.",
            CodexAuthError::InvalidAuthPayload => "Codex auth data is invalid.",
        }
    }

    pub fn allows_auth_fallback(self) -> bool {
        matches!(
            self,
            CodexAuthError::SessionExpired
                | CodexAuthError::TokenConflict
                | CodexAuthError::TokenRevoked
                | CodexAuthError::TokenExpired
        )
    }
}

pub type EnvLookup = Arc<dyn Fn(&str) -> Option<String> + Send + Sync>;

pub struct CodexAuthStore {
    pub home: PathBuf,
    pub env: EnvLookup,
    pub expected_identity_key: Option<String>,
    pub candidate_auth_homes: Vec<PathBuf>,
    pub additional_auth_homes: Vec<PathBuf>,
}

impl CodexAuthStore {
    pub fn live(
        expected_identity_key: Option<String>,
        candidate_auth_homes: Vec<String>,
        additional_auth_homes: Vec<String>,
    ) -> Self {
        Self::new(
            paths::home(),
            Arc::new(host::env_var),
            expected_identity_key,
            candidate_auth_homes,
            additional_auth_homes,
        )
    }

    pub fn new(
        home: PathBuf,
        env: EnvLookup,
        expected_identity_key: Option<String>,
        candidate_auth_homes: Vec<String>,
        additional_auth_homes: Vec<String>,
    ) -> Self {
        let absolute = |value: String| {
            let expanded = paths::expand_home(value.trim_end_matches('/'));
            expanded.to_string_lossy().into_owned()
        };
        CodexAuthStore {
            home,
            env,
            expected_identity_key: normalized_identity_key(expected_identity_key.as_deref()),
            candidate_auth_homes: candidate_auth_homes
                .into_iter()
                .map(absolute)
                .map(PathBuf::from)
                .collect(),
            additional_auth_homes: additional_auth_homes
                .into_iter()
                .map(absolute)
                .map(PathBuf::from)
                .collect(),
        }
    }

    pub fn codex_home(&self) -> Option<String> {
        (self.env)("CODEX_HOME")
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty())
    }

    pub fn auth_paths(&self) -> Vec<PathBuf> {
        let mut seen = std::collections::HashSet::new();
        let mut paths = Vec::new();
        if !self.candidate_auth_homes.is_empty() {
            for home in &self.candidate_auth_homes {
                let path = home.join("auth.json");
                if seen.insert(path.clone()) {
                    paths.push(path);
                }
            }
            return paths;
        }
        let primary: Vec<PathBuf> = match self.codex_home() {
            Some(home) => vec![PathBuf::from(home).join("auth.json")],
            None => [self.home.join(".config/codex"), self.home.join(".codex")]
                .into_iter()
                .map(|home| home.join("auth.json"))
                .collect(),
        };
        for path in primary.into_iter().chain(
            self.additional_auth_homes
                .iter()
                .map(|h| h.join("auth.json")),
        ) {
            if seen.insert(path.clone()) {
                paths.push(path);
            }
        }
        paths
    }

    pub fn load_auth_candidates(&self) -> Result<Vec<CodexAuthState>, CodexAuthError> {
        let mut candidates = Vec::new();
        let mut first_error = None;
        for path in self.auth_paths() {
            match self.load_auth(&path) {
                Ok(Some(candidate)) => candidates.push(candidate),
                Ok(None) => {}
                Err(error) => {
                    if first_error.is_none() {
                        first_error = Some(error);
                    }
                }
            }
        }
        if candidates.is_empty() {
            if let Some(error) = first_error {
                return Err(error);
            }
        }
        if self.candidate_auth_homes.len() > 1 {
            candidates.sort_by(|a, b| {
                credential_freshness(b)
                    .partial_cmp(&credential_freshness(a))
                    .unwrap_or(std::cmp::Ordering::Equal)
            });
        }
        Ok(candidates)
    }

    pub fn load_auth(&self, path: &Path) -> Result<Option<CodexAuthState>, CodexAuthError> {
        let text = match std::fs::read_to_string(path) {
            Ok(text) => text,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err(CodexAuthError::CredentialsUnreadable),
        };
        let auth = parse_auth(&text).ok_or(CodexAuthError::InvalidAuthPayload)?;
        if !has_token_like_auth(&auth) || !self.matches_expected_account(&auth) {
            return Ok(None);
        }
        Ok(Some(CodexAuthState {
            auth,
            source: CodexAuthSource::File(path.to_path_buf()),
        }))
    }

    pub fn load_keychain_auth(
        &self,
        ctx: Option<&crate::context::RefreshContext>,
    ) -> Result<Option<CodexAuthState>, CodexAuthError> {
        let mut permission_required = false;
        let mut unreadable = false;
        for account in self.keychain_account_candidates() {
            match self.load_keychain_account(&account, ctx) {
                Ok(Some(state)) => return Ok(Some(state)),
                Ok(None) => {}
                Err(CodexAuthError::CredentialPermissionRequired) => permission_required = true,
                Err(CodexAuthError::CredentialsUnreadable) => unreadable = true,
                Err(_) => unreadable = true,
            }
        }
        if permission_required {
            return Err(CodexAuthError::CredentialPermissionRequired);
        }
        if unreadable {
            return Err(CodexAuthError::CredentialsUnreadable);
        }
        Ok(None)
    }

    pub fn load_keychain_account(
        &self,
        account: &str,
        ctx: Option<&crate::context::RefreshContext>,
    ) -> Result<Option<CodexAuthState>, CodexAuthError> {
        let request = match ctx {
            Some(ctx) => SecureReadRequest::for_refresh(
                KEYCHAIN_SERVICE,
                SecureAccount::Named(account.into()),
                ID,
                ctx,
            ),
            None => SecureReadRequest::silent(
                KEYCHAIN_SERVICE,
                SecureAccount::Named(account.into()),
                ID,
            ),
        };
        let value = match host::secure_read(&request) {
            SecureReadOutcome::Found { value } => value,
            SecureReadOutcome::NotFound => return Ok(None),
            SecureReadOutcome::InteractionRequired
            | SecureReadOutcome::Denied
            | SecureReadOutcome::Deferred => {
                return Err(CodexAuthError::CredentialPermissionRequired)
            }
            SecureReadOutcome::Cancelled => return Err(CodexAuthError::SessionExpired),
            SecureReadOutcome::Failed { .. } => return Err(CodexAuthError::CredentialsUnreadable),
        };
        let Some(auth) = parse_auth(&value) else {
            return Ok(None);
        };
        if !has_token_like_auth(&auth) || !self.matches_expected_account(&auth) {
            return Ok(None);
        }
        Ok(Some(CodexAuthState {
            auth,
            source: CodexAuthSource::Keychain(account.to_string()),
        }))
    }

    pub fn save(
        &self,
        state: &CodexAuthState,
        replacing: &CodexAuthState,
    ) -> Result<(), CodexAuthError> {
        if state.source != replacing.source {
            return Err(CodexAuthError::TokenConflict);
        }
        let live = match &replacing.source {
            CodexAuthSource::File(path) => self.load_auth(path)?,
            CodexAuthSource::Keychain(account) => self.load_keychain_account(account, None)?,
        };
        let Some(mut live) = live else {
            return Err(CodexAuthError::TokenConflict);
        };
        if live.auth.tokens != replacing.auth.tokens || !self.matches_expected_account(&live.auth) {
            return Err(CodexAuthError::TokenConflict);
        }
        live.auth.tokens = state.auth.tokens.clone();
        live.auth.last_refresh = state.auth.last_refresh.clone();
        self.write(&live)
    }

    fn write(&self, state: &CodexAuthState) -> Result<(), CodexAuthError> {
        let text = match &state.source {
            CodexAuthSource::File(_) => serde_json::to_string_pretty(&state.auth)
                .map_err(|_| CodexAuthError::InvalidAuthPayload)?,
            CodexAuthSource::Keychain(_) => serde_json::to_string(&state.auth)
                .map_err(|_| CodexAuthError::InvalidAuthPayload)?,
        };
        match &state.source {
            CodexAuthSource::File(path) => private_file::write_private_file(path, text.as_bytes())
                .map_err(|_| CodexAuthError::CredentialsUnreadable),
            CodexAuthSource::Keychain(account) => {
                let request = SecureWriteRequest {
                    service: KEYCHAIN_SERVICE.into(),
                    account: SecureAccount::Named(account.clone()),
                    provider: ID.into(),
                    value: text,
                };
                match host::secure_write(&request) {
                    SecureWriteOutcome::Written => Ok(()),
                    SecureWriteOutcome::Failed { .. } => Err(CodexAuthError::CredentialsUnreadable),
                }
            }
        }
    }

    pub fn needs_refresh(&self, auth: &CodexAuth) -> bool {
        if let Some(token) = auth.tokens.as_ref().and_then(|t| t.access_token.as_deref()) {
            if let Some(expires_at) = access_token_expires_at(token) {
                return expires_at - now_seconds() <= ACCESS_TOKEN_REFRESH_WINDOW;
            }
        }
        let Some(last_refresh) = auth.last_refresh.as_deref() else {
            return false;
        };
        let Some(date) = crate::time::parse_iso8601(last_refresh) else {
            return false;
        };
        now_seconds() - date > 8.0 * 24.0 * 3600.0
    }

    pub fn keychain_account_candidates(&self) -> Vec<String> {
        match self.codex_home() {
            Some(home) => vec![keychain_account_for_codex_home(Path::new(&home))],
            None => [self.home.join(".config/codex"), self.home.join(".codex")]
                .iter()
                .map(|home| keychain_account_for_codex_home(home))
                .collect(),
        }
    }

    pub fn matches_expected_account(&self, auth: &CodexAuth) -> bool {
        if has_identity_conflict(auth) {
            return false;
        }
        let Some(expected) = self.expected_identity_key.as_deref() else {
            return true;
        };
        let Some(actual) = Self::account_identity(auth) else {
            return false;
        };
        actual.eq_ignore_ascii_case(expected)
    }

    pub fn account_identity(auth: &CodexAuth) -> Option<String> {
        if has_identity_conflict(auth) {
            return None;
        }
        identity_parts(auth).0.or(identity_parts(auth).1)
    }
}

pub fn keychain_account_for_codex_home(home: &Path) -> String {
    let expanded = if home.is_absolute() {
        home.to_path_buf()
    } else {
        paths::expand_home(&home.to_string_lossy())
    };
    let canonical = std::fs::canonicalize(&expanded).unwrap_or(expanded);
    let digest = Sha256::digest(canonical.to_string_lossy().as_bytes());
    let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
    format!("cli|{}", &hex[..16])
}

fn normalized_identity_key(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(str::to_lowercase)
}

fn now_seconds() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

fn credential_freshness(state: &CodexAuthState) -> (f64, f64) {
    let expiry = state
        .auth
        .tokens
        .as_ref()
        .and_then(|t| t.access_token.as_deref())
        .and_then(access_token_expires_at)
        .unwrap_or(-1.0);
    let refreshed = state
        .auth
        .last_refresh
        .as_deref()
        .and_then(crate::time::parse_iso8601)
        .unwrap_or(-1.0);
    (expiry, refreshed)
}

pub fn access_token_expires_at(token: &str) -> Option<f64> {
    let payload = jwt_payload(token)?;
    payload.get("exp").and_then(Value::as_f64)
}

fn jwt_payload(token: &str) -> Option<Value> {
    let part = token.split('.').nth(1)?;
    let bytes = URL_SAFE_NO_PAD
        .decode(part)
        .or_else(|_| {
            let mut padded = part.to_string();
            while padded.len() % 4 != 0 {
                padded.push('=');
            }
            base64::engine::general_purpose::URL_SAFE.decode(padded)
        })
        .ok()?;
    serde_json::from_slice(&bytes).ok()
}

fn parse_auth(text: &str) -> Option<CodexAuth> {
    if let Ok(auth) = serde_json::from_str::<CodexAuth>(text) {
        return Some(auth);
    }
    let mut hex = text.trim();
    if let Some(stripped) = hex.strip_prefix("0x").or_else(|| hex.strip_prefix("0X")) {
        hex = stripped;
    }
    if hex.is_empty() || hex.len() % 2 != 0 || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let mut bytes = Vec::with_capacity(hex.len() / 2);
    let mut index = 0;
    while index < hex.len() {
        bytes.push(u8::from_str_radix(&hex[index..index + 2], 16).ok()?);
        index += 2;
    }
    serde_json::from_slice(&bytes).ok()
}

pub fn has_token_like_auth(auth: &CodexAuth) -> bool {
    auth.tokens
        .as_ref()
        .and_then(|t| t.access_token.as_deref())
        .is_some_and(|v| !v.is_empty())
        || auth.api_key.as_deref().is_some_and(|v| !v.is_empty())
}

fn identity_parts(auth: &CodexAuth) -> (Option<String>, Option<String>) {
    let account_id = auth
        .tokens
        .as_ref()
        .and_then(|t| t.account_id.as_deref())
        .and_then(|v| normalized_identity_key(Some(v)));
    let id_token_id = auth
        .tokens
        .as_ref()
        .and_then(|t| t.id_token.as_deref())
        .and_then(jwt_payload)
        .and_then(|payload| {
            payload
                .get("https://api.openai.com/auth")
                .and_then(Value::as_object)
                .and_then(|claim| claim.get("chatgpt_account_id"))
                .or_else(|| payload.get("chatgpt_account_id"))
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .and_then(|v| normalized_identity_key(Some(&v)));
    (account_id, id_token_id)
}

fn has_identity_conflict(auth: &CodexAuth) -> bool {
    let (account_id, id_token_id) = identity_parts(auth);
    matches!((account_id, id_token_id), (Some(a), Some(b)) if !a.eq_ignore_ascii_case(&b))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn store(expected: Option<&str>) -> CodexAuthStore {
        CodexAuthStore::new(
            PathBuf::from("/tmp/none"),
            Arc::new(|_| None),
            expected.map(str::to_string),
            vec![],
            vec![],
        )
    }

    #[test]
    fn parses_direct_and_hex_auth_payloads() {
        let text = r#"{"tokens":{"access_token":"a","refresh_token":"r"},"last_refresh":"2026-01-01T00:00:00Z"}"#;
        assert_eq!(
            parse_auth(text)
                .unwrap()
                .tokens
                .unwrap()
                .access_token
                .as_deref(),
            Some("a")
        );
        let hex: String = text.bytes().map(|b| format!("{b:02x}")).collect();
        assert!(parse_auth(&hex).is_some());
        assert!(parse_auth("nope").is_none());
    }

    #[test]
    fn identity_prefers_account_id_and_fails_closed_on_conflict() {
        let token = format!(
            "x.{}.y",
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(
                serde_json::to_vec(
                    &json!({"https://api.openai.com/auth": {"chatgpt_account_id": "acct-b"}})
                )
                .unwrap()
            )
        );
        let mut auth = CodexAuth {
            tokens: Some(CodexTokens {
                id_token: Some(token),
                ..Default::default()
            }),
            ..Default::default()
        };
        assert_eq!(
            CodexAuthStore::account_identity(&auth).as_deref(),
            Some("acct-b")
        );
        auth.tokens.as_mut().unwrap().account_id = Some("acct-a".into());
        assert_eq!(CodexAuthStore::account_identity(&auth), None);
        assert!(!store(Some("acct-b")).matches_expected_account(&auth));
    }

    #[test]
    fn keychain_account_is_the_first_sixteen_sha256_hex_chars() {
        let path = PathBuf::from("/tmp/quotabar-codex-home");
        let digest = Sha256::digest(path.to_string_lossy().as_bytes());
        let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(
            keychain_account_for_codex_home(&path),
            format!("cli|{}", &hex[..16])
        );
    }

    #[test]
    fn refresh_window_uses_jwt_exp_when_readable() {
        let exp = now_seconds() + 60.0;
        let token = format!(
            "x.{}.y",
            base64::engine::general_purpose::URL_SAFE_NO_PAD
                .encode(serde_json::to_vec(&json!({"exp": exp})).unwrap())
        );
        let auth = CodexAuth {
            tokens: Some(CodexTokens {
                access_token: Some(token),
                ..Default::default()
            }),
            ..Default::default()
        };
        assert!(store(None).needs_refresh(&auth));
        assert!(!store(None).needs_refresh(&CodexAuth::default()));
    }
}
