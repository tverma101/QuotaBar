//! Tests for Z.ai auth, mapper, provider, and ZCode local scanner.

use super::auth::spec_with_paths;
use super::mapper::{is_no_coding_plan, map, map_quota, plan_name, MapperError};
use super::zcode::ZCodeUsageScanner;
use super::{ZAIProvider, QUOTA_URL, SUBSCRIPTION_URL};
use crate::context::{RefreshContext, Scope};
use crate::host::{self, Host, LogLevel, SecureReadOutcome, SecureReadRequest};
use crate::http::mock::{FnClient, MockClient};
use crate::http::{HttpError, Response};
use crate::model::{
    ErrorCategory, MetricKind, MetricLine, MetricValue, ProgressFormat, ProviderSnapshot,
};
use crate::providers::api_key::{ApiKeyStatus, ReadKeyError};
use crate::providers::ProviderRuntime;
use crate::sqlite::execute as sqlite_execute;
use crate::time::DISTANT_PAST;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tempfile::TempDir;

const QUOTA_BOTH: &str = r#"{"data":{"limits":[
  {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":15,"nextResetTime":1770648402389},
  {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":40,"nextResetTime":1771300000000},
  {"type":"TIME_LIMIT","unit":5,"number":1,"usage":4000,"currentValue":1828}
]},"success":true}"#;
const LIVE_CREDIT_QUOTA: &str = r#"{"code":200,"msg":"Operation successful","data":{"limits":[
  {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":2000,"currentValue":0,"remaining":2000,"percentage":0},
  {"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":10000,"currentValue":9855,"remaining":145,"percentage":98,"nextResetTime":1786685679998}
]},"level":"lite","success":true}"#;
const SUBSCRIPTION: &str = r#"{"data":[{"productName":"GLM Coding Max"}]}"#;
const NOW: f64 = 1_770_000_000.0;

struct EnvHost(HashMap<String, String>);

impl Host for EnvHost {
    fn log(&self, _: LogLevel, _: &str, _: &str) {}
    fn log_level(&self) -> LogLevel {
        LogLevel::Error
    }
    fn secure_read(&self, _: &SecureReadRequest) -> SecureReadOutcome {
        SecureReadOutcome::NotFound
    }
    fn env_var(&self, name: &str) -> Option<String> {
        self.0.get(name).filter(|v| !v.is_empty()).cloned()
    }
}

fn with_env<R>(vars: &[(&str, &str)], f: impl FnOnce() -> R) -> R {
    let map: HashMap<String, String> = vars
        .iter()
        .map(|(k, v)| ((*k).into(), (*v).into()))
        .collect();
    host::with_test_host(Arc::new(EnvHost(map)), f)
}

fn ok_json(body: &str) -> Response {
    Response {
        status: 200,
        headers: Vec::new(),
        body: body.as_bytes().to_vec(),
    }
}

fn temp_config_paths(dir: &TempDir) -> Vec<std::path::PathBuf> {
    vec![
        dir.path().join("quotabar/zai.json"),
        dir.path().join("openusage/zai.json"),
        dir.path().join("zai/key.json"),
    ]
}

fn empty_scanner(dir: &TempDir) -> ZCodeUsageScanner {
    ZCodeUsageScanner::new(
        dir.path().join("missing/db.sqlite"),
        dir.path().join("missing/leveldb"),
    )
    .with_cache_dir(dir.path().join("cache"))
}

fn ctx(now: f64) -> RefreshContext {
    let mut c = RefreshContext::new(Scope::Full);
    c.now = now;
    c
}

fn error_badge(snap: &ProviderSnapshot) -> Option<String> {
    match snap.lines.first() {
        Some(MetricLine::Badge { text, .. }) => Some(text.clone()),
        _ => None,
    }
}

