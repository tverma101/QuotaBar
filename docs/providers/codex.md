# Codex

Tracks your ChatGPT/Codex subscription limits using the login from the Codex CLI.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | 5-hour rolling window usage |
| Weekly | 7-day window usage |
| Spark / Spark Weekly | GPT-5.3-Codex-Spark model limits — a 5-hour and a weekly window. Shown only when your account has the limit (otherwise "No data"), and tucked below the "show more" caret by default |
| Rate Limit Resets | On-demand rate-limit reset credits, shown as a count (e.g. `2 available`) with a colored dot for the soonest expiry; hover the value for a timeline of each credit's expiry |
| Extra Usage | Flex credits, shown verbatim as dollars + credits (e.g. `$31.84 · 796 credits`) |
| Today / Yesterday / Last 30 Days | Local spend, as cost, tokens, or both (see below) |

When Codex reports your plan name, QuotaBar shows it beside the provider name.

## Where credentials come from

Sign in once with the Codex CLI (`codex`); QuotaBar reads the same auth files (`$CODEX_HOME` respected) with a keychain fallback. Tokens refresh automatically and rotate back into the auth file.

## Registering another account

Open **Settings → Codex Accounts → Sign in to Codex…**. QuotaBar creates a separate Codex home under its application-support directory and launches the official `codex login` browser OAuth flow directly with that home selected. Complete the browser approval; QuotaBar stores only the home path, never the credentials, and only registers it after Codex produces identifiable account metadata. QuotaBar then reloads its provider catalog and builds the separate usage card in the same session. All registered Codex accounts appear as separate cards inside one shared QuotaBar menu-bar panel alongside other enabled providers such as Cursor; QuotaBar keeps one status item so accounts never look like duplicate apps. Existing family-level menu-bar pins are copied to a newly discovered account once so the account card starts with the existing layout; removing that new pin later is respected.

Registered homes are included even when login-shell environment capture is temporarily unavailable, so a cold or failed shell capture does not hide an account registered here.

If you already authenticated a custom Codex home, use **Use Existing Codex Home…** and select the directory containing its `auth.json`. The existing `OPENUSAGE_CODEX_HOMES` environment variable remains supported for scripted setups. Registered homes and environment homes are merged and normalized, while PR 92's identity checks still collapse duplicate homes for the same account and reject unattributed credentials.

## The spend tiles

Native Codex session rollouts remain the primary local source. FCC-routed Codex requests are also folded
from the local FCC usage ledger (`~/.fcc/usage.db`, or `FCC_USAGE_DB`) when its request-start account
fingerprint exactly matches this card's Codex account id. This covers a registered Codex home with no
native session JSONL. Historical FCC rows without a fingerprint remain un-attributed rather than being
guessed onto an account.

Today / Yesterday / Last 30 Days are computed **locally**: QuotaBar reads the Codex CLI's session rollouts under `~/.codex/sessions/` and `archived_sessions/` (or `$CODEX_HOME`) itself — no external tools needed. Symlinks are followed, so a Codex home linked into a synced location (say, a Dropbox folder) is read all the same. Codex usage from the [pi](https://github.com/earendil-works/pi) coding agent counts too: QuotaBar reads pi's session logs under `~/.pi/agent/sessions/` (or `$PI_CODING_AGENT_SESSION_DIR`) and folds any Codex usage there into the same tiles and trend. pi records its own per-message cost, so those dollars come straight from pi rather than being re-estimated. Days are grouped in your Mac's local time zone, so they line up with your own calendar. Each period is one tile showing cost and tokens together (`$4.08 · 1.2M tokens`); a day with no usage reads **No data** rather than a misleading `$0.00 · 0 tokens` — the same as every other spend-tracking provider. The live Session and Weekly meters are unaffected. The dollars are estimated from token counts at API rates (that's the ⓘ) using the shared [model pricing](../pricing.md); sessions that ran on the fast/priority service tier — as recorded in each session's own log — use the fast rates for exactly those turns. Older logs without tier metadata, and everything else, price at standard rates; the current `config.toml` setting is not consulted, so flipping the tier never reprices past days. Auto-review usage keeps its `codex-auto-review` name in the model breakdown, while its cost uses the dated model fallback available for that event. The token counts themselves are measured. Subagent and forked sessions copy their parent session's token history into their own log; QuotaBar recognizes those copies and counts each token once, no matter how many subagents a session spawns. No log data leaves your Mac.

CodexRouter turns are read from its local `usage-events.jsonl` ledger. The Codex card leaves turns served by OpenCode to the OpenCode card, so the two cards do not count the same request twice. Production scans store compact daily totals and a byte checkpoint. An unchanged ledger reads no event bytes; growth reads only the appended bytes. Rotation, truncation, changed attribution, a changed price, or an advanced calendar window rebuilds the affected totals. A catalogue fetch with unchanged prices keeps the cache valid. Native session history remains available to fill days the router did not observe.

Automatic accounting uses a shared pacer targeting 7.5% of one process CPU core across instrumented slices. This is an average target, not a hard instantaneous cap. The compact router ledger fold seeds its cache without pacing so a cold scan does not repeatedly hit the 120-second provider deadline. Later refreshes reuse the cache. Cancelled scans discard partial totals.

