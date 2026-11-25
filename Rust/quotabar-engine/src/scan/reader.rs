//! Streaming line reader: bounded memory per file regardless of size, plain or zstd-compressed.

use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::Path;

const CHUNK: usize = 256 * 1024;

/// A trailing unterminated line longer than this is not JSONL a parser could accept; reading it
/// would only grow memory.
pub const MAX_LINE: usize = 64 * 1024 * 1024;

/// What one read produced besides the delivered lines.
#[derive(Debug, Default)]
pub struct ReadSummary {
    /// Offset just past the last newline-terminated line (the resumable checkpoint).
    pub committed_end: u64,
    /// The trailing bytes after the last newline (a line still being written, or a file without a
    /// final newline).
    pub fragment: Vec<u8>,
    pub bytes_read: u64,
}

/// Deliver every newline-terminated line in `[start, end)` of a plain file to `on_line` (without
/// the newline; a trailing `\r` is kept, JSON parsers ignore it). Reading stops at `end` even if the
/// file has grown since it was stat'ed, so the result describes exactly that revision's bytes.
/// `on_line` returning `false` stops the read early (cancellation or a fatal line).
pub fn read_lines(
    path: &Path,
    start: u64,
    end: u64,
    mut on_line: impl FnMut(&[u8]) -> bool,
) -> io::Result<ReadSummary> {
    let mut file = File::open(path)?;
    file.seek(SeekFrom::Start(start))?;
    let mut remaining = end.saturating_sub(start);
    let mut pending: Vec<u8> = Vec::new();
    let mut chunk = vec![0u8; CHUNK];
    let mut offset = start;
    let mut committed_end = start;
    let mut bytes_read = 0u64;
    while remaining > 0 {
        let want = (remaining as usize).min(CHUNK);
        let n = file.read(&mut chunk[..want])?;
        if n == 0 {
            // The file shrank under us; the caller's revision check rejects this read.
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "log file shrank while it was read"));
        }
        remaining -= n as u64;
        bytes_read += n as u64;
        let data = &chunk[..n];
        let mut line_start = 0;
        for newline in memchr::memchr_iter(b'\n', data) {
            let line: &[u8] = if pending.is_empty() {
                &data[line_start..newline]
            } else {
                pending.extend_from_slice(&data[line_start..newline]);
                &pending
            };
            let keep_going = on_line(line);
            pending.clear();
            line_start = newline + 1;
            committed_end = offset + line_start as u64;
            if !keep_going {
                return Ok(ReadSummary { committed_end, fragment: Vec::new(), bytes_read });
            }
        }
        if pending.len() + (n - line_start) > MAX_LINE {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "log line exceeds the 64 MB limit"));
        }
        pending.extend_from_slice(&data[line_start..]);
        offset += n as u64;
    }
    Ok(ReadSummary { committed_end, fragment: pending, bytes_read })
}

/// Deliver every line of a zstd-compressed JSONL archive, including a final unterminated line.
/// Archives are immutable, so there is no resumable checkpoint.
pub fn read_zstd_lines(path: &Path, mut on_line: impl FnMut(&[u8]) -> bool) -> io::Result<u64> {
    let file = io::BufReader::new(File::open(path)?);
    let mut decoder = ruzstd::decoding::StreamingDecoder::new(file)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("zstd: {e}")))?;
    let mut pending: Vec<u8> = Vec::new();
    let mut chunk = vec![0u8; CHUNK];
    let mut total = 0u64;
    loop {
        let n = decoder.read(&mut chunk)?;
        if n == 0 {
            break;
        }
        total += n as u64;
        let data = &chunk[..n];
        let mut line_start = 0;
        for newline in memchr::memchr_iter(b'\n', data) {
            let line: &[u8] = if pending.is_empty() {
                &data[line_start..newline]
            } else {
                pending.extend_from_slice(&data[line_start..newline]);
                &pending
            };
            let keep_going = on_line(line);
            pending.clear();
            line_start = newline + 1;
            if !keep_going {
                return Ok(total);
            }
        }
        if pending.len() + (n - line_start) > MAX_LINE {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "log line exceeds the 64 MB limit"));
        }
        pending.extend_from_slice(&data[line_start..]);
    }
    if !pending.is_empty() {
        on_line(&pending);
    }
    Ok(total)
}

