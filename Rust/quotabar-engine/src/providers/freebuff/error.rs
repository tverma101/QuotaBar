//! Freebuff's typed failures: `FreebuffAuthError`, `FreebuffProfileError` and `FreebuffUsageError`
//! (Providers/Freebuff/FreebuffAuthStore.swift, FreebuffUsageClient.swift, Providers/ErrorCategory.swift)
//! folded into one enum. The strings and telemetry buckets are the Swift ones, verbatim.

use crate::model::ErrorCategory;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FreebuffError {
    // FreebuffAuthError
    NotLoggedIn,
    InvalidConfigDirectory,
    InvalidCredentials,
    CredentialsUnreadable,
    CredentialPermissionRequired,
    TokenInvalid,
    // FreebuffProfileError
    MissingDefaultProfile,
    // FreebuffUsageError
    ConnectionFailed,
    InvalidResponse,
    RequestFailed(i64),
    QuotaUnavailable,
    LocalHistoryUnreadable,
    LiveAccessUnavailable,
    /// Swift `CancellationError`.
    Cancelled,
}

impl FreebuffError {
    /// Swift `errorDescription`.
    pub fn message(&self) -> String {
        match self {
            FreebuffError::NotLoggedIn => "No Freebuff login was found. Run ~/.config/manicode/freebuff login (or freebuff login if available), then refresh QuotaBar.".into(),
            FreebuffError::InvalidConfigDirectory => "Freebuff's FREEBUFF_CONFIG_DIR must be an absolute path.".into(),
            FreebuffError::InvalidCredentials => "Freebuff's credentials file is invalid. Sign in again with the Freebuff CLI.".into(),
            FreebuffError::CredentialsUnreadable => "QuotaBar couldn't read Freebuff's local credentials. Check file or Keychain access.".into(),
            FreebuffError::CredentialPermissionRequired => "macOS needs permission to read Freebuff's Keychain item. Choose Always Allow when prompted.".into(),
            FreebuffError::TokenInvalid => "The Freebuff login has expired. Sign in again with the Freebuff CLI.".into(),
            FreebuffError::MissingDefaultProfile => "QuotaBar found Freebuff credentials, but they have no `default` profile. Sign in again with the Freebuff CLI, or point FREEBUFF_CONFIG_DIR at the config directory that holds it.".into(),
            FreebuffError::ConnectionFailed => "Couldn't reach Freebuff. Check your connection and try again.".into(),
            FreebuffError::InvalidResponse => "Freebuff returned unreadable usage data. Try again later.".into(),
            FreebuffError::RequestFailed(status) => format!("Freebuff usage request failed (HTTP {status})."),
            FreebuffError::QuotaUnavailable => "Freebuff usage data is not available for this account yet.".into(),
            FreebuffError::LocalHistoryUnreadable => "QuotaBar couldn't read Freebuff Desktop's measured token history. Refresh again after the current turn finishes.".into(),
            FreebuffError::LiveAccessUnavailable => "Live Freebuff quotas and session timers are unavailable. QuotaBar shows saved measurements only.".into(),
            FreebuffError::Cancelled => "Refresh cancelled.".into(),
        }
    }

    /// Swift `CategorizedError.errorCategory`.
    pub fn category(&self) -> ErrorCategory {
        match self {
            FreebuffError::NotLoggedIn => ErrorCategory::NotLoggedIn,
            FreebuffError::InvalidConfigDirectory | FreebuffError::InvalidCredentials => ErrorCategory::AuthInvalid,
            FreebuffError::CredentialsUnreadable | FreebuffError::CredentialPermissionRequired => {
                ErrorCategory::CredentialAccess
            }
            FreebuffError::TokenInvalid => ErrorCategory::AuthExpired,
            FreebuffError::MissingDefaultProfile => ErrorCategory::AuthInvalid,
            FreebuffError::ConnectionFailed => ErrorCategory::Network,
            FreebuffError::InvalidResponse => ErrorCategory::Decoding,
            FreebuffError::RequestFailed(status) => http_category(*status),
            FreebuffError::QuotaUnavailable => ErrorCategory::NotAvailable,
            FreebuffError::LocalHistoryUnreadable => ErrorCategory::Decoding,
            FreebuffError::LiveAccessUnavailable => ErrorCategory::NotAvailable,
            FreebuffError::Cancelled => ErrorCategory::Cancelled,
        }
    }

    /// Stable identifier for the `freebuffAuth` engine method (the Swift case name).
    pub fn code(&self) -> &'static str {
        match self {
            FreebuffError::NotLoggedIn => "notLoggedIn",
            FreebuffError::InvalidConfigDirectory => "invalidConfigDirectory",
            FreebuffError::InvalidCredentials => "invalidCredentials",
            FreebuffError::CredentialsUnreadable => "credentialsUnreadable",
            FreebuffError::CredentialPermissionRequired => "credentialPermissionRequired",
            FreebuffError::TokenInvalid => "tokenInvalid",
            FreebuffError::MissingDefaultProfile => "missingDefaultProfile",
            FreebuffError::ConnectionFailed => "connectionFailed",
            FreebuffError::InvalidResponse => "invalidResponse",
            FreebuffError::RequestFailed(_) => "requestFailed",
            FreebuffError::QuotaUnavailable => "quotaUnavailable",
            FreebuffError::LocalHistoryUnreadable => "localHistoryUnreadable",
            FreebuffError::LiveAccessUnavailable => "liveAccessUnavailable",
            FreebuffError::Cancelled => "cancelled",
        }
    }
}

impl std::fmt::Display for FreebuffError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message())
    }
}

impl std::error::Error for FreebuffError {}

/// Swift `ErrorCategory.http(_:)` over an `Int` status (the live response arrives as a plain integer).
pub fn http_category(status: i64) -> ErrorCategory {
    match status {
        429 => ErrorCategory::RateLimited,
        400..=499 => ErrorCategory::Http4xx,
        500..=599 => ErrorCategory::Http5xx,
        _ => ErrorCategory::Other,
    }
}

impl From<crate::context::Cancelled> for FreebuffError {
    fn from(_: crate::context::Cancelled) -> Self {
        FreebuffError::Cancelled
    }
}
