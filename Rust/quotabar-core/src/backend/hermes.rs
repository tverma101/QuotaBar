//! Hermes Agent local-usage scan.
//!
//! Port of `HermesUsageScanner` in `Sources/QuotaBar/Providers/Hermes/HermesUsageScanner.swift`.
//! The Swift implementation remains the reference oracle for parity tests. The SQL is carried over
//! verbatim (same aggregates, JSON shaping, invalid-row detection, and OpenCode-billing exclusion)
//! so row selection and day bucketing cannot drift; the only material change is that the four
//! queries run on one in-process SQLite connection instead of one `/usr/bin/sqlite3` subprocess per
//! query.
//!
//! Calendar policy stays at the Swift edge: the caller passes the period starts, the future-row
//! cutoff, and the ten-year daily cutoff as epoch seconds, so `Calendar.current` remains the single
//! authority for local-day/week/month boundaries.

use rusqlite::{Connection, OpenFlags};
use serde_json::{json, Map, Value};
use std::path::Path;
use std::time::Duration;

use super::{invalid_param, BackendError};

const MODEL_TABLE_PROBE_SQL: &str = "SELECT name FROM sqlite_master \
     WHERE type = 'table' AND name = 'session_model_usage';";

/// A failed scan attempt. `Sql` may be retried without the read-only flag (matching
/// `SQLiteCLIAccessor.queryValue`); `Data` is a decisive result and must not be retried.
enum AttemptError {
    Sql(String),
    Data(String),
}

impl AttemptError {
    fn message(self) -> String {
        match self {
            AttemptError::Sql(message) | AttemptError::Data(message) => message,
        }
    }
}

struct PeriodRow {
    input: u64,
    output: u64,
    cache_read: u64,
    cache_write: u64,
    reasoning: u64,
    api_call_count: u64,
    cost_usd: Option<f64>,
    is_partial: bool,
}

struct ModelRow {
    model: String,
    tokens: u64,
    cost_usd: Option<f64>,
    is_partial: bool,
}

struct DailyRow {
    day: String,
    tokens: u64,
    cost_usd: Option<f64>,
    cost_is_complete: bool,
}

/// Scan a Hermes `state.db` and return the normalized scan in the shape the Swift bridge decodes.
pub fn scan(params: &Value) -> Result<Value, BackendError> {
    let path = required_string(params, "databasePath")?;
    let starts = period_starts(params)?;
    let maximum_timestamp = required_number(params, "maximumTimestamp")?;
    let daily_cutoff = required_number(params, "dailyCutoff")?;

    if !Path::new(&path).exists() {
        return Err(BackendError {
            kind: "database_unreadable",
            message: format!("Hermes state database not found at {path}"),
        });
    }

    let first = scan_with(
        &path,
        &starts,
        maximum_timestamp,
        daily_cutoff,
        OpenFlags::SQLITE_OPEN_READ_ONLY,
    );
    match first {
        Ok(result) => Ok(result),
        Err(AttemptError::Data(message)) => Err(BackendError {
            kind: "database_unreadable",
            message,
        }),
        Err(AttemptError::Sql(read_only_message)) => {
            // A WAL database under an active writer can refuse a read-only open or query. The
            // statements are SELECTs, so a read-write retry cannot mutate the database; the caller
            // already proved the path exists, so it cannot be created either.
            match scan_with(
                &path,
                &starts,
                maximum_timestamp,
                daily_cutoff,
                OpenFlags::SQLITE_OPEN_READ_WRITE,
            ) {
                Ok(result) => Ok(result),
                Err(error) => {
                    let mut message = error.message();
                    if message.is_empty() {
                        message = read_only_message;
                    }
                    Err(BackendError {
                        kind: "database_unreadable",
                        message,
                    })
                }
            }
        }
    }
}

fn required_string(params: &Value, key: &str) -> Result<String, BackendError> {
    params
        .get(key)
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| invalid_param(format!("missing string parameter `{key}`")))
}

fn required_number(params: &Value, key: &str) -> Result<f64, BackendError> {
    params
        .get(key)
        .and_then(Value::as_f64)
        .filter(|value| value.is_finite())
        .ok_or_else(|| invalid_param(format!("missing finite number parameter `{key}`")))
}

