//! Opt-in measurement of the engine's real batch and local-scan paths.
//!
//! Run with:
//! `cargo test --release --test efficiency_measure -- --ignored --nocapture --test-threads=1`
//!
//! Fixtures are synthetic temp files; provider credentials are absent so no network is used.

use quotabar_engine::context::Scope;
use quotabar_engine::engine::Engine;
use quotabar_engine::paths::{self, Paths};
use quotabar_engine::providers;
use quotabar_engine::providers::devin::sessions::DevinSessionUsageReader;
use serde_json::json;
use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Instant;

struct CountingAllocator;

static ALLOCATIONS: AtomicUsize = AtomicUsize::new(0);
static ALLOCATED_BYTES: AtomicUsize = AtomicUsize::new(0);
static LIVE_BYTES: AtomicUsize = AtomicUsize::new(0);

unsafe impl GlobalAlloc for CountingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let ptr = System.alloc(layout);
        if !ptr.is_null() {
            LIVE_BYTES.fetch_add(layout.size(), Ordering::Relaxed);
        }
        ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
        ALLOCATED_BYTES.fetch_add(layout.size(), Ordering::Relaxed);
        ptr
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        LIVE_BYTES.fetch_sub(layout.size(), Ordering::Relaxed);
        System.dealloc(ptr, layout)
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        let ptr = System.realloc(ptr, layout, new_size);
        if !ptr.is_null() {
            if new_size >= layout.size() {
                LIVE_BYTES.fetch_add(new_size - layout.size(), Ordering::Relaxed);
            } else {
                LIVE_BYTES.fetch_sub(layout.size() - new_size, Ordering::Relaxed);
            }
        }
        ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
        ALLOCATED_BYTES.fetch_add(new_size, Ordering::Relaxed);
        ptr
    }
}

#[global_allocator]
static ALLOCATOR: CountingAllocator = CountingAllocator;

fn reset_allocations() {
    ALLOCATIONS.store(0, Ordering::SeqCst);
    ALLOCATED_BYTES.store(0, Ordering::SeqCst);
}

fn allocations() -> (usize, usize) {
    (
        ALLOCATIONS.load(Ordering::SeqCst),
        ALLOCATED_BYTES.load(Ordering::SeqCst),
    )
}

struct Sample {
    wall_ms: f64,
    allocations: usize,
    allocated_bytes: usize,
    reply_bytes: usize,
}

fn sample(reply: String, started: Instant) -> Sample {
    let (allocations, allocated_bytes) = allocations();
    Sample {
        wall_ms: started.elapsed().as_secs_f64() * 1000.0,
        allocations,
        allocated_bytes,
        reply_bytes: reply.len(),
    }
}

fn configure_temp_engine(dir: &tempfile::TempDir) {
    paths::configure(Paths {
        home: dir.path().join("home"),
        app_data: dir.path().join("appdata"),
    });
    std::fs::create_dir_all(dir.path().join("home")).unwrap();
    std::fs::create_dir_all(dir.path().join("appdata")).unwrap();
}

fn opencode_row(index: usize) -> String {
    format!(
        r#"{{"role":"assistant","cost":0.001,"tokens":{{"total":150}},"model":{{"id":"gpt-5.5","providerID":"opencode-go"}},"index":{index}}}"#
    )
}

fn create_opencode_database(data_directory: &std::path::Path, rows: usize, now_ms: i64) {
    std::fs::create_dir_all(data_directory).unwrap();
    let connection = rusqlite::Connection::open(data_directory.join("opencode.db")).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE session_message (id TEXT PRIMARY KEY, type TEXT, time_created INTEGER, data TEXT);",
        )
        .unwrap();
    let transaction = connection.unchecked_transaction().unwrap();
    {
        let mut statement = transaction
            .prepare("INSERT INTO session_message VALUES (?1, 'assistant', ?2, ?3)")
            .unwrap();
        for index in 0..rows {
            let id = format!("m{index}");
            let timestamp = now_ms - (index as i64 % 10) * 1000;
            statement
                .execute(rusqlite::params![id, timestamp, opencode_row(index)])
                .unwrap();
        }
    }
    transaction.commit().unwrap();
}

fn batch_request(items: Vec<serde_json::Value>, now: f64, scope: &str) -> String {
    json!({
        "method": "refreshBatch",
        "params": {
            "scope": scope,
            "items": items,
            "skipModelCatalogRefresh": true,
            "now": now,
            "perProviderTimeoutSeconds": 30.0
        }
    })
    .to_string()
}

