# Codex Turn Log

## 2026-09-12 — Bind multi-account auth and fence Orca source overrides

- Goal: make a two-account Codex runtime impossible to retarget through a home override, and keep Orca-managed homes from augmenting an existing OpenUsage account's token history.
- Changed: `CodexAuthStore` now accepts an expected account identity, filters file/Keychain candidates against it, rejects conflicting `account_id`/JWT metadata, and refuses to save a mismatched auth state. `CodexProvider` binds every scoped store to its card identity, and `ProviderCatalog` pins both auth and log environments to the card while using the sanitized reader.
- Changed: `OpenUsageEnvironmentReader` now filters Orca-managed paths out of inherited `OPENUSAGE_CODEX_HOMES` lists. Account assembly processes ordinary homes before Orca homes and ignores an Orca source when that identity is already bound to an earlier source, preventing same-identity Orca history from being appended to the default card.
- Validation: focused isolation tests passed 52/52; the full OpenUsage suite passed 1,372 tests with 3 skips and 0 failures. The release bundle built and signed with the known icon fallback and absent-iCloud-profile warning; the previous installed app is recoverable at `/Users/tejas/.codex/archives/openusage/OpenUsage-20260912-pre-double-account-hardening.app`; the corrected bundle is installed at `/Applications/OpenUsage.app`.
- Live evidence: installed CLI returned two non-stale cards with `errors: []`; the installed process has no `CODEX_HOME` or `ORCA_*` markers; launchd has no `CODEX_HOME`, `ORCA_CODEX_HOME`, `ORCA_USER_DATA_PATH`, or `OPENUSAGE_CODEX_HOMES`; default rollouts remain at 0, quarantine contains 285, and runtime/default shared inodes remain 0. No standalone Orca app process is running.
- Account boundary: default and Orca auth files are separate private inodes but carry the same provider account metadata; the separate registered OpenUsage account carries a distinct identity. A same-identity Orca path is therefore excluded from the existing card rather than double-counted.
- Evidence state: implemented, tested, installed, live-smoke verified, and code-signature verified. User visual confirmation of the menu-bar panel remains unconfirmed. The current Codex task still has its inherited Orca-home environment until ChatGPT/Codex is restarted; it does not touch the default tree.
- Learning checkpoint: promoted identity-bound auth loading and source-origin fencing from current source plus negative tests; quarantined same OAuth identity as a billing distinction; skipped GitHub publication, forced OAuth re-login, and visual panel confirmation.
- Next action: restart ChatGPT/Codex when convenient, then re-run the clean-environment smoke check on the new host process. No GitHub publication, merge, or Actions run was performed.
- Reference: `Sources/OpenUsage/Providers/Codex/CodexAuthStore.swift`, `Sources/OpenUsage/Providers/Codex/CodexProvider.swift`, `Sources/OpenUsage/Providers/ProviderCatalog.swift`, `Sources/OpenUsage/Services/OverrideEnvironmentReader.swift`, `Sources/OpenUsage/Services/ProviderAccountAssembly.swift`, `Tests/OpenUsageTests/CodexProviderTests.swift`, `Tests/OpenUsageTests/CodexMultiAccountTests.swift`, `Tests/OpenUsageTests/DefaultAccountObserverTests.swift`, and `docs/troubleshooting/codex-auth-isolation.md`.

## 2026-09-12 — Hard-fence Orca/Codex auth and rollout sources

- Goal: stop Orca-managed Codex sessions, authentication homes, and OpenUsage's default Codex card from being implicitly mixed, while keeping explicit registered account cards working.
- Root cause: the live launchd environment exported both `CODEX_HOME` and `ORCA_CODEX_HOME` to Orca's managed home; Orca's stale backfill marker allowed 285 runtime rollout files to remain hard-linked into `/Users/tejas/.codex/sessions`, and the historical copies would still have inflated default accounting after unlinking. OpenUsage's earlier guard depended on the marker and did not reject an Orca path when the marker was missing; the shell snapshot did not capture the marker.
- Changed: `OpenUsageEnvironmentReader` now rejects both Orca managed path families, including a custom `ORCA_USER_DATA_PATH`, and marker-bearing defaults; the Orca path facts are captured as identity facts; all unscoped Codex auth, log, proxy, and default-observer constructors use the sanitized reader; explicit account-scoped overrides remain the only way to inspect a registered Orca home. Added regression coverage for path-only contamination, custom roots, scoped overrides, and marker capture.
- Live remediation: cleared the user launchd `CODEX_HOME`/`ORCA_CODEX_HOME` exports for future launches; marked Orca's backfill complete with no pending dates; atomically detached all 285 runtime/default shared rollout files; then moved those 285 audit-proven historical default copies into recoverable quarantine at `/Users/tejas/.codex/archives/orca-backfilled-sessions-20260912`. No rollout or credential file was deleted. The prior installed app is recoverable at `/Users/tejas/.codex/archives/openusage/OpenUsage-20260912-pre-auth-isolation-v2.app`; the corrected app is installed at `/Applications/OpenUsage.app` and launched from a clean environment.
- Validation: focused isolation tests passed; the full OpenUsage suite passed 1,366 tests with 3 skips and 0 failures; the release-mode bundle built, deep code-signature verification passed, and the installed CLI returned two non-stale Codex cards with `errors: []`. Post-checks show zero runtime/default shared rollout inodes, zero open default-tree rollout files, zero files remaining in the default session tree, and exactly 285 files in recoverable quarantine. No standalone Orca app process is running; the current Codex task remains the only intentional live Orca-home consumer.
- Evidence: implemented, tested, installed, and live-smoke verified. The current Codex task itself remains a live process that inherited the old variables and has open files under the Orca account home; it was not killed or rewritten. A Codex/ChatGPT restart is still required before that already-running process can lose its inherited environment.
- Account boundary: the default and Orca managed auth files carry the same provider account identity, so separate local homes do not prove two separately billed accounts. A genuinely different billing identity requires a separate OAuth sign-in; this repair prevents local source contamination and does not fabricate identity.
- Next action: restart the current Codex/ChatGPT host session when convenient, then verify the next new session starts without either launchd variable. No GitHub publication, merge, or Actions run was performed.
- Reference: `Sources/OpenUsage/Services/OverrideEnvironmentReader.swift`, `Sources/OpenUsage/Services/ShellEnvironmentSnapshot.swift`, `Sources/OpenUsage/Providers/Codex/CodexAuthStore.swift`, `Sources/OpenUsage/Providers/Codex/CodexLogUsageScanner.swift`, `Sources/OpenUsage/Providers/Codex/CodexProxyUsageScanner.swift`, `Sources/OpenUsage/Providers/DefaultAccountObserver.swift`, `Tests/OpenUsageTests/DefaultAccountObserverTests.swift`, `Tests/OpenUsageTests/ShellEnvironmentSnapshotTests.swift`, and `docs/troubleshooting/codex-auth-isolation.md`.

