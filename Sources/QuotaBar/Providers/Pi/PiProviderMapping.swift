import Foundation

/// Maps a pi session log's `provider` field to the QuotaBar provider whose card its usage belongs on.
/// Pi is a BYO-key agent that drives other providers' models, so its usage is attributed back to the
/// underlying provider (a Claude sub used inside pi lands on the Claude card) rather than shown on a
/// card of its own.
///
/// Only providers QuotaBar already has a card for are listed. Pi providers with no QuotaBar
/// equivalent are intentionally absent and left for future work:
/// - `nvidia-nim` — no QuotaBar card.
///
/// Mapped here but not yet consumed (only Claude and Codex read the pi slice today; the rest have no
/// local usage-trend card to fold into, or use a different spend path): `cursor` (Cursor's trend is
/// built from its CSV export), `zai`/`zhipu`, `google-antigravity`, `github-copilot`.
enum PiProviderMapping {
    /// pi `provider` value → QuotaBar `Provider.id`.
    static let providerToCard: [String: String] = [
        "anthropic": "claude",
        "claude-agent-sdk": "claude",
        "openai-codex": "codex",
        "cursor": "cursor",
        "zai": "zai",
        "zhipu": "zai",
        "google-antigravity": "antigravity",
        "github-copilot": "copilot"
    ]

    /// The QuotaBar card id for a pi provider, or nil when pi used a provider QuotaBar doesn't track.
    static func cardID(forPiProvider provider: String) -> String? {
        providerToCard[provider]
    }
}
