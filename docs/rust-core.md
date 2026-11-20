# Rust core

QuotaBar is a Swift app; the UI and the provider logic stay in Swift. A small set of
CPU-heavy primitives are implemented in Rust as a static library (`quotabar-core`) and called
from Swift over a C ABI. This document describes the split, the fallback contract, and how to
build and extend it.

## Why a Rust core

The menu-bar app is already native code, so this is not about a slow interpreter. The goal is to
do the hot accounting work — today, the whole-file parses behind the Claude, Codex, CodexRouter,
Grok, Pi, and Muse local-history cold scans, plus the Antigravity per-row protobuf decode —
without Foundation's overhead: per-file `Data` materialization,
JSONSerialization dictionary materialization per line, `Data` copies, and per-call formatting.
A shared streaming reader (`src/scanfile.rs`) walks a file in 64 KiB chunks, splits logical
lines without ever allocating one giant `Data`, and feeds each provider's parser — so a cold
scan of a 20,000-line session file never touches Foundation at all. Measured on a
20,000-line synthetic corpus: the Rust path uses roughly **10x less CPU** for the Claude parse
(**~4.6x** for the Codex rollout parser, ~11.7x for the Grok whole-file parse) — run it
yourself with the benchmarks below.

QuotaBar shares none of this behavior change: the Rust parser is a line-for-line port of the
Swift reference implementation, and the two are tested against each other.

## Layout

- `Rust/quotabar-core/` — the crate (edition 2021, `staticlib` + `rlib`). Only dependency:
  `serde_json`, the vetted parser used rather than a hand-rolled one; it is the minimum needed to
  deserialize usage lines and nothing else. New crate dependencies need the usual justification
  from AGENTS.md. `src/scanfile.rs` is the shared chunked file reader every whole-file driver
  (`qb_*_parse_file`) is built on: it enforces the same 64 MiB logical-line cap as
  `JSONLFileReader`, checks cancellation once per chunk, and reports the trailing newline-less
  fragment as carry (`final_partial`) instead of forcing a parse decision on the driver.
- `Sources/CQuotabarCore/` — a clang target whose header (`include/quotabar_core.h`) declares the
  C ABI the Swift code imports. The `.c` shim is a link probe. Whole-file results share one
  status vocabulary (`QB_FILE_OK` / `QB_FILE_FALLBACK` / `QB_FILE_FAILED`).
- `Sources/QuotaBar/Support/ClaudeUsageLineRustParser.swift` — the Claude per-line bridge
  (still used for incremental/append parses). Maps the FFI result onto
  `ClaudeLogUsageScanner.Entry`, or returns nil.
- `Sources/QuotaBar/Support/ClaudeFileRustParser.swift` — the Claude whole-file bridge behind
  `qb_claude_parse_file`; tri-state `FileOutcome` (`.success` / `.failed` / `.fallback`).
- `Sources/QuotaBar/Support/CodexRolloutRustParser.swift` — the Codex bridge. `Handle` is the
  stateful per-line engine (still used for tail reads); `parseFile(at:emitSince:)` is the
  whole-file path behind `qb_codex_parse_file`, returning events plus the tail-cache checkpoint
  projection and `ReadResult` metadata in one result. `.jsonl.zst` archives are declined before
  any read — compressed bytes are not JSONL — so they always take Swift's decompressor path.
- `Sources/QuotaBar/Support/CodexRouterRustParser.swift` — the CodexRouter ledger bridge
  (`src/codex_router.rs`). Unlike the other parsers it does not use serde_json: the Swift
  implementation is a hand-rolled byte-level structural walker (`JSONLineStructure` +
  `CodexRouterEventLineParser`), and the Rust module is a line-for-line port of it, including
  the `JSONSerialization` verdict for structurally unwalkable lines (one leading BOM, a single
  trailing comma, `Decimal`-range integer parts, no positive `Infinity`, depth ≤ 512).
  `parseLine`/`parseLineDetail` feed `CodexRouterEventLineParser.parse`/`parseResult` first;
  `parseFile` is the whole-file driver behind `qb_codex_router_parse_file`, returning events
  plus a `ReadResult` projection (bytes read, trailing carry, oversized-line state) in one
  result. It declines only for non-canonical `at` timestamp strings, which
  `OpenUsageISO8601` normalizes in Swift.
- `Sources/QuotaBar/Providers/Claude/ClaudeLogUsageScanner.swift` — `parseFile(at:)` tries the
  Rust whole-file parser first and re-parses with the untouched Swift reference
  (`parseFileSwift`, through `ClaudeSessionAppendCache`) when the bridge declines. Per-line
  `parseEntries` still tries the Rust line bridge first for append reads.
