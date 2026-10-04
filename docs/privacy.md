# Privacy & Usage Data

**A stock QuotaBar build sends no analytics at all.** The app inherits upstream's PostHog telemetry
mechanism, but no project token is committed, so the analytics sink stays inert: no SDK setup, no
network requests, no anonymous ID, no crash reports. Nothing on this page describes what a default
install transmits, because the answer is nothing.

The rest of this document describes the mechanism that *would* run if a maintainer supplies their own
PostHog project token, so the behaviour is documented rather than hidden. To enable it, set your own
US-region `phc_…` token via `QUOTABAR_POSTHOG_TOKEN`; see [How it works](#how-it-works) below. Nothing
is sent until you do.

## What would always be shared

Once per local day, the app sends an anonymous **app use** ping: that the app was active today, the
app and macOS version, which providers and metrics you have enabled, and which metrics you've pinned
to the menu bar or tucked behind the "show more" caret. A random ID (not tied to you or any account)
lets the project owner count daily active users without identifying anyone.

- **Crash reports** — if the app crashes, it saves a report and sends it the next time you open the
  app: the technical stack trace (which parts of *QuotaBar's own code* were running when it crashed)
  plus the app and macOS version. This contains no account details, credentials, or usage values —
  just where in the app the crash happened.

## What the toggle shares

When extra analytics are on, the app also sends, for each provider refreshed that day, at most one
provider-refresh event:

- **Provider refreshes** — per provider, how many refreshes succeeded or failed that day, the **kinds**
  of errors that happened (for example "not logged in", "network", or an HTTP status group), and how
  many manual refreshes you triggered.

Turning the toggle off stops these extra events. Daily activity and crash reports continue, as long as
a token is configured at all.

## What is never shared

- No account details, names, emails, or credentials.
- No actual usage **values** (no spend amounts, token counts, or limits).
- No error **messages** or file paths — only coarse error categories as counts.

## Credentials stored on this Mac

QuotaBar primarily reads credentials that provider tools already keep on your Mac. When it writes a
user-supplied API key or saves a refreshed credential, the file is replaced atomically and restricted to
your macOS account (owner read and write only). Antigravity's short-lived refreshed-token cache is tied
to the current Keychain login using a one-way fingerprint; the refresh credential itself is not copied.
The cache is never used after logout, an account change, or while Keychain access is unavailable.

Claude Desktop access is strictly read-only. QuotaBar may ask macOS for permission to use the
`Claude Safe Storage` Keychain item so it can decrypt Desktop's current access token. It never uses
Desktop's rotating refresh token and never modifies Desktop's config, cookies, or Keychain data.

## Other network requests

Besides the provider API calls the vendor's own tools would make, QuotaBar fetches public [model price lists](pricing.md) about once an hour (from `openrouter.ai`, `raw.githubusercontent.com`, `models.dev`, and this project's GitHub Pages). An unknown model can bring forward an OpenRouter catalogue refresh, with retry limits. These are plain downloads of public data — they carry no model names, usage, log, or account information, and they run regardless of the analytics toggle. The pricing request does not include an OpenRouter API key. The spend tiles are computed from local CLI logs entirely on your Mac; no log data ever leaves it.

To avoid re-reading unchanged Claude, Codex, and pi logs after every relaunch, QuotaBar keeps their
parsed usage events in `~/Library/Application Support/QuotaBar/log-scan-cache/`. These records contain
the usage metadata needed for local totals, including any per-event cost already recorded by a provider,
but not raw JSONL lines or conversation text. They are private to your macOS account and are never sent
to PostHog, a provider, or iCloud. Old source-file records are dropped as the scan window advances, and
identity caches that have not been used for 35 days are removed. QuotaBar's pricing engine runs after
the cache is read, so its computed aggregates and totals are not persisted in this cache.

If you explicitly turn on [iCloud Sync](icloud-sync.md), QuotaBar writes normalized daily tokens,
spend, and model totals to its private iCloud container so your own Macs can show one combined summary.
Credentials, account limits, provider responses, and raw logs are never written there. This is separate
from anonymous usage analytics: iCloud Sync defaults off and uses your iCloud account, while the
analytics toggle controls extra PostHog events, not daily activity or crash reports.

## How it works

- The sink is inert unless a real `phc_…` project token resolves. `TelemetryConfig.bakedToken` is the
  placeholder `phc_REPLACE_ME`, and `PostHogTelemetrySink` returns without calling
  `PostHogSDK.shared.setup` when it does, so there is no transport to opt out of.
- A maintainer enables analytics by supplying their own token, either as the `bakedToken` value in
  `Sources/QuotaBar/Services/Telemetry.swift` or at runtime via the `QUOTABAR_POSTHOG_TOKEN`
  environment variable. `Tests/QuotaBarTests/TelemetryConfigTests.swift` fails if a real token is
  committed by accident, which is what keeps the default inert over time.
- The token must be US-region for the default host. A project token is a write-only client key scoped
  to one project; anyone reading it can only write events into that project, which is why it is safe to
  commit but must never belong to a project owner who has not agreed to receive the data.
- When enabled, data is fully anonymous: the app never identifies you to the analytics service and
  creates no user profile.
- Daily activity and crash reports are always enabled once a token exists, regardless of the
  extra-analytics switch.
- Counts are rolled up locally and sent as daily summaries, so the app's normal 5-minute refresh never
  turns into a flood of network calls.
- Your analytics choice and the anonymous ID are stored separately from the rest of the app's settings,
  so settings migrations and updates do not re-enable extra analytics or change your ID.

## Turning extra analytics off

Open **Settings → Privacy** and switch **Help make QuotaBar better by sharing anonymous usage analytics**
off. Extra usage analytics stop. Daily activity and crash reports continue, if a token is configured
at all. To send nothing whatsoever, build without a token — which is the default.
