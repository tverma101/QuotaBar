//! Live provider collection for the desktop preview: credential lookup, a
//! bounded read-only HTTP client, and per-provider request + mapper modules.
//! Everything here is read-only — no file writes, no token refresh, no
//! background probing; `refresh` is invoked explicitly per provider.

mod claude;
mod codex;
mod openrouter;
mod zai;

use crate::{Metric, Provider, Snapshot, Unit};
use base64::Engine;
use serde_json::{Map, Value};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// Provider responses and credential files are both capped at 1 MiB — a larger
/// body is never a legitimate usage payload, and a truncated JSON prefix must
/// not be accepted as one either.
const MAX_BODY_BYTES: u64 = 1024 * 1024;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const TOTAL_TIMEOUT: Duration = Duration::from_secs(15);

/// The furthest future instant accepted as a reset for Claude/Codex payloads —
/// a sanity bound for unit mix-ups, mirroring the Swift mappers.
const MAX_RESET_HORIZON_MS: u64 = 100 * 365 * 24 * 60 * 60 * 1000;

pub(crate) fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

// ---------------------------------------------------------------------------
// Errors: a fixed catalogue that crosses IPC as a JSON envelope. Messages are
// actionable and redacted — never a token, URL, payload, or dependency's error
// text. `kind` lets the UI decide whether a stale snapshot may stay visible.
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ErrorKind {
    /// Not signed in / not configured / invalid override. Clears last-good.
    Setup,
    /// 401/403, identity conflict, unusable credential. Clears last-good.
    Auth,
    RateLimited,
    Http,
    Network,
    Invalid,
    Internal,
}

impl ErrorKind {
    fn as_str(self) -> &'static str {
        match self {
            ErrorKind::Setup => "setup",
            ErrorKind::Auth => "auth",
            ErrorKind::RateLimited => "rateLimited",
            ErrorKind::Http => "http",
            ErrorKind::Network => "network",
            ErrorKind::Invalid => "invalid",
            ErrorKind::Internal => "internal",
        }
    }
}

#[derive(Debug)]
pub(crate) struct RefreshError {
    pub kind: ErrorKind,
    pub message: String,
}

impl RefreshError {
    fn new(kind: ErrorKind, message: impl Into<String>) -> Self {
        Self { kind, message: message.into() }
    }

    fn into_ipc(self) -> String {
        serde_json::json!({ "kind": self.kind.as_str(), "message": self.message }).to_string()
    }
}

type RefreshResult<T> = Result<T, RefreshError>;

fn setup(message: impl Into<String>) -> RefreshError {
    RefreshError::new(ErrorKind::Setup, message)
}

fn auth(message: impl Into<String>) -> RefreshError {
    RefreshError::new(ErrorKind::Auth, message)
}

fn invalid_response() -> RefreshError {
    RefreshError::new(ErrorKind::Invalid, "Usage response invalid. Try again later.")
}

fn connection_failed() -> RefreshError {
    RefreshError::new(ErrorKind::Network, "Usage request failed. Check your connection.")
}

fn rate_limited() -> RefreshError {
    RefreshError::new(
        ErrorKind::RateLimited,
        "Rate limited by the provider. Wait a few minutes, then refresh.",
    )
}

fn http_failed(status: u16) -> RefreshError {
    RefreshError::new(
        ErrorKind::Http,
        format!("Usage request failed (HTTP {status}). Try again later."),
    )
}

/// 401/403 → provider-specific re-login text, 429 → wait, other non-2xx →
/// numeric status only.
fn require_success(status: u16, auth_message: &str) -> RefreshResult<()> {
    match status {
        200..=299 => Ok(()),
        401 | 403 => Err(auth(auth_message)),
        429 => Err(rate_limited()),
        other => Err(http_failed(other)),
    }
}

// ---------------------------------------------------------------------------
// HTTP: one bounded client per refresh — 5s connect / 15s total, no redirects
// (an Authorization header must never follow one), no cookie store, response
// capped via Read::take so an oversized body is rejected, never truncated.
// ---------------------------------------------------------------------------

