#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --build ) ]]; then
    printf 'Usage: %s [--build]\n' "${0##*/}" >&2
    exit 2
fi

printf '\n==> Rust core\n'
bash script/build_rust_core.sh
(
    cd Rust/quotabar-core
    printf '\n==> Rust unit tests\n'
    host_triple="$(rustc -vV | awk '/^host:/ {print $2}')"
    cargo test --release --locked --target "$host_triple"
)

jobs="${QUOTABAR_TEST_JOBS:-2}"
if [[ ! "$jobs" =~ ^[1-9][0-9]*$ ]]; then
    printf 'QUOTABAR_TEST_JOBS must be a positive integer.\n' >&2
    exit 2
fi

if [[ ${1:-} == --build ]]; then
    printf '\n==> Swift package build (jobs=%s)\n' "$jobs"
    swift build -j "$jobs" --disable-index-store
fi

printf '\n==> CI workflow and coverage contracts\n'
bash script/test_ci_workflow.sh

printf '\n==> Shell measurement-driver regression tests (mocked Swift)\n'
bash script/test_measure_token_accounting.sh

printf '\n==> Python pricing and CI contract tests\n'
python3 -m unittest discover -v -s Tests -p '*Tests.py'

printf '\n==> Swift XCTest and Swift Testing suites (jobs=%s)\n' "$jobs"
swift test -j "$jobs" --disable-index-store

printf '\nAll QuotaBar test suites passed.\n'
