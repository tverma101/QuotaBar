//! Whole-file JSONL reader shared by the per-provider `qb_*_parse_file` entry points — the Rust
//! mirror of `JSONLFileReader.readLines` (`Sources/QuotaBar/Providers/JSONLFileReader.swift`).
//!
//! The Swift reader streams a file in 64 KiB chunks, splits on '\n' carrying an unterminated tail
//! across chunks, drops logical lines longer than 64 MiB (counting them so the caller can treat
//! the file as incomplete), and can deliver a final unterminated line. This port produces the
//! same stream of delivered lines without per-chunk autoreleased `NSData` buffers or per-line
//! `Data` copies, and adds a per-chunk cancellation callback so the calling Swift task can still
//! abort a giant cold scan. Statistics that `ReadResult` exposes but that only exist to drive
//! Swift efficiency tests (`chunksRead`, `bytesCopiedIntoCarry`, `peakCarryBytes`) are not
//! reproduced — the counters that decide completeness (`bytesRead`, `oversizedLinesSkipped`,
//! `isDiscardingOversizedLine`) are.

use std::ffi::OsStr;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::os::raw::c_void;
use std::os::unix::ffi::OsStrExt;

/// Mirrors `JSONLFileReader.chunkSize`.
pub const CHUNK_SIZE: usize = 64 * 1024;
/// Mirrors `JSONLFileReader.maxLineBytes`.
pub const MAX_LINE_BYTES: usize = 64 * 1024 * 1024;

/// Per-chunk cancellation hook supplied by the Swift side (usually `Task.isCancelled`, so a
/// cancelled provider refresh still stops a giant cold scan at the next chunk boundary).
pub type CancelCallback = extern "C" fn(*mut c_void) -> u8;

/// Whole-file status codes shared by the `qb_*_parse_file` family (mirrors the `QB_FILE_*`
/// macros in `quotabar_core.h`): the file parsed and its entries are valid.
pub const QB_FILE_OK: u32 = 0;
/// A line was legal Swift input this module does not emulate — re-parse the whole file in Swift.
pub const QB_FILE_FALLBACK: u32 = 1;
/// Read error, cancellation, oversized line, or provider-level malformed content — the same
/// conditions under which the Swift file parser returns nil.
pub const QB_FILE_FAILED: u32 = 2;

/// How a whole-file scan ended. Providers fold this into their own result status.
#[derive(Debug, Default)]
pub struct ScanStats {
    /// Payload bytes consumed by the reader (mirrors `Statistics.bytesRead`).
    pub bytes_read: u64,
    /// Logical lines dropped for exceeding the line cap (`Statistics.oversizedLinesSkipped`).
    pub oversized_lines_skipped: u64,
    /// The read loop reached its end without an I/O error, cancellation, or an early abort.
    pub succeeded: bool,
    /// The cancel callback aborted the scan.
    pub cancelled: bool,
    /// The deliver closure asked to stop early (e.g. a line the parser cannot emulate).
    pub aborted: bool,
    /// The file ended while an oversized line was still being discarded
    /// (`ReadResult.isDiscardingOversizedLine`).
    pub is_discarding_oversized_line: bool,
    /// Bytes after the last delivered newline that were never delivered (`ReadResult.finalPartial`
    /// when `deliver_final_partial` is false). Empty when the trailing partial was delivered or
    /// the scan is still discarding an oversized line.
    pub final_partial: Vec<u8>,
}

