//! Devin quota API HTTP client (`SeatManagementService/GetUserStatus`).

use super::auth::{DevinAuth, ID};
use super::mapper::{map_user_status_response, MappedUsage, UsageError};
use crate::context::RefreshContext;
use crate::host::{diagnostic_gate, plugin_tag};
use crate::http::{self, HttpClient, HttpError, Request};
use crate::model::ErrorCategory;
use crate::qlog;
use serde_json::json;
use std::time::Instant;

pub const CLOUD_SERVICE: &str = "exa.seat_management_pb.SeatManagementService";
pub const CLOUD_COMPAT_VERSION: &str = "1.108.2";
pub const QUOTA_UNAVAILABLE: &str = "Devin quota data unavailable. Try again later.";

const HTTP_FAILURE_KEY_PREFIX: &str = "devin.usage.http.";
pub(super) const INVALID_RESPONSE_KEY: &str = "devin.usage.invalid-response";
pub(super) const TRANSPORT_FAILURE_KEY: &str = "devin.usage.transport";

pub enum Attempt {
    Success(MappedUsage),
    AuthFailure,
    Failed(Failure),
    Cancelled,
}

#[derive(Clone, Copy)]
pub enum Failure {
    RequestFailed(u16),
    InvalidResponse,
    ConnectionFailed,
    QuotaUnavailable,
}

impl Failure {
    pub fn message(self) -> String {
        match self {
            Failure::RequestFailed(status) => {
                format!("Devin's service returned an error (HTTP {status}). Try again later.")
            }
            Failure::InvalidResponse => "Devin returned quota data QuotaBar couldn't read. Try again later.".into(),
            Failure::ConnectionFailed => "QuotaBar couldn't reach Devin. Check your connection and try again.".into(),
            Failure::QuotaUnavailable => QUOTA_UNAVAILABLE.into(),
        }
    }

    pub fn category(self) -> ErrorCategory {
        match self {
            Failure::RequestFailed(status) => ErrorCategory::http(status),
            Failure::InvalidResponse => ErrorCategory::Decoding,
            Failure::ConnectionFailed => ErrorCategory::Network,
            Failure::QuotaUnavailable => ErrorCategory::NotAvailable,
        }
    }
}

pub fn attempt(
    http: &dyn HttpClient,
    auth: &DevinAuth,
    ctx: &RefreshContext,
    deadline: Option<Instant>,
) -> Attempt {
    if ctx.is_cancelled() {
        return Attempt::Cancelled;
    }
    let timeout = deadline.map_or(http::DEFAULT_TIMEOUT, |deadline| {
        http::DEFAULT_TIMEOUT.min(deadline.saturating_duration_since(Instant::now()))
    });
    if timeout.is_zero() {
        return Attempt::Failed(Failure::ConnectionFailed);
    }
    let url = format!("{}/{}/GetUserStatus", auth.effective_api_server_url(), CLOUD_SERVICE);
    let body = json!({
        "metadata": {
            "apiKey": auth.api_key,
            "ideName": "devin",
            "ideVersion": CLOUD_COMPAT_VERSION,
            "extensionName": "devin",
            "extensionVersion": CLOUD_COMPAT_VERSION,
            "locale": "en"
        }
    });
    let request = Request::post_json(url, &body)
        .header("Connect-Protocol-Version", "1")
        .timeout(timeout);
    let response = match http.send(&request, &ctx.cancel) {
        Ok(response) => response,
        Err(HttpError::Cancelled) => return Attempt::Cancelled,
        Err(error) => {
            diagnostic_gate::log_once(TRANSPORT_FAILURE_KEY, || {
                qlog!(Warn, plugin_tag(ID), "quota request failed (transport): {error}");
            });
            return Attempt::Failed(Failure::ConnectionFailed);
        }
    };
    if ctx.is_cancelled() {
        return Attempt::Cancelled;
    }
    if response.status == 401 || response.status == 403 {
        return Attempt::AuthFailure;
    }
    if !response.is_success() {
        let status = response.status;
        diagnostic_gate::log_once(&format!("{HTTP_FAILURE_KEY_PREFIX}{status}"), || {
            qlog!(Warn, plugin_tag(ID), "quota request failed (HTTP {status})");
        });
        return Attempt::Failed(Failure::RequestFailed(status));
    }
    match map_user_status_response(&response.body, ctx.now) {
        Ok(mapped) => {
            diagnostic_gate::clear_prefix("devin.usage.");
            Attempt::Success(mapped)
        }
        Err(UsageError::QuotaUnavailable) => Attempt::Failed(Failure::QuotaUnavailable),
        Err(UsageError::InvalidResponse) => {
            diagnostic_gate::log_once(INVALID_RESPONSE_KEY, || {
                qlog!(Warn, plugin_tag(ID), "quota response could not be read");
            });
            Attempt::Failed(Failure::InvalidResponse)
        }
    }
}
