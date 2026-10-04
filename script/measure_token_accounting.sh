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
passed_measurements=0
collected_measurements=0
measurement_log=""
cleanup_measurement_log() {
  if [[ -n "$measurement_log" ]]; then
    rm -f "$measurement_log"
  fi
}
trap cleanup_measurement_log EXIT
for ((repeat = 1; repeat <= repeat_count; repeat++)); do
  if ((repeat % 2 == 1)); then
    modes=(raw paced)
  else
    modes=(paced raw)
  fi
  for mode in "${modes[@]}"; do
    measurement_log="$(mktemp)"
    measurement_passed=0
    measurement_recorded=0
    printf '\nMeasurement %s/%s: token accounting (%s) against the fixed synthetic ledger.\n' \
      "$repeat" "$repeat_count" "$mode"
    if QUOTABAR_TOKEN_ACCOUNTING_MODE="$mode" \
      swift test -c release -j 2 --disable-index-store --disable-swift-testing --filter TokenAccountingEfficiencyTests 2>&1 | tee "$measurement_log"; then
      measurement_passed=1
    else
      status=$?
      printf 'Measurement %s/%s (%s) failed with exit %s; continuing to collect remaining repeats.\n' \
        "$repeat" "$repeat_count" "$mode" "$status" >&2
    fi
    if rg -q "^TOKEN_ACCOUNTING_BENCH mode=${mode} " "$measurement_log"; then
      collected_measurements=$((collected_measurements + 1))
      measurement_recorded=1
    else
      printf 'Measurement %s/%s (%s) emitted no benchmark record.\n' \
        "$repeat" "$repeat_count" "$mode" >&2
    fi
    if ((measurement_passed == 1 && measurement_recorded == 1)); then
      passed_measurements=$((passed_measurements + 1))
    else
      failed_measurements=$((failed_measurements + 1))
    fi
    rm -f "$measurement_log"
    measurement_log=""
  done
done

printf 'Collected %s/%s token-accounting measurements; %s passed all assertions.\n' \
  "$collected_measurements" "$((repeat_count * 2))" "$passed_measurements"
if ((failed_measurements > 0)); then
  printf '%s token-accounting measurement(s) failed their assertions.\n' "$failed_measurements" >&2
  exit 1
fi
