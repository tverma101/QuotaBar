//! Credentials Antigravity already has on the machine (Swift `AntigravityAuthStore`). On current
//! builds the OAuth tokens live in the macOS Keychain (service `gemini`, account `antigravity`) as a
//! `go-keyring-base64`-wrapped JSON blob holding an access token, a refresh token, and an expiry.
//! The Keychain read goes through the host's secure-read callback so prompts, "Always Allow" grants
//! and manual-retry gating stay in the app. QuotaBar's own derived-token cache (`native-auth.json`)
//! is the only file this store writes; Antigravity's Keychain item is never modified.

use super::errors::{AntigravityError, Failure};
use super::ID;
use crate::context::RefreshContext;
use crate::host::{self, auth_tag, diagnostic_gate, SecureAccount, SecureReadOutcome, SecureReadRequest};
use crate::parse;
use crate::paths;
use crate::providers::claude::util::stable_fingerprint;
use crate::qlog;
use crate::time;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::sync::Arc;

pub const KEYCHAIN_SERVICE: &str = "gemini";
pub const KEYCHAIN_ACCOUNT: &str = "antigravity";
pub const UNRESOLVED_CACHE_IDENTITY_KEY: &str = "antigravity-unresolved";
/// Treat a token with less than this left as already expired (skip straight to refresh).
pub const REFRESH_BUFFER_SECS: f64 = 60.0;
pub const GOOGLE_OAUTH_URL: &str = "https://oauth2.googleapis.com/token";

const CACHE_READ_FAILURE_KEY: &str = "auth.antigravity.cache.read";
const CACHE_DECODE_FAILURE_KEY: &str = "auth.antigravity.cache.decode";
const CACHE_WRITE_FAILURE_KEY: &str = "auth.antigravity.cache.write";
const CACHE_REMOVE_FAILURE_KEY: &str = "auth.antigravity.cache.remove";

#[derive(Clone, Debug, Default, PartialEq)]
pub struct KeychainToken {
    pub access_token: Option<String>,
    pub refresh_token: Option<String>,
    pub expiry: Option<f64>,
}

/// T3 Code's private Antigravity instances keep a self-contained OAuth credential on disk
/// (`acp_token.json`). Production reads none of these; they exist only behind the legacy test seam.
#[derive(Clone, Debug, PartialEq)]
pub struct FileCredential {
    pub refresh_token: String,
    pub client_id: String,
    pub client_secret: String,
    pub project_id: Option<String>,
    pub source_path: PathBuf,
}

/// Seam over the platform credential store (production: the host callback).
pub trait SecureStore: Send + Sync {
    fn read(&self, request: &SecureReadRequest) -> SecureReadOutcome;
}

pub struct HostSecureStore;

impl SecureStore for HostSecureStore {
    fn read(&self, request: &SecureReadRequest) -> SecureReadOutcome {
        host::secure_read(request)
    }
}

#[derive(Clone)]
pub struct AntigravityAuthStore {
    pub keychain: Arc<dyn SecureStore>,
    pub now: Arc<dyn Fn() -> f64 + Send + Sync>,
    /// Where T3 Code's private instances keep their credentials. Production reads none.
    pub file_credential_paths: Arc<dyn Fn() -> Vec<PathBuf> + Send + Sync>,
    /// Derived-token cache location; `None` resolves `<app data>/antigravity/native-auth.json`.
    pub cache_path_override: Option<PathBuf>,
}

impl AntigravityAuthStore {
    pub fn live() -> Self {
        AntigravityAuthStore {
            keychain: Arc::new(HostSecureStore),
            now: Arc::new(crate::context::now_timestamp),
            file_credential_paths: Arc::new(Vec::new),
            cache_path_override: None,
        }
    }

    pub fn cache_path(&self) -> PathBuf {
        self.cache_path_override.clone().unwrap_or_else(|| paths::app_data().join("antigravity").join("native-auth.json"))
    }

    fn secure_request(ctx: Option<&RefreshContext>) -> SecureReadRequest {
        let account = SecureAccount::Named(KEYCHAIN_ACCOUNT.to_string());
        match ctx {
            Some(ctx) => SecureReadRequest::for_refresh(KEYCHAIN_SERVICE, account, ID, ctx),
            None => SecureReadRequest::silent(KEYCHAIN_SERVICE, account, ID),
        }
    }

