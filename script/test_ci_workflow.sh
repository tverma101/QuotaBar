#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
workflow_path="$repo_root/../.github/workflows/openusage-ci.yml"

[[ -f "$workflow_path" ]] || {
    printf 'OpenUsage CI workflow is missing: %s\n' "$workflow_path" >&2
    exit 1
}

ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0))' "$workflow_path" >/dev/null

requirement() {
    local needle="$1"
    if ! grep -Fq -- "$needle" "$workflow_path"; then
        printf 'OpenUsage CI workflow is missing required contract: %s\n' "$needle" >&2
        exit 1
    fi
}

requirement "github.event.pull_request.head.repo.full_name != github.repository"
requirement "vars.OPENUSAGE_RUNNER"
requirement "'macos-26'"
requirement 'persist-credentials: false'
requirement '"OpenUsage/**"'

if grep -Eq '^[[:space:]]*runs-on:[[:space:]]*(self-hosted|\[)' "$workflow_path"; then
    printf '%s\n' 'OpenUsage CI must not hard-code an unguarded self-hosted runner' >&2
    exit 1
fi

printf '%s\n' 'OpenUsage CI routing contract passed'
