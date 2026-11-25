//! Grok HTTP client (`cli-chat-proxy.grok.com` and `auth.x.ai`).

use crate::context::CancelToken;
use crate::http::{url_form_encode, HttpClient, HttpError, Request, Response};
use serde::Deserialize;
use std::time::Duration;

pub const CREDITS_CONFIG_URL: &str = "https://cli-chat-proxy.grok.com/v1/billing?format=credits";
pub const SETTINGS_URL: &str = "https://cli-chat-proxy.grok.com/v1/settings";
pub const REFRESH_URL: &str = "https://auth.x.ai/oauth2/token";
pub const TOKEN_AUTH_HEADER: &str = "xai-grok-cli";

const API_TIMEOUT: Duration = Duration::from_secs(10);
const REFRESH_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Clone, Debug, Deserialize)]
pub struct GrokRefreshResponse {
    pub access_token: String,
    #[serde(default)]
    pub refresh_token: Option<String>,
    #[serde(default)]
    pub id_token: Option<String>,
    #[serde(default)]
    pub expires_in: Option<f64>,
}

pub fn refresh_token(
    http: &dyn HttpClient,
    refresh_token: &str,
    client_id: &str,
    cancel: &CancelToken,
) -> Result<Response, HttpError> {
    let body = format!(
        "grant_type=refresh_token&client_id={}&refresh_token={}",
        url_form_encode(client_id),
        url_form_encode(refresh_token)
    );
    let req = Request::post_form(REFRESH_URL, body).timeout(REFRESH_TIMEOUT);
    http.send(&req, cancel)
}

pub fn fetch_credits_config(
    http: &dyn HttpClient,
    access_token: &str,
    cancel: &CancelToken,
) -> Result<Response, HttpError> {
    get_authed(http, CREDITS_CONFIG_URL, access_token, cancel)
}

pub fn fetch_settings(
    http: &dyn HttpClient,
    access_token: &str,
    cancel: &CancelToken,
) -> Result<Response, HttpError> {
    get_authed(http, SETTINGS_URL, access_token, cancel)
}

fn get_authed(
    http: &dyn HttpClient,
    url: &str,
    access_token: &str,
    cancel: &CancelToken,
) -> Result<Response, HttpError> {
    let trimmed = access_token.trim();
    let req = Request::get(url)
        .header("Authorization", format!("Bearer {trimmed}"))
        .header("X-XAI-Token-Auth", TOKEN_AUTH_HEADER)
        .header("Accept", "application/json")
        .timeout(API_TIMEOUT);
    http.send(&req, cancel)
}

pub fn decode_refresh_response(resp: &Response) -> Option<GrokRefreshResponse> {
    serde_json::from_slice(&resp.body).ok()
}
