//! Read-only display overlay for locally delivered VM Box accounting receipts.

use crate::usage_daily::UsageDailyRow;
use chrono::{DateTime, NaiveDate, TimeDelta, Utc};
use serde::Deserialize;
use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};

const MAX_FILES: usize = 16;
const MAX_BYTES: u64 = 2_097_152;
const MAX_DAYS_PER_PROVIDER: usize = 500;
const MAX_AGE: TimeDelta = TimeDelta::minutes(5);
const POLL_INTERVAL: Duration = Duration::from_secs(30);
#[cfg(windows)]
const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x00200000;
#[cfg(windows)]
const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Receipt {
    schema: String,
    #[serde(rename = "deviceID")]
    device_id: String,
    device_name: String,
    updated_at: DateTime<Utc>,
    providers: BTreeMap<String, ProviderHistory>,
    #[serde(default)]
    vmbox_accounts: BTreeMap<String, String>,
    #[serde(default)]
    vmbox_fetched_at: BTreeMap<String, DateTime<Utc>>,
    #[serde(default)]
    vmbox_warnings: BTreeMap<String, String>,
}

#[derive(Deserialize)]
struct ProviderHistory {
    series: DailySeries,
}

#[derive(Deserialize)]
struct DailySeries {
    daily: Vec<Day>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Day {
    date: String,
    total_tokens: i64,
    #[serde(rename = "costUSD")]
    cost_usd: Option<f64>,
    #[serde(default)]
    cost_is_complete: bool,
}

struct RetainedReceipt {
    receipt: Receipt,
    invalid_replacement: bool,
    stamp: (SystemTime, u64),
}

pub struct ReceiptCache {
    directory: PathBuf,
    files: BTreeMap<PathBuf, RetainedReceipt>,
    last_poll: Option<Instant>,
}

impl ReceiptCache {
    pub fn new(directory: PathBuf) -> Self {
        Self { directory, files: BTreeMap::new(), last_poll: None }
    }

    fn poll(&mut self, now: DateTime<Utc>) {
        if self.last_poll.is_some_and(|last| last.elapsed() < POLL_INTERVAL) {
            return;
        }
        self.last_poll = Some(Instant::now());

        let paths = match receipt_paths(&self.directory) {
            Ok(paths) => paths,
            Err(error) => {
                log::warn!("Could not read VM Box receipts; retaining the last valid totals: {error}");
                for file in self.files.values_mut() {
                    file.invalid_replacement = true;
                }
                return;
            }
        };
        self.files.retain(|path, _| paths.contains(path));
        for path in paths {
            match read_receipt(&path, self.files.get(&path), now) {
                Ok(Some((receipt, stamp))) => {
                    self.files.insert(path, RetainedReceipt { receipt, invalid_replacement: false, stamp });
                }
                Ok(None) => {}
                Err(_) => {
                    log::warn!("Ignoring invalid VM Box receipt; retaining any last valid totals");
                    if let Some(file) = self.files.get_mut(&path) {
                        file.invalid_replacement = true;
                    }
                }
            }
        }
    }

    pub fn read_rows(
        &mut self,
        providers: &BTreeMap<String, String>,
        verified_identities: &BTreeMap<String, String>,
        instance_id: Option<&str>,
        now: DateTime<Utc>,
    ) -> Vec<UsageDailyRow> {
        self.poll(now);
        let mut newest = BTreeMap::<&str, &RetainedReceipt>::new();
        for file in self.files.values() {
            let receipt = &file.receipt;
            if newest.get(receipt.device_id.as_str()).is_none_or(|old| old.receipt.updated_at < receipt.updated_at) {
                newest.insert(&receipt.device_id, file);
            }
        }

        let mut rows = Vec::new();
        for file in newest.values() {
            let receipt = &file.receipt;
            for (family, history) in &receipt.providers {
                let Some(id) = receipt_target(family, receipt, providers, verified_identities) else {
                    continue;
                };
                if instance_id.is_some_and(|requested| requested != id) {
                    continue;
                }
                let Some(display_name) = providers.get(id) else { continue };
                let fetched_at = receipt.vmbox_fetched_at.get(family).copied().unwrap_or(receipt.updated_at);
                let outdated = now.signed_duration_since(fetched_at) > MAX_AGE
                    || file.invalid_replacement || receipt.vmbox_warnings.contains_key(family);
                rows.extend(history.series.daily.iter().map(|day| UsageDailyRow {
                    instance_id: id.to_string(),
                    day_key: day.date.clone(),
                    display_name: display_name.clone(),
                    total_tokens: Some(day.total_tokens),
                    input_tokens: None,
                    output_tokens: None,
                    cost_usd: day.cost_usd.filter(|_| day.cost_is_complete),
                    source: if outdated { "vmbox_stale" } else { "vmbox" }.into(),
                    ingested_at_ms: fetched_at.timestamp_millis(),
                }));
            }
        }
        rows
    }