fn period_starts(params: &Value) -> Result<[f64; 3], BackendError> {
    let object = params
        .get("periodStarts")
        .and_then(Value::as_object)
        .ok_or_else(|| invalid_param("missing `periodStarts` object".to_string()))?;
    let mut starts = [0.0; 3];
    for (index, key) in ["today", "thisWeek", "thisMonth"].iter().enumerate() {
        starts[index] = object
            .get(*key)
            .and_then(Value::as_f64)
            .filter(|value| value.is_finite() && *value >= 0.0)
            .ok_or_else(|| invalid_param(format!("missing finite `periodStarts.{key}`")))?;
    }
    Ok(starts)
}

fn scan_with(
    path: &str,
    starts: &[f64; 3],
    maximum_timestamp: f64,
    daily_cutoff: f64,
    flags: OpenFlags,
) -> Result<Value, AttemptError> {
    let connection = Connection::open_with_flags(path, flags).map_err(sql_error)?;
    connection
        .busy_timeout(Duration::from_millis(1_000))
        .map_err(sql_error)?;

    // Matches `try? queryValue(probe) != nil`: a probe failure downgrades to the sessions column.
    let has_model_table = connection
        .query_row(MODEL_TABLE_PROBE_SQL, [], |row| row.get::<_, String>(0))
        .is_ok();

    let period_names = ["today", "thisWeek", "thisMonth"];
    let mut periods: Vec<Value> = Vec::with_capacity(3);
    let mut models_by_period = Map::new();

    for (index, period) in period_names.iter().enumerate() {
        let period_json = query_value(
            &connection,
            &period_sql(starts[index], maximum_timestamp),
            "period query returned no result",
        )?;
        let row = parse_period(&period_json)?;
        periods.push(json!({
            "period": period,
            "input": row.input,
            "output": row.output,
            "cacheRead": row.cache_read,
            "cacheWrite": row.cache_write,
            "reasoning": row.reasoning,
            "apiCallCount": row.api_call_count,
            "costUSD": row.cost_usd,
            "isPartial": row.is_partial,
        }));

        let models_json = query_value(
            &connection,
            &models_sql(starts[index], has_model_table, maximum_timestamp),
            "model query returned no result",
        )?;
        let rows = parse_models(&models_json)?;
        models_by_period.insert(
            (*period).to_string(),
            Value::Array(
                rows.iter()
                    .map(|row| {
                        json!({
                            "model": row.model,
                            "tokens": row.tokens,
                            "costUSD": row.cost_usd,
                            "isPartial": row.is_partial,
                        })
                    })
                    .collect(),
            ),
        );
    }

    let daily_json = query_value(
        &connection,
        &daily_sql(daily_cutoff, maximum_timestamp),
        "daily query returned no result",
    )?;
    let (daily, partial_days) = parse_daily(&daily_json)?;

    Ok(json!({
        "periods": periods,
        "daily": daily.iter().map(|row| json!({
            "date": row.day,
            "totalTokens": row.tokens,
            "costUSD": row.cost_usd,
            "costIsComplete": row.cost_is_complete,
        })).collect::<Vec<_>>(),
        "modelUsageByPeriod": Value::Object(models_by_period),
        "partialDays": partial_days,
    }))
}

fn sql_error(error: rusqlite::Error) -> AttemptError {
    AttemptError::Sql(error.to_string())
}

fn query_value(
    connection: &Connection,
    sql: &str,
    missing_message: &str,
) -> Result<String, AttemptError> {
    match connection.query_row(sql, [], |row| row.get::<_, String>(0)) {
        Ok(value) => Ok(value),
        Err(rusqlite::Error::QueryReturnedNoRows) => {
            Err(AttemptError::Sql(missing_message.to_string()))
        }
        Err(error) => Err(AttemptError::Sql(error.to_string())),
    }
}

// ---------------------------------------------------------------------------
// Parsing (mirror of the Swift `parsePeriod` / `parseModels` / `parseDaily`)
// ---------------------------------------------------------------------------

