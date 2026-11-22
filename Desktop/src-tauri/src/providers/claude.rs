//! Claude live usage: `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR`)
//! → `GET api.anthropic.com/api/oauth/usage`, mapped like the Swift client:
//! `five_hour`/`seven_day`/`seven_day_sonnet` utilization percents plus the
//! Fable-scoped weekly entry from `limits`.

use super::*;

const USAGE_URL: &str = "https://api.anthropic.com/api/oauth/usage";
const AUTH_MESSAGE: &str = "Claude sign-in expired. Run `claude` and sign in again, then refresh.";
const CREDENTIALS_UNREADABLE: &str =
    "QuotaBar found Claude credentials but couldn't read them. Check file permissions, then refresh.";

pub(super) fn refresh() -> RefreshResult<Snapshot> {
    let access_token = load_access_token()?;
    let client = http_client()?;
    let response = get_json(
        &client,
        USAGE_URL,
        &access_token,
        &[
            ("anthropic-beta", "oauth-2025-04-20"),
            ("user-agent", "claude-code/2.1.69"),
        ],
    )?;
    require_success(response.status, AUTH_MESSAGE)?;
    let body = json_object(&response.body)?;
    // A 2xx body carrying none of the usage fields we read (e.g. an `error`
    // object) is an invalid response, not a valid "no usage" snapshot.
    if !["five_hour", "seven_day", "limits"]
        .iter()
        .any(|key| body.contains_key(*key))
    {
        return Err(invalid_response());
    }
    let now = now_ms();
    Ok(Snapshot { metrics: map_usage(&body, now), updated_at_ms: now, warning: None })
}

fn credentials_path() -> RefreshResult<PathBuf> {
    if let Some(dir) = env_override_dir("CLAUDE_CONFIG_DIR", env_value("CLAUDE_CONFIG_DIR").as_deref())? {
        return Ok(dir.join(".credentials.json"));
    }
    Ok(home_dir()?.join(".claude").join(".credentials.json"))
}

