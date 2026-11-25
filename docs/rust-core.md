# Rust core

QuotaBar is a SwiftUI menu-bar app with a Rust backend. The Swift layer owns the AppKit bridge,
SwiftUI views, and the observable stores that drive them. Every provider refresh — authentication,
HTTP clients, local scanners, accounting, pricing, and mapping — runs in Rust and reaches the app
over a C ABI. A few platform workflows remain in Swift (launch-time account discovery, the
Keychain/environment host shim, and telemetry); they are listed below.

## The two crates

- `Rust/quotabar-core/` — the macOS static library (`staticlib` + `rlib`). It exposes the C ABI in
  `Sources/CQuotabarCore/include/quotabar_core.h` and depends on `quotabar-engine`. It also keeps the
  line parsers and compact pricing-catalog codec that Swift still calls directly.
- `Rust/quotabar-engine/` — the cross-platform backend (`rlib`). It is linked into the macOS archive
  through `quotabar-core` and is a normal dependency of the Windows app. It contains provider
  runtimes, the in-process SQLite reader, the incremental JSONL scanner, pricing, and the accounting
  fold.

`Sources/CQuotabarCore/` is a clang target whose header declares the ABI; the `.c` shim is a link
probe. `Sources/QuotaBar/Engine/RustEngine.swift` is the Swift client, and
`Sources/QuotaBar/Engine/RustEngineHost.swift` supplies platform services the engine cannot own:
Keychain reads/writes, environment values, and log forwarding.

## The boundary

Requests and replies are JSON:

```json
{"method":"refresh","params":{"providerId":"cursor","scope":"full","requestId":42}}
{"ok":{"providerID":"cursor","displayName":"Cursor","lines":[...],"refreshedAt":...}}
```

Asynchronous calls run on an engine-owned thread (`qb_engine_call_async`), so a slow network or disk
read never blocks Swift concurrency. Cancelling the Swift task cancels the engine request by ID. A
few synchronous calls remain — credential status and in-process SQLite — and return immediately or
run on a scanner's background actor; none performs network I/O. The reply's snapshot JSON is
byte-compatible with the Swift `ProviderSnapshot` / `MetricLine` `Codable` shape, so the UI decodes
it with the same models it already renders.

The host callbacks let the engine read Keychain items through the app's signed identity (keeping
"Always Allow" grants and the manual-refresh interaction budget intact) and ask for environment
values captured from the login shell. A provider never shells out to `security`, `sqlite3`, or `zstd`.

## What runs in Rust

Engine-backed providers — credentials, API calls, mapping, and their local history:

- Antigravity, Claude, Codex, Copilot, Cursor, Devin, Freebuff, Grok, Hermes, OpenCode, OpenRouter,
  and Z.ai. `ProviderCatalog` constructs these thin Swift wrappers; their former Swift
  implementations remain only as test oracles.
- Codex folds native rollout logs, FCC's SQLite proxy ledger, CodexRouter's JSONL ledger, and pi
  usage in the engine, including account fingerprints, pool aliases, status filtering, cross-source
  model identity, and the per-day merge. The account-scoped merge prefers Router metering and keeps
  native logs/proxy rows as gap fillers; the default card keeps logs → FCC → Router ordering.
- Codex reset-credit reads and claims (credential candidate selection and Keychain fallback, the
  credit-list GET, the idempotent consume POST, expiry matching, replay, and outcome parsing) run in
  `providers/codex/reset_claim.rs` behind cancellable `codexResetCredits` / `codexResetClaim`
  methods. Swift keeps only the popover's orchestration and the state it renders.
- OpenCode's gateway history folds from the engine's OpenCode, Codex Router, Claude, and Muse scan
  sources through the batch path; the Swift scanner survives as a test oracle.
- Muse and pi local scanners are engine modules: pi folds into the Claude and Codex histories, and
  Muse folds into OpenCode's gateway history. Neither has a standalone provider wrapper.

Shared engine infrastructure:

- In-process SQLite (read-only, query time limits, WAL recovery) replacing the per-query
  `/usr/bin/sqlite3` subprocess.
- In-process zstd decoding for compressed Codex archives.
- Model pricing catalogs, resolution, and spend imputation.
- Accounting folds, spend tiles, day buckets, and presentation rows.
- The engine's `refreshBatch` is the production local/accounting fold path; the Swift scan-worker
  child remains as a test seam and as a benign fallback when the engine rejects a batch.

Still Swift: launch-time account and identity discovery (`ProviderAccountAssembly`,
Cursor/Antigravity identity caching, OpenCode account inventory), the Keychain/environment host
callbacks in `RustEngineHost`, the popover orchestration around Codex reset credits, and telemetry.
Those are platform workflows around the engine, not provider refreshes: no provider refresh or
provider-API write executes in Swift, and the Swift reference providers are test-only oracles.

## The parser fallback contract