fn parse_period(json: &str) -> Result<PeriodRow, AttemptError> {
    let value: Value = serde_json::from_str(json).map_err(|_| {
        AttemptError::Data("period query returned malformed accounting data".into())
    })?;
    let array = value
        .as_array()
        .filter(|array| array.len() == 10)
        .ok_or_else(|| {
            AttemptError::Data("period query returned malformed accounting data".into())
        })?;

    let input = nonnegative_token_count(&array[0]);
    let output = nonnegative_token_count(&array[1]);
    let cache_read = nonnegative_token_count(&array[2]);
    let cache_write = nonnegative_token_count(&array[3]);
    let reasoning = nonnegative_token_count(&array[4]);
    let api_call_count = nonnegative_token_count(&array[5]);
    let cost_value = nonnegative_cost(&array[6]);
    let cost_complete = nonnegative_token_count(&array[7]);
    let invalid_rows = nonnegative_token_count(&array[8]);
    let active_sessions = nonnegative_token_count(&array[9]);

    let (
        Some(input),
        Some(output),
        Some(cache_read),
        Some(cache_write),
        Some(reasoning),
        Some(api_call_count),
        Some(cost_value),
        Some(cost_complete),
        Some(invalid_rows),
        Some(active_sessions),
    ) = (
        input,
        output,
        cache_read,
        cache_write,
        reasoning,
        api_call_count,
        cost_value,
        cost_complete,
        invalid_rows,
        active_sessions,
    )
    else {
        return Err(AttemptError::Data(
            "period query returned malformed accounting data".into(),
        ));
    };
    if cost_complete > 1 || invalid_rows != 0 || active_sessions > 1 {
        return Err(AttemptError::Data(
            "period query returned malformed accounting data".into(),
        ));
    }

    Ok(PeriodRow {
        input,
        output,
        cache_read,
        cache_write,
        reasoning,
        api_call_count,
        cost_usd: if cost_complete == 1 && cost_value > 0.0 {
            Some(cost_value)
        } else {
            None
        },
        is_partial: active_sessions == 1,
    })
}

fn parse_models(json: &str) -> Result<Vec<ModelRow>, AttemptError> {
    let value: Value = serde_json::from_str(json)
        .map_err(|_| AttemptError::Data("model query returned malformed accounting data".into()))?;
    let array = value.as_array().ok_or_else(|| {
        AttemptError::Data("model query returned malformed accounting data".into())
    })?;

    let mut rows: Vec<ModelRow> = Vec::with_capacity(array.len());
    for element in array {
        let entry = element
            .as_array()
            .filter(|entry| entry.len() == 6)
            .ok_or_else(|| {
                AttemptError::Data("model query returned malformed accounting data".into())
            })?;
        let tokens = nonnegative_token_count(&entry[1]);
        let cost = nonnegative_cost(&entry[2]);
        let cost_complete = nonnegative_token_count(&entry[3]);
        let invalid_rows = nonnegative_token_count(&entry[4]);
        let active_sessions = nonnegative_token_count(&entry[5]);
        let (
            Some(tokens),
            Some(cost),
            Some(cost_complete),
            Some(invalid_rows),
            Some(active_sessions),
        ) = (tokens, cost, cost_complete, invalid_rows, active_sessions)
        else {
            return Err(AttemptError::Data(
                "model query returned malformed accounting data".into(),
            ));
        };
        if cost_complete > 1 || invalid_rows != 0 || active_sessions > 1 {
            return Err(AttemptError::Data(
                "model query returned malformed accounting data".into(),
            ));
        }

        // A missing or non-string model reads as "Unattributed" (the mapper's empty-name case).
        let model = entry[0]
            .as_str()
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .unwrap_or("")
            .to_string();
        rows.push(ModelRow {
            model,
            tokens,
            cost_usd: if cost_complete == 1 && cost > 0.0 {
                Some(cost)
            } else {
                None
            },
            is_partial: active_sessions == 1,
        });
    }
    // Ordering is applied by the Swift bridge with the same localized comparator the reference
    // scanner uses; SQLite's GROUP BY order is unspecified, so no display order is promised here.
    Ok(rows)
}

