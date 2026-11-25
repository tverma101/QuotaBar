//! Ports of the Swift `FreebuffModelIdentityTests`, plus the saved-catalogue regression.

use super::*;
use crate::context::CancelToken;
use crate::model::ModelUsageEntry;
use crate::pricing::{AliasRule, ModelRates, PricingCatalog, PricingSupplement};
use crate::providers::freebuff::catalog::ModelCatalog;
use crate::providers::freebuff::scanner::{FreebuffScan, FreebuffScanner, Receipt};

const NORMAL: &str = "deepseek/deepseek-v4.1-flash-1017";
const LEGACY: &str = "deepseek/deepseek-v4-flash";
const PLAIN: &str = "deepseek/deepseek-v4.1-flash";
const FAST: &str = "deepseek-v4.1-flash-fast";
/// Sat 2026-10-31 12:00 UTC: the off-peak Flash lane.
const NOW: f64 = 1_793_448_000.0;
/// Off-peak Flash: (20 * 0.15 + 80 * 0.003 + 50 * 0.60) / 1M per receipt.
const RECEIPT_COST: f64 = 0.000_033_24;

fn entry(key: &str, name: &str, digests: Option<&[&str]>) -> CatalogEntry {
    CatalogEntry {
        key: key.into(),
        display_name: name.into(),
        legacy_digests: digests.map(|digests| digests.iter().map(|d| d.to_string()).collect()),
    }
}

fn catalog() -> CatalogEntries {
    [
        entry(
            "m-normal",
            "DeepSeek V4.1 Flash 10/17",
            Some(&["1e303ac563a6f9cc"]),
        ),
        entry("m-fast", "DeepSeek V4.1 Flash Fast 10/17", None),
        entry("m-slow", "DeepSeek V4.1 Flash Slow", None),
    ]
    .into_iter()
    .map(|entry| (entry.key.clone(), entry))
    .collect()
}

fn pricing() -> ModelPricing {
    let normal = ModelRates::new(1.0, 2.0, 1.0, 0.1);
    let mut supplement = PricingSupplement::default();
    supplement
        .pricing
        .insert(FAST.into(), ModelRates::new(4.0, 8.0, 4.0, 0.4));
    supplement
        .alias_rules
        .push(AliasRule::new(r"^DeepSeek V4\.1 Flash Fast 10/17$", FAST).unwrap());
    let open_router = [NORMAL, LEGACY, PLAIN]
        .into_iter()
        .map(|route| (route.to_string(), normal.clone()))
        .collect();
    ModelPricing::new(
        supplement,
        PricingCatalog::default(),
        PricingCatalog::default(),
        PricingCatalog::from_entries(open_router),
        None,
    )
}

fn receipt(id: &str, model: &str) -> Receipt {
    Receipt {
        id: id.into(),
        timestamp_ms: (NOW - 60.0) * 1_000.0,
        metrics_json:
            r#"{"usage":{"inputTokens":100,"outputTokens":50,"cachedInputTokens":80,"totalTokens":150}}"#
                .into(),
        model: Some(model.into()),
    }
}

fn scan(entries: &CatalogEntries, pricing: &ModelPricing, receipts: &[Receipt]) -> FreebuffScan {
    let home = tempfile::tempdir().unwrap();
    FreebuffScanner::with_home(home.path().to_path_buf())
        .scan(NOW, pricing, entries, receipts, &CancelToken::new())
        .expect("scan")
}

fn models(scan: &FreebuffScan) -> Vec<ModelUsageEntry> {
    scan.usage.model_usage.clone().unwrap().daily[0]
        .models
        .clone()
}

fn approx(actual: Option<f64>, expected: f64) {
    let actual = actual.expect("priced");
    assert!((actual - expected).abs() < 1e-12, "{actual} != {expected}");
}

#[test]
fn legacy_digest_matches_the_published_catalogue() {
    assert_eq!(legacy_digest(LEGACY), "1e303ac563a6f9cc");
    assert_ne!(legacy_digest(&LEGACY.to_uppercase()), "1e303ac563a6f9cc");
}

