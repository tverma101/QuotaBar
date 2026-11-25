//! OpenCode credentials (`Providers/OpenCode/OpenCodeAuthStore` and `OpenCodeGoKeyStore`).
//!
//! Two local sources feed the Go account endpoint: OpenCode's own `auth.json` entry named
//! `opencode-go`, and keys the user saved in QuotaBar (`opencode-go-keys.json`). Both are plain
//! local files; neither is ever logged.

use crate::paths;
use crate::qlog;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

pub const AUTH_FILE: &str = "auth.json";
pub const SAVED_KEYS_FILE: &str = "opencode-go-keys.json";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SavedGoKey {
    pub id: String,
    pub label: String,
    pub key: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeySource {
    AuthFile,
    AppSaved,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GoKey {
    pub name: String,
    pub key: String,
    pub id: String,
    pub source: KeySource,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AuthError {
    CredentialsUnreadable(String),
}

impl AuthError {
    pub fn message(&self) -> &'static str {
        match self {
            AuthError::CredentialsUnreadable(_) => {
                "Couldn't read OpenCode credentials. Check auth.json and QuotaBar's saved Go keys, then refresh again."
            }
        }
    }

    pub fn detail(&self) -> &str {
        match self {
            AuthError::CredentialsUnreadable(detail) => detail,
        }
    }
}

/// Resolve OpenCode's data directory: `OPENCODE_DATA_DIR`, then `$XDG_DATA_HOME/opencode`, then
/// `~/.local/share/opencode`.
pub fn data_directory(home: &Path, env: &dyn Fn(&str) -> Option<String>) -> PathBuf {
    if let Some(override_dir) = env("OPENCODE_DATA_DIR")
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
    {
        return paths::expand_home(&override_dir);
    }
    if let Some(xdg) = env("XDG_DATA_HOME")
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
    {
        return paths::expand_home(&xdg).join("opencode");
    }
    home.join(".local/share/opencode")
}

pub fn auth_file_path(data_directory: &Path) -> PathBuf {
    data_directory.join(AUTH_FILE)
}

pub fn saved_keys_path(app_data: &Path) -> PathBuf {
    app_data.join(SAVED_KEYS_FILE)
}

/// Every `opencode*.db` file in the data directory, path-sorted. A missing directory is the normal
/// "never used OpenCode" case; an existing but unreadable directory is an error.
pub fn database_files(data_directory: &Path) -> Result<Vec<PathBuf>, AuthError> {
    let entries = match std::fs::read_dir(data_directory) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(AuthError::CredentialsUnreadable(error.to_string())),
    };
    let mut files = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|e| AuthError::CredentialsUnreadable(e.to_string()))?;
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if name.starts_with("opencode") && name.ends_with(".db") {
            files.push(entry.path());
        }
    }
    files.sort();
    Ok(files)
}

/// Read only the `opencode-go` API entries from `auth.json`. An absent file is `Ok(Vec::new())`; a
/// present but malformed file is unreadable, never "not logged in".
pub fn load_auth_file_keys(data_directory: &Path) -> Result<Vec<GoKey>, AuthError> {
    let path = auth_file_path(data_directory);
    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(AuthError::CredentialsUnreadable(error.to_string())),
    };
    let Ok(serde_json::Value::Object(root)) = serde_json::from_str::<serde_json::Value>(&text)
    else {
        return Err(AuthError::CredentialsUnreadable(
            "auth.json is not valid JSON".into(),
        ));
    };
    let mut keys: Vec<GoKey> = root
        .iter()
        .filter_map(|(name, value)| {
            if !name.eq_ignore_ascii_case("opencode-go") {
                return None;
            }
            let entry = value.as_object()?;
            if entry.get("type").and_then(|v| v.as_str()) != Some("api") {
                return None;
            }
            let key = entry.get("key").and_then(|v| v.as_str())?.trim();
            (!key.is_empty()).then(|| GoKey {
                name: name.clone(),
                key: key.to_string(),
                id: name.clone(),
                source: KeySource::AuthFile,
            })
        })
        .collect();
    keys.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(keys)
}

/// Read QuotaBar's saved Go-key list. Absent is empty; malformed is an error so a broken store is
/// not mistaken for "no keys".
pub fn load_saved_keys(app_data: &Path) -> Result<Vec<SavedGoKey>, AuthError> {
    let path = saved_keys_path(app_data);
    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(AuthError::CredentialsUnreadable(error.to_string())),
    };
    serde_json::from_str::<Vec<SavedGoKey>>(&text).map_err(|error| {
        AuthError::CredentialsUnreadable(format!("go-keys file is not valid JSON: {error}"))
    })
}