#[test]
fn env_precedence_config_formats_and_validation() {
    let dir = TempDir::new().unwrap();
    let spec = spec_with_paths(temp_config_paths(&dir));
    with_env(&[], || {
        assert!(spec.load_key().is_none());
    });
    with_env(&[("ZAI_API_KEY", "zai-env")], || {
        assert_eq!(spec.load_key().as_deref(), Some("zai-env"));
    });
    with_env(&[("GLM_API_KEY", "glm-env")], || {
        assert_eq!(spec.load_key().as_deref(), Some("glm-env"));
    });
    with_env(&[("ZAI_API_KEY", "zai"), ("GLM_API_KEY", "glm")], || {
        assert_eq!(spec.load_key().as_deref(), Some("zai"));
    });

    with_env(&[("ZAI_API_KEY", "env")], || {
        spec.save_key("  zai-new  ").unwrap();
        assert_eq!(spec.load_key().as_deref(), Some("zai-new"));
        assert_eq!(spec.key_status(), ApiKeyStatus::OverrideActive);
        spec.delete_key().unwrap();
        assert_eq!(spec.key_status(), ApiKeyStatus::FromEnvironment);
    });

    std::fs::create_dir_all(spec.config_paths[1].parent().unwrap()).unwrap();
    std::fs::write(&spec.config_paths[1], "  zai-plain\n").unwrap();
    with_env(&[], || {
        assert_eq!(spec.load_key().as_deref(), Some("zai-plain"));
    });
    spec.delete_key().unwrap();
    with_env(&[], || {
        assert!(spec.load_key().is_none());
    });
    assert!(spec.save_key("   ").is_err());

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::create_dir_all(spec.config_paths[0].parent().unwrap()).unwrap();
        std::fs::write(&spec.config_paths[0], r#"{"apiKey":"secret"}"#).unwrap();
        std::fs::set_permissions(
            &spec.config_paths[0],
            std::fs::Permissions::from_mode(0o000),
        )
        .unwrap();
        if std::fs::read(&spec.config_paths[0]).is_err() {
            with_env(&[], || {
                assert_eq!(spec.key_status(), ApiKeyStatus::SavedUnreadable);
                assert!(matches!(
                    spec.load_key_for_refresh(),
                    Err(ReadKeyError::ConfigUnreadable)
                ));
                assert!(spec.has_key_or_unreadable_config());
            });
            with_env(&[("ZAI_API_KEY", "env")], || {
                assert_eq!(spec.key_status(), ApiKeyStatus::EnvironmentFallback);
                assert_eq!(spec.load_key_for_refresh().unwrap().as_deref(), Some("env"));
            });
        }
        std::fs::set_permissions(
            &spec.config_paths[0],
            std::fs::Permissions::from_mode(0o600),
        )
        .unwrap();
    }
}

