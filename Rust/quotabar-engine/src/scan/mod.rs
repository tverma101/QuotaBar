//! Local usage-log scanning shared by every log-based provider (Claude, Codex, Grok, pi, …).
//!
//! - `discover`: find log files and their cheap revision (size, mtimes, inode).
//! - `reader`: stream lines with bounded memory, plain or zstd-compressed (pure Rust, no `zstd`
//!   executable needed), and fingerprint an append-only prefix.
//! - `incremental`: per-file parse cache with append-resume and resumable parser state.
//! - `store`: the on-disk cache (one SQLite file) so a cold start does not re-parse gigabytes.
//! - `codec`: the compact record encoding the store uses.

pub mod codec;
pub mod discover;
pub mod incremental;
pub mod reader;
pub mod store;

pub use codec::{Reader, Record, Writer};
pub use discover::{discover, discover_all, DiscoveredFile, Extensions, Revision};
pub use incremental::{
    file_label, first_future_dated, FileItems, IncrementalScanner, LineError, LineParser, ScanError, ScanStats,
    FUTURE_TOLERANCE_SECONDS,
};
pub use store::ScanStore;

/// A fingerprint of one scan's inputs: every file's path and revision plus caller context (pricing
/// token, window start, account scope). Equal fingerprints mean a cached fold result is still exact.
pub fn fingerprint<T>(files: &[FileItems<T>], context: &[&str]) -> [u8; 16] {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    for part in context {
        hasher.update((part.len() as u64).to_le_bytes());
        hasher.update(part.as_bytes());
    }
    for file in files {
        let path = file.path.to_string_lossy();
        hasher.update((path.len() as u64).to_le_bytes());
        hasher.update(path.as_bytes());
        let r = file.revision;
        for value in [r.size, r.mtime_ns as u64, r.ctime_ns as u64, r.dev, r.ino] {
            hasher.update(value.to_le_bytes());
        }
    }
    let digest = hasher.finalize();
    let mut out = [0u8; 16];
    out.copy_from_slice(&digest[..16]);
    out
}
