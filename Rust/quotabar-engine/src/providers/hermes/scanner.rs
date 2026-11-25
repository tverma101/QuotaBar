//! Hermes Agent local SQLite database scanner (`~/.hermes/state.db` or `$HERMES_HOME/state.db`).

use super::mapper::{
    HermesModelUsage, HermesPeriod, HermesPeriodUsage, HermesTokenCounts, HermesUsageScan,
};
use crate::accounting::{DayZone, UsageHistoryWindow};
use crate::context::CancelToken;
use crate::host;
use crate::model::{DailyUsageEntry, DailyUsageSeries, Timestamp};
use crate::paths;
use crate::scan::incremental::FUTURE_TOLERANCE_SECONDS;
use crate::sqlite::{self, SourceSignature};
use chrono::{Datelike, Days, FixedOffset, Local, LocalResult, NaiveDate, TimeZone, Utc};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HermesScanError {
    DatabaseUnreadable(String),
    Cancelled,
}

struct CachedScan {
    path: PathBuf,
    signature: SourceSignature,
    scanned_at: Timestamp,
    valid_until: Timestamp,
    result: HermesUsageScan,
}

pub struct HermesUsageScanner {
    fixed_path: Option<PathBuf>,
    zone: DayZone,
    cache: Mutex<Option<CachedScan>>,
}

impl HermesUsageScanner {
    pub fn live() -> Self {
        HermesUsageScanner {
            fixed_path: None,
            zone: DayZone::Local,
            cache: Mutex::new(None),
        }
    }

    pub fn at(path: PathBuf, zone: DayZone) -> Self {
        HermesUsageScanner {
            fixed_path: Some(path),
            zone,
            cache: Mutex::new(None),
        }
    }

    pub fn unload_caches(&self) {
        *self.cache.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }

    pub fn effective_path(&self) -> PathBuf {
        self.fixed_path
            .clone()
            .unwrap_or_else(default_state_db_path)
    }

    pub fn scan(
        &self,
        now: Timestamp,
        cancel: &CancelToken,
    ) -> Result<Option<HermesUsageScan>, HermesScanError> {
        if cancel.is_cancelled() {
            return Err(HermesScanError::Cancelled);
        }
        let path = self.effective_path();
        if !path.exists() {
            return Ok(None);
        }
        let signature = sqlite::source_signature(&path);
        {
            let guard = self.cache.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(cached) = guard.as_ref() {
                if cached.path == path
                    && cached.signature == signature
                    && now >= cached.scanned_at
                    && now < cached.valid_until
                {
                    return Ok(Some(cached.result.clone()));
                }
            }
        }

        let max_ts = now + FUTURE_TOLERANCE_SECONDS;
        let has_model_table = query(&path, model_table_probe_sql())?.is_some();
        if cancel.is_cancelled() {
            return Err(HermesScanError::Cancelled);
        }

        let starts = period_starts(now, self.zone);
        let mut periods = Vec::with_capacity(3);
        let mut model_usage_by_period = BTreeMap::new();
        for (period, start) in starts {
            if cancel.is_cancelled() {
                return Err(HermesScanError::Cancelled);
            }
            let sum_json = query(&path, &period_sql(start, Some(max_ts)))?.ok_or_else(|| {
                HermesScanError::DatabaseUnreadable("period query returned no result".into())
            })?;
            let parsed_period = parse_period(&sum_json).ok_or_else(|| {
                HermesScanError::DatabaseUnreadable(
                    "period query returned malformed accounting data".into(),
                )
            })?;
            periods.push(HermesPeriodUsage {
                period,
                counts: parsed_period.counts,
                cost_usd: parsed_period.cost_usd,
                api_call_count: parsed_period.api_call_count,
                is_partial: parsed_period.is_partial,
            });
            if cancel.is_cancelled() {
                return Err(HermesScanError::Cancelled);
            }
            let models_json = query(&path, &models_sql(start, has_model_table, Some(max_ts)))?
                .ok_or_else(|| {
                    HermesScanError::DatabaseUnreadable("model query returned no result".into())
                })?;
            let parsed_models = parse_models(&models_json).ok_or_else(|| {
                HermesScanError::DatabaseUnreadable(
                    "model query returned malformed accounting data".into(),
                )
            })?;
            model_usage_by_period.insert(period, parsed_models);
        }

        let lifetime_days = UsageHistoryWindow::lifetime_days(now, self.zone);
        let today_date = self
            .zone
            .local_date(now)
            .unwrap_or_else(|| NaiveDate::from_ymd_opt(2026, 1, 1).unwrap());
        let cutoff_date = today_date
            .checked_sub_days(Days::new((lifetime_days.saturating_sub(1)) as u64))
            .unwrap_or(today_date);
        let cutoff = start_of_day(cutoff_date, self.zone);

        if cancel.is_cancelled() {
            return Err(HermesScanError::Cancelled);
        }
        let daily_json = query(&path, &daily_sql(cutoff, Some(max_ts)))?.ok_or_else(|| {
            HermesScanError::DatabaseUnreadable("daily query returned no result".into())
        })?;
        let (series, partial_days) = parse_daily(&daily_json).ok_or_else(|| {
            HermesScanError::DatabaseUnreadable(
                "daily query returned malformed accounting data".into(),
            )
        })?;

        let result = HermesUsageScan {
            periods,
            daily: series,
            model_usage_by_period,
            partial_days,
        };
        if let Some(valid_until) = next_midnight(today_date, self.zone) {
            *self.cache.lock().unwrap_or_else(|e| e.into_inner()) = Some(CachedScan {
                path,
                signature,
                scanned_at: now,
                valid_until,
                result: result.clone(),
            });
        }
        Ok(Some(result))
    }
}

