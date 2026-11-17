# Upstream provenance

Status: **owned fork.** This resolves the question left open by issue #41 in `tverma101/Tools`,
where this tree was vendored and tracked with no commits and no recorded provenance.

## Upstream

- Repository: `https://github.com/robinebers/openusage`
- Author: Robin Ebers
- License: MIT (see `LICENSE`)
- Brand: the OpenUsage name and logo are trademarks of Robin Ebers and are **not** used here, per
  `TRADEMARK.md`. This project is a fork and is not the official OpenUsage.

## Imported revision

The subtree arrived in `tverma101/Tools` with its history squashed to nothing — 544 tracked files,
zero commits — so the original revision could not be recovered from local Git history.

It is now pinned by this repository's own history instead:

| Commit | What it is |
| ------ | ---------- |
| `3866cd1` | `chore: establish as-is baseline of vendored OpenUsage tree` — verbatim import, before any local change |
| `5818ab1` | `refactor: drop Sparkle auto-update pipeline` |
| `17776c5` | `refactor: rebrand OpenUsage to QuotaBar` |

`3866cd1` is the exact upstream-equivalent tree, so `git diff 3866cd1..HEAD` is the complete local
delta. The upstream version at import was `v0.7.10-beta.3`, per `CHANGELOG.md`.

To recover the true upstream SHA, diff this tree against upstream tags rather than guessing:

```sh
git clone https://github.com/robinebers/openusage /tmp/openusage-upstream
git --no-pager diff --stat 3866cd1 -- /tmp/openusage-upstream   # compare trees
```

## Local deltas from upstream

Local changes that matter when syncing shared code:

1. **Sparkle auto-updates removed** (`5818ab1`). Sparkle fetches its appcast and DMGs anonymously,
   through an upstream-owned, signed update feed. QuotaBar now has a public repository but no
   QuotaBar-owned feed or release-signing pipeline, so its updater, Settings section, dashboard banner,
   release workflow and GitHub Pages workflows remain removed. Releases are manual.
2. **Rebrand to QuotaBar** (`17776c5`). Required by `TRADEMARK.md`. Build identity, user-facing
   strings, on-disk paths and the bundle id all changed. Internal symbols (`OpenUsageISO8601`,
   `Bundle.openUsageResources`) were left alone deliberately, to keep the upstream diff small.

3. **Shared model pricing catalogue.** QuotaBar adds OpenRouter as a dynamic rate source and places
   verified supplement overrides ahead of it. The supplement still reads from upstream's public URL,
   and the LiteLLM/models.dev snapshots remain local bundled fallbacks. Review pricing precedence and
   its cache behavior when syncing upstream changes to the shared pricing engine.
4. **Snapshot-only menu presentation and incremental accounting.** Opening the panel uses cached
   rows. CodexRouter and OpenCode keep compact local daily checkpoints; background refreshes read
   appended bytes and preserve the provider ownership split. Review these caches and their regression
   tests when syncing provider scanners or refresh behavior.
   CodexRouter checkpoints keep their file identity across catalogue changes and validate the rates,
   aliases, and dated fallbacks actually used before reusing a priced fold.
   Two priced variants share a cross-process write lock so app/CLI snapshots can both resume.
   Claude also reuses completed daily totals and a bounded gateway projection for unchanged sources,
   plus bounded append checkpoints for active session files. Preserve the local source-revision,
   ownership, cancellation, and memory-pressure checks when adapting upstream's tail scanner.
   Claude accepts nullable optional usage fields and ignores non-assistant usage objects. Antigravity
   correlates generation and step identities across row numbers, retaining only proven calendar days;
   undated records never become today's usage on launch. OpenCode reads both SQLite message layouts
   and deduplicates migrated IDs. Reasoning-only Router records keep their measured lower bound
   without blocking independent OpenCode history. Completed Router prefixes remain usable through ordinary appends during the wider fold; rewrites and replacements still invalidate them. Preserve these format-compatibility fixes.

