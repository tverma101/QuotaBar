//! Ported from `Tests/QuotaBarTests/DevinProviderTests.swift` (main + fix/devin-weekly-quota), using
//! real temporary files and SQLite databases instead of fakes.

use super::client::{INVALID_RESPONSE_KEY, TRANSPORT_FAILURE_KEY};
use super::*;
use crate::context::{RefreshContext, Scope};
use crate::host::diagnostic_gate;
use crate::http::{mock::MockClient, HttpError};
use crate::model::{MetricKind, MetricLine, ProviderSnapshot};
use crate::parse;
use crate::test_support::{captured_logs, install_capture_host};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Arc;

const NOW: f64 = 1_773_000_000.0;

fn user_status(plan: &str) -> Value {
    json!({
        "planStatus": {
            "planInfo": { "planName": plan, "billingStrategy": "BILLING_STRATEGY_QUOTA" },
            "dailyQuotaRemainingPercent": 100,
            "weeklyQuotaRemainingPercent": 40,
            "overageBalanceMicros": "964220000",
            "dailyQuotaResetAtUnix": "1774080000",
            "weeklyQuotaResetAtUnix": "1774166400"
        }
    })
}

fn body(plan: &str) -> String {
    json!({ "userStatus": user_status(plan) }).to_string()
}

fn plan_status_mut(status: &mut Value) -> &mut serde_json::Map<String, Value> {
    status["planStatus"].as_object_mut().unwrap()
}

fn progress(lines: &[MetricLine], label: &str) -> Option<(f64, f64, Option<f64>, Option<i64>)> {
    lines.iter().find_map(|line| match line {
        MetricLine::Progress { label: l, used, limit, resets_at, period_duration_ms, .. } if l == label => {
            Some((*used, *limit, *resets_at, *period_duration_ms))
        }
        _ => None,
    })
}

fn dollars(lines: &[MetricLine], label: &str) -> Option<f64> {
    lines.iter().find_map(|line| match line {
        MetricLine::Values { label: l, values, .. } if l == label => {
            values.iter().find(|v| v.kind == MetricKind::Dollars).map(|v| v.number)
        }
        _ => None,
    })
}

fn error_text(snapshot: &ProviderSnapshot) -> Option<String> {
    match snapshot.lines.first() {
        Some(MetricLine::Badge { text, .. }) => Some(text.clone()),
        _ => None,
    }
}

struct Fixture {
    dir: tempfile::TempDir,
}

impl Fixture {
    fn new() -> Self {
        Fixture { dir: tempfile::tempdir().unwrap() }
    }

    fn credentials(&self) -> PathBuf {
        self.dir.path().join("devin/credentials.toml")
    }

    fn state_db(&self) -> PathBuf {
        self.dir.path().join("Devin/User/globalStorage/state.vscdb")
    }

    fn write_credentials(&self, text: &str) {
        std::fs::create_dir_all(self.credentials().parent().unwrap()).unwrap();
        std::fs::write(self.credentials(), text).unwrap();
    }

    fn write_app_auth(&self, value: &str) {
        write_state_db(&self.state_db(), value);
    }

    fn store(&self) -> DevinAuthStore {
        DevinAuthStore::new(vec![self.credentials()], vec![self.state_db()])
    }

    fn provider(&self, http: Arc<MockClient>) -> DevinProvider {
        DevinProvider::new(self.store(), http)
    }
}

fn write_state_db(path: &Path, value: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let conn = rusqlite::Connection::open(path).unwrap();
    conn.execute_batch("CREATE TABLE IF NOT EXISTS ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)").unwrap();
    conn.execute("INSERT INTO ItemTable VALUES ('windsurfAuthStatus', ?1)", [value]).unwrap();
}

fn ctx(now: f64) -> RefreshContext {
    let mut ctx = RefreshContext::new(Scope::Full);
    ctx.now = now;
    ctx
}

// --- auth store ---------------------------------------------------------------------------

