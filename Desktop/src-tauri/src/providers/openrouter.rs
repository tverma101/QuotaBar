//! OpenRouter live usage: `OPENROUTER_API_KEY`/`OPENROUTER_KEY` →
//! `GET /api/v1/credits` + `GET /api/v1/key`. The endpoints are fetched and
//! mapped independently — OpenRouter gates them per key type, so one failing
//! must not blank the other's rows; a partial result carries a warning.

use super::*;

const CREDITS_URL: &str = "https://openrouter.ai/api/v1/credits";
const KEY_URL: &str = "https://openrouter.ai/api/v1/key";
const MISSING_KEY_MESSAGE: &str = "No OpenRouter API key. Set OPENROUTER_API_KEY, then refresh.";
const INVALID_KEY_MESSAGE: &str =
    "OpenRouter API key invalid. Check your key at openrouter.ai/keys, then refresh.";
const INVALID_DATA_MESSAGE: &str = "OpenRouter usage data unavailable. Try again later.";

pub(super) fn refresh() -> RefreshResult<Snapshot> {
    let key = api_key(&["OPENROUTER_API_KEY", "OPENROUTER_KEY"], MISSING_KEY_MESSAGE)?;
    let client = http_client()?;
    let credits = load_endpoint(&client, CREDITS_URL, &key);
    let key_meta = load_endpoint(&client, KEY_URL, &key);
    combine(credits, key_meta)
}

/// One endpoint's outcome, kept tri-state so "key rejected" (401/403) stays
/// distinguishable from a generic fetch failure when deciding whether the key
/// itself is the problem.
enum Endpoint {
    Success(Map<String, Value>),
    AuthFailure,
    Failed(RefreshError),
}

fn load_endpoint(
    client: &reqwest::blocking::Client,
    url: &str,
    key: &str,
) -> Endpoint {
    let response = match get_json(client, url, key, &[]) {
        Ok(response) => response,
        Err(error) => return Endpoint::Failed(error),
    };
    match response.status {
        401 | 403 => Endpoint::AuthFailure,
        200..=299 => match json_object(&response.body)
            .ok()
            .and_then(|root| obj(root.get("data")).cloned())
        {
            Some(data) => Endpoint::Success(data),
            None => Endpoint::Failed(RefreshError::new(ErrorKind::Invalid, INVALID_DATA_MESSAGE)),
        },
        429 => Endpoint::Failed(rate_limited()),
        status => Endpoint::Failed(http_failed(status)),
    }
}

/// Map whatever came back. Any rows → a snapshot (with a warning when one side
/// failed); no rows → the invalid-key error only when *both* sides rejected
/// the credential, otherwise the first real failure.
fn combine(credits: Endpoint, key_meta: Endpoint) -> RefreshResult<Snapshot> {
    let mut metrics = Vec::new();
    if let Endpoint::Success(data) = &credits {
        metrics.extend(credits_lines(data));
    }
    if let Endpoint::Success(data) = &key_meta {
        metrics.extend(key_lines(data));
    }

    if !metrics.is_empty() {
        let partial = !matches!(credits, Endpoint::Success(_))
            || !matches!(key_meta, Endpoint::Success(_));
        return Ok(Snapshot {
            metrics,
            updated_at_ms: now_ms(),
            warning: partial.then(|| {
                "Some OpenRouter data is unavailable — part of the request failed. Refresh to try again."
                    .to_string()
            }),
        });
    }

    if matches!(credits, Endpoint::AuthFailure) && matches!(key_meta, Endpoint::AuthFailure) {
        return Err(auth(INVALID_KEY_MESSAGE));
    }
    for endpoint in [credits, key_meta] {
        if let Endpoint::Failed(error) = endpoint {
            return Err(error);
        }
    }
    // The remaining no-row outcomes — a lone auth rejection beside an empty
    // success, or two 2xx payloads with nothing mappable — are invalid data,
    // not a bad key.
    Err(RefreshError::new(ErrorKind::Invalid, INVALID_DATA_MESSAGE))
}

/// `/credits`: spend against lifetime purchased credits, plus the remaining
/// balance. Both totals are required — a missing purchased-total field is not
/// a measured $0 balance.
fn credits_lines(data: &Map<String, Value>) -> Vec<Metric> {
    let (Some(total_usage), Some(total_credits)) =
        (number(data.get("total_usage")), number(data.get("total_credits")))
    else {
        return Vec::new();
    };
    let used = total_usage.max(0.0);
    let cap = total_credits.max(0.0);

    let mut metrics = Vec::new();
    // Only a positive ceiling makes a meter meaningful; free/never-topped-up
    // accounts still get the Balance row.
    if cap > 0.0 {
        metrics.push(Metric {
            id: "openrouter.credits",
            label: "Credits",
            value: used,
            limit: Some(cap),
            unit: Unit::Usd,
            reset_at_ms: None,
            on_demand: false,
        });
    }
    metrics.push(Metric {
        id: "openrouter.balance",
        label: "Balance",
        value: (cap - used).max(0.0),
        limit: None,
        unit: Unit::Usd,
        reset_at_ms: None,
        on_demand: false,
    });
    metrics
}

