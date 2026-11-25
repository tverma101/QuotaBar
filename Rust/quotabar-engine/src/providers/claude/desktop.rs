//! Claude Desktop's Electron Safe Storage OAuth cache (Swift
//! `ClaudeDesktopAuthStore`): read-only config/cookie access, AES-128-CBC
//! decryption, and account/organization-scoped token selection.

use super::auth::ClaudeOAuth;
use crate::context::RefreshContext;
use crate::host::{self, SecureAccount, SecureReadOutcome, SecureReadRequest};
use aes::Aes128;
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine as _;
use cbc::cipher::{block_padding::Pkcs7, BlockDecryptMut, KeyIvInit};
use pbkdf2::pbkdf2_hmac;
use serde_json::Value;
use sha1::Sha1;
use sha2::{Digest, Sha256};
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

type Aes128CbcDec = cbc::Decryptor<Aes128>;

const CACHE_V1_KEY: &str = "oauth:tokenCache";
const CACHE_V2_KEY: &str = "oauth:tokenCacheV2";
const CONFIG_PATH: &str = "Library/Application Support/Claude/config.json";
const COOKIE_PATHS: [&str; 2] = [
    "Library/Application Support/Claude/Cookies",
    "Library/Application Support/Claude/Network/Cookies",
];
const COOKIE_HOSTS: [&str; 2] = [".claude.ai", "claude.ai"];
const API_HOST: &str = "https://api.anthropic.com";
const PRODUCTION_CLIENT_ID: &str = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const USAGE_SCOPE: &str = "user:profile";
const INFERENCE_SCOPE: &str = "user:inference";
const EXPIRY_SAFETY_MARGIN_MS: f64 = 2.0 * 60.0 * 1000.0;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ClaudeDesktopCredentialStatus {
    #[default]
    NotChecked,
    NotFound,
    PermissionRequired,
    Unreadable,
    Stale,
    Invalid,
    Available,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClaudeDesktopCredentialMaterialStatus {
    Absent,
    Available,
    Unreadable,
}

#[derive(Clone, Debug)]
pub struct ClaudeDesktopCredentialResult {
    pub oauth: Option<ClaudeOAuth>,
    pub status: ClaudeDesktopCredentialStatus,
}

pub struct ClaudeDesktopStore {
    home: PathBuf,
}

impl ClaudeDesktopStore {
    pub fn new(home: PathBuf) -> Self {
        ClaudeDesktopStore { home }
    }

    fn path(&self, relative: &str) -> PathBuf {
        self.home.join(relative)
    }

    pub fn credential_material_status(&self) -> ClaudeDesktopCredentialMaterialStatus {
        let text = match std::fs::read_to_string(self.path(CONFIG_PATH)) {
            Ok(text) => text,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return ClaudeDesktopCredentialMaterialStatus::Absent
            }
            Err(_) => return ClaudeDesktopCredentialMaterialStatus::Unreadable,
        };
        let Some(root) = serde_json::from_str::<Value>(&text).ok() else {
            return ClaudeDesktopCredentialMaterialStatus::Absent;
        };
        if !root.get(CACHE_V2_KEY).is_some_and(Value::is_string)
            && !root.get(CACHE_V1_KEY).is_some_and(Value::is_string)
        {
            return ClaudeDesktopCredentialMaterialStatus::Absent;
        }
        let sql = "SELECT 1 FROM cookies WHERE name = 'lastActiveOrg' AND host_key IN ('.claude.ai', 'claude.ai') LIMIT 1";
        let mut saw_unreadable = false;
        for relative in COOKIE_PATHS {
            let path = self.path(relative);
            if !path.exists() {
                continue;
            }
            match crate::sqlite::query_value(&path, sql) {
                Ok(Some(_)) => return ClaudeDesktopCredentialMaterialStatus::Available,
                Ok(None) => {}
                Err(_) => saw_unreadable = true,
            }
        }
        if saw_unreadable {
            ClaudeDesktopCredentialMaterialStatus::Unreadable
        } else {
            ClaudeDesktopCredentialMaterialStatus::Absent
        }
    }

    pub fn last_known_account_uuid(&self) -> Option<String> {
        let text = std::fs::read_to_string(self.path(CONFIG_PATH)).ok()?;
        let root: Value = serde_json::from_str(&text).ok()?;
        let raw = root.get("lastKnownAccountUuid")?.as_str()?;
        uuid_like(raw).then(|| raw.to_lowercase())
    }

    pub fn load(
        &self,
        ctx: Option<&RefreshContext>,
        organization: Option<&str>,
        expected_account_uuid: Option<&str>,
    ) -> ClaudeDesktopCredentialResult {
        let status = self.credential_material_status();
        let unavailable = |status| ClaudeDesktopCredentialResult {
            oauth: None,
            status,
        };
        if status == ClaudeDesktopCredentialMaterialStatus::Unreadable {
            return unavailable(ClaudeDesktopCredentialStatus::Unreadable);
        }
        let captured_account = self.last_known_account_uuid();
        if let Some(expected) = expected_account_uuid {
            if !captured_account
                .as_deref()
                .is_some_and(|actual| actual.eq_ignore_ascii_case(expected))
            {
                return unavailable(ClaudeDesktopCredentialStatus::NotFound);
            }
        }
        if status != ClaudeDesktopCredentialMaterialStatus::Available {
            return unavailable(ClaudeDesktopCredentialStatus::NotFound);
        }

        let password = match self.safe_storage_password(ctx) {
            Ok(Some(password)) => password,
            Ok(None) => return unavailable(ClaudeDesktopCredentialStatus::NotFound),
            Err(DesktopError::PermissionRequired) => {
                return unavailable(ClaudeDesktopCredentialStatus::PermissionRequired)
            }
            Err(DesktopError::Cancelled) => {
                return unavailable(ClaudeDesktopCredentialStatus::NotChecked)
            }
            Err(_) => return unavailable(ClaudeDesktopCredentialStatus::Invalid),
        };
        let key = derive_key(&password);
        let (v2, v1) = match self.load_caches(&key) {
            Ok(caches) => caches,
            Err(_) => return unavailable(ClaudeDesktopCredentialStatus::Invalid),
        };
        let Some(active_org) = self.active_organization(&key) else {
            return unavailable(ClaudeDesktopCredentialStatus::Invalid);
        };
        let current_account = self.last_known_account_uuid();
        if captured_account != current_account {
            return unavailable(ClaudeDesktopCredentialStatus::NotFound);
        }
        let target = organization.map(|v| v.to_lowercase()).unwrap_or(active_org);
        match select_credential(
            &target,
            current_account.as_deref(),
            v2.as_ref(),
            v1.as_ref(),
            now_secs(),
        ) {
            Selection::Available(oauth) => ClaudeDesktopCredentialResult {
                oauth: Some(oauth),
                status: ClaudeDesktopCredentialStatus::Available,
            },
            Selection::Stale => unavailable(ClaudeDesktopCredentialStatus::Stale),
            Selection::Invalid => unavailable(ClaudeDesktopCredentialStatus::Invalid),
            Selection::NotFound => unavailable(ClaudeDesktopCredentialStatus::NotFound),
        }
    }

    fn safe_storage_password(
        &self,
        ctx: Option<&RefreshContext>,
    ) -> Result<Option<String>, DesktopError> {
        // Match Swift's SafeStorageKeyCache: one successful read serves every Claude account card
        // for the process lifetime. Without this cache a user who chooses one-time "Allow" during
        // account discovery would be prompted again on the first engine refresh.
        static PASSWORD_CACHE: OnceLock<Mutex<Option<String>>> = OnceLock::new();
        let cache = PASSWORD_CACHE.get_or_init(|| Mutex::new(None));
        if let Some(password) = cache.lock().unwrap_or_else(|e| e.into_inner()).clone() {
            return Ok(Some(password));
        }
        let request = match ctx {
            Some(ctx) => SecureReadRequest::for_refresh(
                "Claude Safe Storage",
                SecureAccount::Named("Claude Key".into()),
                "claude",
                ctx,
            ),
            None => SecureReadRequest::silent(
                "Claude Safe Storage",
                SecureAccount::Named("Claude Key".into()),
                "claude",
            ),
        };
        match host::secure_read(&request) {
            SecureReadOutcome::Found { value } => {
                let trimmed = value.trim();
                if trimmed.is_empty() {
                    Err(DesktopError::InvalidKey)
                } else {
                    let password = trimmed.to_string();
                    *cache.lock().unwrap_or_else(|e| e.into_inner()) = Some(password.clone());
                    Ok(Some(password))
                }
            }
            SecureReadOutcome::NotFound => Ok(None),
            SecureReadOutcome::InteractionRequired
            | SecureReadOutcome::Denied
            | SecureReadOutcome::Deferred => Err(DesktopError::PermissionRequired),
            SecureReadOutcome::Cancelled => Err(DesktopError::Cancelled),
            SecureReadOutcome::Failed { .. } => Err(DesktopError::ReadFailed),
        }
    }

    fn load_caches(&self, key: &[u8]) -> Result<(Option<Value>, Option<Value>), DesktopError> {
        let text = std::fs::read_to_string(self.path(CONFIG_PATH))
            .map_err(|_| DesktopError::ReadFailed)?;
        let root: Value = serde_json::from_str(&text).map_err(|_| DesktopError::ReadFailed)?;
        Ok((
            decode_cache(root.get(CACHE_V2_KEY), key)?,
            decode_cache(root.get(CACHE_V1_KEY), key)?,
        ))
    }

    fn active_organization(&self, key: &[u8]) -> Option<String> {
        for relative in COOKIE_PATHS {
            let database = self.path(relative);
            if !database.exists() {
                continue;
            }
            for host_name in COOKIE_HOSTS {
                let escaped = host_name.replace('\'', "''");
                let sql = format!(
                    "SELECT CASE WHEN length(value) > 0 THEN 'plain:' || hex(CAST(value AS BLOB)) ELSE 'encrypted:' || hex(encrypted_value) END \
                     FROM cookies WHERE name = 'lastActiveOrg' AND host_key = '{escaped}' ORDER BY last_update_utc DESC LIMIT 1;"
                );
                let Some(encoded) = crate::sqlite::query_value(&database, &sql).ok().flatten()
                else {
                    continue;
                };
                let Some((mode, hex)) = encoded.split_once(':') else {
                    continue;
                };
                let Some(stored) = hex_bytes(hex) else {
                    continue;
                };
                let value = if mode == "plain" {
                    stored
                } else if mode == "encrypted" {
                    let Ok(decrypted) = decrypt(&stored, key) else {
                        continue;
                    };
                    let host_hash = Sha256::digest(host_name.as_bytes());
                    if !decrypted.starts_with(&host_hash) {
                        continue;
                    }
                    decrypted[host_hash.len()..].to_vec()
                } else {
                    continue;
                };
                let Ok(organization) = String::from_utf8(value) else {
                    continue;
                };
                if uuid_like(&organization) {
                    return Some(organization.to_lowercase());
                }
            }
        }
        None
    }
}

