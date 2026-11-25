//! Unit and integration tests for Cursor auth, mappers, enterprise fallback, and provider refresh.

use super::auth::{
    cache_identity_key, CursorAuthError, CursorAuthSource, CursorAuthState, CursorAuthStore,
    KeychainBackend, MemorySqlite, SqlBackend, ACCESS_TOKEN_KEY, KEYCHAIN_ACCESS_SERVICE,
    KEYCHAIN_REFRESH_SERVICE, MEMBERSHIP_TYPE_KEY, REFRESH_TOKEN_KEY,
};
use super::client::{
    CREDITS_URL, EXPORT_CSV_URL, GROK_BOT_USAGE_URL, PLAN_URL, REFRESH_URL, REST_USAGE_URL,
    STRIPE_URL, USAGE_SUMMARY_URL, USAGE_URL,
};
use super::mapper::{
    map_grok_bot_usage, map_request_based_usage, map_usage, preferred_membership, routing_plan_name,
    should_use_request_based_fallback, BILLING_PERIOD_MS,
};
use super::summary;
use super::CursorProvider;
use crate::context::{RefreshContext, Scope};
use crate::host::{diagnostic_gate, SecureAccount};
use crate::http::{mock::FnClient, HttpError, Response};
use crate::model::{ErrorCategory, MetricKind, MetricLine, MetricValue, ProgressFormat};
use crate::parse::WEEK_MS;
use crate::providers::ProviderRuntime;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

const NOW: f64 = 1_800_000_000.0;

fn base64url_encode(input: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::new();
    let mut i = 0;
    while i < input.len() {
        let b0 = input[i];
        let b1 = if i + 1 < input.len() { input[i + 1] } else { 0 };
        let b2 = if i + 2 < input.len() { input[i + 2] } else { 0 };
        out.push(TABLE[(b0 >> 2) as usize] as char);
        out.push(TABLE[(((b0 & 0x03) << 4) | (b1 >> 4)) as usize] as char);
        if i + 1 < input.len() {
            out.push(TABLE[(((b1 & 0x0F) << 2) | (b2 >> 6)) as usize] as char);
        }
        if i + 2 < input.len() {
            out.push(TABLE[(b2 & 0x3F) as usize] as char);
        }
        i += 3;
    }
    out
}

