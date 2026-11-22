//! Z.ai live usage: `ZAI_API_KEY`/`GLM_API_KEY` →
//! `GET api.z.ai/api/monitor/usage/quota/limit`. The `(unit, number)` window
//! classification and the "no coding plan" signal mirror the Swift mapper; a
//! `TIME_LIMIT` entry is the monthly web-search count.

use super::*;

const QUOTA_URL: &str = "https://api.z.ai/api/monitor/usage/quota/limit";
const MISSING_KEY_MESSAGE: &str = "No Z.ai API key. Set ZAI_API_KEY, then refresh.";
const INVALID_KEY_MESSAGE: &str =
    "Z.ai API key invalid. Check your key at z.ai/manage-apikey/apikey-list, then refresh.";
const NO_PLAN_MESSAGE: &str =
    "No active GLM Coding Plan. Subscribe at z.ai/subscribe to see usage.";
const HOUR_MS: f64 = 60.0 * 60.0 * 1000.0;
const DAY_MS: f64 = 24.0 * HOUR_MS;
/// A reported reset this far ahead (epoch milliseconds) is still believable.
const MAX_RESET_HORIZON_MS: u64 = 2 * 365 * 24 * 60 * 60 * 1000;

pub(super) fn refresh() -> RefreshResult<Snapshot> {
    let key = api_key(&["ZAI_API_KEY", "GLM_API_KEY"], MISSING_KEY_MESSAGE)?;
    let client = http_client()?;
    let response = get_json(&client, QUOTA_URL, &key, &[])?;
    require_success(response.status, INVALID_KEY_MESSAGE)?;
    let root = json_object(&response.body)?;

    // A valid key on an account without a GLM Coding Plan answers a 2xx with
    // `{"success":false, "msg":"…coding plan"}` — a distinct account state, not
    // a malformed response. Other body-level failures stay generic.
    if root.get("success") == Some(&Value::Bool(false)) {
        if is_no_coding_plan(&root) {
            return Err(setup(NO_PLAN_MESSAGE));
        }
        return Err(invalid_response());
    }

    let now = now_ms();
    let metrics = map_quota(&root, now)?;
    Ok(Snapshot { metrics, updated_at_ms: now, warning: None })
}

/// The "valid key, but no GLM Coding Plan" signal: structured `success:false`
/// plus the "coding plan" phrase the message carries, so an unrelated business
/// failure doesn't trip it.
fn is_no_coding_plan(root: &Map<String, Value>) -> bool {
    string(root.get("msg"))
        .unwrap_or_default()
        .to_lowercase()
        .contains("coding plan")
}

fn limit_type<'a>(entry: &'a Map<String, Value>) -> Option<&'a str> {
    string(entry.get("type")).or_else(|| string(entry.get("name")))
}

/// A percentage entry's window: `(unit, number)` where unit 3/4/6/5 is
/// hour/day/week/30 days. Sub-daily → Session, multi-day → Weekly. Unknown
/// units are ignored quietly so a future window can't hide meters we still
/// understand; unreadable windows are `damaged` and counted toward the
/// "recognized but unmappable" failure.
enum WindowOutcome {
    Session,
    Weekly,
    Unknown,
    Damaged,
}

fn classify_window(entry: &Map<String, Value>) -> WindowOutcome {
    let (Some(unit), Some(count)) = (number(entry.get("unit")), number(entry.get("number"))) else {
        return WindowOutcome::Damaged;
    };
    if count <= 0.0 {
        return WindowOutcome::Damaged;
    }
    let unit_ms = match unit {
        3.0 => HOUR_MS,
        4.0 => DAY_MS,
        6.0 => 7.0 * DAY_MS,
        5.0 => 30.0 * DAY_MS,
        _ => return WindowOutcome::Unknown,
    };
    let duration_ms = unit_ms * count;
    if !duration_ms.is_finite() || duration_ms < 1.0 {
        return WindowOutcome::Damaged;
    }
    if duration_ms < DAY_MS {
        WindowOutcome::Session
    } else {
        WindowOutcome::Weekly
    }
}

