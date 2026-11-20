# Refresh CPU budget

The menu-bar app has a stated ceiling: a refresh may use at most **5% of one core while the app is
active**, and the background state must be **at least 50% lower** (≤2.5% of one core). This page
records the measured baseline, how to reproduce it, and where the CPU actually goes.

Numbers below are from the maintainer's 10-core M4 MacBook on AC power, macOS 27.2.1, against the
`0.7.0` build installed at `/Applications/QuotaBar.app` with all eight enabled providers
(Antigravity, Claude, Codex ×2, Cursor, Freebuff, OpenCode, Z.ai) and debug logging on. They are a
starting point for comparison, not a promise for other machines or provider mixes.

## How to measure

`script/measure_cpu.sh` samples the process's own cumulative CPU time once a second and reports the
deltas, so a short spike inside a long session is visible. `ps`'s `%CPU` is a lifetime average and
cannot show one.

```sh
# Background steady state (panel closed, scheduled ticks only).
script/measure_cpu.sh --seconds 360 --panel closed --label "background steady state"

# One full refresh pass, driven through the documented background trigger.
script/measure_cpu.sh --seconds 100 --trigger background --split --label "background full pass"

# The same pass at per-provider granularity, without touching the running app's scheduler.
/usr/bin/time -p /Applications/QuotaBar.app/Contents/MacOS/QuotaBar \
  --scan-worker --providers opencode --scope panel-accounting
```

`--panel open` exists for measuring the dashboard, but it puts the panel on screen; prefer
`--trigger background`, which drives the periodic loop's own full pass with the panel closed.

`--split` separates the menu-bar process from its `--scan-worker` children. That split is the most
important number on this page: fold work happens in the children, not in the app process.

## Baseline (before any change)

| State | Window | Mean | Peak (1 s) | CPU-seconds |
|---|---|---|---|---|
| Background steady state, panel closed | 360 s | **0.23%** | 5.0% | 0.81 |
| Background full pass (trigger) | 100 s | 1.16% | **53%** | 1.16 |
| — of which the app process | | | | 0.26 |
| — of which `--scan-worker` children | | | | **0.92** |
| Forced diagnostic pass (all providers, catalog reload) | 120 s | 3.92% | **78%** | 4.70 |
| Same build re-measured after rebuild + install | 180 s | 0.50% | 37% | 0.90 |

The last row is a confirmation run, not a new state: the app had just been rebuilt and installed, a
launch-time fold was still finishing in a `--scan-worker` child when the window opened, and that
child is the 37% second. Everything else matches the steady-state row.

Background steady state is comfortably inside the target. A full pass is not: it averages ~2% over
a minute, but it reaches 53–78% of a core for one to several seconds inside the pass. If the ceiling
is read as instantaneous — which "max 5%" implies — a pass misses it by roughly 10–15×.

Two distinct causes, both measured:

1. **Fold work is bursty.** 79% of a pass's CPU is the `--scan-worker` child folding local corpora
   at full speed. The scheduler's own 7.5%-of-one-core pacing does not cover these child folds.
2. **The scheduler can spin.** On 2026-11-17T19:39:44Z the log recorded **1,766 empty refresh
   batches in under one second**. A provider still in flight defers the request, the deferred
   request is re-emitted the moment that flight ends, the retry finds another overlapping task, and
   the pair repeats with no backoff. That is a full core for as long as the overlap lasts, and it
   dwarfs every other CPU cost in the app. The same shape appeared before (9,652 batch starts in the
   rotated log).

## After the re-emit fix

The deferred-request livelock is fixed: readiness now uses the same rule as the deferral, and one
provider's emissions are coalesced behind a short cooldown. Measured on the rebuilt and installed
app:

| State | Mean | p95 | Peak (1 s) | CPU-seconds | Over 5% |
|---|---|---|---|---|---|
| Background steady state, 180 s | **0.34%** | 2.00% | 5.00% | 0.61 | 0 of 180 |
| Active full pass, 100 s | 3.12% | 14.00% | 83% | 3.12 | 8 of 100 |

- **Storm gone.** The log held 1,766 batch starts in one second before the fix; after it, 13 starts
  in seven minutes and never more than one in the same second.
- **Cadence unchanged.** Menu-bar passes landed 63 s and 61 s apart against the 60 s tick.
- **Background target met:** 0.34% against a 2.5% cap.
- **The active peak is unchanged and is not the spin.** 2.75 of the pass's 3.12 CPU-seconds are the
  `--scan-worker` child, so a single second still reaches ~80% while a fold runs. Holding the 5%
  instantaneous ceiling needs the fold paced or the parser ported — this fix removes the full-core
  event, not the burst.

## When it runs

| Wake | Cadence (panel closed, AC) | Work |
|---|---|---|
| Quota tick | every 60 s (120 s on battery / Low Power Mode) | pinned providers' live meters |
| History fold | every 15 min (5 min with the panel open) | local accounting via `--scan-worker` |
| CodexRouter ledger wake | about every 15 s | watched, then usually ignored when no spend is pinned; still runs cache unload and allocator page release |

The 15-second ledger wake is why a closed app is not at 0.00%: it is cheap per wake but it never
stops, and it is the reason the background number is reported as a rate rather than a floor.

## Where the CPU goes

