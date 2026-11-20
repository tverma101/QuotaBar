import Foundation
import SQLite3
@testable import QuotaBar

/// Writes a `sessions.db` fixture with the `message_nodes` table the Devin CLI uses: one row per
/// streamed assistant copy, metered token counters under `metadata.metrics`.
enum DevinSessionDatabaseFixture {
    struct Row {
        var createdAt: Int64
        var message: [String: Any]
    }

    static func assistantRow(
        requestID: String,
        timestamp: Date,
        metrics: [String: Any],
        model: String = "swe-2-max"
    ) -> Row {
        Row(
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

    private static func insert(at url: URL, rows: [Row], createTable: Bool) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw SQLiteError.queryFailed("Could not open Devin session fixture")
        }
        defer { sqlite3_close(db) }
        if createTable {
            let schema = """
            CREATE TABLE message_nodes(
                row_id INTEGER PRIMARY KEY,
                created_at INTEGER NOT NULL,
                chat_message TEXT NOT NULL
            )
            """
            guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
                throw SQLiteError.queryFailed("Could not create Devin session fixture")
            }
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO message_nodes(created_at, chat_message) VALUES (?, ?)",
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
            sqlite3_bind_int64(statement, 1, row.createdAt)
            sqlite3_bind_text(statement, 2, json, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SQLiteError.queryFailed("Could not create Devin session fixture")
            }
        }
    }
}