#[test]
#[ignore = "opt-in backend measurement"]
fn measure_opencode_cache_retention() {
    use quotabar_engine::context::CancelToken;
    use quotabar_engine::pricing::ModelPricing;
    use quotabar_engine::providers::opencode::scanner::{clear_database_cache, scan, FoldSources};
    use std::sync::Arc;

    const ROWS: usize = 100_000;
    let dir = tempfile::tempdir().unwrap();
    let now = 1_800_000_000.0;
    create_opencode_database(dir.path(), ROWS, (now * 1000.0) as i64 - 1_000);
    let paths = [dir.path().join("opencode.db")];
    let pricing = Arc::new(ModelPricing::default());
    let sources = FoldSources::default();
    let cancel = CancelToken::new();
    let run_scan = || {
        scan(&paths, 30, now, pricing.clone(), &sources, &cancel)
            .unwrap()
            .unwrap()
    };
    clear_database_cache();
    reset_allocations();
    let start = Instant::now();
    let cold = run_scan();
    let cold_ms = start.elapsed().as_secs_f64() * 1000.0;
    let (cold_allocations, cold_allocated_bytes) = allocations();
    let start = Instant::now();
    let warm = run_scan();
    let warm_ms = start.elapsed().as_secs_f64() * 1000.0;
    assert_eq!(cold, warm);
    assert_eq!(
        warm.log_scan
            .series
            .daily
            .iter()
            .map(|row| row.total_tokens)
            .sum::<i64>(),
        15_000_000
    );
    drop((cold, warm));
    let before = LIVE_BYTES.load(Ordering::Relaxed);
    clear_database_cache();
    let cache_bytes = before - LIVE_BYTES.load(Ordering::Relaxed);
    println!("BENCH opencode_cache_retention rows={ROWS} cache_bytes={cache_bytes} cold_ms={cold_ms:.2} warm_ms={warm_ms:.2} cold_allocations={cold_allocations} cold_allocated_bytes={cold_allocated_bytes}");
}

#[test]
#[ignore = "opt-in backend measurement"]
fn measure_warm_devin_session_reads() {
    const ROWS: usize = 30_000;
    const ITERATIONS: usize = 5;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("sessions.db");
    let mut connection = rusqlite::Connection::open(&path).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE message_nodes (
                row_id INTEGER PRIMARY KEY, session_id TEXT, created_at INTEGER, chat_message TEXT
            );
            CREATE INDEX idx_message_nodes_session ON message_nodes(session_id);",
        )
        .unwrap();
    let transaction = connection.transaction().unwrap();
    {
        let mut statement = transaction
            .prepare("INSERT INTO message_nodes VALUES (?1, 'session', 1781000000, ?2)")
            .unwrap();
        for id in 1..=ROWS {
            let message = json!({
                "role": "assistant",
                "metadata": {
                    "request_id": id.to_string(),
                    "created_at": "2026-06-10T10:00:00Z",
                    "generation_model": "swe-2-max",
                    "metrics": { "input_tokens": 10, "output_tokens": 1 }
                }
            });
            statement
                .execute(rusqlite::params![id, message.to_string()])
                .unwrap();
        }
    }
    transaction.commit().unwrap();
    drop(connection);

    let mut reader = DevinSessionUsageReader::new(Some(dir.path().join("cache")));
    assert_eq!(reader.entries(&path).unwrap().len(), ROWS);
    for copy_rows in [true, false] {
        reset_allocations();
        let started = Instant::now();
        for _ in 0..ITERATIONS {
            let rows = reader.entries(&path).unwrap();
            assert_eq!(rows.len(), ROWS);
            if copy_rows {
                std::hint::black_box(rows.to_vec());
            } else {
                std::hint::black_box(rows);
            }
        }
        let elapsed = started.elapsed();
        let (count, bytes) = allocations();
        println!(
            "BENCH devin_warm_session_reads rows={ROWS} iterations={ITERATIONS} copy_rows={copy_rows} wall_ms={:.2} allocations={count} allocated_bytes={bytes}",
            elapsed.as_secs_f64() * 1000.0,
        );
    }
}