fn parse_daily(json: &str) -> Result<(Vec<DailyRow>, Value), AttemptError> {
    let value: Value = serde_json::from_str(json)
        .map_err(|_| AttemptError::Data("daily query returned malformed accounting data".into()))?;
    let array = value.as_array().ok_or_else(|| {
        AttemptError::Data("daily query returned malformed accounting data".into())
    })?;

    let mut rows: Vec<DailyRow> = Vec::with_capacity(array.len());
    let mut partial_days: Vec<String> = Vec::new();
    for element in array {
        let entry = element
            .as_array()
            .filter(|entry| entry.len() == 6)
            .ok_or_else(|| {
                AttemptError::Data("daily query returned malformed accounting data".into())
            })?;
        let day = entry[0]
            .as_str()
            .ok_or_else(|| {
                AttemptError::Data("daily query returned malformed accounting data".into())
            })?
            .to_string();
        let tokens = nonnegative_token_count(&entry[1]);
        let cost = nonnegative_cost(&entry[2]);
        let cost_complete = nonnegative_token_count(&entry[3]);
        let invalid_rows = nonnegative_token_count(&entry[4]);
        let active_sessions = nonnegative_token_count(&entry[5]);
        let (
            Some(tokens),
            Some(cost),
            Some(cost_complete),
            Some(invalid_rows),
            Some(active_sessions),
        ) = (tokens, cost, cost_complete, invalid_rows, active_sessions)
        else {
            return Err(AttemptError::Data(
                "daily query returned malformed accounting data".into(),
            ));
        };
        if cost_complete > 1 || invalid_rows != 0 || active_sessions > 1 {
            return Err(AttemptError::Data(
                "daily query returned malformed accounting data".into(),
            ));
        }

        let is_partial = active_sessions == 1;
        if is_partial {
            partial_days.push(day.clone());
        }
        let cost_is_complete = cost_complete == 1;
        // A session can carry a recorded cost even when its token buckets are empty. Keep that day
        // so the lifetime report agrees with the Hermes period total.
        if tokens == 0 && !(cost_is_complete && cost > 0.0) {
            continue;
        }
        rows.push(DailyRow {
            day,
            tokens,
            cost_usd: if cost_is_complete && cost > 0.0 {
                Some(cost)
            } else {
                None
            },
            cost_is_complete,
        });
    }
    Ok((
        rows,
        Value::Array(partial_days.into_iter().map(Value::String).collect()),
    ))
}

/// Mirror of `nonnegativeTokenCount`: a JSON number (never a bool), finite, in [0, 1e15],
/// integral. Values in range are exactly representable in f64.
fn nonnegative_token_count(value: &Value) -> Option<u64> {
    let number = match value {
        Value::Number(number) => number,
        _ => return None,
    };
    let value = number.as_f64()?;
    if !value.is_finite() || value < 0.0 || value > 1e15 || value.fract() != 0.0 {
        return None;
    }
    Some(value as u64)
}

/// Mirror of `nonnegativeCost`: finite, in [0, 1e12]. Does not require an integer.
fn nonnegative_cost(value: &Value) -> Option<f64> {
    let number = match value {
        Value::Number(number) => number,
        _ => return None,
    };
    let value = number.as_f64()?;
    if !value.is_finite() || value < 0.0 || value > 1e12 {
        return None;
    }
    Some(value)
}

// ---------------------------------------------------------------------------
// SQL (verbatim port of HermesUsageScanner's builders)
// ---------------------------------------------------------------------------

/// Literal epoch seconds, embedded as a number (never user text). Rounded to milliseconds like the
/// Swift scanner so the comparison is stable against REAL timestamps.
fn literal(seconds: f64) -> String {
    format!("{seconds:.3}")
}

fn period_sql(start: f64, maximum_timestamp: f64) -> String {
    let token_expression = token_sum_expression(None);
    let cost_completeness = cost_completeness_expression(&token_expression, "estimated_cost_usd");
    let invalid_rows = invalid_rows_expression(None, None, Some(maximum_timestamp));
    format!(
        "SELECT json_array(\n         COALESCE(SUM(input_tokens),0),\n         COALESCE(SUM(output_tokens),0),\n         COALESCE(SUM(cache_read_tokens),0),\n         COALESCE(SUM(cache_write_tokens),0),\n         COALESCE(SUM(reasoning_tokens),0),\n         COALESCE(SUM(api_call_count),0),\n         COALESCE(SUM(estimated_cost_usd),0),\n         {cost_completeness},\n         {invalid_rows},\n         CASE WHEN COALESCE(SUM(CASE WHEN ended_at IS NULL THEN 1 ELSE 0 END),0) > 0 THEN 1 ELSE 0 END)\n        FROM sessions\n        WHERE started_at >= {start}\n          AND {billing};",
        start = literal(start),
        billing = non_open_code_billing_predicate(None)
    )
}

