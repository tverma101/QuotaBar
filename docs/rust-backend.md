# Rust backend port

QuotaBar's UI stays SwiftUI; the **backend** is moving behind the existing
`quotabar-core` Rust static library. This page is the working inventory of what the Swift backend
does, what Rust covers today, and what remains.

## The Swift backend today

The app is one SwiftPM module. The backend-shaped code (everything the UI reads but does not draw)
is roughly 83,000 lines:

| Area | Files | Lines | Role |
|---|---:|---:|---|
| `Providers/` | 133 | 43,556 | per-provider auth stores, API clients, local scanners, mappers, local-history caches |
| `Stores/` | 42 | 8,604 | observable state: snapshots, layout, enablement, cache, snooze, notifications |
| `Services/` | 29 | 7,679 | HTTP, process runner, SQLite CLI, scan worker, local HTTP API, history aggregation |
| `Pricing/` | 8 | 2,753 | model-rate resolution and spend imputation |
| `Models/` | 18 | 2,847 | `ProviderSnapshot`, `MetricLine`, `WidgetData`, daily history |
| `App/` | 18 | 3,574 | composition root, refresh scheduler, AppKit shell |
| `Support/` | 41 | 5,420 | formatting, logging, FFI bridges |
| `QuotaBarCLI/` | 3 | 131 | one-shot cache read / forced refresh |

### The boundary the UI uses

The UI never calls a provider's files directly. It goes through:

- **`ProviderRuntime`** (`Providers/ProviderRuntime.swift`) — `refresh() async -> ProviderSnapshot`,
  `hasLocalCredentials()`, `widgetDescriptors`. `WidgetDataStore` owns scheduling, cache merging,
  and publication.
- **`ProviderSnapshot` → `MetricLine`** — the normalized vocabulary (`.progress`, `.values`,
  `.badge`, `.chart`, `.text`). Mappers turn provider data into these once; every view renders the
  same shapes.
- **`WidgetDataStore` / `LayoutStore` / `ProviderEnablementStore`** — observable state the SwiftUI
  views bind to.
- **Local surfaces outside the UI**: loopback HTTP API on `127.0.0.1:6736` (`/v1/limits`,
  `/v1/usage`, and `/:id` variants), the `quotabar-cli` executable, the `--scan-worker` child
  process used for isolated folds, and a `DistributedNotificationCenter` refresh trigger.

### Persistence and native dependencies

- `~/Library/Application Support/QuotaBar/` — snapshot cache, `log-scan-cache/`, provider
  checkpoints and aggregate caches.
- `UserDefaults` — layout, enablement, appearance, refresh/deadline state.
- macOS Keychain via Security.framework, LocalAuthentication prompts, `NSStatusItem`/`NSPanel`,
  IOKit power state, `/usr/bin/sqlite3`, `/usr/bin/ps`, login-shell capture, `URLSession`.
- **FFI**: `Sources/CQuotabarCore` links `Rust/quotabar-core/target/release/libquotabar_core.a`
  (built by `script/build_rust_core.sh`). Swift bridges live in `Sources/QuotaBar/Support/`.

## Rust before this port

`Rust/quotabar-core` was a small performance core (2,547 lines), not a backend:

| Capability | Direction | Status |
|---|---|---|
| Claude usage-line parser | Rust-primary, per line | complete, parity-tested |
| Codex rollout full-file parser | Rust-primary, per file | complete, parity-tested |
| Compact pricing-catalog decode | Rust fallback when Foundation fails | complete, parity-tested |
| Everything else | — | Swift only |

There were no stubs beyond those three primitives: the crate exposed only per-line parser entry
points and the catalog decoder.

## The backend envelope

The new layer is a generic JSON call over the C ABI:

```c
uint32_t qb_backend_abi_version(void);
QbBackendResult *qb_backend_call(const uint8_t *request, size_t request_len);
QbBackendResult *qb_backend_call_with_payload(const uint8_t *request, size_t request_len,
                                             const uint8_t *payload, size_t payload_len);
const uint8_t *qb_backend_result_data(const QbBackendResult *result, size_t *length);
void qb_backend_result_destroy(QbBackendResult *result);
```

Envelope ABI version 2 added the payload pointer; version 3 added the pricing-snapshot operations
and the `{scan, recheckModels}` fold result. Folds carry one fixed-stride binary record per entry
there, so Swift never JSON-encodes a whole history; the JSON envelope keeps the operation, calendar
boundaries, and either a pricing-snapshot handle (the default) or the pre-resolved rate table (the
fallback).

Request: `{"op":"hermes.scan","params":{...}}`

Success: `{"ok":true,"result":{...}}`

Failure: `{"ok":false,"error":{"kind":"...","message":"..."}}`

Rules:

- Operations are additive; `qb_backend_abi_version` bumps when the envelope changes.
- A panic is caught at the FFI edge and reported as `kind:"internal"`; Swift logs it and falls back
  to the Swift reference path for that refresh. A null handle is reserved for pointer misuse.
- Typed failures (`database_unreadable`, …) surface as the provider's existing error and category;
  they are never downgraded to empty data.
