#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> OpenUsage deterministic efficiency contracts"

echo "==> JSONL reader copy/buffer/tail contracts"
swift test --filter JSONLFileReaderEfficiencyTests

echo "==> Append checkpoint identity/state bounds"
swift test --filter AppendOnlyFileTailCacheTests

echo "==> Incremental scanner cache/concurrency contracts"
swift test --filter IncrementalJSONLScannerTests

echo "==> Multi-session resource-envelope contracts"
swift test --filter ResourceEfficiencyContractTests

echo "==> Repeated-refresh/parallel soak contracts"
swift test --filter ResourceSoakContractTests

echo "==> Cross-provider account-isolation contracts"
swift test --filter CrossProviderAccountIsolationContractTests

echo "==> Codex append-only efficiency contracts"
swift test --filter CodexIncrementalEfficiencyTests

echo "==> Codex local-log regression suite"
swift test --filter CodexLogUsageScannerTests

echo "==> Efficiency-focused suites passed"
