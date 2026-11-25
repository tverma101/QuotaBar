//! Antigravity credentials (`Providers/Antigravity/AntigravityAuthStore`).
//!
//! The app/`agy` CLI store a `go-keyring-base64:` JSON blob in the macOS Keychain (`gemini` /
//! `antigravity`). QuotaBar never writes that item; refreshed access tokens live in a small
//! app-owned cache bound to the refresh-token fingerprint.

use crate::host::{self, SecureAccount, SecureReadOutcome, SecureReadRequest};
use crate::qlog;
use base64::Engine as _;
use sha2::{Digest, Sha256};
use std::path::PathBuf;

pub const KEYCHAIN_SERVICE: &str = "gemini";
pub const KEYCHAIN_ACCOUNT: &str = "antigravity";
pub const REFRESH_BUFFER_SECS: f64 = 60.0;
pub const UNRESOLVED_CACHE_IDENTITY: &str = "antigravity-unresolved";

#[derive(Clone, Debug, Default, PartialEq)]
pub struct KeychainToken {
    pub access_token: Option<String>,
    pub refresh_token: Option<String>,
    pub expiry: Option<f64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AuthError {
    NotSignedIn,
    CredentialPermissionRequired,
    CredentialStoreUnreadable,
    InvalidCredentialData,
    AuthExpired,
}

impl AuthError {
    pub fn message(&self) -> &'static str {
        match self {
            AuthError::NotSignedIn => {
                "No Antigravity login was found. Sign in with Antigravity or the agy CLI, then refresh QuotaBar."
            }
            AuthError::CredentialPermissionRequired => {
                "macOS needs permission to read Antigravity's Keychain item. Choose Always Allow when prompted."
            }
            AuthError::CredentialStoreUnreadable => "QuotaBar couldn't read Antigravity's Keychain item.",
            AuthError::InvalidCredentialData => {
                "Antigravity's saved login is unreadable. Sign in again with Antigravity."
            }
            AuthError::AuthExpired => "The Antigravity login has expired. Sign in again.",
        }
    }
}

pub struct AntigravityAuth {
    cache_path: PathBuf,
}

impl AntigravityAuth {
    pub fn live() -> Self {
        AntigravityAuth {
            cache_path: crate::paths::home()
                .join("Library/Application Support/QuotaBar/antigravity/auth.json"),
        }
    }

    pub fn with_cache_path(cache_path: PathBuf) -> Self {
        AntigravityAuth { cache_path }
    }

    pub fn load_keychain_token(
        &self,
        is_manual: bool,
        request_id: Option<u64>,
    ) -> Result<Option<KeychainToken>, AuthError> {
        let mut request = SecureReadRequest {
            service: KEYCHAIN_SERVICE.into(),
            account: SecureAccount::Named(KEYCHAIN_ACCOUNT.into()),
            provider: "antigravity".into(),
            allow_interaction: is_manual,
            bypass_deferred_read_failure: false,
            recheck_blocked_silently: false,
            request_id,
        };
        let outcome = host::secure_read(&request);
        match outcome {
            SecureReadOutcome::Found { value } => match extract_token(&value) {
                Some(token) => Ok(Some(token)),
                None => Err(AuthError::InvalidCredentialData),
            },
            SecureReadOutcome::NotFound => Ok(None),
            SecureReadOutcome::InteractionRequired | SecureReadOutcome::Denied => {
                Err(AuthError::CredentialPermissionRequired)
            }
            SecureReadOutcome::Cancelled => Err(AuthError::CredentialStoreUnreadable),
            SecureReadOutcome::Deferred => {
                request.bypass_deferred_read_failure = true;
                match host::secure_read(&request) {
                    SecureReadOutcome::Found { value } => extract_token(&value)
                        .map(Some)
                        .ok_or(AuthError::InvalidCredentialData),
                    SecureReadOutcome::NotFound => Ok(None),
                    SecureReadOutcome::Cancelled => Err(AuthError::CredentialStoreUnreadable),
                    _ => Err(AuthError::CredentialPermissionRequired),
                }
            }
            SecureReadOutcome::Failed { .. } => Err(AuthError::CredentialStoreUnreadable),
        }
    }

