//! Daily token/cost estimates for Claude from Claude Code's local session logs
//! (`<config dir>/projects/**/*.jsonl`), replacing the external `ccusage` CLI (Swift
//! `ClaudeLogUsageScanner`).
//!
//! Ports ccusage's Claude adapter semantics:
//! - Roots come from `CLAUDE_CONFIG_DIR` (comma-separated; each entry is a config dir containing
//!   `projects/`, or the `projects/` dir itself), else `$XDG_CONFIG_HOME/claude` and `~/.claude`,
//!   plus Cowork's per-session sandboxes (see `roots`).
//! - A usage line must parse (see `log_parse`); entries are deduplicated by `(message.id, requestId)`
//!   with a second pass for sidechain replays (see `dedup`).
//! - Cost mode "auto": a line's `costUSD` when present, else tokens priced through `ModelPricing`.
//!
//! Parsed files live in the engine's shared incremental scanner (memory plus the persistent scan
//! store), so a refresh parses only changed or appended files and then re-runs the cheap dedup and
//! day aggregation, whose result the in-memory fold cache keeps while the sources are unchanged.

use super::aggregate::aggregate;
use super::dedup::ClaudeEntryDeduplication;
use super::entry::ClaudeEntry;
use super::fold_cache::FoldCache;
use super::gateway::is_hosted_gateway_model;
use super::log_parse::ClaudeLineParser;
use super::ownership::OwnershipLookup;
use super::util::{since_date, stable_fingerprint, zone_signature};
use crate::accounting::LogUsageScan;
use crate::context::CancelToken;
use crate::host::{self, diagnostic_gate};
use crate::pricing::ModelPricing;
use crate::qlog;
use crate::scan::{fingerprint, first_future_dated, DiscoveredFile, FileItems, IncrementalScanner, ScanError, ScanStore};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};

pub type ClaudeIncrementalScanner = IncrementalScanner<ClaudeLineParser>;
pub type EnvLookup = Arc<dyn Fn(&str) -> Option<String> + Send + Sync>;
/// Injected session-ownership lookup (tests; Swift `ownershipLookup`).
pub type OwnershipFn = Arc<dyn Fn(&DiscoveredFile) -> OwnershipLookup + Send + Sync>;

/// Lets a provider distinguish a complete empty log scan from a source read that was incomplete.
#[derive(Clone, Debug, PartialEq)]
pub enum ClaudeScanResult {
    Complete(Option<LogUsageScan>),
    Incomplete,
}

/// OpenCode needs only hosted gateway entries. Bound that projection independently of the much larger
/// native history; oversized projections are recomputed every time.
const MAXIMUM_CACHED_GATEWAY_ENTRIES: usize = 4_096;

#[derive(Clone)]
pub struct ClaudeLogConfig {
    pub home: PathBuf,
    pub env: EnvLookup,
    pub account_uuid: Option<String>,
    pub organization_uuid: Option<String>,
    pub allows_unattributed_sessions: bool,
    /// Scoped provider instances pass their stable parse-source identity here. Account or time
    /// filters over the same physical roots deliberately pass the same value and share whole-file
    /// records.
    pub cache_identity_override: Option<String>,
    pub ownership_lookup: Option<OwnershipFn>,
    /// Use this scanner instead of the process-wide one for the parse source (tests inject an
    /// isolated memory-only scanner, as Swift's `incrementalScanner`).
    pub incremental: Option<Arc<ClaudeIncrementalScanner>>,
}

impl ClaudeLogConfig {
    /// The user's real home and process environment (as the host reports it).
    pub fn live() -> Self {
        Self::new(crate::paths::home())
    }

    pub fn new(home: PathBuf) -> Self {
        ClaudeLogConfig {
            home,
            env: Arc::new(host::env_var),
            account_uuid: None,
            organization_uuid: None,
            allows_unattributed_sessions: false,
            cache_identity_override: None,
            ownership_lookup: None,
            incremental: None,
        }
    }
}

pub struct ClaudeLogScanner {
    pub(super) home: PathBuf,
    pub(super) env: EnvLookup,
    pub(super) organization_id: Option<String>,
    pub(super) account_id: Option<String>,
    pub(super) allows_unattributed_sessions: bool,
    cache_identity_override: Option<String>,
    pub(super) ownership_lookup: Option<OwnershipFn>,
    incremental: Option<Arc<ClaudeIncrementalScanner>>,
    aggregate_cache: Mutex<Option<FoldCache<LogUsageScan>>>,
    gateway_cache: Mutex<Option<FoldCache<Vec<ClaudeEntry>>>>,
}

/// One scan's source files, parsed and checked for completeness.
struct Source {
    files: Vec<FileItems<ClaudeEntry>>,
    identity: String,
}

