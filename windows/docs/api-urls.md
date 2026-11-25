# HTTP(S) URLs Used by QuotaBar

This reference explains selected remote endpoints in the Windows plugins and Rust CLI. Run the inventory script from `windows/` for the current list of URL strings.

**Regenerate a sorted unique URL list** (no network access):

```bash
./scripts/list-api-urls.sh              # unique strings only
./scripts/list-api-urls.sh --lines      # file:line + full line
./scripts/list-api-urls.sh --context    # same + 2 lines of context
```

The Antigravity language server uses a loopback port assigned by the IDE. See [Antigravity](providers/antigravity.md) for setup and discovery.

The `jetbrains-ai-assistant` and `mock` plugins use local data.

---

## By provider

### amp

| Symbol / role | File | URL | Purpose |
|---------------|------|-----|---------|
| `API_URL` | `plugins/amp/plugin.js` | `https://ampcode.com/api/internal` | Amp usage / account API |
| (key suffix) | `plugins/amp/plugin.js` | `https://ampcode.com/` | Part of VS Code secrets key `apiKey@https://ampcode.com/` |

### antigravity

| Symbol / role | File | URL | Purpose |
|---------------|------|-----|---------|
| `CLOUD_CODE_URLS[]` | `plugins/antigravity/plugin.js` | `https://daily-cloudcode-pa.googleapis.com` | Cloud Code API base (try first) |
| `CLOUD_CODE_URLS[]` | `plugins/antigravity/plugin.js` | `https://cloudcode-pa.googleapis.com` | Cloud Code API base |
| `GOOGLE_OAUTH_URL` | `plugins/antigravity/plugin.js` | `https://oauth2.googleapis.com/token` | Refresh Google OAuth access token |
| `RETRIEVE_QUOTA_SUMMARY_PATH` | `plugins/antigravity/plugin.js` | *(base)* + `/v1internal:retrieveUserQuotaSummary` | Authoritative quota summary. Daily host first, Cloud Code host second. |
| `FETCH_MODELS_PATH`, `LOAD_CODE_ASSIST_PATH`, `RETRIEVE_QUOTA_PATH` | `plugins/antigravity/plugin.js` | *(base)* + legacy endpoints | Compatibility fallback only when quota summary is unavailable. |
| Local LS | `plugins/antigravity/plugin.js` | `http(s)://127.0.0.1:<port>/.../GetUserStatus` etc. | Primary quota source via language server |

### antigravity-cli

| Symbol / role | File | URL | Purpose |
|---------------|------|-----|---------|
| `CLOUD_CODE_BASES[]` | `plugins/antigravity-cli/plugin.js` | `https://daily-cloudcode-pa.googleapis.com` | Cloud Code API base (try first) |
| `CLOUD_CODE_BASES[]` | `plugins/antigravity-cli/plugin.js` | `https://cloudcode-pa.googleapis.com` | Cloud Code API base |
| `GOOGLE_OAUTH_URL` | `plugins/antigravity-cli/plugin.js` | `https://oauth2.googleapis.com/token` | Refresh Google OAuth access token |
| `RETRIEVE_QUOTA_SUMMARY_PATH` | `plugins/antigravity-cli/plugin.js` | *(base)* + `/v1internal:retrieveUserQuotaSummary` | Authoritative quota summary. Daily host first, Cloud Code host second. |
| `FETCH_MODELS_PATH`, `LOAD_CODE_ASSIST_PATH`, `RETRIEVE_QUOTA_PATH` | `plugins/antigravity-cli/plugin.js` | *(base)* + legacy endpoints | Compatibility fallback only when quota summary is unavailable. |

### claude

| Symbol / role | File | URL | Purpose |
|---------------|------|-----|---------|
| `USAGE_URL` | `plugins/claude/plugin.js` | `https://api.anthropic.com/api/oauth/usage` | OAuth usage |
| `REFRESH_URL` | `plugins/claude/plugin.js` | `https://platform.claude.com/v1/oauth/token` | Token refresh |

