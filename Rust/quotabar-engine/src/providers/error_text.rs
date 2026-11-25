//! Shared user-facing copy for the usage-error cases most providers repeat verbatim (Swift
//! `ProviderUsageErrorText`): transport failure, malformed response, non-2xx status. Providers
//! whose wording intentionally differs (OpenRouter, Copilot, Grok's "billing" phrasing) keep their
//! own strings.

/// The request never completed (network/transport failure).
pub const CONNECTION_FAILED: &str = "Usage request failed. Check your connection.";

/// The response came back but could not be parsed.
pub const INVALID_RESPONSE: &str = "Usage response invalid. Try again later.";

/// The server returned a non-2xx status.
pub fn request_failed(status: u16) -> String {
    format!("Usage request failed (HTTP {status}). Try again later.")
}
