# Codex and Orca account isolation

## Symptom

OpenUsage showed unexpectedly combined Codex usage, and two local Codex homes appeared to be sharing session history. The visible account cards were not a safe indication of separate billing identities.

## Confirmed causes

1. The user launchd environment exported `CODEX_HOME` and `ORCA_CODEX_HOME` to Orca's managed account home. A child process could therefore inherit Orca's home even when it was not launched by an Orca terminal.
2. Orca's session backfill marker was still active with a pending scan date. Its runtime home had hard-linked 285 rollout files into `/Users/tejas/.codex/sessions`, coupling later file changes across the two roots.
3. OpenUsage rejected the implicit home only when the Orca marker was also present. A stale shell snapshot or launch service could provide the path without the marker, and the marker itself was not persisted in the shell identity snapshot. Orca can also place its managed homes under a custom `ORCA_USER_DATA_PATH`.
4. The default Codex auth file and Orca's managed auth file identify the same provider account. Different token rotations or local paths do not turn that into a second billed account.
5. A scoped provider previously relied primarily on its provider-level identity check. A stale or malicious home override could still make the underlying auth store read the other account before the provider rejected it, and conflicting account metadata could be trusted field-by-field.

## Repair

- `OpenUsageEnvironmentReader` rejects both `Library/Application Support/orca/codex-accounts` and `Library/Application Support/orca/codex-runtime-home` paths, including symlink-resolved paths, rejects the corresponding paths below `ORCA_USER_DATA_PATH`, and rejects any non-empty `ORCA_CODEX_HOME` overlay.
- The same reader filters managed Orca homes out of inherited `OPENUSAGE_CODEX_HOMES` lists. A deliberately registered Orca home remains opt-in, but it cannot augment an earlier source carrying the same provider identity.
- Unscoped Codex auth, log, proxy, and default-observer construction uses that reader. Explicit account registrations continue through `OverrideEnvironmentReader`, which pins the selected home deliberately.
- Every scoped `CodexAuthStore` is bound to its card identity. It drops wrong-account file/Keychain candidates, rejects an `account_id`/JWT identity conflict, and refuses to persist a mismatched refreshed state. `ProviderCatalog` pins the card's auth and log homes independently of the ambient process environment.
- `ORCA_CODEX_HOME` and `ORCA_USER_DATA_PATH` are now included in the non-secret shell identity snapshot, so a stale snapshot cannot silently lose the evidence that the process is an Orca overlay or its custom root.
- The stale backfill marker was saved as `backfill-complete.json.pre-isolation-20260912`, then set to `launchActive: false` with no pending scan dates.
- The 285 shared runtime/default rollout files were copied in place and atomically replaced, then the 285 audit-proven historical copies were moved from `~/.codex/sessions` into recoverable quarantine at `/Users/tejas/.codex/archives/orca-backfilled-sessions-20260912`. No rollout or credential file was deleted. Two remaining runtime/account hardlinks are internal to Orca's own managed/runtime pair and are not linked to the default Codex root.
- The user launchd exports were unset. This affects future processes; it cannot rewrite the environment of a process that is already running.

## Validation

- Focused isolation suite: 52 tests, 0 failures.
- Full OpenUsage suite: 1,372 tests, 3 skipped, 0 failures.
- Installed OpenUsage CLI: two non-stale Codex cards, `errors: []`, from a clean app launch; invoking the CLI from the old contaminated parent shell still resolved the default card through the sanitizer.
- Filesystem audit: zero runtime/default shared rollout inodes; zero open default-tree rollout files; zero rollout files remain in the default tree; 285 audit-proven files are in recoverable quarantine; no standalone Orca app process is running. The current Codex task is intentionally open under the Orca account home and does not touch the default tree.
- Auth audit: auth files remain regular private files with distinct filesystem inodes; account identity was compared by metadata only and no token contents were logged.

## Residual boundary

The current Codex task was already running under the old inherited environment and remains open under the Orca managed home. It was intentionally left untouched to avoid terminating the active session. Restart ChatGPT/Codex before relying on the current process as proof of a clean inherited environment. A different provider billing identity still requires a separate OAuth login.
