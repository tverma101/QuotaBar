# Gemini Apps

> Tracks Gemini consumer **Current** and **Weekly** usage from [gemini.google.com/usage](https://gemini.google.com/usage).

This is **not** Antigravity / Gemini CLI coding quota. Those stay on the Antigravity plugins.

Off by default (`#838` newly bundled plugins append disabled). Enable in Settings after logging into [gemini.google.com](https://gemini.google.com/app) in Chrome.

## Overview

- **Provider ID:** `gemini-apps`
- **Source of truth:** `POST https://gemini.google.com/_/BardChatUi/data/batchexecute` RPC `jSf9Qc`
- **Auth:** Google session cookies from Chrome/Chromium (Linux/macOS)
- **Status:** bundled. RPC IDs and cookie encryption can rot.

The usage page shows two percent meters:

- **Current** — type `1` used fraction (about a 5-hour window)
- **Weekly** — type `2` used fraction (7-day window)

Fractions are **used**, not remaining (unlike Antigravity `remainingFraction`).

## Authentication

Order:

1. Decrypt Chrome/Chromium/Brave/Edge cookies for `.google.com` via `host.chromiumCookies.read` (OSCrypt `v10`/`v11`).
2. `GEMINI_COOKIE` env: a `Cookie:` header or `name=value; …` list that includes `__Secure-1PSID` and `SAPISID`.

You must be logged into [gemini.google.com](https://gemini.google.com/app) in that browser. Linux needs an unlocked keyring (`secret-tool lookup application chrome` → Chrome Safe Storage). `v20` / `v12` cookie encryption fails loudly. Windows DPAPI/`v20` is not supported.

## Data Mapping

| RPC | UI |
|-----|-----|
| `jSf9Qc` row type `1` | Current percent + `resetsAt` |
| `jSf9Qc` row type `2` | Weekly percent + `resetsAt` |
| `sJBwce` | Plan (`Pro` / `Ultra` / `Free`) when present |

`GET /app` (fallback `/usage`) also supplies the `SNlM0e` (`at`), `cfb2h` (`bl`), and `FdrFJe` (`f.sid`) tokens required by batchexecute.

## Output

- **Plan**: `Pro` / `Ultra` / `Free` when parsed.
- **Current**: percent progress line.
- **Weekly**: percent progress line.
- **Source**: `Chrome` or `GEMINI_COOKIE`.

## Failure Behavior

| Condition | Message |
|---|---|
| No cookies | `Gemini Apps auth missing. Log into gemini.google.com in Chrome.` |
| Login HTML / missing `SNlM0e` | `Gemini Apps session expired. Log into gemini.google.com in Chrome.` |
| RPC shape changed | `Could not parse Gemini Apps usage.` |
| Network failure | `Could not reach gemini.google.com. Check your connection.` |

This plugin never sends prompts. It only reads the usage page RPCs.