- `Sources/QuotaBar/Providers/Codex/CodexLogUsageScanner.swift` — `fullParseAndCheckpoint` tries
  the Rust engine (`attemptRustFullParse` → `CodexRolloutRustParser.parseFile`) and falls back to
  `fullParseAndCheckpointSwift` when the file declines. Incremental (tail) parsing stays in
  Swift; the checkpoint crosses the FFI one-way so the in-memory append cache can round-trip
  through either engine.
- `Sources/QuotaBar/Providers/Codex/CodexRouterUsageScanner.swift` —
  `fullParseAndCheckpoint` tries `CodexRouterRustParser.parseFile` first and falls back to
  `fullParseAndCheckpointSwift`. The file result emits `.event` + `.malformedEvent` rows in
  file order; `recentEvents` applies the same emitSince gate the Swift loop applies per
  line (malformed rows kept unconditionally), and the carried `ReadResult` stores the same
  `partialLine`/`isDiscardingOversizedLine` tail-cache checkpoint the streaming read
  produces. Append/tail reads stay on the per-line bridge through `parseResult`.
- `Sources/QuotaBar/Support/GrokRustParser.swift` — the Grok bridge (`src/grok.rs`, serde_json
  behind a `"turn_completed"` byte-marker gate). `parseFile`/`parseLine` behind
  `qb_grok_parse_file`/`qb_grok_parse_line`; `GrokLogUsageScanner.parseFile(at:)` dispatches
  Rust-first with `parseFileSwift` as oracle. Template for the other provider ports.
- `Sources/QuotaBar/Support/MuseRustParser.swift` — the Muse bridge (`src/muse.rs`,
  `"goal_usage_attribution"` marker gate, integer `recorded_at` microseconds).
  `MuseUsageScanner.parseFile(at:)` dispatches Rust-first; `parseLineResultSwift` is the oracle.
- `Sources/QuotaBar/Support/PiRustParser.swift` — the Pi bridge (`src/pi.rs`, `"usage":{`
  marker gate, the provider→cardID map replicated as a static table). `PiUsageScanner`
  dispatches Rust-first at both the line and file level; `parseLineSwift`/`parseFileSwift`
  are the oracles.
- `Sources/QuotaBar/Support/AntigravityRustDecoder.swift` — the Antigravity bridge. Ports the
  `AntigravityProtoDecoder` protobuf wire walk (plus the `bytes(fromHex:)` hex decode) that
  `AntigravityDbUsageScanner` runs per generation row; the step timestamp index uses the same
  bridge for `steps.metadata` identities. It declines for non-ASCII hex or identifier strings
  whose canonical equivalence Rust cannot decide, where the Swift reference re-runs.
- `Rust/quotabar-core/src/pricing.rs` — the compact pricing-catalog codec (`catalogFromCompact`),
  **Swift-primary**: Swift's Foundation decoder runs first (byte-exact with the snapshots it
  wrote); the Rust parser (`Sources/QuotaBar/Support/CompactCatalogRustParser.swift`) is called
  only when Foundation cannot handle an input at all. `catalogFromCompact` throws if both fail.

## The fallback contract

The bridge can return nil, and production then runs the Swift path, **never a different answer**:

- a timestamp that is a string but is not one of the canonical UTC shapes this module accepts
  (the Foundation-backed normalization path in `OpenUsageISO8601` handles those),
- a line with more than 64 entries (parent + advisor iterations, Claude only),
- any internal failure (a panic is caught at the FFI boundary and reported as "fall back").

For both providers the file-parse scope is **one whole file, not one line**: a line the Rust
engine cannot emulate makes the entire file re-parse with the Swift engine. Mixing engines
within a file is never done — a partial Rust result is always discarded in favour of a full
Swift re-parse. (Codex is additionally stateful across lines: running model, fast-tier flags,
the child-session replay gate — the file result carries that checkpoint so the append cache
can resume incrementally.)

