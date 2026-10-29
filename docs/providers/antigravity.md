# Antigravity

Tracks pool quotas for Antigravity (Google's AI IDE) using credentials the app or the `agy` CLI already stored on your Mac.

## What it tracks

Antigravity has two shared quota pools, and each pool has two windows — a rolling 5-hour window and a weekly window:

| Metric | Meaning |
|---|---|
| Session | The shared Gemini pool (Pro and Flash draw from the same quota), rolling 5-hour window |
| Weekly | The same Gemini pool's weekly window |
| Argon Weekly | A separate weekly allowance for Gemini 4 Argon, when your account reports it |
| Claude | The shared non-Gemini pool (Claude, GPT-OSS, …), rolling 5-hour window |
| Claude Weekly | The same non-Gemini pool's weekly window |
| Usage Trend | Daily token usage from local Antigravity conversations |
| Today / Yesterday / Last 30 Days | Local token usage and estimated API-equivalent spend |

When Antigravity reports your subscription tier (such as `Pro`, `Ultra`, or `Ultra Lite`), QuotaBar shows it beside the provider name.

Gemini Pro and Gemini Flash are one pool: using either model drains the same quota, so QuotaBar shows one meter per window instead of separate Pro and Flash meters. That pair is named Session and Weekly to match the other providers' rows. Every non-Gemini model shares the second pool, shown under the Claude name (like Codex's Spark pair). The quota API reports fractions, while token usage and estimated spend come separately from local conversation databases.

Argon Weekly is enabled by default, appears only when usable usage is available, and starts On Demand after Weekly without a menu-bar pin. Turning it off in Customize stays off across restarts. Legacy per-model responses never put Argon into the shared Gemini pool because they do not identify its quota window.

Claude and Claude Weekly are optional pools: either row stays hidden by default when the quota response
does not include that pool/window; explicitly enabling one in Customize keeps its empty state visible.
The Gemini Session and Weekly meters remain visible when their data is missing.
After a complete quota response, a pool omitted from that response no longer keeps its previous value.
If a response contains an unknown bucket, a group without a `buckets` array, a duplicate bucket, or a
bucket without a usable fraction, omitted meters keep their previous values and age until a complete
response arrives. Unknown buckets never join a visible pool; when every known meter was refreshed, its
freshness still advances. Duplicate IDs use the more depleted value and keep the response marked
incomplete. Temporary request failures retain the last-good meters and show the provider error.

When using Cloud Code, QuotaBar consults the second host if the first omits shared quota meters. The first usable value for each meter wins. A response with all four usable shared meters avoids the extra request; Argon is optional. A failed or malformed supplemental response preserves measured limits and keeps omitted limits marked as older data.

While a pool's rolling 5-hour window has no usage yet, that meter reads **Not started** on the trailing label instead of a reset countdown; hover explains that the session begins after your first message. The weekly meters always show a normal reset countdown.

## Where credentials come from

QuotaBar never asks for a token — it reads what Antigravity already has:

- **Antigravity running** — QuotaBar talks to the app's local language server (the richest source, and where the plan name comes from). Provider detection also recognizes a discovered Antigravity or `agy` listener; it does not need a separate Cloud Code Keychain token while that local source is available.
- **App closed** — it falls back to the OAuth token Antigravity / `agy` store in your macOS Keychain and queries Google's Cloud Code API. An expired token is refreshed automatically (QuotaBar never writes back to Antigravity's own keychain item). Its short-lived cache is reused only while the same Keychain login is present and readable.

If macOS needs approval for that existing Gemini Keychain item, use the provider's **Refresh** action and choose **Always Allow**. Automatic refreshes stay silent and won't open a Keychain dialog.

If neither is available you'll see *Start Antigravity or run `agy` and try again.* An expired access token with no refresh token is reported as expired sign-in. A Cloud Code 403 is shown as an access denial and does not trigger an OAuth refresh.

## Spend and usage history

QuotaBar reads generation token counts, including the fixed system prompt, from every
`~/.gemini/antigravity*/conversations/*.db` store. This covers the app, IDE, CLI, and compatible
clients with separate conversation roots. It estimates API-equivalent cost using the shared
[model pricing](../pricing.md). These are estimates, not subscription charges, and conversation
content never leaves your Mac.

Older stores include generation dates directly. Newer stores keep dates in conversation steps.
QuotaBar matches their UUIDs and bot IDs even when row numbers differ. Repeated matches are usable
when they agree on the local calendar day; conflicting days stay incomplete. Records without either
ID can still use the legacy row-number match. Undated records never become today's usage on launch.
If a store supplies neither embedded dates nor usable step dates, its dated totals stay unavailable.

Today, Yesterday, Last 30 Days, and Usage Trend combine recent local usage. Usage History retains up
to ten years. Quota meters come from Google's API, so they can show activity even when this Mac has
no matching local records. A quota request failure still allows local history to update and shows
the error alongside it. Meter-only refreshes keep history's separate freshness stamp and warning;
opening the panel or Usage History recomputes carried or stale history.

Unchanged stores reuse cached totals. Changed stores verify old generation and step metadata with
compact SQLite digests, then decode appended rows. Older SQLite builds use bounded verification
batches. Historical edits, changed date matches, and time-zone changes rebuild the affected totals.
Step-date indexes share a 64 MB in-memory budget; an index that exceeds the remaining budget evicts
its whole database cache, and macOS memory pressure clears those database caches together so usage
rows and their dates are rebuilt as one unit.

