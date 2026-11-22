//! QuotaBar desktop preview core: opt-in live usage collection for Linux and
//! Windows. Reads credentials the provider tools already placed on the machine,
//! calls each provider's usage API, and normalizes the response into `Metric`
//! values the static webview renders. Read-only: no token refresh, no writes,
//! no history or spend accounting.

mod providers;

use serde::{Deserialize, Serialize};

/// The providers this preview can refresh. Only these four IDs can reach the
/// network; the IPC layer deserializes provider arguments into this enum, so an
/// unrecognized value never reaches `refresh`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Provider {
    Claude,
    Codex,
    OpenRouter,
    Zai,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Unit {
    Percent,
    Usd,
    Count,
}

/// One normalized usage row. `limit: Some(_)` renders as a meter, `None` as a
/// bare value. `on_demand` rows sit behind the card's expander.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Metric {
    pub id: &'static str,
    pub label: &'static str,
    pub value: f64,
    pub limit: Option<f64>,
    pub unit: Unit,
    pub reset_at_ms: Option<u64>,
    pub on_demand: bool,
}

/// What one refresh produced. `warning` is non-fatal context (e.g. an
/// OpenRouter endpoint that failed while its sibling succeeded); a hard failure
/// is the `Err` side of `refresh` instead.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub metrics: Vec<Metric>,
    pub updated_at_ms: u64,
    pub warning: Option<String>,
}

/// Live refresh for `provider`. Errors are a small JSON envelope —
/// `{"kind": "…", "message": "…"}` — with a fixed, redacted, actionable message;
/// no tokens, URLs, payloads, or dependency error text ever cross the boundary.
pub fn refresh(provider: Provider) -> Result<Snapshot, String> {
    providers::refresh(provider)
}

/// Deterministic representative snapshot for `--demo` mode. Never touches
/// credentials or the network; reset instants are relative to now.
pub fn demo(provider: Provider) -> Snapshot {
    providers::demo(provider)
}
