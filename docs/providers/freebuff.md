# Freebuff

QuotaBar reads Freebuff's existing CLI login and shows current hours balances and reset times.
It does not start a Freebuff session. Freebuff is enabled by default even when you have not logged in;
turn it off in Customize if you do not want its card. Its metrics are always-visible by default, it is
unpinned, and it appears in the alphabetical provider order.

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
They are enabled, Always Visible, and unpinned by default. QuotaBar reads only the measured usage
column in `~/.config/freebuff-desktop/projects/*/desktop-v2.db`, not conversation text. Unchanged
database and WAL files reuse the previous read, and the measured numbers are kept rather than the raw
receipt JSON, so an unchanged history is not decoded again on every refresh; changed turns replace
their latest measurement. A row that carries no identifier or timestamp is skipped — and logged —
instead of making the whole history unreadable. Cached input tokens are already in input, and
reasoning tokens are already in output, so neither is added again. Incomplete receipts keep their
coverage flags in details. Missing history stays No Data. The remembered history is capped: the
oldest project is read again when the cap is reached, so long-lived installs stay bounded.

Dollar values are **OpenRouter API price estimates**, not Freebuff's recorded charges. Models
recorded on receipts take priority. For older receipts, estimates use each thread's saved model
selection, resolved through Freebuff's model catalogue and an exact OpenRouter route. That selection
can differ from past serving models or subagents; the model detail explains this limitation. Opaque
or ambiguous identities remain Unattributed or unpriced, and all measured tokens still count.
Cached input is priced separately from uncached input; reasoning stays inside output. Since a turn
aggregates multiple requests, single-request long-context tiers are not applied. The local rows cover
Desktop only, not CLI or web traffic. Model identities are cached locally without handles or tokens;
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
