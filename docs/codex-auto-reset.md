# Auto-Use Expiring Codex Resets

QuotaBar can optionally redeem banked **Codex rate-limit reset credits**, one minute before their expiration, for every connected Codex account. This does not alter providers that have no supported redeem endpoint, does not buy any credits, and does not change ordinary scheduled quota renewal.

## Enable

Settings → Usage Display → **Auto-Use Expiring Codex Resets** (off by default). Settings shows how many verified Codex accounts are monitored and whether any need attention.

## Behavior

- Every **verified** Codex account has its own credential-scoped worker. An unresolved account identity is never used for automatic provider writes. Disabled/unpinned Codex cards remain eligible under the global opt-in. The account list is captured at app startup; adding an account while the app is running requires the app to restart or reload its account catalog before that account is monitored.
- The worker lists live available credits approximately every five minutes, then sleeps directly toward the earliest `expiry - 60 seconds`. No POST is sent before that trigger or after expiry. A first redemption attempt matches the exact server credit ID and expiry against a fresh GET from that account. A retry uses the saved ID and UUID, even when a previous successful POST may have removed the credit from the list.
- Before a POST, an idempotency UUID is saved and flushed against the account and server credit ID. Failures retry with the same UUID, at most three times per credit ID. After an uncertain response, QuotaBar can replay that exact (credit ID, UUID) even when the credit is no longer listed, to confirm the backend’s `already_redeemed` response. It never substitutes a different credit. Successful, no-credit, and nothing-to-reset outcomes stop attempts for that credit ID; no attempts are made for credits without a real expiry time.
- `nothing_to_reset` means the server did **not** consume a credit, usually because eligible usage is not sufficiently depleted. QuotaBar doesn't force a pointless reset just to spend a credit.
- The claim service refreshes the specific account's usage after a successful claim, and the UI remains usable for manual claims through its account-aware router.

## Limitations

- **Requires the app running and the Mac awake with working connectivity.** macOS suspension, shutdown, offline periods, and long API outages can miss an expiry window. QuotaBar cannot guarantee a redemption when it is not executing.
- This uses a live backend endpoint also used by the Codex client. A provider API change or revoked auth may prevent redemption. Errors are logged; the app never swaps credentials across accounts to compensate.
- A credit that cannot be used because all applicable allowances are sufficiently full will not be spent, even if it expires.
- This feature does not apply to Claude, Cursor, Grok, or other providers; their ordinary quota countdowns are not banked reset credits.
- Only enable this on accounts where you want any expiring reset to be automatically applied. The action is irreversible once accepted by Codex.
