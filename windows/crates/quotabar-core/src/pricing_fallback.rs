use super::{
    CURRENT_LITELLM_JSON, MODELS_DEV_JSON, ModelPricing, ModelRates, PricingSupplement,
    PromptRateTier, SUPPLEMENT_JSON, SupplementFile, build_supplement,
};
use chrono::{DateTime, NaiveDate, Utc};
use reqwest::blocking::Client;
use reqwest::header::{ETAG, IF_NONE_MATCH};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::io::Read;
use std::path::{Path, PathBuf};

type Catalog = HashMap<String, ModelRates>;
const FEED_LIMIT: u64 = 32 * 1024 * 1024;

#[derive(Clone, Copy, Debug)]
pub(super) enum Source {
    Supplement,
    LiteLlm,
    ModelsDev,
}

impl Source {
    pub(super) const ALL: [Self; 3] = [Self::Supplement, Self::LiteLlm, Self::ModelsDev];

    fn url(self) -> &'static str {
        match self {
            Self::Supplement => "https://robinebers.github.io/openusage/pricing_supplement.json",
            Self::LiteLlm => "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json",
            Self::ModelsDev => "https://models.dev/api.json",
        }
    }

    fn path(self, base: &Path) -> PathBuf {
        let name = match self {
            Self::Supplement => "windows-supplement-v1.json",
            Self::LiteLlm => "windows-litellm-v1.json",
            Self::ModelsDev => "windows-models-dev-v1.json",
        };
        base.join("pricing").join(name)
    }
}

#[derive(Deserialize, Serialize)]
struct CachedSource {
    retrieved_ms: i64,
    etag: Option<String>,
    body: Value,
}

enum Layer {
    Supplement(PricingSupplement),
    LiteLlm(Catalog),
    ModelsDev(Catalog),
}

#[derive(Default)]
pub(super) struct Fallback {
    supplement: Option<PricingSupplement>,
    primary: Option<Catalog>,
    secondary: Option<Catalog>,
    etags: [Option<String>; 3],
}

impl Fallback {
    pub(super) fn load(directory: &Path, pricing: &ModelPricing) -> Self {
        let mut result = Self::default();
        for source in Source::ALL {
            let file = match std::fs::File::open(source.path(directory)) {
                Ok(file) => file,
                Err(err) if err.kind() == std::io::ErrorKind::NotFound => continue,
                Err(err) => {
                    log::warn!("Could not open {source:?} price cache: {err}");
                    continue;
                }
            };
            let read = (|| -> anyhow::Result<_> {
                let cache: CachedSource = serde_json::from_slice(&read_body(file, FEED_LIMIT * 2)?)?;
                let layer = decode(source, &cache, pricing)?;
                Ok((layer, cache.etag))
            })();
            match read {
                Ok((layer, etag)) => result.set(source, layer, etag),
                Err(err) => log::warn!("Ignoring invalid {source:?} price cache: {err}"),
            }
        }
        result
    }

    fn set(&mut self, source: Source, layer: Layer, etag: Option<String>) {
        match layer {
            Layer::Supplement(value) => self.supplement = Some(value),
            Layer::LiteLlm(value) => self.primary = Some(value),
            Layer::ModelsDev(value) => self.secondary = Some(value),
        }
        self.etags[source as usize] = etag;
    }

    pub(super) fn supplement<'a>(&'a self, bundled: &'a PricingSupplement) -> &'a PricingSupplement {
        self.supplement.as_ref().unwrap_or(bundled)
    }

    pub(super) fn primary<'a>(&'a self, bundled: &'a Catalog) -> &'a Catalog {
        self.primary.as_ref().unwrap_or(bundled)
    }

    pub(super) fn secondary<'a>(&'a self, bundled: &'a Catalog) -> &'a Catalog {
        self.secondary.as_ref().unwrap_or(bundled)
    }
}