## Local deltas — 2026-11-16

Beyond the rebrand, the fork adds a Total Spend panel **TPS lens** (`AIProvider`-free; a TPS fold of every local-log
corpus (Claude Code, Codex, Grok, Muse, Pi, Z.ai, Antigravity) surfaced through `TotalSpendCard`,
never a dashboard card) and shared panel chrome
(`ShareCardRenderer`, `TPSSpendPanel`, `TPSTotal`). Upstream rebuilt its panel around Priority in 0.8 —
fork deltas in `TotalSpendCard`, `DashboardContentView`, `TotalSpendAggregator` and `MetricFormatter`
conflict with that 0.8 work and need manual attention if upstream's spend UI is ever adapted.

## Selective sync — 2026-10-21

Compared upstream `26132ff48d` (2026-10-18). Adapted these improvements without importing upstream branding, updates, provider activation, or pricing policy:

- `063eb0661ca810905e3f981aaaaff95a7df2e66e` (#1395): Argon Weekly quota, legacy-pool exclusion, and public limit export. Owner defaults: enabled when data exists, On Demand, unpinned, after Weekly; manual off persists. Existing fork Argon pricing already covers the rates and aliases.
- `9e6d36235263e3b06087be7cafc35395ebd8f5ba` (#1407): complementary Cloud Code quota summaries and paid-tier ID mapping. Retains the fork's host order, cancellation/auth classifications, schema diagnostics, and conservative freshness rules. Stops after a complete shared summary; a failed supplemental host cannot clear old omitted meters.
- `eab20cfda184b2743c9c9e3ad561abad92abb4f0` (#1409): identity-safe Cursor membership badges, percent-only org totals, and missing Extra Usage enrichment. Optional requests remain limited to org/team-shaped seats and use the fork's rate-limit/error gates.

Deferred the Claude reset-credit/claim dependency chain (new metric and write workflow), Cursor's replacement day-by-day history stack (overlaps the fork's verified CSV accounting), and deferred snapshot persistence (conflicts with cross-process freshness fences). Registry lookup caching is already present. These are fit decisions, not a blanket upstream merge.

## Update procedure

Refreshing from upstream is now safe and reviewable:

```sh
git fetch upstream
git diff HEAD..upstream/main --stat     # what upstream changed
git merge upstream/main                 # conflicts are expected in rebranded files only
swift build && swift test
```

Expect conflicts in anything that carries the product name. Resolve toward QuotaBar naming.

## Agent modification policy

QuotaBar is a maintained fork, so the old "do not edit this subtree" quarantine no longer applies.
The engineering conventions in `AGENTS.md` govern. The upstream notices — `LICENSE`,
`CODE_OF_CONDUCT.md`, `SECURITY.md`, `CONTRIBUTING.md`, `TRADEMARK.md` — must not be removed or
rewritten, and upstream attribution must be preserved.

## Popup adaptation — 2026-11-07

Adapted upstream `214ba770`: the screenshot action appears while the pointer is over a provider card. The existing single dashboard and customization controls remain in place.

## Claude billing currency adaptation

Adapted upstream `8a883219` to carry Claude Extra Usage's billing currency and minor-unit scale through
the dashboard and local limits API. Existing USD output and the fork's uncapped-row behavior are retained.

## Usage-UX polish adaptation — 2026-11-16

Adapted upstream v0.8.0-era panel feel (presentation/motion only — the Priority board, All Usage tab,
accounts sign-in, and their dependencies stay out). Compared against upstream through `upstream/main`.
The fork KEEPS: Total Spend, local-log providers and spend tiles, menu-bar stars/pins, the On Demand
caret, customization/hidden metrics, and the fork's design language. Nothing was removed. Where
upstream's substance conflicted with a fork feature, the fork won.

### Antigravity (workstream A)

- `ee9815937de6d52ae490f2d8de2412fadc26916d` (#1641) — **adapted.** Quota summaries stay daily-first for the merged-pools read, with production as the fallback/fill (the fork already preferred daily for quota reads; made explicit — production fills omitted buckets per the fork's conservative completeness merge). Plan and project lookups (`loadCodeAssist`) now prefer production as upstream did — daily has the active counters for quota reads, not for plan/project. Legacy per-model endpoints keep daily-first. A 401/403 refusal on the first host no longer short-circuits the summary read when nothing was measured: both hosts are consulted and the failure is classified afterwards (daily can refuse a token production accepts), and the two-host-refusal contract is tested. The mapper no longer rounds the fraction-derived percent — an in-flight Gemini session at 99.965% remaining now reads "100%" with its countdown instead of "Not started"; "Not started" still keys off exact zero usage. Tests: ported the freshness/countdown cases to the fork's API, added `AntigravityUsageClientTests` for host order, omission fill and the 401/503 fallback, made the float-sensitive assertions accuracy-based, and updated the cancellation/refresh-retry expectations for the two-host classify. Not ported: sending the `cloudaicompanionProject` on the summary read (the fork never carried one; it changes the request Google sees and needs owner validation against a live account — the plan/project reads themselves moved to production-first). The fork's auth-error classifications, cancellation handling, schema diagnostics and Argon behavior are unchanged.
- `61333460be8e099b2fde39dd7c04d0b016627cce` (#1510) — **not imported; substance already present.** The fork has no `AccountProviderRuntime`/accounts-sign-in path: it refreshes the existing Keychain login with its own Google OAuth grant once on evidence of an auth failure, retries the read once, and reports expired sign-in on a second refusal; a failed plan/project lookup is never cached (it runs fresh on every refresh), so the retry-the-project-lookup half holds as well. The fork's cancellation and auth-error classifications are kept intact. The `docs/refreshing.md` diff has no fork analog (the fork doesn't enumerate the 401-renewal providers there). Do not import the accounts code path wholesale to get this; if the fork ever adopts accounts sign-in, re-evaluate.

### Panel / dashboard chrome (workstream B)

- `e86a9a6e7f2ab7456e796ac79b2a641d1cca54f9` (#1345) — **taken.** The panel's frame snaps to whole points (top edge down, height rounded), so it no longer shakes by 1 pt under the menu bar during the height morph. Test added; `docs/architecture.md` notes the whole-point frame.
- `8f9720b4eb01f914cb8bf851f950044d6728a236` (#1458) — **adapted.** The 200 pt floor (`PanelGeometry.minimumHeight`, a single value in the fork, not upstream's per-screen split) is gone; the controller clamps with `min(rawHeight, maximumHeight())` — the room below the anchor and 85% of the display, nothing else. Upstream's hosted-popover/`ScreenSlideTests` harness is accounts-architecture test code and not present in the fork; equivalent coverage of the rest-at-content-height behavior would need a hosted-popover harness the fork doesn't have (see follow-ups).
- `9d58bb269317c356b3996b18a9e2a5c6d1d8097e` (#1470) — **adapted.** The SwiftUI hosting view is a subview of the panel's content view (`MenuBarPanel.host(_:)`, `sizingOptions = []`, fill via frame + autoresizing), never the content view itself, so SwiftUI can never set the window frame. The fork already pinned the hosting view below a container rather than the content view; this simplifies it to upstream's shape, keeps the fork's backdrop as the lower subview, and drops the extra `NSHostingController`/container-VC layer. New `MenuBarPanelTests` structural check.
- `36f5d96eb1024e2427c7653f91a024020b99dc04` (#1490) — **taken.** A measurement that lands mid-slide now animates the height immediately instead of being deferred past the slide (macOS 15 measures after layout).
- `c5a2f410280ef2be7931929f0c5c03a0a2a5726f` (#1548) — **adapted/reworked** into the bars change below. Not taken as written: the `hoverHighlight` extraction targets upstream's account title and rows (no fork analog — the fork's Customize L2 back header is not a hover-account title), and the Settings `.scrollContentBackground(.hidden)` has no fork analog (the fork's Settings is custom cards, not a `Form`).
- `31f71093c82a7b09a41081539c22eb329a895c95` (#1549) — **adapted.** Content under the top bar is hidden behind the panel's surface (the opaque tray; a frosted `.regularMaterial` under Increase Transparency, since the fork has no always-opaque page), and the soft edge sits under the footer only. The fork's `safeAreaBar` + soft-edge-on-26 top/bottom chrome is replaced by this treatment.
- `5cfcad4e4861d783c1a047b02f41a77895e5254b` (#1619) — **adapted** (same rework). On macOS 26 and earlier the footer frosts what's under it with an in-window blur (`.menu` NSVisualEffectView, alpha driven by how much is under it, fading 10 pt above the bar) — the macOS 26 system edge didn't draw, leaving rows scrolled under the footer unreadable.
- `94aedf87f7035bb284f5780d5450aad91758a645` (#1619 follow-up) — **adapted** (same rework). macOS 27+ keeps the system soft scroll edge on the bottom bar (always hidden under the top bar, and hidden under the bottom bar while nothing is under it); macOS 26 and earlier share the in-window frost. macOS 15 is covered by the same frost path.
- `c35420ad0471031b860ba093f1b66fa77204809f` (#1615) — **adapted.** `Motion.navigation` (AppKit's 0.25 s easeInOut) runs the screen slide and its height morph; outside a slide the panel takes its new size in one step, like a native window (the in-screen spring re-target for growth/shrink becomes a step set); Customize's L1↔L2 pushes move at the same pace. The fork's own faster `modeSwitch` on chrome call sites was left alone (it isn't upstream's slide mechanism). Not ported: the `CapsuleSegments`/tab picker changes (the fork has no Priority/All Usage tabs) and the accounts/Hub page sites (no fork analog).
- `388ee5feebbcfda0092e5fd02ca9b59f0f59b4c8` (#1640) — **adapted, only the resize-cover half.** While the panel is at a different height than the page's measured ideal, the footer hides what's under it behind the panel's surface, so rows drawn a frame before the panel takes their height can't flash through the footer. Not ported: the press-to-switch tab behavior and everything tab-related (the fork has no tabs).
- `852b1bda7b9dd13ecd0e2088ed8f6ab6591e686d` (#1606) — **adapted, shared math only.** `Pace.elapsedShare` is extracted and shared by `Pace.evaluate` and the even-pace tick. Not ported: the "Pace Marks" Settings toggle (off by default), `DashboardRowModel.paceMark`, the `LevelIndicator` overlay tick, and the Priority-ring tick — the fork already ships the even-pace tick on ordinary bars (always on yellow/red, and on blue behind **Always Show Pacing**); upstream's toggle would either hide those by default (a fork regression) or duplicate the fork's setting. The fork has no Priority rings. `Pace.evaluate` keeps the fork's locked `used == 0 → ahead` behavior; upstream's `used > 0` guard would change the zero-usage tooltip the fork's tests pin.
- `9cdbb7b1a77a4b68604c54523fe35da7dd13fb13` (#1634) — **skipped.** The clock-width fix targets the fixed 60 pt lane of upstream's `weekdayTime` clock-reset column (widened to 80 pt). The fork has no fixed reset column: its absolute reset label sizes itself intrinsically, so there is nothing for a `Tue, 2:30 AM` string to collide with.

No Priority board, no All Usage tab, no accounts/sign-in rewrite (#1444), no removal of stars/pins/local-log spend, no iCloud-sync/local-API removal, no branding changes, no update-pipeline work. The fork's total-spend ring/card, the On Demand caret, the menu-bar strip, hidden-metric customization and design language are unchanged.

Follow-ups worth doing: a hosted-popover harness for panel rest-at-content-height coverage (the fork has no equivalent of upstream's `TestSupport`/`PanelContentHeightTests`); validating the `cloudaicompanionProject`-on-summary-read change against a live Antigravity account before enabling it.
