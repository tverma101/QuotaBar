# Hermes

Tracks your Hermes Agent usage — tokens and cost across your sessions — from Hermes' own local session
database. Nothing is sent anywhere.

## What it tracks

| Metric | Meaning |
|---|---|
| Today | Tokens (and estimated cost) across all Hermes sessions started today |
| This Week | Same, for the current week (starts Monday, your local calendar) |
| This Month | Same, for the current calendar month |
| Usage Trend | A day-by-day sparkline of tokens over the last month |

Each period row shows cost and tokens together (`$0.42 · 9,250 tokens`). Hover a row for the per-model
breakdown — which model used how many tokens — from Hermes' own attribution table. A period with no
usage reads "No data".

The token counts come straight from Hermes' accounting (`input_tokens`, `output_tokens`,
`cache_read_tokens`, `cache_write_tokens`, `reasoning_tokens`), so they include cached and reasoning
tokens the way Hermes bills them. The dollar figure is Hermes' own per-session estimate, so it carries
the ⓘ marker; tokens are always measured.

## Where the data comes from

Use Hermes as usual. OpenUsage reads Hermes' session database at `~/.hermes/state.db` (or
`$HERMES_HOME/state.db` if you've set it) — the same SQLite store Hermes keeps its sessions, token
counters, and billing metadata in. Read-only: OpenUsage never writes to it, and no data leaves your Mac.

## Troubleshooting

- **"Hermes not detected"** — OpenUsage found no `~/.hermes/state.db`. Run Hermes once (CLI or desktop)
  so it creates the database, then refresh.
- **"Couldn't read Hermes' state database"** — the database exists but couldn't be read this refresh
  (locked, corrupt, permissions). Quit Hermes and refresh, or check the permissions on `~/.hermes`.
- **The ⓘ appears on the rows** — the dollar figures are Hermes' estimates of what the sessions cost;
  the token counts are measured.

## Under the hood

OpenUsage queries the `sessions` table (period totals, daily series) and `session_model_usage` (the
per-model breakdown) with the same read-only sqlite access every other local provider uses. Days are
grouped in your Mac's local time zone, so they line up with your own calendar.