- The Rust side returns **data**, not presentation strings. Localized formatting and chart labels
  stay in Swift, so moving a scan cannot change the UI.

## Port status

| Backend capability | Swift source | Rust status |
|---|---|---|
| Claude line parsing | `ClaudeLogUsageScanner` | **ported** (existing) |
| Codex rollout full parse | `CodexLogUsageScanner` | **ported** (existing; incremental tail stays Swift) |
| Compact pricing catalog | `PricingCatalogCodecs` | **ported fallback** (existing) |
| Hermes local SQLite scan | `HermesUsageScanner` | **ported** (Hermes slice) |
| Claude replay dedupe + priced daily fold | `ClaudeLogUsageScanner.dedup` / `aggregate` | **ported** |
| Codex per-file priced fold | `CodexLogUsageScanner.aggregate` | **ported** |
| Pricing catalogue resolution (exact, normalized, fuzzy, fast variants, dated bases) | `ModelPricing.lookup` / `PricingCatalog` / `PricingSupplement` | **ported** |
| Alias-rule evaluation | `PricingSupplement.canonicalName` | stays Swift (ICU is the authority; see below) |
| OpenCode local database surface (schema probe, usage query, cycle anchor, Hermes gateway query, hosted-usage probe) | `OpenCodeUsageScanner` / `OpenCodeDatabaseSQL` | **ported** (this slice; the healthy Rust refresh spawns no `sqlite3`; the logged fallback does) |
| OpenCode gateway fold (Claude/Codex/Hermes/Muse/router rows) | `OpenCodeUsageScanner.scan` | fold stays Swift (sources are Rust-backed parses) |
| Codex router/proxy/gateway folds | `CodexRouter*`, `CodexProxy*` | missing (native session fold is ported) |
| Antigravity local database queries (step probe, step batches, generation batches, fingerprint, max index) | `AntigravityDbUsageScanner` / `AntigravityStepTimestampIndex` | **ported** (query boundary; the healthy refresh spawns no `sqlite3`; the logged fallback does) |
| Freebuff Desktop local history (usage projection, session titles) | `FreebuffDesktopUsageScanner` / `FreebuffDesktopUsageSQL` | **ported** (this slice; the healthy fold spawns no `sqlite3`; the logged fallback does) |
| ZCode SQLite scan | `ZCodeUsageScanner` | missing (SQLite access now available) |
| Grok / pi / Muse JSONL scans | providers | missing |
| Cursor CSV parsing | `CursorCSVParser`, `CursorUsageCSV` | missing |
| Pricing catalogue decode (JSON feeds, compact snapshots) | `PricingCatalogCodecs` | stays Swift (Foundation parity; compact decode has a Rust fallback) |
| Provider HTTP clients | `*UsageClient` | missing |
| Credential stores / Keychain / OAuth | `*AuthStore` | not planned initially (platform UI and prompts stay Swift) |
| Snapshot cache, refresh scheduler, scan worker | `WidgetDataStore`, `ScanWorkerClient` | missing |
| Local HTTP API + limits projection | `LocalUsageServer`, `LocalLimitsAPI` | missing |
| Layout / enablement / settings stores | `Stores/` | stays Swift (UI state) |

## This slice: Hermes

`hermes.scan` moves the whole local database read behind Rust:

- One read-only SQLite connection instead of one `/usr/bin/sqlite3` subprocess per query
  (probe + 3 period + 3 model + daily = 8 spawns before).
- The SQL, JSON shaping, invalid-row detection, OpenCode-billing exclusion, and cost-completeness
  rules are carried over verbatim, so row selection and day bucketing match.
- Calendar policy stays in Swift: the caller passes period starts, the future-row cutoff, and the
  ten-year daily cutoff. `HermesUsageMapper` and all formatting are untouched.
- The original Swift scan remains as `.swift` engine for parity tests and as the logged fallback if
  the backend reports an internal failure.

### Evidence

Run on macOS 27.2 SDK, arm64, release Rust archive:

| Check | Result |
|---|---|
| `cargo test --manifest-path Rust/quotabar-core/Cargo.toml` | 27 passed, 0 failed |
| `swift build` | Build complete |
| `swift test --filter "HermesUsageScannerRealDBTests\|HermesPathsTests"` | 12 passed, 0 failed (the 8 database tests now exercise Rust) |
| `swift test --filter HermesRustBackendTests` | 5 passed, 0 failed (envelope, parity, provider refresh, error paths) |
| `QUOTABAR_HERMES_BENCH=1 swift test --filter testHermesRustVsSwiftScanBenchmark` | 30,000 sessions: Rust median **57.0 ms**, Swift median **106.6 ms** → **1.87×** |

Benchmark runs: Rust 56.8 / 103.8 / 57.0 ms (one busy-machine outlier; median reported); Swift 106.6 / 106.8 / 93.9 ms.

### Contract notes

- Row data, snapshot shape, ordering after the localized model sort, and every rendered row are
  unchanged; the parity test compares both engines' scans and mapper output.
- Database read failures now use the provider's existing `HermesUsageError.databaseUnreadable`
  (friendly copy, `.credentialAccess`) instead of leaking the raw `/usr/bin/sqlite3` stderr that
  the old scan surfaced. This is an error-path wording/category fix, not a data change.

