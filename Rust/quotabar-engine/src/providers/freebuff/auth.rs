//! Freebuff CLI credential discovery (`Providers/Freebuff/FreebuffAuthStore`).
//!
//! Reads the CLI's existing `default` profile from `credentials.json`, its Keychain token, or the
//! CLI's `CODEBUFF_API_KEY` fallback. QuotaBar never launches the CLI or admits a session.

use crate::host::{self, SecureAccount, SecureReadOutcome, SecureReadRequest};
use crate::qlog;
use std::path::PathBuf;

pub const KEYCHAIN_SERVICE: &str = "freebuff-cli";
pub const CREDENTIALS_FILE: &str = "credentials.json";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FreebuffAuth {
    pub token: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AuthError {
    NotLoggedIn,
    InvalidConfigDirectory,
    InvalidCredentials,
    CredentialsUnreadable,
    CredentialPermissionRequired,
    MissingDefaultProfile,
    TokenInvalid,
}

impl AuthError {
    pub fn message(&self) -> &'static str {
        match self {
            AuthError::NotLoggedIn => {
                "No Freebuff login was found. Run ~/.config/manicode/freebuff login (or freebuff login if available), then refresh QuotaBar."
            }
            AuthError::InvalidConfigDirectory => "Freebuff's FREEBUFF_CONFIG_DIR must be an absolute path.",
            AuthError::InvalidCredentials => {
                "Freebuff's credentials file is invalid. Sign in again with the Freebuff CLI."
            }
            AuthError::CredentialsUnreadable => {
                "QuotaBar couldn't read Freebuff's local credentials. Check file or Keychain access."
            }
            AuthError::CredentialPermissionRequired => {
                "macOS needs permission to read Freebuff's Keychain item. Choose Always Allow when prompted."
            }
            AuthError::MissingDefaultProfile => {
                "QuotaBar found Freebuff credentials, but they have no `default` profile. Sign in again with the Freebuff CLI, or point FREEBUFF_CONFIG_DIR at the config directory that holds it."
            }
            AuthError::TokenInvalid => "The Freebuff login has expired. Sign in again with the Freebuff CLI.",
        }
    }
}

pub struct FreebuffAuthStore {
    home: PathBuf,
}

impl FreebuffAuthStore {
    pub fn live() -> Self {
        FreebuffAuthStore {
            home: crate::paths::home(),
        }
    }

    pub fn with_home(home: PathBuf) -> Self {
        FreebuffAuthStore { home }
    }

    pub fn credentials_path(&self) -> Result<PathBuf, AuthError> {
        let directory = match host::env_var("FREEBUFF_CONFIG_DIR") {
            Some(configured) if !configured.trim().is_empty() => {
                let configured = configured.trim();
                if !PathBuf::from(configured).is_absolute() {
                    return Err(AuthError::InvalidConfigDirectory);
                }
                PathBuf::from(configured)
            }
            _ => {
                let environment =
                    host::env_var("NEXT_PUBLIC_CB_ENVIRONMENT").unwrap_or_else(|| "prod".into());
                let suffix = if environment == "prod" {
                    String::new()
                } else {
                    format!("-{environment}")
                };
                self.home.join(".config").join(format!("manicode{suffix}"))
            }
        };
        Ok(directory.join(CREDENTIALS_FILE))
    }

