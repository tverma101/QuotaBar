//! OpenCode Go meters and local plan windows (`OpenCodeUsageMapper`, `OpenCodeGoWindowMath`).

use super::client::AccountUsage;

pub const SESSION_CAP: f64 = 12.0;
pub const WEEKLY_CAP: f64 = 30.0;
pub const MONTHLY_CAP: f64 = 60.0;
pub const SESSION_MS: i64 = 5 * 60 * 60 * 1000;
pub const WEEK_MS: i64 = 7 * 24 * 60 * 60 * 1000;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct GoWindows {
    pub session_spend: f64,
    pub session_resets_at: Option<f64>,
    pub weekly_spend: f64,
    pub weekly_resets_at: Option<f64>,
    pub monthly_spend: f64,
    pub monthly_resets_at: Option<f64>,
    pub monthly_period_ms: Option<i64>,
}

fn dollars(amount: f64) -> String {
    format!("${amount:.2}")
}

fn percent(spend: f64, cap: f64) -> f64 {
    if !cap.is_finite() || cap <= 0.0 {
        return 0.0;
    }
    if !spend.is_finite() {
        return if spend > 0.0 { 100.0 } else { 0.0 };
    }
    (spend.clamp(0.0, cap) / cap) * 100.0
}

fn progress(
    label: &str,
    used: f64,
    resets_at: Option<f64>,
    period_ms: Option<i64>,
    detail: String,
) -> crate::model::MetricLine {
    crate::model::MetricLine::Progress {
        label: label.to_string(),
        used: crate::model::finite(used),
        limit: 100.0,
        format: crate::model::ProgressFormat::Percent,
        resets_at,
        period_duration_ms: period_ms,
        color_hex: None,
        detail: Some(detail),
    }
}

/// Local fallback meters: this Mac's observed Go spend as a share of the published cap.
pub fn local_meter_lines(windows: &GoWindows) -> Vec<crate::model::MetricLine> {
    vec![
        progress(
            "Session",
            percent(windows.session_spend, SESSION_CAP),
            windows.session_resets_at,
            Some(SESSION_MS),
            format!(
                "{} of {}",
                dollars(windows.session_spend),
                dollars(SESSION_CAP)
            ),
        ),
        progress(
            "Weekly",
            percent(windows.weekly_spend, WEEKLY_CAP),
            windows.weekly_resets_at,
            Some(WEEK_MS),
            format!(
                "{} of {}",
                dollars(windows.weekly_spend),
                dollars(WEEKLY_CAP)
            ),
        ),
        progress(
            "Monthly",
            percent(windows.monthly_spend, MONTHLY_CAP),
            windows.monthly_resets_at,
            windows.monthly_period_ms,
            format!(
                "{} of {}",
                dollars(windows.monthly_spend),
                dollars(MONTHLY_CAP)
            ),
        ),
    ]
}

/// Authoritative account-wide meters. The API percentage is used as-is; the detail is the derived
/// remaining official allowance, never a local estimate.
pub fn account_meter_lines(
    usage: &AccountUsage,
    label_suffix: Option<&str>,
) -> Vec<crate::model::MetricLine> {
    let label = |base: &str| match label_suffix {
        Some(suffix) => format!("{base} ({suffix})"),
        None => base.to_string(),
    };
    let row = |base: &str, percent: i64, resets: Option<f64>, period: Option<i64>, cap: f64| {
        let remaining = cap * (100.0 - percent as f64) / 100.0;
        progress(
            &label(base),
            percent as f64,
            resets,
            period,
            format!("{} of {}", dollars(remaining.max(0.0)), dollars(cap)),
        )
    };
    vec![
        row(
            "Session",
            usage.rolling.percent.unwrap_or(0),
            usage.rolling.resets_at,
            Some(SESSION_MS),
            SESSION_CAP,
        ),
        row(
            "Weekly",
            usage.weekly.percent.unwrap_or(0),
            usage.weekly.resets_at,
            Some(WEEK_MS),
            WEEKLY_CAP,
        ),
        row(
            "Monthly",
            usage.monthly.percent.unwrap_or(0),
            usage.monthly.resets_at,
            None,
            MONTHLY_CAP,
        ),
    ]
}

