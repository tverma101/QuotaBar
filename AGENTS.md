# AGENTS.md

QuotaBar is a SwiftPM-based SwiftUI menu-bar app for macOS that shows AI provider usage widgets (Claude, Codex, Cursor, Grok, Devin, and more).

This file documents the engineering conventions for the project. Read it before contributing.

## Agent Instructions

AGENTS.md is the source of truth for agent instructions in this repository. CLAUDE.md files may only point to the nearest AGENTS.md file with `@AGENTS.md`; do not add guidance, duplicate instructions, or project rules to CLAUDE.md.

> **Repository note:** QuotaBar is a fork of [OpenUsage](https://github.com/robinebers/openusage), developed in the open. See [UPSTREAM.md](UPSTREAM.md) for what has diverged.
> Do not use the OpenUsage name or logo in code, UI, or assets — see `TRADEMARK.md`. Keep `LICENSE`,
> `CODE_OF_CONDUCT.md`, `SECURITY.md`, `CONTRIBUTING.md` and upstream attribution intact, and read
> `UPSTREAM.md` before touching shared code so local deltas stay traceable.

## Releases

There is no release automation. `main` is the development line; releases are built and installed by
hand with `./script/build_and_run.sh build`.

### Guardrails (do not break)
- **Never increase the version number on your own initiative — ask for explicit approval first.**
  Versions continue upstream's `0.7.x` line so the two codebases stay comparable.
- The app has **no auto-update path**. Sparkle needs a public repository; this one is private. Do not
  reintroduce an updater without also solving feed hosting.
- iCloud Sync is inert: its container must be registered in the owner's Apple Developer team first.
  Do not treat the Settings section as a working feature.

## Architecture

- SwiftPM executable target; SwiftUI content hosted in an AppKit-owned `NSStatusItem` + custom key-capable `NSPanel`.
- The CLI product is `quotabar-cli`, not `quotabar`: a bare `quotabar` collides with the `QuotaBar`
  library target's build output on case-insensitive filesystems and breaks the app link step.
- Swift 6 with strict concurrency.
- Providers implement the small `ProviderRuntime` protocol: an auth store reads credentials already on the user's machine, a usage client calls the provider's API, and a mapper normalizes the response into `MetricLine` values. The UI renders those normalized values.
- See `docs/` for behavior docs and the developer docs (architecture overview, adding a provider).

## Providers

Conventions for the per-provider modules under `Sources/QuotaBar/Providers/<Name>/`.

- **Structure:** one folder per provider with an auth store (reads credentials already on the user's machine), a usage client (calls the provider API), and a mapper (normalizes to `MetricLine`), conforming to `ProviderRuntime` — `refresh()` plus `hasLocalCredentials()`, the local-only credential probe used by first-run detection (`FirstRunSeeder`) and by new-provider detection on the first launch after the provider ships (`NewProviderSeeder`); mirror the same local credential sources and usability filters that `refresh()` starts with, reusing the auth-store loaders instead of adding a second credential-reading path. See `docs/adding-a-provider.md` and `docs/provider-enablement.md`.
- **Model pricing:** all spend imputation (Claude, Codex, Cursor, Grok) prices through the shared engine in `Sources/QuotaBar/Pricing/` (see `docs/pricing.md`). Cursor-native model rates and alias rules live in `Sources/QuotaBar/Resources/pricing_supplement.json` — sync new or changed models from [Cursor models & pricing](https://cursor.com/docs/models-and-pricing.md) (update `updated_at`, pricing entries, and `alias_rules` for CSV model slugs). QuotaBar reads the supplement from **upstream's** public URL rather than publishing its own, so upstream's edits still reach installed apps. The bundled LiteLLM/models.dev snapshots regenerate with `script/update_pricing_snapshots.sh`.
- **Default order:** Claude, Codex, Cursor first (the established providers, in that order), then every other provider alphabetically by display name (Antigravity, Devin, Grok, …). The order is the array order in `AppContainer`, which seeds `LayoutStore`'s default provider order (and `resetToDefault`). A new provider slots into the alphabetical tail.
- **Metric placement defaults:** when adding or changing a metric, confirm its four defaults with the owner before choosing — never pick silently:
  1. enabled on/off (`DefaultLayout.metricIDs`),
  2. Always Visible vs. On Demand — above the fold vs. behind the per-provider caret (`DefaultLayout.expandedMetricIDs`). Note: a provider always keeps at least one Always Visible row — the dashboard promotes all metrics when every one is marked On Demand, so a fully On Demand provider isn't possible; leave one metric Always Visible for the caret to appear,
  3. pinned to the menu bar (`DefaultLayout.pinnedMetricIDs`),
  4. order (within a provider, the `widgetDescriptors` declaration order).

## Building

`swift build` and `swift test` are the normal commands, but the single `QuotaBar` module is large
enough that `-emit-module` is the peak-memory step of the whole build. On a machine under memory
pressure the kernel kills `swift-frontend` mid-`emit-module` and SwiftPM reports only
`error: SwiftCompile ... failed with a nonzero exit code` — with no compiler diagnostic, because the
process never got far enough to emit one. Confirm the cause before debugging the code:

```sh
ls -t /Library/Logs/DiagnosticReports/JetsamEvent-*.ips | head -1   # "reason" : "per-process-limit"
```

When that is what happened, cut the build's own memory rather than changing source:

```sh
swift build -j 2 --disable-index-store
```

`--disable-index-store` skips the module index, which is IDE-only metadata but a large consumer during
`emit-module`. Adding `-j 1` and `-Xswiftc -gnone` also helps. None of these fix the underlying cause —
`Sources/QuotaBar` is one 262-file module, and splitting it is the real remedy. A 1 MB `.build` lock
left by an interrupted build, or a stale `XCBuildData/build.db`, shows up as a *hang at 0% CPU* rather
than a crash; `rm -rf .build/out/Intermediates.noindex/XCBuildData .build/.lock` clears it.

## Running / Testing Changes

- There is no hot reload. The app is a long-lived menu-bar process, so **every code change requires a full rebuild and restart of the running app** to take effect — kill the running instance, rebuild, and relaunch before testing.

## Pull Requests

Every PR description must follow this structure so reviewers can skim it quickly:

- **TL;DR** — open with a one- or two-sentence plain-English summary of the change.
- **What was happening** — plain-English bullet points describing the prior behavior, bug, or gap that motivated the change.
- **What this changes** — bullet points describing what the PR actually changes.
- **Heads-up** (optional) — noteworthy things a reviewer or future maintainer should consider (risks, follow-ups, trade-offs).
- **Tests** (optional) — how the change was verified.
- **Screenshots** (optional in general, but **required for any PR that makes a visual change**) — images of the affected UI after the change.

## Documentation

- Logic changes must update any docs in `docs/` that describe the affected behavior.
- Keep docs simple, less-technical, and easy to skim; exclude visual design details.

## Code Conventions

- Add a regression test when fixing a bug, where it fits.
- Keep files under ~500 LOC; split or refactor as needed.
- No new dependencies without justification.
- When adding a provider, follow the conventions in "## Providers".

## Error Handling

Always fail loudly into error logging (log file, PostHog) and show friendly errors to the user. Do not add silent fallbacks that hide real problems. Only validate at system boundaries (user input, external APIs); trust internal code and framework guarantees.

## UI

- Use title case for any hardcoded copy used as a title.
- Match the existing design language; QuotaBar has a specific look and feel, inherited from OpenUsage.
- Only add tooltips (`hoverTooltip`) when explicitly asked to. Don't add them proactively to new controls.
