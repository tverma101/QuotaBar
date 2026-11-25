//! HTTP for provider API calls (Swift `URLSessionHTTPClient`).
//!
//! One shared blocking client (connection pool + TLS sessions reused across refreshes), the system
//! proxy honored, plus the optional app proxy from `~/.quotabar/config.json`. Logging matches the
//! macOS app: one Debug line per request with the method, redacted URL and status; on HTTP >= 400 a
//! redacted, truncated (<= 500 byte) body preview. Headers and successful bodies are never logged.
//!
//! The client is blocking. Call it from a plain thread (the macOS C ABI runs every call on its own
//! thread; the Windows app must use `spawn_blocking`), never from inside an async runtime.

use crate::context::CancelToken;
use crate::qlog;
use crate::redact;
use std::sync::{Arc, OnceLock};
use std::time::Duration;

pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Clone, Debug)]
pub struct Request {
    pub method: &'static str,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: Option<Vec<u8>>,
    pub timeout: Duration,
    /// Trust a self-signed loopback certificate. Only ever set for `https://127.0.0.1` requests;
    /// `send` rejects the flag for any other host so a provider cannot accidentally weaken TLS.
    pub allow_insecure_loopback: bool,
}

impl Request {
    pub fn get(url: impl Into<String>) -> Self {
        Request {
            method: "GET",
            url: url.into(),
            headers: Vec::new(),
            body: None,
            timeout: DEFAULT_TIMEOUT,
            allow_insecure_loopback: false,
        }
    }

    pub fn post_json(url: impl Into<String>, body: &serde_json::Value) -> Self {
        Request {
            method: "POST",
            url: url.into(),
            headers: vec![("Content-Type".into(), "application/json".into())],
            body: Some(serde_json::to_vec(body).unwrap_or_default()),
            timeout: DEFAULT_TIMEOUT,
            allow_insecure_loopback: false,
        }
    }

    pub fn post_form(url: impl Into<String>, body: impl Into<String>) -> Self {
        Request {
            method: "POST",
            url: url.into(),
            headers: vec![(
                "Content-Type".into(),
                "application/x-www-form-urlencoded".into(),
            )],
            body: Some(body.into().into_bytes()),
            timeout: DEFAULT_TIMEOUT,
            allow_insecure_loopback: false,
        }
    }

    pub fn header(mut self, name: &str, value: impl Into<String>) -> Self {
        self.headers.push((name.to_string(), value.into()));
        self
    }

    pub fn timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    /// Trust the local language server's self-signed certificate. Valid only for loopback HTTPS.
    pub fn insecure_loopback_tls(mut self) -> Self {
        self.allow_insecure_loopback = true;
        self
    }
}

/// Percent-encode unreserved bytes according to RFC 3986 (matches Swift `urlFormEncoded`).
pub fn url_form_encode(input: &str) -> String {
    let mut encoded = String::with_capacity(input.len());
    for byte in input.as_bytes() {
        if matches!(byte, b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~') {
            encoded.push(*byte as char);
        } else {
            use std::fmt::Write;
            let _ = write!(encoded, "%{byte:02X}");
        }
    }
    encoded
}

#[derive(Clone, Debug, Default)]
pub struct Response {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Response {
    pub fn is_success(&self) -> bool {
        (200..300).contains(&self.status)
    }

    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }

    pub fn json(&self) -> Option<serde_json::Value> {
        serde_json::from_slice(&self.body).ok()
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum HttpError {
    Cancelled,
    InvalidUrl,
    /// DNS, TLS, connect, timeout: the request never produced an HTTP status.
    Transport(String),
}

impl std::fmt::Display for HttpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            HttpError::Cancelled => f.write_str("cancelled"),
            HttpError::InvalidUrl => f.write_str("invalid URL"),
            HttpError::Transport(message) => f.write_str(message),
        }
    }
}

impl std::error::Error for HttpError {}

/// Seam for tests: providers take an `Arc<dyn HttpClient>`.
pub trait HttpClient: Send + Sync {
    fn send(&self, request: &Request, cancel: &CancelToken) -> Result<Response, HttpError>;
}