The transcript logs don't include token accounting, so they aren't used. QuotaBar opens Antigravity
databases in SQLite read-only mode and never retries with read-write access; SQLite may still use WAL
sidecars while reading. Each bounded batch accounts for both generation data and step metadata before
hex expansion. When a client root or database disappears from discovery, its last-good rows remain in the aggregate while
readable stores continue updating. A completed scan of a readable database with no in-window usage
clears old history; an empty directory listing alone does not, because it can race database rotation.
Missing or unpriced models aren't assigned an invented price. Oversized generation records are skipped
with a warning. When a row has a timestamp, QuotaBar marks its day as a lower bound; when its timestamp or contents cannot be
trusted, measured rows remain visible as partial lower bounds and the provider shows a warning. If a
scan finds no measured rows, QuotaBar keeps the last visible history and still surfaces the warning.
Rows without a trustworthy timestamp are excluded from dated totals and keep an incomplete-history
warning until the source can be dated. Read failures remain visible alongside that warning. Missing-root contributions stay cached for the current session; after a
restart, QuotaBar can only re-derive history from roots it can discover.
An unreadable database uses its last-good cached rows when available and marks the combined result
partial; readable sibling stores continue updating. If no database can be read and there is no cached
result, the previous visible history is retained. Cached rows from a temporarily unreadable source recover
when it becomes readable again, and future-dated rows recover once their timestamps become plausible.
Malformed or oversized records remain partial until corrected or until they age out of the history window.

## Troubleshooting

- **"Start Antigravity or run `agy`…"** — sign in to the Antigravity app (or run `agy`) so a usable token exists, then refresh.
- **"Couldn't read Antigravity credentials…"** — unlock Keychain or sign in to Antigravity again. QuotaBar will not use its cached access token until the current login can be verified.
- **"Google denied access to Antigravity usage"** — Cloud Code returned 403. Check that the signed-in account and project have access; QuotaBar does not treat this as an expired token.
- **"Antigravity did not provide a supported usage endpoint"** — the current account or Antigravity build does not expose a quota endpoint QuotaBar recognizes. Update Antigravity and refresh; if the message remains, that account may not expose usage through these endpoints.
- **"Google rejected QuotaBar's Antigravity OAuth client configuration"** — Google returned `invalid_client` while exchanging the refresh token. This is an app-side client configuration issue, not an expired Antigravity sign-in; update QuotaBar and try again.
- **The weekly meters show "No data"** — your Antigravity build doesn't expose the quota-summary endpoint yet (only newer builds do). The 5-hour meters still work from the older endpoints; updating Antigravity brings the weekly meters back.
- **A meter shows "No data"** — that pool/window wasn't in the latest complete response (some tiers only report certain windows). Incomplete responses keep the prior value and mark it stale until a complete response arrives.
- **Spend or usage history shows "No data"** — none of the discovered Antigravity stores has usable generation records in the current 30-day window. The quota meters can still show usage because they come from Google's API; token counts need local generation records. Open Usage History to see older retained records, or run an Antigravity app, IDE, or `agy` session on this Mac and refresh.
- **Some usage is missing** — QuotaBar keeps last-good rows from a cached database or client root that disappears from discovery while readable stores continue updating. A root-discovery or unreadable-database failure preserves the last complete history. Check Settings → Copy Log Path for a read warning, restore access, and refresh.
- **Where did the Gemini Pro and Flash meters go?** — merged: both models draw from the one shared Gemini pool, which is now the single Session meter.
- **Quotas look full after heavy use** — the 5-hour windows reset on a rolling basis and the weekly windows once a week; the reset time is shown on each meter.

## Under the hood

Best source first: the local language server discovered by scanning for the `language_server` / `agy` process and reading its CSRF token and listening ports; then Google Cloud Code using the Keychain token, refreshed via Google OAuth when needed. QuotaBar binds its short-lived refreshed-token cache to a one-way fingerprint of the current Keychain refresh credential. Logout, account changes, legacy caches, and expired or malformed entries cannot reuse a previous account's access token. On each source QuotaBar asks the quota-summary endpoint first (`RetrieveUserQuotaSummary` on the language server, `v1internal:retrieveUserQuotaSummary` on Cloud Code) — the only endpoint that reports the merged pools and the weekly windows. Builds without it fall back to the legacy per-model endpoints (`GetUserStatus` / `GetCommandModelConfigs` locally, `fetchAvailableModels` / `retrieveUserQuota` remotely), whose per-model quotas are merged into the two pools by keeping each pool's worst remaining fraction; those endpoints only know the 5-hour windows. The plan name prefers Antigravity's own `userTier` over the inherited Windsurf plan field. Spend history comes from the generation-accounting protobuf records in each local conversation database.

Thanks to [FelixIsaac](https://github.com/FelixIsaac) for identifying the conversation-database source and contributing the original SQLite/protobuf implementation in [issue #1120](https://github.com/robinebers/openusage/issues/1120) and [pull request #1058](https://github.com/robinebers/openusage/pull/1058).

> Reverse-engineered from the app and language-server binary; endpoints and storage may change without notice.
