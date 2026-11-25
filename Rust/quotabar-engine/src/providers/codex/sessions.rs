//! Codex rollout discovery and native session accounting (Swift `CodexLogUsageScanner`).
//!
//! The line parser and parser state already live in `rollout_parse` / `rollout_state`; this module
//! adds the shared incremental scanner, home/peer attribution, deduplication and the priced fold.

use super::event::Event;
use super::rollout_parse::CodexLineParser;
use crate::accounting::{day_key, DailyUsageAccumulator, LogUsageScan, RowOptions};
use crate::context::CancelToken;
use crate::model::ModelUsageEntry;
use crate::pricing::{ModelPricing, ModelRates, TokenBreakdown};
use crate::providers::claude::gateway::is_hosted_gateway_model;
use crate::scan::{
    discover_all, first_future_dated, DiscoveredFile, Extensions, IncrementalScanner, ScanStore,
};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

#[derive(Clone, Debug, PartialEq)]
pub enum CodexScanResult {
    Complete(Option<LogUsageScan>),
    Incomplete,
}

/// Per-file account attribution for a shared `~/.codex` tree. A rollout names its creator in
/// `session_meta.payload.creator_account_id`; files under `home` are kept only for `identity` (plus
/// unattributed files when `keeps_unattributed`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SharedAttribution {
    pub home: PathBuf,
    pub identity: String,
    pub keeps_unattributed: bool,
}

pub struct CodexSessionScanner {
    homes: Vec<PathBuf>,
    peer_homes: Vec<PathBuf>,
    default_home: PathBuf,
    shared_attribution: Option<SharedAttribution>,
    scanner: Arc<IncrementalScanner<CodexLineParser>>,
}

impl CodexSessionScanner {
    pub fn new(
        home: PathBuf,
        homes: Vec<PathBuf>,
        peer_homes: Vec<PathBuf>,
        shared_attribution: Option<SharedAttribution>,
    ) -> Self {
        let default_home = home.join(".codex");
        let partition = partition_key(&homes, &peer_homes);
        let scanner = shared_scanner(&partition);
        CodexSessionScanner {
            homes,
            peer_homes,
            default_home,
            shared_attribution,
            scanner,
        }
    }

    pub fn scan_result(
        &self,
        days_back: usize,
        now: f64,
        pricing: &ModelPricing,
        cancel: &CancelToken,
    ) -> CodexScanResult {
        let files = match self.session_files(cancel) {
            Ok(files) => files,
            Err(()) => return CodexScanResult::Incomplete,
        };
        let since = now - days_back as f64 * 86_400.0;
        if cancel.is_cancelled() {
            return CodexScanResult::Incomplete;
        }
        if files.is_empty() {
            return match self.scanner.scan(&[], None, cancel) {
                Ok(_) => CodexScanResult::Complete(None),
                Err(_) => CodexScanResult::Incomplete,
            };
        }
        let parsed = match self.scanner.scan(&files, Some(since), cancel) {
            Ok(parsed) => parsed,
            Err(_) => return CodexScanResult::Incomplete,
        };
        if first_future_dated(&parsed, now).is_some() {
            return CodexScanResult::Incomplete;
        }
        let events: Vec<Event> = parsed
            .iter()
            .flat_map(|file| file.items.iter().cloned())
            .collect();
        CodexScanResult::Complete(Some(aggregate(&events, since, pricing)))
    }

    /// Hosted-gateway turns only (OpenCode Go/Zen), for the OpenCode card's combined fold. The
    /// native card excludes these; without this projection they would be counted nowhere. `None`
    /// means the source was incomplete and nothing may be published.
    pub fn hosted_gateway_events(
        &self,
        days_back: usize,
        now: f64,
        cancel: &CancelToken,
    ) -> Option<Vec<Event>> {
        let files = self.session_files(cancel).ok()?;
        let since = now - days_back as f64 * 86_400.0;
        if cancel.is_cancelled() {
            return None;
        }
        if files.is_empty() {
            return Some(Vec::new());
        }
        let parsed = self.scanner.scan(&files, Some(since), cancel).ok()?;
        if first_future_dated(&parsed, now).is_some() {
            return None;
        }
        let mut seen: HashSet<EventKey> = HashSet::new();
        let mut events = Vec::new();
        for event in parsed.iter().flat_map(|file| file.items.iter()) {
            if event.timestamp < since
                || !event.has_token_usage()
                || !is_hosted_gateway_model(event.model.trim())
            {
                continue;
            }
            let key = EventKey {
                timestamp: event.timestamp.to_bits(),
                model: event.model.clone(),
                pricing_model: event.pricing_model.clone(),
                input: event.input,
                cached: event.cached,
                output: event.output,
                reasoning: event.reasoning,
                total: event.total,
                has_complete_cost_breakdown: event.has_complete_cost_breakdown,
                is_fast: event.is_fast,
                service_tier: event.service_tier.clone(),
            };
            if seen.insert(key) {
                events.push(event.clone());
            }
        }
        Some(events)
    }

