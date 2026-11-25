//! The hosted-detail request seam (Swift `FreebuffUsageClient`, minus the live session).
//!
//! **Privacy boundary.** Tracked code never performs Freebuff's live-session request. The macOS
//! shell's private adapter does that itself and hands the response to the engine
//! (`liveSessionResponse`, see `session.rs`). The two *hosted-detail* operations — the model
//! catalogue and the chat/run/event history — need a transport too; this module defines the trait
//! such a transport implements but ships none. With no transport registered
//! ([`set_hosted_transport`] is never called by tracked code) `supports_hosted_detail` is false and
//! every hosted request fails with `liveAccessUnavailable`, exactly like Swift's public build where
//! `FreebuffUsageClient.transport == nil`.

use super::auth::FreebuffAuth;
use super::error::FreebuffError;
use crate::context::CancelToken;
use crate::http::Response;
use std::sync::{Arc, RwLock};

/// Swift `FreebuffUsageClient.Operation` without the `session` case (never expressed in tracked code).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Operation {
    ModelCatalog,
    History { path: String, cursor: Option<String> },
}

/// Why a transport call produced no response.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TransportError {
    Cancelled,
    Failed,
}

pub trait HostedTransport: Send + Sync {
    fn fetch(&self, operation: &Operation, auth: &FreebuffAuth, cancel: &CancelToken)
        -> Result<Response, TransportError>;
}

fn slot() -> &'static RwLock<Option<Arc<dyn HostedTransport>>> {
    static SLOT: RwLock<Option<Arc<dyn HostedTransport>>> = RwLock::new(None);
    &SLOT
}

/// Registers the process-wide hosted-detail transport. Only a private build calls this.
pub fn set_hosted_transport(transport: Option<Arc<dyn HostedTransport>>) {
    *slot().write().unwrap_or_else(|e| e.into_inner()) = transport;
}

pub fn hosted_transport() -> Option<Arc<dyn HostedTransport>> {
    slot().read().unwrap_or_else(|e| e.into_inner()).clone()
}

/// Swift `FreebuffUsageClient` for the hosted operations. `supports_hosted_detail` mirrors
/// `transport != nil && supportsHostedDetail`.
#[derive(Clone)]
pub struct HostedClient {
    transport: Option<Arc<dyn HostedTransport>>,
    pub supports_hosted_detail: bool,
}

impl HostedClient {
    pub fn new(transport: Option<Arc<dyn HostedTransport>>, supports_hosted_detail: bool) -> Self {
        let supports_hosted_detail = transport.is_some() && supports_hosted_detail;
        HostedClient { transport, supports_hosted_detail }
    }

    /// No transport: the public build.
    pub fn offline() -> Self {
        HostedClient::new(None, false)
    }

    /// The registered transport, if any.
    pub fn registered() -> Self {
        HostedClient::new(hosted_transport(), true)
    }

    pub fn fetch_model_catalog(&self, auth: &FreebuffAuth, cancel: &CancelToken) -> Result<Response, FreebuffError> {
        if !self.supports_hosted_detail {
            return Err(FreebuffError::LiveAccessUnavailable);
        }
        self.fetch(&Operation::ModelCatalog, auth, cancel)
    }

    pub fn fetch_history(
        &self,
        path: &str,
        cursor: Option<&str>,
        auth: &FreebuffAuth,
        cancel: &CancelToken,
    ) -> Result<Response, FreebuffError> {
        if !self.supports_hosted_detail {
            return Err(FreebuffError::LiveAccessUnavailable);
        }
        self.fetch(&Operation::History { path: path.to_string(), cursor: cursor.map(str::to_string) }, auth, cancel)
    }

    fn fetch(&self, operation: &Operation, auth: &FreebuffAuth, cancel: &CancelToken) -> Result<Response, FreebuffError> {
        let Some(transport) = &self.transport else { return Err(FreebuffError::LiveAccessUnavailable) };
        match transport.fetch(operation, auth, cancel) {
            Ok(response) => Ok(response),
            Err(TransportError::Cancelled) => Err(FreebuffError::Cancelled),
            Err(TransportError::Failed) if cancel.is_cancelled() => Err(FreebuffError::Cancelled),
            Err(TransportError::Failed) => Err(FreebuffError::ConnectionFailed),
        }
    }
}
