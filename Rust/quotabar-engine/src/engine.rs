//! The engine's front door: a provider registry plus a small JSON request protocol that both the
//! macOS C ABI and the Windows app use.
//!
//! Requests are `{"method": ..., "params": {...}}`; replies are `{"ok": <result>}` or
//! `{"error": "<message>"}`. Methods:
//!
//! | method                | params                                              | result                 |
//! |-----------------------|-----------------------------------------------------|------------------------|
//! | `configure`           | `{home, appData, logLevel?}`                        | `null`                 |
//! | `providers`           | –                                                   | `[{id, displayName}]`  |
//! | `hasLocalCredentials` | `{providerId}`                                      | `bool`                 |
//! | `refresh`             | `{providerId, scope?, isManual?, requestId?, now?, skipModelCatalogRefresh?}` | `ProviderSnapshot` |
//! | `cancel`              | `{requestId}`                                       | `bool` (was in flight) |

use crate::context::{CancelToken, RefreshContext, Scope};
use crate::model::ProviderSnapshot;
use crate::paths::{self, Paths};
use crate::providers::{self, ProviderRuntime};
use crate::qlog;
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

pub struct Engine {
    providers: Vec<Arc<dyn ProviderRuntime>>,
    in_flight: Mutex<HashMap<u64, CancelToken>>,
}

impl Engine {
    pub fn new(providers: Vec<Arc<dyn ProviderRuntime>>) -> Self {
        Engine { providers, in_flight: Mutex::new(HashMap::new()) }
    }

    /// The process-wide engine with every built-in provider.
    pub fn global() -> &'static Engine {
        static ENGINE: OnceLock<Engine> = OnceLock::new();
        ENGINE.get_or_init(|| Engine::new(providers::all()))
    }

    pub fn provider(&self, id: &str) -> Option<Arc<dyn ProviderRuntime>> {
        self.providers.iter().find(|p| p.info().id == id).cloned()
    }

    pub fn provider_ids(&self) -> Vec<String> {
        self.providers.iter().map(|p| p.info().id.clone()).collect()
    }

    /// Refresh one provider. `request_id` registers the call so [`Engine::cancel`] can stop it.
    pub fn refresh(&self, id: &str, mut ctx: RefreshContext, request_id: Option<u64>) -> Option<ProviderSnapshot> {
        let provider = self.provider(id)?;
        ctx.request_id = request_id;
        if let Some(request_id) = request_id {
            // A cancel that raced ahead of its refresh already left a cancelled token here.
            let mut in_flight = self.in_flight.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(existing) = in_flight.get(&request_id) {
                ctx.cancel = existing.clone();
            } else {
                in_flight.insert(request_id, ctx.cancel.clone());
            }
        }
        let started = Instant::now();
        let snapshot = provider.refresh(&ctx);
        if let Some(request_id) = request_id {
            self.in_flight.lock().unwrap_or_else(|e| e.into_inner()).remove(&request_id);
        }
        // Model names this refresh could not price queue a background OpenRouter revalidation, under
        // this refresh's catalogue policy (a menu-bar pass never downloads an existing catalogue).
        if !ctx.is_cancelled() {
            if let Some(pricing) = crate::pricing::shared_if_initialized() {
                pricing.schedule_discovery_if_queued(ctx.skip_model_catalog_refresh);
            }
        }
        qlog!(
            Debug,
            "engine",
            "refresh {} scope={:?} {} in {}ms",
            id,
            ctx.scope,
            if snapshot.is_error() { "error" } else { "ok" },
            started.elapsed().as_millis()
        );
        Some(snapshot)
    }

    /// Cancel an in-flight (or not yet started) refresh. Returns whether it was in flight.
    pub fn cancel(&self, request_id: u64) -> bool {
        let mut in_flight = self.in_flight.lock().unwrap_or_else(|e| e.into_inner());
        match in_flight.get(&request_id) {
            Some(token) => {
                token.cancel();
                true
            }
            None => {
                let token = CancelToken::new();
                token.cancel();
                in_flight.insert(request_id, token);
                false
            }
        }
    }

    /// Handle one JSON request and return the JSON reply.
    pub fn call(&self, request: &str) -> String {
        let reply = match serde_json::from_str::<Envelope>(request) {
            Ok(envelope) => self.dispatch(&envelope.method, envelope.params),
            Err(error) => Err(format!("malformed request: {error}")),
        };
        match reply {
            Ok(value) => json!({ "ok": value }).to_string(),
            Err(message) => json!({ "error": message }).to_string(),
        }
    }

    fn dispatch(&self, method: &str, params: Value) -> Result<Value, String> {
        match method {
            "configure" => {
                let p: ConfigureParams = from_params(params)?;
                paths::configure(Paths { home: PathBuf::from(p.home), app_data: PathBuf::from(p.app_data) });
                Ok(Value::Null)
            }
            "providers" => Ok(Value::Array(
                self.providers
                    .iter()
                    .map(|p| json!({ "id": p.info().id, "displayName": p.info().display_name }))
                    .collect(),
            )),
            "sqliteQuery" => {
                let p: SqliteParams = from_params(params)?;
                crate::sqlite::query_text(&p.path, &p.sql, p.allow_wal_retry)
                    .map(|value| json!(value))
                    .map_err(|error| error.to_string())
            }
            "sqliteExecute" => {
                let p: SqliteParams = from_params(params)?;
                crate::sqlite::execute(&p.path, &p.sql)
                    .map(|_| Value::Null)
                    .map_err(|error| error.to_string())
            }
            "hasLocalCredentials" => {
                let p: ProviderParams = from_params(params)?;
                let provider = self.provider(&p.provider_id).ok_or_else(|| unknown(&p.provider_id))?;
                Ok(Value::Bool(provider.has_local_credentials()))
            }
            "refresh" => {
                let p: RefreshParams = from_params(params)?;
                let mut ctx = RefreshContext::new(p.scope.unwrap_or(Scope::Full));
                ctx.is_manual = p.is_manual.unwrap_or(false);
                ctx.skip_model_catalog_refresh = p.skip_model_catalog_refresh.unwrap_or(false);
                if let Some(now) = p.now {
                    ctx.now = now;
                }
                let snapshot = self.refresh(&p.provider_id, ctx, p.request_id).ok_or_else(|| unknown(&p.provider_id))?;
                serde_json::to_value(snapshot).map_err(|e| e.to_string())
            }
            "cancel" => {
                let p: CancelParams = from_params(params)?;
                Ok(Value::Bool(self.cancel(p.request_id)))
            }
            other => Err(format!("unknown method: {other}")),
        }
    }
}