    pub fn load_auth(
        &self,
        is_manual: bool,
        request_id: Option<u64>,
    ) -> Result<Option<FreebuffAuth>, AuthError> {
        let path = self.credentials_path()?;
        let contents = match std::fs::read_to_string(&path) {
            Ok(contents) => Some(contents),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(_) => {
                qlog!(
                    Error,
                    host::auth_tag("freebuff"),
                    "credentials file read failed"
                );
                if let Some(fallback) = environment_token() {
                    return Ok(Some(fallback));
                }
                return Err(AuthError::CredentialsUnreadable);
            }
        };
        if let Some(contents) = contents.filter(|contents| !contents.trim().is_empty()) {
            let Ok(root) = serde_json::from_str::<serde_json::Value>(&contents) else {
                qlog!(
                    Error,
                    host::auth_tag("freebuff"),
                    "credentials file contained invalid JSON"
                );
                return environment_token()
                    .map(Some)
                    .ok_or(AuthError::InvalidCredentials);
            };
            let Some(profile) = root.get("default").and_then(|value| value.as_object()) else {
                qlog!(
                    Error,
                    host::auth_tag("freebuff"),
                    "credentials file has no `default` profile"
                );
                return environment_token()
                    .map(Some)
                    .ok_or(AuthError::MissingDefaultProfile);
            };
            if let Some(token) = profile
                .get("authToken")
                .and_then(|value| value.as_str())
                .map(str::trim)
                .filter(|value| !value.is_empty())
            {
                return Ok(Some(FreebuffAuth {
                    token: token.to_string(),
                }));
            }
            if profile.get("tokenStore").and_then(|value| value.as_str()) == Some("keychain") {
                let fallback = environment_token();
                let request = SecureReadRequest {
                    service: KEYCHAIN_SERVICE.into(),
                    account: SecureAccount::Named(path.to_string_lossy().into_owned()),
                    provider: "freebuff".into(),
                    allow_interaction: is_manual && fallback.is_none(),
                    bypass_deferred_read_failure: false,
                    recheck_blocked_silently: fallback.is_some(),
                    request_id,
                };
                match host::secure_read(&request) {
                    SecureReadOutcome::Found { value } => {
                        let token = value.trim();
                        if !token.is_empty() {
                            return Ok(Some(FreebuffAuth {
                                token: token.to_string(),
                            }));
                        }
                    }
                    SecureReadOutcome::InteractionRequired | SecureReadOutcome::Denied => {
                        if let Some(fallback) = fallback {
                            return Ok(Some(fallback));
                        }
                        return Err(AuthError::CredentialPermissionRequired);
                    }
                    SecureReadOutcome::NotFound => {}
                    SecureReadOutcome::Cancelled => return Err(AuthError::CredentialsUnreadable),
                    SecureReadOutcome::Deferred | SecureReadOutcome::Failed { .. } => {}
                }
                if let Some(fallback) = fallback {
                    return Ok(Some(fallback));
                }
            }
            return Ok(environment_token());
        }
        Ok(environment_token())
    }

    pub fn has_local_credentials(&self) -> bool {
        match self.load_auth(false, None) {
            Ok(Some(_)) => true,
            Ok(None) => false,
            Err(AuthError::CredentialPermissionRequired) => true,
            Err(AuthError::MissingDefaultProfile) => true,
            Err(AuthError::InvalidConfigDirectory) => true,
            Err(AuthError::CredentialsUnreadable | AuthError::InvalidCredentials) => self
                .credentials_path()
                .map(|path| path.exists())
                .unwrap_or(false),
            Err(AuthError::NotLoggedIn | AuthError::TokenInvalid) => false,
        }
    }
}

fn environment_token() -> Option<FreebuffAuth> {
    host::env_var("CODEBUFF_API_KEY")
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .map(|token| FreebuffAuth { token })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::{Host, LogLevel};
    use std::collections::HashMap;
    use std::sync::Mutex;

    struct EnvHost(Mutex<HashMap<String, String>>);

    impl Host for EnvHost {
        fn log(&self, _: LogLevel, _: &str, _: &str) {}
        fn log_level(&self) -> LogLevel {
            LogLevel::Error
        }
        fn secure_read(&self, _: &SecureReadRequest) -> SecureReadOutcome {
            SecureReadOutcome::NotFound
        }
        fn env_var(&self, name: &str) -> Option<String> {
            self.0.lock().unwrap().get(name).cloned()
        }
    }

    #[test]
    fn reads_profile_token_and_environment_fallback() {
        let dir = tempfile::tempdir().unwrap();
        let config = dir.path().join(".config/manicode");
        std::fs::create_dir_all(&config).unwrap();
        std::fs::write(
            config.join(CREDENTIALS_FILE),
            r#"{"default":{"authToken":"file-token"}}"#,
        )
        .unwrap();
        let host = EnvHost(Mutex::new(HashMap::new()));
        host::with_test_host(std::sync::Arc::new(host), || {
            let store = FreebuffAuthStore::with_home(dir.path().to_path_buf());
            assert_eq!(
                store.load_auth(false, None).unwrap().unwrap().token,
                "file-token"
            );
            assert!(store.has_local_credentials());
        });

        let host = EnvHost(Mutex::new(HashMap::from([(
            "CODEBUFF_API_KEY".into(),
            "env-token".into(),
        )])));
        host::with_test_host(std::sync::Arc::new(host), || {
            let store = FreebuffAuthStore::with_home(dir.path().join("missing"));
            assert_eq!(
                store.load_auth(false, None).unwrap().unwrap().token,
                "env-token"
            );
        });
    }
}