## 2026-09-12 — Keep Orca rollout history out of the default Codex card

- Goal: stop Orca's copied/runtime Codex rollouts from being silently merged into the default Codex token card.
- Changed: OpenUsage now treats Orca homes as explicit opt-in sources instead of auto-discovering `codex-accounts/*/home` and `codex-runtime-home/home`. It still ignores an Orca-injected `CODEX_HOME` when the `ORCA_CODEX_HOME` marker is present, and it deduplicates shared inodes plus copied rollout IDs when multiple homes are intentionally registered. The earlier removal of the static Orca `CODEX_HOME` override remains in place, so Orca's own runtime is not redirected into the system home by OpenUsage.
- Validation: focused Codex/account/provider tests passed 93/93 with 1 expected skip and 0 failures; the full OpenUsage suite passed 1,361 tests with 3 skips and 0 failures. The release bundle rebuilt, deep signature verification passed, and `/Applications/OpenUsage.app` relaunched with Orca stopped. The live API refresh completed successfully; the CLI returned two non-stale Codex cards with `errors: []`.
- Evidence: implemented, tested, installed, and live-smoke verified. The iCloud card now reports `383.4M` tokens today and `9.7B` over the last 30 days, versus the mixed pre-fix `724.9M` today reading; the Gmail card remains `335.4M` over the last 30 days. The two actual OAuth identities remain separately matched by account id; the Orca and default auth files currently carry the same iCloud account id, so they must not be treated as separate billed accounts merely because their local homes differ. No `/Applications/Orca.app` process is running.
- Blocker: none. Historical FCC rows without an account fingerprint remain intentionally unattributed.
- Next action: none for this fix. Direct visual confirmation of the menu-bar panel remains user-unconfirmed; no GitHub publication or merge was requested.
- Reference: `Sources/OpenUsage/Services/ProviderAccountAssembly.swift`, `Sources/OpenUsage/Services/OverrideEnvironmentReader.swift`, `Sources/OpenUsage/Providers/Codex/CodexLogUsageScanner.swift`, `Tests/OpenUsageTests/CodexMultiAccountTests.swift`, `docs/troubleshooting/codex-account-usage-not-visible.md`.

## 2026-08-29 — PR 91 check repair

- Goal: repair the failing OpenUsage CI check for PR 91.
- Changed: `Tests/OpenUsageTests/JSONLScanCacheStoreTests.swift` now recreates the file URL before reading metadata after an atomic rewrite, avoiding stale `URL` resource-value caching in revision fixtures.
- Validation: CI routing contract passed; `swift build` passed; full `swift test --quiet` passed with 1,288 tests, 3 skipped, and 0 failures. Focused cache, incremental-scanner, and resource-soak suites also passed.
- Evidence: implemented and locally tested; GitHub `OpenUsage CI / Build and Test` passed on commit `65f53ac` (run `33286690853`).
- Blocker: none.
- Next action: none for this repair; PR 91's check is green.
- Reference: https://github.com/tverma101/Tools/pull/91

## 2026-08-29 — Sync OpenUsage from merged main after PR 92