fn http_client() -> RefreshResult<reqwest::blocking::Client> {
    reqwest::blocking::Client::builder()
        .connect_timeout(CONNECT_TIMEOUT)
        .timeout(TOTAL_TIMEOUT)
        .redirect(reqwest::redirect::Policy::none())
        .user_agent("QuotaBar")
        .build()
        .map_err(|_| RefreshError::new(ErrorKind::Internal, "QuotaBar couldn't complete the refresh."))
}

struct HttpResponse {
    status: u16,
    headers: reqwest::header::HeaderMap,
    body: Vec<u8>,
}

/// GET a JSON endpoint with an optional bearer token and extra fixed headers.
/// Secrets exist only inside request construction; nothing here logs.
fn get_json(
    client: &reqwest::blocking::Client,
    url: &str,
    bearer: &str,
    extra_headers: &[(&'static str, &str)],
) -> RefreshResult<HttpResponse> {
    let mut request = client
        .get(url)
        .header(reqwest::header::ACCEPT, "application/json");
    if !bearer.is_empty() {
        request = request.bearer_auth(bearer);
    }
    for (name, value) in extra_headers {
        request = request.header(*name, *value);
    }
    let response = request.send().map_err(|_| connection_failed())?;
    let status = response.status().as_u16();
    let headers = response.headers().clone();
    let mut limited = response.take(MAX_BODY_BYTES + 1);
    let mut body = Vec::new();
    limited.read_to_end(&mut body).map_err(|_| connection_failed())?;
    if body.len() as u64 > MAX_BODY_BYTES {
        return Err(invalid_response());
    }
    Ok(HttpResponse { status, headers, body })
}

fn header_number(headers: &reqwest::header::HeaderMap, name: &str) -> Option<f64> {
    headers.get(name).and_then(|v| v.to_str().ok()).and_then(|s| {
        let parsed = s.trim().parse::<f64>().ok()?;
        parsed.is_finite().then_some(parsed)
    })
}

// ---------------------------------------------------------------------------
// JSON / value helpers — the permissive-read rules ported from ProviderParse:
// numbers or numeric strings, finite only; booleans never coerce.
// ---------------------------------------------------------------------------

fn json_object(body: &[u8]) -> RefreshResult<Map<String, Value>> {
    match serde_json::from_slice::<Value>(body) {
        Ok(Value::Object(map)) => Ok(map),
        _ => Err(invalid_response()),
    }
}

fn number(value: Option<&Value>) -> Option<f64> {
    match value? {
        Value::Number(n) => n.as_f64().filter(|v| v.is_finite()),
        Value::String(s) => s.trim().parse::<f64>().ok().filter(|v| v.is_finite()),
        _ => None,
    }
}

/// A reported percent for Claude/Codex: the Swift app doesn't clamp these, so
/// an out-of-range value is treated as unreadable data and skipped rather than
/// rendered as a misleading bar.
fn percent_bounded(value: Option<&Value>) -> Option<f64> {
    number(value).filter(|v| (0.0..=100.0).contains(v))
}

/// Z.ai's clamp, mirroring `ProviderParse.clampPercent`; input is already
/// finite by the time it reaches here.
fn clamp_percent(value: f64) -> f64 {
    value.clamp(0.0, 100.0)
}

fn string(value: Option<&Value>) -> Option<&str> {
    match value? {
        Value::String(s) => Some(s.as_str()),
        _ => None,
    }
}

fn obj(value: Option<&Value>) -> Option<&Map<String, Value>> {
    match value? {
        Value::Object(map) => Some(map),
        _ => None,
    }
}

fn arr(value: Option<&Value>) -> Option<&Vec<Value>> {
    match value? {
        Value::Array(items) => Some(items),
        _ => None,
    }
}

fn rfc3339_ms(text: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(text.trim())
        .ok()
        .map(|d| d.timestamp_millis())
}

/// Accept a millisecond instant only when it is still ahead of `now` and inside
/// the sanity horizon (the same untrusted-instant rule as the Swift mappers).
fn future_ms(ms: i64, now: u64, horizon_ms: u64) -> Option<u64> {
    if ms <= 0 {
        return None;
    }
    let ms = ms as u64;
    if ms <= now || ms - now > horizon_ms {
        None
    } else {
        Some(ms)
    }
}

// ---------------------------------------------------------------------------
// Credentials: cross-platform home/env resolution and capped file reads.
// ---------------------------------------------------------------------------

fn home_dir() -> RefreshResult<PathBuf> {
    std::env::home_dir().ok_or_else(|| {
        RefreshError::new(ErrorKind::Internal, "QuotaBar couldn't locate your home directory.")
    })
}

fn env_value(name: &str) -> Option<String> {
    std::env::var_os(name).map(|v| v.to_string_lossy().into_owned())
}

/// `~` / `~/` expansion without a shell; other inputs returned unchanged.
fn expand_home(raw: &str) -> PathBuf {
    if raw == "~" {
        if let Some(home) = std::env::home_dir() {
            return home;
        }
        return PathBuf::from(raw);
    }
    for prefix in ["~/", "~\\"] {
        if let Some(rest) = raw.strip_prefix(prefix) {
            if let Some(home) = std::env::home_dir() {
                return home.join(rest);
            }
            return PathBuf::from(raw);
        }
    }
    PathBuf::from(raw)
}

/// An explicit env override for a provider's config directory. `Some` when set
/// (after `~` expansion) — and then it must be absolute, because a relative
/// path would load credentials from an arbitrary working directory.
fn env_override_dir(env_var: &str, env_value: Option<&str>) -> RefreshResult<Option<PathBuf>> {
    let Some(raw) = env_value.map(str::trim).filter(|s| !s.is_empty()) else {
        return Ok(None);
    };
    let expanded = expand_home(raw);
    if !expanded.is_absolute() {
        return Err(setup(format!(
            "{env_var} must be an absolute path. Fix the environment variable, then refresh."
        )));
    }
    Ok(Some(expanded))
}

/// Read a credential file whole, bounded at 1 MiB like a response body. `None`
/// when the file does not exist; unreadable or oversized files are errors, not
/// silent misses.
fn read_auth_file(path: &Path, unreadable_message: &str) -> RefreshResult<Option<Vec<u8>>> {
    let file = match std::fs::File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(setup(unreadable_message)),
    };
    let mut limited = file.take(MAX_BODY_BYTES + 1);
    let mut body = Vec::new();
    limited
        .read_to_end(&mut body)
        .map_err(|_| setup(unreadable_message))?;
    if body.len() as u64 > MAX_BODY_BYTES {
        return Err(setup(unreadable_message));
    }
    Ok(Some(body))
}

/// First non-blank env value wins, in declared order (e.g. `ZAI_API_KEY`
/// before `GLM_API_KEY`); `get` is the env lookup so tests stay hermetic.
fn pick_key<'a>(
    names: &[&'a str],
    get: impl Fn(&str) -> Option<String>,
) -> Option<String> {
    names.iter().find_map(|name| {
        get(name)
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty())
    })
}