fn models_sql(start: f64, detailed: bool, maximum_timestamp: f64) -> String {
    let model_expression = if detailed { "smu.model" } else { "model" };
    let tokens_expression = token_sum_expression(if detailed { Some("smu") } else { None });
    let cost_expression = if detailed {
        "smu.estimated_cost_usd"
    } else {
        "estimated_cost_usd"
    };
    let cost_completeness = cost_completeness_expression(&tokens_expression, cost_expression);
    let invalid_rows = invalid_rows_expression(
        if detailed { Some("smu") } else { None },
        if detailed { Some("s") } else { None },
        Some(maximum_timestamp),
    );
    let active_sessions = if detailed {
        "CASE WHEN SUM(CASE WHEN s.ended_at IS NULL THEN 1 ELSE 0 END) > 0 THEN 1 ELSE 0 END"
    } else {
        "CASE WHEN SUM(CASE WHEN ended_at IS NULL THEN 1 ELSE 0 END) > 0 THEN 1 ELSE 0 END"
    };
    let source = if detailed {
        format!(
            "FROM session_model_usage smu\n                JOIN sessions s ON s.id = smu.session_id\n                WHERE s.started_at >= {start}\n                  AND {billing}",
            start = literal(start),
            billing = non_open_code_billing_predicate(Some("s"))
        )
    } else {
        format!(
            "FROM sessions\n                WHERE started_at >= {start}\n                  AND {billing}",
            start = literal(start),
            billing = non_open_code_billing_predicate(None)
        )
    };
    format!(
        "SELECT json_group_array(json_array(model, tokens, cost, cost_is_complete, invalid_rows, active_sessions)) FROM (\n                SELECT {model_expression} AS model,\n                       CAST(SUM({tokens_expression}) AS REAL) AS tokens,\n                       COALESCE(SUM({cost_expression}),0) AS cost,\n                       {cost_completeness} AS cost_is_complete,\n                       {invalid_rows} AS invalid_rows,\n                       {active_sessions} AS active_sessions\n                {source}\n                GROUP BY {model_expression}\n            );"
    )
}

fn daily_sql(cutoff: f64, maximum_timestamp: f64) -> String {
    let token_expression = token_sum_expression(None);
    let cost_completeness = cost_completeness_expression(&token_expression, "estimated_cost_usd");
    let invalid_rows = invalid_rows_expression(None, None, Some(maximum_timestamp));
    format!(
        "SELECT json_group_array(json_array(day, tokens, cost, cost_is_complete, invalid_rows, active_sessions)) FROM (\n            SELECT date(CAST(started_at AS INTEGER),'unixepoch','localtime') AS day,\n                   CAST(SUM({token_expression}) AS REAL) AS tokens,\n                   COALESCE(SUM(estimated_cost_usd),0) AS cost,\n                   {cost_completeness} AS cost_is_complete,\n                   {invalid_rows} AS invalid_rows,\n                   CASE WHEN SUM(CASE WHEN ended_at IS NULL THEN 1 ELSE 0 END) > 0 THEN 1 ELSE 0 END AS active_sessions\n            FROM sessions\n            WHERE started_at >= {cutoff}\n              AND {billing}\n            GROUP BY day\n        );",
        cutoff = literal(cutoff),
        billing = non_open_code_billing_predicate(None)
    )
}

fn token_sum_expression(alias: Option<&str>) -> String {
    let prefix = alias.map(|alias| format!("{alias}.")).unwrap_or_default();
    format!(
        "(COALESCE({prefix}input_tokens,0) + COALESCE({prefix}output_tokens,0) + COALESCE({prefix}cache_read_tokens,0) + COALESCE({prefix}cache_write_tokens,0) + COALESCE({prefix}reasoning_tokens,0))"
    )
}

fn cost_completeness_expression(token_expression: &str, cost_expression: &str) -> String {
    // Hermes declares estimated_cost_usd REAL DEFAULT 0, so a token-bearing row whose importer
    // omitted the field is indistinguishable from an explicit zero after SQLite inserts it.
    // Treat zero as missing coverage; showing another session's subtotal as complete would be false.
    format!(
        "CASE WHEN SUM(CASE WHEN {token_expression} > 0 AND ({cost_expression} IS NULL OR {cost_expression} <= 0) THEN 1 ELSE 0 END) = 0 THEN 1 ELSE 0 END"
    )
}

