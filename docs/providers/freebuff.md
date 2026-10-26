# Freebuff

QuotaBar reads Freebuff's existing CLI login and shows current hours balances and reset times.
It does not start a Freebuff session. Freebuff is enabled by default even when you have not logged in;
turn it off in Customize if you do not want its card. Its metrics are always-visible by default, the
Daily Hours meter is pinned to the menu bar so live session usage stays visible while you are active,
and it appears in the alphabetical provider order.

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
Freebuff's session and model-catalogue endpoints.

## Metrics

Current accounts show **Daily Hours** and **Hours Balance**, matching Freebuff's conversion of five
Freebucks per hour. The balance includes the remaining daily pool and the wallet; it is not added to
the daily pool again. Whole balance hours round down like Freebuff. Legacy daily/weekly/monthly
session caps are hidden when the current hours meter is present. Older servers without that meter
keep their session windows. Monthly Spend appears only when the server supplies actual USD values.
Hours and tokens are separate measurements; neither is converted into the other.

**Today**, **Yesterday**, and **Last 30 Days** show measured tokens from Freebuff Desktop on this Mac.
They are enabled, Always Visible, and unpinned by default. QuotaBar reads usage from assistant-message
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
output, so neither is added again. Incomplete receipts keep their coverage flags in details. Missing
history stays No Data. Both the per-turn cache and completed aggregate stay bounded so long-lived
installs do not keep every raw receipt in memory.

Dollar values are **public API price estimates**, not Freebuff's recorded charges. QuotaBar uses
OpenRouter for exact routes except for Fast's curated Vercel AI Gateway route. Model rows carry the
catalogue's display name whenever one is known, so priced and unpriced turns of the same model read
as one row instead of splitting across a routing slug and a friendly name. Models
recorded on receipts take priority. For older receipts, estimates use each thread's saved model
selection, resolved through Freebuff's model catalogue and an exact OpenRouter route. A
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
DeepSeek's Chinese-public-holiday exception. Fast mode uses a separate Pareto route in Freebuff, so
its exact backend cost and Freebucks charge are not available in local receipts. QuotaBar now prices
persisted Fast-root tokens at the public DeepSeek V4.1 Flash Fast route listed by Vercel AI Gateway:
$0.60 input, $2.40 output, and $0.01 cached input per million tokens. This is a public API comparison,
not an estimate of Pareto's internal cost or Freebuff's Freebucks charge. The estimate uses the
recorded Fast model identity and tokens directly, with no added allowance for hypothetical helper
calls. Freebuff's actual allowance and charges are server-side Freebucks, not token-priced dollars.
Since a turn aggregates multiple requests,
single-request long-context tiers are not applied. The local rows cover Desktop only, not CLI or web
traffic. Model identities are cached locally without handles or tokens;
unchanged catalogues refresh at most hourly, and a catalogue endpoint that keeps failing is retried
at most hourly as well. Public OpenRouter rates use the app's existing pricing cache. A fresh
installation needs Desktop usage before local history can appear.

QuotaBar sends a read-only `GET https://www.codebuff.com/api/v1/freebuff/session` request directly to
the canonical API host, so a redirect cannot strip the login header and make a new login look expired.
A `404` is treated as a normal
no-active-session response; other HTTP and decoding failures remain visible on the provider card.
Transport failures are shown as a retryable network error. Cancelled refreshes remain cancellations and
are not presented as connection failures.

## Source references

- [Freebuff session API client](https://github.com/CodebuffAI/freebuff/blob/main/cli/src/utils/freebuff-session-api.ts)
- [Freebuff session and usage types](https://github.com/CodebuffAI/freebuff/blob/main/common/src/types/freebuff-session.ts)
- [Freebuff authentication](https://github.com/CodebuffAI/freebuff/blob/main/cli/src/utils/auth.ts)
- [Freebuff Keychain token store](https://github.com/CodebuffAI/freebuff/blob/main/cli/src/utils/auth-token-store.ts)
- [Freebuff config directory](https://github.com/CodebuffAI/freebuff/blob/main/cli/src/utils/config-dir.ts)
- [Freebuff hours conversion](https://github.com/CodebuffAI/freebuff/blob/main/common/src/util/freebuff-hours.ts)
- [Freebuff model catalog and Fast-mode pricing notes](https://github.com/CodebuffAI/freebuff/blob/main/common/src/constants/freebuff-models.ts)
- [DeepSeek model prices and peak-hour schedule](https://api-docs.deepseek.com/quick_start/pricing/)