pub struct ReqwestClient {
    client: reqwest::blocking::Client,
    insecure_loopback: Option<reqwest::blocking::Client>,
}

impl ReqwestClient {
    fn build() -> Self {
        let mut builder = reqwest::blocking::Client::builder()
            .user_agent(concat!("QuotaBar/", env!("CARGO_PKG_VERSION")))
            .connect_timeout(Duration::from_secs(10))
            .pool_idle_timeout(Duration::from_secs(90));
        if let Some(proxy) = app_proxy() {
            builder = builder.proxy(proxy);
        }
        // `danger_accept_invalid_certs` applies to the local language server only; every
        // non-loopback request still goes through the validating client above.
        let mut insecure = reqwest::blocking::Client::builder()
            .user_agent(concat!("QuotaBar/", env!("CARGO_PKG_VERSION")))
            .connect_timeout(Duration::from_secs(10))
            .pool_idle_timeout(Duration::from_secs(90))
            .danger_accept_invalid_certs(true)
            .no_proxy();
        if let Some(proxy) = app_proxy() {
            insecure = insecure.proxy(proxy);
        }
        let insecure_loopback = insecure.build().ok();
        let client = builder.build().unwrap_or_else(|error| {
            qlog!(
                Error,
                "http",
                "HTTP client setup failed, using defaults: {error}"
            );
            reqwest::blocking::Client::new()
        });
        ReqwestClient {
            client,
            insecure_loopback,
        }
    }
}

impl HttpClient for ReqwestClient {
    fn send(&self, request: &Request, cancel: &CancelToken) -> Result<Response, HttpError> {
        if cancel.is_cancelled() {
            return Err(HttpError::Cancelled);
        }
        let method = reqwest::Method::from_bytes(request.method.as_bytes())
            .map_err(|_| HttpError::InvalidUrl)?;
        let url = reqwest::Url::parse(&request.url).map_err(|_| HttpError::InvalidUrl)?;
        let loopback = matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "::1"));
        if request.allow_insecure_loopback && !loopback {
            return Err(HttpError::InvalidUrl);
        }
        let client = if request.allow_insecure_loopback {
            self.insecure_loopback.as_ref().unwrap_or(&self.client)
        } else {
            &self.client
        };
        let mut builder = client.request(method, url).timeout(request.timeout);
        for (name, value) in &request.headers {
            builder = builder.header(name.as_str(), value.as_str());
        }
        if let Some(body) = &request.body {
            builder = builder.body(body.clone());
        }
        let redacted_url = redact::redact_url(&request.url);
        let response = builder.send().map_err(|error| {
            qlog!(
                Debug,
                "http",
                "{} {} -> transport error: {}",
                request.method,
                redacted_url,
                transport_reason(&error)
            );
            HttpError::Transport(transport_reason(&error))
        })?;
        let status = response.status().as_u16();
        let headers = response
            .headers()
            .iter()
            .filter_map(|(k, v)| {
                v.to_str()
                    .ok()
                    .map(|v| (k.as_str().to_string(), v.to_string()))
            })
            .collect();
        let body = response
            .bytes()
            .map_err(|error| HttpError::Transport(transport_reason(&error)))?
            .to_vec();
        if status >= 400 {
            qlog!(
                Debug,
                "http",
                "{} {} -> {} body: {}",
                request.method,
                redacted_url,
                status,
                redact::body_preview(&String::from_utf8_lossy(&body), 500)
            );
        } else {
            qlog!(
                Debug,
                "http",
                "{} {} -> {}",
                request.method,
                redacted_url,
                status
            );
        }
        if cancel.is_cancelled() {
            return Err(HttpError::Cancelled);
        }
        Ok(Response {
            status,
            headers,
            body,
        })
    }
}

/// A short, secret-free description of a transport failure.
fn transport_reason(error: &reqwest::Error) -> String {
    if error.is_timeout() {
        "The request timed out.".to_string()
    } else if error.is_connect() {
        "Could not connect to the server.".to_string()
    } else if error.is_body() || error.is_decode() {
        "The connection was interrupted.".to_string()
    } else {
        "The network request failed.".to_string()
    }
}

