//! SpendTileMapperTests: the per-period model breakdown (scoping, sorting, folding into Other).

use super::*;

fn one_day(tokens: i64, cost: Option<f64>, models: Vec<ModelUsageEntry>) -> Vec<MetricLine> {
    mapped_lines(vec![entry("2026-06-26", tokens, cost)], vec![model_day("2026-06-26", models)], BTreeMap::new(), None)
}

#[test]
fn model_breakdown_scopes_today_yesterday_and_last30() {
    let lines = mapped_lines(
        vec![entry("2026-06-26", 300, Some(3.0)), entry("2026-06-25", 700, Some(7.0))],
        vec![
            model_day("2026-06-26", vec![model("alpha", 100, Some(1.0)), model("beta", 200, Some(2.0))]),
            model_day("2026-06-25", vec![model("alpha", 300, Some(3.0)), model("gamma", 400, Some(4.0))]),
        ],
        BTreeMap::new(),
        None,
    );
    let today = model_breakdown(&lines, "Today").expect("today");
    assert_eq!(today.total_tokens, 300);
    assert_eq!(today.total_cost_usd, Some(3.0));
    assert_eq!(model_names(&today), vec!["beta", "alpha"]);

    let yesterday = model_breakdown(&lines, "Yesterday").expect("yesterday");
    assert_eq!(model_names(&yesterday), vec!["gamma", "alpha"]);

    let last30 = model_breakdown(&lines, "Last 30 Days").expect("last 30");
    assert_eq!(last30.total_tokens, 1000);
    assert_eq!(last30.total_cost_usd, Some(10.0));
    assert_eq!(model_names(&last30), vec!["alpha", "gamma", "beta"]);
    assert_eq!(last30.source_note.as_deref(), Some("From test logs"));
    assert_eq!(values(&lines, "Last 30 Days"), Some(vec![dollars(10.0, true, false), tokens(1000.0)]));
}

#[test]
fn model_and_other_rows_keep_known_subtotals_and_mark_them_partial() {
    let models = vec![
        model_day("2026-06-26", vec![model("heavy", 890, Some(89.0)), model("shared", 100, Some(10.0)), model("tiny-priced", 10, Some(1.0))]),
        model_day("2026-06-25", vec![model("heavy", 890, Some(89.0)), model("shared", 100, None), model("tiny-unpriced", 10, None)]),
    ];
    let lines = mapped_lines(
        vec![
            entry("2026-06-26", 1_000, Some(100.0)),
            DailyUsageEntry { cost_is_complete: false, ..entry("2026-06-25", 1_000, Some(89.0)) },
        ],
        models,
        unknown_by_day(&[("2026-06-25", &["shared", "tiny-unpriced"])]),
        None,
    );
    let breakdown = model_breakdown(&lines, "Last 30 Days").expect("breakdown");
    // tiny-priced is the whole Other price and tiny-unpriced adds none, so each stays named.
    assert_eq!(model_names(&breakdown), vec!["heavy", "shared", "tiny-priced", "tiny-unpriced"]);
    assert_eq!(find(&breakdown, "heavy").and_then(|m| m.cost_usd), Some(178.0));
    let shared = find(&breakdown, "shared").expect("shared");
    assert_eq!(shared.cost_usd, Some(10.0));
    assert!(shared.has_incomplete_cost());
    let priced = find(&breakdown, "tiny-priced").expect("priced");
    assert_eq!(priced.cost_usd, Some(1.0));
    assert!(priced.variants.is_none());
    let unpriced = find(&breakdown, "tiny-unpriced").expect("unpriced");
    assert_eq!(unpriced.cost_usd, None);
    assert_eq!(unpriced.total_tokens, 10);
    assert!(find(&breakdown, "Other").is_none());
}

