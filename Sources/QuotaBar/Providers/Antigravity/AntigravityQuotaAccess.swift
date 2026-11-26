import Foundation

/// Which Antigravity sources a build may read. Local conversation history is always read: it is data
/// Antigravity already wrote to the user's disk, and reading it never contacts Google or Antigravity.
///
/// Live quota is different. Both live sources go through interfaces Google does not support for third
/// parties (see `GoogleTermsPolicy`), so public builds use `.localHistoryOnly`.
struct AntigravityQuotaAccess: Sendable, Equatable {
    /// Ask the running Antigravity app or `agy` for quota through its local language server.
    var readsLocalLanguageServer: Bool
    /// Read Antigravity's Google login from the Keychain and call Google's Cloud Code endpoints.
    var usesGoogleCloudCode: Bool

    var readsLiveQuota: Bool { readsLocalLanguageServer || usesGoogleCloudCode }

    /// Public builds: token history, spend estimates, and the usage trend from local conversations.
    static let localHistoryOnly = AntigravityQuotaAccess(readsLocalLanguageServer: false, usesGoogleCloudCode: false)
    /// Private owner builds compiled with `QUOTABAR_GOOGLE_PRIVATE_ACCESS`.
    static let ownerBuild = AntigravityQuotaAccess(readsLocalLanguageServer: true, usesGoogleCloudCode: true)

    static var current: AntigravityQuotaAccess {
        GoogleTermsPolicy.allowsPrivateGoogleAccess ? .ownerBuild : .localHistoryOnly
    }
}
