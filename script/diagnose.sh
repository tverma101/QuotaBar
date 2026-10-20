#!/usr/bin/env bash
set -euo pipefail

# Local controls for an already-running, signed app. Refresh bypasses its cache and failure backoff,
# while keeping Keychain interaction disabled. A provider argument never changes enablement.
# Usage: script/diagnose.sh show|close|refresh [provider-id]
command="${1:-show}"
provider_id="${2:-}"
case "$command" in show|close|refresh) ;; *) echo "usage: $0 show|close|refresh [provider-id]" >&2; exit 2 ;; esac
swift - "$command" "$provider_id" "${BUNDLE_ID:-com.tverma101.quotabar}" <<'SWIFT'
import Foundation
let arguments = CommandLine.arguments
var info: [String: String] = ["bundleID": arguments[3]]
if !arguments[2].isEmpty { info["providerID"] = arguments[2] }
DistributedNotificationCenter().postNotificationName(
    Notification.Name("com.quotabar.diagnostics"), object: arguments[1],
    userInfo: info, deliverImmediately: true
)
SWIFT
