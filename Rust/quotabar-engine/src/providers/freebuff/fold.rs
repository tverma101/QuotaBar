//! The Freebuff token fold (the accounting loop of `FreebuffDesktopUsageScanner.scan`).
//!
//! Each measured turn resolves its recorded or saved model through the catalogue identity, then
//! prices at the Flash comparison or an exact public route. A turn aggregates several requests, so
//! single-request context tiers never apply. Cached input is already in input; reasoning is already
//! in output.

use super::catalog::CatalogEntries;
use super::flash;
use super::identity::ModelIdentity;
use super::scanner::{DerivedTurn, FreebuffScan, OLDER_USAGE_NAME};
use crate::accounting::{day_key, DailyUsageAccumulator, RowOptions};
use crate::model::ModelUsageEntry;
use crate::pricing::{ModelPricing, TokenBreakdown};
use std::collections::{BTreeSet, HashSet};

pub(super) fn fold_turns(
    turns: Vec<DerivedTurn>,
    now: f64,
    pricing: &ModelPricing,
    catalog: &CatalogEntries,
) -> FreebuffScan {
    let mut identity = ModelIdentity::new(catalog, pricing);
    let mut accumulator = DailyUsageAccumulator::new();
    let mut partial_days = BTreeSet::new();
    let mut seen: HashSet<String> = HashSet::new();
    for turn in turns {
        if seen.contains(&turn.id) {
            continue;
        }
        let timestamp = turn.timestamp_ms / 1000.0;
        if timestamp > now {
            continue;
        }
        let day = day_key(timestamp);
        let Some(usage) = turn.usage else {
            if turn.partial {
                partial_days.insert(day);
            }
            continue;
        };
        let (Some(input), Some(output), Some(cached), Some(reasoning)) = (
            usage.input.required(),
            usage.output.required(),
            usage.cached.optional(),
            usage.reasoning.optional(),
        ) else {
            continue;
        };
        let total = input.saturating_add(output);
        if total <= 0 || cached > input || reasoning > output || !usage.total_matches(total) {
            continue;
        }
        let cloud = turn.id.starts_with("cloud:");
        seen.insert(turn.id);
        let saved = turn
            .saved_model
            .as_deref()
            .filter(|value| !value.is_empty());
        let resolved = saved.map(|model| identity.resolve(model, turn.from_receipt));
        let display_name = resolved
            .as_ref()
            .and_then(|resolved| resolved.display_name.clone());
        // Older local rows saved only an opaque selection; without a catalogue name that is an
        // explained history gap, not an actionable pricing failure.
        let legacy_without_identity = display_name.is_none()
            && !turn.from_receipt
            && !cloud
            && saved.is_none_or(|model| model.starts_with("m-") || model.starts_with("fbm1."));
        let model = if legacy_without_identity {
            OLDER_USAGE_NAME.to_string()
        } else {
            display_name
                .clone()
                .or_else(|| {
                    saved
                        .filter(|model| {
                            (turn.from_receipt || model.contains('/'))
                                && !model.starts_with("fbm1.")
                        })
                        .map(str::to_string)
                })
                .unwrap_or_else(|| ModelUsageEntry::UNATTRIBUTED.to_string())
        };
        let tokens = TokenBreakdown {
            input: input - cached,
            cache_read: cached,
            output,
            ..Default::default()
        };
        let route = resolved
            .as_ref()
            .and_then(|resolved| resolved.route.as_deref());
        let cost = route.and_then(|route| match flash::rates(route, timestamp) {
            Some(rates) => Some(rates.cost_dollars(&tokens, Some(timestamp), false)),
            None => pricing
                .open_router
                .entries
                .get(route)
                .or_else(|| pricing.supplement.pricing.get(route))
                .map(|rates| rates.cost_dollars(&tokens, Some(timestamp), false)),
        });
        let group = resolved
            .as_ref()
            .and_then(|resolved| resolved.group.as_deref());
        accumulator.add_with(
            &day,
            total,
            cost,
            &model,
            RowOptions {
                canonical: group,
                cost_is_complete: cost.is_some(),
                ..Default::default()
            },
        );
        accumulator.record_api_estimate(&day, cost, total);
        let unknown_route = resolved
            .as_ref()
            .is_some_and(|resolved| resolved.has_unknown_route);
        if cost.is_some() {
            accumulator.mark_estimated_cost(&day);
        } else if legacy_without_identity || (display_name.is_some() && !unknown_route) {
            // A catalogue name with no public route is an explained gap: tokens count, no warning.
            accumulator.add_named_unpriced_model(&day, &model);
        } else {
            // A raw slug nothing names, or an unattributed stream: the app cannot tell what served
            // it, so the warning stays honest.
            accumulator.add_unknown_model(&day, &model);
        }
        if turn.partial {
            partial_days.insert(day);
        }
    }
    let mut usage = accumulator.build();
    if !partial_days.is_empty() {
        usage = usage.marking_unmeasured_usage(&partial_days);
    }
    FreebuffScan {
        usage,
        partial_days,
    }
}
