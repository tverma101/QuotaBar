//! Mirror of `DailyUsageAccumulator`: the per-day token/cost/model roll-up and the `LogUsageScan`
//! assembly. See the module docs in [`super`] for why pricing resolution and day bucketing stay in
//! Swift while this pass runs in Rust.

use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, BTreeSet, HashMap};

use super::{adding_finite_cost, adding_saturating};

/// Mirror of `DailyUsageAccumulator`. Every method carries the same overflow, completeness, and
/// unknown-model rules as the Swift original; `build` emits the Codable shape of `LogUsageScan`.
#[derive(Debug, Default)]
pub struct DailyUsageAccumulator {
    tokens_by_day: HashMap<String, i64>,
    cost_by_day: HashMap<String, f64>,
    estimated_cost_days: BTreeSet<String>,
    api_estimate_by_day: HashMap<String, f64>,
    api_estimate_incomplete_days: BTreeSet<String>,
    unknown_models_by_day: BTreeMap<String, BTreeSet<String>>,
    named_unpriced_models_by_day: BTreeMap<String, BTreeSet<String>>,
    incomplete_cost_days: BTreeSet<String>,
    structural_incomplete_cost_days: BTreeSet<String>,
    incomplete_model_costs_by_day: BTreeMap<String, BTreeSet<String>>,
    token_count_saturated_days: BTreeSet<String>,
    models_by_day: BTreeMap<String, BTreeMap<String, ModelAccumulator>>,
    overflowed_cost_days: BTreeSet<String>,
    overflowed_api_estimate_days: BTreeSet<String>,
    unmeasured_usage_days: BTreeSet<String>,
}

impl DailyUsageAccumulator {
    /// Used by provider folds whose sources can report unmeasured usage (pi, routed ledgers); kept
    /// on the shared accumulator so those ports do not re-implement the day set.
    #[allow(dead_code)]
    pub fn mark_unmeasured_usage(&mut self, day: &str) {
        self.unmeasured_usage_days.insert(day.to_string());
    }

    pub fn add(
        &mut self,
        day: &str,
        tokens: i64,
        cost: Option<f64>,
        model: &str,
        canonical: Option<&str>,
        cost_is_complete: bool,
        token_count_saturated: bool,
    ) {
        let prior_tokens = self.tokens_by_day.get(day).copied().unwrap_or(0);
        if tokens > 0 && prior_tokens > i64::MAX - tokens {
            self.token_count_saturated_days.insert(day.to_string());
        }
        if token_count_saturated {
            self.token_count_saturated_days.insert(day.to_string());
        }
        self.tokens_by_day
            .insert(day.to_string(), adding_saturating(prior_tokens, tokens));

        if let Some(cost) = cost {
            if self.overflowed_cost_days.contains(day) {
                self.incomplete_cost_days.insert(day.to_string());
            } else if let Some(total) = adding_finite_cost(self.cost_by_day.get(day).copied(), cost)
            {
                self.cost_by_day.insert(day.to_string(), total);
            } else {
                self.overflowed_cost_days.insert(day.to_string());
                self.incomplete_cost_days.insert(day.to_string());
            }
        } else if tokens > 0 {
            self.incomplete_cost_days.insert(day.to_string());
            self.incomplete_model_costs_by_day
                .entry(day.to_string())
                .or_default()
                .insert(model.to_string());
        }
        if !cost_is_complete {
            self.incomplete_cost_days.insert(day.to_string());
            self.incomplete_model_costs_by_day
                .entry(day.to_string())
                .or_default()
                .insert(model.to_string());
        }

        let identity = canonical.unwrap_or(model);
        self.models_by_day
            .entry(day.to_string())
            .or_default()
            .entry(identity.to_string())
            .or_default()
            .add(tokens, cost, model, cost_is_complete, token_count_saturated);
    }

    pub fn mark_cost_incomplete(&mut self, day: &str, model: &str, canonical: Option<&str>) {
        self.incomplete_cost_days.insert(day.to_string());
        self.structural_incomplete_cost_days.insert(day.to_string());
        self.mark_model_cost_incomplete(day, model, canonical);
    }

