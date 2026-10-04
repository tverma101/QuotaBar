# Model Pricing

How QuotaBar turns token counts into estimated dollars across providers. OpenRouter usage and OpenCode usage continue to use the costs their sources report directly.

## Where prices come from

Prices are layered from four sources; when the same model appears in more than one, the earlier source wins:

1. **QuotaBar pricing supplement** — a small JSON file published to GitHub Pages. Its aliases map provider log/CSV names; its curated prices and cache rates override public catalogues when maintainers have verified a better match or a model is missing.
2. **OpenRouter** — the live `/api/v1/models` catalogue supplies automatically discovered model IDs and published prompt/completion rates. Exact route IDs and unambiguous bare model IDs can match; OpenRouter entries are never fuzzy-matched.
3. **LiteLLM** — the community-maintained `model_prices_and_context_window.json`, used as a fallback for models OpenRouter does not list.
4. **models.dev** — a final exact-ID gap-filler for models the earlier sources miss.

The app ships the supplement and LiteLLM and models.dev snapshots for offline use and first launch. OpenRouter is cache-only after its first successful fetch. Each source is refreshed about once an hour with ETag revalidation under `~/Library/Application Support/QuotaBar/pricing/`. A refresh never blocks a usage scan. If OpenRouter cannot refresh, QuotaBar keeps using its last cached catalogue; other sources fill models that have no matching OpenRouter entry.

An unknown model queues a public OpenRouter catalogue revalidation. Repeated misses are combined,
with at most one discovery fetch per five minutes and a 30-minute pause after a failed fetch.
The model name stays local. The next usage refresh picks up any newly available rate; unchanged
catalogue contents keep the same accounting cache identity. Ambiguous route names stay visibly
unpriced until a reliable match exists.

Because the supplement is published to GitHub Pages on merge, a pricing correction reaches installed apps within about an hour — no app update needed.

Updating the app also works. The supplement carries an ISO-8601 `updated_at` timestamp, and the app uses whichever of the cached and bundled copies is newer, so a build shipping fresher rates applies them straight away instead of waiting on the cache to expire. Timestamp precision matters because multiple pricing changes can land on the same day. Older date-only values remain supported. This matters most offline: without it, an old cache would shadow the shipped rates for as long as the feed stayed unreachable.

## How a model name resolves

Log and CSV model names rarely match a catalog key exactly. Supplement alias rules first rewrite known provider slugs. QuotaBar then checks curated supplement rates, OpenRouter exact route IDs and unique bare model IDs, LiteLLM exact rates, fast-variant rules, LiteLLM fuzzy matches (provider prefixes, dated suffixes, and separator differences), and finally exact models.dev IDs. OpenRouter prices are never fuzzy-matched, which avoids choosing between similarly named routes. Fast variants without an exact rate or known model-specific multiplier stay unpriced instead of silently using the standard-speed rate.

Requests routed by [Cursor Router](https://cursor.com/docs/cursor-router.md) are a special case: instead of a slug, Cursor's export names the model it picked in plain words, like `Opus 5 (Auto Balanced)`. Alias rules map those labels to the same rates as the model itself, so a routed request costs what it would have cost picked by hand. The label stays as written in the model breakdown, so you can still tell which requests the router handled.

A model no source can price is left out of the spend figures unless its session already records the actual cost. Otherwise, its tokens don't count toward the day's tile, the Usage Trend, or the model breakdown, because a token count next to a dollar figure that ignores part of it would be misleading. A warning triangle on the affected tiles lists the unpriced models, and a day where nothing could be priced reads "No data".

## What the estimate includes

Costs are computed per usage event from input, cache, and output token buckets. OpenRouter supplies prompt and completion rates; where its model list does not specify cache rates, QuotaBar uses the prompt rate for cache reads and 5-minute writes, with no cache-read discount. One-hour cache writes are estimated at twice that write rate. Other sources may publish cache rates, long-context tiers, and fast-variant multipliers. Cursor's export combines many requests into each row, so QuotaBar uses the normal rate there rather than guessing that one request crossed the limit. When a Claude or Grok session records its own cost, that amount is used as-is. Nested Claude advisor usage has no carried cost, so it is priced separately from its tokens using the advisor model. These are public-catalog estimates, not the provider's bill: route, cache, account, subscription, and negotiated rates can differ.

## Privacy

The pricing refresh fetches public model catalogues from OpenRouter, LiteLLM, models.dev, and this repo's GitHub Pages. It sends no usage or log data and does not send an OpenRouter API key. A live no-key GET currently succeeds, although OpenRouter's API reference documents bearer authorization; if the endpoint begins requiring a key, the last cached catalogue remains in use and the other sources still price models without an exact OpenRouter match.

## Maintainer notes

- **Supplement changes** cover provider aliases, verified overrides (including model-specific cache rates), and models missing from public catalogues, including Cursor-native names that OpenRouter cannot price. Ordinary model additions and rates are discovered from OpenRouter automatically. For an exceptional supplement edit, update `updated_at`; on merge to `main`, `.github/workflows/pricing-supplement.yml` publishes the feed. The bundled copy ships with the next release for first launches.
- **Bundled snapshots** (`pricing_litellm_snapshot.json`, `pricing_models_dev_snapshot.json`): regenerate occasionally (e.g. before a release) with `script/update_pricing_snapshots.sh`. Staleness is harmless — runtime fetches override them.
