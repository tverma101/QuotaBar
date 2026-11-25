import Foundation
import os

/// Which engine reads OpenCode's local databases. The choice is explicit policy at the
/// composition root, never inferred from the accessor's type: wrapping or decorating a
/// `SQLiteAccessing` value cannot silently move production onto the subprocess path.
///
/// Production (`OpenCodeProvider`) pins `.rust`. The `sqliteCLI` engine stays available as the
/// parity oracle, the fallback when the backend reports an internal failure, and the engine test
/// doubles use.
enum OpenCodeDatabaseEngine: Sendable {
    /// In-process Rust reads; no `/usr/bin/sqlite3` subprocess is spawned.
    case rust
    /// The original `/usr/bin/sqlite3` path.
    case sqliteCLI
}

/// Bridge to the OpenCode data-plane operations. Each statement is a separate call so the caller
/// can pace it exactly like the `/usr/bin/sqlite3` path:
///
/// - `opencode.schema` — schema detection (memoized per file revision).
/// - `opencode.query` — one read-only value query: the message data, anchor, Hermes ledger, or
///   hosted-usage probe.
/// - `opencode.anchor` — the monthly-cycle anchor, reusing the backend memo.
///
/// The SQL still comes from `OpenCodeDatabaseSQL` / `OpenCodeDatabaseSchemaProbe` so the layout
/// rules have a single source of truth. Rust owns the connections, the schema/anchor memo, and the
/// query execution; it returns the raw `json_group_array` payload, which the shared
/// `OpenCodeUsageScanner.parseRows` decodes with the same accounting rules as the Swift path. The
/// Swift loop remains the parity oracle and the fallback when the backend reports an internal
/// failure.
enum OpenCodeRustScan {
    struct QueryResult: Sendable {
        let value: String?
        let error: String?
    }

    struct SchemaResult: Decodable, Sendable {
        let schema: String
        let error: String?
    }

    struct AnchorResult: Decodable, Sendable {
        let anchorMs: Double?
        let error: String?
    }

    #if DEBUG
    /// Test-only evidence that the backend actually served the database read. Never read by
    /// shipping code.
    private static let completedSchemaReads = OSAllocatedUnfairLock(initialState: 0)
    static var completedSchemaReadsForTesting: Int { completedSchemaReads.withLock { $0 } }
    private static let completedQueries = OSAllocatedUnfairLock(initialState: 0)
    static var completedQueriesForTesting: Int { completedQueries.withLock { $0 } }
    #endif

    /// Detect the layout from the backend memo, or run the detection statement when cold.
    static func schema(path: String, detectionSQL: String) throws -> SchemaResult {
        let result = try RustBackend.call(
            op: "opencode.schema",
            params: ["path": path, "detectionSQL": detectionSQL]
        )
        let decoded = try JSONDecoder().decode(SchemaResult.self, from: result)
        #if DEBUG
        completedSchemaReads.withLock { $0 += 1 }
        #endif
        return decoded
    }

    /// One read-only value query, with `SQLiteCLIAccessor.queryValue` semantics. The caller decides
    /// whether a response-level `error` is a database failure, an anchor failure, or a reason to
    /// fall back; envelope failures throw.
    ///
    /// The `value` field is the `json_group_array` payload, which reaches several megabytes on a
    /// large window. Read it straight out of the decoded envelope: re-encoding the result object
    /// just to decode it again costs a second full pass over the payload.
    static func query(path: String, sql: String) throws -> QueryResult {
        let result = try RustBackend.callResultObject(
            op: "opencode.query",
            params: ["path": path, "sql": sql]
        )
        #if DEBUG
        completedQueries.withLock { $0 += 1 }
        #endif
        return QueryResult(value: result["value"] as? String, error: result["error"] as? String)
    }

    /// One read-only value query with thrown response errors, used by the Hermes gateway ledger.
    static func queryValue(path: String, sql: String) throws -> String? {
        let decoded = try query(path: path, sql: sql)
        if let error = decoded.error {
            throw RustBackend.BackendError(kind: "query_failed", message: error)
        }
        return decoded.value
    }