fn load_access_token() -> RefreshResult<String> {
    let path = credentials_path()?;
    let body = read_auth_file(&path, CREDENTIALS_UNREADABLE)?.ok_or_else(|| {
        setup("No Claude credentials found. Run `claude` and sign in, then refresh.")
    })?;
    let root: Value = serde_json::from_slice(&body)
        .map_err(|_| auth("Claude credential data is invalid. Run `claude` and sign in again, then refresh."))?;
    root.get("claudeAiOauth")
        .and_then(|oauth| oauth.get("accessToken"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|token| !token.is_empty())
        .map(String::from)
        .ok_or_else(|| {
            auth("Claude sign-in is incomplete. Run `claude` and sign in again, then refresh.")
        })
}

fn map_usage(body: &Map<String, Value>, now: u64) -> Vec<Metric> {
    let mut metrics = Vec::new();
    for (key, id, label, on_demand) in [
        ("five_hour", "claude.session", "Session", false),
        ("seven_day", "claude.weekly", "Weekly", false),
    ] {
        if let Some(metric) = usage_window(body.get(key), id, label, on_demand, now) {
            metrics.push(metric);
        }
    }
    if let Some(metric) = fable_weekly(body.get("limits"), now) {
        metrics.push(metric);
    }
    metrics
}

fn usage_window(
    value: Option<&Value>,
    id: &'static str,
    label: &'static str,
    on_demand: bool,
    now: u64,
) -> Option<Metric> {
    let window = obj(value)?;
    let used = percent_bounded(window.get("utilization"))?;
    Some(Metric {
        id,
        label,
        value: used,
        limit: Some(100.0),
        unit: Unit::Percent,
        reset_at_ms: reset_at(window.get("resets_at"), now),
        on_demand,
    })
}

/// The Fable-scoped weekly limit from `limits`: `kind: "weekly_scoped"` whose
/// `scope.model.display_name` is "Fable" (case-insensitive), `percent` 0–100.
fn fable_weekly(limits: Option<&Value>, now: u64) -> Option<Metric> {
    for entry in arr(limits)? {
        let entry = match obj(Some(entry)) {
            Some(entry) => entry,
            None => continue,
        };
        if string(entry.get("kind")) != Some("weekly_scoped") {
            continue;
        }
        let display_name = entry
            .get("scope")
            .and_then(|scope| obj(Some(scope)))
            .and_then(|scope| scope.get("model"))
            .and_then(|model| obj(Some(model)))
            .and_then(|model| model.get("display_name"))
            .and_then(|name| string(Some(name)));
        if !display_name.is_some_and(|name| name.eq_ignore_ascii_case("fable")) {
            continue;
        }
        // A malformed first Fable entry must not hide a later readable one.
        let Some(used) = percent_bounded(entry.get("percent")) else { continue };
        return Some(Metric {
            id: "claude.fable",
            label: "Fable",
            value: used,
            limit: Some(100.0),
            unit: Unit::Percent,
            reset_at_ms: reset_at(entry.get("resets_at"), now),
            on_demand: false,
        });
    }
    None
}

/// `resets_at` as RFC3339 text or an epoch number (seconds when small,
/// milliseconds when large), then the shared future-instant sanity check.
fn reset_at(value: Option<&Value>, now: u64) -> Option<u64> {
    let ms: i64 = match value? {
        Value::String(text) if !text.trim().is_empty() => rfc3339_ms(text)?,
        other => {
            let number = number(Some(other))?;
            let scaled = if number.abs() < 1e10 { number * 1000.0 } else { number };
            scaled as i64
        }
    };
    future_ms(ms, now, MAX_RESET_HORIZON_MS)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn future_rfc3339(now: u64) -> String {
        let ms = chrono::DateTime::from_timestamp_millis((now + 3_600_000) as i64).unwrap();
        ms.to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
    }

    #[test]
    fn maps_session_weekly_and_fable() {
        let now = now_ms();
        let resets = future_rfc3339(now);
        let body: Map<String, Value> = serde_json::from_str::<Value>(&format!(
            r#"{{
                "five_hour": {{"utilization": 37, "resets_at": "{resets}"}},
                "seven_day": {{"utilization": "62"}},
                "limits": [
                    {{"kind": "weekly_scoped", "scope": {{"model": {{"display_name": "FABLE"}}}},
                      "percent": 9, "resets_at": "{resets}"}},
                    {{"kind": "weekly_scoped", "scope": {{"model": {{"display_name": "Other"}}}},
                      "percent": 50}}
                ]
            }}"#
        ))
        .unwrap()
        .as_object()
        .unwrap()
        .clone();

        let metrics = map_usage(&body, now);
        assert_eq!(metrics.len(), 3);
        assert_eq!(metrics[0].id, "claude.session");
        assert_eq!(metrics[0].value, 37.0);
        assert_eq!(metrics[0].reset_at_ms, Some(now + 3_600_000));
        assert_eq!(metrics[1].id, "claude.weekly");
        assert_eq!(metrics[1].value, 62.0);
        assert_eq!(metrics[2].id, "claude.fable");
        assert!(!metrics[2].on_demand);
    }

    #[test]
    fn malformed_fable_entry_does_not_hide_a_later_good_one() {
        let now = now_ms();
        let body: Map<String, Value> = serde_json::from_str::<Value>(
            r#"{
                "five_hour": {"utilization": 10},
                "limits": [
                    {"kind": "weekly_scoped", "scope": {"model": {"display_name": "Fable"}},
                     "percent": "NaN"},
                    {"kind": "weekly_scoped", "scope": {"model": {"display_name": "Other"}},
                     "percent": 77},
                    {"kind": "weekly_scoped", "scope": {"model": {"display_name": "fable"}},
                     "percent": 21}
                ]
            }"#,
        )
        .unwrap()
        .as_object()
        .unwrap()
        .clone();
        let metrics = map_usage(&body, now);
        let fable = metrics.iter().find(|m| m.id == "claude.fable").unwrap();
        assert_eq!(fable.value, 21.0);
    }

    #[test]
    fn out_of_range_and_missing_windows_are_skipped_not_zeroed() {
        let body: Map<String, Value> = serde_json::from_str::<Value>(
            r#"{
                "five_hour": {"utilization": 140},
                "seven_day": {"utilization": 0}
            }"#,
        )
        .unwrap()
        .as_object()
        .unwrap()
        .clone();
        let metrics = map_usage(&body, now_ms());
        assert_eq!(metrics.len(), 1);
        assert_eq!(metrics[0].id, "claude.weekly");
        assert_eq!(metrics[0].value, 0.0, "a real 0% is reported, not dropped");
    }

    #[test]
    fn nonfinite_and_malformed_payloads_yield_no_metrics() {
        let body: Map<String, Value> = serde_json::from_str::<Value>(
            r#"{"five_hour": {"utilization": "NaN"}, "seven_day": "junk"}"#,
        )
        .unwrap()
        .as_object()
        .unwrap()
        .clone();
        assert!(map_usage(&body, now_ms()).is_empty());
    }

    #[test]
    fn stale_reset_instants_are_dropped() {
        let now = now_ms();
        let body: Map<String, Value> = serde_json::from_str::<Value>(
            r#"{"five_hour": {"utilization": 10, "resets_at": "2001-01-01T00:00:00Z"}}"#,
        )
        .unwrap()
        .as_object()
        .unwrap()
        .clone();
        let metrics = map_usage(&body, now);
        assert_eq!(metrics.len(), 1);
        assert_eq!(metrics[0].reset_at_ms, None);
    }
}