    pub fn has_account_receipts(&mut self, now: DateTime<Utc>) -> bool {
        self.poll(now);
        self.files.values().any(|file| {
            ["claude", "codex"].into_iter().any(|family| {
                file.receipt.providers.contains_key(family)
                    && file.receipt.vmbox_accounts.get(family).is_some_and(|key| !key.is_empty())
            })
        })
    }
}

fn receipt_target<'a>(
    family: &'a str,
    receipt: &Receipt,
    providers: &BTreeMap<String, String>,
    verified_identities: &'a BTreeMap<String, String>,
) -> Option<&'a str> {
    match family {
        "zai" | "antigravity" | "opencode" => Some(family),
        "claude" | "codex" => {
            let account = receipt.vmbox_accounts.get(family).filter(|key| !key.is_empty())?;
            let mut matches = verified_identities.iter().filter(|(id, key)| {
                providers.contains_key(*id)
                    && id.split(':').next() == Some(family)
                    && key.eq_ignore_ascii_case(account)
            });
            let (id, _) = matches.next()?;
            matches.next().is_none().then_some(id)
        }
        _ => None,
    }
}

fn receipt_paths(dir: &Path) -> io::Result<Vec<PathBuf>> {
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error),
    };
    let mut paths = Vec::new();
    for entry in entries {
        let entry = entry?;
        let name = entry.file_name();
        if name.to_str().is_some_and(|n| n.starts_with("vmbox-") && n.ends_with(".json")) {
            paths.push(entry.path());
            if paths.len() > MAX_FILES {
                return Err(io::Error::other("too many VM Box receipts"));
            }
        }
    }
    Ok(paths)
}

fn read_receipt(
    path: &Path,
    previous: Option<&RetainedReceipt>,
    now: DateTime<Utc>,
) -> io::Result<Option<(Receipt, (SystemTime, u64))>> {
    #[cfg(windows)]
    let file = {
        use std::os::windows::fs::OpenOptionsExt;
        fs::OpenOptions::new().read(true).custom_flags(FILE_FLAG_OPEN_REPARSE_POINT).open(path)?
    };
    #[cfg(not(windows))]
    let file = {
        if !fs::symlink_metadata(path)?.is_file() {
            return Err(io::Error::other("receipt is not a regular file"));
        }
        fs::File::open(path)?
    };
    let metadata = file.metadata()?;
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            return Err(io::Error::other("receipt is a reparse point"));
        }
    }
    if !metadata.is_file() || metadata.len() > MAX_BYTES {
        return Err(io::Error::other("receipt is not a bounded regular file"));
    }
    let stamp = (metadata.modified()?, metadata.len());
    if previous.is_some_and(|previous| !previous.invalid_replacement && previous.stamp == stamp) {
        return Ok(None);
    }
    let mut bytes = Vec::new();
    file.take(MAX_BYTES + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_BYTES {
        return Err(io::Error::other("receipt exceeded the byte limit"));
    }
    let mut receipt: Receipt = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
    if receipt.schema != "openusage.history.v1"
        || !receipt.device_id.starts_with("vmbox-")
        || receipt.device_name.trim().is_empty()
        || receipt.updated_at > now + MAX_AGE
        || receipt.vmbox_fetched_at.values().any(|stamp| *stamp > now + MAX_AGE)
    {
        return Err(io::Error::other("invalid VM Box receipt header"));
    }
    for history in receipt.providers.values_mut() {
        let mut dates = HashSet::new();
        for day in &history.series.daily {
            let valid_date = NaiveDate::parse_from_str(&day.date, "%Y-%m-%d")
                .is_ok_and(|parsed| parsed.format("%Y-%m-%d").to_string() == day.date);
            if !valid_date || !dates.insert(&day.date) || day.total_tokens < 0
                || day.cost_usd.is_some_and(|cost| !cost.is_finite() || cost < 0.0)
            {
                return Err(io::Error::other("invalid VM Box receipt day"));
            }
        }
        history.series.daily.sort_unstable_by(|a, b| b.date.cmp(&a.date));
        history.series.daily.truncate(MAX_DAYS_PER_PROVIDER);
    }
    receipt.providers.retain(|id, _| matches!(id.as_str(), "zai" | "antigravity" | "opencode" | "claude" | "codex"));
    Ok(Some((receipt, stamp)))
}