enum DesktopError {
    PermissionRequired,
    Cancelled,
    InvalidKey,
    ReadFailed,
}

fn now_secs() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

fn uuid_like(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 36
        && bytes.iter().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => *byte == b'-',
            _ => byte.is_ascii_hexdigit(),
        })
}

fn hex_bytes(value: &str) -> Option<Vec<u8>> {
    if value.len() % 2 != 0 || !value.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let mut out = Vec::with_capacity(value.len() / 2);
    for index in (0..value.len()).step_by(2) {
        out.push(u8::from_str_radix(&value[index..index + 2], 16).ok()?);
    }
    Some(out)
}

pub fn derive_key(password: &str) -> [u8; 16] {
    let mut key = [0u8; 16];
    pbkdf2_hmac::<Sha1>(password.as_bytes(), b"saltysalt", 1003, &mut key);
    key
}

pub fn decrypt(encrypted: &[u8], key: &[u8]) -> Result<Vec<u8>, ()> {
    if encrypted.len() <= 3 || &encrypted[..3] != b"v10" || key.len() != 16 {
        return Err(());
    }
    let mut payload = encrypted[3..].to_vec();
    let iv = [0x20u8; 16];
    let plaintext = Aes128CbcDec::new_from_slices(key, &iv)
        .map_err(|_| ())?
        .decrypt_padded_mut::<Pkcs7>(&mut payload)
        .map_err(|_| ())?;
    Ok(plaintext.to_vec())
}