Everything else — invalid JSON, non-object JSON, malformed tokens, advisor iterations, SemVer
rules, leap-second calendar math, duplicate keys, null-vs-absent optionals, saturation — is
implemented identically in both paths and pinned by the parity suites:
`Tests/QuotaBarTests/ClaudeUsageLineRustParserTests.swift`,
`Tests/QuotaBarTests/CodexRolloutRustParserTests.swift` (per-line),
`Tests/QuotaBarTests/ClaudeFileRustParserTests.swift`,
`Tests/QuotaBarTests/CodexFileRustParserTests.swift` (whole-file, including checkpoint and
trailing-fragment parity), `GrokRustParserTests.swift`, `MuseRustParserTests.swift`,
`PiRustParserTests.swift`, `CodexRouterRustParserTests.swift`, and
`AntigravityRustDecoderTests.swift`. Run the full suite, not just a filter, when touching
either side.

The C ABI returns a heap-allocated opaque result; Swift copies the strings out and calls
`qb_claude_result_destroy`. A null result is the "fall back to Swift" signal, not an error.

## Building

`script/build_rust_core.sh` builds the crate with `--locked` and copies `libquotabar_core.a` to
`Rust/quotabar-core/target/release/` (the path Package.swift searches). It is called
automatically by `script/build_and_run.sh`, `script/test_suites.sh`, and CI. A plain
`swift build` or `swift test` requires the archive to exist first — run the script once after
cloning, or via the two entry points above.

`QUOTABAR_RUST_UNIVERSAL=1 script/build_rust_core.sh` builds arm64 + x86_64 and lipo-combines
them (used by `RELEASE=1` release builds); missing Rust targets are installed via `rustup target add`.

Rust sources are formatted with rustfmt conventions; `cargo test --release` in the crate runs
its unit tests (shared with nothing — the crate must not depend on Swift).

## Measuring

```sh
QUOTABAR_CLAUDE_PARSE_BENCH=1 swift test --filter testClaudeParseBenchmarkRustVsSwift
QUOTABAR_CODEX_PARSE_BENCH=1 swift test --filter testCodexParseBenchmarkRustVsSwift
QUOTABAR_CLAUDE_FILE_BENCH=1 swift test --filter testClaudeFileBenchmarkRustVsSwift
QUOTABAR_CODEX_FILE_BENCH=1 swift test --filter testCodexFileBenchmarkRustVsSwift
QUOTABAR_GROK_PARSE_BENCH=1 swift test --filter testGrokParseBenchmarkRustVsSwift
QUOTABAR_MUSE_PARSE_BENCH=1 swift test --filter testMuseParseBenchmarkRustVsSwift
QUOTABAR_PI_PARSE_BENCH=1 swift test --filter testPiParseBenchmarkRustVsSwift
QUOTABAR_ROUTER_PARSE_BENCH=1 swift test --filter testRouterParseBenchmarkRustVsSwift
QUOTABAR_ANTIGRAVITY_BENCH=1 swift test --filter testBenchmarkRustVsSwiftDecode
```

print `CLAUDE_PARSE_BENCH` / `CODEX_PARSE_BENCH` (per-line) and
`CLAUDE_FILE_BENCH` / `CODEX_FILE_BENCH` / `GROK_PARSE_BENCH` / `MUSE_PARSE_BENCH` /
`PI_PARSE_BENCH` / `ROUTER_PARSE_BENCH` (whole-file) with Rust vs Swift CPU/wall for the
synthetic corpora in those tests.

## Extending it

Move a primitive only when it is (a) on a measured hot path, (b) safely expressible behind a
small C ABI, and (c) covered by a parity test against its Swift oracle. The surveyed
high-value work is done (Grok, Pi, Muse, CodexRouter — which also covers OpenCode's router
ledger through the same line parser — Antigravity, and whole-file Claude/Codex). What remains
is lower-value by measurement: ZAI's bounded SQLite/LevelDB extraction, Freebuff's small
per-row SQLite JSON, OpenCode's SQLite path, Cursor's bounded CSV exports, and the
API-bound providers — none stream multi-GB corpora. Keep the
C ABI additive — bump `qb_core_version` when the entry layout changes — and keep every new
FFI function returning a null result on any failure so Swift can always fall back loudly.

Note the two FFI directions in use: parsers (Claude, Codex) are **Rust-primary** — the bridge
runs first and Swift re-parses on decline; the compact-catalog codec is **Swift-primary** —
Foundation runs first because exact-half decimal rounding differs between Apple's `strtod`
(toward zero, as used by the snapshot writer) and `serde_json` (half-to-even), so the bundled
snapshots are only byte-exact through Foundation. Rust is invoked only for inputs Foundation
rejects, `retired` presence (not non-emptiness) is preserved across the FFI as the authoritative
flag, and both paths are pinned by `Tests/QuotaBarTests/PricingCompactCatalogTests.swift`.
