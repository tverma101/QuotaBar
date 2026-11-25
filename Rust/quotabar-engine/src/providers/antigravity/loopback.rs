//! HTTP client for the Antigravity language server's loopback listener (Swift
//! `URLSessionHTTPClient(allowsInsecureLoopback: true)`). The server uses a self-signed certificate,
//! so this client skips certificate validation — and therefore refuses every request whose host is
//! not a loopback address. It never uses a proxy.

use crate::context::CancelToken;
use crate::http::{HttpClient, HttpError, Request, Response};
use crate::qlog;
use crate::redact;
use std::sync::{Arc, OnceLock};
use std::time::Duration;

pub struct LoopbackClient {
    client: reqwest::blocking::Client,
}

impl LoopbackClient {
    fn build() -> Self {
        let client = reqwest::blocking::Client::builder()
            .user_agent(concat!("QuotaBar/", env!("CARGO_PKG_VERSION")))
            .connect_timeout(Duration::from_secs(10))
            .no_proxy()
            .danger_accept_invalid_certs(true)
            .build()
            .unwrap_or_else(|error| {
                qlog!(Error, "http", "loopback HTTP client setup failed, using defaults: {error}");
                reqwest::blocking::Client::new()
            });
        LoopbackClient { client }
    }
}

/// Only the IPv4/IPv6 loopback literals qualify; a name is never trusted.
pub fn is_loopback_url(url: &reqwest::Url) -> bool {
    match url.host() {
        Some(url::Host::Ipv4(ip)) => ip.is_loopback(),
        Some(url::Host::Ipv6(ip)) => ip.is_loopback(),
        _ => false,
    }
}

impl HttpClient for LoopbackClient {
    fn send(&self, request: &Request, cancel: &CancelToken) -> Result<Response, HttpError> {
        if cancel.is_cancelled() {
            return Err(HttpError::Cancelled);
        }
        let method = reqwest::Method::from_bytes(request.method.as_bytes()).map_err(|_| HttpError::InvalidUrl)?;
        let url = reqwest::Url::parse(&request.url).map_err(|_| HttpError::InvalidUrl)?;
        if !is_loopback_url(&url) {
            return Err(HttpError::InvalidUrl);
        }
        let mut builder = self.client.request(method, url).timeout(request.timeout);
        for (name, value) in &request.headers {
            builder = builder.header(name.as_str(), value.as_str());
        }
        if let Some(body) = &request.body {
            builder = builder.body(body.clone());
        }
        let redacted_url = redact::redact_url(&request.url);
        let response = builder.send().map_err(|error| {
            qlog!(Debug, "http", "{} {} -> transport error", request.method, redacted_url);
            HttpError::Transport(error.to_string())
        })?;
        let status = response.status().as_u16();
        let headers = response
            .headers()
            .iter()
            .filter_map(|(k, v)| v.to_str().ok().map(|v| (k.as_str().to_string(), v.to_string())))
            .collect();
        let body = response.bytes().map_err(|e| HttpError::Transport(e.to_string()))?.to_vec();
        qlog!(Debug, "http", "{} {} -> {}", request.method, redacted_url, status);
        if cancel.is_cancelled() {
            return Err(HttpError::Cancelled);
        }
        Ok(Response { status, headers, body })
    }
}

pub fn shared() -> Arc<dyn HttpClient> {
    static CLIENT: OnceLock<Arc<LoopbackClient>> = OnceLock::new();
    CLIENT.get_or_init(|| Arc::new(LoopbackClient::build())).clone()
}
