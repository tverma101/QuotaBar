use crate::plugin_engine::runtime::{MetricLine, PluginOutput};
use chrono::{DateTime, TimeDelta, Utc};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::io;
use std::path::Path;

pub const CACHE_FILE_NAME: &str = "usage-api-cache.json";
const DEFAULT_ENABLED: &[&str] = &["claude", "codex", "cursor", "freebuff"];
const FRESHNESS: TimeDelta = TimeDelta::minutes(5);

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CachedPluginSnapshot {
    pub provider_id: String,
    pub display_name: String,
    pub plan: Option<String>,
    #[serde(default)]
    pub warning: Option<String>,
    pub lines: Vec<MetricLine>,
    pub fetched_at: String,
}

impl CachedPluginSnapshot {
    pub fn from_output(output: PluginOutput, now: DateTime<Utc>) -> Self {
        Self {
            provider_id: output.provider_id,
            display_name: output.display_name,
            plan: output.plan,
            warning: output.warning,
            lines: output.lines,
            fetched_at: now.to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        }
    }

    pub fn expires_at(&self) -> Option<DateTime<Utc>> {
        self.fetched_at()?
            .checked_add_signed(FRESHNESS)
    }

    pub fn fetched_at(&self) -> Option<DateTime<Utc>> {
        DateTime::parse_from_rfc3339(&self.fetched_at)
            .ok()
            .map(|date| date.with_timezone(&Utc))
    }

    pub fn is_stale(&self, now: DateTime<Utc>) -> bool {
        self.fetched_at().is_none_or(|fetched_at| {
            fetched_at > now || now.signed_duration_since(fetched_at) >= FRESHNESS
        })
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub struct UsageApiCacheFile {
    pub version: u32,
    pub snapshots: HashMap<String, CachedPluginSnapshot>,
}

pub fn read_cache(dir: &Path) -> io::Result<HashMap<String, CachedPluginSnapshot>> {
    let bytes = match std::fs::read(dir.join(CACHE_FILE_NAME)) {
        Ok(bytes) => bytes,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(HashMap::new()),
        Err(err) => return Err(err),
    };
    let file: UsageApiCacheFile = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
    if file.version != 1 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "unsupported usage cache version"));
    }
    Ok(file.snapshots)
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PluginSelection {
    pub order: Vec<String>,
    pub disabled: HashSet<String>,
    pub provider_instances: BTreeMap<String, ProviderInstance>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderInstance {
    pub base_provider_id: String,
    pub label: String,
}

impl PluginSelection {
    pub fn read(dir: &Path) -> io::Result<Self> {
        #[derive(Deserialize)]
        struct Settings {
            plugins: Option<PluginSelection>,
        }
        let bytes = match std::fs::read(dir.join("settings.json")) {
            Ok(bytes) => bytes,
            Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(Self::default()),
            Err(err) => return Err(err),
        };
        let settings: Settings = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
        Ok(settings.plugins.unwrap_or_default())
    }

    pub fn base_id<'a>(&'a self, id: &'a str) -> &'a str {
        self.provider_instances
            .get(id)
            .map_or(id, |instance| instance.base_provider_id.as_str())
    }

    pub fn matching_ids(&self, known_ids: &[String], requested: Option<&str>) -> Vec<String> {
        let known: HashSet<_> = known_ids.iter().map(String::as_str).collect();
        let mut seen = HashSet::new();
        self.order
            .iter()
            .chain(known_ids)
            .chain(self.provider_instances.keys())
            .filter(|id| known.contains(self.base_id(id)) && seen.insert(id.as_str()))
            .filter(|id| {
                let base = self.base_id(id);
                match requested {
                    Some(request) => request == id.as_str() || request == base,
                    None => {
                        !self.disabled.contains(id.as_str())
                            && (self.order.contains(id) || DEFAULT_ENABLED.contains(&base))
                    }
                }
            })
            .cloned()
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::limits_export::limits_from_snapshots;

    #[test]
    fn app_and_cli_expire_the_same_snapshot_at_five_minutes() {
        let output = PluginOutput {
            provider_id: "codex".to_string(),
            display_name: "Codex".to_string(),
            warning: None,
            plan: None,
            lines: Vec::new(),
            icon_url: String::new(),
        };
        let fetched_at = "2026-07-13T09:00:00Z".parse().unwrap();
        let snap = CachedPluginSnapshot::from_output(output, fetched_at);
        let expire = fetched_at + FRESHNESS;
        assert!(snap.is_stale(fetched_at - TimeDelta::seconds(1)));
        assert!(!snap.is_stale(expire - TimeDelta::seconds(1)));
        let limits = limits_from_snapshots([&snap], vec![], expire);
        assert_eq!(limits.providers["codex"].stale, Some(true));
        assert_eq!(limits.providers["codex"].expires_at.as_deref(), Some("2026-07-13T09:05:00Z"));
    }

    #[test]
    fn exact_and_family_matches_include_disabled_accounts_but_default_read_does_not() {
        let settings: PluginSelection = serde_json::from_value(serde_json::json!({
            "order": ["codex:work", "unavailable", "codex"],
            "disabled": ["codex:work"],
            "providerInstances": { "codex:work": { "baseProviderId": "codex", "label": "Work" } }
        })).unwrap();
        let known = ["codex", "freebuff", "cursor", "devin"].map(str::to_string);
        assert_eq!(settings.matching_ids(&known, None), ["codex", "freebuff", "cursor"]);
        assert_eq!(settings.matching_ids(&known, Some("codex")), ["codex:work", "codex"]);
        assert_eq!(settings.matching_ids(&known, Some("codex:work")), ["codex:work"]);
        assert!(settings.matching_ids(&known, Some("unavailable")).is_empty());
    }
}
