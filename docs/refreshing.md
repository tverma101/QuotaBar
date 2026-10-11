# Refreshing & Caching

## When data updates

- Enabled providers refresh once at launch. With the popover open, full-detail passes run every 5 minutes. With it closed, lightweight menu-bar passes run every 5 minutes on AC or every 15 minutes on battery / Low Power Mode. Opening the popover shows the last snapshot immediately and starts the two-phase refresh described below; Refresh Now can force-update it immediately. Providers normally fetch in parallel, so fast cards update without waiting for a slow one. The batch finishes after every provider returns; notifications, history sync, and the next wait begin after that point.
- A panel-open pass runs in two phases so the meters you are looking at land in seconds instead of trailing the slowest local log fold (~15–20s for the heavy providers). The first phase fetches every enabled provider's live quota meters and nothing else; the second phase recomputes local accounting (spend tiles, history) for the providers that have it, recovering the just-fetched meters onto the refreshed card. A full pass — one combined phase — remains the path for passes nobody is watching: Refresh Now, the CLI, background triggers, and the midnight rollover.
- A cached value's freshness also tracks its **meters**: a fold-only pass (the closed-panel ledger wakes, or the panel's accounting phase) recomputes spend/history while reusing the meters from the previous quota fetch. The cache counts such an entry as fresh only while *both* the history and the meter stamps are within the interval — so recovered meters age out on their own clock and the next panel-open pass re-reads the live quota API instead of cache-hitting on hours-old percentages.
- Background menu-bar ticks pace instrumented local accounting toward 7.5% of one CPU core. Explicit full-history reads (Refresh Now, the one-shot CLI, and the local API) use the 25% interactive budget when their accounting work is instrumented. Panel-open periodic passes and accepted background accounting triggers run full passes without pacing so the active pass does not inherit the background delay. CodexRouter and OpenCode also read a cold compact ledger without pacing to stay inside the provider deadline; persisted summaries make unchanged refreshes skip event bytes. The pacing target averages work over bounded slices, includes CPU from reaped helper processes, and is not an instantaneous hard cap. The repeatable benchmark covers a synthetic CodexRouter scanner/cache path, not every provider.
- Across a local-midnight rollover the next refresh pass widens to full scope, so Today / Yesterday tiles rebuild with the new day instead of re-showing yesterday's numbers under a fresh timestamp. Full passes also fold the **lifetime** window — the local log corpus in full — so the Usage History screen's Lifetime card stays current; the parse and aggregate caches make the deep fold incremental after its first pass, and the 30-day tiles clip the wide result by day key.
- Turning a provider on (yourself in Customize, or automatically by first-launch/new-provider detection) fetches it promptly instead of waiting out the interval — even when the change lands in the middle of a refresh that's already running.
- The Dashboard and Settings footer shows `Next update in Nm`. **Clicking it (or pressing ⌘R while that footer is present)** refreshes immediately, skipping the cache.
- The one-shot `quotabar` command reuses this same persisted cache for five minutes, refreshes missing or stale entries without starting the app, and exits. `quotabar --force` runs the same forced provider refresh as ⌘R regardless of cache age.

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
current. They honor the snapshot cache and failure backoff, serialize the launch pass, and coalesce
menu-bar image updates when several accounts publish state together. Notification evaluation also skips
metric resolution when all notification triggers are off, while still pruning its deduplication state.

## Caching

Snapshots are cached on disk and load instantly at launch, so you see your last-known values immediately instead of placeholders — even before the first fetch finishes.

Claude and Codex cache entries also remember which account produced them. If you swap the account
signed in at the provider's default home between launches, the previous account's cached values are
discarded at the next launch (the card starts empty and fills on its first fetch) instead of briefly
showing the old account's limits and plan under the new login.

A cached value only counts as *fresh* (skip-a-refresh fresh) when it was fetched **during the current running session**. So a value cached in an earlier session always re-fetches on the first pass after launch — you still see it instantly, but the app never waits out the old interval before getting live numbers. This matters after an update: a new app version refreshes right away instead of showing the previous version's data until its interval lapses. Within a session, a freshly fetched value then counts as fresh for one refresh interval before the next pass re-fetches it.

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
