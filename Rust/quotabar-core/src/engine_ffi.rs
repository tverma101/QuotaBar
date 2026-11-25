//! C ABI over `quotabar-engine` for the macOS app.
//!
//! The protocol is JSON (see `quotabar_engine::engine`), so adding a provider or a method never
//! changes this ABI. The host installs callbacks once for logging and secure credential reads.
//!
//! Ownership: every `char *` the engine returns is freed with [`qb_engine_string_free`]. A string the
//! host returns from `host_call` must be allocated with `malloc` (Swift: `strdup`); the engine frees
//! it with `free`.

use quotabar_engine::host::{
    self, Host, LogLevel, SecureReadOutcome, SecureReadRequest, SecureWriteOutcome, SecureWriteRequest,
};
use quotabar_engine::Engine;
use std::ffi::{c_char, c_void, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;

extern "C" {
    fn free(pointer: *mut c_void);
}

pub type QbLogCallback =
    extern "C" fn(context: *mut c_void, level: u32, tag: *const u8, tag_len: usize, message: *const u8, message_len: usize);

/// Host services the engine asks for, as JSON `{"method": ..., "params": ...}`:
///
/// - `secureRead` (params: `SecureReadRequest`, reply: `SecureReadOutcome`)
/// - `secureWrite` (params: `SecureWriteRequest`, reply: `SecureWriteOutcome`)
/// - `secureExists` (params: `{"service": ...}`, reply: bool or null)
/// - `env` (params: `{"name": ...}`, reply: string or null)
///
/// Returns a `malloc`ed, NUL-terminated JSON reply, or NULL when the host cannot answer.
pub type QbHostCallCallback = extern "C" fn(context: *mut c_void, request_json: *const u8, request_len: usize) -> *mut c_char;

pub type QbCallCompletion = extern "C" fn(context: *mut c_void, reply: *mut c_char);

#[repr(C)]
pub struct QbHostCallbacks {
    /// Opaque host pointer passed back to every callback; must stay valid for the process lifetime.
    pub context: *mut c_void,
    pub log: Option<QbLogCallback>,
    pub host_call: Option<QbHostCallCallback>,
    /// Initial log level (0 error, 1 warn, 2 info, 3 debug); change later with
    /// `qb_engine_set_log_level`.
    pub log_level: u32,
}

struct FfiHost {
    context: usize,
    log: Option<QbLogCallback>,
    host_call: Option<QbHostCallCallback>,
}

impl FfiHost {
    /// One JSON round trip to the host; `None` when the host has no handler or cannot answer.
    fn call(&self, method: &str, params: serde_json::Value) -> Option<serde_json::Value> {
        let host_call = self.host_call?;
        let request = serde_json::json!({ "method": method, "params": params }).to_string();
        let reply = host_call(self.context as *mut c_void, request.as_ptr(), request.len());
        if reply.is_null() {
            return None;
        }
        let text = unsafe { std::ffi::CStr::from_ptr(reply) }.to_string_lossy().into_owned();
        unsafe { free(reply.cast()) };
        serde_json::from_str(&text).ok()
    }
}

// The host guarantees its callbacks are thread-safe and `context` outlives the process.
unsafe impl Send for FfiHost {}
unsafe impl Sync for FfiHost {}

static LOG_LEVEL: AtomicU32 = AtomicU32::new(LogLevel::Warn as u32);

impl Host for FfiHost {
    fn log(&self, level: LogLevel, tag: &str, message: &str) {
        if let Some(log) = self.log {
            log(self.context as *mut c_void, level as u32, tag.as_ptr(), tag.len(), message.as_ptr(), message.len());
        }
    }

    fn log_level(&self) -> LogLevel {
        LogLevel::from_u32(LOG_LEVEL.load(Ordering::Relaxed))
    }

    fn secure_read(&self, request: &SecureReadRequest) -> SecureReadOutcome {
        let Ok(params) = serde_json::to_value(request) else {
            return SecureReadOutcome::Failed { message: "request encoding failed".into() };
        };
        match self.call("secureRead", params) {
            Some(reply) => serde_json::from_value(reply)
                .unwrap_or_else(|_| SecureReadOutcome::Failed { message: "host reply could not be decoded".into() }),
            None => SecureReadOutcome::Failed { message: "host has no credential store".into() },
        }
    }

    fn secure_write(&self, request: &SecureWriteRequest) -> SecureWriteOutcome {
        let Ok(params) = serde_json::to_value(request) else {
            return SecureWriteOutcome::Failed { message: "request encoding failed".into() };
        };
        match self.call("secureWrite", params) {
            Some(reply) => serde_json::from_value(reply)
                .unwrap_or_else(|_| SecureWriteOutcome::Failed { message: "host reply could not be decoded".into() }),
            None => SecureWriteOutcome::Failed { message: "host has no credential store".into() },
        }
    }

    fn secure_exists(&self, service: &str) -> Option<bool> {
        self.call("secureExists", serde_json::json!({ "service": service }))?.as_bool()
    }

    fn env_var(&self, name: &str) -> Option<String> {
        match self.call("env", serde_json::json!({ "name": name })) {
            Some(serde_json::Value::String(value)) if !value.is_empty() => Some(value),
            Some(_) => None,
            None => std::env::var(name).ok().filter(|v| !v.is_empty()),
        }
    }
}

/// Install the host callbacks. Call once at launch, before any `qb_engine_call`.
#[no_mangle]
pub extern "C" fn qb_engine_install_host(callbacks: QbHostCallbacks) {
    LOG_LEVEL.store(callbacks.log_level, Ordering::Relaxed);
    host::set_host(Arc::new(FfiHost {
        context: callbacks.context as usize,
        log: callbacks.log,
        host_call: callbacks.host_call,
    }));
}

#[no_mangle]
pub extern "C" fn qb_engine_set_log_level(level: u32) {
    LOG_LEVEL.store(level, Ordering::Relaxed);
}

fn call_guarded(request: &[u8]) -> String {
    match catch_unwind(AssertUnwindSafe(|| match std::str::from_utf8(request) {
        Ok(text) => Engine::global().call(text),
        Err(_) => r#"{"error":"request is not UTF-8"}"#.to_string(),
    })) {
        Ok(reply) => reply,
        Err(panic) => {
            let detail = panic
                .downcast_ref::<&str>()
                .map(|s| s.to_string())
                .or_else(|| panic.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "unknown panic".into());
            quotabar_engine::qlog!(Error, "engine", "engine call panicked: {detail}");
            serde_json::json!({ "error": format!("internal engine error: {detail}") }).to_string()
        }
    }
}

fn into_c_string(reply: String) -> *mut c_char {
    CString::new(reply.replace('\0', ""))
        .unwrap_or_else(|_| CString::new(r#"{"error":"reply encoding failed"}"#).unwrap())
        .into_raw()
}

/// Run one JSON request synchronously on the calling thread. Blocks for network and disk work; do
/// not call from a thread that must stay responsive. Free the reply with `qb_engine_string_free`.
///
/// # Safety
/// `request` must point to `request_len` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn qb_engine_call(request: *const u8, request_len: usize) -> *mut c_char {
    let bytes = if request.is_null() { &[][..] } else { std::slice::from_raw_parts(request, request_len) };
    into_c_string(call_guarded(bytes))
}

/// Run one JSON request on an engine-owned thread and deliver the reply to `completion` (on that
/// thread). The caller's thread never blocks. The completion owns the reply and frees it with
/// `qb_engine_string_free`.
///
/// # Safety
/// `request` must point to `request_len` readable bytes; `context` must stay valid until
/// `completion` runs.
#[no_mangle]
pub unsafe extern "C" fn qb_engine_call_async(
    request: *const u8,
    request_len: usize,
    context: *mut c_void,
    completion: QbCallCompletion,
) {
    let bytes = if request.is_null() { Vec::new() } else { std::slice::from_raw_parts(request, request_len).to_vec() };
    let context = context as usize;
    let spawned = std::thread::Builder::new().name("quotabar-engine".into()).spawn(move || {
        completion(context as *mut c_void, into_c_string(call_guarded(&bytes)));
    });
    if spawned.is_err() {
        completion(context as *mut c_void, into_c_string(r#"{"error":"engine thread could not start"}"#.to_string()));
    }
}

/// Cancel an in-flight request by the `requestId` it was started with. Returns 1 when it was in
/// flight (a not-yet-started request is still cancelled when it arrives).
#[no_mangle]
pub extern "C" fn qb_engine_cancel(request_id: u64) -> u8 {
    u8::from(Engine::global().cancel(request_id))
}

/// Free a string returned by the engine. Safe to call with NULL.
///
/// # Safety
/// `string` must be NULL or a pointer returned by this library that was not freed yet.
#[no_mangle]
pub unsafe extern "C" fn qb_engine_string_free(string: *mut c_char) {
    if !string.is_null() {
        drop(CString::from_raw(string));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sync_call_round_trips_and_frees() {
        let request = br#"{"method":"providers"}"#;
        let reply = unsafe { qb_engine_call(request.as_ptr(), request.len()) };
        let text = unsafe { std::ffi::CStr::from_ptr(reply) }.to_string_lossy().into_owned();
        unsafe { qb_engine_string_free(reply) };
        let value: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert!(value["ok"].as_array().unwrap().iter().any(|p| p["id"] == "devin"));
    }

    #[test]
    fn async_call_delivers_reply() {
        extern "C" fn done(context: *mut c_void, reply: *mut c_char) {
            let sender = unsafe { Box::from_raw(context as *mut std::sync::mpsc::Sender<String>) };
            let text = unsafe { std::ffi::CStr::from_ptr(reply) }.to_string_lossy().into_owned();
            unsafe { qb_engine_string_free(reply) };
            sender.send(text).unwrap();
        }
        let (tx, rx) = std::sync::mpsc::channel::<String>();
        let request = br#"{"method":"nope"}"#;
        unsafe {
            qb_engine_call_async(request.as_ptr(), request.len(), Box::into_raw(Box::new(tx)).cast(), done);
        }
        let reply = rx.recv_timeout(std::time::Duration::from_secs(5)).unwrap();
        assert_eq!(reply, r#"{"error":"unknown method: nope"}"#);
    }
}
