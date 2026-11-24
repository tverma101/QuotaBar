import Foundation
import SQLite3

/// Reads per-call token usage from the Devin CLI's local session database
/// (`~/.local/share/devin/cli/sessions.db`). Each metered assistant `message_nodes` row carries
/// `metadata.metrics` token counters; the CLI writes a fresh assistant row as a response streams,
/// so rows are deduplicated by `metadata.request_id` keeping the newest copy. Reads stay read-only
/// and never touch prompt or tool content.
///
/// The fold is incremental and survives across processes via `DevinSessionUsageCache`: it persists
/// the deduplicated per-request winners plus the row-id multiset they were verified against. A rescan
/// proves the stored prefix intact with a covering-index aggregate (a delete or reinsert changes the
/// count/sum and forces a full fold), then reads content only for appended rows and for a band of
/// recent winners — the latter so a row the CLI rewrote in place while it was still hot self-corrects.
/// An in-place update to an older row is the one blind spot: it is invisible to every cheap check and
/// only gets folded after the next row-set change or inode replacement.
struct DevinSessionUsageReader {
    typealias Entry = DevinTranscriptUsageScanner.Entry

    /// One file's identity for cache validation: inode, modification time, and size. The WAL gets its
    /// own stamp so an un-checkpointed append still invalidates the fold.
    struct FileStamp: Equatable {
        var inode: NSNumber
        var modified: Date
        var size: NSNumber
    }

    /// Winners within this many row ids below the watermark are re-read on every verified fold, so an
    /// in-place `UPDATE` of a recently written row self-corrects; the limit caps a pathological band.
    static let reverifyWinnerRowSpan: Int64 = 4_096
    static let reverifyWinnerRowLimit = 2_048

    /// Fold state shared by the in-memory cache and the disk record: the deduplicated winners, the
    /// row-id multiset they were verified against, and the file stamps at fold time.
    private struct FoldState {
        var watermark: Int64
        var rowCount: Int64
        var rowIdSum: Int64
        var winners: [String: DevinSessionUsageCache.StoredWinner]
        var revision: [FileStamp?]
    }

    /// One metered row's projection — a partition candidate that becomes the stored winner when it
    /// is the newest row id seen for its request id.
    private struct Candidate {
        var rowId: Int64
        var key: String
        var timestamp: Date
        var model: String
        var tokens: TokenBreakdown
    }

    /// Which path produced the last fold — surfaced so tests can distinguish a full fold from an
    /// incremental or stamp-verified serve.
    enum FoldKind { case full, incremental, verified }

    private var cached: (revision: [FileStamp?], entries: [Entry])?
    private var state: FoldState?
    /// The record last adopted from or written to disk, so a fold that changes nothing skips the
    /// rewrite.
    private var persisted: DevinSessionUsageCache.Record?

    private(set) var lastFoldKind: FoldKind?
    private(set) var adoptedDiskRecord = false

    /// One row per metered assistant call: `request_id` partitions the streamed copies and
    /// `copy_rank = 1` keeps the newest `row_id`. `row_id`/`request_id` ride along so the fold can
    /// rebuild the winner map. Each count column pairs with a `json_type` four positions later.
    private static let fullFoldQuery = """
    WITH metered AS MATERIALIZED (
        SELECT row_id, created_at, json_extract(chat_message, '$.metadata.request_id') AS request_id,
               json_extract(chat_message, '$.metadata.created_at') AS generated_at,
               json_extract(chat_message, '$.metadata.generation_model') AS model,
               json_extract(chat_message, '$.metadata.metrics') AS metrics
        FROM message_nodes
        WHERE json_extract(chat_message, '$.role') = 'assistant'
          AND json_type(chat_message, '$.metadata.metrics') = 'object'
          AND (json_type(chat_message, '$.metadata.metrics.input_tokens') IS NOT NULL
            OR json_type(chat_message, '$.metadata.metrics.output_tokens') IS NOT NULL)
    ), unique_calls AS (
        SELECT *, row_number() OVER (PARTITION BY request_id,
            CASE WHEN request_id IS NULL OR request_id = '' THEN row_id ELSE 0 END ORDER BY row_id DESC) AS copy_rank
        FROM metered
    )
    SELECT row_id, request_id, created_at, generated_at, model,
           json_extract(metrics, '$.input_tokens'), json_extract(metrics, '$.output_tokens'),
           json_extract(metrics, '$.cache_read_tokens'), json_extract(metrics, '$.cache_creation_tokens'),
           json_type(metrics, '$.input_tokens'), json_type(metrics, '$.output_tokens'),
           json_type(metrics, '$.cache_read_tokens'), json_type(metrics, '$.cache_creation_tokens')
    FROM unique_calls WHERE copy_rank = 1
    """

