#!/usr/bin/env bash
# Build quotabar-cli for the same target as the Tauri app and place it where Tauri externalBin expects.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

HOST_TRIPLE="$(rustc -vV | awk '/host:/{print $2}')"

# Tauri sets this for beforeBuildCommand (see TAURI_ENV_* in Tauri docs).
if [[ -n "${TAURI_ENV_TARGET_TRIPLE:-}" ]]; then
  TARGET="$TAURI_ENV_TARGET_TRIPLE"
elif [[ -n "${CARGO_BUILD_TARGET:-}" ]]; then
  TARGET="$CARGO_BUILD_TARGET"
else
  TARGET="$HOST_TRIPLE"
fi

mkdir -p "$ROOT/src-tauri/binaries"
if [[ "$TARGET" == *"windows"* ]]; then
  DEST="$ROOT/src-tauri/binaries/quotabar-cli-$TARGET.exe"
else
  DEST="$ROOT/src-tauri/binaries/quotabar-cli-$TARGET"
fi

# In dev setup (`QUOTABAR_DEV_SIDECAR=1`), reuse an existing sidecar or create a lightweight stub
# so starting `tauri:dev` doesn't force a full release compile of quotabar-cli.
if [[ "${QUOTABAR_DEV_SIDECAR:-0}" == "1" ]]; then
  if [[ -x "$DEST" ]]; then
    echo "==> Reusing existing dev CLI sidecar: $DEST"
    exit 0
  fi
  if [[ "$TARGET" != *"windows"* ]]; then
    cat > "$DEST" << 'EOF'
#!/usr/bin/env sh
exec cargo run -q -p quotabar-cli -- "$@"
EOF
    chmod +x "$DEST"
    echo "==> Created lightweight dev CLI sidecar stub: $DEST"
    exit 0
  fi
fi

# Only pass `--target` when cross-compiling (`TARGET != HOST_TRIPLE`) so native builds
# share `target/release/` with `tauri build` and compile shared crates once.
if [[ "$TARGET" == "$HOST_TRIPLE" ]]; then
  echo "==> Building quotabar-cli for host ($TARGET)"
  cargo build --release -p quotabar-cli
  if [[ "$TARGET" == *"windows"* ]]; then
    SRC="$ROOT/target/release/quotabar-cli.exe"
  else
    SRC="$ROOT/target/release/quotabar-cli"
  fi
else
  echo "==> Building quotabar-cli for cross-target $TARGET"
  cargo build --release -p quotabar-cli --target "$TARGET"
  if [[ "$TARGET" == *"windows"* ]]; then
    SRC="$ROOT/target/$TARGET/release/quotabar-cli.exe"
  else
    SRC="$ROOT/target/$TARGET/release/quotabar-cli"
  fi
fi

cp -f "$SRC" "$DEST"
chmod +x "$DEST" 2>/dev/null || true
echo "==> CLI sidecar: $DEST"