### codex

| Symbol / role | File | URL | Purpose |
|---------------|------|-----|---------|
| `REFRESH_URL` | `plugins/codex/plugin.js` | `https://auth.openai.com/oauth/token` | OAuth refresh |
| `USAGE_URL` | `plugins/codex/plugin.js` | `https://chatgpt.com/backend-api/wham/usage` | Usage |

### copilot

| Symbol / role | File | URL | Purpose |
|---------------|------|-----|---------|
| `USAGE_URL` | `plugins/copilot/plugin.js` | `https://api.github.com/copilot_internal/user` | GitHub Copilot usage |

### cursor (plugin)

| Symbol / role | File | URL | Purpose |
|---------------|------|-----|---------|
| `BASE_URL` | `plugins/cursor/plugin.js` | `https://api2.cursor.sh` | Connect/gRPC-Web style API base |
| `USAGE_URL` | `plugins/cursor/plugin.js` | `https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage` | Current period usage |
| `PLAN_URL` | `plugins/cursor/plugin.js` | `https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo` | Plan info |
| `REFRESH_URL` | `plugins/cursor/plugin.js` | `https://api2.cursor.sh/oauth/token` | OAuth refresh |
| `CREDITS_URL` | `plugins/cursor/plugin.js` | `https://api2.cursor.sh/aiserver.v1.DashboardService/GetCreditGrantsBalance` | Credits |
| `USAGE_LIMIT_GRANTS_URL` | `plugins/cursor/plugin.js` | `https://api2.cursor.sh/aiserver.v1.DashboardService/GetUsageLimitStatusAndActiveGrants` | Limits / grants |
| `REST_USAGE_URL` | `plugins/cursor/plugin.js` | `https://cursor.com/api/usage` | Dashboard-style usage (`?user=` may be appended) |
| `STRIPE_URL` | `plugins/cursor/plugin.js` | `https://cursor.com/api/auth/stripe` | Billing / Stripe |
| Request headers | `plugins/cursor/plugin.js` | `https://cursor.com`, `https://cursor.com/dashboard` | `Origin` / `Referer` for some requests |

Quick copy-paste list: `./scripts/print-cursor-endpoints.sh`

### cursor (CLI — `usage-stats` / MTD CSV)

| Symbol / role | File | URL | Purpose |
|---------------|------|-----|---------|
| `REFRESH_URL` | `crates/quotabar-cli/src/cursor_token_usage.rs` | `https://api2.cursor.sh/oauth/token` | OAuth refresh for CSV export |
| `EXPORT_URL` | `crates/quotabar-cli/src/cursor_token_usage.rs` | `https://cursor.com/api/dashboard/export-usage-events-csv` | Token-level usage CSV (cstats-style) |

### factory

| Symbol / role | File | URL | Purpose |
|---------------|------|-----|---------|
| `WORKOS_AUTH_URL` | `plugins/factory/plugin.js` | `https://api.workos.com/user_management/authenticate` | WorkOS |
| `USAGE_URL` | `plugins/factory/plugin.js` | `https://api.factory.ai/api/organization/subscription/usage` | Subscription usage |

### gemini-apps

| Symbol / role | File | URL | Purpose |
|---------------|------|-----|---------|
| `APP_URL` | `plugins/gemini-apps/plugin.js` | `https://gemini.google.com/app` | HTML for `SNlM0e` / `cfb2h` / `FdrFJe` |
| `USAGE_URL` | `plugins/gemini-apps/plugin.js` | `https://gemini.google.com/usage` | Fallback token page |
| `BATCH_URL` | `plugins/gemini-apps/plugin.js` | `https://gemini.google.com/_/BardChatUi/data/batchexecute` | Usage RPC `jSf9Qc` + optional plan `sJBwce` |
| `ORIGIN` | `plugins/gemini-apps/plugin.js` | `https://gemini.google.com` | Origin / SAPISIDHASH |