    pub fn mark_model_cost_incomplete(&mut self, day: &str, model: &str, canonical: Option<&str>) {
        let identity = canonical.unwrap_or(model);
        if let Some(accumulator) = self
            .models_by_day
            .get_mut(day)
            .and_then(|models| models.get_mut(identity))
        {
            accumulator.mark_cost_incomplete(model);
        }
    }

    pub fn add_api_estimate(&mut self, day: &str, cost: f64) {
        if self.overflowed_api_estimate_days.contains(day) {
            self.api_estimate_incomplete_days.insert(day.to_string());
            return;
        }
        if let Some(total) = adding_finite_cost(self.api_estimate_by_day.get(day).copied(), cost) {
            self.api_estimate_by_day.insert(day.to_string(), total);
        } else {
            self.api_estimate_by_day.remove(day);
            self.overflowed_api_estimate_days.insert(day.to_string());
            self.api_estimate_incomplete_days.insert(day.to_string());
        }
    }

    #[allow(dead_code)]
    pub fn mark_estimated_cost(&mut self, day: &str) {
        self.estimated_cost_days.insert(day.to_string());
    }

    pub fn record_api_estimate(&mut self, day: &str, cost: Option<f64>, tokens: i64) {
        if tokens <= 0 {
            return;
        }
        if let Some(cost) = cost {
            self.add_api_estimate(day, cost);
        } else {
            self.api_estimate_incomplete_days.insert(day.to_string());
        }
    }

    pub fn add_unknown_model(&mut self, day: &str, model: &str) {
        self.unknown_models_by_day
            .entry(day.to_string())
            .or_default()
            .insert(model.to_string());
        self.incomplete_cost_days.insert(day.to_string());
        self.api_estimate_incomplete_days.insert(day.to_string());
    }

    #[allow(dead_code)]
    pub fn add_named_unpriced_model(&mut self, day: &str, model: &str) {
        self.named_unpriced_models_by_day
            .entry(day.to_string())
            .or_default()
            .insert(model.to_string());
        self.incomplete_cost_days.insert(day.to_string());
        self.api_estimate_incomplete_days.insert(day.to_string());
    }

