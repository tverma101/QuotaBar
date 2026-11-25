//! DeepSeek V4.1 Flash comparison rates (`FreebuffFlashComparison`).
//!
//! Freebuff serves Flash-family routes for free; QuotaBar prices them at DeepSeek's public API rates
//! from the date those rates took effect. The peak lane applies on Chinese business days during the
//! two UTC windows DeepSeek publishes; holidays and unknown years use the off-peak baseline.

use crate::pricing::ModelRates;
use crate::time::civil_from_days;

/// The route every assumed-standard Flash label prices against.
pub const ROUTE: &str = "deepseek/deepseek-v4.1-flash";
/// 2026-09-10 04:00 UTC.
const EFFECTIVE: f64 = 1_789_012_800.0;

/// State Council schedules: gov.cn/zhengce/zhengceku/202511/content_7047091.htm and
/// gov.cn/zhengce/content/202611/content_7085101.htm, as inclusive `MMDD` ranges.
const HOLIDAYS: &[(i64, &[(u32, u32)])] = &[
    (
        2026,
        &[
            (101, 103),
            (215, 223),
            (404, 406),
            (501, 505),
            (619, 621),
            (925, 927),
            (1001, 1007),
        ],
    ),
    (
        2027,
        &[
            (101, 103),
            (205, 213),
            (403, 405),
            (501, 505),
            (609, 609),
            (915, 915),
            (1001, 1007),
        ],
    ),
];

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

/// Rates for a Flash-family `route` at unix time `at`, or `None` before the effective date or for
/// any other route.
pub fn rates(route: &str, at: f64) -> Option<ModelRates> {
    if at < EFFECTIVE || !matches_route(route) {
        return None;
    }
    Some(if is_peak(at) {
        ModelRates::new(0.30, 1.20, 0.30, 0.006)
    } else {
        ModelRates::new(0.15, 0.60, 0.15, 0.003)
    })
}

fn is_peak(at: f64) -> bool {
    let seconds = at.floor() as i64;
    let days = seconds.div_euclid(86_400);
    let hour = seconds.rem_euclid(86_400) / 3_600;
    // 1970-01-01 was a Thursday: Monday is 0, Friday is 4.
    let weekday = (days + 3).rem_euclid(7);
    if weekday > 4 || !((1..4).contains(&hour) || (6..10).contains(&hour)) {
        return false;
    }
    let (year, month, day) = civil_from_days(days);
    let Some((_, holidays)) = HOLIDAYS.iter().find(|(known, _)| *known == year) else {
        return false;
    };
    // Both UTC peak windows fall on the same civil date in China.
    let date = month * 100 + day;
    !holidays
        .iter()
        .any(|(start, end)| (*start..=*end).contains(&date))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn peak_lane_follows_business_hours_and_holidays() {
        // Tue 2026-11-24 02:00 UTC: peak.
        assert_eq!(
            rates(ROUTE, 1_795_485_600.0).unwrap().input_per_million,
            0.30
        );
        // Same day 05:00 UTC sits between the two windows.
        assert_eq!(
            rates(ROUTE, 1_795_496_400.0).unwrap().input_per_million,
            0.15
        );
        // Sat 2026-11-28 02:00 UTC.
        assert_eq!(
            rates(ROUTE, 1_795_831_200.0).unwrap().input_per_million,
            0.15
        );
        // Thu 2026-10-01 02:00 UTC: National Day.
        assert_eq!(
            rates(ROUTE, 1_790_820_000.0).unwrap().input_per_million,
            0.15
        );
        // Unknown year: off-peak baseline (Fri 2028-11-24 02:00 UTC).
        assert_eq!(
            rates(ROUTE, 1_858_644_000.0).unwrap().input_per_million,
            0.15
        );
        assert!(rates(ROUTE, EFFECTIVE - 1.0).is_none());
        assert!(rates("openai/gpt-6", 1_795_485_600.0).is_none());
        assert!(matches_route("DeepSeek/DeepSeek-V4-Flash"));
    }
}
