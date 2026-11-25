use super::auth::{token_expires_at, GrokAuthError, GrokAuthStore};
use super::client::{CREDITS_CONFIG_URL, REFRESH_URL, SETTINGS_URL, TOKEN_AUTH_HEADER};
use super::logs::{aggregate, dedup, parse_line, GrokLogUsageScanner};
use super::mapper::{
    decode_credits_config, map_credits_config, GrokUsageError, WEEKLY_PERIOD_TYPE,
};
use super::*;
use crate::context::{CancelToken, RefreshContext, Scope};
use crate::http::{mock::FnClient as MockClient, HttpError, Request, Response};
use crate::model::{ErrorCategory, MetricLine};
use crate::pricing::{ModelPricing, ModelRates, PricingCatalog, PricingSupplement};
use crate::scan::IncrementalScanner;
use crate::time;
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};

fn b64url(s: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::new();
    for chunk in s.chunks(3) {
        let b0 = chunk[0];
        let b1 = *chunk.get(1).unwrap_or(&0);
        let b2 = *chunk.get(2).unwrap_or(&0);
        out.push(TABLE[(b0 >> 2) as usize] as char);
        out.push(TABLE[(((b0 & 3) << 4) | (b1 >> 4)) as usize] as char);
        if chunk.len() > 1 {
            out.push(TABLE[(((b1 & 0xf) << 2) | (b2 >> 6)) as usize] as char);
        }
        if chunk.len() > 2 {
            out.push(TABLE[(b2 & 0x3f) as usize] as char);
        }
    }
    out
}

