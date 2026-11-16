import Foundation

/// Whether provider display names blur their account-identifying suffix (“Claude — Acme Corp”)
/// by default across the popover, share cards, and history. On by default; the toggle sits in
/// Settings → Privacy. When on, a blurred suffix reveals itself on tap and hides again on a
/// second tap; per-card reveal state is transient (never persisted).
enum AccountNamePrivacySetting {
    static let key = "blurAccountNames"
    static let defaultValue = true

    /// Name fit for surfaces that cannot offer tap-to-reveal (notification subtitles, hover
    /// tooltips): family-only while the blur is on, otherwise the full name. VoiceOver *actions*
    /// keep the full name by choice — they need to disambiguate cards, which is the point of
    /// giving accounts separate cards.
    static func displayName(for name: String, defaults: UserDefaults = .standard) -> String {
        guard isBlurEnabled(defaults), let split = AccountNameText.splitAccountSuffix(name) else {
            return name
        }
        return split.family
    }

    static func isBlurEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: key) as? Bool) ?? defaultValue
    }
}