#[test]
fn model_breakdown_sorts_folds_other_and_keeps_unpriced_named() {
    let lines = one_day(
        3_700,
        Some(49.0),
        vec![
            model("alpha", 100, Some(10.0)),
            model("beta", 200, Some(9.0)),
            model("aardvark", 300, Some(9.0)),
            model("delta", 400, Some(7.0)),
            model("epsilon", 500, Some(6.0)),
            model("zeta", 600, Some(5.0)),
            model("eta", 700, Some(3.0)),
            model("mystery", 900, None),
        ],
    );
    // The unpriced "mystery" puts the whole list on token shares, so "alpha" — top spend but ~3% of
    // tokens — is the only model small enough to fold; one model is not a group, so it keeps its name.
    // "eta" clears the cap's slot count but holds 19% of tokens, so the token floor keeps it named.
    let breakdown = model_breakdown(&lines, "Today").expect("breakdown");
    assert_eq!(
        model_names(&breakdown),
        vec!["aardvark", "beta", "delta", "epsilon", "zeta", "eta", "mystery", "alpha"]
    );
    let alpha = find(&breakdown, "alpha").expect("alpha");
    assert_eq!(alpha.total_tokens, 100);
    assert_eq!(alpha.cost_usd, Some(10.0));
    assert!(alpha.variants.is_none(), "a lone small model is not listed again under itself");
    assert!(find(&breakdown, "Other").is_none());
    assert_eq!(find(&breakdown, "mystery").and_then(|m| m.cost_usd), None);
}

#[test]
fn model_breakdown_folds_models_minor_on_both_shares_into_other() {
    let lines = one_day(
        1_000,
        Some(100.0),
        vec![model("big", 700, Some(90.0)), model("mid", 200, Some(6.0)), model("tiny", 100, Some(4.0))],
    );
    // All priced -> cost shares 90% / 6% / 4%. "tiny" is under the 5% cost floor, but holds 10% of the
    // measured tokens, so the token floor keeps it named; nothing folds.
    let breakdown = model_breakdown(&lines, "Today").expect("breakdown");
    assert_eq!(model_names(&breakdown), vec!["big", "mid", "tiny"]);
    assert!(find(&breakdown, "Other").is_none(), "no slivers, no Other row");
}

/// The reported bug: a model holding half the measured tokens vanished into Other because its
/// imputed-cost share was 2.9%.
#[test]
fn model_breakdown_keeps_cheap_heavy_model_named_despite_small_cost_share() {
    let models = vec![
        model("grok-4.6", 410_300_000, Some(553.04)),
        model("grok-4.7", 54_700_000, Some(35.06)),
        model("glm-5.3-flash", 488_000_000, Some(19.61)),
        model("straggler-a", 5_000_000, Some(0.50)),
        model("straggler-b", 3_000_000, Some(0.30)),
    ];
    let total: i64 = models.iter().map(|m| m.total_tokens).sum();
    let lines = one_day(total, Some(608.51), models);

    let breakdown = model_breakdown(&lines, "Today").expect("breakdown");
    assert_eq!(model_names(&breakdown), vec!["grok-4.6", "grok-4.7", "glm-5.3-flash", "Other"]);
    assert_eq!(find(&breakdown, "glm-5.3-flash").map(|m| m.total_tokens), Some(488_000_000));
    let other = find(&breakdown, "Other").expect("other");
    assert_eq!(other.total_tokens, 8_000_000);
    assert_eq!(other.cost_usd, Some(0.80));
    let names: Vec<&str> = other.variants.iter().flatten().map(|v| v.model.as_str()).collect();
    assert_eq!(names, vec!["straggler-a", "straggler-b"]);
}

#[test]
fn model_breakdown_keeps_high_token_zero_cost_model_named() {
    let models = vec![
        model("muse-spark-1.3-contributor", 243_900_000, Some(1.14)),
        model("mimo-v2.5", 13_700_000, Some(0.18)),
        model("deepseek-v4.1-flash", 13_200_000, Some(0.16)),
        model("another-paid-model", 10_000, Some(0.10)),
        model("last-paid-model", 10_000, Some(0.10)),
        model("space-bunny-free", 10_500_000_000, Some(0.0)),
        model("tiny-paid-model", 1_000, Some(0.01)),
    ];
    let total: i64 = models.iter().map(|m| m.total_tokens).sum();
    let lines = one_day(total, Some(1.69), models);

    let breakdown = model_breakdown(&lines, "Today").expect("breakdown");
    let free = find(&breakdown, "space-bunny-free").expect("free");
    assert_eq!(free.total_tokens, 10_500_000_000);
    assert_eq!(free.cost_usd, Some(0.0));
    let tiny = find(&breakdown, "tiny-paid-model").expect("tiny");
    assert_eq!(tiny.total_tokens, 1_000);
    assert_eq!(tiny.cost_usd, Some(0.01));
    assert!(tiny.variants.is_none());
    assert!(find(&breakdown, "Other").is_none(), "the only sliver stays named so its cost is not printed twice");
}

