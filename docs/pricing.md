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

LiteLLM and models.dev cache files also carry a retrieval timestamp. For models present in both a cache and the shipped snapshot, QuotaBar uses the newer copy; models present only in the older copy remain available. Caches created by older versions without timestamps are treated as older than a dated bundled snapshot, so an offline app update can apply the shipped rate corrections immediately. A complete models.dev compact cache records its conflict-tombstone set, even when empty. This lets a newer refreshed catalogue clear a resolved conflict while preventing a legacy cache with an arbitrary provider price from undoing a bundled tombstone.

## How a model name resolves

Log and CSV model names rarely match a catalog key exactly. Supplement alias rules first rewrite known provider slugs. QuotaBar then checks curated supplement rates, OpenRouter exact route IDs and unique bare model IDs, LiteLLM exact rates, fast-variant rules, LiteLLM fuzzy matches (provider prefixes, dated suffixes, and separator differences), and finally exact models.dev IDs. OpenRouter prices are never fuzzy-matched, which avoids choosing between similarly named routes. Fast variants use an exact fast rate, or an exact base rate (including the newest matching date-suffixed LiteLLM entry) with a known model-specific multiplier; a fuzzy sibling never supplies the base rate.

Codename (stealth) models get one extra exact retry: log slugs spelled with spaces or underscores are normalized to hyphens before the exact lookups are retried (`space bunny` → `space-bunny`), so the moment a public catalogue lists the codename — OpenRouter's stealth listings carry the model's real rates — discovery prices it. There is no manual mapping step: resolution, pricing, and the backfill of older days all happen automatically on later refreshes.

Requests routed by [Cursor Router](https://cursor.com/docs/cursor-router.md) are a special case: instead of a slug, Cursor's export names the model it picked in plain words, like `Opus 5 (Auto Balanced)`. Cursor-scoped aliases map its CSV slugs and labels to Cursor-specific rates when those differ from the public API rate; other models keep using the shared catalog rates. Grok 4.5 and 4.6 use separate Cursor rates and aliases, while xAI logs keep xAI's cached-input prices and 200K long-context tiers. The label stays as written in the model breakdown, so you can still tell which requests the router handled.

A model no source can price is never hidden: its tokens still count toward the day's tile, the Usage Trend, the Usage History screen, and the model breakdown, while its cost reads a dash — a token count next to a dollar figure that ignores part of it would be misleading. The exception is a product-labeled event whose serving model is unknown: QuotaBar excludes Cursor Grok Bot/Sand export rows from token and model totals instead of guessing which model produced them. A `-free` suffix alone does not establish a rate or inherit one from a paid sibling; verified free models have explicit zero-rate entries in the supplement. (A session that records its own actual cost keeps showing that cost as-is.) A warning triangle on the affected tiles lists the unpriced models. When a catalogue later lists the model (or a codename normalizes onto an entry), the automatic discovery path prices it and every affected day backfills on the next refresh — no action needed.

## What the estimate includes

Costs are computed per usage event from input, cache, and output token buckets. OpenRouter supplies prompt/completion rates, cache prices when published, and request-length overrides. QuotaBar applies published minimum-prompt tiers to the whole request; GPT-6.1 Sol's official 272K boundary is exclusive, so exactly 272,000 prompt tokens keep standard rates. Time- and day-based overrides are not applied because usage rows do not retain enough timing detail. When a source omits a cache-read price, QuotaBar uses the selected input rate without a cache discount; it estimates one-hour cache writes at twice the selected input rate unless an explicit rate is published in the base or a context tier. Other sources may publish cache rates, long-context tiers, and fast-variant multipliers. Cursor's export combines many requests into each row, so QuotaBar uses the normal rate there rather than guessing that one request crossed the limit. When a Claude or Grok session records its own cost, that amount is used as-is. Nested Claude advisor usage has no carried cost, so it is priced separately from its tokens using the advisor model. These are public-catalog estimates, not the provider's bill: route, cache, account, subscription, and negotiated rates can differ.

Codex GPT-6.1 Sol events preserve their reported service tier: Fast is estimated at 2× standard, Flex and Batch at 0.5×, and Ultrafast at 6×. Unknown tiers and other models keep their standard or existing Codex priority pricing. The bundled LiteLLM snapshot carries GPT-6.1 Sol's published long-context tiers for offline use.

## Privacy

The pricing refresh fetches public model catalogues from OpenRouter, LiteLLM, models.dev, and this repo's GitHub Pages. It sends no usage or log data and does not send an OpenRouter API key. A live no-key GET currently succeeds, although OpenRouter's API reference documents bearer authorization; if the endpoint begins requiring a key, the last cached catalogue remains in use and the other sources still price models without an exact OpenRouter match.

## Maintainer notes

- **Supplement changes** cover provider aliases, verified overrides (including model-specific cache rates and request-length tiers), and models missing from public catalogues, including Cursor-native names that OpenRouter cannot price. Use `cursor_alias_rules` and `cursor-` rate keys when a Cursor model's price differs from its public API rate. When renaming/removing a rate key, add its old key to `retired_pricing_keys`; when removing a global alias, add its exact regex to `retired_alias_patterns` so an older cached supplement cannot restore it. Include the complete retirement fields in each current feed; a newer feed can restore an alias by publishing its rule with that pattern absent from `retired_alias_patterns`, while legacy caches remain subordinate to bundle retirements. Ordinary model additions and rates are discovered from OpenRouter automatically. For an exceptional supplement edit, update `updated_at`; on merge to `main`, `.github/workflows/pricing-supplement.yml` publishes the feed. The bundled copy ships with the next release for first launches.
- **Bundled snapshots** (`pricing_litellm_snapshot.json`, `pricing_models_dev_snapshot.json`): regenerate before a release with `script/update_pricing_snapshots.sh`. Staleness is not free: first launches and offline machines price only from the bundle, and the runtime merge keeps bundled-only keys alive so a long-stale bundle can resurrect rates the live feed corrected. Regenerating merges the live feeds over the previous snapshot — fresh rates win per model, models the feed dropped stay priced for historical usage. The generator preserves explicit cache-read provenance when the price appears only in a context tier, and models.dev snapshots carry a complete conflict-tombstone list. When a feed drops a field (LiteLLM dropped the Opus `fast` multipliers in October 2026), pin the value in the supplement's `fast_multipliers` instead of relying on the feed.
