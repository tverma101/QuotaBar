//! GitHub Copilot provider (`Providers/Copilot`).

pub mod auth;
pub mod client;
pub mod mapper;
pub mod org;

#[cfg(test)]
mod tests;

use super::{cancelled_snapshot, ProviderRuntime};
use crate::context::RefreshContext;
use crate::http::{self, HttpClient, HttpError};
use crate::model::{ErrorCategory, ProviderInfo, ProviderSnapshot};
use auth::{
    CopilotAuthError, CopilotAuthStore, ACCESS_DENIED_MSG, ID, NOT_LOGGED_IN_MSG, TOKEN_INVALID_MSG,
};
use mapper::CopilotUsageError;
use org::{FileOrgStateStore, OrgStateStore};
use std::sync::Arc;

pub struct CopilotProvider {
    info: ProviderInfo,
    pub auth: Option<CopilotAuthStore>,
    http: Arc<dyn HttpClient>,
    org_store: Arc<dyn OrgStateStore>,
}

impl CopilotProvider {
    pub fn live() -> Self {
        CopilotProvider {
            info: ProviderInfo {
                id: ID.into(),
                display_name: "Copilot".into(),
            },
            auth: None,
            http: http::shared(),
            org_store: Arc::new(FileOrgStateStore::live()),
        }
    }

    pub fn new(
        auth: CopilotAuthStore,
        http: Arc<dyn HttpClient>,
        org_store: Arc<dyn OrgStateStore>,
    ) -> Self {
        CopilotProvider {
            info: ProviderInfo {
                id: ID.into(),
                display_name: "Copilot".into(),
            },
            auth: Some(auth),
            http,
            org_store,
        }
    }

    fn effective_auth(&self) -> CopilotAuthStore {
        self.auth.clone().unwrap_or_else(CopilotAuthStore::live)
    }
}

impl ProviderRuntime for CopilotProvider {
    fn info(&self) -> &ProviderInfo {
        &self.info
    }

    fn has_local_credentials(&self) -> bool {
        match self.effective_auth().load_token(None) {
            Ok(Some(_)) => true,
            Ok(None) | Err(CopilotAuthError::Cancelled) => false,
            Err(
                CopilotAuthError::CredentialPermissionRequired
                | CopilotAuthError::CredentialsUnreadable
                | CopilotAuthError::InvalidCredentials,
            ) => true,
            Err(CopilotAuthError::NotLoggedIn) => false,
        }
    }

    fn refresh(&self, ctx: &RefreshContext) -> ProviderSnapshot {
        let token = match self.effective_auth().load_token(Some(ctx)) {
            Ok(Some(token)) => token,
            Ok(None) => {
                return ProviderSnapshot::error(
                    &self.info,
                    NOT_LOGGED_IN_MSG,
                    ErrorCategory::NotLoggedIn,
                    ctx.now,
                )
            }
            Err(CopilotAuthError::Cancelled) => return cancelled_snapshot(&self.info, ctx),
            Err(err) => {
                return ProviderSnapshot::error(&self.info, err.message(), err.category(), ctx.now)
            }
        };
        if ctx.is_cancelled() {
            return cancelled_snapshot(&self.info, ctx);
        }

        let resp = match client::fetch_usage(self.http.as_ref(), &token, &ctx.cancel) {
            Ok(resp) => resp,
            Err(HttpError::Cancelled) => return cancelled_snapshot(&self.info, ctx),
            Err(_) => {
                let err = CopilotUsageError::ConnectionFailed;
                return ProviderSnapshot::error(
                    &self.info,
                    &err.message(),
                    err.category(),
                    ctx.now,
                );
            }
        };
        if ctx.is_cancelled() {
            return cancelled_snapshot(&self.info, ctx);
        }
        if resp.status == 401 {
            return ProviderSnapshot::error(
                &self.info,
                TOKEN_INVALID_MSG,
                ErrorCategory::AuthExpired,
                ctx.now,
            );
        }
        if resp.status == 403 {
            return ProviderSnapshot::error(
                &self.info,
                ACCESS_DENIED_MSG,
                ErrorCategory::http(403),
                ctx.now,
            );
        }
        if !resp.is_success() {
            let err = CopilotUsageError::RequestFailed(resp.status);
            return ProviderSnapshot::error(&self.info, &err.message(), err.category(), ctx.now);
        }

        let mut mapped = match mapper::map_user_response(&resp.body) {
            Ok(mapped) => mapped,
            Err(err) => {
                return ProviderSnapshot::error(&self.info, &err.message(), err.category(), ctx.now)
            }
        };
        if mapped.is_org_managed_seat {
            match org::org_billing_lines(self.http.as_ref(), self.org_store.as_ref(), &token, ctx) {
                Ok(org_lines) => mapped.lines.extend(org_lines),
                Err(()) => return cancelled_snapshot(&self.info, ctx),
            }
        }
        ProviderSnapshot::new(&self.info, mapped.plan, mapped.lines, ctx.now)
    }

    fn unload_caches(&self) {
        self.org_store.clear_cache();
    }
}
