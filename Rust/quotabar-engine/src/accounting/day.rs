//! The local-calendar day-key contract (Swift `DailyUsageAccumulator.dayKey`, `UsageHistoryWindow`,
//! `SpendTileMapper.dayKey(fromUsageDate:)`): one `yyyy-MM-dd` spelling shared by the accumulator, the
//! spend tiles and the history window, so day-key drift cannot reappear.

use crate::model::Timestamp;
use crate::time::{days_from_civil, parse_iso8601};
use chrono::{DateTime, Datelike, Days, FixedOffset, Local, Months, NaiveDate, Utc};
use std::collections::BTreeSet;

/// The calendar a day key is read in: the user's local time zone in production (Swift
/// `Calendar.current`), or a fixed offset for deterministic tests and non-local callers.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DayZone {
    Local,
    Fixed(FixedOffset),
}

impl DayZone {
    pub fn utc() -> Self {
        DayZone::Fixed(FixedOffset::east_opt(0).expect("zero offset is valid"))
    }

    /// A fixed zone `seconds` east of UTC; `None` when out of range.
    pub fn fixed_east(seconds: i32) -> Option<Self> {
        FixedOffset::east_opt(seconds).map(DayZone::Fixed)
    }

    /// The calendar date of `timestamp` in this zone; `None` for non-finite or out-of-range values.
    pub fn local_date(self, timestamp: Timestamp) -> Option<NaiveDate> {
        if !timestamp.is_finite() {
            return None;
        }
        let floor = timestamp.floor();
        let nanos = ((timestamp - floor) * 1e9) as u32;
        let utc: DateTime<Utc> = DateTime::from_timestamp(floor as i64, nanos.min(999_999_999))?;
        Some(match self {
            DayZone::Local => utc.with_timezone(&Local).date_naive(),
            DayZone::Fixed(offset) => utc.with_timezone(&offset).date_naive(),
        })
    }

    /// `yyyy-MM-dd` for `timestamp`; `0000-00-00` when the instant has no calendar date (Swift prints
    /// missing date components as zero).
    pub fn day_key(self, timestamp: Timestamp) -> String {
        match self.local_date(timestamp) {
            Some(date) => format_day(date),
            None => "0000-00-00".to_string(),
        }
    }
}

/// `yyyy-MM-dd`, zero-padded like Swift's `String(format: "%04d-%02d-%02d")`.
pub fn format_day(date: NaiveDate) -> String {
    format!("{:04}-{:02}-{:02}", date.year(), date.month(), date.day())
}

/// Local calendar day as `yyyy-MM-dd` in the user's time zone.
pub fn day_key(timestamp: Timestamp) -> String {
    DayZone::Local.day_key(timestamp)
}

/// [`day_key`] in an explicit zone (tests).
pub fn day_key_in(timestamp: Timestamp, zone: DayZone) -> String {
    zone.day_key(timestamp)
}

/// True when `value` is exactly ten characters of `yyyy-MM-dd` shape (ASCII digits and dashes).
/// Calendar validity is the caller's concern.
fn has_iso_day_shape(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 10
        && bytes.iter().enumerate().all(|(i, b)| if i == 4 || i == 7 { *b == b'-' } else { b.is_ascii_digit() })
}

/// The leading `yyyy-MM-dd` of a timestamp-shaped string, if it starts with one.
fn iso_day_prefix(value: &str) -> Option<String> {
    if value.len() < 10 {
        return None;
    }
    let prefix: String = value.chars().take(10).collect();
    has_iso_day_shape(&prefix).then_some(prefix)
}

/// `yyyyMMdd` to `yyyy-MM-dd`, or `None` when the input is not exactly eight ASCII digits.
fn compact_day_key(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    if bytes.len() != 8 || !bytes.iter().all(u8::is_ascii_digit) {
        return None;
    }
    Some(format!("{}-{}-{}", &value[..4], &value[4..6], &value[6..]))
}

const MONTHS: [&str; 12] = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];

/// The fallback `MMM dd, yyyy` shape ("Jun 21, 2026"), read as a calendar date.
fn parse_month_day_year(value: &str) -> Option<String> {
    let (month_text, rest) = value.split_once(char::is_whitespace)?;
    let month = MONTHS.iter().position(|m| m.eq_ignore_ascii_case(month_text))? as u32 + 1;
    let (day_text, year_text) = rest.trim_start().split_once(',')?;
    let (day_text, year_text) = (day_text.trim(), year_text.trim());
    if day_text.is_empty() || day_text.len() > 2 || year_text.len() != 4 {
        return None;
    }
    if !day_text.bytes().all(|b| b.is_ascii_digit()) || !year_text.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let date = NaiveDate::from_ymd_opt(year_text.parse().ok()?, month, day_text.parse().ok()?)?;
    Some(format_day(date))
}

/// Normalize a usage row's raw date (`2026-06-20`, an ISO timestamp, `20260620`, `Jun 20, 2026`) to a
/// local `yyyy-MM-dd` key; `None` when it is none of those.
pub fn day_key_from_usage_date(raw: &str, zone: DayZone) -> Option<String> {
    let value = raw.trim();
    if value.is_empty() {
        return None;
    }
    if has_iso_day_shape(value) {
        return Some(value.to_string());
    }
    if let Some(timestamp) = parse_iso8601(value) {
        return Some(zone.day_key(timestamp));
    }
    iso_day_prefix(value).or_else(|| compact_day_key(value)).or_else(|| parse_month_day_year(value))
}

/// The calendar window shared by local scanners, combined iCloud history and the usage trend.
pub struct UsageHistoryWindow;

impl UsageHistoryWindow {
    /// Total calendar days in the "Last 30 Days" window, **including today**. Every provider must agree
    /// on this number because `TotalSpendAggregator` sums the tiles into one cross-provider figure.
    pub const TOTAL_DAYS: usize = 30;

    /// Days strictly before today (`TOTAL_DAYS - 1`): the `daysBack` scan-window argument.
    pub const PREVIOUS_DAYS: usize = Self::TOTAL_DAYS - 1;

    /// The Usage History lifetime window: ten calendar years back from today, inclusive. Calendar year
    /// arithmetic keeps the cutoff on the same month/day, clamping a leap day.
    pub fn lifetime_days(now: Timestamp, zone: DayZone) -> usize {
        let Some(today) = zone.local_date(now) else { return 1 };
        let first = today.checked_sub_months(Months::new(120)).unwrap_or(today);
        let span = days_from_civil(today.year().into(), today.month(), today.day())
            - days_from_civil(first.year().into(), first.month(), first.day());
        (span + 1).max(1) as usize
    }

    /// The 30 day keys ending today.
    pub fn day_keys(now: Timestamp, zone: DayZone) -> BTreeSet<String> {
        Self::day_keys_count(now, Self::TOTAL_DAYS, zone)
    }

    /// Day keys retained for the Usage History lifetime report, including today.
    pub fn lifetime_day_keys(now: Timestamp, zone: DayZone) -> BTreeSet<String> {
        Self::day_keys_count(now, Self::lifetime_days(now, zone), zone)
    }

    fn day_keys_count(now: Timestamp, count: usize, zone: DayZone) -> BTreeSet<String> {
        let Some(today) = zone.local_date(now) else { return BTreeSet::new() };
        (0..count as u64)
            .filter_map(|offset| today.checked_sub_days(Days::new(offset)))
            .map(format_day)
            .collect()
    }
}