/// A percentage meter from a CREDIT_LIMIT/TOKENS_LIMIT entry. `None` when the
/// percentage itself is unreadable — its siblings' meters still render.
fn percent_line(
    entry: &Map<String, Value>,
    id: &'static str,
    label: &'static str,
    now: u64,
) -> Option<Metric> {
    let percentage = number(entry.get("percentage")).map(clamp_percent)?;
    Some(Metric {
        id,
        label,
        value: percentage,
        limit: Some(100.0),
        unit: Unit::Percent,
        reset_at_ms: reset_at(entry.get("nextResetTime"), now),
        on_demand: false,
    })
}

/// TIME_LIMIT → monthly web-search/reader count. A zero cap is a plan without
/// web searches, not a measurement of zero use — no meter.
fn web_search_line(entry: &Map<String, Value>, now: u64) -> WebSearchOutcome {
    let (Some(used), Some(limit)) =
        (number(entry.get("currentValue")), number(entry.get("usage")))
    else {
        return WebSearchOutcome::Damaged;
    };
    if used < 0.0 || limit < 0.0 {
        return WebSearchOutcome::Damaged;
    }
    if limit == 0.0 {
        return WebSearchOutcome::NotApplicable;
    }
    WebSearchOutcome::Yielded(Metric {
        id: "zai.webSearches",
        label: "Web Searches",
        value: used,
        limit: Some(limit),
        unit: Unit::Count,
        reset_at_ms: reset_at(entry.get("nextResetTime"), now),
        on_demand: true,
    })
}

enum WebSearchOutcome {
    Yielded(Metric),
    NotApplicable,
    Damaged,
}

/// `nextResetTime` is epoch milliseconds, accepted only when still ahead of
/// now and inside the two-year horizon.
fn reset_at(value: Option<&Value>, now: u64) -> Option<u64> {
    let ms = number(value).filter(|ms| *ms > 0.0)?;
    future_ms(ms as i64, now, MAX_RESET_HORIZON_MS)
}

