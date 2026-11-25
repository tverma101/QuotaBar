//! Freebuff's public model identities (`FreebuffModelCatalog`).
//!
//! Freebuff records opaque model keys (`m-…`) and legacy digests instead of route names. The saved
//! catalogue maps them back to public display names so the scanner can price them. It keeps only
//! public identities, never handles or credentials. The file format matches the Swift app's, so
//! either build reads what the other saved.

use super::auth::FreebuffAuth;
use super::client::{ClientError, FreebuffClient};
use crate::context::CancelToken;
use crate::host;
use crate::qlog;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::UNIX_EPOCH;

const FILE_NAME: &str = "freebuff-model-identities.json";
/// Foundation's reference date (2001-01-01) in unix seconds; the saved `fetchedAt` counts from it.
const REFERENCE_DATE: f64 = 978_307_200.0;
/// How long a fetched catalogue stays fresh.
const REFRESH_SECS: f64 = 3_600.0;
/// The minimum gap between attempts, so a failing endpoint is not re-requested every tick.
const RETRY_SECS: f64 = 3_600.0;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CatalogEntry {
    pub key: String,
    #[serde(rename = "displayName")]
    pub display_name: String,
    #[serde(
        rename = "legacyDigests",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub legacy_digests: Option<Vec<String>>,
}

pub type CatalogEntries = HashMap<String, CatalogEntry>;

#[derive(Serialize, Deserialize)]
struct SavedCatalog {
    #[serde(rename = "fetchedAt")]
    fetched_at: f64,
    entries: Vec<CatalogEntry>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CatalogError {
    Cancelled,
    Request(ClientError),
    Invalid,
    Unsaved,
}

#[derive(Default)]
struct State {
    /// The saved file's `(length, modified)` at the last read; `None` when it was missing.
    revision: Option<(u64, u128)>,
    read_once: bool,
    fetched_at: Option<f64>,
    entries: Arc<CatalogEntries>,
    last_attempt_at: Option<f64>,
    last_failure: Option<CatalogError>,
}

pub struct ModelCatalog {
    path: PathBuf,
    state: Mutex<State>,
}

impl ModelCatalog {
    pub fn live() -> Self {
        ModelCatalog::at(crate::paths::app_data().join(FILE_NAME))
    }

    /// The Swift app's location under a given home (tests and alternate homes).
    pub fn under_home(home: &Path) -> Self {
        ModelCatalog::at(
            home.join("Library/Application Support/QuotaBar")
                .join(FILE_NAME),
        )
    }

    pub fn at(path: PathBuf) -> Self {
        ModelCatalog {
            path,
            state: Mutex::new(State::default()),
        }
    }

    /// The saved identities, re-read only when the file changed.
    pub fn current(&self) -> Arc<CatalogEntries> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        self.reload(&mut state);
        state.entries.clone()
    }

    fn reload(&self, state: &mut State) {
        let revision = file_revision(&self.path);
        if state.read_once && revision == state.revision {
            return;
        }
        state.read_once = true;
        state.revision = revision;
        state.entries = Arc::default();
        state.fetched_at = None;
        if revision.is_none() {
            return;
        }
        let decoded = std::fs::read(&self.path)
            .map_err(|error| error.to_string())
            .and_then(|bytes| {
                serde_json::from_slice::<SavedCatalog>(&bytes).map_err(|error| error.to_string())
            });
        match decoded {
            Ok(saved) => {
                state.fetched_at = Some(saved.fetched_at + REFERENCE_DATE);
                state.entries = Arc::new(index(saved.entries));
            }
            Err(error) => qlog!(
                Warn,
                host::auth_tag("freebuff"),
                "saved model identities could not be decoded: {error}"
            ),
        }
    }

    /// Fetch a fresh catalogue at most hourly, backing off failures at the same cadence. The
    /// caller decides whether this build may make the request at all.
    pub fn refresh(
        &self,
        auth: &FreebuffAuth,
        client: &FreebuffClient,
        now: f64,
        cancel: &CancelToken,
    ) -> Result<(), CatalogError> {
        {
            let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
            self.reload(&mut state);
            if state.fetched_at.is_some_and(|at| now - at < REFRESH_SECS) {
                return Ok(());
            }
            if state
                .last_attempt_at
                .is_some_and(|at| now - at < RETRY_SECS)
            {
                return state.last_failure.map_or(Ok(()), Err);
            }
            state.last_attempt_at = Some(now);
        }
        let outcome = self.fetch_and_save(auth, client, now, cancel);
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        match outcome {
            Ok(entries) => {
                state.revision = file_revision(&self.path);
                state.read_once = true;
                state.fetched_at = Some(now);
                state.entries = Arc::new(entries);
                state.last_failure = None;
                Ok(())
            }
            Err(CatalogError::Cancelled) => {
                // A cancelled refresh is not a failed endpoint; the next one may try right away.
                state.last_attempt_at = None;
                Err(CatalogError::Cancelled)
            }
            Err(error) => {
                state.last_failure = Some(error);
                Err(error)
            }
        }
    }

