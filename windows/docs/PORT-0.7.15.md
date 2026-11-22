# OpenUsage v0.7.15 port

Upstream **v0.7.15** (2026-10-19). Swift-only — port applicable behavior into JS plugins, Rust usage scanners/pricing, and tests.

## Shipped

| Upstream | QuotaBar action |
|----------|-------------------|
| Codex usage dashboard link (`chatgpt.com/codex/settings/usage` → `chatgpt.com/settings/usage`) (`1c37176`) | `plugins/codex/plugin.json` |
| Gemini `-n` (`none` effort) model alias pricing (`2fd740a`) | `crates/quotabar-core/data/pricing_supplement.json`, `crates/quotabar-core/src/model_pricing.rs` |
| Codex `codex-auto-review` $0 cost since Oct 6, 2026 (`b5a6e56`) | `crates/quotabar-core/src/codex_usage_scanner.rs`, `crates/quotabar-core/src/pi_usage_scanner.rs` |
| OpenCode Go SQLite migration check (`20260805200742_import_legacy_credentials`) before overriding `auth.json` (`34474ec`) | `plugins/opencode-go/plugin.js`, `plugins/opencode-go/plugin.test.js` |
| Ollama `/api/balance` dollar allowance + Purchased Credits (`677d886`) | `plugins/ollama/plugin.json`, `plugins/ollama/plugin.js`, `plugins/ollama/plugin.test.js` |
| Claude `Rate Limit Resets` hourly throttling + expired grant pruning (`60a379b`) | `plugins/claude/plugin.js`, `plugins/claude/plugin.test.js` |
| Cursor incremental day-by-day paged usage events (`POST /api/dashboard/get-filtered-usage-events`) + local history cache (`93e5897`) | `crates/quotabar-core/src/cursor_usage_export.rs` |

## Skip

| Upstream | Why |
|----------|-----|
| Claude Desktop multi-account switch UI (`#1355`, `#1358`) | macOS Claude Desktop app storage / Swift UI account switcher |
| PostHog / Sparkle / Xcode build configuration bumps | Upstream macOS-only tooling |
