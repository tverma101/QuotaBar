# Hermes

Tracks your Hermes Agent usage — tokens and cost across sessions billed to their configured providers —
from Hermes' own local session database. Nothing is sent anywhere.

## What it tracks

| Metric | Meaning |
|---|---|
| Today | Tokens (and estimated cost) across Hermes sessions billed outside OpenCode and started today |
| This Week | Same, for the current week (starts Monday, your local calendar) |
| This Month | Same, for the current calendar month |
| Usage Trend | A day-by-day sparkline of tokens over the last month |

Each period row shows cost and tokens together (`$0.42 · 9,250 tokens`). Hover a row for the per-model
breakdown — which model used how many tokens — from Hermes' own attribution table. A period with no
usage reads "No data".

The token counts come straight from Hermes' accounting (`input_tokens`, `output_tokens`,
`cache_read_tokens`, `cache_write_tokens`, `reasoning_tokens`), so they include cached and reasoning
tokens the way Hermes bills them. OpenCode-billed sessions appear on the OpenCode card, which reflects
the account that paid for them; including them here as well would double count those tokens in Total
Spend. The dollar figure is Hermes' own per-session estimate, so it carries the ⓘ marker; tokens are
always measured. Sessions whose `ended_at` is still empty are marked Partial on the provider row, in
spend totals, their affected model breakdown rows, and Usage History until Hermes closes them. The
marker stays with the lifetime total after older per-model details age out.

QuotaBar does not retain per-day model attribution for Hermes, so it cannot price those tokens at
public API rates. Token days are marked incomplete in Usage History, so the combined public-rate
estimate is not shown as a complete total. If any token-bearing session has no recorded cost (including
the database's default-zero value), the Hermes dollar total for that period or day is left blank while
its measured tokens remain visible.
If a source counter or recorded cost is malformed, QuotaBar keeps the last complete history instead of
publishing a smaller subtotal.

## Where the data comes from

Use Hermes as usual. QuotaBar reads Hermes' session database at `~/.hermes/state.db` (or
`$HERMES_HOME/state.db` if you've set it) — the same SQLite store Hermes keeps its sessions, token
counters, and billing metadata in. Read-only: QuotaBar never writes to it, and no data leaves your Mac.

## Troubleshooting

- **"Hermes not detected"** — QuotaBar found no `~/.hermes/state.db`. Run Hermes once (CLI or desktop)
  so it creates the database, then refresh.
- **"Couldn't read Hermes' state database"** — the database exists but couldn't be read this refresh
  (locked, corrupt, permissions). Quit Hermes and refresh, or check the permissions on `~/.hermes`.
- **The ⓘ appears on the rows** — the dollar figures are Hermes' estimates of what the sessions cost;
  the token counts are measured.

## Under the hood

QuotaBar queries the `sessions` table (period totals, daily series) and `session_model_usage` (the
per-model breakdown) with the same read-only sqlite access every other local provider uses. Days are
grouped in your Mac's local time zone, so they line up with your own calendar.