/// The Codex Today hover showed gpt-6-luna under Other with the same $0.05 and 1.5M tokens.
#[test]
fn single_small_model_is_not_restated_under_other() {
    let lines = one_day(
        45_600_000,
        Some(4.46),
        vec![model("gpt-6.1-terra", 44_100_000, Some(4.41)), model("gpt-6-luna", 1_500_000, Some(0.05))],
    );
    let breakdown = model_breakdown(&lines, "Today").expect("breakdown");
    assert_eq!(model_names(&breakdown), vec!["gpt-6.1-terra", "gpt-6-luna"]);
    let luna = find(&breakdown, "gpt-6-luna").expect("luna");
    assert_eq!(luna.total_tokens, 1_500_000);
    assert_eq!(luna.cost_usd, Some(0.05));
    assert!(luna.variants.is_none());
    assert!(find(&breakdown, "Other").is_none());
    assert_eq!(breakdown.models.iter().map(|m| m.total_tokens).sum::<i64>(), 45_600_000);
}

/// Cursor and Antigravity fold one priced model together with unpriced tokens. Other's price then
/// matches that one model, so the hover was printing the same dollars twice.
#[test]
fn other_does_not_restate_the_only_priced_contributor() {
    let lines = one_day(
        20_761_030,
        Some(11.76),
        vec![
            model("grok-4.7", 19_751_173, Some(11.52)),
            model("composer-2.5", 110_650, Some(0.24)),
            model("Grok Bot", 899_207, None),
        ],
    );
    let breakdown = model_breakdown(&lines, "Today").expect("breakdown");
    assert_eq!(model_names(&breakdown), vec!["grok-4.7", "composer-2.5", "Grok Bot"]);
    assert!(find(&breakdown, "Other").is_none());
    assert_eq!(breakdown.models.iter().map(|m| m.total_tokens).sum::<i64>(), 20_761_030);
    assert_eq!(find(&breakdown, "composer-2.5").and_then(|m| m.cost_usd), Some(0.24));
    assert_eq!(find(&breakdown, "Grok Bot").and_then(|m| m.cost_usd), None);
    assert_eq!(find(&breakdown, "Grok Bot").map(|m| m.total_tokens), Some(899_207));

    let echoed = ModelUsageEntry {
        variants: Some(vec![
            variant("claude-opus-4-6-thinking", 5_453_009, Some(5.40)),
            variant("Unknown Antigravity Model", 41_884, None),
        ]),
        ..model("Other", 5_494_893, Some(5.40))
    };
    let rows = echoed.presented_rows();
    assert_eq!(
        rows.iter().map(|m| m.model.as_str()).collect::<Vec<_>>(),
        vec!["claude-opus-4-6-thinking", "Unknown Antigravity Model"]
    );
    assert_eq!(rows.iter().map(|m| m.total_tokens).sum::<i64>(), 5_494_893);

    let shared = ModelUsageEntry {
        variants: Some(vec![variant("straggler-a", 5_000_000, Some(0.50)), variant("straggler-b", 3_000_000, Some(0.30))]),
        ..model("Other", 8_000_000, Some(0.80))
    };
    let rows = shared.presented_rows();
    assert_eq!(rows.iter().map(|m| m.model.as_str()).collect::<Vec<_>>(), vec!["Other"], "a real mix stays one Other group");
}

#[test]
fn model_breakdown_folds_unattributed_into_other_regardless_of_size() {
    let lines = one_day(
        1_000,
        Some(6.0),
        // 40% of tokens — well above the 5% floor, still folds.
        vec![model("grok-build", 600, Some(6.0)), model(ModelUsageEntry::UNATTRIBUTED, 400, None)],
    );
    let breakdown = model_breakdown(&lines, "Today").expect("breakdown");
    assert_eq!(model_names(&breakdown), vec!["grok-build", "Other"], "unattributed tokens read as Other");
    let other = find(&breakdown, "Other").expect("other");
    assert_eq!(other.total_tokens, 400);
    assert_eq!(other.cost_usd, None);
    assert!(other.variants.is_none(), "unattributed usage is not listed a second time under Other");
}