/// A sampled signature of `[0, end)`: nine evenly spaced windows (head, interior, tail) hashed
/// together. Files up to 4 KiB are hashed whole. An append-only writer never changes these bytes, so
/// a mismatch proves a rewrite; a match is strong evidence, and the revision check covers the rest.
pub fn prefix_anchor(path: &Path, end: u64) -> io::Result<[u8; 16]> {
    use sha2::{Digest, Sha256};
    const TOTAL: u64 = 4 * 1024;
    const SAMPLES: u64 = 9;
    let mut hasher = Sha256::new();
    hasher.update(end.to_le_bytes());
    let mut file = File::open(path)?;
    if end <= TOTAL {
        let mut buf = vec![0u8; end as usize];
        file.read_exact(&mut buf)?;
        hasher.update(&buf);
    } else {
        let len = TOTAL / SAMPLES;
        let max_start = end - len;
        let mut buf = vec![0u8; len as usize];
        let mut last = None;
        for index in 0..SAMPLES {
            let start = index * max_start / (SAMPLES - 1);
            if last == Some(start) {
                continue;
            }
            last = Some(start);
            file.seek(SeekFrom::Start(start))?;
            file.read_exact(&mut buf)?;
            hasher.update(&buf);
        }
    }
    let digest = hasher.finalize();
    let mut out = [0u8; 16];
    out.copy_from_slice(&digest[..16]);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn collect(path: &Path, start: u64, end: u64) -> (Vec<String>, ReadSummary) {
        let mut lines = Vec::new();
        let summary = read_lines(path, start, end, |l| {
            lines.push(String::from_utf8(l.to_vec()).unwrap());
            true
        })
        .unwrap();
        (lines, summary)
    }

    #[test]
    fn splits_lines_keeps_fragment_and_resumes_from_checkpoint() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("x.jsonl");
        std::fs::write(&path, b"one\ntwo\nthr").unwrap();
        let (lines, summary) = collect(&path, 0, 11);
        assert_eq!(lines, ["one", "two"]);
        assert_eq!(summary.committed_end, 8);
        assert_eq!(summary.fragment, b"thr");

        std::fs::write(&path, b"one\ntwo\nthree\nfour\n").unwrap();
        let (lines, summary) = collect(&path, 8, 19);
        assert_eq!(lines, ["three", "four"]);
        assert_eq!(summary.committed_end, 19);
        assert!(summary.fragment.is_empty());
    }

    #[test]
    fn lines_spanning_chunks_are_reassembled() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("x.jsonl");
        let long = "x".repeat(CHUNK + 17);
        std::fs::write(&path, format!("a\n{long}\nb\n")).unwrap();
        let size = std::fs::metadata(&path).unwrap().len();
        let (lines, summary) = collect(&path, 0, size);
        assert_eq!(lines, ["a".to_string(), long, "b".to_string()]);
        assert_eq!(summary.committed_end, size);
    }

    #[test]
    fn reading_stops_at_the_stat_size_even_if_the_file_grew() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("x.jsonl");
        std::fs::write(&path, b"one\ntwo\n").unwrap();
        let (lines, _) = collect(&path, 0, 4);
        assert_eq!(lines, ["one"]);
    }

    #[test]
    fn anchor_detects_rewrites_but_not_appends() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("x.jsonl");
        let body: String = (0..2000).map(|i| format!("{{\"n\":{i}}}\n")).collect();
        std::fs::write(&path, &body).unwrap();
        let end = body.len() as u64;
        let anchor = prefix_anchor(&path, end).unwrap();
        std::fs::write(&path, format!("{body}{{\"n\":-1}}\n")).unwrap();
        assert_eq!(prefix_anchor(&path, end).unwrap(), anchor);
        std::fs::write(&path, body.replacen("\"n\":0}", "\"n\":9}", 1)).unwrap();
        assert_ne!(prefix_anchor(&path, end).unwrap(), anchor);
    }

    #[test]
    fn zstd_archives_stream_every_line() {
        // `printf 'a\nbb\nccc' | zstd -19 | xxd -i` (no trailing newline: the last line still counts).
        let compressed: &[u8] = &[
            0x28, 0xb5, 0x2f, 0xfd, 0x04, 0x68, 0x41, 0x00, 0x00, 0x61, 0x0a, 0x62, 0x62, 0x0a, 0x63,
            0x63, 0x63, 0x89, 0xaf, 0x7a, 0x1b,
        ];
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("x.jsonl.zst");
        std::fs::write(&path, compressed).unwrap();
        let mut lines = Vec::new();
        read_zstd_lines(&path, |l| {
            lines.push(String::from_utf8(l.to_vec()).unwrap());
            true
        })
        .unwrap();
        assert_eq!(lines, ["a", "bb", "ccc"]);
    }
}
