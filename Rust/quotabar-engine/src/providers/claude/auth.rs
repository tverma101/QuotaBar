//! Claude credential resolution (Swift `ClaudeAuthStore`,
//! `ClaudeDesktopAuthStore`, `ClaudeAuthStore+Keychain`).
//!
//! Sources are probed keychain-before-file, with Claude Desktop as an optional
//! read-only source. The Desktop cache is Electron Safe Storage: an AES-128-CBC
//! blob under a key derived from the Keychain password with PBKDF2-SHA1.

use super::desktop::{
    ClaudeDesktopCredentialResult, ClaudeDesktopCredentialStatus, ClaudeDesktopStore,
};
use crate::host::{
    self, auth_tag, SecureAccount, SecureReadOutcome, SecureReadRequest, SecureWriteOutcome,
    SecureWriteRequest,
};
use crate::paths;
use crate::providers::private_file;
use crate::qlog;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::path::PathBuf;
use std::sync::Arc;

pub type EnvLookup = Arc<dyn Fn(&str) -> Option<String> + Send + Sync>;

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeOAuth {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub access_token: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refresh_token: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subscription_type: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rate_limit_tier: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scopes: Option<Vec<String>>,
}

impl ClaudeOAuth {
    pub fn usable_access_token(&self) -> Option<&str> {
        self.access_token
            .as_deref()
            .map(str::trim)
            .filter(|token| !token.is_empty())
    }

