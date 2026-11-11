# Z.ai

Tracks [Z.ai](https://z.ai) (Zhipu AI) GLM Coding Plan usage quotas for coding subscriptions.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | 5-hour rolling window token usage (percentage); suppressed when the account has no Coding Plan, otherwise visible even if the response omits the limit |
| Weekly | 7-day rolling window token usage (percentage); suppressed when the account has no Coding Plan, otherwise visible even if the response omits the limit |
| Weekend Build | A promotional one-time token grant read from local ZCode (used / total); shows its expiry, and "Expired" once the grant ends; hidden when the account has none |
| Web Searches | Monthly web-search / web-reader / Zread calls (used / limit); hidden when the plan carries no web-search allowance |
| Today / Yesterday / Last 30 Days | Local ZCode usage history, estimated at public API rates; sit below the caret |

When Z.ai reports your plan name, QuotaBar shows it beside the provider name. For promotional
plans (such as Start Plan) that the quota API doesn't cover, the plan name and grant come from the
local ZCode entitlement snapshot instead.

## Where credentials come from

QuotaBar uses an API key for Coding Plan quotas. Weekend Build and the local usage history read ZCode
data on this Mac independently and do not need a key.
QuotaBar reads it from the first place it finds one, in this order:

1. `~/.config/openusage/zai.json` — `{"apiKey":"…"}` (the file Settings writes to)
2. `~/.config/zai/key.json`
3. The `ZAI_API_KEY` environment variable
4. The `GLM_API_KEY` environment variable (the legacy Zhipu name, still accepted)

You can also add and rotate the key from **Settings → API Keys** without touching a file. Either
way, nothing leaves your Mac except the same API calls Z.ai's own subscription UI makes.

## Setup

1. [Subscribe to a GLM Coding plan](https://z.ai/subscribe) and get your API key from the
   [Z.ai console](https://z.ai/manage-apikey/apikey-list).
2. Add the key to QuotaBar via **Settings → API Keys**, **or** export it:

```bash
export ZAI_API_KEY="YOUR_API_KEY"
```

3. Z.ai appears on the dashboard and (after you star a metric) the menu bar on the next refresh.

## Weekend Build

Promotional grants (like a one-time token bonus) are read from ZCode's local entitlement snapshot —
no API key involved. The row shows how much of the grant is used and, when the grant has a recorded
end date, how long it lasts; after that date it reads "Expired" until the next snapshot drops it.
Grant data updates whenever ZCode refreshes its snapshot, so a fresh manual ZCode run feeds QuotaBar.

## ZCode History

The Today / Yesterday / Last 30 Days tiles come from this Mac's `~/.zcode/cli/db/db.sqlite`. They
count recorded input and output across models used in ZCode, including cached input once, and
estimate cost at public API rates. This is local app usage, not the Coding Plan quota or a billing
figure. They appear below the caret and are not pinned by default.

## Under the hood

Two undocumented internal endpoints Z.ai's own subscription UI uses (stable in practice):

- `GET https://api.z.ai/api/biz/subscription/list` — plan name (best-effort; a failure here doesn't
  blank the meters). The plan name changes about once a month, so it is read at most hourly (a manual
  refresh re-reads it) and the last known name is kept when a request fails.
- `GET https://api.z.ai/api/monitor/usage/quota/limit` — the quota meters.

The quota response carries a `limits` array. Each `CREDIT_LIMIT` entry (called `TOKENS_LIMIT` in
older responses) is a percentage quota window; its window length decides which meter it feeds
(sub-daily → Session, multi-day → Weekly), while a `TIME_LIMIT` entry is the monthly web-search
count. Reset times come back as epoch milliseconds. Missing required usage values are reported as
an invalid response instead of being shown as zero. A reset time that is zero, stale, or outside a
believable window is ignored, so the meter falls back to its own cadence ("Resets in 5h") instead of
reading "Resets soon" forever. A web-search entry with a zero cap means the plan has no web-search
allowance, so that meter is hidden rather than drawn empty.

## Troubleshooting

- **"No Z.ai API key"** — add a key in Settings → API Keys, or export `ZAI_API_KEY`.
- **"Couldn't read the saved Z.ai API key"** — a saved config file exists but QuotaBar can't read it. The API Keys card shows an orange repair state; a valid environment key remains active and is labeled as a fallback. Check file permissions, enter a replacement, or remove the saved file, then refresh.
- **"Z.ai API key invalid"** — the key was rejected (401/403). Regenerate it in the
  [Z.ai console](https://z.ai/manage-apikey/apikey-list).
- **"No active GLM Coding Plan"** (amber notice by the name) — the key is valid, but the account has no
  GLM Coding Plan, so there's nothing to meter. Subscribe at [z.ai/subscribe](https://z.ai/subscribe);
  usage appears once your plan is active. Empty Session and Weekly rows are suppressed for this state.
- **Meters show "No data"** — you have a plan, but the quota endpoint returned no usable limits
  yet. The core rows stay visible so this state is distinguishable from an account with no plan. Check
  your [plan](https://z.ai/manage-apikey/coding-plan/personal/my-plan).
