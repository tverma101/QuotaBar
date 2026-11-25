//! OpenCode gateway model ids (Swift `OpenCodeUsageScanner.claudeGatewayPrefixes`,
//! `isHostedGatewayModel`, `isOpenCodeGoGatewayModel`).

/// Model-id prefixes that identify Claude Code sessions routed through the OpenCode gateway.
/// `anthropic/opencode_go/<model>` is the Go subscription, `anthropic/opencode/<model>` the Zen
/// gateway.
pub const CLAUDE_GATEWAY_PREFIXES: [&str; 2] = ["anthropic/opencode_go/", "anthropic/opencode/"];

/// True when a Claude Code / Codex log model is billed through OpenCode Go/Zen rather than the native
/// Claude/Codex subscription. Native card aggregates skip these so Total Spend does not count the same
/// gateway turn on both the native card and the OpenCode fold.
pub fn is_hosted_gateway_model(model: &str) -> bool {
    let trimmed = model.trim();
    CLAUDE_GATEWAY_PREFIXES
        .iter()
        .any(|prefix| trimmed.starts_with(prefix))
}

/// The Go slug identifies Go billing even when an older Router row carries the upstream vendor as its
/// provider label instead of `opencode-go`.
pub fn is_opencode_go_gateway_model(model: &str) -> bool {
    model.trim().starts_with(CLAUDE_GATEWAY_PREFIXES[0])
}
