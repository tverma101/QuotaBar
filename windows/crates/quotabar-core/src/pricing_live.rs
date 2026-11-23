use super::{DEFAULT_PRICING, ModelPricing, ModelRates, PromptRateTier, UTC_DAYS, UtcRateOverride};
use super::fallback::{self, Source};
use serde_json::Value;
use std::collections::HashMap;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

const URL: &str = "https://openrouter.ai/api/v1/models";
const PAGE_LIMIT: usize = 1_000;
const MAX_PAGES: usize = 32;
const MAX_BYTES: u64 = 16 * 1024 * 1024;
const FRESH_FOR: Duration = Duration::from_secs(3600);
const FAILURE_BACKOFF: Duration = Duration::from_secs(1800);
const DISCOVERY_INTERVAL: Duration = Duration::from_secs(300);

type Catalog = HashMap<String, ModelRates>;

struct Refresh {
    directory: PathBuf,
    running: bool,
    attempted: Option<Instant>,
    failed: bool,
    misses: HashMap<String, u8>,
    fallback_due: [Option<Instant>; 3],
}

static REFRESH: OnceLock<Mutex<Refresh>> = OnceLock::new();

pub fn enable_live_pricing(directory: &Path) {
    let pricing = super::default_pricing();
    let _ = REFRESH.set(Mutex::new(Refresh {
        directory: directory.to_path_buf(),
        running: false,
        attempted: None,
        failed: false,
        misses: HashMap::new(),
        fallback_due: [None; 3],
    }));
    schedule_refresh(pricing, None);
}

pub(super) fn schedule_refresh(pricing: &ModelPricing, name: Option<&str>) {
    let Some(mut state) = REFRESH.get().and_then(|s| s.try_lock().ok()) else {
        return;
    };
    if state.running {
        return;
    }
    let elapsed = state.attempted.map(|time| time.elapsed());
    let hourly = elapsed.is_none_or(|age| age >= if state.failed { FAILURE_BACKOFF } else { FRESH_FOR });
    let discovery = !state.failed && elapsed.is_some_and(|age| age >= DISCOVERY_INTERVAL)
        && name.is_some_and(|name| {
            !name.is_empty()
                && name.len() <= super::MAX_CACHED_MODEL_BYTES
                && !pricing.fallback.read().unwrap().supplement(&pricing.supplement).pricing.contains_key(name)
                && !pricing.open_router.read().unwrap().contains_key(name)
                && state.misses.get(name).copied().unwrap_or_default() < 3
                && (state.misses.contains_key(name) || state.misses.len() < 512)
        });
    let now = Instant::now();
    let refresh_open_router = hourly || discovery;
    let due = Source::ALL.map(|source| state.fallback_due[source as usize].is_none_or(|at| at <= now));
    if !refresh_open_router && !due.iter().any(|due| *due) {
        return;
    }
    let discovered = name.filter(|_| discovery).map(str::to_owned);
    let directory = state.directory.clone();
    state.running = true;
    if refresh_open_router {
        state.attempted = Some(now);
    }
    for source in Source::ALL.into_iter().filter(|source| due[*source as usize]) {
        state.fallback_due[source as usize] = Some(now + FAILURE_BACKOFF);
    }
    drop(state);

    let spawned = std::thread::Builder::new().name("pricing-catalog".into()).spawn(move || {
        let pricing = DEFAULT_PRICING.get().unwrap();
        let client = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(30))
            .redirect(reqwest::redirect::Policy::none())
            .build();
        if let Err(error) = &client {
            log::warn!("Could not create pricing HTTP client: {error}");
        }
        if let Ok(client) = &client {
            if refresh_open_router {
                refresh_routes(client, &directory, discovered, pricing);
            }
            for source in Source::ALL.into_iter().filter(|source| due[*source as usize]) {
                let result = fallback::refresh(source, client, &directory, pricing);
                let mut state = REFRESH.get().unwrap().lock().unwrap();
                state.fallback_due[source as usize] = Some(Instant::now() + if result.is_ok() { FRESH_FOR } else { FAILURE_BACKOFF });
                if let Err(error) = result {
                    log::warn!("{source:?} price refresh failed; using last good rates: {error}");
                }
            }
        }
        let mut state = REFRESH.get().unwrap().lock().unwrap();
        state.running = false;
        if refresh_open_router && client.is_err() {
            state.failed = true;
        }
    });
    if let Err(error) = spawned {
        let mut state = REFRESH.get().unwrap().lock().unwrap();
        state.running = false;
        if refresh_open_router {
            state.failed = true;
        }
        log::warn!("Could not start pricing refresh: {error}");
    }
}

