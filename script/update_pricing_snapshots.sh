#!/bin/bash
# Regenerates the bundled pricing snapshots from the live feeds:
#
#   Sources/QuotaBar/Resources/pricing_litellm_snapshot.json      (LiteLLM model_prices)
#   Sources/QuotaBar/Resources/pricing_models_dev_snapshot.json   (models.dev api.json)
#
# The snapshots are the offline fallback for first launch / no network; at runtime the app fetches
# the same feeds hourly and its disk cache overlays these. Refreshing them at release time keeps
# first launches accurate. Each regeneration merges the live feed over the previous snapshot:
# fresh rates win per model, and models the feed dropped stay priced so historical usage keeps
# its dollars. Run from the repo root:
#
#   ./script/update_pricing_snapshots.sh
#
# The compact format must stay in sync with PricingCatalogCodecs.swift (compact codec + the
# defaulting rules of the LiteLLM/models.dev parsers): per-million rates and cache write defaults to
# the input rate. If a source omits cache read, runtime estimates use the selected input rate and
# `cre:false` records that provenance. Context tiers use the same PromptRateTier coding keys as the
# supplement. A cache-read lane published only in a context tier still marks the entry as explicit.
# After regenerating, `swift test` exercises the snapshots via the pricing resolution tests.
set -euo pipefail

cd "$(dirname "$0")/.."
RESOURCES="Sources/QuotaBar/Resources"

LITELLM_URL="https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
MODELS_DEV_URL="https://models.dev/api.json"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

echo "Fetching LiteLLM pricing..."
curl -fsSL --max-time 120 "$LITELLM_URL" -o "$tmpdir/litellm.json"
echo "Fetching models.dev pricing..."
curl -fsSL --max-time 120 "$MODELS_DEV_URL" -o "$tmpdir/models_dev.json"

python3 - "$tmpdir" "$RESOURCES" << 'PY'
import json
import sys
from datetime import datetime, timezone

sys.path.insert(0, "script")
from pricing_snapshot_codec import cache_read_is_explicit

tmpdir, resources = sys.argv[1], sys.argv[2]
retrieved_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def merged_models(models, snapshot_path):
    """Fresh rates win per key; models the feed dropped stay priced for historical usage."""
    try:
        with open(snapshot_path) as f:
            previous = json.load(f)["models"]
    except (OSError, KeyError, ValueError):
        previous = {}
    merged = {**previous, **models}
    kept = len(set(previous) - set(models))
    added = len(set(models) - set(previous))
    print(f"  {len(models)} live + {kept} historical-only keys preserved ({added} new vs previous)")
    return merged

def previous_retired_keys(snapshot_path):
    try:
        with open(snapshot_path) as f:
            return set(json.load(f).get("retired") or [])
    except (OSError, KeyError, ValueError):
        return set()

def compact_model(input_pm, output_pm, cache_write_pm, cache_read_pm, cache_read_explicit,
                  ia=None, oa=None, cwa=None, cra=None, fast=None, tiers=None):
    model = {"i": input_pm, "o": output_pm, "cw": cache_write_pm, "cr": cache_read_pm}
    if not cache_read_explicit:
        model["cre"] = False
    for key, value in (("ia", ia), ("oa", oa), ("cwa", cwa), ("cra", cra), ("fast", fast)):
        if value is not None:
            model[key] = value
    if tiers:
        model["tiers"] = tiers
    return model

def number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None

def litellm_tiers(entry):
    fields = {
        "input_per_million": "input_cost_per_token",
        "output_per_million": "output_cost_per_token",
        "cache_write_per_million": "cache_creation_input_token_cost",
        "cache_read_per_million": "cache_read_input_token_cost",
    }
    tiers = []
    for threshold in (100_000, 128_000, 200_000, 272_000, 512_000):
        tier = {"threshold_prompt_tokens": threshold, "includes_threshold": False}
        for output_name, source_name in fields.items():
            rate = number(entry.get(f"{source_name}_above_{threshold // 1000}k_tokens"))
            if rate is not None:
                tier[output_name] = rate * 1e6
        if len(tier) > 2:
            tiers.append(tier)
    return tiers

