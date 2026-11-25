//! Small helpers shared by the Claude log modules.

use chrono::{DateTime, Days, Local, LocalResult, NaiveDate, TimeZone};
use sha2::{Digest, Sha256};
use std::path::{Component, Path, PathBuf};

/// Start of the local-calendar day `days_back` days before `now` (Swift `JSONLScanning.sinceDate`):
/// the lower bound of the scan window, in the machine's time zone.
pub fn since_date(days_back: usize, now: f64) -> f64 {
    let Some(utc) = DateTime::from_timestamp(now.floor() as i64, 0) else { return now };
    let today = utc.with_timezone(&Local).date_naive();
    today
        .checked_sub_days(Days::new(days_back as u64))
        .and_then(start_of_local_day)
        .unwrap_or(now)
}

/// The first instant of `date` in the local zone (a midnight skipped by a DST jump starts at the first
/// valid hour; an ambiguous midnight takes the earlier instant).
fn start_of_local_day(date: NaiveDate) -> Option<f64> {
    (0..4).find_map(|hour| {
        let midnight = date.and_hms_opt(hour, 0, 0)?;
        match Local.from_local_datetime(&midnight) {
            LocalResult::Single(t) | LocalResult::Ambiguous(t, _) => Some(t.timestamp() as f64),
            LocalResult::None => None,
        }
    })
}

/// The UTC offsets in force at `since` and `now`: part of the fold-cache key, so a change of zone (or
/// a DST transition inside the window) never reuses day buckets cut in the old calendar.
pub fn zone_signature(since: f64, now: f64) -> String {
    let offset = |t: f64| {
        DateTime::from_timestamp(t.floor() as i64, 0)
            .map_or_else(|| "?".to_string(), |utc| utc.with_timezone(&Local).offset().to_string())
    };
    format!("{}/{}", offset(since), offset(now))
}

/// Stable short fingerprint for diagnostic keys and partition names (Swift
/// `JSONLScanCachePaths.stableFingerprint`), so a user's paths never appear in either.
pub fn stable_fingerprint(value: &str) -> String {
    Sha256::digest(value.as_bytes()).iter().take(8).map(|b| format!("{b:02x}")).collect()
}

/// Swift `resolvingSymlinksInPath().standardizedFileURL`: symlinks resolved as far as the path exists
/// (the missing tail is kept), `.` and `..` folded away.
pub fn resolve_path(path: &Path) -> PathBuf {
    let absolute = std::path::absolute(path).unwrap_or_else(|_| path.to_path_buf());
    if let Ok(real) = std::fs::canonicalize(&absolute) {
        return real;
    }
    let mut existing = standardize(&absolute);
    let mut tail = Vec::new();
    while let Some(name) = existing.file_name().map(|n| n.to_owned()) {
        tail.push(name);
        existing.pop();
        if let Ok(mut real) = std::fs::canonicalize(&existing) {
            real.extend(tail.iter().rev());
            return real;
        }
    }
    standardize(&absolute)
}

fn standardize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// Swift `expandHome` against an explicit home directory.
pub fn expand_home(home: &Path, path: &str) -> PathBuf {
    if path == "~" {
        return home.to_path_buf();
    }
    match path.strip_prefix("~/").or_else(|| path.strip_prefix("~\\")) {
        Some(rest) => home.join(rest),
        None => PathBuf::from(path),
    }
}

/// Swift `UUID(uuidString:)` followed by `.uuidString.lowercased()`: the canonical 8-4-4-4-12 hex
/// spelling only.
pub fn normalized_uuid(raw: &str) -> Option<String> {
    let bytes = raw.as_bytes();
    let shaped = bytes.len() == 36
        && bytes.iter().enumerate().all(|(i, b)| match i {
            8 | 13 | 18 | 23 => *b == b'-',
            _ => b.is_ascii_hexdigit(),
        });
    shaped.then(|| raw.to_ascii_lowercase())
}
