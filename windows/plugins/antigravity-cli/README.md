# Antigravity CLI

> **Public builds follow Google's terms.** Google's [Antigravity terms](https://antigravity.google/terms/)
> (section 6) and [FAQ](https://antigravity.google/docs/faq/) do not allow third-party apps to use
> Antigravity's Google sign-in, call its internal quota service, or wrap `agy`. Public QuotaBar
> builds therefore show only **Today, Yesterday, Last 30 Days, and Usage Trend** from local
> Antigravity conversation databases (including T3 Code's private profiles and
> `~/.config/antigravity/conversations`). They never read the `agy` login, contact Google, or probe the
> local language server; the plugin host blocks those calls too
> (`crates/quotabar-core/src/google_terms.rs`). Everything below describes private builds compiled with `QUOTABAR_GOOGLE_PRIVATE_ACCESS=1`.

This provider reads Google Antigravity CLI (`agy`) usage from the Cloud Code quota APIs used by the CLI. It is separate from the Antigravity IDE and Gemini providers because `agy` stores state and auth differently.

Authenticate with `agy` before enabling this provider:

```sh
agy
```

QuotaBar reads non-secret context only from `~/.gemini/antigravity-cli/`. It does not read legacy Gemini OAuth files such as `~/.gemini/oauth_creds.json`.

Authentication comes from the OS credential store entry with service `gemini` and username `antigravity` (same as `agy` / zalando/go-keyring). On Linux this is the Secret Service (unlock your session keyring). The provider accepts raw tokens, JSON OAuth-style payloads (including `{"token":{"access_token":"..."}}` from `agy`), and `go-keyring-base64:` wrapped values when the store returns them.

Quota uses `POST https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary`, then `https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary`, with body `{}`, JSON headers, `Authorization: Bearer <accessToken>`, and `User-Agent: antigravity/cli/1.5.0`. The provider renders `Session`, `Weekly`, `Session — Claude and GPT Models`, and `Weekly — Claude and GPT Models`. Older Cloud Code model/quota calls remain fallback only.

The CLI and IDE appear to share Google platform/model quota, but QuotaBar tracks Antigravity CLI separately so the auth path and implementation remain clear.