pub(super) fn refresh(source: Source, client: &Client, directory: &Path, pricing: &ModelPricing) -> anyhow::Result<()> {
    let etag = pricing.fallback.read().unwrap().etags[source as usize].clone();
    let mut request = client.get(source.url());
    if let Some(value) = etag.as_ref() {
        request = request.header(IF_NONE_MATCH, value);
    }
    let response = request.send()?;
    if response.status() == reqwest::StatusCode::NOT_MODIFIED && etag.is_some() {
        return Ok(());
    }
    anyhow::ensure!(response.status() == reqwest::StatusCode::OK, "HTTP {}", response.status());
    let etag = response.headers().get(ETAG).and_then(|value| value.to_str().ok()).map(str::to_owned);
    let body = serde_json::from_slice(&read_body(response, FEED_LIMIT)?)?;
    let cache = CachedSource { retrieved_ms: Utc::now().timestamp_millis(), etag, body };
    let layer = decode(source, &cache, pricing)?;
    super::live::write_atomic(&source.path(directory), &serde_json::to_vec(&cache)?)?;
    pricing.catalog_changed(|| pricing.fallback.write().unwrap().set(source, layer, cache.etag));
    Ok(())
}

fn read_body(input: impl Read, limit: u64) -> anyhow::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    input.take(limit + 1).read_to_end(&mut bytes)?;
    anyhow::ensure!(bytes.len() as u64 <= limit, "price source exceeds size limit");
    Ok(bytes)
}

fn decode(source: Source, cache: &CachedSource, pricing: &ModelPricing) -> anyhow::Result<Layer> {
    let body = &cache.body;
    match source {
        Source::Supplement => {
            let live: SupplementFile = SupplementFile::deserialize(body)?;
            anyhow::ensure!(!live.pricing.is_empty(), "no supplement prices");
            anyhow::ensure!(live.pricing.values().all(|entry| {
                [Some(entry.input_per_million), Some(entry.output_per_million),
                    entry.cache_write_per_million, entry.cache_read_per_million]
                    .into_iter().flatten().all(|rate| (0.0..=1_000_000_000.0).contains(&rate))
            }), "invalid supplement rate");
            Ok(Layer::Supplement(merge_supplement(live)?))
        }
        Source::LiteLlm => {
            let entries = lite_llm(body)?;
            Ok(Layer::LiteLlm(merge_catalog(pricing.primary.clone(), entries, cache.retrieved_ms, CURRENT_LITELLM_JSON)))
        }
        Source::ModelsDev => {
            let (entries, conflicts) = models_dev(body)?;
            let mut bundled = pricing.secondary.clone();
            let meta: SnapshotMetadata = serde_json::from_str(MODELS_DEV_JSON)?;
            if date(meta.retrieved_at.as_deref()).is_some_and(|at| at.timestamp_millis() > cache.retrieved_ms) {
                bundled.retain(|id, _| !conflicts.contains(id));
                let mut entries = entries;
                entries.extend(bundled);
                for id in meta.retired {
                    entries.remove(&id);
                }
                Ok(Layer::ModelsDev(entries))
            } else {
                bundled.extend(entries);
                for id in conflicts {
                    bundled.remove(&id);
                }
                Ok(Layer::ModelsDev(bundled))
            }
        }
    }
}

#[derive(Default, Deserialize)]
struct SnapshotMetadata {
    retrieved_at: Option<String>,
    #[serde(default)]
    retired: Vec<String>,
}

fn date(value: Option<&str>) -> Option<DateTime<Utc>> {
    let value = value?;
    DateTime::parse_from_rfc3339(value).map(|at| at.to_utc()).ok().or_else(|| {
        NaiveDate::parse_from_str(value, "%Y-%m-%d").ok()?.and_hms_opt(0, 0, 0).map(|at| at.and_utc())
    })
}

fn merge_catalog(mut bundled: Catalog, mut live: Catalog, retrieved_ms: i64, snapshot: &str) -> Catalog {
    let meta: SnapshotMetadata = serde_json::from_str(snapshot).unwrap_or_default();
    if date(meta.retrieved_at.as_deref()).is_some_and(|at| at.timestamp_millis() > retrieved_ms) {
        live.extend(bundled);
        live
    } else {
        bundled.extend(live);
        bundled
    }
}

