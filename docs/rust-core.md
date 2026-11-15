# Rust core

QuotaBar is a Swift app; the UI and the provider logic stay in Swift. A small set of
CPU-heavy primitives are implemented in Rust as a static library (`quotabar-core`) and called
from Swift over a C ABI. This document describes the split, the fallback contract, and how to
build and extend it.

## Why a Rust core

The menu-bar app is already native code, so this is not about a slow interpreter. The goal is to
do the hot accounting work — today, parsing Claude usage lines from large local JSONL ledgers —
without Foundation's overhead per line: JSONSerialization dictionary materialization, `Data`
copies, and per-call formatting. Measured on a 20,000-line synthetic corpus: the Rust path uses
roughly **10x less CPU** for the parse step (run it yourself with the benchmark below).

QuotaBar shares none of this behavior change: the Rust parser is a line-for-line port of the
Swift reference implementation, and the two are tested against each other.

## Layout

- `Rust/quotabar-core/` — the crate (edition 2021, `staticlib` + `rlib`). Only dependency:
  `serde_json`, the vetted parser used rather than a hand-rolled one; it is the minimum needed to
  deserialize usage lines and nothing else. New crate dependencies need the usual justification
  from AGENTS.md.
- `Sources/CQuotabarCore/` — a clang target whose header (`include/quotabar_core.h`) declares the
  C ABI the Swift code imports. The `.c` shim is a link probe.
- `Sources/QuotaBar/Support/ClaudeUsageLineRustParser.swift` — the Swift bridge. Maps the FFI
  result onto `ClaudeLogUsageScanner.Entry`, or returns nil.
- `Sources/QuotaBar/Providers/Claude/ClaudeLogUsageScanner.swift` — `parseEntries` tries the Rust
  bridge first and falls back to the untouched Swift reference (`parseEntriesSwift`) when the
  bridge declines.

## The fallback contract

The bridge can return nil, and production then runs the Swift path, **never a different answer**:

- a timestamp that is a string but is not one of the canonical UTC shapes this module accepts
  (the Foundation-backed normalization path in `OpenUsageISO8601` handles those),
- a line with more than 64 entries (parent + advisor iterations),
- any internal failure (a panic is caught at the FFI boundary and reported as "fall back").

Everything else — invalid JSON, non-object JSON, malformed tokens, advisor iterations, SemVer
rules, leap-second calendar math — is implemented identically in both paths and pinned by the
parity suite in `Tests/QuotaBarTests/ClaudeUsageLineRustParserTests.swift` (run the full suite,
not just the filter, when touching either side).

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
```

prints `CLAUDE_PARSE_BENCH` with Rust vs Swift CPU/wall for 20,000 synthetic lines.

## Extending it

Move a primitive only when it is (a) on a measured hot path, (b) safely expressible behind a
small C ABI, and (c) covered by a parity test against its Swift oracle. Candidates next in line:
the per-line parse in other JSONL providers (Codex, Grok, pi, Muse), and the pricing fold. Keep
the C ABI additive — bump `qb_core_version` when the entry layout changes — and keep every new
FFI function returning a null result on any failure so Swift can always fall back loudly.