    /// Blocking Keychain read. Antigravity's credential is written by the Antigravity app, so its
    /// Keychain ACL does not trust QuotaBar until the user grants it. A *background* refresh can
    /// never grant that, so the one definitive answer becomes copy that names the action that works.
    pub fn load_keychain_token(&self, ctx: Option<&RefreshContext>) -> Result<Option<KeychainToken>, Failure> {
        let raw = match self.keychain.read(&Self::secure_request(ctx)) {
            SecureReadOutcome::Found { value } => value,
            SecureReadOutcome::NotFound => return Ok(None),
            SecureReadOutcome::InteractionRequired | SecureReadOutcome::Denied => {
                // The shared Keychain gate logs the first silent refusal; later blocked refreshes
                // stay quiet instead of repeating a provider-level line on every scheduler tick.
                return Err(AntigravityError::CredentialPermissionRequired.into());
            }
            SecureReadOutcome::Cancelled => return Err(Failure::Cancelled),
            SecureReadOutcome::Deferred | SecureReadOutcome::Failed { .. } => {
                return Err(AntigravityError::CredentialStoreUnreadable.into());
            }
        };
        match extract_token(&raw) {
            Some(token) => Ok(Some(token)),
            // The provider surfaces this typed failure once through persistent-failure logging.
            None => Err(AntigravityError::InvalidCredentialData.into()),
        }
    }

    /// Stable, non-secret account stamp for quota snapshots. Refresh credentials stay stable across
    /// access-token rotation; access-token-only records still get a conservative account fence.
    pub fn cache_identity_key(token: &KeychainToken) -> Option<String> {
        Self::cache_identity_key_for_refresh_token(token.refresh_token.as_deref())
            .or_else(|| Self::cache_identity_key_for_refresh_token(token.access_token.as_deref()))
    }

    pub fn cache_identity_key_for_refresh_token(refresh_token: Option<&str>) -> Option<String> {
        let fingerprint = credential_fingerprint(refresh_token)?;
        Some(format!("antigravity-{}", hex(&fingerprint)))
    }

    /// Resolve the launch identity without ever presenting a Keychain prompt. If Antigravity's ACL
    /// blocks this background read, the stable unresolved marker fences previously attributed quota.
    pub fn cache_identity_key_for_launch(&self) -> String {
        let request = Self::secure_request(None);
        let SecureReadOutcome::Found { value } = self.keychain.read(&request) else {
            return UNRESOLVED_CACHE_IDENTITY_KEY.to_string();
        };
        extract_token(&value)
            .and_then(|token| Self::cache_identity_key(&token))
            .unwrap_or_else(|| UNRESOLVED_CACHE_IDENTITY_KEY.to_string())
    }

    /// Whether a keychain access token is worth attempting: expiry unknown, or it hasn't passed yet.
    pub fn is_usable(&self, expiry: Option<f64>) -> bool {
        match expiry {
            None => true,
            Some(expiry) => expiry - (self.now)() > REFRESH_BUFFER_SECS,
        }
    }

    // MARK: - T3 Code file credentials (legacy test seam only)

    pub fn load_file_credentials(&self) -> Vec<FileCredential> {
        (self.file_credential_paths)().iter().filter_map(|p| self.load_file_credential(p)).collect()
    }

    /// One `acp_token.json`. The refresh token is only ever sent to Google's OAuth endpoint: a file
    /// naming any other `token_uri` is refused at this boundary rather than trusted.
    pub fn load_file_credential(&self, path: &Path) -> Option<FileCredential> {
        let text = std::fs::read_to_string(path).ok()?;
        let Some(object) = serde_json::from_str::<Value>(&text).ok().and_then(|v| v.as_object().cloned()) else {
            diagnostic_gate::log_once(&format!("auth.antigravity.file.{}", stable_fingerprint(&path.to_string_lossy())), || {
                qlog!(Warn, auth_tag(ID), "T3 Code Antigravity credential is not readable JSON; skipping it");
            });
            return None;
        };
        let refresh = first_string(&object, &["refresh_token", "refreshToken"])?;
        let client_id = first_string(&object, &["client_id", "clientId"])?;
        let client_secret = first_string(&object, &["client_secret", "clientSecret"])?;
        if object.get("token_uri").and_then(Value::as_str) != Some(GOOGLE_OAUTH_URL) {
            return None;
        }
        Some(FileCredential {
            refresh_token: refresh,
            client_id,
            client_secret,
            project_id: first_string(&object, &["project_id", "projectId"]),
            source_path: path.to_path_buf(),
        })
    }

    // MARK: - Refreshed-token cache

    pub fn load_cached_token(&self, source: &KeychainToken) -> Option<String> {
        match source.refresh_token.as_deref() {
            Some(refresh) => self.load_cached_token_matching_refresh_token(refresh),
            None => {
                self.discard_cached_token();
                None
            }
        }
    }

