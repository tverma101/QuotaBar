import Foundation
import os

/// Which engine reads Freebuff Desktop's local project databases. The choice is explicit policy at
/// the composition root, never inferred from the accessor's concrete type. Production
/// (`FreebuffDesktopUsageScanner`) pins `.rust`; `.sqliteCLI` remains the parity oracle, the engine
/// test doubles use, and the per-statement fallback on an internal backend failure.
enum FreebuffDesktopDatabaseEngine: Sendable {
    case rust
    case sqliteCLI
}

/// Bridge to the neutral value-query operation. Freebuff Desktop's SQL is built by
/// `FreebuffDesktopUsageSQL` from schema knowledge that lives in Swift, so it travels in each
/// request and stays single-sourced. Rust owns the in-process read-only connection, the one-second
/// busy timeout, the SELECT-only read-write retry, and a five-second bound per statement. The
/// bridge matches the CLI for the INTEGER/TEXT/JSON values these statements select; the projection
/// never selects a REAL, and the shared primitive's REAL formatting is not part of this contract.
enum FreebuffDesktopRustScan {
    #if DEBUG
    /// Test-only evidence that the backend actually served a query. Never read by shipping code.
    private static let completedQueries = OSAllocatedUnfairLock(initialState: 0)
    static var completedQueriesForTesting: Int { completedQueries.withLock { $0 } }
    #endif

    static func queryValue(path: String, sql: String) throws -> String? {
        // Read the payload field straight out of the decoded envelope: the projected history is a
        // multi-megabyte JSON string, and re-encoding it just to decode it again would cost more
        // than the subprocess this replaces.
        let result = try RustBackend.callResultObject(
            op: "sqlite.query",
            params: [
                "path": path,
                "sql": sql,
                // `SQLiteCLIAccessor()` retries read-write once when a WAL-mode Desktop database
                // refuses the read-only open; the in-process engine keeps that same policy.
                "readWriteFallback": true
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

/// Single owner of the Freebuff Desktop SQLite engine policy. It wraps the Rust query primitive and
/// falls back to the original `/usr/bin/sqlite3` accessor for the one statement that hit an internal
/// backend failure; the next statement tries Rust again, so one bad response cannot silently disable
/// the in-process engine for the rest of the session. A SQL error from the database is not an
/// internal failure and is rethrown untouched, so the scanner reports exactly what the CLI would.
final class FreebuffDesktopDatabaseAccess: SQLiteAccessing, Sendable {
    private let engine: FreebuffDesktopDatabaseEngine
    private let sqlite: SQLiteAccessing
    private let rustQuery: @Sendable (String, String) throws -> String?

    init(
        engine: FreebuffDesktopDatabaseEngine,
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        rustQuery: @escaping @Sendable (String, String) throws -> String? = { path, sql in
            try FreebuffDesktopRustScan.queryValue(path: path, sql: sql)
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
                LogTag.plugin("freebuff"),
                "rust freebuff query failed (\(error)); using /usr/bin/sqlite3 for this statement"
            )
            return try sqlite.queryValue(path: path, sql: sql)
        }
    }

    func execute(path: String, sql: String) throws {
        guard engine == .sqliteCLI else {
            throw SQLiteError.queryFailed(
                "Freebuff Desktop uses read-only statements; execute is unavailable on the in-process engine"
            )
        }
        try sqlite.execute(path: path, sql: sql)
    }
}
