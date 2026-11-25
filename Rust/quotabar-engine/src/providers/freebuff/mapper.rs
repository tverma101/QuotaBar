//! Freebuff session endpoint mapping (`Providers/Freebuff/FreebuffUsageMapper`): legacy session
//! windows, the current hours meter, monthly spend, and active-session expiry metadata.

use crate::model::{ActiveSession, MetricKind, MetricLine, MetricValue, ProgressFormat};
use crate::time::parse_iso8601;
use serde_json::{Map, Value};

pub const FIVE_DAY_MS: i64 = 5 * 86_400_000;
pub const FREE_BUCKS_PER_HOUR: f64 = 5.0;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct MappedUsage {
    pub plan: Option<String>,
    pub lines: Vec<MetricLine>,
    pub warning: Option<String>,
    pub active_sessions: Vec<ActiveSession>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MapError;

pub fn map(body: &[u8], status: u16) -> Result<MappedUsage, MapError> {
    let root = if status == 404 {
        let mut object = Map::new();
        object.insert("status".into(), Value::String("none".into()));
        Value::Object(object)
    } else {
        serde_json::from_slice::<Value>(body).map_err(|_| MapError)?
    };
    let object = root.as_object().ok_or(MapError)?;
    let status = object
        .get("status")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or(MapError)?;
    let subscription = object.get("subscription").and_then(Value::as_object);
    let subscription_usage = subscription
        .and_then(|subscription| subscription.get("usage"))
        .and_then(Value::as_object);
    let free_windows = object.get("freeWindows").and_then(Value::as_object);
    let freebucks = object.get("freebucks");
    let freebucks_object = freebucks.and_then(Value::as_object);
    let mut lines = Vec::new();
    let mut warning = None;
    if let Some(raw) = freebucks {
        if !raw.is_null() && freebucks_object.is_none() {
            return Err(MapError);
        }
        if raw.is_null() {
            warning = Some(
                "Freebuff couldn't refresh its hours balances. Refresh again to get current hours."
                    .to_string(),
            );
        }
    }

    if object.contains_key("freebucks") {
        // Legacy windows are still sent for compatibility; the hours meter supersedes them.
    } else if let Some(usage) = subscription_usage {
        append_progress(
            "Daily",
            usage.get("dayUsed"),
            usage.get("dayLimit"),
            ProgressFormat::Count("sessions".into()),
            usage.get("dayResetAt"),
            Some(86_400_000),
            None,
            &mut lines,
        );
        append_progress(
            "5-Day",
            usage.get("fiveDayUsed"),
            usage.get("fiveDayLimit"),
            ProgressFormat::Count("sessions".into()),
            None,
            Some(FIVE_DAY_MS),
            None,
            &mut lines,
        );
        append_progress(
            "Monthly",
            usage.get("monthUsed"),
            usage.get("monthLimit"),
            ProgressFormat::Count("sessions".into()),
            usage.get("periodEndsAt"),
            None,
            None,
            &mut lines,
        );
        append_progress(
            "Premium Sessions",
            usage.get("dayPremiumUsed"),
            usage.get("dayPremiumLimit"),
            ProgressFormat::Count("sessions".into()),
            usage.get("dayResetAt"),
            Some(86_400_000),
            Some("Luna / DeepSeek V4 Pro"),
            &mut lines,
        );
        append_progress(
            "Free Premium Sessions",
            usage.get("freeDayUsed"),
            usage.get("freeDayLimit"),
            ProgressFormat::Count("sessions".into()),
            usage.get("dayResetAt"),
            Some(86_400_000),
            None,
            &mut lines,
        );
    } else if let Some(windows) = free_windows {
        append_progress(
            "Daily",
            windows.get("dayUsed"),
            windows.get("dayLimit"),
            ProgressFormat::Count("sessions".into()),
            windows.get("dayResetAt"),
            Some(86_400_000),
            None,
            &mut lines,
        );
        append_progress(
            "Weekly",
            windows.get("weekUsed"),
            windows.get("weekLimit"),
            ProgressFormat::Count("sessions".into()),
            None,
            Some(604_800_000),
            None,
            &mut lines,
        );
        append_progress(
            "Monthly",
            windows.get("monthUsed"),
            windows.get("monthLimit"),
            ProgressFormat::Count("sessions".into()),
            windows.get("monthResetAt"),
            None,
            None,
            &mut lines,
        );
    } else if let Some(pool) =
        most_used_rate_limit(object.get("rateLimitsByModel").and_then(Value::as_object))
    {
        lines.push(MetricLine::Progress {
            label: "Session Pool".into(),
            used: pool.recent_count,
            limit: pool.limit,
            format: ProgressFormat::Count("sessions".into()),
            resets_at: pool.reset_at,
            period_duration_ms: pool.period_duration_ms,
            color_hex: None,
            detail: pool
                .pool_label
                .map(|label| format!("Most used pool: {label}")),
        });
    }

    if let Some(daily) = freebucks_object
        .and_then(|freebucks| freebucks.get("daily"))
        .and_then(Value::as_object)
    {
        let Some(spent) = nonnegative(daily.get("spent")) else {
            return Err(MapError);
        };
        let Some(limit) = nonnegative(daily.get("limit")) else {
            return Err(MapError);
        };
        if daily
            .get("resetAt")
            .is_some_and(|value| date(Some(value)).is_none())
        {
            return Err(MapError);
        }
        append_progress(
            "Daily Hours",
            Some(&Value::from(spent / FREE_BUCKS_PER_HOUR)),
            Some(&Value::from(limit / FREE_BUCKS_PER_HOUR)),
            ProgressFormat::Count("hours".into()),
            daily.get("resetAt"),
            Some(86_400_000),
            None,
            &mut lines,
        );
    } else if freebucks_object.is_some() {
        return Err(MapError);
    }

    if let Some(freebucks) = freebucks_object {
        let wallet = if let Some(raw) = freebucks.get("wallet") {
            let Some(wallet) = raw.as_object() else {
                return Err(MapError);
            };
            nonnegative(wallet.get("balance")).ok_or(MapError)?
        } else {
            let Some(total) = nonnegative(freebucks.get("balance")) else {
                return Err(MapError);
            };
            let Some(daily) = freebucks.get("daily").and_then(Value::as_object) else {
                return Err(MapError);
            };
            let Some(spent) = nonnegative(daily.get("spent")) else {
                return Err(MapError);
            };
            let Some(limit) = nonnegative(daily.get("limit")) else {
                return Err(MapError);
            };
            let remaining =
                nonnegative(daily.get("remaining")).unwrap_or_else(|| (limit - spent).max(0.0));
            if total + 1e-9 < remaining {
                return Err(MapError);
            }
            (total - remaining).max(0.0)
        };
        lines.push(MetricLine::values(
            "Hours Balance",
            vec![MetricValue::new(
                (wallet / FREE_BUCKS_PER_HOUR + 1e-9).floor(),
                MetricKind::Count,
            )
            .with_label("hours")],
        ));
    } else {
        lines.push(MetricLine::values("Hours Balance", Vec::new()));
    }

    append_monthly_spend(subscription_usage, freebucks_object, &mut lines);
    let has_value = lines.iter().any(|line| {
        if let MetricLine::Values { values, .. } = line {
            !values.is_empty()
        } else {
            true
        }
    });
    if !has_value {
        lines.push(MetricLine::no_usage_data());
    }
    if !lines.iter().any(|line| line.label() == "Monthly Spend") {
        lines.push(MetricLine::values("Monthly Spend", Vec::new()));
    }

    let sessions = active_sessions(object)?;
    lines.push(MetricLine::Values {
        label: "Active Sessions".into(),
        values: Vec::new(),
        color_hex: None,
        expiries_at: sessions.iter().map(|session| session.expires_at).collect(),
        unknown_models: Vec::new(),
        model_breakdown: None,
    });

    let tier = subscription
        .and_then(|subscription| subscription.get("tierId"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty());
    let access_tier = object
        .get("accessTier")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(title_case);
    Ok(MappedUsage {
        plan: tier.map(str::to_string).or(access_tier),
        lines,
        warning,
        active_sessions: sessions,
    })
    .map(|mapped| {
        let _ = status;
        mapped
    })
}

fn title_case(value: &str) -> String {
    let mut chars = value.chars();
    match chars.next() {
        Some(first) => format!("{}{}", first.to_uppercase(), chars.as_str().to_lowercase()),
        None => String::new(),
    }
}

pub fn active_sessions(object: &Map<String, Value>) -> Result<Vec<ActiveSession>, MapError> {
    let mut sessions: Vec<ActiveSession> = Vec::new();
    if object.get("status").and_then(Value::as_str) == Some("active") {
        let Some(expires_at) = date(object.get("expiresAt")) else {
            return Err(MapError);
        };
        let id = object
            .get("instanceId")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .unwrap_or("single");
        upsert_session(
            &mut sessions,
            ActiveSession {
                instance_id: id.to_string(),
                expires_at,
                model: object
                    .get("model")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .map(str::to_string),
                thread_id: None,
                chat_title: None,
                project_path: None,
            },
        );
    }
    match object.get("desktopPurchases") {
        None | Some(Value::Null) => {}
        Some(Value::Array(purchases)) => {
            for purchase in purchases {
                let Some(purchase) = purchase.as_object() else {
                    return Err(MapError);
                };
                let Some(holder) = purchase
                    .get("holderInstanceId")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                else {
                    continue;
                };
                let Some(expires_at) = date(purchase.get("expiresAt")) else {
                    return Err(MapError);
                };
                upsert_session(
                    &mut sessions,
                    ActiveSession {
                        instance_id: holder.to_string(),
                        expires_at,
                        model: purchase
                            .get("model")
                            .and_then(Value::as_str)
                            .map(str::trim)
                            .filter(|value| !value.is_empty())
                            .map(str::to_string),
                        thread_id: None,
                        chat_title: None,
                        project_path: None,
                    },
                );
            }
        }
        Some(_) => return Err(MapError),
    }
    sessions.sort_by(|left, right| {
        left.expires_at
            .partial_cmp(&right.expires_at)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    Ok(sessions)
}

fn upsert_session(sessions: &mut Vec<ActiveSession>, session: ActiveSession) {
    if let Some(existing) = sessions
        .iter_mut()
        .find(|existing| existing.instance_id == session.instance_id)
    {
        *existing = session;
    } else {
        sessions.push(session);
    }
}

struct RateLimitPool {
    key: String,
    pool_label: Option<String>,
    limit: f64,
    recent_count: f64,
    reset_at: Option<f64>,
    period_duration_ms: Option<i64>,
}

fn most_used_rate_limit(models: Option<&Map<String, Value>>) -> Option<RateLimitPool> {
    let models = models?;
    let mut pools: Vec<RateLimitPool> = Vec::new();
    for (model, raw) in models {
        let Some(value) = raw.as_object() else {
            continue;
        };
        let Some(limit) = value
            .get("limit")
            .and_then(Value::as_f64)
            .filter(|value| *value > 0.0)
        else {
            continue;
        };
        let Some(recent_count) = value
            .get("recentCount")
            .and_then(Value::as_f64)
            .filter(|value| *value >= 0.0)
        else {
            continue;
        };
        let key = value
            .get("pool")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
            .unwrap_or_else(|| format!("model:{model}"));
        let candidate = RateLimitPool {
            key: key.clone(),
            pool_label: value
                .get("poolLabel")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(str::to_string),
            limit,
            recent_count,
            reset_at: date(value.get("resetAt")),
            period_duration_ms: period_duration(value.get("period").and_then(Value::as_str)),
        };
        if let Some(existing) = pools.iter_mut().find(|existing| existing.key == key) {
            if candidate.recent_count / candidate.limit > existing.recent_count / existing.limit {
                *existing = candidate;
            }
        } else {
            pools.push(candidate);
        }
    }
    pools.sort_by(|left, right| {
        let left_ratio = left.recent_count / left.limit;
        let right_ratio = right.recent_count / right.limit;
        right_ratio
            .partial_cmp(&left_ratio)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| left.key.cmp(&right.key))
    });
    pools.into_iter().next()
}

fn period_duration(value: Option<&str>) -> Option<i64> {
    match value {
        Some("pacific_day") => Some(86_400_000),
        Some("pacific_week") => Some(604_800_000),
        Some("pacific_month") => Some(30 * 86_400_000),
        _ => None,
    }
}

fn append_monthly_spend(
    subscription_usage: Option<&Map<String, Value>>,
    freebucks: Option<&Map<String, Value>>,
    lines: &mut Vec<MetricLine>,
) {
    let monthly = freebucks
        .and_then(|freebucks| freebucks.get("monthly"))
        .and_then(Value::as_object);
    let spent = number(
        monthly
            .and_then(|monthly| monthly.get("spentUsd"))
            .or_else(|| subscription_usage.and_then(|usage| usage.get("monthSpendUsd"))),
    );
    let limit = number(
        monthly
            .and_then(|monthly| monthly.get("limitUsd"))
            .or_else(|| subscription_usage.and_then(|usage| usage.get("monthSpendLimitUsd"))),
    );
    let Some(spent) = spent.filter(|value| *value >= 0.0) else {
        return;
    };
    let reset = date(
        monthly
            .and_then(|monthly| monthly.get("resetAt"))
            .or_else(|| subscription_usage.and_then(|usage| usage.get("periodEndsAt"))),
    );
    if let Some(limit) = limit.filter(|value| *value > 0.0) {
        lines.push(MetricLine::Progress {
            label: "Monthly Spend".into(),
            used: spent,
            limit,
            format: ProgressFormat::Dollars,
            resets_at: reset,
            period_duration_ms: None,
            color_hex: None,
            detail: None,
        });
    } else {
        lines.push(MetricLine::values(
            "Monthly Spend",
            vec![MetricValue::new(spent, MetricKind::Dollars)],
        ));
    }
}

fn append_progress(
    label: &str,
    used: Option<&Value>,
    limit: Option<&Value>,
    format: ProgressFormat,
    reset: Option<&Value>,
    period_ms: Option<i64>,
    detail: Option<&str>,
    lines: &mut Vec<MetricLine>,
) {
    let Some(used) = number(used).filter(|value| *value >= 0.0) else {
        return;
    };
    let Some(limit) = number(limit).filter(|value| *value >= 0.0) else {
        return;
    };
    lines.push(MetricLine::Progress {
        label: label.to_string(),
        used,
        limit,
        format,
        resets_at: date(reset),
        period_duration_ms: period_ms,
        color_hex: None,
        detail: detail.map(str::to_string),
    });
}

fn number(value: Option<&Value>) -> Option<f64> {
    let value = value?;
    if value.is_boolean() {
        return None;
    }
    value.as_f64().filter(|value| value.is_finite())
}

fn nonnegative(value: Option<&Value>) -> Option<f64> {
    number(value).filter(|value| *value >= 0.0)
}

fn date(value: Option<&Value>) -> Option<f64> {
    value
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .and_then(parse_iso8601)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn current_hours_meter_supersedes_legacy_windows() {
        let body = br#"{
          "status":"active","expiresAt":"2026-11-24T12:00:00Z","instanceId":"i1",
          "subscription":{"tierId":"pro","usage":{"dayUsed":9,"dayLimit":9}},
          "freebucks":{"daily":{"spent":5,"limit":20,"resetAt":"2026-11-25T00:00:00Z"},
                       "wallet":{"balance":35},"monthly":{"spentUsd":2.5,"limitUsd":10}},
          "desktopPurchases":[{"holderInstanceId":"i2","expiresAt":"2026-11-24T11:00:00Z","model":"m"}]
        }"#;
        let mapped = map(body, 200).unwrap();
        assert_eq!(mapped.plan.as_deref(), Some("pro"));
        assert!(mapped
            .lines
            .iter()
            .any(|line| line.label() == "Daily Hours"));
        assert!(!mapped.lines.iter().any(|line| line.label() == "Daily"));
        assert_eq!(mapped.active_sessions.len(), 2);
        assert_eq!(mapped.active_sessions[0].instance_id, "i2");
        assert!(mapped.lines.iter().any(|line| matches!(line, MetricLine::Values { label, values, .. } if label == "Hours Balance" && values[0].number == 7.0)));
    }

    #[test]
    fn null_freebucks_warns_and_rejects_malformed_shapes() {
        let mapped = map(br#"{"status":"none","freebucks":null}"#, 200).unwrap();
        assert!(mapped.warning.is_some());
        assert!(map(br#"{"status":""}"#, 200).is_err());
        assert!(map(
            br#"{"status":"none","freebucks":{"daily":{"spent":"x"}}}"#,
            200
        )
        .is_err());
        assert!(map(br#"{"status":"active"}"#, 200).is_err());
        assert_eq!(map(b"{}", 404).unwrap().plan, None);
    }

    #[test]
    fn rate_limit_pools_group_by_pool_and_choose_most_used() {
        let body = br#"{"status":"none","rateLimitsByModel":{
          "a":{"limit":10,"recentCount":5,"pool":"shared","poolLabel":"Shared"},
          "b":{"limit":10,"recentCount":9,"pool":"shared"}
        }}"#;
        let mapped = map(body, 200).unwrap();
        let pool = mapped
            .lines
            .iter()
            .find(|line| line.label() == "Session Pool")
            .unwrap();
        assert!(
            matches!(pool, MetricLine::Progress { used, limit, .. } if *used == 9.0 && *limit == 10.0)
        );
    }
}
