# QuotaBar macOS visual reference

Captured from Swift revision [8422c3f](https://github.com/tverma101/QuotaBar/tree/8422c3f5b454e1668d716af4a11014596bcae55a) on arm64 macOS 26.6.2 (25G83). The [feature inventory](../../FEATURES.md) now tracks the newer revision `9141aa3`; the PNGs were not recaptured at that revision. See [manifest.tsv](manifest.tsv) for exact PNG dimensions and capture scale.

## Inputs

- Locale: en-US / en_US; time zone: UTC. The fixture clock for snapshot timestamps, menu-bar metrics, and History is 2026-10-05 12:00 UTC. Dashboard row labels that still consult the system clock display the past quota deadlines as **Awaiting Refresh**.
- Provider IDs: `claude`, `codex`, `cursor`, and `freebuff`. No accounts, tokens, or production data. Capture-only instrumentation injected snapshots before presenting the real AppKit status item and panel; the reference branch contains no app-source changes.
- Populated baseline: Claude Max (37% session, 18.5% weekly, 40% Fable, €12.34 of €50 extra usage); Codex Pro (82% session, 41% weekly, two reset credits); Cursor Pro (96% total, 71% Cursor models, 19% other models); Freebuff Free (18 of 60 in the session pool). Percent meters reset at 14:00 UTC.
- Fixture spend (USD) / tokens: Claude 12.34 / 3.7M, Codex 8.30 / 8.2M, Cursor 3.21 / 9.6M, Freebuff 0 / 1.8M for Today; History includes yesterday at half those amounts. History's estimated API rate is 1.25× Today cost. The usage trend fixture uses 0, 1, 4, 1, 9, 6, and 8 million tokens.
- Empty has no snapshots, error injects a Codex sign-in error with other providers populated, and loading places Claude and Codex in the in-flight set before any snapshots arrive.

## Measurements for matching

| Token | Default | Compact |
|---|---:|---:|
| Panel width / outside radius | 320 pt / 13 pt | 320 pt / 13 pt |
| Panel page gutter / card radius | 14 pt / 12 pt | 14 pt / 12 pt |
| Navigation bar height | 44 pt | 44 pt |
| Provider header / supporting text / plan badge | 14 / 12 / 11 pt | 13 / 11 / 10 pt |
| Meter / usage sparkline height | 5 / 18 pt | 4 / 14 pt |
| Section gap / header-to-card gap | 14 / 4 pt | 8 / 2 pt |

Text uses the macOS system font with system weights and monospaced digits where indicated by the view. Compare semantic colors against the PNGs under the same appearance and profile: the tray uses `NSColor.textBackgroundColor`, cards composite `.fill.quaternary` over it, and normal/warning/critical meters use system blue/yellow/red. The native shell PNGs include system-dependent composition; exclude them from app-owned pixel diffs. See [FEATURES.md](../../FEATURES.md) for the source inventory and additional strip measurements.

## Coverage

- `@1x`: native VM display. `@2x`: native HiDPI virtual display at the same 1600 × 1200 logical dimensions, not resampled. The panel window is captured without its shadow. Shell crops show the status item in the macOS menu bar; the separate alpha strips are the app's untinted assets.
- The first viewport of Dashboard, Settings, History, Customize, and Claude's Customize detail is captured in both appearances and densities. Settings also has scrolled captures at `@2x`. The populated Dashboard includes the Total Spend card. Total Spend (light/dark) and Claude (dark) have separate native `@4x` clipboard share PNGs. The dark Options menu is shown with transient copy feedback in a shell crop.
- Empty History and Dashboard, loading Dashboard, and one provider error are captured in both appearances; the app's Reduce Animations and Increase Transparency settings have separate dark Dashboard stills. The strip is shown with text, bars, and the fallback icon; the shell's light menu-bar tint is independent of the in-app appearance.
- These PNGs are not a complete W0 parity sign-off. macOS 15, system Increase Contrast/Reduce Transparency, actual screen-share detection, motion keyframes, deeper dialog and overlay states, provider-specific states beyond the fixture, and CLI/API contract comparisons are not covered.