fn decode_cache(stored: Option<&Value>, key: &[u8]) -> Result<Option<Value>, DesktopError> {
    let Some(base64) = stored.and_then(Value::as_str) else {
        return Ok(None);
    };
    let encrypted = BASE64
        .decode(base64)
        .map_err(|_| DesktopError::ReadFailed)?;
    let plaintext = decrypt(&encrypted, key).map_err(|_| DesktopError::ReadFailed)?;
    serde_json::from_slice::<Value>(&plaintext)
        .map(Some)
        .map_err(|_| DesktopError::ReadFailed)
}

#[derive(Debug, PartialEq)]
pub enum Selection {
    Available(ClaudeOAuth),
    Stale,
    Invalid,
    NotFound,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct CacheKey {
    client_id: String,
    organization: String,
    api_host: String,
    scopes: Vec<String>,
}

fn select_credential(
    active_organization: &str,
    active_account_uuid: Option<&str>,
    v2: Option<&Value>,
    v1: Option<&Value>,
    now: f64,
) -> Selection {
    let organization = active_organization.to_lowercase();
    let v2_entries = normalized_cache(v2, active_account_uuid);
    let v1_entries = normalized_cache(v1, active_account_uuid);
    let v2_candidates = candidates(&v2_entries, &organization, now);
    if let Some(best) = v2_candidates.available.iter().max_by(|a, b| {
        rank(a)
            .partial_cmp(&rank(b))
            .unwrap_or(std::cmp::Ordering::Equal)
    }) {
        return Selection::Available(best.oauth.clone());
    }
    let v1_filtered: Vec<(CacheKey, &Value)> = v1_entries
        .iter()
        .filter(|(key, _)| !v2_entries.contains_key(*key))
        .map(|(key, value)| (key.clone(), *value))
        .collect();
    let v1_map: std::collections::HashMap<CacheKey, &Value> = v1_filtered.into_iter().collect();
    let v1_candidates = candidates(&v1_map, &organization, now);
    if let Some(best) = v1_candidates.available.iter().max_by(|a, b| {
        rank(a)
            .partial_cmp(&rank(b))
            .unwrap_or(std::cmp::Ordering::Equal)
    }) {
        return Selection::Available(best.oauth.clone());
    }
    if v2_candidates.saw_stale || v1_candidates.saw_stale {
        return Selection::Stale;
    }
    if v2_candidates.saw_invalid || v1_candidates.saw_invalid {
        return Selection::Invalid;
    }
    Selection::NotFound
}

#[derive(Clone, Debug)]
struct Candidate {
    oauth: ClaudeOAuth,
    client_id: String,
    scopes: Vec<String>,
    expires_at: f64,
}

fn rank(candidate: &Candidate) -> (u8, u8, usize, f64) {
    let has_full = candidate.scopes.iter().any(|s| s == USAGE_SCOPE)
        && candidate.scopes.iter().any(|s| s == INFERENCE_SCOPE);
    (
        u8::from(candidate.client_id == PRODUCTION_CLIENT_ID && has_full),
        u8::from(has_full),
        candidate.scopes.len(),
        candidate.expires_at,
    )
}

struct CandidateSet {
    available: Vec<Candidate>,
    saw_stale: bool,
    saw_invalid: bool,
}

fn candidates(
    cache: &std::collections::HashMap<CacheKey, &Value>,
    organization: &str,
    now: f64,
) -> CandidateSet {
    let mut out = CandidateSet {
        available: Vec::new(),
        saw_stale: false,
        saw_invalid: false,
    };
    for (key, raw) in cache {
        if key.organization != organization
            || key.api_host != API_HOST
            || !key.scopes.iter().any(|s| s == USAGE_SCOPE)
        {
            continue;
        }
        if raw.is_null() {
            continue;
        }
        let Some(entry) = raw.as_object() else {
            out.saw_invalid = true;
            continue;
        };
        let token = entry
            .get("token")
            .and_then(Value::as_str)
            .map(str::trim)
            .unwrap_or("");
        let expires_at = entry.get("expiresAt").and_then(Value::as_f64);
        let Some(expires_at) = expires_at.filter(|v| v.is_finite()) else {
            out.saw_invalid = true;
            continue;
        };
        if token.is_empty() {
            out.saw_invalid = true;
            continue;
        }
        if expires_at <= now * 1000.0 + EXPIRY_SAFETY_MARGIN_MS {
            out.saw_stale = true;
            continue;
        }
        out.available.push(Candidate {
            oauth: ClaudeOAuth {
                access_token: Some(token.to_string()),
                refresh_token: None,
                expires_at: Some(expires_at),
                subscription_type: entry
                    .get("subscriptionType")
                    .and_then(Value::as_str)
                    .map(str::to_string),
                rate_limit_tier: entry
                    .get("rateLimitTier")
                    .and_then(Value::as_str)
                    .map(str::to_string),
                scopes: Some(key.scopes.clone()),
            },
            client_id: key.client_id.clone(),
            scopes: key.scopes.clone(),
            expires_at,
        });
    }
    out
}

fn normalized_cache<'a>(
    cache: Option<&'a Value>,
    active_account_uuid: Option<&str>,
) -> std::collections::HashMap<CacheKey, &'a Value> {
    let mut legacy = std::collections::HashMap::new();
    let mut scoped = std::collections::HashMap::new();
    let Some(object) = cache.and_then(Value::as_object) else {
        return legacy;
    };
    let mut keys: Vec<&String> = object.keys().collect();
    keys.sort();
    for raw_key in keys {
        let value = &object[raw_key];
        let is_scoped = raw_key.starts_with("acct:");
        let key_part = if is_scoped {
            let Some((owner, rest)) = raw_key[5..].split_once('|') else {
                continue;
            };
            if !active_account_uuid.is_some_and(|active| owner.eq_ignore_ascii_case(active)) {
                continue;
            }
            rest
        } else {
            raw_key.as_str()
        };
        let Some(parsed) = parse_cache_key(key_part) else {
            continue;
        };
        if is_scoped {
            scoped.insert(parsed, value);
        } else {
            legacy.insert(parsed, value);
        }
    }
    for (key, value) in scoped {
        legacy.insert(key, value);
    }
    legacy
}