/// SQLite coerces malformed text values to zero inside SUM(), which otherwise turns one corrupt
/// Hermes row into a plausible smaller total. Carry an invalid-row flag through every aggregate and
/// reject the whole scan if any source counter or recorded cost has the wrong shape.
fn invalid_rows_expression(
    alias: Option<&str>,
    session_alias: Option<&str>,
    maximum_timestamp: Option<f64>,
) -> String {
    let prefix = alias.map(|alias| format!("{alias}.")).unwrap_or_default();
    let mut counter_names = vec![
        "input_tokens",
        "output_tokens",
        "cache_read_tokens",
        "cache_write_tokens",
        "reasoning_tokens",
    ];
    // `api_call_count` is on `sessions`, not the optional per-model attribution table.
    if alias.is_none() {
        counter_names.push("api_call_count");
    }
    let mut invalid_expressions: Vec<String> = counter_names
        .iter()
        .map(|name| {
            let column = format!("{prefix}{name}");
            format!(
                "({column} IS NOT NULL AND (typeof({column}) NOT IN ('integer','real') OR {column} < 0 OR {column} > 1000000000000000 OR {column} != CAST({column} AS INTEGER)))"
            )
        })
        .collect();

    let cost = format!("{prefix}estimated_cost_usd");
    invalid_expressions.push(format!(
        "({cost} IS NOT NULL AND (typeof({cost}) NOT IN ('integer','real') OR {cost} < 0 OR {cost} > 1000000000000))"
    ));

    if let Some(maximum_timestamp) = maximum_timestamp {
        let timestamp_prefix = session_alias
            .map(|alias| format!("{alias}."))
            .unwrap_or_default();
        let timestamp = format!("{timestamp_prefix}started_at");
        let api_call_count = session_alias
            .map(|alias| format!("{alias}.api_call_count"))
            .unwrap_or_else(|| "api_call_count".to_string());
        let has_usage = format!(
            "({} > 0 OR COALESCE({api_call_count},0) > 0 OR COALESCE({cost},0) > 0)",
            token_sum_expression(alias)
        );
        invalid_expressions.push(format!(
            "({has_usage} AND (typeof({timestamp}) NOT IN ('integer','real') OR {timestamp} > {maximum}))",
            maximum = literal(maximum_timestamp)
        ));
    }

    format!(
        "CASE WHEN SUM(CASE WHEN {} THEN 1 ELSE 0 END) > 0 THEN 1 ELSE 0 END",
        invalid_expressions.join(" OR ")
    )
}