#[test]
fn parses_credentials_toml_and_accepts_only_https_server_url() {
    let fixture = Fixture::new();
    fixture.write_credentials("windsurf_api_key = \"devin-session-token$cli\"\napi_server_url = \"https://server.codeium.test/\"");
    let auth = fixture.store().load_credentials_file().unwrap().unwrap();
    assert_eq!(auth.api_key, "devin-session-token$cli");
    assert_eq!(auth.api_server_url.as_deref(), Some("https://server.codeium.test"));

    fixture.write_credentials("windsurf_api_key = \"devin-session-token$cli\"\r\napi_server_url = \"http://server.codeium.test\"");
    let auth = fixture.store().load_credentials_file().unwrap().unwrap();
    assert_eq!(auth.api_key, "devin-session-token$cli");
    assert_eq!(auth.api_server_url, None);
}

#[test]
fn toml_reader_matches_swift_semantics() {
    assert_eq!(read_toml_string("k = bare # comment", "k").as_deref(), Some("bare"));
    assert_eq!(read_toml_string("k = 'single'", "k").as_deref(), Some("single"));
    assert_eq!(read_toml_string("k = \"unterminated", "k"), None);
    assert_eq!(read_toml_string("k =\nk = later", "k"), None, "an empty value stops the search");
    assert_eq!(read_toml_string("other = 1\n k = \"a\\\"b\"", "k").as_deref(), Some("a\\\"b"));
}

