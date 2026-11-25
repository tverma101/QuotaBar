//! Codex credential loading and conflict-safe rotation (Swift `CodexAuthStore`): `auth.json` files
//! under `CODEX_HOME` (or the default homes), and the Codex CLI's `Codex Auth` Keychain items.

use crate::context::RefreshContext;
use crate::host::{self, SecureAccount, SecureReadOutcome, SecureReadRequest, SecureWriteOutcome, SecureWriteRequest};
use crate::parse;
use crate::paths;
use crate::time;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;

pub const ID: &str = "codex";
pub const KEYCHAIN_SERVICE: &str = "Codex Auth";
/// Refresh once the access token is within this window of its JWT `exp` (the `codex` CLI's slack).
pub const ACCESS_TOKEN_REFRESH_WINDOW: f64 = 5.0 * 60.0;
const AUTH_FILE: &str = "auth.json";
const DEFAULT_AUTH_HOMES: [&str; 2] = ["~/.config/codex", "~/.codex"];

#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct CodexTokens {
    #[serde(rename = "access_token", default, skip_serializing_if = "Option::is_none")]
    pub access_token: Option<String>,
    #[serde(rename = "refresh_token", default, skip_serializing_if = "Option::is_none")]
    pub refresh_token: Option<String>,
    #[serde(rename = "id_token", default, skip_serializing_if = "Option::is_none")]
    pub id_token: Option<String>,
    #[serde(rename = "account_id", default, skip_serializing_if = "Option::is_none")]
    pub account_id: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct CodexAuth {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tokens: Option<CodexTokens>,
    #[serde(rename = "last_refresh", default, skip_serializing_if = "Option::is_none")]
    pub last_refresh: Option<String>,
    #[serde(rename = "OPENAI_API_KEY", default, skip_serializing_if = "Option::is_none")]
    pub api_key: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum CodexAuthSource {
    File(String),
    Keychain(String),
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct CodexAuthState {
    pub auth: CodexAuth,
    pub source: CodexAuthSource,
}

impl CodexAuthState {
    /// Whether this candidate carries a non-empty OAuth access token (an API-key-only `auth.json`
    /// cannot serve the usage API).
    pub fn has_usable_access_token(&self) -> bool {
        self.auth.tokens.as_ref().and_then(|t| t.access_token.as_deref()).is_some_and(|t| !t.is_empty())
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
    /// The refresh this read belonged to was cancelled (Swift `CancellationError`).
    Cancelled,
}

impl CodexAuthError {
    /// Swift `errorDescription`.
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
            CodexAuthError::Cancelled => "Refresh cancelled.",
        }
    }

    /// Swift `allowsAuthFallback`: an expired-looking credential may fall through to the next source.
    /// A Keychain ACL refusal never does (it would mask the one action that resolves it).
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

#[derive(Clone)]
pub struct CodexAuthStore {
    env: EnvLookup,
    /// When set, auth from a different ChatGPT account, or whose account id and id-token disagree,
    /// is invisible and cannot be persisted through this store.
    pub expected_identity_key: Option<String>,
    /// Every `auth.json` home already verified to hold `expected_identity_key`; when non-empty they
    /// replace the single `CODEX_HOME` path.
    pub candidate_auth_homes: Vec<String>,
    /// Extra homes tried after the primary home, in order.
    additional_auth_homes: Vec<String>,
}

impl CodexAuthStore {
    pub fn live() -> Self {
        Self::with_env(Arc::new(host::env_var))
    }

    pub fn with_env(env: EnvLookup) -> Self {
        CodexAuthStore { env, expected_identity_key: None, candidate_auth_homes: Vec::new(), additional_auth_homes: Vec::new() }
    }

    pub fn with_additional_auth_homes(mut self, homes: &[String]) -> Self {
        self.additional_auth_homes = homes.iter().map(|h| absolute_home_path(h)).collect();
        self
    }

    pub fn with_candidate_auth_homes(mut self, homes: &[String]) -> Self {
        let mut seen = std::collections::HashSet::new();
        self.candidate_auth_homes = homes.iter().filter(|h| seen.insert((*h).clone())).cloned().collect();
        self
    }

    /// Swift `scoped(to:)`: a copy bound to one account identity.
    pub fn scoped(&self, identity_key: Option<&str>) -> CodexAuthStore {
        let mut copy = self.clone();
        copy.expected_identity_key = normalized_identity_key(identity_key);
        copy
    }

    pub fn load_auth_candidates(&self) -> Result<Vec<CodexAuthState>, CodexAuthError> {
        let mut candidates = Vec::new();
        let mut first_error = None;
        for path in self.auth_paths() {
            match self.load_auth(&path) {
                Ok(Some(candidate)) => candidates.push(candidate),
                Ok(None) => {}
                Err(CodexAuthError::Cancelled) => return Err(CodexAuthError::Cancelled),
                Err(error) => {
                    first_error.get_or_insert(error);
                }
            }
        }
        if candidates.is_empty() {
            if let Some(error) = first_error {
                return Err(error);
            }
        }
        if self.candidate_auth_homes.len() > 1 {
            // Prefer the token that will live longest: homes of one account refresh independently.
            candidates.sort_by(|a, b| {
                let (fa, fb) = (self.credential_freshness(a), self.credential_freshness(b));
                fb.partial_cmp(&fa).unwrap_or(std::cmp::Ordering::Equal)
            });
        }
        Ok(candidates)
    }

    /// Access-token expiry, then the recorded refresh time; unknown values sort last.
    fn credential_freshness(&self, state: &CodexAuthState) -> (f64, f64) {
        let expiry = state
            .auth
            .tokens
            .as_ref()
            .and_then(|t| t.access_token.as_deref())
            .and_then(access_token_expires_at)
            .unwrap_or(-1.0);
        let refreshed = state.auth.last_refresh.as_deref().and_then(time::parse_iso8601).unwrap_or(-1.0);
        (expiry, refreshed)
    }

    /// Reads the credential from one auth file. `None` when the file is missing or carries no
    /// token-like auth for the expected account; read/parse failures stay actionable.
    pub fn load_auth(&self, path: &str) -> Result<Option<CodexAuthState>, CodexAuthError> {
        let text = match std::fs::read_to_string(paths::expand_home(path)) {
            Ok(text) => text,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err(CodexAuthError::CredentialsUnreadable),
        };
        let Some(auth) = parse_auth(&text) else { return Err(CodexAuthError::InvalidAuthPayload) };
        if !has_token_like_auth(&auth) || !self.matches_expected_account(&auth) {
            return Ok(None);
        }
        Ok(Some(CodexAuthState { auth, source: CodexAuthSource::File(path.to_string()) }))
    }

    /// Throws rather than returning `None` for an unreadable item: "macOS will not release this
    /// without a dialog" and "there is no credential" are different problems with different fixes.
    pub fn load_keychain_auth(&self, ctx: Option<&RefreshContext>) -> Result<Option<CodexAuthState>, CodexAuthError> {
        let (mut permission_required, mut unreadable) = (false, false);
        for account in self.keychain_account_candidates() {
            match self.load_keychain_auth_account(&account, ctx) {
                Ok(Some(state)) => return Ok(Some(state)),
                Ok(None) => {}
                Err(CodexAuthError::Cancelled) => return Err(CodexAuthError::Cancelled),
                Err(CodexAuthError::CredentialPermissionRequired) => permission_required = true,
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

    /// Reload one exact Codex CLI Keychain item (a service-only query could select another
    /// profile's credential). `ctx: None` is a silent read.
    pub fn load_keychain_auth_account(
        &self,
        account: &str,
        ctx: Option<&RefreshContext>,
    ) -> Result<Option<CodexAuthState>, CodexAuthError> {
        let request = match ctx {
            Some(ctx) => SecureReadRequest::for_refresh(KEYCHAIN_SERVICE, SecureAccount::Named(account.into()), ID, ctx),
            None => SecureReadRequest::silent(KEYCHAIN_SERVICE, SecureAccount::Named(account.into()), ID),
        };
        self.read_keychain(request, account)
    }

    /// Re-read the live credential before persisting a rotation: silent, never interactive (Swift
    /// `withCredentialSourceRevalidation`).
    fn revalidate_keychain_auth(&self, account: &str) -> Result<Option<CodexAuthState>, CodexAuthError> {
        let request = SecureReadRequest::silent(KEYCHAIN_SERVICE, SecureAccount::Named(account.into()), ID);
        self.read_keychain(request, account)
    }

    fn read_keychain(&self, request: SecureReadRequest, account: &str) -> Result<Option<CodexAuthState>, CodexAuthError> {
        let value = match host::secure_read(&request) {
            SecureReadOutcome::Found { value } => Some(value),
            SecureReadOutcome::NotFound => None,
            SecureReadOutcome::InteractionRequired | SecureReadOutcome::Denied => {
                return Err(CodexAuthError::CredentialPermissionRequired)
            }
            SecureReadOutcome::Cancelled => return Err(CodexAuthError::Cancelled),
            SecureReadOutcome::Deferred | SecureReadOutcome::Failed { .. } => {
                return Err(CodexAuthError::CredentialsUnreadable)
            }
        };
        let Some(value) = value else { return Ok(None) };
        let Some(auth) = parse_auth(&value) else { return Ok(None) };
        if !has_token_like_auth(&auth) || !self.matches_expected_account(&auth) {
            return Ok(None);
        }
        Ok(Some(CodexAuthState { auth, source: CodexAuthSource::Keychain(account.to_string()) }))
    }

    pub fn save(&self, state: &CodexAuthState) -> Result<(), CodexAuthError> {
        if !self.matches_expected_account(&state.auth) {
            return Err(CodexAuthError::TokenConflict);
        }
        match &state.source {
            CodexAuthSource::File(path) => {
                // Swift `[.prettyPrinted, .sortedKeys]`; `Value` objects iterate in key order.
                let value = serde_json::to_value(&state.auth).map_err(|_| CodexAuthError::InvalidAuthPayload)?;
                let text = serde_json::to_string_pretty(&value).map_err(|_| CodexAuthError::InvalidAuthPayload)?;
                write_private_text(&paths::expand_home(path), &text).map_err(|_| CodexAuthError::CredentialsUnreadable)
            }
            CodexAuthSource::Keychain(account) => {
                let text = serde_json::to_string(&state.auth).map_err(|_| CodexAuthError::InvalidAuthPayload)?;
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

    /// Persist a refresh only while the exact credential generation that produced it is still live.
    /// Logout removes the source and a CLI/account switch replaces its token bundle; either must win
    /// over a refresh response already in flight. Non-token metadata is merged from the live value.
    pub fn save_replacing(&self, state: &CodexAuthState, original: &CodexAuthState) -> Result<(), CodexAuthError> {
        if state.source != original.source {
            return Err(CodexAuthError::TokenConflict);
        }
        let live = match &original.source {
            CodexAuthSource::File(path) => self.load_auth(path)?,
            CodexAuthSource::Keychain(account) => self.revalidate_keychain_auth(account)?,
        };
        let Some(live) = live else { return Err(CodexAuthError::TokenConflict) };
        if live.auth.tokens != original.auth.tokens || !self.matches_expected_account(&live.auth) {
            return Err(CodexAuthError::TokenConflict);
        }
        let mut merged = live;
        merged.auth.tokens = state.auth.tokens.clone();
        merged.auth.last_refresh = state.auth.last_refresh.clone();
        self.save(&merged)
    }

    /// Whether the access token should be proactively refreshed: its JWT `exp` within the refresh
    /// window; the 8-day wall-clock age only for tokens whose `exp` is unreadable; a brand-new login
    /// with neither does not need one.
    pub fn needs_refresh(&self, auth: &CodexAuth, now: f64) -> bool {
        if let Some(expires_at) = auth.tokens.as_ref().and_then(|t| t.access_token.as_deref()).and_then(access_token_expires_at) {
            return expires_at - now <= ACCESS_TOKEN_REFRESH_WINDOW;
        }
        let Some(date) = auth.last_refresh.as_deref().and_then(time::parse_iso8601) else { return false };
        now - date > 8.0 * 24.0 * 60.0 * 60.0
    }

    pub fn auth_paths(&self) -> Vec<String> {
        if !self.candidate_auth_homes.is_empty() {
            let mut seen = std::collections::HashSet::new();
            return self
                .candidate_auth_homes
                .iter()
                .map(|h| join_path(h, AUTH_FILE))
                .filter(|p| seen.insert(standardized(p)))
                .collect();
        }
        let primary: Vec<String> = match self.codex_home() {
            Some(home) => vec![join_path(&home, AUTH_FILE)],
            None => DEFAULT_AUTH_HOMES.iter().map(|h| join_path(h, AUTH_FILE)).collect(),
        };
        let mut seen = std::collections::HashSet::new();
        primary
            .into_iter()
            .chain(self.additional_auth_homes.iter().map(|h| join_path(h, AUTH_FILE)))
            .filter(|p| seen.insert(standardized(p)))
            .collect()
    }

    pub fn codex_home(&self) -> Option<String> {
        let home = (self.env)("CODEX_HOME")?.trim().to_string();
        (!home.is_empty()).then_some(home)
    }

    pub fn keychain_account_candidates(&self) -> Vec<String> {
        match self.codex_home() {
            Some(home) => vec![keychain_account(&home)],
            None => DEFAULT_AUTH_HOMES.iter().map(|h| keychain_account(h)).collect(),
        }
    }

    pub fn matches_expected_account(&self, auth: &CodexAuth) -> bool {
        if has_identity_conflict(auth) {
            return false;
        }
        let Some(expected) = &self.expected_identity_key else { return true };
        account_identity(auth).is_some_and(|actual| actual.to_lowercase() == expected.to_lowercase())
    }
}

/// Codex stores direct-keyring credentials at `Codex Auth` / `cli|<16 hex chars>`: the first 16
/// lowercase SHA-256 hex characters of the canonical `CODEX_HOME` path (the original path when
/// canonicalization fails, like the CLI).
pub fn keychain_account(codex_home: &str) -> String {
    let expanded = paths::expand_home(codex_home);
    let canonical = if expanded.exists() { std::fs::canonicalize(&expanded).unwrap_or(expanded) } else { expanded };
    let digest = Sha256::digest(canonical.to_string_lossy().as_bytes());
    let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
    format!("cli|{}", &hex[..16])
}

/// Swift `ProviderParse.decodeJSONWithHexFallback`: plain JSON, else hex-encoded JSON (optionally
/// `0x`-prefixed).
pub fn parse_auth(text: &str) -> Option<CodexAuth> {
    if let Ok(auth) = serde_json::from_str::<CodexAuth>(text) {
        return Some(auth);
    }
    let mut hex = text.trim();
    if let Some(rest) = hex.strip_prefix("0x").or_else(|| hex.strip_prefix("0X")) {
        hex = rest;
    }
    if hex.is_empty() || hex.chars().count() % 2 != 0 || !hex.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let bytes: Vec<u8> = hex
        .as_bytes()
        .chunks(2)
        .map(|pair| u8::from_str_radix(std::str::from_utf8(pair).ok()?, 16).ok())
        .collect::<Option<_>>()?;
    serde_json::from_str::<CodexAuth>(&String::from_utf8(bytes).ok()?).ok()
}

pub fn has_token_like_auth(auth: &CodexAuth) -> bool {
    auth.tokens.as_ref().and_then(|t| t.access_token.as_deref()).is_some_and(|t| !t.is_empty())
        || auth.api_key.as_deref().is_some_and(|k| !k.is_empty())
}

/// Metadata-only account identity. If `account_id` and the id-token's ChatGPT account claim
/// disagree, fail closed (`None`) instead of trusting whichever is present first.
pub fn account_identity(auth: &CodexAuth) -> Option<String> {
    let (account_id, id_token_id) = identity_parts(auth);
    if identity_conflict(&account_id, &id_token_id) {
        return None;
    }
    account_id.or(id_token_id)
}

pub fn has_identity_conflict(auth: &CodexAuth) -> bool {
    let (account_id, id_token_id) = identity_parts(auth);
    identity_conflict(&account_id, &id_token_id)
}

/// Trimmed, lowercased, non-empty.
pub fn normalized_identity_key(value: Option<&str>) -> Option<String> {
    let trimmed = value?.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_lowercase())
}

fn identity_parts(auth: &CodexAuth) -> (Option<String>, Option<String>) {
    let tokens = auth.tokens.as_ref();
    let account_id = normalized_identity_key(tokens.and_then(|t| t.account_id.as_deref()));
    let id_token_id = tokens
        .and_then(|t| t.id_token.as_deref())
        .and_then(swift_jwt_payload)
        .and_then(|payload| chatgpt_account_id(&payload))
        .and_then(|id| normalized_identity_key(Some(&id)));
    (account_id, id_token_id)
}

fn identity_conflict(account_id: &Option<String>, id_token_id: &Option<String>) -> bool {
    match (account_id, id_token_id) {
        (Some(a), Some(b)) => a.to_lowercase() != b.to_lowercase(),
        _ => false,
    }
}

/// Swift `DefaultAccountObserver.chatGPTAccountID(inIDTokenPayload:)`.
pub fn chatgpt_account_id(payload: &serde_json::Map<String, Value>) -> Option<String> {
    let auth_claim = payload.get("https://api.openai.com/auth").and_then(Value::as_object);
    let raw = auth_claim.and_then(|c| c.get("chatgpt_account_id")).or_else(|| payload.get("chatgpt_account_id"));
    let trimmed = raw?.as_str()?.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

/// Swift `ProviderParse.jwtPayload`: needs at least two non-empty dot-separated segments; the second
/// is the base64url payload.
pub fn swift_jwt_payload(token: &str) -> Option<serde_json::Map<String, Value>> {
    let mut parts = token.split('.').filter(|p| !p.is_empty());
    let _header = parts.next()?;
    let payload = parts.next()?;
    let bytes = parse::decode_base64(payload)?;
    match serde_json::from_slice::<Value>(&bytes).ok()? {
        Value::Object(map) => Some(map),
        _ => None,
    }
}

/// The access token's expiry (seconds since 1970) from its JWT `exp` claim.
pub fn access_token_expires_at(token: &str) -> Option<f64> {
    parse::number(swift_jwt_payload(token)?.get("exp"))
}

fn absolute_home_path(home: &str) -> String {
    let trimmed = paths::expand_home(home.trim_end_matches('/')).to_string_lossy().into_owned();
    if trimmed.starts_with('/') {
        return std::fs::canonicalize(&trimmed)
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|_| standardized(&trimmed));
    }
    trimmed
}

fn join_path(base: &str, leaf: &str) -> String {
    format!("{}/{leaf}", base.trim_end_matches('/'))
}

/// Lexically standardized path (`.`/`..`/doubled separators removed), the dedupe key.
fn standardized(path: &str) -> String {
    let mut out: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                out.pop();
            }
            other => out.push(other),
        }
    }
    let joined = out.join("/");
    if path.starts_with('/') {
        format!("/{joined}")
    } else {
        joined
    }
}

/// Swift `LocalTextFileAccessor.writeText`: a private (0600) temporary file in the destination's
/// directory, flushed, then renamed over the target. A symlink at the destination is followed (the
/// rotation lands on the real file), never replaced.
pub fn write_private_text(path: &Path, text: &str) -> std::io::Result<()> {
    let destination = resolve_symlink_destination(path);
    let parent = destination.parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or_else(|| Path::new("."));
    std::fs::create_dir_all(parent)?;
    let name = destination.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let temporary = parent.join(format!(".{name}.{}.tmp", unique_suffix()));
    let mut options = std::fs::OpenOptions::new();
    // `create_new` is O_CREAT|O_EXCL, which also refuses to follow a symlink at the temporary path.
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&temporary)?;
    let write = (|| {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            // A umask may only remove permissions at creation; reassert the exact private mode.
            file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
        }
        file.write_all(text.as_bytes())?;
        file.sync_all()?;
        drop(file);
        std::fs::rename(&temporary, &destination)
    })();
    if write.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    write
}

fn unique_suffix() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_nanos());
    format!("{}-{nanos}-{}", std::process::id(), COUNTER.fetch_add(1, Ordering::Relaxed))
}

/// Swift `resolveSymlinkDestination`: follow up to eight symlink hops, resolving a relative link
/// against the directory holding that link. A cycle returns where it started.
fn resolve_symlink_destination(path: &Path) -> PathBuf {
    let mut current = path.to_path_buf();
    for _ in 0..8 {
        let is_link = std::fs::symlink_metadata(&current).is_ok_and(|m| m.file_type().is_symlink());
        if !is_link {
            return current;
        }
        let Ok(target) = std::fs::read_link(&current) else { return current };
        if target.as_os_str().is_empty() {
            return current;
        }
        let next = if target.is_absolute() {
            target
        } else {
            current.parent().unwrap_or_else(|| Path::new(".")).join(target)
        };
        current = PathBuf::from(standardized(&next.to_string_lossy()));
    }
    path.to_path_buf()
}
