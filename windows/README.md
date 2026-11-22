# QuotaBar for Windows

QuotaBar on Windows: the same menu-bar usage widgets as the macOS app, rebuilt on
[Tauri 2](https://tauri.app) (Rust + React) so it runs on Windows (and Linux).

This directory is a vendored and rebranded copy of
[CrossUsage](https://github.com/barramee27/crossusage) — the existing Tauri port of the
same OpenUsage codebase QuotaBar's macOS app descends from. See
[PROVENANCE.md](PROVENANCE.md) for the exact import, the local deltas, and how to
resync from upstream.

## Layout

- `src/` — React/TypeScript settings window and popover UI.
- `src-tauri/` — Tauri shell (tray, window, updater hooks).
- `crates/quotabar-core` — plugin engine (QuickJS), usage model, scanners.
- `crates/quotabar-cli` — `quotabar-cli`, the headless CLI sidecar.
- `plugins/` — per-provider JS plugins (`plugin.js` + `plugin.json` + `icon.svg`).

## Build and run

Requirements: Rust (stable, windows-gnu toolchain), [Bun](https://bun.sh), and the
WebView2 runtime (present on Windows 11; install `webview2-runtime` otherwise).

```sh
bun install
bash scripts/prepare-cli-sidecar.sh   # builds the quotabar-cli sidecar once
bun run tauri:dev:win                 # dev build + run
```

```sh
bun run test                          # Vitest (UI + plugins)
cargo test -p quotabar-cli            # core/CLI tests
bun run build                         # typecheck + Vite build
```

## Providers

Default-enabled providers match the macOS app: Claude, Codex, Cursor, Freebuff.
Every other bundled plugin is available from Settings but starts disabled; new
plugins append alphabetically after the established three.

## Differences from macOS QuotaBar

- Provider plugins run in a QuickJS sandbox inside the app; a plugin reads the
  same on-disk credentials the macOS auth stores use where the layout is
  platform-neutral (e.g. Freebuff's `~/.config/manicode/credentials.json`,
  `CODEBUFF_API_KEY`).
- No auto-update feed: the updater block in `src-tauri/tauri.conf.json` points at
  this repo's releases but stays inert until a QuotaBar-owned signing key exists
  (same rule as the macOS app).
- Anonymous usage analytics (Aptabase) and CrossUsage's product polls are off:
  those endpoints are owned by the CrossUsage project, not QuotaBar.