fn make_jwt(sub: Option<&str>, exp: Option<i64>) -> String {
    let hdr = base64url_encode(br#"{"alg":"HS256","typ":"JWT"}"#);
    let mut payload = serde_json::Map::new();
    if let Some(s) = sub {
        payload.insert("sub".into(), json!(s));
    }
    if let Some(e) = exp {
        payload.insert("exp".into(), json!(e));
    }
    let body = base64url_encode(&serde_json::to_vec(&payload).unwrap());
    format!("{hdr}.{body}.sig")
}

#[derive(Default)]
struct FakeKeychain {
    default_values: Mutex<HashMap<String, String>>,
    current_user_values: Mutex<HashMap<String, String>>,
    interaction_required: bool,
    calls: Mutex<Vec<bool>>,
}

impl KeychainBackend for FakeKeychain {
    fn read_item(
        &self,
        service: &str,
        account: SecureAccount,
        ctx: Option<&RefreshContext>,
    ) -> Result<Option<String>, CursorAuthError> {
        let allow_interaction = ctx.is_some_and(|c| c.is_manual);
        self.calls.lock().unwrap_or_else(|e| e.into_inner()).push(allow_interaction);
        if self.interaction_required {
            return Err(CursorAuthError::CredentialPermissionRequired);
        }
        let map = match account {
            SecureAccount::CurrentUser => self.current_user_values.lock().unwrap_or_else(|e| e.into_inner()),
            SecureAccount::Any | SecureAccount::Named(_) => {
                self.default_values.lock().unwrap_or_else(|e| e.into_inner())
            }
        };
        Ok(map.get(service).cloned())
    }

    fn write_current_user(&self, service: &str, value: &str) -> Result<(), String> {
        self.current_user_values.lock().unwrap_or_else(|e| e.into_inner()).insert(service.into(), value.into());
        Ok(())
    }

    fn item_exists(&self, service: &str) -> Option<bool> {
        let cu = self.current_user_values.lock().unwrap_or_else(|e| e.into_inner()).contains_key(service);
        let df = self.default_values.lock().unwrap_or_else(|e| e.into_inner()).contains_key(service);
        Some(cu || df)
    }
}

fn json_ok(val: Value) -> Result<Response, HttpError> {
    Ok(Response { status: 200, headers: Vec::new(), body: serde_json::to_vec(&val).unwrap() })
}

fn ctx(now: f64) -> RefreshContext {
    let mut c = RefreshContext::new(Scope::Full);
    c.now = now;
    c
}

#[test]
fn auth_store_priority_persistence_rotation_and_blocked_keychain() {
    let sqlite_tok = make_jwt(Some("google-oauth2|sqlite-user"), None);
    let kc_tok = make_jwt(Some("auth0|keychain-user"), None);
    let sqlite = Arc::new(MemorySqlite::new(HashMap::from([
        (ACCESS_TOKEN_KEY.into(), sqlite_tok.clone()),
        (REFRESH_TOKEN_KEY.into(), "sqlite-refresh".into()),
        (MEMBERSHIP_TYPE_KEY.into(), "free".into()),
    ])));
    let kc = Arc::new(FakeKeychain::default());
    kc.default_values.lock().unwrap().insert(KEYCHAIN_ACCESS_SERVICE.into(), kc_tok.clone());
    kc.default_values.lock().unwrap().insert(KEYCHAIN_REFRESH_SERVICE.into(), "kc-refresh".into());
    let store = CursorAuthStore::with_backends(sqlite.clone(), kc.clone());
    let state = store.load_auth_state(None, NOW, false).unwrap().unwrap();
    assert_eq!(state.source, CursorAuthSource::Keychain);
    assert_eq!(state.access_token, kc_tok);

    let cu_tok = make_jwt(Some("auth0|rotated-user"), None);
    let kc2 = Arc::new(FakeKeychain::default());
    kc2.default_values.lock().unwrap().insert(KEYCHAIN_ACCESS_SERVICE.into(), make_jwt(Some("auth0|legacy"), None));
    kc2.current_user_values.lock().unwrap().insert(KEYCHAIN_ACCESS_SERVICE.into(), cu_tok.clone());
    let empty_sql = Arc::new(MemorySqlite::new(HashMap::new()));
    let store2 = CursorAuthStore::with_backends(empty_sql, kc2.clone());
    assert_eq!(store2.load_auth_state(None, NOW, false).unwrap().unwrap().access_token, cu_tok);

    let kc_blocked = Arc::new(FakeKeychain { interaction_required: true, ..Default::default() });
    let good_sql = Arc::new(MemorySqlite::new(HashMap::from([(ACCESS_TOKEN_KEY.into(), make_jwt(Some("u1"), None))])));
    let store3 = CursorAuthStore::with_backends(good_sql, kc_blocked.clone());
    assert_eq!(store3.load_auth_state(None, NOW, false).unwrap().unwrap().source, CursorAuthSource::Sqlite);
    assert!(kc_blocked.calls.lock().unwrap().is_empty());

    let expired_sql = Arc::new(MemorySqlite::new(HashMap::from([(ACCESS_TOKEN_KEY.into(), make_jwt(Some("u1"), Some(0)))])));
    let store4 = CursorAuthStore::with_backends(expired_sql, kc_blocked.clone());
    assert_eq!(store4.load_auth_state(Some(&ctx(NOW)), NOW, false), Err(CursorAuthError::CredentialPermissionRequired));
    assert_eq!(*kc_blocked.calls.lock().unwrap(), vec![false]);

    let unreadable = Arc::new(MemorySqlite { fail_reads: true, ..MemorySqlite::new(HashMap::new()) });
    let store5 = CursorAuthStore::with_backends(unreadable.clone(), Arc::new(FakeKeychain::default()));
    assert_eq!(store5.load_auth_state(None, NOW, false), Err(CursorAuthError::CredentialsUnreadable));
    let store6 = CursorAuthStore::with_backends(unreadable, kc2);
    assert_eq!(store6.load_auth_state(None, NOW, false).unwrap().unwrap().access_token, cu_tok);

    let switch_sql = Arc::new(MemorySqlite::new(HashMap::from([
        (ACCESS_TOKEN_KEY.into(), make_jwt(Some("google-oauth2|sql"), Some(0))),
        (REFRESH_TOKEN_KEY.into(), "sql-r".into()),
        (MEMBERSHIP_TYPE_KEY.into(), "free".into()),
    ])));
    let switch_kc = Arc::new(FakeKeychain::default());
    let store7 = CursorAuthStore::with_backends(switch_sql.clone(), switch_kc.clone());
    let orig = store7.load_auth_state(None, NOW, false).unwrap().unwrap();
    assert_eq!(orig.source, CursorAuthSource::Sqlite);
    switch_kc.current_user_values.lock().unwrap().insert(KEYCHAIN_ACCESS_SERVICE.into(), make_jwt(Some("auth0|new"), None));
    assert_eq!(store7.save_access_token("late-tok", &orig, NOW), Err(CursorAuthError::SessionExpired));
    assert!(switch_sql.written_values.lock().unwrap().is_empty());

    assert!(cache_identity_key(&CursorAuthState {
        access_token: cu_tok,
        refresh_token: None,
        membership_type: None,
        source: CursorAuthSource::Keychain,
    }).unwrap().starts_with("cursor-"));
}

#[test]
fn usage_summary_team_and_grok_bot_mappers() {
    let mapped = summary::map(
        Some(json!({
            "billingCycleStart": "2026-07-01T00:00:00.000Z",
            "billingCycleEnd": "2026-08-01T00:00:00.000Z",
            "membershipType": "enterprise",
            "individualUsage": {
                "plan": { "enabled": true, "limit": 0, "autoPercentUsed": 0, "apiPercentUsed": 6.25, "totalPercentUsed": 6.25 },
                "onDemand": { "enabled": true, "used": 0, "limit": 25000, "remaining": 25000 }
            }
        }).as_object().unwrap()),
        Some(json!({ "gpt-4": { "numRequests": 37, "maxRequestUsage": 750 }, "startOfMonth": "2026-07-01T00:00:00.000Z" }).as_object().unwrap()),
        Some("Enterprise"),
        "unavailable",
    ).unwrap();
    assert_eq!(mapped.plan.as_deref(), Some("Enterprise"));
    assert!(matches!(mapped.lines.iter().find(|l| l.label() == "Total usage"), Some(MetricLine::Progress { used: 37.0, limit: 750.0, format: ProgressFormat::Count(_), .. })));
    assert!(matches!(mapped.lines.iter().find(|l| l.label() == "On-demand"), Some(MetricLine::Progress { used: 0.0, limit: 250.0, format: ProgressFormat::Dollars, .. })));

    let team_mapped = map_usage(
        json!({
            "enabled": true,
            "billingCycleStart": 1_770_000_000_000i64,
            "billingCycleEnd": 1_772_592_000_000i64,
            "planUsage": { "limit": 40_000, "totalSpend": 10_000, "bonusSpend": 2_500 }
        }).as_object().unwrap(),
        Some("Team"), None, 0.0,
    ).unwrap();
    assert!(!team_mapped.lines.iter().any(|l| l.label() == "Bonus spend"));
    assert!(matches!(team_mapped.lines.iter().find(|l| l.label() == "Total usage"), Some(MetricLine::Progress { used: 100.0, limit: 400.0, format: ProgressFormat::Dollars, .. })));

    let bool_spend = map_usage(
        json!({ "enabled": true, "planUsage": { "limit": 40_000, "remaining": 32_000, "totalSpend": true } }).as_object().unwrap(),
        Some("Team"), None, 0.0,
    ).unwrap();
    assert!(matches!(bool_spend.lines.iter().find(|l| l.label() == "Total usage"), Some(MetricLine::Progress { used: 80.0, limit: 400.0, .. })));

    let huge = map_usage(
        json!({ "enabled": true, "billingCycleStart": 1_770_000_000_000i64, "billingCycleEnd": 1e30, "planUsage": { "limit": 40_000, "totalPercentUsed": 10 } }).as_object().unwrap(),
        Some("Pro"), None, 0.0,
    ).unwrap();
    assert!(matches!(huge.lines.iter().find(|l| l.label() == "Total usage"), Some(MetricLine::Progress { resets_at: None, period_duration_ms: Some(ms), .. }) if *ms == BILLING_PERIOD_MS));

    let credits_mapped = map_usage(
        json!({
            "enabled": true,
            "planUsage": { "limit": 40_000, "remaining": 32_000, "totalPercentUsed": 20, "autoPercentUsed": 12.5, "apiPercentUsed": 7.5 },
            "spendLimitUsage": { "individualLimit": 5_000, "individualRemaining": 4_500, "individualUsed": 0, "totalSpend": 1_200 }
        }).as_object().unwrap(),
        Some("pro plan"),
        Some(json!({ "hasCreditGrants": true, "totalCents": "1000000", "usedCents": "264729" }).as_object().unwrap()),
        991_544.0,
    ).unwrap();
    assert!(matches!(credits_mapped.lines.iter().find(|l| l.label() == "Credits"), Some(MetricLine::Values { values, .. }) if (values[0].number - 17268.15).abs() < 1e-3));
    assert!(matches!(credits_mapped.lines.iter().find(|l| l.label() == "On-demand"), Some(MetricLine::Progress { used: 12.0, limit: 50.0, .. })));

    assert_eq!(preferred_membership(Some("pro"), Some("enterprise")).as_deref(), Some("enterprise"));
    assert_eq!(preferred_membership(Some("enterprise"), Some("team")).as_deref(), Some("enterprise"));
    assert_eq!(routing_plan_name(None, Some("pro")), None);
    assert!(!should_use_request_based_fallback(json!({"enabled": true, "planUsage": {"totalPercentUsed": 20}}).as_object().unwrap(), Some("Team"), false).0);
    assert!(should_use_request_based_fallback(json!({"enabled": true, "planUsage": {}, "spendLimitUsage": {"limitType": "team"}}).as_object().unwrap(), None, false).0);
    assert!(matches!(map_grok_bot_usage(json!({"usagePercent": 37.5, "hasNonZeroIncludedLimit": true}).as_object().unwrap()), Some(MetricLine::Progress { period_duration_ms: Some(w), .. }) if w == WEEK_MS));
    assert!(map_grok_bot_usage(json!({"usagePercent": 42, "usesPooledEnterpriseAllowance": true}).as_object().unwrap()).is_none());
    assert!(map_request_based_usage(json!({"gpt-4": {"maxRequestUsage": 0}}).as_object().unwrap(), Some("Enterprise"), "err").is_err());
}

#[test]
fn provider_refresh_live_enterprise_rotation_and_cancellation() {
    diagnostic_gate::clear_prefix("auth.cursor.");
    let access_tok = make_jwt(Some("google-oauth2|user_abc123"), None);
    let sqlite = Arc::new(MemorySqlite::new(HashMap::from([
        (ACCESS_TOKEN_KEY.into(), access_tok.clone()),
        (MEMBERSHIP_TYPE_KEY.into(), "pro".into()),
    ])));
    let http = Arc::new(FnClient::new(move |req| {
        if req.url == USAGE_URL {
            return json_ok(json!({
                "enabled": true, "billingCycleEnd": 1_772_592_000_000i64,
                "planUsage": { "limit": 2000, "totalSpend": 400, "totalPercentUsed": 20, "autoPercentUsed": 12.5, "apiPercentUsed": 7.5 },
                "spendLimitUsage": { "limitType": "team", "pooledLimit": 0 }
            }));
        }
        if req.url == PLAN_URL {
            return json_ok(json!({"planInfo": {"planName": "Pro"}}));
        }
        if req.url == GROK_BOT_USAGE_URL {
            return json_ok(json!({"usagePercent": 37.5, "hasNonZeroIncludedLimit": true}));
        }
        if req.url == CREDITS_URL {
            return json_ok(json!({"hasCreditGrants": false}));
        }
        if req.url == STRIPE_URL {
            assert_eq!(req.headers.iter().find(|(k, _)| k == "Cookie").unwrap().1, format!("WorkosCursorSessionToken=user_abc123%3A%3A{access_tok}"));
            return json_ok(json!({"customerBalance": "-50000"}));
        }
        if req.url == USAGE_SUMMARY_URL {
            return json_ok(json!({"membershipType": "enterprise", "individualUsage": {"onDemand": {"enabled": true, "used": 500, "limit": 100000, "remaining": 99500}}}));
        }
        if req.url.starts_with(EXPORT_CSV_URL) {
            let csv = format!(
                "Date,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Cost\n{},composer-1,No,0,1000,0,100,Included\n",
                crate::time::format_iso8601(NOW)
            );
            return Ok(Response { status: 200, headers: Vec::new(), body: csv.into_bytes() });
        }
        Ok(Response { status: 404, headers: Vec::new(), body: Vec::new() })
    }));

    let provider = CursorProvider::new(CursorAuthStore::with_backends(sqlite, Arc::new(FakeKeychain::default())), http);
    let c = ctx(NOW);
    let snap = provider.refresh(&c);
    assert_eq!(snap.plan.as_deref(), Some("Enterprise"));
    assert!(c.observed_identity_key().as_deref().unwrap().starts_with("cursor-"));
    assert!(matches!(snap.lines.iter().find(|l| l.label() == "Credits"), Some(MetricLine::Values { values, .. }) if values[0].number == 500.0));
    assert!(snap.lines.iter().any(|l| l.label() == "Grok Bot usage"));
    assert!(snap.lines.iter().any(|l| l.label() == "Usage Trend"));

    let old_tok = make_jwt(Some("auth0|old"), Some(0));
    let rot_sql = Arc::new(MemorySqlite::new(HashMap::from([
        (ACCESS_TOKEN_KEY.into(), old_tok),
        (REFRESH_TOKEN_KEY.into(), "old-refresh".into()),
    ])));
    let rot_ctx = ctx(NOW);
    let rot_ctx_c = rot_ctx.clone();
    let rot_http = Arc::new(FnClient::new(move |req| {
        assert_eq!(req.url, REFRESH_URL);
        rot_ctx_c.cancel.cancel();
        json_ok(json!({"access_token": "rotated-access"}))
    }));
    let rot_prov = CursorProvider::new(CursorAuthStore::with_backends(rot_sql.clone(), Arc::new(FakeKeychain::default())), rot_http);
    assert_eq!(rot_prov.refresh(&rot_ctx).error_category, Some(ErrorCategory::Cancelled));
    assert_eq!(rot_sql.written_values.lock().unwrap().get(ACCESS_TOKEN_KEY).map(String::as_str), Some("rotated-access"));

    let personal_sql = Arc::new(MemorySqlite::new(HashMap::from([(ACCESS_TOKEN_KEY.into(), make_jwt(Some("google-oauth2|p"), None))])));
    let seen_urls = Arc::new(Mutex::new(Vec::new()));
    let seen_c = Arc::clone(&seen_urls);
    let p_http = Arc::new(FnClient::new(move |req| {
        seen_c.lock().unwrap().push(req.url.clone());
        if req.url == USAGE_URL {
            json_ok(json!({"enabled": true, "planUsage": {"limit": 40000, "remaining": 32000, "totalPercentUsed": 20}}))
        } else if req.url == PLAN_URL {
            json_ok(json!({"planInfo": {"planName": "Pro"}}))
        } else {
            Ok(Response { status: 404, headers: Vec::new(), body: Vec::new() })
        }
    }));
    let p_prov = CursorProvider::new(CursorAuthStore::with_backends(personal_sql, Arc::new(FakeKeychain::default())), p_http);
    assert_eq!(p_prov.refresh(&RefreshContext::new(Scope::MenuBar)).plan.as_deref(), Some("Pro"));
    assert!(!seen_urls.lock().unwrap().iter().any(|u| u == USAGE_SUMMARY_URL));

    let _ = (REST_USAGE_URL, MetricValue::new(0.0, MetricKind::Dollars));
}

#[test]
fn refresh_only_sqlite_state_rotates_and_fetches_quota() {
    let new_jwt = make_jwt(Some("google-oauth2|refresh-user"), Some(1_900_000_000));
    let sqlite = Arc::new(MemorySqlite::new(HashMap::from([(REFRESH_TOKEN_KEY.into(), "refresh-token".into())])));
    let store = CursorAuthStore::with_backends(sqlite.clone(), Arc::new(FakeKeychain::default()));
    assert!(store.has_local_credentials());

    let seen = Arc::new(Mutex::new(Vec::new()));
    let seen_c = Arc::clone(&seen);
    let jwt_c = new_jwt.clone();
    let http = Arc::new(FnClient::new(move |req| {
        seen_c.lock().unwrap().push(req.url.clone());
        if req.url == REFRESH_URL {
            return json_ok(json!({"access_token": jwt_c}));
        }
        if req.url == USAGE_URL {
            let auth = req.headers.iter().find(|(k, _)| k == "Authorization").map(|(_, v)| v.as_str()).unwrap_or("");
            assert_eq!(auth, format!("Bearer {jwt_c}"));
            return json_ok(json!({"enabled": true, "planUsage": {"limit": 40000, "remaining": 32000, "totalPercentUsed": 20}}));
        }
        Ok(Response { status: 404, headers: Vec::new(), body: Vec::new() })
    }));
    let provider = CursorProvider::new(store, http);
    let mut c = RefreshContext::new(Scope::MenuBar);
    c.now = NOW;
    let snap = provider.refresh(&c);
    assert!(!snap.is_error());

    let urls = seen.lock().unwrap();
    assert_eq!(urls.first().map(String::as_str), Some(REFRESH_URL));
    assert!(urls.iter().position(|u| u == USAGE_URL).unwrap() > 0);
    drop(urls);
    assert_eq!(sqlite.query_item(ACCESS_TOKEN_KEY).unwrap().as_deref(), Some(new_jwt.as_str()));
}

#[test]
fn save_access_token_rejects_access_and_refresh_drift_independently() {
    let subject = "google-oauth2|user-drift";
    let original = make_jwt(Some(subject), Some(0));
    let sqlite = Arc::new(MemorySqlite::new(HashMap::from([
        (ACCESS_TOKEN_KEY.into(), original.clone()),
        (REFRESH_TOKEN_KEY.into(), "refresh-1".into()),
    ])));
    let store = CursorAuthStore::with_backends(sqlite.clone(), Arc::new(FakeKeychain::default()));
    let observed = store.load_auth_state(None, NOW, false).unwrap().unwrap();
    assert_eq!(observed.source, CursorAuthSource::Sqlite);

    // A newer access token landed concurrently: same subject, different expiry.
    let newer = make_jwt(Some(subject), Some(1_900_000_000));
    sqlite.write_access_token(&newer).unwrap();
    assert_eq!(store.save_access_token("ours", &observed, NOW), Err(CursorAuthError::SessionExpired));
    assert_eq!(sqlite.query_item(ACCESS_TOKEN_KEY).unwrap().as_deref(), Some(newer.as_str()));

    // The original access token restored but a rotated refresh token is rejected too.
    sqlite.write_access_token(&original).unwrap();
    sqlite.values.lock().unwrap().insert(REFRESH_TOKEN_KEY.into(), "refresh-2".into());
    assert_eq!(store.save_access_token("ours", &observed, NOW), Err(CursorAuthError::SessionExpired));
    assert_eq!(sqlite.query_item(ACCESS_TOKEN_KEY).unwrap().as_deref(), Some(original.as_str()));
}

#[test]
fn usage_export_window_starts_at_local_midnight_thirty_days_back() {
    let zone = chrono::FixedOffset::west_opt(5 * 3600).unwrap();
    let now = crate::time::parse_iso8601("2026-11-24T19:15:00Z").unwrap();
    let start = super::usage_export_start(now, &zone).unwrap();
    assert_eq!(start, crate::time::parse_iso8601("2026-10-26T05:00:00Z").unwrap());
    assert_eq!(super::usage_export_start(f64::NAN, &zone), None);
}

#[test]
fn invalid_utf8_usage_csv_is_dropped_without_spend_lines() {
    let access_tok = make_jwt(Some("google-oauth2|utf8-user"), Some(1_900_000_000));
    let sqlite = Arc::new(MemorySqlite::new(HashMap::from([(ACCESS_TOKEN_KEY.into(), access_tok)])));
    let csv = format!(
        "Date,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Cost\n{},modelXname,No,0,1000,0,100,0.01\n",
        crate::time::format_iso8601(NOW)
    );
    let mut body = csv.into_bytes();
    let pos = body.iter().position(|b| *b == b'X').unwrap();
    body[pos] = 0xff;
    let http = Arc::new(FnClient::new(move |req| {
        assert!(req.url.starts_with(EXPORT_CSV_URL));
        Ok(Response { status: 200, headers: Vec::new(), body: body.clone() })
    }));
    let provider = CursorProvider::new(
        CursorAuthStore::with_backends(sqlite, Arc::new(FakeKeychain::default())),
        http,
    )
    .with_pricing_override(Arc::new(crate::pricing::ModelPricing::default()));
    let mut c = RefreshContext::new(Scope::PanelAccounting);
    c.now = NOW;
    let snap = provider.refresh(&c);
    assert!(snap.usage_history.is_none());
    assert!(snap.lines.iter().all(|l| {
        !matches!(l, MetricLine::Values { values, .. } if values.iter().any(|v| v.kind == MetricKind::Dollars))
    }));
}
