//! Cursor HTTP endpoints and session cookie builder (`CursorUsageClient.swift`).

use super::auth::token_subject;
use crate::context::CancelToken;
use crate::http::{url_form_encode, HttpClient, HttpError, Request, Response};
use serde_json::json;
use std::time::Duration;

pub const USAGE_URL: &str = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage";
pub const GROK_BOT_USAGE_URL: &str = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus";
pub const PLAN_URL: &str = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo";
pub const REFRESH_URL: &str = "https://api2.cursor.sh/oauth/token";
pub const CREDITS_URL: &str = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCreditGrantsBalance";
pub const REST_USAGE_URL: &str = "https://cursor.com/api/usage";
pub const USAGE_SUMMARY_URL: &str = "https://cursor.com/api/usage-summary";
pub const STRIPE_URL: &str = "https://cursor.com/api/auth/stripe";
pub const EXPORT_CSV_URL: &str = "https://cursor.com/api/dashboard/export-usage-events-csv";
pub const CLIENT_ID: &str = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB";

const STANDARD_TIMEOUT: Duration = Duration::from_secs(10);
const EXPORT_TIMEOUT: Duration = Duration::from_secs(20);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CursorWebSession {
    pub user_id: String,
    pub session_token: String,
}

pub fn session_from_access_token(access_token: &str) -> Option<CursorWebSession> {
    let subject = token_subject(access_token)?;
    let user_id = subject.rsplit('|').next().filter(|s| !s.is_empty())?;
    let encoded_user = url_form_encode(user_id);
    Some(CursorWebSession {
        user_id: user_id.to_string(),
        session_token: format!("{encoded_user}%3A%3A{access_token}"),
    })
}

pub fn refresh_token(http: &dyn HttpClient, refresh_token: &str, cancel: &CancelToken) -> Result<Response, HttpError> {
    let body = json!({
        "grant_type": "refresh_token",
        "client_id": CLIENT_ID,
        "refresh_token": refresh_token,
    });
    let req = Request::post_json(REFRESH_URL, &body).timeout(STANDARD_TIMEOUT);
    http.send(&req, cancel)
}

pub fn post_connect(http: &dyn HttpClient, url: &str, access_token: &str, cancel: &CancelToken) -> Result<Response, HttpError> {
    let req = Request::post_json(url, &json!({}))
        .header("Authorization", format!("Bearer {access_token}"))
        .header("Connect-Protocol-Version", "1")
        .timeout(STANDARD_TIMEOUT);
    http.send(&req, cancel)
}

pub fn get_with_session(http: &dyn HttpClient, url: &str, session: &CursorWebSession, accept: Option<&str>, timeout: Duration, cancel: &CancelToken) -> Result<Response, HttpError> {
    let mut req = Request::get(url)
        .header("Cookie", format!("WorkosCursorSessionToken={}", session.session_token))
        .timeout(timeout);
    if let Some(accept) = accept {
        req = req.header("Accept", accept);
    }
    http.send(&req, cancel)
}

pub fn fetch_usage(http: &dyn HttpClient, access_token: &str, cancel: &CancelToken) -> Result<Response, HttpError> {
    post_connect(http, USAGE_URL, access_token, cancel)
}

pub fn fetch_grok_bot_usage(http: &dyn HttpClient, access_token: &str, cancel: &CancelToken) -> Result<Response, HttpError> {
    post_connect(http, GROK_BOT_USAGE_URL, access_token, cancel)
}

pub fn fetch_plan(http: &dyn HttpClient, access_token: &str, cancel: &CancelToken) -> Result<Response, HttpError> {
    post_connect(http, PLAN_URL, access_token, cancel)
}

pub fn fetch_credits(http: &dyn HttpClient, access_token: &str, cancel: &CancelToken) -> Result<Response, HttpError> {
    post_connect(http, CREDITS_URL, access_token, cancel)
}

pub fn fetch_rest_usage(http: &dyn HttpClient, access_token: &str, cancel: &CancelToken) -> Result<Option<Response>, HttpError> {
    let Some(session) = session_from_access_token(access_token) else {
        return Ok(None);
    };
    let url = format!("{REST_USAGE_URL}?user={}", url_form_encode(&session.user_id));
    get_with_session(http, &url, &session, None, STANDARD_TIMEOUT, cancel).map(Some)
}

pub fn fetch_usage_summary(http: &dyn HttpClient, access_token: &str, cancel: &CancelToken) -> Result<Option<Response>, HttpError> {
    let Some(session) = session_from_access_token(access_token) else {
        return Ok(None);
    };
    get_with_session(http, USAGE_SUMMARY_URL, &session, None, STANDARD_TIMEOUT, cancel).map(Some)
}

pub fn fetch_stripe_balance(http: &dyn HttpClient, access_token: &str, cancel: &CancelToken) -> Result<Option<Response>, HttpError> {
    let Some(session) = session_from_access_token(access_token) else {
        return Ok(None);
    };
    get_with_session(http, STRIPE_URL, &session, None, STANDARD_TIMEOUT, cancel).map(Some)
}

pub fn fetch_usage_csv(
    http: &dyn HttpClient,
    access_token: &str,
    start_secs: f64,
    end_secs: f64,
    cancel: &CancelToken,
) -> Result<Option<Response>, HttpError> {
    let Some(session) = session_from_access_token(access_token) else {
        return Ok(None);
    };
    let start_ms = (start_secs * 1000.0).round() as i64;
    let end_ms = (end_secs * 1000.0).round() as i64;
    let url = format!("{EXPORT_CSV_URL}?startDate={start_ms}&endDate={end_ms}&strategy=tokens");
    get_with_session(http, &url, &session, Some("text/csv"), EXPORT_TIMEOUT, cancel).map(Some)
}
