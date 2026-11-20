#!/usr/bin/env bash
# Measures QuotaBar's refresh CPU as a percentage of one core.
#
# The refresh targets are stated per pass: at most 5% of one core while the app is active, and at
# most half of that while it is in the background. `ps`'s %CPU is a lifetime average and cannot see
# a 2-second spike inside a 16-hour session, so this samples the process's own cumulative CPU time
# (user + system, the app plus any `--scan-worker` helper child) once a second and reports the
# measured deltas. That makes the number reproducible: same window, same panel state, same math.
#
# Usage:
#   script/measure_cpu.sh --seconds 300 --panel closed --label "background steady state"
#   script/measure_cpu.sh --seconds 90  --panel closed --force-refresh --label "background full pass"
#   script/measure_cpu.sh --seconds 300 --panel open   --label "panel-open steady state"
#
# Options:
#   --seconds N      sampling window in seconds (default 300)
#   --interval S     sample period in seconds; 1 s is the practical floor (default 1)
#   --panel STATE    open|closed: drive the dashboard panel through script/diagnose.sh beforehand
#   --warmup N       seconds to wait after the panel change before sampling (default 5)
#   --trigger KIND    none|background|diagnostic (default none). `background` posts the documented
#                     com.quotabar.refresh distributed trigger (the periodic loop's own full pass);
#                     `diagnostic` posts script/diagnose.sh refresh (forced, includes catalog reload)
#   --trigger-every S repeat the trigger every S seconds inside the window (0 = once, at start)
#   --app PATH       app executable (default /Applications/QuotaBar.app/Contents/MacOS/QuotaBar)
#   --trace          print each sample as `elapsed_s cpu_percent`
#   --split          also report the app process and its `--scan-worker` children separately
#   --label TEXT     label printed with the summary
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
app_exe="/Applications/QuotaBar.app/Contents/MacOS/QuotaBar"
seconds=300
interval=1
panel=""
warmup=5
force_refresh=0
trigger="none"
trigger_every=0
trace=0
split=0
label=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --seconds) seconds="${2:?--seconds needs a value}"; shift 2 ;;
    --interval) interval="${2:?--interval needs a value}"; shift 2 ;;
    --panel) panel="${2:?--panel needs a value}"; shift 2 ;;
    --warmup) warmup="${2:?--warmup needs a value}"; shift 2 ;;
    --force-refresh) force_refresh=1; shift ;;
    --trigger) trigger="${2:?--trigger needs a value}"; shift 2 ;;
    --trigger-every) trigger_every="${2:?--trigger-every needs a value}"; shift 2 ;;
    --app) app_exe="${2:?--app needs a value}"; shift 2 ;;
    --trace) trace=1; shift ;;
    --split) split=1; shift ;;
    --label) label="${2:?--label needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

for value in "$seconds" "$interval" "$warmup" "$trigger_every"; do
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    printf 'seconds, interval and warmup must be whole numbers (got %s)\n' "$value" >&2
    exit 2
  fi
done
if (( interval < 1 || seconds < interval )); then
  printf 'need interval >= 1 and seconds >= interval\n' >&2
  exit 2
fi
case "$panel" in
  ""|open|closed) ;;
  *) printf -- '--panel must be open or closed\n' >&2; exit 2 ;;
esac
case "$trigger" in
  none|background|diagnostic) ;;
  *) printf -- '--trigger must be none, background or diagnostic\n' >&2; exit 2 ;;
esac
if [[ ! -x "$app_exe" ]]; then
  printf 'app executable not found: %s\n' "$app_exe" >&2
  exit 1
fi

# One process per matching command line: the app and its scan-worker child share this executable
# path, and an unrelated `QuotaBar` name match must not leak into the sum.
find_pid() {
  ps -Ao pid=,args= | awk -v exe="$app_exe" '
    $2 == exe || index($0, exe " ") == (length($1) + 2) { print $1; exit }
  '
}

pid="$(find_pid || true)"
if [[ -z "$pid" ]]; then
  printf 'QuotaBar is not running (%s)\n' "$app_exe" >&2
  exit 1
fi

# Cumulative CPU seconds for the app and its helpers, in one `ps` pass.
# Prints "total parent worker": the scan-worker child runs the fold, so splitting it out shows how
# much of a pass is parse work in a child versus orchestration in the menu-bar process itself.
cpu_tuple() {
  ps -Ao pid=,cputime=,args= | awk -v exe="$app_exe" '
    function seconds(field,   day, parts, n, total) {
      day = 0
      if (index(field, "-") > 0) {
        split(field, parts, "-")
        day = parts[1] + 0
        field = parts[2]
      }
      n = split(field, parts, ":")
      total = day * 86400
      if (n == 3) total += parts[1] * 3600 + parts[2] * 60 + parts[3]
      else if (n == 2) total += parts[1] * 60 + parts[2]
      else total += parts[1]
      return total
    }
    {
      args = ""
      for (i = 3; i <= NF; i++) args = args (i > 3 ? " " : "") $i
      if (args == exe || index(args, exe " ") == 1) {
        value = seconds($2)
        total += value
        if (index(args, "--scan-worker") > 0) worker += value
        else parent += value
      }
    }
    END { printf "%.2f %.2f %.2f\n", total, parent, worker }
  '
}