    pub fn needs_refresh(&self, now: f64) -> bool {
        let Some(expires_at) = self.expires_at else {
            return false;
        };
        expires_at - now * 1000.0 <= 5.0 * 60.0 * 1000.0
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum ClaudeSource {
    File,
    KeychainCurrentUser(String),
    KeychainLegacy(String),
    Desktop,
    Environment,
}

impl ClaudeSource {
    pub fn label(&self) -> &str {
        match self {
            ClaudeSource::File => "file",
            ClaudeSource::KeychainCurrentUser(_) => "keychainCurrentUser",
            ClaudeSource::KeychainLegacy(_) => "keychainLegacy",
            ClaudeSource::Desktop => "desktop",
            ClaudeSource::Environment => "environment",
        }
    }
}

#[derive(Clone, Debug)]
pub struct ClaudeCredentialState {
    pub oauth: ClaudeOAuth,
    pub source: ClaudeSource,
    pub raw_text: Option<String>,
    pub inference_only: bool,
}

impl ClaudeCredentialState {
    pub fn has_usable_access_token(&self) -> bool {
        self.oauth.usable_access_token().is_some()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LiveUsageAvailability {
    Available,
    InferenceOnlyToken,
    MissingProfileScope,
}

#[derive(Clone, Debug)]
pub struct ClaudeCredentialLoad {
    pub candidates: Vec<ClaudeCredentialState>,
    pub desktop_status: ClaudeDesktopCredentialStatus,
    pub keychain_permission_required: bool,
    pub keychain_read_failed: bool,
    pub keychain_read_cancelled: bool,
    pub credentials_file_unreadable: bool,
    pub credentials_file_invalid: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ClaudeAuthError {
    NotLoggedIn,
    CredentialPermissionRequired,
    CredentialKeychainReadFailed,
    DesktopPermissionRequired,
    DesktopTokenExpired,
    DesktopCredentialsUnavailable,
    SessionExpired,
    TokenExpired,
    CredentialsChanged,
    InvalidOAuthUrl(String),
}

impl ClaudeAuthError {
    pub fn message(&self) -> String {
        match self {
            ClaudeAuthError::NotLoggedIn => "Not logged in. Run `claude` to authenticate.".into(),
            ClaudeAuthError::CredentialPermissionRequired => {
                "Claude Code login found in the macOS Keychain. Refresh manually and choose Always Allow when macOS asks for access.".into()
            }
            ClaudeAuthError::CredentialKeychainReadFailed => {
                "QuotaBar couldn't read Claude Code login from the macOS Keychain. Check Keychain access, then refresh again.".into()
            }
            ClaudeAuthError::DesktopPermissionRequired => {
                "Claude Desktop login found. Refresh to be asked once, then choose Always Allow to connect it.".into()
            }
            ClaudeAuthError::DesktopTokenExpired => {
                "Claude Desktop login is stale. Open Claude Desktop, then refresh QuotaBar.".into()
            }
            ClaudeAuthError::DesktopCredentialsUnavailable => {
                "Claude Desktop login couldn't be read. Open Claude Desktop, then try again.".into()
            }
            ClaudeAuthError::SessionExpired => "Session expired. Run `claude` to log in again.".into(),
            ClaudeAuthError::TokenExpired => "Token expired. Run `claude` to log in again.".into(),
            ClaudeAuthError::CredentialsChanged => {
                "Claude login changed during refresh. Refresh again.".into()
            }
            ClaudeAuthError::InvalidOAuthUrl(value) => format!(
                "Invalid Claude OAuth URL: {value}. Check CLAUDE_CODE_CUSTOM_OAUTH_URL / CLAUDE_LOCAL_OAUTH_API_BASE."
            ),
        }
    }

    pub fn allows_auth_fallback(&self) -> bool {
        matches!(
            self,
            ClaudeAuthError::SessionExpired
                | ClaudeAuthError::TokenExpired
                | ClaudeAuthError::DesktopTokenExpired
        )
    }
}

#[derive(Clone, Debug)]
pub struct ClaudeOAuthConfig {
    pub usage_url: String,
    pub refresh_url: String,
    pub client_id: String,
}

#[derive(Clone, Debug)]
pub struct ClaudeProviderConfig {
    pub card_id: Option<String>,
    pub display_name: Option<String>,
    pub account_uuid: Option<String>,
    pub organization_uuid: Option<String>,
    pub expected_identity_key: Option<String>,
    pub desktop_organization: Option<String>,
    pub desktop_only: bool,
    pub prefer_organization_scoped_desktop: bool,
    pub allows_unattributed_sessions: bool,
    pub allows_unattributed_pi_usage: bool,
}

impl ClaudeProviderConfig {
    pub fn from_value(value: Option<&Value>) -> Self {
        let map = value.and_then(Value::as_object);
        let string = |key: &str| {
            map.and_then(|m| m.get(key))
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
        };
        let flag = |key: &str, default: bool| {
            map.and_then(|m| m.get(key))
                .and_then(Value::as_bool)
                .unwrap_or(default)
        };
        ClaudeProviderConfig {
            card_id: string("cardID").or_else(|| string("providerID")),
            display_name: string("displayName"),
            account_uuid: string("accountUUID").or_else(|| string("accountUuid")),
            organization_uuid: string("organizationUUID").or_else(|| string("organizationUuid")),
            expected_identity_key: string("expectedIdentityKey"),
            desktop_organization: string("desktopOrganization"),
            desktop_only: flag("desktopOnly", false),
            prefer_organization_scoped_desktop: flag("preferOrganizationScopedDesktop", false),
            allows_unattributed_sessions: flag("allowsUnattributedSessions", true),
            allows_unattributed_pi_usage: flag("allowsUnattributedPiUsage", true),
        }
    }

    pub fn expected_user(&self) -> Option<&str> {
        self.expected_identity_key.as_deref()?.split('|').next()
    }
}

pub struct ClaudeAuthStore {
    pub home: PathBuf,
    pub env: EnvLookup,
    pub expected_identity_key: Option<String>,
    pub desktop_organization: Option<String>,
    pub desktop_only: bool,
    pub prefer_organization_scoped_desktop: bool,
}

impl ClaudeAuthStore {
    pub fn live(config: &ClaudeProviderConfig) -> Self {
        ClaudeAuthStore {
            home: paths::home(),
            env: Arc::new(host::env_var),
            expected_identity_key: config
                .expected_identity_key
                .as_ref()
                .map(|v| v.to_lowercase()),
            desktop_organization: config
                .desktop_organization
                .as_ref()
                .map(|v| v.to_lowercase()),
            desktop_only: config.desktop_only,
            prefer_organization_scoped_desktop: config.prefer_organization_scoped_desktop,
        }
    }

    pub fn new(home: PathBuf, env: EnvLookup) -> Self {
        ClaudeAuthStore {
            home,
            env,
            expected_identity_key: None,
            desktop_organization: None,
            desktop_only: false,
            prefer_organization_scoped_desktop: false,
        }
    }

    fn env_text(&self, name: &str) -> Option<String> {
        (self.env)(name)
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
    }

    fn env_flag(&self, name: &str) -> bool {
        self.env_text(name)
            .map(|value| value.to_lowercase())
            .map(|value| !matches!(value.as_str(), "0" | "false" | "no" | "off"))
            .unwrap_or(false)
    }

    pub fn claude_home(&self) -> PathBuf {
        self.env_text("CLAUDE_CONFIG_DIR")
            .map(|p| paths::expand_home(&p))
            .unwrap_or_else(|| self.home.join(".claude"))
    }

    pub fn credentials_path(&self) -> PathBuf {
        self.claude_home().join(".credentials.json")
    }

    fn endpoints(&self) -> (String, String, String, String) {
        let mut base_api = "https://api.anthropic.com".to_string();
        let mut refresh = "https://platform.claude.com/v1/oauth/token".to_string();
        let mut client_id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e".to_string();
        let mut suffix = String::new();
        let is_ant = self.env_text("USER_TYPE").as_deref() == Some("ant");
        if is_ant && self.env_flag("USE_LOCAL_OAUTH") {
            let base = self
                .env_text("CLAUDE_LOCAL_OAUTH_API_BASE")
                .unwrap_or_else(|| "http://localhost:8000".into())
                .trim_end_matches('/')
                .to_string();
            base_api = base.clone();
            refresh = format!("{base}/v1/oauth/token");
            client_id = "22422756-60c9-4084-8eb7-27705fd5cf9a".into();
            suffix = "-local-oauth".into();
        } else if is_ant && self.env_flag("USE_STAGING_OAUTH") {
            base_api = "https://api-staging.anthropic.com".into();
            refresh = "https://platform.staging.ant.dev/v1/oauth/token".into();
            client_id = "22422756-60c9-4084-8eb7-27705fd5cf9a".into();
            suffix = "-staging-oauth".into();
        }
        if let Some(custom) = self.env_text("CLAUDE_CODE_CUSTOM_OAUTH_URL") {
            let base = custom.trim_end_matches('/').to_string();
            base_api = base.clone();
            refresh = format!("{base}/v1/oauth/token");
            suffix = "-custom-oauth".into();
        }
        if let Some(override_id) = self.env_text("CLAUDE_CODE_OAUTH_CLIENT_ID") {
            client_id = override_id;
        }
        (base_api, refresh, client_id, suffix)
    }

    pub fn oauth_config(&self) -> Result<ClaudeOAuthConfig, ClaudeAuthError> {
        let (base, refresh, client_id, _) = self.endpoints();
        let usage_url = format!("{base}/api/oauth/usage");
        reqwest::Url::parse(&usage_url)
            .map_err(|_| ClaudeAuthError::InvalidOAuthUrl(usage_url.clone()))?;
        reqwest::Url::parse(&refresh)
            .map_err(|_| ClaudeAuthError::InvalidOAuthUrl(refresh.clone()))?;
        Ok(ClaudeOAuthConfig {
            usage_url,
            refresh_url: refresh,
            client_id,
        })
    }

    pub fn keychain_service_candidates(&self) -> Vec<String> {
        let (_, _, _, suffix) = self.endpoints();
        let base = format!("Claude Code{suffix}-credentials");
        match self.claude_home_override() {
            Some(config_dir) => vec![format!("{base}-{}", hash_prefix(&config_dir, 8)), base],
            None => vec![base],
        }
    }

    fn claude_home_override(&self) -> Option<String> {
        self.env_text("CLAUDE_CONFIG_DIR")
    }

    pub fn live_usage_availability(&self, state: &ClaudeCredentialState) -> LiveUsageAvailability {
        if state.inference_only {
            return LiveUsageAvailability::InferenceOnlyToken;
        }
        match &state.oauth.scopes {
            Some(scopes) if !scopes.is_empty() => {
                if scopes.iter().any(|scope| scope == "user:profile") {
                    LiveUsageAvailability::Available
                } else {
                    LiveUsageAvailability::MissingProfileScope
                }
            }
            _ => LiveUsageAvailability::Available,
        }
    }

    pub fn load_credential_set(
        &self,
        ctx: Option<&crate::context::RefreshContext>,
        force_desktop_fallback: bool,
    ) -> ClaudeCredentialLoad {
        let mut desktop_status = ClaudeDesktopCredentialStatus::NotChecked;
        let desktop = ClaudeDesktopStore::new(self.home.clone());
        let mut stored = Vec::new();
        let mut keychain_permission_required = false;
        let mut keychain_read_failed = false;
        let mut file_unreadable = false;
        let mut file_invalid = false;

        if !self.desktop_only && !force_desktop_fallback {
            let keychain = self.load_keychain(ctx);
            keychain_permission_required = keychain.0;
            keychain_read_failed = keychain.1;
            if let Some(state) = keychain.2 {
                stored.push(state);
            }
            let (file, unreadable, invalid) = self.load_file();
            file_unreadable = unreadable;
            file_invalid = invalid;
            if let Some(state) = file {
                stored.push(state);
            }
        }

        let has_usable_cli = stored.iter().any(|state| {
            state.has_usable_access_token()
                && self.live_usage_availability(state) == LiveUsageAvailability::Available
        });
        if force_desktop_fallback || !has_usable_cli || self.prefer_organization_scoped_desktop {
            let result: ClaudeDesktopCredentialResult = desktop.load(
                ctx,
                self.desktop_organization.as_deref(),
                self.expected_user(),
            );
            desktop_status = result.status;
            if let Some(oauth) = result.oauth {
                stored.insert(
                    0,
                    ClaudeCredentialState {
                        oauth,
                        source: ClaudeSource::Desktop,
                        raw_text: None,
                        inference_only: false,
                    },
                );
            }
        }

        let candidates = if self.desktop_only {
            stored
        } else {
            self.applying_environment_token(stored)
        };
        ClaudeCredentialLoad {
            candidates,
            desktop_status,
            keychain_permission_required,
            keychain_read_failed,
            keychain_read_cancelled: false,
            credentials_file_unreadable: file_unreadable,
            credentials_file_invalid: file_invalid,
        }
    }

    pub fn has_keychain_credential_material(&self) -> Option<bool> {
        if self.desktop_only {
            return Some(false);
        }
        let mut probe_failed = false;
        for service in self.keychain_service_candidates() {
            match host::secure_exists(&service) {
                Some(true) => return Some(true),
                Some(false) => {}
                None => probe_failed = true,
            }
        }
        if probe_failed {
            None
        } else {
            Some(false)
        }
    }

    fn expected_user(&self) -> Option<&str> {
        self.expected_identity_key.as_deref()?.split('|').next()
    }

    fn load_keychain(
        &self,
        ctx: Option<&crate::context::RefreshContext>,
    ) -> (bool, bool, Option<ClaudeCredentialState>) {
        let mut permission_required = false;
        let mut read_failed = false;
        for service in self.keychain_service_candidates() {
            for (account, source) in [
                (
                    SecureAccount::CurrentUser,
                    ClaudeSource::KeychainCurrentUser(service.clone()),
                ),
                (
                    SecureAccount::Any,
                    ClaudeSource::KeychainLegacy(service.clone()),
                ),
            ] {
                match self.read_keychain(&service, &account, ctx) {
                    Ok(Some(value)) => {
                        if let Some(state) = parse_keychain_state(&value, source) {
                            return (permission_required, read_failed, Some(state));
                        }
                    }
                    Ok(None) => {}
                    Err(ReadFailure::Permission) => permission_required = true,
                    Err(ReadFailure::Cancelled) => {
                        return (permission_required, read_failed, None);
                    }
                    Err(ReadFailure::Failed) => read_failed = true,
                }
            }
        }
        (permission_required, read_failed, None)
    }

    fn read_keychain(
        &self,
        service: &str,
        account: &SecureAccount,
        ctx: Option<&crate::context::RefreshContext>,
    ) -> Result<Option<String>, ReadFailure> {
        let request = match ctx {
            Some(ctx) => SecureReadRequest::for_refresh(service, account.clone(), "claude", ctx),
            None => SecureReadRequest::silent(service, account.clone(), "claude"),
        };
        match host::secure_read(&request) {
            SecureReadOutcome::Found { value } => Ok(Some(value)),
            SecureReadOutcome::NotFound => Ok(None),
            SecureReadOutcome::InteractionRequired
            | SecureReadOutcome::Denied
            | SecureReadOutcome::Deferred => Err(ReadFailure::Permission),
            SecureReadOutcome::Cancelled => Err(ReadFailure::Cancelled),
            SecureReadOutcome::Failed { .. } => Err(ReadFailure::Failed),
        }
    }

    fn load_file(&self) -> (Option<ClaudeCredentialState>, bool, bool) {
        let path = self.credentials_path();
        let text = match std::fs::read_to_string(&path) {
            Ok(text) => text,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return (None, false, false)
            }
            Err(_) => return (None, true, false),
        };
        let Some(oauth) = parse_credentials(&text) else {
            return (None, false, true);
        };
        if oauth.usable_access_token().is_none() {
            return (None, false, true);
        }
        (
            Some(ClaudeCredentialState {
                oauth,
                source: ClaudeSource::File,
                raw_text: Some(text),
                inference_only: false,
            }),
            false,
            false,
        )
    }

    fn applying_environment_token(
        &self,
        stored: Vec<ClaudeCredentialState>,
    ) -> Vec<ClaudeCredentialState> {
        let Some(env_token) = self.env_text("CLAUDE_CODE_OAUTH_TOKEN") else {
            return stored;
        };
        let live_capable: Vec<ClaudeCredentialState> = stored
            .iter()
            .filter(|state| self.live_usage_availability(state) == LiveUsageAvailability::Available)
            .cloned()
            .collect();
        let base = live_capable.first().or_else(|| stored.first());
        let mut oauth = base.map(|state| state.oauth.clone()).unwrap_or_default();
        oauth.access_token = Some(env_token);
        let env = ClaudeCredentialState {
            oauth,
            source: ClaudeSource::Environment,
            raw_text: None,
            inference_only: true,
        };
        if live_capable.is_empty() {
            vec![env]
        } else {
            let mut out = live_capable;
            out.push(env);
            out
        }
    }

    /// Persist a rotated token only while the same credential generation is
    /// still current. Token material is never written into logs.
    pub fn save(
        &self,
        state: &ClaudeCredentialState,
        expected: &[ClaudeCredentialState],
    ) -> Result<bool, ClaudeAuthError> {
        let current = self.load_credential_set(None, false);
        let same = generation(&current.candidates) == generation(expected);
        if !same {
            return Ok(false);
        }
        let Some(text) = patch_credentials(state.raw_text.as_deref(), &state.oauth) else {
            return Ok(false);
        };
        match &state.source {
            ClaudeSource::File => {
                private_file::write_private_file(&self.credentials_path(), text.as_bytes())
                    .map_err(|_| ClaudeAuthError::CredentialsChanged)?
            }
            ClaudeSource::KeychainCurrentUser(service) => {
                write_keychain(service, &SecureAccount::CurrentUser, &text)?
            }
            ClaudeSource::KeychainLegacy(service) => {
                write_keychain(service, &SecureAccount::Any, &text)?
            }
            ClaudeSource::Desktop | ClaudeSource::Environment => return Ok(false),
        }
        qlog!(
            Debug,
            auth_tag("claude"),
            "persisted rotated credentials (source={})",
            state.source.label()
        );
        Ok(true)
    }
}

fn generation(states: &[ClaudeCredentialState]) -> Vec<(ClaudeSource, ClaudeOAuth)> {
    states
        .iter()
        .filter(|state| state.has_usable_access_token() && !state.inference_only)
        .map(|state| (state.source.clone(), state.oauth.clone()))
        .collect()
}

fn write_keychain(
    service: &str,
    account: &SecureAccount,
    value: &str,
) -> Result<(), ClaudeAuthError> {
    let request = SecureWriteRequest {
        service: service.to_string(),
        account: account.clone(),
        value: value.to_string(),
        provider: "claude".into(),
    };
    match host::secure_write(&request) {
        SecureWriteOutcome::Written => Ok(()),
        SecureWriteOutcome::Failed { .. } => Err(ClaudeAuthError::CredentialsChanged),
    }
}

enum ReadFailure {
    Permission,
    Cancelled,
    Failed,
}

pub fn parse_credentials(text: &str) -> Option<ClaudeOAuth> {
    let root = parse_json_value(text)?;
    serde_json::from_value::<ClaudeOAuth>(root.get("claudeAiOauth")?.clone()).ok()
}

fn parse_keychain_state(value: &str, source: ClaudeSource) -> Option<ClaudeCredentialState> {
    let oauth = parse_credentials(value)?;
    if oauth.usable_access_token().is_none() {
        return None;
    }
    Some(ClaudeCredentialState {
        oauth,
        source,
        raw_text: Some(value.to_string()),
        inference_only: false,
    })
}

/// Parse JSON, then a hex-encoded JSON blob (Swift `decodeJSONWithHexFallback`).
fn parse_json_value(text: &str) -> Option<Value> {
    if let Ok(value) = serde_json::from_str::<Value>(text) {
        return Some(value);
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

/// Merge the refreshed OAuth object into the existing payload without dropping
/// sibling or future fields (Swift `patchCredentials`).
pub fn patch_credentials(raw_text: Option<&str>, new_oauth: &ClaudeOAuth) -> Option<String> {
    let mut root: Map<String, Value> = raw_text
        .and_then(|text| serde_json::from_str::<Value>(text).ok())
        .and_then(|value| value.as_object().cloned())
        .unwrap_or_default();
    let oauth_value = serde_json::to_value(new_oauth).ok()?;
    let mut merged = root
        .get("claudeAiOauth")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    if let Value::Object(fields) = oauth_value {
        for (key, value) in fields {
            merged.insert(key, value);
        }
    }
    root.insert("claudeAiOauth".into(), Value::Object(merged));
    serde_json::to_string(&Value::Object(root)).ok()
}

fn hash_prefix(value: &str, length: usize) -> String {
    let digest = Sha256::digest(value.as_bytes());
    digest
        .iter()
        .flat_map(|byte| format!("{byte:02x}").chars().collect::<Vec<_>>())
        .take(length)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_oauth_and_hex_credentials() {
        let text = r#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":123,"subscriptionType":"max"}}"#;
        let oauth = parse_credentials(text).unwrap();
        assert_eq!(oauth.access_token.as_deref(), Some("a"));
        assert_eq!(oauth.expires_at, Some(123.0));

        let hex: String = text.bytes().map(|b| format!("{b:02x}")).collect();
        assert_eq!(
            parse_credentials(&hex).unwrap().access_token.as_deref(),
            Some("a")
        );
        assert!(parse_credentials("not json").is_none());
    }

    #[test]
    fn patch_keeps_unknown_siblings_and_fields() {
        let raw = r#"{"claudeAiOauth":{"accessToken":"old","future":7},"sibling":true}"#;
        let patch = patch_credentials(
            Some(raw),
            &ClaudeOAuth {
                access_token: Some("new".into()),
                ..Default::default()
            },
        )
        .unwrap();
        let value: Value = serde_json::from_str(&patch).unwrap();
        assert_eq!(value["claudeAiOauth"]["accessToken"], "new");
        assert_eq!(value["claudeAiOauth"]["future"], 7);
        assert_eq!(value["sibling"], true);
    }

    #[test]
    fn plan_format_matches_swift() {
        assert_eq!(
            super::super::mapper::format_plan(Some("max"), Some("20x")),
            Some("Max 20x".into())
        );
        assert_eq!(super::super::mapper::format_plan(None, None), None);
        assert_eq!(
            super::super::mapper::format_plan(Some("  "), Some("20x")),
            None
        );
    }

    #[test]
    fn scope_availability_distinguishes_inference_only() {
        let store = ClaudeAuthStore::new(PathBuf::from("/tmp/none"), Arc::new(|_| None));
        let mut state = ClaudeCredentialState {
            oauth: ClaudeOAuth {
                scopes: Some(vec!["user:inference".into()]),
                ..Default::default()
            },
            source: ClaudeSource::File,
            raw_text: None,
            inference_only: false,
        };
        assert_eq!(
            store.live_usage_availability(&state),
            LiveUsageAvailability::MissingProfileScope
        );
        state.inference_only = true;
        assert_eq!(
            store.live_usage_availability(&state),
            LiveUsageAvailability::InferenceOnlyToken
        );
        state.inference_only = false;
        state.oauth.scopes = None;
        assert_eq!(
            store.live_usage_availability(&state),
            LiveUsageAvailability::Available
        );
    }

    #[test]
    fn provider_config_reads_card_fields() {
        let config = ClaudeProviderConfig::from_value(Some(&json!({
            "cardID": "claude-work",
            "displayName": "Claude Work",
            "expectedIdentityKey": "User|Org",
            "desktopOnly": true
        })));
        assert_eq!(config.card_id.as_deref(), Some("claude-work"));
        assert_eq!(config.expected_user(), Some("User"));
        assert!(config.desktop_only);
    }
}
