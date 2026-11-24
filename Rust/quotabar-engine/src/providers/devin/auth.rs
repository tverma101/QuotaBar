//! Devin authentication sources: CLI `credentials.toml` and IDE `state.vscdb`.

use crate::host::{auth_tag, diagnostic_gate};
use crate::parse;
use crate::paths;
use crate::qlog;
use crate::sqlite::{self, SourceSignature};
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

pub const ID: &str = "devin";
pub const DEFAULT_API_SERVER_URL: &str = "https://server.codeium.com";

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct DevinAuth {
    pub api_key: String,
    pub api_server_url: Option<String>,
}

impl DevinAuth {
    pub fn effective_api_server_url(&self) -> &str {
        self.api_server_url.as_deref().unwrap_or(DEFAULT_API_SERVER_URL)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CredentialsUnreadable;

pub struct DevinAuthStore {
    fixed: Option<(Vec<PathBuf>, Vec<PathBuf>)>,
    pub(super) app_auth_cache: Mutex<HashMap<PathBuf, (SourceSignature, Option<DevinAuth>)>>,
}

impl DevinAuthStore {
    pub fn new(credentials_paths: Vec<PathBuf>, state_db_paths: Vec<PathBuf>) -> Self {
        DevinAuthStore {
            fixed: Some((credentials_paths, state_db_paths)),
            app_auth_cache: Mutex::new(HashMap::new()),
        }
    }

    pub fn live() -> Self {
        DevinAuthStore { fixed: None, app_auth_cache: Mutex::new(HashMap::new()) }
    }

    pub fn unload_caches(&self) {
        self.app_auth_cache.lock().unwrap_or_else(|e| e.into_inner()).clear();
    }

    pub fn credentials_paths(&self) -> Vec<PathBuf> {
        match &self.fixed {
            Some((credentials, _)) => credentials.clone(),
            None => live_locations().0,
        }
    }

    pub fn state_db_paths(&self) -> Vec<PathBuf> {
        match &self.fixed {
            Some((_, state)) => state.clone(),
            None => live_locations().1,
        }
    }

    pub fn load_credentials_file(&self) -> Result<Option<DevinAuth>, CredentialsUnreadable> {
        let Some(path) = self.credentials_paths().into_iter().find(|p| p.exists()) else {
            diagnostic_gate::clear("auth.devin.credentials-file-read");
            return Ok(None);
        };
        let text = match std::fs::read_to_string(&path) {
            Ok(text) => text,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(_) => {
                diagnostic_gate::log_once("auth.devin.credentials-file-read", || {
                    qlog!(Error, auth_tag(ID), "CLI credentials file read failed");
                });
                return Err(CredentialsUnreadable);
            }
        };
        diagnostic_gate::clear("auth.devin.credentials-file-read");
        let Some(api_key) = read_toml_string(&text, "windsurf_api_key") else { return Ok(None) };
        Ok(Some(DevinAuth {
            api_key,
            api_server_url: clean_api_server_url(read_toml_string(&text, "api_server_url").as_deref()),
        }))
    }

    pub fn load_app_auth(&self, path: &Path) -> Result<Option<DevinAuth>, CredentialsUnreadable> {
        let signature = sqlite::source_signature(path);
        if let Some((cached_signature, auth)) =
            self.app_auth_cache.lock().unwrap_or_else(|e| e.into_inner()).get(path)
        {
            if *cached_signature == signature {
                return Ok(auth.clone());
            }
        }
        let auth = read_app_auth(path)?;
        self.app_auth_cache
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(path.to_path_buf(), (signature, auth.clone()));
        Ok(auth)
    }
}

fn live_locations() -> (Vec<PathBuf>, Vec<PathBuf>) {
    let xdg = paths::xdg_data_home();
    let mut credentials = vec![xdg.join("devin/credentials.toml")];
    #[cfg(windows)]
    {
        let local = std::env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(|| paths::home().join("AppData/Local"));
        credentials.push(local.join("devin/credentials.toml"));
    }
    credentials.push(xdg.join("cognition/credentials.toml"));
    let support = paths::platform_app_support();
    let state = ["Devin", "Devin - Next", "Windsurf"]
        .iter()
        .map(|app| support.join(app).join("User/globalStorage/state.vscdb"))
        .collect();
    (credentials, state)
}

fn read_app_auth(path: &Path) -> Result<Option<DevinAuth>, CredentialsUnreadable> {
    let sql = "SELECT value FROM ItemTable WHERE key = 'windsurfAuthStatus' LIMIT 1";
    let value = match sqlite::query_value_tolerating_missing_table(path, sql) {
        Ok(value) => value,
        Err(_) => {
            diagnostic_gate::log_once("auth.devin.state-db-read", || {
                qlog!(Error, auth_tag(ID), "app state database credential read failed");
            });
            return Err(CredentialsUnreadable);
        }
    };
    diagnostic_gate::clear("auth.devin.state-db-read");
    let Some(value) = value else {
        diagnostic_gate::clear("auth.devin.state-db-decode");
        return Ok(None);
    };
    let Some(object) = serde_json::from_str::<Value>(&value).ok().filter(Value::is_object) else {
        diagnostic_gate::log_once("auth.devin.state-db-decode", || {
            qlog!(Error, auth_tag(ID), "app state database credential data could not be decoded");
        });
        return Err(CredentialsUnreadable);
    };
    diagnostic_gate::clear("auth.devin.state-db-decode");
    Ok(parse::trimmed_string(object.get("apiKey")).map(|api_key| DevinAuth { api_key, api_server_url: None }))
}

pub fn clean_api_server_url(value: Option<&str>) -> Option<String> {
    let trimmed = value?.trim();
    if !trimmed.starts_with("https://") {
        return None;
    }
    let cleaned = trimmed.trim_end_matches('/');
    (!cleaned.is_empty()).then(|| cleaned.to_string())
}

pub fn read_toml_string(text: &str, key: &str) -> Option<String> {
    for line in text.split(['\n', '\r']).filter(|l| !l.is_empty()) {
        let Some((name, value)) = line.split_once('=') else { continue };
        if name.trim() != key {
            continue;
        }
        let value = value.trim();
        if value.is_empty() {
            return None;
        }
        if value.starts_with('"') || value.starts_with('\'') {
            return read_quoted(value);
        }
        let value = value.split('#').next().unwrap_or("").trim();
        return (!value.is_empty()).then(|| value.to_string());
    }
    None
}

fn read_quoted(value: &str) -> Option<String> {
    let mut chars = value.chars();
    let quote = chars.next()?;
    let mut output = String::new();
    let mut previous: Option<char> = None;
    for ch in chars {
        if ch == quote && previous != Some('\\') {
            let trimmed = output.trim();
            return (!trimmed.is_empty()).then(|| trimmed.to_string());
        }
        output.push(ch);
        previous = Some(ch);
    }
    None
}