- Goal: merge GitHub PR 92 before updating the local OpenUsage implementation from the updated `main` branch.
- Changed: marked PR 92 ready and merged it into `tverma101/Tools` `main` as `c1d24e543c076685b0e62f1487fdb6ace4433fd2`; restored the local `OpenUsage/` tree from `origin/main` at that commit. The prior local OpenUsage edits were preserved in recoverable `stash@{0}` and were not reapplied over the canonical main snapshot.
- Validation: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --package-path OpenUsage` passed; `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path OpenUsage --quiet` passed with 1,294 tests, 3 skipped, and 0 failures. The restored main tree content audit covered 562 regular files plus the matching `.claude -> .agents` symlink. A branch-relative `git diff --check` reports one inherited extra blank line at `Tests/OpenUsageTests/JSONLScannerCancellationTests.swift:179`; no sync content mismatch was found.
- Evidence: PR 92 is merged remotely; the local OpenUsage source and tests are synced to that merged main snapshot and locally build/test successfully. No install, live runtime, or user visual confirmation was performed.
- Blocker: none for the requested merge and local source sync. The checkout remains on `feature/localtime-zero-db-scaffold` with unrelated pre-existing dirty work, so the OpenUsage files appear as worktree changes relative to that stale branch.
- Next action: review or selectively reapply `stash@{0}` only if the preserved pre-sync local OpenUsage changes are still wanted.
- Reference: https://github.com/tverma101/Tools/pull/92

## 2026-08-29 — Rebuild and launch the current local OpenUsage app

- Goal: resolve the report that local OpenUsage was stale or duplicated after the PR 92 sync.
- Changed: rebuilt and staged `dist/OpenUsage.app` from the canonical OpenUsage source at merged `origin/main` `c1d24e543c076685b0e62f1487fdb6ace4433fd2`, then launched that bundle with the documented `script/build_and_run.sh verify` path. The script now assigns the dev bundle id `com.robinebers.openusage.dev`; the older stable `/Applications/OpenUsage.app` bundle remains separate and was not overwritten.
- Validation: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer CONFIG=release ./script/build_and_run.sh verify` passed. The active process is `/Users/tejas/Projects/Tools/OpenUsage/dist/OpenUsage.app/Contents/MacOS/OpenUsage`, started at 22:49 EDT; the rebuilt dev bundle is dated 2026-08-29, while the separate installed stable bundle remains dated 2026-08-20.
- Evidence: current source hash matches `origin/main`; one updated local dev OpenUsage process is running. This proves build, launch, and process provenance, not user visual confirmation or stable-app installation.
- Blocker: the stable `/Applications/OpenUsage.app` remains an older separate artifact by design, so launching it directly would still run the old build. No duplicate OpenUsage process is running; the other copies are on-disk source/backup artifacts.
- Next action: if the stable `/Applications/OpenUsage.app` itself must be replaced, perform that as a separate installation decision after confirming the desired release/signing boundary.
- Reference: `OpenUsage/script/build_and_run.sh` and the merged PR 92 snapshot.

## 2026-08-29 — Add Codex account registration UX

- Goal: fix the gap where PR 92's multi-account cards existed but users could not register another Codex account from the local OpenUsage app.
- Changed: added persisted app-managed Codex home registrations, merged them with `OPENUSAGE_CODEX_HOMES`, normalized duplicate path spellings, and exposed a Settings → Codex Accounts surface. **Register Another Account…** creates an isolated home and opens `codex login` in Terminal; **Add Existing Codex Home…** accepts an already-authenticated home. Removing/resetting a registration never deletes Codex credentials or history. Updated the Codex provider and Settings documentation.
- Validation: focused `CodexMultiAccountTests` passed with 11 tests and 0 failures; full `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path OpenUsage --quiet` passed with 1,299 tests, 3 skipped, and 0 failures; `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer CONFIG=release ./script/build_and_run.sh verify` built, signed, staged, and launched the local dev bundle; `git diff --check` and `zsh -n OpenUsage/script/build_and_run.sh` passed.
- Evidence: implemented and locally tested; active process is the rebuilt `/Users/tejas/Projects/Tools/OpenUsage/dist/OpenUsage.app`. This proves source/build/launch behavior, not completion of a real browser sign-in or user visual confirmation. The separate `/Applications/OpenUsage.app` stable artifact remains unchanged.
- Blocker: none in the implementation. A user must complete the Codex browser sign-in in the Terminal window and quit/reopen OpenUsage once for the new account identity to be resolved.
- Next action: open Settings → Codex Accounts in the active local dev app and use **Register Another Account…** when ready to authenticate the second account.
- Reference: `OpenUsage/Sources/OpenUsage/Views/CodexAccountsSettingsSection.swift`, `OpenUsage/Sources/OpenUsage/Services/CodexAccountRegistrationService.swift`, and PR 92 merge `c1d24e543c076685b0e62f1487fdb6ace4433fd2`.

## 2026-08-29 — Replace the stale installed OpenUsage bundle

- Goal: delete the old installed OpenUsage version and install the updated registration-capable build without leaving duplicate app bundles active.
- Changed: rebuilt `dist/OpenUsage.app` with the stable bundle id `com.robinebers.openusage`; moved the previous `/Applications/OpenUsage.app` into recoverable Trash; moved the rebuilt bundle into `/Applications/OpenUsage.app`; launched the installed app.
- Validation: build/stage/sign completed; `/Applications/OpenUsage.app` reports bundle id `com.robinebers.openusage` and version `0.7.0-dev`; the old app is absent from Applications, the `dist` app bundle is absent, exactly one matching installed process is running, and `codesign --verify --deep --strict` passes.
- Evidence: implemented, installed, live, and locally signature-verified. User visual confirmation and completion of a second-account browser sign-in remain unverified.
- Blocker: none for replacement. The previous installed app remains recoverable at `/Users/tejas/.Trash/OpenUsage.app.old-20260829-230838`.
- Next action: use Settings → Codex Accounts → **Register Another Account…**, complete the Terminal/browser login, then quit and reopen OpenUsage.
- Reference: `/Users/tejas/Projects/Tools/OpenUsage/script/build_and_run.sh` and the PR 92 merge `c1d24e543c076685b0e62f1487fdb6ace4433fd2`.

