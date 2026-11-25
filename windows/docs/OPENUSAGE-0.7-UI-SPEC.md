# OpenUsage 0.7 UI spec (Modern layout port)

QuotaBar’s [macOS reference captures](../../docs/windows-port/reference/macos/README.md) guide the **Modern** layout. Windows uses a 320-point tray popover that grows with its content up to the available work area limit.

## Screens (Modern shell)

| Screen | Swift reference | QuotaBar |
|--------|-----------------|------------|
| Dashboard | `DashboardView` | `ModernShell` → grouped provider cards (`WidgetGroupedList`) |
| Customize | `CustomizeView` | Provider list and detail with Always Visible and On Demand placement |
| Usage History | `UsageHistoryView` | Local retained totals, daily token chart, and account breakdown |
| Settings | In-popover sections on macOS | Grouped Windows controls across General, Tray, Look, Providers, and Advanced |

Modern is the Windows default when there is no saved layout. From the dashboard, **Options** opens Customize, Usage History, Settings, About, and Quit. **Esc** goes back one screen at a time, then hides the panel. **Ctrl+,** opens Settings.

## Metric identity

- Canonical id: **`${pluginId}:${lineLabel}`** (matches `plugin.json` `lines[].label`).
- Descriptor catalog built at runtime from manifest + probe output.
- `bounded` = progress lines with percent format; `unbounded` = text/spend lines.

## Layout state (`modernLayout` store key)

| Field | Purpose |
|-------|---------|
| `placedMetricIds` | Dashboard-visible metrics |
| `providerOrder` | Legacy stored order; current card order comes from `plugins.order` |
| `metricOrderByProvider` | Row order within card |
| `onDemandOverrides` | Saved Always Visible and On Demand choices per metric |
| `pinnedMetricIds` | Tray strip (Modern only); max **2 per provider** |
| `initialized` | First-launch defaults applied |

Defaults ported from upstream `DefaultLayout.swift`. Migration: legacy `trayLines` → seed `pinnedMetricIds` on first Modern init.

As of 2026-11-01, both dashboard cards and Customize use `plugins.order`. Startup normalization must preserve the saved relative order of known providers, discard duplicate/unknown IDs, and append newly discovered providers. Alphabetically sorting the full list during normalization overwrites drag-and-drop choices on every launch; changing `modernLayout.providerOrder` does not fix that behavior.

## Widget rows

Port of `WidgetRowView.swift`:

- Label + pace dot / run-out warning
- Capsule meter (pace colors; shared with Classic `PaceIndicator` logic)
- Primary: **X% left** ⟷ **Resets in …** (`displayMode`, `resetTimerDisplayMode`)
- Unbounded spend rows clustered (Today / Yesterday / …)

## Tray (Modern)

- `buildMenuBarContent(pinnedMetricIds, …)` → `TrayPrimaryBar[]`
- `use-tray-icon`: when `uiLayout === "modern"`, render pins as bars strip; Classic keeps `trayLines` / `getTrayPrimaryBars`.
- Tests: `modern-layout.test.ts`, `menu-bar-content.test.ts` (pin cap, order, disabled provider).

## Appearance (Modern-only settings)

- **Density** (`regular` | `compact`) — row padding/fonts via `data-density` on shell
- **Reduce transparency** — use existing `themeMode` solid/glass paths

## Release (1.1.1 at upstream GA)

When upstream tags **`v0.7.0`** (non-prerelease):

1. `git fetch upstream --tags`
2. `git diff feat/port-openusage-0.7-prep...v0.7.0 -- plugins/` — gap-fill
3. Diff `upstream/swift` UI commits since last port; adjust Modern components
4. `bun run test`, `cargo test`, manual Classic + Modern smoke
5. Bump **1.1.1**, release; ~7d later merge **1.2.0** polish branch

See [FORK-UPSTREAM.md](./FORK-UPSTREAM.md).