    /// The same row projection as `fullFoldQuery` for a caller-supplied row set — appended rows and
    /// the reverification band — with an identical column order so `candidate(_:)` reads both.
    private static func meteredRowsQuery(where predicate: String) -> String {
        """
        SELECT row_id, json_extract(chat_message, '$.metadata.request_id'),
               created_at, json_extract(chat_message, '$.metadata.created_at'),
               json_extract(chat_message, '$.metadata.generation_model'),
               json_extract(chat_message, '$.metadata.metrics.input_tokens'),
               json_extract(chat_message, '$.metadata.metrics.output_tokens'),
               json_extract(chat_message, '$.metadata.metrics.cache_read_tokens'),
               json_extract(chat_message, '$.metadata.metrics.cache_creation_tokens'),
               json_type(chat_message, '$.metadata.metrics.input_tokens'),
               json_type(chat_message, '$.metadata.metrics.output_tokens'),
               json_type(chat_message, '$.metadata.metrics.cache_read_tokens'),
               json_type(chat_message, '$.metadata.metrics.cache_creation_tokens')
        FROM message_nodes
        WHERE \(predicate)
          AND json_extract(chat_message, '$.role') = 'assistant'
          AND json_type(chat_message, '$.metadata.metrics') = 'object'
          AND (json_type(chat_message, '$.metadata.metrics.input_tokens') IS NOT NULL
            OR json_type(chat_message, '$.metadata.metrics.output_tokens') IS NOT NULL)
        ORDER BY row_id
        """
    }

    /// Whole-table and prefix row-id aggregates in one covering-index pass. With `?1` bound to the
    /// stored watermark, columns 3/4 describe the stored prefix and columns 1/2/5 the live table.
    private static func rowIdAggregateQuery(index: String?) -> String {
        """
        SELECT COUNT(*), COALESCE(SUM(row_id), 0),
               COALESCE(SUM(CASE WHEN row_id <= ?1 THEN row_id ELSE 0 END), 0),
               COALESCE(SUM(CASE WHEN row_id <= ?1 THEN 1 ELSE 0 END), 0),
               COALESCE(MAX(row_id), 0)
        FROM message_nodes\(index.map { " INDEXED BY \"\($0)\"" } ?? "")
        """
    }

