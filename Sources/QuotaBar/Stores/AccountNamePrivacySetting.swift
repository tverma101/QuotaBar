import Foundation

/// Whether provider display names blur their account-identifying suffix (“Claude — Acme Corp”)
/// by default across the popover, share cards, and history. On by default; the toggle sits in
/// Settings → Privacy. When on, a blurred suffix reveals itself on tap and hides again on a
/// second tap; per-card reveal state is transient (never persisted).
enum AccountNamePrivacySetting {
    static let key = "blurAccountNames"
    static let defaultValue = true
}
