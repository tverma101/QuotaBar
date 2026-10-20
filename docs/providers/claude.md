# Claude

Tracks your Claude subscription limits using the login you already have from Claude Code or Claude Desktop.

Each account and organization gets its own Claude card with separate limits and spending. Signing in to
the same account and organization through both Claude Code and Claude Desktop still creates only one card.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | 5-hour rolling window usage |
| Weekly | 7-day window usage |
| Fable | Separate weekly Fable limit (model-scoped window from the `limits` array) |
| Sonnet | Separate weekly Sonnet limit (plan-dependent; hidden until Claude returns it, unless you explicitly enable the row) |
| Extra Usage | Extra-usage credits spent against your monthly cap |
| Today / Yesterday / Last 30 Days | Local spend, as cost, tokens, or both (see below) |

Fable is enabled and always visible directly below Weekly by default. Sonnet stays off until you
enable it in Customize. When Claude reports your plan name, QuotaBar shows it beside the provider name.

## Where credentials come from

Sign in with Claude Code or Claude Desktop; QuotaBar reads the existing login. It checks these sources, preferring one that can read your subscription usage:

1. The macOS keychain entry Claude Code maintains (its source of truth on macOS)
2. `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR/.credentials.json`)
3. Claude Desktop's encrypted login cache
4. `CLAUDE_CODE_OAUTH_TOKEN` environment variable

When multiple accounts are available, a Claude Desktop login for the card's organization takes precedence
when needed. QuotaBar verifies that a credential belongs to the correct account and organization.

Claude Desktop support is read-only. QuotaBar decrypts its currently valid access token using the
`Claude Safe Storage` item in your macOS Keychain. It never reads or uses Desktop's refresh token, and
never changes Desktop's config, cookies, or Keychain entry. This prevents QuotaBar from invalidating
Claude Desktop's session. If the Safe Storage item is replaced while QuotaBar is open, a decryption
mismatch triggers one coordinated key reload and retry. If that replacement still cannot decrypt the
cache, a later explicit refresh gets one bounded reload attempt for that cached key generation.

QuotaBar discovers Desktop organization cards only while a Claude card is enabled. Enabling Claude
after it was fully off rebuilds the account list first. The key read during discovery is shared with
the provider cards, so the first refresh reuses it.

Opening the panel and background refreshes never open a Keychain dialog. If macOS requires approval,
use **Refresh Now**; one explicit refresh can show at most one Keychain dialog across Claude account
cards, and cards that need the same item share that one dialog instead of prompting again. Choosing
**Always Allow** makes later reads silent. If Desktop's short-lived token expires, open
Claude Desktop so it can renew the login, then refresh QuotaBar.

A `CLAUDE_CODE_OAUTH_TOKEN` — usually a long-lived `claude setup-token` — can run the model but can't read your Session and Weekly limits, and it often lingers in your shell environment. So when a real keychain or file login is present, QuotaBar uses that login for the live meters and keeps the environment token only as a fallback; the Session/Weekly meters no longer go blank just because that token is set. If the environment token is your *only* credential (a headless setup), it's used on its own and the spend tiles still load from local logs.

If one source holds an expired or "locked out" token, QuotaBar falls back to the others — so signing in again with `claude` outside the app is picked up on the next refresh, without restarting QuotaBar. Claude Code tokens are refreshed automatically; rotated tokens are written back only while the ordered login candidates still match the start of the refresh, so a newly added higher-priority login wins. Claude Desktop tokens are never refreshed or written by QuotaBar.

Some older Claude credentials do not include a scope list, so QuotaBar still tries live usage with them. If Anthropic explicitly replies with `OAuth token does not meet scope requirement user:profile`, QuotaBar treats that as a missing permission and asks you to sign in again; it does not call the token expired or try to refresh it. Other 403 responses keep the normal auth retry behavior.

## The spend tiles