pub fn state_db_path_for(home: &Path, env: &dyn Fn(&str) -> Option<String>) -> PathBuf {
    if let Some(override_dir) = env("HERMES_HOME") {
        let trimmed = override_dir.trim();
        if !trimmed.is_empty() {
            let expanded = super::super::claude::util::expand_home(home, trimmed);
            return expanded.join("state.db");
        }
    }
    home.join(".hermes/state.db")
}

pub fn default_state_db_path() -> PathBuf {
    state_db_path_for(&paths::home(), &host::env_var)
}

fn query(path: &Path, sql: &str) -> Result<Option<String>, HermesScanError> {
    sqlite::query_text(path, sql, true)
        .map_err(|err| HermesScanError::DatabaseUnreadable(err.to_string()))
}

fn period_starts(now: Timestamp, zone: DayZone) -> [(HermesPeriod, Timestamp); 3] {
    let today = zone
        .local_date(now)
        .unwrap_or_else(|| NaiveDate::from_ymd_opt(2026, 1, 1).unwrap());
    let days_since_monday = today.weekday().num_days_from_monday() as u64;
    let week_date = today
        .checked_sub_days(Days::new(days_since_monday))
        .unwrap_or(today);
    let month_date = today.with_day(1).unwrap_or(today);
    [
        (HermesPeriod::Today, start_of_day(today, zone)),
        (HermesPeriod::ThisWeek, start_of_day(week_date, zone)),
        (HermesPeriod::ThisMonth, start_of_day(month_date, zone)),
    ]
}

fn start_of_day(date: NaiveDate, zone: DayZone) -> Timestamp {
    for hour in 0..4 {
        let Some(naive) = date.and_hms_opt(hour, 0, 0) else {
            continue;
        };
        let resolved = match zone {
            DayZone::Local => match Local.from_local_datetime(&naive) {
                LocalResult::Single(t) | LocalResult::Ambiguous(t, _) => Some(t.timestamp() as f64),
                LocalResult::None => None,
            },
            DayZone::Fixed(offset) => offset
                .from_local_datetime(&naive)
                .single()
                .map(|t| t.timestamp() as f64),
        };
        if let Some(ts) = resolved {
            return ts;
        }
    }
    Utc.from_utc_datetime(&date.and_hms_opt(0, 0, 0).unwrap())
        .timestamp() as f64
}

