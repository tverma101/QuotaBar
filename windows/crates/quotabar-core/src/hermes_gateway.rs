use crate::log_usage_types::{TokenBreakdown, expand_tilde};
use crate::model_pricing::default_pricing;
use rusqlite::{Connection, OpenFlags};
use serde_json::{Value, json};

pub fn scan(enabled: bool) -> rusqlite::Result<Vec<Value>> {
    if !enabled {
        return Ok(vec![]);
    }
    let home = std::env::var("HERMES_HOME").ok();
    let path = expand_tilde(home.as_deref().map(str::trim).filter(|s| !s.is_empty()).unwrap_or("~/.hermes"))
        .join("state.db");
    if !path.exists() {
        return Ok(vec![]);
    }
    let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    let mut stmt = conn.prepare(
        "SELECT started_at, model, billing_provider, billing_base_url,
                COALESCE(input_tokens,0), COALESCE(output_tokens,0), COALESCE(cache_read_tokens,0),
                COALESCE(cache_write_tokens,0), COALESCE(reasoning_tokens,0)
         FROM sessions WHERE started_at >= ?1
           AND (LOWER(billing_provider) LIKE 'opencode%' OR LOWER(billing_base_url) LIKE '%opencode%')",
    )?;
    let cutoff = crate::log_usage_types::since_local_midnight(3653).timestamp();
    let max = chrono::Utc::now().timestamp_millis() + 300_000;
    let rows = stmt.query_map([cutoff], |row| {
        let created = row.get::<_, f64>(0)? * 1000.0;
        let model = row.get::<_, Option<String>>(1)?;
        let provider = row.get::<_, Option<String>>(2)?;
        let url = row.get::<_, Option<String>>(3)?;
        let input = row.get::<_, i64>(4)?;
        let output = row.get::<_, i64>(5)?;
        let cache_read = row.get::<_, i64>(6)?;
        let cache_write = row.get::<_, i64>(7)?;
        let reasoning = row.get::<_, i64>(8)?;
        if [input, output, cache_read, cache_write, reasoning].iter().any(|value| !(0..=1_000_000_000_000_000).contains(value)) {
            return Err(rusqlite::Error::InvalidQuery);
        }
        let tokens = input + output + cache_read + cache_write + reasoning;
        if tokens == 0 {
            return Ok(None);
        }
        if !created.is_finite() || created > max as f64 {
            return Err(rusqlite::Error::InvalidQuery);
        }
        let price = model.and_then(|model| default_pricing().estimated_cost_dollars(&model, &TokenBreakdown {
            input: i32::try_from(input).ok()?,
            output: i32::try_from(output + reasoning).ok()?,
            cache_read: i32::try_from(cache_read).ok()?,
            cache_write5m: i32::try_from(cache_write).ok()?,
            ..TokenBreakdown::default()
        }));
        Ok(Some(json!({ "createdMs": created, "tokens": tokens, "cost": price,
            "go": uses_go(provider.as_deref(), url.as_deref()) })))
    })?;
    rows.collect::<rusqlite::Result<Vec<_>>>().map(|rows| rows.into_iter().flatten().collect())
}

fn uses_go(provider: Option<&str>, url: Option<&str>) -> bool {
    match provider.map(str::trim).map(str::to_ascii_lowercase).as_deref() {
        Some("opencode-go") => true,
        Some("opencode") => false,
        _ => {
            let Some(url) = url.map(str::trim) else { return false };
            let url = if url.contains("://") { url.to_string() } else { format!("https://{url}") };
            reqwest::Url::parse(&url).is_ok_and(|url|
                url.host_str() == Some("opencode.ai") && url.path().trim_matches('/').eq_ignore_ascii_case("zen/go/v1"))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zen_provider_takes_precedence_over_go_url() {
        let go = Some("https://opencode.ai/zen/go/v1");
        assert!(!uses_go(Some("opencode"), go));
        assert!(uses_go(None, go));
        assert!(uses_go(Some("OPENCODE-GO"), None));
        assert!(!uses_go(None, Some("https://opencode.ai.example.org/zen/go/v1")));
    }
}
