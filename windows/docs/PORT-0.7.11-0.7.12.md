# OpenUsage v0.7.11 + v0.7.12 port (QuotaBar 1.5.0)

Upstream **v0.7.11** (2026-09-05) was never landed; bundle it with **v0.7.12** (2026-09-17). Swift-only — port applicable behavior into JS plugins + Rust scanners + React/Tauri.

**Version:** [**1.5.0**](./VERSIONING.md) — **MINOR** because Gemini Apps is a new QuotaBar provider. The upstream bundle itself is PATCH-class and rides along. Baseline: QuotaBar **1.4.4**. Tags: `v0.7.11`, `v0.7.12`.

## Status legend

| Status | Meaning |
|--------|---------|
| **ship** | In **1.5.0** scope |
| **skip** | macOS-only, upstream infra, or already in the fork |
| **later** | Valid fork work; deferred |

## Phase 1 — Pricing

| Upstream | QuotaBar action | Status |
|----------|-------------------|--------|
| Gemini 3.8 Flash + Cursor aliases (#1211) | `pricing_supplement.json` | **done** |
| GPT-6 Astra + Codex priority / 272k rates (#1208) | Supplement + `codex_pricing.rs` | **done** |
| Fable 5.1 + Grok bot aliases (#1197) | Supplement | **done** |
| Muse Spark 1.3 effort variants (#1244) | Supplement | **done** |
| Cursor Grok Bot mode rates (#1246) | `grok-bot-default` → Grok 4.6 Fast, `grok-bot-automation` → Grok 4.6 | **done** |
| Codex `gpt-reserve` at Luna (#1247) | Keep slug; price as `gpt-5.6-luna` | **done** |

## Phase 2 — Plugins / scanners

| Upstream | QuotaBar action | Status |
|----------|-------------------|--------|
| Hide pacing on untouched meters (#1016) | `used <= 0` → no pace projection | **done** |
| Grok subagent / fork / resume ledgers (#1193) | Count every `updates.jsonl` (no event_id double-count) | **done** |
| Codex Business Premium (#1194) | `self_serve_business_prolite` → **Business Premium** | **done** |
| Antigravity all `~/.gemini/antigravity*/conversations` (#1206 dirs) | `conversations_dirs` lists sibling stores | **done** |
| Devin exhausted weekly when percent omitted (#1251) | Reset present + percent omitted → 0 remaining; unparsable throws | **done** |
| Claude nested iteration `model: null` (#1261) | Skip advisor row; keep parent | **done** |
| Claude live plan from `/api/oauth/profile` (#1262) | Once per access token after successful usage | **done** |

## Skip

| Upstream | Why |
|----------|-----|
| Ollama Cloud Ed25519 (#1173) | Fork already has Ollama Cloud via cookies / HTML / API key |
| OpenCode Codex OAuth + shared request pricing (#1195) | Later — no OpenCode Codex OAuth scanner in the fork yet |
| Claude Desktop account-prefixed caches (#1212) | macOS Desktop Safe Storage |
| Menu-bar pin ID remap (#1179) | macOS status-item schema v3; fork tray IDs already migrate |
| iCloud Codex account metadata (#1196) | iCloud sync |
| Claude Swap accounts (#1226) | macOS Desktop / Swap |
| Nested Claude workflow → parent (#1241) | Ownership / workflow scans |
| Repeated Claude session ownership scans (#1245) | Same |
| stale.yml keep-open (#1225) | Upstream GitHub infra |
| PostHog bumps | Aptabase, not PostHog |
| Antigravity step timestamps (#1206 remainder) | Later — dirs only this patch |

## Tests & docs

| Item | Status |
|------|--------|
| Pricing aliases / Astra / Spark / Fable 5.1 | **done** |
| Pace zero-usage, Grok 500-token ledgers, Claude null-model | **done** |
| Devin exhausted weekly / malformed percent | **done** |
| Claude live plan + usage-call counts | **done** |
| Codex Business Premium | **done** |
| Antigravity sibling stores | **done** |
| Host redacts Claude profile `uuid` | **done** |
| `CHANGELOG.md` **1.5.0** cites Gemini Apps + **v0.7.11 + v0.7.12** | **done** |