/// `/key`: period spend (real zeros are measured zeros) and the optional
/// per-key cap. `limit` without `limit_remaining` can't be measured, so the
/// meter is omitted rather than invented.
fn key_lines(data: &Map<String, Value>) -> Vec<Metric> {
    let mut metrics = Vec::new();
    for (key, id, label) in [
        ("usage_daily", "openrouter.today", "Today"),
        ("usage_weekly", "openrouter.week", "This Week"),
        ("usage_monthly", "openrouter.month", "This Month"),
    ] {
        if let Some(amount) = number(data.get(key)) {
            metrics.push(Metric {
                id,
                label,
                value: amount.max(0.0),
                limit: None,
                unit: Unit::Usd,
                reset_at_ms: None,
                on_demand: true,
            });
        }
    }

    if let Some(limit) = number(data.get("limit")).filter(|l| *l > 0.0) {
        if let Some(remaining) = number(data.get("limit_remaining")) {
            metrics.push(Metric {
                id: "openrouter.keyLimit",
                label: "Key Limit",
                value: (limit - remaining.max(0.0)).max(0.0),
                limit: Some(limit),
                unit: Unit::Usd,
                reset_at_ms: None,
                on_demand: true,
            });
        }
    }
    metrics
}

#[cfg(test)]
mod tests {
    use super::*;

    fn data(json: &str) -> Map<String, Value> {
        serde_json::from_str::<Value>(json)
            .unwrap()
            .as_object()
            .unwrap()
            .clone()
    }

    #[test]
    fn credits_requires_both_totals() {
        assert!(credits_lines(&data(r#"{"total_usage": 10}"#)).is_empty());
        let metrics = credits_lines(&data(r#"{"total_usage": 30, "total_credits": 100}"#));
        assert_eq!(metrics.len(), 2);
        assert_eq!(metrics[0].id, "openrouter.credits");
        assert_eq!(metrics[0].value, 30.0);
        assert_eq!(metrics[0].limit, Some(100.0));
        assert_eq!(metrics[1].id, "openrouter.balance");
        assert_eq!(metrics[1].value, 70.0);
    }

    #[test]
    fn zero_cap_skips_the_meter_but_keeps_balance() {
        let metrics = credits_lines(&data(r#"{"total_usage": 0, "total_credits": 0}"#));
        assert_eq!(metrics.len(), 1);
        assert_eq!(metrics[0].id, "openrouter.balance");
        assert_eq!(metrics[0].value, 0.0);
    }

    #[test]
    fn key_limit_without_remaining_is_omitted_not_invented() {
        let metrics = key_lines(&data(r#"{"limit": 50, "usage_daily": 1.5}"#));
        assert_eq!(metrics.len(), 1);
        assert_eq!(metrics[0].id, "openrouter.today");
        assert_eq!(metrics[0].value, 1.5);
        assert!(metrics.iter().all(|m| m.on_demand));
    }

    #[test]
    fn partial_success_yields_rows_and_a_warning() {
        let credits = Endpoint::Success(data(r#"{"total_usage": 30, "total_credits": 100}"#));
        let key_meta = Endpoint::Failed(connection_failed());
        let snapshot = combine(credits, key_meta).unwrap();
        assert_eq!(snapshot.metrics.len(), 2);
        assert!(snapshot.warning.is_some());
    }

    #[test]
    fn both_auth_failures_mean_invalid_key() {
        let err = combine(Endpoint::AuthFailure, Endpoint::AuthFailure).unwrap_err();
        assert_eq!(err.kind, ErrorKind::Auth);
    }

    #[test]
    fn one_gated_endpoint_is_not_an_invalid_key() {
        // /credits forbidden but /key fine → rows render with a warning, no auth error.
        let key_meta = Endpoint::Success(data(r#"{"usage_daily": 2.0}"#));
        let snapshot = combine(Endpoint::AuthFailure, key_meta).unwrap();
        assert_eq!(snapshot.metrics.len(), 1);
        assert!(snapshot.warning.is_some());
    }

    #[test]
    fn two_empty_successes_are_invalid_data() {
        let err = combine(
            Endpoint::Success(data(r#"{"unrelated": true}"#)),
            Endpoint::Success(data(r#"{"also": "empty"}"#)),
        )
        .unwrap_err();
        assert_eq!(err.kind, ErrorKind::Invalid);
    }
}