### Known gap

The Swift engine runs each query through `JSONLAccountingWorkPacer`, which enforces the 7.5%/25%
CPU budget on background/manual passes. The Rust call is currently one unpaced slice (still off the
main actor). On a very large Hermes database that could overshoot a background budget. The next
increment should let Rust yield to the pacer or expose a chunked scan, before more SQLite providers
move over.

## This slice: Claude and Codex accounting

`claude.fold` and `codex.fold` move the tail that runs over every retained log entry — the part
that grows with history size — behind Rust:

- **Claude** — global replay dedupe (exact `(message.id, requestId)` plus sidechain-only message
  collisions, with the same parent/larger-tokens/speed preference), then the priced per-day roll-up
  and `LogUsageScan` assembly. One call per card refresh.
- **Codex** — the per-file fold the scanner stores in its inode aggregate cache, including event
  dedupe, canonical model identity, long-context lanes, priority/service-tier multipliers, the
  no-cache-discount models, and the incomplete-cost markers. One call per changed session file.
- **Shared accounting core** (`backend/accounting/`) — the `ModelRates.costDollars` rate selection
  (prompt tiers, long-context lanes, cache lanes, fast multiplier), the `DailyUsageAccumulator`
  overflow/completeness rules, and the Codable shape of `LogUsageScan`. Both folds use it.
- **Policy stays in Swift** — model resolution (alias rules, OpenRouter/LiteLLM/models.dev) runs
  once per distinct slug through `ModelPricing.resolve` and arrives as a resolved rate table.
  (Superseded by the pricing slice below: the default path now sends a snapshot handle so Rust
  resolves the names; the inline table remains the fallback.) The local-calendar day map is built
  from `Calendar.current` and `DailyUsageAccumulator.dayKey` and passed as day boundaries; Rust
  only picks the last boundary at or before a timestamp, so month/day bucketing is unchanged. The
  localized model-name tie-break is re-applied by the Swift bridge.
- **Fallback** — if the backend reports any failure or the response does not decode, the scanner
  logs and runs the original Swift `dedup`/`aggregate` for the same entries. The Swift methods stay
  in place as the parity oracle.

### Evidence

Run on macOS 27.2 SDK, arm64, release Rust archive, 150,000 synthetic entries over 60 days:

| Check | Result |
|---|---|
| `cargo test --manifest-path Rust/quotabar-core/Cargo.toml` | 40 passed, 0 failed (adds rate/accumulator/fold unit tests) |
| `swift build` | Build complete |
| `swift test` (full suite) | 2,685 executed, 18 skipped, 0 failures |
| `swift test --filter "Claude\|Codex"` | 570 executed, 11 skipped, 0 failures (includes all existing provider/refresh suites) |
| `swift test --filter RustFoldParityTests` | 4 passed: full `LogUsageScan` equality, identical rendered `MetricLine`s, and provider/scanner refreshes confirmed to reach Rust |
| `QUOTABAR_RUST_FOLD_BENCH=1 swift test --filter RustFoldBenchmarkTests` | Claude **785.7 → 353.6 ms (2.22×)**; Codex **940.4 → 154.3 ms (6.09×)** |

Benchmark runs: Claude Rust 351.1 / 354.8 / 353.6 ms, Swift 789.3 / 783.0 / 785.7 ms; Codex Rust
154.3 / 158.9 / 153.3 ms, Swift 940.4 / 953.3 / 938.2 ms. A second run on a busier machine
reproduced the result: Claude Rust **366.6 ms** vs Swift **1110.7 ms (3.03×)**; Codex Rust
**148.4 ms** vs Swift **900.3 ms (6.07×)**. The Rust numbers include entry encoding, the FFI call,
the fold, and decoding the returned scan, so they are end-to-end for the replaced tail.

### Contract notes

- Scan values, day keys, model rows, unknown-model flags, API estimates, and every rendered metric
  line are unchanged; `RustFoldParityTests` asserts whole-scan equality against the Swift oracle and
  equality of the `MetricLine`s produced by `SpendTileMapper`.
- Codex keeps its per-inode aggregate cache: only changed files are folded, one Rust call each.

## This slice: pricing resolution

`claude.fold` and `codex.fold` now take **model names** instead of a Swift-built rate table:

- **`pricing.load`** builds one immutable snapshot per `ModelPricing` (per catalogue refresh) and
  returns a numeric handle. `ModelPricing` loads it lazily on the first fold, caches the handle,
  releases it in `deinit`, and `clearCaches()` drops the Rust memo. The Swift catalogues are
  serialized once (`PricingSnapshotWire`) with Swift's shortest round-trip doubles; `serde_json`'s
  `float_roundtrip` feature is required because its default parser turned `9.600000000000001` into
  `9.6` and priced scans one ULP off the oracle.
