import Foundation

/// Build-time policy for Google-owned services.
///
/// Google's Antigravity Additional Terms (§6) and the Antigravity and Gemini CLI FAQs treat
/// third-party software that accesses those services — reusing their OAuth login, calling their
/// internal endpoints, wrapping `agy`, or presenting itself as the Antigravity client — as a breach
/// that can suspend the user's Google account. Public QuotaBar builds therefore never do any of that:
/// they read only the token history Antigravity already wrote to local disk.
///
/// A private owner build can opt back into the live-limit sources by compiling with
/// `-DQUOTABAR_GOOGLE_PRIVATE_ACCESS` (`QUOTABAR_GOOGLE_PRIVATE_ACCESS=1 ./script/build_and_run.sh`).
/// Release builds refuse that flag, so a distributed binary cannot carry it.
enum GoogleTermsPolicy {
    /// Whether this binary may read Google credentials or query Antigravity's live quota sources.
    static let allowsPrivateGoogleAccess: Bool = {
        #if QUOTABAR_GOOGLE_PRIVATE_ACCESS
        return true
        #else
        return false
        #endif
    }()
}