fn next_midnight(today: NaiveDate, zone: DayZone) -> Option<Timestamp> {
    let tomorrow = today.checked_add_days(Days::new(1))?;
    Some(start_of_day(tomorrow, zone))
}

fn literal(ts: Timestamp) -> String {
    format!("{ts:.3}")
}

pub fn model_table_probe_sql() -> &'static str {
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'session_model_usage';"
}

pub fn period_sql(start: Timestamp, max_timestamp: Option<Timestamp>) -> String {
    let tok = token_sum_expr(None);
    let comp = cost_completeness_expr(&tok, "estimated_cost_usd");
    let invalid = invalid_rows_expr(None, None, max_timestamp);
    let billing = non_opencode_billing_predicate(None);
    format!(
        "SELECT json_array(COALESCE(SUM(input_tokens),0),COALESCE(SUM(output_tokens),0),COALESCE(SUM(cache_read_tokens),0),COALESCE(SUM(cache_write_tokens),0),COALESCE(SUM(reasoning_tokens),0),COALESCE(SUM(api_call_count),0),COALESCE(SUM(estimated_cost_usd),0),{comp},{invalid},CASE WHEN COALESCE(SUM(CASE WHEN ended_at IS NULL THEN 1 ELSE 0 END),0) > 0 THEN 1 ELSE 0 END) FROM sessions WHERE started_at >= {} AND {billing};",
        literal(start)
    )
}

pub fn models_sql(start: Timestamp, detailed: bool, max_timestamp: Option<Timestamp>) -> String {
    let model_expr = if detailed { "smu.model" } else { "model" };
    let tok = token_sum_expr(detailed.then_some("smu"));
    let cost_expr = if detailed {
        "smu.estimated_cost_usd"
    } else {
        "estimated_cost_usd"
    };
    let comp = cost_completeness_expr(&tok, cost_expr);
    let invalid = invalid_rows_expr(
        detailed.then_some("smu"),
        detailed.then_some("s"),
        max_timestamp,
    );
    let active = if detailed {
        "CASE WHEN SUM(CASE WHEN s.ended_at IS NULL THEN 1 ELSE 0 END) > 0 THEN 1 ELSE 0 END"
    } else {
        "CASE WHEN SUM(CASE WHEN ended_at IS NULL THEN 1 ELSE 0 END) > 0 THEN 1 ELSE 0 END"
    };
    let source = if detailed {
        format!(
            "FROM session_model_usage smu JOIN sessions s ON s.id = smu.session_id WHERE s.started_at >= {} AND {}",
            literal(start),
            non_opencode_billing_predicate(Some("s"))
        )
    } else {
        format!(
            "FROM sessions WHERE started_at >= {} AND {}",
            literal(start),
            non_opencode_billing_predicate(None)
        )
    };
    format!(
        "SELECT json_group_array(json_array(model, tokens, cost, cost_is_complete, invalid_rows, active_sessions)) FROM (SELECT {model_expr} AS model, CAST(SUM({tok}) AS REAL) AS tokens, COALESCE(SUM({cost_expr}),0) AS cost, {comp} AS cost_is_complete, {invalid} AS invalid_rows, {active} AS active_sessions {source} GROUP BY {model_expr});"
    )
}