    /// Launch-time identity: a silent read, never a prompt. A blocked read keeps the stable
    /// unresolved marker so prior attribution cannot leak into another account's card.
    pub fn cache_identity_key_for_launch(&self) -> String {
        let request = SecureReadRequest::silent(
            KEYCHAIN_SERVICE,
            SecureAccount::Named(KEYCHAIN_ACCOUNT.into()),
            "antigravity",
        );
        let identity = match host::secure_read(&request) {
            SecureReadOutcome::Found { value } => {
                extract_token(&value).and_then(|token| cache_identity_key(&token))
            }
            _ => None,
        };
        identity.unwrap_or_else(|| UNRESOLVED_CACHE_IDENTITY.to_string())
    }

    pub fn is_usable(&self, expiry: Option<f64>, now: f64) -> bool {
        expiry.is_none_or(|expiry| expiry - now > REFRESH_BUFFER_SECS)
    }

    pub fn load_cached_token(&self, source: &KeychainToken, now: f64) -> Option<String> {
        let expected = credential_fingerprint(source.refresh_token.as_deref())?;
        let text = std::fs::read_to_string(&self.cache_path).ok()?;
        let root: serde_json::Value = serde_json::from_str(&text).ok()?;
        let access = root
            .get("accessToken")
            .and_then(|v| v.as_str())
            .map(str::trim)
            .filter(|v| !v.is_empty())?;
        let expires_at_ms = root.get("expiresAtMs").and_then(|v| v.as_f64())?;
        let fingerprint = root
            .get("credentialFingerprint")
            .and_then(|v| v.as_str())
            .and_then(|value| base64::engine::general_purpose::STANDARD.decode(value).ok())?;
        if fingerprint != expected || expires_at_ms <= (now + REFRESH_BUFFER_SECS) * 1000.0 {
            self.discard_cached_token();
            return None;
        }
        Some(access.to_string())
    }

    /// Persist a refreshed access token only if the Keychain login still matches the one the OAuth
    /// response came from. Returns false when the login changed during the request.
    pub fn cache_token(
        &self,
        access_token: &str,
        expires_in: f64,
        source: &KeychainToken,
        now: f64,
        is_manual: bool,
        request_id: Option<u64>,
    ) -> Result<bool, AuthError> {
        let Some(expected) = credential_fingerprint(source.refresh_token.as_deref()) else {
            return Ok(false);
        };
        if access_token.trim().is_empty() {
            return Ok(false);
        }
        let live = self.load_keychain_token(is_manual, request_id)?;
        if credential_fingerprint(
            live.as_ref()
                .and_then(|token| token.refresh_token.as_deref()),
        ) != Some(expected.clone())
        {
            qlog!(
                Warn,
                host::auth_tag("antigravity"),
                "discarding refreshed token because the Keychain login changed during OAuth"
            );
            return Ok(false);
        }
        let body = serde_json::json!({
            "accessToken": access_token,
            "expiresAtMs": (now + expires_in) * 1000.0,
            "credentialFingerprint": base64::engine::general_purpose::STANDARD.encode(&expected),
        });
        if let Some(parent) = self.cache_path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        match serde_json::to_vec(&body)
            .map_err(|_| AuthError::CredentialStoreUnreadable)
            .and_then(|data| {
                std::fs::write(&self.cache_path, data)
                    .map_err(|_| AuthError::CredentialStoreUnreadable)
            }) {
            Ok(()) => Ok(true),
            Err(error) => {
                // The refreshed token still works for this session; a failed cache only means the
                // next cycle refreshes again, so log instead of failing the live fetch.
                qlog!(
                    Warn,
                    host::auth_tag("antigravity"),
                    "failed to cache refreshed token: {error:?}"
                );
                Ok(true)
            }
        }
    }

    pub fn discard_cached_token(&self) {
        let _ = std::fs::remove_file(&self.cache_path);
    }
}

fn credential_fingerprint(refresh_token: Option<&str>) -> Option<Vec<u8>> {
    let token = refresh_token?.trim();
    if token.is_empty() {
        return None;
    }
    Some(Sha256::digest(token.as_bytes()).to_vec())
}

pub fn cache_identity_key(token: &KeychainToken) -> Option<String> {
    let fingerprint = credential_fingerprint(token.refresh_token.as_deref())
        .or_else(|| credential_fingerprint(token.access_token.as_deref()))?;
    Some(format!(
        "antigravity-{}",
        fingerprint
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>()
    ))
}