    /// The monthly-cycle anchor, reusing the schema/anchor memo for an unchanged revision.
    static func anchor(path: String, schema: String, sql: String) throws -> AnchorResult {
        let result = try RustBackend.call(
            op: "opencode.anchor",
            params: ["path": path, "schema": schema, "sql": sql]
        )
        return try JSONDecoder().decode(AnchorResult.self, from: result)
    }
}

/// One normalized read of the message stores. Both engines produce this shape, so the scanner and
/// its fallback share one result contract.
struct OpenCodeDatabaseRead {
    var rows: [OpenCodeUsageScanner.Row] = []
    var anchorMs: Double?
    var checked: Set<String> = []
    var failures: [String: String] = [:]
}

/// Single owner of the OpenCode database engine policy: which engine runs, how the work is paced,
/// and when an internal backend failure falls back to the `/usr/bin/sqlite3` oracle.
///
/// Every Rust statement is one paced slice, matching the CLI path's per-query pacing. A fallback
/// re-reads every path with the CLI engine so a partial Rust result is never mixed with an oracle
/// result.
struct OpenCodeDatabaseAccess: Sendable {
    let engine: OpenCodeDatabaseEngine
    let sqlite: SQLiteAccessing

    private var usesRust: Bool { engine == .rust }

    /// Read every message database one statement at a time. Nil means the scan was cancelled;
    /// per-database failures stay in `failures` so the scanner can surface the same
    /// `databaseUnreadable` error as before.
    func readMessageDatabases(
        paths: [String],
        cutoffMs: Int,
        maximumTimestampMs: Double
    ) async -> OpenCodeDatabaseRead? {
        guard usesRust else {
            return await Self.readViaCLI(
                paths: paths, cutoffMs: cutoffMs,
                maximumTimestampMs: maximumTimestampMs, sqlite: sqlite
            )
        }

        var read = OpenCodeDatabaseRead()
        do {
            for path in paths {
                guard !Task.isCancelled else { return nil }
                read.checked.insert(path)

                let schema = try JSONLAccountingWorkPacer.shared.perform {
                    try OpenCodeRustScan.schema(
                        path: path,
                        detectionSQL: OpenCodeDatabaseSchemaProbe.detectionSQL
                    )
                }
                guard !Task.isCancelled else { return nil }
                if let error = schema.error {
                    read.failures[path] = error
                    continue
                }
                let layout = OpenCodeDatabaseSchema(backendLabel: schema.schema) ?? .unknown
                Self.logSchema(path: path, layout: layout)

                let dataSQL = OpenCodeDatabaseSQL.dataSQL(cutoffMs: cutoffMs, schema: layout)
                let data = try JSONLAccountingWorkPacer.shared.perform {
                    try OpenCodeRustScan.query(path: path, sql: dataSQL)
                }
                guard !Task.isCancelled else { return nil }
                if let error = data.error {
                    read.failures[path] = error
                    continue
                }
                guard let usageJSON = data.value else {
                    read.failures[path] = "usage query returned no result"
                    continue
                }
                guard let parsedRows = JSONLAccountingWorkPacer.shared.perform({
                    OpenCodeUsageScanner.parseRows(
                        usageJSON, maximumTimestampMs: maximumTimestampMs
                    )
                }) else {
                    read.failures[path] = "usage rows contain malformed accounting values"
                    continue
                }
                read.rows.append(contentsOf: parsedRows)
                guard !Task.isCancelled else { return nil }

                let anchorSQL = OpenCodeDatabaseSQL.anchorSQL(schema: layout)
                let anchor = try JSONLAccountingWorkPacer.shared.perform {
                    try OpenCodeRustScan.anchor(
                        path: path,
                        schema: Self.backendSchemaLabel(layout),
                        sql: anchorSQL
                    )
                }
                guard !Task.isCancelled else { return nil }
                let anchorDiagnosticKey =
                    "opencode.sqlite.anchor.\(JSONLScanCachePaths.stableFingerprint(path))"
                if let error = anchor.error {
                    DiagnosticGate.logOnce(for: anchorDiagnosticKey) {
                        AppLog.warn(
                            LogTag.plugin("opencode"),
                            "anchor query failed for \(path): \(error) — monthly window falls back to calendar month"
                        )
                    }
                } else {
                    DiagnosticGate.clearFailure(anchorDiagnosticKey)
                    if let value = anchor.anchorMs {
                        read.anchorMs = Swift.min(read.anchorMs ?? value, value)
                    }
                }
            }
        } catch {
            AppLog.warn(
                LogTag.plugin("opencode"),
                "rust opencode scan failed (\(error)); using /usr/bin/sqlite3"
            )
            return await Self.readViaCLI(
                paths: paths, cutoffMs: cutoffMs,
                maximumTimestampMs: maximumTimestampMs, sqlite: sqlite
            )
        }
        return read
    }