Today / Yesterday / Last 30 Days are computed **locally**: QuotaBar reads the Claude Code session logs under `~/.claude/projects/` (or `$CLAUDE_CONFIG_DIR`) itself — no external tools needed. Symlinks are followed, so a projects folder linked into a synced location (say, a Dropbox folder) is read all the same. With one known account, Claude usage from the [pi](https://github.com/earendil-works/pi) coding agent counts too: QuotaBar reads pi's session logs under `~/.pi/agent/sessions/` (or `$PI_CODING_AGENT_SESSION_DIR`) and folds any Claude usage there into the same tiles and trend, so a Claude sub driven through pi still shows up here. pi records its own per-message cost, so those dollars come straight from pi rather than being re-estimated. Cowork (the Claude desktop app's agent mode) counts too: it writes the same logs into per-session folders under `~/Library/Application Support/Claude/local-agent-mode-sessions/`, and QuotaBar scans those as well, so desktop agent sessions show up in the tiles alongside terminal ones. Persisted `claude -p` runs count as well. Runs made with `--no-session-persistence` cannot appear because Claude deliberately writes no session log for QuotaBar to read. Advisor work recorded inside a message is counted once under the advisor's own model; the parent's main-model totals are kept separate, and ordinary iteration details are not counted again. A log's recorded fast or standard speed controls its price; QuotaBar does not infer speed from the event date. Days are grouped in your Mac's local time zone, so they line up with your own calendar. Each period is one tile showing cost and tokens together (`$4.08 · 1.2M tokens`); a day with no usage reads **No data** rather than a misleading `$0.00 · 0 tokens` — the same as every other spend-tracking provider. The live Session and Weekly meters are unaffected. The dollars are estimated from token counts at API rates (that's the ⓘ) using the shared [model pricing](../pricing.md); invalid log versions or malformed or negative token buckets keep that source incomplete and preserve last-good history. No log data leaves your Mac.

Sessions that do not identify their account, including usage from pi and third-party tools such as
Conductor, count as long as QuotaBar has never seen more than one Claude account. Once multiple
accounts are discovered, unattributed usage is left out instead of being assigned to the wrong card.

Local spend does not require a Claude OAuth login. If Claude Code uses an API-key gateway instead, the spend tiles and usage trend still load from its session logs; the Claude header shows **Not logged in** because the live Session and Weekly meters still require a Claude subscription login.

## Troubleshooting

- **"Not logged in"** — run `claude` and sign in to enable live subscription limits, then refresh. If you use an API-key gateway, local spend still appears whenever Claude Code has written session logs.
- **Claude Code Keychain access requires approval** — QuotaBar found the Claude Code login in macOS Keychain but could not read it silently. Use **Refresh Now** and choose **Always Allow** when macOS asks. First-run detection never opens this dialog. If a readable file token is rejected and Desktop has no login, QuotaBar keeps this permission error visible so you can grant access to the current login.
- **Claude Code Keychain couldn't be read** — QuotaBar could not read a Claude Code login from macOS Keychain. Check that the keychain is unlocked and QuotaBar can access the item, then refresh. A usable file or Desktop login takes precedence when available.
- **Claude credentials couldn't be read** — QuotaBar found a Claude Code credentials file but macOS could not read it. Check access to `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR/.credentials.json`), then refresh. Local spend still comes from session logs.
- **Claude credentials are invalid** — QuotaBar found a readable credentials file but it is malformed or has no access token. Run `claude` and sign in again, then refresh.
- **Claude Desktop login data couldn't be read** — QuotaBar found Desktop login data but couldn't read its config or Cookies database. Check access to `~/Library/Application Support/Claude/config.json` and the `Cookies` database, then refresh. This check does not open a Keychain dialog.
- **"Claude Desktop login found"** — refresh manually and choose **Always Allow** when macOS asks for access to `Claude Safe Storage`.
- **"Claude Desktop login is stale"** — open Claude Desktop so it can renew the login, then refresh QuotaBar.
- **"Re-login for live usage"** (an amber warning on the Claude header) — your saved login can authenticate for inference but can't read your subscription limits, because it lacks the `user:profile` access (this is what an inference-only token from `claude setup-token` carries). Run `claude` and sign in again with your Claude account, then refresh; the spend tiles keep working in the meantime.
- **"Updates blocked by Anthropic"** (an amber warning on the Claude header) — the usage API is throttling QuotaBar. It keeps the last values from the same login, shows when it will retry, and backs off in the meantime. A different login starts with a fresh cache and cooldown.
- **Spend tiles show "No data"** — QuotaBar found no Claude Code logs in the last 30 days. If your logs live somewhere custom, set `CLAUDE_CONFIG_DIR` so both Claude Code and QuotaBar look in the same place.

## Under the hood

`GET https://api.anthropic.com/api/oauth/usage` with the selected OAuth token. Claude Code tokens refresh via `platform.claude.com/v1/oauth/token`; Claude Desktop tokens are read-only and must be renewed by Desktop itself. If a token is expired or revoked, QuotaBar retries with the next credential source before reporting an error.

When the five-hour session window hasn't begun (the usage API reports no reset time), the Session row shows **Not started** on the trailing label; hover explains that the session begins after your first message. A reported reset time means the window is running, so the row always shows the countdown then — even when Anthropic's whole-percent numbers still read 0% because less than 1% has been used, which matches what Claude Code itself shows.