fn sum_range(costs: &[(f64, f64)], start: f64, end: f64) -> f64 {
    let mut total = 0.0;
    for (ms, cost) in costs {
        if *ms < start || *ms >= end || !cost.is_finite() || *cost < 0.0 {
            continue;
        }
        let next = total + *cost;
        if !next.is_finite() {
            break;
        }
        total = next;
    }
    (total * 10_000.0).round() / 10_000.0
}

fn utc_ms(date: chrono::DateTime<chrono::Utc>) -> f64 {
    date.timestamp_millis() as f64
}

fn anchored_month_start(
    year: i32,
    month: u32,
    anchor: chrono::DateTime<chrono::Utc>,
) -> chrono::DateTime<chrono::Utc> {
    use chrono::{Datelike, TimeZone, Timelike};
    let day = anchor.day().min(days_in_month(year, month));
    chrono::Utc
        .with_ymd_and_hms(
            year,
            month,
            day,
            anchor.hour(),
            anchor.minute(),
            anchor.second(),
        )
        .single()
        .unwrap_or_else(|| {
            chrono::Utc
                .with_ymd_and_hms(year, month, 1, 0, 0, 0)
                .unwrap()
        })
}

fn days_in_month(year: i32, month: u32) -> u32 {
    use chrono::Datelike;
    let first = chrono::NaiveDate::from_ymd_opt(year, month, 1).unwrap();
    let next = if month == 12 {
        chrono::NaiveDate::from_ymd_opt(year + 1, 1, 1)
    } else {
        chrono::NaiveDate::from_ymd_opt(year, month + 1, 1)
    }
    .unwrap();
    (next - first).num_days() as u32
}

fn shift_month(year: i32, month: u32, delta: i32) -> (i32, u32) {
    let total = year * 12 + (month as i32 - 1) + delta;
    (total.div_euclid(12), (total.rem_euclid(12) + 1) as u32)
}

fn anchored_month_bounds(now_ms: f64, anchor_ms: Option<f64>) -> (f64, f64) {
    use chrono::{Datelike, TimeZone, Timelike};
    let now = chrono::Utc
        .timestamp_millis_opt(now_ms as i64)
        .single()
        .unwrap_or_else(chrono::Utc::now);
    let anchor_valid = anchor_ms.filter(|a| a.is_finite() && *a > 0.0 && *a <= now_ms);
    let Some(anchor) =
        anchor_valid.and_then(|a| chrono::Utc.timestamp_millis_opt(a as i64).single())
    else {
        let start = chrono::Utc
            .with_ymd_and_hms(now.year(), now.month(), 1, 0, 0, 0)
            .unwrap();
        let (next_year, next_month) = shift_month(now.year(), now.month(), 1);
        let end = chrono::Utc
            .with_ymd_and_hms(next_year, next_month, 1, 0, 0, 0)
            .unwrap();
        return (utc_ms(start), utc_ms(end));
    };
    let (year, month) = (now.year(), now.month());
    let mut start = anchored_month_start(year, month, anchor);
    let (mut year, mut month) = (year, month);
    if utc_ms(start) > now_ms {
        (year, month) = shift_month(year, month, -1);
        start = anchored_month_start(year, month, anchor);
    }
    let (next_year, next_month) = shift_month(year, month, 1);
    let end = anchored_month_start(next_year, next_month, anchor);
    let _ = (start.hour(), start.minute(), start.second());
    (utc_ms(start), utc_ms(end))
}

