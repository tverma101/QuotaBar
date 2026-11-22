# Linux and Windows (preview)

QuotaBar for Linux and Windows is a **preview** under `Desktop/`: a small Tauri 2 shell
with a native window and tray icon, and a static HTML/CSS/JS panel — no Node runtime, no
bundler, no updater, no telemetry. Provider fetching is a separate Rust library that
reads the credentials already on your machine and calls each provider's usage API.

It is **not** at feature parity with the macOS app — see "Not in the preview" below.

## Supported platforms

- **Ubuntu 24.04** (x64) — `deb` installer. The tray icon needs an AppIndicator-capable
  shell extension; without one, the app runs as a normal window.
- **Windows 11** (x64) — NSIS installer (`-Setup.exe`).

## Building

Prerequisites:

- Rust stable (`rustup`)
- Node 22+ (only for the Tauri CLI and UI tests — the app itself has no Node runtime)
- Linux only: `libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev`
  plus `build-essential pkg-config`
- Windows only: the MSVC C++ build tools (Visual Studio Build Tools) and the WebView2
  Runtime (preinstalled on Windows 11; install it on stripped-down images)

```sh
cd Desktop
cargo test --locked --no-default-features --manifest-path src-tauri/Cargo.toml
npx --yes @tauri-apps/cli@2.12.6 build --bundles deb    # Linux
npx --yes @tauri-apps/cli@2.12.6 build --bundles nsis   # Windows
```

CI (`desktop-ci.yml`) runs the same commands on `ubuntu-24.04` and `windows-2022`.
Installers land in `Desktop/src-tauri/target/release/bundle/`.

## Running

```sh
./quotabar-desktop          # live mode — reads credentials, calls provider APIs
./quotabar-desktop --demo   # deterministic sample data; never touches credentials or network
```

The window stays visible on launch. The tray menu (Open QuotaBar / Refresh / Quit)
appears wherever the desktop shell exposes an AppIndicator/StatusNotifier host or a
Windows notification area. Close behavior differs deliberately by platform:

- **Windows** — with a successfully installed tray icon, closing the window hides it to
  the tray; without one, closing quits the app.
- **Linux** — closing the window always quits. A successfully built tray object does not
  prove a shell is actually exposing it, so hiding on close could strand the app with no
  surface at all; use Minimize to park the window in the taskbar instead. On shells
  without any tray host the app simply runs window-only.

The app never registers itself to start at login.

## Providers and credentials

Only four providers can reach the network; Customize toggles persist per mode.

| Provider | Credential source | Metrics in the preview |
| -------- | ----------------- | ---------------------- |
| Claude | `$CLAUDE_CONFIG_DIR` or `~/.claude/.credentials.json` (`claudeAiOauth.accessToken`) | Session, Weekly, Fable weekly |
| Codex | `$CODEX_HOME` or `~/.codex` → `auth.json` (`tokens.access_token` + account id, verified against the id-token claim). API-key-only files are rejected. | Session, Weekly, Credits |
| OpenRouter | `OPENROUTER_API_KEY`, then `OPENROUTER_KEY` | Credits, Balance, Today/Week/Month spend, Key Limit |
| Z.ai | `ZAI_API_KEY`, then `GLM_API_KEY` | Session, Weekly, Web Searches |

Live mode enables Claude and Codex by default; OpenRouter and Z.ai are opt-in.
Environment variables are captured when the app launches — after changing
`OPENROUTER_API_KEY`/`ZAI_API_KEY`/etc. you must restart QuotaBar for the new
values to be seen.
Demo mode shows all four. Disabled providers are never probed, and disabling a
provider discards its snapshot — nothing is cached to disk.

Refreshes happen on a 60-second timer while the window is visible, on the Refresh
button, or from the tray menu. Errors are classified: sign-in/setup problems clear
the last snapshot; transient failures keep it, marked stale with its timestamp.

## Not in the preview

Feature gaps versus the macOS app, all deliberate:

- All other providers (Cursor, Grok, Devin, Copilot, Freebuff, Antigravity, Hermes,
  OpenCode, Muse, Pi)
- Local log scanning: Today/Yesterday/spend tiles, model pricing, history and streaks
- Saved API-key management UI (env vars only for OpenRouter/Z.ai)
- Token refresh and multi-account support; Codex reset credits and model-specific limits
- `quotabar-cli` and the local HTTP API
- Global shortcut, launch at login, menu-bar pins and metric-level customization
- Signed builds/installers

## Manual QA checklist (VM)

- Launch → window visible, gauge icon, Demo badge only under `--demo`
- Keyboard: Tab reaches every control; Enter/Space activates; focus visible
- Tray: menu Open/Refresh/Quit work where a tray host exists; left-click opens on
  Windows; missing tray support logs a message and the window still closes-to-quit
- Close: Linux always quits the app (minimize parks it in the taskbar); Windows hides
  to tray only when the tray icon installed
- Customize: toggles persist across relaunch; disabling stops refreshes; re-enabling fetches fresh
- Refresh: cards show stale state on network failure, clear on auth failure
- Installer: `deb`/`nsis` installs, launches, and uninstalls cleanly
- Narrow the window to ~340px: content scrolls, nothing clips
