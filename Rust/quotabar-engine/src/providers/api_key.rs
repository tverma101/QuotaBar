//! Shared user-supplied API key storage (Swift `UserAPIKeyStore` + `APIKeyStatus`).
//!
//! Used by providers that take a plain API key from config files or environment variables
//! (OpenRouter, Z.ai). Config files take precedence over environment variables so in-app overrides
//! always beat stale shell environment values.

use crate::host::{self, auth_tag};
use crate::qlog;
use serde::Serialize;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ApiKeyStatus {
    NotSet,
    FromEnvironment,
    Saved,
    OverrideActive,
    SavedUnreadable,
    EnvironmentFallback,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReadKeyError {
    ConfigUnreadable,
}

#[derive(Clone, Debug)]
pub struct ApiKeySpec {
    pub provider_id: &'static str,
    pub config_paths: Vec<PathBuf>,
    pub env_names: &'static [&'static str],
    pub missing_key_error: &'static str,
    pub save_failed_error: &'static str,
    pub delete_failed_error: &'static str,
}

impl ApiKeySpec {
    /// Effective key (`config > env`) without distinguishing unreadable files (used by `currentAPIKey()`).
    pub fn load_key(&self) -> Option<String> {
        self.key_from_config_file().or_else(|| self.key_from_environment())
    }

    /// Key resolution for refresh: keeps scanning later paths/env when an earlier file is unreadable,
    /// and reports `ConfigUnreadable` only if a present file was unreadable and no fallback key exists.
    pub fn load_key_for_refresh(&self) -> Result<Option<String>, ReadKeyError> {
        let mut saw_unreadable = false;
        for path in &self.config_paths {
            if !path.exists() {
                continue;
            }
            match std::fs::read_to_string(path) {
                Ok(text) => {
                    if let Some(key) = key_from_config_text(&text) {
                        return Ok(Some(key));
                    }
                }
                Err(_) => saw_unreadable = true,
            }
        }
        if let Some(env_key) = self.key_from_environment() {
            return Ok(Some(env_key));
        }
        if saw_unreadable {
            return Err(ReadKeyError::ConfigUnreadable);
        }
        Ok(None)
    }

    pub fn has_key_or_unreadable_config(&self) -> bool {
        !matches!(self.load_key_for_refresh(), Ok(None))
    }

    pub fn key_status(&self) -> ApiKeyStatus {
        let has_config = self.key_from_config_file().is_some();
        let has_env = self.key_from_environment().is_some();
        match (has_config, has_env) {
            (true, true) => ApiKeyStatus::OverrideActive,
            (true, false) => ApiKeyStatus::Saved,
            (false, true) => {
                if self.has_unreadable_config_file() {
                    ApiKeyStatus::EnvironmentFallback
                } else {
                    ApiKeyStatus::FromEnvironment
                }
            }
            (false, false) => {
                if self.has_unreadable_config_file() {
                    ApiKeyStatus::SavedUnreadable
                } else {
                    ApiKeyStatus::NotSet
                }
            }
        }
    }

    /// Persist `key` into `config_paths[0]` as `{"apiKey":"..."}`.
    pub fn save_key(&self, key: &str) -> Result<(), String> {
        let trimmed = key.trim();
        if trimmed.is_empty() {
            return Err(self.missing_key_error.to_string());
        }
        let Some(primary) = self.config_paths.first() else {
            return Err(self.save_failed_error.to_string());
        };
        let encoded = serde_json::to_string(&json!({ "apiKey": trimmed }))
            .map_err(|_| self.save_failed_error.to_string())?;
        if let Some(parent) = primary.parent() {
            if let Err(err) = std::fs::create_dir_all(parent) {
                qlog!(Error, auth_tag(self.provider_id), "create API key directory failed: {err}");
                return Err(self.save_failed_error.to_string());
            }
        }
        write_atomic(primary, encoded.as_bytes()).map_err(|err| {
            qlog!(Error, auth_tag(self.provider_id), "save API key failed: {err}");
            self.save_failed_error.to_string()
        })
    }

    /// Remove any saved key files across all candidate paths; missing files are no-ops.
    pub fn delete_key(&self) -> Result<(), String> {
        for path in &self.config_paths {
            if !path.exists() {
                continue;
            }
            if let Err(err) = std::fs::remove_file(path) {
                if err.kind() != std::io::ErrorKind::NotFound {
                    qlog!(Error, auth_tag(self.provider_id), "delete API key failed: {err}");
                    return Err(self.delete_failed_error.to_string());
                }
            }
        }
        Ok(())
    }

