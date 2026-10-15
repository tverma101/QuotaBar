# Freebuff

QuotaBar reads Freebuff's existing CLI login and shows current session quotas, Freebucks, and reset times.
It does not start a Freebuff session. The provider is enabled when QuotaBar finds usable Freebuff
credentials or a configured local source needs repair; its default card is enabled, always visible,
unpinned, and alphabetically ordered.

## Credentials

QuotaBar reads the CLI's `default` profile from `credentials.json`. The default path is
`~/.config/manicode/credentials.json`; `FREEBUFF_CONFIG_DIR` can select another absolute config
directory. The Freebuff CLI may keep an older token in that file or store it in macOS Keychain under
service `freebuff-cli`, with the credentials file path as the Keychain account. A readable file or
Keychain token takes precedence; when a Keychain pointer cannot be resolved, QuotaBar uses
`CODEBUFF_API_KEY` as the CLI does. Without an environment key, an interaction-required Keychain item
still shows the permission message and can be retried with Refresh Now.

If `FREEBUFF_CONFIG_DIR` is set to a relative path, the provider stays visible and refresh shows a
configuration error so you can correct the path.

QuotaBar reads Keychain without prompting during scheduled refreshes. If macOS requires permission, use
Refresh Now and allow access. Credentials are sent only to Freebuff's session-usage endpoint.

## Metrics

The card maps free-tier daily, weekly, and monthly session windows; subscriber daily, five-day, and
monthly usage; the subscriber's optional free premium-session pool and separate plan premium-session
cap; limited-access session pools; and the daily Freebucks pool and current Freebucks balance. Freebucks
are credits, not dollars. The Monthly Spend row appears only if Freebuff includes its actual USD spend
fields in the response; QuotaBar does not estimate or convert Freebucks into dollars. Some Freebuff
deployments omit the legacy monthly USD fields, so that row can be absent.

QuotaBar sends a read-only `GET /api/v1/freebuff/session` request. A `404` is treated as a normal
no-active-session response; other HTTP and decoding failures remain visible on the provider card.
Transport failures are shown as a retryable network error. Cancelled refreshes remain cancellations and
are not presented as connection failures.

## Source references

- [Freebuff session API client](https://github.com/CodebuffAI/freebuff/blob/main/cli/src/utils/freebuff-session-api.ts)
- [Freebuff session and usage types](https://github.com/CodebuffAI/freebuff/blob/main/common/src/types/freebuff-session.ts)
- [Freebuff authentication](https://github.com/CodebuffAI/freebuff/blob/main/cli/src/utils/auth.ts)
- [Freebuff Keychain token store](https://github.com/CodebuffAI/freebuff/blob/main/cli/src/utils/auth-token-store.ts)
- [Freebuff config directory](https://github.com/CodebuffAI/freebuff/blob/main/cli/src/utils/config-dir.ts)