## 2026-08-29 — Fix account-registration collisions and cold-start discovery

- Goal: continue the efficiency and bug audit after the PR 92 sync and installed-bundle replacement, with focus on registering a second Codex account.
- Changed: fixed `CodexAccountRegistrationService` to generate a unique Terminal command path for every login attempt; kept app-registered and process-configured Codex homes in the launch account pass when login-shell capture is cold or unavailable; made `script/test_efficiency.sh` executable; added regression coverage and documented the cold-start behavior.
- Validation: targeted Codex registration/account-assembly tests passed with 17 tests and 0 failures; the direct efficiency harness passed all eight focused suites (81 tests, 1 skipped); full `swift test --quiet` passed with 1,302 tests, 3 skipped, and 0 failures.
- Evidence: implemented, locally tested, rebuilt, installed, and live. The installed bundle reports `com.robinebers.openusage` version `0.7.0-dev`, deep signature verification passes, and exactly one installed process is running. User visual confirmation and a real second-account browser sign-in remain unverified.
- Blocker: the currently installed runtime has repeatedly logged `optional credit-grants response contained invalid grant metadata` for Cursor while its primary refresh succeeds; this remains a candidate upstream/schema warning rather than a confirmed usage bug.
- Next action: complete a real second-account browser sign-in through Settings → Codex Accounts; separately investigate the Cursor optional credit-grants schema warning if it persists.
- Reference: `Sources/OpenUsage/Services/CodexAccountRegistrationService.swift`, `Sources/OpenUsage/Services/ProviderAccountAssembly.swift`, `Tests/OpenUsageTests/CodexMultiAccountTests.swift`, `Tests/OpenUsageTests/ProviderAccountAssemblyTests.swift`, and `script/test_efficiency.sh`.

## 2026-08-29 — Bound multi-session indexing and cold-start work

- Goal: continue the efficiency and bug audit after the account-registration fixes, focusing on multi-session indexing edge cases and poor startup CPU behavior.
- Changed: Claude discovery now deduplicates overlapping config-root paths; Claude session ownership cache entries include attribute modification time so same-size rewrites that restore content mtime are reclassified; OpenCode's Claude gateway fold shares the native Claude source identity and incremental parse cache; OpenCode's Codex fold includes registered homes, canonicalizes aliases, and scans each home once; the first app refresh serializes provider starts before returning to normal concurrency. Updated the architecture, OpenCode, research, and cache-key comments, plus regression coverage.
- Validation: the eight-suite efficiency harness passed 81 test invocations with 1 skipped and 0 failures; full `swift test --package-path . --quiet` passed with 1,306 tests, 3 skipped, and 0 failures; release build completed with the existing icon fallback and absent-iCloud-profile warnings. The rebuilt `/Applications/OpenUsage.app` reports bundle id `com.robinebers.openusage` version `0.7.0-dev`, deep signature verification passes, `dist/OpenUsage.app` is absent, and exactly one installed process is running.
- Evidence: implemented, tested, installed, and live. A 35-sample installed-process startup measurement peaked at 100.9% CPU and 354,400 KB (346.1 MiB) RSS, versus the earlier local sample of about 156% CPU and 346 MiB RSS; this is workload evidence, not a universal bound. Live logs show the first refresh started with three providers and completed them serially in 5.67 seconds. User visual confirmation and a real second-account browser sign-in remain unverified.
- Blocker: none for the source or installed replacement. The Cursor optional credit-grants metadata warning persists as an independent candidate schema issue; no speculative change was made for it.
- Next action: complete a real second-account browser sign-in through Settings → Codex Accounts; if startup still feels slow on another workload, capture a longer Instruments profile. No GitHub publication or Actions run was performed.
- Reference: `Sources/OpenUsage/Providers/Claude/ClaudeLogUsageScanner.swift`, `Sources/OpenUsage/Providers/OpenCode/OpenCodeUsageScanner.swift`, `Sources/OpenUsage/Providers/ProviderCatalog.swift`, `Sources/OpenUsage/Stores/WidgetDataStore.swift`, `Tests/OpenUsageTests/ClaudeLogUsageScannerTests.swift`, and `docs/architecture.md`.

## 2026-08-29 — Investigate intermittent macOS beep during self-hosted tests

- Goal: identify the occasional system beep reported while the local self-hosted runner executes test work.
- Inspected: canonical `tverma101/Tools` checkout `/Users/tejas/Projects/Tools`, current `feature/localtime-zero-db-scaffold` dirty baseline, live OpenUsage process, runner logs, and OpenUsage sound/notification call sites.
- Validation: read-only process and log inspection found repeated `Build and Test` jobs on `actions.runner.tverma101-Tools.openusage-macos-arm64`; `ShareCardRendererTests.testCopyToPasteboardReturnsFalseForUnencodableImage()` passes an empty `NSImage` into `ShareCardRenderer.copyToPasteboard`, whose failure branch calls `NSSound.beep()` at `Sources/OpenUsage/Support/ShareCardRenderer.swift:42`. No test or source command was rerun because it could intentionally emit another beep.
- Evidence: strong source-to-test explanation for one beep per test-suite run; no timestamp-level audio event correlation was established. OpenUsage quota notification sounds are a separate opt-in path and no recent notification log entries were observed.
- Blocker: none for diagnosis; a code-level suppression or injectable test sound policy would require an explicit fix request.
- Next action: if authorized, make the failure sound test-safe (prefer injection or a test guard while retaining user-facing diagnostics) and add focused regression coverage.
- Reference: `Sources/OpenUsage/Support/ShareCardRenderer.swift`, `Tests/OpenUsageTests/ShareCardRendererTests.swift`, and `/Users/tejas/Library/Logs/actions.runner.tverma101-Tools.openusage-macos-arm64/stdout.log`.

