//! Freebuff network I/O (`Providers/Freebuff/FreebuffUsageClient`): read-only session poll, model
//! catalogue, and the shared Cloud/Desktop history pages.

use super::auth::FreebuffAuth;
use crate::context::CancelToken;
use crate::host;
use crate::http::{self, HttpClient, HttpError, Request};
use std::sync::Arc;
use std::time::Duration;

pub const SESSION_URL: &str = "https://www.codebuff.com/api/v1/freebuff/session";
pub const MODEL_CATALOG_URL: &str = "https://www.codebuff.com/api/v1/freebuff/models";
const TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ClientError {
    ConnectionFailed,
    InvalidResponse,
    RequestFailed(u16),
    TokenInvalid,
}

pub struct FreebuffClient {
    http: Arc<dyn HttpClient>,
}

impl FreebuffClient {
    pub fn live() -> Self {
        FreebuffClient {
            http: http::shared(),
        }
    }

    pub fn new(http: Arc<dyn HttpClient>) -> Self {
        FreebuffClient { http }
    }

    pub fn fetch_session(
        &self,
        auth: &FreebuffAuth,
        cancel: &CancelToken,
    ) -> Result<http::Response, ClientError> {
        self.fetch(
            SESSION_URL,
            auth,
            &[("x-freebuff-multi-session", "1")],
            cancel,
        )
    }

    pub fn fetch_model_catalog(
        &self,
        auth: &FreebuffAuth,
        cancel: &CancelToken,
    ) -> Result<http::Response, ClientError> {
        self.fetch(
            MODEL_CATALOG_URL,
            auth,
            &[("x-freebuff-catalog-protocol", "1")],
            cancel,
        )
    }

    pub fn fetch_history(
        &self,
        path: &str,
        cursor: Option<&str>,
        auth: &FreebuffAuth,
        cancel: &CancelToken,
    ) -> Result<http::Response, ClientError> {
        let limit = if path.ends_with("/events") {
            "500"
        } else {
            "100"
        };
        let mut url = format!("https://www.codebuff.com/api/v1/cloud/history/{path}?limit={limit}");
        if let Some(cursor) = cursor {
            url.push_str("&cursor=");
            url.push_str(&http::url_form_encode(cursor));
        }
        self.fetch(&url, auth, &[("x-freebuff-device-chats", "1")], cancel)
    }

    fn fetch(
        &self,
        url: &str,
        auth: &FreebuffAuth,
        extra: &[(&str, &str)],
        cancel: &CancelToken,
    ) -> Result<http::Response, ClientError> {
        let mut request = Request::get(url)
            .header("Authorization", format!("Bearer {}", auth.token))
            .header("Accept", "application/json")
            .header("x-fb-timezone", current_timezone())
            .timeout(TIMEOUT);
        for (name, value) in extra {
            request = request.header(name, *value);
        }
        match self.http.send(&request, cancel) {
            Ok(response) => Ok(response),
            Err(HttpError::Cancelled) => Err(ClientError::ConnectionFailed),
            Err(_) => {
                host::log(
                    host::LogLevel::Debug,
                    &host::plugin_tag("freebuff"),
                    "history request failed",
                );
                Err(ClientError::ConnectionFailed)
            }
        }
    }
}

fn current_timezone() -> String {
    // The engine's day keys already use the local zone; the CLI header only affects the server's
    // reset copy, so the IANA name is worth sending when the platform exposes it.
    std::env::var("TZ")
        .ok()
        .map(|value| value.trim_start_matches(':').to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "UTC".to_string())
}

pub fn map_error(error: ClientError) -> &'static str {
    match error {
        ClientError::ConnectionFailed => {
            "Couldn't reach Freebuff. Check your connection and try again."
        }
        ClientError::InvalidResponse => "Freebuff returned unreadable usage data. Try again later.",
        ClientError::RequestFailed(_) => "Freebuff usage request failed.",
        ClientError::TokenInvalid => {
            "The Freebuff login has expired. Sign in again with the Freebuff CLI."
        }
    }
}