fn merge_supplement(live: SupplementFile) -> anyhow::Result<PricingSupplement> {
    let bundled: SupplementFile = serde_json::from_str(SUPPLEMENT_JSON)?;
    let bundled_time = date(bundled.updated_at.as_deref());
    let live_time = date(live.updated_at.as_deref());
    let preserve_bundle_alias_retirements = live_time <= bundled_time || live.retired_alias_patterns.is_none();
    let keep_retired_keys = bundled.retired_pricing_keys.clone();
    let keep_retired_aliases = bundled.retired_alias_patterns.clone().unwrap_or_default();
    let (mut base, newer) = if bundled_time > live_time { (live, bundled) } else { (bundled, live) };
    base.pricing.extend(newer.pricing);
    base.fast_multipliers.extend(newer.fast_multipliers);
    base.retired_pricing_keys.extend(newer.retired_pricing_keys);
    base.retired_pricing_keys.extend(keep_retired_keys);
    let mut aliases = newer.alias_rules;
    let mut seen: HashSet<_> = aliases.iter().map(|rule| rule.pattern.clone()).collect();
    aliases.extend(base.alias_rules.into_iter().filter(|rule| seen.insert(rule.pattern.clone())));
    let mut retired = if let Some(newer_retired) = newer.retired_alias_patterns {
        newer_retired
    } else {
        base.retired_alias_patterns.take().unwrap_or_default()
    };
    if preserve_bundle_alias_retirements {
        retired.extend(keep_retired_aliases);
    }
    base.alias_rules = aliases;
    base.retired_alias_patterns = Some(retired);
    Ok(build_supplement(base))
}

fn numeric_rate(value: &Value, multiplier: f64) -> Option<f64> {
    let rate = value.as_f64()?;
    (rate >= 0.0 && rate <= 1_000_000_000.0 / multiplier).then_some(rate * multiplier)
}

fn rates(input: f64, output: f64, write: Option<f64>, read: Option<f64>, tiers: Vec<PromptRateTier>) -> ModelRates {
    let explicit = read.is_some() || tiers.iter().any(|tier| tier.cache_read_per_million.is_some());
    ModelRates {
        input_per_million: input, output_per_million: output,
        cache_write_per_million: write.unwrap_or(input), cache_read_per_million: read.unwrap_or(input),
        cache_write_1h_per_million: None, prompt_rate_tiers: tiers, utc_rate_overrides: Vec::new(),
        input_above_200k: None, output_above_200k: None, cache_write_above_200k: None,
        cache_read_above_200k: None, cache_read_is_explicit: explicit,
        long_context_threshold_tokens: 200_000, fast_multiplier: 1.0,
    }
}

fn lite_llm(body: &Value) -> anyhow::Result<Catalog> {
    let keys = ["input_cost_per_token", "output_cost_per_token", "cache_creation_input_token_cost", "cache_read_input_token_cost"];
    let entries: Catalog = body.as_object().ok_or_else(|| anyhow::anyhow!("invalid LiteLLM feed"))?
        .iter().filter_map(|(id, row)| {
            let rate = |value: &Value| numeric_rate(value, 1_000_000.0);
            let [input, output, write, read] = keys.map(|key| rate(&row[key]));
            let tiers = [100_000, 128_000, 200_000, 272_000, 512_000].into_iter()
                .filter_map(|threshold| {
                    let values = keys.map(|key| rate(&row[format!("{key}_above_{}k_tokens", threshold / 1000)]));
                    tier(threshold, false, values)
                }).collect();
            let mut rates = rates(input?, output?, write, read, tiers);
            rates.fast_multiplier = row["provider_specific_entry"]["fast"].as_f64()
                .filter(|value| value.is_finite() && *value > 0.0).unwrap_or(1.0);
            Some((id.clone(), rates))
        }).collect();
    anyhow::ensure!(!entries.is_empty(), "no usable LiteLLM prices");
    Ok(entries)
}

