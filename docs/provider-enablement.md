# Which Providers Are On

How QuotaBar chooses its starting provider cards and how you turn on the rest.

## First install

A fresh install starts with Claude, Codex, Cursor, Freebuff, and any registered Codex account cards on. If the bare Claude card ID is unavailable because of saved account history, its preferred account-scoped card carries the Claude default. Every other provider starts off and stays off until you enable it in **Customize**. QuotaBar does not scan local logins or Keychain items to choose providers, so optional cards cannot appear just because a CLI or app happens to be installed. See [Dashboard § First launch](dashboard.md#first-launch).

## When an update adds a new provider

An update can add new provider cards to QuotaBar, but they remain off until you enable them in **Customize**. Installing or signing in to the provider's own app never changes your QuotaBar provider selection.

## Your choices always stick

Everything you set in Customize — providers on or off, metric layout, menu-bar stars — carries across updates untouched. Newly shipped optional providers are added to Customize but never turned on automatically.

The **Reset All Customization** button at the top of the Customize provider list restores the default set — Claude (using its preferred account-scoped card if needed), Codex, Cursor, Freebuff, and registered Codex accounts — and turns other providers off. It asks for confirmation first. See [Dashboard](dashboard.md) for the metric side of that reset.

## How it works (for the curious)

The app persists provider choices and legacy discovery metadata:

- **Enabled providers** — the providers currently on. This is the source of truth the dashboard and menu bar read.
- **Known providers** — every provider this install has seen. Newly registered providers stay off until you enable them. Old pending credential-probe records from earlier builds are discarded.
- Provider implementations may expose a local-only `hasLocalCredentials()` check, but startup and provider discovery do not call it to change your settings.

Routine startup reads OpenCode's Go-key inventory only while OpenCode is enabled. Enabling it rebuilds the account-specific meters from its configured keys; opening **OpenCode Go Keys** in Customize or making an explicit CLI request also reads that inventory for the requested action.

The one-shot CLI applies the same settings migration and fresh-install defaults before it selects providers. A named request can refresh that provider for the current command, while OpenCode's related Claude, Codex, and Hermes scans still follow their saved enablement.

When every Claude card is off, startup skips Claude Desktop organization discovery and its Safe Storage
read. Turning a Claude card on rebuilds the account list before the replacement dashboard appears. If
that action enabled the generic Claude fallback and discovery replaces it with account-scoped cards,
QuotaBar carries the enablement to the preferred account card unless that card was explicitly turned off.

The settings migration preserves recorded Customize choices and enabled provider cards that can be identified from saved account records. It keeps currently enabled core defaults and turns off optional cards that older versions enabled only through credential detection. Freebuff stays on when it was already enabled; a newly introduced default turns it on only when the saved provider history shows it had not been seen or explicitly disabled. If an older settings format left an optional card's choice ambiguous, that card stays off unless a Customize choice was recorded.
