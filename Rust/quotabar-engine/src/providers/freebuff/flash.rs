//! Direct DeepSeek API comparison only (`FreebuffFlashComparison.swift`). Prices published by
//! DeepSeek; these are not Freebuff charges.

use crate::model::Timestamp;
use crate::pricing::ModelRates;
use crate::time;

pub const ROUTE: &str = "deepseek/deepseek-v4.1-flash";
/// 2026-09-10 04:00 UTC.
const EFFECTIVE: Timestamp = 1_789_012_800.0;

pub fn matches_route(route: &str) -> bool {
    let name = route.to_lowercase();
    let slug = name.strip_prefix("deepseek/").unwrap_or(&name);
    matches!(
        slug,
        "deepseek-flash"
            | "deepseek-v4-flash"
            | "deepseek-v4-flash-vision-exp"
            | "deepseek-v4.1-flash"
            | "deepseek-v4.1-flash-1017"
            | "deepseek-v4.1-flash-fast"
    )
}

fn off_peak() -> ModelRates {
    ModelRates::new(0.15, 0.60, 0.15, 0.003)
}

fn peak() -> ModelRates {
    ModelRates::new(0.30, 1.20, 0.30, 0.006)
}

/// State Council schedules: gov.cn/zhengce/zhengceku/202511/content_7047091.htm
/// and gov.cn/zhengce/content/202611/content_7085101.htm. Unknown years use the off-peak baseline.
fn holidays(year: i64) -> Option<&'static [(i64, i64)]> {
    match year {
        2026 => Some(&[(101, 103), (215, 223), (404, 406), (501, 505), (619, 621), (925, 927), (1001, 1007)]),
        2027 => Some(&[(101, 103), (205, 213), (403, 405), (501, 505), (609, 609), (915, 915), (1001, 1007)]),
        _ => None,
    }
}

pub fn rates(route: &str, at: Timestamp) -> Option<ModelRates> {
    if at < EFFECTIVE || !matches_route(route) {
        return None;
    }
    let seconds = at.floor() as i64;
    let days = seconds.div_euclid(86_400);
    let hour = seconds.rem_euclid(86_400) / 3_600;
    let (year, month, day) = time::civil_from_days(days);
    // 1970-01-01 was a Thursday; Swift `weekday` counts Sunday as 1.
    let weekday = (days + 4).rem_euclid(7) + 1;
    let md = i64::from(month) * 100 + i64::from(day);
    let is_peak = (2..=6).contains(&weekday)
        && ((1..4).contains(&hour) || (6..10).contains(&hour))
        && holidays(year).is_some_and(|ranges| !ranges.iter().any(|(lo, hi)| (*lo..=*hi).contains(&md)));
    // Both UTC peak windows fall on the same civil date in China.
    Some(if is_peak { peak() } else { off_peak() })
}
