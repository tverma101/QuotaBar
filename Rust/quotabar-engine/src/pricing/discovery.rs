//! OpenRouter model discovery (Swift `ModelPricingStore+Discovery.swift`): when a model has no curated
//! price or exact OpenRouter rate, revalidate the public catalogue once and fold any newly published
//! route into the next snapshot.
//!
//! Cost control is the point. A ledger can mention one model thousands of times per pass, and
//! providers refresh on every menu-bar tap, so:
//! - `ModelPricing` reports each distinct name once per snapshot; the sink buffers at most 32.
//! - Discovery never overlaps the hourly refresh, and an hourly OpenRouter fetch counts as the
//!   attempt for every queued name.
//! - At most one discovery fetch per five minutes, and a name stops queuing after three misses.
//! - Names are only a local hint: the only request this can make is the same public
//!   `/api/v1/models` GET the hourly refresh uses. No name is ever sent anywhere.

use super::resolve::ModelPricing;
use super::store::{spawn, PricingStore, SourceId};
use crate::qlog;
use std::collections::{BTreeSet, HashMap};
use std::sync::{Arc, Mutex};

const RETRY_INTERVAL: f64 = 5.0 * 60.0;
const MAX_MISS_STREAK: u32 = 3;
const MAX_TRACKED: usize = 64;
const MAX_NAME_LENGTH: usize = 200;
const MAX_BUFFERED: usize = 32;

/// Bounded hand-off from `ModelPricing`'s report hook. Called from scanner threads, possibly
/// thousands of times per pass; does the minimum.
#[derive(Default)]
pub(super) struct UnresolvedSink {
    names: Mutex<BTreeSet<String>>,
}

impl UnresolvedSink {
    pub(super) fn record(&self, raw: &str) {
        let name = raw.trim();
        // Over-long names are parse artifacts, not model ids.
        if name.is_empty() || name.len() > MAX_NAME_LENGTH {
            return;
        }
        let mut names = self.names.lock().unwrap_or_else(|e| e.into_inner());
        if names.len() < MAX_BUFFERED {
            names.insert(name.to_string());
        }
    }

    fn drain(&self) -> BTreeSet<String> {
        std::mem::take(&mut *self.names.lock().unwrap_or_else(|e| e.into_inner()))
    }
}

#[derive(Default)]
pub(super) struct DiscoveryState {
    pub(super) running: bool,
    pending: BTreeSet<String>,
    /// Name -> earliest time a round may fetch for it again.
    backoff: HashMap<String, f64>,
    /// Consecutive attempts without an exact OpenRouter rate.
    miss_streaks: HashMap<String, u32>,
    last_open_router_attempt: Option<f64>,
}

impl DiscoveryState {
    pub(super) fn note_open_router_attempt(&mut self, now: f64) {
        self.last_open_router_attempt = Some(now);
    }

    fn outside_floor(&self, now: f64) -> bool {
        self.last_open_router_attempt.map_or(true, |last| now - last >= RETRY_INTERVAL)
    }

    /// Drop names an exact OpenRouter route now prices, and names that exhausted their misses.
    pub(super) fn prune_completed(&mut self, pricing: &ModelPricing) {
        let names: Vec<String> = self.pending.iter().cloned().collect();
        for name in names {
            if pricing.has_exact_open_router_rate(&name) {
                self.miss_streaks.remove(&name);
                self.backoff.remove(&name);
                self.pending.remove(&name);
            } else if self.miss_streaks.get(&name).copied().unwrap_or(0) >= MAX_MISS_STREAK {
                self.pending.remove(&name);
            }
        }
    }

    fn bound_pending(&mut self) {
        while self.pending.len() > MAX_TRACKED {
            self.pending.pop_last();
        }
    }

    /// Names eligible now; names inside their cool-off stay queued.
    fn take_wanted(&self, now: f64) -> BTreeSet<String> {
        self.pending
            .iter()
            .filter(|n| self.miss_streaks.get(*n).copied().unwrap_or(0) < MAX_MISS_STREAK)
            .filter(|n| self.backoff.get(*n).map_or(true, |eligible| now >= *eligible))
            .take(MAX_TRACKED)
            .cloned()
            .collect()
    }

    fn back_off(&mut self, names: &BTreeSet<String>, pricing: &ModelPricing, now: f64) {
        for name in names {
            self.backoff.insert(name.clone(), now + RETRY_INTERVAL);
            if pricing.has_exact_open_router_rate(name) {
                self.pending.remove(name);
            } else {
                self.pending.insert(name.clone());
            }
        }
        self.bound_pending();
        let cutoff = now - RETRY_INTERVAL;
        self.backoff.retain(|_, until| *until >= cutoff);
        let pending = &self.pending;
        self.miss_streaks.retain(|name, _| pending.contains(name));
        if self.backoff.len() > MAX_TRACKED * 2 {
            let mut newest: Vec<(String, f64)> = self.backoff.drain().collect();
            newest.sort_by(|a, b| b.1.total_cmp(&a.1));
            newest.truncate(MAX_TRACKED * 2);
            self.backoff = newest.into_iter().collect();
        }
    }

