//! RFC-4180 CSV parser and Cursor usage CSV normalization (`CursorCSVParser.swift`, `CursorUsageCSV.swift`).

use crate::context::CancelToken;
use crate::pricing::{ModelPricing, TokenBreakdown};
use crate::time::parse_iso8601;
use chrono::{Local, LocalResult, NaiveDateTime, TimeZone};
use std::collections::{HashMap, HashSet};

pub const FUTURE_TOLERANCE_SECONDS: f64 = 5.0 * 60.0;

#[derive(Clone, Debug, PartialEq)]
pub struct CSVScanSummary {
    pub is_structurally_complete: bool,
    pub was_cancelled: bool,
    pub rejected_record_count: usize,
}

#[derive(Clone, Debug, PartialEq)]
pub struct CursorUsageCSVRow {
    pub date: f64,
    pub model: String,
    pub tokens: TokenBreakdown,
    pub imputed_cost_dollars: Option<f64>,
    pub reported_cost_dollars: Option<f64>,
    pub cost_is_opaque_grok_bot: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct CursorUsageCSVParseResult {
    pub rows: Vec<CursorUsageCSVRow>,
    pub rejected_row_count: usize,
    pub unpriced_grok_bot_row_count: usize,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CursorUsageCSVError {
    MalformedCSV,
    MissingColumns(Vec<String>),
    FutureTimestamp,
}

const REQUIRED_COLUMNS: [&str; 6] = [
    "Date",
    "Model",
    "Input (w/ Cache Write)",
    "Input (w/o Cache Write)",
    "Cache Read",
    "Output Tokens",
];

pub fn is_opaque_grok_bot_product_label(raw_model: &str) -> bool {
    let slug = raw_model
        .trim()
        .to_ascii_lowercase()
        .replace(['_', ' '], "-");
    slug == "grok-bot"
        || slug.starts_with("grok-bot-")
        || slug == "grokbot"
        || slug.starts_with("grokbot-")
        || slug == "sand"
        || slug.starts_with("sand-")
}

/// Stream RFC-4180 CSV records with UTF-8 BOM stripping, quoted newlines/commas, `""` unescaping,
/// duplicate-header rejection, width matching, and cooperative cancellation.
pub fn for_each_record(
    csv: &str,
    cancel: &CancelToken,
    mut on_record: impl FnMut(&[(&str, String)], &[String]),
) -> Result<CSVScanSummary, CursorUsageCSVError> {
    for_each_record_with_header(
        csv,
        cancel,
        |_| Ok(()),
        |pairs, headers| on_record(pairs, headers),
    )
}

fn for_each_record_with_header(
    csv: &str,
    cancel: &CancelToken,
    on_header: impl FnOnce(&[String]) -> Result<(), CursorUsageCSVError>,
    mut on_record: impl FnMut(&[(&str, String)], &[String]),
) -> Result<CSVScanSummary, CursorUsageCSVError> {
    if cancel.is_cancelled() {
        return Ok(CSVScanSummary {
            is_structurally_complete: false,
            was_cancelled: true,
            rejected_record_count: 0,
        });
    }
    let mut rows = parse_raw_rows(csv, cancel)?;
    if cancel.is_cancelled() {
        return Ok(CSVScanSummary {
            is_structurally_complete: false,
            was_cancelled: true,
            rejected_record_count: 0,
        });
    }
    if rows.is_empty() {
        return Ok(CSVScanSummary {
            is_structurally_complete: true,
            was_cancelled: false,
            rejected_record_count: 0,
        });
    }

    let mut headers = rows.remove(0);
    if let Some(first) = headers.first_mut() {
        if let Some(stripped) = first.strip_prefix('\u{FEFF}') {
            *first = stripped.to_string();
        }
    }
    let trimmed_headers: Vec<String> = headers.iter().map(|h| h.trim().to_string()).collect();
    let mut seen = HashSet::new();
    for h in &trimmed_headers {
        if !seen.insert(h.as_str()) {
            return Err(CursorUsageCSVError::MalformedCSV);
        }
    }
    on_header(&trimmed_headers)?;

    let mut rejected_record_count = 0usize;
    let mut pairs: Vec<(&str, String)> = Vec::with_capacity(trimmed_headers.len());
    for (idx, row) in rows.into_iter().enumerate() {
        if idx.is_multiple_of(256) && cancel.is_cancelled() {
            return Ok(CSVScanSummary {
                is_structurally_complete: false,
                was_cancelled: true,
                rejected_record_count,
            });
        }
        if row.len() == 1 && row[0].is_empty() && trimmed_headers.len() > 1 {
            continue;
        }
        if row.len() != trimmed_headers.len() {
            rejected_record_count += 1;
            continue;
        }
        pairs.clear();
        for (k, v) in trimmed_headers.iter().zip(row.into_iter()) {
            pairs.push((k.as_str(), v));
        }
        on_record(&pairs, &trimmed_headers);
    }

    Ok(CSVScanSummary {
        is_structurally_complete: true,
        was_cancelled: false,
        rejected_record_count,
    })
}

fn parse_raw_rows(
    csv: &str,
    cancel: &CancelToken,
) -> Result<Vec<Vec<String>>, CursorUsageCSVError> {
    let bytes = csv.as_bytes();
    let mut rows: Vec<Vec<String>> = Vec::new();
    let mut current_row: Vec<String> = Vec::new();
    let mut field = Vec::<u8>::new();
    let mut in_quotes = false;
    let mut at_field_start = true;
    let mut just_closed_quote = false;
    let mut idx = 0usize;
    let mut steps = 0usize;

    while idx < bytes.len() {
        steps += 1;
        if steps.is_multiple_of(8192) && cancel.is_cancelled() {
            return Ok(Vec::new());
        }
        let b = bytes[idx];
        if in_quotes {
            if b == b'"' {
                if idx + 1 < bytes.len() && bytes[idx + 1] == b'"' {
                    field.push(b'"');
                    idx += 2;
                } else {
                    in_quotes = false;
                    just_closed_quote = true;
                    idx += 1;
                }
            } else {
                field.push(b);
                idx += 1;
            }
            continue;
        }

        if just_closed_quote {
            match b {
                b',' => {
                    current_row.push(String::from_utf8_lossy(&field).into_owned());
                    field.clear();
                    at_field_start = true;
                    just_closed_quote = false;
                    idx += 1;
                    continue;
                }
                b'\r' => {
                    current_row.push(String::from_utf8_lossy(&field).into_owned());
                    field.clear();
                    rows.push(std::mem::take(&mut current_row));
                    at_field_start = true;
                    just_closed_quote = false;
                    idx += if idx + 1 < bytes.len() && bytes[idx + 1] == b'\n' {
                        2
                    } else {
                        1
                    };
                    continue;
                }
                b'\n' => {
                    current_row.push(String::from_utf8_lossy(&field).into_owned());
                    field.clear();
                    rows.push(std::mem::take(&mut current_row));
                    at_field_start = true;
                    just_closed_quote = false;
                    idx += 1;
                    continue;
                }
                _ => return Err(CursorUsageCSVError::MalformedCSV),
            }
        }

        match b {
            b'"' => {
                if !at_field_start {
                    return Err(CursorUsageCSVError::MalformedCSV);
                }
                in_quotes = true;
                at_field_start = false;
                idx += 1;
            }
            b',' => {
                current_row.push(String::from_utf8_lossy(&field).into_owned());
                field.clear();
                at_field_start = true;
                idx += 1;
            }
            b'\r' => {
                current_row.push(String::from_utf8_lossy(&field).into_owned());
                field.clear();
                rows.push(std::mem::take(&mut current_row));
                at_field_start = true;
                idx += if idx + 1 < bytes.len() && bytes[idx + 1] == b'\n' {
                    2
                } else {
                    1
                };
            }
            b'\n' => {
                current_row.push(String::from_utf8_lossy(&field).into_owned());
                field.clear();
                rows.push(std::mem::take(&mut current_row));
                at_field_start = true;
                idx += 1;
            }
            _ => {
                at_field_start = false;
                field.push(b);
                idx += 1;
            }
        }
    }

    if in_quotes {
        return Err(CursorUsageCSVError::MalformedCSV);
    }
    if !field.is_empty() || !current_row.is_empty() {
        current_row.push(String::from_utf8_lossy(&field).into_owned());
        rows.push(current_row);
    }
    Ok(rows)
}

pub fn parse_usage_csv(
    csv: &str,
    pricing: &ModelPricing,
    maximum_timestamp: f64,
    cancel: &CancelToken,
) -> Result<CursorUsageCSVParseResult, CursorUsageCSVError> {
    let mut rows = Vec::new();
    let mut rejected_row_count = 0usize;
    let mut has_future_timestamp = false;
    let mut unpriced_grok_bot_row_count = 0usize;
    let summary = for_each_record_with_header(
        csv,
        cancel,
        |headers| {
            let header_set: HashSet<&str> = headers.iter().map(String::as_str).collect();
            let missing: Vec<String> = REQUIRED_COLUMNS
                .iter()
                .filter(|col| !header_set.contains(**col))
                .map(|s| (*s).to_string())
                .collect();
            if !missing.is_empty() {
                return Err(CursorUsageCSVError::MissingColumns(missing));
            }
            Ok(())
        },
        |pairs, _| {
            let map: HashMap<&str, &str> = pairs.iter().map(|(k, v)| (*k, v.as_str())).collect();
            let Some(date_str) = map.get("Date").map(|s| s.trim()).filter(|s| !s.is_empty()) else {
                rejected_row_count += 1;
                return;
            };
            let Some(date) = parse_csv_date(date_str) else {
                rejected_row_count += 1;
                return;
            };
            let model = map.get("Model").map(|s| s.trim()).unwrap_or("").to_string();
            if model.is_empty() {
                rejected_row_count += 1;
                return;
            }

            let Some(cache_write) =
                parse_grouped_token_int(map.get("Input (w/ Cache Write)").copied().unwrap_or(""))
            else {
                rejected_row_count += 1;
                return;
            };
            let Some(input) =
                parse_grouped_token_int(map.get("Input (w/o Cache Write)").copied().unwrap_or(""))
            else {
                rejected_row_count += 1;
                return;
            };
            let Some(cache_read) =
                parse_grouped_token_int(map.get("Cache Read").copied().unwrap_or(""))
            else {
                rejected_row_count += 1;
                return;
            };
            let Some(output) =
                parse_grouped_token_int(map.get("Output Tokens").copied().unwrap_or(""))
            else {
                rejected_row_count += 1;
                return;
            };

            let Some(row_token_count) = cache_write
                .checked_add(input)
                .and_then(|v| v.checked_add(cache_read))
                .and_then(|v| v.checked_add(output))
            else {
                rejected_row_count += 1;
                return;
            };

            let reported_cost_dollars = map.get("Cost").copied().and_then(parse_cost_dollars);
            if row_token_count == 0 && reported_cost_dollars.unwrap_or(0.0) <= 0.0 {
                return;
            }
            if date > maximum_timestamp {
                has_future_timestamp = true;
                return;
            }

            let tokens = TokenBreakdown {
                input,
                cache_write_5m: cache_write,
                cache_write_1h: 0,
                cache_read,
                output,
                is_fast: false,
            };
            let opaque = is_opaque_grok_bot_product_label(&model);
            let imputed_cost_dollars = if opaque {
                unpriced_grok_bot_row_count += 1;
                None
            } else if row_token_count == 0 {
                None
            } else {
                pricing.estimated_cursor_cost_dollars(&model, &tokens, false)
            };

            rows.push(CursorUsageCSVRow {
                date,
                model,
                tokens,
                imputed_cost_dollars,
                reported_cost_dollars,
                cost_is_opaque_grok_bot: opaque,
            });
        },
    )?;

    if !summary.is_structurally_complete {
        return Err(CursorUsageCSVError::MalformedCSV);
    }
    if has_future_timestamp {
        return Err(CursorUsageCSVError::FutureTimestamp);
    }

    Ok(CursorUsageCSVParseResult {
        rows,
        rejected_row_count: rejected_row_count + summary.rejected_record_count,
        unpriced_grok_bot_row_count,
    })
}

fn parse_csv_date(raw: &str) -> Option<f64> {
    if let Some(ts) = parse_iso8601(raw) {
        return Some(ts);
    }
    let naive = NaiveDateTime::parse_from_str(raw, "%Y-%m-%d %H:%M:%S")
        .or_else(|_| NaiveDateTime::parse_from_str(raw, "%Y-%m-%d %H:%M"))
        .ok()?;
    match Local.from_local_datetime(&naive) {
        LocalResult::Single(dt) | LocalResult::Ambiguous(dt, _) => Some(dt.timestamp() as f64),
        LocalResult::None => None,
    }
}

fn parse_grouped_token_int(raw: &str) -> Option<i64> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Some(0);
    }
    if trimmed.contains(',') {
        let mut parts = trimmed.split(',');
        let first = parts.next()?;
        if first.is_empty() || first.len() > 3 || !first.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        let mut rest_count = 0usize;
        for part in parts {
            if part.len() != 3 || !part.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            rest_count += 1;
        }
        if rest_count == 0 {
            return None;
        }
        return trimmed
            .replace(',', "")
            .parse::<i64>()
            .ok()
            .filter(|&v| v >= 0);
    }
    if !trimmed.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    trimmed.parse::<i64>().ok().filter(|&v| v >= 0)
}

fn parse_cost_dollars(raw: &str) -> Option<f64> {
    let trimmed = raw.trim();
    let numeric = trimmed.strip_prefix('$').unwrap_or(trimmed);
    if numeric.is_empty() || !numeric.bytes().all(|b| b.is_ascii_digit() || b == b'.') {
        return None;
    }
    let value = numeric.parse::<f64>().ok()?;
    (value.is_finite() && value >= 0.0).then_some(value)
}