impl ClaudeLogScanner {
    pub fn new(config: ClaudeLogConfig) -> Self {
        assert!(config.cache_identity_override.as_deref() != Some(""), "cache identity override must not be empty");
        ClaudeLogScanner {
            home: config.home,
            env: config.env,
            organization_id: config.organization_uuid.map(|v| v.to_lowercase()),
            account_id: config.account_uuid.map(|v| v.to_lowercase()),
            allows_unattributed_sessions: config.allows_unattributed_sessions,
            cache_identity_override: config.cache_identity_override,
            ownership_lookup: config.ownership_lookup,
            incremental: config.incremental,
            aggregate_cache: Mutex::new(None),
            gateway_cache: Mutex::new(None),
        }
    }

    /// Scan the last `days_back` days of Claude logs. `None` when no Claude data directory or no log
    /// files exist (the spend tiles then render "No data") or the scan was incomplete; an empty series
    /// when logs exist but have no usage in the window.
    pub fn scan(&self, days_back: usize, now: f64, pricing: &ModelPricing, cancel: &CancelToken) -> Option<LogUsageScan> {
        match self.scan_result(days_back, now, pricing, cancel) {
            ClaudeScanResult::Complete(scan) => scan,
            ClaudeScanResult::Incomplete => None,
        }
    }

    /// Completeness-aware form used by the Claude provider so an ownership/read failure cannot be
    /// mistaken for a clean scan that simply found no Claude rows.
    pub fn scan_result(&self, days_back: usize, now: f64, pricing: &ModelPricing, cancel: &CancelToken) -> ClaudeScanResult {
        let since = since_date(days_back, now);
        let identity = self.parse_cache_identity();
        let roots = self.claude_roots();
        let files = if roots.is_empty() { Some(Vec::new()) } else { self.source_files(&roots, cancel) };
        let Some(files) = files else { return ClaudeScanResult::Incomplete };
        if cancel.is_cancelled() {
            return ClaudeScanResult::Incomplete;
        }
        if files.is_empty() {
            *lock(&self.aggregate_cache) = None;
            self.prune(&identity, since, cancel);
            diagnostic_gate::clear(&self.future_gate_key("sessions", &identity));
            return ClaudeScanResult::Complete(None);
        }
        let Some(source) = self.scan_source("sessions", identity, &files, since, now, cancel) else {
            return ClaudeScanResult::Incomplete;
        };
        let key = self.fold_key(&source, "aggregate", since, now, Some(pricing.aggregate_cache_token()));
        if let Some(cached) = lock(&self.aggregate_cache).as_ref().and_then(|c| c.lookup(&key, now)) {
            return ClaudeScanResult::Complete(Some(cached));
        }
        *lock(&self.aggregate_cache) = None;
        let deduped = dedup_source(&source);
        if cancel.is_cancelled() {
            return ClaudeScanResult::Incomplete;
        }
        let result = aggregate(&deduped, since, pricing);
        *lock(&self.aggregate_cache) = Some(FoldCache::new(key, now, result.clone()));
        ClaudeScanResult::Complete(Some(result))
    }

    /// The deduplicated hosted-gateway entries of the last `days_back` days (Swift
    /// `foldParsedEntries(hostedGatewayOnly: true)`), sharing the native card's parse cache so
    /// unchanged session logs are never re-parsed. The complete source is deduplicated first: a native
    /// replay may win a cross-file collision, so filtering first could count a turn owned by the Claude
    /// card. `roots` overrides discovery with explicit config dirs. `None` means the source was
    /// incomplete (nothing may be published).
    pub fn gateway_entries(
        &self,
        days_back: usize,
        now: f64,
        roots: Option<Vec<PathBuf>>,
        cancel: &CancelToken,
    ) -> Option<Vec<ClaudeEntry>> {
        self.fold_entries(days_back, now, roots, true, cancel)
    }

    /// Swift `foldParsedEntries`: every deduplicated entry, or only the hosted-gateway ones.
    pub(super) fn fold_entries(
        &self,
        days_back: usize,
        now: f64,
        roots: Option<Vec<PathBuf>>,
        hosted_gateway_only: bool,
        cancel: &CancelToken,
    ) -> Option<Vec<ClaudeEntry>> {
        let since = since_date(days_back, now);
        let (roots, identity) = match roots {
            Some(roots) => {
                let identity = self.cache_identity_override.clone().unwrap_or_else(|| super::roots::roots_identity(&roots));
                (roots, identity)
            }
            None => (self.claude_roots(), self.parse_cache_identity()),
        };
        let files = self.source_files(&roots, cancel)?;
        if files.is_empty() {
            *lock(&self.gateway_cache) = None;
            self.prune(&identity, since, cancel);
            diagnostic_gate::clear(&self.future_gate_key("gateway", &identity));
            return Some(Vec::new());
        }
        let source = self.scan_source("gateway", identity, &files, since, now, cancel)?;
        let key = self.fold_key(&source, "gateway", since, now, None);
        if hosted_gateway_only {
            if let Some(cached) = lock(&self.gateway_cache).as_ref().and_then(|c| c.lookup(&key, now)) {
                return Some(cached);
            }
            *lock(&self.gateway_cache) = None;
        }
        let mut entries = dedup_source(&source);
        if cancel.is_cancelled() {
            return None;
        }
        if hosted_gateway_only {
            entries.retain(|e| e.model.as_deref().is_some_and(|m| is_hosted_gateway_model(m.trim())));
            if entries.len() <= MAXIMUM_CACHED_GATEWAY_ENTRIES {
                *lock(&self.gateway_cache) = Some(FoldCache::new(key, now, entries.clone()));
            }
        }
        Some(entries)
    }