/// Rolling five-hour, UTC-week, and anchored-month spend windows. `anchor_ms` is the earliest-ever
/// local Go row; an absent or implausible anchor falls back to the calendar month.
pub fn compute_windows(
    costs: &[(f64, f64)],
    anchor_ms: Option<f64>,
    now: chrono::DateTime<chrono::Utc>,
) -> GoWindows {
    use chrono::{Datelike, TimeZone, Timelike};
    let now_ms = utc_ms(now);
    let session_start = now_ms - SESSION_MS as f64;
    let session_spend = sum_range(costs, session_start, now_ms);
    let oldest_in_session = costs
        .iter()
        .filter(|(ms, _)| *ms >= session_start && *ms < now_ms)
        .map(|(ms, _)| *ms)
        .fold(f64::INFINITY, f64::min);
    let session_anchor = if oldest_in_session.is_finite() {
        oldest_in_session
    } else {
        now_ms
    };
    let session_resets = chrono::Utc
        .timestamp_millis_opt((session_anchor + SESSION_MS as f64) as i64)
        .single()
        .map(utc_ms);

    let start_of_today = chrono::Utc
        .with_ymd_and_hms(now.year(), now.month(), now.day(), 0, 0, 0)
        .unwrap();
    let days_since_monday = now.weekday().num_days_from_monday() as i64;
    let week_start_date = start_of_today - chrono::Duration::days(days_since_monday);
    let week_start = utc_ms(week_start_date);
    let week_end = week_start + WEEK_MS as f64;
    let weekly_spend = sum_range(costs, week_start, week_end);

    let (month_start, month_end) = anchored_month_bounds(now_ms, anchor_ms);
    let monthly_spend = sum_range(costs, month_start, month_end);
    let _ = (now.hour(), now.minute(), now.second());

    GoWindows {
        session_spend,
        session_resets_at: session_resets,
        weekly_spend,
        weekly_resets_at: chrono::Utc
            .timestamp_millis_opt(week_end as i64)
            .single()
            .map(utc_ms),
        monthly_spend,
        monthly_resets_at: chrono::Utc
            .timestamp_millis_opt(month_end as i64)
            .single()
            .map(utc_ms),
        monthly_period_ms: ((month_end - month_start).round() as i64).into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn windows_cover_session_week_and_anchored_month() {
        let now = chrono::Utc.with_ymd_and_hms(2026, 7, 15, 12, 0, 0).unwrap();
        let now_ms = utc_ms(now);
        let costs = vec![
            (now_ms - 1_000.0, 2.0),
            (now_ms - 6.0 * 3_600_000.0, 10.0),
            (now_ms - 3.0 * 86_400_000.0, 5.0),
        ];
        let windows = compute_windows(&costs, Some(now_ms - 40.0 * 86_400_000.0), now);
        assert!((windows.session_spend - 2.0).abs() < 1e-9);
        assert!((windows.weekly_spend - 12.0).abs() < 1e-9);
        assert!(windows.monthly_spend > 0.0);
    }

    #[test]
    fn account_rows_use_api_percent_and_remaining_cap() {
        let usage = super::super::client::AccountUsage {
            rolling: super::super::client::AccountWindow {
                status: "ok".into(),
                percent: Some(80),
                resets_at: None,
            },
            weekly: super::super::client::AccountWindow {
                status: "ok".into(),
                percent: Some(50),
                resets_at: None,
            },
            monthly: super::super::client::AccountWindow {
                status: "ok".into(),
                percent: Some(25),
                resets_at: None,
            },
        };
        let lines = account_meter_lines(&usage, Some("Work"));
        assert_eq!(lines[0].label(), "Session (Work)");
        match &lines[0] {
            crate::model::MetricLine::Progress { used, detail, .. } => {
                assert_eq!(*used, 80.0);
                assert!(detail.as_deref().unwrap().starts_with("$2.40 of $12.00"));
            }
            other => panic!("unexpected {other:?}"),
        }
    }
}