#[test]
fn reads_app_auth_from_sqlite_state() {
    let fixture = Fixture::new();
    fixture.write_app_auth(r#"{"apiKey":" devin-session-token$app "}"#);
    let auth = fixture.store().load_app_auth(&fixture.state_db()).unwrap().unwrap();
    assert_eq!(auth.api_key, "devin-session-token$app");
    assert_eq!(auth.api_server_url, None);
}

#[test]
fn unreadable_credentials_file_errors_but_missing_file_is_none() {
    let fixture = Fixture::new();
    assert_eq!(fixture.store().load_credentials_file(), Ok(None));
    // A directory where the file should be: present but unreadable.
    std::fs::create_dir_all(fixture.credentials()).unwrap();
    assert_eq!(fixture.store().load_credentials_file(), Err(CredentialsUnreadable));
}

#[test]
fn unreadable_app_database_errors_but_missing_row_is_none() {
    let fixture = Fixture::new();
    assert_eq!(fixture.store().load_app_auth(&fixture.state_db()), Ok(None));
    std::fs::create_dir_all(fixture.state_db().parent().unwrap()).unwrap();
    std::fs::write(fixture.state_db(), "this is not a sqlite database at all, not even close").unwrap();
    assert_eq!(fixture.store().load_app_auth(&fixture.state_db()), Err(CredentialsUnreadable));

    let empty = Fixture::new();
    std::fs::create_dir_all(empty.state_db().parent().unwrap()).unwrap();
    rusqlite::Connection::open(empty.state_db())
        .unwrap()
        .execute_batch("CREATE TABLE ItemTable (key TEXT, value BLOB)")
        .unwrap();
    assert_eq!(empty.store().load_app_auth(&empty.state_db()), Ok(None));
}

#[test]
fn undecodable_app_auth_is_unreadable() {
    let fixture = Fixture::new();
    fixture.write_app_auth("not json");
    assert_eq!(fixture.store().load_app_auth(&fixture.state_db()), Err(CredentialsUnreadable));
}

#[test]
fn app_auth_is_read_once_until_the_state_database_changes() {
    let fixture = Fixture::new();
    fixture.write_app_auth(r#"{"apiKey":"first"}"#);
    let store = fixture.store();
    let db = fixture.state_db();
    assert_eq!(store.load_app_auth(&db).unwrap().unwrap().api_key, "first");
    // Corrupt the cached entry's value directly: an unchanged revision must serve the cache.
    store.app_auth_cache.lock().unwrap().get_mut(&fixture.state_db()).unwrap().1 =
        Some(DevinAuth { api_key: "cached".into(), api_server_url: None });
    assert_eq!(store.load_app_auth(&fixture.state_db()).unwrap().unwrap().api_key, "cached");
    std::thread::sleep(std::time::Duration::from_millis(5));
    fixture.write_app_auth(r#"{"apiKey":"second"}"#);
    assert_eq!(store.load_app_auth(&fixture.state_db()).unwrap().unwrap().api_key, "second");
}

// --- mapper -------------------------------------------------------------------------------

#[test]
fn maps_quota_lines_and_extra_usage_balance() {
    let mapped = map_user_status(&user_status("Max"), NOW).unwrap();
    assert_eq!(mapped.plan, "Max");
    let daily = progress(&mapped.lines, "Daily quota").unwrap();
    assert_eq!((daily.0, daily.3), (0.0, Some(parse::DAY_MS)));
    let weekly = progress(&mapped.lines, "Weekly quota").unwrap();
    assert_eq!((weekly.0, weekly.3), (60.0, Some(parse::WEEK_MS)));
    assert!(weekly.2.is_some());
    assert!((dollars(&mapped.lines, "Extra usage balance").unwrap() - 964.22).abs() < 1e-4);
}

#[test]
fn stale_reset_timestamps_are_dropped() {
    let mut status = user_status("Max");
    plan_status_mut(&mut status).insert("dailyQuotaResetAtUnix".into(), json!("0"));
    plan_status_mut(&mut status).insert("weeklyQuotaResetAtUnix".into(), json!("0"));
    let mapped = map_user_status(&status, NOW).unwrap();
    assert_eq!(progress(&mapped.lines, "Daily quota").unwrap().2, None);
    let weekly = progress(&mapped.lines, "Weekly quota").unwrap();
    assert_eq!((weekly.2, weekly.3), (None, Some(parse::WEEK_MS)));
}

#[test]
fn reset_beyond_horizon_is_dropped() {
    let mut status = user_status("Max");
    plan_status_mut(&mut status).insert("weeklyQuotaResetAtUnix".into(), json!(NOW * 1000.0));
    let mapped = map_user_status(&status, NOW).unwrap();
    assert_eq!(progress(&mapped.lines, "Weekly quota").unwrap().2, None);
}

#[test]
fn zero_overage_balance_reads_zero_dollars() {
    let mut status = user_status("Max");
    plan_status_mut(&mut status).insert("overageBalanceMicros".into(), json!("0"));
    let mapped = map_user_status(&status, NOW).unwrap();
    assert_eq!(dollars(&mapped.lines, "Extra usage balance"), Some(0.0));
}

#[test]
fn hidden_daily_quota_fills_absent_weekly_row() {
    let mut status = user_status("Max");
    let plan_status = plan_status_mut(&mut status);
    plan_status["planInfo"]["hideDailyQuota"] = json!(true);
    plan_status.insert("dailyQuotaRemainingPercent".into(), json!(30));
    plan_status.remove("weeklyQuotaRemainingPercent");
    plan_status.remove("weeklyQuotaResetAtUnix");
    let mapped = map_user_status(&status, NOW).unwrap();
    assert!(progress(&mapped.lines, "Daily quota").is_none());
    let weekly = progress(&mapped.lines, "Weekly quota").unwrap();
    assert_eq!((weekly.0, weekly.2), (70.0, None));
}

#[test]
fn valid_weekly_reset_with_absent_percentage_means_exhausted_window() {
    for hide in [true, false] {
        let mut status = user_status("Max");
        let plan_status = plan_status_mut(&mut status);
        plan_status["planInfo"]["hideDailyQuota"] = json!(hide);
        plan_status.insert("dailyQuotaRemainingPercent".into(), json!(100));
        plan_status.remove("weeklyQuotaRemainingPercent");
        let mapped = map_user_status(&status, NOW).unwrap();
        let weekly = progress(&mapped.lines, "Weekly quota").unwrap();
        assert_eq!(weekly, (100.0, 100.0, Some(1_774_166_400.0), Some(parse::WEEK_MS)), "hide={hide}");
        if hide {
            assert!(progress(&mapped.lines, "Daily quota").is_none());
        }
    }
}

#[test]
fn invalid_weekly_percentage_is_invalid_response() {
    for invalid in [json!("abc"), json!(true), Value::Null] {
        let mut status = user_status("Max");
        plan_status_mut(&mut status).insert("weeklyQuotaRemainingPercent".into(), invalid.clone());
        assert_eq!(map_user_status(&status, NOW), Err(UsageError::InvalidResponse), "{invalid}");
    }
}

#[test]
fn stale_weekly_reset_with_absent_percentage_uses_daily_fallback() {
    let mut status = user_status("Max");
    let plan_status = plan_status_mut(&mut status);
    plan_status["planInfo"]["hideDailyQuota"] = json!(true);
    plan_status.insert("dailyQuotaRemainingPercent".into(), json!(30));
    plan_status.remove("weeklyQuotaRemainingPercent");
    plan_status.insert("weeklyQuotaResetAtUnix".into(), json!(((NOW as i64) - 1).to_string()));
    let mapped = map_user_status(&status, NOW).unwrap();
    let weekly = progress(&mapped.lines, "Weekly quota").unwrap();
    assert_eq!((weekly.0, weekly.2), (70.0, None));
}

#[test]
fn no_displayable_fields_is_quota_unavailable() {
    let status = json!({ "planStatus": { "planInfo": { "planName": "Max" } } });
    assert_eq!(map_user_status(&status, NOW), Err(UsageError::QuotaUnavailable));
    assert_eq!(map_user_status_response(b"{\"unexpected\":true}", NOW), Err(UsageError::InvalidResponse));
}

#[test]
fn snapshot_serializes_like_swift() {
    let fixture = Fixture::new();
    fixture.write_app_auth(r#"{"apiKey":"devin-session-token$app"}"#);
    let http = MockClient::new(vec![MockClient::json(200, &body("Max"))]);
    let snapshot = fixture.provider(http).refresh(&ctx(NOW));
    let value = serde_json::to_value(&snapshot).unwrap();
    assert_eq!(value["providerID"], "devin");
    assert_eq!(value["displayName"], "Devin");
    assert_eq!(value["plan"], "Max");
    assert_eq!(value["lines"][0]["type"], "progress");
    assert_eq!(value["lines"][0]["label"], "Daily quota");
    assert_eq!(value["lines"][0]["format"]["kind"], "percent");
    assert_eq!(value["lines"][0]["periodDurationMs"], parse::DAY_MS);
    assert_eq!(value["lines"][2]["type"], "values");
    assert_eq!(value["lines"][2]["values"][0]["kind"], "dollars");
    assert_eq!(value["quotaRefreshedAt"], NOW);
    assert!(value.get("errorCategory").is_none());
}

// --- provider -----------------------------------------------------------------------------

#[test]
fn refresh_uses_credentials_file_before_app_state() {
    let fixture = Fixture::new();
    fixture.write_credentials("windsurf_api_key = \"devin-session-token$cli\"\napi_server_url = \"https://server.codeium.test\"");
    fixture.write_app_auth(r#"{"apiKey":"devin-session-token$app"}"#);
    let http = MockClient::new(vec![MockClient::json(200, &body("Max"))]);
    let snapshot = fixture.provider(http.clone()).refresh(&ctx(1_800_000_000.0));
    assert_eq!(snapshot.plan.as_deref(), Some("Max"));
    assert_eq!(snapshot.lines.len(), 3);
    let requests = http.requests.lock().unwrap();
    assert_eq!(requests.len(), 1);
    assert_eq!(
        requests[0].url,
        "https://server.codeium.test/exa.seat_management_pb.SeatManagementService/GetUserStatus"
    );
    assert!(requests[0].headers.contains(&("Connect-Protocol-Version".into(), "1".into())));
    let sent: Value = serde_json::from_slice(requests[0].body.as_ref().unwrap()).unwrap();
    assert_eq!(sent["metadata"]["apiKey"], "devin-session-token$cli");
    assert_eq!(sent["metadata"]["ideName"], "devin");
    assert_eq!(sent["metadata"]["extensionVersion"], CLOUD_COMPAT_VERSION);
}

#[test]
fn refresh_falls_back_to_app_state_after_expired_credentials() {
    let fixture = Fixture::new();
    fixture.write_credentials("windsurf_api_key = \"devin-session-token$cli\"\napi_server_url = \"https://server.codeium.test\"");
    fixture.write_app_auth(r#"{"apiKey":"devin-session-token$app"}"#);
    let http = MockClient::new(vec![MockClient::json(401, "{}"), MockClient::json(200, &body("Teams"))]);
    let snapshot = fixture.provider(http.clone()).refresh(&ctx(NOW));
    assert_eq!(snapshot.plan.as_deref(), Some("Teams"));
    let urls: Vec<String> = http.requests.lock().unwrap().iter().map(|r| r.url.clone()).collect();
    assert_eq!(
        urls,
        vec![
            "https://server.codeium.test/exa.seat_management_pb.SeatManagementService/GetUserStatus",
            "https://server.codeium.com/exa.seat_management_pb.SeatManagementService/GetUserStatus",
        ]
    );
}

#[test]
fn same_key_and_server_is_not_retried_from_another_source() {
    let fixture = Fixture::new();
    fixture.write_credentials("windsurf_api_key = \"same\"");
    fixture.write_app_auth(r#"{"apiKey":"same"}"#);
    let http = MockClient::new(vec![MockClient::json(401, "{}")]);
    let snapshot = fixture.provider(http.clone()).refresh(&ctx(NOW));
    assert_eq!(snapshot.error_category, Some(ErrorCategory::NotLoggedIn));
    assert_eq!(http.requests.lock().unwrap().len(), 1);
}

#[test]
fn cancellation_of_first_source_stops_before_app_auth_fallback() {
    let fixture = Fixture::new();
    fixture.write_credentials("windsurf_api_key = \"devin-session-token$cli\"\napi_server_url = \"https://server.codeium.test\"");
    fixture.write_app_auth(r#"{"apiKey":"devin-session-token$app"}"#);
    let http = MockClient::new(vec![Err(HttpError::Cancelled)]);
    let snapshot = fixture.provider(http.clone()).refresh(&ctx(NOW));
    assert_eq!(snapshot.error_category, Some(ErrorCategory::Cancelled));
    assert_eq!(http.requests.lock().unwrap().len(), 1);
}

#[test]
fn refresh_returns_login_hint_without_auth() {
    let fixture = Fixture::new();
    let provider = fixture.provider(MockClient::new(vec![]));
    assert!(!provider.has_local_credentials());
    let snapshot = provider.refresh(&ctx(NOW));
    assert_eq!(snapshot.lines[0].label(), "Error");
    assert_eq!(error_text(&snapshot).as_deref(), Some(NOT_LOGGED_IN));
    assert_eq!(snapshot.error_category, Some(ErrorCategory::NotLoggedIn));
}

#[test]
fn unreadable_credentials_file_keeps_provider_visible() {
    let fixture = Fixture::new();
    std::fs::create_dir_all(fixture.credentials()).unwrap();
    let http = MockClient::new(vec![]);
    let provider = fixture.provider(http.clone());
    assert!(provider.has_local_credentials());
    let snapshot = provider.refresh(&ctx(NOW));
    assert_eq!(snapshot.error_category, Some(ErrorCategory::CredentialAccess));
    assert_eq!(error_text(&snapshot).as_deref(), Some(CREDENTIALS_UNREADABLE));
    assert!(http.requests.lock().unwrap().is_empty());
}

#[test]
fn unreadable_app_database_keeps_provider_visible() {
    let fixture = Fixture::new();
    std::fs::create_dir_all(fixture.state_db().parent().unwrap()).unwrap();
    std::fs::write(fixture.state_db(), "garbage that is definitely not sqlite, padded out a little").unwrap();
    let http = MockClient::new(vec![]);
    let provider = fixture.provider(http.clone());
    assert!(provider.has_local_credentials());
    let snapshot = provider.refresh(&ctx(NOW));
    assert_eq!(snapshot.error_category, Some(ErrorCategory::CredentialAccess));
    assert!(http.requests.lock().unwrap().is_empty());
}

#[test]
fn server_error_reports_status_and_logs() {
    install_capture_host();
    diagnostic_gate::clear("devin.usage.http.503");
    let fixture = Fixture::new();
    fixture.write_app_auth(r#"{"apiKey":"devin-session-token$app"}"#);
    let snapshot = fixture.provider(MockClient::new(vec![MockClient::json(503, "{}")])).refresh(&ctx(NOW));
    assert_eq!(snapshot.error_category, Some(ErrorCategory::Http5xx));
    assert!(error_text(&snapshot).unwrap().contains("503"));
    assert!(captured_logs().iter().any(|l| l.contains("HTTP 503")));
}

#[test]
fn unreadable_response_is_a_decoding_problem_and_logs() {
    install_capture_host();
    diagnostic_gate::clear(INVALID_RESPONSE_KEY);
    let fixture = Fixture::new();
    fixture.write_app_auth(r#"{"apiKey":"devin-session-token$app"}"#);
    let http = MockClient::new(vec![MockClient::json(200, "{\"unexpected\":true}")]);
    let snapshot = fixture.provider(http).refresh(&ctx(NOW));
    assert_eq!(snapshot.error_category, Some(ErrorCategory::Decoding));
    assert_ne!(error_text(&snapshot).as_deref(), Some(QUOTA_UNAVAILABLE));
    assert!(captured_logs().iter().any(|l| l.contains("could not be read")));
}

#[test]
fn transport_failure_is_a_connection_problem_and_logs() {
    install_capture_host();
    diagnostic_gate::clear(TRANSPORT_FAILURE_KEY);
    let fixture = Fixture::new();
    fixture.write_app_auth(r#"{"apiKey":"devin-session-token$app"}"#);
    let http = MockClient::new(vec![Err(HttpError::Transport("Could not connect to the server.".into()))]);
    let snapshot = fixture.provider(http).refresh(&ctx(NOW));
    assert_eq!(snapshot.error_category, Some(ErrorCategory::Network));
    assert!(error_text(&snapshot).unwrap().contains("reach Devin"));
    assert!(captured_logs().iter().any(|l| l.contains("transport")));
}

#[test]
fn legacy_windsurf_state_is_used_when_devin_app_is_absent() {
    let fixture = Fixture::new();
    let windsurf = fixture.dir.path().join("Windsurf/User/globalStorage/state.vscdb");
    write_state_db(&windsurf, r#"{"apiKey":"windsurf-key"}"#);
    let store = DevinAuthStore::new(vec![fixture.credentials()], vec![fixture.state_db(), windsurf]);
    let http = MockClient::new(vec![MockClient::json(200, &body("Pro"))]);
    let provider = DevinProvider::new(store, http.clone());
    assert!(provider.has_local_credentials());
    assert_eq!(provider.refresh(&ctx(NOW)).plan.as_deref(), Some("Pro"));
    let sent: Value = serde_json::from_slice(http.requests.lock().unwrap()[0].body.as_ref().unwrap()).unwrap();
    assert_eq!(sent["metadata"]["apiKey"], "windsurf-key");
}

#[test]
fn explicit_key_never_falls_back_to_machine_credentials() {
    let fixture = Fixture::new();
    fixture.write_credentials("windsurf_api_key = \"devin-session-token$cli\"");
    fixture.write_app_auth(r#"{"apiKey":"devin-session-token$app"}"#);
    let http = MockClient::new(vec![MockClient::json(401, "{}")]);
    let provider = fixture.provider(http.clone());

    let mut context = RefreshContext::new(Scope::PanelMeters);
    context.now = NOW;
    let snapshot = provider.refresh_with_api_key(&context, Some("explicit"), None);
    assert_eq!(snapshot.error_category, Some(ErrorCategory::NotLoggedIn));
    {
        let requests = http.requests.lock().unwrap();
        assert_eq!(requests.len(), 1);
        let sent: Value = serde_json::from_slice(requests[0].body.as_ref().unwrap()).unwrap();
        assert_eq!(sent["metadata"]["apiKey"], "explicit");
    }

    let snapshot = provider.refresh_with_api_key(&context, Some("   "), None);
    assert_eq!(snapshot.error_category, Some(ErrorCategory::NotLoggedIn));
    assert_eq!(http.requests.lock().unwrap().len(), 1);
}