    /// The metered entries for the database at `url`. A missing database is a complete empty
    /// result; a read that fails, or one whose revision moves mid-scan, is retried on the next call
    /// rather than cached.
    mutating func entries(at url: URL) throws -> [Entry] {
        guard let before = try Self.revision(at: url) else {
            cached = nil
            state = nil
            persisted = nil
            return []
        }
        if let cached, cached.revision == before {
            return cached.entries
        }
        try Task.checkCancellation()

        // Adopt the disk record only when it was folded against this same database file.
        if state == nil,
           let record = DevinSessionUsageCache.read(path: url.path),
           record.revision.count == 2,
           record.revision[0]?.inode == before[0]?.inode.int64Value {
            state = FoldState(
                watermark: record.watermark,
                rowCount: record.rowCount,
                rowIdSum: record.rowIdSum,
                winners: record.winners,
                revision: record.revision.map { $0.map(Self.fileStamp) }
            )
            persisted = record
            adoptedDiskRecord = true
        }

        // Identical file stamps prove no write could have happened since the fold; skip SQLite.
        if let state, state.revision == before {
            lastFoldKind = .verified
            let entries = Self.sortedEntries(state.winners)
            cached = (revision: before, entries: entries)
            return entries
        }

        // An incremental fold needs the persisted prefix of this same file; a new inode means the
        // database was replaced and must be folded in full.
        let prior = state.flatMap { $0.revision[0]?.inode == before[0]?.inode ? $0 : nil }
        let scanned = try Self.scan(path: url.path, prior: prior, stamps: before)
        lastFoldKind = scanned.kind

        if let after = try Self.revision(at: url), after == before {
            state = scanned.state
            cached = (revision: before, entries: scanned.entries)
            let record = DevinSessionUsageCache.Record(
                schema: DevinSessionUsageCache.schema,
                revision: before.map(Self.storedStamp),
                watermark: scanned.state.watermark,
                rowCount: scanned.state.rowCount,
                rowIdSum: scanned.state.rowIdSum,
                winners: scanned.state.winners
            )
            if record != persisted {
                DevinSessionUsageCache.write(record, path: url.path)
                persisted = record
            }
        }
        return scanned.entries
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

    private static func storedStamp(_ stamp: FileStamp?) -> DevinSessionUsageCache.StoredStamp? {
        guard let stamp else { return nil }
        return DevinSessionUsageCache.StoredStamp(
            inode: stamp.inode.int64Value,
            modified: stamp.modified.timeIntervalSinceReferenceDate,
            size: stamp.size.int64Value
        )
    }

    private static func fileStamp(_ stamp: DevinSessionUsageCache.StoredStamp) -> FileStamp {
        FileStamp(
            inode: NSNumber(value: stamp.inode),
            modified: Date(timeIntervalSinceReferenceDate: stamp.modified),
            size: NSNumber(value: stamp.size)
        )
    }

    // MARK: - SQLite fold

    private static func scan(
        path: String,
        prior: FoldState?,
        stamps: [FileStamp?]
    ) throws -> (state: FoldState, entries: [Entry], kind: FoldKind) {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        defer { if let database { sqlite3_close(database) } }
        guard opened == SQLITE_OK, let database else {
            throw SQLiteError.queryFailed("Could not read Devin session usage")
        }
        sqlite3_busy_timeout(database, 250)

        // One read transaction keeps the aggregate probe, the winner fold, and the reverification
        // reads on a single snapshot, so concurrent commits cannot interleave between them.
        guard sqlite3_exec(database, "BEGIN DEFERRED TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.queryFailed("Could not read Devin session usage")
        }
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }

        let aggregate = try rowIdAggregate(database, watermark: prior?.watermark ?? .max)
        if let prior,
           aggregate.prefixCount == prior.rowCount,
           aggregate.prefixSum == prior.rowIdSum,
           let winners = try incrementalWinners(database, prior: prior, totalRows: aggregate.total)
        {
            let state = FoldState(
                watermark: aggregate.maximum, rowCount: aggregate.total,
                rowIdSum: aggregate.sum, winners: winners, revision: stamps
            )
            try commit(database)
            return (state, sortedEntries(winners), .incremental)
        }

        var winners: [String: DevinSessionUsageCache.StoredWinner] = [:]
        try foldRows(database, into: &winners)
        let state = FoldState(
            watermark: aggregate.maximum, rowCount: aggregate.total,
            rowIdSum: aggregate.sum, winners: winners, revision: stamps
        )
        try commit(database)
        return (state, sortedEntries(winners), .full)
    }