fn refresh_routes(client: &reqwest::blocking::Client, directory: &Path, discovered: Option<String>, pricing: &ModelPricing) {
        let result = fetch(client).and_then(|catalog| {
            let changed = *pricing.open_router.read().unwrap() != catalog;
            if changed {
                write_atomic(&cache_path(directory), &serde_json::to_vec(&catalog)?)?;
            }
            Ok((catalog, changed))
        });
        let mut state = REFRESH.get().unwrap().lock().unwrap();
        state.failed = result.is_err();
        match result {
            Ok((catalog, changed)) => {
                state.misses.retain(|name, _| !catalog.contains_key(name));
                if let Some(name) = discovered.filter(|name| !catalog.contains_key(name)) {
                    *state.misses.entry(name).or_default() += 1;
                }
                if changed {
                    pricing.catalog_changed(|| *pricing.open_router.write().unwrap() = catalog);
                }
            }
            Err(error) => log::warn!("OpenRouter price refresh failed; using last good rates: {error}"),
        }
}

fn cache_path(directory: &Path) -> PathBuf {
    directory.join("pricing").join("windows-openrouter-v1.json")
}

pub(super) fn load_cache(directory: &Path) -> Catalog {
    let result = (|| -> anyhow::Result<Catalog> {
        let mut bytes = Vec::new();
        std::fs::File::open(cache_path(directory))?.take(MAX_BYTES + 1).read_to_end(&mut bytes)?;
        anyhow::ensure!(bytes.len() as u64 <= MAX_BYTES, "catalog cache exceeds size limit");
        Ok(serde_json::from_slice(&bytes)?)
    })();
    match result {
        Ok(catalog) => catalog,
        Err(err) => {
            if !err.downcast_ref::<io::Error>().is_some_and(|e| e.kind() == io::ErrorKind::NotFound) {
                log::warn!("Ignoring unreadable OpenRouter price cache: {err}");
            }
            HashMap::new()
        }
    }
}