# diagnose.sh filters on the bundle id, which the installed bundle declares; fall back to the
# production id so a moved app path does not silently drive nothing.
bundle_id() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$(dirname "$(dirname "$(dirname "$app_exe")")")/Contents/Info.plist" 2>/dev/null \
    || printf 'com.tverma101.quotabar'
}

if [[ "$panel" == "open" || "$panel" == "closed" ]]; then
  if [[ "$panel" == "open" ]]; then
    BUNDLE_ID="$(bundle_id)" "$repo_root/script/diagnose.sh" show >/dev/null
  else
    BUNDLE_ID="$(bundle_id)" "$repo_root/script/diagnose.sh" close >/dev/null
  fi
  printf '==> panel %s (%s)\n' "$panel" "$(bundle_id)"
fi
if (( warmup > 0 )); then
  sleep "$warmup"
fi

samples="$(mktemp)"
cleanup() { rm -f "$samples"; }
trap cleanup EXIT

# Both triggers are documented, in-product entry points (docs/refreshing.md): the distributed
# com.quotabar.refresh name drives the periodic loop's own full pass, diagnose.sh refresh drives its
# forced diagnostic pass. Neither needs the dashboard panel on screen.
post_trigger() {
  case "$trigger" in
    background)
      swift - <<'SWIFT' >/dev/null 2>&1
import Foundation
DistributedNotificationCenter().postNotificationName(
    Notification.Name("com.quotabar.refresh"), object: nil, deliverImmediately: true)
SWIFT
      ;;
    diagnostic)
      "$repo_root/script/diagnose.sh" refresh >/dev/null 2>&1
      ;;
    none) ;;
  esac
}

start_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if (( force_refresh )); then
  trigger="diagnostic"
  post_trigger
  trigger="none"
elif [[ "$trigger" != "none" ]]; then
  post_trigger
fi

previous="$(cpu_tuple)"
printf '==> sampling pid %s every %ss for %ss%s\n' \
  "$pid" "$interval" "$seconds" "${label:+ ($label)}"

elapsed=0
while (( elapsed < seconds )); do
  sleep "$interval"
  current="$(cpu_tuple)"
  awk -v e="$elapsed" -v p="$previous" -v c="$current" -v s="$interval" 'BEGIN {
    split(p, before, " ")
    split(c, after, " ")
    total = after[1] - before[1]
    parent = after[2] - before[2]
    worker = after[3] - before[3]
    if (total < 0) total = 0
    if (parent < 0) parent = 0
    if (worker < 0) worker = 0
    printf "%.1f %.2f %.2f %.2f\n", e + s, total / s * 100, parent / s * 100, worker / s * 100
  }' >>"$samples"
  previous="$current"
  elapsed=$(( elapsed + interval ))
  if (( trigger_every > 0 )) && (( elapsed < seconds )) && (( elapsed % trigger_every == 0 )); then
    post_trigger
  fi
done

end_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Each sample is a percentage of one core; percentage-seconds / 100 is CPU-seconds.
total_cpu="$(awk -v s="$interval" '{ total += $2 } END { printf "%.2f", total * s / 100 }' "$samples")"
parent_cpu="$(awk -v s="$interval" '{ total += $3 } END { printf "%.2f", total * s / 100 }' "$samples")"
worker_cpu="$(awk -v s="$interval" '{ total += $4 } END { printf "%.2f", total * s / 100 }' "$samples")"

if (( trace )); then
  printf '\n%s\n' "second cpu_percent"
  awk '{ printf "%6.0f %6.2f\n", $1, $2 }' "$samples"
  printf '\n'
fi

# Percentiles from a numerically sorted copy; BSD awk has no asort().
sorted="$(mktemp)"
awk '{ print $2 }' "$samples" | sort -n >"$sorted"
awk -v label="$label" -v window="$seconds" -v interval="$interval" \
    -v total="$total_cpu" -v first="$start_iso" -v last="$end_iso" -v pid="$pid" '
  { values[NR] = $1 }
  END {
    n = NR
    if (n == 0) { print "no samples"; exit 1 }
    sum = 0
    for (i = 1; i <= n; i++) {
      sum += values[i]
      if (values[i] > values[max]) max = i
      if (values[i] > 5.0) over5++
      if (values[i] > 25.0) over25++
    }
    mean = sum / n
    median = (n % 2) ? values[(n + 1) / 2] : (values[n / 2] + values[n / 2 + 1]) / 2
    p95 = values[int(n * 0.95) < 1 ? 1 : int(n * 0.95 + 0.999)]
    printf "\n==> QuotaBar CPU%s\n", (label == "" ? "" : " — " label)
    printf "    window      %s .. %s (%ss, %ss samples, pid %s)\n", first, last, window, interval, pid
    printf "    mean        %6.2f%% of one core\n", mean
    printf "    median      %6.2f%%\n", median
    printf "    p95         %6.2f%%\n", p95
    printf "    peak (1 s)  %6.2f%%\n", values[max]
    printf "    total CPU   %6.2f CPU-seconds\n", total
    printf "    samples     %d, above 5%%: %d, above 25%%: %d\n", n, over5, over25
  }
' "$sorted"

if (( split )); then
  awk -v parent="$parent_cpu" -v worker="$worker_cpu" 'BEGIN {
    printf "    split       app %.2f CPU-seconds, --scan-worker children %.2f CPU-seconds\n", parent, worker
  }'
fi
rm -f "$sorted"
