//! Codex live usage: `$CODEX_HOME/auth.json` (or `~/.config/codex` then
//! `~/.codex`) → `GET chatgpt.com/backend-api/wham/usage`. Window classification
//! and the credit conversion mirror the Swift mapper; no token refresh and no
//! reset-credit claims in this preview.

use super::*;

const USAGE_URL: &str = "https://chatgpt.com/backend-api/wham/usage";
const AUTH_MESSAGE: &str = "Codex session expired. Run `codex` to sign in again, then refresh.";
const CREDENTIALS_UNREADABLE: &str =
    "QuotaBar found Codex credential data but couldn't read it. Check file permissions, then refresh.";
/// Codex flex credits are worth 4¢ each — the same conversion the Swift
/// mapper mirrors from the Codex CLI/plugin.
const CREDIT_USD_RATE: f64 = 0.04;
const SESSION_WINDOW_MS: f64 = 18_000_000.0; // five hours
const WEEKLY_WINDOW_MS: f64 = 604_800_000.0; // seven days
/// A year covers every real `limit_window_seconds`; anything longer is a
/// malformed payload, not a plan.
const MAX_WINDOW_MS: f64 = 366.0 * 24.0 * 60.0 * 60.0 * 1000.0;

pub(super) fn refresh() -> RefreshResult<Snapshot> {
    let credential = load_credentials()?;
    let client = http_client()?;
    let mut extra_headers: Vec<(&'static str, &str)> = Vec::new();
    if let Some(account_id) = &credential.account_id {
        extra_headers.push(("chatgpt-account-id", account_id));
    }
    let response = get_json(&client, USAGE_URL, &credential.access_token, &extra_headers)?;
    require_success(response.status, AUTH_MESSAGE)?;
    let body = json_object(&response.body)?;
    // A 2xx body with none of the fields we read — and no usage headers either —
    // is an invalid response, not a valid "no usage" snapshot.
    let recognized = ["rate_limit", "credits", "plan_type"]
        .iter()
        .any(|key| body.contains_key(*key))
        || ["x-codex-primary-used-percent", "x-codex-secondary-used-percent", "x-codex-credits-balance"]
            .iter()
            .any(|name| response.headers.contains_key(*name));
    if !recognized {
        return Err(invalid_response());
    }
    let now = now_ms();
    Ok(Snapshot {
        metrics: map_usage(&body, &response.headers, now),
        updated_at_ms: now,
        warning: None,
    })
}

// ---------------------------------------------------------------------------
// Credentials
// ---------------------------------------------------------------------------

struct CodexCredential {
    access_token: String,
    account_id: Option<String>,
}

fn auth_paths() -> RefreshResult<Vec<PathBuf>> {
    if let Some(dir) = env_override_dir("CODEX_HOME", env_value("CODEX_HOME").as_deref())? {
        return Ok(vec![dir.join("auth.json")]);
    }
    Ok(vec![home_dir()?.join(".codex").join("auth.json")])
}

fn load_credentials() -> RefreshResult<CodexCredential> {
    for path in auth_paths()? {
        let Some(body) = read_auth_file(&path, CREDENTIALS_UNREADABLE)? else {
            continue;
        };
        let root: Value = serde_json::from_slice(&body).map_err(|_| {
            auth("Codex credential data is invalid. Run `codex` to sign in again.")
        })?;
        if let Some(credential) = credential_from(&root)? {
            return Ok(credential);
        }
    }
    Err(setup("No Codex credentials found. Run `codex` to sign in, then refresh."))
}

/// `None` when the file carries no token-like credential; an API-key-only file
/// is a hard failure (usage needs the ChatGPT session), and an `account_id`
/// that disagrees with the id-token claim fails closed rather than trusting
/// whichever field happened to be present first.
fn credential_from(root: &Value) -> RefreshResult<Option<CodexCredential>> {
    let tokens = obj(root.get("tokens"));
    let access_token = tokens
        .and_then(|tokens| tokens.get("access_token"))
        .and_then(|v| string(Some(v)))
        .map(str::trim)
        .filter(|s| !s.is_empty());

    let Some(access_token) = access_token else {
        let has_api_key = root
            .get("OPENAI_API_KEY")
            .and_then(|v| string(Some(v)))
            .is_some_and(|key| !key.trim().is_empty());
        if has_api_key {
            return Err(auth(
                "Codex usage isn't available for an API-key sign-in. Run `codex` to sign in with your ChatGPT account.",
            ));
        }
        return Ok(None);
    };

    let file_id = tokens
        .and_then(|tokens| tokens.get("account_id"))
        .and_then(|v| string(Some(v)))
        .map(normalize_id)
        .filter(|s| !s.is_empty());
    let token_id = tokens
        .and_then(|tokens| tokens.get("id_token"))
        .and_then(|v| string(Some(v)))
        .and_then(codex_id_token_account)
        .map(|id| normalize_id(&id))
        .filter(|s| !s.is_empty());

    if let (Some(file_id), Some(token_id)) = (&file_id, &token_id) {
        if file_id != token_id {
            return Err(auth(
                "Codex credentials disagree about the signed-in account. Run `codex` to sign in again.",
            ));
        }
    }

    Ok(Some(CodexCredential {
        access_token: access_token.to_string(),
        account_id: file_id.or(token_id),
    }))
}

// ---------------------------------------------------------------------------
// Mapping — ported from CodexUsageMapper's window classification.
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum WindowKind {
    Session,
    Weekly,
}

struct WindowCandidate<'a> {
    window: Option<&'a Map<String, Value>>,
    used_percent: Option<f64>,
    fallback_kind: WindowKind,
}

