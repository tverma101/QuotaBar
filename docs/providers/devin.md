# Devin

Tracks your Devin quota using the login from the Devin CLI or the Devin app, plus the token usage the Devin CLI records in its local session database.

## What it tracks

| Metric | Meaning |
|---|---|
| Weekly | Weekly quota used (falls back to the daily figure only when Devin reports neither a weekly percentage nor a usable weekly reset; a valid reset with no percentage means the window is exhausted) |
| Daily | Daily quota used (hidden by default when Devin does not return a daily quota; an explicit Customize opt-in keeps the empty state visible) |
| Extra Balance | Overage/extra-usage balance in dollars |
| Usage Trend | Token usage per day for the last 30 days, from local CLI sessions |
| Today / Yesterday / Last 30 Days | Tokens used that day or across the last 30 days, from local CLI sessions; below the caret |

When Devin reports your plan name, QuotaBar shows it beside the provider name.

## Token usage comes from local sessions

Devin's quota API reports percentages, not tokens. Token usage is read from the Devin CLI's local
session database (`~/.local/share/devin/cli/sessions.db`), which records every model call — so
ordinary `devin` sessions count without any export flag. The CLI writes a fresh row as a response
streams; QuotaBar counts each call once.

When the database is missing or holds no metered calls, QuotaBar falls back to the ATIF transcript
exports in `~/.local/share/devin/cli/transcripts` — only sessions launched with `devin --export`
(or run through Devin Desktop) leave one there. The two sources are never added together. When
neither source has usage, the tiles honestly read "No data" rather than inventing totals, and the
numbers are not a billing statement.

Tokens are counted per model call (`input_tokens`, `output_tokens`, `cache_read_tokens`,
`cache_creation_tokens`) and priced at public API rates when the model's name resolves — the
dollar figures are estimates. Devin-native `swe-*` models have no public rate, so their rows show
real token counts without a dollar figure. These totals sit under the Devin caret and are not
pinned by default.

Devin's quota API returns meters and balances, not per-call dollar amounts, so Devin costs appear
only in **API Estimates**. The local log slug `gemini-4-neon-xhigh` maps to the exact public route
`google/gemini-4-neon` for that estimate; this is not a Devin-reported charge.

## Where credentials come from

Checked in this order — whichever works first wins:

1. Devin CLI credentials: `~/.local/share/devin/credentials.toml` (uses `windsurf_api_key`, and `api_server_url` when present)
2. The Devin app's local state database

If the CLI credentials fail but the app is signed in with a different account, the app's auth is used instead.

## Troubleshooting

- **"Not logged in"** — run `devin auth login`, or sign into the Devin app, then refresh.
- **"Couldn't read Devin's local credentials"** — check read access to `credentials.toml` and Devin's state database, then refresh. An existing but unreadable source is reported separately from a missing login.
- **"Devin's service returned an error (HTTP …)"** — Devin's API answered with an error status. QuotaBar logs the status; try again in a moment.
- **"Devin returned quota data QuotaBar couldn't read"** — the response no longer matches the expected shape. QuotaBar logs this so the change can be diagnosed.
- **"Couldn't reach Devin"** — the request never completed. Check the connection and try again.
- **Weekly shows the daily figure** — only when Devin reports neither a weekly percentage nor a usable weekly reset does the daily quota fill the Weekly row (with no reset time of its own). A valid weekly reset with an absent percentage instead means the weekly window is exhausted, so the row reads 100% used.

## Under the hood

Connect RPC `GetUserStatus` on the configured API server (default `server.codeium.com`). Quota percentages arrive as "remaining" and are flipped to "used". No token refresh — a 401/403 switches to the next auth source instead. The Devin app's stored credential is read from its state database only when that file changes, so a quiet refresh does not re-read it. A reported reset time that is zero, stale, or outside a believable window is ignored, so the row falls back to its own cadence ("Resets in 24h") instead of reading "Resets soon" forever.