- **`backend/pricing/`** mirrors `ModelPricing.lookup`: supplement overrides, OpenRouter → LiteLLM
  exact with separator-normalized retries, `-fast` variants scaled from their base (including the
  dated-primary rule), free-suffix handling, the `-fast`/free early exits, fuzzy matching with the
  numeric-version guard, and the supplement fast-multiplier stamp. `pricing.resolve` exposes the
  same resolver to parity tests and diagnostics; `pricing.clear` drops the memo.
- **Alias rules stay in Swift.** They are ICU `NSRegularExpression` patterns from a network-
  refreshed feed, and the current feed contains `^gemini-3-pro(?=-)…`, a lookahead the Rust
  `regex` crate cannot express. Swapping in a different engine would put a live, user-refreshable
  ruleset behind unproven regex semantics. Instead, Swift sends one memoized canonical name per
  distinct slug; Rust applies the catalogue lookup and rate assembly. This is the resolution half
  of the request, not a new contract.
- **Discovery parity** — the fold reports the same OpenRouter-recheck candidates `ModelPricing`
  would have reported, including slugs that only appear in entries the scan window drops. Rust
  dedupes them once per snapshot, like the Swift memo.

### Evidence

The parity suite compares resolved `ModelRates` and the discovery-candidate set against
`ModelPricing.resolve` for synthetic edge cases and for a broad (few-hundred-name) sample of the
shipped supplement/LiteLLM/models.dev catalogues, then compares whole scans and rendered
`MetricLine`s for both fold modes.

| Check | Result |
|---|---|
| `cargo test --manifest-path Rust/quotabar-core/Cargo.toml` | 56 passed, 0 failed |
| `swift test --filter "RustPricingParityTests\|RustFoldParityTests"` | 10 passed, 0 failed |
| `swift test --filter "RustPricingParityTests\|RustFoldParityTests\|ModelPricing\|Claude\|Codex"` | 635 executed, 11 skipped, 0 failures |
| `swift test` (full suite) | 2,691 executed, 19 skipped, 0 failures |
| `QUOTABAR_RUST_FOLD_BENCH=1 swift test --filter RustFoldBenchmarkTests` | 150k entries, backend vs inline rate table: Claude **317.4 vs 332.9 ms (1.05×)**, Codex **160.9 vs 165.9 ms (1.03×)**; against the Swift folds: **750.6 → 317.4 ms (2.36×)** and **888.3 → 160.9 ms (5.52×)** |
| Same run, catalogue snapshot | 377 names: Swift cold resolve **4,291.8 ms** vs Rust warm **2.7 ms**; a realistic 15-model refresh: **184.7 ms → 0.1 ms**; one-time `pricing.load` **51.2 ms** |

A second full run reproduced the same shape: Claude **314.3 vs 329.3 ms (1.05×)**, Codex
**158.0 vs 164.7 ms (1.04×)**; catalogue load **57.5 ms**.

Benchmark caveats: the test binary is a debug build, so absolute times are inflated; the fold
comparison uses the existing corpus (8 priced models plus ~1,550 synthetic unknown slugs), where
entry folding dominates, so the backend-vs-inline delta looks small. The saving the port actually
buys is the cold-resolve line: that was a per-refresh pricing build (184.7 ms for a realistic
15-model refresh, 4.3 s for a broad 377-name sweep), replaced by one `pricing.load` (51.2 ms) per
catalogue refresh and then ~0.1 ms warm lookups shared by Claude and Codex. Rust keeps a second
in-memory copy of the catalogues (~4,000 + 3,500 entries) while the Swift copy remains for the
oracle and fallback.

### Contract notes

- Resolved rates, unknown-model flags, spend tiles, and rendered lines are unchanged; the parity
test asserts exact `ModelRates` equality (including UTC lanes and prompt tiers) and whole-scan
  equality against the Swift oracle.
- The inline rate table is still built when `backendPricingHandle()` returns nil, so a declined
  load falls back to the previous path with a logged warning.


## This slice: OpenCode local database surface

On the healthy Rust path a complete OpenCode refresh goes through the envelope without spawning
`/usr/bin/sqlite3`. The intentional fallbacks (backend internal failure, or the explicit
`OpenCodeDatabaseEngine.sqliteCLI` oracle) still use the subprocess path; the zero-spawn tripwire
asserts the healthy path only.

- **Staged statements.** The message-store read is three envelope calls per database —
  `opencode.schema`, one `opencode.query` for the selected data SQL, and `opencode.anchor` — so
  Swift paces, cancels, and bounds each statement exactly like the CLI path. Rust opens one
  in-process connection per statement (a little setup cost traded for that parity).
- **`opencode.query`** — one value query with `SQLiteCLIAccessor.queryValue` semantics for the
  INTEGER/TEXT values these statements select (missing file → `nil`, empty cell → `nil`, errors
  thrown). The Hermes gateway ledger query uses it. See the Antigravity section for the documented
  REAL/scientific-notation limitation shared by this primitive.
- **`opencode.probe`** — the schema probe plus an existence query in one round trip against the
  same memo. It stays as the direct envelope operation and its contention tests; the paced
  `hasHostedUsage()` refresh uses the separate `opencode.schema` and `opencode.query` calls so each
  statement gets its own bound.
