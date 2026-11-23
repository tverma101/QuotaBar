# QuotaBar for Windows

QuotaBar shows AI coding subscription limits, reset times, credits, and spend in the Windows notification area. See [GitHub Releases](https://github.com/tverma101/QuotaBar/releases) for the Windows 11 x64 setup executable.

## Install and Set Up

1. Run the `-setup.exe` and open **QuotaBar** from Start. The installer uses the current user's profile and installs WebView2 if it is missing.
2. Click the gauge in the taskbar notification area to reopen the dashboard. You may find it under the hidden icons arrow. Right-click the icon for Settings, About, Restart, and Quit.
3. Open **Options → Settings → Providers** to change which providers are tracked. Claude, Codex, Cursor, and Freebuff start enabled. Sign in through the relevant provider tool if a card needs credentials.

In the Modern layout, **Options → Customize** also lets you enable providers, choose which metrics stay visible or appear on demand, and pin supported metrics. **Options → Usage History** summarizes the local daily usage retained for enabled accounts when local usage history is turned on. iCloud Sync is unavailable on Windows.
4. Set **Start on Login** or **Start Hidden** under **Advanced**. Usage normally refreshes every 15 minutes, including when the panel is closed.

To update, open **About QuotaBar → Downloads and Updates**, quit QuotaBar, and run the newer installer under the same Windows account. Your selected dashboard layout and provider settings carry over.

| Data | Default Location |
| --- | --- |
| Installed app and bundled CLI | `%LOCALAPPDATA%\QuotaBar` |
| Settings and app data | `%APPDATA%\com.tverma101.quotabar` |
| CLI configuration | `%APPDATA%\quotabar\config.toml` |
| Optional proxy configuration | `%USERPROFILE%\.quotabar\config.json` |

The dashboard and [local HTTP API](docs/local-http-api.md) share the app's provider results. History and provider availability depend on the provider's Windows support.

## Build From Source

Install [Tauri's Windows prerequisites](https://v2.tauri.app/start/prerequisites/), Node.js, Bun, Git for Windows, and stable Rust with the MSVC toolchain. Run from this directory:

```sh
bun install --frozen-lockfile
bun run tauri:dev:win
bun run test
bun run tauri:build --bundles nsis -- --locked
```

The `-setup.exe` is under `target/release/bundle/nsis/`. For a public build, follow the [release instructions](../docs/releasing.md).

The desktop port uses Tauri and a local QuickJS provider runtime. See [provenance](PROVENANCE.md) for attribution and upstream synchronization details.
