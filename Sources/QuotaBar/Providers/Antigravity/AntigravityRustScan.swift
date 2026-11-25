import Foundation
import os

/// Which engine reads Antigravity's local conversation databases. The choice is explicit policy at
/// the composition root, never inferred from the accessor's concrete type. Production pins `.rust`;
/// `.sqliteCLI` remains the parity oracle, the test double, and the fallback on an internal backend
/// failure.
enum AntigravityDatabaseEngine: Sendable {
    case rust
    case sqliteCLI
}

/// Bridge to the provider-neutral value-query operation. The SQL is built by
/// `AntigravityDbUsageScanner` / `AntigravityStepTimestampIndex` and travels in each request, so
/// the schema-dependent batch statements stay single-sourced in Swift. Rust owns the in-process
/// read-only connection, the one-second busy timeout, and a five-second bound per statement. The
/// bridge matches the CLI for the INTEGER/TEXT values Antigravity selects; no statement selects a
/// REAL, and the shared primitive's REAL formatting is not part of this provider's contract.
///
/// There is no Antigravity-specific operation: this provider's policy differs from the neutral
/// default only in refusing the read-write retry (`allowsReadWriteFallback: false` on its CLI
/// accessor), which the request states explicitly.
enum AntigravityRustScan {
    #if DEBUG
    /// Test-only evidence that the backend actually served a query. Never read by shipping code.
    private static let completedQueries = OSAllocatedUnfairLock(initialState: 0)
    static var completedQueriesForTesting: Int { completedQueries.withLock { $0 } }
    #endif

    static func queryValue(path: String, sql: String) throws -> String? {
        // The batch payloads are large (`hex(metadata)` chunks, JSON arrays), so read the value
        // field straight out of the decoded envelope instead of re-encoding the result object.
        let result = try RustBackend.callResultObject(
            op: "sqlite.query",
            params: [
                "path": path,
                "sql": sql,
                // Antigravity's SQLiteCLIAccessor is created with `allowsReadWriteFallback: false`;
                // keep the same read-only failure policy on the in-process engine.
                "readWriteFallback": false
            ]
        )
        #if DEBUG
        completedQueries.withLock { $0 += 1 }
        #endif
        if let error = result["error"] as? String {
            throw SQLiteError.queryFailed(error)
        }
        return result["value"] as? String
    }
}

/// Single owner of the Antigravity SQLite engine policy. It wraps the Rust query primitive and
/// falls back to the original `/usr/bin/sqlite3` accessor for the one statement that hit an
/// internal backend failure; the next statement tries Rust again, so one bad response cannot
/// silently disable the in-process engine for the rest of the session. A SQL error from the
/// database is not an internal failure and is rethrown untouched so the scanner's existing
/// `sha3`/busy/retry handling sees exactly what the CLI would report.
final class AntigravityDatabaseAccess: SQLiteAccessing, Sendable {
    private let engine: AntigravityDatabaseEngine
    private let sqlite: SQLiteAccessing
    private let rustQuery: @Sendable (String, String) throws -> String?

    init(
        engine: AntigravityDatabaseEngine,
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(allowsReadWriteFallback: false),
        rustQuery: @escaping @Sendable (String, String) throws -> String? = { path, sql in
            try AntigravityRustScan.queryValue(path: path, sql: sql)
        }
    ) {
        self.engine = engine
        self.sqlite = sqlite
        self.rustQuery = rustQuery
    }

    func queryValue(path: String, sql: String) throws -> String? {
        guard engine == .rust else {
            return try sqlite.queryValue(path: path, sql: sql)
        }
        do {
            return try rustQuery(path, sql)
        } catch let error as SQLiteError {
            throw error
        } catch {
            AppLog.warn(
                LogTag.plugin("antigravity"),
                "rust antigravity query failed (\(error)); using /usr/bin/sqlite3 for this statement"
            )
            return try sqlite.queryValue(path: path, sql: sql)
        }
    }

    func execute(path: String, sql: String) throws {
        guard engine == .sqliteCLI else {
            throw SQLiteError.queryFailed(
                "Antigravity uses read-only statements; execute is unavailable on the in-process engine"
            )
        }
        try sqlite.execute(path: path, sql: sql)
    }
}