fn api_key(names: &[&str], missing_message: &str) -> RefreshResult<String> {
    pick_key(names, |name| env_value(name)).ok_or_else(|| setup(missing_message))
}

/// The ChatGPT account id claimed inside a Codex `id_token` JWT: the middle
/// base64url segment's `https://api.openai.com/auth.chatgpt_account_id` claim
/// (with a bare `chatgpt_account_id` fallback). A malformed token simply
/// yields no claim, mirroring the Swift reader's optional chain.
fn codex_id_token_account(id_token: &str) -> Option<String> {
    let payload = id_token.split('.').nth(1)?;
    let decoded = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload)
        .or_else(|_| base64::engine::general_purpose::URL_SAFE.decode(payload))
        .ok()?;
    let value: Value = serde_json::from_slice(&decoded).ok()?;
    let claim = value
        .get("https://api.openai.com/auth")
        .and_then(|auth| auth.get("chatgpt_account_id"))
        .or_else(|| value.get("chatgpt_account_id"));
    string(claim).map(str::trim).filter(|s| !s.is_empty()).map(String::from)
}

fn normalize_id(value: &str) -> String {
    value.trim().to_lowercase()
}

// ---------------------------------------------------------------------------
// Dispatch + demo
// ---------------------------------------------------------------------------

