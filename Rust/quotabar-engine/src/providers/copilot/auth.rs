//! Copilot credential loading: editor JSON files, `gh` hosts.yml, and GitHub CLI Keychain.

use crate::context::RefreshContext;
use crate::host::{self, auth_tag, diagnostic_gate, SecureAccount, SecureReadOutcome, SecureReadRequest};
use crate::parse;
use crate::paths;
use crate::qlog;
use serde_json::Value;
use std::path::{Path, PathBuf};

pub const ID: &str = "copilot";
pub const GH_KEYCHAIN_SERVICE: &str = "gh:github.com";

pub const NOT_LOGGED_IN_MSG: &str =
    "Sign in to GitHub Copilot in your editor, or run gh auth login, and try again.";
pub const CREDENTIAL_PERMISSION_MSG: &str =
    "macOS needs permission to read your Copilot Keychain item. Refresh to be asked once, then choose Always Allow.";
pub const CREDENTIALS_UNREADABLE_MSG: &str =
    "QuotaBar couldn't read a Copilot credential source. Check file access for your editor or GitHub CLI config, or unlock your login Keychain, then refresh again.";
pub const INVALID_CREDENTIALS_MSG: &str =
    "QuotaBar found malformed Copilot editor credentials. Repair or remove the invalid apps.json or hosts.json file, then sign in again with your editor or GitHub CLI.";
pub const TOKEN_INVALID_MSG: &str =
    "GitHub token invalid or expired. Re-authenticate (gh auth login) and try again.";
pub const ACCESS_DENIED_MSG: &str =
    "GitHub denied access to Copilot usage. Check your Copilot license and organization policy.";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CopilotAuthError {
    NotLoggedIn,
    CredentialPermissionRequired,
    CredentialsUnreadable,
    InvalidCredentials,
    Cancelled,
}

impl CopilotAuthError {
    pub fn message(self) -> &'static str {
        match self {
            CopilotAuthError::NotLoggedIn => NOT_LOGGED_IN_MSG,
            CopilotAuthError::CredentialPermissionRequired => CREDENTIAL_PERMISSION_MSG,
            CopilotAuthError::CredentialsUnreadable => CREDENTIALS_UNREADABLE_MSG,
            CopilotAuthError::InvalidCredentials => INVALID_CREDENTIALS_MSG,
            CopilotAuthError::Cancelled => "Refresh cancelled.",
        }
    }

    pub fn category(self) -> crate::model::ErrorCategory {
        use crate::model::ErrorCategory;
        match self {
            CopilotAuthError::NotLoggedIn => ErrorCategory::NotLoggedIn,
            CopilotAuthError::CredentialPermissionRequired | CopilotAuthError::CredentialsUnreadable => {
                ErrorCategory::CredentialAccess
            }
            CopilotAuthError::InvalidCredentials => ErrorCategory::AuthInvalid,
            CopilotAuthError::Cancelled => ErrorCategory::Cancelled,
        }
    }
}

#[derive(Clone, Debug)]
pub struct CopilotAuthStore {
    pub editor_apps_path: PathBuf,
    pub editor_hosts_path: PathBuf,
    pub gh_hosts_path: PathBuf,
}

impl CopilotAuthStore {
    pub fn live() -> Self {
        CopilotAuthStore {
            editor_apps_path: paths::expand_home("~/.config/github-copilot/apps.json"),
            editor_hosts_path: paths::expand_home("~/.config/github-copilot/hosts.json"),
            gh_hosts_path: paths::expand_home("~/.config/gh/hosts.yml"),
        }
    }

    pub fn load_token(&self, ctx: Option<&RefreshContext>) -> Result<Option<String>, CopilotAuthError> {
        let mut saw_unreadable = false;
        let mut saw_invalid = false;

        match load_editor_token(&self.editor_apps_path) {
            Ok(Some(tok)) => return Ok(Some(tok)),
            Ok(None) => {}
            Err(CopilotAuthError::CredentialsUnreadable) => saw_unreadable = true,
            Err(CopilotAuthError::InvalidCredentials) => saw_invalid = true,
            Err(other) => return Err(other),
        }

        match load_editor_token(&self.editor_hosts_path) {
            Ok(Some(tok)) => return Ok(Some(tok)),
            Ok(None) => {}
            Err(CopilotAuthError::CredentialsUnreadable) => saw_unreadable = true,
            Err(CopilotAuthError::InvalidCredentials) => saw_invalid = true,
            Err(other) => return Err(other),
        }

        match self.load_gh_token(ctx) {
            Ok(Some(tok)) => return Ok(Some(tok)),
            Ok(None) => {}
            Err(CopilotAuthError::CredentialsUnreadable) => saw_unreadable = true,
            Err(other) => return Err(other),
        }

        if saw_invalid {
            return Err(CopilotAuthError::InvalidCredentials);
        }
        if saw_unreadable {
            return Err(CopilotAuthError::CredentialsUnreadable);
        }
        Ok(None)
    }