fn map_usage(
    body: &Map<String, Value>,
    headers: &reqwest::header::HeaderMap,
    now: u64,
) -> Vec<Metric> {
    let mut metrics = Vec::new();
    let rate_limit = obj(body.get("rate_limit"));

    let candidates: Vec<WindowCandidate> = [
        window_candidate(
            rate_limit.and_then(|r| r.get("primary_window")),
            header_number(headers, "x-codex-primary-used-percent"),
            WindowKind::Session,
        ),
        window_candidate(
            rate_limit.and_then(|r| r.get("secondary_window")),
            header_number(headers, "x-codex-secondary-used-percent"),
            WindowKind::Weekly,
        ),
    ]
    .into_iter()
    .flatten()
    .collect();

    for (kind, id, label) in [
        (WindowKind::Session, "codex.session", "Session"),
        (WindowKind::Weekly, "codex.weekly", "Weekly"),
    ] {
        if let Some(metric) = classified_line(&candidates, kind, id, label, now) {
            metrics.push(metric);
        }
    }

    if let Some(balance) = credits_balance(body, headers) {
        metrics.push(Metric {
            id: "codex.credits",
            label: "Credits",
            value: credit_usd(balance),
            limit: None,
            unit: Unit::Usd,
            reset_at_ms: None,
            on_demand: true,
        });
    }

    metrics
}

/// A candidate exists when the slot's window object arrived or a usable header
/// percent can stand in for it — the same header fallback as the Swift mapper,
/// on the main `rate_limit` only.
fn window_candidate<'a>(
    value: Option<&'a Value>,
    header_percent: Option<f64>,
    fallback_kind: WindowKind,
) -> Option<WindowCandidate<'a>> {
    let window = obj(value);
    if window.is_none() && header_percent.is_none() {
        return None;
    }
    let used_percent = window
        .and_then(|w| number(w.get("used_percent")))
        .or(header_percent)
        .filter(|v| (0.0..=100.0).contains(v));
    Some(WindowCandidate { window, used_percent, fallback_kind })
}

fn exact_kind(window: Option<&Map<String, Value>>) -> Option<WindowKind> {
    let milliseconds = window
        .and_then(|w| number(w.get("limit_window_seconds")))
        .filter(|seconds| *seconds > 0.0)
        .map(|seconds| seconds * 1000.0)
        .filter(|ms| ms.is_finite() && *ms <= MAX_WINDOW_MS)?;
    if milliseconds == SESSION_WINDOW_MS {
        Some(WindowKind::Session)
    } else if milliseconds == WEEKLY_WINDOW_MS {
        Some(WindowKind::Weekly)
    } else {
        None
    }
}

/// Explicit duration wins over slot position: a temporarily sole weekly limit
/// moved into the primary slot must render as Weekly, never as Session. The
/// positional mapping is only a fallback for payloads without a recognized
/// duration.
fn classified_line(
    candidates: &[WindowCandidate],
    kind: WindowKind,
    id: &'static str,
    label: &'static str,
    now: u64,
) -> Option<Metric> {
    let candidate = candidates
        .iter()
        .find(|c| exact_kind(c.window) == Some(kind))
        .or_else(|| {
            candidates
                .iter()
                .find(|c| exact_kind(c.window).is_none() && c.fallback_kind == kind)
        })?;
    let used = candidate.used_percent?;
    Some(Metric {
        id,
        label,
        value: used,
        limit: Some(100.0),
        unit: Unit::Percent,
        reset_at_ms: candidate.window.and_then(|w| reset_at(w, now)),
        on_demand: false,
    })
}

/// `reset_at` epoch seconds, else `reset_after_seconds` relative to now —
/// both inside the shared sanity horizon.
fn reset_at(window: &Map<String, Value>, now: u64) -> Option<u64> {
    if let Some(seconds) = number(window.get("reset_at")) {
        return future_ms((seconds * 1000.0) as i64, now, MAX_RESET_HORIZON_MS);
    }
    if let Some(after) = number(window.get("reset_after_seconds")) {
        if after > 0.0 && after * 1000.0 <= MAX_RESET_HORIZON_MS as f64 {
            return Some(now + after as u64 * 1000);
        }
    }
    None
}

/// Flex-credit balance: the `credits` object's `balance`, an explicit
/// `has_credits: false` as a real zero, or the response header — the only
/// shapes the Swift mapper recognizes. Dollarized at 4¢ per floored credit.
fn credits_balance(body: &Map<String, Value>, headers: &reqwest::header::HeaderMap) -> Option<f64> {
    if let Some(credits) = obj(body.get("credits")) {
        if let Some(balance) = number(credits.get("balance")) {
            return Some(balance);
        }
        if credits.get("has_credits") == Some(&Value::Bool(false)) {
            return Some(0.0);
        }
    }
    header_number(headers, "x-codex-credits-balance")
}

