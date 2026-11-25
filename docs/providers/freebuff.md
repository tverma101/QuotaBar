# Freebuff

QuotaBar shows saved Freebuff measurements from this Mac. It does not contact Freebuff, so live
quotas, session timers, and hosted history refreshes are unavailable. Current hours balances and
active sessions are on the
[Freebuff dashboard](https://codebuff.com/account). Freebuff is enabled by default even when you
have not logged in; turn it off in Customize if you do not want its card. Its metrics are
always-visible by default. It appears in the alphabetical provider order.

## Saved History

Desktop history does not require signing in to QuotaBar. Receipts saved by an older version are
included only when they match the existing local Freebuff login. Account matching happens on this
Mac; QuotaBar sends no credentials or receipts. Unmatched receipts are left out, not counted as zero.

## Metrics

On Windows, Active Sessions counts each occupied session once and lists its expiration in UTC.
Unused Desktop purchases are not counted as active sessions.

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

**Today**, **Yesterday**, and **Last 30 Days** combine measured Freebuff Desktop history on this Mac
with any hosted receipts a previous version already saved here. These tiles are enabled, Always
Visible, and unpinned by default. Because hosted history is not refreshed, coverage shrinks to what
is saved locally: saved receipts keep their run identifiers, models, timestamps, cursors, and
measured usage — never conversation payloads — and days the saved data does not cover stay marked
incomplete rather than counted as zero. Each run's newest measured receipt replaces its earlier
cumulative values. A local copy with the same
`cloud:<run>` identifier counts once, with a measured hosted receipt taking precedence. When hosted
usage is missing, a measured older Desktop copy remains included and its coverage stays incomplete. Native Claude/Codex and BYOK runs are excluded.

Hosted receipts cover the last 30 days, with one extra boundary day for local calendar periods.
Completed runs are included by finish time, so a long run that started before the window still
counts when it finishes inside it. A
bounded, login-scoped cache keeps only run identifiers, models, timestamps, cursors, and measured
usage. Conversation payloads are not decoded or saved. Completed unchanged runs reuse their cached
receipt across restarts. Memory-pressure cleanup
unloads the in-memory mirror; local accounting restores the saved receipts before publishing totals.
Missing or incomplete receipts keep their day marked incomplete. Failed or cancelled hosted runs
and imported hosted history stay lower bounds without an extra warning; unexplained gaps, including
incomplete local Desktop receipts, still warn. Their missing tokens are unknown, never counted as
zero or estimated from hours.
This mixed history is marked account-wide so another
Mac cannot blindly add the hosted portion again.

On Windows, app startup and manual refresh can also update hosted and older Desktop token
totals. A five-minute cooldown limits those history requests. Interval refreshes use the last
history snapshot for the same login and do not contact the hosted history endpoint. Windows
shows measured token totals; the macOS model and price breakdown described below is separate.

For older Desktop sessions, QuotaBar reads usage from assistant-message
metrics and the separate `auto_run_decision_receipts.manager_json.usage` records in
`~/.config/freebuff-desktop/projects/*/desktop-v2.db`, never conversation text. The mission manager's
start time and route recorded with the counters are used for its estimate. A model on the manager
record itself is a saved selection, not proof of the route. `outcome_json.usage` is excluded because it
repeats the completed assistant response; older databases without the manager-receipt table still
provide assistant-message history. Unchanged database and WAL files reuse the previous read and
complete daily fold, so an unchanged history is not decoded or re-aggregated on every refresh. When a
database changes, only new messages and messages whose stored sizes changed are read again, so an
active session does not force a re-read of every earlier chat. A read is one consistent database
snapshot, so a turn that finishes mid-read no longer drops that pass's history. If
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
exact OpenRouter route rates when available, without remapping them through a bundled model alias.
Curated prices are a fallback for routes the catalogue cannot price. Model rows carry the
catalogue's display name whenever one is known. Legacy model IDs use the catalogue's published
identity digests, so receipts recorded with an old route and a current catalogue key share one row.
The catalogue is the copy saved on this Mac. Builds without hosted access never request a new
copy. A model Freebuff adds later keeps its tokens but stays unpriced until the saved catalogue
includes it. A saved copy that can't be read is logged, and its models stay unpriced.
For ambiguous DeepSeek V4.1 Flash Fast selections, QuotaBar assumes standard Flash public API
rates and names the row Standard Rate Assumed. This is not evidence of the serving tier; a
receipt that records an exact route takes precedence. This does not verify which route served a
request. The breakdown groups Slow modes, build-date labels, and context
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
Cached input is priced separately from uncached input; reasoning stays inside output.
Flash estimates use DeepSeek's direct API rates for cache hits, uncached input, and output. The
estimator uses each stored turn timestamp, applying peak prices in the published UTC windows except
Chinese public holidays. Years without a verified holiday schedule use the off-peak baseline. Turns
can span rate windows, and Freebuff bills separately. A recorded route or a saved selection does not
imply Freebuff charges.
Standard Flash costs $0.15 per million uncached input tokens, $0.003 per million cached
input tokens, and $0.60 per million output tokens off-peak. Peak rates are double.
These rates do not depend on the live pricing catalogue or the Fast label.
Since a turn aggregates multiple requests,
single-request long-context tiers are not applied. The older local rows cover Desktop only; saved
hosted receipts cover the signed-in account's shared history as of their last refresh. Standalone
CLI traffic without saved run receipts is not included.
Public OpenRouter rates use the app's existing pricing cache. A fresh
installation needs measured Desktop or saved hosted usage before token history can appear.

## Headless Checks

Run `quotabar freebuff --diagnose --force` to refresh and print a backend JSON report built from
saved local data. It includes the normalized receipt totals, resolved widget values,
freshness, and coverage warnings without opening the panel. A cached read can omit `--force`.

For the same Keychain access identity as the installed app, use
`/Applications/QuotaBar.app/Contents/MacOS/QuotaBar --diagnose freebuff --force`. This mode branches
before SwiftUI or the app delegate starts and exits after printing the report. The running menu-bar
app can remain open. It starts no session, heartbeat, window, local server, refresh timer, or
Freebuff network request. Login tokens, purchase holder IDs, and conversations are
excluded. Exit status 4 means the JSON contains warnings or errors; missing receipts remain a
coverage warning.

## Source references

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
- [China State Council 2026 holiday schedule](https://www.gov.cn/zhengce/zhengceku/202511/content_7047091.htm)
- [China State Council 2027 holiday schedule](https://www.gov.cn/zhengce/content/202611/content_7085101.htm)
