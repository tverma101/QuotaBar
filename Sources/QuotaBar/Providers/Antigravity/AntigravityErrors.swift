import Foundation

/// Antigravity surfaces three user-facing failures. Every per-strategy error (LS not running, a decode
/// miss) is swallowed and the next strategy is tried; only when all strategies are exhausted does one of
/// these reach the UI.
enum AntigravityError: Error, LocalizedError, Equatable {
    /// No usable credentials anywhere (no LS running, no keychain token, nothing cached).
    case notSignedIn
    /// The Keychain credential may exist, but macOS would not let QuotaBar read it.
    case credentialStoreUnreadable
    /// The Keychain item needs user interaction to release. Distinct from `credentialStoreUnreadable`
    /// because the remedy is different: an explicit Refresh Now, not unlocking anything. A background
    /// refresh can never clear this, so it must not be reported as a broken credential store.
    case credentialPermissionRequired
    /// The Keychain item was present but did not contain usable Antigravity credential data.
    case invalidCredentialData
    /// Google rejected QuotaBar's OAuth client configuration; this does not mean the user's sign-in expired.
    case oauthClientConfigurationInvalid
    /// A token was found but rejected as expired or invalid, and a refresh could not recover it.
    case authExpired
    /// Cloud Code explicitly denied access. A permission denial is not evidence that the token expired.
    case accessDenied
    /// Credentials exist and look valid, but every endpoint was unreachable (network / server outage).
    /// Distinct from `notSignedIn` so a signed-in user isn't told to start Antigravity during an outage.
    case unavailable

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Start Antigravity or run `agy` and try again."
        case .credentialStoreUnreadable:
            return "Couldn't read Antigravity credentials from Keychain. Unlock Keychain or sign in to Antigravity again."
        case .credentialPermissionRequired:
            return "Antigravity needs permission to read its Keychain item. Use Refresh Now to be asked once, then grant it."
        case .invalidCredentialData:
            return "Antigravity credentials are invalid. Open Antigravity or run `agy` to sign in again."
        case .oauthClientConfigurationInvalid:
            return "Google rejected QuotaBar's Antigravity OAuth client configuration. Update QuotaBar and try again."
        case .authExpired:
            return "Antigravity sign-in expired. Open Antigravity or run `agy` to refresh."
        case .accessDenied:
            return "Google denied access to Antigravity usage. Check that this account and project have access."
        case .unavailable:
            return "Antigravity usage is temporarily unavailable. Try again shortly."
        }
    }
}
