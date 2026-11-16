import SwiftUI

/// Renders a provider display name with its account-identifying suffix blurred by default.
///
/// Managed multi-account cards build names as `"Family — Account"` (see `ProviderAccountAssembly`),
/// so the suffix after the first `" — "` is the account. With the setting on (the default), the
/// account suffix renders blurred and tap-to-reveal; everything else renders plain. With the setting
/// off, the name renders exactly as before. The name split is centralized here so every display
/// surface (dashboard, Customize, reorder previews, history, share card, menus) blurs identically.
/// Menu surfaces (NSMenu-backed) cannot deliver taps to their items, so they pass
/// `interactiveReveal: false` — they stay blur-only and carry no button semantics.
struct AccountNameText: View {
    let text: String
    var font: Font = .system(size: 13, weight: .semibold)
    var foregroundStyle: AnyShapeStyle = AnyShapeStyle(.primary)
    var lineLimit: Int = 1
    var layoutPriority: Double = 0
    /// Tap-to-reveal on the suffix. False inside menu labels, where the gesture can never fire.
    var interactiveReveal: Bool = true

    @AppStorage(AccountNamePrivacySetting.key) private var blurEnabled = AccountNamePrivacySetting.defaultValue
    @State private var revealed = false

    /// Splits `"Family — Account"` into the prefix to keep visible and the account suffix to blur.
    /// Returns nil when the name carries no account suffix (ordinary single-account cards).
    /// Splits at the *first* `" — "` so an account label containing its own dashes stays intact
    /// in the blurred part.
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
                suffixText(split.account)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(revealed ? text : "\(split.family), account name hidden")
            .accessibilityAddTraits(interactiveReveal ? .isButton : [])
            .accessibilityHint(accessibilityHintText)
        } else {
            Text(text)
                .font(font)
                .foregroundStyle(foregroundStyle)
                .lineLimit(lineLimit)
                .layoutPriority(layoutPriority)
        }
    }

    private var accessibilityHintText: String {
        guard interactiveReveal else { return "" }
        return revealed
            ? "Double tap to hide the account name"
            : "Double tap to reveal the account name"
    }

    @ViewBuilder
    private func suffixText(_ account: String) -> some View {
        let label = account
        if interactiveReveal {
            Text(label)
                .font(font)
                .foregroundStyle(foregroundStyle)
                .lineLimit(lineLimit)
                .blur(radius: revealed ? 0 : 10)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { revealed.toggle() } }
        } else {
            Text(label)
                .font(font)
                .foregroundStyle(foregroundStyle)
                .lineLimit(lineLimit)
                .blur(radius: 10)
        }
    }
}