Cold fold cost per provider, measured by running each provider's scan worker directly
(`--scan-worker --providers <id> --scope panel-accounting`):

| Provider | CPU-seconds | Wall | Bound by |
|---|---|---|---|
| **OpenCode** | **2.46–2.55** | 2.5 s | CPU |
| Claude | 1.22–1.29 | 1.2 s | CPU |
| Freebuff | 1.02 | 66 s | network |
| Cursor | 0.94 | 12 s | network |
| Codex (second account) | 0.78 | 0.8 s | CPU |
| Antigravity | 0.50 | 0.6 s | CPU |
| Codex | 0.47 | 0.4 s | CPU |
| Z.ai | 0.40 | 1.0 s | subprocess |

OpenCode is the hottest CPU-bound fold and the only one that is both expensive and fully CPU-bound.

Thread-level attribution was not obtained: `ps -M` omits short-lived threads, and `sample` counts
blocked threads the same as running ones, so both overstate the main thread. The per-provider and
per-stage numbers above come from the products themselves and are what the port decision rests on;
Instruments' Time Profiler is the tool to reach for if thread-level detail is ever needed.
Its own stage log splits the time:

```
opencode scan stages total=1607ms [sqlite=852ms accumulate=87ms claudeFold=645ms codexFold=21ms]
```

`claudeFold` is the fold of CodexRouter's append-only ledger
(`~/.codex/codex-router/usage-events.jsonl`, **25.6 MB / 57,764 lines** on this machine). It is a
per-line JSON parse driven by `CodexRouterEventLineParser`, a hand-written Swift byte scanner, and
it is shared by OpenCode's ledger fold and Codex's router fold. Claude's and Codex's own rollout
parsers already have Rust ports, which is why they cost roughly half as much per byte.

## Porting plan: CodexRouter ledger line parser → Rust

**Slice.** Only `CodexRouterEventLineParser` (one line in, one validated `Event`/row out) and the
day/model accumulation that consumes its output. Not the provider clients, not the SQLite reads, not
the dashboard.

**Why this slice.** It is on the measured hot path (621–896 ms per OpenCode fold, 34% of the cold
fold CPU), it is CPU-bound while Cursor/Freebuff are network-bound, and it is a pure
bytes-in/values-out function — the shape the existing crate already handles safely.

**Why not the whole widget.** Cursor and Freebuff are waiting on the network; Z.ai shells out to
`sqlite3`; OpenCode's `sqlite=` stage is I/O. Porting them buys nothing. The scheduler spin is a
control-flow bug and must be fixed in Swift, not ported.

**Mechanism**, following `docs/rust-core.md`:

1. Add `qb_router_line_parse` to `Rust/quotabar-core/src/` with a line buffer in, a packed
   `{date, model, provider, status, input, cached, output, reasoning, total, account flags}` out, or
   a null result for every input it cannot resolve.
2. Add `Sources/QuotaBar/Support/CodexRouterLineRustParser.swift` as the bridge, mirroring
   `CodexRolloutRustParser`: Rust first for a full parse, Swift fallback on any decline, one engine
   per file — never mixed.
3. Keep the existing Swift parser untouched as the oracle and add a parity suite over the real
   ledger corpus plus synthetic edge cases (malformed rows, future timestamps, 64-byte timestamp
   cache, oversized lines).
4. Reuse the existing benchmark hook
   (`QUOTABAR_CODEX_PARSE_BENCH`-style) to report Rust vs Swift CPU on the same 25 MB corpus.

**Expected effect.** The existing ports measured ~4.6× (Codex rollout) to ~10× (Claude lines) less
CPU for the same parse. Applying the conservative 4.6× to the measured 621–896 ms fold would cut
roughly 0.4–0.5 CPU-seconds per OpenCode pass — around 40% of the pass's child CPU. It does **not**
by itself hold the instantaneous peak under 5%; that also needs the scheduler spin fixed and the
fold paced (the pacing already exists for closed-panel wakes and can be extended to these children).

**Acceptance for the port.** `script/measure_cpu.sh --seconds 100 --trigger background --split`
shows the same-or-lower peak and a lower child CPU total than the baseline row above, with the full
test suite green.

**Sequencing.** Fix the deferral spin first — it is a one-line-class control-flow fix and it removes
the only path that reaches a full core. Then port the ledger parser, then extend pacing to the fold
children; only after all three can the 5% instantaneous ceiling be claimed with a measurement.

## Rebuild and install

The installed app uses the production bundle id without a provisioning profile, so a local build
must be installed with that id explicitly (`RELEASE=1` would demand a release tag at HEAD):

```sh
# One-time after cloning, and whenever the Rust core changes.
bash script/build_rust_core.sh

# Build + stage + sign into dist/QuotaBar.app (no install).
./script/build_and_run.sh build

# Replace /Applications/QuotaBar.app with this build and relaunch it.
BUNDLE_ID=com.tverma101.quotabar ./script/build_and_run.sh install

# Verify the running copy, then re-measure.
pgrep -fl "/Applications/QuotaBar.app/Contents/MacOS/QuotaBar"
script/measure_cpu.sh --seconds 360 --panel closed --label "background steady state (after)"
```

`install` refuses to replace a bundle with a different identity, verifies the signature before and
after the move, restores the previous bundle if the new one does not start, and stops only the exact
bundle paths.
