# Devin

Tracks your Devin quota using the login from the Devin CLI or the Devin app.

## What it tracks

| Metric | Meaning |
|---|---|
| Weekly | Weekly quota used (falls back to the daily figure when Devin reports no weekly quota) |
| Daily | Daily quota used (hidden by default when Devin does not return a daily quota; an explicit Customize opt-in keeps the empty state visible) |
| Extra Balance | Overage/extra-usage balance in dollars |

When Devin reports your plan name, QuotaBar shows it beside the provider name.

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
- **Weekly shows the daily figure** — when Devin reports no separate weekly quota, the daily quota is shown in the Weekly row so it stays meaningful.

## Under the hood

Connect RPC `GetUserStatus` on the configured API server (default `server.codeium.com`). Quota percentages arrive as "remaining" and are flipped to "used". No token refresh — a 401/403 switches to the next auth source instead.
