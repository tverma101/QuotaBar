//! Account scoping of the shared session logs (Swift `ownedUsageFiles`, `indexedDesktopSessionIDs`).

use super::logs::ClaudeLogScanner;
use super::ownership::{shared_identity, OwnershipLookup};
use super::roots::{claude_app_support, cowork_base};
use super::util::{normalized_uuid, resolve_path, stable_fingerprint};
use crate::context::CancelToken;
use crate::host::{self, diagnostic_gate};
use crate::qlog;
use crate::scan::DiscoveredFile;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::ffi::OsString;
use std::path::{Path, PathBuf};

impl ClaudeLogScanner {
    /// Cowork roots carry their organization in the directory layout. Other sessions identify theirs
    /// in a bridge event or Desktop's account-and-organization-scoped session index; subagent files
    /// inherit their parent session's ownership. Keeps this outside the shared parsed-entry cache.
    /// `None` means ownership could not be established for some file (or the scan was cancelled), so a
    /// partial sum must not be published.
    pub(super) fn owned_usage_files(
        &self,
        files: &[DiscoveredFile],
        organization_id: &str,
        cancel: &CancelToken,
    ) -> Option<Vec<DiscoveredFile>> {
        let cowork_prefix = cowork_base(&resolve_path(&self.home));
        let files_by_path: HashMap<&Path, &DiscoveredFile> =
            files.iter().rev().map(|file| (file.path.as_path(), file)).collect();
        let mut seen: HashSet<&Path> = HashSet::new();
        let mut owned = Vec::new();
        let mut desktop_session_ids: Option<HashSet<String>> = None;

        for file in files {
            if cancel.is_cancelled() {
                return None;
            }
            if !seen.insert(file.path.as_path()) {
                continue;
            }
            let canonical = std::fs::canonicalize(&file.path).unwrap_or_else(|_| file.path.clone());
            if let Ok(relative) = canonical.strip_prefix(&cowork_prefix) {
                let components: Vec<String> = relative.components().map(|c| c.as_os_str().to_string_lossy().to_lowercase()).collect();
                if components.len() > 1
                    && components[1] == organization_id
                    && self.account_id.as_deref().is_none_or(|account| components[0] == account)
                {
                    owned.push(file.clone());
                }
                continue;
            }

            let directory = file.path.parent().unwrap_or(Path::new(""));
            let session_file = if directory.file_name().is_some_and(|name| name == "subagents") {
                // `<session>/subagents/<agent>.jsonl` belongs to `<session>.jsonl`.
                let mut parent: OsString = directory.parent().unwrap_or(Path::new("")).as_os_str().to_owned();
                parent.push(".jsonl");
                files_by_path.get(Path::new(&parent)).copied()
            } else {
                Some(file)
            };
            let Some(session_file) = session_file else { continue };
            let lookup = match &self.ownership_lookup {
                Some(lookup) => lookup(session_file),
                None => shared_identity(session_file, cancel),
            };
            if cancel.is_cancelled() {
                return None;
            }
            match lookup {
                // It may belong to this account; omitting it would publish a successful partial sum.
                OwnershipLookup::Unreadable => return None,
                OwnershipLookup::Readable { is_ambiguous: true, .. } => {}
                OwnershipLookup::Readable { organization_id: Some(owner), account_id, .. } => {
                    if owner == organization_id && (self.account_id.is_none() || account_id == self.account_id) {
                        owned.push(file.clone());
                    }
                }
                OwnershipLookup::Readable { organization_id: None, .. } if self.allows_unattributed_sessions => owned.push(file.clone()),
                OwnershipLookup::Readable { organization_id: None, .. } => {
                    let Some(account_id) = &self.account_id else { continue };
                    if desktop_session_ids.is_none() {
                        desktop_session_ids = Some(self.desktop_session_ids_or_log(account_id, organization_id)?);
                    }
                    let session_id = session_file.path.file_stem().map(|s| s.to_string_lossy().to_lowercase());
                    if session_id.is_some_and(|id| desktop_session_ids.as_ref().is_some_and(|ids| ids.contains(&id))) {
                        owned.push(file.clone());
                    }
                }
            }
        }
        Some(owned)
    }

    fn desktop_session_ids_or_log(&self, account_id: &str, organization_id: &str) -> Option<HashSet<String>> {
        let directory = self.desktop_session_index_directory(account_id, organization_id);
        let prefix = format!("claude.desktop.session-index.{}.", stable_fingerprint(&directory.to_string_lossy()));
        match indexed_desktop_session_ids(&directory) {
            Some(ids) => {
                diagnostic_gate::clear_prefix(&prefix);
                Some(ids)
            }
            None => {
                diagnostic_gate::log_once(&format!("{prefix}incomplete"), || {
                    qlog!(
                        Warn,
                        host::plugin_tag("claude"),
                        "account-scoped desktop session index could not be completely read; preserving last-good history"
                    );
                });
                None
            }
        }
    }

    fn desktop_session_index_directory(&self, account_id: &str, organization_id: &str) -> PathBuf {
        claude_app_support(&self.home).join("claude-code-sessions").join(account_id).join(organization_id)
    }
}

/// The `cliSessionId`s the Desktop app indexed for one account and organization. A missing index is a
/// valid empty source. A present index that cannot be read is different: account ownership is
/// unresolved and the combined history must not publish (`None`).
fn indexed_desktop_session_ids(directory: &Path) -> Option<HashSet<String>> {
    match std::fs::metadata(directory) {
        Ok(meta) if meta.is_dir() => {}
        Ok(_) => return None,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Some(HashSet::new()),
        Err(_) => return None,
    }
    let mut session_ids = HashSet::new();
    for entry in std::fs::read_dir(directory).ok()? {
        let entry = entry.ok()?;
        let name = entry.file_name().to_string_lossy().into_owned();
        let indexed = name.starts_with("local_") && Path::new(&name).extension().is_some_and(|e| e == "json");
        if name.starts_with('.') || !indexed {
            continue;
        }
        let meta = std::fs::symlink_metadata(entry.path()).ok()?;
        // Do not follow index symlinks into another account's directory. They do not establish
        // ownership for this account's sessions.
        if meta.file_type().is_symlink() {
            continue;
        }
        if !meta.is_file() {
            return None;
        }
        let object: Value = serde_json::from_slice(&std::fs::read(entry.path()).ok()?).ok()?;
        let raw_session_id = object.as_object()?.get("cliSessionId")?.as_str()?;
        // Non-UUID values cannot match Claude's UUID-named session logs; keep ignoring those
        // well-formed but unrelated index entries.
        if let Some(session_id) = normalized_uuid(raw_session_id) {
            session_ids.insert(session_id);
        }
    }
    Some(session_ids)
}
