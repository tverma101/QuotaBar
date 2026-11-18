# CPU Measurement & Baseline

How to observe QuotaBar's CPU, and what the current build measures. The target is a per-process
ceiling expressed the way Activity Monitor shows it: **percent of one CPU core**, not percent of the
whole machine.

## What runs

- `/Applications/QuotaBar.app/Contents/MacOS/QuotaBar` — the menu-bar app.
- `QuotaBar --scan-worker …` — a short-lived child that folds local corpora during an accounting pass.
  It shares the executable name, so its CPU belongs to the app's total. Summing only the parent would
  miss the fold.

While the panel is closed the app:

- refreshes live quota meters every minute on AC (every two minutes on battery / Low Power Mode);
- folds local spend history every fifteen minutes (five while the panel is open, or when iCloud Sync
  is enabled);
- runs no dashboard timers or animation loops — the dashboard content mounts only while visible.

Opening the panel adds the visible countdowns, a one-minute meter cadence, and five-minute folds.
A manual Refresh and the CLI use the interactive CPU budget (25% of one core) rather than the
background allowance.

## Method

```sh
./script/measure_cpu.sh [seconds]     # default: 300
```

The script runs `top -l N -s 1`, sums every process named `QuotaBar` in each sample, and drops
`top`'s first sample because it is a lifetime average. It reports:

- **mean** — CPU-time divided by actual wall time, i.e. the sustained reading;
- **median**, **p95**, **max** — the distribution of one-second samples.

No root or `powermetrics` is needed, and `top`'s own CPU is not charged to the app.

### Reading the 2% ceiling

- **Sustained (CPU-time / wall) ≤ 2%** is the useful background-app ceiling. This build is well under it.
- **Every one-second sample ≤ 2%** is much stricter: a 0.02 s burst inside one second reads as 2%.
  The one-minute meter pass briefly crosses that line even when the app is healthy (see below).
  A 10-second or 60-second rolling average is the fairer "spike" measure at this scale.

## Baseline

Measured 2026-11-17 on commit `8422c3f5` plus the refresh-loop wake-policy fix, macOS 27.2.1,
Apple M4 (10 cores), 16 GB, release build, installed app, panel closed, no interaction.

| Window | Mean | Median | p95 | Max (1 s) |
|---|---:|---:|---:|---:|
| 5 minutes, closed panel, no fold in the window | 0.35% | 0.0% | 2.6% | 6.0% |

The mean is about 1.1 CPU-seconds over five minutes. The peaks are the one-minute meter passes
(roughly 0.6–1.4 s of wall each), not a steady load.

## Known exception: the fifteen-minute fold can livelock

A fifteen-minute history fold can enter a deferred-refresh feedback loop. While the accounting batch
holds provider tasks, a one-minute meter pass is deferred; every provider task that ends emits a
"ready" wake, the loop retries, and the batch defers it again. Measured on 2026-11-17: the parent held
**68–91% of one core for 48–74 seconds**, with thousands of 0 ms deferred retries in the log.

The wake-timeout and task-lifetime fixes in this change remove two secondary spins (a zero-timeout
poll and a cleanup-window spin) but do not break the feedback loop. That needs a store-level fix in
`WidgetDataStore`'s deferred-refresh emission. Until then the 2% ceiling holds for idle/meter-only
operation and is violated during a fold.

## What this baseline does not cover

- **Launch.** The first pass does a cold local fold and a launch-time account scan; expect a
  multi-second burst well above the idle figure. The ceiling applies after the app settles.
- **Panel open.** Visible countdowns and five-minute folds are active work.
- **Manual Refresh / CLI.** These intentionally use the 25% interactive budget so a user-facing pass
  finishes inside the provider deadline.
- **TPS.** The TPS Tracker is not part of this branch's build. Its fold reads seven local corpora and
  must be re-baselined after it is integrated; it shares parse caches but still walks the cached
  events for each corpus on every accounting pass.
