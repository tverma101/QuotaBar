# Antigravity

Tracks pool quotas for Antigravity (Google's AI IDE) using credentials the app or the `agy` CLI already stored on your Mac.

## What it tracks

Antigravity has two shared quota pools, and each pool has two windows — a rolling 5-hour window and a weekly window:

| Metric | Meaning |
|---|---|
| Session | The shared Gemini pool (Pro and Flash draw from the same quota), rolling 5-hour window |
| Weekly | The same Gemini pool's weekly window |
| Claude | The shared non-Gemini pool (Claude, GPT-OSS, …), rolling 5-hour window |
| Claude Weekly | The same non-Gemini pool's weekly window |
| Usage Trend | Daily token usage from local Antigravity conversations |
| Today / Yesterday / Last 30 Days | Local token usage and estimated API-equivalent spend |

When Antigravity reports your subscription tier (such as `Pro` or `Ultra`), QuotaBar shows it beside the provider name.

Gemini Pro and Gemini Flash are one pool: using either model drains the same quota, so QuotaBar shows one meter per window instead of separate Pro and Flash meters. That pair is named Session and Weekly to match the other providers' rows. Every non-Gemini model shares the second pool, shown under the Claude name (like Codex's Spark pair). The quota API reports fractions, while token usage and estimated spend come separately from local conversation databases.

While a pool's rolling 5-hour window has no usage yet, that meter reads **Not started** on the trailing label instead of a reset countdown; hover explains that the session begins after your first message. The weekly meters always show a normal reset countdown.

## Where credentials come from

QuotaBar never asks for a token — it reads what Antigravity already has:

- **Antigravity running** — QuotaBar talks to the app's local language server (the richest source, and where the plan name comes from). Provider detection also recognizes a discovered Antigravity or `agy` listener; it does not need a separate Cloud Code Keychain token while that local source is available.
- **App closed** — it falls back to the OAuth token Antigravity / `agy` store in your macOS Keychain and queries Google's Cloud Code API. An expired token is refreshed automatically (QuotaBar never writes back to Antigravity's own keychain item). Its short-lived cache is reused only while the same Keychain login is present and readable.

If macOS needs approval for that existing Gemini Keychain item, use the provider's **Refresh** action and choose **Always Allow**. Automatic refreshes stay silent and won't open a Keychain dialog.

If neither is available you'll see *Start Antigravity or run `agy` and try again.* An expired access token with no refresh token is reported as expired sign-in. A Cloud Code 403 is shown as an access denial and does not trigger an OAuth refresh.

## Spend and usage history

QuotaBar reads generation token counts, including the fixed system prompt, from every `~/.gemini/antigravity*/conversations/*.db` store. That covers the Antigravity app, IDE, CLI, and compatible clients that keep separate conversation roots. QuotaBar estimates their API-equivalent cost using the shared [model pricing](../pricing.md). Today, Yesterday, Last 30 Days, and Usage Trend combine recent usage across the discovered stores; Usage History retains up to ten years. The quota meters come from Google's API, while token counts come only from generation records stored on this Mac, so quota usage can be present while these local token rows have no recent data. If Google's quota request fails, QuotaBar still scans local history and shows the error alongside any available spend rows. These are estimates, not charges from your Antigravity subscription, and conversation data never leaves your Mac. Unchanged databases reuse their cached history; when a database changes, QuotaBar verifies cached rows with one compact SQLite digest query before reading appended generations. SQLite CLI builds without the digest functions use the bounded batch verifier. Edits to older records trigger a full rescan so totals don't stay stale.

The transcript logs don't include token accounting, so they aren't used. When a client root or database
disappears from discovery, its last-good rows remain in the aggregate while readable stores continue
updating. A root-discovery or database-read failure keeps the last complete aggregate instead of
publishing partial history. Missing or unpriced models aren't assigned an invented price, and unusually
large generation records are skipped with a warning to keep memory usage bounded.

## Troubleshooting

- **"Start Antigravity or run `agy`…"** — sign in to the Antigravity app (or run `agy`) so a usable token exists, then refresh.
- **"Couldn't read Antigravity credentials…"** — unlock Keychain or sign in to Antigravity again. QuotaBar will not use its cached access token until the current login can be verified.
- **"Google denied access to Antigravity usage"** — Cloud Code returned 403. Check that the signed-in account and project have access; QuotaBar does not treat this as an expired token.
- **"Google rejected QuotaBar's Antigravity OAuth client configuration"** — Google returned `invalid_client` while exchanging the refresh token. This is an app-side client configuration issue, not an expired Antigravity sign-in; update QuotaBar and try again.
- **The weekly meters show "No data"** — your Antigravity build doesn't expose the quota-summary endpoint yet (only newer builds do). The 5-hour meters still work from the older endpoints; updating Antigravity brings the weekly meters back.
- **A meter shows "No data"** — that pool/window wasn't in the latest response (some tiers only report certain windows). The other meters still update.
- **Spend or usage history shows "No data"** — none of the discovered Antigravity stores has usable generation records in the current 30-day window. The quota meters can still show usage because they come from Google's API; token counts need local generation records. Open Usage History to see older retained records, or run an Antigravity app, IDE, or `agy` session on this Mac and refresh.
- **Some usage is missing** — QuotaBar keeps last-good rows from a cached database or client root that disappears from discovery while readable stores continue updating. A root-discovery or unreadable-database failure preserves the last complete history. Check Settings → Copy Log Path for a read warning, restore access, and refresh.
- **Where did the Gemini Pro and Flash meters go?** — merged: both models draw from the one shared Gemini pool, which is now the single Session meter.
- **Quotas look full after heavy use** — the 5-hour windows reset on a rolling basis and the weekly windows once a week; the reset time is shown on each meter.

## Under the hood

Best source first: the local language server discovered by scanning for the `language_server` / `agy` process and reading its CSRF token and listening ports; then Google Cloud Code using the Keychain token, refreshed via Google OAuth when needed. QuotaBar binds its short-lived refreshed-token cache to a one-way fingerprint of the current Keychain refresh credential. Logout, account changes, legacy caches, and expired or malformed entries cannot reuse a previous account's access token. On each source QuotaBar asks the quota-summary endpoint first (`RetrieveUserQuotaSummary` on the language server, `v1internal:retrieveUserQuotaSummary` on Cloud Code) — the only endpoint that reports the merged pools and the weekly windows. Builds without it fall back to the legacy per-model endpoints (`GetUserStatus` / `GetCommandModelConfigs` locally, `fetchAvailableModels` / `retrieveUserQuota` remotely), whose per-model quotas are merged into the two pools by keeping each pool's worst remaining fraction; those endpoints only know the 5-hour windows. The plan name prefers Antigravity's own `userTier` over the inherited Windsurf plan field. Spend history comes from the generation-accounting protobuf records in each local conversation database.

Thanks to [FelixIsaac](https://github.com/FelixIsaac) for identifying the conversation-database source and contributing the original SQLite/protobuf implementation in [issue #1120](https://github.com/robinebers/openusage/issues/1120) and [pull request #1058](https://github.com/robinebers/openusage/pull/1058).

> Reverse-engineered from the app and language-server binary; endpoints and storage may change without notice.