## 2026-08-30 — Replace Codex account registration with official sign-in

- Goal: replace the temporary Terminal-script registration flow with the proper Codex sign-in method after the registration UX was rejected as poor.
- Changed: `CodexAccountRegistrationService` now launches the official `codex login` browser OAuth flow directly through `/usr/bin/env`, scopes it to a fresh private `CODEX_HOME`, drains child output with a bounded tail, validates Codex's resulting account metadata, and persists the home only after a real account is identifiable. Settings now presents **Sign in to Codex…** and **Use Existing Codex Home…**; app termination cancels any in-flight login. Removed the old `.command`/Terminal implementation and updated Codex/settings documentation.
- Validation: focused `CodexMultiAccountTests` passed with 12 tests and 0 failures; full `swift test --package-path . --quiet` passed with 1,305 tests, 3 skipped, and 0 failures. An isolated `codex login status` probe with a temporary `CODEX_HOME` returned `Not logged in` and created no auth file. Release build completed with the existing icon fallback and absent-iCloud-profile warnings.
- Evidence: implemented, tested, installed, live, and deep-signature verified. `/Applications/OpenUsage.app` is the only installed bundle, `dist/OpenUsage.app` is absent, and one installed process is running. No browser sign-in was performed, so the real second-account result remains user-unverified.
- Blocker: none in the implementation. Cursor's independent optional credit-grants metadata warning remains unchanged; no speculative fix was made.
- Next action: open Settings → Codex Accounts → **Sign in to Codex…**, complete the browser approval, and restart OpenUsage once so the new account card is assembled.
- Reference: `Sources/OpenUsage/Services/CodexAccountRegistrationService.swift`, `Sources/OpenUsage/Views/CodexAccountsSettingsSection.swift`, `Sources/OpenUsage/App/OpenUsageApp.swift`, `Tests/OpenUsageTests/CodexMultiAccountTests.swift`, `docs/providers/codex.md`, and `docs/settings.md`.

## 2026-08-30 — Silence OpenUsage test-runner beeps