fn make_jwt(exp: i64) -> String {
    format!(
        "{}.{}.sig",
        b64url(br#"{"alg":"none"}"#),
        b64url(format!(r#"{{"exp":{exp}}}"#).as_bytes())
    )
}

fn credits_body(percent: Option<f64>, cap: Option<f64>, start: &str, end: &str) -> Vec<u8> {
    let mut cfg = json!({
        "currentPeriod": { "type": WEEKLY_PERIOD_TYPE, "start": start, "end": end }
    });
    if let Some(p) = percent {
        cfg["creditUsagePercent"] = json!(p);
    }
    if let Some(c) = cap {
        cfg["onDemandCap"] = json!({ "val": c });
    }
    serde_json::to_vec(&json!({ "config": cfg })).unwrap()
}

fn completed_turn(
    ts: &str,
    model: &str,
    input: i64,
    cached: i64,
    cw: i64,
    out: i64,
    ticks: Option<i64>,
    event_id: Option<&str>,
) -> Vec<u8> {
    let mut m = json!({
        "inputTokens": input,
        "cachedReadTokens": cached,
        "cacheCreationTokens": cw,
        "outputTokens": out,
        "reasoningTokens": 0
    });
    if let Some(t) = ticks {
        m["costUsdTicks"] = json!(t);
    }
    let mut meta = serde_json::Map::new();
    if let Some(id) = event_id {
        meta.insert("eventId".into(), json!(id));
    }
    let mut params = json!({
        "sessionId": "s1",
        "update": {
            "sessionUpdate": "turn_completed",
            "usage": { "inputTokens": input, "outputTokens": out, "modelUsage": { model: m } }
        }
    });
    if !meta.is_empty() {
        params["_meta"] = Value::Object(meta);
    }
    serde_json::to_vec(&json!({ "timestamp": ts, "method": "session/update", "params": params }))
        .unwrap()
}

#[test]
fn auth_store_reads_jwt_expiry_and_refuses_corrupt_overwrite() {
    let tok = make_jwt(1_770_000_000);
    assert_eq!(token_expires_at(&tok), Some(1_770_000_000.0));

    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("auth.json");
    let store = GrokAuthStore::at(path.clone());
    assert!(matches!(
        store.load_auth_candidates(),
        Err(GrokAuthError::NotLoggedIn)
    ));

    std::fs::write(&path, "not json").unwrap();
    assert!(matches!(
        store.load_auth_candidates(),
        Err(GrokAuthError::InvalidAuth)
    ));

    let valid = json!({ "https://auth.x.ai::client": { "key": tok, "refresh_token": "r1", "expires_at": "2026-07-01T00:00:00.000Z" } });
    std::fs::write(&path, serde_json::to_vec(&valid).unwrap()).unwrap();
    let mut state = store
        .load_auth_candidates()
        .unwrap()
        .into_iter()
        .next()
        .unwrap();
    let orig = state.clone();
    state.entry.key = Some("rotated".into());

    std::fs::write(&path, "{ corrupt").unwrap();
    assert!(store.save(&state).is_err());
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "{ corrupt");

    // save_replacing rejects if file changed concurrently
    std::fs::write(
        &path,
        serde_json::to_vec(&json!({ "https://auth.x.ai::other": { "key": "x" } })).unwrap(),
    )
    .unwrap();
    assert!(matches!(
        store.save_replacing(&state, &orig),
        Err(GrokAuthError::AuthConflict)
    ));
}

#[test]
fn credits_config_decoder_and_mapper_cover_proto_defaults_and_caps() {
    let body = credits_body(
        Some(99.0),
        None,
        "2026-07-03T04:01:09.238389+00:00",
        "2026-07-10T04:01:09.238389+00:00",
    );
    let cfg = decode_credits_config(&body).unwrap();
    assert_eq!(cfg.period_type, WEEKLY_PERIOD_TYPE);
    assert_eq!(cfg.used_percent, 99.0);
    assert_eq!(cfg.on_demand_cap, 0.0);

    let lines = map_credits_config(&body).unwrap();
    assert!(
        matches!(&lines[0], MetricLine::Progress { label, used, .. } if label == "Weekly limit" && *used == 99.0)
    );
    assert!(
        matches!(&lines[1], MetricLine::Badge { label, text, color_hex, .. } if label == "Pay as you go" && text == "Disabled" && color_hex.as_deref() == Some("#a3a3a3"))
    );

    let enabled = map_credits_config(&credits_body(
        None,
        Some(2500.0),
        "2026-07-03T00:00:00Z",
        "2026-07-10T00:00:00Z",
    ))
    .unwrap();
    assert!(
        matches!(&enabled[1], MetricLine::Badge { text, color_hex, .. } if text == "2500 cap" && color_hex.as_deref() == Some("#22c55e"))
    );

    let bad_order = credits_body(None, None, "2026-07-07T00:00:00Z", "2026-06-30T00:00:00Z");
    assert_eq!(
        decode_credits_config(&bad_order).unwrap_err(),
        GrokUsageError::InvalidResponse
    );
    assert_eq!(
        decode_credits_config(b"{}").unwrap_err(),
        GrokUsageError::InvalidResponse
    );
}

#[test]
fn log_scanner_token_math_subagent_exclusion_and_hostile_input() {
    let ts = "2026-06-10T10:00:00.000Z";
    let line = completed_turn(
        ts,
        "grok-4.6-build",
        1_000_000,
        700_000,
        100_000,
        250_000,
        Some(2_357_158_800),
        Some("e1"),
    );
    let parsed = parse_line(&line).unwrap();
    assert_eq!(parsed[0].tokens.input, 200_000);
    assert_eq!(parsed[0].tokens.cache_read, 700_000);
    assert_eq!(parsed[0].tokens.cache_write_5m, 100_000);
    assert_eq!(parsed[0].tokens.output, 250_000);
    assert_eq!(parsed[0].tokens.total_tokens(), 1_250_000);

    // Copied event id dedups while malformed turn_completed lines are skipped cleanly
    let dup_entries = [parse_line(&line).unwrap(), parse_line(&line).unwrap()].concat();
    let deduped = dedup(dup_entries);
    assert_eq!(deduped.len(), 1);
    let scan = aggregate(&deduped, 0.0, &ModelPricing::default());
    assert!((scan.series.daily[0].cost_usd.unwrap() - 0.23571588).abs() < 1e-8);
    assert!(
        (scan.series.daily[0].reported_cost.as_ref().unwrap().dollars - 0.23571588).abs() < 1e-8
    );

    // Pricing fallback with PricingCatalog rates
    let mut map = std::collections::HashMap::new();
    map.insert(
        "grok-4.5-build".to_string(),
        ModelRates::new(4.0, 12.0, 4.0, 0.6),
    );
    let pricing = ModelPricing::new(
        PricingSupplement::default(),
        PricingCatalog::from_entries(map),
        PricingCatalog::default(),
        PricingCatalog::default(),
        None,
    );
    let fb_line = completed_turn(
        ts,
        "grok-4.5-build",
        1_000_000,
        700_000,
        100_000,
        250_000,
        Some(1_000_000_000),
        None,
    );
    let fb_scan = aggregate(&parse_line(&fb_line).unwrap(), 0.0, &pricing);
    assert!((fb_scan.series.daily[0].cost_usd.unwrap() - 0.1).abs() < 1e-4);
    assert!(
        (fb_scan
            .api_estimate_by_day
            .unwrap()
            .values()
            .next()
            .unwrap()
            - 4.62)
            .abs()
            < 1e-4
    );

    // Hostile event_msg does not crash
    let hostile = br#"{"type":"event_msg","payload":{"type":"token_count","modelUsage":{"m":{"inputTokens":1e30,"outputTokens":5,"cachedReadTokens":-1e30}}},"timestamp":"2026-09-20T10:00:00.000Z"}"#;
    assert!(parse_line(hostile).is_none());

    // Subagent exclusion & malformed summary fail-closed
    let dir = tempfile::tempdir().unwrap();
    let sess = dir.path().join(".grok/sessions");
    std::fs::create_dir_all(sess.join("proj/coord/subagents/w1")).unwrap();
    std::fs::write(
        sess.join("proj/coord/summary.json"),
        r#"{"session_kind":"coordinator"}"#,
    )
    .unwrap();
    std::fs::write(
        sess.join("proj/coord/updates.jsonl"),
        completed_turn(
            ts,
            "grok-4.6-build",
            300,
            0,
            0,
            0,
            Some(30_000_000_000),
            Some("c1"),
        ),
    )
    .unwrap();
    std::fs::write(
        sess.join("proj/coord/subagents/w1/summary.json"),
        r#"{"session_kind":"subagent"}"#,
    )
    .unwrap();
    std::fs::write(
        sess.join("proj/coord/subagents/w1/updates.jsonl"),
        completed_turn(
            ts,
            "grok-4.6-build",
            100,
            0,
            0,
            0,
            Some(10_000_000_000),
            Some("s1"),
        ),
    )
    .unwrap();
    std::fs::write(sess.join("proj/coord/debug.jsonl"), &line).unwrap();

    let scanner = GrokLogUsageScanner::new(
        dir.path().to_path_buf(),
        Arc::new(|_| None),
        Some(Arc::new(IncrementalScanner::new(
            logs::GrokLineParser,
            "test-grok",
            None,
        ))),
    );
    let now = time::parse_iso8601("2026-06-18T12:00:00Z").unwrap();
    let res = scanner
        .scan(
            30,
            now,
            &|| Arc::new(ModelPricing::default()),
            &CancelToken::new(),
        )
        .unwrap();
    assert_eq!(res.series.daily[0].total_tokens, 300);

    std::fs::write(sess.join("proj/coord/summary.json"), "{invalid").unwrap();
    assert!(scanner
        .scan(
            30,
            now,
            &|| Arc::new(ModelPricing::default()),
            &CancelToken::new()
        )
        .is_none());
}

#[test]
fn provider_refreshes_tokens_caches_plan_and_retries_401() {
    let dir = tempfile::tempdir().unwrap();
    let auth_path = dir.path().join("auth.json");
    let auth_data = json!({
        "https://auth.x.ai::client": {
            "key": "expired-token",
            "refresh_token": "old-rt",
            "expires_at": "2000-01-01T00:00:00.000Z"
        }
    });
    std::fs::write(&auth_path, serde_json::to_vec(&auth_data).unwrap()).unwrap();

    let requests = Arc::new(Mutex::new(Vec::<String>::new()));
    let reqs = requests.clone();
    let client = Arc::new(MockClient::new(move |req: &Request| {
        reqs.lock().unwrap().push(req.url.clone());
        if req.url == REFRESH_URL {
            Ok(Response {
                status: 200,
                headers: Vec::new(),
                body: serde_json::to_vec(&json!({ "access_token": "new-tok", "refresh_token": "new-rt", "expires_in": 3600 })).unwrap(),
            })
        } else if req.url == CREDITS_CONFIG_URL {
            assert_eq!(
                req.headers
                    .iter()
                    .find(|(k, _)| k == "X-XAI-Token-Auth")
                    .map(|(_, v)| v.as_str()),
                Some(TOKEN_AUTH_HEADER)
            );
            assert_eq!(
                req.headers
                    .iter()
                    .find(|(k, _)| k == "Authorization")
                    .map(|(_, v)| v.as_str()),
                Some("Bearer new-tok")
            );
            Ok(Response {
                status: 200,
                headers: Vec::new(),
                body: credits_body(
                    Some(42.0),
                    Some(1000.0),
                    "2026-06-15T00:00:00Z",
                    "2026-06-22T00:00:00Z",
                ),
            })
        } else if req.url == SETTINGS_URL {
            Ok(Response {
                status: 200,
                headers: Vec::new(),
                body: br#"{"subscription_tier_display":"SuperGrok"}"#.to_vec(),
            })
        } else {
            Err(HttpError::Transport("unexpected".into()))
        }
    }));
    let scanner = GrokLogUsageScanner::new(
        dir.path().to_path_buf(),
        Arc::new(|_| None),
        Some(Arc::new(IncrementalScanner::new(
            logs::GrokLineParser,
            "test-grok-p",
            None,
        ))),
    );
    let provider = GrokProvider::new(GrokAuthStore::at(auth_path.clone()), client, scanner);
    let mut ctx = RefreshContext::new(Scope::Full);
    ctx.now = time::parse_iso8601("2026-06-18T12:00:00Z").unwrap();
    let snap = provider.refresh(&ctx);
    assert_eq!(snap.error_category, None);
    assert_eq!(snap.plan.as_deref(), Some("SuperGrok"));
    assert!(snap.lines.iter().any(|l| l.label() == "Weekly limit"));
    let updated = std::fs::read_to_string(&auth_path).unwrap();
    assert!(updated.contains("new-rt"));
    assert!(requests.lock().unwrap().iter().any(|u| u == SETTINGS_URL));

    // Unreadable auth file still counts as detected locally and surfaces CredentialAccess
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&auth_path, std::fs::Permissions::from_mode(0o000)).unwrap();
        assert!(provider.has_local_credentials());
        assert_eq!(
            provider.refresh(&ctx).error_category,
            Some(ErrorCategory::CredentialAccess)
        );
        std::fs::set_permissions(&auth_path, std::fs::Permissions::from_mode(0o600)).unwrap();
    }
}
