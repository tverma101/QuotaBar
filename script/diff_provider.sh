#!/usr/bin/env bash
# Historical parity check for the Rust engine port: runs one provider's local-only fold through a
# preserved pre-port Swift reference build (`QuotaBar --scan-worker --return-only`) and through the
# Rust engine example on this machine's real data, then diffs the normalized snapshots. The current
# app no longer implements --scan-worker, so SWIFT_REFERENCE_BIN is required. Local scopes only:
# neither side calls live quota APIs or rotates credentials.
#
#   SWIFT_REFERENCE_BIN=/path/to/pre-port/QuotaBar script/diff_provider.sh claude [panel-accounting|local-accounting]
#
# Output lands in $DIFF_OUT (default: a new temp dir): swift.json, rust.json, *.norm.json, diff.txt.
set -euo pipefail
cd "$(dirname "$0")/.."
id="${1:?usage: diff_provider.sh <provider-id> [panel-accounting|local-accounting]}"
scope="${2:-panel-accounting}"
case "$scope" in
  panel-accounting) rust_scope=panelAccounting ;;
  local-accounting) rust_scope=localAccounting ;;
  *) echo "unknown scope: $scope" >&2; exit 2 ;;
esac
swift_bin="${SWIFT_REFERENCE_BIN:?set SWIFT_REFERENCE_BIN to a preserved pre-port QuotaBar executable}"
out="${DIFF_OUT:-$(mktemp -d -t quotabar-diff)}"
mkdir -p "$out"

QUOTABAR_IN_SCAN_WORKER=1 "$swift_bin" --scan-worker --providers "$id" --scope "$scope" --return-only \
  > "$out/swift.json" 2> "$out/swift.stderr" || { echo "swift reference failed (see $out/swift.stderr)" >&2; exit 1; }
QUOTABAR_APP_DATA="$out/engine-data" cargo run --quiet --release \
  --manifest-path Rust/quotabar-engine/Cargo.toml --example engine -- refresh "$id" "$rust_scope" \
  > "$out/rust.json" 2> "$out/rust.stderr" || { echo "rust engine failed (see $out/rust.stderr)" >&2; exit 1; }

# Drop wall-clock stamps that legitimately differ between two runs, sort Swift `Set`-backed day
# lists (encoded in hash order), and print integral floats the same way on both sides.
normalize='walk(if type == "object" then del(.refreshedAt, .updatedAt, .fetchedAt, .quotaRefreshedAt, .historyRefreshedAt, .generatedAt, .scannedAt) | with_entries(if (.key | endswith("Days")) and (.value | type) == "array" then .value |= sort else . end) elif type == "number" then (. + 0) else . end)'
jq -S --arg id "$id" ".snapshots[\$id] | $normalize" "$out/swift.json" > "$out/swift.norm.json"
jq -S "(.ok.snapshot // .ok) | $normalize" "$out/rust.json" > "$out/rust.norm.json"
if diff -u "$out/swift.norm.json" "$out/rust.norm.json" > "$out/diff.txt"; then
  echo "MATCH $id ($scope) -> $out"
else
  echo "DIFF $id ($scope): $(grep -c '^[-+][^-+]' "$out/diff.txt") changed lines -> $out/diff.txt"
  exit 1
fi
