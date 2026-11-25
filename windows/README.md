# QuotaBar for Windows

QuotaBar shows AI coding subscription limits, reset times, credits, and spend in the Windows notification area.

**Windows 11 x64.** The current beta installer is unsigned. Windows may show a SmartScreen or publisher prompt. [Download v0.7.2-beta.2](https://github.com/tverma101/QuotaBar/releases/download/v0.7.2-beta.2/QuotaBar_0.7.2-beta.2_x64-setup.exe) · [Release notes and checksum](https://github.com/tverma101/QuotaBar/releases/tag/v0.7.2-beta.2)

## Install and Set Up

1. Run the `-setup.exe` and open **QuotaBar** from Start. The installer uses the current user's profile and installs WebView2 if it is missing.
2. Click the gauge in the taskbar notification area to reopen the dashboard. You may find it under the hidden icons arrow. Right-click the icon for Settings, About, Restart, and Quit.
3. Open **Options → Customize** in Modern or **Options → Settings → Providers** in Classic to change which providers are tracked. Claude, Codex, Cursor, and Freebuff start enabled. Sign in through the relevant provider tool if a card needs credentials.
4. Set **Start on Login** or **Start Hidden** under **Advanced**. Usage normally refreshes every 15 minutes, including when the panel is closed.

To update, open **About QuotaBar → Downloads and Updates**, quit QuotaBar, and run the newer installer under the same Windows account. Your selected dashboard layout and provider settings carry over.

New profiles open in **Modern**. Use **Options → Usage History** for local totals after enabling **Save usage snapshots after successful refreshes** under **Settings → Advanced**. Change layouts in **Settings → Look → UI layout**.

## CLI and Local API

The installer includes `quotabar-cli.exe` alongside the app. Run this in PowerShell to read Codex limits.

```powershell
& "$env:LOCALAPPDATA\QuotaBar\quotabar-cli.exe" read codex
```

The running tray app also exposes the same cached provider data at `http://127.0.0.1:6736/v1/limits`. [CLI guide](../docs/cli.md#windows) · [Windows local API](docs/local-http-api.md)

## Data Locations

| Data | Default Location |
| --- | --- |
| Installed app and bundled CLI | `%LOCALAPPDATA%\QuotaBar` |
| Settings and app data | `%APPDATA%\com.tverma101.quotabar` |
| CLI configuration | `%APPDATA%\quotabar\config.toml` |
| Optional proxy configuration | `%USERPROFILE%\.quotabar\config.json` |

## Build From Source

Install [Tauri's Windows prerequisites](https://v2.tauri.app/start/prerequisites/), Node.js, Bun, Git for Windows, and stable Rust with the MSVC toolchain. Run from this directory:

```powershell
bun install --frozen-lockfile
bun run test
bun run tauri:build --bundles nsis -- --locked
```

The `-setup.exe` is under `target/release/bundle/nsis/`. For local development, use `bun run tauri:dev:win` after installing dependencies. For a public build, use [the tagged release workflow](../docs/releasing.md#windows).

The desktop port uses Tauri, a React interface, a Rust backend/core, and a local QuickJS provider runtime. See [provenance](PROVENANCE.md) for attribution and upstream synchronization details.