- **Independent bounds.** Each SQLite statement gets its own five-second deadline, matching the
  CLI path's per-subprocess bound. Schema detection, the data query, and the anchor cannot consume
  each other's budget, and a data failure skips the anchor exactly as the oracle does.
- **One memo owner.** The backend keys a single entry per database revision
  (`path|dev:ino:size:mtime:ctime|wal-stamp`) holding both the layout and the full-history anchor.
  A v1→v2 migration rewrites the file, so both answers invalidate together; the Swift scanner no
  longer keeps a second schema/anchor cache that could disagree with it.
- **SQL stays in Swift.** The v1/v2/mixed statements are built by `OpenCodeDatabaseSQL` and travel
  in the request. They are large, layout-dependent, and already pinned by the schema suite; keeping
  one builder avoids a second copy that could drift. Rust owns connection setup, the probe, the
  matching query, the anchor, and failure classification.
- **Parsing stays single-sourced.** Rust returns the `json_group_array` text sqlite itself produced;
  the shared `parseRows` decodes it. An earlier version parsed and re-encoded rows in Rust, and the
  second JSON pass measured slower than the spawns it removed.
- **Calendar policy stays in Swift.** Rows are raw epoch milliseconds; day keys, the accumulator,
  the gateway folds, and `OpenCodeGoWindowMath` are untouched.
- **One engine/fallback owner.** `OpenCodeDatabaseAccess` owns the engine choice, pacing, and the
  Rust→CLI fallback for the message read, gateway query, and hosted probe. Every Rust operation
  either returns the same result shape as its CLI counterpart or is caught at that boundary, logged,
  and re-run on the CLI engine; a partial Rust read is never mixed with oracle rows. The scanner
  never infers the engine from the accessor's concrete type, so decorating `SQLiteAccessing` cannot
  silently flip production onto the subprocess path.
- **Pacing.** Every statement is one `JSONLAccountingWorkPacer` slice, so schema, data, and
  anchor each account and yield at the CLI path's per-query granularity. Cancellation is checked
  between stages and between databases; a stopped refresh stops before the next statement, not
  after a multi-DB scan. A pathological statement aborts on its own five-second bound rather than
  blocking the refresh indefinitely.
- **Memo stamp discipline.** The schema probe captures the file revision before querying and
  stores under that stamp, so a write or v1→v2 migration landing mid-probe cannot cache the old
  layout under the new revision. The anchor uses the same rule; a regression test races a touch
  against the probe and fails on the old code.
- **Known gaps.** The gateway fold remains Swift. The message payload is small at the sizes this
  provider writes (about 0.5 MB per 10k rows), and its decode is about 4.6 ms in a debug test build;
  at that scale the Swift fold and the engine, not the wire, are the remaining cost. A binary row
  payload stays an option for a much larger window but is not what these numbers point at.

### Evidence

| Check | Result |
|---|---|
| `cargo test --manifest-path Rust/quotabar-core/Cargo.toml` | 80 passed, 0 failed (including real contended-writer retries, per-statement bound counting, and the schema-stamp race) |
| `swift test --filter "OpenCode"` | 190 executed, 2 skipped, 0 failures |
| `swift test --filter OpenCodeRustParityTests` | 6 passed: whole-scan equality, rendered `SpendTileMapper` line equality, provider refresh served by Rust, explicit CLI-oracle path, future-timestamp rejection parity, and a bridge-vs-CLI payload test over unicode, quotes, backslashes, newlines, NULL/empty cells, a WAL database, and corrupt/unreadable files |
| `swift test --filter OpenCodeHermesGatewayTests` | 6 passed, including `testRefreshSpawnsNoSQLiteSubprocess`: a real OpenCode + Hermes fixture refresh calls the Rust backend and a tripwire accessor records **0** subprocess queries |
| `swift test` (full suite) | 2,716 executed, 23 skipped, 0 failures |
| `QUOTABAR_OPENCODE_BENCH=1 swift test --filter OpenCodeRustBenchmarkTests` | **cold** full refresh, 3 DBs × 10k rows + 500 Hermes sessions: **247.8 ms Rust vs 274.3 ms CLI (1.11×)**, scan **10 → 0 spawns**; cold database stage 600 rows total (3 × 200): **4.1 vs 30.1 ms (7.28×)**; 30k rows total (3 × 10k): **137.2 vs 166.6 ms (1.21×)**. The message payload for one 10k-row database is 501,829 bytes; the bridge decode went from **4.6 ms** (result round-trip) to **1.5 ms** (single-pass field read) |
| Staged deadline fixture through `qb_backend_call` | three statements of ~1.9 s each: schema 1.89 s, data 1.91 s, anchor 1.85 s, all `ok`. The old interface shared one 5 s future and failed the anchor; the staged calls each get their own bound. |

