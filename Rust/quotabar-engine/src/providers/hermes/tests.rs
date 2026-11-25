use super::mapper::{
    breakdown, lines, usage_history, HermesModelUsage, HermesPeriod, HermesPeriodUsage,
    HermesTokenCounts, HermesUsageScan,
};
use super::scanner::{state_db_path_for, HermesUsageScanner};
use super::*;
use crate::accounting::DayZone;
use crate::context::{CancelToken, RefreshContext, Scope};
use crate::model::{DailyUsageEntry, DailyUsageSeries, ErrorCategory, MetricLine, ModelUsageEntry};
use rusqlite::Connection;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

fn create_hermes_db(path: &Path, sql: &str) {
    let conn = Connection::open(path).unwrap();
    conn.execute_batch(
        "CREATE TABLE sessions (
            id TEXT PRIMARY KEY,
            model TEXT,
            started_at REAL NOT NULL,
            ended_at REAL DEFAULT 0,
            input_tokens INTEGER DEFAULT 0,
            output_tokens INTEGER DEFAULT 0,
            cache_read_tokens INTEGER DEFAULT 0,
            cache_write_tokens INTEGER DEFAULT 0,
            reasoning_tokens INTEGER DEFAULT 0,
            api_call_count INTEGER DEFAULT 0,
            estimated_cost_usd REAL DEFAULT 0,
            billing_provider TEXT,
            billing_base_url TEXT
        );
        CREATE TABLE session_model_usage (
            session_id TEXT NOT NULL,
            model TEXT NOT NULL,
            input_tokens INTEGER DEFAULT 0,
            output_tokens INTEGER DEFAULT 0,
            cache_read_tokens INTEGER DEFAULT 0,
            cache_write_tokens INTEGER DEFAULT 0,
            reasoning_tokens INTEGER DEFAULT 0,
            estimated_cost_usd REAL DEFAULT 0
        );",
    )
    .unwrap();
    if !sql.is_empty() {
        conn.execute_batch(sql).unwrap();
    }
}

#[test]
fn hermes_paths_respects_hermes_home_override_and_tilde() {
    let home = PathBuf::from("/Users/test");
    assert_eq!(
        state_db_path_for(&home, &|_| None),
        home.join(".hermes/state.db")
    );
    assert_eq!(
        state_db_path_for(&home, &|k| (k == "HERMES_HOME")
            .then(|| "/custom/hermes".into())),
        PathBuf::from("/custom/hermes/state.db")
    );
    assert_eq!(
        state_db_path_for(&home, &|k| (k == "HERMES_HOME")
            .then(|| "~/hermes-data".into())),
        home.join("hermes-data/state.db")
    );
    assert_eq!(
        state_db_path_for(&home, &|k| (k == "HERMES_HOME").then(|| "   ".into())),
        home.join(".hermes/state.db")
    );
}

#[test]
fn real_db_periods_daily_opencode_exclusion_and_missing_table_fallback() {
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("state.db");
    let now = 1_784_800_000.0;
    create_hermes_db(
        &db,
        &format!(
            "INSERT INTO sessions (id, model, started_at, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens, api_call_count, estimated_cost_usd, billing_provider, billing_base_url) VALUES
               ('recent', 'kimi/kimi-k2.7', {recent}, 1000, 200, 8000, 0, 50, 12, 0.42, 'anthropic', 'https://api.anthropic.com'),
               ('ancient', 'glm/glm-5', {ancient}, 9000, 900, 0, 0, 0, 99, 9.99, NULL, NULL),
               ('gateway', 'deepseek-v4-flash', {recent}, 500, 60, 0, 0, 0, 1, 0.75, 'opencode-go', 'https://opencode.ai/zen/go/v1');
             INSERT INTO session_model_usage (session_id, model, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens, estimated_cost_usd) VALUES
               ('recent', 'kimi/kimi-k2.7', 1000, 200, 8000, 0, 50, 0.42),
               ('recent', 'deepseek/deepseek-v4-flash', 300, 100, 0, 0, 10, 0.05),
               ('gateway', 'deepseek-v4-flash', 500, 60, 0, 0, 0, 0.75);",
            recent = now - 60.0,
            ancient = now - 45.0 * 86_400.0,
        ),
    );
    let scanner = HermesUsageScanner::at(db.clone(), DayZone::Local);
    let scan = scanner.scan(now, &CancelToken::new()).unwrap().unwrap();
    let today = scan
        .periods
        .iter()
        .find(|p| p.period == HermesPeriod::Today)
        .unwrap();
    assert_eq!(today.counts.total(), 9250);
    assert!((today.cost_usd.unwrap() - 0.42).abs() < 1e-4);
    assert_eq!(today.api_call_count, 12);
    let models = &scan.model_usage_by_period[&HermesPeriod::Today];
    assert_eq!(
        models.iter().map(|m| m.model.as_str()).collect::<Vec<_>>(),
        ["kimi/kimi-k2.7", "deepseek/deepseek-v4-flash"]
    );
    let mut daily_toks: Vec<i64> = scan.daily.daily.iter().map(|d| d.total_tokens).collect();
    daily_toks.sort();
    assert_eq!(daily_toks, [9250, 9900]);

    // Fallback when session_model_usage table absent + future timestamp check
    let db2 = dir.path().join("no_model_table.db");
    let conn = Connection::open(&db2).unwrap();
    conn.execute_batch(&format!(
        "CREATE TABLE sessions (id TEXT PRIMARY KEY, model TEXT, started_at REAL NOT NULL, ended_at REAL DEFAULT 0, input_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0, cache_read_tokens INTEGER DEFAULT 0, cache_write_tokens INTEGER DEFAULT 0, reasoning_tokens INTEGER DEFAULT 0, api_call_count INTEGER DEFAULT 0, estimated_cost_usd REAL DEFAULT 0, billing_provider TEXT, billing_base_url TEXT);
         INSERT INTO sessions (id, model, started_at, input_tokens, output_tokens) VALUES ('r', 'kimi/kimi-k2.7', {ts}, 1000, 200);",
        ts = now - 60.0,
    )).unwrap();
    drop(conn);
    let s2 = HermesUsageScanner::at(db2.clone(), DayZone::Local)
        .scan(now, &CancelToken::new())
        .unwrap()
        .unwrap();
    assert_eq!(
        s2.model_usage_by_period[&HermesPeriod::Today][0].tokens,
        1200
    );

    // Future dated session fails scan cleanly
    let conn = Connection::open(&db2).unwrap();
    conn.execute_batch(&format!(
        "INSERT INTO sessions (id, model, started_at, input_tokens) VALUES ('fut', 'm', {fut}, 100);",
        fut = now + 400.0
    )).unwrap();
    drop(conn);
    assert!(HermesUsageScanner::at(db2, DayZone::Local)
        .scan(now, &CancelToken::new())
        .is_err());
}

