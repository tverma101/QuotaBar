# OpenCode

Tracks your OpenCode-hosted usage — the **Go** subscription and the **Zen** pay-as-you-go gateway —
from your OpenCode account plus OpenCode's own logs already on your Mac.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | Account-wide usage in the rolling 5-hour window, as a percent of the plan cap, with the reset countdown |
| Weekly | Account-wide usage this week, as a percent (resets Monday) |
| Monthly | Account-wide usage this cycle, as a percent |
| Today / Yesterday / Last 30 Days | Cost and tokens across all your OpenCode-hosted usage (Go + Zen), including Claude Code sessions routed through the OpenCode gateway |
| Usage Trend | A day-by-day sparkline of tokens over the last month |

When you have the Go subscription, QuotaBar shows "Go" beside the provider name.

The Session / Weekly / Monthly meters are **account-wide**: QuotaBar reads them from OpenCode's official
usage endpoint (`/zen/go/v1/usage`), so they count every client that uses your OpenCode Go account — the
OpenCode CLI on any machine, Claude Code sessions routed through the gateway (`anthropic/opencode_go/…`
models), and anything else billed to the account. If the endpoint is unreachable, the meters fall back
to this Mac's observed spend against the published caps ($12 / 5h, $30 / week, $60 / month) and the card
keeps working. If you only use the Zen pay-as-you-go gateway (no Go subscription), the cap meters are
hidden and you'll just see the spend tiles.

## Multiple keys

OpenCode stores separate credentials for separate products. Only the `opencode-go` API key belongs to
the Go account-usage endpoint; the sibling `opencode` key is a Zen gateway credential and is never sent
to the Go endpoint. QuotaBar also accepts app-saved Go keys for additional accounts. An exact duplicate
key (for example, the same key in `auth.json` and QuotaBar settings) is fetched safely but shown once;
different keys remain separate even if their current percentages happen to match, because the endpoint
does not return a stable account id that would justify merging them.

