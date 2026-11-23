# OpenUsage v0.7.14 port

Upstream **v0.7.14** (2026-10-06). Swift-only — port applicable behavior into JS plugins, reset label helpers, and tests.

## Shipped

| Upstream | QuotaBar action |
|----------|-------------------|
| Codex plan names (`prolite` → `Pro 100`, `pro` → `Pro 200`, `promax` → `Pro 500`) (#1332) | `plugins/codex/plugin.js` + `plugins/codex/plugin.test.js` |
| Cursor structured team usage pools preferred over legacy $20 allowance (#1337) | `plugins/cursor/plugin.js`, `plugins/cursor-nightly/plugin.js`, `plugins/cursor/plugin.test.js` |
| OpenCode Go sub-1% Session reset countdowns and 5h untouched placeholder drop (#1340) | `plugins/opencode-go/plugin.js`, `src/lib/reset-tooltip.ts`, `src/components/provider-card.tsx`, `src/lib/widget-data.ts` + tests |

## Skip

| Upstream | Why |
|----------|-----|
| Independent Codex home token persistence on account cards (#1322) | Tied to macOS Swift auto-discovered `CodexAccountCard` / `xswap`; QuotaBar extra accounts manage credentials via explicit account storage |
| Local Codex spend per auto-discovered account folder (#1349) | Tied to macOS `CodexHistoryScope` / `xswap` multi-account card discovery |
| Retained slow Codex history scans across refreshes (#1338) | QuotaBar runs probes in isolated per-refresh QuickJS workers |
| Report an Issue in Options menu (#1343) | macOS SwiftUI `HeaderView` Options capsule; QuotaBar already has feedback/support links |
| Screen header/footer pager slide & AppKit panel top-edge rounding (#1345, #1346) | macOS SwiftUI `DashboardView` / AppKit `PanelHeightController` |
| PostHog 3.85.3 bump (#1347) | Upstream iOS/macOS SDK dependency |
