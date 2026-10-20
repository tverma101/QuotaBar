#!/usr/bin/env bash
set -euo pipefail

# Builds QuotaBar, stages a signed .app bundle under dist/, and launches it in place by default.
# The dev build:
#   - is signed with a stable Apple Development identity, so keychain/permission grants stick across
#     rebuilds (macOS keys those to the signing identity + bundle id, not the install location);
#   - uses its own bundle id (com.tverma101.quotabar.dev), so it never touches the real installed
#     app's settings or keychain. To run against the real app's data instead, set BUNDLE_ID to
#     com.tverma101.quotabar below;
#
# Usage: script/build_and_run.sh [run|build|install|logs|verify]
# Env:   CODESIGN_IDENTITY  override signing identity (exact name or hash)
#        ALLOW_ADHOC_SIGNING "1" permits signing without a stable identity (grants reset on rebuild)
#        CONFIG             "release" (default) or "debug"
#        BUILD_JOBS         SwiftPM worker count (default: 2, to limit peak compiler memory)
#        RELEASE            "1" uses the production app identity; install preserves the destination identity
#        ICLOUD_PROVISIONING_PROFILE  optional override for the development provisioning profile;
#                         otherwise the newest matching installed profile is selected automatically

MODE="${1:-run}"
CONFIG="${CONFIG:-release}"

TARGET_NAME="QuotaBar"                  # SwiftPM target / binary name
APP_DISPLAY="QuotaBar"                  # user-facing app name
# The dev id is deliberate: it keeps local work off the installed app's UserDefaults domain and its
# Keychain entries. But the iCloud container was *pinned* to the dev id, so even setting BUNDLE_ID by
# hand produced a bundle declaring the wrong container. Derive it instead. RELEASE=1 is the shipping
# configuration — and note that switching ids is not cosmetic: macOS keys Keychain grants to the app's
# designated requirement, which embeds the bundle id, and UserDefaults are per-domain, so a different id
# means a fresh settings store and every previously-granted Keychain item needing consent again.
RELEASE="${RELEASE:-0}"
if [ "$RELEASE" = "1" ]; then
  DEFAULT_BUNDLE_ID="com.tverma101.quotabar"
else
  DEFAULT_BUNDLE_ID="com.tverma101.quotabar.dev"
fi
BUNDLE_ID="${BUNDLE_ID:-$DEFAULT_BUNDLE_ID}"
ICLOUD_CONTAINER_ID="${ICLOUD_CONTAINER_ID:-iCloud.$BUNDLE_ID}"
MIN_SYSTEM_VERSION="15.0"
APP_VERSION="0.7.0"
APP_BUILD="0.7.0"
if [ "$RELEASE" = "1" ]; then
  DISPLAY_VERSION="$APP_VERSION"
else
  DISPLAY_VERSION="$APP_VERSION-dev"
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_DISPLAY.app"
STAGING_APP_BUNDLE="$DIST_DIR/.$APP_DISPLAY.staging.$$"
DIST_BACKUP_BUNDLE="$DIST_DIR/.$APP_DISPLAY.backup.$$"
APP_CONTENTS="$STAGING_APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_HELPERS="$APP_CONTENTS/Helpers"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$TARGET_NAME"
CLI_BINARY="$APP_HELPERS/quotabar"
INFO_PLIST="$APP_CONTENTS/Info.plist"
RESOURCE_BUNDLE_NAME="${TARGET_NAME}_${TARGET_NAME}.bundle"
ENTITLEMENTS="$ROOT_DIR/script/QuotaBar.dev.entitlements.plist"
SIGN_ENTITLEMENTS="$ROOT_DIR/script/QuotaBar.local.entitlements.plist"
INSTALL_DEST="/Applications/$APP_DISPLAY.app"
INSTALL_STAGE="${INSTALL_DEST}.staging.$$"
INSTALL_BACKUP="${INSTALL_DEST}.backup.$$"
DIST_NEW_MOVED=0
DIST_BACKUP_MOVED=0
DIST_COMMITTED=0
INSTALL_NEW_MOVED=0
INSTALL_BACKUP_MOVED=0
INSTALL_COMMITTED=0

if [ "$MODE" = "install" ]; then
  if [ ! -d /Applications ] || [ ! -w /Applications ]; then
    echo "cannot install: /Applications is not writable by the current user" >&2
    exit 1
  fi
  if [ -e "$INSTALL_DEST" ]; then
    INSTALLED_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALL_DEST/Contents/Info.plist" 2>/dev/null || true)
    if [ "$INSTALLED_BUNDLE_ID" != "$BUNDLE_ID" ]; then
      echo "refusing to replace $INSTALL_DEST with a different app identity (installed: ${INSTALLED_BUNDLE_ID:-unknown}, requested: $BUNDLE_ID)" >&2
      exit 1
    fi
  fi
