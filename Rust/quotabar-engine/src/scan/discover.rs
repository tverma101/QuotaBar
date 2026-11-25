//! Log-file discovery and the cheap file revision the scan cache is keyed on.

use std::fs::Metadata;
use std::io;
use std::path::{Path, PathBuf};

/// The stat fields that identify one version of a file without reading it. `ctime_ns` is the
/// metadata-change time: it moves on an in-place rewrite even when a writer restores the content
/// modification time and length. Fields a platform cannot report stay zero on both sides of a
/// comparison.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct Revision {
    pub size: u64,
    pub mtime_ns: i64,
    pub ctime_ns: i64,
    pub dev: u64,
    pub ino: u64,
}

impl Revision {
    pub fn of(meta: &Metadata) -> Revision {
        platform_revision(meta)
    }

    pub fn read(path: &Path) -> io::Result<Revision> {
        Ok(Revision::of(&std::fs::metadata(path)?))
    }

    /// Same physical file (rotation and replacement change the inode).
    pub fn same_file(&self, other: &Revision) -> bool {
        self.dev == other.dev && self.ino == other.ino
    }

    /// Content modification time in seconds since 1970.
    pub fn mtime(&self) -> f64 {
        self.mtime_ns as f64 / 1e9
    }
}

#[cfg(unix)]
fn platform_revision(meta: &Metadata) -> Revision {
    use std::os::unix::fs::MetadataExt;
    Revision {
        size: meta.len(),
        mtime_ns: meta.mtime().saturating_mul(1_000_000_000).saturating_add(meta.mtime_nsec()),
        ctime_ns: meta.ctime().saturating_mul(1_000_000_000).saturating_add(meta.ctime_nsec()),
        dev: meta.dev(),
        ino: meta.ino(),
    }
}

#[cfg(not(unix))]
fn platform_revision(meta: &Metadata) -> Revision {
    let nanos = |time: io::Result<std::time::SystemTime>| {
        time.ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map_or(0, |d| i64::try_from(d.as_nanos()).unwrap_or(i64::MAX))
    };
    // Windows has no stable inode through std; creation time stands in for "same file", which a
    // rotate-and-recreate changes.
    Revision {
        size: meta.len(),
        mtime_ns: nanos(meta.modified()),
        ctime_ns: 0,
        dev: 0,
        ino: nanos(meta.created()) as u64,
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DiscoveredFile {
    pub path: PathBuf,
    pub revision: Revision,
}

impl DiscoveredFile {
    pub fn is_zstd(&self) -> bool {
        self.path.extension().is_some_and(|e| e == "zst")
    }
}

/// Which file names a walk yields.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Extensions {
    /// `*.jsonl`
    Jsonl,
    /// `*.jsonl` and `*.jsonl.zst` (Codex compresses finished sessions).
    JsonlAndZstd,
    /// `*.json`
    Json,
}

impl Extensions {
    fn matches(self, name: &str) -> bool {
        match self {
            Extensions::Jsonl => name.ends_with(".jsonl"),
            Extensions::JsonlAndZstd => name.ends_with(".jsonl") || name.ends_with(".jsonl.zst"),
            Extensions::Json => name.ends_with(".json"),
        }
    }
}

/// Every matching regular file under `root`, recursively, sorted by path so keep-first dedup is
/// deterministic.
///
/// A missing root is a complete empty result. A root that exists but cannot be read or fully
/// enumerated is an error, so a multi-root caller cannot publish partial history as if it were
/// complete. Symlinks below the root are not followed (the root itself may be one).
pub fn discover(root: &Path, extensions: Extensions) -> io::Result<Vec<DiscoveredFile>> {
    let root = match std::fs::canonicalize(root) {
        Ok(root) => root,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e),
    };
    if !std::fs::metadata(&root)?.is_dir() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "log root is not a directory"));
    }
    let mut files = Vec::new();
    let mut stack = vec![root];
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir)? {
            let entry = entry?;
            let kind = entry.file_type()?;
            if kind.is_dir() {
                stack.push(entry.path());
            } else if kind.is_file() {
                let name = entry.file_name();
                let Some(name) = name.to_str() else { continue };
                if extensions.matches(name) {
                    let path = entry.path();
                    // `DirEntry::metadata` does not report the inode on every platform.
                    let revision = Revision::read(&path)?;
                    files.push(DiscoveredFile { path, revision });
                }
            }
        }
    }
    files.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(files)
}

/// `discover` over several roots; the first unreadable root fails the whole walk. Duplicate roots
/// (a symlink to another root) yield each file once.
pub fn discover_all(roots: &[PathBuf], extensions: Extensions) -> io::Result<Vec<DiscoveredFile>> {
    let mut files = Vec::new();
    for root in roots {
        files.extend(discover(root, extensions)?);
    }
    files.sort_by(|a, b| a.path.cmp(&b.path));
    files.dedup_by(|a, b| a.path == b.path);
    Ok(files)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_root_is_empty_and_files_are_sorted_and_filtered() {
        let dir = tempfile::tempdir().unwrap();
        assert!(discover(&dir.path().join("absent"), Extensions::Jsonl).unwrap().is_empty());
        std::fs::create_dir_all(dir.path().join("b/c")).unwrap();
        for name in ["b/c/2.jsonl", "a.jsonl", "b/1.jsonl", "b/skip.json", "b/old.jsonl.zst"] {
            std::fs::write(dir.path().join(name), b"{}\n").unwrap();
        }
        let names = |ext| {
            discover(dir.path(), ext)
                .unwrap()
                .iter()
                .map(|f| f.path.strip_prefix(std::fs::canonicalize(dir.path()).unwrap()).unwrap().to_owned())
                .map(|p| p.to_string_lossy().replace('\\', "/"))
                .collect::<Vec<_>>()
        };
        assert_eq!(names(Extensions::Jsonl), ["a.jsonl", "b/1.jsonl", "b/c/2.jsonl"]);
        assert_eq!(
            names(Extensions::JsonlAndZstd),
            ["a.jsonl", "b/1.jsonl", "b/c/2.jsonl", "b/old.jsonl.zst"]
        );
    }

    #[test]
    fn a_file_root_is_an_error_not_an_empty_result() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("x.jsonl");
        std::fs::write(&file, b"").unwrap();
        assert!(discover(&file, Extensions::Jsonl).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn revision_changes_on_rewrite_and_append() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("x.jsonl");
        std::fs::write(&file, b"a\n").unwrap();
        let first = Revision::read(&file).unwrap();
        std::fs::OpenOptions::new().append(true).open(&file).unwrap();
        use std::io::Write;
        std::fs::OpenOptions::new().append(true).open(&file).unwrap().write_all(b"b\n").unwrap();
        let second = Revision::read(&file).unwrap();
        assert!(first.same_file(&second));
        assert_eq!(second.size, 4);
        assert_ne!(first, second);
    }
}
