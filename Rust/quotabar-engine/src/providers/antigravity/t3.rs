//! T3 Code runs Antigravity through its own ACP adapter, giving every instance a private GEMINI_HOME
//! at `~/.t3/userdata/providers/antigravity/<instance-key>/antigravity-acp` (Swift
//! `AntigravityT3Support`). Production QuotaBar neither reads its conversation stores nor its
//! credentials (the strict native scope applies); these helpers exist for the retained test seams.

use std::path::{Path, PathBuf};

pub const PROFILES_ROOT_SUBPATH: &str = ".t3/userdata/providers/antigravity";
pub const CREDENTIAL_FILE_NAME: &str = "acp_token.json";

/// The private conversation directories, canonicalized (symlinks resolved), deduplicated and sorted.
/// A missing profiles root is the normal "no T3 Code" case and yields `[]`; a root that exists but
/// cannot be listed is an error so the caller can fail loudly.
pub fn conversation_directories(home: &Path) -> Result<Vec<String>, String> {
    let root = home.join(PROFILES_ROOT_SUBPATH);
    if !root.exists() {
        return Ok(Vec::new());
    }
    let mut names: Vec<String> = std::fs::read_dir(&root)
        .map_err(|e| e.to_string())?
        .filter_map(|e| e.ok().map(|e| e.file_name().to_string_lossy().into_owned()))
        .collect();
    names.sort();
    let mut found = std::collections::BTreeSet::new();
    for name in names {
        let conversations = root.join(&name).join("antigravity-acp").join("conversations");
        if conversations.is_dir() {
            let resolved = std::fs::canonicalize(&conversations).unwrap_or(conversations);
            found.insert(resolved.to_string_lossy().into_owned());
        }
    }
    Ok(found.into_iter().collect())
}

/// The instances' file-based OAuth credentials, most recently active profile first (the running
/// instance is the one writing conversations), ties broken by path for determinism.
pub fn credential_files(home: &Path) -> Vec<PathBuf> {
    let root = home.join(PROFILES_ROOT_SUBPATH);
    let Ok(entries) = std::fs::read_dir(&root) else { return Vec::new() };
    let mut names: Vec<String> = entries.filter_map(|e| e.ok().map(|e| e.file_name().to_string_lossy().into_owned())).collect();
    names.sort();
    let mut candidates: Vec<(PathBuf, f64)> = Vec::new();
    for name in names {
        let profile = root.join(&name).join("antigravity-acp");
        let credential = profile.join(CREDENTIAL_FILE_NAME);
        if !credential.exists() {
            continue;
        }
        let activity = std::fs::metadata(profile.join("conversations"))
            .and_then(|m| m.modified())
            .map(crate::context::system_time_to_timestamp)
            .unwrap_or(crate::time::DISTANT_PAST);
        candidates.push((credential, activity));
    }
    candidates.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal).then_with(|| a.0.cmp(&b.0)));
    candidates.into_iter().map(|(path, _)| path).collect()
}
