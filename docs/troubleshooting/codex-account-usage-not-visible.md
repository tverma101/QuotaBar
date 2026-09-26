# Codex account signed in but usage card missing

## Scope

- `scope`: additional Codex account registration, same-session card discovery, and one aggregate menu-bar panel
- `project`: OpenUsage
- `status`: fixed, installed, and live-smoke verified; visual dashboard confirmation pending
- `last_verified`: 2026-09-12
- `canonical_doc`: `docs/providers/codex.md`, `docs/settings.md`
- `rollout_refs`: `docs/codex/turn-log.md`; rollout `019ff8e3-8bd3-7e43-8bd5-bdfa77e83ad9`

## Symptom

Codex browser sign-in completed and wrote an isolated `auth.json`, but the new account did not appear in the running OpenUsage dashboard or refresh logs.

## Previous root cause

OpenUsage built `ProviderCatalog`, `WidgetRegistry`, `LayoutStore`, and `WidgetDataStore` once at launch. Registration persisted the new home, but the existing process retained the old provider graph, so it could not create the account-scoped provider or its card until a restart. The first per-account status-item implementation then split one shared usage surface into multiple status items, which made an account look like a duplicate app and could open a panel focused on only one card.

## Accounting gap found after the previous fix

The account card could exist while its registered Codex home contained no native session JSONL. In the
live setup, those requests were routed through FCC, whose older ledger rows had no account fingerprint,
so OpenUsage had no safe source to place the spend on the second card. FCC also resolved its fallback
identity when a request was recorded, which allowed a credential switch during a long stream to stamp
the wrong account.

The repair captures FCC provider identity immediately after request preflight and before stream start.
OpenUsage then reads only new, fingerprinted `fcc_proxy` rows from FCC's local ledger and matches the
exact Codex account fingerprint; it never guesses historical un-attributed rows.

Orca can keep the durable credential under an account-scoped home while the active rollout is written
to its authenticated `codex-runtime-home/home` bridge. Those homes are intentionally not auto-discovered
by OpenUsage: Orca backfills copies of `~/.codex`, and all of the copies can carry the same OAuth account
id even when they represent a different application's local history. OpenUsage ignores an ambient Orca
`CODEX_HOME` when `ORCA_CODEX_HOME` marks the overlay and scans only the default home plus explicitly
registered/configured homes. If a user intentionally registers multiple homes, the scanner deduplicates
shared inodes and copied `rollout-<id>.jsonl` names, but identity matching alone never attaches Orca's
runtime bridge to the default card.

## Recovery and fix

The app still uses Codex's official `codex login` browser OAuth flow and registers only identifiable homes. After successful registration, `CodexAccountRegistrationService` notifies `AppDelegate`; the app explicitly tears down the old panel/status-item graph and rebuilds the composition root. Existing-home imports use the same identity validation and reject missing, unattributed, or duplicate homes. The controller now creates exactly one aggregate status item and one shared key-capable panel; the dashboard keeps each Codex account as its own card alongside Cursor and other enabled providers. Existing family-level pins are migrated once to a newly discovered account-specific provider, while a later explicit unpin is left alone. New account providers are inserted beside their family card in the saved dashboard order so the new card is not stranded below unrelated providers. FCC proxy usage is folded only when its request-start fingerprint matches the card.

## Validation

- Accounting repair: focused FCC lint plus usage, executor, Codex-auth, and OpenCode-Go tests passed
  57/57; full OpenUsage `swift test --quiet` passed 1,320 tests with 3 skips and 0 failures.
- Current Orca separation repair: focused Codex/account/provider tests passed 93/93 with 1 expected
  skip; full OpenUsage `swift test --quiet` passed 1,361 tests with 3 skips and 0 failures.
- The full FCC suite passed 4,116 tests with 152 skips; six cross-checkout editable-install/import/
  version tests remain unrelated to this repair.
- The installed `/Applications/OpenUsage.app` CLI refreshed both Codex cards and returned an OpenCode
  Go payload with `errors: []`; no `account usage API unavailable (opencode)` warning appeared after
  the fresh launch. The active FCC server is healthy on port 8082 from the editable worktree.
- Installed provenance: `/Applications/OpenUsage.app`, one running process, release-mode build hash
  matches the staged corrected bundle, and the previous bundle is recoverable in the dated archive
  recorded in `docs/codex/turn-log.md`.
- Separation verification: the live API now reports the iCloud card at `383.4M` tokens today and
  `9.7B` for the last 30 days, down from the mixed `724.9M` today reading; the Gmail card remains
  `335.4M` for the last 30 days. The installed CLI returns two non-stale Codex cards with `errors: []`,
  and the live log shows only the default home plus the explicitly registered Gmail home.

## Residual gap

Historical FCC events written before request-start attribution cannot be assigned to an account after the
fact. They remain visible only as account-unidentified FCC totals. The installed/live repair is verified
through CLI and log evidence; direct visual confirmation of the dashboard remains user-unconfirmed.
Cursor's optional credit-grants metadata warning is unrelated and remains unchanged.