- Goal: stop the intermittent macOS system beep emitted while the self-hosted OpenUsage runner executes tests.
- Changed: `ShareCardRenderer` now routes its failure feedback through a test-aware guard; XCTest keeps the existing error logs and returns unchanged but does not call `NSSound.beep()`. Added a regression assertion that failure sound is disabled in the XCTest harness.
- Validation: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path OpenUsage --filter ShareCardRendererTests` passed all 7 tests with 0 failures and no beep. `CONFIG=release ./script/build_and_run.sh verify` rebuilt, signed, staged, and reported a successful launch of the local dev bundle. The post-check later found a concurrent process had relaunched the stable `/Applications/OpenUsage.app`, so the dev bundle's continued live state could not be claimed. No runner service, preferences, installed stable app, or unrelated worktree files were changed.
- Evidence: implemented, tested, and release-built; the stable `/Applications/OpenUsage.app` was not replaced. The source-level test behavior is verified; user confirmation that the next scheduled runner job is quiet remains pending.
- Blocker: none.
- Next action: let the next scheduled self-hosted test job run and confirm the system remains quiet; if it does, this diagnosis is behaviorally confirmed.
- Reference: `Sources/OpenUsage/Support/ShareCardRenderer.swift` and `Tests/OpenUsageTests/ShareCardRendererTests.swift`.

## 2026-08-30 — Finalize proper Codex account sign-in and live card reload

- Goal: replace the rejected account-registration UX with Codex's normal browser sign-in, close invalid-import edge cases, and make a completed sign-in visible without a manual restart.
- Changed: the Settings action launches the installed Codex CLI's official browser OAuth command directly with a fresh private CODEX_HOME; OpenUsage never creates an auth URL, token, shell script, or Terminal window. The home is registered only after Codex's auth metadata identifies an account. Existing-home imports use the same identity check and reject missing, unattributed, or duplicate homes. Successful registration now tears down and rebuilds the provider/status-item composition root so the new usage card loads in the same session. Updated the Settings/Codex documentation and added focused regression coverage.
- Validation: focused CodexMultiAccountTests passed with 15 tests and 0 failures; full swift test passed with 1,309 tests, 3 skipped, and 0 failures; the eight-suite efficiency harness passed 81 test invocations with 1 skipped and 0 failures; release build, deep signature verification, and installed launch passed. The live installed log recorded both Codex identities, two status items, and a successful refresh for codex@0577ce6e. OpenUsage's own CLI then returned a fresh, non-stale limits payload for that exact account with exit 0. The installed bundle is /Applications/OpenUsage.app, dist/OpenUsage.app is absent, and exactly one OpenUsage process is running from the installed bundle.
- Evidence: implemented, tested, installed, live, and signature-verified. The user's browser sign-in, metadata registration, and new-account refresh are now observed in the live log; visual confirmation of the dashboard card remains pending. Cursor's independent optional credit-grants metadata warning remains.
- Blocker: none for the requested implementation. No GitHub publication, merge, or Actions run was performed in this turn.
- Next action: open the OpenUsage dashboard and verify the second Codex card visually; no restart should be required after the next successful sign-in.
- Reference: Sources/OpenUsage/Services/CodexAccountRegistrationService.swift, Sources/OpenUsage/Views/CodexAccountsSettingsSection.swift, Tests/OpenUsageTests/CodexMultiAccountTests.swift, docs/providers/codex.md, and docs/settings.md.

## 2026-08-30 — Remove duplicate Codex menu-bar status item

- Goal: fix the live report that two OpenUsage-looking icons appeared and one had no usable dashboard view after adding a second Codex account.
- Changed: restored one canonical `NSStatusItem`; all Codex accounts remain distinct dashboard cards and share one menu-bar strip/panel. Removed the account-specific image slice that could create an orphan fallback icon, and made new account-scoped providers insert beside their provider family in an existing layout. Added regression tests and updated menu-bar, Codex, and troubleshooting documentation.
- Validation: focused menu-bar/account-order tests passed; full `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --quiet` passed with 1,312 tests, 3 skipped, and 0 failures; `./script/test_efficiency.sh` passed; the release build/install completed; `/Applications/OpenUsage.app` is the only app bundle found, `codesign --verify --deep --strict /Applications/OpenUsage.app` passes, and the installed process is running. The live log records the singular `Status item ready` entry followed by successful refreshes for both Codex identities.
- Evidence: implemented, tested, installed, live, and signature-verified. Direct post-fix menu-bar click and visual confirmation remain pending because the Computer Use connector was not callable in this environment. The previous installed bundle remains recoverable in `/Users/tejas/.Trash/`.
- Blocker: none for the source or installed replacement. Cursor's independent optional credit-grants metadata warning remains unchanged; no GitHub publication, merge, or Actions run was performed.
- Next action: click the one OpenUsage icon and verify the shared panel shows both Codex cards; if two icons remain, capture a fresh screenshot after that click so the remaining icon's owner can be identified.
- Reference: `Sources/OpenUsage/App/StatusItemController.swift`, `Sources/OpenUsage/App/StatusItemImageUpdater.swift`, `Sources/OpenUsage/Stores/WidgetRegistry.swift`, `Tests/OpenUsageTests/MenuBarContentTests.swift`, and `Tests/OpenUsageTests/WidgetRegistryTests.swift`.

## 2026-08-30 — Restore two account-scoped Codex menu-bar icons

- Goal: honor the corrected requirement that two configured Codex accounts must produce two usable OpenUsage menu-bar icons, while eliminating the orphan-icon behavior.
- Changed: `StatusItemController` now creates one status item per distinct Codex provider account when more than one is configured; each item has an account-scoped strip, tooltip, click target, and shared key-capable dashboard panel. Clicking either item selects that account, filters the dashboard to its card, and re-anchors the same panel; right-click Settings is anchored to the exact item. The outside-click monitor accepts all status buttons, and registration reload teardown removes retired items and shortcut handlers before rebuilding. Added scoped rendering and status-item contract tests and updated the menu-bar/Codex/troubleshooting documentation.
- Validation: focused menu-bar/widget tests passed with 19 tests and 0 failures; full `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --quiet` passed with 1,315 tests, 3 skipped, and 0 failures; `./script/test_efficiency.sh` passed all 81 efficiency invocations with 1 skipped and 0 failures; release build/signing completed. The old `/Applications/OpenUsage.app` was moved to recoverable Trash at `/Users/tejas/.Trash/OpenUsage.app.before-two-status-items-20260830-1049`, the new bundle was installed at `/Applications/OpenUsage.app`, `dist/OpenUsage.app` is absent, exactly one installed process is running, and deep signature verification passes. The current installed log records `Status items ready (count: 2, buttons: 2)` followed by successful refreshes for both Codex identities.
- Evidence: implemented, tested, installed, live, and signature-verified. Direct visual clicking of each menu-bar item remains user-unconfirmed because the Computer Use connector was not callable in this environment; source and live log evidence cover the sender routing and account count.
- Blocker: none for the requested two-icon implementation. Cursor's independent optional credit-grants metadata warning remains unchanged; no GitHub publication, merge, or Actions run was performed.
- Next action: click each OpenUsage icon once and confirm each opens the corresponding Codex account card; if the displayed account label/value is wrong, capture that post-click screenshot for the next bounded fix.
- Reference: `Sources/OpenUsage/App/StatusItemController.swift`, `Sources/OpenUsage/App/StatusItemImageUpdater.swift`, `Sources/OpenUsage/App/PanelOutsideClickMonitor.swift`, `Sources/OpenUsage/Views/DashboardContentView.swift`, `Tests/OpenUsageTests/MenuBarContentTests.swift`, and `/Applications/OpenUsage.app`.

## 2026-08-30 — Migrate legacy Codex pins for account-scoped menu-bar strips

- Goal: fix the remaining bare OpenUsage-looking item after enabling one menu-bar icon per Codex account.
- Root cause: existing layouts retained family-level pins (`codex.session` and `codex.weekly`), while the newly discovered account used scoped descriptors (`codex@0577ce6e.session` and `codex@0577ce6e.weekly`). The second status item therefore had no matching pinned metrics and rendered only its fallback mark.
- Changed: `LayoutBootstrap` now copies family pin membership to each newly discovered account descriptor once, persists a seeded-account-pin marker, and honors a later explicit account-pin removal. Explicitly empty pin layouts remain empty. Added persistence, bootstrap, and regression coverage; retained the two account-scoped status items and shared account-focused panel behavior.
- Validation: full `swift test --quiet` passed with 1,317 tests, 3 skipped, and 0 failures; `./script/test_efficiency.sh` passed all 81 efficiency invocations with 1 skipped and 0 failures; release build/install completed; `git diff --check` passed for touched files. The installed defaults contain both family and `codex@0577ce6e` session/weekly pins, exactly one `/Applications/OpenUsage.app` process is running, it is the only discovered OpenUsage bundle, and deep signature verification passes. The live log records `Status items ready (count: 2, buttons: 2)` and successful refreshes for both Codex identities. A fresh menu-bar capture shows two metric-bearing OpenUsage items; the separate bare OpenAI mark is owned by the running `/Applications/ChatGPT.app` process.
- Evidence: implemented, tested, installed, live, signature-verified, and visually inspected. Direct click-through of each item remains user-unconfirmed because the Computer Use connector was unavailable.
- Blocker: none for the requested fix. The prior installed bundle remains recoverable at `/Users/tejas/.Trash/OpenUsage.app.before-pin-migration-20260830-1100`. No GitHub publication, merge, or Actions run was performed.
- Next action: click the two metric-bearing OpenUsage icons and confirm each opens its corresponding Codex account card; do not treat the separate ChatGPT mark as an OpenUsage duplicate.
- Reference: `Sources/OpenUsage/Stores/LayoutPersistence.swift`, `Sources/OpenUsage/Stores/LayoutBootstrap.swift`, `Sources/OpenUsage/Stores/LayoutStore.swift`, `Tests/OpenUsageTests/LayoutBootstrapTests.swift`, `Sources/OpenUsage/App/StatusItemController.swift`, and `docs/menu-bar.md`.

## 2026-08-30 — Consolidate Codex accounts into one OpenUsage menu-bar panel

- Goal: match the corrected UX requirement: one OpenUsage menu-bar item containing two Codex account metrics/cards and one Cursor item, without duplicate OpenUsage status items.
- Changed: removed the account-scoped status-item graph and its focused-dashboard path. `StatusItemController` now owns exactly one aggregate status item and one shared panel; `StatusItemImageUpdater` renders all pinned provider groups together; the dashboard keeps both Codex account groups and Cursor available in the same panel. The legacy family-pin migration remains in place so both account metrics render after upgrade.
- Validation: focused menu-bar tests passed 11/11; full `swift test --quiet` passed with 1,315 tests, 3 skipped, and 0 failures; `./script/test_efficiency.sh` passed all 81 efficiency invocations with 1 skipped and 0 failures; release build/install completed; `git diff --check` passed for touched files. The installed log records `Status item ready (count: 1, buttons: 1)` and successful refreshes for `codex`, `codex@0577ce6e`, and `cursor`. Exactly one installed OpenUsage process is running, `/Applications/OpenUsage.app` is the only discovered OpenUsage bundle, and deep signature verification passes.
- Evidence: implemented, tested, installed, live, signature-verified, visually inspected, and user-confirmed by the follow-up screenshot showing one panel with both Codex account cards. The separate bare OpenAI mark and Cursor mark are other applications' menu-bar items.
- Blocker: none. The prior installed bundle remains recoverable at `/Users/tejas/.Trash/OpenUsage.app.before-one-menu-20260830-1115`. No GitHub publication, merge, or Actions run was performed in this turn.
- Next action: none for this request; continue using the single OpenUsage menu-bar item. Broader speculative efficiency candidates remain out of scope for this bounded repair.
- Reference: `Sources/OpenUsage/App/StatusItemController.swift`, `Sources/OpenUsage/App/StatusItemImageUpdater.swift`, `Sources/OpenUsage/Views/DashboardView.swift`, `Sources/OpenUsage/Views/DashboardContentView.swift`, `Sources/OpenUsage/Views/WidgetGroupedListView.swift`, `Tests/OpenUsageTests/MenuBarContentTests.swift`, `docs/menu-bar.md`, and the user-confirmed screenshot from 2026-08-30 11:19.

## 2026-08-30 — Remove hidden-panel periodic CPU work

- Goal: continue the idle-efficiency audit and eliminate avoidable CPU work while OpenUsage is closed in the menu bar, without making usage values stale while the panel is open or changing the five-minute refresh contract.
- Inspected: the AppKit panel lifetime, `AppContainer`'s refresh loop, `WidgetDataStore` notification evaluation, all `TimelineView` mounts, the menu-bar image observer, local scanner paths, and iCloud metadata observation. The panel remains mounted after `orderOut`, so its SwiftUI timers were the confirmed hidden-work boundary.
- Root cause: the footer mounted a one-second countdown, reset/expiry rows mounted 30-second clocks, and visited iCloud settings rows mounted 60-second age clocks even when the panel was hidden. A 50 ms delayed image update was also created for every observable write, and disabled notifications still resolved every visible metric on each background pass.
- Changed: added `VisibilityGatedPeriodicTimeline` with a structural hidden/static branch; applied it to the footer, metric rows, and iCloud rows; coalesced pending menu-bar image renders and cancel them on teardown; skipped notification metric resolution when all triggers are off while retaining evaluator pruning. Updated `docs/architecture.md` and `docs/refreshing.md`, plus regression coverage for timer mount policy and disabled-notification resolution.
- Validation: focused regressions passed; full `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --quiet` passed with 1,317 tests, 3 skipped, and 0 failures; `./script/test_efficiency.sh` passed all eight focused suites with one expected parity skip; release staging/signing passed with the repository's known `actool` fallback and absent-iCloud-profile warning. The prior installed bundle is recoverable at `/Users/tejas/.Trash/OpenUsage.app.before-idle-cpu-20260830-114348`; `/Applications/OpenUsage.app` is the only discovered bundle, one process runs from it, and deep signature verification passes.
- Evidence: pre-fix hidden-panel sampling across a scheduled refresh averaged 2.819% CPU and peaked at 100.0%; post-fix hidden-panel sampling averaged 0.043% and peaked at 1.3% over 30 seconds. A post-fix five-second `sample` contained only the sleeping AppKit run loop and no app-owned timer/render stack. The installed launch completed its four-provider first pass in 7.021 seconds.
- Learning checkpoint: the hidden SwiftUI clocks were promoted as the confirmed project-level cause and documented; system display-configuration callbacks and the intentional five-minute provider refresh were quarantined as independent candidates; changing refresh cadence or scanner algorithms was skipped because this turn did not establish that they were idle work.
- Residual gap: the five-minute background refresh intentionally remains so the menu-bar strip stays current; its transient CPU cost was observed pre-fix but not re-measured at the next installed five-minute boundary. No GitHub publication, merge, or Actions run was performed.
- Next action: monitor the installed app through one later scheduled refresh if a lower refresh-spike budget is required; otherwise continue using the single OpenUsage menu-bar item.
- Reference: `Sources/OpenUsage/Support/PartyMode.swift`, `Sources/OpenUsage/App/StatusItemImageUpdater.swift`, `Sources/OpenUsage/Views/PopoverFooter.swift`, `Sources/OpenUsage/Views/WidgetRowView.swift`, `Sources/OpenUsage/Views/ICloudSyncSettingsSection.swift`, `Sources/OpenUsage/Stores/WidgetDataStore.swift`, `Tests/OpenUsageTests/ReduceAnimationsSettingTests.swift`, `Tests/OpenUsageTests/WidgetDataStoreNotificationTests.swift`, `docs/architecture.md`, and `docs/refreshing.md`.

## 2026-09-02 — Attribute FCC proxy usage to Codex and OpenCode Go accounts

- Goal: repair second-account Codex history and OpenCode Go account tracking without guessing
  account ownership from mutable credentials or identical quota windows.
- Changed: OpenUsage now folds only exact fingerprinted `fcc_proxy` rows from FCC's metadata-only
  ledger into the matching Codex card. FCC captures the provider fingerprint at request start,
  before a stream can outlive an account switch; OpenAI Codex uses its account id fingerprint and
  OpenCode Go uses its credential fingerprint. OpenCode API discovery now sends only the
  `opencode-go` credential to the Go usage endpoint, collapses exact duplicate credentials, and
  keeps distinct credentials separate even when percentages match. Historical unattributed rows
  remain unassigned.
- Validation: focused FCC lint plus usage/executor/Codex-auth/OpenCode-Go tests passed 57/57;
  full OpenUsage `swift test --quiet` passed 1,320 tests with 3 skips and 0 failures; full FCC
  pytest passed 4,116 with 152 skips and 6 unrelated editable-install/import/version failures.
  Release build completed, the previous `/Applications/OpenUsage.app` bundle was moved to the
  recoverable archive `/Users/tejas/.codex/archives/openusage/OpenUsage-20260902-pre-account-attribution.app`,
  and the corrected bundle is installed and running at `/Applications/OpenUsage.app`. Its CLI
  returned both Codex cards and an OpenCode Go payload with `errors: []`; the active FCC server
  is healthy on port 8082, version 4.65.2, and its process cwd is the editable FCC worktree.
- Evidence: implemented, tested, built, installed, and live-smoke verified. No model request was
  generated for validation. The live OpenCode Zen key is no longer sent to the Go endpoint.
  Visual dashboard confirmation remains user-unconfirmed.
- Learning checkpoint: promoted request-start identity capture and exact account-key filtering as
  the verified repair; quarantined the six FCC full-suite environment failures and the repository's
  existing Icon Composer fallback; skipped historical ledger backfill and any paid/provider model
  request because neither can be done honestly from available evidence.
- Residual gap: FCC rows written before this fix without an account fingerprint cannot be safely
  reconstructed. Future FCC requests need the restarted editable server to receive attribution;
  no GitHub publication, merge, or Actions run was performed.
- Next action: use the installed OpenUsage dashboard normally; after the next request through each
  account, refresh and confirm the newly written spend appears only on its matching card.
- Reference: `Sources/OpenUsage/Providers/Codex/CodexProxyUsageScanner.swift`,
  `Sources/OpenUsage/Providers/Codex/CodexProvider.swift`,
  `Sources/OpenUsage/Providers/OpenCode/OpenCodeAuthStore.swift`,
  `Sources/OpenUsage/Providers/OpenCode/OpenCodeProvider.swift`, FCC
  `src/free_claude_code/application/execution.py`, FCC
  `src/free_claude_code/usage/stream.py`, `docs/providers/codex.md`,
  `docs/providers/opencode.md`, and `docs/troubleshooting/codex-account-usage-not-visible.md`.