    fn load_gh_token(&self, ctx: Option<&RefreshContext>) -> Result<Option<String>, CopilotAuthError> {
        let yaml = match read_optional_file(&self.gh_hosts_path) {
            FileState::Missing => None,
            FileState::Unreadable => {
                // Without a readable username, a service-only Keychain lookup could select a different account.
                return Err(CopilotAuthError::CredentialsUnreadable);
            }
            FileState::Present(text) => Some(text),
        };
        if let Some(ref text) = yaml {
            if let Some(tok) = yaml_value(text, "oauth_token", "github.com") {
                return Ok(Some(decode_gh_token(&tok)));
            }
        }
        let account = yaml.as_deref().and_then(|t| yaml_value(t, "user", "github.com"));
        let req = match account {
            Some(user) => match ctx {
                Some(ctx) => SecureReadRequest::for_refresh(
                    GH_KEYCHAIN_SERVICE,
                    SecureAccount::Named(user),
                    ID,
                    ctx,
                ),
                None => SecureReadRequest::silent(GH_KEYCHAIN_SERVICE, SecureAccount::Named(user), ID),
            },
            None => match ctx {
                Some(ctx) => SecureReadRequest::for_refresh(
                    GH_KEYCHAIN_SERVICE,
                    SecureAccount::Any,
                    ID,
                    ctx,
                ),
                None => SecureReadRequest::silent(GH_KEYCHAIN_SERVICE, SecureAccount::Any, ID),
            },
        };
        match host::secure_read(&req) {
            SecureReadOutcome::Found { value: raw } => {
                let decoded = decode_gh_token(&raw);
                if decoded.is_empty() {
                    Ok(None)
                } else {
                    Ok(Some(decoded))
                }
            }
            SecureReadOutcome::NotFound => Ok(None),
            SecureReadOutcome::InteractionRequired | SecureReadOutcome::Denied => {
                Err(CopilotAuthError::CredentialPermissionRequired)
            }
            SecureReadOutcome::Cancelled => Err(CopilotAuthError::Cancelled),
            SecureReadOutcome::Deferred | SecureReadOutcome::Failed { .. } => {
                Err(CopilotAuthError::CredentialsUnreadable)
            }
        }
    }
}

enum FileState {
    Missing,
    Unreadable,
    Present(String),
}

fn read_optional_file(path: &Path) -> FileState {
    if !path.exists() {
        return FileState::Missing;
    }
    match std::fs::read_to_string(path) {
        Ok(text) => {
            diagnostic_gate::clear(&format!("auth.copilot.read.{}", file_fingerprint(path)));
            FileState::Present(text)
        }
        Err(_) => {
            diagnostic_gate::log_once(&format!("auth.copilot.read.{}", file_fingerprint(path)), || {
                qlog!(Error, auth_tag(ID), "copilot credential file read failed");
            });
            FileState::Unreadable
        }
    }
}

fn load_editor_token(path: &Path) -> Result<Option<String>, CopilotAuthError> {
    let text = match read_optional_file(path) {
        FileState::Missing => return Ok(None),
        FileState::Unreadable => return Err(CopilotAuthError::CredentialsUnreadable),
        FileState::Present(t) => t,
    };
    let Ok(Value::Object(root)) = serde_json::from_str::<Value>(&text) else {
        return Err(CopilotAuthError::InvalidCredentials);
    };
    for (host, entry) in root {
        if !(host == "github.com" || host.starts_with("github.com:")) {
            continue;
        }
        let Some(obj) = entry.as_object() else {
            return Err(CopilotAuthError::InvalidCredentials);
        };
        match obj.get("oauth_token") {
            None | Some(Value::Null) => continue,
            Some(Value::String(s)) => {
                let trimmed = s.trim();
                if !trimmed.is_empty() {
                    return Ok(Some(trimmed.to_string()));
                }
            }
            Some(_) => return Err(CopilotAuthError::InvalidCredentials),
        }
    }
    Ok(None)
}

pub fn decode_gh_token(raw: &str) -> String {
    let trimmed = raw.trim();
    if let Some(encoded) = trimmed.strip_prefix("go-keyring-base64:") {
        if let Some(bytes) = parse::decode_base64(encoded) {
            if let Ok(text) = String::from_utf8(bytes) {
                return text.trim().to_string();
            }
        }
    }
    trimmed.to_string()
}

pub fn yaml_value(text: &str, key: &str, host: &str) -> Option<String> {
    let prefix = format!("{key}:");
    let host_header = format!("{host}:");
    let mut in_host = false;
    for line in text.lines() {
        let Some(first) = line.chars().next() else {
            continue;
        };
        if !first.is_whitespace() {
            in_host = line.trim().starts_with(&host_header);
            continue;
        }
        if !in_host {
            continue;
        }
        let trimmed = line.trim();
        let Some(rest) = trimmed.strip_prefix(&prefix) else {
            continue;
        };
        let value = rest.trim().trim_matches(|c| c == '"' || c == '\'');
        if !value.is_empty() {
            return Some(value.to_string());
        }
    }
    None
}

fn file_fingerprint(path: &Path) -> String {
    use sha2::{Digest, Sha256};
    Sha256::digest(path.to_string_lossy().as_bytes())
        .iter()
        .take(8)
        .map(|b| format!("{b:02x}"))
        .collect()
}