#[test]
fn default_zero_cost_active_session_and_mapper_breakdown_fold_rules() {
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("partial.db");
    let now = 1_784_800_000.0;
    create_hermes_db(
        &db,
        &format!(
            "INSERT INTO sessions (id, model, started_at, ended_at, input_tokens, output_tokens, estimated_cost_usd) VALUES
               ('active', 'kimi-k2.7', {s}, NULL, 100, 40, 0.5),
               ('missing', 'm-nocost', {s2}, 1, 300, 30, 0);",
            s = now - 60.0,
            s2 = now - 59.0,
        ),
    );
    let provider = HermesProvider::with_scanner(HermesUsageScanner::at(db, DayZone::Local));
    assert!(provider.has_local_credentials());
    let mut ctx = RefreshContext::new(Scope::Full);
    ctx.now = now;
    let snap = provider.refresh(&ctx);
    assert_eq!(snap.error_category, None);
    let today_line = snap.lines.iter().find(|l| l.label() == "Today").unwrap();
    if let MetricLine::Values { values, .. } = today_line {
        // Default 0 cost makes cost None, active session sets is_partial = Some(true).
        assert_eq!(values.len(), 1);
        assert_eq!(values[0].is_partial, Some(true));
    }

    // Mapper top-3 + material unpriced model rule
    let models = vec![
        HermesModelUsage {
            model: "leader".into(),
            tokens: 100_000_000,
            cost_usd: Some(10.0),
            is_partial: false,
        },
        HermesModelUsage {
            model: "b".into(),
            tokens: 50_000_000,
            cost_usd: Some(5.0),
            is_partial: false,
        },
        HermesModelUsage {
            model: "c".into(),
            tokens: 30_000_000,
            cost_usd: Some(3.0),
            is_partial: false,
        },
        HermesModelUsage {
            model: "d".into(),
            tokens: 20_000_000,
            cost_usd: Some(2.0),
            is_partial: false,
        },
        HermesModelUsage {
            model: "swe-2-max".into(),
            tokens: 15_000_000,
            cost_usd: None,
            is_partial: false,
        },
        HermesModelUsage {
            model: "e".into(),
            tokens: 10_000_000,
            cost_usd: Some(1.0),
            is_partial: false,
        },
        HermesModelUsage {
            model: "compactor".into(),
            tokens: 1_500_000,
            cost_usd: None,
            is_partial: false,
        },
    ];
    let bd = breakdown(&models, 216_500_000, Some(21.0)).unwrap();
    assert_eq!(
        bd.models
            .iter()
            .map(|m| m.model.as_str())
            .collect::<Vec<_>>(),
        ["leader", "b", "c", "swe-2-max", ModelUsageEntry::OTHER]
    );
    assert!(bd.models.last().unwrap().has_incomplete_cost());

    let missing_snap = HermesProvider::with_scanner(HermesUsageScanner::at(
        dir.path().join("absent.db"),
        DayZone::Local,
    ))
    .refresh(&ctx);
    assert_eq!(
        missing_snap.error_category,
        Some(ErrorCategory::NotLoggedIn)
    );
    let _ = (
        lines,
        usage_history,
        HermesTokenCounts::default(),
        HermesPeriodUsage {
            period: HermesPeriod::Today,
            counts: HermesTokenCounts::default(),
            cost_usd: None,
            api_call_count: 0,
            is_partial: false,
        },
        DailyUsageSeries {
            daily: vec![DailyUsageEntry::new("2026-07-01", 10, None)],
        },
        BTreeMap::<HermesPeriod, Vec<HermesModelUsage>>::new(),
        BTreeSet::<String>::new(),
        HermesUsageScan {
            periods: vec![],
            daily: DailyUsageSeries { daily: vec![] },
            model_usage_by_period: BTreeMap::new(),
            partial_days: BTreeSet::new(),
        },
    );
}