    fn session_files(&self, cancel: &CancelToken) -> Result<Vec<DiscoveredFile>, ()> {
        let default_canonical = canonical(&self.default_home);
        let mut non_default: Vec<&PathBuf> = Vec::new();
        let mut default_homes: Vec<&PathBuf> = Vec::new();
        for home in &self.homes {
            if canonical(home) == default_canonical {
                default_homes.push(home);
            } else {
                non_default.push(home);
            }
        }
        let peer_inodes: HashSet<(u64, u64)> = if non_default.is_empty() {
            HashSet::new()
        } else {
            let mut inodes = HashSet::new();
            for peer in &self.peer_homes {
                collect_inodes(peer, &mut inodes, cancel)?;
            }
            inodes
        };
        let ordered: Vec<&PathBuf> = default_homes.into_iter().chain(non_default).collect();
        let mut files = Vec::new();
        let mut seen_dirs: HashSet<PathBuf> = HashSet::new();
        let mut seen_inodes: HashSet<(u64, u64)> = HashSet::new();
        let mut seen_rollouts: HashSet<String> = HashSet::new();
        for home in ordered {
            if cancel.is_cancelled() {
                return Err(());
            }
            let skip_peer_links = canonical(home) != default_canonical && !peer_inodes.is_empty();
            let mut seen_relative: HashSet<PathBuf> = HashSet::new();
            for name in ["sessions", "archived_sessions"] {
                let dir = canonical(&home.join(name));
                if !dir.exists() {
                    continue;
                }
                if !dir.is_dir() {
                    return Err(());
                }
                if !seen_dirs.insert(dir.clone()) {
                    continue;
                }
                let discovered =
                    discover_all(&[dir.clone()], Extensions::JsonlAndZstd).map_err(|_| ())?;
                for file in discovered {
                    if cancel.is_cancelled() {
                        return Err(());
                    }
                    let relative = file
                        .path
                        .strip_prefix(&dir)
                        .unwrap_or(&file.path)
                        .to_path_buf();
                    if !seen_relative.insert(relative) {
                        continue;
                    }
                    let inode = (file.revision.dev, file.revision.ino);
                    if skip_peer_links && peer_inodes.contains(&inode) {
                        continue;
                    }
                    if !seen_inodes.insert(inode) {
                        continue;
                    }
                    if let Some(rollout) = rollout_name(&file.path) {
                        if !seen_rollouts.insert(rollout) {
                            continue;
                        }
                    }
                    files.push(file);
                }
            }
        }
        if let Some(attribution) = &self.shared_attribution {
            let prefix = format!("{}/", canonical(&attribution.home).display());
            files.retain(|file| {
                let path = canonical(&file.path);
                if !path.to_string_lossy().starts_with(&prefix) {
                    return true;
                }
                match peek_creator_account_id(&file.path) {
                    Some(creator) => creator.eq_ignore_ascii_case(&attribution.identity),
                    None => attribution.keeps_unattributed,
                }
            });
        }
        Ok(files)
    }
}

fn peek_creator_account_id(path: &Path) -> Option<String> {
    const LIMIT: usize = 16 * 1024;
    let mut head = Vec::new();
    if path.extension().is_some_and(|extension| extension == "zst") {
        let _ = crate::scan::reader::read_zstd_chunks(path, |chunk| {
            let remaining = LIMIT.saturating_sub(head.len());
            head.extend_from_slice(&chunk[..chunk.len().min(remaining)]);
            Ok(head.len() >= LIMIT)
        });
    } else {
        use std::io::Read;
        let mut file = std::fs::File::open(path).ok()?;
        let mut buffer = vec![0u8; LIMIT];
        let read = file.read(&mut buffer).ok()?;
        head.extend_from_slice(&buffer[..read]);
    }
    let marker = b"\"creator_account_id\":\"";
    let start = head
        .windows(marker.len())
        .position(|window| window == marker)?
        + marker.len();
    let end = head[start..].iter().position(|byte| *byte == b'"')? + start;
    if end == start {
        return None;
    }
    String::from_utf8(head[start..end].to_vec()).ok()
}