    /// One completed attempt: names still without an exact rate burn a miss; three misses stop the
    /// name (a parse artifact must not cost a fetch every five minutes forever).
    fn apply_miss_streak(&mut self, names: &BTreeSet<String>, pricing: &ModelPricing) {
        for name in names {
            if pricing.has_exact_open_router_rate(name) {
                self.miss_streaks.remove(name);
                continue;
            }
            let streak = self.miss_streaks.entry(name.clone()).or_insert(0);
            *streak += 1;
            if *streak >= MAX_MISS_STREAK {
                self.pending.remove(name);
            }
        }
    }

    /// The hourly refresh fetched OpenRouter: count it as the attempt for every eligible name.
    pub(super) fn absorb_external_attempt(&mut self, pricing: &ModelPricing, now: f64) {
        let wanted = self.take_wanted(now);
        if !wanted.is_empty() {
            self.back_off(&wanted, pricing, now);
            self.apply_miss_streak(&wanted, pricing);
        }
    }
}

impl PricingStore {
    /// Queue names without a curated price or exact OpenRouter rate for a background revalidation.
    pub fn report_unknown_models<'a>(&self, names: impl IntoIterator<Item = &'a str>) {
        for name in names {
            self.sink.record(name);
        }
    }

    /// Start one background discovery round if names are queued and every guard allows it. Called
    /// from `current()` and after each provider refresh, with that refresh's scope.
    pub fn schedule_discovery_if_queued(self: &Arc<Self>, skip_model_catalog_refresh: bool) {
        if let Some(wanted) = self.claim_discovery_round(skip_model_catalog_refresh) {
            let store = self.clone();
            if !spawn("quotabar-pricing-discovery", move || store.discover(wanted)) {
                self.lock().discovery.running = false;
            }
        }
    }

    /// Run a queued discovery round on the calling thread (tests).
    pub fn run_discovery_now(self: &Arc<Self>, skip_model_catalog_refresh: bool) {
        if let Some(wanted) = self.claim_discovery_round(skip_model_catalog_refresh) {
            self.discover(wanted);
        }
    }

    fn claim_discovery_round(&self, skip_model_catalog_refresh: bool) -> Option<BTreeSet<String>> {
        let now = self.now();
        let mut guard = self.lock();
        let state = &mut *guard;
        let drained = self.sink.drain();
        let discovery = &mut state.discovery;
        discovery.pending.extend(drained);
        discovery.bound_pending();
        discovery.prune_completed(&state.pricing);
        if discovery.pending.is_empty() || discovery.running || state.refresh_running {
            return None;
        }
        // A menu-bar pass may only download a catalogue that is missing entirely.
        if skip_model_catalog_refresh && self.cache_file(SourceId::OpenRouter).exists() {
            return None;
        }
        // A source that just failed keeps its own 30-minute cool-off.
        if self.failure_retry_blocked(state, SourceId::OpenRouter) {
            return None;
        }
        let discovery = &mut state.discovery;
        if !discovery.outside_floor(now) {
            return None;
        }
        let wanted = discovery.take_wanted(now);
        if wanted.is_empty() {
            return None;
        }
        // Reserve the floor now so a second caller cannot pass the same checks before the fetch runs.
        discovery.running = true;
        discovery.last_open_router_attempt = Some(now);
        Some(wanted)
    }

    fn discover(self: &Arc<Self>, names: BTreeSet<String>) {
        let changed = self.config.source_urls.contains_key(&SourceId::OpenRouter) && self.fetch(SourceId::OpenRouter);
        let now = self.now();
        let mut guard = self.lock();
        let state = &mut *guard;
        if changed {
            self.rebuild_pricing(state);
            let matched = names.iter().filter(|n| state.pricing.has_exact_open_router_rate(n)).count();
            if matched > 0 {
                qlog!(Info, "pricing", "OpenRouter catalogue matched {matched} of {} model name(s)", names.len());
            }
        }
        if self.config.source_urls.contains_key(&SourceId::OpenRouter) {
            self.write_source_states(state);
        }
        state.discovery.back_off(&names, &state.pricing, now);
        state.discovery.apply_miss_streak(&names, &state.pricing);
        state.discovery.running = false;
    }
}
