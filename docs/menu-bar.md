# Menu Bar

Star your most important metrics straight into the menu bar strip.

## Right-clicking the icon

Right-click (or control-click) the QuotaBar menu bar icon for a quick menu with **Settings** and **Quit**. QuotaBar keeps one status item and one shared panel regardless of provider count, so two Codex accounts and Cursor remain together in the same dashboard instead of looking like duplicate apps.

## Usage History

The dashboard footer's **Options** menu → **Usage History** opens a read-only report built from the same local usage data the spend tiles show, so the two can never disagree:

- **Lifetime** — recorded tokens and plan-priced cost from the retained history window (up to 10 years), dated by its earliest day ("Since Mar 2026"). Claude, Codex, and Grok fold up to ten years of local logs; sources with shorter scan or retention windows contribute only the history they preserve. When those dollars were imputed from token counts (subscription logs carry no per-message cost, so they are priced at public API rates), the headline carries an **Est.** mark.
- **At Public API Rates (Est.)** — what all that recorded usage would have cost at each model's public API rates. A what-if comparison, never a recorded amount. QuotaBar hides the figure when any retained day includes an unpriced model, even after that model's name ages out of the 30-day detail. It is also hidden when it would display the same figure as the Lifetime total — subscription logs with no per-message cost make the two coincide, and one number stated twice adds nothing.
- **Today / 7 Days / 30 Days** summary cards: tokens always, plan-priced cost (a dash where nothing could be priced yet).
- A **daily token trend** across the 30-day window, with one bar for every calendar day including idle days.
- One section per enabled provider with **per-model rows** for the window: tokens plus cost (or a dash for models no catalogue prices yet — those backfill automatically once discovery finds a rate; see [Pricing](pricing.md)).

## Starring

Star a metric from any row's right-click menu, or from the always-visible star beside a metric in Customize.

- On first launch the app ships with a default set of stars (Antigravity Session/Weekly, Claude Session/Weekly, Codex Session/Weekly, Cursor Models/Other Models, Copilot Credits, OpenRouter Credits, Z.ai Session/Weekly) so the strip shows numbers right away. Change them anytime; a provider's Reset restores its defaults, and Reset All restores the full set. Only providers that are turned on render in the strip — and a fresh install starts with just the providers detected on your Mac (see [Dashboard § First launch](dashboard.md#first-launch)) — so the default stars don't crowd the menu bar with tools you don't use.
- At most **2 stars per provider**.
- When a star isn't allowed, the star button stays clickable — clicking it shakes and shows the reason in a temporary pill over the bottom of Customize (for example, "Up to 2 stars per provider").

## Styles

Settings → Appearance → Icon Style:

- **Text** — provider icon plus values; two starred metrics from the same provider stack as a labeled pair.
- **Bars** — a compact glyph containing the first four starred metrics that have a limit (metrics without limits only appear in Text style).
- In each provider or account's Customize detail, **Show in menu bar** controls the whole entry: both its icon and pinned usage values. New providers and accounts default to on. Turning it off removes that provider/account from both Text and Bars styles.

## Hiding usage while screen sharing

Settings → Privacy → **Hide From Screen Share** (off by default). While your screen is being shared or recorded — a Zoom/Meet/Teams share, a screen recording, macOS Screen Sharing — the strip is replaced with the QuotaBar icon and wordmark, so token counts and spend never show up in front of an audience. The moment the capture ends, your starred metrics come right back. Captures you start yourself (a screen recording, for example) count too, so those get the wordmark as well.

Detection rides the system's own "an app is capturing the screen" signal — the same one that lights the capture indicator in the menu bar — checked the instant it changes and re-checked every few seconds while the setting is on.

## What the strip shows

The strip only renders real data. A starred metric with nothing fetched yet is skipped; a provider whose stars all lack data disappears entirely (icon included). When nothing has data, the strip falls back to the app icon, but the single status item remains clickable and opens the aggregate dashboard. Stars follow your Customize order — Always Visible metrics first, then On Demand ones. A metric can be starred whether it's Always Visible or On Demand. Multiple Claude and Codex accounts remain separate provider cards inside the same panel. When an account moves from a family ID to an account-specific ID, its existing family pins carry over once, even when the old family card is no longer active; later explicit unpins are preserved.
