import Foundation

struct ZCodeUsageResult: Sendable, Equatable {
    var totalTokens: Double?
    var planName: String?
}

/// Local ZCode App Usage. ZCode records the full prompt (including cache hits) in input_tokens,
/// so adding its cache columns again would double-count them. This is not a Coding Plan quota.
final class ZCodeUsageScanner: @unchecked Sendable {
    static let defaultSqlitePath = "~/.zcode/cli/db/db.sqlite"

    let sqlite: any SQLiteAccessing
    let path: String

    private let lock = NSLock()
    private var cachedResult: ZCodeUsageResult?
    private var cachedSqliteStamp: (size: UInt64, mtime: TimeInterval)?

    init(
        sqlite: any SQLiteAccessing = SQLiteCLIAccessor(allowsReadWriteFallback: false),
        path: String = defaultSqlitePath
    ) {
        self.sqlite = sqlite
        self.path = path
    }

    func hasHistory() -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: expanded)
    }

    func totalTokens() throws -> Double? {
        try usage()?.totalTokens
    }

    func usage() throws -> ZCodeUsageResult? {
        try Task.checkCancellation()
        let expanded = (path as NSString).expandingTildeInPath
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: expanded),
              let size = attrs[.size] as? UInt64,
              let mdate = attrs[.modificationDate] as? Date else {
            lock.withLock {
                cachedResult = nil
                cachedSqliteStamp = nil
            }
            return nil
        }
        let currentStamp = (size, mdate.timeIntervalSinceReferenceDate)

        if let cached = lock.withLock({ () -> ZCodeUsageResult? in
            guard let stamp = cachedSqliteStamp,
                  stamp.size == currentStamp.0,
                  stamp.mtime == currentStamp.1 else {
                return nil
            }
            return cachedResult
        }) {
            return cached
        }

        try Task.checkCancellation()
        let sql = """
            SELECT (SELECT CASE WHEN SUM(CASE WHEN typeof(input_tokens) != 'integer'
                OR typeof(output_tokens) != 'integer' OR input_tokens < 0 OR output_tokens < 0
                THEN 1 ELSE 0 END) > 0 THEN 'invalid'
                ELSE CAST(SUM(CAST(input_tokens AS REAL) + CAST(output_tokens AS REAL)) AS TEXT) END
            FROM model_usage) || '|' || COALESCE((SELECT provider_id FROM model_usage WHERE provider_id LIKE 'account:zai%' ORDER BY started_at DESC LIMIT 1), '');
            """
        let raw = try sqlite.queryValue(path: path, sql: sql)
        try Task.checkCancellation()

        guard let raw else {
            lock.withLock {
                cachedResult = nil
                cachedSqliteStamp = currentStamp
            }
            return nil
        }

        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard let tokenString = parts.first else { throw ZCodeUsageError.invalidUsage }
        guard tokenString != "invalid" else { throw ZCodeUsageError.invalidUsage }

        var totalTokens: Double? = nil
        if let total = Double(tokenString), total.isFinite, total >= 0 {
            totalTokens = total > 0 ? total : nil
        } else if !tokenString.isEmpty {
            throw ZCodeUsageError.invalidUsage
        }

        var planName: String? = nil
        if parts.count > 1 {
            let providerID = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if providerID.contains("start-plan") {
                planName = "Start Plan"
            } else if providerID.contains("coding-plan") {
                planName = "Coding Plan"
            }
        }

        let result = ZCodeUsageResult(totalTokens: totalTokens, planName: planName)
        lock.withLock {
            cachedResult = result
            cachedSqliteStamp = currentStamp
        }
        return result
    }

    func unloadCachesForMemoryPressure() {
        lock.withLock {
            cachedResult = nil
            cachedSqliteStamp = nil
        }
    }
}

enum ZCodeUsageError: Error, LocalizedError {
    case invalidUsage
    var errorDescription: String? { "Couldn't read ZCode token usage." }
}
