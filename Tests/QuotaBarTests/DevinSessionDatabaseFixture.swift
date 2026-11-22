import Foundation
import SQLite3
@testable import QuotaBar

/// Writes a `sessions.db` fixture with the `message_nodes` table the Devin CLI uses: one row per
/// streamed assistant copy, metered token counters under `metadata.metrics`. The schema mirrors the
/// real database's `AUTOINCREMENT` row ids and session covering index so the incremental fold's
/// prefix checks run against the same plan they get in production.
enum DevinSessionDatabaseFixture {
    struct Row {
        var sessionID: String
        var createdAt: Int64
        var message: [String: Any]

        static func assistantRow(
            requestID: String,
            timestamp: Date,
            metrics: [String: Any],
            model: String = "swe-2-max",
            sessionID: String = "fixture-session"
        ) -> Row {
            DevinSessionDatabaseFixture.assistantRow(
                requestID: requestID, timestamp: timestamp, metrics: metrics,
                model: model, sessionID: sessionID
            )
        }

        static func userRow(requestID: String, timestamp: Date, metrics: [String: Any]) -> Row {
            DevinSessionDatabaseFixture.userRow(requestID: requestID, timestamp: timestamp, metrics: metrics)
        }
    }

    static func assistantRow(
        requestID: String,
        timestamp: Date,
        metrics: [String: Any],
        model: String = "swe-2-max",
        sessionID: String = "fixture-session"
    ) -> Row {
        Row(
            sessionID: sessionID,
            createdAt: Int64(timestamp.timeIntervalSince1970),
            message: [
                "role": "assistant",
                "metadata": [
                    "request_id": requestID,
                    "created_at": OpenUsageISO8601.string(from: timestamp),
                    "generation_model": model,
                    "metrics": metrics
                ]
            ]
        )
    }

    static func userRow(requestID: String, timestamp: Date, metrics: [String: Any]) -> Row {
        Row(
            sessionID: "fixture-session",
            createdAt: Int64(timestamp.timeIntervalSince1970),
            message: [
                "role": "user",
                "metadata": [
                    "request_id": requestID,
                    "created_at": OpenUsageISO8601.string(from: timestamp),
                    "metrics": metrics
                ]
            ]
        )
    }

    static func create(at url: URL, rows: [Row]) throws {
        try insert(at: url, rows: rows, createTable: true)
    }

    static func append(at url: URL, rows: [Row]) throws {
        try insert(at: url, rows: rows, createTable: false)
    }

    /// Rewrite one row's `chat_message` in place, keeping its `row_id` — the update pattern the
    /// CLI's `AFTER UPDATE OF chat_message` trigger exists for.
    static func update(at url: URL, rowId: Int64, message: [String: Any]) throws {
        let json = String(
            decoding: try JSONSerialization.data(withJSONObject: message),
            as: UTF8.self
        )
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw SQLiteError.queryFailed("Could not open Devin session fixture")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "UPDATE message_nodes SET chat_message = ? WHERE row_id = ?",
            -1, &statement, nil
        ) == SQLITE_OK, let statement else {
            throw SQLiteError.queryFailed("Could not write Devin session fixture")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, json, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(statement, 2, rowId)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteError.queryFailed("Could not write Devin session fixture")
        }
    }

    static func delete(at url: URL, rowIds: [Int64]) throws {
        guard !rowIds.isEmpty else { return }
        let list = rowIds.map(String.init).joined(separator: ",")
        try execute(at: url, sql: "DELETE FROM message_nodes WHERE row_id IN (\(list))")
    }

    /// Every `row_id` currently in the table, ascending — tests resolve the rows they want to
    /// update or delete through this rather than guessing ids.
    static func rowIds(at url: URL) throws -> [Int64] {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw SQLiteError.queryFailed("Could not open Devin session fixture")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT row_id FROM message_nodes ORDER BY row_id", -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw SQLiteError.queryFailed("Could not read Devin session fixture")
        }
        defer { sqlite3_finalize(statement) }
        var ids: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            ids.append(sqlite3_column_int64(statement, 0))
        }
        return ids
    }

    private static func insert(at url: URL, rows: [Row], createTable: Bool) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw SQLiteError.queryFailed("Could not open Devin session fixture")
        }
        defer { sqlite3_close(db) }
        if createTable {
            let schema = """
            CREATE TABLE message_nodes(
                row_id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                node_id INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                chat_message TEXT NOT NULL
            );
            CREATE INDEX idx_message_nodes_session ON message_nodes(session_id);
            """
            guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
                throw SQLiteError.queryFailed("Could not create Devin session fixture")
            }
        }
        var nextNodeId: Int64 = 0
        var counter: OpaquePointer?
        if sqlite3_prepare_v2(
            db,
            "SELECT COALESCE(MAX(node_id), 0) + 1 FROM message_nodes WHERE session_id = ?",
            -1, &counter, nil
        ) == SQLITE_OK, let counter {
            defer { sqlite3_finalize(counter) }
            for row in rows {
                sqlite3_reset(counter)
                sqlite3_clear_bindings(counter)
                sqlite3_bind_text(counter, 1, row.sessionID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                if sqlite3_step(counter) == SQLITE_ROW {
                    nextNodeId = max(nextNodeId, sqlite3_column_int64(counter, 0))
                }
            }
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO message_nodes(session_id, node_id, created_at, chat_message) VALUES (?, ?, ?, ?)",
            -1, &statement, nil
        ) == SQLITE_OK, let statement else {
            throw SQLiteError.queryFailed("Could not create Devin session fixture")
        }
        defer { sqlite3_finalize(statement) }
        for row in rows {
            let json = String(
                decoding: try JSONSerialization.data(withJSONObject: row.message),
                as: UTF8.self
            )
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, row.sessionID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int64(statement, 2, nextNodeId)
            sqlite3_bind_int64(statement, 3, row.createdAt)
            sqlite3_bind_text(statement, 4, json, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SQLiteError.queryFailed("Could not create Devin session fixture")
            }
            nextNodeId += 1
        }
    }

    private static func execute(at url: URL, sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw SQLiteError.queryFailed("Could not open Devin session fixture")
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.queryFailed("Could not write Devin session fixture")
        }
    }
}
