#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repeat_count="${QUOTABAR_TOKEN_ACCOUNTING_REPEATS:-3}"

if [[ ! "$repeat_count" =~ ^[1-9][0-9]*$ ]]; then
  printf 'QUOTABAR_TOKEN_ACCOUNTING_REPEATS must be a positive integer.\n' >&2
  exit 2
fi

cd "$repo_root"
failed_measurements=0
completed_measurements=0
for ((repeat = 1; repeat <= repeat_count; repeat++)); do
  if ((repeat % 2 == 1)); then
    modes=(raw paced)
  else
    modes=(paced raw)
  fi
  for mode in "${modes[@]}"; do
    printf '\nMeasurement %s/%s: token accounting (%s) against the fixed synthetic ledger.\n' \
      "$repeat" "$repeat_count" "$mode"
    if QUOTABAR_TOKEN_ACCOUNTING_MODE="$mode" \
      swift test -c release -j 2 --disable-index-store --filter TokenAccountingEfficiencyTests; then
      completed_measurements=$((completed_measurements + 1))
    else
      status=$?
      printf 'Measurement %s/%s (%s) failed with exit %s; continuing to collect remaining repeats.\n' \
        "$repeat" "$repeat_count" "$mode" "$status" >&2
      failed_measurements=$((failed_measurements + 1))
    fi
  done
done

printf 'Collected %s/%s token-accounting measurements.\n' "$completed_measurements" "$((repeat_count * 2))"
if ((failed_measurements > 0)); then
  printf '%s token-accounting measurement(s) failed their assertions.\n' "$failed_measurements" >&2
  exit 1
fi
