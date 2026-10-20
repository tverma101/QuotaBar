# Cursor

Tracks your Cursor plan usage using the login from the Cursor app.

## What it tracks

| Metric | Meaning |
|---|---|
| Total Usage | Plan usage for the billing cycle (percent or dollars; included request count vs. cap on request-based Enterprise accounts); hidden if the response has model percentages but no aggregate total |
| Cursor Models | Usage percent for Cursor's own models. The pool is Grok 4.7, Grok 4.6, Grok 4.5, and Composer 2.5. Hidden by default when the plan response omits this breakdown |
| Other Models | Usage percent for other models. Hidden by default when the plan response omits this breakdown |
| Grok Bot | Grok Bot weekly usage percent and reset countdown; enabled by default |
| Extra Usage | On-demand spend; user-scoped when available, otherwise the team aggregate; shown as a meter when Cursor returns a limit |
| Requests | Optional copy of the included request count vs. cap for custom layouts; hidden by default when Cursor does not report a request cap |
| Credits | Credit balance left from grants and prepaid account balance; hidden when neither balance is available |

When Cursor reports your plan name, QuotaBar shows it beside the provider name.

Grok Bot has its own usage allowance, separate from Cursor's normal billing-cycle meter. Its widget
is enabled by default in Cursor's On Demand section. It uses your existing Cursor login, so signing
into the Grok CLI is not required.

## Where credentials come from

Just be signed into the Cursor app. QuotaBar reads Cursor's local state database for session tokens and uses Keychain as a fallback. When the database already has a usable token, optional Keychain reads are skipped, except when a free-plan account's token subject is needed to select the correct credential. Rotated Keychain tokens are saved under the current-user account and read back before legacy service-only entries. Nothing extra to install or configure.

A newer **Refresh Now** supersedes credential reads still queued by an older refresh, so they cannot
raise a late Keychain dialog or undo the newer action's grant.

## Spend history

Today, Yesterday, Last 30 Days, and Usage Trend come from Cursor's usage export. QuotaBar requests its current 30-day CSV window, so Usage History can include only the rows Cursor returns in that export. Cached history is stamped with a one-way hash of the selected Cursor account subject or credential; when identity cannot be read without Keychain access, QuotaBar withholds the old cache until a refresh resolves the account. QuotaBar uses exported token counts and shared model pricing to estimate cost locally. Cursor may label Grok Bot work as a product (`grok-bot-*` or legacy `sand-*`) without naming its serving model. QuotaBar keeps those rows in measured token totals under their product labels, but leaves their cost unpriced and does not guess which model ran; the cost stays incomplete and the unknown-model warning lists the products. If a future export names the actual model, that model's row is priced normally. The separate Grok Bot quota meter is unaffected. Genuine model rows such as `grok-4.7` continue to count and price normally. Cursor's export may occasionally arrive late, so the newest figures can lag behind current activity. If any row is malformed or contains a token count above 1 quadrillion, QuotaBar withholds that refresh's spend export rather than publishing a partial subtotal. A failed download, invalid export schema, or broken CSV structure likewise leaves spend history unavailable for that refresh. Each failure is recorded in the diagnostic log without including the exported usage data.

## Troubleshooting

- **"Not logged in" / token errors** — open Cursor and make sure you're signed in, then refresh.
- **"Couldn't read Cursor's local credential data"** — check that Cursor's state database and the login Keychain are readable, then refresh. A source that exists but cannot be read is reported separately from a missing login.
- **Some metrics missing** — Cursor omits fields depending on plan type. Missing aggregate totals, model breakdowns, and caps stay hidden unless you explicitly enable their rows in Customize.
- **Optional lookup failed** — Grok Bot, plan, credit-grant, prepaid-balance, and request-fallback failures stay nonfatal when primary usage is available. QuotaBar records fixed, credential-free reasons in the diagnostic log.

## Under the hood

GLM 5.3 and GLM 5.3 Flash exports use both `glm-5.3` and `glm-5p3` spellings with Low, High, or Max effort suffixes. The pricing list resolves these names using [Cursor's published rates](https://cursor.com/docs/models/glm-5-3-flash), including its cache-read prices, so priced usage does not show an unknown-model warning.

Connect RPC on `api2.cursor.sh` (dashboard usage and `DashboardService/GetSandUsageStatus` for Grok Bot), combined REST fallback at `cursor.com/api/usage` and `cursor.com/api/usage-summary` for Enterprise/team accounts, Stripe balance at `cursor.com/api/auth/stripe`, and the usage-events CSV export at `cursor.com/api/dashboard/export-usage-events-csv`. The fallback combines the included request allowance with structured percentages and user-scoped on-demand spend; neither REST response is treated as the whole account snapshot by itself. The primary dashboard usage request refreshes the token and retries once after a 401/403; optional endpoint failures stay nonfatal when the other fallback response is usable and are recorded in the diagnostic log. Per-day spend imputation uses exported token counts and the shared [model pricing](../pricing.md): OpenRouter automatically supplies exact public route rates when they match, while curated aliases and Cursor-specific rates handle names such as `auto` and `composer-*` that OpenRouter does not list. These values estimate public model-rate cost and can differ from Cursor's actual subscription or invoice totals.
