//! Antigravity's user-facing failures (Swift `AntigravityError`). Every per-strategy error (LS not
//! running, a decode miss) is swallowed and the next strategy is tried; only when all strategies are
//! exhausted does one of these reach the UI.

use crate::model::ErrorCategory;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AntigravityError {
    /// No usable credentials anywhere (no LS running, no keychain token, nothing cached).
    NotSignedIn,
    /// The Keychain credential may exist, but macOS would not let QuotaBar read it.
    CredentialStoreUnreadable,
    /// The Keychain item needs user interaction to release. The remedy is an explicit Refresh Now.
    CredentialPermissionRequired,
    /// The Keychain item was present but did not contain usable Antigravity credential data.
    InvalidCredentialData,
    /// Google rejected QuotaBar's OAuth client configuration; the user's sign-in did not expire.
    OAuthClientConfigurationInvalid,
    /// A token was found but rejected as expired or invalid, and a refresh could not recover it.
    AuthExpired,
    /// Cloud Code explicitly denied access (not evidence that the token expired).
    AccessDenied,
    /// Valid credentials, but none of the known quota endpoints is exposed.
    QuotaEndpointUnavailable,
    /// Credentials look valid, but every endpoint was unreachable.
    Unavailable,
}

impl AntigravityError {
    pub fn message(self) -> &'static str {
        match self {
            AntigravityError::NotSignedIn => {
                "Sign in to Antigravity once, then refresh QuotaBar. The app can stay closed after sign-in."
            }
            AntigravityError::CredentialStoreUnreadable => {
                "Couldn't read Antigravity credentials from Keychain. Unlock Keychain or sign in to Antigravity again."
            }
            AntigravityError::CredentialPermissionRequired => {
                "Allow QuotaBar to read Antigravity's saved sign-in. Click Refresh on this card, then choose Always Allow if macOS asks."
            }
            AntigravityError::InvalidCredentialData => {
                "Antigravity credentials are invalid. Open Antigravity or run `agy` to sign in again."
            }
            AntigravityError::OAuthClientConfigurationInvalid => {
                "Google rejected QuotaBar's Antigravity OAuth client configuration. Update QuotaBar and try again."
            }
            AntigravityError::AuthExpired => "Antigravity sign-in expired. Open Antigravity or run `agy` to refresh.",
            AntigravityError::AccessDenied => {
                "Google denied access to Antigravity usage. Check that this account and project have access."
            }
            AntigravityError::QuotaEndpointUnavailable => {
                "Antigravity did not provide a supported usage endpoint for this account or app version."
            }
            AntigravityError::Unavailable => "Antigravity usage is temporarily unavailable. Try again shortly.",
        }
    }

    pub fn category(self) -> ErrorCategory {
        match self {
            AntigravityError::NotSignedIn => ErrorCategory::NotLoggedIn,
            AntigravityError::CredentialStoreUnreadable | AntigravityError::CredentialPermissionRequired => {
                ErrorCategory::CredentialAccess
            }
            AntigravityError::InvalidCredentialData | AntigravityError::OAuthClientConfigurationInvalid => {
                ErrorCategory::AuthInvalid
            }
            AntigravityError::AuthExpired => ErrorCategory::AuthExpired,
            AntigravityError::AccessDenied => ErrorCategory::Http4xx,
            AntigravityError::QuotaEndpointUnavailable => ErrorCategory::NotAvailable,
            AntigravityError::Unavailable => ErrorCategory::Network,
        }
    }
}

/// A probe either fails with one of the user-facing errors or was cancelled (Swift's thrown
/// `CancellationError`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    Error(AntigravityError),
    Cancelled,
}

impl From<AntigravityError> for Failure {
    fn from(error: AntigravityError) -> Self {
        Failure::Error(error)
    }
}
