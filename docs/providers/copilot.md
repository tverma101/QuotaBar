# Copilot

Tracks your GitHub Copilot quota using a GitHub token that Copilot tooling already left on your machine. No login flow, no browser cookies.

## What it tracks

| Metric | Meaning |
|---|---|
| Credits | Share of your monthly AI-credit allotment used (the headline meter). On org-managed seats with no allotment, a plain count of your own credits used this cycle |
| Extra Usage | Premium interactions used beyond your included credits, once extra spend is enabled |
| Org Credits | AI credits your whole organization used this month (org-managed Business/Enterprise seats) |
| Org Spend | Dollars your organization was billed for AI credits beyond the included pool |
| Chat | Chat-message quota used |
| Completions | Code-completion quota used |

Credits and Extra Usage are Always Visible by default; Org Credits, Org Spend, Chat, and Completions start in On Demand behind the card's caret. Percent meters show percent used and, when the response includes one, a countdown to the next reset. The plan name (Pro, Business, Free, …) shows next to the provider.

Since June 2026 GitHub Copilot bills all plans by **AI credits**, so what each account shows differs by plan:

- **Paid plans** meter the credit pool — so you see Credits (and Extra Usage if you've turned on additional spend). Chat and completions are unlimited on paid plans, so those rows read "No data".
- **Free plans** have no credits, so Credits reads "No data"; instead you see your fixed Chat and Completions counts under the caret.
- **Org-managed seats (Copilot Business / Enterprise assigned by an organization)** return no per-seat percent quota. If the response's `premium_interactions` bucket carries a real `credits_used` count, QuotaBar shows it as **Credits** — a plain count, not a percentage, since this bucket's `entitlement` is 0 (no allotment to divide by). This is your *own* consumption and needs no special access. QuotaBar also looks the usage up in the organization's billing: it lists your organizations, finds the one whose billing reports Copilot AI-credit usage, and shows **Org Credits** (credits the whole org used this month) and **Org Spend** (dollars billed beyond the included pool). Two caveats there:
  - The Org Credits/Org Spend numbers are **organization-wide**, not your personal share — GitHub doesn't expose per-seat usage through that API.
  - Reading an org's billing requires you to be an **org owner or billing manager**. Regular members don't get Org Credits/Org Spend, but still see their own Credits count when the response carries one; if it doesn't, the meters read "No data".
- Org Credits is shown as a plain count, not a percentage: the billing API reports usage only, never the org's credit allotment, and QuotaBar doesn't fabricate a denominator.

A dollar credit figure (e.g. "$12 of $15 used") isn't shown: GitHub only exposes that through its logged-in web billing page, which would require reading browser cookies — QuotaBar does not do that. Editors like VS Code show the same credit *percentage* from this endpoint, not a dollar amount.

## Where credentials come from

Checked in this order (prompt-free files first, Keychain last):

1. Copilot editor token: `~/.config/github-copilot/apps.json` (older `hosts.json`) — written by the VS Code / JetBrains / Neovim Copilot plugins.
2. GitHub CLI config: `~/.config/gh/hosts.yml` (`oauth_token`), when `gh` stores its token in a file.
3. GitHub CLI Keychain item (service `gh:github.com`), when `gh` stores its token in the system keyring.

QuotaBar scopes a GitHub CLI Keychain lookup to the username in `hosts.yml` when that file is readable. If the file exists but cannot be read, QuotaBar keeps Copilot visible and reports a credential-access error rather than making a service-only query that could select a different GitHub account.

### Setup

If usage doesn't appear, authenticate with the GitHub CLI:

```bash
brew install gh   # if needed
gh auth login     # choose GitHub.com and follow the prompts
```

Using Copilot in a supported editor is enough on its own — the editor writes the token to `apps.json`.

## Troubleshooting

- **"Sign in to GitHub Copilot…"** — no token was found. Sign in to Copilot in your editor, or run `gh auth login`.
- **"QuotaBar couldn't read a Copilot credential source"** — check that your editor config or GitHub CLI config is readable, or unlock your login Keychain, then refresh.
- **"QuotaBar found malformed Copilot editor credentials"** — `apps.json` or `hosts.json` is invalid JSON or has a malformed GitHub.com entry (including a non-string `oauth_token`). Repair/remove the malformed file or sign in again; a readable alternate source such as GitHub CLI config or Keychain still takes precedence when it has a token.
- **The GitHub CLI config cannot be read** — restore read access to `~/.config/gh/hosts.yml`. QuotaBar needs its username to safely select the matching Keychain item, so it will not use an unscoped lookup while the file is unreadable.
- **"GitHub token invalid or expired"** — GitHub returned 401. Re-authenticate with `gh auth login`.
- **"GitHub denied access to Copilot usage"** — GitHub returned 403. Check the account's Copilot license and organization policy before changing credentials.
- **Meters show "No data" but the plan is shown** — expected on an org-managed Copilot Business/Enterprise seat whose response carries no personal `credits_used` and, if you aren't an org owner or billing manager, no org billing access either (GitHub doesn't expose per-seat quota otherwise, and org billing is admin-only). If you *are* an org admin and still see no Org Credits, make sure your token can list your orgs — the GitHub CLI token from `gh auth login` can; some editor-plugin tokens can't.

## Under the hood

`GET https://api.github.com/copilot_internal/user` with the standard Copilot client headers (API version `2025-04-01`). The response reports each bucket as percent *remaining*; the meters show percent *used*.

For org-managed seats (identified by the token-based-billing placeholder in that response), the provider additionally calls the public REST billing API: `GET /user/orgs` to list your organizations, following GitHub's pagination links, then `GET /orgs/{org}/settings/billing/usage/summary` per org until one reports Copilot AI-credit usage. The matching org is remembered, so steady-state refreshes make a single extra call; it's re-discovered automatically if it stops answering. When GitHub reports a rate limit or the remaining request count reaches zero, QuotaBar stops the org scan for that refresh and honors `Retry-After` / reset time when supplied; otherwise org discovery pauses for five minutes. Repeated complete no-access/no-result scans also pause for five minutes. A partial membership scan can still use its completed pages, but it isn't cached as a complete no-result. An explicit Refresh retries an ordinary no-result scan immediately but still honors a server-directed rate-limit deadline.
