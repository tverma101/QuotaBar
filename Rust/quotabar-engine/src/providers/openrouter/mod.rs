//! OpenRouter quota and credit balance provider (`Providers/OpenRouter`).

pub mod auth;
pub mod mapper;

#[cfg(test)]
mod tests;

use super::api_key::ApiKeySpec;
use super::{cancelled_snapshot, ProviderRuntime};
use crate::context::RefreshContext;
use crate::http::{self, HttpClient, HttpError, Request};
use crate::model::{ErrorCategory, ProviderInfo, ProviderSnapshot};
use serde_json::{Map, Value};
use std::sync::Arc;
use std::time::Duration;

pub const ID: &str = "openrouter";
pub const CREDITS_URL: &str = "https://openrouter.ai/api/v1/credits";
pub const KEY_URL: &str = "https://openrouter.ai/api/v1/key";

const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);

enum EndpointResult {
    Success(Map<String, Value>),
    AuthFailure,
    Failed(String, ErrorCategory),
}

impl EndpointResult {
    fn is_auth_failure(&self) -> bool {
        matches!(self, EndpointResult::AuthFailure)
    }

    fn failure(self) -> Option<(String, ErrorCategory)> {
        match self {
            EndpointResult::Failed(msg, cat) => Some((msg, cat)),
            _ => None,
        }
    }
}

pub struct OpenRouterProvider {
    info: ProviderInfo,
    spec: Option<ApiKeySpec>,
    http: Arc<dyn HttpClient>,
}

impl OpenRouterProvider {
    pub fn live() -> Self {
        OpenRouterProvider {
            info: ProviderInfo {
                id: ID.into(),
                display_name: "OpenRouter".into(),
            },
            spec: None,
            http: http::shared(),
        }
    }

    pub fn new(spec: ApiKeySpec, http: Arc<dyn HttpClient>) -> Self {
        OpenRouterProvider {
            info: ProviderInfo {
                id: ID.into(),
                display_name: "OpenRouter".into(),
            },
            spec: Some(spec),
            http,
        }
    }

    fn effective_spec(&self) -> ApiKeySpec {
        self.spec.clone().unwrap_or_else(auth::live_spec)
    }

    fn load_endpoint(
        &self,
        url: &str,
        api_key: &str,
        ctx: &RefreshContext,
    ) -> Result<EndpointResult, ()> {
        if ctx.is_cancelled() {
            return Err(());
        }
        let req = Request::get(url)
            .header("Authorization", format!("Bearer {api_key}"))
            .header("Accept", "application/json")
            .timeout(REQUEST_TIMEOUT);
        let resp = match self.http.send(&req, &ctx.cancel) {
            Ok(resp) => resp,
            Err(HttpError::Cancelled) => return Err(()),
            Err(_) => {
                return Ok(EndpointResult::Failed(
                    "Couldn't reach OpenRouter. Check your connection.".into(),
                    ErrorCategory::Network,
                ))
            }
        };
        if ctx.is_cancelled() {
            return Err(());
        }
        if resp.status == 401 || resp.status == 403 {
            return Ok(EndpointResult::AuthFailure);
        }
        if !resp.is_success() {
            return Ok(EndpointResult::Failed(
                format!("OpenRouter request failed (HTTP {}).", resp.status),
                ErrorCategory::http(resp.status),
            ));
        }
        let Some(data) = mapper::data_object(&resp.body) else {
            return Ok(EndpointResult::Failed(
                "OpenRouter usage data unavailable. Try again later.".into(),
                ErrorCategory::Decoding,
            ));
        };
        Ok(EndpointResult::Success(data))
    }
}

impl ProviderRuntime for OpenRouterProvider {
    fn info(&self) -> &ProviderInfo {
        &self.info
    }

    fn has_local_credentials(&self) -> bool {
        self.effective_spec().has_key_or_unreadable_config()
    }

    fn refresh(&self, ctx: &RefreshContext) -> ProviderSnapshot {
        let spec = self.effective_spec();
        let api_key = match auth::load_for_refresh(&spec) {
            Ok(key) => key,
            Err((msg, category)) => {
                return ProviderSnapshot::error(&self.info, msg, category, ctx.now)
            }
        };

        let Ok(credits) = self.load_endpoint(CREDITS_URL, &api_key, ctx) else {
            return cancelled_snapshot(&self.info, ctx);
        };
        let Ok(key_res) = self.load_endpoint(KEY_URL, &api_key, ctx) else {
            return cancelled_snapshot(&self.info, ctx);
        };

        let mut lines = Vec::new();
        let mut plan = None;
        if let EndpointResult::Success(ref data) = credits {
            lines.extend(mapper::credits_lines(data));
        }
        if let EndpointResult::Success(ref data) = key_res {
            let (mapped_plan, key_lines) = mapper::key_metrics(data);
            plan = mapped_plan;
            lines.extend(key_lines);
        }

        if !lines.is_empty() {
            return ProviderSnapshot::new(&self.info, plan, lines, ctx.now);
        }
        if credits.is_auth_failure() && key_res.is_auth_failure() {
            return ProviderSnapshot::error(
                &self.info,
                auth::INVALID_KEY_ERROR,
                ErrorCategory::AuthInvalid,
                ctx.now,
            );
        }
        let (msg, category) = credits
            .failure()
            .or_else(|| key_res.failure())
            .unwrap_or_else(|| {
                (
                    "OpenRouter usage data unavailable. Try again later.".into(),
                    ErrorCategory::Decoding,
                )
            });
        ProviderSnapshot::error(&self.info, &msg, category, ctx.now)
    }
}
