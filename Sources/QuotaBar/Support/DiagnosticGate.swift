import os

/// Keeps persistent local-source failures to one diagnostic until that source recovers. Provider
/// refreshes can still succeed through another source, so store-level failure deduplication alone
/// cannot cover these messages.
enum DiagnosticGate {
    private static let loggedFailures = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    static func logOnce(for key: String, emit: () -> Void) {
        let isFirstFailure = loggedFailures.withLock { $0.insert(key).inserted }
        if isFirstFailure { emit() }
    }

    static func clearFailure(_ key: String) {
        _ = loggedFailures.withLock { $0.remove(key) }
    }

    static func clearFailures(prefix: String) {
        loggedFailures.withLock { keys in
            keys = Set(keys.filter { !$0.hasPrefix(prefix) })
        }
    }
}