fn unknown(id: &str) -> String {
    format!("unknown provider: {id}")
}

fn from_params<T: for<'de> Deserialize<'de>>(params: Value) -> Result<T, String> {
    serde_json::from_value(params).map_err(|e| format!("invalid params: {e}"))
}

#[derive(Deserialize)]
struct Envelope {
    method: String,
    #[serde(default)]
    params: Value,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConfigureParams {
    home: String,
    app_data: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProviderParams {
    provider_id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SqliteParams {
    path: PathBuf,
    sql: String,
    #[serde(default)]
    allow_wal_retry: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RefreshParams {
    provider_id: String,
    scope: Option<Scope>,
    is_manual: Option<bool>,
    request_id: Option<u64>,
    now: Option<f64>,
    skip_model_catalog_refresh: Option<bool>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CancelParams {
    request_id: u64,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{ErrorCategory, ProviderInfo};

    struct Slow {
        info: ProviderInfo,
    }

    impl ProviderRuntime for Slow {
        fn info(&self) -> &ProviderInfo {
            &self.info
        }
        fn has_local_credentials(&self) -> bool {
            true
        }
        fn refresh(&self, ctx: &RefreshContext) -> ProviderSnapshot {
            for _ in 0..200 {
                if ctx.is_cancelled() {
                    return providers::cancelled_snapshot(&self.info, ctx);
                }
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
            ProviderSnapshot::new(&self.info, None, vec![], ctx.now)
        }
    }

    fn engine() -> Arc<Engine> {
        Arc::new(Engine::new(vec![Arc::new(Slow { info: ProviderInfo { id: "slow".into(), display_name: "Slow".into() } })]))
    }

    #[test]
    fn dispatches_json_requests() {
        let engine = engine();
        let reply: Value = serde_json::from_str(&engine.call(r#"{"method":"providers"}"#)).unwrap();
        assert_eq!(reply["ok"][0]["id"], "slow");
        let reply: Value =
            serde_json::from_str(&engine.call(r#"{"method":"hasLocalCredentials","params":{"providerId":"slow"}}"#)).unwrap();
        assert_eq!(reply["ok"], true);
        let reply: Value =
            serde_json::from_str(&engine.call(r#"{"method":"refresh","params":{"providerId":"nope"}}"#)).unwrap();
        assert_eq!(reply["error"], "unknown provider: nope");
        let reply: Value = serde_json::from_str(&engine.call("not json")).unwrap();
        assert!(reply["error"].as_str().unwrap().starts_with("malformed request"));
    }

    #[test]
    fn cancel_stops_an_in_flight_refresh() {
        let engine = engine();
        let worker = {
            let engine = engine.clone();
            std::thread::spawn(move || {
                engine.call(r#"{"method":"refresh","params":{"providerId":"slow","requestId":7,"now":5}}"#)
            })
        };
        std::thread::sleep(std::time::Duration::from_millis(30));
        assert!(engine.cancel(7));
        let reply: Value = serde_json::from_str(&worker.join().unwrap()).unwrap();
        assert_eq!(reply["ok"]["errorCategory"], "cancelled");
        assert_eq!(reply["ok"]["refreshedAt"], 5.0);
    }

    #[test]
    fn cancel_before_start_still_cancels() {
        let engine = engine();
        assert!(!engine.cancel(9));
        let ctx = RefreshContext::new(Scope::Full);
        let snapshot = engine.refresh("slow", ctx, Some(9)).unwrap();
        assert_eq!(snapshot.error_category, Some(ErrorCategory::Cancelled));
    }
}
