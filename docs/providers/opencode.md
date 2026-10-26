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
models), and anything else billed to the account. If the endpoint is unavailable or cannot confirm
current Go usage, QuotaBar hides the cap meters and Go badge, clears any previously cached quota rows,
and keeps local spend and token history. Local history does not prove that the subscription is active.
The Go badge appears
only after the endpoint returns all three usable account windows (`ok` or `rate-limited`). If you only
use the Zen pay-as-you-go gateway (no Go subscription), the cap meters are hidden and you'll just see the
spend tiles. Local `opencode-go` history without a current Go key is not evidence of an active
subscription and never enables the cap meters.

QuotaBar fingerprints the complete inventory of Go keys, including when there is one key or no keys.
At launch, if a key rotated under the same label or the inventory could not be read, cached Go caps
are hidden until the complete inventory is readable and the current key answers. During a refresh,
an unreadable source withholds new Go quota requests and clears caps whose owner cannot be verified.
Machine-local spend and token history remains visible across the change.

## Multiple keys

OpenCode stores separate credentials for separate products. Only the `opencode-go` API key belongs to
the Go account-usage endpoint; the sibling `opencode` key is a Zen gateway credential and is never sent
to the Go endpoint. QuotaBar also accepts app-saved Go keys for additional accounts. An exact duplicate
key (for example, the same key in `auth.json` and QuotaBar settings) is fetched safely but shown once;
different keys remain separate even if their current percentages happen to match, because the endpoint
does not return a stable account id that would justify merging them. The card creates separate Session,
Weekly, and Monthly rows for every distinct configured account; repeated display labels are numbered so
each row remains identifiable.

