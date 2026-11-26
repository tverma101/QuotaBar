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
it yourself with the benchmarks below. The Claude line parser deserializes only the fields it
reads into borrowed, zero-copy values (the rest of the line — file contents, tool output — is
skipped at scan speed), and benches ~1.75x faster than the whole-line `serde_json::Value` port it
replaced on a real 30 MB corpus of recent usage lines (8,000 lines), with byte-identical entries.

QuotaBar shares none of this behavior change: the Rust parser is a line-for-line port of the
Swift reference implementation, and the two are tested against each other.

## Layout

- `Rust/quotabar-core/` — the crate (edition 2021, `staticlib` + `rlib`). Dependencies:
  `serde_json` (with `raw_value`), `serde` derive, and `memchr` — all already in the lock graph,
  all there to keep the line scan zero-copy; no other new dependencies without the usual
  justification from AGENTS.md.
- `Sources/CQuotabarCore/` — a clang target whose header (`include/quotabar_core.h`) declares the
  C/Rust ABI the Swift code imports: the parser entry points, the compact pricing-catalog codec,
  and `qb_find_byte`, a memchr-backed byte search the JSONL reader uses for newline scanning.
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

## The fallback contract

The bridge can return nil, and production then runs the Swift path, **never a different answer**:

- a timestamp that is a string but is not one of the canonical UTC shapes this module accepts
  (the Foundation-backed normalization path in `OpenUsageISO8601` handles those),
- a line with more than 64 entries (parent + advisor iterations, Claude only),
- any internal failure (a panic is caught at the FFI boundary and reported as "fall back").

For Codex the scope is **one whole file, not one line**: the engine is stateful across the file's
lines (running model, fast-tier flags, the child-session replay gate), so a line it cannot emulate
makes the entire file re-parse with the Swift engine. Mixing engines within a file is never done.

The Claude parser runs a **borrowed typed fast path** before that fallback: a `TypedLine<'a>`
deserializes only the fields the parser reads (strings as zero-copy `&'a str`, ambiguous tokens as
a `RawField` tri-state distinguishing absent from present-null from present-value, `usage` as a
`Map<String, Value>` small enough to keep exact). Lines with JSON escapes in any watched string, or
in shapes the typed model cannot express, drop into the `Value` implementation with byte-for-byte
the pre-typed result. `is_sidechain`/`version`/`requestId`-style literal `null` is treated as an
error there exactly as the reference does — `Option<Box<RawValue>>` alone would swallow it.

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