pub fn saved_to_go_keys(saved: &[SavedGoKey]) -> Vec<GoKey> {
    saved
        .iter()
        .map(|entry| GoKey {
            name: entry.label.clone(),
            key: entry.key.trim().to_string(),
            id: entry.id.clone(),
            source: KeySource::AppSaved,
        })
        .filter(|entry| !entry.key.is_empty())
        .collect()
}

pub fn load_all_keys(
    home: &Path,
    env: &dyn Fn(&str) -> Option<String>,
) -> Result<(PathBuf, Vec<GoKey>, bool, bool), AuthError> {
    let data_directory = data_directory(home, env);
    let file = load_auth_file_keys(&data_directory);
    let saved = load_saved_keys(&paths::app_data());
    let mut keys = Vec::new();
    let auth_ok = file.is_ok();
    let saved_ok = saved.is_ok();
    if let Ok(file) = file {
        keys.extend(file);
    }
    if let Ok(saved) = saved {
        keys.extend(saved_to_go_keys(&saved));
    }
    if !auth_ok && !saved_ok {
        return Err(AuthError::CredentialsUnreadable(
            "OpenCode credentials are unreadable".into(),
        ));
    }
    if !auth_ok {
        qlog!(
            Warn,
            crate::host::plugin_tag("opencode"),
            "auth.json unreadable"
        );
    }
    if !saved_ok {
        qlog!(
            Warn,
            crate::host::plugin_tag("opencode"),
            "app-saved OpenCode Go keys unreadable"
        );
    }
    Ok((data_directory, keys, auth_ok, saved_ok))
}

/// `hasLocalCredentials` sources: a Go key in `auth.json`, a saved Go key, or hosted usage in a
/// local database. An unreadable credential file counts as a footprint so refresh can surface it.
pub fn has_local_credentials(home: &Path, env: &dyn Fn(&str) -> Option<String>) -> bool {
    let data_directory = data_directory(home, env);
    match load_auth_file_keys(&data_directory) {
        Ok(keys) if !keys.is_empty() => return true,
        Err(_) => return true,
        Ok(_) => {}
    }
    match load_saved_keys(&paths::app_data()) {
        Ok(keys) if !keys.is_empty() => return true,
        Err(_) => return true,
        Ok(_) => {}
    }
    let files = match database_files(&data_directory) {
        Ok(files) => files,
        Err(_) => return true,
    };
    files
        .iter()
        .any(|path| database_has_hosted_usage(path).unwrap_or(false))
}

fn database_has_hosted_usage(path: &Path) -> Result<bool, ()> {
    // Cheap probe: one representative layout. Unknown/missing tables fall back to the legacy table.
    let v2 = "SELECT 1 FROM session_message WHERE type = 'assistant' AND json_valid(data) \
              AND COALESCE(json_extract(data,'$.model.providerID'), json_extract(data,'$.providerID')) \
                  IN ('opencode-go','opencode') LIMIT 1;";
    let legacy = "SELECT 1 FROM message WHERE json_valid(data) \
              AND json_extract(data,'$.role') = 'assistant' \
              AND COALESCE(json_extract(data,'$.providerID'), json_extract(data,'$.model.providerID')) \
                  IN ('opencode-go','opencode') LIMIT 1;";
    if crate::sqlite::query_value_tolerating_missing_table(path, v2)
        .map_err(|_| ())?
        .is_some()
    {
        return Ok(true);
    }
    Ok(
        crate::sqlite::query_value_tolerating_missing_table(path, legacy)
            .map_err(|_| ())?
            .is_some(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_go_only_and_ignores_sibling_entries() {
        let dir = tempfile::tempdir().unwrap();
        let data = dir.path().join("opencode");
        std::fs::create_dir_all(&data).unwrap();
        std::fs::write(
            data.join(AUTH_FILE),
            r#"{"opencode":{"type":"api","key":"zen-key"},"opencode-go":{"type":"api","key":" go-key "},"other":42}"#,
        )
        .unwrap();
        let keys = load_auth_file_keys(&data).unwrap();
        assert_eq!(keys.len(), 1);
        assert_eq!(keys[0].name, "opencode-go");
        assert_eq!(keys[0].key, "go-key");
    }

    #[test]
    fn malformed_auth_file_is_unreadable_not_logged_out() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join(AUTH_FILE), "{").unwrap();
        assert!(matches!(
            load_auth_file_keys(dir.path()),
            Err(AuthError::CredentialsUnreadable(_))
        ));
    }
}