#[test]
fn catalogue_grouping_keeps_the_assumed_standard_rate_separate() {
    let receipts = [
        receipt("key", "m-normal"),
        receipt("legacy", LEGACY),
        receipt("dated", NORMAL),
        receipt("fast", "m-fast"),
        receipt("slow", "m-slow"),
    ];
    let scan = scan(&catalog(), &pricing(), &receipts);
    let day = &scan.usage.series.daily[0];
    let models = models(&scan);
    assert_eq!(models.len(), 2);
    let flash = models
        .iter()
        .find(|model| model.model == "DeepSeek V4.1 Flash")
        .unwrap();
    let assumed = models
        .iter()
        .find(|model| model.model == ASSUMED_STANDARD)
        .unwrap();
    assert_eq!(flash.total_tokens, 600);
    assert_eq!(day.total_tokens, 750);
    approx(flash.cost_usd, 4.0 * RECEIPT_COST);
    approx(day.cost_usd, 5.0 * RECEIPT_COST);
    assert_eq!(assumed.total_tokens, 150);
    approx(assumed.cost_usd, RECEIPT_COST);
    assert_ne!(
        flash.cost_is_complete,
        Some(false),
        "Slow prices at the Flash comparison"
    );
    assert!(
        scan.usage.unknown_models_by_day.is_empty(),
        "known but unpriced is not unknown"
    );
    let variants = flash.variants.clone().unwrap();
    assert_eq!(variants.len(), 2);
    let normal = variants
        .iter()
        .find(|variant| variant.model == "DeepSeek V4.1 Flash 10/17")
        .unwrap();
    assert_eq!(normal.total_tokens, 450);
    approx(normal.cost_usd, 3.0 * RECEIPT_COST);
}

#[test]
fn only_receipt_provenance_can_label_an_exact_fast_route() {
    let entries = catalog();
    let pricing = pricing();
    let mut resolver = ModelIdentity::new(&entries, &pricing);
    for evidence in [false, true] {
        let opaque = resolver.resolve("m-fast", evidence);
        assert_eq!(opaque.route.as_deref(), Some(PLAIN));
        assert_eq!(opaque.display_name.as_deref(), Some(ASSUMED_STANDARD));
    }
    let selected = resolver.resolve(FAST, false);
    assert_eq!(selected.route.as_deref(), Some(PLAIN));
    assert_eq!(selected.display_name.as_deref(), Some(ASSUMED_STANDARD));
    let recorded = resolver.resolve(&format!("deepseek/{FAST}"), true);
    assert_eq!(recorded.route.as_deref(), Some(FAST));
    assert_eq!(
        recorded.display_name.as_deref(),
        Some("DeepSeek V4.1 Flash Fast (Recorded Route)")
    );
    assert_eq!(resolver.resolve(FAST, true).route.as_deref(), Some(FAST));
    assert_eq!(resolver.resolve(PLAIN, true).route.as_deref(), Some(PLAIN));

    let mut conflict = catalog();
    conflict.get_mut("m-normal").unwrap().legacy_digests = None;
    conflict.get_mut("m-fast").unwrap().legacy_digests = Some(vec![legacy_digest(LEGACY)]);
    let mut conflicting = ModelIdentity::new(&conflict, &pricing);
    let saved = conflicting.resolve(LEGACY, false);
    assert_eq!(saved.route.as_deref(), Some(PLAIN));
    assert_eq!(saved.display_name.as_deref(), Some(ASSUMED_STANDARD));
    assert_eq!(
        conflicting.resolve(LEGACY, true).route.as_deref(),
        Some(LEGACY)
    );

    let empty = ModelPricing::default();
    let missing = ModelIdentity::new(&entries, &empty).resolve("m-fast", false);
    assert_eq!(missing.route.as_deref(), Some(flash::ROUTE));
    assert_eq!(missing.display_name.as_deref(), Some(ASSUMED_STANDARD));
}

#[test]
fn different_versions_and_unidentified_slugs_stay_separate() {
    let mut entries = catalog();
    for added in [
        entry("m-new", "DeepSeek V4.2 Flash Fast 11/01", None),
        entry("m-pro", "DeepSeek V4.1 Pro", None),
        entry("m-sol", "GPT-6.1 Sol", None),
        entry("m-terra", "GPT-6.1 Terra", None),
    ] {
        entries.insert(added.key.clone(), added);
    }
    let names = [
        "m-normal",
        "m-new",
        "m-pro",
        "m-sol",
        "m-terra",
        "unknown/flash-fast",
        "fbm1.private",
    ];
    let receipts: Vec<Receipt> = names
        .iter()
        .enumerate()
        .map(|(index, name)| receipt(&format!("cloud:{index}"), name))
        .collect();
    let scan = scan(&entries, &pricing(), &receipts);
    let mut found: Vec<String> = models(&scan).into_iter().map(|model| model.model).collect();
    found.sort();
    assert_eq!(
        found,
        [
            "DeepSeek V4.1 Flash",
            "DeepSeek V4.1 Pro",
            "DeepSeek V4.2 Flash (Route Unverified)",
            "GPT-6.1 Sol",
            "GPT-6.1 Terra",
            "Unattributed",
            "unknown/flash (Route Unverified)",
        ]
    );
    assert_eq!(scan.usage.series.daily[0].total_tokens, 1_050);
    let unknown: Vec<&String> = scan
        .usage
        .unknown_models_by_day
        .values()
        .next()
        .unwrap()
        .iter()
        .collect();
    assert_eq!(
        unknown,
        ["Unattributed", "unknown/flash (Route Unverified)"]
    );
}