def models_dev_tiers(cost):
    tiers = []
    for source_tier in cost.get("tiers") or []:
        if not isinstance(source_tier, dict):
            continue
        context = source_tier.get("tier") or {}
        threshold = number(context.get("size")) if context.get("type", "context") == "context" else None
        if threshold is None or int(threshold) != threshold:
            continue
        # models.dev `tier.size` starts the new context band, so the exact threshold
        # belongs to that tier. LiteLLM's `_above_N_tokens` fields are exclusive above.
        tier = {"threshold_prompt_tokens": int(threshold), "includes_threshold": True}
        for field in ("input", "output", "cache_write", "cache_read"):
            rate = number(source_tier.get(field))
            if rate is not None:
                tier[f"{field}_per_million"] = rate
        if len(tier) > 2:
            tiers.append(tier)
    if not any(tier["threshold_prompt_tokens"] == 200_000 for tier in tiers):
        high = cost.get("context_over_200k") or {}
        if isinstance(high, dict):
            tier = {"threshold_prompt_tokens": 200_000, "includes_threshold": True}
            for field in ("input", "output", "cache_write", "cache_read"):
                rate = number(high.get(field))
                if rate is not None:
                    tier[f"{field}_per_million"] = rate
            if len(tier) > 2:
                tiers.append(tier)
    return sorted(tiers, key=lambda tier: tier["threshold_prompt_tokens"])

# LiteLLM: costs are per token; entries without both input and output cost are stubs -> skipped.
with open(f"{tmpdir}/litellm.json") as f:
    litellm = json.load(f)
models = {}
for key, entry in litellm.items():
    if not isinstance(entry, dict):
        continue
    i, o = number(entry.get("input_cost_per_token")), number(entry.get("output_cost_per_token"))
    if i is None or o is None:
        continue
    cw = number(entry.get("cache_creation_input_token_cost"))
    cr = number(entry.get("cache_read_input_token_cost"))
    tiers = litellm_tiers(entry)
    provider_specific = entry.get("provider_specific_entry") or {}
    models[key] = compact_model(
        i * 1e6, o * 1e6,
        (cw if cw is not None else i) * 1e6,
        (cr if cr is not None else i) * 1e6,
        cache_read_is_explicit(cr, tiers),
        ia=(lambda v: v * 1e6 if v is not None else None)(number(entry.get("input_cost_per_token_above_200k_tokens"))),
        oa=(lambda v: v * 1e6 if v is not None else None)(number(entry.get("output_cost_per_token_above_200k_tokens"))),
        cwa=(lambda v: v * 1e6 if v is not None else None)(number(entry.get("cache_creation_input_token_cost_above_200k_tokens"))),
        cra=(lambda v: v * 1e6 if v is not None else None)(number(entry.get("cache_read_input_token_cost_above_200k_tokens"))),
        tiers=tiers,
        fast=number(provider_specific.get("fast")) if isinstance(provider_specific, dict) else None,
    )
if not models:
    sys.exit("LiteLLM feed produced no usable entries - aborting.")
models = merged_models(models, f"{resources}/pricing_litellm_snapshot.json")
with open(f"{resources}/pricing_litellm_snapshot.json", "w") as f:
    json.dump({"retrieved_at": retrieved_at, "models": models}, f, sort_keys=True, separators=(",", ":"))
print(f"pricing_litellm_snapshot.json: {len(models)} models")

# models.dev: costs are already per million; ids are stored bare. Conflicting provider-specific
# prices are omitted instead of depending on provider order.
with open(f"{tmpdir}/models_dev.json") as f:
    models_dev = json.load(f)
candidate_models = {}
for provider_name in sorted(models_dev):
    provider = models_dev[provider_name]
    if not isinstance(provider, dict):
        continue
    for model_id, model in (provider.get("models") or {}).items():
        if not isinstance(model, dict):
            continue
        cost = model.get("cost") or {}
        i, o = number(cost.get("input")), number(cost.get("output"))
        if i is None or o is None:
            continue
        cw, cr = number(cost.get("cache_write")), number(cost.get("cache_read"))
        tiers = models_dev_tiers(cost)
        candidate_models.setdefault(model_id, []).append(compact_model(
            i, o,
            cw if cw is not None else i,
            cr if cr is not None else i,
            cache_read_is_explicit(cr, tiers),
            tiers=tiers,
        ))
models = {
    model_id: candidates[0]
    for model_id, candidates in candidate_models.items()
    if all(candidate == candidates[0] for candidate in candidates[1:])
}
conflicting_ids = set(candidate_models) - set(models)
if not models:
    sys.exit("models.dev feed produced no usable entries - aborting.")
models = merged_models(models, f"{resources}/pricing_models_dev_snapshot.json")
retired_ids = previous_retired_keys(f"{resources}/pricing_models_dev_snapshot.json") - set(models)
for model_id in conflicting_ids:
    models.pop(model_id, None)
    retired_ids.add(model_id)
if conflicting_ids:
    print(f"  omitted {len(conflicting_ids)} IDs with conflicting provider-specific rates")
with open(f"{resources}/pricing_models_dev_snapshot.json", "w") as f:
    json.dump({
        "retrieved_at": retrieved_at,
        "models": models,
        "retired": sorted(retired_ids),
    }, f, sort_keys=True, separators=(",", ":"))
print(f"pricing_models_dev_snapshot.json: {len(models)} models")
PY

ls -lh "$RESOURCES"/pricing_*_snapshot.json
