import Foundation

/// Keeps only a completed result, never the full native transcript. Callers still enumerate sources
/// and check account ownership before lookup, so additions, removals, rewrites and read failures take
/// their normal path. A backwards clock forces another future-timestamp check over the source rows.
struct ClaudeUsageFoldCache<Value: Sendable>: Sendable {
    struct Key: Equatable, Sendable {
        var files: [JSONLScanning.DiscoveredFile]
        var identity: String
        var since: Date
        var timeZoneIdentifier: String = Calendar.current.timeZone.identifier
        var pricingToken: String? = nil
    }

    var key: Key
    var observedAt: Date
    var value: Value

    func lookup(_ key: Key, now: Date) -> Value? {
        guard self.key == key, now >= observedAt else { return nil }
        let kind = key.pricingToken == nil ? "gateway" : "aggregate"
        let diagnosticKey = "claude.fold.source-changed.\(kind)." + JSONLScanCachePaths.stableFingerprint(key.identity)
        guard JSONLScanning.filesStillMatch(key.files) else {
            if !Task.isCancelled {
                DiagnosticGate.logOnce(for: diagnosticKey) {
                    AppLog.warn(LogTag.plugin("claude"), "session source changed before cached history could be reused; checking the source again")
                }
            }
            return nil
        }
        DiagnosticGate.clearFailure(diagnosticKey)
        return value
    }
}