pub fn daily_sql(cutoff: Timestamp, max_timestamp: Option<Timestamp>) -> String {
    let tok = token_sum_expr(None);
    let comp = cost_completeness_expr(&tok, "estimated_cost_usd");
    let invalid = invalid_rows_expr(None, None, max_timestamp);
    let billing = non_opencode_billing_predicate(None);
    format!(
        "SELECT json_group_array(json_array(day, tokens, cost, cost_is_complete, invalid_rows, active_sessions)) FROM (SELECT date(CAST(started_at AS INTEGER),'unixepoch','localtime') AS day, CAST(SUM({tok}) AS REAL) AS tokens, COALESCE(SUM(estimated_cost_usd),0) AS cost, {comp} AS cost_is_complete, {invalid} AS invalid_rows, CASE WHEN SUM(CASE WHEN ended_at IS NULL THEN 1 ELSE 0 END) > 0 THEN 1 ELSE 0 END AS active_sessions FROM sessions WHERE started_at >= {} AND {billing} GROUP BY day);",
        literal(cutoff)
    )
}

fn token_sum_expr(alias: Option<&str>) -> String {
    let p = alias.map_or_else(String::new, |a| format!("{a}."));
    format!("(COALESCE({p}input_tokens,0) + COALESCE({p}output_tokens,0) + COALESCE({p}cache_read_tokens,0) + COALESCE({p}cache_write_tokens,0) + COALESCE({p}reasoning_tokens,0))")
}

fn cost_completeness_expr(tok_expr: &str, cost_expr: &str) -> String {
    format!("CASE WHEN SUM(CASE WHEN {tok_expr} > 0 AND ({cost_expr} IS NULL OR {cost_expr} <= 0) THEN 1 ELSE 0 END) = 0 THEN 1 ELSE 0 END")
}

fn invalid_rows_expr(
    alias: Option<&str>,
    session_alias: Option<&str>,
    max_ts: Option<Timestamp>,
) -> String {
    let p = alias.map_or_else(String::new, |a| format!("{a}."));
    let mut names = vec![
        "input_tokens",
        "output_tokens",
        "cache_read_tokens",
        "cache_write_tokens",
        "reasoning_tokens",
    ];
    if alias.is_none() {
        names.push("api_call_count");
    }
    let mut parts: Vec<String> = names
        .into_iter()
        .map(|n| {
            let col = format!("{p}{n}");
            format!("({col} IS NOT NULL AND (typeof({col}) NOT IN ('integer','real') OR {col} < 0 OR {col} > 1000000000000000 OR {col} != CAST({col} AS INTEGER)))")
        })
        .collect();
    let cost = format!("{p}estimated_cost_usd");
    parts.push(format!("({cost} IS NOT NULL AND (typeof({cost}) NOT IN ('integer','real') OR {cost} < 0 OR {cost} > 1000000000000))"));
    if let Some(max) = max_ts {
        let sp = session_alias.map_or_else(String::new, |a| format!("{a}."));
        let ts = format!("{sp}started_at");
        let calls = format!("{sp}api_call_count");
        let has_usage = format!(
            "({} > 0 OR COALESCE({calls},0) > 0 OR COALESCE({cost},0) > 0)",
            token_sum_expr(alias)
        );
        parts.push(format!(
            "({has_usage} AND (typeof({ts}) NOT IN ('integer','real') OR {ts} > {}))",
            literal(max)
        ));
    }
    format!(
        "CASE WHEN SUM(CASE WHEN {} THEN 1 ELSE 0 END) > 0 THEN 1 ELSE 0 END",
        parts.join(" OR ")
    )
}

fn non_opencode_billing_predicate(session_alias: Option<&str>) -> String {
    let p = session_alias.map_or_else(String::new, |a| format!("{a}."));
    format!(
        "COALESCE(LOWER({p}billing_provider), '') NOT LIKE 'opencode%' AND COALESCE(LOWER({p}billing_base_url), '') NOT LIKE '%opencode%'"
    )
}

struct ParsedPeriod {
    counts: HermesTokenCounts,
    cost_usd: Option<f64>,
    api_call_count: i64,
    is_partial: bool,
}