    /// One read-only value query. A backend failure is logged and retried on the CLI engine; only a
    /// CLI failure reaches the caller.
    func queryValue(path: String, sql: String) throws -> String? {
        if usesRust {
            do {
                return try JSONLAccountingWorkPacer.shared.perform {
                    try OpenCodeRustScan.queryValue(path: path, sql: sql)
                }
            } catch {
                AppLog.warn(
                    LogTag.plugin("opencode"),
                    "rust opencode query failed (\(error)); using /usr/bin/sqlite3"
                )
            }
        }
        return try JSONLAccountingWorkPacer.shared.perform {
            try sqlite.queryValue(path: path, sql: sql)
        }
    }

    /// The hosted-usage existence probe. Schema detection and the existence query are paced
    /// separately, exactly like the CLI path; a failure falls back to the CLI detect-and-query
    /// pair.
    func hostedUsageValue(path: String) throws -> String? {
        if usesRust {
            do {
                let schema = try JSONLAccountingWorkPacer.shared.perform {
                    try OpenCodeRustScan.schema(
                        path: path,
                        detectionSQL: OpenCodeDatabaseSchemaProbe.detectionSQL
                    )
                }
                if let error = schema.error {
                    throw RustBackend.BackendError(kind: "probe_failed", message: error)
                }
                let layout = OpenCodeDatabaseSchema(backendLabel: schema.schema) ?? .unknown
                return try JSONLAccountingWorkPacer.shared.perform {
                    try OpenCodeRustScan.queryValue(
                        path: path,
                        sql: OpenCodeDatabaseSQL.probeSQL(schema: layout)
                    )
                }
            } catch {
                AppLog.warn(
                    LogTag.plugin("opencode"),
                    "rust opencode probe failed (\(error)); using /usr/bin/sqlite3"
                )
            }
        }
        let schema = try JSONLAccountingWorkPacer.shared.perform {
            try OpenCodeDatabaseSchemaProbe.detect(sqlite: sqlite, path: path)
        }
        return try JSONLAccountingWorkPacer.shared.perform {
            try sqlite.queryValue(
                path: path, sql: OpenCodeDatabaseSQL.probeSQL(schema: schema)
            )
        }
    }

    private static func readViaCLI(
        paths: [String],
        cutoffMs: Int,
        maximumTimestampMs: Double,
        sqlite: SQLiteAccessing
    ) async -> OpenCodeDatabaseRead? {
        guard let cli = await OpenCodeUsageScanner.readDatabasesViaCLI(
            paths: paths, cutoffMs: cutoffMs,
            maximumTimestampMs: maximumTimestampMs, sqlite: sqlite
        ) else { return nil }
        return OpenCodeDatabaseRead(
            rows: cli.rows, anchorMs: cli.anchorMs,
            checked: cli.checked, failures: cli.failures
        )
    }

    private static func logSchema(path: String, layout: OpenCodeDatabaseSchema) {
        guard layout.readsV2 else { return }
        let description = layout == .v2 ? "session_message" : "session_message + message"
        DiagnosticGate.logOnce(
            for: "opencode.sqlite.schema.\(JSONLScanCachePaths.stableFingerprint(path))"
        ) {
            AppLog.info(.refresh, "opencode database \(path) uses the \(description) layout")
        }
    }

    private static func backendSchemaLabel(_ layout: OpenCodeDatabaseSchema) -> String {
        switch layout.effective {
        case .v2: return "v2"
        case .mixed: return "mixed"
        case .legacy, .unknown: return "legacy"
        }
    }
}

extension OpenCodeDatabaseSchema {
    /// The wire label the backend reports for the probed layout.
    init?(backendLabel: String) {
        switch backendLabel {
        case "legacy": self = .legacy
        case "v2": self = .v2
        case "mixed": self = .mixed
        case "unknown": self = .unknown
        default: return nil
        }
    }
}
