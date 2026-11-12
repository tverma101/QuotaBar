#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
workflow_path="${1:-$repo_root/.github/workflows/ci.yml}"
if [[ $# -gt 1 || ! -f "$workflow_path" ]]; then
    printf 'QuotaBar CI workflow not found (or too many arguments): %s\n' "$workflow_path" >&2
    exit 1
fi

# Parse YAML rather than grepping comments or retired OpenUsage paths. Ruby and
# its bundled YAML parser are present on the supported macOS CI runner.
ruby - "$workflow_path" <<'RUBY'
require "yaml"

path = ARGV.fetch(0)
begin
  workflow = YAML.load_file(path)
rescue StandardError => error
  abort "QuotaBar CI workflow is invalid YAML: #{error.message}"
end

def require_contract(condition, detail)
  abort "QuotaBar CI workflow contract failed: #{detail}" unless condition
end

require_contract(workflow.is_a?(Hash), "expected a YAML mapping")
# Ruby's YAML 1.1 parser may interpret the unquoted `on` as Boolean true.
events = workflow["on"] || workflow[true]
require_contract(events.is_a?(Hash), "push and pull_request event definitions")
%w[push pull_request].each do |event|
  branches = events.dig(event, "branches")
  require_contract(branches.is_a?(Array) && branches.include?("main"), "#{event} must test main")
end
require_contract(workflow.dig("permissions", "contents") == "read", "read-only contents permission")

job = workflow.dig("jobs", "check")
require_contract(job.is_a?(Hash), "check job")
require_contract(job["runs-on"] == "macos-26", "supported macos-26 SDK runner")
steps = job["steps"]
require_contract(steps.is_a?(Array) && !steps.empty?, "check job steps")
checkout = steps.find { |step| step.is_a?(Hash) && step["uses"].to_s.start_with?("actions/checkout@") }
require_contract(checkout && checkout.dig("with", "persist-credentials") == false,
                 "checkout must disable credential persistence")

commands = steps.flat_map { |step| step.is_a?(Hash) ? step["run"].to_s.lines : [] }
                .map(&:strip)
                .reject { |line| line.empty? || line.start_with?("#") }
require_contract(commands.any? { |line| line.match?(/^swift build(?:\s|$)/) }, "Swift package build")
require_contract(commands.any? { |line| line.match?(/^bash script\/test_suites\.sh(?:\s|$)/) },
                 "full test-suite driver (Swift, Python, and shell contracts)")
puts "QuotaBar CI routing and test-suite contracts passed"
RUBY
