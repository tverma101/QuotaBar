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

## What the toggle shares

When extra analytics are on, the app also sends, for each provider refreshed that day, at most one
provider-refresh event:

- **Provider refreshes** — per provider, how many refreshes succeeded or failed that day, the **kinds**
  of errors that happened (for example "not logged in", "network", or an HTTP status group), and how
  many manual refreshes you triggered.

Turning the toggle off stops these extra events. Daily activity continues, as long as
a token is configured at all.

## What is never shared

- No account details, names, emails, or credentials.
- No actual usage **values** (no spend amounts, token counts, or limits).
- No error **messages** or file paths — only coarse error categories as counts.
- No crash reports — exception autocapture stays off because its `$exception` payloads can embed
  local file paths, which must never leave this Mac, even when a token is configured.

## Account names on screen

Account-scoped provider cards (“Claude — Acme Corp”) render their account suffix **blurred by default** — in the dashboard, history, the Total Spend legend, share cards, and popover menus — so a glimpse at your screen does not leak which accounts you use. Tap a blurred suffix to reveal it; tap again to hide it. **Blur Account Names** in Settings → Privacy turns the behavior off. The reveal state is never persisted; only the setting survives a restart. This is a screen concern, not a data-flow one: nothing about the blur changes what leaves this Mac.

## Credentials stored on this Mac

QuotaBar primarily reads credentials that provider tools already keep on your Mac. User-supplied API
keys are written atomically to an app-owned config file restricted to your macOS account (owner read and
write only). When a provider refresh rotates a Keychain credential, QuotaBar uses Security.framework
to add or update the matching item in the current default file-based keychain. Credential writes forbid
authentication UI; if macOS requires interaction for a write, QuotaBar returns a typed access error
instead of opening a prompt during token persistence. Cursor token rotation sends its SQLite update on
the child process's standard input; credential values are not passed as subprocess arguments.

## Google services

Google's Antigravity and Gemini terms do not allow third-party apps to use their Google sign-in,
internal quota endpoints, or browser sessions. Public QuotaBar builds — on macOS and Windows — follow
that: they never read Antigravity's or Gemini's Keychain login, never refresh Google tokens, never probe
Antigravity's local language server, never read Google browser cookies, and never contact Google's
Antigravity or Gemini services. Antigravity usage comes only from the conversation history it already
stores on your computer, and that history never leaves it. On Windows the plugin host refuses these
operations itself, so a plugin cannot reach them by mistake.

Only a private build that its owner compiles with `QUOTABAR_GOOGLE_PRIVATE_ACCESS=1` reads Antigravity's
login for live limits. In those builds the short-lived refreshed-token cache is tied to the current
Keychain login using a one-way fingerprint; the refresh credential itself is not copied. The cache is
never used after logout, an account change, or while Keychain access is unavailable.

Claude Desktop access is strictly read-only. QuotaBar may ask macOS for permission to use the
`Claude Safe Storage` Keychain item so it can decrypt Desktop's current access token. It never uses
Desktop's rotating refresh token and never modifies Desktop's config, cookies, or Keychain data.

Scheduled and background credential reads forbid Keychain UI. An explicit Refresh may show one read
dialog across the enabled provider cards; cancelling it suppresses duplicate reads during that action,
and a later explicit Refresh is the retry. Keychain writes always forbid authentication UI.

Opening **Customize** runs local-only setup checks for supported providers so matching rows can be marked
**Setup found**. These checks reuse each provider's local credential sources; they make no
network requests, show no Keychain prompts, and their results remain in memory for the current app
session. Discovery does not enable a provider or send setup results anywhere. A match indicates that a
local setup source was found, not that a later provider refresh is guaranteed to succeed.

## Other network requests

Besides provider API calls, QuotaBar fetches public [model price lists](pricing.md) about once an hour from `openrouter.ai`, `raw.githubusercontent.com`, `models.dev`, and the OpenUsage pricing supplement at `robinebers.github.io`. An unknown model can bring forward an OpenRouter catalogue refresh, with retry limits. These downloads carry no model names, usage, log, or account information and run regardless of the analytics toggle. The pricing request does not include an OpenRouter API key. QuotaBar computes spend tiles from local CLI logs on your Mac and keeps the raw logs on the device.

To avoid re-reading unchanged Claude, Codex, and pi logs after every relaunch, QuotaBar keeps their
parsed usage events in `~/Library/Application Support/QuotaBar/log-scan-cache/`. These records contain
the usage metadata needed for local totals, including any per-event cost already recorded by a provider,
but not raw JSONL lines or conversation text. They are private to your macOS account and are never sent
to PostHog, a provider, or iCloud. Old source-file records are dropped as the scan window advances, and
identity caches that have not been used for 35 days are removed. QuotaBar's pricing engine runs after
the cache is read, so its computed aggregates and totals are not persisted in this cache. Separately,
finished per-day usage totals (tokens, costs, and per-model sums — no event rows) are kept in
`~/Library/Application Support/QuotaBar/log-usage-aggregates/` so a refresh over unchanged sources can
skip re-folding entirely; the same account privacy applies.

If you explicitly turn on [iCloud Sync](icloud-sync.md), QuotaBar writes normalized daily tokens,
spend, and model totals to its private iCloud container so your own Macs can show one combined summary.
Credentials, account limits, provider responses, and raw logs are never written there. This is separate
from anonymous usage analytics: iCloud Sync defaults off and uses your iCloud account, while the
analytics toggle controls extra PostHog events, not daily activity.

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
- Daily activity is always enabled once a token exists, regardless of the
  extra-analytics switch.
- Counts are rolled up locally and sent as daily summaries, so the app's normal 5-minute refresh never
  turns into a flood of network calls.
- Your analytics choice and the anonymous ID are stored separately from the rest of the app's settings,
  so settings migrations and updates do not re-enable extra analytics or change your ID.

## Turning extra analytics off

Open **Settings → Privacy** and switch **Help make QuotaBar better by sharing anonymous usage analytics**
off. Extra usage analytics stop. Daily activity continues, if a token is configured
at all. To send nothing whatsoever, build without a token — which is the default.