    fn key_from_environment(&self) -> Option<String> {
        for name in self.env_names {
            if let Some(val) = host::env_var(name) {
                let trimmed = val.trim();
                if !trimmed.is_empty() {
                    return Some(trimmed.to_string());
                }
            }
        }
        None
    }

    fn key_from_config_file(&self) -> Option<String> {
        for path in &self.config_paths {
            if !path.exists() {
                continue;
            }
            let Ok(text) = std::fs::read_to_string(path) else { continue };
            if let Some(key) = key_from_config_text(&text) {
                return Some(key);
            }
        }
        None
    }

    fn has_unreadable_config_file(&self) -> bool {
        self.config_paths
            .iter()
            .filter(|p| p.exists())
            .any(|p| std::fs::read_to_string(p).is_err())
    }
}

/// Accept `{"apiKey": ...}` / `{"api_key": ...}` / `{"key": ...}`, or plain text without `{`.
pub fn key_from_config_text(text: &str) -> Option<String> {
    if let Ok(Value::Object(obj)) = serde_json::from_str::<Value>(text) {
        for field in ["apiKey", "api_key", "key"] {
            if let Some(val) = obj.get(field).and_then(Value::as_str) {
                let trimmed = val.trim();
                if !trimmed.is_empty() {
                    return Some(trimmed.to_string());
                }
            }
        }
        return None;
    }
    let trimmed = text.trim();
    if trimmed.is_empty() || trimmed.contains('{') {
        None
    } else {
        Some(trimmed.to_string())
    }
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

/// Dispatch `credentialAction` RPC for user API-key providers (`openrouter`, later `zai`).
pub fn dispatch(provider_id: &str, action: &str, key: Option<&str>) -> Result<Value, String> {
    let spec = match provider_id {
        "openrouter" => super::openrouter::auth::live_spec(),
        "zai" => super::zai::auth::live_spec(),
        other => return Err(format!("provider does not support credentialAction: {other}")),
    };
    match action {
        "status" => Ok(json!({ "status": spec.key_status() })),
        "current" => Ok(json!({ "key": spec.load_key() })),
        "save" => {
            spec.save_key(key.unwrap_or(""))?;
            Ok(json!({ "status": spec.key_status() }))
        }
        "delete" => {
            spec.delete_key()?;
            Ok(json!({ "status": spec.key_status() }))
        }
        other => Err(format!("unknown credentialAction: {other}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_json_and_plain_text_keys() {
        assert_eq!(key_from_config_text(r#"{"apiKey":" sk-1 "}"#).as_deref(), Some("sk-1"));
        assert_eq!(key_from_config_text(r#"{"api_key":"sk-2"}"#).as_deref(), Some("sk-2"));
        assert_eq!(key_from_config_text(r#"{"key":"sk-3"}"#).as_deref(), Some("sk-3"));
        assert_eq!(key_from_config_text("  sk-plain\n").as_deref(), Some("sk-plain"));
        assert_eq!(key_from_config_text("   "), None);
        assert_eq!(key_from_config_text("{broken"), None);
    }

    #[test]
    fn save_read_and_delete_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let primary = dir.path().join("primary.json");
        let alt = dir.path().join("alt.txt");
        let spec = ApiKeySpec {
            provider_id: "openrouter",
            config_paths: vec![primary.clone(), alt.clone()],
            env_names: &[],
            missing_key_error: "missing",
            save_failed_error: "save_failed",
            delete_failed_error: "delete_failed",
        };
        assert_eq!(spec.key_status(), ApiKeyStatus::NotSet);
        assert!(spec.save_key("   ").is_err());

        spec.save_key("  sk-or-new  ").unwrap();
        assert_eq!(std::fs::read_to_string(&primary).unwrap(), r#"{"apiKey":"sk-or-new"}"#);
        assert_eq!(spec.key_status(), ApiKeyStatus::Saved);
        assert_eq!(spec.load_key().as_deref(), Some("sk-or-new"));

        std::fs::write(&alt, "sk-alt").unwrap();
        spec.delete_key().unwrap();
        assert!(!primary.exists());
        assert!(!alt.exists());
        assert_eq!(spec.key_status(), ApiKeyStatus::NotSet);
    }
}