Three cold benchmark runs on the staged three-call path: full refresh Rust 247.7 / 247.8 / 253.9 ms,
CLI 273.2 / 285.5 / 274.3 ms; 600-row database stage Rust 4.5 / 4.1 / 3.7 ms, CLI 31.9 / 30.1 /
29.4 ms; 30k rows Rust 144.8 / 137.2 / 135.1 ms, CLI 166.6 / 173.7 / 159.3 ms. The full-refresh
win is modest and noisy while the database stage and spawn elimination are consistent. Every timed
iteration bumps the fixture's file revision (outside the timer), so both engines re-probe and re-run
the full-history anchor: the numbers isolate the engine, not Rust's memo advantage. The test binary
is a debug build, so absolute times are inflated; these medians were taken while an unrelated test
suite held one core (load average about 5), and absolute times move 10–30% between runs on the same
tree, so the engine delta and the spawn counts are the signal. Run-to-run variance is large at 600
rows because the absolute times are small. The decode measurement is the same payload through both
strategies in the test process, so it isolates the removed re-encode from SQL and engine cost.

### Contract notes

- Row selection, ordering, day keys, model rows, unknown-model flags, partial-cost markers, Go
  windows, and every rendered metric line are unchanged; the parity tests assert whole-scan equality
  and `SpendTileMapper` line equality against the CLI oracle.
- A future timestamp still rejects the whole payload (keeping last-good history) rather than
  dropping one row; parity covers that through both engines.
- A malformed row still rejects its database; a missing database is a no-result read, not an empty
  scan. Failed anchor queries stay best-effort and edge-logged.
- Each statement has its own five-second bound; a slow anchor cannot consume the data query's
  budget, and a schema detection failure goes through the same per-database failure path as the
  CLI detect-and-query pair.
- A read-only open or query that fails retries once with read-write access (SELECT-only), matching
  `SQLiteCLIAccessor`, for the staged schema/data/anchor calls, `opencode.query`, and
  `opencode.probe`. A rollback-mode exclusive writer (a WAL writer does not block readers) held past the one-second busy timeout makes
  the first attempt time out inside the call and the read-write retry succeed after the writer
  releases; the same contention drives the probe. A database that stays locked surfaces as the
  provider's existing readable failure instead of an empty snapshot.

## This slice: Antigravity local database queries

Antigravity's conversation databases now use the same in-process value-query primitive as OpenCode,
but the provider keeps its SQL and its accounting model. On the healthy Rust path an Antigravity
refresh spawns no `/usr/bin/sqlite3`; the intentional CLI fallback (an internal backend failure) and
the explicit `.sqliteCLI` parity oracle do spawn it.

- **The neutral `sqlite.query` op serves this provider.** There is no Antigravity-specific
  operation: one statement with `SQLiteCLIAccessor.queryValue` semantics for the INTEGER/TEXT
  columns Antigravity selects — missing file → `nil`, trimmed value → `nil`, exact integer/text
  rendering, and a five-second bound per statement. The request states `readWriteFallback: false`,
  so it deliberately does **not** retry read-write, matching this provider's existing
  `SQLiteCLIAccessor(allowsReadWriteFallback: false)` policy. The batch payloads are read from the
  decoded envelope in one pass rather than re-encoded for a second decode.
- **REAL formatting is not claimed.** Antigravity's statements select only INTEGER/TEXT columns
  (indices, lengths, hex, and JSON). The shared primitive's REAL rendering matches sqlite3 for
  ordinary values such as `2.0` but not for scientific values: `1e300` prints as `1.0e+300` in
  sqlite3 and as a full decimal expansion in Rust. No Antigravity query can reach that path, so it
  is a documented limitation rather than a formatter change that could disturb OpenCode parity.
- **SQL stays in Swift.** Antigravity's statements depend on its bounded batch constants, optional
  `steps` columns, and batch byte budgets. `AntigravityDbUsageScanner` and
  `AntigravityStepTimestampIndex` build them and send each one in the request; Rust owns the
  connection and execution. Moving that builder into Rust would create a second schema-dependent
  source of truth, so the query boundary is the port rather than a duplicate scan operation.
- **Parsing, step matching, fingerprints, protobuf projection, and priced folds stay in Swift.**
  `AntigravityProtoDecoder`, `AntigravityStepTimestampIndex`'s identity rules,
  `AntigravityAccountingProjection`, the per-fingerprint derivation cache, and
  `DailyUsageAccumulator` are untouched. The local calendar/day bucketing remains Swift's.
- **One engine/fallback owner.** `AntigravityDatabaseAccess` owns the explicit `.rust` versus
  `.sqliteCLI` policy. Production pins `.rust`; the CLI accessor remains the parity oracle, the
  test double, and the fallback. A backend/internal bridge failure is logged and re-runs **that
  one statement** on the CLI; the next statement tries Rust again, so a transient failure cannot
  silently disable the in-process engine for the session. A SQL error is rethrown unchanged so the
  scanner's existing `sha3`, busy, and retry handling sees the same failure. `execute` is refused
  on the `.rust` engine, so a write call cannot bypass the policy and spawn the CLI.
- **No duplicate schema/anchor memo.** Antigravity has no cross-refresh schema or anchor cache of
  its own. The step-metadata probe result is part of the existing per-database `CachedDatabase`
  record keyed by `DatabaseFingerprint`; this slice adds no backend cache that could disagree with
  it after a migration. The scanner still re-probes only when the file revision changes.