fn models_dev(body: &Value) -> anyhow::Result<(Catalog, HashSet<String>)> {
    let keys = ["input", "output", "cache_write", "cache_read"];
    let mut entries: Catalog = HashMap::new();
    let mut retired = HashSet::new();
    for provider in body.as_object().ok_or_else(|| anyhow::anyhow!("invalid models.dev feed"))?.values() {
        for (id, row) in provider["models"].as_object().into_iter().flatten() {
            if retired.contains(id) {
                continue;
            }
            let cost = &row["cost"];
            let rates_at = |value: &Value| keys.map(|key| numeric_rate(&value[key], 1.0));
            let [Some(input), Some(output), write, read] = rates_at(cost) else { continue; };
            let mut tiers: Vec<_> = cost["tiers"].as_array().into_iter().flatten().filter_map(|value| {
                let context = &value["tier"];
                if context["type"].as_str() != Some("context") { return None; }
                tier(context["size"].as_i64()?, true, rates_at(value))
            }).collect();
            if !tiers.iter().any(|tier| tier.threshold_prompt_tokens == 200_000) {
                tiers.extend(tier(200_000, true, rates_at(&cost["context_over_200k"])));
            }
            tiers.sort_by_key(|tier| tier.threshold_prompt_tokens);
            let rate = rates(input, output, write, read, tiers);
            if let Some(existing) = entries.get(id) {
                if *existing != rate {
                    entries.remove(id);
                    retired.insert(id.clone());
                }
            } else {
                entries.insert(id.clone(), rate);
            }
        }
    }
    anyhow::ensure!(!entries.is_empty(), "no usable models.dev prices");
    Ok((entries, retired))
}

fn tier(threshold: i64, includes_threshold: bool, [input, output, write, read]: [Option<f64>; 4]) -> Option<PromptRateTier> {
    (threshold >= 0 && [input, output, write, read].into_iter().any(|rate| rate.is_some())).then_some(PromptRateTier {
        threshold_prompt_tokens: threshold, includes_threshold,
        input_per_million: input, output_per_million: output,
        cache_write_per_million: write, cache_read_per_million: read, cache_write_1h_per_million: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn cached_litellm_rates_restore_with_etag_and_threshold() {
        let pricing = ModelPricing::from_bundled();
        let temp = tempfile::tempdir().unwrap();
        let source = Source::LiteLlm;
        let cache = CachedSource {
            retrieved_ms: date(Some("2030-01-01T00:00:00Z")).unwrap().timestamp_millis(),
            etag: Some("\"fixture\"".into()),
            body: json!({
                "fixture/test": {
                    "input_cost_per_token": 0.000001,
                    "output_cost_per_token": 0.000002,
                    "input_cost_per_token_above_272k_tokens": 0.000003
                },
                "unusable": {"input_cost_per_token": -1, "output_cost_per_token": 0}
            }),
        };
        super::super::live::write_atomic(&source.path(temp.path()), &serde_json::to_vec(&cache).unwrap()).unwrap();
        let restored = Fallback::load(temp.path(), &pricing);
        let rates = &restored.primary(&pricing.primary)["fixture/test"];
        assert_eq!(rates.input_per_million, 1.0);
        assert_eq!(rates.prompt_rate_tiers[0].threshold_prompt_tokens, 272_000);
        assert!(!rates.prompt_rate_tiers[0].includes_threshold);
        assert_eq!(restored.etags[source as usize].as_deref(), Some("\"fixture\""));
        assert!(!restored.primary(&pricing.primary).contains_key("unusable"));
    }

    #[test]
    fn model_conflicts_retire_existing_bundle_rates() {
        let mut pricing = ModelPricing::from_bundled();
        pricing.secondary.insert("collision".into(), rates(1.0, 2.0, None, None, vec![]));
        let cache = CachedSource {
            retrieved_ms: date(Some("2030-01-01T00:00:00Z")).unwrap().timestamp_millis(),
            etag: None,
            body: json!({
                "vendor_a": {"models": {
                    "collision": {"cost": {"input": 1, "output": 2}},
                    "new-model": {"cost": {"input": 3, "output": 6}}
                }},
                "vendor_b": {"models": {
                    "collision": {"cost": {"input": 4, "output": 2}}
                }}
            }),
        };
        let Layer::ModelsDev(merged) = decode(Source::ModelsDev, &cache, &pricing).unwrap() else {
            panic!("expected models.dev layer");
        };
        assert!(!merged.contains_key("collision"));
        assert_eq!(merged["new-model"].input_per_million, 3.0);
    }
}