fn map_quota(root: &Map<String, Value>, now: u64) -> RefreshResult<Vec<Metric>> {
    // The limits array lives under `data.limits`; the legacy payload also
    // allowed the root object to be the container directly — honor both, but a
    // present `data` must be an object.
    let container = match root.get("data") {
        Some(data) => obj(Some(data)).ok_or_else(invalid_response)?,
        None => root,
    };
    let limits = arr(container.get("limits")).ok_or_else(invalid_response)?;
    // An explicitly empty quota list is a valid no-data state, not an error.
    if limits.is_empty() {
        return Ok(Vec::new());
    }

    let mut metrics = Vec::new();
    let mut saw_recognized = false;

    for entry in limits.iter().filter_map(|e| obj(Some(e))) {
        match limit_type(entry) {
            Some("CREDIT_LIMIT") | Some("TOKENS_LIMIT") => match classify_window(entry) {
                WindowOutcome::Session => {
                    saw_recognized = true;
                    if let Some(metric) = percent_line(entry, "zai.session", "Session", now) {
                        metrics.push(metric);
                    }
                }
                WindowOutcome::Weekly => {
                    saw_recognized = true;
                    if let Some(metric) = percent_line(entry, "zai.weekly", "Weekly", now) {
                        metrics.push(metric);
                    }
                }
                WindowOutcome::Unknown => {}
                WindowOutcome::Damaged => saw_recognized = true,
            },
            _ => {}
        }
    }

    if let Some(web) = limits
        .iter()
        .filter_map(|e| obj(Some(e)))
        .find(|entry| limit_type(entry) == Some("TIME_LIMIT"))
    {
        match web_search_line(web, now) {
            WebSearchOutcome::Yielded(metric) => {
                saw_recognized = true;
                metrics.push(metric);
            }
            WebSearchOutcome::NotApplicable => {}
            WebSearchOutcome::Damaged => saw_recognized = true,
        }
    }

    if metrics.is_empty() && saw_recognized {
        // Entries claimed meters we couldn't read — invalid, not "no usage".
        return Err(invalid_response());
    }
    Ok(metrics)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn root(json: &str) -> Map<String, Value> {
        serde_json::from_str::<Value>(json)
            .unwrap()
            .as_object()
            .unwrap()
            .clone()
    }

    fn future_reset(now: u64) -> u64 {
        now + 10 * 24 * 60 * 60 * 1000
    }

    #[test]
    fn maps_session_weekly_and_web_searches() {
        let now = now_ms();
        let reset = future_reset(now);
        let root = root(&format!(
            r#"{{"data": {{"limits": [
                {{"type": "CREDIT_LIMIT", "unit": 3, "number": 5, "percentage": 23,
                   "nextResetTime": {reset}}},
                {{"type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 48}},
                {{"type": "TIME_LIMIT", "currentValue": 34, "usage": 100,
                   "nextResetTime": {reset}}}
            ]}}}}"#
        ));
        let metrics = map_quota(&root, now).unwrap();
        assert_eq!(metrics.len(), 3);
        assert_eq!(metrics[0].id, "zai.session");
        assert_eq!(metrics[0].value, 23.0);
        assert_eq!(metrics[0].reset_at_ms, Some(reset));
        assert_eq!(metrics[1].id, "zai.weekly");
        assert_eq!(metrics[2].id, "zai.webSearches");
        assert_eq!(metrics[2].limit, Some(100.0));
        assert!(metrics[2].on_demand);
    }

    #[test]
    fn unknown_units_do_not_blank_valid_siblings() {
        let now = now_ms();
        let root = root(
            r#"{"data": {"limits": [
                {"type": "CREDIT_LIMIT", "unit": 99, "number": 1, "percentage": 90},
                {"type": "CREDIT_LIMIT", "unit": 3, "number": 5, "percentage": 12}
            ]}}"#,
        );
        let metrics = map_quota(&root, now).unwrap();
        assert_eq!(metrics.len(), 1);
        assert_eq!(metrics[0].id, "zai.session");
    }

    #[test]
    fn day_long_windows_are_weekly_and_sub_daily_are_session() {
        let now = now_ms();
        let root = root(
            r#"{"limits": [
                {"type": "CREDIT_LIMIT", "unit": 4, "number": 1, "percentage": 55},
                {"type": "CREDIT_LIMIT", "unit": 3, "number": 23, "percentage": 10}
            ]}"#,
        );
        let metrics = map_quota(&root, now).unwrap();
        assert_eq!(metrics[0].id, "zai.weekly");
        assert_eq!(metrics[1].id, "zai.session");
    }

    #[test]
    fn zero_cap_time_limit_is_omitted_and_empty_quota_is_no_usage() {
        let now = now_ms();
        let zero_cap = root(r#"{"limits": [{"type": "TIME_LIMIT", "currentValue": 0, "usage": 0}]}"#);
        assert!(map_quota(&zero_cap, now).unwrap().is_empty());
        let empty = root(r#"{"data": {"limits": []}}"#);
        assert!(map_quota(&empty, now).unwrap().is_empty());
    }

    #[test]
    fn damaged_recognized_entries_are_invalid_not_zero() {
        let now = now_ms();
        let root = root(r#"{"limits": [{"type": "CREDIT_LIMIT", "percentage": 40}]}"#);
        assert_eq!(map_quota(&root, now).unwrap_err().kind, ErrorKind::Invalid);
    }

    #[test]
    fn unrecognized_payload_is_invalid() {
        let now = now_ms();
        assert_eq!(map_quota(&root(r#"{"data": {"other": []}}"#), now).unwrap_err().kind, ErrorKind::Invalid);
        assert_eq!(map_quota(&root(r#"{"data": "text"}"#), now).unwrap_err().kind, ErrorKind::Invalid);
    }

    #[test]
    fn no_coding_plan_matches_the_structured_signal_only() {
        assert!(is_no_coding_plan(&root(
            r#"{"success": false, "code": 500, "msg": "no active coding plan"}"#
        )));
        assert!(!is_no_coding_plan(&root(r#"{"success": false, "msg": "rate limited"}"#)));
    }
}
