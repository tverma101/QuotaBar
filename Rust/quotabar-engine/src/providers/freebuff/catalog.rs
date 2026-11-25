//! Freebuff's model-identity catalogue (`FreebuffModelCatalog.swift`). Keeps only public model
//! identities, never expiring handles or login credentials. The pricing store supplies OpenRouter
//! rates; this catalogue only resolves Freebuff's opaque keys.
//!
//! Refreshing it is a hosted-detail request, so [`FreebuffModelCatalog::refresh`] goes through the
//! [`HostedClient`] and fails with `liveAccessUnavailable` unless a transport is registered.

use super::auth::FreebuffAuth;
use super::error::FreebuffError;
use super::identity::FreebuffModelIdentity;
use super::transport::HostedClient;
use crate::context::CancelToken;
use crate::host::{auth_tag, plugin_tag};
use crate::model::Timestamp;
use crate::pricing::ModelPricing;
use crate::qlog;
use crate::time::REFERENCE_DATE_UNIX;
use regex_lite::Regex;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

/// How long a fetched catalogue stays fresh.
pub const REFRESH_INTERVAL: f64 = 3600.0;
/// The minimum gap between attempts. A failing endpoint backs off to the same cadence as a working
/// one instead of being re-requested on every refresh tick.
pub const RETRY_INTERVAL: f64 = 3600.0;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub key: String,
    pub display_name: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub legacy_digests: Option<Vec<String>>,
}

/// Swift's `Cache` is encoded with `JSONEncoder`'s default date strategy: seconds since 2001-01-01.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Cache {
    fetched_at: f64,
    entries: Vec<Entry>,
}

impl Cache {
    fn fetched_at_unix(&self) -> Timestamp {
        self.fetched_at + REFERENCE_DATE_UNIX
    }
}

#[derive(Default)]
struct State {
    loaded: bool,
    cache: Option<Cache>,
    /// When the last catalogue request was made, successful or not.
    last_attempt_at: Option<Timestamp>,
    /// Why the last attempt failed, so the backoff can keep reporting it.
    last_failure: Option<FreebuffError>,
}

enum CachePath {
    /// `<app data>/freebuff-model-identities.json`, resolved when first used (the host configures the
    /// directories after providers are constructed).
    Live,
    Fixed(Option<PathBuf>),
}

pub struct FreebuffModelCatalog {
    path: CachePath,
    state: Mutex<State>,
}

impl FreebuffModelCatalog {
    pub fn live() -> Self {
        FreebuffModelCatalog { path: CachePath::Live, state: Mutex::new(State::default()) }
    }

    pub fn new(cache_path: Option<PathBuf>) -> Self {
        FreebuffModelCatalog { path: CachePath::Fixed(cache_path), state: Mutex::new(State::default()) }
    }

    fn cache_path(&self) -> Option<PathBuf> {
        match &self.path {
            CachePath::Live => Some(crate::paths::app_data().join("freebuff-model-identities.json")),
            CachePath::Fixed(path) => path.clone(),
        }
    }

    fn load_if_needed(&self, state: &mut State) {
        if state.loaded {
            return;
        }
        state.loaded = true;
        let Some(path) = self.cache_path() else { return };
        let Ok(data) = std::fs::read(&path) else { return };
        match serde_json::from_slice::<Cache>(&data) {
            Ok(cache) => state.cache = Some(cache),
            Err(_) => qlog!(Warn, auth_tag("freebuff"), "saved model identities could not be decoded"),
        }
    }

    /// Release the decoded mirror; the saved file is read again on the next use.
    pub fn unload_caches(&self) {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state.cache = None;
        state.loaded = false;
    }