#[test]
fn model_breakdown_groups_case_insensitively_and_keeps_dominant_spelling() {
    let lines = one_day(400, Some(4.0), vec![model("GLM-5.2", 100, Some(1.0)), model("glm-5.2", 300, Some(3.0))]);
    let breakdown = model_breakdown(&lines, "Today").expect("breakdown");
    assert_eq!(model_names(&breakdown), vec!["glm-5.2"], "case variants collapse into one row");
    let merged = &breakdown.models[0];
    assert_eq!(merged.total_tokens, 400);
    assert_eq!(merged.cost_usd, Some(4.0));
    assert!(merged.variants.is_none(), "casing differences are not a real breakdown");
}

#[test]
fn model_breakdown_merges_variants_across_days() {
    let with_variants = |tokens, cost, variants| ModelUsageEntry { variants: Some(variants), ..model("opus", tokens, Some(cost)) };
    let lines = mapped_lines(
        vec![entry("2026-06-26", 300, Some(3.0)), entry("2026-06-25", 400, Some(4.0))],
        vec![
            model_day("2026-06-26", vec![with_variants(300, 3.0, vec![variant("opus-thinking-max", 300, Some(3.0))])]),
            model_day(
                "2026-06-25",
                vec![with_variants(
                    400,
                    4.0,
                    vec![variant("opus-thinking-max", 100, Some(1.0)), variant("opus-thinking-high", 300, Some(3.0))],
                )],
            ),
        ],
        BTreeMap::new(),
        None,
    );
    let last30 = model_breakdown(&lines, "Last 30 Days").expect("last 30");
    let opus = find(&last30, "opus").expect("opus");
    assert_eq!(opus.total_tokens, 700);
    assert_eq!(opus.cost_usd, Some(7.0));
    let variants = opus.variants.as_ref().expect("variants");
    assert_eq!(
        variants.iter().map(|v| v.model.as_str()).collect::<Vec<_>>(),
        vec!["opus-thinking-max", "opus-thinking-high"],
        "the same slug merges into one line across the period's days"
    );
    assert_eq!(variants.iter().map(|v| v.cost_usd).collect::<Vec<_>>(), vec![Some(4.0), Some(3.0)]);
    assert_eq!(variants.iter().map(|v| v.total_tokens).collect::<Vec<_>>(), vec![400, 300]);
}

#[test]
fn model_and_variant_cost_overflow_retains_marked_known_subtotal() {
    let overflowing = || ModelUsageEntry {
        variants: Some(vec![variant("opus-thinking", 1, Some(1e308))]),
        ..model("opus", 1, Some(1e308))
    };
    let lines = mapped_lines(
        vec![entry("2026-06-26", 1, Some(1e308)), entry("2026-06-25", 1, Some(1e308))],
        vec![model_day("2026-06-26", vec![overflowing()]), model_day("2026-06-25", vec![overflowing()])],
        BTreeMap::new(),
        None,
    );
    let last30 = model_breakdown(&lines, "Last 30 Days").expect("last 30");
    let opus = find(&last30, "opus").expect("opus");
    let thinking = opus.variants.iter().flatten().find(|v| v.model == "opus-thinking").expect("variant");
    assert_eq!(opus.cost_usd, Some(1e308));
    assert!(opus.has_incomplete_cost());
    assert_eq!(thinking.cost_usd, Some(1e308));
    assert!(thinking.has_incomplete_cost());
}

#[test]
fn cost_share_folding_normalizes_before_summing_huge_finite_models() {
    let models: Vec<ModelUsageEntry> = (0..21)
        .map(|index| {
            let name = if index == 0 { "dominant".to_string() } else { format!("minor-{index}") };
            model(&name, 1, Some(if index == 0 { 1e308 } else { 1e307 }))
        })
        .collect();
    let lines = mapped_lines(
        vec![DailyUsageEntry {
            cost_is_complete: false,
            has_unexplained_incomplete_cost: Some(false),
            ..entry("2026-06-26", 21, None)
        }],
        vec![model_day("2026-06-26", models)],
        BTreeMap::new(),
        None,
    );
    let breakdown = model_breakdown(&lines, "Today").expect("breakdown");
    assert_eq!(model_names(&breakdown), vec!["dominant", "Other"]);
    assert_eq!(breakdown.models.first().and_then(|m| m.cost_usd), Some(1e308));
}
