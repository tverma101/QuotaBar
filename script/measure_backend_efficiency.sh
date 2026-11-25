#!/usr/bin/env bash
# Repeatable backend measurement. Numbers are machine-specific; compare runs of the same machine.
#
#   script/measure_backend_efficiency.sh
#
# QUOTABAR_BENCH_ROWS and QUOTABAR_BENCH_ITERATIONS tune the synthetic OpenCode scan; the Swift
# pass reads the current profile's local history in fold-only scope. A cold pricing cache can
# start public catalogue requests. Run the synthetic provider pass without credential overrides.

set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Building the Rust static library for the Swift pass"
bash script/build_rust_core.sh >/dev/null

echo "==> Engine: full batch, fold-only batch, 100k-row SQLite scan"
cargo test --release --locked --manifest-path Rust/quotabar-engine/Cargo.toml \
    --test efficiency_measure -- --ignored --nocapture --test-threads=1

echo "==> Core: large C ABI reply and the removed extra copy"
cargo test --release --locked --manifest-path Rust/quotabar-core/Cargo.toml \
    --lib efficiency_measure_tests -- --ignored --nocapture --test-threads=1

echo "==> Swift: full fold batch through the bridge, decode, and main-actor responsiveness"
QUOTABAR_SWIFT_BACKEND_BENCH=1 swift test --filter BackendEfficiencyTests