    private static func commit(_ database: OpaquePointer) throws {
        guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.queryFailed("Could not read Devin session usage")
        }
    }

    /// Merge appended rows and re-verify recent winners. Returns nil when a stored winner can no
    /// longer be ranked locally — it moved partitions or lost metering — demanding a full fold.
    private static func incrementalWinners(
        _ database: OpaquePointer,
        prior: FoldState,
        totalRows: Int64
    ) throws -> [String: DevinSessionUsageCache.StoredWinner]? {
        var winners = prior.winners

        // Appended rows always outrank the stored winners: every stored row id is below the
        // watermark and AUTOINCREMENT assigns new rows ids above it.
        if totalRows > prior.rowCount {
            try eachCandidate(database, where: "row_id > \(prior.watermark)") { candidate in
                if let existing = winners[candidate.key], existing.rowId > candidate.rowId {
                    return
                }
                winners[candidate.key] = storedWinner(candidate)
            }
        }

        // Re-read the winners closest to the watermark. A row the CLI updated in place re-derives to
        // a corrected entry under the same partition key; one that lost metering or moved partitions
        // can no longer be ranked locally and demands a full fold.
        let bandFloor = prior.watermark - reverifyWinnerRowSpan
        var band = prior.winners.values.filter { $0.rowId > bandFloor }.map(\.rowId).sorted()
        guard !band.isEmpty else { return winners }
        if band.count > reverifyWinnerRowLimit {
            band = Array(band.suffix(reverifyWinnerRowLimit))
        }
        var keyByRowId: [Int64: String] = [:]
        keyByRowId.reserveCapacity(band.count)
        for (key, winner) in prior.winners where winner.rowId > bandFloor {
            keyByRowId[winner.rowId] = key
        }
        var seen: Set<Int64> = []
        seen.reserveCapacity(band.count)
        let inList = band.map(String.init).joined(separator: ",")
        var consistent = true
        try eachCandidate(database, where: "row_id IN (\(inList))") { candidate in
            guard keyByRowId[candidate.rowId] == candidate.key else {
                consistent = false
                return
            }
            // Re-store the row's current content only while it still holds its partition — an
            // appended newer copy (above the old watermark) already won it in the merge above and
            // must not be overwritten back to the older streamed copy.
            if winners[candidate.key]?.rowId == candidate.rowId {
                winners[candidate.key] = storedWinner(candidate)
            }
            seen.insert(candidate.rowId)
        }
        guard consistent, seen.count == band.count else { return nil }
        return winners
    }

    /// The `message_nodes` row-id aggregates a fold decision needs, read through a covering index so
    /// the probe never touches the multi-gigabyte chat payloads.
    private static func rowIdAggregate(
        _ database: OpaquePointer,
        watermark: Int64
    ) throws -> (total: Int64, sum: Int64, prefixSum: Int64, prefixCount: Int64, maximum: Int64) {
        let sql = rowIdAggregateQuery(index: coveringIndexName(database))
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw SQLiteError.queryFailed("Could not read Devin session usage")
        }
        sqlite3_bind_int64(statement, 1, watermark)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteError.queryFailed("Could not read Devin session usage")
        }
        return (
            total: sqlite3_column_int64(statement, 0),
            sum: sqlite3_column_int64(statement, 1),
            prefixSum: sqlite3_column_int64(statement, 2),
            prefixCount: sqlite3_column_int64(statement, 3),
            maximum: sqlite3_column_int64(statement, 4)
        )
    }

    /// The CLI's session index covers row ids, so the probe scans its small b-tree instead of the
    /// table's payload pages. Any other index works too; with none the probe falls back to a plain
    /// scan — slower, but still correct.
    private static func coveringIndexName(_ database: OpaquePointer) -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            database,
            "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'message_nodes'",
            -1, &statement, nil
        ) == SQLITE_OK, let statement else { return nil }
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = text(statement, 0) { names.append(name) }
        }
        return names.contains("idx_message_nodes_session") ? "idx_message_nodes_session" : names.first
    }

    /// The windowed full fold: emits partition winners, one per `request_id`.
    private static func foldRows(
        _ database: OpaquePointer,
        into winners: inout [String: DevinSessionUsageCache.StoredWinner]
    ) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, fullFoldQuery, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw SQLiteError.queryFailed("Could not read Devin session usage")
        }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw SQLiteError.queryFailed("Could not read Devin session usage")
            }
            try Task.checkCancellation()
            let candidate = try Self.candidate(statement)
            winners[candidate.key] = storedWinner(candidate)
        }
    }

    /// Step a caller-built metered-row query, yielding each row's candidate to `body`.
    private static func eachCandidate(
        _ database: OpaquePointer,
        where predicate: String,
        body: (Candidate) throws -> Void
    ) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, meteredRowsQuery(where: predicate), -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw SQLiteError.queryFailed("Could not read Devin session usage")
        }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw SQLiteError.queryFailed("Could not read Devin session usage")
            }
            try Task.checkCancellation()
            try body(Self.candidate(statement))
        }
    }

    /// Read one stepped row. Column layout: 0 `row_id`, 1 `request_id`, 2 `created_at`,
    /// 3 `generated_at`, 4 `model`, 5–8 token counters, 9–12 their `json_type` partners.
    private static func candidate(_ statement: OpaquePointer) throws -> Candidate {
        let rowId = sqlite3_column_int64(statement, 0)
        let timestamp = text(statement, 3).flatMap(OpenUsageISO8601.date(from:))
            ?? Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 2)))
        let model = text(statement, 4)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Candidate(
            rowId: rowId,
            key: partitionKey(statement, rowId: rowId),
            timestamp: timestamp,
            model: model.isEmpty ? ModelUsageEntry.unattributedModelName : model,
            tokens: TokenBreakdown(
                input: try count(statement, 5),
                cacheWrite5m: try count(statement, 8),
                cacheRead: try count(statement, 7),
                output: try count(statement, 6)
            )
        )
    }

    /// The dedupe partition one row belongs to, matching the window's `PARTITION BY request_id,
    /// CASE ...`: non-empty request ids share a partition; NULL or empty ones partition per row.
    private static func partitionKey(_ statement: OpaquePointer, rowId: Int64) -> String {
        switch sqlite3_column_type(statement, 1) {
        case SQLITE_TEXT:
            let value = text(statement, 1) ?? ""
            return value.isEmpty ? "u:\(rowId)" : "r:\(value)"
        case SQLITE_NULL:
            return "u:\(rowId)"
        default:
            // Non-text request ids still partition by their exact value; prefix with the column
            // type so a numeric 5 never collides with the string "5".
            let raw = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            return "n:\(sqlite3_column_type(statement, 1)):\(raw)"
        }
    }

    private static func storedWinner(_ candidate: Candidate) -> DevinSessionUsageCache.StoredWinner {
        DevinSessionUsageCache.StoredWinner(
            rowId: candidate.rowId,
            timestamp: candidate.timestamp,
            model: candidate.model,
            input: candidate.tokens.input,
            cacheWrite5m: candidate.tokens.cacheWrite5m,
            cacheRead: candidate.tokens.cacheRead,
            output: candidate.tokens.output
        )
    }

    /// The deduplicated winners as fold entries, ordered by row id for deterministic output.
    /// Winners that total zero tokens still hold their partition — a newer copy exists — but
    /// contribute nothing, exactly like the `totalTokens > 0` filter in the original single-query fold.
    private static func sortedEntries(_ winners: [String: DevinSessionUsageCache.StoredWinner]) -> [Entry] {
        winners.values.sorted { $0.rowId < $1.rowId }.compactMap { winner in
            let tokens = TokenBreakdown(
                input: winner.input,
                cacheWrite5m: winner.cacheWrite5m,
                cacheRead: winner.cacheRead,
                output: winner.output
            )
            guard tokens.totalTokens > 0 else { return nil }
            return Entry(timestamp: winner.timestamp, model: winner.model, tokens: tokens)
        }
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