Run `script/measure_token_accounting.sh` on an isolated Mac to check the event-cache path with three raw/paced pairs. The fixed medium fixture has 8,192 rows / 3,276,800 bytes, two accounts, and a 4,096-event append burst. It verifies exact tokens, cold indexing, persisted-cache hydration, unchanged refreshes, and append work. Override `QUOTABAR_TOKEN_ACCOUNTING_REPEATS` to change the pair count. All pairs run even after a failed assertion, and any failed pair makes the command fail.

The production compact-cache check is separate: `QUOTABAR_PRODUCTION_ACCOUNTING_BENCH=1 swift test -c release --disable-swift-testing --filter ProductionTokenAccountingEfficiencyTests`. It covers Codex and OpenCode's router share, verifies twenty unchanged refreshes read zero ledger bytes, and checks append totals and byte counts. These benchmarks use XCTest; the regular full suite still runs both testing libraries. These synthetic workloads do not read or upload local usage history and do not establish an app-wide instantaneous CPU ceiling.

For supported GPT-5.4, GPT-5.5, and GPT-5.6 models, requests above 272k input tokens use OpenAI's long-context rates for the whole request. Daybreak Blue usage is priced as GPT-5.6 Sol, matching OpenAI's published alias and Daybreak pricing. Cached input uses the published cache-read discount when the pricing source provides one; otherwise it is estimated at the full input rate. Fast/priority estimates use each model's published Codex multiplier (for example, GPT-5.5 uses 2.5×); model names ending in `-fast` are normalized to their unscaled base rate before that multiplier is applied once.

## Troubleshooting

- **FCC-routed spend is missing** — the registered Codex home may have no native session JSONL because
  the request ran through FCC. Only newly fingerprinted FCC proxy rows can be assigned to a card;
  historical account-unidentified rows are intentionally not guessed.

- **"Not logged in"** — finish **Sign in to Codex…** in the browser; QuotaBar reloads the account registry when the official login completes. For a home authenticated outside QuotaBar, use **Use Existing Codex Home…**.
- **API-key-only setups** can't read subscription usage — sign in with your ChatGPT account instead.
- **Spend tiles show "No data"** — QuotaBar found no Codex session logs in the last 30 days. If your Codex home lives somewhere custom, set `CODEX_HOME` so both the Codex CLI and QuotaBar look in the same place.

## Under the hood

In addition to the official Codex usage request, the spend scan reads FCC's local ledger read-only and
metadata-only. It filters `provider_id = openai`, `source = fcc_proxy`, and the exact fingerprint
derived from the card's account id; prompts, responses, keys, and historical un-attributed rows are
never read or assigned.

`GET https://chatgpt.com/backend-api/wham/usage` with the Codex OAuth token; refresh via `auth.openai.com`. A 401/403 triggers one token refresh and retry. Session and Weekly are classified by each usage window's duration rather than by its primary/secondary slot. This matters when Codex temporarily removes one limit and moves the remaining weekly window into the primary slot. Payloads without a recognized duration retain the primary-as-Session and secondary-as-Weekly compatibility fallback; response headers fill percentages missing from the corresponding window.

Spark and Spark Weekly come from the same response's `additional_rate_limits` array — model-specific limits that reuse the duration-based Session/Weekly classification. QuotaBar surfaces the entry whose name identifies GPT-5.3-Codex-Spark as those two meters; accounts without the limit simply omit the entry, so the rows read "No data". Other model limits in that array aren't shown.

QuotaBar preserves Codex's reported `used_percent` verbatim. If the API reports 1% used for an untouched window, the app shows 99% left; if it reports 0%, the app shows 100% left. Codex rows use the normal reset label rather than inferring a special "Not started" state. Burn-rate pacing still waits until enough of the window has elapsed to make a useful projection.

The "Rate Limit Resets" row shows the on-demand reset-credit count, e.g. `2 available`, with a colored dot for the soonest credit's expiry — blue beyond a week, yellow within a week, red within 48 hours. QuotaBar also makes a best-effort `GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits` call — the dedicated endpoint that lists each credit's expiry — and surfaces those in a popover when you hover the value: a timeline of each reset, soonest-first — a numbered color dot, the exact expiry time (`Jul 12 at 5:30 PM`), and the countdown to it (`12d 18h`) on the trailing edge. When no credits are available it reads `0 available` and the popover shows `You have no rate limit resets`. If the dedicated call fails, the row falls back to the count embedded in the usage body (`rate_limit_reset_credits.available_count`); since that body carries no per-credit expiries, the popover states the count (`N available`) and notes that expiry times are unavailable rather than implying there are none.

### Using a reset from the popover

You can also spend a reset credit right from that popover — the same claim the Codex CLI's "Usage limit resets" picker performs. Hover a credit in the timeline and a **Use** button appears; clicking it expands that credit into an inline confirmation ("Immediately reset your usage limits. This can't be undone.") with **Reset** / **Cancel**. Confirming claims that exact credit and immediately resets your 5-hour and weekly windows; the app then refreshes Codex so the meters and the remaining count reflect it before the success line ("Reset claimed. Enjoy!") appears.

Safeguards, because a claim is irreversible:

- Claiming is always a deliberate two-click flow behind the hover popover — nothing is ever claimed automatically.
- Each claim targets one explicit credit (re-matched against a fresh credit list at claim time) and carries an idempotency key, so a retry after a network error can never spend a second credit.
- If the credit was meanwhile used elsewhere (CLI or web) the popover says it's no longer available and refreshes; if your usage doesn't need a reset, Codex refuses without spending the credit and the popover says so. After a claim resets usage, the remaining Use buttons disable ("nothing to reset") until the popover is reopened.
