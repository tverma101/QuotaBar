# QuotaBar

Track your AI coding subscriptions from the macOS menu bar.

QuotaBar shows how much of your AI coding plans you've used: session and weekly limits, credits, and spend, all in one popover. Pin your most important metrics straight into the menu bar.

> **This is an independent fork, not the official OpenUsage.**
> QuotaBar is derived from [OpenUsage](https://github.com/robinebers/openusage) by Robin Ebers, which is
> licensed under the MIT licence. It is **not** endorsed by, affiliated with, or an official part of
> OpenUsage, and the OpenUsage name and logo are not used here — see [TRADEMARK.md](TRADEMARK.md).
> Report QuotaBar issues in this repository; report OpenUsage issues
> [upstream](https://github.com/robinebers/openusage/issues).

## Requirements

- macOS 15 (Sequoia) or later

## Building and running

```sh
swift build                     # build
swift test                      # run the test suite
./script/build_and_run.sh run   # stage a signed dev bundle in dist/ and launch it
```

There is **no auto-update mechanism**: the repository is private, and the upstream Sparkle feed is
served anonymously from a public repository. Reinstall by rebuilding, or replace the app bundle in
`/Applications` by hand.

## Supported Providers

- **[Antigravity](docs/providers/antigravity.md)** — shared Gemini and Claude pool quotas, 5-hour and weekly windows
- **[Claude](docs/providers/claude.md)** — session, weekly, model-specific limits, extra usage, local daily spend
- **[Codex](docs/providers/codex.md)** — session, weekly, credits, local daily spend
- **[Copilot](docs/providers/copilot.md)** — AI credits, extra usage, organization billing, chat and completions
- **[Cursor](docs/providers/cursor.md)** — credits, total usage, Grok Bot, Cursor Models, Other Models, requests, on-demand, per-day spend
- **[Devin](docs/providers/devin.md)** — weekly and daily quota, extra usage balance
- **[Grok](docs/providers/grok.md)** — weekly shared pool, pay-as-you-go, local daily spend
- **[OpenCode](docs/providers/opencode.md)** — Go session/weekly/monthly caps, Zen spend, local daily spend
- **[OpenRouter](docs/providers/openrouter.md)** — credit balance, daily/weekly/monthly spend (API key)
- **[Z.ai](docs/providers/zai.md)** — session, weekly, web-search quotas (GLM Coding Plan, API key)

Most providers read the credentials already on your machine (keychain, auth files, app state) — no extra login. OpenRouter and Z.ai are the exceptions: they have no local credential to reuse, so you supply an API key (see [OpenRouter setup](docs/providers/openrouter.md) or [Z.ai setup](docs/providers/zai.md)). Credentials are used only for the corresponding provider requests. QuotaBar's separate anonymous summaries and public pricing downloads are documented under [Privacy & usage data](docs/privacy.md).

## Features

- **Menu bar pins.** Pin metrics to the menu bar (up to 2 per provider); render as compact text or mini bars. The strip hides metrics with no data instead of showing placeholders.
- **Dashboard popover.** Provider-grouped meters with live reset countdowns and pace indicators. Click usage or reset values to flip their display everywhere; right-click a row to hide or star it, refresh its provider, or open Customize.
- **Global shortcut.** Toggle the popover from anywhere — record any combo in Settings.
- **Customize.** Turn providers and metrics on or off, choose which rows stay Always Visible or On Demand, and drag-reorder both.
- **Stale-while-revalidate.** Cached values display instantly at launch; refresh runs every 5 minutes.
- **[One-shot CLI](docs/cli.md).** Agents can read stable limit JSON through the same five-minute cache with `quotabar`, or bypass freshness with `quotabar --force`; the menu-bar app does not need to be running.
- **[Local HTTP API](docs/local-http-api.md).** Other apps can read machine-friendly limits from `127.0.0.1:6736/v1/limits`; the legacy `/v1/usage` UI contract remains supported. It is loopback-only and never serves credentials; note that browser pages can read it too — see the [privacy note](docs/local-http-api.md#cors-and-privacy).
- **[Proxy support](docs/proxy.md).** Route provider requests through SOCKS5 or HTTP(S) via `~/.quotabar/config.json`.
- **Native settings.** Launch at login, global shortcut, icon style, theme, density, 12/24-hour time — see [Settings](docs/settings.md).



## Documentation

Behavior docs live in [docs/](docs/README.md): the [dashboard](docs/dashboard.md), [menu bar pins](docs/menu-bar.md), [settings](docs/settings.md), [refresh & caching](docs/refreshing.md), the [CLI](docs/cli.md), the [local HTTP API](docs/local-http-api.md), the [proxy](docs/proxy.md), and one page per provider.

For working on the code, see the developer docs: [architecture](docs/architecture.md), [adding a provider](docs/adding-a-provider.md), and [debugging & capturing logs](docs/debugging.md).

## Requirements

- macOS 15 (Sequoia) or later
- Universal binary — runs natively on both Apple Silicon and Intel Macs

The Today / Yesterday / Last 30 Days spend tiles are computed natively from local CLI logs (Claude,
Codex, and Grok) or Cursor's usage export — no Node.js or other runtime needed. Dollars are estimated
with [dynamically refreshed model pricing](docs/pricing.md).



## Architecture

SwiftPM package, SwiftUI content hosted in an AppKit-owned `NSStatusItem` + custom key-capable `NSPanel`, Swift 6 strict concurrency. The app and CLI share one module: providers implement a small `ProviderRuntime` protocol (auth store → usage client → mapper → `ProviderSnapshot`), and both surfaces read the same normalized data — see the [architecture overview](docs/architecture.md) for how the pieces fit together and [AGENTS.md](AGENTS.md) for engineering conventions.

## Releasing

There is no automated release pipeline. To produce an installable build:

```sh
./script/build_and_run.sh build          # stage a signed bundle in dist/
```

The staged bundle is signed with an Apple Development identity found in your keychain, which is
enough to run it locally but not to distribute it. Distributing to other machines needs a Developer ID
Application certificate, a provisioning profile for `com.tverma101.quotabar`, and notarization — none
of which this repository is set up to automate.

### iCloud Sync

iCloud Sync is **inert in this fork**. Its container is `iCloud.com.tverma101.quotabar`, which has to
be registered in your own Apple Developer team before any build can use it; with no matching
provisioning profile installed, the build script reports:

```
WARNING: no matching installed iCloud provisioning profile was found; iCloud Sync will be unavailable in this build.
```

The sync code is kept intact so it can be enabled later by registering the container and installing a
profile. See [iCloud Sync](docs/icloud-sync.md) for the container identifiers.

## Contributing

This is an independent fork, so contributions are welcome here and follow [CONTRIBUTING.md](CONTRIBUTING.md). Bug reports about QuotaBar belong in this repository; anything that looks like an upstream defect should go to [robinebers/openusage](https://github.com/robinebers/openusage/issues).

## License

[MIT](LICENSE) — inherited from OpenUsage. See [LICENSE](LICENSE) for the copyright notice and
[UPSTREAM.md](UPSTREAM.md) for this fork's provenance.
