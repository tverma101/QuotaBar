//! Z.ai API-key resolution via the shared `api_key` store (`Providers/ZAI/ZAIAuthStore.swift`).

use super::super::api_key::{ApiKeySpec, ReadKeyError};
use crate::model::ErrorCategory;
use crate::paths;
use std::path::PathBuf;

pub const CONFIG_PATHS: [&str; 3] = [
    "~/.config/quotabar/zai.json",
    "~/.config/openusage/zai.json",
    "~/.config/zai/key.json",
];
pub const ENV_NAMES: [&str; 2] = ["ZAI_API_KEY", "GLM_API_KEY"];

pub const MISSING_KEY_ERROR: &str =
    "No Z.ai API key. Set ZAI_API_KEY or add it to ~/.config/quotabar/zai.json.";
pub const CREDENTIALS_UNREADABLE_ERROR: &str =
    "Couldn't read the saved Z.ai API key. Check the config file permissions, then refresh again.";
pub const INVALID_KEY_ERROR: &str = "Z.ai API key invalid. Check your key at z.ai/manage-apikey/apikey-list.";
pub const SAVE_FAILED_ERROR: &str = "Couldn't save the Z.ai API key.";
pub const DELETE_FAILED_ERROR: &str = "Couldn't remove the saved Z.ai API key.";

pub fn live_spec() -> ApiKeySpec {
    ApiKeySpec {
        provider_id: "zai",
        config_paths: CONFIG_PATHS.iter().map(|p| paths::expand_home(p)).collect(),
        env_names: &ENV_NAMES,
        missing_key_error: MISSING_KEY_ERROR,
        save_failed_error: SAVE_FAILED_ERROR,
        delete_failed_error: DELETE_FAILED_ERROR,
    }
}

pub fn spec_with_paths(config_paths: Vec<PathBuf>) -> ApiKeySpec {
    ApiKeySpec {
        provider_id: "zai",
        config_paths,
        env_names: &ENV_NAMES,
        missing_key_error: MISSING_KEY_ERROR,
        save_failed_error: SAVE_FAILED_ERROR,
        delete_failed_error: DELETE_FAILED_ERROR,
    }
}

pub fn load_for_refresh(spec: &ApiKeySpec) -> Result<Option<String>, (&'static str, ErrorCategory)> {
    match spec.load_key_for_refresh() {
        Ok(Some(key)) => Ok(Some(key)),
        Ok(None) => Ok(None),
        Err(ReadKeyError::ConfigUnreadable) => {
            Err((CREDENTIALS_UNREADABLE_ERROR, ErrorCategory::CredentialAccess))
        }
    }
}