pub(crate) fn refresh(provider: Provider) -> Result<Snapshot, String> {
    let result = match provider {
        Provider::Claude => claude::refresh(),
        Provider::Codex => codex::refresh(),
        Provider::OpenRouter => openrouter::refresh(),
        Provider::Zai => zai::refresh(),
    };
    result.map_err(RefreshError::into_ipc)
}

/// Deterministic representative numbers — `--demo` exercises the full render
/// path without touching credentials or the network.
pub(crate) fn demo(provider: Provider) -> Snapshot {
    fn metric(
        id: &'static str,
        label: &'static str,
        value: f64,
        limit: Option<f64>,
        unit: Unit,
        reset_at_ms: Option<u64>,
        on_demand: bool,
    ) -> Metric {
        Metric { id, label, value, limit, unit, reset_at_ms, on_demand }
    }

    const HOUR: u64 = 60 * 60 * 1000;
    const DAY: u64 = 24 * HOUR;
    let now = now_ms();
    let metrics = match provider {
        Provider::Claude => vec![
            metric("claude.session", "Session", 37.0, Some(100.0), Unit::Percent, Some(now + 2 * HOUR + 14 * 60 * 1000), false),
            metric("claude.weekly", "Weekly", 62.0, Some(100.0), Unit::Percent, Some(now + 3 * DAY + 5 * HOUR), false),
            metric("claude.fable", "Fable", 9.0, Some(100.0), Unit::Percent, Some(now + 3 * DAY + 5 * HOUR), false),
        ],
        Provider::Codex => vec![
            metric("codex.session", "Session", 41.0, Some(100.0), Unit::Percent, Some(now + 3 * HOUR + 22 * 60 * 1000), false),
            metric("codex.weekly", "Weekly", 55.0, Some(100.0), Unit::Percent, Some(now + 4 * DAY + 6 * HOUR), false),
            metric("codex.credits", "Credits", 6.4, None, Unit::Usd, None, true),
        ],
        Provider::OpenRouter => vec![
            metric("openrouter.credits", "Credits", 42.18, Some(100.0), Unit::Usd, None, false),
            metric("openrouter.balance", "Balance", 57.82, None, Unit::Usd, None, false),
            metric("openrouter.today", "Today", 3.42, None, Unit::Usd, None, true),
            metric("openrouter.week", "This Week", 18.10, None, Unit::Usd, None, true),
            metric("openrouter.month", "This Month", 64.55, None, Unit::Usd, None, true),
            metric("openrouter.keyLimit", "Key Limit", 25.0, Some(50.0), Unit::Usd, None, true),
        ],
        Provider::Zai => vec![
            metric("zai.session", "Session", 23.0, Some(100.0), Unit::Percent, Some(now + 4 * HOUR + 9 * 60 * 1000), false),
            metric("zai.weekly", "Weekly", 48.0, Some(100.0), Unit::Percent, Some(now + 5 * DAY + 7 * HOUR), false),
            metric("zai.webSearches", "Web Searches", 34.0, Some(100.0), Unit::Count, Some(now + 12 * DAY), true),
        ],
    };
    Snapshot { metrics, updated_at_ms: now, warning: None }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn number_accepts_numbers_and_numeric_strings() {
        assert_eq!(number(Some(&serde_json::json!(42.5))), Some(42.5));
        assert_eq!(number(Some(&serde_json::json!(" 7 "))), Some(7.0));
        assert_eq!(number(Some(&serde_json::json!(true))), None);
        assert_eq!(number(Some(&serde_json::json!("NaN"))), None);
        assert_eq!(number(Some(&serde_json::json!("abc"))), None);
        assert_eq!(number(None), None);
    }

    #[test]
    fn percent_bounded_rejects_out_of_range() {
        assert_eq!(percent_bounded(Some(&serde_json::json!(0))), Some(0.0));
        assert_eq!(percent_bounded(Some(&serde_json::json!(100))), Some(100.0));
        assert_eq!(percent_bounded(Some(&serde_json::json!(-1))), None);
        assert_eq!(percent_bounded(Some(&serde_json::json!(100.5))), None);
        assert_eq!(percent_bounded(Some(&serde_json::json!("NaN"))), None);
    }

    #[test]
    fn future_ms_requires_a_future_instant_inside_the_horizon() {
        let now = 1_000_000_000_000u64;
        assert_eq!(future_ms((now + 1000) as i64, now, MAX_RESET_HORIZON_MS), Some(now + 1000));
        assert_eq!(future_ms((now - 1) as i64, now, MAX_RESET_HORIZON_MS), None);
        assert_eq!(future_ms(0, now, MAX_RESET_HORIZON_MS), None);
        assert_eq!(future_ms(i64::MAX, now, MAX_RESET_HORIZON_MS), None);
    }

    #[test]
    fn rfc3339_ms_parses_offsets() {
        assert_eq!(
            rfc3339_ms("1970-01-01T00:00:01Z"),
            Some(1000)
        );
        assert_eq!(rfc3339_ms("not a date"), None);
    }

    #[test]
    fn pick_key_prefers_first_nonblank_name() {
        let env = |name: &str| match name {
            "FIRST" => Some("   ".to_string()),
            "SECOND" => Some("  sk-2  ".to_string()),
            _ => None,
        };
        assert_eq!(pick_key(&["FIRST", "SECOND"], env), Some("sk-2".to_string()));
        assert_eq!(pick_key(&["FIRST", "MISSING"], env), None);
    }

    #[test]
    fn id_token_account_reads_the_namespaced_claim() {
        // {"https://api.openai.com/auth":{"chatgpt_account_id":"acct-123"}}
        let token = "h.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdC0xMjMifX0.s";
        assert_eq!(codex_id_token_account(token).as_deref(), Some("acct-123"));
        assert_eq!(codex_id_token_account("not-a-jwt"), None);
        assert_eq!(codex_id_token_account("h.e30.s"), None);
    }

    #[test]
    fn relative_env_override_is_rejected() {
        let err = env_override_dir("CODEX_HOME", Some("relative/dir")).unwrap_err();
        assert_eq!(err.kind, ErrorKind::Setup);
        assert!(err.message.contains("CODEX_HOME"));
    }

    #[test]
    fn tilde_env_override_expands_under_home() {
        let dir = env_override_dir("CODEX_HOME", Some("~/codex-test"))
            .unwrap()
            .unwrap();
        assert!(dir.is_absolute());
        assert!(dir.ends_with("codex-test"));
    }

    #[test]
    fn demo_snapshots_are_never_empty() {
        for provider in [Provider::Claude, Provider::Codex, Provider::OpenRouter, Provider::Zai] {
            let snapshot = demo(provider);
            assert!(!snapshot.metrics.is_empty(), "{provider:?} demo must render rows");
            for metric in &snapshot.metrics {
                assert!(metric.value.is_finite());
            }
        }
    }

    #[test]
    fn error_envelope_is_machine_readable_json() {
        let ipc = RefreshError::new(ErrorKind::Auth, "test message").into_ipc();
        let parsed: Value = serde_json::from_str(&ipc).unwrap();
        assert_eq!(parsed["kind"], "auth");
        assert_eq!(parsed["message"], "test message");
    }
}
