use super::*;
use crate::scan::codec::{Reader, Writer};
use crate::scan::discover::{discover, Extensions};
use std::io::Write as _;

/// Rows are `n=<number>`; the state counts rows so far (exercises resumable parser state).
/// `bad` is malformed; lines without `n=` are ignored by the prefilter.
struct CountingParser;

#[derive(Clone, Debug, PartialEq)]
struct Row {
    n: i64,
    ordinal: u64,
}

impl Record for Row {
    fn encode(&self, w: &mut Writer) {
        w.i64(self.n);
        w.varint(self.ordinal);
    }
    fn decode(r: &mut Reader<'_>) -> Option<Self> {
        Some(Row {
            n: r.i64()?,
            ordinal: r.varint()?,
        })
    }
}

#[derive(Clone, Default, Debug)]
struct Count(u64);

impl Record for Count {
    fn encode(&self, w: &mut Writer) {
        w.varint(self.0);
    }
    fn decode(r: &mut Reader<'_>) -> Option<Self> {
        Some(Count(r.varint()?))
    }
}

impl LineParser for CountingParser {
    type Item = Row;
    type State = Count;
    const LAYOUT: u32 = 1;

    fn wants(&self, line: &[u8]) -> bool {
        line.starts_with(b"n=") || line == b"bad"
    }

    fn parse(&self, state: &mut Count, line: &[u8], out: &mut Vec<Row>) -> Result<(), LineError> {
        let text = std::str::from_utf8(line).map_err(|_| LineError("utf8"))?;
        let n = text
            .strip_prefix("n=")
            .and_then(|v| v.parse().ok())
            .ok_or(LineError("not a row"))?;
        state.0 += 1;
        out.push(Row {
            n,
            ordinal: state.0,
        });
        Ok(())
    }
}

fn values(result: &[FileItems<Row>]) -> Vec<(i64, u64)> {
    result
        .iter()
        .flat_map(|f| f.iter().map(|r| (r.n, r.ordinal)))
        .collect()
}

fn append(path: &Path, text: &str) {
    std::fs::OpenOptions::new()
        .append(true)
        .open(path)
        .unwrap()
        .write_all(text.as_bytes())
        .unwrap();
}

fn scan(
    scanner: &IncrementalScanner<CountingParser>,
    root: &Path,
) -> Result<Vec<FileItems<Row>>, ScanError> {
    let files = discover(root, Extensions::Jsonl).unwrap();
    scanner.scan(&files, None, &CancelToken::new())
}

#[test]
fn reuses_unchanged_files_and_resumes_appends_with_parser_state() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("a.jsonl");
    std::fs::write(&path, "n=1\nskip\nn=2\n").unwrap();
    let scanner = IncrementalScanner::new(CountingParser, "test", None);

    assert_eq!(
        values(&scan(&scanner, dir.path()).unwrap()),
        [(1, 1), (2, 2)]
    );
    assert_eq!(scanner.last_stats().full, 1);

    assert_eq!(
        values(&scan(&scanner, dir.path()).unwrap()),
        [(1, 1), (2, 2)]
    );
    assert_eq!(
        scanner.last_stats(),
        ScanStats {
            reused: 1,
            ..Default::default()
        }
    );

    append(&path, "n=3\n");
    assert_eq!(
        values(&scan(&scanner, dir.path()).unwrap()),
        [(1, 1), (2, 2), (3, 3)]
    );
    let stats = scanner.last_stats();
    assert_eq!((stats.appended, stats.full, stats.bytes_read), (1, 0, 4));
}

#[test]
fn a_trailing_partial_line_is_provisional_and_counted_once() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("a.jsonl");
    std::fs::write(&path, "n=1\nn=2").unwrap();
    let scanner = IncrementalScanner::new(CountingParser, "test", None);
    // The unterminated row is visible now...
    assert_eq!(
        values(&scan(&scanner, dir.path()).unwrap()),
        [(1, 1), (2, 2)]
    );
    // ...and when its line completes it is re-read as a whole, not counted twice.
    append(&path, "5\nn=7\n");
    assert_eq!(
        values(&scan(&scanner, dir.path()).unwrap()),
        [(1, 1), (25, 2), (7, 3)]
    );
    assert_eq!(scanner.last_stats().appended, 1);
}

#[test]
fn an_unparseable_trailing_fragment_is_skipped_until_complete() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("a.jsonl");
    std::fs::write(&path, "n=1\nn=").unwrap();
    let scanner = IncrementalScanner::new(CountingParser, "test", None);
    assert_eq!(values(&scan(&scanner, dir.path()).unwrap()), [(1, 1)]);
    append(&path, "4\n");
    assert_eq!(
        values(&scan(&scanner, dir.path()).unwrap()),
        [(1, 1), (4, 2)]
    );
}

#[test]
fn rewrites_and_truncations_force_a_full_parse() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("a.jsonl");
    std::fs::write(&path, "n=1\nn=2\n").unwrap();
    let scanner = IncrementalScanner::new(CountingParser, "test", None);
    scan(&scanner, dir.path()).unwrap();

    // Same length, different content: the prefix signature changes.
    std::fs::write(&path, "n=8\nn=9\nn=3\n").unwrap();
    assert_eq!(
        values(&scan(&scanner, dir.path()).unwrap()),
        [(8, 1), (9, 2), (3, 3)]
    );
    assert_eq!(scanner.last_stats().full, 1);

    std::fs::write(&path, "n=5\n").unwrap();
    assert_eq!(values(&scan(&scanner, dir.path()).unwrap()), [(5, 1)]);
    assert_eq!(scanner.last_stats().full, 1);
}