fi

bundle_is_running() {
  local bundle_path="$1"
  local expected="$bundle_path/Contents/MacOS/$TARGET_NAME"
  local pids pid actual
  pids="$(pgrep -x "$TARGET_NAME" 2>/dev/null || true)"
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    actual="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$actual" == "$expected" || "$actual" == "$expected "* ]]; then
      return 0
    fi
  done <<< "$pids"
  return 1
}

stop_running_bundle() {
  local bundle_path="$1"
  local expected="$bundle_path/Contents/MacOS/$TARGET_NAME"
  local pids pid actual attempt
  pids="$(pgrep -x "$TARGET_NAME" 2>/dev/null || true)"
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    actual="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    [[ "$actual" == "$expected" || "$actual" == "$expected "* ]] || continue
    kill "$pid" 2>/dev/null || true
    for ((attempt = 0; attempt < 25; attempt++)); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.2
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done <<< "$pids"
}

trash_if_present() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    /usr/bin/trash -v "$1"
  fi
}

cleanup_build() {
  local status=$?
  trap - EXIT
  if [ -e "$STAGING_APP_BUNDLE" ]; then
    trash_if_present "$STAGING_APP_BUNDLE"
  fi
  if [ -e "$INSTALL_STAGE" ]; then
    trash_if_present "$INSTALL_STAGE"
  fi
  if [ "$INSTALL_COMMITTED" -eq 0 ]; then
    if [ "$INSTALL_NEW_MOVED" -eq 1 ] && [ -e "$INSTALL_DEST" ]; then
      stop_running_bundle "$INSTALL_DEST"
      trash_if_present "$INSTALL_DEST" || echo "could not remove failed replacement; recovery bundle: $INSTALL_DEST" >&2
    fi
    if [ "$INSTALL_BACKUP_MOVED" -eq 1 ] && [ -e "$INSTALL_BACKUP" ]; then
      mv "$INSTALL_BACKUP" "$INSTALL_DEST" || echo "could not restore prior install; recovery bundle: $INSTALL_BACKUP" >&2
    fi
  fi
  if [ "$DIST_COMMITTED" -eq 0 ]; then
    if [ "$DIST_NEW_MOVED" -eq 1 ] && [ -e "$APP_BUNDLE" ]; then
      stop_running_bundle "$APP_BUNDLE"
      trash_if_present "$APP_BUNDLE" || echo "could not remove failed dist replacement: $APP_BUNDLE" >&2
    fi
    if [ "$DIST_BACKUP_MOVED" -eq 1 ] && [ -e "$DIST_BACKUP_BUNDLE" ]; then
      mv "$DIST_BACKUP_BUNDLE" "$APP_BUNDLE" || echo "could not restore prior dist app; recovery bundle: $DIST_BACKUP_BUNDLE" >&2
    fi
  fi
  exit "$status"
}
trap cleanup_build EXIT

