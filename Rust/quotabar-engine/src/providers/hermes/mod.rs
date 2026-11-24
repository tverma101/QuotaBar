//! Hermes Agent local usage provider (`Providers/Hermes`).

pub mod mapper;
pub mod scanner;

#[cfg(test)]
mod tests;

use super::{cancelled_snapshot, ProviderRuntime};
use crate::context::RefreshContext;
use crate::model::{ErrorCategory, ProviderInfo, ProviderSnapshot};
use scanner::{HermesScanError, HermesUsageScanner};

pub const ID: &str = "hermes";
pub const NOT_DETECTED_MSG: &str = "Hermes not detected. Use Hermes (CLI or desktop) once, then refresh.";
pub const DATABASE_UNREADABLE_MSG: &str =
    "Couldn't read Hermes' state database. Quit Hermes and refresh, or check ~/.hermes permissions.";

pub struct HermesProvider {
    info: ProviderInfo,
    pub scanner: HermesUsageScanner,
}

impl HermesProvider {
    pub fn live() -> Self {
        HermesProvider {
            info: ProviderInfo { id: ID.into(), display_name: "Hermes".into() },
            scanner: HermesUsageScanner::live(),
        }
    }

    pub fn with_scanner(scanner: HermesUsageScanner) -> Self {
        HermesProvider {
            info: ProviderInfo { id: ID.into(), display_name: "Hermes".into() },
            scanner,
        }
    }
}

impl ProviderRuntime for HermesProvider {
    fn info(&self) -> &ProviderInfo {
        &self.info
    }

    fn has_local_credentials(&self) -> bool {
        self.scanner.effective_path().exists()
    }

    fn refresh(&self, ctx: &RefreshContext) -> ProviderSnapshot {
        let scan = match self.scanner.scan(ctx.now, &ctx.cancel) {
            Ok(Some(scan)) => scan,
            Ok(None) => return ProviderSnapshot::error(&self.info, NOT_DETECTED_MSG, ErrorCategory::NotLoggedIn, ctx.now),
            Err(HermesScanError::Cancelled) => return cancelled_snapshot(&self.info, ctx),
            Err(HermesScanError::DatabaseUnreadable(_)) => {
                return ProviderSnapshot::error(&self.info, DATABASE_UNREADABLE_MSG, ErrorCategory::CredentialAccess, ctx.now)
            }
        };
        let lines = mapper::lines(&scan, ctx.now, crate::accounting::DayZone::Local);
        let history = mapper::usage_history(&scan);
        ProviderSnapshot::new(&self.info, None, lines, ctx.now).with_usage_history(Some(history))
    }

    fn unload_caches(&self) {
        self.scanner.unload_caches();
    }
}