#[test]
fn a_malformed_complete_line_fails_the_scan_and_keeps_the_last_good_cache() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("a.jsonl");
    std::fs::write(&path, "n=1\n").unwrap();
    let scanner = IncrementalScanner::new(CountingParser, "test", None);
    scan(&scanner, dir.path()).unwrap();
    append(&path, "bad\n");
    assert!(matches!(
        scan(&scanner, dir.path()),
        Err(ScanError::Malformed {
            reason: "not a row",
            ..
        })
    ));
    // The failed scan published nothing; fixing the file recovers through a full parse.
    std::fs::write(&path, "n=1\nn=2\n").unwrap();
    assert_eq!(
        values(&scan(&scanner, dir.path()).unwrap()),
        [(1, 1), (2, 2)]
    );
}

#[test]
fn removed_and_out_of_window_files_leave_the_cache() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("a.jsonl"), "n=1\n").unwrap();
    std::fs::write(dir.path().join("b.jsonl"), "n=2\n").unwrap();
    let scanner = IncrementalScanner::new(CountingParser, "test", None);
    assert_eq!(
        values(&scan(&scanner, dir.path()).unwrap()),
        [(1, 1), (2, 1)]
    );
    let files = discover(dir.path(), Extensions::Jsonl).unwrap();
    let future = files.iter().map(|f| f.revision.mtime()).fold(0.0, f64::max) + 1.0;
    assert!(scanner
        .scan(&files, Some(future), &CancelToken::new())
        .unwrap()
        .is_empty());
    assert!(scanner.state.lock().unwrap().files.is_empty());
}

#[test]
fn cancellation_fails_the_scan() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("a.jsonl"), "n=1\n").unwrap();
    let scanner = IncrementalScanner::new(CountingParser, "test", None);
    let cancel = CancelToken::new();
    cancel.cancel();
    let files = discover(dir.path(), Extensions::Jsonl).unwrap();
    assert!(matches!(
        scanner.scan(&files, None, &cancel),
        Err(ScanError::Cancelled)
    ));
}

#[test]
fn the_persistent_store_survives_a_restart_and_resumes_appends() {
    let logs = tempfile::tempdir().unwrap();
    let cache = tempfile::tempdir().unwrap();
    let store: &'static ScanStore =
        Box::leak(Box::new(ScanStore::at(cache.path().join("scan.sqlite3"))));
    let path = logs.path().join("a.jsonl");
    std::fs::write(&path, "n=1\nn=2\n").unwrap();

    let first = IncrementalScanner::new(CountingParser, "p", Some(store));
    scan(&first, logs.path()).unwrap();
    drop(first);

    // A new process: the rows come from the store, not the log.
    let second = IncrementalScanner::new(CountingParser, "p", Some(store));
    assert_eq!(
        values(&scan(&second, logs.path()).unwrap()),
        [(1, 1), (2, 2)]
    );
    assert_eq!(
        second.last_stats(),
        ScanStats {
            reused: 1,
            ..Default::default()
        }
    );

    append(&path, "n=3\n");
    let third = IncrementalScanner::new(CountingParser, "p", Some(store));
    assert_eq!(
        values(&scan(&third, logs.path()).unwrap()),
        [(1, 1), (2, 2), (3, 3)]
    );
    assert_eq!(third.last_stats().appended, 1);
}

#[test]
fn many_files_parse_in_parallel_and_keep_input_order() {
    let dir = tempfile::tempdir().unwrap();
    for i in 0..40 {
        std::fs::write(dir.path().join(format!("{i:03}.jsonl")), format!("n={i}\n")).unwrap();
    }
    let scanner = IncrementalScanner::new(CountingParser, "test", None);
    let got: Vec<i64> = values(&scan(&scanner, dir.path()).unwrap())
        .into_iter()
        .map(|(n, _)| n)
        .collect();
    assert_eq!(got, (0..40).collect::<Vec<_>>());
}

/// Rows are timestamps; the future guard follows appends and fragments.
struct StampParser;

impl LineParser for StampParser {
    type Item = Row;
    type State = Count;
    const LAYOUT: u32 = 1;

    fn wants(&self, _line: &[u8]) -> bool {
        true
    }

    fn parse(&self, state: &mut Count, line: &[u8], out: &mut Vec<Row>) -> Result<(), LineError> {
        CountingParser.parse(state, line, out)
    }

    fn contributing_timestamp(&self, item: &Row) -> Option<f64> {
        (item.n >= 0).then_some(item.n as f64)
    }
}

#[test]
fn latest_contributing_timestamp_tracks_appends_and_fragments() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("a.jsonl");
    std::fs::write(&path, "n=100\nn=-5\n").unwrap();
    let scanner = IncrementalScanner::new(StampParser, "test", None);
    let scan_stamp = |scanner: &IncrementalScanner<StampParser>| {
        let files = discover(dir.path(), Extensions::Jsonl).unwrap();
        scanner.scan(&files, None, &CancelToken::new()).unwrap()
    };
    let first = scan_stamp(&scanner);
    assert_eq!(first[0].latest_timestamp, Some(100.0));
    assert!(!first[0].is_future_dated(100.0));
    assert!(first[0].is_future_dated(100.0 - FUTURE_TOLERANCE_SECONDS - 1.0));

    append(&path, "n=900");
    let second = scan_stamp(&scanner);
    assert_eq!(second[0].latest_timestamp, Some(900.0));
    assert!(super::first_future_dated(&second, 0.0).is_some());

    // The fragment completes as a smaller value: its provisional maximum must not linger.
    append(&path, "\n");
    std::fs::write(&path, "n=100\nn=-5\nn=90\n").unwrap();
    assert_eq!(scan_stamp(&scanner)[0].latest_timestamp, Some(100.0));
}