### kimi

| Symbol / role | File | URL | Purpose |
|---------------|------|-----|---------|
| `USAGE_URL` | `plugins/kimi/plugin.js` | `https://api.kimi.com/coding/v1/usages` | Usage |
| `REFRESH_URL` | `plugins/kimi/plugin.js` | `https://auth.kimi.com/api/oauth/token` | OAuth refresh |

### minimax

| Symbol / role | File | URL | Purpose |
|---------------|------|-----|---------|
| `GLOBAL_PRIMARY_USAGE_URL` | `plugins/minimax/plugin.js` | `https://api.minimax.io/v1/api/openplatform/coding_plan/remains` | Global region |
| fallback array | `plugins/minimax/plugin.js` | `https://api.minimax.io/v1/coding_plan/remains` | Fallback |
| fallback array | `plugins/minimax/plugin.js` | `https://www.minimax.io/v1/api/openplatform/coding_plan/remains` | Legacy www host |
| `CN_PRIMARY_USAGE_URL` | `plugins/minimax/plugin.js` | `https://api.minimaxi.com/v1/api/openplatform/coding_plan/remains` | China region |
| `CN_FALLBACK_USAGE_URLS` | `plugins/minimax/plugin.js` | `https://api.minimaxi.com/v1/coding_plan/remains` | CN fallback |

### perplexity

| Symbol / role | File | URL | Purpose |
|---------------|------|-----|---------|
| `LOCAL_USER_ENDPOINT` | `plugins/perplexity/plugin.js` | `https://www.perplexity.ai/api/user` | User (from cached DB ref) |
| `REST_API_BASE` | `plugins/perplexity/plugin.js` | `https://www.perplexity.ai/rest/pplx-api/v2` | Groups / usage analytics |
| `RATE_LIMIT_ENDPOINT` | `plugins/perplexity/plugin.js` | `https://www.perplexity.ai/rest/rate-limit/all` | Rate limits |

### opencode-go

| Symbol / role | File | URL | Purpose |
|---------------|------|-----|---------|
| `USAGE_URL` | `plugins/opencode-go/plugin.js` | `https://opencode.ai/zen/go/v1/usage` | OpenCode Go quota |

### z.ai

| Symbol / role | File | URL | Purpose |
|---------------|------|-----|---------|
| `BASE_URL` | `plugins/zai/plugin.js` | `https://api.z.ai` | API base |
| `SUBSCRIPTION_URL` | `plugins/zai/plugin.js` | `https://api.z.ai/api/biz/subscription/list` | Subscription |
| `QUOTA_URL` | `plugins/zai/plugin.js` | `https://api.z.ai/api/monitor/usage/quota/limit` | Quota |

---

## Rust test / example URLs (not production APIs)

These appear in **unit tests** or validation examples only:

| File | URL |
|------|-----|
| `crates/quotabar-core/src/plugin_engine/manifest.rs` | `https://status.example.com`, `https://example.com/billing`, `https://example.com` |
| `crates/quotabar-core/src/plugin_engine/host_api.rs` | `https://api.example.com/...`, `https://cursor.com/api/usage?...` (fixture for URL parsing / redaction tests) |

---

## Documentation and repo links in source

Comments and banners reference **GitHub**, **cstats**, etc. They are not called as APIs by the app:

- `https://github.com/robinebers/openusage`, `https://github.com/tverma101/QuotaBar`, `https://github.com/robinebers/cstats`

---

## Optional: HTML link spider (not for API route discovery)

Recursive `wget` does **not** enumerate `api2.cursor.sh` paths — those come from client code. See [research/deep-crawl-and-vpn.md](research/deep-crawl-and-vpn.md). For Cursor, run `./scripts/print-cursor-endpoints.sh`. For rare HTML sitemap crawling only: `./scripts/wget-html-spider.sh 'https://…'` (output under `docs/research/crawl-output/`, gitignored).
