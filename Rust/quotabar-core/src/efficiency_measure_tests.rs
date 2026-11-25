//! Opt-in measurement of the C ABI reply path with a large JSON payload.
//!
//! Run with:
//! `cargo test --release --test efficiency_measure -- --ignored --nocapture --test-threads=1`

use crate::engine_ffi::{qb_engine_call, qb_engine_string_free};
use std::alloc::{GlobalAlloc, Layout, System};
use std::ffi::{CStr, CString};
use std::hint::black_box;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Instant;

struct CountingAllocator;

static ALLOCATIONS: AtomicUsize = AtomicUsize::new(0);
static ALLOCATED_BYTES: AtomicUsize = AtomicUsize::new(0);

unsafe impl GlobalAlloc for CountingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
        ALLOCATED_BYTES.fetch_add(layout.size(), Ordering::Relaxed);
        System.alloc(layout)
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        System.dealloc(ptr, layout)
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
        ALLOCATED_BYTES.fetch_add(new_size, Ordering::Relaxed);
        System.realloc(ptr, layout, new_size)
    }
}

#[global_allocator]
static ALLOCATOR: CountingAllocator = CountingAllocator;

fn call(json: &str) -> String {
    let bytes = json.as_bytes();
    let reply = unsafe { qb_engine_call(bytes.as_ptr(), bytes.len()) };
    let text = unsafe { CStr::from_ptr(reply) }
        .to_string_lossy()
        .into_owned();
    unsafe { qb_engine_string_free(reply) };
    text
}

fn reset_allocations() {
    ALLOCATIONS.store(0, Ordering::SeqCst);
    ALLOCATED_BYTES.store(0, Ordering::SeqCst);
}

#[test]
#[ignore = "opt-in backend measurement"]
fn measure_large_c_abi_reply() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    let app_data = dir.path().join("appdata");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&app_data).unwrap();
    let configured = serde_json::json!({
        "method": "configure",
        "params": { "home": home, "appData": app_data }
    })
    .to_string();
    assert!(call(&configured).starts_with(r#"{"ok""#));

    let database = dir.path().join("large.db");
    let payload_bytes = std::env::var("QUOTABAR_BENCH_PAYLOAD_BYTES")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(8 * 1024 * 1024);
    let payload = "x".repeat(payload_bytes);
    let escaped = serde_json::to_string(&payload).unwrap();
    let create = serde_json::json!({
        "method": "sqliteExecute",
        "params": {
            "path": database,
            "sql": format!("CREATE TABLE payload (value TEXT); INSERT INTO payload VALUES ({escaped});")
        }
    })
    .to_string();
    let created = call(&create);
    assert!(created.starts_with(r#"{"ok""#), "{created}");

    let query = serde_json::json!({
        "method": "sqliteQuery",
        "params": { "path": database, "sql": "SELECT value FROM payload" }
    })
    .to_string();
    let iterations = std::env::var("QUOTABAR_BENCH_ITERATIONS")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(5);
    let mut wall_ms = Vec::new();
    let mut allocations = Vec::new();
    let mut allocated_bytes = Vec::new();
    let mut reply_bytes = 0;
    for _ in 0..iterations {
        reset_allocations();
        let started = Instant::now();
        let reply = call(&query);
        wall_ms.push(started.elapsed().as_secs_f64() * 1000.0);
        allocations.push(ALLOCATIONS.load(Ordering::SeqCst));
        allocated_bytes.push(ALLOCATED_BYTES.load(Ordering::SeqCst));
        reply_bytes = reply.len();
        assert!(reply.starts_with(r#"{"ok""#));
    }
    let average = |values: &[f64]| values.iter().sum::<f64>() / values.len() as f64;

    // The old boundary built a second `CString` from the reply string before handing it to C. JSON
    // cannot contain NUL, so that copy was pure overhead; measure what the direct pointer saves.
    let reply_text = call(&query);
    let mut legacy_wall_ms = Vec::new();
    let mut legacy_allocations = Vec::new();
    let mut legacy_bytes = Vec::new();
    for _ in 0..iterations {
        reset_allocations();
        let started = Instant::now();
        let copy = CString::new(reply_text.as_str()).unwrap();
        legacy_wall_ms.push(started.elapsed().as_secs_f64() * 1000.0);
        legacy_allocations.push(ALLOCATIONS.load(Ordering::SeqCst));
        legacy_bytes.push(ALLOCATED_BYTES.load(Ordering::SeqCst));
        black_box(copy);
    }
    println!(
        "BENCH c_abi_large_reply payload_bytes={} iterations={} avg_wall_ms={:.3} avg_allocations={:.1} avg_allocated_bytes={:.0} reply_bytes={} legacy_extra_copy_ms={:.3} legacy_extra_copy_allocations={:.1} legacy_extra_copy_bytes={:.0}",
        payload_bytes,
        iterations,
        average(&wall_ms),
        allocations.iter().sum::<usize>() as f64 / iterations as f64,
        allocated_bytes.iter().sum::<usize>() as f64 / iterations as f64,
        reply_bytes,
        average(&legacy_wall_ms),
        legacy_allocations.iter().sum::<usize>() as f64 / iterations as f64,
        legacy_bytes.iter().sum::<usize>() as f64 / iterations as f64,
    );
}