    /// The derived cache is bound to the refresh credential that produced it. Requires at least
    /// [`REFRESH_BUFFER_SECS`] of life left, matching `is_usable` for the keychain token.
    pub fn load_cached_token_matching_refresh_token(&self, refresh_token: &str) -> Option<String> {
        let Some(expected) = credential_fingerprint(Some(refresh_token)) else {
            self.discard_cached_token();
            return None;
        };
        let path = self.cache_path();
        let text = match std::fs::read_to_string(&path) {
            Ok(text) => {
                diagnostic_gate::clear(CACHE_READ_FAILURE_KEY);
                text
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                diagnostic_gate::clear(CACHE_READ_FAILURE_KEY);
                diagnostic_gate::clear(CACHE_DECODE_FAILURE_KEY);
                return None;
            }
            Err(_) => {
                diagnostic_gate::log_once(CACHE_READ_FAILURE_KEY, || {
                    qlog!(Warn, auth_tag(ID), "refreshed-token cache read failed; ignoring it");
                });
                return None;
            }
        };
        let Ok(cached) = serde_json::from_str::<CachedToken>(&text) else {
            diagnostic_gate::log_once(CACHE_DECODE_FAILURE_KEY, || {
                qlog!(Warn, auth_tag(ID), "refreshed-token cache is malformed; discarding it");
            });
            self.discard_cached_token();
            return None;
        };
        diagnostic_gate::clear(CACHE_DECODE_FAILURE_KEY);
        let token = cached.access_token.trim().to_string();
        let bound = cached.credential_fingerprint.as_deref().and_then(parse::decode_base64);
        if bound.as_deref() != Some(expected.as_slice())
            || cached.expires_at_ms <= ((self.now)() + REFRESH_BUFFER_SECS) * 1000.0
            || token.is_empty()
        {
            self.discard_cached_token();
            return None;
        }
        Some(token)
    }

    /// Cache a refreshed access token bound to a Keychain credential, revalidating that the
    /// credential is still the live one (a silent re-read) before writing.
    pub fn cache_token(&self, access_token: &str, expires_in: f64, source: &KeychainToken) -> Result<bool, Failure> {
        self.cache_token_matching_refresh_token(access_token, expires_in, source.refresh_token.as_deref(), || {
            // OAuth runs off-thread and can outlive a logout/account switch. Re-read the Keychain
            // source immediately before writing the derived cache — silently, never prompting.
            Ok(self.load_keychain_token(None)?.and_then(|t| t.refresh_token))
        })
    }

    /// Cache a refreshed access token bound to a refresh credential. `revalidate` returns the current
    /// refresh token for the source; a mismatch discards the derived token instead of caching it
    /// against a login that changed mid-OAuth.
    pub fn cache_token_matching_refresh_token(
        &self,
        access_token: &str,
        expires_in: f64,
        refresh_token: Option<&str>,
        revalidate: impl FnOnce() -> Result<Option<String>, Failure>,
    ) -> Result<bool, Failure> {
        let Some(fingerprint) = credential_fingerprint(refresh_token) else { return Ok(false) };
        if access_token.trim().is_empty() {
            return Ok(false);
        }
        let live = revalidate()?;
        if credential_fingerprint(live.as_deref()) != Some(fingerprint.clone()) {
            qlog!(Warn, auth_tag(ID), "discarding refreshed token because the Antigravity login changed during OAuth");
            return Ok(false);
        }
        let cached = CachedToken {
            access_token: access_token.to_string(),
            expires_at_ms: ((self.now)() + expires_in) * 1000.0,
            credential_fingerprint: Some(base64_encode(&fingerprint)),
        };
        let write = serde_json::to_vec(&cached)
            .map_err(|e| e.to_string())
            .and_then(|data| paths::write_atomic(&self.cache_path(), &data).map_err(|e| e.to_string()));
        match write {
            Ok(()) => diagnostic_gate::clear(CACHE_WRITE_FAILURE_KEY),
            Err(error) => {
                // The refreshed token still works for this session; a failed cache only means we
                // refresh again next cycle. Log loudly rather than fail the live fetch.
                diagnostic_gate::log_once(CACHE_WRITE_FAILURE_KEY, || {
                    qlog!(Warn, auth_tag(ID), "failed to cache refreshed token: {error}");
                });
            }
        }
        Ok(true)
    }

