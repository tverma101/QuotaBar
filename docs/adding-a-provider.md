# Adding a Provider

How to add a new AI provider to QuotaBar. Read the [architecture overview](architecture.md) first so the
pieces below make sense.

## What a provider is

A provider implements `ProviderRuntime` under `Rust/quotabar-engine/src/providers/`. It has three parts:

- an **auth store** that reads credentials already on the user's machine (config files, keychain),
- a **usage client** that calls the provider's API,
- a **mapper** that turns the response into the app's metric vocabulary.

QuotaBar normally reads the companion CLI or app's existing login. API-key-only providers use the
settings workflow described below.

Besides `refresh`, every Rust provider implements `has_local_credentials`, a local-only check of whether
its setup credentials exist, without contacting the provider. Customize uses this probe to mark
matching setups on the Mac. The probe must stay silent and mirror the credential sources `refresh()`
reads. Its result is a hint only: optional providers stay off until the user selects them in Customize.
The Swift wrapper calls `RustEngine`, which runs blocking work away from the UI thread. See
[Which Providers Are On](provider-enablement.md).

## The metric contract

`refresh()` returns a `ProviderSnapshot` whose `lines` are `MetricLine` values. Pick the case by the shape
of the number, not by the provider:

- **`.progress`** — a bounded meter with `used`, `limit`, and a `format`:
  - `.percent` for quota-style limits (session, weekly),
  - `.dollars` for a capped dollar amount (credits with a ceiling),
  - `.count(suffix:)` for a capped count (e.g. requests per cycle).
  - Add `resetsAt` when the window resets at a known time, and `periodDurationMs` for the cycle length.
- **`.values`** — an unbounded row carrying one or more raw numbers (each a `MetricValue`: a number, its
  kind, an optional unit label like `"tokens"`). Use it for any limitless numeric row — a spend day carries
  dollars *and* tokens, Codex credits carry dollars *and* a count. The widget picks which to show
  (cost-only, tokens-only, or both) via its descriptor, and formatting happens at the display edge, so the
  menu bar never re-parses a string. Prefer this for numbers.
- **`.badge`** — a short status pill, like `Disabled` or a pay-as-you-go cap. Use it for state rather than
  a fillable number.
- **`.chart`** — dated numeric points for a compact usage-trend row.
- **`.text`** — a string-valued provider notice preserved in the local API. It does not render a widget;
  use `.progress`, `.values`, `.badge`, or `.chart` for every descriptor-backed row.

Set the snapshot's `plan` when the provider exposes a plan name. On failure, return
`ProviderSnapshot::error` with a user-facing message and an `ErrorCategory`. Telemetry uses the
category to group failures. Report incomplete scans and honor cancellation.

## Steps

1. **Check first.** Look at open issues and `docs/providers/` to see if the provider is already requested
   or in progress.
2. **Create the Rust module.** Reuse the shared HTTP, parsing, accounting, and host services. Use the
   same credential loaders for setup probes and refreshes. Honor the refresh scope so a history
   scan can run independently of live quota requests.
3. **Declare its widgets.** Add a Swift wrapper under `Sources/QuotaBar/Providers/<Name>/` that calls
   `RustEngine.refresh` and `RustEngine.hasLocalCredentials`. Declare metrics with the factories in
   `WidgetDescriptor+Factories.swift` (`percent`, `boundedDollars`, `spend`, `tokenSpend`, `combined`, `values`, `badge`, and so on).
4. **Register it.** Add the runtime to the Rust provider registry in `src/providers/mod.rs` and the
   Swift wrapper to `ProviderCatalog`. Confirm widget defaults with the project owner.
5. **Test it.** Put mapper, credential, and scanner fixtures in the Rust engine tests. Use Swift
   tests to verify widget and bridge behavior.
6. **Document it.** Add a page under `docs/providers/` covering what it tracks, where its credentials come
   from, the endpoints it calls, and what its error states mean.
7. **Run it.** Build and launch with `./script/build_and_run.sh` and confirm the provider shows up.

## Conventions

- Validate only at the boundary (the API response); trust the app's internal types.
- Match the metric labels and units the provider's own dashboard uses, so numbers are recognizable.
- Declare the provider's **quick links** on its `Provider` value (`links:`). Each link is a `ProviderLink(label:url:)` rendered as a button in the card's expanded area that opens the URL in the default browser. Ship the provider's own Status / Console / Dashboard pages where they exist; leave `links` off (it defaults to empty) for providers without any. Cap at **two** links per provider (standard labels: Status, Dashboard, API Keys, or Usage). Only `http(s)` URLs with a non-empty label render.

## Keychain credential reads

- Use the engine's `SecureReadRequest::for_refresh` for refreshes and `SecureReadRequest::silent` for
  setup probes. The Swift host uses the request ID to recover the explicit Refresh action's
  interaction budget.
- Pass the provider's known account name so reads and prompt suppression stay scoped to the exact item. Codex profiles, for example, have separate account names derived from their `CODEX_HOME` paths.
- Keep credential probes local and silent. Do not enable interaction from `hasLocalCredentials()`.
- Only explicit Refresh actions run inside `withManualRefresh`. `loadOffMainActor` carries that context through its detached task, including the shared one-dialog budget. Background, panel-open, and startup passes stay silent.
- A cancelled prompt is suppressed for the rest of that action; a later user-requested Refresh clears the previous decline and allows one new prompt for the whole provider batch.

## User-supplied API keys

Most providers read credentials already on the machine (a companion CLI/app's session, the keychain).
A provider with nothing local to read — OpenRouter is the first — conforms to `APIKeyManaging` so the
in-app **Settings → API Keys** card manages its key with no per-provider UI work:

- The auth store exposes a four-state `keyStatus()` (`notSet` / `fromEnvironment` / `saved` /
  `overrideActive`), a `currentAPIKey()` for the reveal toggle, and `saveAPIKey(_:)` / `deleteAPIKey()`
  that write to a config file the auth store already reads. Config-file precedence over the env var is
  what makes a saved key an override for free.
- The provider conforms by delegating those to its auth store, and reports its storage path and env
  name for the card's copy.
- `AppContainer` collects every `APIKeyManaging` provider into `apiKeyProviders`, which the card
  lists. Add the provider to the registry as usual and the card picks it up.

Persist the key to a file the auth store already checks (don't introduce a parallel store), so the
file remains the source of truth and a user can still edit it by hand.
