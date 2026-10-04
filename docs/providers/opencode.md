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

QuotaBar shows "Go" beside the provider only after OpenCode's account endpoint confirms usable Go
usage windows. Having a saved key by itself does not establish that the subscription is active.

The Session / Weekly / Monthly meters are **account-wide**: QuotaBar reads them from OpenCode's official
usage endpoint (`/zen/go/v1/usage`), so they count every client that uses your OpenCode Go account — the
OpenCode CLI on any machine, Claude Code sessions routed through the gateway (`anthropic/opencode_go/…`
models), and anything else billed to the account. If the endpoint has a temporary network, server, or
rate-limit failure, **Show All Accounts** can fall back to this Mac's recent Go spend against the published caps
($12 / 5h, $30 / week, $60 / month). Local history has no account identity, so this fallback is hidden
when a specific key is pinned. It never shows the Go badge. If OpenCode rejects a key or cannot confirm
its Go entitlement, QuotaBar hides the cap meters and keeps the local spend tiles. The Go badge appears
only after the endpoint returns all three usable account windows (`ok` or `rate-limited`). If you only
use the Zen pay-as-you-go gateway (no Go subscription), the cap meters are hidden and you'll just see the
spend tiles.

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
When the API has a temporary network, server, or rate-limit failure and no account is pinned, the meters can fall
back to this Mac's observed spend against the published caps — the recorded `opencode*.db` cost plus
the gateway-fold estimates from this Mac's Claude Code / Codex / Hermes logs (Go-subscription usage
only; Zen pay-as-you-go bills separately and is excluded) — so the percent and dollars come from the
same local source. A pinned key never uses this aggregate because the local rows cannot be assigned to
that account. Authentication, entitlement, invalid-response, and other client errors (except HTTP 429)
also suppress the cap fallback.
The spend tiles combine every client that dials the OpenCode gateway on this Mac:

1. Per-message cost OpenCode records in its local SQLite logs (authoritative dollars), and
2. Claude Code sessions routed through the OpenCode gateway — their measured tokens are folded into the
   tiles, with dollars imputed from token counts.
3. The Zen gateway's per-message cost.
4. Codex rollouts whose turns ran through the gateway (parsed with the Codex scanner's own parser,
   so cumulative-total deltas and subagent replay gating are handled exactly as the Codex card does).
   A separate gateway-only cache reuses the native parse records and keeps unrelated Codex turns out
   of repeated OpenCode folds. Codex output includes reasoning, which is counted once.
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

The spend detail keeps a free model with a material share of tokens on its own named row even though
its spend share is `0%`. Models grouped into `Other` are identified beneath that row's label, led by
the model with the most tokens.

## Troubleshooting

- **Everything shows "No data"** — QuotaBar needs OpenCode's local database at
  `~/.local/share/opencode/opencode*.db`. Run an OpenCode session, then refresh. (An active Go account
  confirmed by the account endpoint can show cap meters before your first local message.)
- **No Session / Weekly / Monthly meters** — those are Go-plan caps. The account endpoint must confirm
  the subscription, or a temporary network/server/rate-limit failure must leave recent local Go usage
  for the unpinned fallback. A pinned key never uses aggregate local history. Rejected keys, an
  unconfirmed entitlement, other client errors, or an unreadable response hide the cap meters. A saved
  key alone is not enough; Zen-only accounts see the spend tiles instead.
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

The router ledger includes legacy `anthropic/opencode_go/…` and `anthropic/opencode/…` rows even
when no native session log exists. For a local day and model covered by the router, gateway session
logs are skipped; native-only days and models fill the gaps. This avoids counting a routed turn from
both sources. Without a shared request ID, independently used sessions of the same model on a covered
day cannot be separated reliably; the router source takes precedence.

CodexRouter sometimes records `estimatedInputTokens` when the upstream provider reported zero input tokens.
That is a router approximation used for context-window bookkeeping, not a measured count. QuotaBar does not
fold it into token or dollar totals; it counts the input, cached-input, and output tokens the provider
actually reported. A provider that reports zero input can therefore still contribute its measured output
tokens, while an invented input estimate is never presented as real usage.

A row whose model is priced at zero — including an unlisted model whose name ends in `-free`, such as a
router-served custom model — still contributes its **tokens**. A row with no price at all is excluded from
every total and reported by the unpriced-model warning instead, so a free tier never silently disappears.

### Cost of reading the ledger

The ledger grows as requests complete. Only bytes appended since the last read are parsed. Small ledgers keep individual
rows for the window. Large ledgers fold into durable local-calendar day/model buckets, so a refresh keeps a
small aggregate plus the individual Go rows still needed by the rolling cap meters instead of keeping every
OpenCode row resident. The compact checkpoint is persisted, so an unchanged ledger after a relaunch is a
metadata check rather than a full parse. Rewriting or replacing existing data invalidates the checkpoint.
The hosted production benchmark uses 8,192 synthetic rows across multiple models and days, verifies
exact totals, and checks that repeated reads consume zero new ledger bytes:

```sh
QUOTABAR_PRODUCTION_ACCOUNTING_BENCH=1 swift test -c release --disable-swift-testing --filter ProductionTokenAccountingEfficiencyTests
```

Fields are read straight out of the line's bytes rather than through `JSONSerialization`, which was the
dominant cost. The shared CodexRouter single-pass parser also supplies timestamp, provider, status, input,
cached-input, output, reasoning, and total fields in one structural walk; OpenCode converts only the
provider-stamped, successful rows it owns. Lines for other providers cost almost nothing because they are
rejected before token accounting. A line the writer had not finished is carried to the next read rather
than parsed, and a truncated line is skipped rather than turned into a short row.
