#!/usr/bin/env bash
# Regenerate Tauri/desktop icons from branding/quotabar-icon-color.svg
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/branding/quotabar-icon-color.svg"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

rsvg-convert -w 1024 -h 1024 "$SRC" -o "$TMP/quotabar-1024.png"
(cd "$ROOT" && bunx tauri icon "$TMP/quotabar-1024.png" -o src-tauri/icons)
rsvg-convert -w 64 -h 64 "$SRC" -o "$TMP/quotabar-tray.png"
\cp -f "$TMP/quotabar-tray.png" "$ROOT/src-tauri/icons/tray-icon.png"
mkdir -p "$ROOT/public"
\cp -f "$ROOT/src-tauri/icons/128x128.png" "$ROOT/public/icon.png"
\cp -f "$SRC" "$ROOT/public/favicon.svg"
\cp -f "$SRC" "$ROOT/sites/quotabar-web/app/icon.svg"
echo "Icons synced. Rebuild: cd src-tauri && cargo build"
echo "Linux Alt+Tab still old? Installed .deb uses /usr/share/icons — run:"
echo "  sudo ./scripts/install-linux-system-icons.sh"