/// Decode the Keychain value into tokens. Mirrors the `agy` format: an optional
/// `go-keyring-base64:` wrapper around JSON `{ token: { access_token, refresh_token, expiry } }`,
/// with fallbacks for a bare JSON string, a `Bearer …` value, or a raw token.
pub fn extract_token(raw: &str) -> Option<KeychainToken> {
    let normalized = raw.trim_matches(|c: char| c.is_whitespace() || c == '\u{feff}');
    let text = unwrap_go_keyring(normalized)?;
    if let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) {
        return match value {
            serde_json::Value::Object(object) => token_from_object(&object),
            serde_json::Value::String(token) => {
                let token = token.trim();
                (!token.is_empty()).then(|| KeychainToken {
                    access_token: Some(token.to_string()),
                    ..Default::default()
                })
            }
            _ => None,
        };
    }
    let trimmed = text.trim();
    if trimmed.starts_with('{') || trimmed.starts_with('[') {
        return None;
    }
    if let Some(token) = trimmed.strip_prefix("Bearer ") {
        let token = token.trim();
        return (!token.is_empty()).then(|| KeychainToken {
            access_token: Some(token.to_string()),
            ..Default::default()
        });
    }
    (!trimmed.is_empty()).then(|| KeychainToken {
        access_token: Some(trimmed.to_string()),
        ..Default::default()
    })
}

fn unwrap_go_keyring(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    let text = match trimmed.strip_prefix("go-keyring-base64:") {
        Some(encoded) => {
            let decoded = base64::engine::general_purpose::STANDARD
                .decode(encoded.trim())
                .ok()?;
            String::from_utf8(decoded).ok()?.trim().to_string()
        }
        None => trimmed.to_string(),
    };
    (!text.is_empty()).then_some(text)
}

fn token_from_object(object: &serde_json::Map<String, serde_json::Value>) -> Option<KeychainToken> {
    let source = object
        .get("token")
        .and_then(|value| value.as_object())
        .unwrap_or(object);
    let access = first_string(
        source,
        &[
            "access_token",
            "accessToken",
            "token",
            "id_token",
            "idToken",
            "bearerToken",
            "auth_token",
            "authToken",
        ],
    );
    let refresh = first_string(source, &["refresh_token", "refreshToken"]);
    let expiry = first_string(source, &["expiry", "expires_at", "expiresAt"])
        .and_then(|value| crate::time::parse_iso8601(&value));
    if access.is_none() && refresh.is_none() {
        for key in ["tokens", "oauth", "oauth2", "credentials", "auth"] {
            if let Some(nested) = object.get(key).and_then(|value| value.as_object()) {
                if let Some(token) = token_from_object(nested) {
                    return Some(token);
                }
            }
        }
        return None;
    }
    Some(KeychainToken {
        access_token: access,
        refresh_token: refresh,
        expiry,
    })
}

fn first_string(
    object: &serde_json::Map<String, serde_json::Value>,
    keys: &[&str],
) -> Option<String> {
    for key in keys {
        if let Some(value) = object.get(*key).and_then(|value| value.as_str()) {
            let trimmed = value.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_go_keyring_and_nested_tokens() {
        let payload = base64::engine::general_purpose::STANDARD.encode(
            br#"{"token":{"access_token":"access","refresh_token":"refresh","expiry":"2026-11-24T12:00:00Z"}}"#,
        );
        let token = extract_token(&format!("go-keyring-base64:{payload}")).unwrap();
        assert_eq!(token.access_token.as_deref(), Some("access"));
        assert_eq!(token.refresh_token.as_deref(), Some("refresh"));
        assert!(token.expiry.is_some());

        let bearer = extract_token("Bearer abc").unwrap();
        assert_eq!(bearer.access_token.as_deref(), Some("abc"));
        assert!(extract_token("{not-json").is_none());
    }

    #[test]
    fn identity_uses_refresh_then_access_token() {
        let refresh = KeychainToken {
            refresh_token: Some("r".into()),
            ..Default::default()
        };
        let access = KeychainToken {
            access_token: Some("a".into()),
            ..Default::default()
        };
        assert!(cache_identity_key(&refresh)
            .unwrap()
            .starts_with("antigravity-"));
        assert!(cache_identity_key(&access)
            .unwrap()
            .starts_with("antigravity-"));
        assert_ne!(cache_identity_key(&refresh), cache_identity_key(&access));
    }
}
