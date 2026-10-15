# Refreshing & Caching

## When data updates

- Enabled providers refresh once at launch; disabled provider cards are filtered before any provider refresh begins. Live quota meters refresh every minute while the panel is open and every minute on AC or every two minutes on battery / Low Power Mode while it is closed. Their 50-second cache window expires before each scheduled tick, so the minute tick fetches instead of sometimes landing just inside a 60-second cache boundary. Full history folds have a separate five-minute cadence. While the panel is closed, that history deadline does not widen the quota pass to every provider; only pinned and notification-relevant meters are requested. Quota-only requests normally run concurrently, including at launch, so a slow provider does not hold other pinned meters in line; they serialize when memory pressure requires it. History folds run in a tracked background task and never block the meter scheduler. If a meter deadline arrives during a fold, a meter-only refresh may overlap that fold for the same enabled card. An explicit panel-meter Retry uses the same overlap rule, so a slow history pass cannot hold its visible quota retry. Meter requests still serialize against other meter requests and full refreshes, and folds still serialize against other folds. The popover countdown tracks quota-capable batches, not fold-only accounting.
- Refresh requests that need all providers run in two phases: fetch every enabled provider's live quota meters, then recompute local accounting (spend tiles and history) and merge it with those meters. The same ordering applies to panel opens, accepted background triggers, midnight rollover, and the five-minute history refresh. Each due five-minute history deadline reruns the local fold even when its prior snapshot is otherwise fresh, while preserving the recovered meters and normal failure backoff. While the panel stays open, one-minute ticks run only the meter phase. A ledger append runs the narrow Codex/OpenCode local-accounting fold, with no quota API rereads and no unrelated history scans. Refresh Now, the CLI, and the local API keep their direct full-refresh behavior.
- While a pass is running, repeated wakes of the same kind coalesce, while distinct causes (ledger changes, provider toggles, panel opens, and refresh requests) are all retained for the next pass.
- A cached value's freshness also tracks its **meters**: a fold-only pass recomputes spend/history while reusing the meters from the previous quota fetch. Meter-only scopes use a 50-second freshness window, while full/history scopes keep the five-minute window. The scheduler moves its deadline after a live quota attempt (or a due no-work tick); an early pass that only hits cache or scans a local-only provider moves neither the deadline nor the footer countdown. Together these prevent equal-deadline cache hits from stretching subscription refreshes to every other minute. The cache checks both history and meter stamps, so recovered meters age on their own clock and the next quota pass re-reads the API instead of cache-hitting on old percentages.
- Quota and local-history failures have separate retry windows. A failed quota request does not hold back a local fold, and a local scan failure does not postpone the next live meter request. A visible Retry runs meters first and then folds providers that export local history; both phases retain the same one-dialog Keychain allowance and use the interactive CPU budget. During the second phase, the warning and Retry action stay visible beside a supplementary spinner. If a newer manual action supersedes the meter phase, silent recovery keeps the interactive accounting budget without reopening Keychain. The error remains until the work that failed succeeds. Full-refresh failures share backoff with those component passes. Forced retries keep their requested scope through the provider deadline, so a meter retry does not unexpectedly start a slow full-history scan. Providers whose meter pass already scans history, such as Hermes, are skipped by the separate fold phase. Deferred history retries keep their cache, backoff bypass, and manual Keychain context when a meter pass finishes first; disabling that provider invalidates its queued history request, including a request already handed to the scheduler.
- Background menu-bar ticks pace instrumented local accounting toward 7.5% of one CPU core. Explicit full-history reads (Refresh Now, the one-shot CLI, and the local API) use the 25% interactive budget when their accounting work is instrumented. Visible provider retries use that same interactive budget across their meter and history phases. Panel-open and accepted background accounting folds run without pacing. CodexRouter and OpenCode also read a cold compact ledger without pacing to stay inside the provider deadline; persisted summaries make unchanged refreshes skip event bytes. The pacing target averages work over bounded slices, includes CPU from reaped helper processes, and is not an instantaneous hard cap. The repeatable benchmark covers a synthetic CodexRouter scanner/cache path, not every provider.
- Across a local-midnight rollover, all enabled live meters refresh first and the local fold runs separately, so Today / Yesterday tiles rebuild with the new day without blocking later meter deadlines. History folds also cover the **lifetime** window — the local log corpus in full — so the Usage History screen's Lifetime card stays current; parse and aggregate caches make the deep fold incremental after its first pass, and the 30-day tiles clip the wide result by day key.
- Turning a provider on (yourself in Customize, or automatically by first-launch/new-provider detection) schedules all enabled meters promptly and queues its history fold. Turning one off cancels its in-flight refresh; cancellation checks stop later scanner and API stages, and disabled cards are never selected by later passes. Disabling the last Codex card also disarms the CodexRouter file and directory watches, so a turned-off source is not even monitored; enabling a Codex card arms them again. Disabling a Codex card cancels sibling scans that captured its peer-home list. Codex managed-home deduplication walks only enabled peer homes. Claude account ownership metadata is cached across enabled cards; a shared-root candidate is read only through its ownership preamble and first usage row to classify it, then nonmatching usage rows stay out of the enabled card's parser. A CodexRouter ledger wake is ignored when every Codex card is disabled, and OpenCode is not rescanned for that disabled source. If a closed-panel ledger append lands inside the wake cooldown, one trailing wake runs when the cooldown expires so the final append is not stranded.
- OpenCode's combined spend fold also skips Claude, Codex, Hermes, or Muse log sources when that source family is disabled; with multiple Claude or Codex account cards, it folds only enabled Claude scanners and Codex homes. Hermes remains serialized with heavy local work because its meter refresh reads its local database even in a meters-only pass; that local-only scan does not advance the global quota deadline.
- The Dashboard and Settings footer shows `Next update in Nm`. **Clicking it (or pressing ⌘R while that footer is present)** refreshes immediately, skipping the cache.
- Keychain reads on scheduled/background passes are silent. A user-requested Refresh (including a provider's context-menu Refresh) can show at most one Keychain read dialog across all provider cards. Only one interactive Security query may be in flight at a time. A newer Refresh invalidates an older prompt context and cannot start another interactive query until the synchronous read returns. Sibling reads wait while a claimed query is still in cancellable setup; if that setup ends before Security starts, a sibling can use the returned prompt budget. Once the read begins, the budget stays spent. If a prompt is cancelled, QuotaBar suppresses duplicate reads for the rest of that action; a successful grant clears the per-item block, and concurrent reads of that same item retry silently after the granted read returns. Credential writes also forbid authentication UI; if a rotated-token write requires interaction, QuotaBar returns a typed Keychain access error rather than prompting during persistence.
- If a newer manual Refresh supersedes a provider while it is loading credentials, QuotaBar discards that load before trying fallback credentials or publishing its stale result.
- Canceling a provider load or starting a newer manual Refresh invalidates the LocalAuthentication context attached to an active Keychain read. Security.framework's `SecItemCopyMatching` call is synchronous, so macOS does not guarantee when the call returns or the prompt disappears after invalidation. QuotaBar keeps the interactive-query slot occupied until the call returns.
- The one-shot `quotabar` command reuses this same persisted cache for five minutes, refreshes missing or stale entries without starting the app, and exits. Its account identity scan runs off the main actor along with provider credential loads. `quotabar --force` runs the same forced provider refresh as ⌘R regardless of cache age.

## Background refresh without opening the menu

Ask the running app to refresh local Codex and OpenCode accounting with this local notification:

```sh
swift -e 'import Foundation; DistributedNotificationCenter().postNotificationName(Notification.Name("com.quotabar.refresh"), object: nil, deliverImmediately: true)'
```

Bursts collapse into one request, and accepted requests are at least 15 seconds apart. The pass runs
with the panel closed and keeps the normal cache and failure backoff. Codex and OpenCode snapshots
are invalidated so their accounting actually runs; that can also call their provider APIs. Other
providers refresh only when their normal cache is stale. `notifyutil` uses a different notification
channel and does not trigger this path.

Router accounting keeps compact daily checkpoints. An unchanged ledger reads no event bytes, and
an append reads its new bytes. Rotation, rewriting existing data, a new accounting window, or changed
prices can require rebuilding. The initial compact router fold runs without the pacing delay so it
can finish within the provider deadline; the rest of instrumented automatic accounting remains paced.
- While a provider is fetching, a small spinner appears next to its name (and one shows in the footer beside the countdown), so you can tell a refresh is in flight rather than wondering if the numbers are stale.
- With [iCloud Sync](icloud-sync.md) on, a refresh batch writes one machine-history file after the whole
  batch finishes. Manual provider refreshes write after that provider finishes, and adjacent changes are
  debounced into one write.

## Idle behavior

The panel window stays ready between opens. Its dashboard content mounts only while visible and is
released when hidden. Opening it rebuilds the content from cached usage and starts its visible
countdowns; a closed panel has no dashboard timers or animation loops running.

Lightweight provider refreshes remain active while the panel is closed so the menu-bar strip stays
current. They honor the snapshot cache and failure backoff, normally fetch pinned provider meters
concurrently (serializing under memory pressure), and coalesce menu-bar image updates when several
accounts publish state together. Notification evaluation also skips metric resolution when all
notification triggers are off, while still pruning its deduplication state.

## Caching

Snapshots are cached on disk and load instantly at launch, so you see your last-known values immediately instead of placeholders — even before the first fetch finishes.

Claude and Codex cache entries also remember which account produced them. If you swap the account
signed in at the provider's default home between launches, the previous account's cached values are
discarded at the next launch (the card starts empty and fills on its first fetch) instead of briefly
showing the old account's limits and plan under the new login.

A cached value only counts as *fresh* (skip-a-refresh fresh) when it was fetched **during the current running session**. So a value cached in an earlier session always re-fetches on the first pass after launch — you still see it instantly, but the app never waits out the old interval before getting live numbers. This matters after an update: a new app version refreshes right away instead of showing the previous version's data until its interval lapses. Within a session, live quota meters count as fresh for 50 seconds; the scheduler requests them every minute on AC or every two minutes on battery / Low Power Mode while closed. Full/history data keeps the five-minute interval.

Claude, Codex, and pi spend history has a separate local-log parse cache under
`~/Library/Application Support/QuotaBar/log-scan-cache/`. It stores parsed usage events before QuotaBar
applies model-rate estimates, so pricing updates take effect without re-reading unchanged JSONL. On
relaunch, an entry is reused only when its path, size, modification time, and parser version still match.
Same-home cards share parsed data, and changing one source file rewrites only that file's record. Old files
leave the cache as the history window advances, and identities unused for 35 days are removed. App writes
are debounced until after refresh; the one-shot CLI drains pending writes before it exits.

When macOS reports memory pressure, QuotaBar saves pending parse-cache writes and releases in-memory
Codex event arrays in the background. This cleanup does not require the main thread and keeps the app
running without clearing the usage values already on screen.

## When a fetch fails

A failed refresh **never wipes your data**: the last good values stay on screen, and a small warning triangle appears next to the provider's name — hover it for the error message (e.g. "Not logged in"). The error clears on the next successful refresh.

Repeated scheduled failures with the same message are logged once until the provider recovers; a forced refresh still logs its result so an explicit retry remains visible.

A provider that stops responding altogether is given up on after two minutes. Its spinner stops, the
warning triangle reads "Refresh timed out after 120s", and it is tried again on a later pass — so one
stuck provider can't leave a spinner turning for the rest of the session. The wait is deliberately long:
a healthy provider on a slow network can legitimately take over a minute, and it should be reported as
slow, not as broken.

The last good normalized history is preserved too, so a temporary provider failure—or a successful
limit refresh whose local log scan is temporarily unavailable—does not remove this Mac's previous
contribution from an iCloud-combined spend total.

Rows that have never had data show "No data" rather than made-up numbers.

## Stale data

Because a failed refresh keeps the last good values on screen, those values can persist if refreshes keep failing — so a plan or limit that changed on the provider's side could otherwise keep showing the old figures indefinitely. To make that obvious, a small **"Outdated"** tag appears next to the provider's name once its data is more than a couple of refresh cycles old (about ten minutes); hover it for the precise age ("Last updated 3h ago"). The tag stays short so it never crowds a long plan name. When you see it, the numbers below are from that earlier time, not live — usually because the provider is failing to refresh (check the warning triangle) or the Mac was asleep. A successful refresh clears it.
