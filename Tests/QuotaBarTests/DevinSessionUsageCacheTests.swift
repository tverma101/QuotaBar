import Foundation
import XCTest
@testable import QuotaBar

/// The Devin session fold keeps its deduplicated winners on disk so a fresh process (the scan
/// worker) folds only what changed. These tests exercise the fold paths directly:
/// `.full` recomputes everything, `.incremental` merges appended rows and re-reads recent winners,
/// `.verified` serves the persisted fold when file stamps prove nothing was written.
final class DevinSessionUsageCacheTests: XCTestCase {
    private var scratch: URL!
    private var database: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("devin-session-usage-\(UUID().uuidString)", isDirectory: true)
        let databaseDirectory = scratch.appendingPathComponent("cli", isDirectory: true)
        try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        database = databaseDirectory.appendingPathComponent("sessions.db")
        DevinSessionUsageCache.directoryOverride = scratch.appendingPathComponent("cache", isDirectory: true)
    }

    override func tearDown() {
        DevinSessionUsageCache.directoryOverride = nil
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        super.tearDown()
    }

    private static let timestamp = TestLocalInstant.date(2026, 6, 10, 10)

    private func totalTokens(_ entries: [DevinTranscriptUsageScanner.Entry]) -> Int {
        entries.reduce(0) { $0 + $1.tokens.totalTokens }
    }

    func testFreshReaderServesPersistedFoldWithoutFolding() throws {
        try DevinSessionDatabaseFixture.create(at: database, rows: [
            .assistantRow(requestID: "req-a", timestamp: Self.timestamp, metrics: ["input_tokens": 10, "output_tokens": 1]),
            .assistantRow(requestID: "req-b", timestamp: Self.timestamp, metrics: ["input_tokens": 20, "output_tokens": 2])
        ])
        var first = DevinSessionUsageReader()
        let folded = try first.entries(at: database)
        XCTAssertEqual(first.lastFoldKind, .full)
        XCTAssertEqual(totalTokens(folded), 33)

        // A new reader instance — like the next scan-worker process — must not re-fold.
        var second = DevinSessionUsageReader()
        let served = try second.entries(at: database)
        XCTAssertTrue(second.adoptedDiskRecord)
        XCTAssertEqual(second.lastFoldKind, .verified)
        XCTAssertEqual(served, folded)
    }

    func testAppendedRowsFoldIncrementallyAndNewestCopyWins() throws {
        try DevinSessionDatabaseFixture.create(at: database, rows: [
            .assistantRow(requestID: "req-a", timestamp: Self.timestamp, metrics: ["input_tokens": 10, "output_tokens": 1]),
            .assistantRow(requestID: "req-b", timestamp: Self.timestamp, metrics: ["input_tokens": 20, "output_tokens": 2])
        ])
        var first = DevinSessionUsageReader()
        XCTAssertEqual(totalTokens(try first.entries(at: database)), 33)

        // The stream's final copy of req-a supersedes the stored winner; req-c is a new call.
        try DevinSessionDatabaseFixture.append(at: database, rows: [
            .assistantRow(requestID: "req-a", timestamp: Self.timestamp, metrics: ["input_tokens": 99, "output_tokens": 9]),
            .assistantRow(requestID: "req-c", timestamp: Self.timestamp, metrics: ["output_tokens": 5])
        ])

        var second = DevinSessionUsageReader()
        let entries = try second.entries(at: database)
        XCTAssertTrue(second.adoptedDiskRecord)
        XCTAssertEqual(second.lastFoldKind, .incremental)
        // req-a now counts 108 (99+9), req-b still 22, req-c 5.
        XCTAssertEqual(totalTokens(entries), 135)
        XCTAssertEqual(entries.count, 3)
    }

    func testAppendedStreamedCopiesStillDeduplicateByRequestId() throws {
        try DevinSessionDatabaseFixture.create(at: database, rows: [
            .assistantRow(requestID: "req-a", timestamp: Self.timestamp, metrics: ["input_tokens": 10])
        ])
        var first = DevinSessionUsageReader()
        _ = try first.entries(at: database)

        // Two more streamed copies of the same call; only the newest counts.
        try DevinSessionDatabaseFixture.append(at: database, rows: [
            .assistantRow(requestID: "req-a", timestamp: Self.timestamp, metrics: ["input_tokens": 40, "output_tokens": 4]),
            .assistantRow(requestID: "req-a", timestamp: Self.timestamp, metrics: ["input_tokens": 50, "output_tokens": 5])
        ])

        var second = DevinSessionUsageReader()
        let entries = try second.entries(at: database)
        XCTAssertEqual(second.lastFoldKind, .incremental)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(totalTokens(entries), 55)
    }

    func testDeleteForcesFullFoldAndRunnerUpWinsPartition() throws {
        // Two streamed copies of req-a: row 2 is the stored winner. Deleting it must promote row 1
        // — the partition re-rank only a full fold can compute.
        try DevinSessionDatabaseFixture.create(at: database, rows: [
            .assistantRow(requestID: "req-a", timestamp: Self.timestamp, metrics: ["input_tokens": 10, "output_tokens": 1]),
            .assistantRow(requestID: "req-a", timestamp: Self.timestamp, metrics: ["input_tokens": 11, "output_tokens": 1]),
            .assistantRow(requestID: "req-b", timestamp: Self.timestamp, metrics: ["output_tokens": 7])
        ])
        var first = DevinSessionUsageReader()
        // Winner for req-a is the second copy (12) plus req-b (7).
        XCTAssertEqual(totalTokens(try first.entries(at: database)), 19)

        let ids = try DevinSessionDatabaseFixture.rowIds(at: database)
        try DevinSessionDatabaseFixture.delete(at: database, rowIds: [ids[1]])

        var second = DevinSessionUsageReader()
        let entries = try second.entries(at: database)
        XCTAssertEqual(second.lastFoldKind, .full)
        // req-a falls back to its first copy (11), req-b unchanged (7).
        XCTAssertEqual(totalTokens(entries), 18)
    }

    func testInPlaceUpdateOfRecentWinnerSelfCorrects() throws {
        try DevinSessionDatabaseFixture.create(at: database, rows: [
            .assistantRow(requestID: "req-a", timestamp: Self.timestamp, metrics: ["input_tokens": 10, "output_tokens": 1]),
            .userRow(requestID: "req-u", timestamp: Self.timestamp, metrics: ["input_tokens": 999])
        ])
        var first = DevinSessionUsageReader()
        XCTAssertEqual(totalTokens(try first.entries(at: database)), 11)

        // The CLI rewrites the row's metrics in place: same row id, same request id, new counters.
        let ids = try DevinSessionDatabaseFixture.rowIds(at: database)
        let updated = DevinSessionDatabaseFixture.assistantRow(
            requestID: "req-a", timestamp: Self.timestamp, metrics: ["input_tokens": 42, "output_tokens": 4]
        )
        try DevinSessionDatabaseFixture.update(at: database, rowId: ids[0], message: updated.message)

        var second = DevinSessionUsageReader()
        let entries = try second.entries(at: database)
        XCTAssertEqual(second.lastFoldKind, .incremental)
        XCTAssertEqual(totalTokens(entries), 46)
    }

    func testInPlaceUpdateMovingPartitionsFallsBackToFullFold() throws {
        try DevinSessionDatabaseFixture.create(at: database, rows: [
            .assistantRow(requestID: "req-a", timestamp: Self.timestamp, metrics: ["input_tokens": 10, "output_tokens": 1]),
            .assistantRow(requestID: "req-a", timestamp: Self.timestamp, metrics: ["input_tokens": 20, "output_tokens": 2]),
            .assistantRow(requestID: "req-b", timestamp: Self.timestamp, metrics: ["output_tokens": 5])
        ])
        var first = DevinSessionUsageReader()
        // req-a winner is the second copy (22) plus req-b (5).
        XCTAssertEqual(totalTokens(try first.entries(at: database)), 27)

        // The stored winner row's request id changes: its old partition's real winner is the first
        // copy now, which only a full fold can re-rank.
        let ids = try DevinSessionDatabaseFixture.rowIds(at: database)
        let moved = DevinSessionDatabaseFixture.assistantRow(
            requestID: "req-moved", timestamp: Self.timestamp, metrics: ["input_tokens": 20, "output_tokens": 2]
        )
        try DevinSessionDatabaseFixture.update(at: database, rowId: ids[1], message: moved.message)

        var second = DevinSessionUsageReader()
        let entries = try second.entries(at: database)
        XCTAssertEqual(second.lastFoldKind, .full)
        // req-a back to its first copy (11), req-moved (22), req-b (5).
        XCTAssertEqual(totalTokens(entries), 38)
        XCTAssertEqual(entries.count, 3)
    }

    func testInPlaceUpdateThatUnmetersWinnerFallsBackToFullFold() throws {
        try DevinSessionDatabaseFixture.create(at: database, rows: [
            .assistantRow(requestID: "req-a", timestamp: Self.timestamp, metrics: ["input_tokens": 10]),
            .assistantRow(requestID: "req-a", timestamp: Self.timestamp, metrics: ["input_tokens": 20]),
            .assistantRow(requestID: "req-b", timestamp: Self.timestamp, metrics: ["output_tokens": 5])
        ])
        var first = DevinSessionUsageReader()
        XCTAssertEqual(totalTokens(try first.entries(at: database)), 25)

        // The newest copy is rewritten as a user message: req-a's winner becomes its first copy.
        let ids = try DevinSessionDatabaseFixture.rowIds(at: database)
        let unmetered = DevinSessionDatabaseFixture.userRow(
            requestID: "req-a", timestamp: Self.timestamp, metrics: ["input_tokens": 20]
        )
        try DevinSessionDatabaseFixture.update(at: database, rowId: ids[1], message: unmetered.message)

        var second = DevinSessionUsageReader()
        let entries = try second.entries(at: database)
        XCTAssertEqual(second.lastFoldKind, .full)
        XCTAssertEqual(totalTokens(entries), 15)
    }

    func testReplacedDatabaseFoldsInFull() throws {
        try DevinSessionDatabaseFixture.create(at: database, rows: [
            .assistantRow(requestID: "req-a", timestamp: Self.timestamp, metrics: ["input_tokens": 10])
        ])
        var first = DevinSessionUsageReader()
        XCTAssertEqual(totalTokens(try first.entries(at: database)), 10)

        // Same path, new file: the inode change invalidates the persisted prefix.
        try FileManager.default.removeItem(at: database)
        try DevinSessionDatabaseFixture.create(at: database, rows: [
            .assistantRow(requestID: "req-new", timestamp: Self.timestamp, metrics: ["output_tokens": 7])
        ])

        var second = DevinSessionUsageReader()
        let entries = try second.entries(at: database)
        XCTAssertEqual(second.lastFoldKind, .full)
        XCTAssertEqual(totalTokens(entries), 7)
    }

    func testMissingDatabaseIsAnEmptyResult() throws {
        var reader = DevinSessionUsageReader()
        let entries = try reader.entries(at: database)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertNil(reader.lastFoldKind)
    }

    func testEmptyThenAppendedDatabaseFoldsIncrementally() throws {
        try DevinSessionDatabaseFixture.create(at: database, rows: [])
        var first = DevinSessionUsageReader()
        XCTAssertTrue(try first.entries(at: database).isEmpty)

        try DevinSessionDatabaseFixture.append(at: database, rows: [
            .assistantRow(requestID: "req-a", timestamp: Self.timestamp, metrics: ["output_tokens": 3])
        ])

        var second = DevinSessionUsageReader()
        let entries = try second.entries(at: database)
        XCTAssertEqual(second.lastFoldKind, .incremental)
        XCTAssertEqual(totalTokens(entries), 3)
    }

    func testRowsWithoutRequestIdStayUnique() throws {
        // NULL and empty request ids partition by their own row id — never deduplicated away.
        func meteredRow(_ metrics: [String: Any], requestID: Any?) -> DevinSessionDatabaseFixture.Row {
            var metadata: [String: Any] = [
                "created_at": OpenUsageISO8601.string(from: Self.timestamp),
                "metrics": metrics
            ]
            if let requestID { metadata["request_id"] = requestID }
            return DevinSessionDatabaseFixture.Row(
                sessionID: "fixture-session",
                createdAt: Int64(Self.timestamp.timeIntervalSince1970),
                message: ["role": "assistant", "metadata": metadata]
            )
        }
        try DevinSessionDatabaseFixture.create(at: database, rows: [
            meteredRow(["input_tokens": 5], requestID: nil),
            meteredRow(["input_tokens": 7], requestID: NSNull()),
            meteredRow(["input_tokens": 11], requestID: "")
        ])

        var reader = DevinSessionUsageReader()
        let entries = try reader.entries(at: database)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(totalTokens(entries), 23)
    }

    func testDamagedAppendedRowFailsWholeRead() throws {
        try DevinSessionDatabaseFixture.create(at: database, rows: [
            .assistantRow(requestID: "req-a", timestamp: Self.timestamp, metrics: ["input_tokens": 10])
        ])
        var first = DevinSessionUsageReader()
        _ = try first.entries(at: database)

        try DevinSessionDatabaseFixture.append(at: database, rows: [
            .assistantRow(requestID: "req-b", timestamp: Self.timestamp, metrics: ["input_tokens": "not-a-count"])
        ])

        var second = DevinSessionUsageReader()
        XCTAssertThrowsError(try second.entries(at: database))
    }

    func testZeroTotalWinnerStillSuppressesItsPartition() throws {
        // A newer copy with zero totals is the partition's winner: its zero counts, the older
        // copy's tokens do not come back.
        try DevinSessionDatabaseFixture.create(at: database, rows: [
            .assistantRow(requestID: "req-a", timestamp: Self.timestamp, metrics: ["input_tokens": 10])
        ])
        var first = DevinSessionUsageReader()
        _ = try first.entries(at: database)

        try DevinSessionDatabaseFixture.append(at: database, rows: [
            .assistantRow(requestID: "req-a", timestamp: Self.timestamp, metrics: ["input_tokens": 0, "output_tokens": 0])
        ])

        var second = DevinSessionUsageReader()
        let entries = try second.entries(at: database)
        XCTAssertEqual(second.lastFoldKind, .incremental)
        XCTAssertTrue(entries.isEmpty)
    }
}