#[test]
#[ignore = "opt-in backend measurement"]
fn measure_full_batch_and_opencode_scan() {
    let rows = std::env::var("QUOTABAR_BENCH_ROWS")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(100_000);
    let iterations = std::env::var("QUOTABAR_BENCH_ITERATIONS")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(5);

    let dir = tempfile::tempdir().unwrap();
    configure_temp_engine(&dir);
    let engine = Engine::new(providers::all());
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs_f64();
    let now_ms = (now * 1000.0) as i64;

    let all_ids: Vec<String> = engine
        .providers()
        .iter()
        .map(|provider| provider.info().id.clone())
        .collect();
    let all_items: Vec<_> = all_ids
        .iter()
        .map(|id| json!({ "providerId": id }))
        .collect();
    let all_request = batch_request(all_items.clone(), now, "full");
    let all_fold_request = batch_request(all_items, now, "localAccounting");

    reset_allocations();
    let started = Instant::now();
    let all_reply = engine.call(&all_request);
    let all = sample(all_reply, started);
    let mut all_warm = Vec::new();
    for _ in 0..iterations {
        reset_allocations();
        let started = Instant::now();
        let reply = engine.call(&all_request);
        all_warm.push(sample(reply, started));
    }
    let warm = |select: fn(&Sample) -> f64| {
        all_warm.iter().map(select).sum::<f64>() / all_warm.len().max(1) as f64
    };
    println!(
        "BENCH batch_all_providers scope=full providers={} cold_wall_ms={:.2} cold_allocations={} cold_allocated_bytes={} warm_wall_ms={:.2} warm_allocations={:.1} warm_allocated_bytes={:.0} reply_bytes={}",
        all_ids.len(),
        all.wall_ms,
        all.allocations,
        all.allocated_bytes,
        warm(|sample| sample.wall_ms),
        warm(|sample| sample.allocations as f64),
        warm(|sample| sample.allocated_bytes as f64),
        all.reply_bytes
    );

    let mut fold_warm = Vec::new();
    for _ in 0..iterations {
        reset_allocations();
        let started = Instant::now();
        let reply = engine.call(&all_fold_request);
        fold_warm.push(sample(reply, started));
    }
    println!(
        "BENCH batch_all_providers scope=localAccounting providers={} warm_wall_ms={:.2} warm_allocations={:.1} warm_allocated_bytes={:.0} reply_bytes={}",
        all_ids.len(),
        fold_warm.iter().map(|s| s.wall_ms).sum::<f64>() / fold_warm.len().max(1) as f64,
        fold_warm.iter().map(|s| s.allocations).sum::<usize>() as f64
            / fold_warm.len().max(1) as f64,
        fold_warm.iter().map(|s| s.allocated_bytes).sum::<usize>() as f64
            / fold_warm.len().max(1) as f64,
        fold_warm.first().map_or(0, |s| s.reply_bytes)
    );

    let data_directory = dir.path().join("opencode-data");
    create_opencode_database(&data_directory, rows, now_ms);
    let opencode_items = vec![json!({
        "providerId": "opencode",
        "config": {
            "dataDirectory": data_directory,
            "gatewayClaude": false,
            "gatewayCodex": false,
            "gatewayHermes": false,
            "gatewayMuse": false
        }
    })];
    let opencode_request = batch_request(opencode_items, now, "full");

    let mut cold_samples = Vec::new();
    let mut warm_samples = Vec::new();
    for _ in 0..iterations {
        // Clearing the parsed-row cache makes each even iteration behave like the pre-cache
        // implementation, which reparsed every row on every refresh.
        quotabar_engine::providers::opencode::scanner::clear_database_cache();
        reset_allocations();
        let started = Instant::now();
        let reply = engine.call(&opencode_request);
        cold_samples.push(sample(reply, started));
        reset_allocations();
        let started = Instant::now();
        let reply = engine.call(&opencode_request);
        warm_samples.push(sample(reply, started));
    }
    let average_ms = |samples: &[Sample]| {
        samples.iter().map(|s| s.wall_ms).sum::<f64>() / samples.len().max(1) as f64
    };
    let average_allocations = |samples: &[Sample]| {
        samples.iter().map(|s| s.allocations).sum::<usize>() / samples.len().max(1)
    };
    let average_bytes = |samples: &[Sample]| {
        samples.iter().map(|s| s.allocated_bytes).sum::<usize>() / samples.len().max(1)
    };
    println!(
        "BENCH opencode_scan rows={} cold_wall_ms={:.2} cold_allocations={} cold_allocated_bytes={} warm_wall_ms={:.2} warm_allocations={} warm_allocated_bytes={} reply_bytes={} scope={:?}",
        rows,
        average_ms(&cold_samples),
        average_allocations(&cold_samples),
        average_bytes(&cold_samples),
        average_ms(&warm_samples),
        average_allocations(&warm_samples),
        average_bytes(&warm_samples),
        warm_samples.first().map_or(0, |s| s.reply_bytes),
        Scope::Full
    );
}
