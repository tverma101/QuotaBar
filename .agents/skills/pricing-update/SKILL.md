---
name: pricing-update
description: Maintain QuotaBar's pricing supplement for provider aliases, Cursor-native models, verified overrides, and public-catalog gaps. Routine model discovery and route rates come from the live OpenRouter catalogue. Use when Cursor adds a native model, a public rate needs a verified exception, or a spend tile shows a warning triangle.
---

# Pricing Update

`Sources/QuotaBar/Resources/pricing_supplement.json` carries provider aliases, Cursor-native models that public catalogues do not list (such as `auto`, `composer-*`, and `github_bugbot`), verified rate/cache overrides, and known gaps. The live OpenRouter `/api/v1/models` catalogue automatically supplies exact route estimates across providers; LiteLLM and models.dev remain fallbacks. The supplement is published from upstream's GitHub Pages and is loaded by QuotaBar within about an hour. Full background: `docs/pricing.md`.

Routine API model additions and prompt/completion rates do not need manual supplement edits: OpenRouter refreshes automatically about hourly. Edit the supplement only for aliases, Cursor-native models, verified provider-specific cache/rate overrides, or a documented public-catalog gap. OpenRouter does not provide Cursor's native subscription prices.

## Steps

### 1. Pull the source of truth into context

OpenRouter supplies routine API model discovery and public route rates automatically. When editing a Cursor-specific supplement entry, fetch https://cursor.com/docs/models-and-pricing.md and read the whole thing. It is the source for:

- Cursor-native model prices (`auto`, `composer-*`, Bugbot) — input, cache write, cache read, output, all USD per million tokens.
- Which models have a fast variant and what the fast pricing is.
- Long-context tiers (e.g. Sonnet 1M) that bill the whole request at the >200k rate.
- Model names/slugs as Cursor spells them (needed for alias rules).

### 2. Diff against the current supplement

Read `Sources/QuotaBar/Resources/pricing_supplement.json` and compare:

- **Price changes** on existing `pricing` entries.
- **New Cursor-native models** missing from `pricing`.
- **Removed/renamed models** — never delete an entry that old usage data may still reference; keep it so historical days keep their dollars. Only remove an entry if it was outright wrong.
- **`fast_multipliers`** — for API models whose fast variant is priced as a multiplier of the base rate. Only needed when the catalogs don't carry a `-fast` key themselves.
- **`alias_rules`** — a new model usually needs one, because Cursor CSV slugs and Codex/Claude log names rarely match catalog keys exactly (thinking suffixes, effort levels like `-low`/`-high`/`-xhigh`, dot vs dash versions). Follow the existing patterns: anchored regex, escaped dots, optional effort/thinking groups. `-fast` variants need their own rule ordered BEFORE the base rule (first match wins).

For ordinary API models, confirm whether OpenRouter already lists an exact route before adding anything. Prefer an alias to a public catalogue key over duplicating rates in the supplement; keep a curated override only when a verified source justifies it.

### 3. Edit the supplement

- Update `updated_at` to today (YYYY-MM-DD).
- Keep the file's style: 2-space indent, rates as plain numbers, `$comment` explanations for non-obvious entries.
- Rates are USD per million tokens; cache read defaults matter — copy the exact numbers from the Cursor page, don't infer.

### 4. Validate

Run the same checks CI runs, plus the pricing tests:

```sh
python3 - << 'PY'
import json, re, sys
with open("Sources/QuotaBar/Resources/pricing_supplement.json") as f:
    s = json.load(f)
problems = []
for m, e in s["pricing"].items():
    for f_ in ("input_per_million", "output_per_million"):
        if not isinstance(e.get(f_), (int, float)):
            problems.append(f"pricing[{m}].{f_} missing or not a number")
for r in s["alias_rules"]:
    try: re.compile(r["pattern"])
    except re.error as err: problems.append(f"{r['pattern']!r}: {err}")
    if not r.get("canonical"): problems.append(f"{r['pattern']!r} has no canonical")
for m, x in (s.get("fast_multipliers") or {}).items():
    if not isinstance(x, (int, float)) or x <= 0:
        problems.append(f"fast_multipliers[{m}] must be positive")
sys.exit("FAILED:\n" + "\n".join(problems)) if problems else print("Supplement OK")
PY

swift test --filter "ModelPricing|PricingBundledResource"
```

If a new alias rule maps a slug that appears in real usage, add a resolution test case in `Tests/QuotaBarTests/ModelPricingTests.swift`.

### 5. Publish only when requested

If the user requests publication, branch from `main`, commit (`fix(pricing): ...` or `feat(pricing): ...`), and open a PR following the repo's PR description structure (TL;DR / What was happening / What this changes). Cite the source for each manual price or alias so the owner can verify it. Never push pricing changes directly to `main`.

### 6. Verify publication after an approved merge

Once merged, the `Publish pricing supplement` workflow runs. Confirm it landed:

```sh
gh run list --workflow=pricing-supplement.yml --limit 1
curl -s https://robinebers.github.io/openusage/pricing_supplement.json | python3 -c "import json,sys; print(json.load(sys.stdin)['updated_at'])"
```

The `updated_at` served must match the merged file. Publishing is two hops: the supplement workflow pushes the file to the `gh-pages` branch, then `.github/workflows/deploy-pages.yml` on `main` deploys that branch to the live site (Pages source is "GitHub Actions"). If the URL is stale after ~10 minutes, check `gh run list --workflow=deploy-pages.yml` and re-run **`gh workflow run deploy-pages.yml --ref main`** (not `--ref gh-pages`).

## Optional: refresh bundled snapshots

The bundled LiteLLM/models.dev snapshots (`pricing_*_snapshot.json`) are a separate concern — offline fallbacks refreshed with `./script/update_pricing_snapshots.sh`, typically before a release. Staleness is harmless; only regenerate them if asked or as part of release prep, in their own commit.

## Rules

- USD per million tokens everywhere; verified overrides need an authoritative source.
- Prefer OpenRouter exact routes for routine API estimates, then LiteLLM/models.dev fallbacks; use aliases instead of duplicating prices where possible.
- Never delete pricing entries that historical usage may reference.
- `-fast` alias rules come before their base-model rules.
- Always bump `updated_at`; always go through a PR.
