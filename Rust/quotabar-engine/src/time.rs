//! Timestamp parsing and formatting shared by scanners, caches and pricing (Swift
//! `OpenUsageISO8601`). Timestamps are `f64` seconds since 1970 everywhere in the engine.

/// Foundation's reference date (2001-01-01T00:00:00Z) in Unix seconds. Swift `JSONEncoder` writes
/// `Date` as seconds since this instant by default, so caches shared with the Swift app use it.
pub const REFERENCE_DATE_UNIX: f64 = 978_307_200.0;

/// Swift `Date.distantPast.timeIntervalSince1970`.
pub const DISTANT_PAST: f64 = -62_135_769_600.0;

/// Proleptic Gregorian days since 1970-01-01 (Howard Hinnant's civil-date transform).
pub fn days_from_civil(year: i64, month: u32, day: u32) -> i64 {
    let y = year - i64::from(month <= 2);
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let m = i64::from(month);
    let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + i64::from(day) - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// Inverse of [`days_from_civil`]: `(year, month, day)`.
pub fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (yoe + era * 400 + i64::from(month <= 2), month, day)
}

fn days_in_month(year: i64, month: u32) -> u32 {
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    match month {
        2 if leap => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

fn digits(bytes: &[u8]) -> Option<i64> {
    if bytes.is_empty() || !bytes.iter().all(u8::is_ascii_digit) {
        return None;
    }
    Some(
        bytes
            .iter()
            .fold(0i64, |acc, b| acc * 10 + i64::from(b - b'0')),
    )
}

/// Parse the ISO-8601 shapes provider logs and APIs emit: `2026-05-01T10:00:00Z`, fractional seconds
/// (truncated to milliseconds, like Swift), `±HH:MM` offsets, a space instead of `T`, a trailing
/// ` UTC`, and zone-less values (read as UTC).
pub fn parse_iso8601(raw: &str) -> Option<f64> {
    let s = raw.trim();
    let bytes = s.as_bytes();
    if bytes.len() < 19 {
        return None;
    }
    let head = &bytes[..19];
    let shape_ok = head[4] == b'-'
        && head[7] == b'-'
        && (head[10] == b'T' || head[10] == b' ')
        && head[13] == b':'
        && head[16] == b':';
    if !shape_ok {
        return None;
    }
    let year = digits(&head[0..4])?;
    let month = digits(&head[5..7])? as u32;
    let day = digits(&head[8..10])? as u32;
    let hour = digits(&head[11..13])?;
    let minute = digits(&head[14..16])?;
    let second = digits(&head[17..19])?;
    if year <= 0 || !(1..=12).contains(&month) || hour > 23 || minute > 59 || second > 59 {
        return None;
    }
    if day < 1 || day > days_in_month(year, month) {
        return None;
    }

    let mut rest = &s[19..];
    let mut millis = 0i64;
    if let Some(after_dot) = rest.strip_prefix('.') {
        let count = after_dot.bytes().take_while(u8::is_ascii_digit).count();
        if count == 0 {
            return None;
        }
        let mut frac: Vec<u8> = after_dot.as_bytes()[..count.min(3)].to_vec();
        frac.resize(3, b'0');
        millis = digits(&frac)?;
        rest = &after_dot[count..];
    }
    let offset_seconds = match rest {
        "" | "Z" | "z" | " UTC" => 0,
        tz => {
            let sign = match tz.as_bytes()[0] {
                b'+' => 1,
                b'-' => -1,
                _ => return None,
            };
            let body = tz[1..].replace(':', "");
            if body.len() != 4 {
                return None;
            }
            let hh = digits(&body.as_bytes()[0..2])?;
            let mm = digits(&body.as_bytes()[2..4])?;
            if hh > 23 || mm > 59 {
                return None;
            }
            sign * (hh * 3600 + mm * 60)
        }
    };
    let whole = days_from_civil(year, month, day) * 86_400 + hour * 3_600 + minute * 60 + second
        - offset_seconds;
    Some(whole as f64 + millis as f64 / 1_000.0)
}

/// `YYYY-MM-DD` (midnight UTC) or any [`parse_iso8601`] shape — the supplement's `updated_at` and the
/// catalogs' `retrieved_at`.
pub fn parse_feed_date(value: &str) -> Option<f64> {
    if let Some(ts) = parse_iso8601(value) {
        return Some(ts);
    }
    let b = value.as_bytes();
    if b.len() == 10 && b[4] == b'-' && b[7] == b'-' {
        return parse_iso8601(&format!("{value}T00:00:00Z"));
    }
    None
}

/// `2026-05-01T10:00:00.123Z` (UTC, millisecond precision).
pub fn format_iso8601(timestamp: f64) -> String {
    let millis_total = (timestamp * 1_000.0).floor() as i64;
    let seconds = millis_total.div_euclid(1_000);
    let millis = millis_total.rem_euclid(1_000);
    let (year, month, day) = civil_from_days(seconds.div_euclid(86_400));
    let sod = seconds.rem_euclid(86_400);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{millis:03}Z",
        sod / 3_600,
        sod % 3_600 / 60,
        sod % 60
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_common_shapes() {
        let base = 1_777_629_600.0; // 2026-05-01T10:00:00Z
        assert_eq!(parse_iso8601("2026-05-01T10:00:00Z"), Some(base));
        assert_eq!(
            parse_iso8601("2026-05-01T10:00:00.1239Z"),
            Some(base + 0.123)
        );
        assert_eq!(parse_iso8601("2026-05-01 10:00:00"), Some(base));
        assert_eq!(parse_iso8601("2026-05-01 10:00:00 UTC"), Some(base));
        assert_eq!(parse_iso8601("2026-05-01T12:30:00+02:30"), Some(base));
        assert_eq!(parse_iso8601(" 2026-05-01T10:00:00 "), Some(base));
        assert_eq!(parse_iso8601("2026-02-30T10:00:00Z"), None);
        assert_eq!(parse_iso8601("2026-05-01T24:00:00Z"), None);
        assert_eq!(parse_iso8601("nope"), None);
        assert_eq!(parse_feed_date("2026-05-01"), Some(base - 36_000.0));
    }

    #[test]
    fn formats_and_round_trips() {
        assert_eq!(format_iso8601(1_777_629_600.5), "2026-05-01T10:00:00.500Z");
        for days in [-1_000_000i64, -1, 0, 59, 20_000, 1_000_000] {
            let (y, m, d) = civil_from_days(days);
            assert_eq!(days_from_civil(y, m, d), days);
        }
    }
}
