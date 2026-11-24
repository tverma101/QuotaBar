# Menu Bar

Star your most important metrics straight into the menu bar strip.

## Right-clicking the icon

Right-click (or control-click) the QuotaBar menu bar icon for a quick menu with **Settings** and **Quit**. QuotaBar keeps one status item and one shared panel regardless of provider count, so two Codex accounts and Cursor remain together in the same dashboard instead of looking like duplicate apps.

## Usage History

Hovering a spend value shows its model breakdown. Tapping the value opens the same breakdown
without the hover wait, and the value's touch area reaches a little past the text so the tap lands
easily. The top three models keep their own rows and the rest stay together as **Other**,
which lists each one's name, measured tokens, and cost or **Unpriced** once. A single small model,
or the one model that accounts for Other's whole price, keeps its own row, so the same tokens and
cost are not shown twice. Missing older model labels remain explicit usage categories rather than
being counted as additional named models. When Other has more contributors than fit, the list
scrolls inside the popover. The breakdown stays put while you tap around the panel; it closes once
the pointer leaves it, another breakdown takes its place, or the panel itself closes.

The dashboard footer's **Options** menu → **Usage History** opens a read-only report built from the same local usage data as the spend tiles. Its **Cost Source** selector changes dollars only; measured token totals and dashboard, menu-bar, and CLI spend remain unchanged.

- **Reported Only** (default) sums dollar amounts recorded by providers. Missing costs remain blank, and known partial coverage is marked rather than filled with estimates.
- **API Estimates** compares measured tokens with published API rates; it is not a bill. Only priced usage contributes, so totals are lower bounds when some usage has no public rate. Model rows may remain dollar-free when the estimate cannot be safely carried to individual models.
- **Lifetime** — the selected cost source across retained history (up to 10 years), dated by its earliest day ("Since Mar 2026"). Claude, Codex, and Grok fold up to ten years of local logs; sources with shorter scan or retention windows contribute only the history they preserve.
- **Today / 7 Days / 30 Days** summary cards: tokens always, plus the selected cost source or a dash when no amount is available.
- A **daily token trend** across the 30-day window, with one bar for every calendar day including idle days.
- One section per enabled provider with **per-model rows** for the window: tokens plus cost where its provenance is available (or a dash); see [Pricing](pricing.md).

## Generation Speed

Open **Options → Generation Speed** in the dashboard footer to see [average output speed by provider and model](dashboard.md#generation-speed) for ZCode and Antigravity.

## Starring

Star a metric from any row's right-click menu, or from the always-visible star beside a metric in Customize.

- On first launch the app ships with a default set of stars (Antigravity Session/Weekly, Claude Session/Weekly, Codex Session/Weekly, Cursor Models/Other Models, Freebuff Daily Hours, Copilot Credits, OpenRouter Credits, Z.ai Session/Weekly) so the strip shows numbers right away. Change them anytime; a provider's Reset restores its defaults, and Reset All restores the full set. Only providers that are turned on render in the strip; new installs start with Claude, Codex, Cursor, and Freebuff on, while other providers stay off until you enable them in Customize.
- At most **2 stars per provider**.
- When a star isn't allowed, the star button stays clickable — clicking it shakes and shows the reason in a temporary pill over the bottom of Customize (for example, "Up to 2 stars per provider").

## Styles

Settings → Appearance → Icon Style:

- **Text** — provider icon plus values. One starred metric renders as a single number; two from the same provider stack as two tight lines, read positionally (`87%` over `32%`) with no label words, so the strip stays as narrow as a percentage-only reading. Multiple Codex accounts share one Codex mark, followed by each account's pinned usage values in order. The mark is kept small so it identifies the provider without eating menu-bar width.
- **Bars** — a compact glyph containing the first four starred metrics that have a limit (metrics without limits only appear in Text style).
- In each provider or account's Customize detail, **Show in menu bar** controls whether its pinned values appear. The first visible Codex account supplies the shared mark; other accounts keep their own values under it. New providers and accounts default to on. Turning it off removes that provider/account from both Text and Bars styles — and it also stops that provider's live menu-bar refreshes while the panel stays closed, since nothing it produces can be drawn there. Meters refresh again as soon as you show it, because opening the panel refreshes every enabled provider.

## Hiding usage while screen sharing

Settings → Privacy → **Hide From Screen Share** (off by default). While your screen is being shared or recorded — a Zoom/Meet/Teams share, a screen recording, macOS Screen Sharing — the strip is replaced with the QuotaBar icon and wordmark, so token counts and spend never show up in front of an audience. The moment the capture ends, your starred metrics come right back. Captures you start yourself (a screen recording, for example) count too, so those get the wordmark as well.

Detection rides the system's own "an app is capturing the screen" signal — the same one that lights the capture indicator in the menu bar — checked the instant it changes and re-checked every few seconds while the setting is on.

## Snoozing low-usage or exhausted subscriptions

Settings → **Snooze Subscriptions** (off by default) lets you temporarily hide menu bar icons for subscriptions that are out of usage or below a chosen threshold (0%, 5%, 10%, 15%, or 20% remaining). When a subscription's quota resets or recovers, its menu bar icon and values automatically reappear. You can choose which subscriptions auto-snooze or manually snooze a subscription until its next reset from its context menu.

## What the strip shows

The strip only renders real data. A starred metric with nothing fetched yet is skipped; a provider whose stars all lack data disappears entirely (icon included). When nothing has data, the strip falls back to the app icon, but the single status item remains clickable and opens the aggregate dashboard. The same fallback keeps the icon when every subscription is snoozed at once, so the panel always stays openable. Stars follow your Customize order — Always Visible metrics first, then On Demand ones. A metric can be starred whether it's Always Visible or On Demand. Multiple Claude and Codex accounts remain separate provider cards inside the same panel. Codex account values remain separate in the strip but share one provider mark. When an account moves from a family ID to an account-specific ID, its existing family pins carry over once, even when the old family card is no longer active; later explicit unpins are preserved.

A bounded count meter carries a compact unit in the strip when the unit is the only thing that makes the number meaningful — an hours balance reads `30h`, not a bare `30` — while percent and dollar meters stay as they are. Units that would abbreviate ambiguously (sessions would collapse to `s`, which reads as seconds) keep their bare number instead.

Freebuff's Daily Hours pin shows only **active session timers**, using each session's actual expiry time. Every live session stays under the one Freebuff mark. Two timers stack. A third or fourth sits beside that pair, so the strip stays the same height as the other providers. Daily reset times, remaining allowances, balances, expired sessions, and unoccupied purchased hours do not appear beside those timers. The countdowns update each minute and disappear when no sessions remain active.

Claude and Antigravity meters disappear from the menu bar when their saved reset time is more than five minutes past, until a fresh value arrives. Open the dashboard to see the last known value and any refresh warning.