# Resolve signing before building. Quietly falling back to ad hoc signing changes the designated
# requirement on every rebuild and loses the user's Always Allow grants.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$CODESIGN_IDENTITY" ]; then
  CODESIGN_IDENTITY=$(/usr/bin/security find-identity -p codesigning -v 2>/dev/null \
    | /usr/bin/awk -F\" '/Apple Development:/ { print $2; exit }')
fi
if { [ -z "$CODESIGN_IDENTITY" ] || [ "$CODESIGN_IDENTITY" = "-" ]; } && [ "${ALLOW_ADHOC_SIGNING:-0}" != "1" ]; then
  echo "cannot preserve Keychain grants: select a stable CODESIGN_IDENTITY; use ALLOW_ADHOC_SIGNING=1 only for an intentional ad hoc build" >&2
  exit 1
fi

BUILD_JOBS="${BUILD_JOBS:-2}"
echo "==> swift build ($CONFIG, $BUILD_JOBS jobs, index store disabled)"
swift build -c "$CONFIG" -j "$BUILD_JOBS" --disable-index-store
BUILD_DIR="$(swift build -c "$CONFIG" -j "$BUILD_JOBS" --disable-index-store --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$TARGET_NAME"
BUILD_CLI_BINARY="$BUILD_DIR/quotabar-cli"

if [ ! -x "$BUILD_BINARY" ]; then
  echo "missing built binary: $BUILD_BINARY" >&2
  exit 1
fi
if [ ! -x "$BUILD_CLI_BINARY" ]; then
  echo "missing built CLI: $BUILD_CLI_BINARY" >&2
  exit 1
fi

echo "==> staging $STAGING_APP_BUNDLE"
trash_if_present "$STAGING_APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_HELPERS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$BUILD_CLI_BINARY" "$CLI_BINARY"
chmod +x "$APP_BINARY"
chmod +x "$CLI_BINARY"
# Helpers sit one directory below Contents, so give dyld the same embedded-framework location as the app
# binary, matching where the app's own dependencies are embedded.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$CLI_BINARY"

# SwiftPM stamps LC_BUILD_VERSION's `sdk` field with the deployment target (macOS 15), not the real
# SDK it compiled against. macOS gates the modern Liquid Glass control appearance (pop-up buttons,
# pickers, etc.) on the linked SDK — a "15.0" stamp makes AppKit fall back to legacy Aqua controls.
# Restamp the sdk to 26.0 (Tahoe, where Liquid Glass landed) while keeping minos at MIN_SYSTEM_VERSION
# so the app still runs on macOS 15 but gets the modern controls. Re-signed below.
echo "==> stamping linked SDK 26.0 for Liquid Glass controls (minos stays $MIN_SYSTEM_VERSION)"
vtool -set-build-version macos "$MIN_SYSTEM_VERSION" 26.0 -replace -output "$APP_BINARY.tmp" "$APP_BINARY"
mv "$APP_BINARY.tmp" "$APP_BINARY"
chmod +x "$APP_BINARY"
# Stage every SwiftPM resource bundle produced by the build (the app's own
# QuotaBar_QuotaBar.bundle, which carries the provider SVGs + model manifest)
# into Contents/Resources, the standard app layout. Bundle.openUsageResources
# (see Support/ResourceBundle.swift) loads it from there.
shopt -s nullglob
for bundle in "$BUILD_DIR"/*.bundle; do
  cp -R "$bundle" "$APP_RESOURCES/$(basename "$bundle")"
done
shopt -u nullglob

# Compile the Icon Composer source (assets/AppIcon.icon) into Assets.car so
# Tahoe renders the real Liquid Glass icon. CFBundleIconName below must match
# the .icon file stem ("AppIcon"). The app floor is macOS 15, so a classic .icns
# fallback is relevant there (the release build supplies one); this dev build only
# stages the Assets.car and runs on the maintainer's current OS.
echo "==> compiling app icon (actool)"
PREBUILT_ICON_DIR="$ROOT_DIR/assets/AppIcon.prebuilt"
if xcrun actool "$ROOT_DIR/assets/AppIcon.icon" --compile "$APP_RESOURCES" \
  --app-icon AppIcon \
  --enable-on-demand-resources NO \
  --development-region en \
  --target-device mac \
  --platform macosx \
  --minimum-deployment-target "$MIN_SYSTEM_VERSION" \
  --output-partial-info-plist /dev/null \
  --output-format human-readable-text --errors --warnings; then
  : # compiled the icon fresh
elif [ -f "$PREBUILT_ICON_DIR/Assets.car" ]; then
  # actool is broken on some toolchains; commit 08863d7 ships a prebuilt icon so release CI bypasses
  # it. Reuse the same prebuilt here, so a failed actool doesn't abort the dev build under set -e and
  # the app still gets its real icon.
  echo "==> actool failed; using prebuilt icon (assets/AppIcon.prebuilt)"
  cp "$PREBUILT_ICON_DIR/Assets.car" "$APP_RESOURCES/Assets.car"
  [ -f "$PREBUILT_ICON_DIR/AppIcon.icns" ] && cp "$PREBUILT_ICON_DIR/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
else
  echo "WARNING: actool failed and no prebuilt icon found; continuing without an icon" >&2
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$TARGET_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_DISPLAY</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_DISPLAY</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$DISPLAY_VERSION</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>NSHumanReadableCopyright</key>
  <string>MIT licensed. Derived from OpenUsage by Robin Ebers.</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSUbiquitousContainers</key>
  <dict>
    <key>$ICLOUD_CONTAINER_ID</key>
    <dict>
      <key>NSUbiquitousContainerIsDocumentScopePublic</key>
      <false/>
      <key>NSUbiquitousContainerName</key>
      <string>QuotaBar</string>
      <key>NSUbiquitousContainerSupportedFolderLevels</key>
      <string>None</string>
    </dict>
  </dict>
</dict>
</plist>
PLIST

if [ -n "${ICLOUD_PROVISIONING_PROFILE:-}" ] && [ ! -f "$ICLOUD_PROVISIONING_PROFILE" ]; then
  echo "iCloud provisioning profile not found: $ICLOUD_PROVISIONING_PROFILE" >&2
  exit 1
fi

if [ -z "${ICLOUD_PROVISIONING_PROFILE:-}" ]; then
  ICLOUD_PROVISIONING_PROFILE=$("$ROOT_DIR/script/find_icloud_provisioning_profile.sh" \
    "$BUNDLE_ID" "$ICLOUD_CONTAINER_ID" || true)
fi

if [ -n "${ICLOUD_PROVISIONING_PROFILE:-}" ]; then
  echo "==> using iCloud provisioning profile: $ICLOUD_PROVISIONING_PROFILE"
  cp "$ICLOUD_PROVISIONING_PROFILE" "$APP_CONTENTS/embedded.provisionprofile"
  SIGN_ENTITLEMENTS="$DIST_DIR/QuotaBar.dev.resolved.entitlements.plist"
  "$ROOT_DIR/script/render_icloud_entitlements.sh" \
    "$ENTITLEMENTS" "$ICLOUD_PROVISIONING_PROFILE" "$SIGN_ENTITLEMENTS" \
    "$ICLOUD_CONTAINER_ID"
else
  echo "WARNING: no matching installed iCloud provisioning profile was found; iCloud Sync will be unavailable in this build." >&2
fi

# Resolve the entitlements actually used for signing.
#
# The keychain access group is only claimed when this build is backed by a provisioning profile.
# An app signed with a bare development certificate and no profile is not authorized for any access
# group, and declaring one anyway makes launchd refuse to spawn the app (RBSRequestErrorDomain
# Code=5 / POSIX 163, "Launchd job spawn failed"). So the group is added only once a profile has been
# resolved above; dev builds fall back to the implicit group derived from the bundle id.
#
# Deriving the group from BUNDLE_ID rather than hardcoding it also keeps a dev bundle and a production
# bundle in different groups, so they cannot read or overwrite each other's keychain items.
#
# Note the code, not this entitlement, is what stops the refresh-time Keychain dialogs: provider reads
# go through `readGenericPasswordForRefresh`, which is silent unless the user asked for a refresh.
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-LD48G22523}"
RESOLVED_ENTITLEMENTS="$DIST_DIR/$APP_DISPLAY.signed.entitlements.plist"
/bin/cp "$SIGN_ENTITLEMENTS" "$RESOLVED_ENTITLEMENTS"
if [ -n "$ICLOUD_PROVISIONING_PROFILE" ]; then
  /usr/libexec/PlistBuddy -c "Add :keychain-access-groups array" "$RESOLVED_ENTITLEMENTS" >/dev/null
  /usr/libexec/PlistBuddy -c "Add :keychain-access-groups:0 string $DEVELOPMENT_TEAM.$BUNDLE_ID" \
    "$RESOLVED_ENTITLEMENTS" >/dev/null
  echo "==> keychain access group: $DEVELOPMENT_TEAM.$BUNDLE_ID"
else
  echo "==> no provisioning profile: omitting keychain-access-groups (unclaimed groups block launch)"
fi

if [ -n "$CODESIGN_IDENTITY" ] && [ "$CODESIGN_IDENTITY" != "-" ]; then
  /usr/bin/codesign --force --options runtime --sign "$CODESIGN_IDENTITY" "$CLI_BINARY" >/dev/null
  /usr/bin/codesign --force --options runtime \
    --sign "$CODESIGN_IDENTITY" \
    --entitlements "$RESOLVED_ENTITLEMENTS" \
    "$STAGING_APP_BUNDLE" >/dev/null
  echo "==> signed with: $CODESIGN_IDENTITY"
else
  /usr/bin/codesign --force --sign - "$CLI_BINARY" >/dev/null
  /usr/bin/codesign --force --sign - --entitlements "$RESOLVED_ENTITLEMENTS" "$STAGING_APP_BUNDLE" >/dev/null
  echo "WARNING: no Apple Development identity found; ad-hoc signed." >&2
fi

STAGED_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")
if [ "$STAGED_BUNDLE_ID" != "$BUNDLE_ID" ]; then
  echo "staged app identity mismatch: expected $BUNDLE_ID, found $STAGED_BUNDLE_ID" >&2
  exit 1
fi
/usr/bin/codesign --verify --deep --strict "$STAGING_APP_BUNDLE" >/dev/null

echo "==> verifying staged bundle identity and signature"
stop_running_bundle "$APP_BUNDLE"
if [ -e "$APP_BUNDLE" ]; then
  mv "$APP_BUNDLE" "$DIST_BACKUP_BUNDLE"
  DIST_BACKUP_MOVED=1
fi
if ! mv "$STAGING_APP_BUNDLE" "$APP_BUNDLE"; then
  echo "could not move staged app into place: $APP_BUNDLE" >&2
  exit 1
fi
DIST_NEW_MOVED=1
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE" >/dev/null
DIST_COMMITTED=1
if [ "$DIST_BACKUP_MOVED" -eq 1 ]; then
  trash_if_present "$DIST_BACKUP_BUNDLE"
  DIST_BACKUP_MOVED=0
fi

launch_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    stop_running_bundle "$APP_BUNDLE"
    launch_app
    echo "==> launched $APP_DISPLAY (dist/$APP_DISPLAY.app)"
    ;;
  build)
    : # build + stage + sign only
    ;;
  install)
    # Copy into /Applications so the app is somewhere macOS actually looks.
    #
    # Running out of `dist/` is why this app was hard to find. A menu-bar app (LSUIElement) has no Dock
    # icon and no Launchpad entry by design, which is correct — but it means /Applications is the only
    # place Spotlight and Finder treat it as an installed application. From a build directory it is
    # effectively invisible: no Spotlight hit, no way to relaunch after the checkout is gone.
    trash_if_present "$INSTALL_STAGE"
    mkdir -p "$INSTALL_STAGE"
    rsync -a --delete "$APP_BUNDLE/" "$INSTALL_STAGE/"
    /usr/bin/codesign --verify --deep --strict "$INSTALL_STAGE" >/dev/null
    INSTALL_STAGE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALL_STAGE/Contents/Info.plist")
    if [ "$INSTALL_STAGE_ID" != "$BUNDLE_ID" ]; then
      echo "staged install identity mismatch: expected $BUNDLE_ID, found $INSTALL_STAGE_ID" >&2
      exit 1
    fi
    echo "==> staged and signature verified: $INSTALL_STAGE"

    # Build and verify the replacement before stopping either copy. Stop only the exact bundle paths,
    # because dev and release builds share the QuotaBar process name but use different identities.
    stop_running_bundle "$APP_BUNDLE"
    stop_running_bundle "$INSTALL_DEST"

    if [ -e "$INSTALL_DEST" ]; then
      mv "$INSTALL_DEST" "$INSTALL_BACKUP"
      INSTALL_BACKUP_MOVED=1
    fi
    if ! mv "$INSTALL_STAGE" "$INSTALL_DEST"; then
      echo "could not move staged app into place: $INSTALL_DEST" >&2
      exit 1
    fi
    INSTALL_NEW_MOVED=1
    /usr/bin/codesign --verify --deep --strict "$INSTALL_DEST" >/dev/null
    INSTALL_FINAL_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALL_DEST/Contents/Info.plist")
    if [ "$INSTALL_FINAL_ID" != "$BUNDLE_ID" ]; then
      echo "installed app identity verification failed: $INSTALL_DEST" >&2
      exit 1
    fi
    echo "==> installed and signature verified: $INSTALL_DEST"
    /usr/bin/mdimport -r "$INSTALL_DEST" >/dev/null 2>&1 || true
    open -a "$INSTALL_DEST"
    for ((attempt = 0; attempt < 25; attempt++)); do
      bundle_is_running "$INSTALL_DEST" && break
      sleep 0.2
    done
    if ! bundle_is_running "$INSTALL_DEST"; then
      echo "installed app did not start; the prior bundle will be restored from $INSTALL_BACKUP" >&2
      exit 1
    fi
    INSTALL_COMMITTED=1
    if [ -e "$INSTALL_BACKUP" ]; then
      trash_if_present "$INSTALL_BACKUP"
      INSTALL_BACKUP_MOVED=0
    fi
    echo "==> launched from $INSTALL_DEST"
    ;;
  logs)
    stop_running_bundle "$APP_BUNDLE"
    launch_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$TARGET_NAME\""
    ;;
  verify)
    stop_running_bundle "$APP_BUNDLE"
    launch_app
    for ((attempt = 0; attempt < 25; attempt++)); do
      bundle_is_running "$APP_BUNDLE" && break
      sleep 0.2
    done
    bundle_is_running "$APP_BUNDLE" && echo "==> running"
    ;;
  *)
    echo "usage: $0 [run|build|install|logs|verify]" >&2
    exit 2
    ;;
esac
