//! Drive the engine from a terminal, for differential checks against the app:
//!
//! ```sh
//! cargo run --release --example engine -- refresh devin          # one provider, pretty JSON
//! cargo run --release --example engine -- probe devin            # hasLocalCredentials
//! cargo run --release --example engine -- providers
//! QUOTABAR_LOG=debug cargo run --example engine -- refresh devin  # engine log lines on stderr
//! ```

use quotabar_engine::host::{set_host, LogLevel, StderrHost};
use quotabar_engine::Engine;
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::Instant;

fn main() {
    let level = match std::env::var("QUOTABAR_LOG").unwrap_or_default().as_str() {
        "debug" => LogLevel::Debug,
        "info" => LogLevel::Info,
        "error" => LogLevel::Error,
        _ => LogLevel::Warn,
    };
    set_host(Arc::new(StderrHost { level }));
    let args: Vec<String> = std::env::args().skip(1).collect();
    let request = match args.first().map(String::as_str) {
        Some("providers") => json!({ "method": "providers" }),
        Some("probe") if args.len() == 2 => json!({ "method": "hasLocalCredentials", "params": { "providerId": args[1] } }),
        Some("refresh") if args.len() >= 2 => json!({
            "method": "refresh",
            "params": { "providerId": args[1], "scope": args.get(2).map(String::as_str).unwrap_or("full") }
        }),
        _ => {
            eprintln!("usage: engine providers | probe <provider> | refresh <provider> [scope]");
            std::process::exit(2);
        }
    };
    let started = Instant::now();
    let reply: Value = serde_json::from_str(&Engine::global().call(&request.to_string())).expect("engine reply is JSON");
    eprintln!("({} ms)", started.elapsed().as_millis());
    println!("{}", serde_json::to_string_pretty(&reply).expect("reply serializes"));
    if reply.get("error").is_some() {
        std::process::exit(1);
    }
}
