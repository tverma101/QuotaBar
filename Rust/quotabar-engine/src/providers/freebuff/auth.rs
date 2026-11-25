//! Freebuff CLI credentials (`FreebuffAuthStore.swift`). Reads the CLI's existing `default` profile:
//! current versions keep the token in Keychain (`freebuff-cli`, account = credentials file path) and
//! leave a pointer in credentials.json; older versions may keep `authToken` in that file.
//! `CODEBUFF_API_KEY` is the CLI's own environment fallback. QuotaBar never launches the CLI.

use super::error::FreebuffError;
use crate::context::RefreshContext;
use crate::host::{self, auth_tag, diagnostic_gate, SecureAccount, SecureReadOutcome, SecureReadRequest};
use crate::qlog;
use serde_json::Value;
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;

pub const ID: &str = "freebuff";
pub const KEYCHAIN_SERVICE: &str = "freebuff-cli";
pub const CREDENTIALS_FILE_NAME: &str = "credentials.json";
const CREDENTIALS_READ_KEY: &str = "auth.freebuff.credentials-read";
const INVALID_CREDENTIALS_KEY: &str = "auth.freebuff.credentials-invalid";
const MISSING_DEFAULT_PROFILE_KEY: &str = "auth.freebuff.credentials-no-default-profile";

/// Swift `FreebuffAuth`: the bearer token and nothing else.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct FreebuffAuth {
    pub token: String,
}

type EnvFn = Arc<dyn Fn(&str) -> Option<String> + Send + Sync>;

#[derive(Clone)]
pub struct FreebuffAuthStore {
    home: PathBuf,
    env: EnvFn,
}

impl FreebuffAuthStore {
    /// The host's environment and the configured home directory.
    pub fn live() -> Self {
        FreebuffAuthStore { home: crate::paths::home(), env: Arc::new(host::env_var) }
    }

    pub fn new(home: PathBuf, env: impl Fn(&str) -> Option<String> + Send + Sync + 'static) -> Self {
        FreebuffAuthStore { home, env: Arc::new(env) }
    }

    fn env(&self, name: &str) -> Option<String> {
        (self.env)(name)
    }

    /// Swift `credentialsFilePath()`.
    pub fn credentials_file_path(&self) -> Result<String, FreebuffError> {
        let directory = match self.env("FREEBUFF_CONFIG_DIR").filter(|v| !v.is_empty()) {
            Some(configured) => {
                if !Path::new(&configured).is_absolute() {
                    return Err(FreebuffError::InvalidConfigDirectory);
                }
                PathBuf::from(configured)
            }
            None => {
                let environment = self.env("NEXT_PUBLIC_CB_ENVIRONMENT").unwrap_or_else(|| "prod".into());
                let suffix = if environment == "prod" { String::new() } else { format!("-{environment}") };
                self.home.join(".config").join(format!("manicode{suffix}"))
            }
        };
        Ok(standardize(&directory.join(CREDENTIALS_FILE_NAME)).to_string_lossy().into_owned())
    }