    pub fn build(&self) -> Value {
        let mut days: Vec<&String> = self.tokens_by_day.keys().collect();
        days.sort();
        days.reverse();

        let series: Vec<Value> = days
            .iter()
            .map(|day| {
                let day = day.as_str();
                let known_models: BTreeSet<&String> = self
                    .unknown_models_by_day
                    .get(day)
                    .into_iter()
                    .flatten()
                    .chain(
                        self.named_unpriced_models_by_day
                            .get(day)
                            .into_iter()
                            .flatten(),
                    )
                    .collect();
                let has_structural_gap = self.structural_incomplete_cost_days.contains(day)
                    || self
                        .incomplete_model_costs_by_day
                        .get(day)
                        .map(|models| models.iter().any(|model| !known_models.contains(model)))
                        .unwrap_or(false);
                let has_known_cost_gap =
                    self.overflowed_cost_days.contains(day) || !known_models.is_empty();
                let has_unexplained = if has_structural_gap {
                    Some(true)
                } else if has_known_cost_gap {
                    Some(false)
                } else {
                    None
                };

                let mut row = Map::new();
                row.insert("date".into(), json!(day));
                row.insert(
                    "totalTokens".into(),
                    json!(self.tokens_by_day.get(day).copied().unwrap_or(0)),
                );
                if let Some(cost) = self.cost_by_day.get(day) {
                    row.insert("costUSD".into(), json!(cost));
                }
                row.insert(
                    "costIsComplete".into(),
                    json!(!self.incomplete_cost_days.contains(day)),
                );
                if let Some(unexplained) = has_unexplained {
                    row.insert("hasUnexplainedIncompleteCost".into(), json!(unexplained));
                }
                row.insert(
                    "tokenCountSaturated".into(),
                    json!(self.token_count_saturated_days.contains(day)),
                );
                Value::Object(row)
            })
            .collect();

        let mut model_days: Vec<&String> = self.models_by_day.keys().collect();
        model_days.sort();
        model_days.reverse();
        let model_daily: Vec<Value> = model_days
            .iter()
            .map(|day| {
                let mut models: Vec<Value> = self
                    .models_by_day
                    .get(*day)
                    .into_iter()
                    .flatten()
                    .map(|(model, accumulator)| accumulator.entry(model))
                    .collect();
                // Swift applies `localizedStandardCompare` to the final name tie-break; the bridge
                // re-sorts each day with that exact comparator. This pass only has to make the
                // numeric order match (cost desc, then tokens desc) and stay deterministic.
                models.sort_by(|lhs, rhs| {
                    let lhs_cost = lhs.get("costUSD").and_then(Value::as_f64).unwrap_or(0.0);
                    let rhs_cost = rhs.get("costUSD").and_then(Value::as_f64).unwrap_or(0.0);
                    if lhs_cost != rhs_cost {
                        return rhs_cost.total_cmp(&lhs_cost);
                    }
                    let lhs_tokens = lhs.get("totalTokens").and_then(Value::as_i64).unwrap_or(0);
                    let rhs_tokens = rhs.get("totalTokens").and_then(Value::as_i64).unwrap_or(0);
                    if lhs_tokens != rhs_tokens {
                        return rhs_tokens.cmp(&lhs_tokens);
                    }
                    lhs.get("model")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .cmp(rhs.get("model").and_then(Value::as_str).unwrap_or_default())
                });
                json!({ "date": day, "models": models })
            })
            .collect();

        let unknown_models: Map<String, Value> = self
            .unknown_models_by_day
            .iter()
            .map(|(day, models)| (day.clone(), json!(models)))
            .collect();

        let mut result = Map::new();
        result.insert("series".into(), json!({ "daily": series }));
        result.insert("modelUsage".into(), json!({ "daily": model_daily }));
        result.insert("unknownModelsByDay".into(), Value::Object(unknown_models));
        if !self.api_estimate_by_day.is_empty() {
            let estimates: Map<String, Value> = self
                .api_estimate_by_day
                .iter()
                .map(|(day, estimate)| (day.clone(), json!(estimate)))
                .collect();
            result.insert("apiEstimateByDay".into(), Value::Object(estimates));
        }
        result.insert(
            "apiEstimateIncompleteDays".into(),
            json!(self.api_estimate_incomplete_days),
        );
        if !self.estimated_cost_days.is_empty() {
            result.insert("estimatedCostDays".into(), json!(self.estimated_cost_days));
        }
        if !self.unmeasured_usage_days.is_empty() {
            result.insert(
                "unmeasuredUsageDays".into(),
                json!(self.unmeasured_usage_days),
            );
        }
        Value::Object(result)
    }
}

#[derive(Debug)]
struct ModelAccumulator {
    tokens: i64,
    token_count_saturated: bool,
    cost_usd: Option<f64>,
    cost_is_complete: bool,
    cost_overflowed: bool,
    spellings: HashMap<String, Spelling>,
}

impl ModelAccumulator {
    fn new() -> Self {
        Self {
            tokens: 0,
            token_count_saturated: false,
            cost_usd: None,
            cost_is_complete: true,
            cost_overflowed: false,
            spellings: HashMap::new(),
        }
    }

    fn add(
        &mut self,
        tokens: i64,
        cost_usd: Option<f64>,
        spelling: &str,
        cost_is_complete: bool,
        source_token_count_saturated: bool,
    ) {
        if tokens > 0 && self.tokens > i64::MAX - tokens {
            self.token_count_saturated = true;
        }
        self.tokens = adding_saturating(self.tokens, tokens);
        self.token_count_saturated = self.token_count_saturated || source_token_count_saturated;
        if let Some(cost) = cost_usd {
            if !self.cost_overflowed {
                if let Some(total) = adding_finite_cost(self.cost_usd, cost) {
                    self.cost_usd = Some(total);
                } else {
                    self.cost_overflowed = true;
                    self.cost_is_complete = false;
                }
            }
        } else if tokens > 0 {
            self.cost_is_complete = false;
        }
        if !cost_is_complete {
            self.cost_is_complete = false;
        }

        let key = spelling.to_lowercase();
        let existing = self.spellings.entry(key).or_insert_with(|| Spelling {
            tokens: 0,
            cost_usd: None,
            spelling: spelling.to_string(),
            cost_is_complete: true,
            token_count_saturated: false,
            cost_overflowed: false,
        });
        if tokens > 0 && existing.tokens > i64::MAX - tokens {
            existing.token_count_saturated = true;
        }
        existing.tokens = adding_saturating(existing.tokens, tokens);
        existing.token_count_saturated =
            existing.token_count_saturated || source_token_count_saturated;
        if let Some(cost) = cost_usd {
            if !existing.cost_overflowed {
                if let Some(total) = adding_finite_cost(existing.cost_usd, cost) {
                    existing.cost_usd = Some(total);
                } else {
                    existing.cost_overflowed = true;
                    existing.cost_is_complete = false;
                }
            }
        } else if tokens > 0 {
            existing.cost_is_complete = false;
        }
        if !cost_is_complete {
            existing.cost_is_complete = false;
        }
    }

