#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$repo_root"
for mode in raw paced; do
  printf '\nMeasuring token accounting (%s) against the fixed synthetic ledger.\n' "$mode"
  QUOTABAR_TOKEN_ACCOUNTING_MODE="$mode" \
    swift test -j 2 --disable-index-store --filter TokenAccountingEfficiencyTests
done
