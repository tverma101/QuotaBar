#!/usr/bin/env bash
set -euo pipefail

# Measures the running QuotaBar app's CPU as a percentage of one core, once per second.
# Every process named QuotaBar is summed, so the short-lived --scan-worker child counts too.
#
# Usage: script/measure_cpu.sh [seconds]
# Env:   QUOTABAR_PROCESS_NAME  process name to sample (default: QuotaBar)
#
# Reports mean, median, p95 and peak. The 2% ceiling in docs/cpu-baseline.md refers to the
# closed-panel steady state: p95 is the sustained reading, max is the worst one-second sample.
# Sampling with `top` adds a little system load but does not charge that CPU to QuotaBar.

duration="${1:-300}"
process_name="${QUOTABAR_PROCESS_NAME:-QuotaBar}"

if [[ ! "$duration" =~ ^[1-9][0-9]*$ ]]; then
  printf 'usage: %s [seconds] (positive integer)\n' "$0" >&2
  exit 2
fi
if ! pgrep -x "$process_name" >/dev/null 2>&1; then
  printf 'no running %s process; launch the app first\n' "$process_name" >&2
  exit 1
fi

samples="$(mktemp)"
sorted="$(mktemp)"
trap 'rm -f "$samples" "$sorted"' EXIT

printf 'Sampling %s for %ss at 1 Hz (%% of one core, all matching processes).\n' \
  "$process_name" "$duration"

# `top`'s first sample is a lifetime average, so request one extra and drop it. Each
# "Processes:" header starts a new sample; the per-process rows follow it. A scan worker
# shares the executable name, so summing every matching row includes its CPU.
started="$(date +%s)"
top -l "$((duration + 1))" -s 1 -stats pid,cpu,command 2>/dev/null \
  | awk -v name="$process_name" '
      /^Processes:/ {
        if (sample >= 1) print sum
        sample++
        sum = 0
        next
      }
      $3 == name && $1 ~ /^[0-9]+$/ { sum += $2 }
      END { if (sample >= 1) print sum }
    ' \
  | tail -n +2 > "$samples"
finished="$(date +%s)"
elapsed=$((finished - started))
if ((elapsed < 1)); then elapsed=1; fi

if [[ ! -s "$samples" ]]; then
  printf 'no CPU samples collected; is %s still running?\n' "$process_name" >&2
  exit 1
fi

sort -n "$samples" > "$sorted"
# Sliding-window peaks answer the question a sustained ceiling actually asks: a one-second
# sample can cross 2% for an unavoidable 0.02 s burst, while a 30 s or 60 s window only
# crosses it when the app is genuinely busy for that long.
awk '
  { v[NR] = $1; sum30 += $1; sum60 += $1
    if (NR > 30) sum30 -= v[NR - 30]
    if (NR > 60) sum60 -= v[NR - 60]
    if (NR >= 30 && sum30 / 30 > max30) max30 = sum30 / 30
    if (NR >= 60 && sum60 / 60 > max60) max60 = sum60 / 60
  }
  END {
    printf "QUOTABAR_CPU_WINDOWS samples=%d max_30s_pct=%.2f max_60s_pct=%.2f\n", NR, max30, max60
  }
' "$samples"
awk -v elapsed="$elapsed" '
  { v[NR] = $1; sum += $1; if ($1 > max) max = $1 }
  END {
    n = NR
    if (n == 0) { print "no samples collected" > "/dev/stderr"; exit 1 }
    median = (n % 2 ? v[(n + 1) / 2] : (v[n / 2] + v[n / 2 + 1]) / 2)
    p95Index = int(n * 0.95)
    if (p95Index < 1) p95Index = 1
    # Each sample is a percentage over roughly one second, so the sum in percent-seconds
    # divided by actual wall time is the CPU-time-weighted mean (per-core percent).
    printf "QUOTABAR_CPU_BENCH window_s=%d samples=%d mean_pct=%.2f median_pct=%.2f p95_pct=%.2f max_pct=%.1f\n", \
      elapsed, n, sum / elapsed, median, v[p95Index], max
  }
' "$sorted"
