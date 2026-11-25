# QuotaBar

Track your AI coding subscriptions from the macOS menu bar or Windows system tray.

QuotaBar is a cross-platform desktop app for macOS and Windows. It shows how much of your AI coding plans you've used — session and weekly limits, credits, and spend — all in one popover. On macOS, pin your most important metrics straight into the menu bar; on Windows, the dashboard lives in the system tray.

> **This is an independent fork, not the official OpenUsage.**
> QuotaBar is derived from [OpenUsage](https://github.com/robinebers/openusage) by Robin Ebers, which is
> licensed under the MIT licence. It is **not** endorsed by, affiliated with, or an official part of
> OpenUsage, and the OpenUsage name and logo are not used here — see [TRADEMARK.md](TRADEMARK.md).
> Report QuotaBar issues in this repository; report OpenUsage issues
> [upstream](https://github.com/robinebers/openusage/issues).

## Platforms

QuotaBar ships as two native desktop implementations:

- **macOS** — a Swift/SwiftUI menu-bar app backed by the shared Swift provider pipeline and Rust parsing core.
- **Windows** — a Tauri system-tray app with a React interface, Rust backend, and QuickJS provider runtime. See [QuotaBar for Windows](windows/README.md).

Both platforms track the same core usage concepts, but provider support and platform-specific shell features can differ.

## Download and Set Up

**Windows 11 x64.** Run the setup program, open **QuotaBar** from Start, then click the gauge in the taskbar notification area. Check the hidden icons if needed. The current beta installer is unsigned, so Windows may show a SmartScreen or publisher prompt. [Download v0.7.2-beta.2](https://github.com/tverma101/QuotaBar/releases/download/v0.7.2-beta.2/QuotaBar_0.7.2-beta.2_x64-setup.exe) · [Release notes and checksum](https://github.com/tverma101/QuotaBar/releases/tag/v0.7.2-beta.2)

**macOS 15 or later.** Build QuotaBar from the same release tag. After launching, click the gauge in the menu bar. [macOS source build instructions](#build-from-source)

Claude, Codex, Cursor, and Freebuff are enabled on a fresh install. Sign in through the corresponding provider tool, then refresh QuotaBar. Open **Options → Customize** to manage additional providers in the macOS or Windows Modern dashboard. Provider and metric availability varies by platform.

Updates are manual. On Windows, open **About QuotaBar → Downloads and Updates**, quit QuotaBar, and run the newer installer under the same Windows account. On macOS, check out the newer tag and rebuild. [All releases](https://github.com/tverma101/QuotaBar/releases)

## Build From Source

On macOS, install Xcode 26 or later and stable Rust. To build the current beta, clone this repository and run from its root.

```sh
git checkout v0.7.2-beta.2
CODESIGN_IDENTITY=- ALLOW_ADHOC_SIGNING=1 ./script/build_and_run.sh verify
```

The development build runs from `dist/`. Use an Apple Development signing identity if you need macOS permissions to persist across builds. See [Testing](docs/testing.md) for the test suites.

On Windows, follow the [Windows build and setup guide](windows/README.md).

## Providers

- **[Antigravity](docs/providers/antigravity.md)** — shared Gemini and Claude pool quotas, 5-hour and weekly windows
- **[Claude](docs/providers/claude.md)** — session, weekly, model-specific limits, extra usage, local daily spend
- **[Codex](docs/providers/codex.md)** — session, weekly, credits, local daily spend
- **[Copilot](docs/providers/copilot.md)** — AI credits, extra usage, organization billing, chat and completions
- **[Cursor](docs/providers/cursor.md)** — credits, total usage, Grok Bot, Cursor Models, Other Models, requests, on-demand, per-day spend
- **[Devin](docs/providers/devin.md)** — weekly and daily quota, extra usage balance
- **[Freebuff](docs/providers/freebuff.md)** — Daily Hours, Hours Balance, active sessions, and measured token and spend history
- **[Grok](docs/providers/grok.md)** — weekly shared pool, pay-as-you-go, local daily spend
- **[Hermes](docs/providers/hermes.md)** — session and weekly quota, local daily spend
- **[OpenCode](docs/providers/opencode.md)** — Go session/weekly/monthly caps, Zen spend, local daily spend
- **[OpenRouter](docs/providers/openrouter.md)** — credit balance, daily/weekly/monthly spend (API key)
- **[Z.ai](docs/providers/zai.md)** — session, weekly, web-search quotas (GLM Coding Plan, API key)

Most providers read the credentials already on your machine (keychain, auth files, app state) — no extra login. OpenRouter and Z.ai are the exceptions: they have no local credential to reuse, so you supply an API key (see [OpenRouter setup](docs/providers/openrouter.md) or [Z.ai setup](docs/providers/zai.md)). Credentials are used only for the corresponding provider requests. QuotaBar's separate anonymous summaries and public pricing downloads are documented under [Privacy & usage data](docs/privacy.md).

## Features

These are the core product features. Some shell behavior is platform-specific; the Windows README documents Windows behavior.

- **Menu bar pins (macOS).** Pin metrics to the menu bar (up to 2 per provider); render as compact text or mini bars. The strip hides metrics with no data instead of showing placeholders.
- **Dashboard popover.** Provider-grouped meters with live reset countdowns and pace indicators. On macOS, click usage or reset values to flip their display, or right-click a row for metric actions.
- **Global shortcut.** Toggle the popover from anywhere — record any combo in Settings.
- **Customize.** Turn providers and metrics on or off, choose which rows stay Always Visible or On Demand, and drag-reorder both.
- **Local setup discovery (macOS).** Customize marks supported setups already on the device. You choose which providers to enable.
- **Background refresh.** macOS refreshes live quota every minute, or every two minutes on battery or in Low Power Mode. On Windows, the default refresh interval is 15 minutes.
- **One-shot CLI.** Read limit JSON with `quotabar` on macOS or `quotabar-cli read` on Windows. Add `--force` to refresh. [CLI guide](docs/cli.md)
- **Local HTTP API.** Local apps can read limits from `127.0.0.1:6736/v1/limits`. [macOS API](docs/local-http-api.md) · [Windows API](windows/docs/local-http-api.md)
- **[Proxy support](docs/proxy.md).** Route provider requests through SOCKS5 or HTTP(S) via `~/.quotabar/config.json`.
- **Native settings.** Launch at login, global shortcut, icon style, theme, density, 12/24-hour time — see [Settings](docs/settings.md).

## Documentation

Behavior docs live in [docs/](docs/README.md): the [dashboard](docs/dashboard.md), [menu bar pins](docs/menu-bar.md), [settings](docs/settings.md), [refresh & caching](docs/refreshing.md), the [CLI](docs/cli.md), the [local HTTP API](docs/local-http-api.md), the [proxy](docs/proxy.md), and one page per provider.

For working on the code, see the developer docs: [architecture](docs/architecture.md), [adding a provider](docs/adding-a-provider.md), and [debugging & capturing logs](docs/debugging.md).

## Architecture

The macOS app is a SwiftPM package with SwiftUI content hosted in an AppKit-owned `NSStatusItem` + custom key-capable `NSPanel`, using Swift 6 strict concurrency. The macOS app and CLI share one module: providers implement a small `ProviderRuntime` protocol (auth store → usage client → mapper → `ProviderSnapshot`), and both surfaces read the same normalized data. The Windows app uses Tauri, React, a Rust backend/core, and bundled JavaScript provider plugins under `windows/`. See the [architecture overview](docs/architecture.md), [Windows README](windows/README.md), and [AGENTS.md](AGENTS.md) for engineering conventions.

## Releasing

See [Preparing a Release](docs/releasing.md) for platform builds, smoke tests, and GitHub publishing.

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