- **SHA3 is optional.** The bundled in-process SQLite does not provide the CLI's `sha3` /`sha3_agg`
  functions. The scanner already treats that as an unsupported optimization: it falls back to the
  bounded `cachedRowsMatch` verifier and the maximum-index check. Results are identical, but a
  changed large database pays a second full read for that verifier. This is one reason the modern
  10k win is 1.73× rather than larger; registering SHA3 in the Rust connection is the next
  Antigravity optimization, not a provider port.
- **Pacing.** Every query site is one `JSONLAccountingWorkPacer` slice: the step probe, each step
  batch, each generation batch, the fingerprint query, the bounded prefix verifier, and the max
  index. The scanner checks cancellation between stages and databases, just as the CLI path did.

### Evidence

| Check | Result |
|---|---|
| `cargo test --manifest-path Rust/quotabar-core/Cargo.toml` | 80 passed, 0 failed (including the shared primitive's missing-file, SQL-error, INTEGER/TEXT/simple-REAL rendering, uppercase-hex/null-column, empty-cell, and large-integer cases); `cargo fmt --check` clean |
| `swift test --filter "Antigravity"` | 207 executed, 2 skipped, 0 failures |
| `swift test --filter AntigravityRustParityTests` | 7 passed: whole-scan equality, rendered `SpendTileMapper` line equality, malformed/future-row parity, explicit CLI-oracle path, provider-refresh-through-Rust, a zero-subprocess tripwire, one-statement fallback recovery, and refusal of `execute` on the Rust engine |
| `swift test` (full suite) | 2,716 executed, 23 skipped, 0 failures |
| `QUOTABAR_ANTIGRAVITY_BENCH=1 swift test --filter AntigravityRustBenchmarkTests` | cold **legacy** scan (no `steps`, embedded timestamps): 200 rows **8.1 vs 18.1 ms (2.23×)**, **3 → 0 spawns**; 10k **250.2 vs 294.3 ms (1.18×)**, **12 → 0 spawns**. Cold **modern** scan (`steps` table, matching UUID/bot identities, undated generations): 200 rows **11.8 vs 33.5 ms (2.84×)**, **7 → 0 spawns**; 10k **447.4 vs 772.6 ms (1.73×)**, **93 → 0 spawns** |

Each row above is the median of three cold runs; every iteration resets the scanner cache, the
per-database persistence directory, and the process counter, so both engines pay the schema probe,
the step index, the full-history fingerprint, and the data reads. The modern fixture is the real
shape: a `steps` table forces 128-row step-index batches, so a 10k modern database issues about 90
CLI queries versus 12 for the legacy fixture. The small-window modern win (~2.8×) is larger than
the legacy row; the large modern win (1.73×) is held back by the Rust connection lacking `sha3`,
which forces the bounded verifier to re-read the full history. The benchmark is a debug test build,
so absolute times are inflated; this set was taken with an unrelated test suite holding one core
(load average about 5), and absolute times move 10–30% between runs on the same tree. The fixture
build itself uses a longer write budget than the product's five-second read bound, so a loaded
machine cannot abort the benchmark before it measures. The benchmark is per database scan, not a
full provider refresh: quota HTTP, auth, and directory discovery are outside the timer, and a
refresh with multiple stores multiplies the database portion. Spawn elimination is deterministic;
the measured deltas are the engine signal, and the 93 → 0 modern count is the one that matters for
real stores.

## This slice: shared SQLite primitive and Freebuff Desktop local history

The value-query primitive moved out of `backend/opencode` into the neutral `backend/sqlite` module
before a third consumer existed. It owns connection setup, the one-second busy timeout, the
SELECT-only read-write retry, one five-second bound **per statement**, and the
`SQLiteCLIAccessor.queryValue` rendering (empty cell → `nil`, exact INTEGER, trimmed TEXT, ordinary
REALs — with the documented scientific-notation gap). OpenCode and Antigravity moved onto it without
changing their scan paths, and a neutral `sqlite.query` operation serves providers whose statements
are built in Swift; Antigravity and Freebuff Desktop now both call it directly, and all three read
large value payloads in a single pass.

On the healthy Rust path a Freebuff Desktop history fold spawns no `/usr/bin/sqlite3`; an internal
backend failure falls back to the CLI **for that one statement**, and the explicit `.sqliteCLI`
oracle and that fallback do spawn it.

- **Two statements, SQL in Swift.** The assistant-message/mission-manager projection and the
  active-session title lookup are built by `FreebuffDesktopUsageSQL` — they embed this Desktop
  schema's `json_extract`/`json_set` shapes and its older-schema retries — and travel in each
  request. Rust owns the connection, the bound, and the retry, and returns the same
  `json_group_array` text sqlite prints, so the Swift decoder stays single-sourced.
- **The revision cache stays in Swift.** The per-database revision cache, its disk mirror
  (`FreebuffDesktopTurnPersistence`), and the completed aggregate are validated against the
  database's own size/mtime stamps before use. Rust keeps no cache for this provider, so the two
  cannot disagree after a migration; there is no second owner to invalidate.
- **Pacing.** Pacing lives at the statement boundary inside `FreebuffDesktopUsageSQL`: the
  projection, each legacy-schema retry, and the title lookup are one slice each, so a fallback that
  issues a second statement accounts for both exactly as the two `sqlite3` processes did. The
  derived-turn decode and the title decode are their own slices too. Cancellation is checked before
  and between statements and before the decode; the title lookup is skipped when the refresh is
  already cancelled.
- **One engine/fallback owner.** `FreebuffDesktopDatabaseAccess` owns the explicit `.rust` versus
  `.sqliteCLI` policy. Production pins `.rust` through the scanner's default accessor; the CLI
  accessor remains the parity oracle, the test double, and the fallback. A bridge failure is logged
  and re-runs that one statement on the CLI; the next statement (or scan) tries Rust again. A SQL
  error is rethrown unchanged. `execute` is refused on the `.rust` engine, so no code path can
  reach the CLI accessor on a Rust engine by accident.
- **Payload path.** `RustBackend.callResultObject` reads the single payload field out of the decoded
  envelope instead of re-encoding the (multi-megabyte) result for a typed decode. The fixture's
  1.88 MB payload decodes in **5.0 ms** through the field read versus **22.3 ms** through the old
  round-trip; the statement itself is 15.4 ms versus the CLI's 14.1 ms. OpenCode and Antigravity use
  the same single-pass read for their value queries. Schema, anchor, fold, pricing, and Hermes
  results are small structured objects and keep the ordinary typed decode.

### Evidence

| Check | Result |
|---|---|
| `cargo test --manifest-path Rust/quotabar-core/Cargo.toml` | 80 passed, 0 failed (the neutral primitive's empty-aggregate, NULL/empty-cell projection, large-integer, trimming, error, retry-policy, and Antigravity generation-shape cases); `cargo fmt --check` clean |
| `swift test --filter "Freebuff"` | 116 executed, 2 skipped, 0 failures |
| `swift test --filter FreebuffRustParityTests` | 7 passed: whole-scan and rendered `SpendTileMapper` line equality, multi-database + changed-revision parity, zero-subprocess tripwire on the real store shape, explicit CLI-oracle path, one-statement fallback + next-statement/next-scan recovery, `execute` refusal, and the session-title statement served by Rust |
| `swift test` (full suite) | 2,716 executed, 23 skipped, 0 failures |
| `QUOTABAR_FREEBUFF_BENCH=1 swift test --filter FreebuffRustBenchmarkTests` | cold full local-history fold: 200 rows **5.6 vs 8.9 ms (1.59×)**, 10k rows **227.1 vs 217.3 ms (0.96×)**; statement alone 200 rows **0.5 vs 2.8 ms**, 10k rows **15.4 vs 14.1 ms**; payload **37,012 bytes** (decode 0.4 vs 0.1 ms) and **1,880,730 bytes** (decode 22.3 vs 5.0 ms); spawns **1 → 0** in both shapes |

Each row is the median of three cold runs: every iteration builds a fresh scanner, clears the
in-memory caches, and points the disk record at a new directory, so the number isolates the engine
rather than a warm memo. At 10k rows the fold is dominated by the Swift receipt decode and the
priced aggregate that both engines pay, so the 0.96× is parity inside noise; the win at that size is
the removed process and the single-pass payload read, not wall-clock. The 200-row row is the shape
most project databases have, and there the fixed cost of starting `/usr/bin/sqlite3` is most of the
CLI time. The benchmark is a debug test build, so absolute times are inflated; this set was taken
with an unrelated test suite holding one core (load average about 5), and absolute times move
10–30% between runs on the same tree. It covers one project database's local history — the hosted
receipt fetch, model catalogue refresh, and auth are HTTP/file work outside the timer.

## Suggested order for the rest

1. **ZCode, then the Codex FCC ledger.** ZCode is the next target: its local `model_usage` read is
   two statements per changed refresh (the valid/damaged/provider-id aggregate and the daily
   `GROUP BY`; a third only on the minimal-schema fallback), and it has no in-process engine yet.
   The Codex FCC ledger follows with two statements per configured database per refresh and no file
   revision memo. Devin's, Cursor's, and Claude Desktop's credential reads are the small tail — each
   is one cached statement on a cold credential read. The connection layer, accounting core, and
   error contract now exist; each provider needs a parity test against its Swift oracle.
2. **Antigravity's SHA3 gap** — register `sha3` / `sha3_agg` on the Rust connection so a changed
   large database uses the one-pass digest instead of the bounded re-read. Results are already
   identical; this is the remaining efficiency gap measured above.
3. **OpenCode's remaining tail** — the gateway fold and a binary row payload for very large windows.
4. **JSONL providers** — Grok, pi, Muse. Their folds can reuse the accounting core directly.
5. **HTTP clients** — one shared Rust HTTP path with proxy/timeout/error parity, then per-provider
   request/response mapping.
6. **Local API serialization** — project `ProviderSnapshot` into the limits envelope in Rust so the
   app, CLI, and HTTP API share one serializer.
7. **Only then** consider moving the scheduler/scan-worker boundary; credential access stays with
   the platform layer.

Keep every step additive and parity-tested; the Swift implementation is the oracle until the Rust
path has shipped through the real boundary.