fn scanner_registry() -> &'static Mutex<HashMap<String, Arc<IncrementalScanner<CodexLineParser>>>> {
    static REGISTRY: OnceLock<Mutex<HashMap<String, Arc<IncrementalScanner<CodexLineParser>>>>> =
        OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

fn shared_scanner(partition: &str) -> Arc<IncrementalScanner<CodexLineParser>> {
    let key = format!("codex:{}", partition);
    let mut registry = scanner_registry().lock().unwrap_or_else(|e| e.into_inner());
    registry
        .entry(key.clone())
        .or_insert_with(|| {
            Arc::new(IncrementalScanner::new(
                CodexLineParser::default(),
                key,
                Some(ScanStore::shared()),
            ))
        })
        .clone()
}

/// Release parsed rollout rows retained by every shared session scanner. The scan store keeps
/// compact checkpoints, so the next pass rehydrates instead of reparsing the rollout files.
pub(super) fn unload_shared_caches() {
    let mut registry = scanner_registry().lock().unwrap_or_else(|e| e.into_inner());
    for scanner in registry.values() {
        scanner.clear_memory_cache();
    }
    registry.clear();
}

fn partition_key(homes: &[PathBuf], peers: &[PathBuf]) -> String {
    let mut hasher = Sha256::new();
    let mut home_paths: Vec<String> = homes
        .iter()
        .map(|h| canonical(h).to_string_lossy().into_owned())
        .collect();
    home_paths.sort();
    let mut peer_paths: Vec<String> = peers
        .iter()
        .map(|h| canonical(h).to_string_lossy().into_owned())
        .collect();
    peer_paths.sort();
    for value in home_paths.iter().chain(peer_paths.iter()) {
        hasher.update(value.as_bytes());
        hasher.update([0]);
    }
    let digest = hasher.finalize();
    digest.iter().map(|b| format!("{b:02x}")).collect()
}

