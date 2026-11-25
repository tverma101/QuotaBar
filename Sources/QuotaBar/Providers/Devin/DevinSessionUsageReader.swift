import Foundation
import SQLite3

/// Reads per-call token usage from the Devin CLI's local session database
/// (`~/.local/share/devin/cli/sessions.db`). Each metered assistant `message_nodes` row carries
/// `metadata.metrics` token counters; the CLI writes a fresh assistant row as a response streams,
/// so rows are deduplicated by `metadata.request_id` keeping the newest copy. Reads stay read-only
/// and never touch prompt or tool content.
struct DevinSessionUsageReader {
    typealias Entry = DevinTranscriptUsageScanner.Entry

    /// One file's identity for cache validation: inode, modification time, and size. The
    /// write-ahead log gets its own stamp so an un-checkpointed append still invalidates the fold.
    struct FileStamp: Equatable {
        var inode: NSNumber
        var modified: Date
        var size: NSNumber
    }

    private var cached: (revision: [FileStamp?], entries: [Entry])?

    /// One row per metered assistant call: `request_id` partitions the streamed copies and
    /// `copy_rank = 1` keeps the newest `row_id`. Token counters arrive as JSON values, so each
    /// count column is paired with a `json_type` column four positions later.
    ///
    /// `fields` pulls every needed path out of `chat_message` in ONE parse (a multi-path
    /// `json_extract` yields a JSON array whose missing paths come back as `null` elements), then
    /// the metered CTE unpacks them from that small array — instead of re-parsing the whole
    /// document once per column and once per WHERE clause.
    private static let query = """
    WITH extracted AS MATERIALIZED (
        SELECT row_id, created_at,
               json_extract(chat_message,
                   '$.role', '$.metadata.request_id', '$.metadata.created_at',
                   '$.metadata.generation_model', '$.metadata.metrics') AS fields
        FROM message_nodes
    ), metered AS MATERIALIZED (
        SELECT row_id, created_at,
               json_extract(fields, '$[1]') AS request_id,
               json_extract(fields, '$[2]') AS generated_at,
               json_extract(fields, '$[3]') AS model,
               json_extract(fields, '$[4]') AS metrics
        FROM extracted
        WHERE json_extract(fields, '$[0]') = 'assistant'
          AND json_type(fields, '$[4]') = 'object'
          AND (json_type(fields, '$[4].input_tokens') IS NOT NULL
            OR json_type(fields, '$[4].output_tokens') IS NOT NULL)
    ), unique_calls AS (
        SELECT *, row_number() OVER (PARTITION BY request_id,
            CASE WHEN request_id IS NULL OR request_id = '' THEN row_id ELSE 0 END ORDER BY row_id DESC) AS copy_rank
        FROM metered
    )
    SELECT created_at, generated_at, model, json_extract(metrics, '$.input_tokens'),
           json_extract(metrics, '$.output_tokens'), json_extract(metrics, '$.cache_read_tokens'),
           json_extract(metrics, '$.cache_creation_tokens'), json_type(metrics, '$.input_tokens'),
           json_type(metrics, '$.output_tokens'), json_type(metrics, '$.cache_read_tokens'),
           json_type(metrics, '$.cache_creation_tokens')
    FROM unique_calls WHERE copy_rank = 1
    """

    /// The metered entries for the database at `url`, served from `cached` while the database and
    /// its WAL keep the same revision. A missing database is a complete empty result; a read that
    /// fails, or one whose revision moves mid-scan, is retried on the next call rather than cached.
    mutating func entries(at url: URL) throws -> [Entry] {
        guard let before = try Self.revision(at: url) else {
            cached = nil
            return []
        }
        if let cached, cached.revision == before {
            return cached.entries
        }
        let entries = try Self.read(url.path)
        if let after = try Self.revision(at: url), after == before {
            cached = (revision: before, entries: entries)
        }
        return entries
    }

    /// `[database, wal]` stamps; nil overall only when the database itself is absent. A missing WAL
    /// file is a nil stamp, not an error — the log simply has not been created yet.
    private static func revision(at url: URL) throws -> [FileStamp?]? {
        let path = url.path
        guard let database = try fileStamp(atPath: path) else { return nil }
        return [database, try fileStamp(atPath: path + "-wal")]
    }

    private static func fileStamp(atPath path: String) throws -> FileStamp? {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: path)
        } catch let error as CocoaError
            where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return nil
        }
        guard let inode = attributes[.systemFileNumber] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber
        else {
            throw SQLiteError.queryFailed("Could not read Devin session usage")
        }
        return FileStamp(inode: inode, modified: modified, size: size)
    }

    private static func read(_ path: String) throws -> [Entry] {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        defer { if let database { sqlite3_close(database) } }
        guard opened == SQLITE_OK, let database else {
            throw SQLiteError.queryFailed("Could not read Devin session usage")
        }
        sqlite3_busy_timeout(database, 250)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw SQLiteError.queryFailed("Could not read Devin session usage")
        }
        var entries: [Entry] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw SQLiteError.queryFailed("Could not read Devin session usage")
            }
            try Task.checkCancellation()
            let timestamp = text(statement, 1).flatMap(OpenUsageISO8601.date(from:))
                ?? Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0)))
            let model = text(statement, 2)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let tokens = TokenBreakdown(
                input: try count(statement, 3),
                cacheWrite5m: try count(statement, 6),
                cacheRead: try count(statement, 5),
                output: try count(statement, 4)
            )
            if tokens.totalTokens > 0 {
                entries.append(Entry(
                    timestamp: timestamp,
                    model: model.isEmpty ? ModelUsageEntry.unattributedModelName : model,
                    tokens: tokens
                ))
            }
        }
        return entries
    }

    /// Column text only when SQLite reports a TEXT value; numbers, JSON nulls, and SQL NULLs read nil.
    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let bytes = sqlite3_column_text(statement, column)
        else { return nil }
        return String(cString: bytes)
    }

    /// One token counter. The paired `json_type` column (four positions later in the SELECT) must
    /// be missing or JSON null — both read as zero — or "integer"; any other JSON type means the
    /// stored metrics are damaged and the whole read fails so the caller keeps last-good history.
    /// The integer itself must be a plausible non-negative count.
    private static func count(_ statement: OpaquePointer, _ column: Int32) throws -> Int {
        guard let type = text(statement, column + 4), type != "null" else { return 0 }
        guard type == "integer" else {
            throw SQLiteError.queryFailed("Could not read Devin session usage")
        }
        let value = sqlite3_column_int64(statement, column)
        guard value >= 0, value <= 1_000_000_000_000_000 else {
            throw SQLiteError.queryFailed("Could not read Devin session usage")
        }
        return Int(value)
    }
}
