//! Private, symlink-following credential file writes (Swift `LocalTextFileAccessor.writeText`).
//!
//! Credential and token files must never be readable by another local account, and a path that is
//! a symlink (users keep `~/.grok/auth.json` and friends linked into a dotfiles repo) must keep
//! being a symlink: `rename(2)` replaces the directory entry, so writing to the link path itself
//! would silently destroy the link. The write therefore resolves the link chain first, writes a
//! private (0600) temporary file beside the real target, flushes it, and renames it into place.

use std::io::Write;
use std::path::{Component, Path, PathBuf};

/// Swift bounds the chain to eight hops so a cycle cannot hang a background refresh.
const MAX_SYMLINK_HOPS: usize = 8;

pub fn write_private_file(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let destination = resolve_symlink_destination(path);
    let dir = destination
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."));
    std::fs::create_dir_all(&dir)?;
    let name = destination
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let mut tmp = tempfile::Builder::new()
        .prefix(&format!(".{name}."))
        .suffix(".tmp")
        .tempfile_in(&dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        tmp.as_file()
            .set_permissions(std::fs::Permissions::from_mode(0o600))?;
    }
    tmp.write_all(bytes)?;
    tmp.flush()?;
    tmp.as_file().sync_all()?;
    tmp.persist(&destination).map_err(|e| e.error)?;
    Ok(())
}

/// Follow a symlink chain at `path` and return the path that should actually be written. A cycle,
/// or a chain deeper than the hop budget, returns `path` itself.
pub fn resolve_symlink_destination(path: &Path) -> PathBuf {
    let mut current = path.to_path_buf();
    for _ in 0..MAX_SYMLINK_HOPS {
        let is_link = std::fs::symlink_metadata(&current)
            .map(|m| m.file_type().is_symlink())
            .unwrap_or(false);
        if !is_link {
            return current;
        }
        let Ok(target) = std::fs::read_link(&current) else {
            return current;
        };
        if target.as_os_str().is_empty() {
            return current;
        }
        // A relative link resolves against the directory holding this link, not the original path.
        let next = if target.is_absolute() {
            target
        } else {
            current
                .parent()
                .unwrap_or_else(|| Path::new("."))
                .join(target)
        };
        current = normalize(&next);
    }
    path.to_path_buf()
}

/// Lexical normalization (`.` and `..` segments), like `NSString.standardizingPath`.
fn normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                if !out.pop() {
                    out.push("..");
                }
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn writes_privately_and_follows_symlink_chains() {
        let dir = tempfile::tempdir().unwrap();
        let real = dir.path().join("dotfiles/auth.json");
        std::fs::create_dir_all(real.parent().unwrap()).unwrap();
        std::fs::write(&real, "old").unwrap();
        let hop = dir.path().join("hop.json");
        std::os::unix::fs::symlink("dotfiles/auth.json", &hop).unwrap();
        let link = dir.path().join("home/auth.json");
        std::fs::create_dir_all(link.parent().unwrap()).unwrap();
        std::os::unix::fs::symlink("../hop.json", &link).unwrap();

        write_private_file(&link, b"new").unwrap();

        assert!(
            std::fs::symlink_metadata(&link)
                .unwrap()
                .file_type()
                .is_symlink(),
            "the link must survive"
        );
        assert_eq!(std::fs::read_to_string(&real).unwrap(), "new");
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&real).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let leftovers: Vec<_> = std::fs::read_dir(real.parent().unwrap()).unwrap().collect();
        assert_eq!(leftovers.len(), 1, "no temporary file may remain");
    }

    #[test]
    fn broken_link_writes_the_target_and_cycles_fall_back_to_the_path() {
        let dir = tempfile::tempdir().unwrap();
        let link = dir.path().join("auth.json");
        std::os::unix::fs::symlink("missing/real.json", &link).unwrap();
        write_private_file(&link, b"x").unwrap();
        assert_eq!(
            std::fs::read_to_string(dir.path().join("missing/real.json")).unwrap(),
            "x"
        );

        let a = dir.path().join("a");
        let b = dir.path().join("b");
        std::os::unix::fs::symlink(&b, &a).unwrap();
        std::os::unix::fs::symlink(&a, &b).unwrap();
        assert_eq!(resolve_symlink_destination(&a), a);
    }
}