    /// Parse what changed among `files` and apply the future-timestamp guard. `None` means the scan is
    /// incomplete: a source could not be read or holds a malformed record (logged with the file's
    /// name only), a row is dated in the future, or the scan was cancelled.
    fn scan_source(
        &self,
        kind: &str,
        identity: String,
        files: &[DiscoveredFile],
        since: f64,
        now: f64,
        cancel: &CancelToken,
    ) -> Option<Source> {
        let scanned = match self.incremental_for(&identity).scan(files, Some(since), cancel) {
            Ok(scanned) => scanned,
            Err(ScanError::Cancelled) => return None,
            Err(error) => {
                qlog!(Warn, host::plugin_tag("claude"), "session scan is incomplete, preserving last-good history: {error}");
                return None;
            }
        };
        let gate = self.future_gate_key(kind, &identity);
        if first_future_dated(&scanned, now).is_some() {
            diagnostic_gate::log_once(&gate, || {
                qlog!(
                    Warn,
                    host::plugin_tag("claude"),
                    "session usage contains a timestamp more than five minutes ahead; preserving last-good history"
                );
            });
            return None;
        }
        diagnostic_gate::clear(&gate);
        Some(Source { files: scanned, identity })
    }

    /// Drop this source's cached files when nothing is in scope any more (Swift scans an empty list).
    fn prune(&self, identity: &str, since: f64, cancel: &CancelToken) {
        if let Err(error) = self.incremental_for(identity).scan(&[], Some(since), cancel) {
            if !matches!(error, ScanError::Cancelled) {
                qlog!(Warn, host::plugin_tag("claude"), "could not prune the session cache: {error}");
            }
        }
    }

    /// Shared per parse source, so every card over the same roots reuses one cache.
    fn incremental_for(&self, identity: &str) -> Arc<ClaudeIncrementalScanner> {
        if let Some(scanner) = &self.incremental {
            return scanner.clone();
        }
        static REGISTRY: OnceLock<Mutex<HashMap<String, Arc<ClaudeIncrementalScanner>>>> = OnceLock::new();
        let partition = format!("claude:{}", stable_fingerprint(identity));
        let mut registry = lock(REGISTRY.get_or_init(Default::default));
        registry
            .entry(partition.clone())
            .or_insert_with(|| {
                Arc::new(IncrementalScanner::new(ClaudeLineParser::new(), partition, Some(ScanStore::shared())))
            })
            .clone()
    }

    fn fold_key(&self, source: &Source, kind: &str, since: f64, now: f64, pricing_token: Option<&str>) -> [u8; 16] {
        let since_text = since.to_string();
        let zone = zone_signature(since, now);
        fingerprint(
            &source.files,
            &[
                kind,
                &source.identity,
                &since_text,
                &zone,
                pricing_token.unwrap_or(""),
                self.organization_id.as_deref().unwrap_or("no-organization"),
                self.account_id.as_deref().unwrap_or("no-account"),
                if self.allows_unattributed_sessions { "allows-unattributed" } else { "requires-owned-session" },
            ],
        )
    }

    fn future_gate_key(&self, kind: &str, identity: &str) -> String {
        let scope = [
            kind,
            identity,
            self.organization_id.as_deref().unwrap_or("no-organization"),
            self.account_id.as_deref().unwrap_or("no-account"),
            if self.allows_unattributed_sessions { "allows-unattributed" } else { "requires-owned-session" },
        ]
        .join("\n");
        format!("claude.sessions.future-timestamp.{}", stable_fingerprint(&scope))
    }

    /// Stable source configuration identity rather than the discovered root list: Cowork adds session
    /// roots over time, and a new session must extend the same cache instead of cold-parsing every old
    /// file. Scoped root overrides pass an explicit identity so distinct homes stay partitioned.
    pub(super) fn parse_cache_identity(&self) -> String {
        match &self.cache_identity_override {
            Some(identity) => identity.clone(),
            None => super::roots::parse_source_identity(&self.home, self.env.as_ref()),
        }
    }
}

/// Every contributing entry in file order, deduplicated across the whole source.
fn dedup_source(source: &Source) -> Vec<ClaudeEntry> {
    let mut deduplication = ClaudeEntryDeduplication::default();
    for file in &source.files {
        for entry in file.iter().filter(|e| e.contributes_usage()) {
            deduplication.append(entry.clone());
        }
    }
    deduplication.into_entries()
}

pub(super) fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|e| e.into_inner())
}
