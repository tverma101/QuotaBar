# Antigravity CLI

> **Public builds follow Google's terms.** Google's [Antigravity terms](https://antigravity.google/terms/)
> (section 6) and [FAQ](https://antigravity.google/docs/faq/) do not allow third-party apps to use
> Antigravity's Google sign-in, call its internal quota service, or wrap `agy`. Public QuotaBar
> builds therefore show only **Today, Yesterday, Last 30 Days, and Usage Trend** from local
> Antigravity conversation databases (including T3 Code's private profiles and
> `~/.config/antigravity/conversations`). They never read the `agy` login, contact Google, or probe the
> local language server; the plugin host blocks those calls too
> (`crates/quotabar-core/src/google_terms.rs`). Everything below describes private builds compiled with `QUOTABAR_GOOGLE_PRIVATE_ACCESS=1`.

Tracks Google Antigravity CLI (`agy`) Cloud Code quota.

## Setup

Sign in with the CLI first:

```bash
agy
```

OpenUsage uses the CLI keychain login. It does not start a browser OAuth flow.

Access tokens expire (~1 hour). QuotaBar refreshes them with the stored `refresh_token` (same Google OAuth client as Antigravity IDE) and writes the updated JSON back to the credential store. If refresh fails, run `agy` again — you should not need to sign in every day when refresh tokens remain valid.

## Data Sources

- Non-secret CLI context: `~/.gemini/antigravity-cli/`
- Auth: OS credential store — service `gemini`, username/account `antigravity` (macOS Keychain, Linux Secret Service via GNOME Keyring/KWallet, Windows Credential Manager target `gemini:antigravity` per go-keyring). JSON shape from `agy` includes `token.access_token`, `token.refresh_token`, and `token.expiry`.
- Quota APIs (tries `daily-cloudcode-pa` then `cloudcode-pa`):
  - `POST …/v1internal:retrieveUserQuotaSummary` — body `{}`; authoritative quota source for `agy`; headers include `Authorization: Bearer <accessToken>`, a versioned `User-Agent: antigravity/cli/1.5.0`, and JSON content headers. An unversioned identity can return only Claude/GPT buckets even when the account has Gemini quota.
  - `POST …/v1internal:loadCodeAssist` — legacy fallback; body includes `metadata` (IDE/client context)
  - `POST …/v1internal:fetchAvailableModels` — legacy fallback; body `{}` only (`metadata` causes HTTP 400)
  - `POST …/v1internal:retrieveUserQuota` — legacy fallback; body `{}`

The provider does not read legacy Gemini OAuth files such as `~/.gemini/oauth_creds.json`.

## Quota Lines

- `gemini-5h` -> `Session`
- `gemini-weekly` -> `Weekly`
- `3p-5h` -> `Session — Claude and GPT Models`
- `3p-weekly` -> `Weekly — Claude and GPT Models`

The plugin converts `remainingFraction` to percentage used and preserves `resetTime`.
Legacy fallback still maps model IDs/labels to `Gemini Pro`, `Gemini Flash`, and `Claude` only when no usable summary response is available.

## Notes

The CLI and IDE appear to share Google platform/model quota. OpenUsage tracks Antigravity CLI separately because the CLI uses different state and auth paths.
