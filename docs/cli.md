# Command-Line Interface

QuotaBar ships a one-shot `quotabar` command for agents and scripts. It prints the documented
[`/v1/limits`](local-http-api.md#get-v1limits) JSON and exits; it never launches or leaves the menu-bar
app running. The output contains stable scalar limits and balances, not UI rows, colors, subtitles,
charts, or spend-history tiles.

```sh
quotabar                 # every enabled provider, refreshing stale cache entries
quotabar codex           # one provider, refreshing when its cache is stale
quotabar codex --force   # refresh through the shared provider engine, cache, print, exit
quotabar freebuff --diagnose --force # refresh and inspect backend metrics without opening the panel
```

The command and app import the same providers, authentication stores, pricing, refresh coordinator, and
snapshot cache. A normal read reuses snapshots less than five minutes old and refreshes missing or stale
ones. `--force` is the CLI equivalent of the app's manual refresh: it bypasses that freshness gate and
writes successful results to the same cache. The CLI applies the same settings migration and fresh-install
provider defaults, then honors the saved provider choices. Naming a provider is a one-action request for
that provider; it does not enable other providers whose local history may feed OpenCode. Credentials are
used locally and never appear in the output. Refreshes receive a shared per-provider order when they start,
so a slower older result cannot replace a newer app or CLI result. Meter-only and history-only writes merge
their updated data into the latest persisted snapshot.

A provider argument names providers by plain string matching, exactly like the
[local HTTP API](local-http-api.md): an exact provider ID names that provider, and a family ID
(`claude`, `codex`) names every account card of that family — with one account that's exactly the one
card, so existing usage keeps working unchanged as multi-account support arrives. The output envelope
contains every matched provider; an ID that names nothing exits with an error. There is no aliasing
or account-picking logic.

## Install on `PATH`

In QuotaBar, open **Settings → Command Line** and click **Install…**. After the standard macOS
administrator prompt, `quotabar` is available globally in new terminal sessions. The installed symlink
points to the signed helper inside QuotaBar, so in-place app updates also update the command.

Exit codes are `0` for success, `2` for invalid arguments or an unknown provider, and `4` when a
refresh or local read fails.

## Backend Diagnostics

`--diagnose` prints `quotabar.diagnostics.v1` JSON instead of scalar limits. The report contains
normalized snapshots and token coverage, resolved widget values, enabled and pinned metric IDs,
active session clocks, separate quota/history ages, and explicit findings. It uses the app's
provider, widget, and menu-bar data paths without rendering views. `--force` requests a fresh read;
without it, the normal shared-cache rules apply. Warnings and errors produce exit status 4, while
still returning the report. Diagnostic output includes usage and model names; review it before sharing.

If macOS grants a provider's Keychain item to the app but not its CLI helper, the installed app
executable supports the same headless path:

```sh
/Applications/QuotaBar.app/Contents/MacOS/QuotaBar --diagnose freebuff --force
```

This exits before starting SwiftUI, the menu-bar controller, servers, or timers. It can run beside
the normal app and uses its existing silent credential access. Refresh errors stay visible even
when usable older snapshots or newly scanned local history remain available.
