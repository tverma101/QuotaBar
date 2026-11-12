#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

jobs="${QUOTABAR_TEST_JOBS:-2}"
if [[ ! "$jobs" =~ ^[1-9][0-9]*$ ]]; then
    printf 'QUOTABAR_TEST_JOBS must be a positive integer.\n' >&2
    exit 2
fi

# One SwiftPM invocation avoids eight repeated build/index-store startups.
# The full suite is covered by test_suites.sh; this is a fast, focused subset.
printf '==> QuotaBar deterministic efficiency and account-isolation contracts\n'
swift test -j "$jobs" --disable-index-store --filter \
  'JSONLFileReaderEfficiencyTests|AppendOnlyFileTailCacheTests|IncrementalJSONLScannerTests|ResourceEfficiencyContractTests|ResourceSoakContractTests|CrossProviderAccountIsolationContractTests|CodexIncrementalEfficiencyTests|CodexLogUsageScannerTests'
printf '==> Efficiency-focused suites passed\n