#[test]
fn mapper_limits_credit_limit_validation_and_resets() {
    let mapped = map(QUOTA_BOTH.as_bytes(), Some(SUBSCRIPTION.as_bytes()), NOW).unwrap();
    assert_eq!(mapped.plan.as_deref(), Some("GLM Coding Max"));
    let find = |label: &str| mapped.lines.iter().find(|l| l.label() == label).unwrap();
    assert!(
        matches!(find("Session"), MetricLine::Progress { used, period_duration_ms: Some(18_000_000), resets_at: Some(_), .. } if (*used - 15.0).abs() < 1e-3)
    );
    assert!(
        matches!(find("Weekly"), MetricLine::Progress { used, period_duration_ms: Some(604_800_000), .. } if (*used - 40.0).abs() < 1e-3)
    );
    assert!(
        matches!(find("Web Searches"), MetricLine::Progress { used, limit, format: ProgressFormat::Count(s), period_duration_ms: Some(2_592_000_000), .. } if s == "searches" && *used == 1828.0 && *limit == 4000.0)
    );

    let credit = map_quota(LIVE_CREDIT_QUOTA.as_bytes(), NOW).unwrap();
    assert!(
        matches!(&credit[0], MetricLine::Progress { label, used, .. } if label == "Session" && *used == 0.0)
    );
    assert!(
        matches!(&credit[1], MetricLine::Progress { label, used, .. } if label == "Weekly" && *used == 98.0)
    );

    let divergent = r#"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":3,"percentage":10},{"type":"TOKENS_LIMIT","unit":4,"number":3,"percentage":20}]}}"#;
    let div_lines = map_quota(divergent.as_bytes(), NOW).unwrap();
    assert!(matches!(
        &div_lines[0],
        MetricLine::Progress {
            period_duration_ms: Some(10_800_000),
            ..
        }
    ));
    assert!(matches!(
        &div_lines[1],
        MetricLine::Progress {
            period_duration_ms: Some(259_200_000),
            ..
        }
    ));

    for malformed in [
        r#"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5}]}}"#,
        r#"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":true}]}}"#,
        r#"{"data":{"limits":[{"type":"TIME_LIMIT","usage":1000}]}}"#,
        r#"{"data":{"limits":[{"type":"TIME_LIMIT","currentValue":10}]}}"#,
        r#"{"data":{"limits":[{"type":"TIME_LIMIT","currentValue":-1,"usage":1000}]}}"#,
        "not-json",
        r#"{"data":[]}"#,
        r#"{"data":{}}"#,
        r#"{"data":{"limits":{}}}"#,
    ] {
        assert_eq!(
            map_quota(malformed.as_bytes(), NOW),
            Err(MapperError::InvalidResponse),
            "{malformed}"
        );
    }
    assert_eq!(
        map_quota(br#"{"data":{"limits":[]}}"#, NOW).unwrap()[0].label(),
        "Status"
    );
    assert_eq!(map_quota(br#"{"data":{"limits":[{"type":"FUTURE_LIMIT"},{"type":"TOKENS_LIMIT","unit":99,"number":1,"percentage":70}]}}"#, NOW).unwrap()[0].label(), "Status");

    let partial = map_quota(br#"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5},{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25}]}}"#, NOW).unwrap();
    assert_eq!(partial.len(), 1);
    assert_eq!(partial[0].label(), "Session");

    assert!(is_no_coding_plan(
        r#"{"code":500,"msg":"当前用户不存在coding plan","success":false}"#.as_bytes()
    ));
    assert!(!is_no_coding_plan(QUOTA_BOTH.as_bytes()));
    assert!(plan_name(br#"{"data":[]}"#).is_none());

    let clamped = map_quota(
        br#"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":150}]}}"#,
        NOW,
    )
    .unwrap();
    assert!(
        matches!(clamped.first(), Some(MetricLine::Progress { used, .. }) if (*used - 100.0).abs() < 1e-6)
    );

    let zero_reset = map_quota(br#"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":15,"nextResetTime":0}]}}"#, NOW).unwrap();
    assert!(matches!(
        zero_reset.first(),
        Some(MetricLine::Progress {
            resets_at: None,
            ..
        })
    ));

    let zero_web = map_quota(br#"{"data":{"limits":[{"type":"TIME_LIMIT","unit":5,"number":1,"usage":0,"currentValue":0}]}}"#, NOW).unwrap();
    assert_eq!(zero_web[0].label(), "Status");
}

#[test]
fn provider_refresh_plan_cache_failures_and_scopes() {
    with_env(&[], || {
        let dir = TempDir::new().unwrap();
        let spec = spec_with_paths(temp_config_paths(&dir));
        spec.save_key("key-1").unwrap();

        let clock = Arc::new(Mutex::new(1_800_000_000.0));
        let sub_calls = Arc::new(AtomicUsize::new(0));
        let sub_fail = Arc::new(AtomicBool::new(false));
        let sub_calls_c = Arc::clone(&sub_calls);
        let sub_fail_c = Arc::clone(&sub_fail);

        let http = Arc::new(FnClient::new(move |req| {
            if req.url == QUOTA_URL {
                return Ok(ok_json(QUOTA_BOTH));
            }
            assert_eq!(req.url, SUBSCRIPTION_URL);
            sub_calls_c.fetch_add(1, Ordering::SeqCst);
            if sub_fail_c.load(Ordering::SeqCst) {
                return Ok(Response {
                    status: 500,
                    headers: Vec::new(),
                    body: Vec::new(),
                });
            }
            let auth_hdr = req
                .headers
                .iter()
                .find(|(k, _)| k == "Authorization")
                .map(|(_, v)| v.as_str())
                .unwrap_or("");
            if auth_hdr.contains("key-2") {
                Ok(ok_json(r#"{"data":[{"productName":"GLM Pro"}]}"#))
            } else {
                Ok(ok_json(SUBSCRIPTION))
            }
        }));

        let provider = ZAIProvider::new(spec.clone(), http, empty_scanner(&dir));
        assert!(provider.has_local_credentials());
        let first = provider.refresh(&ctx(*clock.lock().unwrap()));
        assert_eq!(first.plan.as_deref(), Some("GLM Coding Max"));
        assert_eq!(sub_calls.load(Ordering::SeqCst), 1);

        let second = provider.refresh(&ctx(*clock.lock().unwrap()));
        assert_eq!(second.plan.as_deref(), Some("GLM Coding Max"));
        assert_eq!(sub_calls.load(Ordering::SeqCst), 1);

        sub_fail.store(true, Ordering::SeqCst);
        *clock.lock().unwrap() += 3660.0;
        let third = provider.refresh(&ctx(*clock.lock().unwrap()));
        assert_eq!(third.plan.as_deref(), Some("GLM Coding Max"));
        assert_eq!(sub_calls.load(Ordering::SeqCst), 2);

        sub_fail.store(false, Ordering::SeqCst);
        spec.save_key("key-2").unwrap();
        let rotated = provider.refresh(&ctx(*clock.lock().unwrap()));
        assert_eq!(rotated.plan.as_deref(), Some("GLM Pro"));
        assert_eq!(sub_calls.load(Ordering::SeqCst), 3);

        let cancel_urls = Arc::new(Mutex::new(Vec::new()));
        let cancel_c = Arc::clone(&cancel_urls);
        let cancel_http = Arc::new(FnClient::new(move |req| {
            cancel_c.lock().unwrap().push(req.url.clone());
            Err(HttpError::Cancelled)
        }));
        let cancel_snap =
            ZAIProvider::new(spec.clone(), cancel_http, empty_scanner(&dir)).refresh(&ctx(NOW));
        assert_eq!(cancel_snap.error_category, Some(ErrorCategory::Cancelled));
        assert_eq!(*cancel_urls.lock().unwrap(), vec![QUOTA_URL.to_string()]);

        let http_401 = MockClient::new(vec![
            Ok(Response {
                status: 401,
                headers: Vec::new(),
                body: b"{}".to_vec(),
            }),
            Ok(ok_json(SUBSCRIPTION)),
        ]);
        let snap_401 =
            ZAIProvider::new(spec.clone(), http_401, empty_scanner(&dir)).refresh(&ctx(NOW));
        assert_eq!(snap_401.error_category, Some(ErrorCategory::AuthInvalid));
        assert_eq!(
            error_badge(&snap_401).as_deref(),
            Some("Z.ai API key invalid. Check your key at z.ai/manage-apikey/apikey-list.")
        );

        let http_500 = MockClient::new(vec![
            Ok(Response {
                status: 500,
                headers: Vec::new(),
                body: b"{}".to_vec(),
            }),
            Ok(ok_json(SUBSCRIPTION)),
        ]);
        let snap_500 =
            ZAIProvider::new(spec.clone(), http_500, empty_scanner(&dir)).refresh(&ctx(NOW));
        assert_eq!(snap_500.error_category, Some(ErrorCategory::Http5xx));
        assert_eq!(
            error_badge(&snap_500).as_deref(),
            Some("Usage request failed (HTTP 500). Try again later.")
        );

        let http_net = MockClient::new(vec![
            Err(HttpError::Transport("down".into())),
            Ok(ok_json(SUBSCRIPTION)),
        ]);
        let net_snap = ZAIProvider::new(spec.clone(), http_net.clone(), empty_scanner(&dir))
            .refresh(&ctx(NOW));
        assert_eq!(net_snap.error_category, Some(ErrorCategory::Network));
        assert_eq!(
            error_badge(&net_snap).as_deref(),
            Some("Usage request failed. Check your connection.")
        );
        {
            let requests = http_net.requests.lock().unwrap();
            let urls: Vec<&str> = requests.iter().map(|r| r.url.as_str()).collect();
            assert_eq!(urls, vec![QUOTA_URL, SUBSCRIPTION_URL]);
            assert!(requests
                .iter()
                .all(|r| r.timeout == Duration::from_secs(15)));
        }

        let http_ncp = MockClient::new(vec![
            Ok(ok_json(
                r#"{"code":500,"msg":"当前用户不存在coding plan","success":false}"#,
            )),
            Ok(ok_json(SUBSCRIPTION)),
        ]);
        let ncp_snap =
            ZAIProvider::new(spec.clone(), http_ncp, empty_scanner(&dir)).refresh(&ctx(NOW));
        assert_eq!(ncp_snap.error_category, Some(ErrorCategory::NotAvailable));
        assert_eq!(
            error_badge(&ncp_snap).as_deref(),
            Some("No active GLM Coding Plan. Subscribe at z.ai/subscribe to see usage.")
        );
        assert_eq!(ncp_snap.clears_prior_menu_bar_quota_state, Some(true));

        let http_bad_limit = MockClient::new(vec![
            Ok(ok_json(
                r#"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5}]}}"#,
            )),
            Ok(ok_json(r#"{"data":[]}"#)),
        ]);
        let bad_snap =
            ZAIProvider::new(spec.clone(), http_bad_limit, empty_scanner(&dir)).refresh(&ctx(NOW));
        assert_eq!(bad_snap.error_category, Some(ErrorCategory::Decoding));
        assert_eq!(
            error_badge(&bad_snap).as_deref(),
            Some("Usage response invalid. Try again later.")
        );

        let mut fold_ctx = ctx(NOW);
        fold_ctx.scope = Scope::PanelAccounting;
        let untouched = MockClient::new(vec![]);
        let fold_snap =
            ZAIProvider::new(spec, untouched.clone(), empty_scanner(&dir)).refresh(&fold_ctx);
        assert!(untouched.requests.lock().unwrap().is_empty());
        assert!(fold_snap.lines.iter().all(|l| l.label() != "Session"));
    });
}

fn make_zcode_fixture(
    dir: &TempDir,
    sqlite_sql: &str,
    entitlement_json: Option<&str>,
) -> ZCodeUsageScanner {
    let db_dir = dir.path().join("db");
    let lvl_dir = dir.path().join("leveldb");
    std::fs::create_dir_all(&db_dir).unwrap();
    std::fs::create_dir_all(&lvl_dir).unwrap();
    let sqlite_path = db_dir.join("db.sqlite");
    sqlite_execute(&sqlite_path, sqlite_sql).unwrap();
    if let Some(body) = entitlement_json {
        let payload = format!(
            "zcode:usage-entitlement:subscription-v2:account:zai-start-plan:[\"hash\",{{\"providerId\":\"account:zai-start-plan\"}}]:auth:1\u{0001}{body}"
        );
        std::fs::write(lvl_dir.join("000001.log"), payload.as_bytes()).unwrap();
    }
    ZCodeUsageScanner::new(sqlite_path, lvl_dir).with_cache_dir(dir.path().join("cache"))
}

#[test]
fn zcode_damaged_rows_real_row_isolation_and_broken_sqlite_fallback() {
    with_env(&[], || {
        let dir = TempDir::new().unwrap();
        let scanner = make_zcode_fixture(
            &dir,
            "CREATE TABLE model_usage (input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens, model_id, provider_id, started_at);
             INSERT INTO model_usage VALUES (1.5, 2, 0, 0, 'glm-4', 'account:zai-start-plan', 1794160000000),
                                            (100, 20, 0, 0, 'glm-4', 'account:zai-start-plan', 1794160000000);",
            None,
        );
        let usage = scanner.usage(Some(1_794_160_000.0), None).unwrap().unwrap();
        assert_eq!(usage.total_tokens, Some(120.0));
        assert_eq!(usage.damaged_rows, 1);
        assert_eq!(usage.log_scan.unwrap().series.daily[0].total_tokens, 120);

        let dir2 = TempDir::new().unwrap();
        let broken = make_zcode_fixture(
            &dir2,
            "CREATE TABLE other (id INTEGER);",
            Some(
                r#"{"cachedAt":1794254217417,"snapshot":{"quota":{"level":"Start","limits":[]}}}"#,
            ),
        );
        let provider = ZAIProvider::new(
            spec_with_paths(temp_config_paths(&dir2)),
            MockClient::new(vec![]),
            broken,
        );
        let snap = provider.refresh(&ctx(1_794_160_000.0));
        assert_eq!(snap.plan.as_deref(), Some("Start Plan"));
        assert_eq!(
            snap.history_warning.as_deref(),
            Some("Couldn't read ZCode token usage.")
        );
    });
}

#[test]
fn zcode_wal_invalidation_persisted_cache_and_failed_quota_distant_past() {
    with_env(&[], || {
        let dir = TempDir::new().unwrap();
        let scanner = make_zcode_fixture(
            &dir,
            "CREATE TABLE model_usage (input_tokens INTEGER, output_tokens INTEGER, provider_id TEXT, started_at INTEGER);
             INSERT INTO model_usage VALUES (1000, 500, 'account:zai-start-plan', 1794160000000);",
            Some(r#"{"cachedAt":1794163892440,"snapshot":{"quota":{"level":"Start","limits":[{"planId":"zcode-v3-start-plan-1106-wk","period":"one_time","unit":500000000,"usage":194069327,"remaining":305930673,"nextResetTime":1794186000000}]}}}"#),
        );
        let first = scanner.usage(Some(1_794_160_000.0), None).unwrap().unwrap();
        assert_eq!(first.total_tokens, Some(1500.0));
        let second =
            ZCodeUsageScanner::new(scanner.sqlite_path.clone(), scanner.leveldb_dir.clone())
                .with_cache_dir(dir.path().join("cache"))
                .usage(Some(1_794_160_000.0), None)
                .unwrap()
                .unwrap();
        assert_eq!(second.total_tokens, Some(1500.0));

        let spec = spec_with_paths(temp_config_paths(&dir));
        spec.save_key("zai-test").unwrap();
        let http = MockClient::new(vec![
            Ok(Response {
                status: 500,
                headers: Vec::new(),
                body: Vec::new(),
            }),
            Ok(ok_json(SUBSCRIPTION)),
        ]);
        let snap = ZAIProvider::new(spec, http, scanner).refresh(&ctx(1_794_160_000.0));
        assert!(snap.lines.iter().any(|l| l.label() == "Weekend Build"));
        assert_eq!(snap.quota_refreshed_at, Some(DISTANT_PAST));
    });
}

#[test]
fn zcode_promo_lifecycle_freshest_scheduled_and_pricing() {
    with_env(&[], || {
        let dir = TempDir::new().unwrap();
        let scanner = make_zcode_fixture(
            &dir,
            "CREATE TABLE model_usage (id TEXT PRIMARY KEY, input_tokens INTEGER, output_tokens INTEGER, cache_read_input_tokens INTEGER, cache_creation_input_tokens INTEGER, model_id TEXT, provider_id TEXT, started_at INTEGER);
             INSERT INTO model_usage VALUES ('1', 1000000, 200000, 500000, 0, 'GLM-5.3-Flash', 'account:zai-start-plan', 1794160000000);",
            Some(r#"{"cachedAt":1000,"snapshot":{"quota":{"level":"Start","limits":[{"planId":"zcode-v3-start-plan-1110-nt","period":"one_time","unit":500000000,"usage":0,"remaining":500000000,"nextResetTime":1794272400000}]},"subscription":{"details":[{"productId":"zcode-v3-start-plan-1110-nt","productName":"ZCODE GLOBAL BUILD","billingCycle":"one_time","expireTime":"2026-11-11T01:00:00.000Z","entitlements":[{"entitlementId":"ent-1","effectiveTime":"2026-11-10T15:00:00.000Z"}]}]}}}"#),
        );
        let ldb = "zcode:usage-entitlement:subscription-v2:account:zai-coding-plan:[\"h\",{}]:auth:2\u{0001}{\"cachedAt\":2000,\"snapshot\":{\"quota\":{\"level\":\"Start\",\"limits\":[{\"planId\":\"zcode-v3-start-plan-1110-nt\",\"period\":\"one_time\",\"unit\":300000000,\"usage\":0,\"remaining\":300000000}]},\"subscription\":{\"details\":[{\"productId\":\"zcode-v3-start-plan-1110-nt\",\"productName\":\"ZCODE GLOBAL BUILD\",\"billingCycle\":\"one_time\",\"expireTime\":\"2026-11-11T01:00:00.000Z\",\"entitlements\":[{\"entitlementId\":\"ent-1\",\"effectiveTime\":\"2026-11-10T15:00:00.000Z\"}]}]}}}";
        std::fs::write(scanner.leveldb_dir.join("000002.ldb"), ldb.as_bytes()).unwrap();

        let provider = ZAIProvider::new(
            spec_with_paths(temp_config_paths(&dir)),
            MockClient::new(vec![]),
            scanner.clone(),
        );
        let snap = provider.refresh(&ctx(1_794_317_209.0));
        let build = snap
            .lines
            .iter()
            .find(|l| l.label() == "Global Build")
            .unwrap();
        assert!(
            matches!(build, MetricLine::Progress { limit, detail: Some(d), format: ProgressFormat::Count(s), .. } if *limit == 300_000_000.0 && d.starts_with("Starts") && s == "tokens")
        );

        let snap_same_day = provider.refresh(&ctx(1_794_160_000.0));
        let history = snap_same_day.usage_history.as_ref().unwrap();
        assert_eq!(history.series.daily[0].total_tokens, 1_200_000);
        let today = snap_same_day
            .lines
            .iter()
            .find(|l| l.label() == "Today")
            .unwrap();
        match today {
            MetricLine::Values {
                values,
                model_breakdown,
                ..
            } => {
                let dollars = values
                    .iter()
                    .find(|v| {
                        matches!(
                            v,
                            MetricValue {
                                kind: MetricKind::Dollars,
                                ..
                            }
                        )
                    })
                    .unwrap();
                assert!((dollars.number - 0.1895).abs() < 0.002);
                assert_eq!(
                    model_breakdown.as_ref().unwrap().models[0]
                        .model
                        .to_ascii_lowercase(),
                    "glm-5.3-flash"
                );
            }
            _ => panic!("expected Today line"),
        }
    });
}