    /// Remove only QuotaBar's derived token; Antigravity's Keychain entry is never modified.
    pub fn discard_cached_token(&self) {
        match std::fs::remove_file(self.cache_path()) {
            Ok(()) => diagnostic_gate::clear(CACHE_REMOVE_FAILURE_KEY),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => diagnostic_gate::clear(CACHE_REMOVE_FAILURE_KEY),
            Err(_) => diagnostic_gate::log_once(CACHE_REMOVE_FAILURE_KEY, || {
                qlog!(Warn, auth_tag(ID), "failed to remove stale refreshed-token cache");
            }),
        }
    }
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CachedToken {
    access_token: String,
    expires_at_ms: f64,
    /// SHA-256 of the refresh credential that produced this derived access token (base64, as Swift `Data`). Optional so
    /// unbound cache files decode as a safe miss.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    credential_fingerprint: Option<String>,
}

/// Standard padded base64 — the encoding Swift's `JSONEncoder` uses for `Data`, so a cache file
/// written by either implementation is readable by the other.
fn base64_encode(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = (u32::from(chunk[0]) << 16) | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8) | u32::from(*chunk.get(2).unwrap_or(&0));
        out.push(TABLE[(n >> 18) as usize & 63] as char);
        out.push(TABLE[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { TABLE[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { TABLE[n as usize & 63] as char } else { '=' });
    }
    out
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn credential_fingerprint(refresh_token: Option<&str>) -> Option<Vec<u8>> {
    let token = refresh_token?.trim();
    (!token.is_empty()).then(|| Sha256::digest(token.as_bytes()).to_vec())
}

// MARK: - Token extraction (pure)

fn boundary(c: char) -> bool {
    c.is_whitespace() || c == '\u{FEFF}'
}

fn unwrap_go_keyring(raw: &str) -> Option<String> {
    let mut text = raw.trim().to_string();
    if let Some(encoded) = text.strip_prefix("go-keyring-base64:") {
        let decoded = parse::decode_base64(encoded.trim()).and_then(|b| String::from_utf8(b).ok())?;
        text = decoded.trim().to_string();
    }
    (!text.is_empty()).then_some(text)
}

/// Decode the keychain value into tokens. Mirrors the `agy` format: an optional
/// `go-keyring-base64:` wrapper around JSON `{ token: { access_token, refresh_token, expiry }, … }`,
/// with fallbacks for a `Bearer …` value or a raw token. Like Swift's `JSONSerialization` without
/// fragment support, a top-level JSON scalar is not parsed JSON: it is treated as a raw token.
pub fn extract_token(raw: &str) -> Option<KeychainToken> {
    let normalized = raw.trim_matches(boundary);
    let unwrapped = unwrap_go_keyring(normalized)?;
    let text = unwrapped.trim_matches(boundary);
    if text.is_empty() {
        return None;
    }
    match serde_json::from_str::<Value>(text) {
        Ok(Value::Object(object)) => return token_from_object(&object),
        Ok(Value::Array(_)) => return None,
        _ => {}
    }
    // Broken structured material is never sent as a raw bearer token.
    if text.starts_with('{') || text.starts_with('[') {
        return None;
    }
    if let Some(rest) = text.strip_prefix("Bearer ") {
        let token = rest.trim();
        return (!token.is_empty()).then(|| KeychainToken { access_token: Some(token.to_string()), ..Default::default() });
    }
    Some(KeychainToken { access_token: Some(text.to_string()), ..Default::default() })
}

pub fn token_from_object(object: &Map<String, Value>) -> Option<KeychainToken> {
    // Prefer a nested `token` object (the agy shape); otherwise read fields off the root.
    let source = object.get("token").and_then(Value::as_object).unwrap_or(object);
    let access = first_string(
        source,
        &["access_token", "accessToken", "token", "id_token", "idToken", "bearerToken", "auth_token", "authToken"],
    );
    let refresh = first_string(source, &["refresh_token", "refreshToken"]);
    let expiry = first_string(source, &["expiry", "expires_at", "expiresAt"]).and_then(|v| time::parse_iso8601(&v));

    if access.is_none() && refresh.is_none() {
        for key in ["tokens", "oauth", "oauth2", "credentials", "auth"] {
            if let Some(token) = object.get(key).and_then(Value::as_object).and_then(token_from_object) {
                return Some(token);
            }
        }
        return None;
    }
    Some(KeychainToken { access_token: access, refresh_token: refresh, expiry })
}

fn first_string(object: &Map<String, Value>, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| {
        let value = object.get(*key)?.as_str()?.trim();
        (!value.is_empty()).then(|| value.to_string())
    })
}
