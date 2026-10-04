#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
mkdir "$fixture_dir/bin"
cat > "$fixture_dir/bin/swift" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${QB_MEASUREMENT_TEST_MODE:-valid}" in
  missing) exit 0 ;;
  *) printf '\033[0m\rTOKEN_ACCOUNTING_BENCH mode=%s rows=8192 bytes=3276800 mock=1\n' "$QUOTABAR_TOKEN_ACCOUNTING_MODE" ;;
esac
if [[ "${QB_MEASUREMENT_TEST_MODE:-valid}" == failed ]]; then exit 1; fi
SH
chmod +x "$fixture_dir/bin/swift"

PATH="$fixture_dir/bin:$PATH" QB_MEASUREMENT_TEST_MODE=valid \
  QUOTABAR_TOKEN_ACCOUNTING_REPEATS=3 bash "$repo_root/script/measure_token_accounting.sh" > "$fixture_dir/valid.log" 2>&1
rg -q 'Collected 6/6 token-accounting measurements; 6 passed all assertions.' "$fixture_dir/valid.log"

for mode in missing failed; do
  if PATH="$fixture_dir/bin:$PATH" QB_MEASUREMENT_TEST_MODE="$mode" \
    QUOTABAR_TOKEN_ACCOUNTING_REPEATS=1 bash "$repo_root/script/measure_token_accounting.sh" > "$fixture_dir/$mode.log" 2>&1; then
    printf 'Measurement driver incorrectly accepted %s output.\n' "$mode" >&2
    exit 1
  fi
done
printf 'Measurement driver regression checks passed (formatted, missing, failed).\n'