/// OpenCode-billed Hermes sessions are folded onto the OpenCode card, where their cost is
/// attributed to the account that paid for them. Keeping them in the Hermes card would double
/// count their tokens in cross-provider spend totals.
fn non_open_code_billing_predicate(session_alias: Option<&str>) -> String {
    let prefix = session_alias
        .map(|alias| format!("{alias}."))
        .unwrap_or_default();
    format!(
        "COALESCE(LOWER({prefix}billing_provider), '') NOT LIKE 'opencode%'\n          AND COALESCE(LOWER({prefix}billing_base_url), '') NOT LIKE '%opencode%'"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn create_fixture(path: &str) {
        let connection = Connection::open(path).expect("open fixture");
        connection
            .execute_batch(
                "CREATE TABLE sessions (
                    id TEXT PRIMARY KEY,
                    model TEXT,
                    started_at REAL NOT NULL,
                    ended_at REAL DEFAULT 0,
                    input_tokens INTEGER DEFAULT 0,
                    output_tokens INTEGER DEFAULT 0,
                    cache_read_tokens INTEGER DEFAULT 0,
                    cache_write_tokens INTEGER DEFAULT 0,
                    reasoning_tokens INTEGER DEFAULT 0,
                    api_call_count INTEGER DEFAULT 0,
                    estimated_cost_usd REAL DEFAULT 0,
                    billing_provider TEXT,
                    billing_base_url TEXT
                );
                CREATE TABLE session_model_usage (
                    session_id TEXT NOT NULL,
                    model TEXT NOT NULL,
                    input_tokens INTEGER DEFAULT 0,
                    output_tokens INTEGER DEFAULT 0,
                    cache_read_tokens INTEGER DEFAULT 0,
                    cache_write_tokens INTEGER DEFAULT 0,
                    reasoning_tokens INTEGER DEFAULT 0,
                    estimated_cost_usd REAL DEFAULT 0
                );",
            )
            .expect("schema");
    }

    fn params(path: &str, now: f64) -> Value {
        json!({
            "databasePath": path,
            "periodStarts": { "today": now - 3_600.0, "thisWeek": now - 86_400.0, "thisMonth": now - 172_800.0 },
            "maximumTimestamp": now + 300.0,
            "dailyCutoff": now - 365_000_000.0,
        })
    }

    #[test]
    fn scan_reports_periods_models_and_daily_rows() {
        let dir = std::env::temp_dir().join(format!("quotabar-hermes-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("state.db");
        let path_string = path.to_string_lossy().to_string();
        let _ = std::fs::remove_file(&path);
        create_fixture(&path_string);

        let now = 1_784_800_000.0;
        let connection = Connection::open(&path_string).unwrap();
        connection
            .execute_batch(&format!(
                "INSERT INTO sessions (id, model, started_at, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens, api_call_count, estimated_cost_usd) VALUES
                  ('recent', 'kimi/kimi-k2.7', {}, 1000, 200, 8000, 0, 50, 12, 0.42);
                 INSERT INTO session_model_usage (session_id, model, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens, estimated_cost_usd) VALUES
                  ('recent', 'kimi/kimi-k2.7', 1000, 200, 8000, 0, 50, 0.42),
                  ('recent', 'deepseek/deepseek-v4-flash', 300, 100, 0, 0, 10, 0.05);",
                now - 3_600.0
            ))
            .unwrap();
        drop(connection);

        let result = scan(&params(&path_string, now)).expect("scan");
        assert_eq!(result["periods"][0]["input"], 1000);
        assert_eq!(result["periods"][0]["cacheRead"], 8000);
        assert_eq!(result["periods"][0]["costUSD"], 0.42);
        assert_eq!(
            result["modelUsageByPeriod"]["today"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        assert_eq!(result["daily"].as_array().unwrap().len(), 1);
        assert_eq!(result["daily"][0]["totalTokens"], 9250);
        assert!(result["partialDays"].as_array().unwrap().is_empty());

        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_dir(&dir);
    }

    #[test]
    fn scan_excludes_opencode_billed_sessions() {
        let dir = std::env::temp_dir().join(format!("quotabar-hermes-oc-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("state.db");
        let path_string = path.to_string_lossy().to_string();
        let _ = std::fs::remove_file(&path);
        create_fixture(&path_string);

        let now = 1_784_800_000.0;
        let connection = Connection::open(&path_string).unwrap();
        connection
            .execute_batch(&format!(
                "INSERT INTO sessions (id, model, started_at, input_tokens, output_tokens, estimated_cost_usd, billing_provider, billing_base_url) VALUES
                  ('direct', 'claude-sonnet-5', {started}, 100, 20, 0.25, 'anthropic', 'https://api.anthropic.com'),
                  ('gateway', 'deepseek-v4-flash', {started}, 500, 60, 0.75, 'opencode-go', 'https://opencode.ai/zen/go/v1');",
                started = now - 60.0
            ))
            .unwrap();
        drop(connection);

        let result = scan(&params(&path_string, now)).expect("scan");
        assert_eq!(result["periods"][0]["input"], 100);
        assert_eq!(result["periods"][0]["costUSD"], 0.25);
        assert_eq!(result["daily"][0]["totalTokens"], 120);

        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_dir(&dir);
    }

    #[test]
    fn scan_treats_default_zero_cost_as_incomplete() {
        let dir = std::env::temp_dir().join(format!("quotabar-hermes-cost-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("state.db");
        let path_string = path.to_string_lossy().to_string();
        let _ = std::fs::remove_file(&path);
        create_fixture(&path_string);

        let now = 1_784_800_000.0;
        let connection = Connection::open(&path_string).unwrap();
        connection
            .execute_batch(&format!(
                "INSERT INTO sessions (id, model, started_at, input_tokens, output_tokens, estimated_cost_usd) VALUES
                  ('priced', 'priced-model', {started}, 100, 20, 0.25);
                 INSERT INTO sessions (id, model, started_at, input_tokens, output_tokens) VALUES
                  ('missing-cost', 'missing-cost-model', {started_plus}, 300, 30);",
                started = now - 60.0,
                started_plus = now - 59.0
            ))
            .unwrap();
        drop(connection);

        let result = scan(&params(&path_string, now)).expect("scan");
        assert_eq!(result["periods"][0]["input"], 400);
        assert!(result["periods"][0]["costUSD"].is_null());
        assert_eq!(result["daily"][0]["totalTokens"], 450);

        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_dir(&dir);
    }

    #[test]
    fn missing_database_is_a_typed_error() {
        let error = scan(&params(
            "/nonexistent/quotabar/hermes/state.db",
            1_784_800_000.0,
        ))
        .unwrap_err();
        assert_eq!(error.kind, "database_unreadable");
    }
}