    fn fetch_and_save(
        &self,
        auth: &FreebuffAuth,
        client: &FreebuffClient,
        now: f64,
        cancel: &CancelToken,
    ) -> Result<CatalogEntries, CatalogError> {
        let response = client.fetch_model_catalog(auth, cancel);
        if cancel.is_cancelled() {
            return Err(CatalogError::Cancelled);
        }
        let response = response.map_err(CatalogError::Request)?;
        if !(200..300).contains(&response.status) {
            return Err(CatalogError::Request(ClientError::RequestFailed(
                response.status,
            )));
        }
        #[derive(Deserialize)]
        struct Wire {
            protocol: i64,
            rows: Vec<CatalogEntry>,
        }
        let wire: Wire =
            serde_json::from_slice(&response.body).map_err(|_| CatalogError::Invalid)?;
        let unique: HashSet<&str> = wire.rows.iter().map(|row| row.key.as_str()).collect();
        let valid = wire.protocol == 1
            && !wire.rows.is_empty()
            && wire
                .rows
                .iter()
                .all(|row| !row.key.is_empty() && !row.display_name.is_empty())
            && unique.len() == wire.rows.len();
        if !valid {
            return Err(CatalogError::Invalid);
        }
        let saved = SavedCatalog {
            fetched_at: now - REFERENCE_DATE,
            entries: wire.rows,
        };
        let bytes = serde_json::to_vec(&saved).map_err(|_| CatalogError::Unsaved)?;
        crate::paths::write_atomic(&self.path, &bytes).map_err(|error| {
            qlog!(
                Warn,
                host::auth_tag("freebuff"),
                "model identities could not be saved: {error}"
            );
            CatalogError::Unsaved
        })?;
        Ok(index(saved.entries))
    }
}

/// Keyed by opaque key; a repeated key keeps its last row, as the Swift catalogue did.
fn index(entries: Vec<CatalogEntry>) -> CatalogEntries {
    entries
        .into_iter()
        .map(|entry| (entry.key.clone(), entry))
        .collect()
}

fn file_revision(path: &Path) -> Option<(u64, u128)> {
    let metadata = std::fs::metadata(path).ok()?;
    let modified = metadata.modified().ok()?.duration_since(UNIX_EPOCH).ok()?;
    Some((metadata.len(), modified.as_nanos()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::http::mock::MockClient;

    const ROWS: &str = r#"{"protocol":1,"rows":[{"key":"m-a","displayName":"Model A"}]}"#;

    #[test]
    fn refresh_saves_the_swift_format_and_backs_off() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("identities.json");
        let catalog = ModelCatalog::at(path.clone());
        let auth = FreebuffAuth {
            token: "token".into(),
        };
        let now = 1_800_000_000.0;
        let http = MockClient::new(vec![MockClient::json(200, ROWS)]);
        let client = FreebuffClient::new(http.clone());
        assert_eq!(
            catalog.refresh(&auth, &client, now, &CancelToken::new()),
            Ok(())
        );
        assert_eq!(catalog.current()["m-a"].display_name, "Model A");
        let saved: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(saved["fetchedAt"].as_f64(), Some(now - REFERENCE_DATE));
        assert_eq!(saved["entries"][0]["displayName"], "Model A");

        // Fresh within the hour: no second request, even from a new reader of the same file.
        let reader = ModelCatalog::at(path);
        assert_eq!(
            reader.refresh(&auth, &client, now + 60.0, &CancelToken::new()),
            Ok(())
        );
        assert_eq!(http.requests.lock().unwrap().len(), 1);
    }

    #[test]
    fn a_failed_refresh_keeps_reporting_without_re_requesting() {
        let dir = tempfile::tempdir().unwrap();
        let catalog = ModelCatalog::at(dir.path().join("identities.json"));
        let auth = FreebuffAuth {
            token: "token".into(),
        };
        let http = MockClient::new(vec![MockClient::json(200, r#"{"protocol":2,"rows":[]}"#)]);
        let client = FreebuffClient::new(http.clone());
        let now = 1_800_000_000.0;
        let cancel = CancelToken::new();
        assert_eq!(
            catalog.refresh(&auth, &client, now, &cancel),
            Err(CatalogError::Invalid)
        );
        assert_eq!(
            catalog.refresh(&auth, &client, now + 60.0, &cancel),
            Err(CatalogError::Invalid)
        );
        assert_eq!(http.requests.lock().unwrap().len(), 1);
        assert!(catalog.current().is_empty());
    }
}