/// Stream `path` over `[start_offset, end_offset)` in `CHUNK_SIZE` reads, split on '\n', and hand
/// each complete logical line to `deliver` — mirroring `JSONLFileReader.readLines`:
///
/// - an unterminated tail at a chunk boundary accumulates in `carry` instead of copying every
///   line through an accumulator,
/// - a logical line longer than `max_line_bytes` is counted in `oversized_lines_skipped` and
///   dropped (bytes until its terminating newline are discarded — `discarding` continuation
///   state, so a corrupt giant row cannot grow `carry` without bound),
/// - the cancel callback runs once per chunk before the next read,
/// - a read error, a short file when `end_offset` was promised, cancellation, or a `deliver`
///   early-abort all leave `succeeded` false,
/// - the trailing unterminated line is delivered only when `deliver_final_partial` is set and
///   an oversized discard is not in progress.
///
/// `deliver` returns false to abort the scan early (the provider records why in its own state —
/// for example a line shape that must be re-parsed by Swift). Empty lines are never delivered.
/// Its second argument is true only for the trailing unterminated tail — parsers that keep an
/// incomplete tail buffered for the next append (the Codex router reader) gate on it.
#[allow(clippy::too_many_arguments)]
pub fn scan_file_lines(
    path: &[u8],
    start_offset: u64,
    end_offset: Option<u64>,
    deliver_final_partial: bool,
    mut discarding: bool,
    cancel_ctx: *mut c_void,
    cancel: Option<CancelCallback>,
    max_line_bytes: usize,
    deliver: &mut dyn FnMut(&[u8], bool) -> bool,
) -> ScanStats {
    let mut stats = ScanStats::default();
    if let Some(end) = end_offset {
        if end < start_offset {
            return stats;
        }
    }

    let mut file = match File::open(OsStr::from_bytes(path)) {
        Ok(file) => file,
        Err(_) => return stats,
    };
    if start_offset > 0 && file.seek(SeekFrom::Start(start_offset)).is_err() {
        return stats;
    }

    let mut chunk = vec![0u8; CHUNK_SIZE];
    // `carry` holds at most the tail of one logical line; the first short-line file sizes it
    // small and it grows only when a record genuinely spans chunks.
    let mut carry: Vec<u8> = Vec::with_capacity(4 * 1024);
    let mut read_failed = false;
    let mut reached_end = false;

    while !reached_end {
        let remaining = end_offset.map(|end| end - start_offset - stats.bytes_read);
        if remaining == Some(0) {
            break;
        }
        // FileHandle reads are synchronous, so cancellation cannot interrupt one in-flight read;
        // checking once per chunk bounds canceled work to one chunk plus its line parsing.
        if let Some(check) = cancel {
            if check(cancel_ctx) != 0 {
                stats.cancelled = true;
                stats.final_partial = carry;
                return stats;
            }
        }

        let requested = remaining
            .map(|left| left.min(CHUNK_SIZE as u64) as usize)
            .unwrap_or(CHUNK_SIZE);
        match file.read(&mut chunk[..requested]) {
            Ok(0) => {
                // EOF: clean stop for an open-ended read, a failure when a fixed window was owed.
                if remaining.is_some() {
                    read_failed = true;
                }
                reached_end = true;
            }
            Ok(n) => {
                stats.bytes_read += n as u64;
                if !split_and_deliver(
                    &chunk[..n],
                    &mut carry,
                    &mut discarding,
                    &mut stats,
                    max_line_bytes,
                    deliver,
                ) {
                    stats.aborted = true;
                    stats.final_partial = carry;
                    return stats;
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => {
                read_failed = true;
                reached_end = true;
            }
        }
    }

    if read_failed {
        stats.final_partial = carry;
        return stats;
    }
    if deliver_final_partial && !discarding && !carry.is_empty() {
        if !deliver(&carry, true) {
            stats.aborted = true;
            stats.final_partial = carry;
            return stats;
        }
        // Mirrors `carry.removeAll(keepingCapacity: true)` after a successful
        // `onLine(carry)` delivery: the partial no longer counts as pending.
        carry.clear();
    }
    stats.succeeded = true;
    stats.is_discarding_oversized_line = discarding;
    stats.final_partial = carry;
    stats
}

/// Split one chunk into newline-delimited lines and hand each to `deliver`, carrying an
/// unterminated tail into the next chunk — a line-for-line port of
/// `JSONLFileReader.splitAndDeliver`. Returns false when `deliver` aborted the scan.
fn split_and_deliver(
    chunk: &[u8],
    carry: &mut Vec<u8>,
    discarding: &mut bool,
    stats: &mut ScanStats,
    max_line_bytes: usize,
    deliver: &mut dyn FnMut(&[u8], bool) -> bool,
) -> bool {
    let mut segment_start = 0;
    while segment_start < chunk.len() {
        let Some(relative) = memchr::memchr(b'\n', &chunk[segment_start..]) else {
            break;
        };
        let newline = segment_start + relative;
        if *discarding {
            // We already exceeded the bound in an earlier chunk. The newline ends that one
            // rejected logical record; later records in this same chunk remain eligible.
            *discarding = false;
        } else if carry.is_empty() {
            let line = &chunk[segment_start..newline];
            if line.len() <= max_line_bytes {
                if !line.is_empty() && !deliver(line, false) {
                    return false;
                }
            } else {
                stats.oversized_lines_skipped += 1;
            }
        } else {
            let continuation = &chunk[segment_start..newline];
            if carry.len() + continuation.len() <= max_line_bytes {
                carry.extend_from_slice(continuation);
                if !carry.is_empty() && !deliver(carry, false) {
                    return false;
                }
            } else {
                stats.oversized_lines_skipped += 1;
            }
            carry.clear();
        }
        segment_start = newline + 1;
    }

    if segment_start < chunk.len() && !*discarding {
        let tail = &chunk[segment_start..];
        if carry.len() + tail.len() <= max_line_bytes {
            carry.extend_from_slice(tail);
        } else {
            // Drop the accumulated bytes immediately and ignore continuation chunks until the
            // next newline. This is the memory safety boundary for malformed giant rows.
            stats.oversized_lines_skipped += 1;
            carry.clear();
            *discarding = true;
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    extern "C" fn never_cancel(_ctx: *mut c_void) -> u8 {
        0
    }

    fn write_temp(bytes: &[u8]) -> String {
        use std::sync::atomic::{AtomicU64, Ordering};
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "quotabar-scanfile-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let mut file = File::create(&path).expect("create temp");
        file.write_all(bytes).expect("write temp");
        path.to_str().expect("utf8 temp path").to_string()
    }

    fn collect(
        path: &str,
        start: u64,
        end: Option<u64>,
        deliver_final: bool,
    ) -> (ScanStats, Vec<Vec<u8>>) {
        let mut lines: Vec<Vec<u8>> = Vec::new();
        let stats = scan_file_lines(
            path.as_bytes(),
            start,
            end,
            deliver_final,
            false,
            std::ptr::null_mut(),
            Some(never_cancel),
            MAX_LINE_BYTES,
            &mut |line, _is_final_partial| {
                lines.push(line.to_vec());
                true
            },
        );
        (stats, lines)
    }

    #[test]
    fn delivers_all_lines_including_trailing_partial() {
        let path = write_temp(b"one\ntwo\nthree");
        let (stats, lines) = collect(&path, 0, None, true);
        std::fs::remove_file(&path).ok();
        assert!(stats.succeeded);
        assert_eq!(stats.bytes_read, 13);
        assert_eq!(
            lines,
            vec![b"one".to_vec(), b"two".to_vec(), b"three".to_vec()]
        );
    }

    #[test]
    fn drops_trailing_partial_when_not_delivered() {
        let path = write_temp(b"one\ntwo\nthree");
        let (stats, lines) = collect(&path, 0, None, false);
        std::fs::remove_file(&path).ok();
        assert!(stats.succeeded);
        assert_eq!(lines, vec![b"one".to_vec(), b"two".to_vec()]);
        // The undelivered tail is the append-resume carry (`ReadResult.finalPartial`).
        assert_eq!(stats.final_partial, b"three");
    }

    #[test]
    fn final_partial_is_empty_after_delivery() {
        let path = write_temp(b"one\ntwo\nthree");
        let (stats, lines) = collect(&path, 0, None, true);
        std::fs::remove_file(&path).ok();
        assert!(stats.succeeded);
        assert!(stats.final_partial.is_empty());
        assert_eq!(lines.len(), 3);
    }

    #[test]
    fn final_partial_is_empty_when_discarding_oversized() {
        let mut bytes = b"ok\n".to_vec();
        bytes.extend(std::iter::repeat(b'x').take(70 * 1024));
        let path = write_temp(&bytes);
        let stats = scan_file_lines(
            path.as_bytes(),
            0,
            None,
            false,
            false,
            std::ptr::null_mut(),
            Some(never_cancel),
            64 * 1024,
            &mut |_, _| true,
        );
        std::fs::remove_file(&path).ok();
        assert!(stats.is_discarding_oversized_line);
        assert!(stats.final_partial.is_empty());
    }

    #[test]
    fn skips_empty_lines() {
        let path = write_temp(b"\n\na\n\n");
        let (stats, lines) = collect(&path, 0, None, true);
        std::fs::remove_file(&path).ok();
        assert!(stats.succeeded);
        assert_eq!(lines, vec![b"a".to_vec()]);
    }

    #[test]
    fn start_offset_resumes_mid_file() {
        let path = write_temp(b"one\ntwo\nthree\n");
        // Start inside "two" — the tail of that record is delivered as one line.
        let (stats, lines) = collect(&path, 5, None, true);
        std::fs::remove_file(&path).ok();
        assert!(stats.succeeded);
        assert_eq!(lines, vec![b"wo".to_vec(), b"three".to_vec()]);
    }

    #[test]
    fn end_offset_windows_the_read() {
        let path = write_temp(b"one\ntwo\nthree\n");
        let (stats, lines) = collect(&path, 0, Some(8), true);
        std::fs::remove_file(&path).ok();
        assert!(stats.succeeded);
        assert_eq!(stats.bytes_read, 8);
        assert_eq!(lines, vec![b"one".to_vec(), b"two".to_vec()]);
    }

    #[test]
    fn short_file_under_a_promised_window_fails() {
        let path = write_temp(b"one\n");
        let (stats, _lines) = collect(&path, 0, Some(4096), true);
        std::fs::remove_file(&path).ok();
        assert!(!stats.succeeded);
    }

    #[test]
    fn missing_file_fails() {
        let (stats, _lines) = collect("/nonexistent/quotabar-test-file", 0, None, true);
        assert!(!stats.succeeded);
    }

    #[test]
    fn cancellation_aborts_at_chunk_boundary() {
        extern "C" fn always_cancel(_ctx: *mut c_void) -> u8 {
            1
        }
        let path = write_temp(b"one\ntwo\n");
        let mut lines = 0;
        let stats = scan_file_lines(
            path.as_bytes(),
            0,
            None,
            true,
            false,
            std::ptr::null_mut(),
            Some(always_cancel),
            MAX_LINE_BYTES,
            &mut |_, _| {
                lines += 1;
                true
            },
        );
        std::fs::remove_file(&path).ok();
        assert!(stats.cancelled);
        assert!(!stats.succeeded);
        assert_eq!(lines, 0);
    }

    #[test]
    fn deliver_false_aborts_early() {
        let path = write_temp(b"one\ntwo\nthree\n");
        let mut lines = 0;
        let stats = scan_file_lines(
            path.as_bytes(),
            0,
            None,
            true,
            false,
            std::ptr::null_mut(),
            Some(never_cancel),
            MAX_LINE_BYTES,
            &mut |_, _| {
                lines += 1;
                false
            },
        );
        std::fs::remove_file(&path).ok();
        assert!(stats.aborted);
        assert!(!stats.succeeded);
        assert_eq!(lines, 1);
    }

    #[test]
    fn oversized_line_is_skipped_and_counted() {
        let mut bytes = b"ok\n".to_vec();
        bytes.extend(std::iter::repeat(b'x').take(70 * 1024));
        bytes.extend(b"\nafter\n");
        let path = write_temp(&bytes);
        let mut lines: Vec<Vec<u8>> = Vec::new();
        let stats = scan_file_lines(
            path.as_bytes(),
            0,
            None,
            true,
            false,
            std::ptr::null_mut(),
            Some(never_cancel),
            64 * 1024,
            &mut |line, _is_final_partial| {
                lines.push(line.to_vec());
                true
            },
        );
        std::fs::remove_file(&path).ok();
        assert!(stats.succeeded);
        assert_eq!(stats.oversized_lines_skipped, 1);
        assert_eq!(lines, vec![b"ok".to_vec(), b"after".to_vec()]);
    }

    #[test]
    fn oversized_unterminated_tail_enters_discarding() {
        let mut bytes = b"ok\n".to_vec();
        bytes.extend(std::iter::repeat(b'x').take(70 * 1024));
        let path = write_temp(&bytes);
        let mut lines = 0;
        let stats = scan_file_lines(
            path.as_bytes(),
            0,
            None,
            true,
            false,
            std::ptr::null_mut(),
            Some(never_cancel),
            64 * 1024,
            &mut |_, _| {
                lines += 1;
                true
            },
        );
        std::fs::remove_file(&path).ok();
        assert!(stats.succeeded);
        assert!(stats.is_discarding_oversized_line);
        assert_eq!(stats.oversized_lines_skipped, 1);
        assert_eq!(lines, 1);
    }

    #[test]
    fn long_line_spanning_chunks_is_delivered_once() {
        let mut bytes = b"a\n".to_vec();
        bytes.extend(std::iter::repeat(b'y').take(200 * 1024));
        bytes.extend(b"\nb\n");
        let path = write_temp(&bytes);
        let (stats, lines) = collect(&path, 0, None, true);
        std::fs::remove_file(&path).ok();
        assert!(stats.succeeded);
        assert_eq!(lines.len(), 3);
        assert_eq!(lines[1].len(), 200 * 1024);
    }
}
