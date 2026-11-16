import SwiftUI

/// Renders a provider display name with its account-identifying suffix blurred by default.
///
/// Managed multi-account cards build names as `"Family — Account"` (see `ProviderAccountAssembly`),
/// so the suffix after the first `" — "` is the account. With the setting on (the default), the
/// account suffix renders blurred and tap-to-reveal; everything else renders plain. With the setting
/// off, the name renders exactly as before. The name split is centralized here so every display
/// surface (dashboard, Customize, reorder previews, history, share card, menus) blurs identically.
struct AccountNameText: View {
    let text: String
    var font: Font = .system(size: 13, weight: .semibold)
    var foregroundStyle: AnyShapeStyle = AnyShapeStyle(.primary)
    var lineLimit: Int = 1
    var layoutPriority: Double = 0

    @AppStorage(AccountNamePrivacySetting.key) private var blurEnabled = AccountNamePrivacySetting.defaultValue
    @State private var revealed = false

    /// Splits `"Family — Account"` into the prefix to keep visible and the account suffix to blur.
    /// Returns nil when the name carries no account suffix (ordinary single-account cards) or the
    /// setting is off. Splits at the *first* `" — "` so an account label containing its own dashes
    /// stays intact in the blurred part.
    static func splitAccountSuffix(_ text: String) -> (family: String, account: String)? {
        guard let range = text.range(of: " — ") else { return nil }
        let account = String(text[range.upperBound...])
        guard !account.isEmpty else { return nil }
        return (String(text[..<range.lowerBound]), account)
    }

    private var split: (family: String, account: String)? {
        guard blurEnabled else { return nil }
        return Self.splitAccountSuffix(text)
    }

    var body: some View {
        if let split {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\(split.family) — ")
                    .font(font)
                    .foregroundStyle(foregroundStyle)
                    .lineLimit(lineLimit)
                    .layoutPriority(layoutPriority)
                Text(split.account)
                    .font(font)
                    .foregroundStyle(foregroundStyle)
                    .lineLimit(lineLimit)
                    .blur(radius: revealed ? 0 : 7)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { revealed.toggle() } }
                    .accessibilityLabel(revealed ? split.account : "Account name hidden")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(revealed
                        ? "Double tap to hide the account name"
                        : "Double tap to reveal the account name")
            }
        } else {
            Text(text)
                .font(font)
                .foregroundStyle(foregroundStyle)
                .lineLimit(lineLimit)
                .layoutPriority(layoutPriority)
        }
    }
}