    /// Swift `loadAuth()`. `ctx` carries the refresh's manual flag and request id for the Keychain
    /// read; `None` is a silent probe.
    pub fn load_auth(&self, ctx: Option<&RefreshContext>) -> Result<Option<FreebuffAuth>, FreebuffError> {
        let path = self.credentials_file_path()?;
        let contents = match std::fs::read_to_string(&path) {
            Ok(text) => Some(text),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(_) => {
                diagnostic_gate::log_once(CREDENTIALS_READ_KEY, || {
                    qlog!(Error, auth_tag(ID), "credentials file read failed");
                });
                if let Some(fallback) = self.environment_token() {
                    return Ok(Some(fallback));
                }
                return Err(FreebuffError::CredentialsUnreadable);
            }
        };
        diagnostic_gate::clear(CREDENTIALS_READ_KEY);

        match contents.filter(|text| !text.trim().is_empty()) {
            Some(text) => {
                let Some(Value::Object(object)) = serde_json::from_str::<Value>(&text).ok() else {
                    diagnostic_gate::log_once(INVALID_CREDENTIALS_KEY, || {
                        qlog!(Error, auth_tag(ID), "credentials file contained invalid JSON");
                    });
                    if let Some(fallback) = self.environment_token() {
                        return Ok(Some(fallback));
                    }
                    return Err(FreebuffError::InvalidCredentials);
                };
                diagnostic_gate::clear(INVALID_CREDENTIALS_KEY);
                let Some(profile) = object.get("default").and_then(Value::as_object) else {
                    // The file parsed but names its profile something else. Report that instead of
                    // "no login was found", which sends the user back to the CLI for a login that
                    // already exists.
                    diagnostic_gate::log_once(MISSING_DEFAULT_PROFILE_KEY, || {
                        qlog!(Error, auth_tag(ID), "credentials file has no `default` profile");
                    });
                    if let Some(fallback) = self.environment_token() {
                        return Ok(Some(fallback));
                    }
                    return Err(FreebuffError::MissingDefaultProfile);
                };
                diagnostic_gate::clear(MISSING_DEFAULT_PROFILE_KEY);

                if let Some(token) = trimmed(profile.get("authToken")) {
                    return Ok(Some(FreebuffAuth { token }));
                }
                if profile.get("tokenStore").and_then(Value::as_str) == Some("keychain") {
                    let fallback = self.environment_token();
                    let mut request = match ctx {
                        Some(ctx) => SecureReadRequest::for_refresh(
                            KEYCHAIN_SERVICE,
                            SecureAccount::Named(path.clone()),
                            ID,
                            ctx,
                        ),
                        None => SecureReadRequest::silent(KEYCHAIN_SERVICE, SecureAccount::Named(path.clone()), ID),
                    };
                    if fallback.is_some() {
                        // A usable CLI environment token is already available. Still prefer the
                        // Keychain value when it can be read silently, but do not open a prompt
                        // that repeated manual refreshes would show again after fallback. A new
                        // manual action may retry an earlier blocked item silently so restored
                        // Keychain access can replace a stale environment token.
                        request.allow_interaction = false;
                        request.recheck_blocked_silently = true;
                    }
                    match host::secure_read(&request) {
                        SecureReadOutcome::Found { value } => {
                            let token = value.trim();
                            if !token.is_empty() {
                                return Ok(Some(FreebuffAuth { token: token.to_string() }));
                            }
                        }
                        SecureReadOutcome::NotFound => {}
                        SecureReadOutcome::InteractionRequired | SecureReadOutcome::Denied => {
                            return match fallback {
                                Some(fallback) => Ok(Some(fallback)),
                                None => Err(FreebuffError::CredentialPermissionRequired),
                            };
                        }
                        SecureReadOutcome::Cancelled => return Err(FreebuffError::Cancelled),
                        SecureReadOutcome::Deferred | SecureReadOutcome::Failed { .. } => {
                            return match fallback {
                                Some(fallback) => Ok(Some(fallback)),
                                None => Err(FreebuffError::CredentialsUnreadable),
                            };
                        }
                    }
                    if let Some(fallback) = fallback {
                        return Ok(Some(fallback));
                    }
                }
            }
            None => diagnostic_gate::clear(INVALID_CREDENTIALS_KEY),
        }
        Ok(self.environment_token())
    }

    /// Swift `hasLocalCredentials()`: a silent, local-only probe that never changes enablement.
    pub fn has_local_credentials(&self) -> bool {
        match self.load_auth(None) {
            Ok(auth) => auth.is_some(),
            Err(FreebuffError::NotLoggedIn) => false,
            // The profile explicitly points to this Keychain item; the silent read proved that the
            // item exists but requires user interaction. The provider is still locally configured.
            Err(FreebuffError::CredentialPermissionRequired) => true,
            // Keep a present but broken profile enabled so the provider can show its typed repair
            // message instead of making a local installation look absent.
            Err(FreebuffError::CredentialsUnreadable | FreebuffError::InvalidCredentials) => {
                self.credentials_file_path().map(|path| Path::new(&path).exists()).unwrap_or(false)
            }
            // The credentials file is present and readable; it just names its profile differently.
            Err(FreebuffError::MissingDefaultProfile) => true,
            // A configured but invalid path is still an explicit Freebuff setup. Keep the provider
            // visible so refresh can show the actionable absolute-path error.
            Err(FreebuffError::InvalidConfigDirectory) => true,
            Err(_) => false,
        }
    }

    fn environment_token(&self) -> Option<FreebuffAuth> {
        trimmed_str(self.env("CODEBUFF_API_KEY")?.as_str()).map(|token| FreebuffAuth { token })
    }
}

fn trimmed(value: Option<&Value>) -> Option<String> {
    trimmed_str(value?.as_str()?)
}

fn trimmed_str(value: &str) -> Option<String> {
    let trimmed = value.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

/// Swift `standardizedFileURL.path`: `.` and `..` folded away lexically, no symlink resolution.
fn standardize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}
