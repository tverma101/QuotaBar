use super::batch::{self, BatchParams};
use super::Engine;
use crate::context::{RefreshContext, Scope};
use crate::paths::{self, Paths};
use crate::pricing::TokenBreakdown;
use serde::Deserialize;
use serde_json::{json, Value};
use std::path::PathBuf;

pub(super) fn dispatch(engine: &Engine, method: &str, params: Value) -> Result<Value, String> {
    match method {
        "configure" => {
            let p: ConfigureParams = from_params(params)?;
            paths::configure(Paths { home: PathBuf::from(p.home), app_data: PathBuf::from(p.app_data) });
            Ok(Value::Null)
        }
        "providers" => Ok(Value::Array(
            engine
                .providers()
                .iter()
                .map(|p| json!({ "id": p.info().id, "displayName": p.info().display_name }))
                .collect(),
        )),
        "sqliteQuery" => {
            let p: SqliteParams = from_params(params)?;
            let result = match p.timeout_seconds.filter(|seconds| seconds.is_finite() && *seconds > 0.0) {
                Some(seconds) => crate::sqlite::query_text_within(
                    &p.path,
                    &p.sql,
                    p.allow_wal_retry,
                    std::time::Duration::from_secs_f64(seconds.min(3600.0)),
                ),
                None => crate::sqlite::query_text(&p.path, &p.sql, p.allow_wal_retry),
            };
            result.map(|value| json!(value)).map_err(|error| error.to_string())
        }
        "sqliteExecute" => {
            let p: SqliteParams = from_params(params)?;
            crate::sqlite::execute(&p.path, &p.sql)
                .map(|_| Value::Null)
                .map_err(|error| error.to_string())
        }
        "hasLocalCredentials" => {
            let p: HasCredsParams = from_params(params)?;
            let provider = engine.provider(&p.provider_id).ok_or_else(|| unknown(&p.provider_id))?;
            Ok(Value::Bool(provider.has_local_credentials_with_config(p.config.as_ref())))
        }
        "refresh" => {
            let p: RefreshParams = from_params(params)?;
            let mut ctx = RefreshContext::new(p.scope.unwrap_or(Scope::Full));
            ctx.is_manual = p.is_manual.unwrap_or(false);
            ctx.skip_model_catalog_refresh = p.skip_model_catalog_refresh.unwrap_or(false);
            ctx.paced = p.paced.unwrap_or(false);
            ctx.config = p.config;
            if let Some(now) = p.now {
                ctx.now = now;
            }
            let (snapshot, identity) = engine
                .refresh_with_identity(&p.provider_id, ctx, p.request_id)
                .ok_or_else(|| unknown(&p.provider_id))?;
            if p.include_identity.unwrap_or(false) {
                Ok(json!({ "snapshot": snapshot, "identityKey": identity }))
            } else {
                serde_json::to_value(snapshot).map_err(|e| e.to_string())
            }
        }
        "refreshBatch" => {
            let p: BatchParams = from_params(params)?;
            let response = batch::run(engine, p);
            serde_json::to_value(response).map_err(|e| e.to_string())
        }
        "unloadCaches" => {
            if let Some(pricing) = crate::pricing::shared_if_initialized() {
                pricing.clear_caches();
            }
            for provider in engine.providers() {
                provider.unload_caches();
            }
            Ok(Value::Null)
        }
        "pricingStatus" => Ok(crate::pricing::shared().status()),
        "pricingRefresh" => {
            let p: PricingRefreshParams = from_params_or_default(params)?;
            let store = crate::pricing::shared();
            if p.background.unwrap_or(false) {
                let _ = store.current(false);
            } else {
                store.refresh_now();
            }
            Ok(store.status())
        }
        "pricingClearCaches" => {
            crate::pricing::shared().clear_caches();
            Ok(Value::Null)
        }
        "pricingResolve" => {
            let p: PricingResolveParams = from_params(params)?;
            let pricing = crate::pricing::shared().current(p.skip_model_catalog_refresh.unwrap_or(true));
            let apply_long = p.apply_long_context_rates.unwrap_or(true);
            let rates = pricing.resolve(&p.model);
            let cost_usd = p.tokens.as_ref().and_then(|t| {
                if p.is_cursor.unwrap_or(false) {
                    pricing.estimated_cursor_cost_dollars(&p.model, t, apply_long)
                } else {
                    pricing.estimated_cost_dollars(&p.model, t, p.timestamp, apply_long)
                }
            });
            Ok(json!({
                "canonicalName": pricing.canonical_name(&p.model),
                "cursorCanonicalName": pricing.cursor_canonical_name(&p.model),
                "hasExactOpenRouterRate": pricing.has_exact_open_router_rate(&p.model),
                "cacheToken": pricing.aggregate_cache_token(),
                "rates": rates.as_deref(),
                "costUsd": cost_usd,
            }))
        }
        "cancel" => {
            let p: CancelParams = from_params(params)?;
            Ok(Value::Bool(engine.cancel(p.request_id)))
        }
        other => Err(format!("unknown method: {other}")),
    }
}

fn unknown(id: &str) -> String {
    format!("unknown provider: {id}")
}

fn from_params<T: for<'de> Deserialize<'de>>(params: Value) -> Result<T, String> {
    serde_json::from_value(params).map_err(|e| format!("invalid params: {e}"))
}

fn from_params_or_default<T: Default + for<'de> Deserialize<'de>>(params: Value) -> Result<T, String> {
    if params.is_null() {
        Ok(T::default())
    } else {
        from_params(params)
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConfigureParams {
    home: String,
    app_data: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HasCredsParams {
    provider_id: String,
    #[serde(default)]
    config: Option<Value>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SqliteParams {
    path: PathBuf,
    sql: String,
    #[serde(default)]
    allow_wal_retry: bool,
    /// Per-query wall-clock budget in seconds; the engine default (5s) when absent.
    #[serde(default)]
    timeout_seconds: Option<f64>,
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
    paced: Option<bool>,
    config: Option<Value>,
    include_identity: Option<bool>,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PricingRefreshParams {
    background: Option<bool>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PricingResolveParams {
    model: String,
    is_cursor: Option<bool>,
    tokens: Option<TokenBreakdown>,
    timestamp: Option<f64>,
    apply_long_context_rates: Option<bool>,
    skip_model_catalog_refresh: Option<bool>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CancelParams {
    request_id: u64,
}
