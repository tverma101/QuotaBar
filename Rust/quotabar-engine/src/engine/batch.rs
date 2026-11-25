use super::Engine;
use crate::context::{now_timestamp, CancelToken, RefreshContext, Scope};
use crate::model::ProviderSnapshot;
use crate::providers::ProviderRuntime;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::sync::{mpsc, Arc};
use std::time::{Duration, Instant};

const DEFAULT_PROVIDER_TIMEOUT_SECS: f64 = 120.0;
const MIN_REMAINING_BUDGET_SECS: f64 = 5.0;

const HEAVY_LOCAL_LOG_PROVIDERS: [&str; 10] = [
    "claude",
    "codex",
    "opencode",
    "grok",
    "muse",
    "pi",
    "hermes",
    "freebuff",
    "cursor",
    "antigravity",
];

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct BatchItem {
    pub provider_id: String,
    #[serde(default)]
    pub config: Option<Value>,
    #[serde(default)]
    pub default_identity_key: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct BatchParams {
    pub items: Vec<BatchItem>,
    pub scope: Option<Scope>,
    pub is_manual: Option<bool>,
    pub skip_model_catalog_refresh: Option<bool>,
    pub per_provider_timeout_seconds: Option<f64>,
    pub batch_budget_seconds: Option<f64>,
    pub paced: Option<bool>,
    pub request_id: Option<u64>,
    pub now: Option<f64>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct BatchResponse {
    pub snapshots: BTreeMap<String, ProviderSnapshot>,
    pub errors: BTreeMap<String, String>,
    pub identity_keys: BTreeMap<String, String>,
}

struct Outcome {
    provider_id: String,
    default_identity_key: Option<String>,
    snapshot: Option<ProviderSnapshot>,
    observed_identity_key: Option<String>,
}

pub(super) fn run(engine: &Engine, params: BatchParams) -> BatchResponse {
    let scope = params.scope.unwrap_or(Scope::PanelAccounting);
    let mut batch_cancel = CancelToken::new();
    engine.register_token(params.request_id, &mut batch_cancel);

    let base_now = params.now.unwrap_or_else(now_timestamp);
    let is_manual = params.is_manual.unwrap_or(false);
    let skip_catalog = params.skip_model_catalog_refresh.unwrap_or(true);
    let paced = params.paced.unwrap_or(false);
    let per_provider_timeout = params
        .per_provider_timeout_seconds
        .filter(|s| s.is_finite() && *s > 0.0)
        .unwrap_or(DEFAULT_PROVIDER_TIMEOUT_SECS);
    let batch_budget = params
        .batch_budget_seconds
        .filter(|s| s.is_finite() && *s > 0.0);
    let batch_start = Instant::now();

    let mut light = Vec::new();
    let mut heavy = Vec::new();
    for item in params.items {
        if is_heavy_provider(&item.provider_id, scope) {
            heavy.push(item);
        } else {
            light.push(item);
        }
    }

    let mut response = BatchResponse {
        snapshots: BTreeMap::new(),
        errors: BTreeMap::new(),
        identity_keys: BTreeMap::new(),
    };

    let run_one = |item: &BatchItem| -> Option<Outcome> {
        run_item(
            engine,
            item,
            scope,
            is_manual,
            skip_catalog,
            paced,
            base_now,
            &batch_cancel,
            params.request_id,
            batch_start,
            per_provider_timeout,
            batch_budget,
        )
    };

    let light_outcomes: Vec<Option<Outcome>> = if light.len() <= 1 {
        light.iter().map(run_one).collect()
    } else {
        std::thread::scope(|s| {
            let handles: Vec<_> = light.iter().map(|item| s.spawn(|| run_one(item))).collect();
            handles
                .into_iter()
                .map(|h| h.join().ok().flatten())
                .collect()
        })
    };
    for outcome in light_outcomes.into_iter().flatten() {
        record(&mut response, outcome, scope);
    }

    for item in &heavy {
        if batch_cancel.is_cancelled() {
            break;
        }
        if let Some(outcome) = run_one(item) {
            record(&mut response, outcome, scope);
        }
    }

    engine.clear_batch_children(params.request_id);
    engine.finish_token(params.request_id);
    response
}

#[allow(clippy::too_many_arguments)]
fn run_item(
    engine: &Engine,
    item: &BatchItem,
    scope: Scope,
    is_manual: bool,
    skip_model_catalog_refresh: bool,
    paced: bool,
    now: f64,
    batch_cancel: &CancelToken,
    batch_request_id: Option<u64>,
    batch_start: Instant,
    per_provider_timeout: f64,
    batch_budget: Option<f64>,
) -> Option<Outcome> {
    if batch_cancel.is_cancelled() {
        return None;
    }
    let Some(provider) = resolve_provider(engine, &item.provider_id) else {
        return None;
    };
    let remaining = batch_budget.map(|b| b - batch_start.elapsed().as_secs_f64());
    if remaining.is_some_and(|r| r < MIN_REMAINING_BUDGET_SECS) {
        return None;
    }
    let timeout_secs = remaining.map_or(per_provider_timeout, |r| per_provider_timeout.min(r));

    let mut ctx = RefreshContext::new(scope);
    ctx.is_manual = is_manual;
    ctx.skip_model_catalog_refresh = skip_model_catalog_refresh;
    ctx.paced = paced;
    ctx.now = now;
    ctx.config = item.config.clone();
    let child_cancel = ctx.cancel.clone();
    engine.register_batch_child(batch_request_id, &child_cancel);

    let (tx, rx) = mpsc::sync_channel::<(ProviderSnapshot, Option<String>)>(1);
    let spawned = std::thread::Builder::new()
        .name(format!("quotabar-batch-{}", item.provider_id))
        .spawn(move || {
            let snapshot = provider.refresh(&ctx);
            let observed = ctx.observed_identity_key();
            let _ = tx.send((snapshot, observed));
        });
    if spawned.is_err() {
        return Some(Outcome {
            provider_id: item.provider_id.clone(),
            default_identity_key: item.default_identity_key.clone(),
            snapshot: None,
            observed_identity_key: None,
        });
    }

    let deadline = Instant::now() + Duration::from_secs_f64(timeout_secs.max(0.05));
    loop {
        if batch_cancel.is_cancelled() {
            child_cancel.cancel();
            return None;
        }
        let now_inst = Instant::now();
        if now_inst >= deadline {
            child_cancel.cancel();
            return Some(Outcome {
                provider_id: item.provider_id.clone(),
                default_identity_key: item.default_identity_key.clone(),
                snapshot: None,
                observed_identity_key: None,
            });
        }
        let step = Duration::from_millis(50).min(deadline - now_inst);
        match rx.recv_timeout(step) {
            Ok((snapshot, observed)) => {
                if batch_cancel.is_cancelled() {
                    return None;
                }
                return Some(Outcome {
                    provider_id: item.provider_id.clone(),
                    default_identity_key: item.default_identity_key.clone(),
                    snapshot: Some(snapshot),
                    observed_identity_key: observed,
                });
            }
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                return Some(Outcome {
                    provider_id: item.provider_id.clone(),
                    default_identity_key: item.default_identity_key.clone(),
                    snapshot: None,
                    observed_identity_key: None,
                });
            }
        }
    }
}

fn record(response: &mut BatchResponse, outcome: Outcome, scope: Scope) {
    let family = provider_family(&outcome.provider_id);
    if let Some(snapshot) = outcome.snapshot {
        response
            .snapshots
            .insert(outcome.provider_id.clone(), snapshot);
        // Antigravity local history is machine-local; a fold must never publish a quota identity.
        if !(scope.suppresses_live_quota() && family == "antigravity") {
            if let Some(key) = outcome
                .observed_identity_key
                .or(outcome.default_identity_key)
            {
                response.identity_keys.insert(outcome.provider_id, key);
            }
        }
    } else {
        response.errors.insert(
            outcome.provider_id,
            "Accounting refresh timed out".to_string(),
        );
    }
}

fn provider_family(provider_id: &str) -> &str {
    provider_id.split('@').next().unwrap_or(provider_id)
}

fn resolve_provider(engine: &Engine, provider_id: &str) -> Option<Arc<dyn ProviderRuntime>> {
    engine
        .provider(provider_id)
        .or_else(|| engine.provider(provider_family(provider_id)))
}

fn is_heavy_provider(provider_id: &str, scope: Scope) -> bool {
    let family = provider_family(provider_id);
    if scope.skips_local_accounting() {
        return matches!(family, "hermes" | "opencode");
    }
    HEAVY_LOCAL_LOG_PROVIDERS.contains(&family) || HEAVY_LOCAL_LOG_PROVIDERS.contains(&provider_id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::ProviderInfo;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct TestProvider {
        info: ProviderInfo,
        delay: Duration,
        identity: Option<&'static str>,
        active_heavy: Option<Arc<AtomicUsize>>,
        max_heavy: Option<Arc<AtomicUsize>>,
    }

    impl TestProvider {
        fn simple(id: &str, delay_ms: u64, identity: Option<&'static str>) -> Self {
            TestProvider {
                info: ProviderInfo {
                    id: id.into(),
                    display_name: id.into(),
                },
                delay: Duration::from_millis(delay_ms),
                identity,
                active_heavy: None,
                max_heavy: None,
            }
        }
    }

    impl ProviderRuntime for TestProvider {
        fn info(&self) -> &ProviderInfo {
            &self.info
        }
        fn has_local_credentials(&self) -> bool {
            true
        }
        fn refresh(&self, ctx: &RefreshContext) -> ProviderSnapshot {
            if let (Some(cur), Some(max)) = (&self.active_heavy, &self.max_heavy) {
                let prev = cur.fetch_add(1, Ordering::SeqCst) + 1;
                max.fetch_max(prev, Ordering::SeqCst);
            }
            let started = Instant::now();
            while started.elapsed() < self.delay {
                if ctx.is_cancelled() {
                    if let Some(cur) = &self.active_heavy {
                        cur.fetch_sub(1, Ordering::SeqCst);
                    }
                    return crate::providers::cancelled_snapshot(&self.info, ctx);
                }
                std::thread::sleep(Duration::from_millis(5));
            }
            if let Some(cur) = &self.active_heavy {
                cur.fetch_sub(1, Ordering::SeqCst);
            }
            if let Some(id) = self.identity {
                ctx.set_observed_identity_key(id);
            }
            ProviderSnapshot::new(&self.info, None, vec![], ctx.now)
        }
    }

    #[test]
    fn heavy_providers_serialize_and_antigravity_fold_never_emits_identity() {
        let active = Arc::new(AtomicUsize::new(0));
        let max_seen = Arc::new(AtomicUsize::new(0));
        let engine = Engine::new(vec![
            Arc::new(TestProvider::simple("devin", 10, Some("devin-id"))),
            Arc::new(TestProvider::simple(
                "antigravity",
                10,
                Some("leaked-ag-id"),
            )),
            Arc::new(TestProvider {
                info: ProviderInfo {
                    id: "claude".into(),
                    display_name: "Claude".into(),
                },
                delay: Duration::from_millis(25),
                identity: Some("claude-id"),
                active_heavy: Some(active.clone()),
                max_heavy: Some(max_seen.clone()),
            }),
            Arc::new(TestProvider {
                info: ProviderInfo {
                    id: "codex".into(),
                    display_name: "Codex".into(),
                },
                delay: Duration::from_millis(25),
                identity: None,
                active_heavy: Some(active),
                max_heavy: Some(max_seen.clone()),
            }),
        ]);
        let req = serde_json::json!({
            "method": "refreshBatch",
            "params": {
                "scope": "panelAccounting",
                "items": [
                    { "providerId": "devin" },
                    { "providerId": "antigravity", "defaultIdentityKey": "ag-default" },
                    { "providerId": "claude" },
                    { "providerId": "codex", "defaultIdentityKey": "codex-default" }
                ]
            }
        });
        let reply: Value = serde_json::from_str(&engine.call(&req.to_string())).unwrap();
        let ok = &reply["ok"];
        assert!(ok["snapshots"]["devin"].is_object());
        assert!(ok["snapshots"]["antigravity"].is_object());
        assert!(ok["identityKeys"].get("antigravity").is_none());
        assert_eq!(ok["identityKeys"]["devin"], "devin-id");
        assert_eq!(ok["identityKeys"]["claude"], "claude-id");
        assert_eq!(ok["identityKeys"]["codex"], "codex-default");
        assert_eq!(max_seen.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn timeout_records_error_and_budget_omits_unstarted_providers() {
        let engine = Engine::new(vec![
            Arc::new(TestProvider::simple("claude", 2_000, None)),
            Arc::new(TestProvider::simple("codex", 10, None)),
        ]);
        let reply: Value = serde_json::from_str(
            &engine.call(
                &serde_json::json!({
                    "method": "refreshBatch",
                    "params": {
                        "scope": "panelAccounting",
                        "perProviderTimeoutSeconds": 0.08,
                        "items": [{ "providerId": "claude" }, { "providerId": "codex" }]
                    }
                })
                .to_string(),
            ),
        )
        .unwrap();
        assert_eq!(
            reply["ok"]["errors"]["claude"],
            "Accounting refresh timed out"
        );
        assert!(reply["ok"]["snapshots"]["codex"].is_object());

        let engine2 = Engine::new(vec![Arc::new(TestProvider::simple("devin", 10, None))]);
        let omitted: Value = serde_json::from_str(
            &engine2.call(
                &serde_json::json!({
                    "method": "refreshBatch",
                    "params": {
                        "batchBudgetSeconds": 1.0,
                        "items": [{ "providerId": "devin" }]
                    }
                })
                .to_string(),
            ),
        )
        .unwrap();
        assert!(omitted["ok"]["snapshots"].as_object().unwrap().is_empty());
        assert!(omitted["ok"]["errors"].as_object().unwrap().is_empty());
    }
}
