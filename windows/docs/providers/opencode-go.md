# OpenCode Go

> Go plan meters come from OpenCode's official usage API when a local Go API key exists. Without a key, QuotaBar falls back to observed local SQLite spend.

## Overview

- **Provider ID:** `opencode-go`
- **Auth:** `~/.local/share/opencode/auth.json` (`opencode-go` entry `key`) or a Settings provider-account API key
- **Account meters:** `GET https://opencode.ai/zen/go/v1/usage` (`Authorization: Bearer <key>`)
- **Local fallback:** Assistant usage from every `opencode*.db` in `OPENCODE_DATA_DIR`, `XDG_DATA_HOME/opencode` or `~/.local/share/opencode` (in that order).

## Detection

The plugin enables when either:

- auth has a non-empty Go key, or
- local history already contains `opencode-go` assistant messages with numeric `cost`

## Data source

**With a key:** Session / Weekly / Monthly are **account-wide percents** from `/zen/go/v1/usage` (same numbers as the OpenCode dashboard), plus ISO `resetsAt`. Local SQLite is not used for those bars.

**Without a key:** bars are observed local dollar spend vs published Go caps (`$12` / `$30` / `$60`), clamped at 100%.

History includes Go and Zen turns from both OpenCode database layouts. Migrated turns with the same message ID count once. QuotaBar also projects reported Muse session usage from `~/.local/share/muse/sessions`, and OpenCode-billed Hermes sessions when Hermes is enabled. Unpriced turns still contribute tokens. Local history belongs to the main OpenCode card, not each configured key.

## API errors

| HTTP | Meaning |
|------|---------|
| 401 | Key rejected — sign into OpenCode Go again |
| 403 `EntitlementError` | No Go subscription on this key |
| other / unreachable | Fail loudly (no silent $0) |

## Window rules (local fallback only)

- `5h`: rolling last 5 hours
- `Weekly`: UTC Monday `00:00`
- `Monthly`: earliest local Go usage as subscription-style anchor

## Port

OpenUsage **v0.7.9** (#1097). QuotaBar 1.4.1.
