//! Pricing-snapshot handles and the `pricing.*` backend operations.
//!
//! Swift loads one immutable snapshot per `ModelPricing` and keeps the numeric handle for the
//! lifetime of that pricing object, so folds never resend a multi-megabyte catalogue.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use serde_json::{json, Map, Value};

use super::{invalid_param, BackendError, Snapshot};
use crate::backend::accounting::ModelRates;

static REGISTRY: OnceLock<Mutex<HashMap<u64, Arc<Snapshot>>>> = OnceLock::new();
static NEXT_HANDLE: AtomicU64 = AtomicU64::new(1);

fn registry() -> &'static Mutex<HashMap<u64, Arc<Snapshot>>> {
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

pub(crate) fn snapshot_for(handle: u64) -> Result<Arc<Snapshot>, BackendError> {
    registry()
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .get(&handle)
        .cloned()
        .ok_or_else(|| invalid_param(format!("unknown pricing handle {handle}")))
}

fn required_handle(params: &Value) -> Result<u64, BackendError> {
    params
        .get("handle")
        .and_then(Value::as_u64)
        .ok_or_else(|| invalid_param("missing numeric `handle`".to_string()))
}

/// `pricing.load` — build a snapshot once per Swift `ModelPricing` and return its handle.
pub(crate) fn load(params: &Value) -> Result<Value, BackendError> {
    let snapshot = Snapshot::from_params(params)?;
    let handle = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
    registry()
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .insert(handle, Arc::new(snapshot));
    Ok(json!({ "handle": handle }))
}

/// `pricing.release` — drop a snapshot when its Swift owner is deallocated.
pub(crate) fn release(params: &Value) -> Result<Value, BackendError> {
    let handle = required_handle(params)?;
    let released = registry()
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .remove(&handle)
        .is_some();
    Ok(json!({ "released": released }))
}

/// `pricing.clear` — drop memoized resolutions without rebuilding the catalogues.
pub(crate) fn clear(params: &Value) -> Result<Value, BackendError> {
    let snapshot = snapshot_for(required_handle(params)?)?;
    snapshot.clear_memo();
    Ok(json!({ "cleared": true }))
}

/// `pricing.resolve` — resolve a batch of names. Used by parity tests and diagnostics; folds call
/// the same resolver directly.
pub(crate) fn resolve_op(params: &Value) -> Result<Value, BackendError> {
    let snapshot = snapshot_for(required_handle(params)?)?;
    let models = params
        .get("models")
        .and_then(Value::as_array)
        .ok_or_else(|| invalid_param("missing `models` array".to_string()))?;
    let canonical_names = canonical_names(params)?;
    let mut recheck: Vec<String> = Vec::new();
    let mut rates = Map::with_capacity(models.len());
    for model in models {
        let model = model
            .as_str()
            .ok_or_else(|| invalid_param("`models` must contain only strings".to_string()))?;
        let canonical = canonical_names.get(model).map(String::as_str);
        let resolved = snapshot.resolve(model, canonical, &mut recheck);
        rates.insert(
            model.to_string(),
            resolved
                .map(|rates| serde_json::to_value(rates).unwrap_or(Value::Null))
                .unwrap_or(Value::Null),
        );
    }
    Ok(json!({ "rates": rates, "recheckModels": recheck }))
}

/// Alias-rule results Swift computed for the fold's distinct slugs.
pub(super) fn canonical_names(params: &Value) -> Result<HashMap<String, String>, BackendError> {
    match params.get("canonicalNames") {
        None | Some(Value::Null) => Ok(HashMap::new()),
        Some(Value::Object(map)) => map
            .iter()
            .map(|(model, canonical)| {
                canonical
                    .as_str()
                    .map(|canonical| (model.clone(), canonical.to_string()))
                    .ok_or_else(|| {
                        invalid_param("`canonicalNames` must map strings to strings".to_string())
                    })
            })
            .collect(),
        Some(_) => Err(invalid_param(
            "`canonicalNames` must be an object".to_string(),
        )),
    }
}

// ---------------------------------------------------------------------------
// Fold-facing pricing source
// ---------------------------------------------------------------------------

/// Where a fold gets its rates: a Rust snapshot (model names + canonical names) or, for the
/// fallback path, the pre-resolved table Swift still builds.
pub(crate) struct FoldPricing {
    backend: Option<BackendPricing>,
    inline: Option<HashMap<String, Option<ModelRates>>>,
    recheck: Vec<String>,
}

struct BackendPricing {
    snapshot: Arc<Snapshot>,
    canonical_names: HashMap<String, String>,
}

impl FoldPricing {
    /// Whether this fold was handed a Rust pricing snapshot rather than a pre-resolved table.
    pub fn handle_present(params: &Value) -> bool {
        params
            .get("pricingHandle")
            .is_some_and(|value| !value.is_null())
    }

    pub fn from_params(params: &Value) -> Result<Self, BackendError> {
        if let Some(handle) = params.get("pricingHandle").filter(|value| !value.is_null()) {
            let handle = handle
                .as_u64()
                .ok_or_else(|| invalid_param("`pricingHandle` must be a number".to_string()))?;
            return Ok(Self {
                backend: Some(BackendPricing {
                    snapshot: snapshot_for(handle)?,
                    canonical_names: canonical_names(params)?,
                }),
                inline: None,
                recheck: Vec::new(),
            });
        }
        let object = params
            .get("pricing")
            .and_then(Value::as_object)
            .ok_or_else(|| invalid_param("missing `pricing` object".to_string()))?;
        let mut table: HashMap<String, Option<ModelRates>> = HashMap::with_capacity(object.len());
        for (model, value) in object {
            if value.is_null() {
                table.insert(model.clone(), None);
                continue;
            }
            let rates: ModelRates = serde_json::from_value(value.clone()).map_err(|error| {
                invalid_param(format!("invalid pricing rates for `{model}`: {error}"))
            })?;
            table.insert(model.clone(), Some(rates));
        }
        Ok(Self {
            backend: None,
            inline: Some(table),
            recheck: Vec::new(),
        })
    }

    pub fn has_backend(&self) -> bool {
        self.backend.is_some()
    }

    /// The alias-rule result for `model` when the backend resolves names, else nil (the inline
    /// table already contains the canonical identity). A miss means "no rule matched".
    pub fn canonical(&self, model: &str) -> Option<&str> {
        self.backend
            .as_ref()
            .and_then(|backend| backend.canonical_names.get(model).map(String::as_str))
    }

    pub fn resolve(&mut self, model: &str) -> Option<ModelRates> {
        let Self {
            backend,
            inline,
            recheck,
        } = self;
        if let Some(backend) = backend {
            let canonical = backend.canonical_names.get(model).map(String::as_str);
            return backend.snapshot.resolve(model, canonical, recheck);
        }
        inline
            .as_ref()
            .and_then(|table| table.get(model))
            .cloned()
            .flatten()
    }

    /// Names that need an OpenRouter catalogue recheck, reported once per snapshot.
    pub fn take_recheck(&mut self) -> Vec<String> {
        std::mem::take(&mut self.recheck)
    }
}