pub fn overlay_daily_rows(
    local: Vec<UsageDailyRow>,
    imported: Vec<UsageDailyRow>,
    limit: u32,
) -> Vec<UsageDailyRow> {
    if imported.is_empty() {
        return local;
    }
    let mut rows: BTreeMap<_, _> = local.into_iter()
        .map(|row| ((row.instance_id.clone(), row.day_key.clone()), row)).collect();
    for vm in imported {
        let existing = rows.entry((vm.instance_id.clone(), vm.day_key.clone()));
        existing.and_modify(|row| {
            row.total_tokens = row.total_tokens.zip(vm.total_tokens)
                .map(|(a, b)| a.saturating_add(b));
            row.input_tokens = None;
            row.output_tokens = None;
            row.cost_usd = row.cost_usd.zip(vm.cost_usd)
                .map(|(a, b)| a + b).filter(|cost| cost.is_finite());
            if row.source != "vmbox_stale" {
                row.source.clone_from(&vm.source);
            }
            row.ingested_at_ms = row.ingested_at_ms.max(vm.ingested_at_ms);
        }).or_insert(vm);
    }
    let mut rows: Vec<_> = rows.into_values().collect();
    rows.sort_by(|a, b| b.day_key.cmp(&a.day_key).then_with(|| a.instance_id.cmp(&b.instance_id)));
    rows.truncate(limit.clamp(1, MAX_DAYS_PER_PROVIDER as u32) as usize);
    rows
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn now() -> DateTime<Utc> {
        "2026-07-13T09:00:00Z".parse().unwrap()
    }

    fn fixture(device: &str, at: DateTime<Utc>, tokens: i64) -> Vec<u8> {
        let provider = json!({ "series": { "daily": [{ "date": "2026-07-13", "totalTokens": tokens }] } });
        serde_json::to_vec(&json!({
            "schema": "openusage.history.v1",
            "deviceID": device,
            "deviceName": "Fixture VM",
            "updatedAt": at,
            "providers": { "zai": provider, "claude": provider, "codex": provider, "cursor": provider },
            "vmboxAccounts": { "claude": "canonical-work", "codex": "canonical-personal" },
        })).unwrap()
    }

    #[test]
    fn newest_receipt_per_device_is_merged_without_inventing_prices_or_quota() {
        let temp = tempfile::tempdir().unwrap();
        let dir = temp.path();
        fs::write(dir.join("vmbox-a.json"), fixture("vmbox-one", now() - TimeDelta::minutes(1), 10)).unwrap();
        fs::write(dir.join("vmbox-b.json"), fixture("vmbox-one", now(), 20)).unwrap();
        fs::write(dir.join("vmbox-c.json"), fixture("vmbox-two", now(), 30)).unwrap();
        let mut cache = ReceiptCache::new(dir.into());
        let providers = BTreeMap::from([
            ("claude".into(), "Claude".into()),
            ("claude:work".into(), "Claude (Work)".into()),
            ("cursor".into(), "Cursor".into()),
            ("zai".into(), "Z.ai".into()),
        ]);
        let mut identities = BTreeMap::from([("claude:work".into(), "CANONICAL-WORK".into())]);
        let rows = overlay_daily_rows(vec![], cache.read_rows(&providers, &identities, None, now()), 120);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].instance_id, "claude:work");
        assert_eq!(rows[1].instance_id, "zai");
        assert!(rows.iter().all(|r| r.total_tokens == Some(50) && r.cost_usd.is_none()));

        identities.insert("claude".into(), "canonical-work".into());
        assert!(cache.read_rows(&providers, &identities, Some("claude:work"), now()).is_empty());
        assert!(cache.read_rows(&providers, &BTreeMap::new(), Some("claude:work"), now()).is_empty());
    }

    #[test]
    fn invalid_replacement_and_offline_receipt_keep_last_good_totals() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("vmbox-a.json");
        let mut cache = ReceiptCache::new(temp.path().into());
        let providers = BTreeMap::from([("zai".into(), "Z.ai".into())]);
        let no_identities = BTreeMap::new();
        fs::write(&path, fixture("vmbox-one", now(), 20)).unwrap();
        assert_eq!(cache.read_rows(&providers, &no_identities, None, now())[0].source, "vmbox");

        fs::write(path, fixture("vmbox-one", now(), -100)).unwrap();
        cache.last_poll = None;
        let invalid = cache.read_rows(&providers, &no_identities, None, now());
        assert_eq!(invalid[0].total_tokens, Some(20));
        assert_eq!(invalid[0].source, "vmbox_stale");

        let offline = cache.read_rows(&providers, &no_identities, None, now() + TimeDelta::minutes(6));
        assert_eq!(offline[0].source, "vmbox_stale");
    }

    #[test]
    fn codex_matches_only_a_verified_identity_in_its_own_family() {
        let temp = tempfile::tempdir().unwrap();
        fs::write(temp.path().join("vmbox-a.json"), fixture("vmbox-one", now(), 20)).unwrap();
        let providers = BTreeMap::from([
            ("codex".into(), "Codex".into()),
            ("codex:personal".into(), "Codex (Personal)".into()),
        ]);
        let mut cache = ReceiptCache::new(temp.path().into());
        assert!(cache.has_account_receipts(now()));
        let verified = BTreeMap::from([
            ("codex".into(), "other".into()),
            ("codex:personal".into(), "canonical-personal".into()),
            ("claude:personal".into(), "canonical-personal".into()),
        ]);
        let rows = cache.read_rows(&providers, &verified, None, now());
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].instance_id, "codex:personal");
    }

    #[test]
    fn excess_files_and_bytes_are_rejected() {
        let temp = tempfile::tempdir().unwrap();
        let dir = temp.path();
        for i in 0..=MAX_FILES {
            fs::write(dir.join(format!("vmbox-{i}.json")), []).unwrap();
        }
        assert!(receipt_paths(dir).is_err());
        let path = dir.join("vmbox-0.json");
        fs::OpenOptions::new().write(true).open(&path).unwrap().set_len(MAX_BYTES + 1).unwrap();
        assert!(read_receipt(&path, None, now()).is_err());
    }
}
