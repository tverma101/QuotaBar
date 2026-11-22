# QuotaBar

Track your AI coding subscriptions from the macOS menu bar.

QuotaBar shows how much of your AI coding plans you've used: session and weekly limits, credits, and spend, all in one popover. Pin your most important metrics straight into the menu bar.

> **This is an independent fork, not the official OpenUsage.**
> QuotaBar is derived from [OpenUsage](https://github.com/robinebers/openusage) by Robin Ebers, which is
> licensed under the MIT licence. It is **not** endorsed by, affiliated with, or an official part of
> OpenUsage, and the OpenUsage name and logo are not used here — see [TRADEMARK.md](TRADEMARK.md).
> Report QuotaBar issues in this repository; report OpenUsage issues
> [upstream](https://github.com/robinebers/openusage/issues).

## Download and Set Up

QuotaBar runs on **macOS 15 (Sequoia) or later**. macOS release builds are universal (Apple Silicon and Intel). The download and setup instructions here apply to macOS.

1. Open [GitHub Releases](https://github.com/tverma101/QuotaBar/releases). If there is no release with a QuotaBar `.dmg` under **Assets**, there is no installable download yet. GitHub's **Source code** archives are not installers; use the source build instructions below instead.
2. Open the `.dmg`, drag **QuotaBar** into **Applications**, and open it from there. Click the **QuotaBar icon in the menu bar** to open the dashboard.
3. Open **Customize** to see which provider setups QuotaBar found on your Mac. Enable the providers you want. If a card asks you to sign in or add a key, use its [provider setup guide](docs/README.md#providers), then return to Customize and choose **Rescan**.

QuotaBar does not update itself. To update a release build, quit QuotaBar and replace the app in Applications using the new `.dmg`.

## Build From Source

To build on a Mac, install [Xcode 26 or later](https://developer.apple.com/xcode/) (Swift 6.2 and the macOS 26 SDK) and [stable Rust via rustup](https://rustup.rs/). From the repository root:

```sh
CODESIGN_IDENTITY=- ALLOW_ADHOC_SIGNING=1 ./script/build_and_run.sh verify
```

This builds the Rust core, stages an ad-hoc-signed development app in `dist/`, and launches it without replacing anything in Applications. Use an Apple Development signing identity instead if you need macOS permissions to persist across builds. See [Testing](docs/testing.md) for the test suites.

## Supported Providers

- **[Antigravity](docs/providers/antigravity.md)** — shared Gemini and Claude pool quotas, 5-hour and weekly windows
- **[Claude](docs/providers/claude.md)** — session, weekly, model-specific limits, extra usage, local daily spend
- **[Codex](docs/providers/codex.md)** — session, weekly, credits, local daily spend
- **[Copilot](docs/providers/copilot.md)** — AI credits, extra usage, organization billing, chat and completions
- **[Cursor](docs/providers/cursor.md)** — credits, total usage, Grok Bot, Cursor Models, Other Models, requests, on-demand, per-day spend
- **[Devin](docs/providers/devin.md)** — weekly and daily quota, extra usage balance
- **[Freebuff](docs/providers/freebuff.md)** — session quotas, Freebucks credits, reset times, and reported monthly spend
- **[Grok](docs/providers/grok.md)** — weekly shared pool, pay-as-you-go, local daily spend
- **[Hermes](docs/providers/hermes.md)** — session and weekly quota, local daily spend
- **[OpenCode](docs/providers/opencode.md)** — Go session/weekly/monthly caps, Zen spend, local daily spend
- **[OpenRouter](docs/providers/openrouter.md)** — credit balance, daily/weekly/monthly spend (API key)
- **[Z.ai](docs/providers/zai.md)** — session, weekly, web-search quotas (GLM Coding Plan, API key)

Most providers read the credentials already on your machine (keychain, auth files, app state) — no extra login. OpenRouter and Z.ai are the exceptions: they have no local credential to reuse, so you supply an API key (see [OpenRouter setup](docs/providers/openrouter.md) or [Z.ai setup](docs/providers/zai.md)). Credentials are used only for the corresponding provider requests. See [Privacy & usage data](docs/privacy.md) for network requests and telemetry behavior.

## Features

- **Menu bar pins.** Pin metrics to the menu bar (up to 2 per provider); render as compact text or mini bars. The strip hides metrics with no data instead of showing placeholders.
- **Dashboard popover.** Provider-grouped meters with live reset countdowns and pace indicators. Click usage or reset values to flip their display everywhere; right-click a row to hide or star it, refresh its provider, or open Customize.
- **Global shortcut.** Toggle the popover from anywhere — record any combo in Settings.
- **Customize.** Turn providers and metrics on or off, choose which rows stay Always Visible or On Demand, and drag-reorder both.
- **Local setup discovery.** QuotaBar checks supported provider setup sources on this Mac and marks matches in Customize. You choose which providers to enable; discovery stays local and never activates providers automatically.
- **Stale-while-revalidate.** Cached values display instantly at launch; live quota meters refresh every minute (every two minutes on battery or in Low Power Mode), while full history refreshes every five minutes.
- **[One-shot CLI](docs/cli.md).** Agents can read stable limit JSON through the same five-minute cache with `quotabar`, or bypass freshness with `quotabar --force`; the menu-bar app does not need to be running.
- **[Local HTTP API](docs/local-http-api.md).** Other apps can read machine-friendly limits from `127.0.0.1:6736/v1/limits`; the legacy `/v1/usage` UI contract remains supported. It is loopback-only and never serves credentials; note that browser pages can read it too — see the [privacy note](docs/local-http-api.md#cors-and-privacy).
- **[Proxy support](docs/proxy.md).** Route provider requests through SOCKS5 or HTTP(S) via `~/.quotabar/config.json`.
- **Native settings.** Launch at login, global shortcut, icon style, theme, density, 12/24-hour time — see [Settings](docs/settings.md).

The Today / Yesterday / Last 30 Days spend tiles are computed natively from local CLI logs (Claude,
Codex, and Grok) or Cursor's usage export — no Node.js or other runtime needed. Dollars are estimated
with [dynamically refreshed model pricing](docs/pricing.md).

## Documentation

Behavior docs live in [docs/](docs/README.md): the [dashboard](docs/dashboard.md), [menu bar pins](docs/menu-bar.md), [settings](docs/settings.md), [refresh & caching](docs/refreshing.md), the [CLI](docs/cli.md), the [local HTTP API](docs/local-http-api.md), the [proxy](docs/proxy.md), and one page per provider.

For working on the code, see the developer docs: [architecture](docs/architecture.md), [adding a provider](docs/adding-a-provider.md), and [debugging & capturing logs](docs/debugging.md).

## Architecture

SwiftPM package, SwiftUI content hosted in an AppKit-owned `NSStatusItem` + custom key-capable `NSPanel`, Swift 6 strict concurrency. The app and CLI share one module: providers implement a small `ProviderRuntime` protocol (auth store → usage client → mapper → `ProviderSnapshot`), and both surfaces read the same normalized data — see the [architecture overview](docs/architecture.md) for how the pieces fit together and [AGENTS.md](AGENTS.md) for engineering conventions.

## Releasing

Releases are built and published manually. See [Preparing a macOS release](docs/releasing.md).

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