pub(super) fn write_atomic(path: &Path, data: &[u8]) -> anyhow::Result<()> {
    std::fs::create_dir_all(path.parent().unwrap())?;
    let temp = path.with_extension(format!("{}.tmp", std::process::id()));
    let result = (|| -> anyhow::Result<()> {
        std::fs::write(&temp, data)?;
        std::fs::rename(&temp, path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(temp);
    }
    result
}

fn fetch(client: &reqwest::blocking::Client) -> anyhow::Result<Catalog> {
    read_pages(|offset| {
        let mut bytes = Vec::new();
        client.get(format!("{URL}?limit={PAGE_LIMIT}&offset={offset}"))
            .send()?.error_for_status()?.take(MAX_BYTES + 1).read_to_end(&mut bytes)?;
        anyhow::ensure!(bytes.len() as u64 <= MAX_BYTES, "catalog page exceeds size limit");
        Ok(serde_json::from_slice(&bytes)?)
    })
}

fn read_pages(mut page: impl FnMut(usize) -> anyhow::Result<Value>) -> anyhow::Result<Catalog> {
    let mut routes = Catalog::new();
    let mut offset = 0;
    let mut expected = None;
    for _ in 0..MAX_PAGES {
        let body = page(offset)?;
        let count = body["total_count"].as_u64().and_then(|n| usize::try_from(n).ok());
        let rows = body["data"].as_array().ok_or_else(|| anyhow::anyhow!("missing catalog data"))?;
        let next = body["links"].get("next").ok_or_else(|| anyhow::anyhow!("missing catalog pagination"))?;
        let end = offset + rows.len();
        anyhow::ensure!(count.is_some_and(|n| n >= end) && expected.is_none_or(|n| Some(n) == count)
            && rows.len() <= PAGE_LIMIT, "inconsistent catalog page");
        expected = count;
        for row in rows {
            if let Some((id, rates)) = parse_route(row) {
                routes.entry(id.to_owned()).or_insert(rates);
            }
        }
        if Some(end) == count {
            anyhow::ensure!(next.is_null() && !routes.is_empty(), "catalog did not end cleanly");
            let mut aliases = HashMap::new();
            for (id, rates) in &routes {
                if let Some((_, slug)) = id.split_once('/') {
                    if !slug.is_empty() && !slug.contains(['/', ':']) {
                        let alias = slug.to_ascii_lowercase();
                        aliases.entry(alias).and_modify(|entry| *entry = None).or_insert(Some(rates.clone()));
                    }
                }
            }
            for (alias, rate) in aliases {
                if let Some(rate) = rate {
                    routes.entry(alias).or_insert(rate);
                }
            }
            return Ok(routes);
        }
        let next_offset = next.as_str().and_then(|link| reqwest::Url::parse(link).ok())
            .and_then(|url| url.query_pairs().find(|(key, _)| key == "offset")
                .and_then(|(_, value)| value.parse::<usize>().ok()));
        anyhow::ensure!(next_offset == Some(end) && end > offset, "invalid catalog offset");
        offset = end;
    }
    anyhow::bail!("catalog exceeded pagination limit")
}

fn rate(value: &Value) -> Option<f64> {
    let n = value.as_f64().or_else(|| value.as_str()?.parse().ok())?;
    (n.is_finite() && n >= 0.0 && n <= f64::MAX / 1_000_000.0).then(|| n * 1_000_000.0)
}

fn parse_route(row: &Value) -> Option<(&str, ModelRates)> {
    let id = row["id"].as_str()?.trim();
    if id.is_empty() {
        return None;
    }
    let pricing = &row["pricing"];
    let input = rate(&pricing["prompt"])?;
    let output = rate(&pricing["completion"])?;
    let cache_read = rate(&pricing["input_cache_read"]);
    let mut tiers = Vec::new();
    let mut timed = Vec::new();
    for override_ in pricing["overrides"].as_array().into_iter().flatten() {
        let prompt = rate(&override_["prompt"]);
        let completion = rate(&override_["completion"]);
        let write = rate(&override_["input_cache_write"]);
        let read = rate(&override_["input_cache_read"]);
        let write_1h = rate(&override_["input_cache_write_1h"]);
        if [prompt, completion, write, read, write_1h].iter().all(Option::is_none) {
            continue;
        }
        if let Some(threshold) = override_.get("min_prompt_tokens") {
            if let Some(threshold) = threshold.as_i64().filter(|n| *n >= 0) {
                let slug = id.rsplit('/').next().unwrap_or(id).split(':').next().unwrap_or(id);
                tiers.push(PromptRateTier {
                    threshold_prompt_tokens: threshold,
                    includes_threshold: !(threshold == 272_000 && slug.eq_ignore_ascii_case("gpt-6.1-sol")),
                    input_per_million: prompt,
                    output_per_million: completion,
                    cache_write_per_million: write,
                    cache_read_per_million: read,
                    cache_write_1h_per_million: write_1h,
                });
            }
        } else if let Some((days, start, end)) = utc_window(override_) {
            timed.push(UtcRateOverride {
                utc_days: days,
                utc_start_minute: start,
                utc_end_minute: end,
                input_per_million: prompt,
                output_per_million: completion,
                cache_write_per_million: write,
                cache_read_per_million: read,
                cache_write_1h_per_million: write_1h,
            });
        }
    }
    let cache_read_is_explicit = cache_read.is_some()
        || tiers.iter().any(|tier| tier.cache_read_per_million.is_some())
        || timed.iter().any(|tier| tier.cache_read_per_million.is_some());
    Some((id, ModelRates {
        input_per_million: input,
        output_per_million: output,
        cache_write_per_million: rate(&pricing["input_cache_write"]).unwrap_or(input),
        cache_read_per_million: cache_read.unwrap_or(input),
        cache_write_1h_per_million: rate(&pricing["input_cache_write_1h"]),
        prompt_rate_tiers: tiers,
        utc_rate_overrides: timed,
        input_above_200k: None,
        output_above_200k: None,
        cache_write_above_200k: None,
        cache_read_above_200k: None,
        cache_read_is_explicit,
        long_context_threshold_tokens: 200_000,
        fast_multiplier: 1.0,
    }))
}

type UtcWindow = (Option<Vec<String>>, Option<u32>, Option<u32>);

fn utc_window(value: &Value) -> Option<UtcWindow> {
    let days = match &value["utc_days"] {
        Value::Null => None,
        value => {
            let days: Vec<_> = value.as_array()?.iter()
                .map(|day| Some(day.as_str()?.to_ascii_lowercase()))
                .collect::<Option<_>>()?;
            if days.is_empty() || !days.iter().all(|day| UTC_DAYS.contains(&day.as_str())) {
                return None;
            }
            Some(days)
        }
    };
    let minute = |key| -> Option<Option<u32>> {
        let value = &value[key];
        if value.is_null() {
            return Some(None);
        }
        let time = value.as_u64().or_else(|| value.as_str()?.parse().ok())?;
        (time <= 2400 && time % 100 < 60).then_some(Some((time / 100 * 60 + time % 100) as u32))
    };
    let start = minute("utc_start")?;
    let end = minute("utc_end")?;
    let end = if end == Some(0) && start.is_some_and(|n| n > 0) { Some(1440) } else { end };
    (days.is_some() || start.is_some() || end.is_some()).then_some((days, start, end))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::log_usage_types::TokenBreakdown;
    use serde_json::json;

    fn route(id: &str) -> Value {
        json!({
            "id": id,
            "pricing": {
                "prompt": "0.000002",
                "completion": "0.000004",
                "overrides": [{
                    "utc_days": ["Sunday"], "utc_start": 2300, "utc_end": 100,
                    "prompt": "0.000001", "input_cache_read": "0.0000005",
                    "input_cache_write_1h": "0.000003"
                }]
            }
        })
    }

    #[test]
    fn validates_all_pages_before_returning_routes_and_unique_aliases() {
        let page = |offset| Ok(if offset == 0 {
            json!({"data": [route("one/shared"), route("one/unique")], "total_count": 3,
                "links": {"next": "https://openrouter.ai/api/v1/models?offset=2"}})
        } else {
            json!({"data": [route("two/shared")], "total_count": 3, "links": {"next": null}})
        });
        let catalog = read_pages(page).unwrap();
        assert!(catalog.contains_key("one/shared"));
        assert!(catalog.contains_key("unique"));
        assert!(!catalog.contains_key("shared"));
        assert!(read_pages(|_| page(0)).is_err());
    }

    #[test]
    fn utc_overnight_starts_inclusive_and_ends_exclusive_without_rounding_requests() {
        let value = route("vendor/example");
        let (_, rates) = parse_route(&value).unwrap();
        let tokens = TokenBreakdown {
            input: 1000, output: 1000, cache_read: 1000, cache_write5m: 0,
            cache_write1h: 1000, is_fast: false,
        };
        let cost = |at: &str| rates.cost_dollars_at(&tokens, Some(at.parse().unwrap()), true);
        assert!((cost("2026-11-22T23:00:00Z") - 0.0085).abs() < 1e-12);
        assert!((cost("2026-11-22T19:30:00-05:00") - 0.0085).abs() < 1e-12);
        assert!((cost("2026-11-23T01:00:00Z") - 0.012).abs() < 1e-12);
        assert!((rates.cost_dollars(&tokens) - 0.012).abs() < 1e-12);
    }
}
