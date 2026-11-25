//! Session ownership metadata (Swift `ClaudeSessionOwnershipIndex`).
//!
//! Account-scoped Claude cards share physical logs. Ownership metadata is cached per file revision
//! across those cards so each candidate session is classified once; nonmatching usage rows never
//! enter the parse/fold cache.

use super::util::stable_fingerprint;
use crate::context::CancelToken;
use crate::host::{self, diagnostic_gate};
use crate::qlog;
use crate::scan::{file_label, DiscoveredFile, Revision};
use memchr::{memchr, memmem};
use serde_json::Value;
use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

/// Readable ownership metadata can legitimately be ambiguous or absent. Only a failure to read the
/// preamble makes an account-scoped scan incomplete.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum OwnershipLookup {
    Readable {
        organization_id: Option<String>,
        account_id: Option<String>,
        is_ambiguous: bool,
    },
    Unreadable,
}

const READ_DIAGNOSTIC_BASE: &str = "claude.session.ownership-read.";
const READ_LIMIT: usize = 1024 * 1024;
const CHUNK: usize = 64 * 1024;
const OWNER_MARKER: &[u8] = br#""ownerOrganizationUuid""#;
const USAGE_MARKER: &[u8] = br#""usage":{"#;

struct CachedIdentity {
    revision: Revision,
    identity: OwnershipPrefix,
}

fn index() -> &'static Mutex<HashMap<PathBuf, CachedIdentity>> {
    static INDEX: OnceLock<Mutex<HashMap<PathBuf, CachedIdentity>>> = OnceLock::new();
    INDEX.get_or_init(Default::default)
}

/// The process-wide, revision-keyed lookup. A file whose size, mtimes or inode changed is re-read;
/// unchanged files are answered from memory.
pub fn shared_identity(file: &DiscoveredFile, cancel: &CancelToken) -> OwnershipLookup {
    let failure_prefix = format!(
        "{READ_DIAGNOSTIC_BASE}{}.",
        stable_fingerprint(&file.path.to_string_lossy())
    );
    let cached = index()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(&file.path)
        .filter(|cached| cached.revision == file.revision)
        .map(|cached| cached.identity.clone());
    if let Some(identity) = cached {
        diagnostic_gate::clear_prefix(&failure_prefix);
        return identity.into_lookup();
    }
    if cancel.is_cancelled() {
        return OwnershipLookup::Unreadable;
    }
    match read_ownership_prefix(&file.path, cancel) {
        Some(identity) => {
            diagnostic_gate::clear_prefix(&failure_prefix);
            index().lock().unwrap_or_else(|e| e.into_inner()).insert(
                file.path.clone(),
                CachedIdentity {
                    revision: file.revision,
                    identity: identity.clone(),
                },
            );
            identity.into_lookup()
        }
        None => {
            if !cancel.is_cancelled() {
                let revision = format!("{:?}", file.revision);
                let key = format!("{failure_prefix}{}", stable_fingerprint(&revision));
                diagnostic_gate::log_once(&key, || {
                    qlog!(
                        Warn,
                        host::plugin_tag("claude"),
                        "Failed to read Claude session ownership from {}",
                        file_label(&file.path)
                    );
                });
            }
            OwnershipLookup::Unreadable
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct OwnershipPrefix {
    pub organization_id: Option<String>,
    pub account_id: Option<String>,
    pub is_ambiguous: bool,
}

impl OwnershipPrefix {
    fn into_lookup(self) -> OwnershipLookup {
        OwnershipLookup::Readable {
            organization_id: self.organization_id,
            account_id: self.account_id,
            is_ambiguous: self.is_ambiguous,
        }
    }

    /// Fold one preamble line into the running owner. Two different organizations (or accounts) make
    /// the session ambiguous, and an ambiguous session is never attributed to anyone.
    fn inspect(&mut self, line: &[u8]) {
        if self.is_ambiguous || memmem::find(line, OWNER_MARKER).is_none() {
            return;
        }
        let Ok(Value::Object(object)) = serde_json::from_slice::<Value>(line) else {
            return;
        };
        let Some(owner) = object
            .get("ownerOrganizationUuid")
            .and_then(Value::as_str)
            .filter(|v| !v.is_empty())
        else {
            return;
        };
        let candidate = owner.to_lowercase();
        if self
            .organization_id
            .as_ref()
            .is_some_and(|existing| *existing != candidate)
        {
            self.is_ambiguous = true;
            return;
        }
        self.organization_id = Some(candidate);
        if let Some(account) = object
            .get("ownerAccountUuid")
            .and_then(Value::as_str)
            .filter(|v| !v.is_empty())
        {
            let normalized = account.to_lowercase();
            if self
                .account_id
                .as_ref()
                .is_some_and(|existing| *existing != normalized)
            {
                self.is_ambiguous = true;
                return;
            }
            self.account_id = Some(normalized);
        }
    }
}

/// Ownership is written in the session preamble, before the first usage row. Read only that prefix:
/// a disabled account's shared-root file needs attribution metadata, not a full-file scan just to
/// decide that its usage rows do not belong to this enabled card. `None` means the preamble could not
/// be read (or the read was cancelled).
pub fn read_ownership_prefix(path: &Path, cancel: &CancelToken) -> Option<OwnershipPrefix> {
    let mut file = std::fs::File::open(path).ok()?;
    let mut prefix = OwnershipPrefix::default();
    let mut carry: Vec<u8> = Vec::new();
    let mut buffer = vec![0u8; CHUNK];
    let mut bytes_read = 0usize;
    let mut reached_usage = false;
    while bytes_read < READ_LIMIT && !reached_usage {
        if cancel.is_cancelled() {
            return None;
        }
        let amount = CHUNK.min(READ_LIMIT - bytes_read);
        let count = match file.read(&mut buffer[..amount]) {
            Ok(count) => count,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => return None,
        };
        if count == 0 {
            if !carry.is_empty() {
                prefix.inspect(&carry);
            }
            break;
        }
        bytes_read += count;
        carry.extend_from_slice(&buffer[..count]);
        let mut line_start = 0;
        while let Some(offset) = memchr(b'\n', &carry[line_start..]) {
            let line = &carry[line_start..line_start + offset];
            prefix.inspect(line);
            line_start += offset + 1;
            if memmem::find(line, USAGE_MARKER).is_some() {
                reached_usage = true;
                break;
            }
        }
        carry.drain(..line_start);
    }
    Some(prefix)
}
