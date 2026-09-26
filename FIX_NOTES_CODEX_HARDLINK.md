# OpenUsage Codex cost double-counting fix

## Bug

With two Codex accounts (default `~/.codex` + an Orca/managed home), Orca had
**hardlinked** session rollouts across both trees (same size + same inode).
Live inventory showed hundreds of overlapping Desktop sessions.

Confirmed direction on Tejas's machine: Orca **backfilled from** `~/.codex`
**into** the managed orca home (`systemSessionsRoot: ~/.codex/sessions`), not
the other way around.

What went wrong with the first attribution pass:

1. Code preferred managed/non-default for shared inodes and made **default skip
   peer hardlinks**.
2. That moved ~266 Desktop sessions onto account #2 and left default with a thin
   residual (~84 files / ~$36) while the API still showed heavy default use.
3. Estimated costs were wrong per account (default too low, managed too high).

## Fix (correct direction)

### `CodexLogUsageScanner.sessionFiles`

- Params: `peerHomes: [URL] = []` and `homeDirectory` (to identify default
  `~/.codex`).
- Collect `(st_dev, st_ino)` for every `*.jsonl` under each peer home's
  `sessions/` and `archived_sessions/` (via `AppendOnlyFileProbe` / `lstat`).
- When enumerating a **non-default / managed** home, **skip** any file whose
  inode is in that peer set (hardlinks shared with `~/.codex`).
- When enumerating default `~/.codex`, **do not** skip peer hardlinks — keep
  shared inodes on default.
- Across all homes in one scan: **dedupe by inode**. Default homes are
  processed first so the kept path is `~/.codex` when both appear in `homes`.
- `DiscoveredFile` cache fields are unchanged (path/size/mtime only).

Skip condition (invert of the old rule):

`skipPeerHardlinks = !isDefaultCodexHome && !peerInodes.isEmpty`

### Scanner wiring

- `peerHomes` is stored on `CodexLogUsageScanner` (init param, default `[]`).
- `scan` / `parsedEvents` pass `peerHomes` + `homeDirectory` into
  `sessionFiles`.

### `ProviderCatalog.make`

- For each Codex card, `peerHomes` = every **other** card's `logHomes` (or
  `[home]` if `logHomes` is empty) — still wired both ways.
- Auth env unchanged (single `CODEX_HOME`).
- Log env still comma-joined `logHomes`.

### `OpenCodeUsageScanner` gateway fold

- `partitionCodexHomes` splits managed vs default.
- Scan **default first** with no peer stripping.
- Scan **managed** with `peerHomes` = default homes so shared hardlinks are not
  double-folded into OpenCode.

## Attribution after the fix

| Card | Scans | peerHomes effect |
|------|-------|------------------|
| Account #1 (default `~/.codex`) | its logHomes | keeps shared hardlinks (does not skip peer inodes) |
| Account #2 (Orca/managed) | its logHomes | skips inodes that also exist under peer `~/.codex`; prices only-orca / native managed sessions |

Same inode appearing under both homes in one scan → counted once, preferred path = default `~/.codex`.

## Tests

- `testSessionFilesDefaultKeepsHardlinksSharedWithPeerManagedHome`
- `testSessionFilesManagedKeepsNativeOnlySessions`
- `testSessionFilesDedupesInodePreferringDefaultHome`
- `testPartitionPlusPeerHomesManagedSkipsDefaultHardlinks`
- `testProviderCatalogWiresPeerHomesAcrossCodexCards`

## Build note

Run on Tejas's Mac: `swift test --filter 'CodexLogUsageScannerTests|CodexMultiAccountTests|OpenCodeUsageScannerTests'`
then `BUNDLE_ID=com.robinebers.openusage CONFIG=release ./script/build_and_run.sh run`.