    pub fn current(&self) -> HashMap<String, Entry> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        self.load_if_needed(&mut state);
        let mut out = HashMap::new();
        for entry in state.cache.as_ref().map(|c| c.entries.as_slice()).unwrap_or_default() {
            out.insert(entry.key.clone(), entry.clone());
        }
        out
    }

    pub fn refresh(
        &self,
        auth: &FreebuffAuth,
        client: &HostedClient,
        now: Timestamp,
        cancel: &CancelToken,
    ) -> Result<(), FreebuffError> {
        {
            let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
            self.load_if_needed(&mut state);
            if let Some(cache) = &state.cache {
                if now - cache.fetched_at_unix() < REFRESH_INTERVAL {
                    return Ok(());
                }
            }
            // A failed attempt backs off like a successful one. Without this the catalogue was
            // re-requested on every refresh tick for as long as the endpoint stayed broken.
            if let Some(last) = state.last_attempt_at {
                if now - last < RETRY_INTERVAL {
                    return match &state.last_failure {
                        Some(failure) => Err(failure.clone()),
                        None => Ok(()),
                    };
                }
            }
            state.last_attempt_at = Some(now);
        }
        match self.fetch(auth, client, now, cancel) {
            Ok(replacement) => {
                let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
                state.cache = Some(replacement);
                state.last_failure = None;
                Ok(())
            }
            Err(FreebuffError::Cancelled) => {
                // A cancelled refresh is not a failed endpoint; the next one may try again right away.
                self.state.lock().unwrap_or_else(|e| e.into_inner()).last_attempt_at = None;
                Err(FreebuffError::Cancelled)
            }
            Err(error) => {
                let recorded = match error {
                    FreebuffError::ConnectionFailed
                    | FreebuffError::InvalidResponse
                    | FreebuffError::RequestFailed(_)
                    | FreebuffError::QuotaUnavailable
                    | FreebuffError::LocalHistoryUnreadable
                    | FreebuffError::LiveAccessUnavailable => error.clone(),
                    _ => FreebuffError::InvalidResponse,
                };
                self.state.lock().unwrap_or_else(|e| e.into_inner()).last_failure = Some(recorded);
                Err(error)
            }
        }
    }

    /// The network half of [`refresh`](Self::refresh): fetch, validate, persist. Returns the new cache.
    fn fetch(
        &self,
        auth: &FreebuffAuth,
        client: &HostedClient,
        now: Timestamp,
        cancel: &CancelToken,
    ) -> Result<Cache, FreebuffError> {
        #[derive(Deserialize)]
        struct Wire {
            protocol: i64,
            rows: Vec<Entry>,
        }
        let response = client.fetch_model_catalog(auth, cancel)?;
        if !response.is_success() {
            return Err(FreebuffError::RequestFailed(i64::from(response.status)));
        }
        let wire: Wire = serde_json::from_slice(&response.body).map_err(|_| FreebuffError::InvalidResponse)?;
        let keys: HashSet<&str> = wire.rows.iter().map(|r| r.key.as_str()).collect();
        if wire.protocol != 1
            || wire.rows.is_empty()
            || !wire.rows.iter().all(|r| !r.key.is_empty() && !r.display_name.is_empty())
            || keys.len() != wire.rows.len()
        {
            return Err(FreebuffError::InvalidResponse);
        }
        let replacement = Cache { fetched_at: now - REFERENCE_DATE_UNIX, entries: wire.rows };
        if let Some(path) = self.cache_path() {
            let bytes = serde_json::to_vec(&replacement).map_err(|_| FreebuffError::InvalidResponse)?;
            crate::paths::write_atomic(&path, &bytes).map_err(|error| {
                qlog!(Warn, plugin_tag("freebuff"), "model identity cache write failed: {error}");
                FreebuffError::InvalidResponse
            })?;
        }
        Ok(replacement)
    }
}

/// Exact normalized names and explicit supplement aliases only; preserve every version/variant
/// word. Ambiguous routes remain unpriced. No fuzzy lookup or opaque-key-to-model guessing.
pub fn pricing_route(model: &str, entries: &HashMap<String, Entry>, pricing: &ModelPricing) -> Option<String> {
    let mut identity = FreebuffModelIdentity::new(entries, pricing);
    identity.resolve(model, pricing, false).route
}

