# Freebuff

QuotaBar reads Freebuff's existing CLI login and shows current hours balances and reset times.
It does not start a Freebuff session. Freebuff is enabled by default even when you have not logged in;
turn it off in Customize if you do not want its card. Its metrics are always-visible by default, and
the Daily Hours pin shows **active session timers** in the menu bar, refreshed each minute. These use
actual session expiry times, including occupied Desktop hours, rather than the daily allowance reset.
With several active sessions, every timer stays under the one Freebuff mark, in the same two-line height as the other providers. Idle, expired, and unoccupied purchased hours disappear.
For Freebuff Desktop sessions on this Mac, each session is linked to its local chat title and project.
A renamed chat shows its current title on the next refresh. Hovering the session count lists those titles.
Raw model routes are left off that list.
Other Freebuff allowance and balance pins do not add values beside the session timers. It appears in
the alphabetical provider order.

## Credentials

QuotaBar reads the CLI's `default` profile from `credentials.json`. The default path is
`~/.config/manicode/credentials.json`; `FREEBUFF_CONFIG_DIR` can select another absolute config
directory. The Freebuff CLI may keep an older token in that file or store it in macOS Keychain under
service `freebuff-cli`, with the credentials file path as the Keychain account. A readable file or
Keychain token takes precedence; when a Keychain pointer cannot be resolved, QuotaBar uses
`CODEBUFF_API_KEY` as the CLI does. When that environment fallback exists, Keychain reads stay silent;
each manual refresh rechecks silently so newly granted access can replace a stale environment token.
Without an environment key, an interaction-required Keychain item can show the permission message and
be retried with Refresh Now.

If `FREEBUFF_CONFIG_DIR` is set to a relative path, the provider stays visible and refresh shows a
configuration error so you can correct the path.

If the card says no login was found, sign in once with the Freebuff CLI, then choose **Refresh** on
the card. The default local binary command is `~/.config/manicode/freebuff login`; use `freebuff login`
if the CLI wrapper is on your `PATH`. Enabling the card only makes it visible; it does not sign in or
create credentials.

If the card says QuotaBar found Freebuff credentials but they have no `default` profile, the CLI
wrote its login under a different profile name. QuotaBar logs this; sign in again with the Freebuff
CLI, or point `FREEBUFF_CONFIG_DIR` at the config directory that holds the `default` profile.

