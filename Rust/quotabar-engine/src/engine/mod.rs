//! The engine's front door: provider registry, cancellation tracking, and JSON RPC protocol.
//!
//! Requests are `{"method": ..., "params": {...}}`; replies are `{"ok": <result>}` or
//! `{"error": "<message>"}`.

mod batch;
mod dispatch;

use crate::context::{CancelToken, RefreshContext};
use crate::model::ProviderSnapshot;
use crate::providers::{self, ProviderRuntime};
use crate::qlog;
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

pub struct Engine {
    providers: Vec<Arc<dyn ProviderRuntime>>,
    in_flight: Mutex<HashMap<u64, CancelToken>>,
    batch_children: Mutex<HashMap<u64, Vec<CancelToken>>>,
}

impl Engine {
    pub fn new(providers: Vec<Arc<dyn ProviderRuntime>>) -> Self {
        Engine {
            providers,
            in_flight: Mutex::new(HashMap::new()),
            batch_children: Mutex::new(HashMap::new()),
        }
    }

    /// The process-wide engine with every built-in provider.
    pub fn global() -> &'static Engine {
        static ENGINE: OnceLock<Engine> = OnceLock::new();
        ENGINE.get_or_init(|| Engine::new(providers::all()))
    }

    /// The runtime for `id`. An account card (`codex@…`, `claude@…`) runs on its family's runtime,
    /// whose config names the account.
    pub fn provider(&self, id: &str) -> Option<Arc<dyn ProviderRuntime>> {
        let exact = |id: &str| self.providers.iter().find(|p| p.info().id == id).cloned();
        exact(id).or_else(|| match id.split_once('@') {
            Some((family, _)) => exact(family),
            None => None,
        })
    }

    pub fn providers(&self) -> &[Arc<dyn ProviderRuntime>] {
        &self.providers
    }

    pub fn provider_ids(&self) -> Vec<String> {
        self.providers.iter().map(|p| p.info().id.clone()).collect()
    }

    pub(crate) fn register_token(&self, request_id: Option<u64>, token: &mut CancelToken) {
        let Some(request_id) = request_id else { return };
        let mut in_flight = self.in_flight.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(existing) = in_flight.get(&request_id) {
            *token = existing.clone();
        } else {
            in_flight.insert(request_id, token.clone());
        }
    }

    pub(crate) fn finish_token(&self, request_id: Option<u64>) {
        if let Some(request_id) = request_id {
            self.in_flight
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .remove(&request_id);
        }
    }

    pub(crate) fn register_batch_child(&self, batch_id: Option<u64>, child: &CancelToken) {
        let Some(batch_id) = batch_id else { return };
        self.batch_children
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .entry(batch_id)
            .or_default()
            .push(child.clone());
    }

    pub(crate) fn clear_batch_children(&self, batch_id: Option<u64>) {
        if let Some(batch_id) = batch_id {
            self.batch_children
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .remove(&batch_id);
        }
    }

    /// Refresh one provider and return both its snapshot and any observed identity key.
    pub fn refresh_with_identity(
        &self,
        id: &str,
        mut ctx: RefreshContext,
        request_id: Option<u64>,
    ) -> Option<(ProviderSnapshot, Option<String>)> {
        let provider = self.provider(id)?;
        ctx.request_id = request_id;
        self.register_token(request_id, &mut ctx.cancel);
        ctx.cancel.serial_scan = ctx.paced;
        let started = Instant::now();
        let snapshot = provider.refresh(&ctx);
        self.finish_token(request_id);
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
        let identity = ctx.observed_identity_key();
        Some((snapshot, identity))
    }

    /// Refresh one provider. `request_id` registers the call so [`Engine::cancel`] can stop it.
    pub fn refresh(
        &self,
        id: &str,
        ctx: RefreshContext,
        request_id: Option<u64>,
    ) -> Option<ProviderSnapshot> {
        self.refresh_with_identity(id, ctx, request_id)
            .map(|(snapshot, _)| snapshot)
    }

    /// Cancel an in-flight (or not yet started) refresh or batch. Returns whether it was in flight.
    pub fn cancel(&self, request_id: u64) -> bool {
        let was_present = {
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
        };
        if let Some(children) = self
            .batch_children
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(&request_id)
        {
            for child in children {
                child.cancel();
            }
        }
        was_present
    }

    /// Handle one JSON request and return the JSON reply.
    pub fn call(&self, request: &str) -> String {
        let reply = match serde_json::from_str::<Envelope>(request) {
            Ok(envelope) => dispatch::dispatch(self, &envelope.method, envelope.params),
            Err(error) => Err(format!("malformed request: {error}")),
        };
        match reply {
            Ok(value) => json!({ "ok": value }).to_string(),
            Err(message) => json!({ "error": message }).to_string(),
        }
    }
}

#[derive(Deserialize)]
struct Envelope {
    method: String,
    #[serde(default)]
    params: Value,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::context::Scope;
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
        Arc::new(Engine::new(vec![Arc::new(Slow {
            info: ProviderInfo {
                id: "slow".into(),
                display_name: "Slow".into(),
            },
        })]))
    }

    #[test]
    fn dispatches_json_requests() {
        let engine = engine();
        let reply: Value = serde_json::from_str(&engine.call(r#"{"method":"providers"}"#)).unwrap();
        assert_eq!(reply["ok"][0]["id"], "slow");
        let reply: Value = serde_json::from_str(
            &engine.call(r#"{"method":"hasLocalCredentials","params":{"providerId":"slow"}}"#),
        )
        .unwrap();
        assert_eq!(reply["ok"], true);
        let reply: Value = serde_json::from_str(
            &engine.call(r#"{"method":"refresh","params":{"providerId":"nope"}}"#),
        )
        .unwrap();
        assert_eq!(reply["error"], "unknown provider: nope");
        // Regression: account cards failed every single refresh with "unknown provider".
        for method in ["refresh", "hasLocalCredentials"] {
            let reply: Value = serde_json::from_str(&engine.call(&format!(
                r#"{{"method":"{method}","params":{{"providerId":"slow@account-b"}}}}"#
            )))
            .unwrap();
            assert!(reply["error"].is_null(), "{method}: {reply}");
        }
        let reply: Value = serde_json::from_str(
            &engine.call(r#"{"method":"refresh","params":{"providerId":"nope@account"}}"#),
        )
        .unwrap();
        assert_eq!(reply["error"], "unknown provider: nope@account");
        let reply: Value = serde_json::from_str(&engine.call("not json")).unwrap();
        assert!(reply["error"]
            .as_str()
            .unwrap()
            .starts_with("malformed request"));
    }

    #[test]
    fn cancel_stops_an_in_flight_refresh() {
        let engine = engine();
        let worker = {
            let engine = engine.clone();
            std::thread::spawn(move || {
                engine.call(
                    r#"{"method":"refresh","params":{"providerId":"slow","requestId":7,"now":5}}"#,
                )
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