pub fn pricing_routes(entries: &HashMap<String, Entry>, pricing: &ModelPricing) -> HashMap<String, String> {
    let mut index: BTreeMap<String, Vec<&String>> = BTreeMap::new();
    for key in pricing.open_router.entries.keys().filter(|k| k.contains('/')) {
        let last = key.split('/').filter(|part| !part.is_empty()).next_back().unwrap_or(key);
        index.entry(normalized(last)).or_default().push(key);
    }
    let mut routes: HashMap<String, String> = HashMap::new();
    for (model, entry) in entries {
        if fast_base_name(&entry.display_name).is_some() {
            continue;
        }
        if let Some(matches) = index.get(&normalized(&entry.display_name)) {
            if matches.len() == 1 && fast_base_name(matches[0]).is_none() {
                routes.insert(model.clone(), matches[0].clone());
            }
        }
    }
    // Curated fallback aliases do not prove a Fast serving route either.
    for (model, entry) in entries {
        if routes.contains_key(model) || fast_base_name(&entry.display_name).is_some() {
            continue;
        }
        let Some(canonical) = pricing.supplement.canonical_name(&entry.display_name) else { continue };
        if fast_base_name(&canonical).is_some() || !pricing.supplement.pricing.contains_key(&canonical) {
            continue;
        }
        routes.insert(model.clone(), canonical);
    }
    routes
}

fn regex(slot: &'static OnceLock<Regex>, pattern: &str) -> &'static Regex {
    slot.get_or_init(|| Regex::new(pattern).expect("static regex"))
}

/// Recognizes a tier suffix, not words like Flash or FastAPI. Some labels end in a build date.
pub fn fast_base_name(name: &str) -> Option<String> {
    static FAST_SUFFIX: OnceLock<Regex> = OnceLock::new();
    let trimmed = name.trim();
    let found = regex(&FAST_SUFFIX, r"(?i)[\s_-]+fast(?:[\s_-]+(?:\d{1,2}/\d{1,2}|\d{4}))?$").find(trimmed)?;
    Some(trimmed[..found.start()].to_string())
}

fn normalized(name: &str) -> String {
    // Freebuff labels the same Haiku route once with an extra "100k context" descriptor. It is
    // a context annotation, not a distinct route; per-request context tiers cannot be applied to
    // its aggregated turn receipts, so route it to the exact base model entry.
    static CONTEXT: OnceLock<Regex> = OnceLock::new();
    let route_name = regex(&CONTEXT, r"(?i)\s*(?:[·•]\s*)?100k\s+context$").replace_all(name, "").into_owned();
    let lowered: Vec<char> = route_name.to_lowercase().chars().collect();
    // `\bv(?=\d)` removed: a "v" that starts a word and is followed by a digit.
    let mut kept = String::with_capacity(lowered.len());
    for (index, ch) in lowered.iter().enumerate() {
        let starts_word = index == 0 || !is_word_char(lowered[index - 1]);
        let before_digit = lowered.get(index + 1).is_some_and(|next| next.is_ascii_digit());
        if *ch == 'v' && starts_word && before_digit {
            continue;
        }
        kept.push(*ch);
    }
    kept.chars().filter(|c| c.is_alphabetic() || c.is_numeric()).collect()
}

fn is_word_char(ch: char) -> bool {
    ch.is_alphanumeric() || ch == '_'
}

/// Catalogue labels retain real model versions, but mode/build/context annotations need not repeat a
/// model in the compact breakdown. Full source labels survive as accounting variants.
pub fn group_name(name: &str) -> String {
    static CONTEXT: OnceLock<Regex> = OnceLock::new();
    static DATE: OnceLock<Regex> = OnceLock::new();
    static TIER: OnceLock<Regex> = OnceLock::new();
    let without_context = regex(&CONTEXT, r"(?i)\s*(?:[·•]\s*)?\d+k\s+context$").replace_all(name, "");
    let without_date = regex(&DATE, r"\s+\d{1,2}/\d{1,2}$").replace_all(&without_context, "");
    let without_tier = regex(&TIER, r"(?i)\s+(?:Fast|Slow)$").replace_all(&without_date, "");
    without_tier.trim().to_string()
}