fn canonical(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

fn collect_inodes(
    home: &Path,
    out: &mut HashSet<(u64, u64)>,
    cancel: &CancelToken,
) -> Result<(), ()> {
    for name in ["sessions", "archived_sessions"] {
        let dir = canonical(&home.join(name));
        if !dir.exists() {
            continue;
        }
        if !dir.is_dir() {
            return Err(());
        }
        let discovered = discover_all(&[dir], Extensions::JsonlAndZstd).map_err(|_| ())?;
        for file in discovered {
            if cancel.is_cancelled() {
                return Err(());
            }
            out.insert((file.revision.dev, file.revision.ino));
        }
    }
    Ok(())
}

fn rollout_name(path: &Path) -> Option<String> {
    let name = path.file_name()?.to_str()?;
    let base = name
        .strip_suffix(".jsonl.zst")
        .or_else(|| name.strip_suffix(".jsonl"))?;
    base.starts_with("rollout-").then(|| base.to_string())
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct EventKey {
    timestamp: u64,
    model: Arc<str>,
    pricing_model: Option<Arc<str>>,
    input: i64,
    cached: i64,
    output: i64,
    reasoning: i64,
    total: i64,
    has_complete_cost_breakdown: bool,
    is_fast: bool,
    service_tier: Option<Arc<str>>,
}

pub fn aggregate(events: &[Event], since: f64, pricing: &ModelPricing) -> LogUsageScan {
    let mut seen: HashSet<EventKey> = HashSet::new();
    let mut accumulator = DailyUsageAccumulator::new();
    for event in events {
        if event.timestamp < since {
            continue;
        }
        let key = EventKey {
            timestamp: event.timestamp.to_bits(),
            model: event.model.clone(),
            pricing_model: event.pricing_model.clone(),
            input: event.input,
            cached: event.cached,
            output: event.output,
            reasoning: event.reasoning,
            total: event.total,
            has_complete_cost_breakdown: event.has_complete_cost_breakdown,
            is_fast: event.is_fast,
            service_tier: event.service_tier.clone(),
        };
        if !seen.insert(key) {
            continue;
        }
        let day = day_key(event.timestamp);
        let trimmed = event.model.trim();
        let model = if trimmed.is_empty() {
            ModelUsageEntry::UNATTRIBUTED
        } else {
            trimmed
        };
        if is_hosted_gateway_model(model) {
            continue;
        }
        let pricing_model = event.pricing_model.as_deref().unwrap_or(model);
        let canonical = pricing
            .canonical_key(&[
                pricing_model.to_string(),
                bare_model(pricing_model).to_string(),
            ])
            .unwrap_or_else(|| pricing_model.to_string());
        let rate_model = canonical
            .strip_suffix("-fast")
            .unwrap_or(&canonical)
            .to_string();
        let base_rates = pricing.resolve(&rate_model);
        let resolved_rates = base_rates
            .clone()
            .or_else(|| pricing.resolve(pricing_model));
        let api_estimate = event
            .has_complete_cost_breakdown
            .then(|| {
                resolved_rates.as_ref().map(|rates| {
                    rates.cost_dollars(
                        &TokenBreakdown {
                            input: (event.input - event.cached).max(0),
                            cache_write_5m: 0,
                            cache_write_1h: 0,
                            cache_read: event.cached,
                            output: event.output,
                            is_fast: false,
                        },
                        None,
                        true,
                    )
                })
            })
            .flatten();
        accumulator.record_api_estimate(
            &day,
            if event.has_complete_cost_breakdown {
                api_estimate
            } else {
                None
            },
            event.total,
        );

        let Some(rates) = resolved_rates else {
            if event.total > 0 {
                accumulator.add_unknown_model(&day, model);
            }
            accumulator.add_with(
                &day,
                event.total,
                None,
                model,
                RowOptions {
                    canonical: Some(&canonical),
                    cost_is_complete: event.has_complete_cost_breakdown,
                    token_count_saturated: false,
                },
            );
            continue;
        };
        let is_fast_alias = canonical.ends_with("-fast");
        let applies_fast = if is_fast_alias {
            base_rates.is_some()
        } else {
            event.is_fast
        };
        let service_multiplier =
            codex_service_tier_multiplier(&rate_model, event.service_tier.as_deref());
        let multiplier =
            service_multiplier.unwrap_or_else(|| codex_priority_multiplier(&rate_model, &rates));
        let event_cost = if event.has_complete_cost_breakdown {
            Some(cost(
                &rates,
                event,
                &rate_model,
                service_multiplier.is_some() || applies_fast,
                multiplier,
            ))
        } else {
            None
        };
        accumulator.add_with(
            &day,
            event.total,
            event_cost,
            model,
            RowOptions {
                canonical: Some(&canonical),
                cost_is_complete: event.has_complete_cost_breakdown,
                token_count_saturated: false,
            },
        );
    }
    accumulator.build()
}

fn bare_model(model: &str) -> &str {
    let trimmed = model.trim();
    trimmed
        .split('/')
        .filter(|part| !part.is_empty())
        .next_back()
        .unwrap_or(trimmed)
}

pub(crate) fn cost(
    rates: &ModelRates,
    event: &Event,
    model: &str,
    fast_tier: bool,
    fast_multiplier: f64,
) -> f64 {
    let mut effective = rates.clone();
    if let Some((input, output, cache_read)) = codex_long_context_rates(model) {
        effective.input_above_200k_per_million = Some(input);
        effective.output_above_200k_per_million = Some(output);
        effective.cache_read_above_200k_per_million = Some(cache_read);
        effective.long_context_threshold_tokens = 272_000;
    }
    if codex_model_has_no_cache_discount(model) || !rates.cache_read_is_explicit {
        effective.cache_read_per_million = effective.input_per_million;
        effective.cache_read_above_200k_per_million = effective.input_above_200k_per_million;
    }
    effective.fast_multiplier = fast_multiplier;
    effective.cost_dollars(
        &TokenBreakdown {
            input: (event.input - event.cached).max(0),
            cache_write_5m: 0,
            cache_write_1h: 0,
            cache_read: event.cached,
            output: event.output,
            is_fast: fast_tier,
        },
        None,
        true,
    )
}

pub(crate) fn codex_priority_multiplier(model: &str, rates: &ModelRates) -> f64 {
    match dated_base_model(model).as_str() {
        "gpt-5.5" | "gpt-5.5-pro" => 2.5,
        "gpt-5.4" | "gpt-5.4-pro" | "gpt-5.6-sol" | "gpt-5.6-terra" | "gpt-5.6-luna"
        | "gpt-6-sol" | "gpt-6-terra" | "gpt-6-luna" | "gpt-6-astra" => 2.0,
        _ => {
            if rates.fast_multiplier == 1.0 {
                2.0
            } else {
                rates.fast_multiplier
            }
        }
    }
}

pub(crate) fn codex_service_tier_multiplier(
    model: &str,
    service_tier: Option<&str>,
) -> Option<f64> {
    let base = dated_base_model(model);
    let slug = base
        .split('/')
        .filter(|s| !s.is_empty())
        .next_back()
        .unwrap_or(&base);
    if slug != "gpt-6.1-sol" {
        return None;
    }
    match service_tier?.to_lowercase().as_str() {
        "fast" | "priority" => Some(2.0),
        "flex" | "batch" => Some(0.5),
        "ultrafast" => Some(6.0),
        _ => None,
    }
}

fn codex_model_has_no_cache_discount(model: &str) -> bool {
    matches!(
        dated_base_model(model).as_str(),
        "gpt-5.4-pro" | "gpt-5.5-pro"
    )
}

fn codex_long_context_rates(model: &str) -> Option<(f64, f64, f64)> {
    match dated_base_model(model).as_str() {
        "gpt-5.4" => Some((5.0, 22.5, 0.5)),
        "gpt-5.4-pro" => Some((60.0, 270.0, 60.0)),
        "gpt-5.5" => Some((10.0, 45.0, 1.0)),
        "gpt-5.5-pro" => Some((60.0, 270.0, 60.0)),
        "gpt-5.6-sol" => Some((8.0, 30.0, 0.8)),
        "gpt-5.6-terra" | "gpt-6-terra" => Some((4.0, 18.0, 0.4)),
        "gpt-5.6-luna" => Some((0.4, 1.8, 0.04)),
        "gpt-6-sol" => Some((4.0, 15.0, 0.4)),
        "gpt-6-astra" => Some((20.0, 75.0, 2.0)),
        "gpt-6-luna" => Some((0.2, 0.75, 0.02)),
        _ => None,
    }
}

fn dated_base_model(model: &str) -> String {
    strip_dated_suffix(model, true)
        .or_else(|| strip_dated_suffix(model, false))
        .unwrap_or_else(|| model.to_string())
}

fn strip_dated_suffix(model: &str, separated: bool) -> Option<String> {
    let bytes = model.as_bytes();
    let suffix_len = if separated { 11 } else { 9 };
    if bytes.len() < suffix_len {
        return None;
    }
    let start = bytes.len() - suffix_len;
    if bytes[start] != b'-' {
        return None;
    }
    if separated {
        for offset in 1..=10 {
            if offset == 5 || offset == 8 {
                if bytes[start + offset] != b'-' {
                    return None;
                }
            } else if !bytes[start + offset].is_ascii_digit() {
                return None;
            }
        }
    } else if !(1..=8).all(|offset| bytes[start + offset].is_ascii_digit()) {
        return None;
    }
    Some(model[..start].to_string())
}

/// Convenience for the provider: fold pi's scan beside native events.
pub fn merged_scan(native: Option<LogUsageScan>, pi: Option<LogUsageScan>) -> Option<LogUsageScan> {
    DailyUsageAccumulator::merged(&[native, pi], None)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pricing::ModelPricing;
    use std::sync::Arc;

    fn event(model: &str, input: i64, cached: i64, output: i64) -> Event {
        Event {
            timestamp: 1_800_000_000.0,
            model: Arc::from(model),
            pricing_model: None,
            input,
            cached,
            output,
            reasoning: 0,
            total: input + output,
            has_complete_cost_breakdown: true,
            is_fast: false,
            service_tier: None,
        }
    }

    #[test]
    fn dedupes_identical_events_and_counts_tokens_without_a_price() {
        let events = [
            event("unpriced-codename", 10, 2, 5),
            event("unpriced-codename", 10, 2, 5),
        ];
        let scan = aggregate(&events, 0.0, &ModelPricing::default());
        assert_eq!(scan.series.daily.len(), 1);
        assert_eq!(scan.series.daily[0].total_tokens, 15);
        assert!(scan
            .unknown_models_by_day
            .values()
            .flatten()
            .any(|m| m == "unpriced-codename"));
    }

    #[test]
    fn hosted_gateway_rows_are_excluded_from_native_totals() {
        let events = [
            event("anthropic/opencode_go/gpt-5", 10, 0, 2),
            event("gpt-5", 10, 0, 2),
        ];
        let scan = aggregate(&events, 0.0, &ModelPricing::default());
        assert_eq!(scan.series.daily[0].total_tokens, 12);
    }

    #[test]
    fn dated_suffix_and_long_context_helpers_match_swift() {
        assert_eq!(dated_base_model("gpt-5.4-2025-08-07"), "gpt-5.4");
        assert_eq!(dated_base_model("gpt-5.4-20250807"), "gpt-5.4");
        assert_eq!(
            codex_long_context_rates("gpt-5.4-2025-08-07"),
            Some((5.0, 22.5, 0.5))
        );
        assert_eq!(
            codex_service_tier_multiplier("gpt-6.1-sol", Some("ultrafast")),
            Some(6.0)
        );
        assert!(codex_model_has_no_cache_discount("gpt-5.5-pro-2025-01-01"));
    }
}