**Keys in settings.** OpenCode ▸ Customize ▸ **OpenCode Go Keys** lets you save extra Go keys (for
example a second account's key from another machine) with a label, remove them, and pick which account
the card shows. Saved keys are stored in QuotaBar's Application Support folder; the `auth.json` keys
themselves are listed read-only. The list reloads when the section opens and after an edit. Tapping a
key row pins the card to that key's account — the meters swap to its numbers — and tapping **Show All
Accounts** unpins back to one row per distinct account. Adding or removing a key rebuilds those account
rows and refreshes OpenCode without repeating the startup account scan. Removing the pinned key clears
the selection automatically. The spend tiles are local to this Mac, so they do not change when you swap
accounts.

## Where credentials come from

Use OpenCode as usual. QuotaBar reads OpenCode's local data directory
(`~/.local/share/opencode`, or `$OPENCODE_DATA_DIR` / `$XDG_DATA_HOME` if you've set them): the
`opencode-go` entry in `auth.json` to detect Go usage, and the local SQLite logs for the numbers. There's no login
prompt and no token to paste. Keys saved through the app's settings are read alongside the `auth.json`
keys. Routine startup inventories those Go keys only while the OpenCode provider is enabled. Opening
**OpenCode Go Keys** in Customize or making a CLI request for OpenCode also reads them for that action.
The keys are used only in the request to OpenCode's usage endpoint and are never persisted in logs.

## The meters and spend tiles

The account meters show ONLY the official subscription numbers: the percentages are OpenCode's own
account-wide accounting, and each row's dollar context is the remaining allowance derived from that
same percent against the published caps (e.g. `80% used · $12.00 of $60`) — local estimates never mix
into these rows. Click a meter's headline to flip the whole card between "used" and "left" readings.
If the endpoint is unavailable, returns an incomplete response, or does not confirm active Go usage,
the cap rows and plan badge disappear until a later successful account response. Cached quota rows are
cleared, while local spend and token history remains available.
The spend tiles combine every client that dials the OpenCode gateway on this Mac:

1. Per-message cost OpenCode records in its local SQLite logs (authoritative dollars), and
2. Claude Code sessions routed through the OpenCode gateway — their measured tokens are folded into the
   tiles, with dollars imputed from token counts.
3. The Zen gateway's per-message cost.
4. Codex rollouts whose turns ran through the gateway (parsed with the Codex scanner's own parser,
   so cumulative-total deltas and subagent replay gating are handled exactly as the Codex card does).
   A separate gateway-only cache reuses the native parse records and keeps unrelated Codex turns out
   of repeated OpenCode folds. Codex output includes reasoning, which is counted once.
5. Hermes sessions billed to the OpenCode account (`billing_provider` `opencode-go` / `opencode`, or
   the OpenCode Go base URL, in `~/.hermes/state.db`) — Hermes talks to the gateway directly and never
   writes `opencode*.db`.

When a spend period includes a gateway row priced from tokens, its dollar value carries the estimate
marker. A period made only of OpenCode's recorded SQLite costs stays unmarked, even if an older day
contains an estimate. The lifetime History total keeps the marker when any included day has imputed
dollars.

If any configured usage source cannot be read completely, QuotaBar keeps the last complete spend
history instead of publishing a partial subtotal; it records which source failed in the diagnostic log.
The Router source list and verified prefix are checked again after the wider fold. Malformed events,
rotation, truncation, changed prefix samples, and same-size rewrites retain the prior history. Ordinary
appends leave the measured prefix valid; the next refresh consumes the new tail.
For CodexRouter rows, QuotaBar keeps the reported token total when it disagrees with the measured
components, but marks the spend and public-rate estimate incomplete. A zero-token row never suppresses
matching native usage. If a Router reports a zero total with positive input or output but omits the other
measured component, OpenCode keeps the last-good history until the row has a complete breakdown.
A router row with zero input/output/total but measured reasoning keeps that reasoning as an output
lower bound. Its input remains unknown, its cost stays incomplete, and it never replaces complete
native usage. A single such row does not stop other local history from updating.
Router `estimatedInputTokens` never contributes to measured usage, even when the estimate itself exceeds
the safe integer range. If finite SQLite costs overflow when they are combined, QuotaBar keeps the finite
priced subtotal as a lower bound and marks it Partial. The local Go fallback meter clamps over-cap spend
to 100% and keeps its window totals finite.

OpenCode's SQLite logs use a reported total when it is positive, or derive the total from valid token
components when the stored total is zero or missing. The fallback requires a token object with valid
input and output counts. If a row has malformed token or cost values, or a Router JSONL record is too
large to parse safely, that fold keeps the previous complete history. Pi and Muse session records with
invalid counters, impossible cache buckets, or mismatched reported totals also keep the previous history.
Malformed Router records with uniquely validated routing, status, and account stamps are kept as validation
markers and do not block enabled accounts; enabling that account makes the source incomplete until the row
is repaired or removed. Failed requests with a valid non-success status are ignored even if their usage
fields are malformed. Unknown, conflicting, or malformed account stamps still fail closed. Timezone changes
rebuild local-day Router buckets from the source ledger.

The Claude gateway fold shares the native Claude card's incremental parse cache and deduplicates
overlapping Claude roots. Unchanged sources reuse a bounded gateway-only projection after checking
ownership and timestamps, avoiding another fold through unrelated Claude history. The Codex gateway
fold includes app-registered Codex homes and visits each
canonical home separately, sharing the per-home cache with its account card. This keeps multi-session
and multi-config setups from omitting or re-reading the same terminal session during a cold refresh
without changing the usage sources or ownership filtering.

Imputed dollars (items 2, 4, 5) are calibrated to the provider's OWN recorded cost per token: when the
local logs carry billed rows for a model, its fold is priced at the average rate those rows actually
recorded, not the catalog sticker rate. That matters because the gateway bills DeepSeek cache hits at a
fraction of the sticker input rate — the recorded average can sit ~15× below the catalog miss rate, so
charging every token at the miss rate would overstate spend by the same factor. Models with no recorded
rows fall back to catalog rates; free-tier models recorded at $0 fold at $0. A few models skip
calibration entirely because their recorded sample misrepresents the published rate: Muse Spark (tiny
sample) and DeepSeek V4 Pro (cache-mix mismatch) use the catalog card, and Space Bunny's legacy
`space-bunny-free` rows recorded $0 during its free-promo period while the model is paid on the GO plan
now, so the supplement's GO card prices its folds.

Go and Zen observations stay separate even when they use the same model, since the two products can
bill at different rates. A hosted database row dated more than five minutes in the future makes the
scan incomplete, so QuotaBar keeps the last complete spend history instead of adding a future-day total.
CodexRouter rows for enabled or unresolved accounts follow the same bound. A future row positively
identified as belonging to a disabled Codex account does not block other enabled accounts; QuotaBar keeps
its account watermark in the compact ledger so enabling that account later still waits for the clock or
source revision before counting the row.
Future-dated Hermes sessions with no tokens in any usage bucket are ignored after their fields are validated,
since they cannot change spend totals.

Whenever imputed dollars are present the tiles carry the ⓘ estimate marker; models the catalogs don't
know surface as a warning instead of a guess.

**Days with a still-running Hermes session are partial.** Hermes writes a session's usage ledger to
`~/.hermes/state.db` in delayed bursts while the session runs, so the fold's view of an in-progress
session always trails the actual consumption — and keeps rising until the session ends. QuotaBar
detects those sessions (`ended_at` not yet set) and marks the affected day's tiles with the ⓘ marker
on BOTH the dollars and the token count, and the Usage Trend note explains it — a live session is
never presented as a settled total. Once the session ends, the ledger finalizes and the numbers
converge on the next refresh. The card's official account meters are unaffected and stay current.
Usage History totals and model rows also show Partial for those days, and Total Spend excludes an
active-session period from Cost/MTok. The local `/v1/usage` response adds `partial: true` while keeping
the current values available.
If the Hermes database can't be read at all during a refresh (e.g. locked by a busy write), the whole
fold fails closed: nothing narrower is published as if it were the complete card, the failure is logged
loudly (once per persistent failure), and the last good history stays on screen until the source
recovers.

Each spend tile shows cost and tokens together (`$4.08 · 1.2M tokens`), the same as Claude / Codex /
Cursor. A period with no recorded usage reads "No data" rather than a misleading `$0.00`. Local
history retains up to ten years for the Usage History screen; spend tiles include only their labeled
dates. The compact router ledger keeps exact Go event times for recent cap windows and folds older
events into day/model totals, preserving whether input was measured or estimated. No log data leaves
your Mac.

The spend detail never hides a model that holds a material share of the period's tokens on its own
named row — even when its cost share (or actual cost) is tiny: tokens are the measured quantity, so
half the usage can never disappear behind "Other". Models grouped into `Other` are identified
beneath that row's label, led by the model with the most tokens.

## Troubleshooting

- **Everything shows "No data"** — QuotaBar needs OpenCode's local database at
  `~/.local/share/opencode/opencode*.db`. Run an OpenCode session, then refresh. (An active Go account
  confirmed by the account endpoint can show cap meters before your first local message.)
- **No Session / Weekly / Monthly meters** — those are Go-plan caps and require a successful current
  account response. Network/server/rate-limit failures, rejected keys, incomplete responses, and
  unconfirmed entitlements hide the cap meters. Local Go history does not prove an active subscription;
  Zen-only accounts see spend tiles instead.
- **"Couldn't read OpenCode's local database"** — the database (or data directory) exists but couldn't be
  read this refresh. An unreadable discovered database keeps OpenCode enabled so QuotaBar can surface
  this error. Quit OpenCode and refresh; if it persists, check the permissions on
  `~/.local/share/opencode`.
- **"Couldn't read OpenCode credentials"** — `auth.json` or QuotaBar's saved Go-key file
  (`~/Library/Application Support/QuotaBar/opencode-go-keys.json`) exists but couldn't be read. Check
  file permissions, then refresh. QuotaBar waits for both credential sources before making Go quota
  requests, including when only one key is currently known. Unreadable credentials clear cached caps
  because their account owner cannot be verified. Local spend history still refreshes when its database
  can be read, and the last confirmed local history stays available if the database scan fails.
- **The ⓘ appears on the spend tiles** — some of the dollars are imputed from token counts (Claude Code
  sessions routed through the gateway don't record a per-message cost); the tokens are always measured.
- **A warning triangle names a model** — a model the pricing catalogs don't know was used through the
  gateway; its tokens were left out of the totals rather than guessed. Add an alias or pricing entry if
  you want it counted.

## Under the hood

QuotaBar reads both the legacy `message` table and the newer `session_message` table. During
migration it combines them by message ID, preferring the newer copy so a turn counts once. The
usage probe and Go cycle anchor use the same schema detection. Provider-reported zero cost stays
zero, including free models; missing costs keep measured tokens with incomplete cost.

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
when no native session log exists. A router row can replace native Codex log usage only when its account
identity resolves to an enabled Codex account and every router bucket for that local day/model/account
has complete measured input. Claude, Hermes, and Muse rows always count independently. Rows without a
resolvable router account identity stay additive. If the router supplies only estimated input and a
matching native Codex row exists, the native row wins; otherwise the measured router fields remain visible.

The native Codex logs and router ledger do not share a request ID. QuotaBar therefore cannot separate
independent same-model Codex work by the same account on one local day: when a complete router bucket and
a native row overlap, the router bucket takes precedence for that whole day/model/account pair. Known
pricing aliases share a reconciliation key, so alternate model spellings do not count one turn twice.

CodexRouter sometimes records `estimatedInputTokens` when the upstream provider reported zero input tokens.
That is a router approximation used for context-window bookkeeping, not a measured count. QuotaBar does not
fold it into token or dollar totals; it counts the input, cached-input, and output tokens the provider
actually reported. A provider that reports zero input can therefore still contribute its measured output
tokens, while an invented input estimate is never presented as real usage.

A row whose model is priced at zero — including an unlisted model whose name ends in `-free`, such as a
router-served custom model — still contributes its **tokens**. A row with no price still contributes its
reported **tokens**, but no dollar estimate; QuotaBar marks the affected spend period with the unpriced-model
warning so a partial priced subtotal is not mistaken for the model's full cost.

### Cost of reading the ledger

The ledger grows as requests complete. Only bytes appended since the last read are parsed. Small ledgers keep individual
rows for the window. Large ledgers fold into durable local-calendar day/model buckets, so a refresh keeps a
small aggregate plus the individual Go rows still needed by the rolling cap meters instead of keeping every
OpenCode row resident. The compact checkpoint is persisted, so an unchanged ledger after a relaunch is a
metadata check rather than a full parse. Rewriting or replacing existing data invalidates the checkpoint.
The checkpoint checks both modification and change timestamps, including when a same-size rewrite restores
the original modification time, and only records a stamp validated against the bytes it just read.
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