The Claude and Codex line parsers are also exposed as direct C functions. The bridge may return
nil, and production then runs the Swift reference path, **never a different answer**:

- a timestamp that is a string but is not one of the canonical UTC shapes this module accepts,
- a line with more than 64 entries (parent + advisor iterations, Claude only),
- any internal failure (a panic is caught at the FFI boundary and reported as "fall back").

For Codex the scope is **one whole file, not one line**: the engine is stateful across the file's
lines, so a line it cannot emulate makes the entire file re-parse with the Swift engine. Lines the
parser skips as damaged are counted exactly like the Swift parser's `damagedLineCount`.

Everything else — invalid JSON, non-object JSON, malformed tokens, advisor iterations, SemVer
rules, leap-second calendar math — is implemented identically in both paths and pinned by the parity
suites in `Tests/QuotaBarTests/ClaudeUsageLineRustParserTests.swift` and
`Tests/QuotaBarTests/CodexRolloutRustParserTests.swift`.

## Building

`script/build_rust_core.sh` builds `quotabar-core` (and therefore `quotabar-engine`) with `--locked`
and copies `libquotabar_core.a` to `Rust/quotabar-core/target/release/`. It is called automatically
by `script/build_and_run.sh`, `script/test_suites.sh`, and CI. A plain `swift build` or `swift test`
requires the archive to exist first.

`QUOTABAR_RUST_UNIVERSAL=1` builds arm64 + x86_64 and lipo-combines them. `QUOTABAR_RUST_TARGET`
builds a specific triple for cross-compilation checks.

The macOS target uses the system TLS stack (Security.framework) and links Security,
SystemConfiguration, CoreFoundation, and iconv, as declared in `Package.swift`.

## Testing

```sh
cargo test --release --manifest-path Rust/quotabar-engine/Cargo.toml
cargo test --release --manifest-path Rust/quotabar-core/Cargo.toml
swift test --filter RustEngineBridgeTests
```

The Rust suites cover provider behavior and the engine's parsers/scanners. The Swift bridge suite
pins the JSON contract and the C ABI round trip. Each engine-backed provider keeps a
`…SwiftReferenceProvider` oracle that its Swift unit tests drive; production constructs only the
engine-backed providers in `ProviderCatalog`, so there is never a second live path. Do not update an
oracle to "fix" a production bug — change the engine and its Rust test instead.

## Measuring

```sh
script/measure_backend_efficiency.sh
```

prints the refresh hot path, end to end:

- `BENCH batch_all_providers` — all providers through `refreshBatch`, cold and warm, with total
  allocations and allocated bytes from a counting allocator. The `localAccounting` line is the
  fold-only accounting pass.
- `BENCH opencode_scan` — a synthetic 100k-row OpenCode SQLite database, cold (cache cleared) and
  warm, so the parsed-row cache's effect is visible.
- `BENCH c_abi_large_reply` — an 8 MiB SQLite reply through the C ABI, plus the extra copy the old
  boundary paid.
- `SWIFT_BENCH fold_refresh` — the same fold batch through the Swift bridge on the signed-in
  profile's own local history: wall time per refresh, snapshot decode and request encode time,
  main-actor ticks during the call (the engine runs off the main thread), and per-provider wall
  times.

`QUOTABAR_BENCH_ROWS` and `QUOTABAR_BENCH_ITERATIONS` tune the synthetic scan. The Swift line reads
local history only; it does not contact provider APIs or the Keychain.

```sh
QUOTABAR_CLAUDE_PARSE_BENCH=1 swift test --filter testClaudeParseBenchmarkRustVsSwift
QUOTABAR_CODEX_PARSE_BENCH=1 swift test --filter testCodexParseBenchmarkRustVsSwift
```

print `CLAUDE_PARSE_BENCH` / `CODEX_PARSE_BENCH` with Rust vs Swift CPU/wall for the synthetic
corpora in those tests.

### Refresh cost

Provider refresh runs on engine-owned threads, never the Swift/UI thread; the bridge only encodes
one request and decodes the resulting snapshot JSON. Scanners keep revision-keyed caches so an
unchanged local source is not reparsed on every pass: OpenCode caches parsed rows by source
signature, and Antigravity caches decoded conversation folds for the whole database set (its byte
budget, not a small database-count cap, bounds memory). Devin's first full session-database fold is
split into row-id chunks so no statement hits SQLite's per-query interrupt; the one-time build gets
a longer connection budget, persists its winner map, and every later pass verifies the record. Cache
entries are dropped on memory-pressure `unloadCaches` and on account changes where the scanner
exposes that hook.

## Extending it

A provider moves when its auth store, HTTP client, mapper, and local scanners can be expressed in
the engine and covered by tests. Keep the JSON ABI additive: new methods do not change the C layout.
A failure inside the engine becomes a typed error snapshot, never a silent empty card. When a
provider's Swift implementation is kept as a reference oracle, `ProviderCatalog` must construct the
engine-backed runtime so production never has a second live path.
