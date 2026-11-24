//! Shared 401/403 token-refresh single-retry flow (Swift `ProviderAuthRetry`).

use crate::context::RefreshContext;
use crate::host::diagnostic_gate;
use crate::http::{HttpError, Response};
use crate::qlog;
use sha2::{Digest, Sha256};

pub fn is_auth_failure(response: &Response) -> bool {
    response.status == 401 || response.status == 403
}

pub enum RetryOutcome<E> {
    Response(Response),
    Cancelled,
    ConnectionFailed,
    RetriedConnectionFailed,
    AuthExpired,
    RefreshError(E),
}

pub fn fetch_with_retry<E>(
    provider_id: &str,
    diagnostic_source_id: &str,
    token: &str,
    ctx: &RefreshContext,
    attempt: impl Fn(&str) -> Result<Response, HttpError>,
    refresh_access_token: impl FnOnce() -> Result<String, E>,
) -> RetryOutcome<E> {
    if ctx.is_cancelled() {
        return RetryOutcome::Cancelled;
    }
    let response = match attempt(token) {
        Ok(r) => r,
        Err(HttpError::Cancelled) => return RetryOutcome::Cancelled,
        Err(_) => return RetryOutcome::ConnectionFailed,
    };
    if ctx.is_cancelled() {
        return RetryOutcome::Cancelled;
    }
    let diag_key = diagnostic_key(provider_id, diagnostic_source_id);
    if !is_auth_failure(&response) {
        if response.is_success() {
            diagnostic_gate::clear(&diag_key);
        }
        return RetryOutcome::Response(response);
    }

    qlog!(Debug, "auth", "{} -> refreshing token, retrying once ({})", response.status, provider_id);
    let refreshed = match refresh_access_token() {
        Ok(tok) => tok,
        Err(err) => return RetryOutcome::RefreshError(err),
    };
    if ctx.is_cancelled() {
        return RetryOutcome::Cancelled;
    }
    let retried = match attempt(&refreshed) {
        Ok(r) => r,
        Err(HttpError::Cancelled) => return RetryOutcome::Cancelled,
        Err(_) => return RetryOutcome::RetriedConnectionFailed,
    };
    if ctx.is_cancelled() {
        return RetryOutcome::Cancelled;
    }
    if is_auth_failure(&retried) {
        diagnostic_gate::log_once(&diag_key, || {
            qlog!(Warn, "auth", "retry still unauthorized -> auth expired ({provider_id})");
        });
        return RetryOutcome::AuthExpired;
    }
    if retried.is_success() {
        diagnostic_gate::clear(&diag_key);
    }
    RetryOutcome::Response(retried)
}

fn diagnostic_key(provider_id: &str, source_id: &str) -> String {
    let fp: String = Sha256::digest(source_id.as_bytes()).iter().take(8).map(|b| format!("{b:02x}")).collect();
    format!("auth.provider-retry.{provider_id}.{fp}")
}