fn parse_period(json_text: &str) -> Option<ParsedPeriod> {
    let arr: Vec<Value> = serde_json::from_str(json_text).ok()?;
    if arr.len() != 10 {
        return None;
    }
    let input = strict_tok(&arr[0])?;
    let output = strict_tok(&arr[1])?;
    let cache_read = strict_tok(&arr[2])?;
    let cache_write = strict_tok(&arr[3])?;
    let reasoning = strict_tok(&arr[4])?;
    let api_call_count = strict_tok(&arr[5])?;
    let cost_val = strict_cost(&arr[6])?;
    let cost_complete = strict_tok(&arr[7]).filter(|v| *v <= 1)? == 1;
    if strict_tok(&arr[8])? != 0 {
        return None;
    }
    let active = strict_tok(&arr[9]).filter(|v| *v <= 1)?;
    Some(ParsedPeriod {
        counts: HermesTokenCounts {
            input,
            output,
            cache_read,
            cache_write,
            reasoning,
        },
        cost_usd: (cost_complete && cost_val > 0.0).then_some(cost_val),
        api_call_count,
        is_partial: active == 1,
    })
}

fn parse_models(json_text: &str) -> Option<Vec<HermesModelUsage>> {
    let arr: Vec<Value> = serde_json::from_str(json_text).ok()?;
    let mut rows = Vec::with_capacity(arr.len());
    for elem in arr {
        let entry = elem.as_array()?;
        if entry.len() != 6 {
            return None;
        }
        let model = entry[0].as_str().map(str::trim).unwrap_or("").to_string();
        let tokens = strict_tok(&entry[1])?;
        let cost = strict_cost(&entry[2])?;
        let cost_complete = strict_tok(&entry[3]).filter(|v| *v <= 1)? == 1;
        if strict_tok(&entry[4])? != 0 {
            return None;
        }
        let active = strict_tok(&entry[5]).filter(|v| *v <= 1)?;
        rows.push(HermesModelUsage {
            model,
            tokens,
            cost_usd: (cost_complete && cost > 0.0).then_some(cost),
            is_partial: active == 1,
        });
    }
    rows.sort_by(|a, b| {
        b.tokens
            .cmp(&a.tokens)
            .then_with(|| crate::accounting::localized_standard_compare(&a.model, &b.model))
    });
    Some(rows)
}

fn parse_daily(json_text: &str) -> Option<(DailyUsageSeries, BTreeSet<String>)> {
    let arr: Vec<Value> = serde_json::from_str(json_text).ok()?;
    let mut daily = Vec::with_capacity(arr.len());
    let mut partial = BTreeSet::new();
    for elem in arr {
        let entry = elem.as_array()?;
        if entry.len() != 6 {
            return None;
        }
        let day = entry[0].as_str()?.to_string();
        let tokens = strict_tok(&entry[1])?;
        let cost = strict_cost(&entry[2])?;
        let cost_complete = strict_tok(&entry[3]).filter(|v| *v <= 1)? == 1;
        if strict_tok(&entry[4])? != 0 {
            return None;
        }
        let active = strict_tok(&entry[5]).filter(|v| *v <= 1)?;
        if active == 1 {
            partial.insert(day.clone());
        }
        if tokens > 0 || (cost_complete && cost > 0.0) {
            daily.push(DailyUsageEntry {
                date: day,
                total_tokens: tokens,
                cost_usd: (cost_complete && cost > 0.0).then_some(cost),
                cost_is_complete: cost_complete,
                has_unexplained_incomplete_cost: None,
                token_count_saturated: false,
                reported_cost: None,
            });
        }
    }
    let _ = FixedOffset::east_opt(0);
    Some((DailyUsageSeries { daily }, partial))
}

fn strict_tok(val: &Value) -> Option<i64> {
    if val.is_boolean() {
        return None;
    }
    let num = crate::parse::number(Some(val))?;
    (num.is_finite() && num >= 0.0 && num <= 1e15 && num.trunc() == num).then_some(num as i64)
}

fn strict_cost(val: &Value) -> Option<f64> {
    if val.is_boolean() {
        return None;
    }
    let num = crate::parse::number(Some(val))?;
    (num.is_finite() && num >= 0.0 && num <= 1e12).then_some(num)
}
