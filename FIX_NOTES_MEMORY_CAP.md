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

Idle settled footprint should stay near prior unload-mode levels (~100–250 MB). Peaks during
cold parse may still rise, but must not unbounded-climb across refreshes.