/// The shared production client.
pub fn shared() -> Arc<dyn HttpClient> {
    static CLIENT: OnceLock<Arc<ReqwestClient>> = OnceLock::new();
    CLIENT
        .get_or_init(|| Arc::new(ReqwestClient::build()))
        .clone()
}

/// `~/.quotabar/config.json` → `{"proxy": {"enabled": true, "url": "socks5://host:port"}}`.
/// Absent or disabled means no app proxy (the system proxy still applies). Loopback never proxies.
fn app_proxy() -> Option<reqwest::Proxy> {
    let path = crate::paths::home().join(".quotabar").join("config.json");
    let text = std::fs::read_to_string(&path).ok()?;
    let root: serde_json::Value = match serde_json::from_str(&text) {
        Ok(root) => root,
        Err(_) => {
            qlog!(
                Warn,
                "config",
                "proxy config could not be parsed; ignoring it"
            );
            return None;
        }
    };
    let proxy = root.get("proxy")?;
    if proxy.get("enabled").and_then(|v| v.as_bool()) != Some(true) {
        return None;
    }
    let url = proxy.get("url").and_then(|v| v.as_str())?;
    let lower = url.to_ascii_lowercase();
    if !(lower.starts_with("socks5://")
        || lower.starts_with("http://")
        || lower.starts_with("https://"))
    {
        qlog!(Warn, "config", "proxy url scheme unsupported; ignoring it");
        return None;
    }
    match reqwest::Proxy::all(url) {
        Ok(proxy) => {
            let shown = reqwest::Url::parse(url)
                .map(|u| {
                    format!(
                        "{}://{}:{}",
                        u.scheme(),
                        u.host_str().unwrap_or(""),
                        u.port_or_known_default().unwrap_or(0)
                    )
                })
                .unwrap_or_default();
            qlog!(Info, "config", "proxy enabled {shown}");
            Some(proxy.no_proxy(reqwest::NoProxy::from_string("localhost,127.0.0.1,::1")))
        }
        Err(_) => {
            qlog!(Warn, "config", "proxy url invalid; ignoring it");
            None
        }
    }
}

/// Scripted responses for unit tests.
#[cfg(any(test, feature = "test-support"))]
pub mod mock {
    use super::*;
    use std::sync::Mutex;

    pub struct MockClient {
        pub responses: Mutex<Vec<Result<Response, HttpError>>>,
        pub requests: Mutex<Vec<Request>>,
    }

    impl MockClient {
        pub fn new(responses: Vec<Result<Response, HttpError>>) -> Arc<Self> {
            Arc::new(MockClient {
                responses: Mutex::new(responses),
                requests: Mutex::new(Vec::new()),
            })
        }

        pub fn json(status: u16, body: &str) -> Result<Response, HttpError> {
            Ok(Response {
                status,
                headers: Vec::new(),
                body: body.as_bytes().to_vec(),
            })
        }
    }

    impl HttpClient for MockClient {
        fn send(&self, request: &Request, cancel: &CancelToken) -> Result<Response, HttpError> {
            if cancel.is_cancelled() {
                return Err(HttpError::Cancelled);
            }
            self.requests.lock().unwrap().push(request.clone());
            let mut responses = self.responses.lock().unwrap();
            if responses.is_empty() {
                return Err(HttpError::Transport("no scripted response".into()));
            }
            responses.remove(0)
        }
    }

    pub struct FnClient {
        handler: Box<dyn Fn(&Request) -> Result<Response, HttpError> + Send + Sync>,
        pub requests: Mutex<Vec<Request>>,
    }

    impl FnClient {
        pub fn new(
            handler: impl Fn(&Request) -> Result<Response, HttpError> + Send + Sync + 'static,
        ) -> Self {
            FnClient {
                handler: Box::new(handler),
                requests: Mutex::new(Vec::new()),
            }
        }
    }

    impl HttpClient for FnClient {
        fn send(&self, request: &Request, cancel: &CancelToken) -> Result<Response, HttpError> {
            if cancel.is_cancelled() {
                return Err(HttpError::Cancelled);
            }
            self.requests.lock().unwrap().push(request.clone());
            (self.handler)(request)
        }
    }
}