**Keys in settings.** OpenCode ▸ Customize ▸ **OpenCode Go Keys** lets you save extra Go keys (for
example a second account's key from another machine) with a label, remove them, and pick which account
the card shows. Saved keys are stored in an app-owned file next to `auth.json`; the `auth.json` keys
themselves are listed read-only. Tapping a key row pins the card to that key's account — the meters
swap to its numbers, labeled with the key — and tapping **Show All Accounts** unpins back to one row
per distinct account. Removing the pinned key clears the selection automatically. The spend tiles are
local to this Mac, so they do not change when you swap accounts.

## Where credentials come from

Use OpenCode as usual. QuotaBar reads OpenCode's local data directory
(`~/.local/share/opencode`, or `$OPENCODE_DATA_DIR` / `$XDG_DATA_HOME` if you've set them): the
`opencode-go` entry in `auth.json` to detect Go usage, and the local SQLite logs for the numbers. There's no login
prompt and no token to paste. Keys saved through the app's settings are read alongside the `auth.json`
keys. The keys are used only in the request to OpenCode's usage endpoint and are never persisted in
logs.

## The meters and spend tiles

The account meters show ONLY the official subscription numbers: the percentages are OpenCode's own
account-wide accounting, and each row's dollar context is the remaining allowance derived from that
same percent against the published caps (e.g. `80% used · $12.00 of $60`) — local estimates never mix
into these rows. Click a meter's headline to flip the whole card between "used" and "left" readings.
When the API is unreachable the meters fall back to this Mac's observed spend against the published
caps — the recorded `opencode*.db` cost plus the gateway-fold estimates from this Mac's Claude Code /
Codex / Hermes logs (Go-subscription usage only; Zen pay-as-you-go bills separately and is excluded) —
so the percent and the dollars then come from the same local source and agree exactly.
The spend tiles combine every client that dials the OpenCode gateway on this Mac:

1. Per-message cost OpenCode records in its local SQLite logs (authoritative dollars), and
2. Claude Code sessions routed through the OpenCode gateway — their measured tokens are folded into the
   tiles, with dollars imputed from token counts.
3. The Zen gateway's per-message cost.
4. Codex rollouts whose turns ran through the gateway (parsed with the Codex scanner's own parser,
   so cumulative-total deltas and subagent replay gating are handled exactly as the Codex card does).
5. Hermes sessions billed to the OpenCode account (`billing_provider` `opencode-go` / `opencode` in
   `~/.hermes/state.db`) — Hermes talks to the gateway directly and never writes `opencode*.db`.

The Claude gateway fold shares the native Claude card's incremental parse cache and deduplicates
overlapping Claude roots. The Codex gateway fold includes app-registered Codex homes and visits each
canonical home separately, sharing the per-home cache with its account card. This keeps multi-session
and multi-config setups from omitting or re-reading the same terminal session during a cold refresh
without changing the usage sources or ownership filtering.

Imputed dollars (items 2, 4, 5) are calibrated to the provider's OWN recorded cost per token: when the
local logs carry billed rows for a model, its fold is priced at the average rate those rows actually
recorded, not the catalog sticker rate. That matters because the gateway bills DeepSeek cache hits at a
fraction of the sticker input rate — the recorded average can sit ~15× below the catalog miss rate, so
charging every token at the miss rate would overstate spend by the same factor. Models with no recorded
rows fall back to catalog rates; free-tier models recorded at $0 fold at $0.

Whenever imputed dollars are present the tiles carry the ⓘ estimate marker; models the catalogs don't
know surface as a warning instead of a guess.

**Days with a still-running Hermes session are partial.** Hermes writes a session's usage ledger to
`~/.hermes/state.db` in delayed bursts while the session runs, so the fold's view of an in-progress
session always trails the actual consumption — and keeps rising until the session ends. QuotaBar
detects those sessions (`ended_at` not yet set) and marks the affected day's tiles with the ⓘ marker
on BOTH the dollars and the token count, and the Usage Trend note explains it — a live session is
never presented as a settled total. Once the session ends, the ledger finalizes and the numbers
converge on the next refresh. The card's official account meters are unaffected and stay current.
If the Hermes database can't be read at all during a refresh (e.g. locked by a busy write), the fold
is skipped but the failure is logged loudly (once per persistent failure), never silently dropped.

Each spend tile shows cost and tokens together (`$4.08 · 1.2M tokens`), the same as Claude / Codex /
Cursor. A period with no recorded usage reads "No data" rather than a misleading `$0.00`. No log data
leaves your Mac.

## Troubleshooting

- **Everything shows "No data"** — QuotaBar needs OpenCode's local database at
  `~/.local/share/opencode/opencode*.db`. Run an OpenCode session, then refresh. (If you're logged into
  Go, the cap meters show at 0% even before your first local message.)
- **No Session / Weekly / Monthly meters** — those are Go-plan caps; you'll see them when you're logged
  into OpenCode Go or have used it recently on this Mac. Zen-only (or lapsed) users see the spend tiles
  instead — old Go history alone won't bring the caps back.
- **"Couldn't read OpenCode's local database"** — the database (or data directory) exists but couldn't be
  read this refresh. Quit OpenCode and refresh; if it persists, check the permissions on
  `~/.local/share/opencode`.
- **"Couldn't read OpenCode's auth.json"** — the file exists but is unreadable or not valid JSON. Check
  its permissions, or log into OpenCode Go again to rewrite it.
- **The ⓘ appears on the spend tiles** — some of the dollars are imputed from token counts (Claude Code
  sessions routed through the gateway don't record a per-message cost); the tokens are always measured.
- **A warning triangle names a model** — a model the pricing catalogs don't know was used through the
  gateway; its tokens were left out of the totals rather than guessed. Add an alias or pricing entry if
  you want it counted.

## Under the hood

QuotaBar reads the assistant-message `cost` and token fields from every `opencode*.db` in the data
directory (stable is `opencode.db`, the preview line is `opencode-next.db` — all channels are unioned).
The Go caps sum the `opencode-go` messages; the spend tiles and trend sum both `opencode-go` (Go) and
`opencode` (Zen). Claude Code's session logs under `~/.claude/projects` (or `$CLAUDE_CONFIG_DIR`),
Codex rollouts under `~/.codex/sessions` + `archived_sessions` (or `$CODEX_HOME`), and Hermes'
`~/.hermes/state.db` (or `$HERMES_HOME`) are scanned for gateway-billed sessions — model ids starting
with `anthropic/opencode_go/` or `anthropic/opencode/` for Claude/Codex, `billing_provider`
`opencode-go`/`opencode` for Hermes — and folded into the same tiles. The account meters come from
`GET https://opencode.ai/zen/go/v1/usage` with each Go key as the Bearer token. Read-only; nothing is sent
except the authenticated usage request.

## Codex Router turns

CodexRouter meters every turn it routes, including the ones it hands to an OpenCode-hosted account
(`opencode-go`, `opencode`, `opencode-free`). Those turns never reach `opencode*.db` — a free Zen model can
bypass the OpenCode server entirely — so this card reads the router's `usage-events.jsonl` ledger for them,
while the Codex card defers them here. The two cards therefore partition the ledger: nothing is counted
twice, and nothing falls through the gap between them.

A row is named for the model (`space-bunny-free`), not the serving account (`opencode-free/`). Only
`opencode-go` is charged against the Go subscription's Session / Weekly / Monthly cap meters; Zen and free
tier usage is billed outside them.
