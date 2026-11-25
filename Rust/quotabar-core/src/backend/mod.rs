//! JSON request/response boundary for provider backend work.
//!
//! Swift calls one C entry point (`qb_backend_call`) with a UTF-8 JSON request and receives a UTF-8
//! JSON response. The envelope is intentionally small and additive:
//!
//! ```json
//! {"op":"hermes.scan","params":{...}}
//! ```
//!
//! Success: `{"ok":true,"result":{...}}`. Failure: `{"ok":false,"error":{"kind":"...","message":"..."}}`.
//! A panic is caught at the FFI edge and reported as `kind:"internal"` so Swift can log it and fall
//! back to the Swift reference path for that refresh instead of crashing the app.

mod accounting;
mod claude_fold;
mod codex_fold;
mod codex_pricing;
mod hermes;
mod opencode;
mod pricing;
mod sqlite;
mod sqlite_sha3;

use serde_json::{json, Value};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;

/// A typed backend failure. `kind` is stable machine vocabulary; `message` is diagnostic detail.
#[derive(Debug)]
pub struct BackendError {
    pub kind: &'static str,
    pub message: String,
}

pub(crate) fn invalid_param(message: String) -> BackendError {
    BackendError {
        kind: "invalid_request",
        message,
    }
}

/// Heap-owned response the C caller frees with [`super::qb_backend_result_destroy`].
pub struct QbBackendResult {
    pub(crate) bytes: Vec<u8>,
}

impl QbBackendResult {
    fn from_value(value: &Value) -> Self {
        Self {
            bytes: serde_json::to_vec(value).unwrap_or_else(|_| {
                br#"{"ok":false,"error":{"kind":"internal","message":"response encoding failed"}}"#
                    .to_vec()
            }),
        }
    }
}

fn dispatch(request: &[u8], payload: &[u8]) -> QbBackendResult {
    let value: Value = match serde_json::from_slice(request) {
        Ok(value) => value,
        Err(error) => {
            return QbBackendResult::from_value(&json!({
                "ok": false,
                "error": { "kind": "invalid_request", "message": format!("invalid JSON: {error}") }
            }))
        }
    };

    let op = value.get("op").and_then(Value::as_str).unwrap_or_default();
    let params = value.get("params").cloned().unwrap_or(Value::Null);

    let outcome: Result<Value, BackendError> = match op {
        "hermes.scan" => hermes::scan(&params),
        "opencode.scan" => opencode::scan(&params),
        "opencode.schema" => opencode::schema(&params),
        "opencode.anchor" => opencode::anchor(&params),
        "opencode.query" => opencode::query(&params),
        "opencode.probe" => opencode::probe(&params),
        "sqlite.query" => sqlite::query(&params),
        "claude.fold" => claude_fold::fold(&params, payload),
        "codex.fold" => codex_fold::fold(&params, payload),
        "pricing.load" => pricing::load(&params),
        "pricing.release" => pricing::release(&params),
        "pricing.clear" => pricing::clear(&params),
        "pricing.resolve" => pricing::resolve_op(&params),
        _ => Err(BackendError {
            kind: "unknown_operation",
            message: format!("unknown backend operation `{op}`"),
        }),
    };

    match outcome {
        Ok(result) => QbBackendResult::from_value(&json!({ "ok": true, "result": result })),
        Err(error) => QbBackendResult::from_value(&json!({
            "ok": false,
            "error": { "kind": error.kind, "message": error.message }
        })),
    }
}

/// ABI version of the backend envelope. Bump when the request/response contract changes.
///
/// 3: pricing snapshot handles (`pricing.load` / `release` / `clear` / `resolve`) and the
///    `{scan, recheckModels}` fold result.
#[no_mangle]
pub extern "C" fn qb_backend_abi_version() -> u32 {
    3
}

/// Handle one backend request with no binary payload. Returns null only for a null pointer with a
/// nonzero length; every parse, dispatch, or panic failure is reported inside the JSON envelope.
#[no_mangle]
pub extern "C" fn qb_backend_call(request: *const u8, request_len: usize) -> *mut QbBackendResult {
    qb_backend_call_with_payload(request, request_len, ptr::null(), 0)
}

/// Handle one backend request plus an optional fixed-stride binary payload.
///
/// The payload carries the bulk entry data for a fold (one record per entry) so Swift does not have
/// to JSON-encode a whole history, and Rust can read it with fixed offsets. The JSON envelope keeps
/// the operation, calendar boundaries, and pricing table.
#[no_mangle]
pub extern "C" fn qb_backend_call_with_payload(
    request: *const u8,
    request_len: usize,
    payload: *const u8,
    payload_len: usize,
) -> *mut QbBackendResult {
    if (request.is_null() && request_len > 0) || (payload.is_null() && payload_len > 0) {
        return ptr::null_mut();
    }
    let request_bytes = if request.is_null() {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(request, request_len) }
    };
    let payload_bytes = if payload.is_null() {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(payload, payload_len) }
    };
    let result = catch_unwind(AssertUnwindSafe(|| dispatch(request_bytes, payload_bytes)))
        .unwrap_or_else(|_| {
            QbBackendResult::from_value(&json!({
                "ok": false,
                "error": { "kind": "internal", "message": "backend panicked" }
            }))
        });
    Box::into_raw(Box::new(result))
}

/// Pointer to the UTF-8 response bytes, valid until [`qb_backend_result_destroy`].
#[no_mangle]
pub extern "C" fn qb_backend_result_data(
    result: *const QbBackendResult,
    length: *mut usize,
) -> *const u8 {
    if result.is_null() {
        if !length.is_null() {
            unsafe { *length = 0 };
        }
        return ptr::null();
    }
    let result = unsafe { &*result };
    if !length.is_null() {
        unsafe { *length = result.bytes.len() };
    }
    result.bytes.as_ptr()
}

/// # Safety
/// `result` must be a pointer returned by [`qb_backend_call`], destroyed at most once.
#[no_mangle]
pub unsafe extern "C" fn qb_backend_result_destroy(result: *mut QbBackendResult) {
    if result.is_null() {
        return;
    }
    unsafe { drop(Box::from_raw(result)) };
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(request: &str) -> Value {
        let result = dispatch(request.as_bytes(), &[]);
        serde_json::from_slice(&result.bytes).expect("response JSON")
    }

    #[test]
    fn unknown_operation_is_a_typed_error() {
        let response = call(r#"{"op":"nope","params":{}}"#);
        assert_eq!(response["ok"], false);
        assert_eq!(response["error"]["kind"], "unknown_operation");
    }

    #[test]
    fn invalid_json_is_a_typed_error() {
        let response = call("not json");
        assert_eq!(response["ok"], false);
        assert_eq!(response["error"]["kind"], "invalid_request");
    }

    #[test]
    fn hermes_missing_params_are_rejected() {
        let response = call(r#"{"op":"hermes.scan","params":{}}"#);
        assert_eq!(response["ok"], false);
        assert_eq!(response["error"]["kind"], "invalid_request");
    }
}
