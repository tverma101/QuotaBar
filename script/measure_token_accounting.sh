#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repeat_count="${QUOTABAR_TOKEN_ACCOUNTING_REPEATS:-3}"

if [[ ! "$repeat_count" =~ ^[1-9][0-9]*$ ]]; then
  printf 'QUOTABAR_TOKEN_ACCOUNTING_REPEATS must be a positive integer.\n' >&2
  exit 2
fi

cd "$repo_root"
for ((repeat = 1; repeat <= repeat_count; repeat++)); do
  for mode in raw paced; do
    printf '\nMeasurement %s/%s: token accounting (%s) against the fixed synthetic ledger.\n' \
      "$repeat" "$repeat_count" "$mode"
    QUOTABAR_TOKEN_ACCOUNTING_MODE="$mode" \
      swift test -j 2 --disable-index-store --filter TokenAccountingEfficiencyTests
  done
done