On a fresh Mac, install the [official Freebuff CLI](https://freebuff.com/cli), then run
`freebuff login` and finish **Connect** in your browser. QuotaBar needs this one-time login even
though the card is enabled by default. When its Keychain item is first read, use **Refresh** and
choose **Always Allow** if macOS asks. Reinstalling or rebuilding QuotaBar with the same stable
signing identity keeps the CLI login and its existing Keychain grant. Background refreshes stay silent.

QuotaBar reads Keychain without prompting during scheduled refreshes. A manual refresh can prompt for
an interaction-required item when no environment fallback is available. Credentials are sent only to
Freebuff's canonical API host for its session, model catalogue, and read-only hosted history.

## Metrics

Current accounts show **Daily Hours** and **Hours Balance**, matching Freebuff's conversion of five
Freebucks per hour. Daily Hours is today's replenishing allowance. Hours Balance is the separate
wallet, including any remaining monthly bonus and earned or purchased funds. It excludes the daily
pool. Freebuff's top-level API balance combines both, so it must not be used for this wallet row.
Older responses without a wallet field use the combined balance minus the daily remainder. Whole
wallet hours round down like Freebuff. An unavailable meter clears old values and shows a warning;
a missing wallet never silently becomes zero. Legacy daily/weekly/monthly
session caps are hidden when the current hours meter is present. Older servers without that meter
keep their session windows. Monthly Spend appears only when the server supplies actual USD values.
Hours and tokens are separate measurements; neither is converted into the other.

**Usage Trend** shows a daily sparkline of measured token volume across the last 30 days. It is enabled, Always Visible, and unpinned by default.

**Today**, **Yesterday**, and **Last 30 Days** combine measured hosted-run tokens with older Freebuff
Desktop history on this Mac. Current **On This Device** sessions also keep their receipts in hosted
history; the tools run on your Mac, but the older SQLite history no longer receives their tokens.
These tiles are enabled, Always Visible, and unpinned by default. QuotaBar reads `metrics` usage
events from Freebuff's existing read-only chat/run history API, with the current client's
`x-freebuff-device-chats: 1` compatibility header so On This Device chats are included. Each run's
newest measured receipt replaces its earlier cumulative values. Later context-only or
interruption updates preserve the last measured counts and coverage flag. A local copy with the same
`cloud:<run>` identifier counts once, with a measured hosted receipt taking precedence. When hosted
usage is missing, a measured older Desktop copy remains included and its coverage stays incomplete. Native Claude/Codex and BYOK runs are excluded.

Hosted receipts cover the last 30 days, with one extra boundary day for local calendar periods.
Completed runs are included by finish time, so a long run that started before the window still
counts when it finishes inside it. Active runs remain eligible. Model corrections update cached
receipts even when no new metrics event arrives. A
bounded, login-scoped cache keeps only run identifiers, models, timestamps, cursors, and measured
usage. Conversation payloads are not decoded or saved. Completed unchanged runs reuse their cached
receipt across restarts; active runs resume after the last event cursor. Memory-pressure cleanup
unloads the in-memory mirror; local accounting restores the saved receipts before publishing totals.
History requests happen in the accounting pass, never on menu-bar timer refreshes. Failed pages keep the previous receipts and
show a warning that totals may be incomplete, which stays visible across successful session polls.
Runs with missing or incomplete token receipts also keep their day marked incomplete and show a
history warning. Their missing tokens are unknown, never counted as zero or estimated from hours.
Older receipt caches are replayed once to recover counts that a later sparse update could have hidden.
Incomplete runs are checked again at most once every five minutes even when their completed status
and chat timestamp have not changed, so a late receipt can repair the subtotal. Removing a chat or
run from the history list does not erase its already measured consumption inside the saved window.
This mixed history is marked account-wide so another
Mac cannot blindly add the hosted portion again.

For older Desktop sessions, QuotaBar reads usage from assistant-message
metrics and the separate `auto_run_decision_receipts.manager_json.usage` records in
`~/.config/freebuff-desktop/projects/*/desktop-v2.db`, never conversation text. The mission manager's
recorded model and start time are used for its estimate. `outcome_json.usage` is excluded because it
repeats the completed assistant response; older databases without the manager-receipt table still
provide assistant-message history. Unchanged database and WAL files reuse the previous read and
complete daily fold, so an unchanged history is not decoded or re-aggregated on every refresh. If
pricing changes, cached measured rows are repriced without another SQLite read while their per-turn
entries remain cached. Changed turns replace their latest measurement. A row that carries no
identifier or timestamp is skipped — and logged — instead of making the whole history unreadable. The
per-turn cache is capped; an evicted project is read again only when a source or pricing change
requires a new fold. Cached input tokens are already in input, and reasoning tokens are already in
output, so neither is added again. Incomplete receipts and rows without usage keep their coverage
flags in details and mark the measured subtotal as a lower bound. Empty or absent assistant metrics
are included in this coverage check, rather than being filtered out of the database query. Missing
history stays No Data. Both the per-turn cache and completed aggregate stay bounded so long-lived
installs do not keep every raw receipt in memory.

Dollar values are **public API price estimates**, not Freebuff's recorded charges. QuotaBar uses
OpenRouter for exact routes. Model rows carry the
catalogue's display name whenever one is known. Legacy model IDs use the catalogue's published
identity digests, so receipts recorded with an old route and a current catalogue key share one row.
Freebuff removed its Flash Fast serving mode; a catalogue name that still claims it presents and
prices as the base Flash model (hosted receipts only ever carry the plain slug), so no row or
variant is labelled Fast. The breakdown groups Slow modes, build-date labels, and context
annotations under the model's
name. Their measured tokens and separate rate estimates remain in the accounting variants; different
model versions and families stay separate. Grouping does not change token totals or reprice a mode
at another mode's rate. Unknown or conflicting identities are never guessed. Models
recorded on receipts take priority. For older receipts, estimates use each thread's saved model
selection, resolved through Freebuff's model catalogue and an exact OpenRouter route. When Desktop
has cleared the thread's model column, QuotaBar projects only the model field from its saved thread
snapshot. Receipt models still take priority. Older local records whose labels are missing or retired
remain token-only **Older Freebuff Usage**; their price is incomplete, shown by the lower-bound dollar
marker, without an actionable unknown-pricing warning. Unknown models actually named on receipts
still raise that warning. No measured tokens are dropped. A
`100k context` label resolves to the same Claude Haiku 5.5 route; receipts aggregate multiple
requests, so QuotaBar uses the route's standard rates instead of guessing whether an individual
request crossed a long-context price tier. That selection can differ from past serving models or
subagents. A model the catalogue names but no public route prices keeps its tokens and shows a
dashed cost without raising the unknown-model warning — the
model is known, only its price is missing. Opaque or ambiguous identities remain Unattributed or
unpriced and do raise the warning; all measured tokens still count either way.
Cached input is priced separately from uncached input; reasoning stays inside output. DeepSeek V4.1
Flash's dated OpenRouter route publishes UTC weekday/time price windows, which QuotaBar applies at
each stored assistant-message or mission-manager timestamp. A turn can aggregate calls across a
window boundary, so that estimate is approximate for those turns. The route metadata does not include
DeepSeek's Chinese-public-holiday exception. Freebuff removed its Fast serving mode, so usage
recorded under the old Fast catalogue key is presented and priced as the base Flash model; receipts
recorded with a raw Fast route slug from before the removal still price at the public DeepSeek V4.1
Flash Fast route listed by Vercel AI Gateway: $0.60 input, $2.40 output, and $0.01 cached input per
million tokens. This is a public API comparison,
not an estimate of Pareto's internal cost or Freebuff's Freebucks charge. Freebuff's actual
allowance and charges are server-side Freebucks, not token-priced dollars.
Since a turn aggregates multiple requests,
single-request long-context tiers are not applied. The older local rows cover Desktop only; hosted
runs cover the signed-in account's shared history. Standalone CLI traffic without hosted run receipts
is not included. Model identities are cached locally without handles or tokens;
unchanged catalogues refresh at most hourly, and a catalogue endpoint that keeps failing is retried
at most hourly as well. Public OpenRouter rates use the app's existing pricing cache. A fresh
installation needs measured Desktop or hosted usage before token history can appear.

QuotaBar sends a read-only `GET https://www.codebuff.com/api/v1/freebuff/session` request directly to
the canonical API host, so a redirect cannot strip the login header and make a new login look expired.
A `404` is treated as a normal
no-active-session response; other HTTP and decoding failures remain visible on the provider card.
Transport failures are shown as a retryable network error. A quota or credential error remains
visible even when local token history succeeds; the successful history can still be saved without
making old balances look freshly checked. Cancelled refreshes remain cancellations and
are not presented as connection failures.

## Headless Checks

Run `quotabar freebuff --diagnose --force` to refresh and print a backend JSON report. It includes
the normalized receipt totals, resolved widget values, session clocks, freshness, and coverage
warnings without opening the panel. A cached read can omit `--force`.

For the same Keychain access identity as the installed app, use
`/Applications/QuotaBar.app/Contents/MacOS/QuotaBar --diagnose freebuff --force`. This mode branches
before SwiftUI or the app delegate starts and exits after printing the report. The running menu-bar
app can remain open. It starts no session, heartbeat, window, local server, or refresh timer.
Fresh Freebuff checks also include an allowlisted numeric source projection, so daily, wallet,
and combined balances can be compared. Login tokens, purchase holder IDs, and conversations are
excluded. Exit status 4 means the JSON contains warnings or errors; missing receipts remain a
coverage warning after a successful balance check.

## Source references

- [Freebuff session API client](https://github.com/CodebuffAI/freebuff/blob/main/cli/src/utils/freebuff-session-api.ts)
- [Freebuff session and usage types](https://github.com/CodebuffAI/freebuff/blob/main/common/src/types/freebuff-session.ts)
- [Freebuff hosted history API](https://github.com/CodebuffAI/freebuff/blob/main/common/src/desktop-cloud/history.ts)
- [Cumulative hosted token receipts](https://github.com/CodebuffAI/freebuff/blob/main/common/src/desktop-cloud/turn-metrics.ts)
- [Freebuff authentication](https://github.com/CodebuffAI/freebuff/blob/main/cli/src/utils/auth.ts)
- [Freebuff Keychain token store](https://github.com/CodebuffAI/freebuff/blob/main/cli/src/utils/auth-token-store.ts)
- [Freebuff config directory](https://github.com/CodebuffAI/freebuff/blob/main/cli/src/utils/config-dir.ts)
- [Freebuff hours conversion](https://github.com/CodebuffAI/freebuff/blob/main/common/src/util/freebuff-hours.ts)
- [Freebuff model catalog and Fast-mode pricing notes](https://github.com/CodebuffAI/freebuff/blob/main/common/src/constants/freebuff-models.ts)
- [Freebuff legacy model identity contract](https://github.com/CodebuffAI/freebuff/blob/main/common/src/types/freebuff-model-catalog.ts)
- [DeepSeek model prices and peak-hour schedule](https://api-docs.deepseek.com/quick_start/pricing/)