fn credit_usd(balance: f64) -> f64 {
    balance.floor().clamp(0.0, 1e9) * CREDIT_USD_RATE
}

#[cfg(test)]
mod tests {
    use super::*;

    fn body(json: &str) -> Map<String, Value> {
        serde_json::from_str::<Value>(json)
            .unwrap()
            .as_object()
            .unwrap()
            .clone()
    }

    #[test]
    fn weekly_only_primary_is_never_presented_as_session() {
        let now = now_ms();
        let body = body(
            r#"{"rate_limit": {"primary_window":
                {"used_percent": 63, "limit_window_seconds": 604800, "reset_after_seconds": 300000}}}"#,
        );
        let metrics = map_usage(&body, &reqwest::header::HeaderMap::new(), now);
        assert_eq!(metrics.len(), 1);
        assert_eq!(metrics[0].id, "codex.weekly");
        assert_eq!(metrics[0].reset_at_ms, Some(now + 300_000_000));
    }

    #[test]
    fn missing_percent_is_no_row_but_a_real_zero_is_a_row() {
        let now = now_ms();
        let body = body(
            r#"{"rate_limit": {
                "primary_window": {"limit_window_seconds": 18000},
                "secondary_window": {"used_percent": 0, "limit_window_seconds": 604800}}}"#,
        );
        let metrics = map_usage(&body, &reqwest::header::HeaderMap::new(), now);
        assert_eq!(metrics.len(), 1);
        assert_eq!(metrics[0].id, "codex.weekly");
        assert_eq!(metrics[0].value, 0.0);
    }

    #[test]
    fn positional_fallback_applies_to_unknown_durations() {
        let now = now_ms();
        let body = body(
            r#"{"rate_limit": {
                "primary_window": {"used_percent": 12, "limit_window_seconds": 3600},
                "secondary_window": {"used_percent": 34, "limit_window_seconds": 86400}}}"#,
        );
        let metrics = map_usage(&body, &reqwest::header::HeaderMap::new(), now);
        assert_eq!(metrics.len(), 2);
        assert_eq!(metrics[0].id, "codex.session");
        assert_eq!(metrics[0].value, 12.0);
        assert_eq!(metrics[1].id, "codex.weekly");
        assert_eq!(metrics[1].value, 34.0);
    }

    #[test]
    fn header_percent_fills_a_missing_window_body() {
        let now = now_ms();
        let mut headers = reqwest::header::HeaderMap::new();
        headers.insert("x-codex-primary-used-percent", "58".parse().unwrap());
        let reset_secs = now / 1000 + 3600;
        let body = body(&format!(
            r#"{{"rate_limit": {{"secondary_window":
            {{"used_percent": 20, "limit_window_seconds": 604800, "reset_at": {reset_secs}}}}}}}"#
        ));
        let metrics = map_usage(&body, &headers, now);
        assert_eq!(metrics.len(), 2);
        assert_eq!(metrics[0].id, "codex.session");
        assert_eq!(metrics[0].value, 58.0);
        assert_eq!(metrics[1].reset_at_ms, Some(reset_secs * 1000));
    }

    #[test]
    fn out_of_range_percent_produces_no_meter() {
        let body = body(r#"{"rate_limit": {"primary_window": {"used_percent": "NaN"}}}"#);
        assert!(map_usage(&body, &reqwest::header::HeaderMap::new(), now_ms()).is_empty());
    }

    #[test]
    fn identity_conflict_fails_closed() {
        // id_token claim says acct-2 while account_id says acct-1.
        let root: Value = serde_json::from_str(
            r#"{"tokens": {
                "access_token": "tok",
                "account_id": "ACCT-1",
                "id_token": "h.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdC0yIn19.s"}}"#,
        )
        .unwrap();
        let err = credential_from(&root).err().unwrap();
        assert_eq!(err.kind, ErrorKind::Auth);
    }

    #[test]
    fn agreeing_identity_uses_the_account_id() {
        let root: Value = serde_json::from_str(
            r#"{"tokens": {
                "access_token": "tok",
                "id_token": "h.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiQUNDVC05In19.s"}}"#,
        )
        .unwrap();
        let credential = credential_from(&root).unwrap().unwrap();
        assert_eq!(credential.account_id.as_deref(), Some("acct-9"));
    }

    #[test]
    fn api_key_only_file_is_not_usable() {
        let root: Value = serde_json::from_str(r#"{"OPENAI_API_KEY": "sk-x"}"#).unwrap();
        let err = credential_from(&root).err().unwrap();
        assert_eq!(err.kind, ErrorKind::Auth);
    }

    #[test]
    fn credits_convert_at_four_cents_and_clamp() {
        assert_eq!(credit_usd(821.9), 821.0 * 0.04);
        assert_eq!(credit_usd(-3.0), 0.0);
    }
}
