//! OpenRouter API-key resolution via the shared `api_key` store.

use super::super::api_key::{ApiKeySpec, ReadKeyError};
use crate::model::ErrorCategory;
use crate::paths;
use std::path::PathBuf;

pub const CONFIG_PATHS: [&str; 3] = [
    "~/.config/quotabar/openrouter.json",
    "~/.config/openusage/openrouter.json",
    "~/.config/openrouter/key.json",
];
pub const ENV_NAMES: [&str; 2] = ["OPENROUTER_API_KEY", "OPENROUTER_KEY"];

pub const MISSING_KEY_ERROR: &str =
    "No OpenRouter API key. Set OPENROUTER_API_KEY or add it to ~/.config/quotabar/openrouter.json.";
pub const CREDENTIALS_UNREADABLE_ERROR: &str =
    "Couldn't read the saved OpenRouter API key. Check the config file permissions, then refresh again.";
pub const INVALID_KEY_ERROR: &str =
    "OpenRouter API key invalid. Check your key at openrouter.ai/keys.";
pub const SAVE_FAILED_ERROR: &str = "Couldn't save the OpenRouter API key.";
pub const DELETE_FAILED_ERROR: &str = "Couldn't remove the saved OpenRouter API key.";

pub fn live_spec() -> ApiKeySpec {
    ApiKeySpec {
        provider_id: "openrouter",
        config_paths: CONFIG_PATHS.iter().map(|p| paths::expand_home(p)).collect(),
        env_names: &ENV_NAMES,
        missing_key_error: MISSING_KEY_ERROR,
        save_failed_error: SAVE_FAILED_ERROR,
        delete_failed_error: DELETE_FAILED_ERROR,
    }
}

pub fn spec_with_paths(config_paths: Vec<PathBuf>) -> ApiKeySpec {
    ApiKeySpec {
        provider_id: "openrouter",
        config_paths,
        env_names: &ENV_NAMES,
        missing_key_error: MISSING_KEY_ERROR,
        save_failed_error: SAVE_FAILED_ERROR,
        delete_failed_error: DELETE_FAILED_ERROR,
    }
}

pub fn load_for_refresh(spec: &ApiKeySpec) -> Result<String, (&'static str, ErrorCategory)> {
    match spec.load_key_for_refresh() {
        Ok(Some(key)) => Ok(key),
        Ok(None) => Err((MISSING_KEY_ERROR, ErrorCategory::NotLoggedIn)),
        Err(ReadKeyError::ConfigUnreadable) => {
            Err((CREDENTIALS_UNREADABLE_ERROR, ErrorCategory::CredentialAccess))
        }
    }
}