#[test]
fn same_named_entries_do_not_make_route_display_ambiguous() {
    let mut entries = catalog();
    entries.insert(
        "m-copy".into(),
        entry("m-copy", "DeepSeek V4.1 Flash 10/17", None),
    );
    let pricing = pricing();
    let mut resolver = ModelIdentity::new(&entries, &pricing);
    let resolved = resolver.resolve(NORMAL, false);
    assert_eq!(
        resolved.display_name.as_deref(),
        Some("DeepSeek V4.1 Flash 10/17")
    );
    assert_eq!(resolved.group.as_deref(), Some("DeepSeek V4.1 Flash"));
}

#[test]
fn ambiguous_legacy_digest_does_not_assign_an_arbitrary_model() {
    let mut entries = catalog();
    entries.insert(
        "m-collision".into(),
        entry(
            "m-collision",
            "Different Model",
            Some(&["1e303ac563a6f9cc"]),
        ),
    );
    let empty = ModelPricing::default();
    let resolved = ModelIdentity::new(&entries, &empty).resolve(LEGACY, false);
    assert_eq!(resolved.display_name, None);
    assert_eq!(resolved.route.as_deref(), Some(LEGACY));
}

#[test]
fn suffix_helpers_keep_versions_and_strip_annotations() {
    assert_eq!(
        fast_base_name("DeepSeek V4.1 Flash Fast 10/17").as_deref(),
        Some("DeepSeek V4.1 Flash")
    );
    assert_eq!(
        fast_base_name("unknown/flash-fast").as_deref(),
        Some("unknown/flash")
    );
    assert_eq!(fast_base_name("FastAPI Model"), None);
    assert_eq!(fast_base_name("DeepSeek V4.1 Flash"), None);
    assert_eq!(
        group_name("Claude Haiku 5.5 · 100k context"),
        "Claude Haiku 5.5"
    );
    assert_eq!(
        group_name("DeepSeek V4.1 Flash Slow"),
        "DeepSeek V4.1 Flash"
    );
    assert_eq!(
        normalized("Claude Haiku 5.5 · 100k context"),
        "claudehaiku55"
    );
    assert_eq!(normalized("DeepSeek V4.1 Flash"), "deepseek41flash");
    assert_eq!(normalized("deepseek-v4.1-flash"), "deepseek41flash");
}

/// Regression: the Rust port never read the saved catalogue, so Freebuff Desktop turns recorded
/// as `m-096e75164d` (DeepSeek V4.1 Flash Fast) carried tokens but no dollars.
#[test]
fn saved_catalogue_prices_opaque_flash_fast_turns() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("freebuff-model-identities.json");
    std::fs::write(
        &path,
        r#"{"entries":[{"legacyDigests":["1e303ac563a6f9cc"],"key":"m-096e75164d","displayName":"DeepSeek V4.1 Flash Fast"}],"fetchedAt":817185739.535036}"#,
    )
    .unwrap();
    let catalog = ModelCatalog::at(path.clone());
    let entries = catalog.current();
    assert_eq!(entries.len(), 1);
    let mut recorded = receipt("cloud:recorded", "m-096e75164d");
    recorded.metrics_json = r#"{"usage":{"model":"m-096e75164d","inputTokens":100,"outputTokens":50,"cachedInputTokens":80,"totalTokens":150}}"#.into();
    let receipts = [receipt("selected", "m-096e75164d"), recorded];
    let scan = scan(&entries, &ModelPricing::default(), &receipts);
    let models = models(&scan);
    assert_eq!(models.len(), 1);
    assert_eq!(models[0].model, ASSUMED_STANDARD);
    approx(models[0].cost_usd, 2.0 * RECEIPT_COST);
    assert!(scan.usage.unknown_models_by_day.is_empty());
    assert!(scan.usage.series.daily[0].cost_usd.is_some());

    // A rewrite is re-read; an unreadable file yields no identities rather than stale ones.
    std::fs::write(&path, b"not json at all, and longer than before").unwrap();
    assert!(catalog.current().is_empty());
}
