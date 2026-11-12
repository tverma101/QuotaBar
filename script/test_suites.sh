#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

jobs="${QUOTABAR_TEST_JOBS:-2}"
if [[ ! "$jobs" =~ ^[1-9][0-9]*$ ]]; then
    printf 'QUOTABAR_TEST_JOBS must be a positive integer.\n' >&2
    exit 2
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
