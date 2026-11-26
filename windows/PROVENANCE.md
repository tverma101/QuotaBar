# Windows port provenance

`windows/` is the QuotaBar port for Windows (and Linux). It is built on
[CrossUsage](https://github.com/barramee27/crossusage) — itself an MIT-licensed fork of
[OpenUsage](https://github.com/robinebers/openusage) by Robin Ebers — which ports the OpenUsage
menu-bar app to a Tauri (Rust + React) tray application for Windows and Linux.

## Imported revision

- Repository: `https://github.com/barramee27/crossusage`
- Commit: `ca138f5de093f2a4424997953c611fa99685b8cb` (vendored 2026-11-22)
- License: MIT — `LICENSE` in this directory is retained as required.

Excluded from the import: git history, CI workflows, release binaries, the crossusage.dev
website, and CrossUsage branding assets.

## Local deltas applied at import

1. **Rebrand to QuotaBar** — product name, window title, bundle identifier
   (`com.tverma101.quotabar`, matching the macOS app), crate/binary names
   (`quotabar`, `quotabar-cli`, `quotabar-core`, `quotabar-win-launcher`), publisher,
   homepage, and all user-facing strings.
2. **Icons** — `src-tauri/icons/` regenerated from `assets/AppIcon.icon/Assets/quotabar-gauge.svg`
   via `scripts/render-icon.html` / `render-tray-icon.html` (headless-Chrome raster pipeline).
3. **Release services** — QuotaBar ships without the imported analytics tracker and product polls. The
   imported updater signing key was replaced with a QuotaBar-owned key, and the updater reads this
   repository's `update-feed` branch. About still links to GitHub Releases for downloads.
4. **Windows setup** — a per-user installer bundles the CLI and providers. Settings use the user's
   roaming app-data directory. The compact panel groups settings into sections.

## Update procedure

Changes from CrossUsage or upstream OpenUsage land as normal commits here. When syncing from
CrossUsage, diff against the imported commit and re-apply the deltas above (names, keys,
defaults).
