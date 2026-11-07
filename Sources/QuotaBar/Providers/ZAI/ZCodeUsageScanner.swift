import Foundation

/// Local ZCode App Usage. ZCode records the full prompt (including cache hits) in input_tokens,
/// so adding its cache columns again would double-count them. This is not a Coding Plan quota.
struct ZCodeUsageScanner: Sendable {
    let sqlite: any SQLiteAccessing
    let path: String

    init(sqlite: any SQLiteAccessing = SQLiteCLIAccessor(allowsReadWriteFallback: false),
         path: String = "~/.zcode/cli/db/db.sqlite") {
        self.sqlite = sqlite
        self.path = path
    }

    func hasHistory() -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath)
    }

    func totalTokens() throws -> Double? {
        try Task.checkCancellation()
        let result = try sqlite.queryValue(path: path, sql: """
            SELECT CASE WHEN SUM(CASE WHEN typeof(input_tokens) != 'integer'
                OR typeof(output_tokens) != 'integer' OR input_tokens < 0 OR output_tokens < 0
                THEN 1 ELSE 0 END) > 0 THEN 'invalid'
                ELSE CAST(SUM(CAST(input_tokens AS REAL) + CAST(output_tokens AS REAL)) AS TEXT) END
            FROM model_usage
            """)
        try Task.checkCancellation()
        guard let result else { return nil }
        guard let total = Double(result), total.isFinite, total >= 0 else {
            throw ZCodeUsageError.invalidUsage
        }
        return total > 0 ? total : nil
    }
}

enum ZCodeUsageError: Error, LocalizedError {
    case invalidUsage
    var errorDescription: String? { "Couldn't read ZCode token usage." }
}
