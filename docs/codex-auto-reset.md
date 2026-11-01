# Auto-Use Expiring Codex Resets

QuotaBar can optionally redeem banked **Codex rate-limit reset credits**, one minute before their expiration, for every connected Codex account. This does not alter providers that have no supported redeem endpoint, does not buy any credits, and does not change ordinary scheduled quota renewal.

## Enable

Settings → Usage Display → **Auto-Use Expiring Codex Resets** (off by default). Settings shows how many verified Codex accounts are monitored and whether any need attention.
The Codex reset-credit detail also shows whether auto-use is off, checking, monitoring, or needs attention, and the next attempt time when a credit is scheduled. Reset All Settings turns auto-use off without erasing the saved idempotency ledger.

## Behavior

- Every **verified** Codex account has its own credential-scoped worker. An unresolved account identity is never used for automatic provider writes. Disabled/unpinned Codex cards remain eligible under the global opt-in. The account list is captured at app startup; adding an account while the app is running requires the app to restart or reload its account catalog before that account is monitored.
- The worker lists live available credits approximately every five minutes, then sleeps directly toward the earliest `expiry - 60 seconds`. No POST is sent before that trigger or after expiry. A first redemption attempt matches the exact server credit ID and expiry against a fresh GET from that account. A retry uses the saved ID and UUID, even when a previous successful POST may have removed the credit from the list.
- Wake, a system-clock change, and network reconnection prompt another check. Events arriving during a check are buffered; they do not cancel an in-flight redemption. Failed credit lookups retry within 15 seconds, or 10 seconds near a previously seen expiry. Successful idle checks retain their five-minute cadence.
- If a credit's expiry changes during the preflight check, QuotaBar reschedules it using a fresh list instead of marking the credit unusable. The claim service independently checks the one-minute window before sending a POST.
- Previously seen credit deadlines survive a restart, bound to the verified account. They never authorize a new write without live validation. If a seen expiry passes without a confirmed auto-use, the detail reports **Reset Window Passed**; the credit may have expired or been used elsewhere. Unobserved credits and expiry windows cannot be reconstructed after the fact.
- Before a POST, an idempotency UUID is saved and flushed against the account and server credit ID. Failures retry with the same UUID, at most three times per credit ID. After an uncertain response, QuotaBar can replay that exact (credit ID, UUID) even when the credit is no longer listed, to confirm the backend’s `already_redeemed` response. It never substitutes a different credit. Successful, no-credit, and nothing-to-reset outcomes stop attempts for that credit ID; no attempts are made for credits without a real expiry time.
- `nothing_to_reset` means the server did **not** consume a credit, usually because eligible usage is not sufficiently depleted. QuotaBar doesn't force a pointless reset just to spend a credit.
- The claim service refreshes the specific account's usage after a successful claim, and the UI remains usable for manual claims through its account-aware router.
- Turning the setting off cancels preflight checks before the consume request. Those credits remain eligible if auto-use is re-enabled before expiry. A consume request already sent cannot be recalled; an uncertain response resumes only with its saved credit ID and request UUID. A changed preflight expiry also rolls back the unsent attempt and prompts a fresh check.

## Limitations

- **Requires the app running and the Mac awake with working connectivity.** macOS suspension, shutdown, offline periods, and long API outages can miss an expiry window. QuotaBar cannot guarantee a redemption when it is not executing.
- This uses a live backend endpoint also used by the Codex client. A provider API change or revoked auth may prevent redemption. Errors are logged; the app never swaps credentials across accounts to compensate.
- A credit that cannot be used because all applicable allowances are sufficiently full will not be spent, even if it expires.
- This feature does not apply to Claude, Cursor, Grok, or other providers; their ordinary quota countdowns are not banked reset credits.
- Only enable this on accounts where you want any expiring reset to be automatically applied. The action is irreversible once accepted by Codex.
