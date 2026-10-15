# Which Providers Are On

How QuotaBar decides which providers start on, what happens when an update adds a new provider, and the one rule that governs it all: **your own toggles always win and are never overridden.**

## First install

A fresh install doesn't turn on every provider QuotaBar knows about. It starts with Claude, Codex, and Cursor, then quickly checks which providers have credentials available on your Mac — an existing local login, saved API key, or supported environment variable; nothing is sent anywhere — and switches to exactly that set. All providers are checked at once, so detection takes as long as the slowest single check, not the sum of them. If nothing is found, the Claude/Codex/Cursor starter set stays. Providers the check turns on are fetched right away, so they appear with data instead of waiting for the next scheduled refresh. See [Dashboard § First launch](dashboard.md#first-launch) for how the dashboard presents this.

## When an update adds a new provider

The same detection runs for providers that arrive later. On the first launch after an update, QuotaBar compares the providers it now ships with the ones this install has seen before. For each brand-new one, it runs the same local-only credential check:

- **Credentials are available locally** → the provider turns on and appears on the dashboard.
- **No credentials are available** → it stays off. You can always turn it on later in **Customize**.

This check happens **once per provider**. If QuotaBar closes before a check finishes, it resumes that pending check on the next launch. A saved user toggle still wins, and a completed miss is not probed again. After detection finishes, the provider is yours to manage: if you turn it off, no update will turn it back on, and installing the tool later won't flip it on behind your back either — head to Customize when you want it.

## Your choices always stick

Everything you set in Customize — providers on or off, metric layout, menu-bar stars — carries across updates untouched. The only thing an update may ever change is turning **on** a provider you have never seen before, and only when you actually have that tool installed.

The one exception is deliberate: the **Reset All Customization** button at the top of the Customize provider list. Because you asked for a clean slate, it re-runs the same local credential detection as first launch and switches the enabled set back to exactly the providers with credentials available on your Mac (Claude/Codex/Cursor if none are found) — so it can turn a provider off even if you had it on, or back on if you had turned it off. It also asks for confirmation first. See [Dashboard](dashboard.md) for the metric side of that reset.

## How it works (for the curious)

The app persists provider choices plus the state needed to resume unfinished credential checks:

- **Enabled providers** — the providers currently on. This is the source of truth the dashboard and menu bar read.
- **Known providers and pending checks** — every provider this install has seen, plus any new-provider checks that did not finish before QuotaBar closed. A pending check resumes on launch; a completed miss stays one-shot. Persisted user-choice revisions prevent a resumed first-run check from replacing a toggle.
- Each provider implements a cheap, local-only credential probe (`hasLocalCredentials()`) — the same files, keychain entries, saved keys, and environment variables its normal refresh reads, never the network.

Older installs (from before first-run detection existed) started with every provider on and stored only the ones turned *off*. A one-time settings migration converts them to the lists above with the exact same providers on and off as before — nothing visibly changes on the launch that migrates; those installs simply join the same new-provider detection from then on.
