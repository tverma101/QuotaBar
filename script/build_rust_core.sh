#!/usr/bin/env bash
# Builds the quotabar-core Rust static library that backs the CQuotabarCore clang target
# (see Sources/CQuotabarCore/ and docs/rust-core.md).
#
# By default this builds for the host architecture only, which is all a local SwiftPM build needs.
# Set QUOTABAR_RUST_UNIVERSAL=1 to build a universal arm64 + x86_64 archive instead (used by
# RELEASE=1 ./script/build_and_run.sh). Missing rust targets are installed via rustup.
#
# The archive always lands at Rust/quotabar-core/target/release/libquotabar_core.a, the path the
# Package.swift linker setting searches, regardless of per-target intermediate directories.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
crate_dir="$repo_root/Rust/quotabar-core"

if ! command -v cargo >/dev/null 2>&1; then
    echo "error: cargo not found. Install Rust (https://rustup.rs) to build the QuotaBar core." >&2
    exit 1
fi

host_triple="$(rustc -vV | awk '/^host:/ {print $2}')"
if [[ "${QUOTABAR_RUST_UNIVERSAL:-0}" == "1" ]]; then
    targets=(aarch64-apple-darwin x86_64-apple-darwin)
else
    targets=("$host_triple")
fi

for target in "${targets[@]}"; do
    if ! rustup target list --installed 2>/dev/null | grep -qx "$target"; then
        echo "==> rustup target add $target"
        rustup target add "$target"
    fi
    cargo build --release --locked --manifest-path "$crate_dir/Cargo.toml" --target "$target"
done

out_dir="$crate_dir/target/release"
mkdir -p "$out_dir"
archives=()
for target in "${targets[@]}"; do
    archives+=("$crate_dir/target/$target/release/libquotabar_core.a")
done

if [[ ${#archives[@]} -eq 1 ]]; then
    cp "${archives[0]}" "$out_dir/libquotabar_core.a"
else
    lipo -create "${archives[@]}" -output "$out_dir/libquotabar_core.a"
fi
echo "==> Rust core ready: $out_dir/libquotabar_core.a (${targets[*]})"