fn parse_cache_key(value: &str) -> Option<CacheKey> {
    let marker = format!(":{API_HOST}:");
    let position = value.find(&marker)?;
    let prefix = &value[..position];
    let (client_id, organization) = prefix.split_once(':')?;
    if !uuid_like(client_id) || !uuid_like(organization) {
        return None;
    }
    let scopes = value[position + marker.len()..]
        .split_whitespace()
        .map(str::to_string)
        .collect();
    Some(CacheKey {
        client_id: client_id.to_lowercase(),
        organization: organization.to_lowercase(),
        api_host: API_HOST.into(),
        scopes,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn selects_production_full_scope_over_stale_long_ttl() {
        let active = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
        let other = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb";
        let prod_key =
            format!("{PRODUCTION_CLIENT_ID}:{active}:{API_HOST}:user:profile user:inference");
        let old_key =
            format!("bbbbbbbb-1111-1111-1111-bbbbbbbbbbbb:{active}:{API_HOST}:user:profile");
        let cache = json!({
            prod_key: {"token": "good", "expiresAt": 9_999_999_999_999.0, "subscriptionType": "max"},
            old_key: {"token": "old", "expiresAt": 9_999_999_999_999.0}
        });
        assert_eq!(
            select_credential(active, Some(active), Some(&cache), None, 1_800_000_000.0),
            Selection::Available(ClaudeOAuth {
                access_token: Some("good".into()),
                refresh_token: None,
                expires_at: Some(9_999_999_999_999.0),
                subscription_type: Some("max".into()),
                rate_limit_tier: None,
                scopes: Some(vec!["user:profile".into(), "user:inference".into()]),
            })
        );
        let _ = other;
    }

    #[test]
    fn scoped_entries_require_the_active_account() {
        let active = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
        let key = format!("{PRODUCTION_CLIENT_ID}:{active}:{API_HOST}:user:profile");
        let cache = json!({
            format!("acct:{active}|{key}"): {"token": "yes", "expiresAt": 9_999_999_999_999.0},
            format!("acct:bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb|{key}"): {"token": "no", "expiresAt": 9_999_999_999_999.0}
        });
        match select_credential(active, Some(active), Some(&cache), None, 1_800_000_000.0) {
            Selection::Available(oauth) => assert_eq!(oauth.access_token.as_deref(), Some("yes")),
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn classifies_stale_and_invalid_entries() {
        let active = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
        let key = format!("{PRODUCTION_CLIENT_ID}:{active}:{API_HOST}:user:profile");
        let stale = json!({ key.clone(): {"token": "t", "expiresAt": 1.0} });
        assert_eq!(
            select_credential(active, Some(active), Some(&stale), None, 1_800_000_000.0),
            Selection::Stale
        );
        let invalid = json!({ key: {"token": "t"} });
        assert_eq!(
            select_credential(active, Some(active), Some(&invalid), None, 1_800_000_000.0),
            Selection::Invalid
        );
    }

    #[test]
    fn decrypts_v10_blob_with_zero_iv_and_pkcs7() {
        use cbc::cipher::{BlockEncryptMut, KeyIvInit};
        type Enc = cbc::Encryptor<Aes128>;
        let key = [7u8; 16];
        let iv = [0x20u8; 16];
        let mut payload = b"hello desktop".to_vec();
        let message_len = payload.len();
        payload.resize(message_len + 16, 0);
        let encrypted = Enc::new_from_slices(&key, &iv)
            .unwrap()
            .encrypt_padded_mut::<Pkcs7>(&mut payload, message_len)
            .unwrap()
            .to_vec();
        let mut framed = b"v10".to_vec();
        framed.extend(encrypted);
        assert_eq!(decrypt(&framed, &key).unwrap(), b"hello desktop");
    }
}
