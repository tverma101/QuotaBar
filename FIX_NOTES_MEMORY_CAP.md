# Memory cap — keep OpenUsage under ~0.5 GB

## Problem
With multi-GB Codex session corpora (~13 GB on this machine), concurrent Codex + OpenCode
refreshes could build giant `[Event]` / `[Entry]` arrays (scanner return + sharedTailCache),
pushing physical footprint past 1 GB even after prior unload-after-refresh work.

## Design
1. **ProcessMemoryBudget** — soft 320 MB / hard 480 MB `phys_footprint` ceilings.
2. **Streaming `foldItems`** — IncrementalJSONLScanner visits rows per file without concatenating
   a mega-array; Codex/Claude/OpenCode production paths use folds.
3. **Tighter tail-cache caps** — sharedTailCache maxEntries 128, maxRetainedItems 8_000.
4. **Unload between heavy providers and Codex homes** — WidgetDataStore + OpenCode per-home unload.
5. **OS memory-pressure source** — warning/critical triggers `unloadForMemoryPressure`.
6. **Hard-limit serialization** — refreshAll runs one provider at a time when over hard limit.

## The dominant cost was autorelease pools, not retained data

A cold scan peaked at **1,817 MB** of `phys_footprint` while *live heap was ~25 MB* and the largest
array the app owned was 1.06 MB. The gap was Foundation buffers the process had already finished
with. `leaks --autoreleasePools` on a live scan measured **1,025 MB across 13,126 `NSConcreteData`**
sitting in pools.

`JSONLFileReader.deliver` already wrapped `body(line)` in a pool, but `NSFileHandle.read` is called
from the *chunk loop*, outside it. Each call autoreleases an ~80 KB buffer (Foundation rounds the
64 KB request up to 81,920 bytes), so every buffer a file allocated piled into the pool the caller
opened around the whole parse and only drained at end-of-file. Giving each chunk its own pool fixed it.

Measured, same 9.8 GB / 290-file corpus:

| | Before | After |
|---|---|---|
| CLI cold scan | 1,817 MB | **536 MB** |
| CLI warm scan | 270 MB | **63 MB** |
| App settled, popover closed | 603 MB | **104 MB** |
| App peak, popover open | 982 MB | **233 MB** |
| Soft-limit hits per full batch | 4 | **0** |

The 320/480 MB ceilings are now meaningful rather than continuously exceeded.

### Ruled out by measurement, not assumption

Worth recording so they are not retried:

- **Serialising provider refreshes past the soft limit** — 1,768 vs 1,817 MB. Noise. A single Codex
  fold dominates; concurrency is a secondary effect.
- **`malloc_zone_pressure_relief`** — no effect, at cycle end or per file, because the pages are not
  free. The API is also documented as releasing little or nothing on modern macOS.
- **Owning-copying parser strings** — peak unchanged, warm path 7x worse.
- **Shrinking `chunkSize` to 16 KB** — peak unchanged. Total buffer bytes scale with corpus size,
  not buffer count, so this could never have been the fix.

Idle settled footprint should stay near prior unload-mode levels (~100–250 MB). Peaks during
cold parse may still rise, but must not unbounded-climb across refreshes.
