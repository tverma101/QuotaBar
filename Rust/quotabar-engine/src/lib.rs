//! QuotaBar's cross-platform backend.
//!
//! Everything except drawing lives here: reading credentials already on the machine, calling
//! provider APIs, scanning local usage logs and databases, pricing, caches. The macOS app links it
//! through the C ABI in `Rust/quotabar-core` and renders the `ProviderSnapshot` JSON it returns; the
//! Windows app depends on this crate directly.

pub mod accounting;
pub mod context;
pub mod engine;
pub mod host;
pub mod http;
pub mod model;
pub mod parse;
pub mod paths;
pub mod pricing;
pub mod providers;
pub mod redact;
pub mod scan;
pub mod sqlite;
pub mod sqlite_sha3;
pub mod time;

pub use engine::Engine;

#[cfg(test)]
pub(crate) mod test_support {
    use crate::host::{set_host, Host, LogLevel, SecureReadOutcome, SecureReadRequest};
    use std::sync::{Arc, Mutex, Once, OnceLock};

    fn logs() -> &'static Mutex<Vec<String>> {
        static LOGS: OnceLock<Mutex<Vec<String>>> = OnceLock::new();
        LOGS.get_or_init(|| Mutex::new(Vec::new()))
    }

    struct CaptureHost;

    impl Host for CaptureHost {
        fn log(&self, _level: LogLevel, tag: &str, message: &str) {
            logs().lock().unwrap().push(format!("[{tag}] {message}"));
        }
        fn log_level(&self) -> LogLevel {
            LogLevel::Debug
        }
        fn secure_read(&self, _request: &SecureReadRequest) -> SecureReadOutcome {
            SecureReadOutcome::NotFound
        }
    }

    /// Route every engine log line into an in-memory list shared by all tests in this binary.
    pub fn install_capture_host() {
        static ONCE: Once = Once::new();
        ONCE.call_once(|| set_host(Arc::new(CaptureHost)));
    }

    pub fn captured_logs() -> Vec<String> {
        logs().lock().unwrap().clone()
    }
}
