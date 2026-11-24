# Rust core

QuotaBar is a Swift app; the UI and the provider logic stay in Swift. A small set of
CPU-heavy primitives are implemented in Rust as a static library (`quotabar-core`) and called
from Swift over a C ABI. This document describes the split, the fallback contract, and how to
build and extend it.

## Why a Rust core

The menu-bar app is already native code, so this is not about a slow interpreter. The goal is to
do the hot accounting work — today, the per-line parsers behind the Claude and Codex local-history
folds — without Foundation's overhead per line: JSONSerialization dictionary materialization,
`Data` copies, and per-call formatting. Measured on a 20,000-line synthetic corpus: the Rust path
uses roughly **10x less CPU** for the Claude parse (**~4.6x** for the Codex rollout parser) — run
it yourself with the benchmarks below.

QuotaBar shares none of this behavior change: the Rust parser is a line-for-line port of the
Swift reference implementation, and the two are tested against each other.

## Layout

- `Rust/quotabar-core/` — the crate (edition 2021, `staticlib` + `rlib`). Only dependency:
  `serde_json`, the vetted parser used rather than a hand-rolled one; it is the minimum needed to
  deserialize usage lines and nothing else. New crate dependencies need the usual justification
  from AGENTS.md.
- `Sources/CQuotabarCore/` — a clang target whose header (`include/quotabar_core.h`) declares the
  C ABI the Swift code imports. The `.c` shim is a link probe.
- `Sources/QuotaBar/Support/ClaudeUsageLineRustParser.swift` — the Claude bridge. Maps the FFI
  result onto `ClaudeLogUsageScanner.Entry`, or returns nil.
- `Sources/QuotaBar/Support/CodexRolloutRustParser.swift` — the Codex bridge. Stateful across one
  file's lines; `consume(_:)` returns false when the file must be re-parsed with Swift.
- `Sources/QuotaBar/Providers/Claude/ClaudeLogUsageScanner.swift` — `parseEntries` tries the Rust
  bridge first and falls back to the untouched Swift reference (`parseEntriesSwift`) when the
  bridge declines.
- `Sources/QuotaBar/Providers/Codex/CodexLogUsageScanner.swift` — `fullParseAndCheckpoint` tries
  the Rust engine (`attemptRustFullParse`) and falls back to `fullParseAndCheckpointSwift` when
  any line declines. Incremental (tail) parsing stays in Swift; the checkpoint crosses the FFI
  one-way so the in-memory append cache can round-trip through either engine.
- `Rust/quotabar-core/src/pricing.rs` — the compact pricing-catalog codec (`catalogFromCompact`),
  **Swift-primary**: Swift's Foundation decoder runs first (byte-exact with the snapshots it
  wrote); the Rust parser (`Sources/QuotaBar/Support/CompactCatalogRustParser.swift`) is called
  only when Foundation cannot handle an input at all. `catalogFromCompact` throws if both fail.

## The engine (`quotabar-engine`)

`Rust/quotabar-engine/` is the cross-platform backend the Swift app (and the Windows port) is moving
onto. It is linked into the same static library and called over a small JSON request/reply bridge
(`Sources/QuotaBar/Engine/RustEngine.swift`). Today it serves:

- **Devin** — the whole live refresh (credentials, API, mapping) runs in the engine; Swift adds the
  local transcript history on top.
- **Local SQLite reads** for every provider that reads another app's database (OpenCode, Freebuff,
  Antigravity, ZCode, Cursor, Hermes, Claude Desktop, the Codex proxy). Reads run in-process instead of launching `/usr/bin/sqlite3`
  per query, open read-only, and stop at a per-query time limit: five seconds by default, thirty for
  the large OpenCode and Freebuff stores.
- **Compressed Codex archives** (`.jsonl.zst`), decoded in-process with output and time limits.

The engine asks the app for things only the app can do — Keychain reads and writes, environment
values — through host callbacks, so a Keychain read still uses the app's signed identity and its
existing "Always Allow" grants, and is cancelled with the refresh that asked for it.

Not yet moved: the remaining providers' live refreshes and the Claude/Codex/Grok local-history
scanners still run in Swift (their per-line parsers already use the Rust core above), and the
scan-worker child process still hosts the heavy history folds.

## The fallback contract

The bridge can return nil, and production then runs the Swift path, **never a different answer**:

- a timestamp that is a string but is not one of the canonical UTC shapes this module accepts
  (the Foundation-backed normalization path in `OpenUsageISO8601` handles those),
- a line with more than 64 entries (parent + advisor iterations, Claude only),
- any internal failure (a panic is caught at the FFI boundary and reported as "fall back").

For Codex the scope is **one whole file, not one line**: the engine is stateful across the file's
lines (running model, fast-tier flags, the child-session replay gate), so a line it cannot emulate
makes the entire file re-parse with the Swift engine. Mixing engines within a file is never done.
Lines the parser skips as damaged are counted (`damaged_line_count`, exposed as
`qb_codex_parser_damaged_count` / `Handle.damagedLineCount`) exactly like the Swift parser's
`damagedLineCount` — a torn write skips the record and rides the checkpoint, it does not reject
the file.

Everything else — invalid JSON, non-object JSON, malformed tokens, advisor iterations, SemVer
rules, leap-second calendar math — is implemented identically in both paths and pinned by the
parity suites in `Tests/QuotaBarTests/ClaudeUsageLineRustParserTests.swift` and
`Tests/QuotaBarTests/CodexRolloutRustParserTests.swift` (run the full suite, not just the filter,
when touching either side).

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

The crate is portable — it exposes a C ABI with no platform dependencies, so it compiles for
Windows and Linux unchanged. `QUOTABAR_RUST_TARGET=<triple> script/build_rust_core.sh` builds a
specific target (e.g. `x86_64-pc-windows-msvc`, which emits `quotabar_core.lib`); cross-*linking*
still needs the target toolchain on PATH, but `cargo check --target <triple>` verifies
compilation without it.

Rust sources are formatted with rustfmt conventions; `cargo test --release` in the crate runs
its unit tests (shared with nothing — the crate must not depend on Swift).

## Measuring

```sh
QUOTABAR_CLAUDE_PARSE_BENCH=1 swift test --filter testClaudeParseBenchmarkRustVsSwift
QUOTABAR_CODEX_PARSE_BENCH=1 swift test --filter testCodexParseBenchmarkRustVsSwift
```

print `CLAUDE_PARSE_BENCH` / `CODEX_PARSE_BENCH` with Rust vs Swift CPU/wall for the synthetic
corpora in those tests.

## Extending it

Move a primitive only when it is (a) on a measured hot path, (b) safely expressible behind a
small C ABI, and (c) covered by a parity test against its Swift oracle. Candidates next in line:
the per-line parse in other JSONL providers (Grok, pi, Muse), and the pricing fold. Keep the
C ABI additive — bump `qb_core_version` when the entry layout changes — and keep every new
FFI function returning a null result on any failure so Swift can always fall back loudly.

Note the two FFI directions in use: parsers (Claude, Codex) are **Rust-primary** — the bridge
runs first and Swift re-parses on decline; the compact-catalog codec is **Swift-primary** —
Foundation runs first because exact-half decimal rounding differs between Apple's `strtod`
(toward zero, as used by the snapshot writer) and `serde_json` (half-to-even), so the bundled
snapshots are only byte-exact through Foundation. Rust is invoked only for inputs Foundation
rejects, `retired` presence (not non-emptiness) is preserved across the FFI as the authoritative
flag, and both paths are pinned by `Tests/QuotaBarTests/PricingCompactCatalogTests.swift`.