    fn mark_cost_incomplete(&mut self, spelling: &str) {
        self.cost_is_complete = false;
        if let Some(existing) = self.spellings.get_mut(&spelling.to_lowercase()) {
            existing.cost_is_complete = false;
        }
    }

    fn entry(&self, model: &str) -> Value {
        let mut variants: Vec<&Spelling> = self.spellings.values().collect();
        variants.sort_by(|lhs, rhs| {
            rhs.tokens
                .cmp(&lhs.tokens)
                .then_with(|| lhs.spelling.cmp(&rhs.spelling))
        });

        let mut row = Map::new();
        row.insert("model".into(), json!(model));
        row.insert("totalTokens".into(), json!(self.tokens));
        if let Some(cost) = self.cost_usd {
            row.insert("costUSD".into(), json!(cost));
        }
        let is_trivial =
            variants.len() == 1 && variants[0].spelling.to_lowercase() == model.to_lowercase();
        if !is_trivial && !variants.is_empty() {
            let values: Vec<Value> = variants
                .iter()
                .map(|variant| {
                    let mut value = Map::new();
                    value.insert("model".into(), json!(variant.spelling));
                    value.insert("totalTokens".into(), json!(variant.tokens));
                    if let Some(cost) = variant.cost_usd {
                        value.insert("costUSD".into(), json!(cost));
                    }
                    if !variant.cost_is_complete {
                        value.insert("costIsComplete".into(), json!(false));
                    }
                    if variant.token_count_saturated {
                        value.insert("tokenCountSaturated".into(), json!(true));
                    }
                    Value::Object(value)
                })
                .collect();
            row.insert("variants".into(), json!(values));
        }
        if !self.cost_is_complete {
            row.insert("costIsComplete".into(), json!(false));
        }
        if self.token_count_saturated {
            row.insert("tokenCountSaturated".into(), json!(true));
        }
        Value::Object(row)
    }
}

impl Default for ModelAccumulator {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug)]
struct Spelling {
    tokens: i64,
    cost_usd: Option<f64>,
    spelling: String,
    cost_is_complete: bool,
    token_count_saturated: bool,
    cost_overflowed: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accumulator_builds_days_and_incomplete_markers() {
        let mut accumulator = DailyUsageAccumulator::default();
        accumulator.add("2026-01-02", 100, Some(0.5), "priced", None, true, false);
        accumulator.add("2026-01-02", 50, None, "mystery", None, true, false);
        accumulator.add_unknown_model("2026-01-02", "mystery");
        let scan = accumulator.build();
        let days = scan["series"]["daily"].as_array().unwrap();
        assert_eq!(days.len(), 1);
        assert_eq!(days[0]["date"], "2026-01-02");
        assert_eq!(days[0]["totalTokens"], 150);
        assert_eq!(days[0]["costUSD"], 0.5);
        assert_eq!(days[0]["costIsComplete"], false);
        assert_eq!(days[0]["hasUnexplainedIncompleteCost"], false);
        assert_eq!(scan["unknownModelsByDay"]["2026-01-02"][0], "mystery");
        assert_eq!(scan["apiEstimateIncompleteDays"][0], "2026-01-02");
    }
}
