# OpenUsage Codex spend double-counting fix (FCC + OpenCode gateway)

## Findings (2026-09-07 / Tejas Mac)

### Hardlink ownership — still correct

Live source + `/Applications/OpenUsage.app` (built after the hardlink fix) keep:

`skipPeerHardlinks = !isDefaultCodexHome && !peerInodes.isEmpty`

Inventory simulation:

| Tree | jsonl | role |
|------|------:|------|
| `~/.codex` | 361 | default keeps all (incl. shared) |
| Orca managed home | 328 | |
| Shared hardlinks (nlink=2) | 276 | stay on default; account2 skips |
| Only-orca | 52 | priced on account2 |
| Registered `Account-ADC7C6C8…` | 0 sessions | auth-only; logHomes still include Orca |

`ProviderCatalog` still wires `peerHomes` both ways. OpenCode fold still scans default first, then managed with `peerHomes=default`.

`sharedTailCache` is path-keyed (`resolve` + standardize). Hardlinked peers are different paths → different keys. With managed skipping shared inodes, cards do not rehydrate each other's attributed files after `unloadRetainedItems`.

### Real double-count — FCC proxy + native logs (account2)

Account2 (`1118f6f1…` / gmail) showed tile note **"From your Codex logs, FCC proxy (estimated)"**.

- Only-orca sessions are almost all `gpt-5.6-luna`
- `~/.fcc/usage.db` fingerprint `acct_1257f3fe5af1` (account2) has ~3001 rows / ~335M tokens last-30, model `anthropic/openai/gpt-5.6-luna`
- `DailyUsageAccumulator.merged([native, proxy, pi])` **added both** with no day-level dedupe

Default account had no FCC fingerprint rows → no FCC note → no this class of double.

### Secondary double-count — OpenCode gateway fold vs native cards

Codex (and Claude) session logs include `anthropic/opencode_go/…` and `anthropic/opencode/…`. OpenCode folds those into its tiles. Native `aggregate` also priced them → Total Spend could count the same gateway turn twice (Codex/Claude slice + OpenCode slice).

API Weekly % meters are **quota**, not local $ — looking different from Last 30 is expected, not mixing.

## Fix

1. **`DailyUsageAccumulator.mergedPreferringPrimary(_:fillingGapsFrom:)`**  
   Primary days win; FCC (etc.) only fills days with no primary priced rows.  
   `CodexProvider` uses this for native vs FCC, then still `merged` with pi.

2. **`OpenCodeUsageScanner.isHostedGatewayModel`**  
   Codex + Claude `aggregate` skip hosted gateway models.  
   `parsedEvents` / `parsedEntries` unchanged so the OpenCode fold still sees them.

## Tests

- `testMergedPreferringPrimaryKeepsPrimaryDaysAndFillsGapsOnly`
- `testMergedPreferringPrimaryReportsNoSupplementWhenFullyOverlapped`
- `testAggregateSkipsOpenCodeHostedGatewayModels`

## Before → after (live API on Tejas Mac)

| Card | Before Last 30 | After Last 30 | Note |
|------|----------------|---------------|------|
| Codex default (icloud) | $489.61 · 11.1B | $489.84 · 11.1B | Codex logs only (gateway models excluded from aggregate; tiny drift / live traffic) |
| Codex account2 (gmail) | $94.53 · 1.6B | $91.63 · 1.6B | FCC gap-fill only; overlapping FCC+log days no longer double (~$2.90) |
| OpenCode | $164.13 · 10.6B | $164.13 · 10.6B | unchanged (still owns gateway fold) |

Account2 trend note may still mention FCC when proxy-only days remain; it drops "FCC proxy" when every proxy day is already covered by logs.

## What to glance at in the UI

- Per-account **Last 30 / Today** (local estimate) — account2 note should drop "FCC proxy" when logs already cover those days
- **Weekly / Session %** — ChatGPT API quota meters; do not compare them as dollar tokens
- **Total Spend** — OpenCode slice holds gateway-imputed $; Codex slices should not re-include `anthropic/opencode*` models
